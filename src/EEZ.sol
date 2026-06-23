// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IProofSystem} from "./interfaces/IProofSystem.sol";
import {IRollupContract} from "./interfaces/IRollup.sol";
import {CrossChainProxy} from "./base/CrossChainProxy.sol";
import {
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    StaticLookup,
    ExecutionEntry,
    ExpectedStateRootPerRollup,
    ProxyInfo,
    RollupConfig,
    RollupIdWithProofSystems,
    ProofSystemBatchPerVerificationEntries,
    RollupVerification
} from "./interfaces/IEEZ.sol";
import {EEZBase} from "./base/EEZBase.sol";
import {IMetaCrossChainReceiver} from "./interfaces/IMetaCrossChainReceiver.sol";

/// @title EEZ
/// @notice L1 contract managing rollup state roots, multi-prover batch posting, and cross-chain call execution
/// @dev EARLY-STAGE IMPLEMENTATION — NOT PRODUCTION READY.
///      This is a first implementation of the sync-rollups protocol. It has NOT undergone an
///      external security audit. Interfaces, storage layout, error semantics, and execution
///      flow are expected to change in the near term as design issues are fixed and the
///      protocol is iterated on. Do not rely on this code for value-bearing deployments,
///      and do not treat its current behavior as the canonical specification.
/// @dev Execution entries are posted via `postAndVerifyBatch(batch)`,
///      attested by ≥ threshold proof systems per rollup. Atomic verification: if any single
///      proof fails, the whole batch reverts.
///
///      The batch's leading `transientExecutionEntryCount` entries are loaded into
///      `_transientExecutions` (semantically transient, cleared at end of every batch). The
///      leading run of those entries with `proxyEntryHash == 0` runs inline as "immediate"
///      entries (state deltas + flat calls + rolling hash, one `_applyAndExecute` cycle per
///      entry). Then `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()`
///      is invoked (when msg.sender has code) so the caller can drive the remaining transient
///      entries via cross-chain proxy calls within the same transaction.
///
///      The batch remainder (entries past `transientExecutionEntryCount`) is published into
///      per-rollup queues keyed by `destinationRollupId` UNCONDITIONALLY — even if the meta
///      hook left transient entries unconsumed. Soundness backstop: every entry's
///      `StateDelta.currentState` is checked at consumption time, so any persistent entry
///      whose preconditions were lost with the dropped transient leftover simply fails its
///      `StateRootMismatch` check.
///
///      Deferred consumption: `executeCrossChainCall` (proxy entry) and `executeL2TX(rid)` route
///      to `verificationByRollup[rid].executionQueue[cursor]` and advance the per-rollup cursor.
contract EEZ is EEZBase {
    /// @notice The rollup ID representing L1 mainnet
    uint256 public constant MAINNET_ROLLUP_ID = 0;

    /// @notice Counter for generating rollup IDs
    uint256 public rollupCounter;

    /// @notice Mapping from rollup ID to rollup configuration (state root + ether + manager pointer)
    /// @dev The rollupContract is the source of truth for "is this id registered" — a zero
    ///      rollupContract means the slot is unused. Callbacks from the manager pass the
    ///      rollupId explicitly and the registry validates `msg.sender == rollups[rid].rollupContract`,
    ///      so no reverse-lookup mapping is needed.
    mapping(uint256 rollupId => RollupConfig config) public rollups;

    /// @notice Per-rollup deferred queue + once-per-block guard
    mapping(uint256 rollupId => RollupVerification record) internal verificationByRollup;

    // ── Transient-backed execution entries & lookup calls ──
    //
    // First N entries / M lookup calls of the batch's leading prefix live here instead of
    // the per-rollup persistent queues to save storage gas during intra-tx (meta-hook)
    // consumption. Semantically transient (populated and cleared within a single batch
    // call) but declared as regular storage since Solidity 0.8.34 does not yet support
    // `transient` data location for reference types with nested dynamic arrays. Both are
    // cleared at the end of every postAndVerifyBatch, regardless of success.
    // TODO: promote to real `transient` once Solidity supports transient reference types
    //       with nested dynamic arrays — until then, we rely on manual `delete` at the
    //       end of every postAndVerifyBatch plus SSTORE refunds from zeroing the slots.
    ExecutionEntry[] public _transientExecutions;
    StaticLookup[] public _transientStaticLookups;

    /// @notice Cursor into `_transientExecutions` for the next entry to consume.
    /// @dev Only meaningful while `_transientExecutions.length != 0`. The table's length
    ///      itself is what flags "inside a transient batch" for `_getCurrentEntry()`
    ///      and `_consumeAndExecute`; this variable just tracks progress. Transient so it
    ///      resets between transactions automatically, and explicitly reset at the end
    ///      of every postAndVerifyBatch.
    uint256 transient _transientExecutionIndex;

    // No dedicated `_inPostBatch` flag — `_transientExecutions.length != 0` already
    // identifies the dangerous re-entry window (from `_loadTransientExecutions` through cleanup).
    // Steps 1-3 of `postAndVerifyBatch` (validate, verify-STATICCALL, mark-verified) have no
    // external calls, and step 7 (publish) has no external calls either, so neither
    // needs guarding.

    /// @notice The rollup ID whose queue is supplying the entry currently being processed.
    /// @dev `0` outside execution. Used by `_getCurrentEntry()` to disambiguate which
    ///      persistent queue to route into when `_transientExecutions.length == 0`.
    uint256 transient _currentEntryRollupId;

    /// @notice Deferred-revert flag for `_consumeNestedAction` no-match path.
    /// @dev When `_consumeNestedAction` finds no matching ExpectedL1ToL2Call, transient
    ///      failed-lookup, or persistent failed-lookup, it sets this flag and returns empty
    ///      bytes instead of reverting immediately. `_applyAndExecute` checks the flag at
    ///      end-of-entry and reverts `ExecutionNotFound` then. Transient — rolls back with
    ///      the surrounding frame on revert, so no manual reset needed.
    bool transient _l1ToL2CallNotFound;

    /// @notice 1-indexed global L2→L1 call counter and cursor into `entry.l2ToL1Calls[]`.
    /// @dev `_currentL2ToL1Call != 0` also doubles as the `_insideExecution()` predicate.
    uint256 transient _currentL2ToL1Call;

    /// @notice Sequential reentrant (L1→L2) call consumption counter.
    /// @dev Also used by `staticCallLookup` to disambiguate multiple lookup calls within the same call.
    uint256 transient _lastL1ToL2CallConsumed;

    /// @notice Net ether flow for the current entry: `Σ inbound msg.value − Σ outbound call value`.
    ///         The whole accounting side of the ether-delta invariant (`Σ etherDelta == _entryEtherDelta`).
    /// @dev Signed and `transient`. Inbound side: `executeCrossChainCall` SETS it to `int256(msg.value)`
    ///      at the top level (defensive — residue can never leak across entries) and ADDS at every
    ///      reentrant call; `executeL2TX` / `attemptApplyImmediate` revert `ResidualEntryEtherIn`
    ///      unless it is already 0 (no value path reaches them). Outbound side: `_processNCalls`
    ///      SUBTRACTS `cc.value` for every successful value-bearing call. It MUST be `transient`,
    ///      not a local: a value-bearing call processed inside a reentrant sub-frame
    ///      (`_consumeNestedAction`/`_consumeSuccessfulReentrant` -> `_processNCalls`) runs in a
    ///      SEPARATE call stack — a local outflow would be dropped when that frame returns. As
    ///      `transient` both sides accumulate across frames, while revertNextNCalls / reverted-lookup
    ///      frames — which always revert — have their additions AND subtractions rolled back by the
    ///      EVM, matching the physical ETH that also rolls back. Reset to 0 at the end of `_applyAndExecute`.
    int256 transient _entryEtherDelta;

    /// @notice Emitted when a new rollup is created
    event RollupCreated(uint256 indexed rollupId, address indexed rollupContract, bytes32 initialState);

    /// @notice Emitted when a rollup state is updated (only via the registered rollupContract)
    event StateUpdated(uint256 indexed rollupId, bytes32 newStateRoot);

    /// @notice Emitted when an L2 execution is performed
    event L2ExecutionPerformed(uint256 indexed rollupId, bytes32 newState);

    /// @notice Emitted when an execution entry is consumed
    event ExecutionConsumed(
        bytes32 indexed crossChainCallHash, uint256 indexed rollupId, uint256 indexed executionQueueIndex
    );

    /// @notice Emitted when a precomputed L2 transaction is executed
    event L2TXExecuted(uint256 indexed rollupId, uint256 indexed executionQueueIndex);

    /// @notice Emitted when a batch is posted, carrying the number of rollups verified
    event BatchPosted(uint256 indexed rollupCount);

    /// @notice Emitted when an immediate entry's `_applyAndExecute` reverts during postAndVerifyBatch
    ///         step 4. The entry's state changes are rolled back; the cursor advances and the
    ///         loop continues with the next immediate entry. `revertData` carries the inner
    ///         revert payload (custom error or message) for off-chain debugging.
    event ImmediateEntrySkipped(uint256 indexed transientIdx, bytes revertData);

    /// @notice Emitted on `_consumeNestedAction`'s deferred no-match path. Returns empty
    ///         bytes; the deferred-revert flag fires `ExecutionNotFound` at the entry boundary.
    ///         Event exists because the no-match site has no error frame.
    event L1ToL2CallNotFound(
        uint256 indexed entryIndex,
        bytes32 indexed crossChainCallHash,
        uint256 currentL2ToL1Call,
        uint256 lastL1ToL2CallConsumed
    );

    /// @notice Emitted after each call completes in `_processNCalls`.
    /// @dev Not emitted for calls inside a revertNextNCalls (those events are rolled back by the revert).
    event CallResult(uint256 indexed entryIndex, uint256 indexed l2ToL1CallNumber, bool success, bytes returnData);

    /// @notice Emitted when a reentrant L1→L2 call is consumed during reentrant execution
    event L1ToL2CallConsumed(
        uint256 indexed entryIndex, uint256 indexed l1ToL2CallNumber, bytes32 crossChainCallHash, uint256 callCount
    );

    /// @notice Emitted after an entry's execution completes and all verifications pass
    event EntryExecuted(
        uint256 indexed entryIndex, bytes32 rollingHash, uint256 l2ToL1CallsProcessed, uint256 l1ToL2CallsConsumed
    );

    /// @notice Emitted after a rollback window (`revertNextNCalls`) is processed via
    ///         `executeInContextAndRevert` — `nCalls` calls ran, succeeded, then had their state rolled back.
    event CallsReverted(uint256 indexed entryIndex, uint256 startL2ToL1Call, uint256 nCalls);

    /// @notice Error when proof verification fails
    error InvalidProof();

    /// @notice Reverts when `postAndVerifyBatch` is re-entered (e.g., via the meta hook calling back
    ///         into `postAndVerifyBatch` for a disjoint rollup set, which would otherwise corrupt the
    ///         shared transient tables)
    error PostBatchReentry();

    /// @notice Error when caller is not the rollup's registered manager contract
    error NotRollupContract();

    /// @notice Error when the manager's `setStateRoot` escape hatch is invoked in the same
    ///         block a `postAndVerifyBatch` already touched the rollup
    /// @dev Conservative gate: once a verified state transition lands in block N, the manager
    ///      must wait until block N+1 to escape-mutate. Avoids invalidating queued entries'
    ///      `currentState` checks and prevents PS-set / threshold mutation from racing the meta hook.
    error RollupBatchActiveThisBlock(uint256 rollupId);

    /// @notice Error when proposed manager contract is address(0) or the registry itself
    error InvalidRollupContract();

    /// @notice Error when a rollup would have negative ether balance
    error InsufficientRollupBalance();

    /// @notice Error when the ether delta from state deltas doesn't match actual ETH flow
    error EtherDeltaMismatch();

    /// @notice A no-value top-level entry point found a nonzero `_entryEtherDelta` — should be
    ///         impossible; signals a corrupted execution context, not recoverable input.
    error ResidualEntryEtherIn();

    /// @notice Error when a state delta's currentState doesn't match the rollup's on-chain stateRoot
    error StateRootMismatch(uint256 rollupId);

    /// @notice Error when execution is attempted in a different block than the last state update for that rollup
    error ExecutionNotInCurrentBlock(uint256 rollupId);

    /// @notice Error when executeL2TX is called while already inside a cross-chain execution
    error L2TXNotAllowedDuringExecution();

    /// @notice Error when the manager's `setStateRoot` escape hatch is invoked while a cross-chain
    ///         execution is in progress (e.g., the manager is reached via a cross-chain call that
    ///         tries to re-escape mid-flow).
    error SetStateRootNotAllowedDuringExecution();

    /// @notice Error when `transientExecutionEntryCount` exceeds the entry count
    error TransientCountExceedsEntries();

    /// @notice Error when `transientStaticLookupCount` exceeds the lookup call count
    error TransientStaticLookupCountExceedsStaticLookups();

    /// @notice Error when transient lookup calls come without transient entries (unreachable —
    ///         no entries means no immediate drain and no meta hook, so nothing can consume them)
    error TransientStaticLookupsWithoutTransientEntries();

    /// @notice Error when batch validation fails for malformed inputs
    error InvalidProofSystemConfig();

    /// @notice Error when duplicate / unsorted proof systems are submitted in the batch
    error DuplicateProofSystem(address proofSystem);

    /// @notice Error when an entry's destinationRollupId, a state delta's rollupId, or a
    ///         lookup call's destinationRollupId references a rollup not in the batch
    error RollupNotInBatch(uint256 rollupId);

    /// @notice Error when not all L2→L1 calls (`entry.l2ToL1Calls`) were consumed after execution
    error UnconsumedL2ToL1Calls();

    /// @notice Proxy protection (postAndVerifyBatch): an entry routes to a rollup not in its own
    ///         `stateDeltas`, so consuming it would drive a proxy for a rollup it never proved.
    error EntryDestinationNotInStateDeltas(uint256 rollupId);

    /// @notice Proxy protection (postAndVerifyBatch): a top-level lookup's `destinationRollupId` is
    ///         not among its own `expectedStateRoots` pins — the routing target must be pinned to
    ///         proven state (mirrors the entry `destination ∈ stateDeltas` rule).
    error LookupDestinationNotPinned(uint256 rollupId);

    /// @notice Proxy protection (postAndVerifyBatch): an L2→L1 call is sourced from a rollup not in
    ///         the host's verified set (entry `stateDeltas`, or a top-level lookup's `expectedStateRoots` pins).
    ///         MAINNET (L1) is never verified — an L1-sourced cross-chain call is rejected here
    ///         (mirrors the same-network proxy ban: L1 is not its own cross-chain counterparty).
    error CallSourceNotVerified(uint256 rollupId);

    /// @notice Proxy protection (postAndVerifyBatch): a reentrant L1→L2 call targets a rollup not in
    ///         the host's verified set. MAINNET (L1) is never a valid cross-chain destination.
    error ReentrantDestinationNotVerified(uint256 rollupId);

    /// @notice Proxy protection (execution): a consumed `ExpectedL1ToL2Call`'s declared
    ///         `destinationRollupId` does not equal the calling proxy's rollup. The clear-text id
    ///         was verified against the host's `stateDeltas` at postAndVerifyBatch; this stops a
    ///         prover from declaring one rollup yet routing the call to another via the one-way hash.
    error ReentrantDestinationMismatch(uint256 declared, uint256 actual);

    /// @notice An entry's `stateDeltas` are not strictly increasing by `rollupId`. The strict order
    ///         rejects duplicate rollups (which would let one entry apply two transitions to the same
    ///         rollup) and, starting above MAINNET_ROLLUP_ID, also rejects a mainnet (L1) delta.
    error StateDeltasNotStrictlyIncreasing(uint256 rollupId);

    /// @notice A top-level lookup's `expectedStateRoots` pins are not strictly increasing by
    ///         `rollupId`. Same rationale as `StateDeltasNotStrictlyIncreasing`: rejects duplicate
    ///         pins and (bounding above MAINNET_ROLLUP_ID) a mainnet (L1) pin.
    error ExpectedStateRootsNotStrictlyIncreasing(uint256 rollupId);

    // ──────────────────────────────────────────────
    //  Rollup creation
    // ──────────────────────────────────────────────

    /// @notice Registers a pre-deployed `IRollupContract`-conforming manager contract as a new rollup
    /// @dev The caller deploys the manager (e.g. our reference `Rollup.sol`, or a custom
    ///      multisig / governance contract) with the desired proof systems / threshold /
    ///      whatever ownership model it chooses baked in, then registers it here. Registry
    ///      assigns a fresh rollupId and stores the initial state root; the manager learns its
    ///      id via the `rollupContractRegistered` callback (there is no reverse-lookup mapping).
    ///      The registry makes no assumption about how the manager
    ///      handles ownership — that's entirely the manager's concern.
    /// @param rollupContract Address of the pre-deployed `IRollupContract` contract
    /// @param initialState Initial state root for this rollup
    /// @return rollupId Newly assigned rollup ID
    function registerRollup(address rollupContract, bytes32 initialState) external returns (uint256 rollupId) {
        if (rollupContract == address(0) || rollupContract == address(this)) revert InvalidRollupContract();

        // Sequential ids stay well below 2^64 — required: ProxyInfo.originalRollupId narrows to uint64.
        rollupId = ++rollupCounter;
        rollups[rollupId] = RollupConfig({rollupContract: rollupContract, stateRoot: initialState, etherBalance: 0});

        // One-shot callback informing the manager of its rollupId. Manager must accept this
        // call only from the registry and only when not already initialized (otherwise reuse
        // of an already-registered manager would silently take over a different rollupId).
        IRollupContract(rollupContract).rollupContractRegistered(rollupId);

        emit RollupCreated(rollupId, rollupContract, initialState);
    }

    // ──────────────────────────────────────────────
    //  Batch posting & execution table (multi-prover)
    // ──────────────────────────────────────────────

    /// @notice Posts a single proof-system batch attested by ≥ threshold proof systems per rollup
    /// @dev Flow:
    ///      1. Structural validation (sorting, registration, destination membership,
    ///         transient bounds, per-rollup PS-index ranges). NO external calls.
    ///      2. Atomic verification: fetch the vkMatrix per rollup (each manager enforces its
    ///         own threshold against the rollup's chosen PS subset) and verify every proof.
    ///         ALL must verify before any state mutation — atomicity across the jointly-attesting
    ///         proof systems. These external calls are `view` (STATICCALL), so no reentrancy concern.
    ///      3. Mark every touched rollup as verified-this-block. Sets the once-per-block-per-rollup
    ///         invariant AND the read gate for `executeCrossChainCall` / `executeL2TX` (which
    ///         require `lastVerifiedBlock(rid) == block.number`). Done before the meta hook
    ///         (non-view CALL) so the hook + later proxy calls can read from the queues.
    ///      4. Build the transient stream from `entries[0..transientExecutionEntryCount)`
    ///         (and `staticLookups[0..transientStaticLookupCount)`). The stream lives in
    ///         `_transientExecutions` / `_transientStaticLookups` and is consumed via a single
    ///         global cursor.
    ///      5. Drain the leading run of transient entries whose `proxyEntryHash == 0` inline
    ///         (pure L2 transactions + L2 transactions that touch L1). These have no source
    ///         action to match so they cannot be driven by the meta hook — the only place
    ///         they can be consumed is here. Each entry is dispatched via a `try/catch`
    ///         self-call (`attemptApplyImmediate`); if `_applyAndExecute` reverts, the
    ///         entry's state mutations roll back, an `ImmediateEntrySkipped` event is
    ///         emitted, and the loop continues with the next entry.
    ///      6. If `msg.sender` is a contract, invoke its `IMetaCrossChainReceiver` hook so it
    ///         can drive the rest of the transient-backed entries via cross-chain proxy calls
    ///         within the same transaction.
    ///      7. Clean up the transient tables (whatever the hook consumed and whatever it
    ///         didn't). Anything left unconsumed is dropped here.
    ///      8. Publish the remainder (entries past `transientExecutionEntryCount`) into
    ///         per-rollup queues keyed by each entry's `destinationRollupId`. Done
    ///         unconditionally — entries are content-addressed by `StateDelta.currentState`,
    ///         so any entry whose preconditions were dropped with the transient leftover
    ///         simply fails at consumption.
    /// @param batch The proof-system batch carrying entries, lookup calls, per-rollup PS
    ///        subsets, proofs, transient prefix bounds, and the L1 `blockNumber` the batch
    ///        binds to (see `ProofSystemBatchPerVerificationEntries.blockNumber`).
    function postAndVerifyBatch(ProofSystemBatchPerVerificationEntries calldata batch) external {
        // Reentrancy guard. Per-rollup `lastVerifiedBlock` blocks same-rollup re-entry, but a
        // disjoint-rollup nested call (e.g., from the meta hook) would otherwise share the
        // same `_transientExecutions` / `_transientStaticLookups` storage and corrupt them.
        // `_transientExecutions.length != 0` is true from `_loadTransientExecutions` through cleanup,
        // covering the entire window where a meta-hook callback could reach back here.
        // `_insideExecution()` is NOT sufficient — it's false during the meta hook window
        // (between proxy calls), missing the most common reentry path.
        if (_transientExecutions.length != 0) revert PostBatchReentry();

        // 1. Structural validation, NO external calls. Catches malformed input and ensures
        //    every rollup is registered (rollupContract != 0) before we touch its manager.
        _validateStructure(batch);

        // 2. Per-rollup vk fetch + per-PS verification. Each manager enforces BOTH threshold
        //    (`proofSystemIndex.length >= threshold`) AND per-PS membership (every resolved PS
        //    address has a non-zero vkey for this rollup) inside `checkProofSystemsAndGetVkeys`
        //    — reverts on either failure, so the matrix is uniformly non-zero on success.
        //
        //    Reentrancy: both `IRollupContract.checkProofSystemsAndGetVkeys` and `IProofSystem.verify`
        //    are `view` → dispatched via STATICCALL by the compiler. State mutations inside
        //    a STATICCALL frame (including nested calls) revert at the EVM level, so a
        //    malicious manager / verifier cannot reenter (state-mutating). Safe to perform
        //    these external calls before `_markVerifiedBlockPerRollup`.
        bytes32[][] memory vkMatrix = _fetchVkMatrix(batch);
        _verifyProofSystemBatch(batch, vkMatrix);

        // 3. Mark all touched rollups as verified-this-block. Sets the once-per-block-per-rollup
        //    invariant AND the read gate for `executeCrossChainCall` / `executeL2TX` (which
        //    require `lastVerifiedBlock(rid) == block.number`). Done before the immediate-entry
        //    `_processNCalls` (which calls into proxies via non-view CALL — those CAN reenter,
        //    so the lastVerifiedBlock guard is what they hit).
        for (uint256 r = 0; r < batch.rollupIdsWithProofSystems.length; r++) {
            _markVerifiedBlockPerRollup(batch.rollupIdsWithProofSystems[r].rollupId);
        }

        // 4. Build the transient stream from the leading prefix.
        _loadTransientExecutions(batch);

        // 5. Drain the leading run of transient entries with `proxyEntryHash == 0` inline.
        //    These are the "pure L2 transactions + L2 transactions that touch L1" entries —
        //    no source action to match, so the only way to consume them is here, before the
        //    meta hook starts driving non-zero-proxyEntryHash entries via proxy calls. Each runs
        //    its own `_applyAndExecute` cycle (rolling hash / cursors reset per entry).
        //    `_entryEtherDelta` is 0 here — these entries aren't driven by an external value transfer.
        //
        //    REVERTIBLE: each entry is dispatched through a self-call wrapper. If
        //    `_applyAndExecute` reverts (currentState mismatch, rolling-hash mismatch,
        //    unconsumed calls / nested actions, etc.), the EVM revert rolls back ALL state
        //    mutations from that entry — leaving on-chain state as if the entry never ran.
        //    The cursor advance happens OUTSIDE the try frame, so the loop continues with
        //    the next entry. Skipped entries emit `ImmediateEntrySkipped` for off-chain debug.
        //    Soundness backstop: any later entry that depended on the skipped entry's state
        //    deltas will fail its own `StateRootMismatch` check at consumption time — the
        //    cascade naturally drops dependent work without needing a global abort.
        while (
            _transientExecutionIndex < _transientExecutions.length
                && _transientExecutions[_transientExecutionIndex].proxyEntryHash == bytes32(0)
        ) {
            uint256 idx = _transientExecutionIndex;
            try this.attemptApplyImmediate(idx) {}
            catch (bytes memory revertData) {
                emit ImmediateEntrySkipped(idx, revertData);
            }
            _transientExecutionIndex = idx + 1;
        }

        // 6. Meta hook — caller drives the rest of the transient entries via proxy calls.
        if (_transientExecutionIndex < _transientExecutions.length && msg.sender.code.length > 0) {
            IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions();
        }

        // 7. Cleanup transient tables (SSTORE refunds; nothing leaks into next tx). Done
        //    BEFORE the deferred publish so that any subsequent reads during publish see a
        //    clean transient surface, and storage writes happen in a single committed phase.
        delete _transientExecutions;
        delete _transientStaticLookups;
        _transientExecutionIndex = 0;

        // 8. Deferred publish — push the remainder (entries past `transientExecutionEntryCount`)
        //    into per-rollup queues keyed by `destinationRollupId`. Done unconditionally even
        //    if the meta hook didn't drain the transient stream: every entry is content-
        //    addressed via `StateDelta.currentState`, so any entry whose preconditions were
        //    lost with the dropped transient leftover will simply fail its `StateRootMismatch`
        //    check at consumption time. Publishing regardless means a hook that consumed
        //    nothing still leaves the deferred queue usable.
        _publishRemainderExecutions(batch);

        emit BatchPosted(batch.rollupIdsWithProofSystems.length);
    }

    // ──────────────────────────────────────────────
    //  postAndVerifyBatch internals
    // ──────────────────────────────────────────────

    /// @notice Self-call wrapper that runs `_applyAndExecute` for one immediate entry
    ///         in an isolated frame. Used by `postAndVerifyBatch` step 5 to make immediate-entry
    ///         execution revertible: if this frame reverts, the surrounding `try/catch`
    ///         in postAndVerifyBatch catches and skips to the next entry instead of aborting the
    ///         whole batch. Unlike `executeInContextAndRevert`, this propagates the inner
    ///         result — succeeds when `_applyAndExecute` succeeds, reverts when it reverts.
    /// @dev Sets `_currentEntryIndex` / `_currentEntryRollupId` here so transient state for
    ///      the entry being processed is set within the same frame as `_applyAndExecute`.
    ///      On revert those writes roll back too, which is fine — the next iteration sets
    ///      them fresh. The cursor advance in postAndVerifyBatch happens OUTSIDE this frame.
    function attemptApplyImmediate(uint256 transientIdx) public {
        if (msg.sender != address(this)) revert NotSelf();
        ExecutionEntry storage entry = _transientExecutions[transientIdx];
        _currentEntryIndex = transientIdx;
        _currentEntryRollupId = 0; // marker: transient phase (storage routes via length)
        if (_entryEtherDelta != 0) revert ResidualEntryEtherIn(); // immediate entries receive no inbound value
        _applyAndExecute(entry.stateDeltas, entry.rollingHash);
    }

    /// @notice Structural validation — no external calls, no vkey reads.
    /// @dev Verifies sorting, registration of rollups + PSes, transient bounds, entry /
    ///      lookup-call `destinationRollupId` membership, and per-rollup PS-index ranges.
    function _validateStructure(ProofSystemBatchPerVerificationEntries calldata batch) internal view {
        uint256 psLen = batch.proofSystems.length;
        if (psLen == 0) revert InvalidProofSystemConfig();
        if (psLen != batch.proofs.length) revert InvalidProofSystemConfig();
        if (batch.rollupIdsWithProofSystems.length == 0) revert InvalidProofSystemConfig();

        // proofSystems strictly increasing by address (rejects address(0) and duplicates).
        // No central PS registry — each rollup's manager defines its own allowed set via the
        // vkey map. The per-rollup `proofSystemIndex[]` then picks the SUBSET of the global
        // list that the rollup accepts; PSes outside any rollup's subset still cost the
        // orchestrator a `verify` call but contribute to no rollup's threshold.
        address prevPs = address(0);
        for (uint256 k = 0; k < psLen; k++) {
            address ps = batch.proofSystems[k];
            if (uint160(ps) <= uint160(prevPs)) revert DuplicateProofSystem(ps);
            prevPs = ps;
        }

        // Per-rollup checks: rollupIds strictly increasing (catches same-rid-twice and
        // rid==0/MAINNET), each rollup registered (rollupContract != 0), and each rollup's
        // proofSystemIndex[] strictly increasing within `[0, psLen)` (rejects duplicates and
        // out-of-range indices). The strictly-increasing PS-index check makes the on-chain
        // resolution to addresses unique and lets the manager rely on de-duplicated input.
        uint256 prevRid = MAINNET_ROLLUP_ID;
        for (uint256 r = 0; r < batch.rollupIdsWithProofSystems.length; r++) {
            RollupIdWithProofSystems calldata rps = batch.rollupIdsWithProofSystems[r];
            if (rps.rollupId <= prevRid) revert InvalidProofSystemConfig();
            if (rollups[rps.rollupId].rollupContract == address(0)) revert InvalidProofSystemConfig();
            prevRid = rps.rollupId;

            uint64[] calldata indices = rps.proofSystemIndex;
            if (indices.length == 0) revert InvalidProofSystemConfig();
            // Use a 1-indexed sentinel so the first iteration's `idx <= prev` works against 0.
            uint256 prevIdx;
            for (uint256 j = 0; j < indices.length; j++) {
                uint256 idx = uint256(indices[j]);
                if (idx >= psLen) revert InvalidProofSystemConfig();
                if (j > 0 && idx <= prevIdx) revert InvalidProofSystemConfig();
                prevIdx = idx;
            }
        }

        // Every state delta's / pin's rollupId must belong to the batch, and each entry's / lookup's
        // destinationRollupId must be one of them — so destination ∈ {deltas | pins} ⊆ batch is
        // transitive (no separate `_containsRollupInBatch` on the destination). That membership is
        // what keeps `_publishRemainderExecutions` from routing into a non-participating queue.
        for (uint256 i = 0; i < batch.entries.length; i++) {
            ExecutionEntry calldata entry = batch.entries[i];
            // Single pass over stateDeltas: enforce strictly-increasing-by-rollupId (bounding from
            // MAINNET_ROLLUP_ID (0) this sorts, rejects duplicate rollups — so no entry applies two
            // transitions to one rollup — and rejects a mainnet (L1) delta), require each is in the
            // batch, AND collect the entry's verified-rollup set in the same loop.
            StateDelta[] calldata deltas = entry.stateDeltas;
            uint256[] memory verifiedRollups = new uint256[](deltas.length);
            uint256 prevDeltaRid = MAINNET_ROLLUP_ID;
            for (uint256 j = 0; j < deltas.length; j++) {
                uint256 drid = deltas[j].rollupId;
                if (drid <= prevDeltaRid) revert StateDeltasNotStrictlyIncreasing(drid);
                if (!_containsRollupInBatch(batch, drid)) revert RollupNotInBatch(drid);
                verifiedRollups[j] = drid;
                prevDeltaRid = drid;
            }
            // Proxy protection: every rollup this entry's cross-chain calls touch must be part of
            // the entry's proven state transition, so a consumed proxy is always backed by a
            // verified rollup. The entry routes to (and the calls source from / target) only its
            // own `stateDeltas` rollups; MAINNET (L1) is never verified — L1 is not its own
            // cross-chain counterparty (mirrors the same-network proxy ban). destination ∈ stateDeltas
            // also makes its batch membership transitive.
            if (!_contains(verifiedRollups, entry.destinationRollupId)) {
                revert EntryDestinationNotInStateDeltas(entry.destinationRollupId);
            }
            _validateCallsContainVerifiedRollups(entry.l2ToL1Calls, entry.expectedL1ToL2Calls, verifiedRollups);
        }
        for (uint256 i = 0; i < batch.staticLookups.length; i++) {
            StaticLookup calldata lc = batch.staticLookups[i];
            // A top-level lookup's verified set is the rollups it pins (`expectedStateRoots`). Like
            // an entry's `stateDeltas`, pins are validated strictly-increasing-by-rollupId in one
            // pass (bounding from MAINNET_ROLLUP_ID (0) this sorts, dedups, and rejects a mainnet
            // pin), require each is in the batch, and they form the sub-call verified set.
            ExpectedStateRootPerRollup[] calldata pins = lc.expectedStateRoots;
            uint256[] memory verifiedRollups = new uint256[](pins.length);
            uint256 prevPinRid = MAINNET_ROLLUP_ID;
            for (uint256 j = 0; j < pins.length; j++) {
                uint256 prid = pins[j].rollupId;
                if (prid <= prevPinRid) revert ExpectedStateRootsNotStrictlyIncreasing(prid);
                if (!_containsRollupInBatch(batch, prid)) revert RollupNotInBatch(prid);
                verifiedRollups[j] = prid;
                prevPinRid = prid;
            }
            // The lookup must pin its own destination (destination ∈ pins) — same shape as the entry
            // destination check. This anchors the routing target to proven state and makes its batch
            // membership transitive.
            if (!_contains(verifiedRollups, lc.destinationRollupId)) {
                revert LookupDestinationNotPinned(lc.destinationRollupId);
            }
            // A static lookup has no reentrant table — only its read-only `l2ToL1Calls` sub-call
            // sources need to be within the pinned (verified) set.
            L2ToL1Call[] calldata lcCalls = lc.l2ToL1Calls;
            for (uint256 j = 0; j < lcCalls.length; j++) {
                if (!_contains(verifiedRollups, lcCalls[j].sourceRollupId)) {
                    revert CallSourceNotVerified(lcCalls[j].sourceRollupId);
                }
            }
        }

        // Transient prefix bounds.
        if (batch.transientExecutionEntryCount > batch.entries.length) revert TransientCountExceedsEntries();
        if (batch.transientStaticLookupCount > batch.staticLookups.length) {
            revert TransientStaticLookupCountExceedsStaticLookups();
        }
        // Transient lookups are only reachable while transient entries are mid-flight
        // (`staticCallLookup` reads the transient pool only when `_transientExecutions` is non-empty)
        // — reject the dead-weight shape.
        if (batch.transientExecutionEntryCount == 0 && batch.transientStaticLookupCount != 0) {
            revert TransientStaticLookupsWithoutTransientEntries();
        }
    }

    /// @notice Fetches the (rollup × chosen-PS-subset) vkey matrix — one external call to
    ///         `checkProofSystemsAndGetVkeys` per rollup, passing only the rollup's chosen
    ///         PS subset (resolved from indices into the batch's global `proofSystems[]`).
    ///         The manager enforces its own threshold against `subset.length` and reverts if
    ///         any subset entry isn't an allowed PS for that rollup.
    /// @dev Returns a JAGGED matrix: `vkMatrix[r].length == proofSystemIndex[r].length`. The
    ///      element at `vkMatrix[r][j]` is the vkey of `proofSystems[proofSystemIndex[r][j]]`
    ///      for rollup r. `_verifyProofSystemBatch` projects this jagged matrix into per-PS
    ///      vkey vectors when building each PS's publicInputsHash.
    function _fetchVkMatrix(ProofSystemBatchPerVerificationEntries calldata batch)
        internal
        view
        returns (bytes32[][] memory vkMatrix)
    {
        vkMatrix = new bytes32[][](batch.rollupIdsWithProofSystems.length);
        for (uint256 r = 0; r < batch.rollupIdsWithProofSystems.length; r++) {
            RollupIdWithProofSystems calldata rps = batch.rollupIdsWithProofSystems[r];
            uint64[] calldata indices = rps.proofSystemIndex;

            // Resolve indices into the batch's global PS list to PS addresses. Indices were
            // validated as in-range and strictly increasing in `_validateStructure`, so the
            // resolved proofSystemUsed is itself strictly increasing — same invariant the manager's
            // `checkProofSystemsAndGetVkeys` relies on for its own membership / dedup logic.
            address[] memory proofSystemUsed = new address[](indices.length);
            for (uint256 j = 0; j < indices.length; j++) {
                proofSystemUsed[j] = batch.proofSystems[uint256(indices[j])];
            }

            vkMatrix[r] =
                IRollupContract(rollups[rps.rollupId].rollupContract).checkProofSystemsAndGetVkeys(proofSystemUsed);
            // Manager must return exactly one vkey per resolved PS. Without this, a manager
            // returning a short array would OOB-panic when projected into per-PS vkey vectors;
            // a long array would silently ignore tail entries.
            if (vkMatrix[r].length != indices.length) revert InvalidProofSystemConfig();
        }
    }

    /// @notice Builds per-PS publicInputsHash and verifies every proof in the batch
    /// @dev Two-stage shape:
    ///        customDataAcc = bytes32(0)
    ///        for each rollup r: customDataAcc = H(customDataAcc, rollupId_r, customData_r)
    ///        sharedPublicInput = H(entryHashes, staticLookupHashes, blobHashes, H(callData), customDataAcc)
    ///      For each PS k we walk the rollupIdsWithProofSystems table in canonical order;
    ///      every rollup that lists k in its `proofSystemIndex[]` folds into a per-PS
    ///      rolling accumulator one rollup at a time:
    ///        acc_k = bytes32(0)
    ///        for each rollup r with k ∈ proofSystemIndex[r]:
    ///          acc_k = H(acc_k, rollupId_r, vkMatrix[r][j])
    ///      Then `publicInputsHash[k] = H(sharedPublicInput, acc_k)`. Each rollup's
    ///      `customData` is fetched ONCE via `getCustomData` and folded into the SHARED input
    ///      (it doesn't vary per PS), keyed by rollupId so the binding stays rollup-specific.
    function _verifyProofSystemBatch(ProofSystemBatchPerVerificationEntries calldata batch, bytes32[][] memory vkMatrix)
        internal
        view
    {
        // Selected blob hashes (indexed into the tx-level blob set)
        bytes32[] memory blobHashes = new bytes32[](batch.blobIndices.length);
        for (uint256 i = 0; i < batch.blobIndices.length; i++) {
            blobHashes[i] = blobhash(batch.blobIndices[i]);
        }

        // Per-entry hash binds the FULL entry content: stateDeltas, proxyEntryHash,
        // destinationRollupId, l2ToL1Calls[], the unified expectedL1ToL2Calls[] (success + static +
        // reverted reentrant calls, each with its currentRollingHash position key), callCount,
        // returnData, rollingHash. Prevents an orchestrator from swapping
        // call/reentrant-call/returnData at execution time without invalidating the proof.
        bytes32[] memory entryHashes = new bytes32[](batch.entries.length);
        for (uint256 i = 0; i < batch.entries.length; i++) {
            entryHashes[i] = keccak256(abi.encode(batch.entries[i]));
        }

        // Per-lookup-call hash, same rationale.
        bytes32[] memory staticLookupHashes = new bytes32[](batch.staticLookups.length);
        for (uint256 i = 0; i < batch.staticLookups.length; i++) {
            staticLookupHashes[i] = keccak256(abi.encode(batch.staticLookups[i]));
        }

        // Fetch each rollup's customData blob ONCE and fold it (keyed by rollupId) into a
        // single accumulator. The read is `view` (STATICCALL) so a malicious manager cannot
        // reenter. customData doesn't vary per PS, so it binds into the SHARED input below
        // rather than the per-PS accumulator.
        uint256 rollupCount = batch.rollupIdsWithProofSystems.length;
        bytes32 customDataAcc = bytes32(0);
        for (uint256 r = 0; r < rollupCount; r++) {
            bytes memory customData = IRollupContract(
                    rollups[batch.rollupIdsWithProofSystems[r].rollupId].rollupContract
                ).getCustomData(batch.blockNumber);
            // acc_r = H(acc_{r-1}, rollupId_r, customData_r), folded in canonical rollupId order.
            // Keyed by rollupId so each blob is bound to its rollup; provers must mirror this.
            customDataAcc =
                keccak256(abi.encode(customDataAcc, batch.rollupIdsWithProofSystems[r].rollupId, customData));
        }

        bytes32 sharedPublicInput = keccak256(
            abi.encodePacked(
                abi.encode(entryHashes),
                abi.encode(staticLookupHashes),
                abi.encode(blobHashes),
                keccak256(batch.callData),
                customDataAcc // per-rollup customData fold; shared across all PS
            )
        );

        // Per-PS verification — for each PS k, walk attesting rollups in canonical order
        // (rollupId-ascending, the order the batch enforces) and fold each rollup's
        // (rollupId, vkey_for_PS_k) into a rolling accumulator. Off-chain provers MUST mirror
        // this incremental scheme so the on-chain rebuild matches.
        for (uint256 k = 0; k < batch.proofSystems.length; k++) {
            bytes32 acc = bytes32(0);
            for (uint256 r = 0; r < rollupCount; r++) {
                RollupIdWithProofSystems calldata rps = batch.rollupIdsWithProofSystems[r];
                uint256 j = _findIndexPosition(rps.proofSystemIndex, k);
                if (j == type(uint256).max) continue;
                acc = keccak256(abi.encode(acc, rps.rollupId, vkMatrix[r][j]));
            }

            bytes32 publicInputsHash = keccak256(abi.encodePacked(sharedPublicInput, acc));

            if (!IProofSystem(batch.proofSystems[k]).verify(batch.proofs[k], publicInputsHash)) {
                revert InvalidProof();
            }
        }
    }

    /// @notice Marks `rid` as verified this block and resets its queue.
    /// @dev Wipes the execution / lookup queues and cursor on EVERY verify — including a
    ///      same-block re-verify, where a second proven batch fully SUPERSEDES the first for
    ///      this rollup (no append). Safe because state only mutates at consumption and every
    ///      entry is gated by `StateDelta.currentState`: any dropped entry a later batch
    ///      wrongly assumed had applied fails `StateRootMismatch` loudly rather than corrupting
    ///      state — so discarding unconsumed-but-proven entries is a liveness choice, not a
    ///      safety one.
    function _markVerifiedBlockPerRollup(uint256 rid) internal {
        RollupVerification storage rec = verificationByRollup[rid];
        rec.lastVerifiedBlock = block.number;
        // Wipe on every verify: a same-block verify replaces the queue.
        delete rec.executionQueue;
        delete rec.staticLookupQueue;
        rec.executionQueueIndex = 0;
    }

    /// @notice Builds the transient stream from the batch's leading prefix
    /// @dev The bounds are validated in `_validateStructure` so we don't re-check here.
    function _loadTransientExecutions(ProofSystemBatchPerVerificationEntries calldata batch) internal {
        for (uint256 i = 0; i < batch.transientExecutionEntryCount; i++) {
            _transientExecutions.push(batch.entries[i]);
        }
        for (uint256 i = 0; i < batch.transientStaticLookupCount; i++) {
            _transientStaticLookups.push(batch.staticLookups[i]);
        }
    }

    /// @notice Publishes the batch remainder (entries past `transientExecutionEntryCount`)
    ///         into per-rollup queues keyed by `destinationRollupId`
    function _publishRemainderExecutions(ProofSystemBatchPerVerificationEntries calldata batch) internal {
        for (uint256 i = batch.transientExecutionEntryCount; i < batch.entries.length; i++) {
            uint256 destRid = batch.entries[i].destinationRollupId;
            verificationByRollup[destRid].executionQueue.push(batch.entries[i]);
        }
        
        for (uint256 i = batch.transientStaticLookupCount; i < batch.staticLookups.length; i++) {
            uint256 destRid = batch.staticLookups[i].destinationRollupId;
            // A static lookup is queued under its own `destinationRollupId` — coherent by
            // construction: the `staticCallLookup` scan targets the proxy's `originalRollupId`, which
            // is also the target rollup bound into `crossChainCallHash`.
            verificationByRollup[destRid].staticLookupQueue.push(batch.staticLookups[i]);
        }
    }

    // ──────────────────────────────────────────────
    //  L2 execution (proxy entry point)
    // ──────────────────────────────────────────────

    /// @notice Executes a cross-chain call initiated by an authorized proxy
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return result The return data from the execution
    function executeCrossChainCall(address sourceAddress, bytes calldata callData)
        external
        payable
        returns (bytes memory result)
    {
        // Only PROXY
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
        if (proxyInfo.originalAddress == address(0)) revert UnauthorizedProxy();

        uint256 destRid = proxyInfo.originalRollupId;

        // Block-scoped read gate — entries can only be consumed in the block they were posted
        if (verificationByRollup[destRid].lastVerifiedBlock != block.number) {
            revert ExecutionNotInCurrentBlock(destRid);
        }

        bytes32 crossChainCallHash = computeCrossChainCallHash(
            destRid, proxyInfo.originalAddress, msg.value, callData, sourceAddress, MAINNET_ROLLUP_ID
        );

        emit CrossChainCallExecuted(crossChainCallHash, msg.sender, sourceAddress, callData, msg.value);

        if (_insideExecution()) {
            // Reentrant — ADD this call's value to the entry's net-ether accumulator
            _entryEtherDelta += int256(msg.value);
            return _consumeNestedAction(destRid, crossChainCallHash);
        }

        // Top-level — SET (not add): a fresh entry starts from exactly its own msg.value,
        // so residue can never leak across entries.
        _entryEtherDelta = int256(msg.value);
        return _consumeAndExecute(destRid, crossChainCallHash);
    }

    // ──────────────────────────────────────────────
    //  Execute precomputed L2 transaction
    // ──────────────────────────────────────────────

    /// @notice Executes the next pure-L2 transaction queued for `rollupId`
    /// @dev The next entry must have `proxyEntryHash == bytes32(0)` — consumed from the transient
    ///      table while a batch is mid-flight, otherwise from the rollup's queue.
    ///      Cannot run while reentrantly inside another cross-chain execution.
    function executeL2TX(uint256 rollupId) external returns (bytes memory result) {
        if (verificationByRollup[rollupId].lastVerifiedBlock != block.number) {
            revert ExecutionNotInCurrentBlock(rollupId);
        }

        if (_insideExecution()) revert L2TXNotAllowedDuringExecution();

        // Non-payable and never mid-entry — a dirty accumulator here is a bug; surface it, don't mask it.
        if (_entryEtherDelta != 0) revert ResidualEntryEtherIn();

        // During the transient phase consumption comes from the transient table — emit that cursor.
        uint256 idx = _transientExecutions.length != 0
            ? _transientExecutionIndex
            : verificationByRollup[rollupId].executionQueueIndex;
        emit L2TXExecuted(rollupId, idx);
        return _consumeAndExecute(rollupId, bytes32(0));
    }

    // ──────────────────────────────────────────────
    //  Internal execution
    // ──────────────────────────────────────────────

    /// @notice Resolves the entry currently being processed.
    /// @dev While the transient table is non-empty, `_currentEntryIndex` indexes into it.
    ///      Otherwise we route into `verificationByRollup[_currentEntryRollupId].executionQueue` —
    ///      the rollup whose queue supplied the entry being executed (set by
    ///      `_consumeAndExecute` before entering the inner flow).
    function _getCurrentEntry() internal view returns (ExecutionEntry storage entry) {
        if (_transientExecutions.length != 0) {
            entry = _transientExecutions[_currentEntryIndex];
        } else {
            entry = verificationByRollup[_currentEntryRollupId].executionQueue[_currentEntryIndex];
        }
    }

    /// @notice Resolves a reentrant (L1→L2) CALL: a plain-success entry consumed from the unified
    ///         `expectedL1ToL2Calls` table, or a reverted entry executed as a sub-execution.
    /// @dev Both are content-addressed by `(crossChainCallHash, currentRollingHash)` against the
    ///      active entry table (`expectedL1ToL2Calls`) — `currentRollingHash` is the live `_rollingHash`,
    ///      which uniquely pins the execution point (it folds every prior call / nesting boundary).
    ///      Routing:
    ///      1. PLAIN SUCCESS (`!isStatic && !failed`) matching the key → `_consumeSuccessfulReentrant`,
    ///         which hashes NESTED_BEGIN/END and runs the entry's OWN `l2ToL1Calls[]` sub-array as a
    ///         committing sub-execution (saved/restored cursor frame), then returns `returnData`.
    ///      2. REVERTED (`failed && !isStatic`) matching the key → `_executeRevertedNestedLookup`,
    ///         which runs the entry's own sub-calls and always reverts with `returnData`.
    ///      3. No match → set the deferred-revert flag `_l1ToL2CallNotFound` and return empty
    ///         bytes; the end-of-entry check in `_applyAndExecute` reverts `ExecutionNotFound`.
    ///
    ///      Matching is a STRICT FORWARD scan from `_lastL1ToL2CallConsumed`: a CALL only ever
    ///      matches an entry at/after the cursor, and a plain success advances it past the matched
    ///      index (never backward). Single pass — the first non-static match at/after the cursor IS
    ///      the entry; its `failed` flag picks reverted-vs-success (the key is unique per position, so
    ///      success and revert can't share one). Static reentrant reads never reach here — the proxy
    ///      dispatches them through `staticCallLookup` (a STATICCALL, which cannot advance the cursor,
    ///      though it scans the same forward window). Completeness of the success entries rests on the
    ///      rolling hash + the flat-call cursor, not a table-length check: a skipped success entry
    ///      either leaves flat calls unconsumed (`UnconsumedL2ToL1Calls`) or diverges the rolling
    ///      hash; an unused entry is inert (exactly as an unused lookup was).
    function _consumeNestedAction(uint256 destRid, bytes32 crossChainCallHash) internal returns (bytes memory) {
        // Active host table: the containing entry's, or — while a reverted lookup executes — the
        // top-level lookup's. A reverted nested sub-execution shares the SAME host table; its
        // entries are disambiguated by the seeded `currentRollingHash`.
        ExpectedL1ToL2Call[] storage expectedCalls = _getCurrentEntry().expectedL1ToL2Calls;
        bytes32 roll = _rollingHash; // position key — folds every prior call / nesting boundary

        // STRICT FORWARD scan from `_lastL1ToL2CallConsumed`: reentrant calls are consumed in order,
        // so the scan never looks before the cursor — a CALL can match a future entry but never a
        // previously-consumed one. Content-addressing by (crossChainCallHash, currentRollingHash) is
        // unique per CALL position, so a success and a reverted entry can never share it — the first
        // non-static match at/after the cursor IS the entry, and its `failed` flag selects the path.
        // Static entries are skipped here; they resolve through `staticCallLookup` (also forward-scanned).
        for (uint256 i = _lastL1ToL2CallConsumed; i < expectedCalls.length; i++) {
            ExpectedL1ToL2Call storage nested = expectedCalls[i];
            if (
                !nested.isStatic && nested.crossChainCallHash == crossChainCallHash
                    && nested.currentRollingHash == roll
            ) {
                // Proxy protection: the declared destination (verified against the host's stateDeltas
                // at postAndVerifyBatch) must be the rollup actually being called — the proxy's rollup.
                if (nested.destinationRollupId != destRid) {
                    revert ReentrantDestinationMismatch(nested.destinationRollupId, destRid);
                }
                if (nested.failed) {
                    _executeRevertedNestedLookup(i); // always reverts (cursor advance would roll back anyway)
                }
                // Plain success: consume entry `i` and move the cursor PAST it (never backward).
                _lastL1ToL2CallConsumed = i + 1;
                return _consumeSuccessfulReentrant(i, crossChainCallHash, i + 1);
            }
        }

        // No match anywhere — defer the revert. Set flag, return empty bytes; the
        //    end-of-entry check in `_applyAndExecute` reverts `ExecutionNotFound`.
        //    NOTE: returning empty bytes may still revert this call sooner than the
        //    end-of-entry check — the proxy `.call` will return `(success=true, "")`, but
        //    the calling contract typically ABI-decodes the return value into a typed
        //    result. If it expects a non-empty payload (e.g. `abi.decode(retData, (uint256))`)
        //    the decode itself reverts the calling frame, which in turn propagates up. The
        //    deferred-revert flag only guarantees the *entry* eventually reverts; it does
        //    NOT guarantee execution reaches the end-of-entry check intact.
        // Emit so off-chain can locate the no-match site — the eventual revert points at the entry boundary.
        emit L1ToL2CallNotFound(_currentEntryIndex, crossChainCallHash, _currentL2ToL1Call, _lastL1ToL2CallConsumed);
        _l1ToL2CallNotFound = true;
        return "";
    }

    /// @notice Runs a plain-success reentrant call's OWN `l2ToL1Calls[]` sub-array as a COMMITTING
    ///         sub-execution, then returns its cached `returnData`.
    /// @dev Unlike a reverted sub-execution, the sub-calls' state AND rolling-hash contributions
    ///      PERSIST, so it folds into the host's single continuous `_rollingHash` (no seed, no
    ///      separate sub-hash) between NESTED_BEGIN/END and cannot use the revert-unwind to restore
    ///      the outer frame. Instead it saves/restores the outer flat-call cursor and the
    ///      reverted-lookup pointers manually; the sub-array runs under a fresh local cursor (so
    ///      `_activeCalls()` resolves to THIS entry's sub-array via `_reentrantSubFrameIndex`). The
    ///      forward cursor `_lastL1ToL2CallConsumed` (already advanced past `index` by the caller) is
    ///      reset to 0 for the sub-frame's own forward scan and restored afterwards. `nestedNumber`
    ///      (the matched array index + 1) labels the NESTED_BEGIN/END frame in the rolling hash.
    function _consumeSuccessfulReentrant(uint256 index, bytes32 crossChainCallHash, uint256 nestedNumber)
        internal
        returns (bytes memory)
    {
        ExpectedL1ToL2Call storage nested = _getCurrentEntry().expectedL1ToL2Calls[index];
        uint256 subLen = nested.l2ToL1Calls.length;

        emit L1ToL2CallConsumed(_currentEntryIndex, nestedNumber, crossChainCallHash, subLen);
        _rollingHashNestedBegin(nestedNumber);

        // Save the outer frame; the sub-array runs under fresh cursors that fold into the SAME
        // continuous rolling hash. `_lastL1ToL2CallConsumed` was set to `index + 1` by the caller.
        uint256 outerCursor = _currentL2ToL1Call;
        uint256 outerConsumed = _lastL1ToL2CallConsumed;
        bool outerInside = _inReentrantSubFrame;
        uint256 outerRevIdx = _reentrantSubFrameIndex;

        _inReentrantSubFrame = true; // scopes `_activeCalls()` to this entry's sub-array
        _reentrantSubFrameIndex = index;
        _currentL2ToL1Call = 0;
        _lastL1ToL2CallConsumed = 0; // sub-frame's own forward cursor

        // If `_processNCalls` (or the check below) REVERTS and that revert propagates out of this
        // call's `executeCrossChainCall` frame, the manual restore is skipped — but harmlessly: the
        // tstore writes above live in this frame, so the EVM rolls them back to exactly the saved
        // outer values on unwind. The manual restore only matters on the normal-return path.
        _processNCalls(subLen);
        if (_currentL2ToL1Call != subLen) revert UnconsumedL2ToL1Calls();

        // Restore the outer frame (state + continuous rolling hash already committed).
        _currentL2ToL1Call = outerCursor;
        _lastL1ToL2CallConsumed = outerConsumed;
        _inReentrantSubFrame = outerInside;
        _reentrantSubFrameIndex = outerRevIdx;

        _rollingHashNestedEnd(nestedNumber);
        return nested.returnData;
    }

    /// @notice Consumes the next execution entry, applies state deltas, executes calls, and verifies rolling hash
    /// @dev Consults the transient table first ("always look for transient calls before storage calls").
    ///      While a postAndVerifyBatch call is running, `_transientExecutions` is non-empty and ALL consumption
    ///      is routed through it via a global cursor — entries are NOT popped, only `_transientExecutionIndex`
    ///      advances. Because that cursor is GLOBAL (not per-rollup), the transient branch also requires
    ///      `destinationRollupId == destRid`: the block gate passes for any rollup verified this block
    ///      (including by an earlier batch), and `proxyEntryHash == 0` (executeL2TX) carries no rollup
    ///      binding of its own. Outside the transient batch, consumption is routed by the destination
    ///      rollup to `verificationByRollup[destRid].executionQueue` with that rollup's own cursor —
    ///      there `destinationRollupId` is consistent by construction (entries are published under it).
    ///
    ///      Miss path: when the cursor is out of bounds or the next entry's `proxyEntryHash` doesn't
    ///      match, we simply revert `ExecutionNotFound`. There is no reverted-top-level fallback —
    ///      top-level reverting calls are expressed as normal entries, and the static pool
    ///      (`StaticLookup`) is read-only, reachable only through `staticCallLookup`.
    /// @param destRid The destination rollup whose queue / transient slot to consume from
    /// @param crossChainCallHash The expected action input hash for the next entry
    /// @return result The pre-computed return data from the action
    function _consumeAndExecute(uint256 destRid, bytes32 crossChainCallHash) internal returns (bytes memory result) {
        ExecutionEntry storage entry;
        uint256 idx;

        if (_transientExecutions.length != 0) {
            idx = _transientExecutionIndex;
            if (
                idx >= _transientExecutions.length || _transientExecutions[idx].proxyEntryHash != crossChainCallHash
                    || _transientExecutions[idx].destinationRollupId != destRid
            ) {
                // No matching entry. (Top-level reverting calls are no longer a pooled lookup —
                // they're expressed as normal entries — so there is no reverted-lookup fallback here.)
                revert ExecutionNotFound();
            }
            _transientExecutionIndex = idx + 1;
            entry = _transientExecutions[idx];
            _currentEntryRollupId = 0; // marker: transient phase (storage routes via length)
        } else {
            RollupVerification storage rec = verificationByRollup[destRid];
            idx = rec.executionQueueIndex;
            if (idx >= rec.executionQueue.length || rec.executionQueue[idx].proxyEntryHash != crossChainCallHash) {
                // No matching entry. (Top-level reverting calls are no longer a pooled lookup —
                // they're expressed as normal entries — so there is no reverted-lookup fallback here.)
                revert ExecutionNotFound();
            }
            rec.executionQueueIndex = idx + 1;
            entry = rec.executionQueue[idx];
            _currentEntryRollupId = destRid;
        }

        emit ExecutionConsumed(crossChainCallHash, destRid, idx);

        _currentEntryIndex = idx;
        _applyAndExecute(entry.stateDeltas, entry.rollingHash);

        return entry.returnData;
    }

    /// @notice Applies state deltas (with currentState validation), processes the entry's
    ///         top-level calls, verifies rolling hash, checks ether accounting, then resets
    ///         _currentL2ToL1Call
    /// @dev `_entryEtherDelta` already holds the entry-point call's `msg.value` when we get here
    ///      (SET by the top-level entry point before consumption), so it is NOT reset in
    ///      this preamble — only at the end, after the invariant check.
    /// @dev The entry's `l2ToL1Calls[]` is now its TOP-LEVEL calls only (each reentrant frame
    ///      carries its own sub-calls), so it is run to completion — no `callCount` partition.
    function _applyAndExecute(StateDelta[] memory deltas, bytes32 rollingHash) internal {
        ExecutionEntry storage entry = _getCurrentEntry();
        _rollingHash = bytes32(0);
        _currentL2ToL1Call = 0;
        _lastL1ToL2CallConsumed = 0;

        _processNCalls(entry.l2ToL1Calls.length);
        int256 totalEtherDelta = _applyStateDeltas(deltas);

        // Check the deferred no-match flag from `_consumeNestedAction` first so the failure
        // surfaces as `ExecutionNotFound` rather than the downstream `RollingHashMismatch` it
        // would otherwise cause (returning empty bytes diverges the entry's rolling hash).
        if (_l1ToL2CallNotFound) revert ExecutionNotFound();
        if (_rollingHash != rollingHash) revert RollingHashMismatch();
        if (_currentL2ToL1Call != entry.l2ToL1Calls.length) revert UnconsumedL2ToL1Calls();
        // No reentrant table-length check: the unified `expectedL1ToL2Calls` mixes plain-success
        // entries with static / reverted ones (content-addressed, may be unused). Completeness of
        // the success entries is enforced by the rolling hash + the flat-call cursor above — a
        // missing success entry diverges one or the other; an unused entry is inert.
        // `_entryEtherDelta` sums net ether across the top-level frame AND every reentrant sub-frame,
        // so the invariant captures the full physical flow.
        if (totalEtherDelta != _entryEtherDelta) revert EtherDeltaMismatch();

        emit EntryExecuted(_currentEntryIndex, _rollingHash, _currentL2ToL1Call, _lastL1ToL2CallConsumed);
        _currentL2ToL1Call = 0; // resets _insideExecution()
        _entryEtherDelta = 0; // reset for the next top-level entry in this tx
    }

    /// @notice Processes N calls from the active flat call array (entry top-level, or a reentrant
    ///         sub-frame's own `l2ToL1Calls[]`).
    /// @param count Number of calls to process
    /// @dev Outgoing ETH from successful value calls is SUBTRACTED from the `transient _entryEtherDelta`
    ///      accumulator (NOT a local return) so every frame — top-level AND reentrant sub-frames —
    ///      contributes to one entry-wide total that survives the separate call stacks. Subtractions
    ///      inside a revertNextNCalls / reverted sub-execution roll back with that frame's revert (the tstore
    ///      is undone with the physical value transfer), so only committed outflow survives.
    function _processNCalls(uint256 count) internal {
        // Active flat-call array: the entry's, or the reentrant sub-frame's while one is executing.
        L2ToL1Call[] storage calls = _activeCalls();
        uint256 processed = 0;
        while (processed < count) {
            uint256 revertNextNCalls = calls[_currentL2ToL1Call].revertNextNCalls;

            if (revertNextNCalls == 0) {
                L2ToL1Call memory cc = calls[_currentL2ToL1Call];
                _currentL2ToL1Call++;

                _rollingHashCallBegin(_currentL2ToL1Call);

                address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
                if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
                    _createCrossChainProxyInternal(cc.sourceAddress, cc.sourceRollupId);
                }

                bool success;
                bytes memory retData;
                if (cc.isStatic) {
                    // Read-only dispatch: STATICCALL carries no value and reverts on any state write.
                    // A static call loaded with value is malformed — reject it rather than drop the value.
                    if (cc.value != 0) revert StaticCallWithValue();

                    (success, retData) = sourceProxy.staticcall(
                        abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data))
                    );
                } else {
                    (success, retData) = sourceProxy.call{
                        value: cc.value
                    }(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)));
                    if (cc.value > 0 && success) {
                        _entryEtherDelta -= int256(cc.value);
                    }
                }

                _rollingHashCallEnd(_currentL2ToL1Call, success, retData);
                emit CallResult(_currentEntryIndex, _currentL2ToL1Call, success, retData);
                processed++;
            } else {
                uint256 savedCallNumber = _currentL2ToL1Call;
                calls[_currentL2ToL1Call].revertNextNCalls = 0;

                try this.executeInContextAndRevert(revertNextNCalls) {}
                catch (bytes memory revertData) {
                    // Direct assign is still an OR-merge: the inner frame inherits the outer
                    // flag and never clears it, so a span no-match survives the forced revert.
                    (_rollingHash, _lastL1ToL2CallConsumed, _currentL2ToL1Call, _l1ToL2CallNotFound) =
                        _decodeContextResult(revertData);
                }

                // Restore the `revertNextNCalls` we zeroed above (so the array reads back as authored;
                // not strictly required since the slot isn't read again this entry).
                calls[savedCallNumber].revertNextNCalls = revertNextNCalls;
                emit CallsReverted(_currentEntryIndex, savedCallNumber, revertNextNCalls);
                processed += revertNextNCalls;
            }
        }
    }

    /// @notice Executes calls in an isolated context that always reverts
    function executeInContextAndRevert(uint256 callCount) external {
        if (msg.sender != address(this)) revert NotSelf();
        _processNCalls(callCount);
        revert ContextResult(_rollingHash, _lastL1ToL2CallConsumed, _currentL2ToL1Call, _l1ToL2CallNotFound);
    }

    /// @notice Validates and applies state deltas; sums ether deltas across rollups
    function _applyStateDeltas(StateDelta[] memory deltas) internal returns (int256 totalEtherDelta) {
        for (uint256 i = 0; i < deltas.length; i++) {
            StateDelta memory delta = deltas[i];
            RollupConfig storage config = rollups[delta.rollupId];
            if (config.stateRoot != delta.currentState) revert StateRootMismatch(delta.rollupId);
            config.stateRoot = delta.newState;
            totalEtherDelta += delta.etherDelta;

            if (delta.etherDelta < 0) {
                uint256 decrement = uint256(-delta.etherDelta);
                if (config.etherBalance < decrement) revert InsufficientRollupBalance();
                config.etherBalance -= decrement;
            } else if (delta.etherDelta > 0) {
                config.etherBalance += uint256(delta.etherDelta);
            }

            emit L2ExecutionPerformed(delta.rollupId, delta.newState);
        }
    }

    /// @notice Whether every state-root pin of a top-level lookup equals the live root.
    ///         Part of the MATCH predicate (full-scan semantics) — a mismatch skips the
    ///         candidate instead of reverting.
    function _stateRootsMatch(StaticLookup storage sc) internal view returns (bool) {
        ExpectedStateRootPerRollup[] storage pins = sc.expectedStateRoots;
        for (uint256 i = 0; i < pins.length; i++) {
            if (rollups[pins[i].rollupId].stateRoot != pins[i].stateRoot) return false;
        }
        return true;
    }

    // ──────────────────────────────────────────────
    //  Predicates
    // ──────────────────────────────────────────────

    /// @notice Returns true if currently inside a cross-chain call execution
    function _insideExecution() internal view returns (bool) {
        return _currentL2ToL1Call != 0;
    }

    // ──────────────────────────────────────────────
    //  Active-execution accessors
    // ──────────────────────────────────────────────
    //
    // `_processNCalls` and `_consumeNestedAction` operate on whichever flat-call / reentrant
    // tables are active. Two contexts:
    //   - normal entry execution → the entry's tables;
    //   - a reentrant SUB-FRAME executing (`_inReentrantSubFrame`) → the `ExpectedL1ToL2Call` at
    //     `_reentrantSubFrameIndex` within the host reentrant table (`_getCurrentEntry().expectedL1ToL2Calls`) supplies the
    //     flat sub-calls. NOTE: despite its name, `_inReentrantSubFrame` is set for BOTH a reverted
    //     sub-execution AND a committing success sub-frame (`_consumeSuccessfulReentrant`) — both run a
    //     reentrant entry's OWN `l2ToL1Calls[]`. (A rename to a neutral name is deferred with the L2
    //     mirror, since the field lives in the shared `EEZBase`.) The reentrant table itself stays the
    //     host's, since a sub-execution's own reentrant calls live there too (disambiguated by the
    //     seeded / continued `currentRollingHash`).

    /// @notice The flat L2→L1 call array driving the current execution — a reentrant sub-frame's
    ///         own `l2ToL1Calls[]` while one runs, otherwise the entry's top-level calls.
    /// @dev The reentrant (L1→L2) table is always the current entry's `expectedL1ToL2Calls` (read
    ///      directly off `_getCurrentEntry()` at the call sites). A reentrant sub-frame
    ///      resolves its own reentrant calls from that SAME table, keyed by the seeded / continued
    ///      `currentRollingHash` — top-level pooled lookups are static-only, so there is no
    ///      executed-lookup host to switch to.
    function _activeCalls() internal view returns (L2ToL1Call[] storage) {
        if (_inReentrantSubFrame) {
            return _getCurrentEntry().expectedL1ToL2Calls[_reentrantSubFrameIndex].l2ToL1Calls;
        }
        return _getCurrentEntry().l2ToL1Calls;
    }

    // ──────────────────────────────────────────────
    //  Static-lookup resolution
    // ──────────────────────────────────────────────

    /// @notice Shared static-resolution body: run the sub-calls (untagged schema, always
    ///         compared — an empty `calls[]` hashes to 0, which must match a sub-call-less
    ///         lookup's `rollingHash`), then return the cached data, or revert with it when
    ///         `failed`.
    function _resolveStaticLookup(L2ToL1Call[] storage calls, bytes32 rollingHash, bool failed, bytes memory returnData)
        internal
        view
        returns (bytes memory)
    {
        if (_processNStaticCalls(calls) != rollingHash) revert RollingHashMismatch();
        if (failed) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return returnData;
    }

    /// @notice Runs a reverted NESTED reentrant call (the reverted `expectedL1ToL2Calls[index]`) as a
    ///         self-contained mini-entry, then reverts with its cached `returnData`. Runs INLINE in
    ///         the consuming `executeCrossChainCall` frame; the terminal revert discards the sub-call
    ///         state AND restores the outer cursors (the EVM rolls back every tstore here), so the
    ///         pre-revert checks need no `ContextResult` escape. The sub-execution SEEDS its rolling
    ///         hash with the call's `currentRollingHash` so its own reentrant calls (in the same host
    ///         table) occupy a distinct hash namespace — replacing the old `executingLookupIndex`
    ///         coordinate. Deeper reverted sub-executions compose via the same unwind.
    function _executeRevertedNestedLookup(uint256 index) internal {
        ExpectedL1ToL2Call storage el = _getCurrentEntry().expectedL1ToL2Calls[index];
        uint256 subLen = el.l2ToL1Calls.length;

        // Pointers for deeper frames (`_activeCalls()`); storage refs can't be transient.
        _reentrantSubFrameIndex = index;
        _inReentrantSubFrame = true;

        // Fresh sub-execution context. The flag reset shields it from an earlier outer no-match; the
        // terminal revert restores the outer value. The rolling hash is SEEDED (not zeroed) so this
        // context's reentrant keys stay distinct from the host's and sibling sub-executions'.
        _l1ToL2CallNotFound = false;
        _rollingHash = el.currentRollingHash;
        _currentL2ToL1Call = 0;
        _lastL1ToL2CallConsumed = 0;

        _processNCalls(subLen);

        // Same end-checks/order as `_applyAndExecute` (deferred no-match first); no reentrant
        // table-length check — static / reverted entries are a content-addressed pool that may be
        // partially used.
        if (_l1ToL2CallNotFound) revert ExecutionNotFound();
        if (_rollingHash != el.rollingHash) revert RollingHashMismatch();
        if (_currentL2ToL1Call != subLen) revert UnconsumedL2ToL1Calls();

        bytes memory returnData = el.returnData;
        assembly {
            revert(add(returnData, 0x20), mload(returnData))
        }
    }

    /// @notice Executes the lookup call's optional `calls[]` in static context and computes a
    ///         rolling hash of the results (untagged static schema). No `revertNextNCalls` handling.
    /// @dev All proxies referenced must already be deployed; CREATE2 is unavailable inside a
    ///      STATICCALL frame. The accumulator is a local, not `_rollingHash`, so this is verified
    ///      against `StaticLookup.rollingHash`. See `docs/CORE_PROTOCOL_SPEC.md` §E.2.
    function _processNStaticCalls(L2ToL1Call[] memory calls) internal view returns (bytes32 computedHash) {
        for (uint256 i = 0; i < calls.length; i++) {
            L2ToL1Call memory cc = calls[i];
            address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
            // STATICCALL to a codeless address silently succeeds — reject so the prover can't pre-hash a no-op.
            if (sourceProxy.code.length == 0) revert LookupCallProxyNotDeployed(sourceProxy);
            (bool success, bytes memory retData) =
                sourceProxy.staticcall(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)));
            computedHash = _rollingHashStaticResult(computedHash, success, retData);
        }
    }

    // ──────────────────────────────────────────────
    //  Static lookup
    // ──────────────────────────────────────────────

    /// @notice Looks up a pre-computed lookup result.
    /// @dev Inside an execution: scans the active host's unified `expectedL1ToL2Calls` for an
    ///      `isStatic` entry matching `(crossChainCallHash, currentRollingHash)` — the same
    ///      content-addressed key the reentrant CALLs use, with `currentRollingHash` read from the
    ///      live `_rollingHash`. Outside: while a batch is mid-flight, ONLY its transient pool (the
    ///      transient phase is self-contained — see docs/CAVEATS.md); otherwise the routed rollup's
    ///      persistent `staticLookupQueue`. Match: a top-level `StaticLookup` with `crossChainCallHash` and
    ///      every state-root pin live (full scan — a non-matching candidate is skipped). tload works
    ///      in static context, so the transient tracking variables are readable.
    /// @dev TODO (perf): linear scans are O(n) — sort + binary-search once profiling shows
    ///      it matters (the publicInputsHash already binds the arrays, so prover re-ordering
    ///      can't sneak in).
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return The pre-computed return data
    function staticCallLookup(address sourceAddress, bytes calldata callData) external view returns (bytes memory) {
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
        if (proxyInfo.originalAddress == address(0)) revert UnauthorizedProxy();

        uint256 destRid = proxyInfo.originalRollupId;
        bytes32 crossChainCallHash = computeCrossChainCallHash(
            destRid, proxyInfo.originalAddress, 0, callData, sourceAddress, MAINNET_ROLLUP_ID
        );

        // Nested: the active host's unified reentrant table, content-addressed by
        // (crossChainCallHash, currentRollingHash). A STATICCALL cannot mutate the cursor, so a
        // static read is always position-pinned by the rolling hash rather than consumed.
        if (_insideExecution()) {
            bytes32 roll = _rollingHash;
            // Forward scan from the cursor — same strict-forward window as `_consumeNestedAction`
            // (a static read cannot advance the cursor, but it still only matches at/after it).
            ExpectedL1ToL2Call[] storage expectedCalls = _getCurrentEntry().expectedL1ToL2Calls;
            for (uint256 i = _lastL1ToL2CallConsumed; i < expectedCalls.length; i++) {
                ExpectedL1ToL2Call storage el = expectedCalls[i];
                if (el.isStatic && el.crossChainCallHash == crossChainCallHash && el.currentRollingHash == roll) {
                    // Proxy protection: the declared destination (verified at postAndVerifyBatch)
                    // must be the rollup actually being read — the proxy's rollup.
                    if (el.destinationRollupId != destRid) {
                        revert ReentrantDestinationMismatch(el.destinationRollupId, destRid);
                    }
                    return _resolveStaticLookup(el.l2ToL1Calls, el.rollingHash, el.failed, el.returnData);
                }
            }
            revert ExecutionNotFound();
        }

        // Top-level: scan the single table in scope — the batch's transient pool while one is
        // mid-flight (the transient phase is self-contained — see docs/CAVEATS.md), otherwise
        // `destRid`'s persistent queue.
        StaticLookup[] storage staticLookups =
            _transientExecutions.length != 0 ? _transientStaticLookups : verificationByRollup[destRid].staticLookupQueue;
        for (uint256 i = 0; i < staticLookups.length; i++) {
            StaticLookup storage sc = staticLookups[i];
            // Proxy protection: fold the declared destination into the match. The transient pool
            // is a single global table (not queue-routed by rollup), so without this a prover could
            // resolve a lookup for a rollup other than the calling proxy's. Persistent lookups are
            // queue-routed by destination, so this is always true for them.
            if (
                sc.crossChainCallHash == crossChainCallHash && sc.destinationRollupId == destRid && _stateRootsMatch(sc)
            ) {
                return _resolveStaticLookup(sc.l2ToL1Calls, sc.rollingHash, sc.failed, sc.returnData);
            }
        }

        revert ExecutionNotFound();
    }

    // ──────────────────────────────────────────────
    //  Rollup management (only registered manager)
    // ──────────────────────────────────────────────
    //
    // `setStateRoot` below is the only path through which the registered manager contract
    // can mutate central state. The manager passes its rollupId explicitly (learned via the
    // `rollupContractRegistered` callback — there is no reverse-lookup mapping) and the
    // registry validates `msg.sender == rollups[rid].rollupContract`. Gated on the registry's
    // `lastVerifiedBlock(rid) == block.number` predicate, the single source of truth for
    // "this rollup is mid-flow this block — don't mutate". The per-rollup manager contract
    // has no lockout modifier on its owner ops because (a) only `setStateRoot` reaches
    // central state and (b) it's already gated here.

    /// @notice Owner escape hatch for setting the state root directly. Callable only by the
    ///         registered manager contract for `rollupId`. Locked out for the rest of the block
    ///         once any postAndVerifyBatch has touched this rollup (see `RollupBatchActiveThisBlock`).
    function setStateRoot(uint256 rollupId, bytes32 newStateRoot) external {
        if (msg.sender != rollups[rollupId].rollupContract) revert NotRollupContract();
        if (_insideExecution()) revert SetStateRootNotAllowedDuringExecution();
        if (verificationByRollup[rollupId].lastVerifiedBlock == block.number) {
            revert RollupBatchActiveThisBlock(rollupId);
        }
        rollups[rollupId].stateRoot = newStateRoot;
        emit StateUpdated(rollupId, newStateRoot);
    }

    // ──────────────────────────────────────────────
    //  Internal helpers
    // ──────────────────────────────────────────────

    /// @notice L1's own network is mainnet — `createCrossChainProxy` may not proxy an L1 address.
    function _getRollupId() internal pure override returns (uint256) {
        return MAINNET_ROLLUP_ID;
    }

    /// @notice Returns the position of `target` in a strictly-increasing `uint64[]`, or
    ///         `type(uint256).max` if not present. Strictly-increasing invariant is enforced
    ///         in `_validateStructure`, so binary search is safe.
    function _findIndexPosition(uint64[] calldata sortedIndices, uint256 target) internal pure returns (uint256) {
        uint256 lo = 0;
        uint256 hi = sortedIndices.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            uint256 v = uint256(sortedIndices[mid]);
            if (v == target) return mid;
            if (v < target) lo = mid + 1;
            else hi = mid;
        }
        return type(uint256).max;
    }

    /// @notice Binary-search membership check on the batch's `rollupIdsWithProofSystems[]`,
    ///         which is sorted strictly ascending by `.rollupId`.
    /// @dev Binary (vs `_contains`'s linear): a whole batch can carry many rollups, and this list is
    ///      kept sorted, so the log(n) lookup is worth it. Per-entry / per-lookup sets are small, so
    ///      they use a linear scan instead — see `_contains`.
    function _containsRollupInBatch(ProofSystemBatchPerVerificationEntries calldata batch, uint256 rollupId)
        internal
        pure
        returns (bool)
    {
        uint256 lo = 0;
        uint256 hi = batch.rollupIdsWithProofSystems.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            uint256 v = batch.rollupIdsWithProofSystems[mid].rollupId;
            if (v == rollupId) return true;
            if (v < rollupId) lo = mid + 1;
            else hi = mid;
        }
        return false;
    }

    // ──────────────────────────────────────────────
    //  Proxy-protection verified-rollup checks (postAndVerifyBatch)
    // ──────────────────────────────────────────────
    //
    // A cross-chain call only touches a rollup the host actually proved. The host's verified set is
    // its `stateDeltas` (entry) or its `expectedStateRoots` pins (top-level lookup). MAINNET (L1) is never
    // in a verified set — L1 is not its own cross-chain counterparty (mirrors the same-network proxy
    // ban). Enforced statically here so every proxy a consumed entry drives is backed by a verified
    // rollup. Reentrant calls and every lookup additionally re-check the clear-text destination id
    // against the live calling-proxy rollup at execution.

    /// @notice Every L2→L1 call's `sourceRollupId` and every reentrant L1→L2 call's
    ///         `destinationRollupId` must be in `verifiedRollups`. Each reentrant entry's own
    ///         sub-calls (static / reverted `l2ToL1Calls`) are validated in the same pass — the
    ///         unified `expectedL1ToL2Calls` flat table holds every deeper-context reentrant call,
    ///         so no recursion is needed.
    function _validateCallsContainVerifiedRollups(
        L2ToL1Call[] calldata calls,
        ExpectedL1ToL2Call[] calldata reentrant,
        uint256[] memory verifiedRollups
    )
        internal
        pure
    {
        for (uint256 i = 0; i < calls.length; i++) {
            if (!_contains(verifiedRollups, calls[i].sourceRollupId)) {
                revert CallSourceNotVerified(calls[i].sourceRollupId);
            }
        }
        for (uint256 i = 0; i < reentrant.length; i++) {
            if (!_contains(verifiedRollups, reentrant[i].destinationRollupId)) {
                revert ReentrantDestinationNotVerified(reentrant[i].destinationRollupId);
            }
            // Sub-calls carried by a static / reverted reentrant entry source from the host's
            // verified set too (empty for a plain-success entry).
            L2ToL1Call[] calldata subCalls = reentrant[i].l2ToL1Calls;
            for (uint256 j = 0; j < subCalls.length; j++) {
                if (!_contains(verifiedRollups, subCalls[j].sourceRollupId)) {
                    revert CallSourceNotVerified(subCalls[j].sourceRollupId);
                }
            }
        }
    }

    /// @notice True if `rollupId` appears in `ids`. Strict membership — no MAINNET exemption.
    /// @dev Linear scan (vs `_containsRollupInBatch`'s binary search): `ids` here is a single entry's
    ///      `stateDeltas` rollups or one lookup's `expectedStateRoots` pins — usually only a handful, and the
    ///      lookup set isn't sorted — so a linear scan is the simpler, general fit. A whole batch can
    ///      hold many rollups, which is why the batch-wide check is sorted + binary instead.
    function _contains(uint256[] memory ids, uint256 rollupId) internal pure returns (bool) {
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == rollupId) return true;
        }
        return false;
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice Last block at which `_rollupId` was verified by a postAndVerifyBatch call
    function lastVerifiedBlock(uint256 _rollupId) external view returns (uint256) {
        return verificationByRollup[_rollupId].lastVerifiedBlock;
    }

    /// @notice Length of the deferred queue for `_rollupId` (only meaningful in the current
    ///         block; stale entries from prior blocks are treated as empty by readers)
    function queueLength(uint256 _rollupId) external view returns (uint256) {
        return verificationByRollup[_rollupId].executionQueue.length;
    }

    /// @notice Cursor (next-to-consume) for the deferred queue of `_rollupId`
    function executionQueueIndex(uint256 _rollupId) external view returns (uint256) {
        return verificationByRollup[_rollupId].executionQueueIndex;
    }
}
