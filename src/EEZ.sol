// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IProofSystem} from "./interfaces/IProofSystem.sol";
import {IRollupContract} from "./interfaces/IRollup.sol";
import {CrossChainProxy} from "./base/CrossChainProxy.sol";
import {StateDelta, L2ToL1Call, ExpectedL1ToL2Call, LookupCall, ExecutionEntry, ProxyInfo} from "./interfaces/IEEZ.sol";
import {EEZBase} from "./base/EEZBase.sol";
import {IMetaCrossChainReceiver} from "./interfaces/IMetaCrossChainReceiver.sol";

/// @notice Rollup configuration held by the central registry.
/// @dev Owner, threshold, and per-PS vkeys live on the per-rollup `IRollupContract` contract pointed
///      to by `rollupContract`. The central registry holds only the *state* (state root,
///      ether balance) and reads vkeys through `IRollupContract.checkProofSystemsAndGetVkeys` — which
///      enforces the manager's threshold internally and reverts if not met. Threshold itself
///      is never read by the registry.
struct RollupConfig {
    address rollupContract;
    bytes32 stateRoot;
    uint256 etherBalance;
}

/// @notice One participating rollup in a `ProofSystemBatchPerVerificationEntries` together
///         with the SUBSET of the batch's global `proofSystems[]` that this rollup accepts.
/// @dev `proofSystemIndex[]` is a list of indices into the parent batch's `proofSystems[]`,
///      strictly increasing. The on-chain registry resolves them to PS addresses and hands
///      that subset to this rollup's manager via `IRollupContract.checkProofSystemsAndGetVkeys`. The
///      manager enforces its own threshold against `proofSystemIndex.length`.
struct RollupIdWithProofSystems {
    uint256 rollupId;
    uint64[] proofSystemIndex;
}

/// @notice One batch's payload — a group of proof systems jointly attesting to a set of
///         rollups' state transitions. Each rollup picks the subset of `proofSystems[]` it
///         accepts via `RollupIdWithProofSystems[r].proofSystemIndex`.
/// @dev The participating rollups (read off `RollupIdWithProofSystems[r].rollupId`) must be
///      strictly increasing — paired with the once-per-block-per-rollup invariant on
///      `_markVerifiedThisBlock`, this prevents a single batch from verifying the same
///      rollup twice. `proofSystems[]` is the batch-global PS list (strictly increasing,
///      rejects address(0) and duplicates). Each rollup's `proofSystemIndex[]` is strictly
///      increasing too, indices in `[0, proofSystems.length)`, and its length must satisfy
///      that rollup's threshold (enforced by `IRollupContract.checkProofSystemsAndGetVkeys`).
/// @dev `blobIndices` selects which of the tx-level EIP-4844 blobs this batch consumes;
///      `callData` is batch-scoped (each PS's circuit gets its own region).
/// @dev `transientExecutionEntryCount` and `transientLookupCallCount` are pure on-chain
///      dispatch parameters — not bound by the proof — so the orchestrator can tune the
///      transient/persistent split without re-proving.
struct ProofSystemBatchPerVerificationEntries {
    ExecutionEntry[] entries;
    LookupCall[] l1ToL2lookupCalls;
    uint256 transientExecutionEntryCount;
    uint256 transientLookupCallCount;
    address[] proofSystems;
    RollupIdWithProofSystems[] rollupIdsWithProofSystems;
    bytes32 crossProofSystemInteractions;
    uint256[] blobIndices;
    bytes callData;
    bytes[] proofs;
}

