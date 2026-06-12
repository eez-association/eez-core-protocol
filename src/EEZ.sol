// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IProofSystem} from "./interfaces/IProofSystem.sol";
import {IRollupContract} from "./interfaces/IRollup.sol";
import {CrossChainProxy} from "./base/CrossChainProxy.sol";
import {
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    LookupCall,
    ExecutionEntry,
    ExpectedLookup,
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
    LookupCall[] public _transientLookupCalls;

    /// @notice Cursor into `_transientExecutions` for the next entry to consume.
    /// @dev Only meaningful while `_transientExecutions.length != 0`. The table's length
    ///      itself is what flags "inside a transient batch" for `_getCurrentEntryStoragePointer()`
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
    /// @dev `0` outside execution. Used by `_getCurrentEntryStoragePointer()` to disambiguate which
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

    /// @notice All ether received via `executeCrossChainCall` during the current entry —
    ///         the top-level call's `msg.value` plus every reentrant call's.
    /// @dev Single accounting side of the ether-delta invariant (`Σ etherDelta == _entryEtherIn
    ///      - etherOut`). Defensive discipline at the top level: `executeCrossChainCall` SETS
    ///      it to msg.value; `executeL2TX` and `attemptApplyImmediate` revert
    ///      `ResidualEntryEtherIn` unless it is already 0 (no value path reaches them) —
    ///      residue can never leak across entries — while reentrant calls ADD. Cleared again
    ///      at the end of `_applyAndExecute`. Receipts inside a revertSpan or a reverted
    ///      lookup's sub-execution roll back with that frame's revert, matching the physical ETH.
    uint256 transient _entryEtherIn;

    /// @notice Rollup whose persistent `lookupQueue` holds the TOP-LEVEL LookupCall being
    ///         executed (pairs with the base's `_topLevelLookupIndex`).
    /// @dev Unused while the match came from the transient table. L1-only — L2 has a single
    ///      lookup table and needs no rollup routing.
    uint256 transient _revertedLookupRollupId;

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
    /// @dev Not emitted for calls inside a revertSpan (those events are rolled back by the revert).
    event CallResult(uint256 indexed entryIndex, uint256 indexed l2ToL1CallNumber, bool success, bytes returnData);

    /// @notice Emitted when a reentrant L1→L2 call is consumed during reentrant execution
    event L1ToL2CallConsumed(
        uint256 indexed entryIndex, uint256 indexed l1ToL2CallNumber, bytes32 crossChainCallHash, uint256 callCount
    );

    /// @notice Emitted after an entry's execution completes and all verifications pass
    event EntryExecuted(
        uint256 indexed entryIndex, bytes32 rollingHash, uint256 l2ToL1CallsProcessed, uint256 l1ToL2CallsConsumed
    );

    /// @notice Emitted after a revert span is processed via `executeInContextAndRevert`
    event RevertSpanExecuted(uint256 indexed entryIndex, uint256 startL2ToL1Call, uint256 span);

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

    /// @notice A no-value top-level entry point found a nonzero `_entryEtherIn` — should be
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

    /// @notice Error when `transientLookupCallCount` exceeds the lookup call count
    error TransientLookupCallCountExceedsLookupCalls();

    /// @notice Error when transient lookup calls come without transient entries (unreachable —
    ///         no entries means no immediate drain and no meta hook, so nothing can consume them)
    error TransientLookupCallsWithoutTransientEntries();

    /// @notice Error when batch validation fails for malformed inputs
    error InvalidProofSystemConfig();

    /// @notice Error when duplicate / unsorted proof systems are submitted in the batch
    error DuplicateProofSystem(address proofSystem);

    /// @notice Error when an entry's destinationRollupId, a state delta's rollupId, or a
    ///         lookup call's destinationRollupId references a rollup not in the batch
    error RollupNotInBatch(uint256 rollupId);

    /// @notice Error when not all L2→L1 calls (`entry.l2ToL1Calls`) were consumed after execution
    error UnconsumedL2ToL1Calls();

    /// @notice Error when not all reentrant L1→L2 calls (`entry.expectedL1ToL2Calls`) were
    ///         consumed after execution
    error UnconsumedL1ToL2Calls();

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
    ///         ALL must verify before any state mutation — atomicity is what makes
    ///         `crossProofSystemInteractions` load-bearing across PSes. These external calls
    ///         are `view` (STATICCALL), so no reentrancy concern.
    ///      3. Mark every touched rollup as verified-this-block. Sets the once-per-block-per-rollup
    ///         invariant AND the read gate for `executeCrossChainCall` / `executeL2TX` (which
    ///         require `lastVerifiedBlock(rid) == block.number`). Done before the meta hook
    ///         (non-view CALL) so the hook + later proxy calls can read from the queues.
    ///      4. Build the transient stream from `entries[0..transientExecutionEntryCount)`
    ///         (and `l1ToL2lookupCalls[0..transientLookupCallCount)`). The stream lives in
    ///         `_transientExecutions` / `_transientLookupCalls` and is consumed via a single
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
        // same `_transientExecutions` / `_transientLookupCalls` storage and corrupt them.
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
        //    `_entryEtherIn` is 0 here — these entries aren't driven by an external value transfer.
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
        delete _transientLookupCalls;
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
        if (_entryEtherIn != 0) revert ResidualEntryEtherIn(); // immediate entries receive no inbound value
        _applyAndExecute(entry.stateDeltas, entry.callCount, entry.rollingHash);
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

        // Every entry's destinationRollupId AND every state delta's rollupId must belong to
        // the batch. The destination check is what prevents an adversarial prover from
        // routing an entry into a non-participating rollup's queue during `_publishRemainderExecutions`.
        // Same constraint for lookup calls.
        for (uint256 i = 0; i < batch.entries.length; i++) {
            ExecutionEntry calldata entry = batch.entries[i];
            if (!_containsRollupInBatch(batch, entry.destinationRollupId)) {
                revert RollupNotInBatch(entry.destinationRollupId);
            }
            StateDelta[] calldata deltas = entry.stateDeltas;
            for (uint256 j = 0; j < deltas.length; j++) {
                if (!_containsRollupInBatch(batch, deltas[j].rollupId)) {
                    revert RollupNotInBatch(deltas[j].rollupId);
                }
            }
        }
        for (uint256 i = 0; i < batch.l1ToL2lookupCalls.length; i++) {
            if (!_containsRollupInBatch(batch, batch.l1ToL2lookupCalls[i].destinationRollupId)) {
                revert RollupNotInBatch(batch.l1ToL2lookupCalls[i].destinationRollupId);
            }
        }

        // Transient prefix bounds.
        if (batch.transientExecutionEntryCount > batch.entries.length) revert TransientCountExceedsEntries();
        if (batch.transientLookupCallCount > batch.l1ToL2lookupCalls.length) {
            revert TransientLookupCallCountExceedsLookupCalls();
        }
        // Transient lookups are only reachable while transient entries are mid-flight
        // (`_activeLookupCalls` keys off `_transientExecutions`) — reject the dead-weight shape.
        if (batch.transientExecutionEntryCount == 0 && batch.transientLookupCallCount != 0) {
            revert TransientLookupCallsWithoutTransientEntries();
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
    ///        sharedPublicInput = H(entryHashes, lookupCallHashes, blobHashes, H(callData),
    ///                              crossProofSystemInteractions)
    ///      For each PS k we walk the rollupIdsWithProofSystems table in canonical order;
    ///      every rollup that lists k in its `proofSystemIndex[]` folds into a per-PS
    ///      rolling accumulator one rollup at a time:
    ///        acc_k = bytes32(0)
    ///        for each rollup r with k ∈ proofSystemIndex[r]:
    ///          acc_k = H(acc_k, rollupId_r, vkMatrix[r][j], blockHash_r, timestamp_r)
    ///      Then `publicInputsHash[k] = H(sharedPublicInput, acc_k)`. (blockHash, timestamp)
    ///      are fetched ONCE per rollup via `getTimestampAndBlockHash` ahead of the per-PS
    ///      loop, intentionally OUTSIDE sharedPublicInput so they can be rollup-specific.
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
        // destinationRollupId, l2ToL1Calls[], expectedL1ToL2Calls[], expectedLookups[],
        // callCount, returnData, rollingHash. Prevents an orchestrator from swapping
        // call/reentrant-call/returnData at execution time without invalidating the proof.
        bytes32[] memory entryHashes = new bytes32[](batch.entries.length);
        for (uint256 i = 0; i < batch.entries.length; i++) {
            entryHashes[i] = keccak256(abi.encode(batch.entries[i]));
        }

        // Per-lookup-call hash, same rationale.
        bytes32[] memory lookupCallHashes = new bytes32[](batch.l1ToL2lookupCalls.length);
        for (uint256 i = 0; i < batch.l1ToL2lookupCalls.length; i++) {
            lookupCallHashes[i] = keccak256(abi.encode(batch.l1ToL2lookupCalls[i]));
        }

        bytes32 sharedPublicInput = keccak256(
            abi.encodePacked(
                abi.encode(entryHashes),
                abi.encode(lookupCallHashes),
                abi.encode(blobHashes),
                keccak256(batch.callData),
                batch.crossProofSystemInteractions
            )
        );

        // Fetch (timestamp, blockHash) for every rollup ONCE — reused across all PS loops
        // below. Both reads are `view` (STATICCALL) so a malicious manager cannot reenter.
        uint256 rollupCount = batch.rollupIdsWithProofSystems.length;
        uint256[] memory timestamps = new uint256[](rollupCount);
        bytes32[] memory blockHashes = new bytes32[](rollupCount);
        for (uint256 r = 0; r < rollupCount; r++) {
            (timestamps[r], blockHashes[r]) = IRollupContract(
                    rollups[batch.rollupIdsWithProofSystems[r].rollupId].rollupContract
                ).getTimestampAndBlockHash(batch.blockNumber);
        }

        // Per-PS verification — for each PS k, walk attesting rollups in canonical order
        // (rollupId-ascending, the order the batch enforces) and fold each rollup's
        // (rollupId, vkey_for_PS_k, blockHash, timestamp) into a rolling accumulator. Off-
        // chain provers MUST mirror this incremental scheme so the on-chain rebuild matches.
        for (uint256 k = 0; k < batch.proofSystems.length; k++) {
            bytes32 acc = bytes32(0);
            for (uint256 r = 0; r < rollupCount; r++) {
                RollupIdWithProofSystems calldata rps = batch.rollupIdsWithProofSystems[r];
                uint256 j = _findIndexPosition(rps.proofSystemIndex, k);
                if (j == type(uint256).max) continue;
                acc = keccak256(abi.encode(acc, rps.rollupId, vkMatrix[r][j], blockHashes[r], timestamps[r]));
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
        delete rec.lookupQueue;
        rec.executionQueueIndex = 0;
    }

    /// @notice Builds the transient stream from the batch's leading prefix
    /// @dev The bounds are validated in `_validateStructure` so we don't re-check here.
    function _loadTransientExecutions(ProofSystemBatchPerVerificationEntries calldata batch) internal {
        for (uint256 i = 0; i < batch.transientExecutionEntryCount; i++) {
            _transientExecutions.push(batch.entries[i]);
        }
        for (uint256 i = 0; i < batch.transientLookupCallCount; i++) {
            _transientLookupCalls.push(batch.l1ToL2lookupCalls[i]);
        }
    }

    /// @notice Publishes the batch remainder (entries past `transientExecutionEntryCount`)
    ///         into per-rollup queues keyed by `destinationRollupId`
    function _publishRemainderExecutions(ProofSystemBatchPerVerificationEntries calldata batch) internal {
        for (uint256 i = batch.transientExecutionEntryCount; i < batch.entries.length; i++) {
            uint256 destRid = batch.entries[i].destinationRollupId;
            verificationByRollup[destRid].executionQueue.push(batch.entries[i]);
        }
        for (uint256 i = batch.transientLookupCallCount; i < batch.l1ToL2lookupCalls.length; i++) {
            uint256 destRid = batch.l1ToL2lookupCalls[i].destinationRollupId;
            // A top-level lookup is queued under its own `destinationRollupId` — coherent by
            // construction: the consumption scan targets the proxy's `originalRollupId`, which
            // is also the target rollup bound into `crossChainCallHash`. For a `failed` lookup
            // the field is additionally load-bearing — `_executeRevertedTopLevelLookup` stores it in
            // `_revertedLookupRollupId` so `_currentTopLevelLookup` can re-derive the queue mid-execution.
            verificationByRollup[destRid].lookupQueue.push(batch.l1ToL2lookupCalls[i]);
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
            // Reentrant — ADD this call's value to the entry's inbound-ether accumulator
            _entryEtherIn += msg.value;
            return _consumeNestedAction(crossChainCallHash);
        }

        // Top-level — SET (not add): a fresh entry starts from exactly its own msg.value,
        // so residue can never leak across entries.
        _entryEtherIn = msg.value;
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
        if (_entryEtherIn != 0) revert ResidualEntryEtherIn();

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
    function _getCurrentEntryStoragePointer() internal view returns (ExecutionEntry storage entry) {
        if (_transientExecutions.length != 0) {
            entry = _transientExecutions[_currentEntryIndex];
        } else {
            entry = verificationByRollup[_currentEntryRollupId].executionQueue[_currentEntryIndex];
        }
    }

    /// @notice The TOP-LEVEL LookupCall currently being executed, reconstructed from the
    ///         transient pointers. Only valid while `_revertedLookupTopLevel`.
    function _currentTopLevelLookup() internal view returns (LookupCall storage) {
        return _activeLookupCalls(_revertedLookupRollupId)[_topLevelLookupIndex];
    }

    /// @notice Consumes the next ExpectedL1ToL2Call entry, or runs a pre-computed
    ///         reverting lookup call when no entry matches.
    /// @dev Routing rules:
    ///      1. ExpectedL1ToL2Call at `_lastL1ToL2CallConsumed` matches `crossChainCallHash`
    ///         → advance the cursor by 1, hash NESTED_BEGIN/END, return cached returnData.
    ///         This is the only path that advances the cursor.
    ///      2. Otherwise scan the active host's nested-lookup table (`_getActiveLookups()` — the
    ///         entry's `expectedLookups`, or the top-level lookup's own table while one is
    ///         executing) for a `failed=true` `ExpectedLookup` keyed by
    ///         (crossChainCallHash, _currentL2ToL1Call, idx, executingLookupIndex) where `idx`
    ///         is the current cursor value → execute it and revert with the pre-computed
    ///         returnData. Entry-scoped — no queue routing.
    ///      3. No match → set the deferred-revert flag `_l1ToL2CallNotFound` and return
    ///         empty bytes. The end-of-entry check in `_applyAndExecute` reverts
    ///         `ExecutionNotFound`. The cursor stays at `idx` so further reentrant calls in
    ///         the same entry observe the same key the prover saw.
    ///
    ///      Why fall back only on `failed=true`: a successful reentrant call in a normal CALL
    ///      frame is expressed as an ExpectedL1ToL2Call entry; a successful read-only call
    ///      is in a STATICCALL frame and routed to `staticCallLookup` instead. A lookup-call
    ///      hit on this path only makes sense when the caller has try/catch and expects a
    ///      revert.
    function _consumeNestedAction(bytes32 crossChainCallHash) internal returns (bytes memory) {
        // Active nested table: the containing entry's, or — while executing a reverted lookup —
        // that lookup's own `expectedL1ToL2Calls`.
        ExpectedL1ToL2Call[] storage expectedCalls = _activeNested();
        uint256 idx = _lastL1ToL2CallConsumed; // pre-commit read; advance only on match

        // 1. ExpectedL1ToL2Call priority — the ONLY path that advances the cursor.
        if (idx < expectedCalls.length && expectedCalls[idx].crossChainCallHash == crossChainCallHash) {
            ExpectedL1ToL2Call storage nested = expectedCalls[idx];
            _lastL1ToL2CallConsumed = idx + 1;
            uint256 nestedNumber = idx + 1;
            emit L1ToL2CallConsumed(_currentEntryIndex, nestedNumber, crossChainCallHash, nested.callCount);
            _rollingHashNestedBegin(nestedNumber);
            _processNCalls(nested.callCount);
            _rollingHashNestedEnd(nestedNumber);
            return nested.returnData;
        }

        // 2. Fallback to a reverted nested lookup (key = pre-bump cursor) in the active host's
        //    `expectedLookups` table — entry-scoped, no queue routing. A match is resolved by
        //    `_executeRevertedNestedLookup`, which always reverts (a plain reverted lookup is just its
        //    `callCount == 0` case).
        uint64 callNum = uint64(_currentL2ToL1Call);
        uint64 lastNA = uint64(idx);
        uint64 execIdx = _activeLookupContext();
        ExpectedLookup[] storage lookups = _getActiveLookups();
        for (uint256 i = 0; i < lookups.length; i++) {
            ExpectedLookup storage el = lookups[i];
            if (
                el.failed && el.crossChainCallHash == crossChainCallHash && el.l2ToL1CallNumber == callNum
                    && el.lastL1ToL2CallConsumed == lastNA && el.executingLookupIndex == execIdx
            ) {
                _executeRevertedNestedLookup(i); // always reverts
            }
        }

        // 3. No match anywhere — defer the revert. Set flag, return empty bytes; the
        //    end-of-entry check in `_applyAndExecute` reverts `ExecutionNotFound`.
        //    NOTE: returning empty bytes may still revert this call sooner than the
        //    end-of-entry check — the proxy `.call` will return `(success=true, "")`, but
        //    the calling contract typically ABI-decodes the return value into a typed
        //    result. If it expects a non-empty payload (e.g. `abi.decode(retData, (uint256))`)
        //    the decode itself reverts the calling frame, which in turn propagates up. The
        //    deferred-revert flag only guarantees the *entry* eventually reverts; it does
        //    NOT guarantee execution reaches the end-of-entry check intact.
        // Emit so off-chain can locate the no-match site — the eventual revert points at the entry boundary.
        emit L1ToL2CallNotFound(_currentEntryIndex, crossChainCallHash, _currentL2ToL1Call, idx);
        _l1ToL2CallNotFound = true;
        return "";
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
    ///      Miss path: when the cursor is out of bounds or the next entry's `proxyEntryHash` doesn't match,
    ///      `_tryRevertedTopLevelLookup` scans the transient + persistent lookup tables for a
    ///      `failed=true` `LookupCall` matching `crossChainCallHash` with live state-root pins.
    ///      On match, that helper reverts with the cached `returnData` (so the caller's `try/catch` observes
    ///      the prover-specified revert). On no match the helper returns and we revert `ExecutionNotFound`.
    ///      The cursor is NOT advanced on the miss path — a failed top-level call consumes a `LookupCall`,
    ///      not an `ExecutionEntry`, so the next consumer still sees the same next entry.
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
                // Try reverted-lookup fallback (always reverts on match); otherwise ExecutionNotFound
                _tryRevertedTopLevelLookup(crossChainCallHash, destRid);
                revert ExecutionNotFound();
            }
            _transientExecutionIndex = idx + 1;
            entry = _transientExecutions[idx];
            _currentEntryRollupId = 0; // marker: transient phase (storage routes via length)
        } else {
            RollupVerification storage rec = verificationByRollup[destRid];
            idx = rec.executionQueueIndex;
            if (idx >= rec.executionQueue.length || rec.executionQueue[idx].proxyEntryHash != crossChainCallHash) {
                // Try reverted-lookup fallback (always reverts on match); otherwise ExecutionNotFound
                _tryRevertedTopLevelLookup(crossChainCallHash, destRid);
                revert ExecutionNotFound();
            }
            rec.executionQueueIndex = idx + 1;
            entry = rec.executionQueue[idx];
            _currentEntryRollupId = destRid;
        }

        emit ExecutionConsumed(crossChainCallHash, destRid, idx);

        _currentEntryIndex = idx;
        _applyAndExecute(entry.stateDeltas, entry.callCount, entry.rollingHash);

        return entry.returnData;
    }

    /// @notice Applies state deltas (with currentState validation), processes calls,
    ///         verifies rolling hash, checks ether accounting, then resets _currentL2ToL1Call
    /// @dev `_entryEtherIn` already holds the entry-point call's `msg.value` when we get here
    ///      (SET by the top-level entry point before consumption), so it is NOT reset in
    ///      this preamble — only at the end, after the invariant check.
    function _applyAndExecute(StateDelta[] memory deltas, uint256 callCount, bytes32 rollingHash) internal {
        _rollingHash = bytes32(0);
        _currentL2ToL1Call = 0;
        _lastL1ToL2CallConsumed = 0;

        int256 etherOut = _processNCalls(callCount);
        int256 totalEtherDelta = _applyStateDeltas(deltas);

        ExecutionEntry storage entry = _getCurrentEntryStoragePointer();
        // Check the deferred no-match flag from `_consumeNestedAction` first so the failure
        // surfaces as `ExecutionNotFound` rather than the downstream `RollingHashMismatch` it
        // would otherwise cause (returning empty bytes diverges the entry's rolling hash).
        if (_l1ToL2CallNotFound) revert ExecutionNotFound();
        if (_rollingHash != rollingHash) revert RollingHashMismatch();
        if (_currentL2ToL1Call != entry.l2ToL1Calls.length) revert UnconsumedL2ToL1Calls();
        if (_lastL1ToL2CallConsumed != entry.expectedL1ToL2Calls.length) revert UnconsumedL1ToL2Calls();
        if (totalEtherDelta != int256(_entryEtherIn) - etherOut) revert EtherDeltaMismatch();

        emit EntryExecuted(_currentEntryIndex, _rollingHash, _currentL2ToL1Call, _lastL1ToL2CallConsumed);
        _currentL2ToL1Call = 0; // resets _insideExecution()
        _entryEtherIn = 0; // reset for the next top-level entry in this tx
    }

    /// @notice Processes N calls from the flat entry.l2ToL1Calls[] array
    /// @param count Number of iterations to process
    /// @return etherOut Total ETH sent in successful (non-reverted) calls. Local var (not
    ///         transient) so revertSpan rollbacks don't affect the outer accumulator — the
    ///         inner `_processNCalls` invocation through `executeInContextAndRevert` keeps its own
    ///         local that is discarded with the revert frame, which is exactly what we want.
    function _processNCalls(uint256 count) internal returns (int256 etherOut) {
        // Active flat-call array: the entry's, or the reverted lookup's while one is executing.
        L2ToL1Call[] storage calls = _activeCalls();
        uint256 processed = 0;
        while (processed < count) {
            uint256 revertSpan = calls[_currentL2ToL1Call].revertSpan;

            if (revertSpan == 0) {
                L2ToL1Call memory cc = calls[_currentL2ToL1Call];
                _currentL2ToL1Call++;

                _rollingHashCallBegin(_currentL2ToL1Call);

                address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
                if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
                    _createCrossChainProxyInternal(cc.sourceAddress, cc.sourceRollupId);
                }

                (bool success, bytes memory retData) = sourceProxy.call{
                    value: cc.value
                }(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)));

                if (cc.value > 0 && success) {
                    etherOut += int256(cc.value);
                }

                _rollingHashCallEnd(_currentL2ToL1Call, success, retData);
                emit CallResult(_currentEntryIndex, _currentL2ToL1Call, success, retData);
                processed++;
            } else {
                uint256 savedCallNumber = _currentL2ToL1Call;
                calls[_currentL2ToL1Call].revertSpan = 0;

                try this.executeInContextAndRevert(revertSpan) {}
                catch (bytes memory revertData) {
                    // Direct assign is still an OR-merge: the inner frame inherits the outer
                    // flag and never clears it, so a span no-match survives the forced revert.
                    (_rollingHash, _lastL1ToL2CallConsumed, _currentL2ToL1Call, _l1ToL2CallNotFound) =
                        _decodeContextResult(revertData);
                }

                // unnecesary, since it's not read again, it lets the storage as it was
                calls[savedCallNumber].revertSpan = revertSpan;
                emit RevertSpanExecuted(_currentEntryIndex, savedCallNumber, revertSpan);
                processed += revertSpan;
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
    function _stateRootsMatch(LookupCall storage sc) internal view returns (bool) {
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
    // `_processNCalls` and `_consumeNestedAction` operate on whichever flat-call / reentrant /
    // nested-lookup tables are active. Three contexts:
    //   - normal entry execution → the entry's tables;
    //   - top-level reverted lookup executing (`_revertedLookupTopLevel`) → the pool lookup's tables;
    //   - nested reverted lookup executing (`_insideRevertedLookup`) → the `ExpectedLookup` at
    //     `_revertedLookupIndex` within the active host table (`_getActiveLookups()`).

    /// @notice The flat L2→L1 call array driving the current execution.
    function _activeCalls() internal view returns (L2ToL1Call[] storage) {
        if (_insideRevertedLookup) return _getActiveLookups()[_revertedLookupIndex].l2ToL1Calls;
        if (_revertedLookupTopLevel) return _currentTopLevelLookup().l2ToL1Calls;
        return _getCurrentEntryStoragePointer().l2ToL1Calls;
    }

    /// @notice The reentrant (L1→L2) table for the current execution.
    function _activeNested() internal view returns (ExpectedL1ToL2Call[] storage) {
        if (_insideRevertedLookup) return _getActiveLookups()[_revertedLookupIndex].expectedL1ToL2Calls;
        if (_revertedLookupTopLevel) return _currentTopLevelLookup().expectedL1ToL2Calls;
        return _getCurrentEntryStoragePointer().expectedL1ToL2Calls;
    }

    /// @notice The nested-lookup table of the active HOST — the entry's `expectedLookups`, or
    ///         the top-level lookup's own table while one is being executed. Deeper reverted-lookup executions
    ///         within a host resolve from this same flat table.
    function _getActiveLookups() internal view returns (ExpectedLookup[] storage) {
        return _revertedLookupTopLevel
            ? _currentTopLevelLookup().expectedLookups
            : _getCurrentEntryStoragePointer().expectedLookups;
    }

    // ──────────────────────────────────────────────
    //  Lookup-call resolution
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
        if (_processNLookupCalls(calls) != rollingHash) revert RollingHashMismatch();
        if (failed) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return returnData;
    }

    /// @notice Runs a reverted NESTED lookup (`_getActiveLookups()[index]`) as a self-contained
    ///         mini-entry, then reverts with its cached `returnData`.
    function _executeRevertedNestedLookup(uint256 index) internal {
        ExpectedLookup storage el = _getActiveLookups()[index];

        // Pointer for deeper frames (`_activeCalls()` / `_activeNested()`); storage refs
        // can't be transient.
        _revertedLookupIndex = index;
        _insideRevertedLookup = true;

        _executeRevertedLookup(
            el.callCount, el.rollingHash, el.l2ToL1Calls.length, el.expectedL1ToL2Calls.length, el.returnData
        );
    }

    /// @notice Runs a reverted TOP-LEVEL `LookupCall` as a self-contained mini-entry, then
    ///         reverts with its cached `returnData`. The pool lookup becomes the active HOST:
    ///         its tables drive the sub-execution, including its own `expectedLookups` for nested
    ///         lookups observed inside it.
    function _executeRevertedTopLevelLookup(LookupCall storage sc, uint256 index) internal {
        // Host pointers for deeper frames; the pool is re-derived in `_currentTopLevelLookup`.
        _topLevelLookupIndex = index;
        _revertedLookupRollupId = sc.destinationRollupId;
        _revertedLookupTopLevel = true;

        _executeRevertedLookup(
            sc.callCount, sc.rollingHash, sc.l2ToL1Calls.length, sc.expectedL1ToL2Calls.length, sc.returnData
        );
    }

    /// @notice Shared execution tail for reverted lookups: fresh sub-execution context, run the
    ///         sub-calls, entry-style end checks, then the terminal revert with the cached
    ///         `returnData`. Runs INLINE in the consuming `executeCrossChainCall` frame; the
    ///         revert discards the sub-call state AND restores the outer cursors (the EVM
    ///         rolls back every tstore here), so the pre-revert checks need no `ContextResult`
    ///         escape. Deeper reverted-lookup executions compose via the same unwind.
    function _executeRevertedLookup(
        uint256 callCount,
        bytes32 rollingHash,
        uint256 callsLength,
        uint256 reentrantLength,
        bytes memory returnData
    )
        internal
    {
        // Fresh sub-execution context. The flag reset shields this sub-execution from an
        // earlier no-match in the outer entry; the terminal revert restores the outer value.
        _l1ToL2CallNotFound = false;
        _rollingHash = bytes32(0);
        _currentL2ToL1Call = 0;
        _lastL1ToL2CallConsumed = 0;

        _processNCalls(callCount);

        // Deferred no-match flag first, same order as `_applyAndExecute` — a cross-chain call
        // unaccounted for by the tables must fail even when the prover pre-hashed its "" result.
        if (_l1ToL2CallNotFound) revert ExecutionNotFound();
        if (_rollingHash != rollingHash) revert RollingHashMismatch();
        if (_currentL2ToL1Call != callsLength) revert UnconsumedL2ToL1Calls();
        if (_lastL1ToL2CallConsumed != reentrantLength) revert UnconsumedL1ToL2Calls();

        assembly {
            revert(add(returnData, 0x20), mload(returnData))
        }
    }

    /// @notice Executes the lookup call's optional `calls[]` in static context and computes a
    ///         rolling hash of the results (untagged static schema). No `revertSpan` handling.
    /// @dev All proxies referenced must already be deployed; CREATE2 is unavailable inside a
    ///      STATICCALL frame. The accumulator is a local, not `_rollingHash`, so this is verified
    ///      against `LookupCall.rollingHash`. See `docs/CORE_PROTOCOL_SPEC.md` §E.2.
    function _processNLookupCalls(L2ToL1Call[] memory calls) internal view returns (bytes32 computedHash) {
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
    //  Lookup call lookup
    // ──────────────────────────────────────────────

    /// @notice Looks up a pre-computed lookup result.
    /// @dev Inside an execution: scans the active host's entry-scoped `expectedLookups` by
    ///      `(crossChainCallHash, l2ToL1CallNumber, lastL1ToL2CallConsumed, executingLookupIndex)`.
    ///      Outside: while a batch is mid-flight, ONLY its transient pool (the transient phase
    ///      is self-contained — see docs/CAVEATS.md); otherwise the routed rollup's persistent
    ///      `lookupQueue`. Match: a top-level `LookupCall` with `crossChainCallHash` and every
    ///      state-root pin live (full scan — a non-matching candidate is skipped). tload works
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

        // Nested: entry-scoped table of the active host, keyed by the live cursors.
        if (_insideExecution()) {
            uint64 callNum = uint64(_currentL2ToL1Call);
            uint64 lastNA = uint64(_lastL1ToL2CallConsumed);
            uint64 execIdx = _activeLookupContext();
            ExpectedLookup[] storage lookups = _getActiveLookups();
            for (uint256 i = 0; i < lookups.length; i++) {
                ExpectedLookup storage el = lookups[i];
                if (
                    el.crossChainCallHash == crossChainCallHash && el.l2ToL1CallNumber == callNum
                        && el.lastL1ToL2CallConsumed == lastNA && el.executingLookupIndex == execIdx
                ) {
                    return _resolveStaticLookup(el.l2ToL1Calls, el.rollingHash, el.failed, el.returnData);
                }
            }
            revert ExecutionNotFound();
        }

        // Top-level: scan the single table in scope (see `_activeLookupCalls`).
        LookupCall[] storage lookupCalls = _activeLookupCalls(destRid);
        for (uint256 i = 0; i < lookupCalls.length; i++) {
            LookupCall storage sc = lookupCalls[i];
            if (sc.crossChainCallHash == crossChainCallHash && _stateRootsMatch(sc)) {
                return _resolveStaticLookup(sc.l2ToL1Calls, sc.rollingHash, sc.failed, sc.returnData);
            }
        }

        revert ExecutionNotFound();
    }

    /// @notice Top-level fallback: scan the transient pool while a batch is mid-flight
    ///         (transient phase is self-contained — see docs/CAVEATS.md), otherwise the routed
    ///         rollup's persistent `lookupQueue`, for a `failed` `LookupCall` matching
    ///         `crossChainCallHash` with every state-root pin live (full scan). Only reachable
    ///         outside an execution — nested lookups live on the entry. A match is resolved by
    ///         `_executeRevertedTopLevelLookup` (always reverts); no match returns so the
    ///         caller reverts `ExecutionNotFound`.
    function _tryRevertedTopLevelLookup(bytes32 crossChainCallHash, uint256 destRid) internal {
        LookupCall[] storage lookupCalls = _activeLookupCalls(destRid);
        for (uint256 i = 0; i < lookupCalls.length; i++) {
            LookupCall storage sc = lookupCalls[i];
            if (sc.failed && sc.crossChainCallHash == crossChainCallHash && _stateRootsMatch(sc)) {
                _executeRevertedTopLevelLookup(sc, i); // always reverts
            }
        }
    }

    /// @notice The top-level `LookupCall` table in scope: the batch's transient table while
    ///         one is mid-flight (the transient phase is self-contained — see docs/CAVEATS.md),
    ///         otherwise `destRid`'s persistent `lookupQueue`. Single source of the phase
    ///         rule — also what makes `_currentTopLevelLookup` sound: a persistent match
    ///         implies the transient tables are empty.
    function _activeLookupCalls(uint256 destRid) internal view returns (LookupCall[] storage) {
        return _transientExecutions.length != 0 ? _transientLookupCalls : verificationByRollup[destRid].lookupQueue;
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
