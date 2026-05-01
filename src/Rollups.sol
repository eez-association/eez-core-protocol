// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IProofSystem} from "./IProofSystem.sol";
import {IRollup} from "./rollupContract/IRollup.sol";
import {CrossChainProxy} from "./CrossChainProxy.sol";
import {
    ICrossChainManager,
    StateDelta,
    CrossChainCall,
    NestedAction,
    LookupCall,
    ExecutionEntry,
    ProxyInfo
} from "./ICrossChainManager.sol";
import {IMetaCrossChainReceiver} from "./interfaces/IMetaCrossChainReceiver.sol";

/// @notice Rollup configuration held by the central registry.
/// @dev Owner, threshold, and per-PS vkeys live on the per-rollup `IRollup` contract pointed
///      to by `rollupContract`. The central registry holds only the *state* (state root,
///      ether balance) and reads vkeys through `IRollup.getVkeysFromProofSystems` — which
///      enforces the manager's threshold internally and reverts if not met. Threshold itself
///      is never read by the registry.
struct RollupConfig {
    address rollupContract;
    bytes32 stateRoot;
    uint256 etherBalance;
}

/// @notice One sub-batch's payload — a group of proof systems jointly attesting to a set of
///         rollups' state transitions, all sharing the same entries / lookup calls /
///         crossProofSystemInteractions binding.
/// @dev `rollupIds` must be strictly increasing within a sub-batch (cross-batch disjointness
///      is enforced for free by `_markVerifiedThisBlock`'s once-per-block guard).
///      `proofSystems` must be strictly increasing (rejects address(0) and duplicates).
///      Each manager enforces ITS OWN `getVkeysFromProofSystems` strict semantic: every
///      `proofSystems[i]` must be allowed for that rollup (non-zero vkey) AND
///      `proofSystems.length` must be ≥ that rollup's threshold. Net effect: the (rid × ps)
///      vkMatrix is uniformly non-zero — the orchestrator must choose a `proofSystems` set
///      that's a subset of every participating rollup's allowed set.
/// @dev `blobIndices` selects which of the tx-level EIP-4844 blobs this sub-batch consumes;
///      `callData` is sub-batch-scoped (each PS's circuit gets its own region).
/// @dev `transientCount` and `transientLookupCallCount` are per-sub-batch: from each sub-batch
///      we pull its first `transientCount` entries and first `transientLookupCallCount` static
///      calls into the shared transient tables (concatenated in sub-batch order). They are
///      pure on-chain dispatch parameters — not bound by the proof — so the orchestrator can
///      tune the transient/persistent split per sub-batch without re-proving.
struct ProofSystemBatch {
    address[] proofSystems;
    uint256[] rollupIds;
    ExecutionEntry[] entries;
    LookupCall[] lookupCalls;
    uint256 transientCount;
    uint256 transientLookupCallCount;
    uint256[] blobIndices;
    bytes callData;
    bytes[] proof;
    bytes32 crossProofSystemInteractions;
}

/// @notice Per-rollup deferred-consumption queue + once-per-block guard
/// @dev `lastVerifiedBlock` doubles as:
///        (a) the once-per-block-per-rollup invariant (a rollup can be verified at most once
///            per L1 block — required so multiple `postBatch` calls in the same block are
///            only allowed on disjoint rollup sets);
///        (b) read gate for consumers (entries can only be consumed in the block they were
///            posted — `executeCrossChainCall` / `executeL2TX` / `staticCallLookup` all gate
///            on `lastVerifiedBlock(rid) == block.number`);
///        (c) lockout signal for the registry's owner-escape paths — `Rollups.setStateRoot`
///            and `Rollups.setRollupContract` revert `RollupBatchActiveThisBlock` when this
///            equals `block.number`;
///        (d) the lazy-reset signal — when `lastVerifiedBlock < block.number` the queue is
///            considered empty, no explicit cleanup pass needed.
struct RollupVerification {
    uint256 lastVerifiedBlock;
    ExecutionEntry[] queue;
    LookupCall[] lookupQueue;
    uint256 cursor;
}