/// @notice Per-rollup deferred-consumption queue + once-per-block guard
/// @dev `lastVerifiedBlock` doubles as:
///        (a) the once-per-block-per-rollup invariant (a rollup can be verified at most once
///            per L1 block — required so multiple `postAndVerifyBatch` calls in the same block are
///            only allowed on disjoint rollup sets);
///        (b) read gate for consumers (entries can only be consumed in the block they were
///            posted — `executeCrossChainCall` / `executeL2TX` / `staticCallLookup` all gate
///            on `lastVerifiedBlock(rid) == block.number`);
///        (c) lockout signal for the registry's owner-escape path `EEZ.setStateRoot`,
///            which reverts `RollupBatchActiveThisBlock` when this equals `block.number`;
///        (d) the lazy-reset signal — when `lastVerifiedBlock < block.number` the queue is
///            considered empty, no explicit cleanup pass needed.
struct RollupVerification {
    uint256 lastVerifiedBlock;
    ExecutionEntry[] queue;
    LookupCall[] lookupQueue;
    uint256 cursor;
}

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
///      to `verificationByRollup[rid].queue[cursor]` and advance the per-rollup cursor.
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
    ///      itself is what flags "inside a transient batch" for `_currentEntryStorage()`
    ///      and `_consumeAndExecute`; this variable just tracks progress. Transient so it
    ///      resets between transactions automatically, and explicitly reset at the end
    ///      of every postAndVerifyBatch.
    uint256 transient _transientExecutionIndex;

    // No dedicated `_inPostBatch` flag — `_transientExecutions.length != 0` already
    // identifies the dangerous re-entry window (from `_loadTransient` through cleanup).
    // Steps 1-3 of `postAndVerifyBatch` (validate, verify-STATICCALL, mark-verified) have no
    // external calls, and step 7 (publish) has no external calls either, so neither
    // needs guarding.

    /// @notice The rollup ID whose queue is supplying the entry currently being processed.
    /// @dev `0` outside execution. Used by `_currentEntryStorage()` to disambiguate which
    ///      persistent queue to route into when `_transientExecutions.length == 0`.
    uint256 transient _currentEntryRollupId;

    /// @notice Deferred-revert flag for `_consumeNestedAction` no-match path.
    /// @dev When `_consumeNestedAction` finds no matching ExpectedL1ToL2Call, transient
    ///      failed-lookup, or persistent failed-lookup, it sets this flag and returns empty
    ///      bytes instead of reverting immediately. `_applyAndExecute` checks the flag at
    ///      end-of-entry and reverts `ExecutionNotFound` then. Transient — rolls back with
    ///      the surrounding frame on revert, so no manual reset needed.
    bool transient _nestedActionNotFound;

    /// @notice Emitted when a new rollup is created
    event RollupCreated(uint256 indexed rollupId, address indexed rollupContract, bytes32 initialState);

    /// @notice Emitted when a rollup state is updated (only via the registered rollupContract)
    event StateUpdated(uint256 indexed rollupId, bytes32 newStateRoot);

    /// @notice Emitted when an L2 execution is performed
    event L2ExecutionPerformed(uint256 indexed rollupId, bytes32 newState);

    /// @notice Emitted when an execution entry is consumed
    event ExecutionConsumed(bytes32 indexed crossChainCallHash, uint256 indexed rollupId, uint256 indexed cursor);

    /// @notice Emitted when a precomputed L2 transaction is executed
    event L2TXExecuted(uint256 indexed rollupId, uint256 indexed cursor);

    /// @notice Emitted when a batch is posted, carrying the number of rollups verified
    event BatchPosted(uint256 indexed rollupCount);

    /// @notice Emitted when an immediate entry's `_applyAndExecute` reverts during postAndVerifyBatch
    ///         step 4. The entry's state changes are rolled back; the cursor advances and the
    ///         loop continues with the next immediate entry. `revertData` carries the inner
    ///         revert payload (custom error or message) for off-chain debugging.
    event ImmediateEntrySkipped(uint256 indexed transientIdx, bytes revertData);

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

    /// @notice Error when batch validation fails for malformed inputs
    error InvalidProofSystemConfig();

    /// @notice Error when duplicate / unsorted proof systems are submitted in the batch
    error DuplicateProofSystem(address proofSystem);

    /// @notice Error when an entry's destinationRollupId, a state delta's rollupId, or a
    ///         lookup call's destinationRollupId references a rollup not in the batch
    error RollupNotInBatch(uint256 rollupId);

    // ──────────────────────────────────────────────
    //  Rollup creation
    // ──────────────────────────────────────────────

    /// @notice Registers a pre-deployed `IRollupContract`-conforming manager contract as a new rollup
    /// @dev The caller deploys the manager (e.g. our reference `Rollup.sol`, or a custom
    ///      multisig / governance contract) with the desired proof systems / threshold /
    ///      whatever ownership model it chooses baked in, then registers it here. Registry
    ///      assigns a fresh rollupId, stores the initial state root, and indexes the manager
    ///      for reverse-lookup. The registry makes no assumption about how the manager
    ///      handles ownership — that's entirely the manager's concern.
    /// @param rollupContract Address of the pre-deployed `IRollupContract` contract
    /// @param initialState Initial state root for this rollup
    /// @return rollupId Newly assigned rollup ID
    function registerRollup(address rollupContract, bytes32 initialState) external returns (uint256 rollupId) {
        if (rollupContract == address(0) || rollupContract == address(this)) revert InvalidRollupContract();

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
    ///        subsets, proofs, and transient prefix bounds
    function postAndVerifyBatch(ProofSystemBatchPerVerificationEntries calldata batch) external {
        // Reentrancy guard. Per-rollup `lastVerifiedBlock` blocks same-rollup re-entry, but a
        // disjoint-rollup nested call (e.g., from the meta hook) would otherwise share the
        // same `_transientExecutions` / `_transientLookupCalls` storage and corrupt them.
        // `_transientExecutions.length != 0` is true from `_loadTransient` through cleanup,
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
        //    these external calls before `_markVerifiedThisBlock`.
        bytes32[][] memory vkMatrix = _fetchVkMatrix(batch);
        _verifyProofSystemBatch(batch, vkMatrix);

        // 3. Mark all touched rollups as verified-this-block. Sets the once-per-block-per-rollup
        //    invariant AND the read gate for `executeCrossChainCall` / `executeL2TX` (which
        //    require `lastVerifiedBlock(rid) == block.number`). Done before the immediate-entry
        //    `_processNCalls` (which calls into proxies via non-view CALL — those CAN reenter,
        //    so the lastVerifiedBlock guard is what they hit).
        for (uint256 r = 0; r < batch.rollupIdsWithProofSystems.length; r++) {
            _markVerifiedThisBlock(batch.rollupIdsWithProofSystems[r].rollupId);
        }

        // 4. Build the transient stream from the leading prefix.
        _loadTransient(batch);

        // 5. Drain the leading run of transient entries with `proxyEntryHash == 0` inline.
        //    These are the "pure L2 transactions + L2 transactions that touch L1" entries —
        //    no source action to match, so the only way to consume them is here, before the
        //    meta hook starts driving non-zero-proxyEntryHash entries via proxy calls. Each runs
        //    its own `_applyAndExecute` cycle (rolling hash / cursors reset per entry).
        //    `etherIn = 0` because these entries aren't driven by an external value transfer.
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
        _publishRemainder(batch);

        emit BatchPosted(batch.rollupIdsWithProofSystems.length);
    }

    // ──────────────────────────────────────────────
    //  postAndVerifyBatch internals
    // ──────────────────────────────────────────────

    /// @notice Self-call wrapper that runs `_applyAndExecute` for one immediate entry
    ///         in an isolated frame. Used by `postAndVerifyBatch` step 4 to make immediate-entry
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
        _applyAndExecute(entry.stateDeltas, entry.callCount, entry.rollingHash, 0);
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
        // routing an entry into a non-participating rollup's queue during `_publishRemainder`.
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
        // destinationRollupId, L2ToL1Calls[], nestedActions[], callCount, returnData,
        // rollingHash. Prevents an orchestrator from swapping call/nestedAction/returnData
        // at execution time without invalidating the proof.
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
                ).getTimestampAndBlockHash();
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

    /// @notice Marks `rid` as verified this block. Multiple verifications per rollup per
    ///         block are allowed — subsequent calls in the same block append to the existing
    ///         queue without resetting the cursor, so already-published entries remain
    ///         consumable.
    /// @dev Lazy reset: only on the FIRST touch this block (i.e., `lastVerifiedBlock <
    ///      block.number`) do we wipe the queue and zero the cursor. On a same-block re-touch
    ///      we leave the queue / lookupQueue / cursor alone; `_publishRemainder` will push
    ///      additional entries onto the existing queue.
    function _markVerifiedThisBlock(uint256 rid) internal {
        RollupVerification storage rec = verificationByRollup[rid];
        if (rec.lastVerifiedBlock != block.number) {
            rec.lastVerifiedBlock = block.number;
            // First touch this block — clear stale persistent state from prior blocks.
            if (rec.queue.length != 0) delete rec.queue;
            if (rec.lookupQueue.length != 0) delete rec.lookupQueue;
            rec.cursor = 0;
        }
    }

    /// @notice Builds the transient stream from the batch's leading prefix
    /// @dev The bounds are validated in `_validateStructure` so we don't re-check here.
    function _loadTransient(ProofSystemBatchPerVerificationEntries calldata batch) internal {
        for (uint256 i = 0; i < batch.transientExecutionEntryCount; i++) {
            _transientExecutions.push(batch.entries[i]);
        }
        for (uint256 i = 0; i < batch.transientLookupCallCount; i++) {
            _transientLookupCalls.push(batch.l1ToL2lookupCalls[i]);
        }
    }

    /// @notice Publishes the batch remainder (entries past `transientExecutionEntryCount`)
    ///         into per-rollup queues keyed by `destinationRollupId`
    function _publishRemainder(ProofSystemBatchPerVerificationEntries calldata batch) internal {
        for (uint256 i = batch.transientExecutionEntryCount; i < batch.entries.length; i++) {
            uint256 destRid = batch.entries[i].destinationRollupId;
            verificationByRollup[destRid].queue.push(batch.entries[i]);
        }
        for (uint256 i = batch.transientLookupCallCount; i < batch.l1ToL2lookupCalls.length; i++) {
            uint256 destRid = batch.l1ToL2lookupCalls[i].destinationRollupId;
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
            // Reentrant — consume the next nested action
            return _consumeNestedAction(crossChainCallHash);
        }

        return _consumeAndExecute(destRid, crossChainCallHash, int256(msg.value));
    }

    // ──────────────────────────────────────────────
    //  Execute precomputed L2 transaction
    // ──────────────────────────────────────────────

    /// @notice Executes the next pure-L2 transaction queued for `rollupId`
    /// @dev The next entry in `verificationByRollup[rollupId].queue` must have crossChainCallHash == 0.
    ///      Cannot run while reentrantly inside another cross-chain execution.
    function executeL2TX(uint256 rollupId) external returns (bytes memory result) {
        if (verificationByRollup[rollupId].lastVerifiedBlock != block.number) {
            revert ExecutionNotInCurrentBlock(rollupId);
        }

        if (_insideExecution()) revert L2TXNotAllowedDuringExecution();

        emit L2TXExecuted(rollupId, verificationByRollup[rollupId].cursor);
        return _consumeAndExecute(rollupId, bytes32(0), 0);
    }

    // ──────────────────────────────────────────────
    //  Internal execution
    // ──────────────────────────────────────────────

    /// @notice Resolves the entry currently being processed.
    /// @dev While the transient table is non-empty, `_currentEntryIndex` indexes into it.
    ///      Otherwise we route into `verificationByRollup[_currentEntryRollupId].queue` —
    ///      the rollup whose queue supplied the entry being executed (set by
    ///      `_consumeAndExecute` before entering the inner flow).
    function _currentEntryStorage() internal view returns (ExecutionEntry storage entry) {
        if (_transientExecutions.length != 0) {
            entry = _transientExecutions[_currentEntryIndex];
        } else {
            entry = verificationByRollup[_currentEntryRollupId].queue[_currentEntryIndex];
        }
    }

    /// @notice Consumes the next ExpectedL1ToL2Call entry, or replays a pre-computed
    ///         reverting lookup call when no entry matches.
    /// @dev Routing rules:
    ///      1. ExpectedL1ToL2Call at `_lastNestedActionConsumed` matches `crossChainCallHash`
    ///         → advance the cursor by 1, hash NESTED_BEGIN/END, return cached returnData.
    ///         This is the only path that advances the cursor.
    ///      2. Otherwise scan `_transientLookupCalls` then the destination rollup's
    ///         `lookupQueue` for a `failed=true` entry keyed by
    ///         (crossChainCallHash, _currentCallNumber, idx) where `idx` is the current cursor
    ///         value → revert with cached returnData.
    ///      3. No match → set the deferred-revert flag `_nestedActionNotFound` and return
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
        ExecutionEntry storage entry = _currentEntryStorage();
        uint256 idx = _lastNestedActionConsumed; // pre-commit read; advance only on match

        // 1. ExpectedL1ToL2Call priority — the ONLY path that advances the cursor.
        if (
            idx < entry.expectedL1ToL2Calls.length
                && entry.expectedL1ToL2Calls[idx].crossChainCallHash == crossChainCallHash
        ) {
            _lastNestedActionConsumed = idx + 1;
            ExpectedL1ToL2Call storage nested = entry.expectedL1ToL2Calls[idx];
            uint256 nestedNumber = idx + 1;
            emit NestedActionConsumed(_currentEntryIndex, nestedNumber, crossChainCallHash, nested.callCount);
            _rollingHashNestedBegin(nestedNumber);
            _processNCalls(nested.callCount);
            _rollingHashNestedEnd(nestedNumber);
            return nested.returnData;
        }

        // 2. Fallback to a failed-lookup-call entry. Lookup key uses pre-bump cursor.
        uint64 callNum = uint64(_currentCallNumber);
        uint64 lastNA = uint64(idx);
        for (uint256 i = 0; i < _transientLookupCalls.length; i++) {
            LookupCall storage sc = _transientLookupCalls[i];
            if (
                sc.failed && sc.crossChainCallHash == crossChainCallHash && sc.callNumber == callNum
                    && sc.lastNestedActionConsumed == lastNA
            ) {
                _resolveLookupCall(sc); // always reverts (sc.failed == true)
            }
        }
        
        // Per-rollup static queue: route by the action's target rollup (== entry.destinationRollupId
        // because nested actions are scoped to the containing entry).
        uint256 destRid = entry.destinationRollupId;
        LookupCall[] storage lookupQueue = verificationByRollup[destRid].lookupQueue;
        for (uint256 i = 0; i < lookupQueue.length; i++) {
            LookupCall storage sc = lookupQueue[i];
            if (
                sc.failed && sc.crossChainCallHash == crossChainCallHash && sc.callNumber == callNum
                    && sc.lastNestedActionConsumed == lastNA
            ) {
                _resolveLookupCall(sc);
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
        _nestedActionNotFound = true;
        return "";
    }

    /// @notice Consumes the next execution entry, applies state deltas, executes calls, and verifies rolling hash
    /// @dev Consults the transient table first ("always look for transient calls before storage calls").
    ///      While a postAndVerifyBatch call is running, `_transientExecutions` is non-empty and ALL consumption
    ///      is routed through it via a global cursor — entries are NOT popped, only `_transientExecutionIndex`
    ///      advances. Outside the transient batch, consumption is routed by the destination rollup to
    ///      `verificationByRollup[destRid].queue` with that rollup's own cursor — `destinationRollupId`
    ///      doesn't need a separate consistency check because (a) the proof bound it into the entry hash,
    ///      and (b) the crossChainCallHash preimage already commits to the target rollup.
    ///
    ///      Miss path: when the cursor is out of bounds or the next entry's `proxyEntryHash` doesn't match,
    ///      `_tryRevertedTopLevelLookup` scans the transient + persistent lookup tables for a
    ///      `failed=true` `LookupCall` keyed by `(crossChainCallHash, callNumber=0, lastNestedActionConsumed=0)`.
    ///      On match, that helper reverts with the cached `returnData` (so the caller's `try/catch` observes
    ///      the prover-specified revert). On no match the helper returns and we revert `ExecutionNotFound`.
    ///      The cursor is NOT advanced on the miss path — a failed top-level call consumes a `LookupCall`,
    ///      not an `ExecutionEntry`, so the next consumer still sees the same next entry.
    /// @param destRid The destination rollup whose queue / transient slot to consume from
    /// @param crossChainCallHash The expected action input hash for the next entry
    /// @param etherIn The ETH value received (msg.value) for ether accounting
    /// @return result The pre-computed return data from the action
    function _consumeAndExecute(uint256 destRid, bytes32 crossChainCallHash, int256 etherIn)
        internal
        returns (bytes memory result)
    {
        ExecutionEntry storage entry;
        uint256 idx;

        if (_transientExecutions.length != 0) {
            idx = _transientExecutionIndex;
            if (idx >= _transientExecutions.length || _transientExecutions[idx].proxyEntryHash != crossChainCallHash) {
                // Try reverted-lookup fallback (always reverts on match); otherwise ExecutionNotFound
                _tryRevertedTopLevelLookup(crossChainCallHash, destRid);
                revert ExecutionNotFound();
            }
            _transientExecutionIndex = idx + 1;
            entry = _transientExecutions[idx];
            _currentEntryRollupId = 0; // marker: transient phase (storage routes via length)
        } else {
            RollupVerification storage rec = verificationByRollup[destRid];
            idx = rec.cursor;
            if (idx >= rec.queue.length || rec.queue[idx].proxyEntryHash != crossChainCallHash) {
                // Try reverted-lookup fallback (always reverts on match); otherwise ExecutionNotFound
                _tryRevertedTopLevelLookup(crossChainCallHash, destRid);
                revert ExecutionNotFound();
            }
            rec.cursor = idx + 1;
            entry = rec.queue[idx];
            _currentEntryRollupId = destRid;
        }

        emit ExecutionConsumed(crossChainCallHash, destRid, idx);

        _currentEntryIndex = idx;
        _applyAndExecute(entry.stateDeltas, entry.callCount, entry.rollingHash, etherIn);

        return entry.returnData;
    }

    /// @notice Applies state deltas (with currentState validation), processes calls,
    ///         verifies rolling hash, checks ether accounting, then resets _currentCallNumber
    function _applyAndExecute(StateDelta[] memory deltas, uint256 callCount, bytes32 rollingHash, int256 etherIn)
        internal
    {
        _rollingHash = bytes32(0);
        _currentCallNumber = 0;
        _lastNestedActionConsumed = 0;

        int256 etherOut = _processNCalls(callCount);
        int256 totalEtherDelta = _applyStateDeltas(deltas);

        ExecutionEntry storage entry = _currentEntryStorage();
        // Check the deferred no-match flag from `_consumeNestedAction` first so the failure
        // surfaces as `ExecutionNotFound` rather than the downstream `RollingHashMismatch` it
        // would otherwise cause (returning empty bytes diverges the entry's rolling hash).
        if (_nestedActionNotFound) revert ExecutionNotFound();
        if (_rollingHash != rollingHash) revert RollingHashMismatch();
        if (_currentCallNumber != entry.L2ToL1Calls.length) revert UnconsumedCalls();
        if (_lastNestedActionConsumed != entry.expectedL1ToL2Calls.length) revert UnconsumedNestedActions();
        if (totalEtherDelta != etherIn - etherOut) revert EtherDeltaMismatch();

        emit EntryExecuted(_currentEntryIndex, _rollingHash, _currentCallNumber, _lastNestedActionConsumed);
        _currentCallNumber = 0; // resets _insideExecution()
    }

    /// @notice Processes N calls from the flat entry.L2ToL1Calls[] array
    /// @param count Number of iterations to process
    /// @return etherOut Total ETH sent in successful (non-reverted) calls. Local var (not
    ///         transient) so revertSpan rollbacks don't affect the outer accumulator — the
    ///         inner `_processNCalls` invocation through `executeInContextAndRevert` keeps its own
    ///         local that is discarded with the revert frame, which is exactly what we want.
    function _processNCalls(uint256 count) internal returns (int256 etherOut) {
        ExecutionEntry storage entry = _currentEntryStorage();
        uint256 processed = 0;
        while (processed < count) {
            uint256 revertSpan = entry.L2ToL1Calls[_currentCallNumber].revertSpan;

            if (revertSpan == 0) {
                L2ToL1Call memory cc = entry.L2ToL1Calls[_currentCallNumber];
                _currentCallNumber++;

                _rollingHashCallBegin(_currentCallNumber);

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

                _rollingHashCallEnd(_currentCallNumber, success, retData);
                emit CallResult(_currentEntryIndex, _currentCallNumber, success, retData);
                processed++;
            } else {
                uint256 savedCallNumber = _currentCallNumber;
                entry.L2ToL1Calls[_currentCallNumber].revertSpan = 0;

                try this.executeInContextAndRevert(revertSpan) {}
                catch (bytes memory revertData) {
                    bool innerNotFound;
                    (_rollingHash, _lastNestedActionConsumed, _currentCallNumber, innerNotFound) =
                        _decodeContextResult(revertData);
                    // OR-merge: a no-match observed inside the span must survive the forced
                    // revert so the end-of-entry check still fires `ExecutionNotFound`.
                    if (innerNotFound) _nestedActionNotFound = true;
                }

                entry.L2ToL1Calls[savedCallNumber].revertSpan = revertSpan;
                emit RevertSpanExecuted(_currentEntryIndex, savedCallNumber, revertSpan);
                processed += revertSpan;
            }
        }
    }

    /// @notice Executes calls in an isolated context that always reverts
    function executeInContextAndRevert(uint256 callCount) external {
        if (msg.sender != address(this)) revert NotSelf();
        _processNCalls(callCount);
        revert ContextResult(_rollingHash, _lastNestedActionConsumed, _currentCallNumber, _nestedActionNotFound);
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

    // ──────────────────────────────────────────────
    //  Rollup management (only registered manager)
    // ──────────────────────────────────────────────
    //
    // The two functions below are the only paths through which the registered manager
    // contract for a rollup can mutate central state (state root, manager pointer). Both
    // resolve `rollupId` by `msg.sender` against the reverse-lookup mapping — the manager
    // never has to know its own id. Both gate on the registry's `lastVerifiedBlock(rid) ==
    // block.number` predicate, which is the single source of truth for "this rollup is
    // mid-flow this block — don't mutate". The per-rollup manager contract has no lockout
    // modifier on its owner ops because (a) only `setStateRoot` reaches central state and
    // (b) it's already gated here.

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
    //  Lookup call lookup
    // ──────────────────────────────────────────────

    /// @notice Looks up a pre-computed lookup call result, scanning the transient table
    ///         first then the destination rollup's static queue
    /// @dev Matches by crossChainCallHash + current call number + last nested action consumed.
    ///      Consults `_transientLookupCalls` first (populated only while a postAndVerifyBatch is
    ///      executing its transient prefix) and falls through to the per-rollup
    ///      `lookupQueue` keyed by `proxyInfo.originalRollupId`. tload works in static
    ///      context, so the transient tracking variables used to compute the match keys
    ///      are readable.
    /// @dev TODO (perf): if the batch has many lookup calls, the linear scan is O(n).
    ///      Idea: have the orchestrator sort `lookupCalls[]` by a derived key (e.g., the
    ///      lookup tuple `keccak256(crossChainCallHash, callNumber, lastNestedActionConsumed)`,
    ///      treated as a `uint256`) so on-chain we can binary-search → O(log n). Same
    ///      `_consumeNestedAction` fallback could use the same ordering. The proof would
    ///      need to enforce sort order (cheap: `keys[i+1] > keys[i]`) and the publicInputsHash
    ///      already binds the array via `lookupCallHashes`, so re-ordering by the prover
    ///      can't sneak in. Punted until profiling shows it matters.
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

        uint64 callNum = uint64(_currentCallNumber);
        uint64 lastNA = uint64(_lastNestedActionConsumed);

        for (uint256 i = 0; i < _transientLookupCalls.length; i++) {
            LookupCall storage sc = _transientLookupCalls[i];
            if (
                sc.crossChainCallHash == crossChainCallHash && sc.callNumber == callNum
                    && sc.lastNestedActionConsumed == lastNA
            ) {
                return _resolveLookupCall(sc);
            }
        }
        LookupCall[] storage lookupQueue = verificationByRollup[destRid].lookupQueue;
        for (uint256 i = 0; i < lookupQueue.length; i++) {
            LookupCall storage sc = lookupQueue[i];
            if (
                sc.crossChainCallHash == crossChainCallHash && sc.callNumber == callNum
                    && sc.lastNestedActionConsumed == lastNA
            ) {
                return _resolveLookupCall(sc);
            }
        }

        revert ExecutionNotFound();
    }

    /// @notice Top-level fallback: scan transient table then the routed rollup's persistent
    ///         `lookupQueue` for a `LookupCall` with `failed=true` matching
    ///         `(crossChainCallHash, callNumber=0, lastNestedActionConsumed=0)`. The (0,0)
    ///         lookup key denotes top-level context — disjoint from the nested fallback path
    ///         which always observes `callNumber > 0`. On match, `_resolveLookupCall` reverts
    ///         with the cached `returnData`; on no match, returns so the caller reverts
    ///         `ExecutionNotFound`.
    function _tryRevertedTopLevelLookup(bytes32 crossChainCallHash, uint256 destRid) internal view {
        for (uint256 i = 0; i < _transientLookupCalls.length; i++) {
            LookupCall storage sc = _transientLookupCalls[i];
            if (
                sc.failed && sc.crossChainCallHash == crossChainCallHash && sc.callNumber == 0
                    && sc.lastNestedActionConsumed == 0
            ) {
                _resolveLookupCall(sc); // always reverts (sc.failed == true)
            }
        }
        LookupCall[] storage lookupQueue = verificationByRollup[destRid].lookupQueue;
        for (uint256 i = 0; i < lookupQueue.length; i++) {
            LookupCall storage sc = lookupQueue[i];
            if (
                sc.failed && sc.crossChainCallHash == crossChainCallHash && sc.callNumber == 0
                    && sc.lastNestedActionConsumed == 0
            ) {
                _resolveLookupCall(sc);
            }
        }
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
        return verificationByRollup[_rollupId].queue.length;
    }

    /// @notice Cursor (next-to-consume) for the deferred queue of `_rollupId`
    function queueCursor(uint256 _rollupId) external view returns (uint256) {
        return verificationByRollup[_rollupId].cursor;
    }
}
