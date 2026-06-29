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
///      The batch's leading `immediateEntryCount` entries are the IMMEDIATE prefix — entries executed
///      within this transaction rather than queued. It has two parts: (a) the leading run of L2Tx
///      entries (`proxyEntryHash == 0`) runs immediately straight from calldata (state deltas + flat calls +
///      rolling hash, one `_executeEntry` cycle per entry; never SSTOREd); (b) the rest are loaded into
///      `_transientExecutions` (semantically transient, cleared at end of every batch) and
///      `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` is invoked (when
///      msg.sender has code) so the caller — e.g. an account-abstraction entrypoint — can drive them
///      via cross-chain proxy calls within the same transaction.
///
///      The batch remainder (entries past `immediateEntryCount`) is published into
///      per-rollup queues keyed by `destinationRollupId` UNCONDITIONALLY — even if the meta
///      hook left transient entries unconsumed. Soundness backstop: every entry's
///      `StateDelta.currentState` is checked at consumption time, so any persistent entry
///      whose preconditions were lost with the dropped transient leftover simply fails its
///      `StateRootMismatch` check.
///
///      Deferred consumption: `executeCrossChainCall` (proxy entry) and `executeL2Txs(rid)` route
///      to `verificationByRollup[rid].executionQueue[cursor]` and advance the per-rollup cursor.
contract EEZ is EEZBase {
    // ──────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────

    /// @notice The rollup ID representing L1 mainnet
    uint64 public constant MAINNET_ROLLUP_ID = 0;

    // ──────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────

    /// @notice Counter for generating rollup IDs
    uint256 public rollupCounter;

    /// @notice Mapping from rollup ID to rollup configuration (state root + ether + manager pointer)
    /// @dev The rollupContract is the source of truth for "is this id registered" — a zero
    ///      rollupContract means the slot is unused. Callbacks from the manager pass the
    ///      rollupId explicitly and the registry validates `msg.sender == rollups[rid].rollupContract`,
    ///      so no reverse-lookup mapping is needed.
    mapping(uint64 rollupId => RollupConfig config) public rollups;

    /// @notice Per-rollup deferred queue + once-per-block guard
    mapping(uint64 rollupId => RollupVerification record) internal verificationByRollup;

    // ── Transient-BACKED storage (semantically transient, but plain storage) ──
    //
    // The meta-hook remainder of the batch's leading prefix lives here (not the persistent queues) to
    // save storage gas during intra-tx meta-hook consumption. Plain storage, since Solidity 0.8.34 lacks
    // `transient` for nested-dynamic reference types; all are `delete`d at the end of every
    // postAndVerifyBatch (SSTORE refunds). `_transientExecutions.length != 0` flags the meta-hook re-entry
    // window (see the `postAndVerifyBatch` guard); the leading L2Tx run executes entries straight from
    // calldata, so it stays empty until (and unless) the meta-hook remainder is loaded — the immediate L2Tx run's
    // own re-entry window is covered by `_insideExecution()` instead.
    // TODO: promote to real `transient` once Solidity supports it for these types.
    ExecutionEntry[] public _transientExecutions;
    StaticLookup[] public _transientStaticLookups;

    /// @notice The reentrant (L1→L2) table of the ONE immediate L2Tx entry currently executing —
    ///         the FIRST source `getExpectedL1toL2Calls()` consults, so it holds only the in-flight
    ///         entry's table (one at a time, not all the L2Txs at once) and is empty at every other time.
    /// @dev The immediate L2Tx run executes its entries straight from calldata and never SSTOREs them
    ///      whole (the point of the immediate L2Tx path); their other fields stay in memory. But a proxy re-entry
    ///      crosses an external boundary and can't see `_executeEntry`'s memory, so this one array is
    ///      parked in storage for the duration of the entry. Lifecycle (in `_attemptExecuteImmediateL2Txs`): pushed
    ///      from the calldata entry before `_executeEntry`, `delete`d right after it — so it never carries
    ///      more than the current entry's table. Commonly empty (most L2Txs make no reentrant call). A
    ///      skipped (reverting) entry's pushes roll back with its self-call, so it is never observed
    ///      non-empty outside the immediate L2Tx run. The meta-hook and persistent phases route their reentrant
    ///      tables to `_transientExecutions` / the per-rollup queue instead, never here.
    ExpectedL1ToL2Call[] internal _expectedL1toL2CallsForImmediateL2Txs;

    /// @notice The rollups an entry may drive proxies for (its `stateDeltas` rollupIds): pushed at
    ///         execution start, `delete`d at the end. Doubles as `_insideExecution()` (non-empty ⇔
    ///         executing) and the proxy-protection set. Storage, not `transient` (no transient arrays);
    ///         reverts roll the pushes back.
    uint64[] internal _verifiedRollupInCurrentExecutingEntry;

    // ──────────────────────────────────────────────
    //  Transient state
    // ──────────────────────────────────────────────

    /// @notice Cursor for the next transient entry to consume (meaningful while
    ///         `_transientExecutions.length != 0`).
    // One GLOBAL cursor across all rollups. Meta-hook entries must be consumed in array order.
    uint256 transient _transientExecutionIndex;

    /// @notice Rollup whose persistent queue supplies the entry currently in `_executeEntry`, naming the
    ///         queue `getExpectedL1toL2Calls()` reads its reentrant table from. Set ONLY by
    ///         `_consumeAndExecuteEntry`'s persistent branch (to `destRid`) and cleared back to 0 there
    ///         once the entry finishes; 0 everywhere else (immediate L2Tx run and meta-hook phase, which route
    ///         their reentrant tables elsewhere).
    uint64 transient _currentEntryRollupId;

    /// @notice Forward-scan position into the entry's `expectedL1ToL2Calls`. MUST be transient —
    ///         `_consumeNestedCall` / `staticCallLookup` read it from fresh reentrant frames.
    ///         Saved/restored across a sub-frame.
    uint256 transient _lastL1ToL2CallConsumed;

    /// @notice Net ether flow for the current entry (`Σ inbound msg.value − Σ outbound call value`);
    ///         the accounting side of the ether-delta invariant (`Σ etherDelta == _entryEtherDelta`).
    /// @dev MUST be transient, not a local: a value call in a reentrant sub-frame runs in a separate
    ///      call stack, so a local outflow would be lost. revertNextNCalls / reverted-lookup frames
    ///      always revert, rolling back their contributions to match the physical ETH. Inbound is SET
    ///      at the top level / ADDED per reentrant call; reset at the end of `_executeEntry`.
    int256 transient _entryEtherDelta;

    /// @notice Emitted when a new rollup is created
    event RollupCreated(uint64 indexed rollupId, address indexed rollupContract, bytes32 initialState);

    /// @notice Emitted when a rollup state is updated (only via the registered rollupContract)
    event StateUpdated(uint64 indexed rollupId, bytes32 newStateRoot);

    /// @notice Emitted when an L2 execution is performed
    event L2ExecutionPerformed(uint64 indexed rollupId, bytes32 newState);

    /// @notice Emitted when an execution entry is consumed
    event ExecutionConsumed(
        bytes32 indexed crossChainCallHash, uint64 indexed rollupId, uint256 indexed executionQueueIndex
    );

    /// @notice Emitted when a precomputed L2 transaction is executed
    event L2TXExecuted(uint64 indexed rollupId);

    /// @notice Emitted when a batch is posted, carrying the number of rollups verified
    event BatchPosted(uint256 indexed rollupCount);

    /// @notice Emitted when an L2 tx entry's `_executeEntry` reverts during postAndVerifyBatch's
    ///         immediate L2Tx run. The entry's state changes are rolled back; the cursor advances
    ///         and the loop continues with the next L2 tx. `revertData` carries the inner
    ///         revert payload (custom error or message) for off-chain debugging.
    event L2TxSkipped(uint256 indexed transientIdx, bytes revertData);

    /// @notice Emitted after each call completes in `_processNCalls`.
    /// @dev Not emitted for calls inside a revertNextNCalls (those events are rolled back by the revert).
    event CallResult(uint256 indexed entryIndex, uint256 indexed l2ToL1CallNumber, bool success, bytes returnData);

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
    error RollupBatchActiveThisBlock(uint64 rollupId);

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
    error StateRootMismatch(uint64 rollupId);

    /// @notice Error when execution is attempted in a different block than the last state update for that rollup
    error ExecutionNotInCurrentBlock(uint64 rollupId);

    /// @notice Error when executeL2Txs is called while already inside a cross-chain execution
    error L2TXNotAllowedDuringExecution();

    /// @notice Error when the manager's `setStateRoot` escape hatch is invoked while a cross-chain
    ///         execution is in progress (e.g., the manager is reached via a cross-chain call that
    ///         tries to re-escape mid-flow).
    error SetStateRootNotAllowedDuringExecution();

    /// @notice Error when `immediateEntryCount` exceeds the entry count
    error ImmediateCountExceedsEntries();

    /// @notice Error when `immediateStaticLookupCount` exceeds the lookup call count
    error ImmediateStaticLookupCountExceedsStaticLookups();

    /// @notice Error when immediate static lookups come without any immediate entries (unreachable —
    ///         no entries means no immediate L2Tx run and no meta hook, so nothing can consume them)
    error ImmediateStaticLookupsWithoutImmediateEntries();

    /// @notice Error when batch validation fails for malformed inputs
    error InvalidProofSystemConfig();

    /// @notice Error when duplicate / unsorted proof systems are submitted in the batch
    error DuplicateProofSystem(address proofSystem);

    /// @notice Error when an entry's destinationRollupId, a state delta's rollupId, or a
    ///         lookup call's destinationRollupId references a rollup not in the batch
    error RollupNotInBatch(uint64 rollupId);

    /// @notice Error when not all L2→L1 calls (`entry.l2ToL1Calls`) were consumed after execution
    error UnconsumedL2ToL1Calls();

    /// @notice A `revertNextNCalls` span declares more calls than remain in its array (malformed entry).
    error RevertSpanOutOfBounds(uint256 start, uint256 span, uint256 length);

    /// @notice A reentrant call resolved with no host entry: an immediate L2Tx with an empty parked table
    ///         reaches `getExpectedL1toL2Calls()` with `_currentEntryRollupId == 0`. Cannot match — graceful revert.
    error NoExpectedL1ToL2CallFound();

    /// @notice Proxy protection (postAndVerifyBatch): a top-level lookup's `destinationRollupId` is
    ///         not among its own `expectedStateRoots` pins — the routing target must be pinned to
    ///         proven state (mirrors the entry `destination ∈ stateDeltas` rule).
    error LookupDestinationNotPinned(uint64 rollupId);

    /// @notice Proxy protection (RUNTIME): an L2→L1 call's source rollup isn't in the executing
    ///         entry's allowed set (its `stateDeltas`). Also covers a static lookup's sub-call
    ///         sources at validation time (∉ its `expectedStateRoots` pins).
    error CallSourceNotVerified(uint64 rollupId);

    /// @notice Proxy protection (RUNTIME): a reentrant / static-read call targets a rollup not in the
    ///         executing entry's allowed set.
    error ReentrantDestinationNotVerified(uint64 rollupId);

    /// @notice An entry's `stateDeltas` are not strictly increasing by `rollupId`. The strict order
    ///         rejects duplicate rollups (which would let one entry apply two transitions to the same
    ///         rollup) and, starting above MAINNET_ROLLUP_ID, also rejects a mainnet (L1) delta.
    error StateDeltasNotStrictlyIncreasing(uint64 rollupId);

    /// @notice An entry carries no `stateDeltas` — it would be unpinned from the `StateRootMismatch`
    ///         backstop, so it's rejected at validation.
    error EntryHasNoStateDeltas();

    /// @notice An entry's `destinationRollupId` (the queue it routes to) is not among its own
    ///         `stateDeltas` — so it could be parked in a non-participating rollup's queue. Rejected
    ///         at validation: the routing target must be a rollup this entry actually proved.
    error EntryDestinationNotInStateDeltas(uint64 rollupId);

    /// @notice A top-level lookup's `expectedStateRoots` pins are not strictly increasing by
    ///         `rollupId`. Same rationale as `StateDeltasNotStrictlyIncreasing`: rejects duplicate
    ///         pins and (bounding above MAINNET_ROLLUP_ID) a mainnet (L1) pin.
    error ExpectedStateRootsNotStrictlyIncreasing(uint64 rollupId);

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
    function registerRollup(address rollupContract, bytes32 initialState) external returns (uint64 rollupId) {
        if (rollupContract == address(0) || rollupContract == address(this)) revert InvalidRollupContract();

        // Sequential ids stay well below 2^64 — required: ProxyInfo.originalRollupId narrows to uint64.
        rollupId = uint64(++rollupCounter);
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

    /// @notice Posts a batch attested by ≥ threshold proof systems per rollup, then runs / queues
    ///         its execution entries.
    /// @dev Steps: (1) validate structure, (2) fetch per-rollup vkeys, (3) verify all proofs
    ///      atomically, (4) mark rollups verified-this-block, (5+6) run the leading L2Tx
    ///      (`proxyEntryHash == 0`) entries immediately, straight from calldata, (7) fire the meta hook —
    ///      load the remaining transient-prefix entries and trigger `msg.sender`'s hook (if it has code)
    ///      to consume them, presumably via account abstraction, (8) clear transient tables, (9) publish
    ///      the remainder executions to per-rollup queues. See the inline comments for the per-step rationale.
    /// @param batch entries, static lookups, per-rollup PS subsets, proofs, transient prefix bounds,
    ///        and the L1 `blockNumber` the batch binds to.
    function postAndVerifyBatch(ProofSystemBatchPerVerificationEntries calldata batch) external {
        // Reentrancy guard: block a nested `postAndVerifyBatch` (e.g. from the meta hook, or from an
        // immediate L2Tx's proxy target) so it can't corrupt the shared transient tables. The two flags
        // cover every window in which a STATE-MUTATING external call is in flight: `_insideExecution()`
        // during the immediate L2Tx run AND any executing entry, `_transientExecutions.length != 0` during
        // the meta hook. The remaining external calls before the immediate L2Tx run
        // (`checkProofSystemsAndGetVkeys`, `getCustomData`, `verify`) are all `view`/STATICCALL, so a
        // reentrant batch (which SSTOREs immediately) can't survive there regardless
        // If in a future there are allowed reentranat calls, e.g making getCustomData non-view, we might need an explicit mutex
        if (_insideExecution() || _transientExecutions.length != 0) revert PostBatchReentry();

        // 1. Structural validation (sorting, registration, membership, bounds). No external calls.
        _validateBatchStructure(batch);

        // 2. Fetch per-rollup vkeys. Each manager enforces its own threshold + per-PS membership in
        //    `checkProofSystemsAndGetVkeys`. The call is `view` (STATICCALL), so it can't reenter.
        bytes32[][] memory verificationKeysPerRollup = _getVerificationKeysPerRollup(batch);

        // 3. Verify every proof atomically (any failure reverts the batch) BEFORE any state mutation.
        //    Safe to run before `_markVerifiedBlockAndDeletePreviousEntries` since verification is read-only.
        _verifyProofSystemBatch(batch, verificationKeysPerRollup);

        // 4. Mark touched rollups verified-this-block by setting `lastVerifiedBlock = block.number`.
        //    This both records that the rollup was verified in this block and opens the read gate
        //    (`lastVerifiedBlock == block.number`) that later proxy calls / the meta hook check.
        for (uint256 r = 0; r < batch.rollupIdsWithProofSystems.length; r++) {
            _markVerifiedBlockAndDeletePreviousEntries(batch.rollupIdsWithProofSystems[r].rollupId);
        }

        // 5+6. Drain the LEADING run of L2Tx entries (`proxyEntryHash == 0`) straight from the batch
        //    calldata — no full-entry SSTORE; only each entry's reentrant table is parked transiently
        //    (see `_attemptExecuteImmediateL2Txs`). Each runs in a `try/catch` self-call so a revert rolls
        //    back only that entry and the loop continues, emitting `L2TxSkipped`. If a later entry
        //    depended on a skipped one, it will fail its own `StateRootMismatch` check at consumption
        //    (its expected pre-state no longer holds). Stop at the first non-L2Tx entry.
        uint256 immediateEntryCount = batch.immediateEntryCount;
        uint256 i = 0;
        for (; i < immediateEntryCount; i++) {
            // Check if next entry is a l2Tx
            if (batch.entries[i].proxyEntryHash != bytes32(0)) break;

            // Attempt to execute L2txs (the loop index `i` still labels the L2TxSkipped event)
            try this._attemptExecuteImmediateL2Txs(batch.entries[i]) {}
            catch (bytes memory revertData) {
                emit L2TxSkipped(i, revertData);
            }
        }

        // 7. Meta hook — if transient-prefix entries remain past the leading L2Tx run and the caller has
        //    code, load the remainder (entries[i..immediateEntryCount] plus the static-lookup
        //    pool) into the transient tables and let the caller drive them via proxy calls.
        // TODO(review): EOA poster silently drops middle immediate-prefix entries. When the caller has
        //   NO code, this block is skipped, so entries[i..immediateEntryCount) are neither executed
        //   here NOR queued by _saveRemainderExecutions (which starts at immediateEntryCount) — they
        //   are dropped. Proven entries should not vanish based on whether msg.sender is a contract.
        //   Decide: revert when (i < immediateEntryCount && code.length == 0), or fall back to queuing
        //   the unconsumed slice.
        if (i < immediateEntryCount && msg.sender.code.length > 0) {
            for (uint256 j = i; j < immediateEntryCount; j++) {
                _transientExecutions.push(batch.entries[j]);
            }
            for (uint256 j = 0; j < batch.immediateStaticLookupCount; j++) {
                _transientStaticLookups.push(batch.staticLookups[j]);
            }
            IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions();
        }

        // 8. Save the remaining executions to their per-rollup queues, unconditionally. Each entry
        //    records its expected pre-state in `StateDelta.currentState`, which is re-checked when the
        //    entry is consumed. So even if an entry is queued whose preconditions no longer hold (e.g.
        //    its dependency was a transient leftover that got dropped), it simply reverts with
        //    `StateRootMismatch` at consumption instead of executing incorrectly.
        _saveRemainderExecutions(batch);

        // 9. Clear the transient tables. Emptying `_transientExecutions` also closes the re-entry window
        //    (the guard keys off its length). Unconsumed transient leftovers are dropped (they were never
        //    persisted — the remainder saved above is a separate set of entries).
        delete _transientExecutions;
        delete _transientStaticLookups;
        _transientExecutionIndex = 0;

        emit BatchPosted(batch.rollupIdsWithProofSystems.length);
    }

    // ──────────────────────────────────────────────
    //  postAndVerifyBatch internals
    // ──────────────────────────────────────────────

    /// @notice Self-call wrapper that runs ONE leading immediate L2Tx entry, straight from the batch
    ///         calldata, in an isolated frame. Used by `postAndVerifyBatch` step 5+6 to make the immediate
    ///         L2Tx execution revertible: if this frame reverts, the surrounding `try/catch` in
    ///         postAndVerifyBatch catches and skips to the next entry instead of aborting the whole batch.
    ///         Unlike `executeInContextAndRevert`, this propagates the inner result — succeeds when
    ///         `_executeEntry` succeeds, reverts when it reverts.
    /// @dev The full entry is NEVER SSTOREd. Only its reentrant table is parked in
    ///      `_expectedL1toL2CallsForImmediateL2Txs` (commonly empty) so a proxy re-entry during this entry can
    ///      resolve against it via `getExpectedL1toL2Calls()`; it is cleared on success and rolls back
    ///      with the frame on a skip. Neither `_currentEntryIndex` nor `_currentEntryRollupId` is set
    ///      here: the immediate L2Tx run precedes any `_consumeAndExecuteEntry` (which leaves both 0 on exit), so
    ///      both are already 0 — the immediate L2Tx reentrant table comes from
    ///      `_expectedL1toL2CallsForImmediateL2Txs`, not an index into a queue. Consequence: this entry's
    ///      events (`EntryExecuted` / `CallResult`) log `entryIndex == 0`.
    function _attemptExecuteImmediateL2Txs(ExecutionEntry calldata entry) public {
        if (msg.sender != address(this)) revert NotSelf();
        if (_entryEtherDelta != 0) revert ResidualEntryEtherIn(); // L2Tx entries receive no inbound value

        // Park the reentrant table while `_transientExecutions` stays empty (the signal that the immediate L2Tx run is active).
        for (uint256 k = 0; k < entry.expectedL1ToL2Calls.length; k++) {
            _expectedL1toL2CallsForImmediateL2Txs.push(entry.expectedL1ToL2Calls[k]);
        }

        _executeEntry(entry);

        delete _expectedL1toL2CallsForImmediateL2Txs;
    }

    /// @notice Structural validation of the batch — no external calls, no vkey reads.
    /// @dev Checks PS/rollup sorting + registration, per-rollup PS-index ranges, and transient prefix
    ///      bounds. Crucially, it also enforces PROXY PROTECTION: every rollup an entry/lookup touches
    ///      — its `destinationRollupId` plus every cross-chain call's source/target rollup — must be in
    ///      that entry's proven set (its `stateDeltas`, or the lookup's `expectedStateRoots` pins), so
    ///      every proxy driven at execution is backed by a verified rollup.
    function _validateBatchStructure(ProofSystemBatchPerVerificationEntries calldata batch) internal view {
        uint256 psLen = batch.proofSystems.length;
        if (psLen == 0) revert InvalidProofSystemConfig();
        if (psLen != batch.proofs.length) revert InvalidProofSystemConfig();
        if (batch.rollupIdsWithProofSystems.length == 0) revert InvalidProofSystemConfig();

        // proofSystems strictly increasing by address (rejects address(0) + duplicates). There's no
        // central PS registry; each rollup's manager picks its accepted SUBSET via `proofSystemIndexes[]`.
        address prevPs = address(0);
        for (uint256 k = 0; k < psLen; k++) {
            address ps = batch.proofSystems[k];
            if (uint160(ps) <= uint160(prevPs)) revert DuplicateProofSystem(ps);
            prevPs = ps;
        }

        // Per-rollup: rollupIds strictly increasing (rejects same-rid-twice and MAINNET), each
        // registered, and each `proofSystemIndexes[]` strictly increasing within `[0, psLen)` (unique,
        // in-range — so the on-chain resolution to PS addresses is dedup'd).
        uint64 prevRid = MAINNET_ROLLUP_ID;
        for (uint256 r = 0; r < batch.rollupIdsWithProofSystems.length; r++) {
            RollupIdWithProofSystems calldata rollupInfoPerVerification = batch.rollupIdsWithProofSystems[r];
            if (rollupInfoPerVerification.rollupId <= prevRid) revert InvalidProofSystemConfig();
            if (rollups[rollupInfoPerVerification.rollupId].rollupContract == address(0)) {
                revert InvalidProofSystemConfig();
            }
            prevRid = rollupInfoPerVerification.rollupId;

            uint64[] calldata indices = rollupInfoPerVerification.proofSystemIndexes;
            if (indices.length == 0) revert InvalidProofSystemConfig();
            uint256 prevIdx;
            for (uint256 j = 0; j < indices.length; j++) {
                uint256 idx = uint256(indices[j]);
                if (idx >= psLen) revert InvalidProofSystemConfig();
                if (j > 0 && idx <= prevIdx) revert InvalidProofSystemConfig();
                prevIdx = idx;
            }
        }

        // Per entry: `stateDeltas` (≥1, strictly increasing, all ∈ batch), `destinationRollupId` ∈ deltas,
        // and every call SOURCE ∈ deltas. Sources are fail-fast here; reentrant TARGETS carry no rollup
        // field, so they stay a RUNTIME check (`_isRollupAllowed`) — together they replace the old static walk.
        for (uint256 i = 0; i < batch.entries.length; i++) {
            ExecutionEntry calldata entry = batch.entries[i];
            StateDelta[] calldata deltas = entry.stateDeltas;
            if (deltas.length == 0) revert EntryHasNoStateDeltas(); // must be state-pinned to the backstop

            uint64[] memory verifiedRollups = new uint64[](deltas.length);
            uint64 prevDeltaRid = MAINNET_ROLLUP_ID;
            for (uint256 j = 0; j < deltas.length; j++) {
                uint64 drid = deltas[j].rollupId;
                if (drid <= prevDeltaRid) revert StateDeltasNotStrictlyIncreasing(drid);
                if (!_containsRollupInBatch(batch, drid)) revert RollupNotInBatch(drid);
                verifiedRollups[j] = drid;
                prevDeltaRid = drid;
            }
            // Route only into a proven rollup's queue — else `_saveRemainderExecutions` could park the
            // entry in a non-participating queue. (Mirrors the lookup `destinationRollupId ∈ pins` check.)
            uint64 destRid = entry.destinationRollupId;
            if (!_containsRollupInList(verifiedRollups, destRid)) revert EntryDestinationNotInStateDeltas(destRid);

            // Every call SOURCE proven — top-level calls + each reentrant frame's sub-calls. Flat
            // double-loop: reverted frames reuse the host table, so there's no deeper nesting to recurse.
            L2ToL1Call[] calldata topCalls = entry.l2ToL1Calls;
            for (uint256 j = 0; j < topCalls.length; j++) {
                if (!_containsRollupInList(verifiedRollups, topCalls[j].sourceRollupId)) {
                    revert CallSourceNotVerified(topCalls[j].sourceRollupId);
                }
            }
            ExpectedL1ToL2Call[] calldata reentrant = entry.expectedL1ToL2Calls;
            for (uint256 j = 0; j < reentrant.length; j++) {
                L2ToL1Call[] calldata subCalls = reentrant[j].l2ToL1Calls;
                for (uint256 k = 0; k < subCalls.length; k++) {
                    if (!_containsRollupInList(verifiedRollups, subCalls[k].sourceRollupId)) {
                        revert CallSourceNotVerified(subCalls[k].sourceRollupId);
                    }
                }
            }
        }

        // Same shape for static lookups: the verified set is the rollups they pin
        // (`expectedStateRoots`, validated strictly-increasing); `destinationRollupId` must be pinned,
        // and the read-only sub-call sources must be in the set (a static lookup has no reentrant table).
        for (uint256 i = 0; i < batch.staticLookups.length; i++) {
            StaticLookup calldata staticLookup = batch.staticLookups[i];
            ExpectedStateRootPerRollup[] calldata expectedStateRoots = staticLookup.expectedStateRoots;
            uint64[] memory verifiedRollups = new uint64[](expectedStateRoots.length);
            uint64 prevPinRid = MAINNET_ROLLUP_ID;
            for (uint256 j = 0; j < expectedStateRoots.length; j++) {
                uint64 prid = expectedStateRoots[j].rollupId;
                if (prid <= prevPinRid) revert ExpectedStateRootsNotStrictlyIncreasing(prid);
                if (!_containsRollupInBatch(batch, prid)) revert RollupNotInBatch(prid);
                verifiedRollups[j] = prid;
                prevPinRid = prid;
            }
            if (!_containsRollupInList(verifiedRollups, staticLookup.destinationRollupId)) {
                revert LookupDestinationNotPinned(staticLookup.destinationRollupId);
            }
            L2ToL1Call[] calldata lcCalls = staticLookup.l2ToL1Calls;
            for (uint256 j = 0; j < lcCalls.length; j++) {
                if (!_containsRollupInList(verifiedRollups, lcCalls[j].sourceRollupId)) {
                    revert CallSourceNotVerified(lcCalls[j].sourceRollupId);
                }
            }
        }

        // Transient prefix bounds. Reject the dead-weight shape (lookups without entries) — the
        // transient lookup pool is only reachable while transient entries are mid-flight.
        if (batch.immediateEntryCount > batch.entries.length) revert ImmediateCountExceedsEntries();
        if (batch.immediateStaticLookupCount > batch.staticLookups.length) {
            revert ImmediateStaticLookupCountExceedsStaticLookups();
        }
        if (batch.immediateEntryCount == 0 && batch.immediateStaticLookupCount != 0) {
            revert ImmediateStaticLookupsWithoutImmediateEntries();
        }
    }

    /// @notice Fetches the (rollup × chosen-PS-subset) vkey matrix — one external call to
    ///         `checkProofSystemsAndGetVkeys` per rollup, passing only the rollup's chosen
    ///         PS subset (resolved from indices into the batch's global `proofSystems[]`).
    ///         The manager enforces its own threshold against `subset.length` and reverts if
    ///         any subset entry isn't an allowed PS for that rollup.
    /// @dev Returns a JAGGED matrix: `verificationKeysPerRollup[r].length == proofSystemIndexes[r].length`. The
    ///      element at `verificationKeysPerRollup[r][j]` is the vkey of `proofSystems[proofSystemIndexes[r][j]]`
    ///      for rollup r. `_verifyProofSystemBatch` projects this jagged matrix into per-PS
    ///      vkey vectors when building each PS's publicInputsHash.
    function _getVerificationKeysPerRollup(ProofSystemBatchPerVerificationEntries calldata batch)
        internal
        view
        returns (bytes32[][] memory verificationKeysPerRollup)
    {
        verificationKeysPerRollup = new bytes32[][](batch.rollupIdsWithProofSystems.length);
        for (uint256 r = 0; r < batch.rollupIdsWithProofSystems.length; r++) {
            RollupIdWithProofSystems calldata rollupIdWithProofSystems = batch.rollupIdsWithProofSystems[r];
            uint64[] calldata proofSystemIndexes = rollupIdWithProofSystems.proofSystemIndexes;

            // Resolve indices into the batch's global PS list to PS addresses. Indices were
            // validated as in-range and strictly increasing in `_validateBatchStructure`, so the
            // resolved proofSystemUsed is itself strictly increasing — same invariant the manager's
            // `checkProofSystemsAndGetVkeys` relies on for its own membership / dedup logic.
            address[] memory proofSystemUsedByRollup = new address[](proofSystemIndexes.length);
            for (uint256 j = 0; j < proofSystemIndexes.length; j++) {
                proofSystemUsedByRollup[j] = batch.proofSystems[uint256(proofSystemIndexes[j])];
            }

            verificationKeysPerRollup[r] = IRollupContract(rollups[rollupIdWithProofSystems.rollupId].rollupContract)
                .checkProofSystemsAndGetVkeys(proofSystemUsedByRollup);
            // Manager must return exactly one vkey per resolved PS. Without this, a manager
            // returning a short array would OOB-panic when projected into per-PS vkey vectors;
            // a long array would silently ignore tail entries.
            if (verificationKeysPerRollup[r].length != proofSystemIndexes.length) revert InvalidProofSystemConfig();
        }
    }

    /// @notice Builds per-PS publicInputsHash and verifies every proof in the batch
    /// @dev Two-stage shape:
    ///        customDataHashes[r] = H(rollupId_r, customData_r)   // per-rollup, canonical order
    ///        sharedPublicInput = H(entryHashes, staticLookupHashes, blobHashes, H(callData), customDataHashes)
    ///      For each PS k we walk the rollupIdsWithProofSystems table in canonical order;
    ///      every rollup that lists k in its `proofSystemIndexes[]` folds into a per-PS
    ///      rolling accumulator one rollup at a time:
    ///        acc_k = bytes32(0)
    ///        for each rollup r with k ∈ proofSystemIndexes[r]:
    ///          acc_k = H(acc_k, rollupId_r, verificationKeysPerRollup[r][j])
    ///      Then `publicInputsHash[k] = H(sharedPublicInput, acc_k)`. Each rollup's
    ///      `customData` is fetched ONCE via `getCustomData` and folded into the SHARED input
    ///      (it doesn't vary per PS), keyed by rollupId so the binding stays rollup-specific.
    function _verifyProofSystemBatch(
        ProofSystemBatchPerVerificationEntries calldata batch,
        bytes32[][] memory verificationKeysPerRollup
    )
        internal
        view
    {
        // Selected blob hashes (indexed into the tx-level blob set)
        bytes32[] memory blobHashes = new bytes32[](batch.blobIndices.length);
        for (uint256 i = 0; i < batch.blobIndices.length; i++) {
            blobHashes[i] = blobhash(batch.blobIndices[i]);
        }

        // Per-entry hash binds the FULL entry content (stateDeltas, proxyEntryHash, destinationRollupId,
        // l2ToL1Calls[], the unified expectedL1ToL2Calls[], returnData, rollingHash) — so an orchestrator
        // can't swap calls / results at execution time without invalidating the proof.
        bytes32[] memory entryHashes = new bytes32[](batch.entries.length);
        for (uint256 i = 0; i < batch.entries.length; i++) {
            entryHashes[i] = keccak256(abi.encode(batch.entries[i]));
        }

        // Per-lookup-call hash, same rationale.
        bytes32[] memory staticLookupHashes = new bytes32[](batch.staticLookups.length);
        for (uint256 i = 0; i < batch.staticLookups.length; i++) {
            staticLookupHashes[i] = keccak256(abi.encode(batch.staticLookups[i]));
        }

        // Per-rollup customData hash, keyed by rollupId. Each blob
        // is fetched ONCE via a `view` STATICCALL (a malicious manager cannot reenter).
        uint256 rollupCount = batch.rollupIdsWithProofSystems.length;
        bytes32[] memory customDataHashes = new bytes32[](rollupCount);
        for (uint256 r = 0; r < rollupCount; r++) {
            bytes memory customData = IRollupContract(
                    rollups[batch.rollupIdsWithProofSystems[r].rollupId].rollupContract
                ).getCustomData(batch.blockNumber);
            // Keyed by rollupId so each blob is bound to its rollup; provers must mirror this.
            customDataHashes[r] = keccak256(abi.encode(batch.rollupIdsWithProofSystems[r].rollupId, customData));
        }

        bytes32 sharedPublicInput = keccak256(
            abi.encodePacked(
                abi.encode(entryHashes),
                abi.encode(staticLookupHashes),
                abi.encode(blobHashes),
                keccak256(batch.callData),
                abi.encode(customDataHashes) // per-rollup customData; shared across all PS
            )
        );

        // Per-PS verification — for each PS k, walk attesting rollups in canonical order
        // (rollupId-ascending, the order the batch enforces) and fold each rollup's
        // (rollupId, vkey_for_PS_k) into a rolling accumulator. Off-chain provers MUST mirror
        // this incremental scheme so the on-chain rebuild matches.
        for (uint256 k = 0; k < batch.proofSystems.length; k++) {
            bytes32 accRollupsWithVerificationKeys = bytes32(0);
            for (uint256 r = 0; r < rollupCount; r++) {
                RollupIdWithProofSystems calldata rollupInfoPerVerification = batch.rollupIdsWithProofSystems[r];
                uint256 j = _findIndexPosition(rollupInfoPerVerification.proofSystemIndexes, k);
                if (j == type(uint256).max) continue;
                accRollupsWithVerificationKeys = keccak256(
                    abi.encode(
                        accRollupsWithVerificationKeys,
                        rollupInfoPerVerification.rollupId,
                        verificationKeysPerRollup[r][j]
                    )
                );
            }

            bytes32 publicInputsHash = keccak256(abi.encodePacked(sharedPublicInput, accRollupsWithVerificationKeys));

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
    function _markVerifiedBlockAndDeletePreviousEntries(uint64 rid) internal {
        RollupVerification storage rec = verificationByRollup[rid];
        rec.lastVerifiedBlock = uint64(block.number);
        // Wipe on every verify: a same-block verify replaces the queue.
        delete rec.executionQueue;
        delete rec.staticLookupQueue;
        rec.executionQueueIndex = 0;
    }

    /// @notice Publishes the batch remainder (entries past `immediateEntryCount`)
    ///         into per-rollup queues keyed by `destinationRollupId`
    function _saveRemainderExecutions(ProofSystemBatchPerVerificationEntries calldata batch) internal {
        for (uint256 i = batch.immediateEntryCount; i < batch.entries.length; i++) {
            uint64 destRid = batch.entries[i].destinationRollupId;
            verificationByRollup[destRid].executionQueue.push(batch.entries[i]);
        }

        for (uint256 i = batch.immediateStaticLookupCount; i < batch.staticLookups.length; i++) {
            uint64 destRid = batch.staticLookups[i].destinationRollupId;
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
    /// @dev only callable by EEZ proxies
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return result The return data from the execution
    function executeCrossChainCall(address sourceAddress, bytes calldata callData)
        external
        payable
        returns (bytes memory result)
    {
        // Get EEZ proxy info from msg.sender
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];

        // Check msg.sender is EEZ proxy
        if (!proxyInfo.isProxy) revert UnauthorizedProxy();

        address destAddress = proxyInfo.originalAddress;
        uint64 destRid = proxyInfo.originalRollupId;

        // Entries can only be consumed in the block they were posted
        if (verificationByRollup[destRid].lastVerifiedBlock != uint64(block.number)) {
            revert ExecutionNotInCurrentBlock(destRid);
        }

        bytes32 crossChainCallHash = computeCrossChainCallHash(
            NOT_STATIC_CALL, sourceAddress, MAINNET_ROLLUP_ID, destAddress, destRid, msg.value, callData
        );

        emit CrossChainCallExecuted(crossChainCallHash, msg.sender, sourceAddress, callData, msg.value);

        if (_insideExecution()) {
            // Reentrant — ADD this call's value to the entry's net-ether accumulator
            _entryEtherDelta += int256(msg.value);
            return _consumeNestedCall(destRid, crossChainCallHash);
        }

        // Top-level: a fresh entry starts from exactly its own msg.value,
        // so residue can never leak across entries.
        _entryEtherDelta = int256(msg.value);
        return _consumeAndExecuteEntry(destRid, crossChainCallHash);
    }

    // ──────────────────────────────────────────────
    //  Execute precomputed L2 transaction
    // ──────────────────────────────────────────────

    /// @notice Executes the next pure-L2 transaction queued for `rollupId`
    /// @dev The next entry must have `proxyEntryHash == bytes32(0)`.
    ///      Cannot run while reentrantly inside another cross-chain execution.
    function executeL2Txs(uint64 rollupId) external returns (bytes memory result) {
        if (verificationByRollup[rollupId].lastVerifiedBlock != uint64(block.number)) {
            revert ExecutionNotInCurrentBlock(rollupId);
        }

        // This function is for starting L2 transactions, and cannot be called in the middle of another execution
        if (_insideExecution()) revert L2TXNotAllowedDuringExecution();

        // Non-payable and non mid-entry — a dirty _entryEtherDelta here is a bug.
        if (_entryEtherDelta != 0) revert ResidualEntryEtherIn();

        emit L2TXExecuted(rollupId);
        return _consumeAndExecuteEntry(rollupId, bytes32(0));
    }

    // ──────────────────────────────────────────────
    //  Internal execution
    // ──────────────────────────────────────────────

    /// @notice The reentrant (L1→L2) table of the entry currently being processed — the storage source a
    ///         proxy re-entry resolves against (it crosses an external boundary and can't see the
    ///         executing `_executeEntry`'s memory entry).
    /// @dev Three sources, in priority order:
    ///      (a) immediate L2Tx run — its entry never lands in storage, so only the table is parked in
    ///          `_expectedL1toL2CallsForImmediateL2Txs` (non-empty ONLY while such an entry runs);
    ///      (b) meta-hook — a batch is mid-flight, so the transient entry at `_currentEntryIndex`;
    ///      (c) normal proxy consumption (outside any batch) — the persistent queue entry of
    ///          `_currentEntryRollupId` at `_currentEntryIndex`.
    function getExpectedL1toL2Calls() internal view returns (ExpectedL1ToL2Call[] storage) {
        // (a) immediate L2Tx run
        if (_expectedL1toL2CallsForImmediateL2Txs.length != 0) {
            return _expectedL1toL2CallsForImmediateL2Txs;
        }
        // (b) meta-hook: batch mid-flight
        if (_transientExecutions.length != 0) {
            return _transientExecutions[_currentEntryIndex].expectedL1ToL2Calls;
        }
        // (c) normal proxy consumption: persistent queue. An immediate L2Tx whose parked table (a) is EMPTY
        // yet still makes a reentrant call reaches here with `_currentEntryRollupId == 0` (never a real queue);
        // the call could not have matched, so revert gracefully instead of OOB-panicking on the empty queue.
        if (_currentEntryRollupId == 0) revert NoExpectedL1ToL2CallFound();
        return verificationByRollup[_currentEntryRollupId].executionQueue[_currentEntryIndex].expectedL1ToL2Calls;
    }

    /// @notice Resolves a reentrant (L1→L2) CALL: a plain-success entry consumed from
    ///         `expectedL1ToL2Calls`, or a reverted entry run as a sub-execution.
    /// @dev Entries are content-addressed by `expectedL1toL2Hash == keccak256(crossChainCallHash, _rollingHash)`,
    ///      where `_rollingHash` folds every prior call and nesting boundary, so it uniquely pins the
    ///      execution point. The scan walks STRICT FORWARD from `_lastL1ToL2CallConsumed` (calls are
    ///      consumed in order, never before the cursor); the first match IS the entry, and its `success`
    ///      flag selects the path in `_resolveNestedReentrant` (commit vs run-and-revert). The key is
    ///      unique per position, so a success and a reverted entry can never share one. Static entries
    ///      can't match here — their `crossChainCallHash` folds `isStatic = true`, while this lookup is
    ///      keyed with `isStatic = false`; the proxy routes reentrant STATICCALLs to `staticCallLookup`.
    ///      On no match, `_rollingHashCallNotFound` folds CALL_NOT_FOUND so the entry reverts at its
    ///      rolling-hash check (`RollingHashMismatch`). Completeness of the success entries rests on that
    ///      hash, not a table-length check: a skipped success entry omits its NESTED frame, diverging the
    ///      hash; an unconsumed entry is inert.
    function _consumeNestedCall(uint64 destRid, bytes32 crossChainCallHash) internal returns (bytes memory) {
        // Proxy protection: the reentrant call's target rollup must be in the entry's proven set.
        if (!_isRollupAllowed(destRid)) revert ReentrantDestinationNotVerified(destRid);

        // Host table is the current entry's `expectedL1ToL2Calls`; a reverted sub-execution shares it
        // for its own reentrant calls, disambiguated by the `_rollingHash` folded into the key.
        ExpectedL1ToL2Call[] storage expectedCalls = getExpectedL1toL2Calls();
        bytes32 expectedL1toL2Hash = _computeExpectedL1toL2Hash(crossChainCallHash, _rollingHash);

        for (uint256 i = _lastL1ToL2CallConsumed; i < expectedCalls.length; i++) {
            ExpectedL1ToL2Call storage expectedL1ToL2Call = expectedCalls[i];
            if (expectedL1ToL2Call.expectedL1toL2Hash == expectedL1toL2Hash) {
                // Advance the cursor PAST this match before resolving it
                _lastL1ToL2CallConsumed = i + 1;
                return _resolveNestedReentrant(expectedL1ToL2Call, crossChainCallHash);
            }
        }

        // No match: CALL_NOT_FOUND is a distinct tag from the CALL_END(true, "") folded for a normal
        // empty return, so it can't be forged as one. The hash divergence is what the entry boundary
        // checks and it rides the `ContextResult` payload across a revert-span boundary, so it survives
        // any intermediate try/catch.
        _rollingHashCallNotFound(crossChainCallHash);
        return "";
    }

    /// @notice Resolves a matched reentrant (L1→L2) CALL by running its OWN `l2ToL1Calls[]` sub-array.
    /// @dev Takes the matched entry by `storage` pointer (the caller already resolved + indexed it, and
    ///      advanced `_lastL1ToL2CallConsumed` past it). SUCCESS commits the sub-execution into the host's
    ///      continuous `_rollingHash` (NESTED_END) and returns `returnData`. REVERTED checks the sub-hash
    ///      against `expectedL1toL2Call.revertedOrStaticRollingHash` and reverts with `returnData`; the
    ///      terminal revert rolls back the frame's state, hash, and cursor (no save needed).
    function _resolveNestedReentrant(ExpectedL1ToL2Call storage expectedL1toL2Call, bytes32 crossChainCallHash)
        internal
        returns (bytes memory)
    {
        L2ToL1Call[] memory l2ToL1Calls = expectedL1toL2Call.l2ToL1Calls;

        // Open the frame and run the sub-array (cursor already advanced by the caller, so the sub-frame's
        // own reentrant calls scan strictly forward).
        _rollingHashNestedBegin(crossChainCallHash);
        _processNCalls(l2ToL1Calls);

        if (expectedL1toL2Call.success) {
            // Updates the rolling hash closing the nested call
            _rollingHashNestedEnd();
            return expectedL1toL2Call.returnData;
        } else {
            // It reverts with the expected saved revert data only if expecting rolling hash matches
            if (_rollingHash != expectedL1toL2Call.revertedOrStaticRollingHash) revert RollingHashMismatch();
            bytes memory returnData = expectedL1toL2Call.returnData;
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    /// @notice Consumes the next execution entry, applies state deltas, executes calls, and verifies rolling hash
    /// @dev Consults the transient table first ("always look for transient calls before storage calls").
    ///      While a postAndVerifyBatch call is running, `_transientExecutions` is non-empty and ALL consumption
    ///      is routed through it via a global cursor — entries are NOT popped, only `_transientExecutionIndex`
    ///      advances. Because that cursor is GLOBAL (not per-rollup), the transient branch also requires
    ///      `destinationRollupId == destRid`: the block gate passes for any rollup verified this block
    ///      (including by an earlier batch), and `proxyEntryHash == 0` (executeL2Txs) carries no rollup
    ///      binding of its own. Outside the transient batch, consumption is routed by the destination
    ///      rollup to `verificationByRollup[destRid].executionQueue` with that rollup's own cursor —
    ///      there `destinationRollupId` is consistent by construction (entries are published under it).
    ///
    ///      Miss path: when the cursor is out of bounds or the entry doesn't fully match
    ///      (`_entryMatches`: identity, routing, or a stale `currentState`), we revert
    ///      `ExecutionNotFound`. There is no reverted-top-level fallback — top-level reverting calls
    ///      are normal entries, and the static pool (`StaticLookup`) is read-only (`staticCallLookup`).
    /// @param destRid The destination rollup whose queue / transient slot to consume from
    /// @param crossChainCallHash The expected action input hash for the next entry
    /// @return result The pre-computed return data from the action
    function _consumeAndExecuteEntry(uint64 destRid, bytes32 crossChainCallHash)
        internal
        returns (bytes memory result)
    {
        ExecutionEntry storage entry;
        uint256 idx;

        // Scan forward from the cursor to the first matching entry (skipping non-matches; see
        // `_entryMatches`).
        if (_transientExecutions.length != 0) {
            idx = _findMatchingEntry(_transientExecutions, _transientExecutionIndex, crossChainCallHash, destRid);
            _transientExecutionIndex = idx + 1;
            entry = _transientExecutions[idx];
        } else {
            RollupVerification storage rec = verificationByRollup[destRid];
            idx = _findMatchingEntry(rec.executionQueue, rec.executionQueueIndex, crossChainCallHash, destRid);
            rec.executionQueueIndex = uint64(idx + 1);
            entry = rec.executionQueue[idx];
            _currentEntryRollupId = destRid; // the queue getExpectedL1toL2Calls() reads this
        }

        emit ExecutionConsumed(crossChainCallHash, destRid, idx);

        _currentEntryIndex = idx;
        _executeEntry(entry);

        // Reset the entry pointers now the entry is done. `_currentEntryRollupId = 0` is load-bearing
        // (the immediate L2Tx path relies on it being 0); `_currentEntryIndex = 0` is hygiene/symmetry —
        // it's only read mid-`_executeEntry` and always re-set before the next read. On a revert both
        // transient writes roll back to 0 anyway.
        _currentEntryRollupId = 0;
        _currentEntryIndex = 0;

        return entry.returnData;
    }

    /// @notice Forward-scans `executionQueue` from `startIndex` for the FIRST entry that matches
    ///         `crossChainCallHash` and `destRid` (see `_entryMatches`), returning its index. Reverts
    ///         `ExecutionNotFound` if the scan reaches the end of the queue with no match.
    /// @dev Skipping intervening non-matches is what lets a top-level call reach past already-attempted
    ///      failed entries (whose reverts left the cursor where it was). A skipped entry simply never
    ///      executes — anything depending on it later fails its own `currentState` check.
    function _findMatchingEntry(
        ExecutionEntry[] storage executionQueue,
        uint256 startIndex,
        bytes32 crossChainCallHash,
        uint64 destRid
    )
        internal
        view
        returns (uint256)
    {
        uint256 queueLen = executionQueue.length;
        for (uint256 i = startIndex; i < queueLen; i++) {
            if (_entryMatches(executionQueue[i], crossChainCallHash, destRid)) {
                return i;
            }
        }
        revert ExecutionNotFound();
    }

    /// @notice Whether the entry at the cursor is the right one to consume: its identity
    ///         (`proxyEntryHash`), routing (`destinationRollupId`), AND state preconditions (every
    ///         delta's `currentState` == the live root) all hold.
    /// @dev `destinationRollupId == destRid` is load-bearing in the transient branch (one global
    ///      cursor across rollups); it holds by construction in the persistent branch (queue-routed),
    ///      so the check is harmless there. The `currentState` check makes a stale-state entry a
    ///      non-match (→ `ExecutionNotFound`); `_executeEntry` re-asserts it as the gate for the
    ///      immediate L2Tx path that doesn't pass through here.
    function _entryMatches(ExecutionEntry storage entry, bytes32 crossChainCallHash, uint64 destRid)
        internal
        view
        returns (bool)
    {
        if (entry.proxyEntryHash != crossChainCallHash) return false;
        if (entry.destinationRollupId != destRid) return false;
        StateDelta[] storage deltas = entry.stateDeltas;
        for (uint256 i = 0; i < deltas.length; i++) {
            if (rollups[deltas[i].rollupId].stateRoot != deltas[i].currentState) return false;
        }
        return true;
    }

    /// @notice Applies state deltas (with currentState validation), processes the entry's
    ///         top-level calls, verifies rolling hash, checks ether accounting.
    /// @dev `_entryEtherDelta` already holds the entry-point call's `msg.value` when we get here
    ///      (SET by the top-level entry point before consumption), so it is NOT reset in
    ///      this preamble — only at the end, after the invariant check.
    /// @dev The entry's `l2ToL1Calls[]` is its TOP-LEVEL calls only (each reentrant frame carries
    ///      its own sub-calls); `_processNCalls` runs the whole array, so completeness is structural
    ///      (no cursor-vs-length check). `_verifiedRollupInCurrentExecutingEntry` is non-empty for the whole span (backs
    ///      `_insideExecution()`), so a reentrant call is routed correctly.
    /// @dev The entry is taken by `memory` so a leading L2Tx can be executed straight from calldata
    ///      without SSTOREing the whole struct (see `_attemptExecuteImmediateL2Txs`). `entry.expectedL1ToL2Calls`
    ///      is NOT read here — proxy re-entries cross an external boundary and resolve the reentrant
    ///      table from storage via `getExpectedL1toL2Calls()`.
    /// @param entry The execution entry to run; the caller is responsible for routing
    ///        `getExpectedL1toL2Calls()` to the matching live storage table.
    function _executeEntry(ExecutionEntry memory entry) internal {
        StateDelta[] memory deltas = entry.stateDeltas;

        // Redundant ≥1-delta guard (also enforced at validation): a non-empty `_verifiedRollupInCurrentExecutingEntry` is
        // what backs `_insideExecution()`.
        if (deltas.length == 0) revert EntryHasNoStateDeltas();

        // Validity gate + allowed-rollups set, one pass. CHECK each `currentState` vs the live root
        // (fail fast — `newState` applies after the calls so mid-execution reads see the pre-state),
        // and ADD each delta's rollup to `_verifiedRollupInCurrentExecutingEntry` (proxy-protection: the proxies the entry
        // can execute are limited to the rollups it proved). Populating the array also flips
        // `_insideExecution()` true (it's non-empty now); `delete` at the end flips it back.
        for (uint256 i = 0; i < deltas.length; i++) {
            if (rollups[deltas[i].rollupId].stateRoot != deltas[i].currentState) {
                revert StateRootMismatch(deltas[i].rollupId);
            }
            _verifiedRollupInCurrentExecutingEntry.push(deltas[i].rollupId);
        }

        _rollingHashEntryBegin(deltas, entry.proxyEntryHash); // initial hash: binds starting state + identity
        _lastL1ToL2CallConsumed = 0;

        L2ToL1Call[] memory calls = entry.l2ToL1Calls;
        _processNCalls(calls);
        int256 totalEtherDelta = _applyStateDeltas(deltas);

        // A reentrant no-match folded CALL_NOT_FOUND into the rolling hash, so it surfaces here as a
        // `RollingHashMismatch` — no separate no-match check needed.
        if (_rollingHash != entry.rollingHash) revert RollingHashMismatch();
        // No reentrant table-length check: the unified `expectedL1ToL2Calls` mixes plain-success
        // entries with static / reverted ones (content-addressed, may be unused). Completeness of
        // the success entries is enforced by the rolling hash; an unused entry is inert.
        // `_entryEtherDelta` sums net ether across the top-level frame AND every reentrant sub-frame,
        // so the invariant captures the full physical flow.
        if (totalEtherDelta != _entryEtherDelta) revert EtherDeltaMismatch();

        emit EntryExecuted(_currentEntryIndex, _rollingHash, calls.length, _lastL1ToL2CallConsumed);

        // Top-level reverting entry: the trace is now verified, so unwind everything — the applied state
        // deltas, the inbound value, the cursor advance, and these cleanups all roll back with the revert,
        // surfacing `returnData` to the caller. Mirrors `_resolveStaticLookup`'s `!success` branch.
        if (!entry.success) {
            bytes memory returnData = entry.returnData;
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        delete _verifiedRollupInCurrentExecutingEntry; // clears the allowed set AND resets _insideExecution() to false
        _entryEtherDelta = 0; // reset for the next top-level entry in this tx
        _rollingHash = bytes32(0); // reset so the next entry's `_rollingHashEntryBegin` zero-guard passes
    }

    /// @notice Processes the WHOLE `calls` array (the entry's top-level calls, a reentrant sub-frame's
    ///         own calls, or a force-revert span slice), walked by a plain LOCAL index, folding the
    ///         rolling hash (source checked in validateStructure).
    /// @dev The index is a local, not transient: it auto-survives a reentrant proxy call (the outer
    ///      stack is preserved across the return), so there's nothing to save/restore for the L2→L1
    ///      position. Successful value calls SUBTRACT from the transient `_entryEtherDelta` (not a local)
    ///      so every frame folds into one entry-wide total; a force-revert span's subtractions roll back
    ///      with its revert (the tstore is undone with the physical value transfer).
    function _processNCalls(L2ToL1Call[] memory calls) internal {
        for (uint256 i = 0; i < calls.length;) {
            uint256 revertNextNCalls = calls[i].revertNextNCalls;

            if (revertNextNCalls == 0) {
                L2ToL1Call memory l2ToL1Call = calls[i];

                // Fold the call's identity (target on L1 = MAINNET, source = its rollup) into CALL_BEGIN.
                _rollingHashCallBegin(
                    computeCrossChainCallHash(
                        l2ToL1Call.isStatic,
                        l2ToL1Call.sourceAddress,
                        l2ToL1Call.sourceRollupId,
                        l2ToL1Call.targetAddress,
                        MAINNET_ROLLUP_ID,
                        l2ToL1Call.value,
                        l2ToL1Call.data
                    )
                );

                // No source check here: every executed call's `sourceRollupId` was already validated
                // ∈ `stateDeltas` in `_validateBatchStructure` (entry + reentrant sub-call walk).
                address sourceProxy = computeCrossChainProxyAddress(l2ToL1Call.sourceAddress, l2ToL1Call.sourceRollupId);
                if (!authorizedProxies[sourceProxy].isProxy) {
                    _createCrossChainProxyInternal(l2ToL1Call.sourceAddress, l2ToL1Call.sourceRollupId);
                }

                bool success;
                bytes memory retData;
                if (l2ToL1Call.isStatic) {
                    // Read-only dispatch: STATICCALL carries no value and reverts on any state write.
                    // A static call loaded with value is malformed — reject it rather than drop the value.
                    if (l2ToL1Call.value != 0) revert StaticCallWithValue();

                    (success, retData) = sourceProxy.staticcall(
                        abi.encodeCall(CrossChainProxy.executeOnBehalf, (l2ToL1Call.targetAddress, l2ToL1Call.data))
                    );
                } else {
                    (success, retData) = sourceProxy.call{
                        value: l2ToL1Call.value
                    }(abi.encodeCall(CrossChainProxy.executeOnBehalf, (l2ToL1Call.targetAddress, l2ToL1Call.data)));
                    if (l2ToL1Call.value > 0 && success) {
                        // Safe int to uint conversion since is a value that we just transfer in the above line, i cannot be >=2^255 ether
                        _entryEtherDelta -= int256(l2ToL1Call.value);
                    }
                }

                _rollingHashCallEnd(success, retData);
                emit CallResult(_currentEntryIndex, i, success, retData);
                i++;
            } else {
                // Force-revert span: the next `n` calls (this one included) run, succeed, then have
                // their state rolled back. Run them in an isolated self-call that always reverts; its
                // committed-to-`_rollingHash` and reentrant-consumption escape via `ContextResult` and
                // are restored here, while the EVM discards the state. A no-match inside the span is
                // already folded into that `_rollingHash`, so it rides out with no separate flag.
                if (i + revertNextNCalls > calls.length) {
                    revert RevertSpanOutOfBounds(i, revertNextNCalls, calls.length);
                }
                // Zero the trigger's span marker in our throwaway memory copy (the slice copies it),
                // so the isolated re-run reads it as a normal call instead of recursing into the span.
                calls[i].revertNextNCalls = 0;

                L2ToL1Call[] memory revertedSpan = _sliceL2ToL1Calls(calls, i, revertNextNCalls);
                try this.executeInContextAndRevert(revertedSpan) {}
                catch (bytes memory revertData) {
                    (_rollingHash, _lastL1ToL2CallConsumed,) = _decodeContextResult(revertData);
                }
                emit CallsReverted(_currentEntryIndex, i, revertNextNCalls);
                i += revertNextNCalls; // skip past the span — its calls ran inside the self-call
            }
        }
    }

    /// @notice Runs `calls` in an isolated context that always reverts (force-revert span executor).
    ///         Receives the span slice by `memory` (ABI-encoded across the self-call) since a
    ///         `storage` ref can't cross an external boundary; processes the whole slice.
    function executeInContextAndRevert(L2ToL1Call[] memory calls) external {
        if (msg.sender != address(this)) revert NotSelf();
        _processNCalls(calls);
        // 3rd field is always 0 on L1; it exists for the shared L1/L2 ContextResult decoder.
        revert ContextResult(_rollingHash, _lastL1ToL2CallConsumed, 0);
    }

    /// @notice Applies state deltas (root + ether balance) and sums their ether deltas. The
    ///         `currentState` precondition is the validity gate checked upfront in `_executeEntry`
    ///         (roots are immutable mid-execution), so this just applies `newState`.
    function _applyStateDeltas(StateDelta[] memory deltas) internal returns (int256 totalEtherDelta) {
        for (uint256 i = 0; i < deltas.length; i++) {
            StateDelta memory delta = deltas[i];
            RollupConfig storage config = rollups[delta.rollupId];
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
    function _stateRootsMatch(StaticLookup storage lookup) internal view returns (bool) {
        ExpectedStateRootPerRollup[] storage pins = lookup.expectedStateRoots;
        for (uint256 i = 0; i < pins.length; i++) {
            if (rollups[pins[i].rollupId].stateRoot != pins[i].stateRoot) return false;
        }
        return true;
    }

    // The flat call array driving execution is passed to `_processNCalls` explicitly by `memory`
    // (the entry's top-level calls, or a reentrant sub-frame's own). The reentrant (L1→L2) table is
    // always the current entry's `expectedL1ToL2Calls` (read off `getExpectedL1toL2Calls()` where needed);
    // a sub-frame's own reentrant calls live in that SAME table, disambiguated by the live
    // `_rollingHash` folded into each entry's `expectedL1toL2Hash`.

    // ──────────────────────────────────────────────
    //  Static lookup
    // ──────────────────────────────────────────────

    /// @notice Looks up a pre-computed lookup result.
    /// @dev Inside an execution: scans the active host's unified `expectedL1ToL2Calls` for an entry
    ///      whose `expectedL1toL2Hash` matches `keccak256(crossChainCallHash, _rollingHash)` — the same
    ///      content-addressed key the reentrant CALLs use. The `crossChainCallHash` here folds
    ///      `isStatic = true`, so only static entries can match. Outside: while a batch is mid-flight,
    ///      ONLY its transient pool (the
    ///      transient phase is self-contained — see docs/CAVEATS.md); otherwise the routed rollup's
    ///      persistent `staticLookupQueue`. Match: a top-level `StaticLookup` with `proxyEntryHash` and
    ///      every state-root pin live (full scan — a non-matching candidate is skipped). tload works
    ///      in static context, so the transient tracking variables are readable.
    /// @dev TODO (perf): linear scans are O(n) — sort + binary-search once profiling shows
    ///      it matters (the publicInputsHash already binds the arrays, so prover re-ordering
    ///      can't sneak in).
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return The pre-computed return data
    function staticCallLookup(address sourceAddress, bytes calldata callData) external view returns (bytes memory) {
        // Get EEZ proxy info from msg.sender
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];

        // Check msg.sender is EEZ proxy
        if (!proxyInfo.isProxy) revert UnauthorizedProxy();

        address destAddress = proxyInfo.originalAddress;
        uint64 destRid = proxyInfo.originalRollupId;

        bytes32 crossChainCallHash =
            computeCrossChainCallHash(IS_STATIC, sourceAddress, MAINNET_ROLLUP_ID, destAddress, destRid, 0, callData);

        // Nested: the active host's unified reentrant table, content-addressed by `expectedL1toL2Hash`.
        // `crossChainCallHash` was computed with `isStatic = true`, so it can only match a static
        // entry. A STATICCALL cannot mutate the cursor, so a static read is position-pinned by the
        // rolling hash rather than consumed.
        if (_insideExecution()) {
            // Proxy protection: the read's target rollup must be in the entry's proven set.
            if (!_isRollupAllowed(destRid)) revert ReentrantDestinationNotVerified(destRid);
            bytes32 expectedL1toL2Hash = _computeExpectedL1toL2Hash(crossChainCallHash, _rollingHash);
            // Forward scan from the cursor — same strict-forward window as `_consumeNestedCall`
            // (a static read cannot advance the cursor, but it still only matches at/after it).
            ExpectedL1ToL2Call[] storage expectedCalls = getExpectedL1toL2Calls();
            for (uint256 i = _lastL1ToL2CallConsumed; i < expectedCalls.length; i++) {
                ExpectedL1ToL2Call storage expectedCall = expectedCalls[i];
                if (expectedCall.expectedL1toL2Hash == expectedL1toL2Hash) {
                    return _resolveStaticLookup(
                        expectedCall.l2ToL1Calls,
                        expectedCall.revertedOrStaticRollingHash,
                        expectedCall.success,
                        expectedCall.returnData
                    );
                }
            }
            revert ExecutionNotFound();
        }

        // Top-level: scan the single table in scope — the batch's transient pool while one is
        // mid-flight (the transient phase is self-contained — see docs/CAVEATS.md), otherwise
        // `destRid`'s persistent queue.
        // Note that static calls do not obsolete after a block passes. As long as the state roots matches it can be execute
        StaticLookup[] storage staticLookups = _transientExecutions.length != 0
            ? _transientStaticLookups
            : verificationByRollup[destRid].staticLookupQueue;
        for (uint256 i = 0; i < staticLookups.length; i++) {
            StaticLookup storage lookup = staticLookups[i];
            // Proxy protection: fold the declared destination into the match. The transient pool
            // is a single global table (not queue-routed by rollup), so without this a prover could
            // resolve a lookup for a rollup other than the calling proxy's. Persistent lookups are
            // queue-routed by destination, so this is always true for them.
            if (
                lookup.proxyEntryHash == crossChainCallHash && lookup.destinationRollupId == destRid
                    && _stateRootsMatch(lookup)
            ) {
                return _resolveStaticLookup(lookup.l2ToL1Calls, lookup.rollingHash, lookup.success, lookup.returnData);
            }
        }

        revert ExecutionNotFound();
    }

    /// @notice Shared static-resolution body: run the sub-calls (untagged schema, always
    ///         compared — an empty `calls[]` hashes to 0, which must match a sub-call-less
    ///         lookup's `revertedOrStaticRollingHash`), then return the cached data, or revert with it when
    ///         `!success`.
    function _resolveStaticLookup(
        L2ToL1Call[] storage calls,
        bytes32 revertedOrStaticRollingHash,
        bool success,
        bytes memory returnData
    )
        internal
        view
        returns (bytes memory)
    {
        if (_processNStaticCalls(calls) != revertedOrStaticRollingHash) revert RollingHashMismatch();
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return returnData;
    }

    /// @notice Runs the lookup's `calls[]` in static context, folding an untagged rolling hash verified
    ///         against `StaticLookup.rollingHash` (source checked in validateStructure).
    /// @dev No `revertNextNCalls` since there are not changes on state; referenced proxies must already be deployed (CREATE2 is unavailable
    ///      inside a STATICCALL frame). See `docs/CORE_PROTOCOL_SPEC.md` §E.2.
    function _processNStaticCalls(L2ToL1Call[] memory calls) internal view returns (bytes32 computedHash) {
        for (uint256 i = 0; i < calls.length; i++) {
            L2ToL1Call memory l2ToL1Call = calls[i];
            // No source check: sub-call sources are validated ∈ proven set in `_validateBatchStructure`
            // — nested lookups via the entry's reentrant walk, top-level via the lookup's `expectedStateRoots`.
            address sourceProxy = computeCrossChainProxyAddress(l2ToL1Call.sourceAddress, l2ToL1Call.sourceRollupId);
            // STATICCALL to a codeless address silently succeeds — reject so the prover can't pre-hash a no-op.
            if (sourceProxy.code.length == 0) revert LookupCallProxyNotDeployed(sourceProxy);
            (bool success, bytes memory retData) = sourceProxy.staticcall(
                abi.encodeCall(CrossChainProxy.executeOnBehalf, (l2ToL1Call.targetAddress, l2ToL1Call.data))
            );
            computedHash = _rollingHashStaticResult(computedHash, success, retData);
        }
    }

    /// @notice True while inside a cross-chain call execution — backed by the allowed-rollups array
    ///         (non-empty ⇔ executing, since every entry has ≥1 delta and the array is `delete`d at the
    ///         end of `_executeEntry`).
    // review we could check rolling hash instead too
    function _insideExecution() internal view returns (bool) {
        return _verifiedRollupInCurrentExecutingEntry.length != 0;
    }

    // ── "Allowed rollups" set ────────────────────────────────────────────────────────────────────
    // Runtime proxy-protection for reentrant / static-read TARGETS only. A target's rollup is whichever
    // proxy re-enters (no clear-text field to validate at post time), so it's checked here against the
    // executing entry's `stateDeltas` — populated into `_verifiedRollupInCurrentExecutingEntry` by `_executeEntry`. Call
    // SOURCES need no runtime check: `_validateBatchStructure` already pins them ∈ `stateDeltas`.

    /// @notice True iff `rollupId` is in the current entry's allowed set. Linear scan (deltas are few).
    function _isRollupAllowed(uint64 rollupId) internal view returns (bool) {
        uint64[] storage allowed = _verifiedRollupInCurrentExecutingEntry;
        uint256 n = allowed.length;
        for (uint256 i = 0; i < n; i++) {
            if (allowed[i] == rollupId) return true;
        }
        return false;
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
    function setStateRoot(uint64 rollupId, bytes32 newStateRoot) external {
        if (msg.sender != rollups[rollupId].rollupContract) revert NotRollupContract();
        if (_insideExecution()) revert SetStateRootNotAllowedDuringExecution();
        if (verificationByRollup[rollupId].lastVerifiedBlock == uint64(block.number)) {
            revert RollupBatchActiveThisBlock(rollupId);
        }
        rollups[rollupId].stateRoot = newStateRoot;
        emit StateUpdated(rollupId, newStateRoot);
    }

    // ──────────────────────────────────────────────
    //  Internal helpers
    // ──────────────────────────────────────────────

    /// @notice L1's own network is mainnet — `createCrossChainProxy` may not proxy an L1 address.
    function _getRollupId() internal pure override returns (uint64) {
        return MAINNET_ROLLUP_ID;
    }

    /// @notice Returns the position of `target` in a strictly-increasing `uint64[]`, or
    ///         `type(uint256).max` if not present. Strictly-increasing invariant is enforced
    ///         in `_validateBatchStructure`, so binary search is safe.
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
    /// @dev Binary (vs `_containsRollupInList`'s linear): a whole batch can carry many rollups, and this list is
    ///      kept sorted, so the log(n) lookup is worth it. Per-entry / per-lookup sets are small, so
    ///      they use a linear scan instead — see `_containsRollupInList`.
    function _containsRollupInBatch(ProofSystemBatchPerVerificationEntries calldata batch, uint64 rollupId)
        internal
        pure
        returns (bool)
    {
        uint256 lo = 0;
        uint256 hi = batch.rollupIdsWithProofSystems.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            uint64 v = batch.rollupIdsWithProofSystems[mid].rollupId;
            if (v == rollupId) return true;
            if (v < rollupId) lo = mid + 1;
            else hi = mid;
        }
        return false;
    }

    // ──────────────────────────────────────────────
    //  Proxy-protection: call SOURCES are validated ∈ `stateDeltas` in `_validateBatchStructure`.
    //  Reentrant / static-read TARGETS have no clear-text field, so they're checked at RUNTIME via
    //  `_isRollupAllowed` against the per-entry allowed-rollups set (`stateDeltas`, set by `_executeEntry`).
    // ──────────────────────────────────────────────

    /// @notice True if `rollupId` appears in `ids`. Strict membership — no MAINNET exemption.
    /// @dev Linear scan (vs `_containsRollupInBatch`'s binary search): `ids` here is a single entry's
    ///      `stateDeltas` rollups or one lookup's `expectedStateRoots` pins — usually only a handful, and the
    ///      lookup set isn't sorted — so a linear scan is the simpler, general fit. A whole batch can
    ///      hold many rollups, which is why the batch-wide check is sorted + binary instead.
    function _containsRollupInList(uint64[] memory ids, uint64 rollupId) internal pure returns (bool) {
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == rollupId) return true;
        }
        return false;
    }

    /// @notice Copies the `n`-call span at `start` into a fresh memory array. Explicit field copy
    ///         (not element assignment) so the fresh structs don't alias the caller's array. The
    ///         caller zeroes the trigger's `revertNextNCalls` before slicing (so `span[0]` copies 0
    ///         and the isolated re-run won't recurse into the same span).
    function _sliceL2ToL1Calls(L2ToL1Call[] memory calls, uint256 start, uint256 n)
        internal
        pure
        returns (L2ToL1Call[] memory span)
    {
        span = new L2ToL1Call[](n);
        for (uint256 k = 0; k < n; k++) {
            L2ToL1Call memory source = calls[start + k];
            span[k] = L2ToL1Call({
                isStatic: source.isStatic,
                targetAddress: source.targetAddress,
                value: source.value,
                data: source.data,
                sourceAddress: source.sourceAddress,
                sourceRollupId: source.sourceRollupId,
                revertNextNCalls: source.revertNextNCalls
            });
        }
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice Last block at which `_rollupId` was verified by a postAndVerifyBatch call
    function lastVerifiedBlock(uint64 _rollupId) external view returns (uint256) {
        return verificationByRollup[_rollupId].lastVerifiedBlock;
    }

    /// @notice Length of the deferred queue for `_rollupId` (only meaningful in the current
    ///         block; stale entries from prior blocks are treated as empty by readers)
    function queueLength(uint64 _rollupId) external view returns (uint256) {
        return verificationByRollup[_rollupId].executionQueue.length;
    }

    /// @notice Cursor (next-to-consume) for the deferred queue of `_rollupId`
    function executionQueueIndex(uint64 _rollupId) external view returns (uint256) {
        return verificationByRollup[_rollupId].executionQueueIndex;
    }
}