/// @title Rollups
/// @notice L1 contract managing rollup state roots, multi-prover batch posting, and cross-chain call execution
/// @dev Execution entries are posted via `postBatch()` with one or more sub-batches, each
///      attested by ≥ threshold proof systems. Atomic verification: if any single proof
///      fails, the whole batch reverts.
///
///      Each sub-batch's leading `transientCount` entries are concatenated (in sub-batch
///      order) into `_transientExecutions` (semantically transient, cleared at end of
///      postBatch). The leading run of those entries with `actionHash == 0` runs inline as
///      "immediate" entries (state deltas + flat calls + rolling hash, one `_applyAndExecute`
///      cycle per entry). Then `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()`
///      is invoked (when msg.sender has code) so the caller can drive the remaining transient
///      entries via cross-chain proxy calls within the same transaction.
///
///      Each sub-batch's remainder (entries past its `transientCount`) is published into
///      per-rollup queues keyed by `destinationRollupId` UNCONDITIONALLY — even if the meta
///      hook left transient entries unconsumed. Soundness backstop: every entry's
///      `StateDelta.currentState` is checked at consumption time, so any persistent entry
///      whose preconditions were lost with the dropped transient leftover simply fails its
///      `StateRootMismatch` check.
///
///      Deferred consumption: `executeCrossChainCall` (proxy entry) and `executeL2TX(rid)`
///      route to `verificationByRollup[rid].queue[cursor]` and advance the per-rollup cursor.
contract Rollups is ICrossChainManager {
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

    /// @notice Mapping of authorized CrossChainProxy contracts to their identity
    mapping(address proxy => ProxyInfo info) public authorizedProxies;

    // ── Rolling hash tag constants ──
    uint8 internal constant CALL_BEGIN = 1;
    uint8 internal constant CALL_END = 2;
    uint8 internal constant NESTED_BEGIN = 3;
    uint8 internal constant NESTED_END = 4;

    // ── Transient-backed execution entries & lookup calls ──
    //
    // First N entries / M lookup calls of the flattened sub-batch stream live here instead of
    // the per-rollup persistent queues to save storage gas during intra-tx (meta-hook)
    // consumption. Semantically transient (populated and cleared within a single postBatch
    // call) but declared as regular storage since Solidity 0.8.34 does not yet support
    // `transient` data location for reference types with nested dynamic arrays. Both are
    // cleared at the end of every postBatch, regardless of success.
    // TODO: promote to real `transient` once Solidity supports transient reference types
    //       with nested dynamic arrays — until then, we rely on manual `delete` at the
    //       end of every postBatch plus SSTORE refunds from zeroing the slots.
    ExecutionEntry[] public _transientExecutions;
    LookupCall[] public _transientLookupCalls;

    /// @notice Cursor into `_transientExecutions` for the next entry to consume.
    /// @dev Only meaningful while `_transientExecutions.length != 0`. The table's length
    ///      itself is what flags "inside a transient batch" for `_currentEntryStorage()`
    ///      and `_consumeAndExecute`; this variable just tracks progress. Transient so it
    ///      resets between transactions automatically, and explicitly reset at the end
    ///      of every postBatch.
    uint256 transient _transientExecutionIndex;

    // No dedicated `_inPostBatch` flag — `_transientExecutions.length != 0` already
    // identifies the dangerous re-entry window (from `_loadTransient` through cleanup).
    // Steps 1-3 of `postBatch` (validate, verify-STATICCALL, mark-verified) have no
    // external calls, and step 7 (publish) has no external calls either, so neither
    // needs guarding.

    // ── Transient execution state ──

    /// @notice The current execution entry being processed
    /// @dev When inside the transient phase (`_transientExecutions.length != 0`), this
    ///      indexes `_transientExecutions`. In the persistent phase, it's the per-rollup
    ///      queue cursor `(cursor - 1)` of whichever rollup queue is currently being
    ///      consumed; the rollup itself is held in `_currentEntryRollupId`.
    uint256 transient _currentEntryIndex;

    /// @notice The rollup ID whose queue is supplying the entry currently being processed.
    /// @dev `0` outside execution. Used by `_currentEntryStorage()` to disambiguate which
    ///      persistent queue to route into when `_transientExecutions.length == 0`.
    uint256 transient _currentEntryRollupId;

    /// @notice Transient rolling hash accumulating tagged events across the entire entry
    bytes32 transient _rollingHash;

    /// @notice 1-indexed global call counter and cursor into entry.calls[]
    /// @dev Also replaces _insideExecution: _currentCallNumber != 0 means inside execution
    uint256 transient _currentCallNumber;

    /// @notice Sequential nested action consumption counter
    /// @dev Also used by staticCallLookup to disambiguate multiple lookup calls within the same call
    uint256 transient _lastNestedActionConsumed;

    /// @notice Emitted when a new rollup is created
    event RollupCreated(uint256 indexed rollupId, address indexed rollupContract, bytes32 initialState);

    /// @notice Emitted when a rollup's manager contract is swapped
    event RollupContractChanged(
        uint256 indexed rollupId, address indexed previousContract, address indexed newContract
    );

    /// @notice Emitted when a rollup state is updated (only via the registered rollupContract)
    event StateUpdated(uint256 indexed rollupId, bytes32 newStateRoot);

    /// @notice Emitted when a new CrossChainProxy is created
    event CrossChainProxyCreated(
        address indexed proxy, address indexed originalAddress, uint256 indexed originalRollupId
    );

    /// @notice Emitted when an L2 execution is performed
    event L2ExecutionPerformed(uint256 indexed rollupId, bytes32 newState);

    /// @notice Emitted when an execution entry is consumed
    event ExecutionConsumed(bytes32 indexed actionHash, uint256 indexed rollupId, uint256 indexed cursor);

    /// @notice Emitted when a cross-chain call is executed via proxy
    event CrossChainCallExecuted(
        bytes32 indexed actionHash, address indexed proxy, address sourceAddress, bytes callData, uint256 value
    );

    /// @notice Emitted when a precomputed L2 transaction is executed
    event L2TXExecuted(uint256 indexed rollupId, uint256 indexed cursor);

    /// @notice Emitted when a batch is posted via postBatch
    event BatchPosted(uint256 indexed subBatchCount);

    /// @notice Emitted after each call completes in _processNCalls
    /// @dev Not emitted for calls inside a revertSpan (those events are rolled back by the revert)
    event CallResult(uint256 indexed entryIndex, uint256 indexed callNumber, bool success, bytes returnData);

    /// @notice Emitted when a nested action is consumed during reentrant execution
    event NestedActionConsumed(
        uint256 indexed entryIndex, uint256 indexed nestedNumber, bytes32 actionHash, uint256 callCount
    );

    /// @notice Emitted after an entry's execution completes and all verifications pass
    event EntryExecuted(
        uint256 indexed entryIndex, bytes32 rollingHash, uint256 callsProcessed, uint256 nestedActionsConsumed
    );

    /// @notice Emitted after a revert span is processed via executeInContextAndRevert
    event RevertSpanExecuted(uint256 indexed entryIndex, uint256 startCallNumber, uint256 span);

    /// @notice Error when proof verification fails
    error InvalidProof();

    /// @notice Reverts when `postBatch` is re-entered (e.g., via the meta hook calling back
    ///         into `postBatch` for a disjoint rollup set, which would otherwise corrupt the
    ///         shared transient tables)
    error PostBatchReentry();

    /// @notice Error when caller is not an authorized proxy
    error UnauthorizedProxy();

    /// @notice Error when caller is not the rollup's registered manager contract
    error NotRollupContract();

    /// @notice Error when executeInContextAndRevert is called by an external address
    error NotSelf();

    /// @notice Error when execution is not found or actionHash doesn't match next entry
    error ExecutionNotFound();

    /// @notice Error when a second `postBatch` tries to verify a rollup already verified this block
    error RollupAlreadyVerifiedThisBlock(uint256 rollupId);

    /// @notice Error when an owner-escape path on the manager (setStateRoot / setRollupContract)
    ///         is invoked in the same block a `postBatch` already touched the rollup
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

    /// @notice Error when the computed rolling hash doesn't match the entry's rollingHash
    error RollingHashMismatch();

    /// @notice Carries execution results out of a reverted context
    error ContextResult(bytes32 rollingHash, uint256 lastNestedActionConsumed, uint256 currentCallNumber);

    /// @notice Error when executeInContextAndRevert reverts with an unexpected error
    error UnexpectedContextRevert(bytes revertData);

    /// @notice Error when not all nested actions were consumed after execution
    error UnconsumedNestedActions();

    /// @notice Error when not all calls were consumed after execution
    error UnconsumedCalls();

    /// @notice Error when executeL2TX is called while already inside a cross-chain execution
    error L2TXNotAllowedDuringExecution();

    /// @notice Error when `transientCount` passed to postBatch exceeds the flattened entry count
    error TransientCountExceedsEntries();

    /// @notice Error when `transientLookupCallCount` exceeds the flattened lookup call count
    error TransientLookupCallCountExceedsLookupCalls();

    /// @notice Error when sub-batch validation fails for malformed inputs
    error InvalidProofSystemConfig();

    /// @notice Error when duplicate / unsorted proof systems are submitted in a single sub-batch
    error DuplicateProofSystem(address proofSystem);

    /// @notice Error when an entry's destinationRollupId, a state delta's rollupId, or a
    ///         lookup call's destinationRollupId references a rollup not in the sub-batch
    error RollupNotInBatch(uint256 rollupId);

    // ──────────────────────────────────────────────
    //  Rollup creation
    // ──────────────────────────────────────────────

    /// @notice Registers a pre-deployed `IRollup`-conforming manager contract as a new rollup
    /// @dev The caller deploys the manager (e.g. our reference `Rollup.sol`, or a custom
    ///      multisig / governance contract) with the desired proof systems / threshold /
    ///      whatever ownership model it chooses baked in, then registers it here. Registry
    ///      assigns a fresh rollupId, stores the initial state root, and indexes the manager
    ///      for reverse-lookup. The registry makes no assumption about how the manager
    ///      handles ownership — that's entirely the manager's concern.
    /// @param rollupContract Address of the pre-deployed `IRollup` contract
    /// @param initialState Initial state root for this rollup
    /// @return rollupId Newly assigned rollup ID
    function createRollup(address rollupContract, bytes32 initialState) external returns (uint256 rollupId) {
        if (rollupContract == address(0) || rollupContract == address(this)) revert InvalidRollupContract();

        rollupId = rollupCounter++;
        rollups[rollupId] = RollupConfig({rollupContract: rollupContract, stateRoot: initialState, etherBalance: 0});

        // One-shot callback informing the manager of its rollupId. Manager must accept this
        // call only from the registry and only when not already initialized (otherwise reuse
        // of an already-registered manager would silently take over a different rollupId).
        IRollup(rollupContract).rollupContractRegistered(rollupId);

        emit RollupCreated(rollupId, rollupContract, initialState);
    }

    // ──────────────────────────────────────────────
    //  Batch posting & execution table (multi-prover)
    // ──────────────────────────────────────────────

    /// @notice Posts a batch composed of one or more sub-batches, each attested by ≥ threshold proof systems
    /// @dev Flow:
    ///      1. Per-sub-batch structural validation (sorting, disjointness, registration,
    ///         destination membership, transient bounds). NO external calls.
    ///      2. Atomic verification: per sub-batch, fetch vkMatrix from the manager (which
    ///         enforces its own threshold) and verify each proof. ALL must verify before any
    ///         state mutation — atomicity is what makes `crossProofSystemInteractions`
    ///         load-bearing across PSes. These external calls are `view` (STATICCALL), so
    ///         no reentrancy concern.
    ///      3. Mark every touched rollup as verified-this-block. Sets the once-per-block-per-rollup
    ///         invariant AND the read gate for `executeCrossChainCall` / `executeL2TX` (which
    ///         require `lastVerifiedBlock(rid) == block.number`). Done before the meta hook
    ///         (non-view CALL) so the hook + later proxy calls can read from the queues.
    ///      4. Build the transient stream by concatenating each sub-batch's leading
    ///         `batch.transientCount` entries (and `batch.transientLookupCallCount` static
    ///         calls) in sub-batch order. The combined stream lives in `_transientExecutions`
    ///         / `_transientLookupCalls` and is consumed via a single global cursor.
    ///      5. Drain the leading run of transient entries whose `actionHash == 0` inline
    ///         (pure L2 transactions + L2 transactions that touch L1). These have no source
    ///         action to match so they cannot be driven by the meta hook — the only place
    ///         they can be consumed during postBatch is here. The transient cursor advances
    ///         past all of them before the hook fires; each entry runs its own
    ///         `_applyAndExecute` cycle with independent rolling hash / cursor resets.
    ///      6. If `msg.sender` is a contract, invoke its `IMetaCrossChainReceiver` hook so it
    ///         can drive the rest of the transient-backed entries via cross-chain proxy calls
    ///         within the same transaction.
    ///      7. Clean up the transient tables (whatever the hook consumed and whatever it
    ///         didn't). Anything left unconsumed is dropped here.
    ///      8. Publish each sub-batch's remainder (entries past its own `transientCount`)
    ///         into per-rollup queues keyed by each entry's `destinationRollupId`. Done
    ///         unconditionally — entries are content-addressed by `StateDelta.currentState`,
    ///         so any entry whose preconditions were dropped with the transient leftover
    ///         simply fails at consumption. A sub-batch with `transientCount == 0`
    ///         contributes nothing to the transient stream and all its entries flow straight
    ///         into the per-rollup queues here.
    /// @param batches Array of proof-system groups (rollupIds disjoint across sub-batches);
    ///                each carries its own `transientCount` / `transientLookupCallCount`
    function postBatch(ProofSystemBatch[] calldata batches) external {
        // Reentrancy guard. Per-rollup `lastVerifiedBlock` blocks same-rollup re-entry, but a
        // disjoint-rollup nested `postBatch` (e.g., from the meta hook) would otherwise share
        // the same `_transientExecutions` / `_transientLookupCalls` storage and corrupt them.
        // `_transientExecutions.length != 0` is true from `_loadTransient` through cleanup,
        // covering the entire window where a meta-hook callback could reach back here.
        // `_insideExecution()` is NOT sufficient — it's false during the meta hook window
        // (between proxy calls), missing the most common reentry path.
        if (_transientExecutions.length != 0) revert PostBatchReentry();

        if (batches.length == 0) revert InvalidProofSystemConfig();

        // 1. Structural validation, NO external calls. Catches malformed input and ensures
        //    every rollup is registered (rollupContract != 0) before we touch its manager.
        for (uint256 b = 0; b < batches.length; b++) {
            _validateStructure(batches[b]);
        }

        // 2. Per-sub-batch verification — fetch the vkMatrix ONCE per rollup, then verify
        //    every proof in that sub-batch using the cached matrix. Each manager enforces
        //    BOTH threshold (`proofSystems.length >= threshold`) AND per-PS membership
        //    (every input PS has a non-zero vkey for this rollup) inside
        //    `getVkeysFromProofSystems` — reverts on either failure, so the matrix is
        //    uniformly non-zero on success. Single combined loop keeps the matrix scoped
        //    to one iteration so we don't allocate `bytes32[][][]` across the whole batch.
        //
        //    Reentrancy: both `IRollup.getVkeysFromProofSystems` and `IProofSystem.verify`
        //    are `view` → dispatched via STATICCALL by the compiler. State mutations inside
        //    a STATICCALL frame (including nested calls) revert at the EVM level, so a
        //    malicious manager / verifier cannot reenter `postBatch` (state-mutating). Safe
        //    to perform these external calls before `_markVerifiedThisBlock`.
        for (uint256 b = 0; b < batches.length; b++) {
            bytes32[][] memory vkMatrix = _fetchVkMatrix(batches[b]);
            _verifyProofSystemBatch(batches[b], vkMatrix);
        }

        // 3. Mark all touched rollups as verified-this-block. Sets the once-per-block-per-rollup
        //    invariant AND the read gate for `executeCrossChainCall` / `executeL2TX` (which
        //    require `lastVerifiedBlock(rid) == block.number`). Done before the immediate-entry
        //    `_processNCalls` (which calls into proxies via non-view CALL — those CAN reenter,
        //    so the lastVerifiedBlock guard is what they hit).
        for (uint256 b = 0; b < batches.length; b++) {
            uint256[] calldata rids = batches[b].rollupIds;
            for (uint256 i = 0; i < rids.length; i++) {
                _markVerifiedThisBlock(rids[i]);
            }
        }

        // 3. Build the transient stream by concatenating each sub-batch's leading prefix.
        _loadTransient(batches);

        // 4. Drain the leading run of transient entries with `actionHash == 0` inline.
        //    These are the "pure L2 transactions + L2 transactions that touch L1" entries —
        //    no source action to match, so the only way to consume them is here, before the
        //    meta hook starts driving non-zero-actionHash entries via proxy calls. Each runs
        //    its own `_applyAndExecute` cycle (rolling hash / cursors reset per entry).
        //    `etherIn = 0` because these entries aren't driven by an external value transfer.
        while (
            _transientExecutionIndex < _transientExecutions.length
                && _transientExecutions[_transientExecutionIndex].actionHash == bytes32(0)
        ) {
            uint256 idx = _transientExecutionIndex;
            _currentEntryIndex = idx;
            _currentEntryRollupId = 0; // marker: transient phase (storage routes via length)
            ExecutionEntry storage immediate = _transientExecutions[idx];
            _applyAndExecute(immediate.stateDeltas, immediate.callCount, immediate.rollingHash, 0);
            _transientExecutionIndex = idx + 1;
        }

        // 5. Meta hook — caller drives the rest of the transient entries via proxy calls.
        if (_transientExecutionIndex < _transientExecutions.length && msg.sender.code.length > 0) {
            IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions();
        }

        // 6. Cleanup transient tables (SSTORE refunds; nothing leaks into next tx). Done
        //    BEFORE the deferred publish so that any subsequent reads during publish see a
        //    clean transient surface, and storage writes happen in a single committed phase.
        delete _transientExecutions;
        delete _transientLookupCalls;
        _transientExecutionIndex = 0;

        // 7. Deferred publish — push each sub-batch's remainder (entries past its own
        //    `transientCount`) into per-rollup queues keyed by `destinationRollupId`.
        //    Done unconditionally even if the meta hook didn't drain the transient stream:
        //    every entry is content-addressed via `StateDelta.currentState`, so any entry
        //    whose preconditions were lost with the dropped transient leftover will simply
        //    fail its `StateRootMismatch` check at consumption time. Publishing regardless
        //    means a hook that consumed nothing still leaves the deferred queue usable.
        _publishRemainder(batches);

        emit BatchPosted(batches.length);
    }

    // ──────────────────────────────────────────────
    //  postBatch internals
    // ──────────────────────────────────────────────

    /// @notice Structural validation of a sub-batch — no external calls, no vkey reads.
    /// @dev Verifies sorting, registration of rollups + PSes, transient bounds, and entry /
    ///      lookup-call `destinationRollupId` membership. Cross-sub-batch disjointness is
    ///      NOT checked here — it's enforced for free by `_markVerifiedThisBlock` at step 3.
    function _validateStructure(ProofSystemBatch calldata batch) internal view {
        if (batch.proofSystems.length == 0) revert InvalidProofSystemConfig();
        if (batch.proofSystems.length != batch.proof.length) revert InvalidProofSystemConfig();
        if (batch.rollupIds.length == 0) revert InvalidProofSystemConfig();

        // rollupIds strictly increasing within this sub-batch (catches same-rid-twice in one
        // batch and address(0) duplicates). Each rollup must be registered (rollupContract != 0).
        //
        // Cross-sub-batch disjointness is NOT checked here — it falls out for free in step 3
        // (`_markVerifiedThisBlock`): a rollup that appears in two sub-batches gets marked
        // twice and the second call reverts `RollupAlreadyVerifiedThisBlock(rid)`. That's
        // O(rollups) instead of the O(rollups × sub-batches) scan we'd otherwise do here.
        uint256 prevRid = MAINNET_ROLLUP_ID;
        for (uint256 i = 0; i < batch.rollupIds.length; i++) {
            uint256 rid = batch.rollupIds[i];
            if (rid <= prevRid) revert InvalidProofSystemConfig();
            if (rollups[rid].rollupContract == address(0)) revert InvalidProofSystemConfig();
            prevRid = rid;
        }

        // proofSystems strictly increasing by address (rejects address(0) and duplicates).
        // No central PS registry — each rollup's manager defines its own allowed set via the
        // vkey map. If a PS is not in any rollup's allowed set in this group, it returns
        // bytes32(0) for that rollup, doesn't contribute to the manager's threshold count,
        // and just costs the orchestrator gas during `IProofSystem.verify`.
        address prevPs = address(0);
        for (uint256 k = 0; k < batch.proofSystems.length; k++) {
            address ps = batch.proofSystems[k];
            if (uint160(ps) <= uint160(prevPs)) revert DuplicateProofSystem(ps);
            prevPs = ps;
        }

        // Every entry's destinationRollupId AND every entry's state delta rollupIds must
        // belong to this sub-batch's rollupIds. The destination check is what prevents an
        // adversarial prover from routing an entry into a different sub-batch's queue
        // during `_publishRemainder`. Same constraint for lookup calls.
        for (uint256 i = 0; i < batch.entries.length; i++) {
            ExecutionEntry calldata entry = batch.entries[i];
            if (!_containsRollup(batch.rollupIds, entry.destinationRollupId)) {
                revert RollupNotInBatch(entry.destinationRollupId);
            }
            StateDelta[] calldata deltas = entry.stateDeltas;
            for (uint256 j = 0; j < deltas.length; j++) {
                if (!_containsRollup(batch.rollupIds, deltas[j].rollupId)) {
                    revert RollupNotInBatch(deltas[j].rollupId);
                }
            }
        }
        for (uint256 i = 0; i < batch.lookupCalls.length; i++) {
            if (!_containsRollup(batch.rollupIds, batch.lookupCalls[i].destinationRollupId)) {
                revert RollupNotInBatch(batch.lookupCalls[i].destinationRollupId);
            }
        }

        // Per-sub-batch transient bounds.
        if (batch.transientCount > batch.entries.length) revert TransientCountExceedsEntries();
        if (batch.transientLookupCallCount > batch.lookupCalls.length) {
            revert TransientLookupCallCountExceedsLookupCalls();
        }
    }

    /// @notice Fetches the (rollupIds × proofSystems) vkey matrix for a sub-batch — one
    ///         external call to `getVkeysFromProofSystems` per rollup. The manager enforces
    ///         its own threshold internally and reverts if not met; on success, the registry
    ///         trusts the returned vkeys. Single fetch reused across the relevance check and
    ///         the publicInputsHash.
    /// @dev Called AFTER `_markVerifiedThisBlock`, so reentry into `postBatch` for the same
    ///      rollups is blocked by `RollupAlreadyVerifiedThisBlock`.
    function _fetchVkMatrix(ProofSystemBatch calldata batch) internal view returns (bytes32[][] memory vkMatrix) {
        vkMatrix = new bytes32[][](batch.rollupIds.length);
        for (uint256 r = 0; r < batch.rollupIds.length; r++) {
            vkMatrix[r] =
                IRollup(rollups[batch.rollupIds[r]].rollupContract).getVkeysFromProofSystems(batch.proofSystems);
        }
    }

    /// @notice Builds per-PS publicInputsHash and verifies every proof in a sub-batch
    /// @dev Uses the cached `vkMatrix` from `_fetchVkMatrix` — same vkeys the threshold gate
    ///      counted against, so a malicious manager cannot return different rows across calls.
    function _verifyProofSystemBatch(ProofSystemBatch calldata batch, bytes32[][] memory vkMatrix) internal view {
        // Selected blob hashes (indexed into the tx-level blob set)
        bytes32[] memory blobHashes = new bytes32[](batch.blobIndices.length);
        for (uint256 i = 0; i < batch.blobIndices.length; i++) {
            blobHashes[i] = blobhash(batch.blobIndices[i]);
        }

        // Per-entry hash binds the FULL entry content: stateDeltas, actionHash,
        // destinationRollupId, calls[], nestedActions[], callCount, returnData, failed,
        // rollingHash. Hashing the whole struct prevents an orchestrator from swapping
        // call/nestedAction/returnData/failed at execution time without invalidating the
        // proof — the rolling hash alone binds only OBSERVED call behavior (success +
        // retData), not the call inputs (target/value/data) that the on-chain code reads
        // out of storage at execution time.
        bytes32[] memory entryHashes = new bytes32[](batch.entries.length);
        for (uint256 i = 0; i < batch.entries.length; i++) {
            entryHashes[i] = keccak256(abi.encode(batch.entries[i]));
        }

        // Per-lookup-call hash, same rationale: a `LookupCall` with empty `calls[]` has only
        // its `returnData` / `failed` validated by content equality at lookup time, so without
        // a hash binding here the orchestrator could swap returnData arbitrarily. Hashing the
        // whole struct (actionHash, destinationRollupId, returnData, failed, stateRoot,
        // callNumber, lastNestedActionConsumed, calls[], rollingHash) closes that gap.
        bytes32[] memory lookupCallHashes = new bytes32[](batch.lookupCalls.length);
        for (uint256 i = 0; i < batch.lookupCalls.length; i++) {
            lookupCallHashes[i] = keccak256(abi.encode(batch.lookupCalls[i]));
        }

        // Two-stage public inputs hash:
        //   sharedPublicInput = H(prevBlockhash, timestamp, rollupIds, entryHashes,
        //                  lookupCallHashes, blobHashes, H(callData), crossProofSystemInteractions)
        //   publicInputsHash[k] = H(sharedPublicInput, rollupVks[k])
        // Stage split keeps the per-PS hash shallow (only two args) so it fits in the EVM
        // stack under via-IR. Commitment is equivalent — every input is still bound, just
        // through a one-extra-keccak path that off-chain provers must mirror.
        bytes32 sharedPublicInput = keccak256(
            abi.encodePacked(
                blockhash(block.number - 1),
                block.timestamp,
                abi.encode(batch.rollupIds),
                abi.encode(entryHashes),
                abi.encode(lookupCallHashes),
                abi.encode(blobHashes),
                keccak256(batch.callData),
                batch.crossProofSystemInteractions
            )
        );

        // Per-PS verification — each PS gets its own publicInputsHash because rollupVks
        // are per-(rid, ps). vkMatrix was fetched once by `_fetchVkMatrix` and reused.
        for (uint256 k = 0; k < batch.proofSystems.length; k++) {
            bytes32[] memory rollupVks = new bytes32[](batch.rollupIds.length);
            for (uint256 r = 0; r < batch.rollupIds.length; r++) {
                rollupVks[r] = vkMatrix[r][k];
            }

            bytes32 publicInputsHash = keccak256(abi.encodePacked(sharedPublicInput, abi.encode(rollupVks)));

            if (!IProofSystem(batch.proofSystems[k]).verify(batch.proof[k], publicInputsHash)) {
                revert InvalidProof();
            }
        }
    }

    /// @notice Sets `lastVerifiedBlock = block.number` for `rid` and rejects double-verification
    /// @dev Lazy reset: a stale `lastVerifiedBlock < block.number` means the queue/cursor are
    ///      considered empty — overwrite them on first touch this block.
    function _markVerifiedThisBlock(uint256 rid) internal {
        RollupVerification storage rec = verificationByRollup[rid];
        if (rec.lastVerifiedBlock == block.number) revert RollupAlreadyVerifiedThisBlock(rid);
        rec.lastVerifiedBlock = block.number;
        // Lazy queue reset — clear stale persistent state from prior blocks.
        if (rec.queue.length != 0) delete rec.queue;
        if (rec.lookupQueue.length != 0) delete rec.lookupQueue;
        rec.cursor = 0;
    }

    /// @notice Builds the transient stream by concatenating each sub-batch's leading prefix
    /// @dev Each sub-batch contributes its first `batch.transientCount` entries and first
    ///      `batch.transientLookupCallCount` lookup calls. The bounds are validated in
    ///      `_validateProofSystemBatch` so we don't need to re-check here.
    function _loadTransient(ProofSystemBatch[] calldata batches) internal {
        for (uint256 b = 0; b < batches.length; b++) {
            ProofSystemBatch calldata batch = batches[b];
            for (uint256 i = 0; i < batch.transientCount; i++) {
                _transientExecutions.push(batch.entries[i]);
            }
            for (uint256 i = 0; i < batch.transientLookupCallCount; i++) {
                _transientLookupCalls.push(batch.lookupCalls[i]);
            }
        }
    }

    /// @notice Publishes each sub-batch's remainder (entries past its own transientCount)
    ///         into per-rollup queues keyed by `destinationRollupId`
    /// @dev TODO: gas optimization opportunity — when the meta hook left some transient
    ///      entries unconsumed (i.e., `_transientExecutionIndex < _transientExecutions.length`),
    ///      every persistent remainder entry whose preconditions depended on a dropped
    ///      transient sibling will fail its `StateRootMismatch` check at consumption time.
    ///      We could detect this case and skip pushing those doomed entries, saving the
    ///      SSTOREs. The detection isn't free (we'd need to track per-sub-batch consumption
    ///      OR walk forward from `_transientExecutionIndex` mapping back to sub-batch
    ///      boundaries) so it's only a win if hooks frequently leave entries unconsumed,
    ///      which we don't expect in normal operation. Punted until profiling shows it
    ///      matters.
    function _publishRemainder(ProofSystemBatch[] calldata batches) internal {
        for (uint256 b = 0; b < batches.length; b++) {
            ProofSystemBatch calldata batch = batches[b];
            for (uint256 i = batch.transientCount; i < batch.entries.length; i++) {
                uint256 destRid = batch.entries[i].destinationRollupId;
                verificationByRollup[destRid].queue.push(batch.entries[i]);
            }
            for (uint256 i = batch.transientLookupCallCount; i < batch.lookupCalls.length; i++) {
                uint256 destRid = batch.lookupCalls[i].destinationRollupId;
                verificationByRollup[destRid].lookupQueue.push(batch.lookupCalls[i]);
            }
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
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
        if (proxyInfo.originalAddress == address(0)) revert UnauthorizedProxy();

        uint256 destRid = proxyInfo.originalRollupId;

        // Block-scoped read gate — entries can only be consumed in the block they were posted
        if (verificationByRollup[destRid].lastVerifiedBlock != block.number) {
            revert ExecutionNotInCurrentBlock(destRid);
        }

        bytes32 actionHash = _computeActionInputHash(
            destRid, proxyInfo.originalAddress, msg.value, callData, sourceAddress, MAINNET_ROLLUP_ID
        );

        emit CrossChainCallExecuted(actionHash, msg.sender, sourceAddress, callData, msg.value);

        if (_insideExecution()) {
            // Reentrant — consume the next nested action
            return _consumeNestedAction(actionHash);
        }

        return _consumeAndExecute(destRid, actionHash, int256(msg.value));
    }

    // ──────────────────────────────────────────────
    //  Execute precomputed L2 transaction
    // ──────────────────────────────────────────────

    /// @notice Executes the next pure-L2 transaction queued for `rollupId`
    /// @dev The next entry in `verificationByRollup[rollupId].queue` must have actionHash == 0.
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

    /// @notice Consumes the next nested action, or replays a pre-computed reverting
    ///         lookup call when no NestedAction matches.
    /// @dev Routing rules:
    ///      1. NestedAction at `_lastNestedActionConsumed` matches `actionHash` → consume
    ///         (the speculative `++` bump is what commits, hash NESTED_BEGIN/END, return
    ///         cached returnData).
    ///      2. Otherwise scan `_transientLookupCalls` then the destination rollup's
    ///         `lookupQueue` for a `failed=true` entry keyed by
    ///         (actionHash, _currentCallNumber, idx) where `idx` is the pre-bump cursor
    ///         value → revert with cached returnData. Every fallback path reverts, so the
    ///         speculative bump is rolled back by the EVM automatically.
    ///      3. No match → revert `ExecutionNotFound`.
    ///
    ///      Why fall back only on `failed=true`: a successful reentrant call in a normal CALL
    ///      frame is expressed as a NestedAction; a successful read-only call is in a STATICCALL
    ///      frame and routed to `staticCallLookup` instead. A lookup-call hit on this path only
    ///      makes sense when the caller has try/catch and expects a revert. The fallback
    ///      sidesteps the transient-rollback issue: a successful match's bump persists; every
    ///      other path reverts and the bump rolls back with it.
    function _consumeNestedAction(bytes32 actionHash) internal returns (bytes memory) {
        ExecutionEntry storage entry = _currentEntryStorage();
        uint256 idx = _lastNestedActionConsumed++;

        // 1. NestedAction priority
        if (idx < entry.nestedActions.length && entry.nestedActions[idx].actionHash == actionHash) {
            NestedAction storage nested = entry.nestedActions[idx];
            uint256 nestedNumber = idx + 1;
            emit NestedActionConsumed(_currentEntryIndex, nestedNumber, actionHash, nested.callCount);
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
                sc.failed && sc.actionHash == actionHash && sc.callNumber == callNum
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
                sc.failed && sc.actionHash == actionHash && sc.callNumber == callNum
                    && sc.lastNestedActionConsumed == lastNA
            ) {
                _resolveLookupCall(sc);
            }
        }

        // 3. No match anywhere
        revert ExecutionNotFound();
    }

    /// @notice Consumes the next execution entry, applies state deltas, executes calls, and verifies rolling hash
    /// @dev Consults the transient table first ("always look for transient calls before storage calls").
    ///      While a postBatch call is running, `_transientExecutions` is non-empty and ALL consumption
    ///      is routed through it via a global cursor — entries are NOT popped, only `_transientExecutionIndex`
    ///      advances. Running past the end inside a transient batch is treated as a hard `ExecutionNotFound`
    ///      (not a fall-through): the proof sized the batch and the hook trying to consume more than that
    ///      is a protocol bug. Outside the transient batch, consumption is routed by the destination rollup
    ///      to `verificationByRollup[destRid].queue` with that rollup's own cursor — `destinationRollupId`
    ///      doesn't need a separate consistency check because (a) the proof bound it into the entry hash,
    ///      and (b) the actionHash preimage already commits to the target rollup, so a mismatch falls
    ///      through to the `entry.actionHash != actionHash` revert below.
    /// @param destRid The destination rollup whose queue / transient slot to consume from
    /// @param actionHash The expected action input hash for the next entry
    /// @param etherIn The ETH value received (msg.value) for ether accounting
    /// @return result The pre-computed return data from the action
    function _consumeAndExecute(uint256 destRid, bytes32 actionHash, int256 etherIn)
        internal
        returns (bytes memory result)
    {
        ExecutionEntry storage entry;
        uint256 idx;

        if (_transientExecutions.length != 0) {
            idx = _transientExecutionIndex++;
            if (idx >= _transientExecutions.length) revert ExecutionNotFound();
            entry = _transientExecutions[idx];
            _currentEntryRollupId = 0; // marker: transient phase (storage routes via length)
        } else {
            RollupVerification storage rec = verificationByRollup[destRid];
            idx = rec.cursor++;
            if (idx >= rec.queue.length) revert ExecutionNotFound();
            entry = rec.queue[idx];
            _currentEntryRollupId = destRid;
        }

        if (entry.actionHash != actionHash) revert ExecutionNotFound();

        emit ExecutionConsumed(actionHash, destRid, idx);

        _currentEntryIndex = idx;
        _applyAndExecute(entry.stateDeltas, entry.callCount, entry.rollingHash, etherIn);

        bytes memory returnData = entry.returnData;
        if (entry.failed) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return returnData;
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
        if (_rollingHash != rollingHash) revert RollingHashMismatch();
        if (_currentCallNumber != entry.calls.length) revert UnconsumedCalls();
        if (_lastNestedActionConsumed != entry.nestedActions.length) revert UnconsumedNestedActions();
        if (totalEtherDelta != etherIn - etherOut) revert EtherDeltaMismatch();

        emit EntryExecuted(_currentEntryIndex, _rollingHash, _currentCallNumber, _lastNestedActionConsumed);
        _currentCallNumber = 0; // resets _insideExecution()
    }

    /// @notice Processes N calls from the flat entry.calls[] array
    /// @param count Number of iterations to process
    /// @return etherOut Total ETH sent in successful (non-reverted) calls. Local var (not
    ///         transient) so revertSpan rollbacks don't affect the outer accumulator — the
    ///         inner `_processNCalls` invocation through `executeInContextAndRevert` keeps its own
    ///         local that is discarded with the revert frame, which is exactly what we want.
    function _processNCalls(uint256 count) internal returns (int256 etherOut) {
        ExecutionEntry storage entry = _currentEntryStorage();
        uint256 processed = 0;
        while (processed < count) {
            uint256 revertSpan = entry.calls[_currentCallNumber].revertSpan;

            if (revertSpan == 0) {
                CrossChainCall memory cc = entry.calls[_currentCallNumber];
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
                entry.calls[_currentCallNumber].revertSpan = 0;

                try this.executeInContextAndRevert(revertSpan) {}
                catch (bytes memory revertData) {
                    (_rollingHash, _lastNestedActionConsumed, _currentCallNumber) = _decodeContextResult(revertData);
                }

                entry.calls[savedCallNumber].revertSpan = revertSpan;
                emit RevertSpanExecuted(_currentEntryIndex, savedCallNumber, revertSpan);
                processed += revertSpan;
            }
        }
    }

    /// @notice Executes calls in an isolated context that always reverts
    function executeInContextAndRevert(uint256 callCount) external {
        if (msg.sender != address(this)) revert NotSelf();
        _processNCalls(callCount);
        revert ContextResult(_rollingHash, _lastNestedActionConsumed, _currentCallNumber);
    }

    /// @notice Decodes a ContextResult revert payload
    function _decodeContextResult(bytes memory revertData)
        internal
        pure
        returns (bytes32 rollingHash, uint256 naConsumed, uint256 callNumber)
    {
        if (bytes4(revertData) != ContextResult.selector) revert UnexpectedContextRevert(revertData);
        assembly {
            let ptr := add(revertData, 36)
            rollingHash := mload(ptr)
            naConsumed := mload(add(ptr, 32))
            callNumber := mload(add(ptr, 64))
        }
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

    /// @notice Returns true if currently inside a cross-chain call execution
    function _insideExecution() internal view returns (bool) {
        return _currentCallNumber != 0;
    }

    // ──────────────────────────────────────────────
    //  CrossChainProxy creation
    // ──────────────────────────────────────────────

    /// @notice Creates a new CrossChainProxy contract for an original address
    function createCrossChainProxy(address originalAddress, uint256 originalRollupId) external returns (address proxy) {
        return _createCrossChainProxyInternal(originalAddress, originalRollupId);
    }

    /// @notice Deploys a CrossChainProxy via CREATE2 and registers it as authorized
    function _createCrossChainProxyInternal(address originalAddress, uint256 originalRollupId)
        internal
        returns (address proxy)
    {
        bytes32 salt = keccak256(abi.encodePacked(originalRollupId, originalAddress));
        proxy = address(new CrossChainProxy{salt: salt}(address(this), originalAddress, originalRollupId));
        authorizedProxies[proxy] = ProxyInfo(originalAddress, uint64(originalRollupId));
        emit CrossChainProxyCreated(proxy, originalAddress, originalRollupId);
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
    ///         once any postBatch has touched this rollup (see `RollupBatchActiveThisBlock`).
    function setStateRoot(uint256 rollupId, bytes32 newStateRoot) external {
        if (msg.sender != rollups[rollupId].rollupContract) revert NotRollupContract();
        if (verificationByRollup[rollupId].lastVerifiedBlock == block.number) {
            revert RollupBatchActiveThisBlock(rollupId);
        }
        rollups[rollupId].stateRoot = newStateRoot;
        emit StateUpdated(rollupId, newStateRoot);
    }

    /// @notice Swap the manager contract for `rollupId`. Callable only by the current manager.
    /// @dev The OLD manager calls this to hand off authority. The new contract receives the
    ///      `rollupContractRegistered(rollupId)` callback so it learns its id; subsequent callbacks from
    ///      it pass the same id back. Locked out for the rest of the block once any postBatch
    ///      has touched this rollup. The registry makes no assumption about ownership inside
    ///      `newContract` — handoff legitimacy is the OLD manager's responsibility.
    function setRollupContract(uint256 rollupId, address newContract) external {
        if (msg.sender != rollups[rollupId].rollupContract) revert NotRollupContract();
        if (newContract == address(0) || newContract == address(this)) revert InvalidRollupContract();

        rollups[rollupId].rollupContract = newContract;
        IRollup(newContract).rollupContractRegistered(rollupId);

        emit RollupContractChanged(rollupId, msg.sender, newContract);
    }

    // ──────────────────────────────────────────────
    //  Lookup call lookup
    // ──────────────────────────────────────────────

    /// @notice Looks up a pre-computed lookup call result, scanning the transient table
    ///         first then the destination rollup's static queue
    /// @dev Matches by actionHash + current call number + last nested action consumed.
    ///      Consults `_transientLookupCalls` first (populated only while a postBatch is
    ///      executing its transient prefix) and falls through to the per-rollup
    ///      `lookupQueue` keyed by `proxyInfo.originalRollupId`. tload works in static
    ///      context, so the transient tracking variables used to compute the match keys
    ///      are readable.
    /// @dev TODO (perf): if a sub-batch has many lookup calls, the linear scan is O(n).
    ///      Idea: have the orchestrator sort `lookupCalls[]` by a derived key (e.g., the
    ///      lookup tuple `keccak256(actionHash, callNumber, lastNestedActionConsumed)`,
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
        bytes32 actionHash =
            _computeActionInputHash(destRid, proxyInfo.originalAddress, 0, callData, sourceAddress, MAINNET_ROLLUP_ID);

        uint64 callNum = uint64(_currentCallNumber);
        uint64 lastNA = uint64(_lastNestedActionConsumed);

        for (uint256 i = 0; i < _transientLookupCalls.length; i++) {
            LookupCall storage sc = _transientLookupCalls[i];
            if (sc.actionHash == actionHash && sc.callNumber == callNum && sc.lastNestedActionConsumed == lastNA) {
                return _resolveLookupCall(sc);
            }
        }
        LookupCall[] storage lookupQueue = verificationByRollup[destRid].lookupQueue;
        for (uint256 i = 0; i < lookupQueue.length; i++) {
            LookupCall storage sc = lookupQueue[i];
            if (sc.actionHash == actionHash && sc.callNumber == callNum && sc.lastNestedActionConsumed == lastNA) {
                return _resolveLookupCall(sc);
            }
        }

        revert ExecutionNotFound();
    }

    /// @notice Verifies and unpacks a matched lookup call entry
    function _resolveLookupCall(LookupCall storage sc) internal view returns (bytes memory) {
        if (sc.calls.length > 0) {
            bytes32 computedHash = _processNLookupCalls(sc.calls);
            if (computedHash != sc.rollingHash) revert RollingHashMismatch();
        }
        if (sc.failed) {
            bytes memory returnData = sc.returnData;
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return sc.returnData;
    }

    /// @notice Executes calls in static context and computes a rolling hash of results
    function _processNLookupCalls(CrossChainCall[] memory calls) internal view returns (bytes32 computedHash) {
        for (uint256 i = 0; i < calls.length; i++) {
            CrossChainCall memory cc = calls[i];
            address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
            (bool success, bytes memory retData) =
                sourceProxy.staticcall(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)));
            computedHash = _rollingHashStaticResult(computedHash, success, retData);
        }
    }

    // ──────────────────────────────────────────────
    //  Rolling hash
    // ──────────────────────────────────────────────
    //
    // The entry-level `_rollingHash` accumulator is updated at four event points during
    // entry execution: at the start and end of each top-level call, and at the start and
    // end of each nested-action frame. Each event is tagged with a domain byte
    // (CALL_BEGIN/CALL_END/NESTED_BEGIN/NESTED_END) so the same set of inputs can't collide
    // across event types. The final value is checked against `entry.rollingHash` in
    // `_applyAndExecute`. See CLAUDE.md §Rolling Hash for the full specification.
    //
    // Static-call sub-hashes (`_processNLookupCalls`) use a simpler, untagged formula
    // because they're verified against `LookupCall.rollingHash`, a separate accumulator.

    /// @notice Folds a CALL_BEGIN event into `_rollingHash` for the given call number.
    function _rollingHashCallBegin(uint256 callNumber) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_BEGIN, callNumber));
    }

    /// @notice Folds a CALL_END event into `_rollingHash`, including the call's observed
    ///         outcome (success flag + raw return/revert data).
    function _rollingHashCallEnd(uint256 callNumber, bool success, bytes memory retData) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_END, callNumber, success, retData));
    }

    /// @notice Folds a NESTED_BEGIN event into `_rollingHash` for the given nested-action
    ///         index (1-indexed).
    function _rollingHashNestedBegin(uint256 nestedNumber) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_BEGIN, nestedNumber));
    }

    /// @notice Folds a NESTED_END event into `_rollingHash` for the given nested-action
    ///         index (1-indexed).
    function _rollingHashNestedEnd(uint256 nestedNumber) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_END, nestedNumber));
    }

    /// @notice Folds a static sub-call result into a local accumulator. Pure: doesn't touch
    ///         `_rollingHash` because lookup calls are verified against
    ///         `LookupCall.rollingHash`, a separate per-LookupCall accumulator.
    function _rollingHashStaticResult(bytes32 prev, bool success, bytes memory retData)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(prev, success, retData));
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    /// @notice Computes the action input hash from individual fields. Same shape used both
    ///         when building the hash for a proxy-driven CALL (`executeCrossChainCall`) and
    ///         for a static lookup (`staticCallLookup`).
    function _computeActionInputHash(
        uint256 rollupId,
        address destination,
        uint256 value,
        bytes memory data,
        address sourceAddress,
        uint256 sourceRollup
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup));
    }

    /// @notice Binary-search membership check in a strictly-increasing array of rollup IDs
    function _containsRollup(uint256[] calldata sortedRollupIds, uint256 rollupId) internal pure returns (bool) {
        uint256 lo = 0;
        uint256 hi = sortedRollupIds.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            uint256 v = sortedRollupIds[mid];
            if (v == rollupId) return true;
            if (v < rollupId) lo = mid + 1;
            else hi = mid;
        }
        return false;
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice Last block at which `_rollupId` was verified by a postBatch call
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

    /// @notice Computes the deterministic CREATE2 address for a CrossChainProxy
    function computeCrossChainProxyAddress(address originalAddress, uint256 originalRollupId)
        public
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(originalRollupId, originalAddress));
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(CrossChainProxy).creationCode, abi.encode(address(this), originalAddress, originalRollupId)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
