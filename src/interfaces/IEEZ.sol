// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
//  IEEZ — shared cross-chain interface + L1 (EEZ) execution structs.
//
//  This file holds:
//    - `ProxyInfo` and the `IEEZ` interface: direction-neutral, shared by the L1
//      (`EEZ`) and L2 (`EEZL2`) managers and by `CrossChainProxy` / `Bridge`.
//    - The L1-canonical, directionally-named execution structs consumed by `EEZ.sol`:
//        * an `L2ToL1Call` is a cross-chain call executed on L1 (flat
//          `l2ToL1Calls[]` array, walked by the `_currentL2ToL1Call` cursor),
//        * an `ExpectedL1ToL2Call` is a reentrant L1→L2 call fired during execution
//          (the `expectedL1ToL2Calls[]` table, counted by `_lastL1ToL2CallConsumed`).
//
//  The mirror-image L2 structs live in `IEEZL2.sol` with self-relative names and a
//  deliberately leaner layout (no `StateDelta`, `destinationRollupId`, or
//  `ExpectedStateRootPerRollup`) — L2 never hashes a whole entry/lookup, so its
//  layout is free to diverge from L1's.
//
//  Casing: types/events/errors are PascalCase (`L2ToL1Call`, `L1ToL2CallConsumed`,
//  `UnconsumedL2ToL1Calls`); variables / struct fields / params are mixedCase with
//  the connector capitalized (`l2ToL1Calls`, `_currentL2ToL1Call`).
// ─────────────────────────────────────────────────────────────────────────────

/// @notice One participating rollup in a `ProofSystemBatchPerVerificationEntries` together
///         with the SUBSET of the batch's global `proofSystems[]` that this rollup accepts.
/// @dev `proofSystemIndex[]` is a list of indices into the parent batch's `proofSystems[]`,
///      strictly increasing. The on-chain registry resolves them to PS addresses and hands
///      that subset to this rollup's contract via `IRollupContract.checkProofSystemsAndGetVkeys`
struct RollupIdWithProofSystems {
    uint256 rollupId;
    uint64[] proofSystemIndex;
}

/// @notice One batch's payload — a group of proof systems jointly attesting to a set of
///         rollups' state transitions. Each rollup picks the subset of `proofSystems[]` it
///         accepts via `RollupIdWithProofSystems[r].proofSystemIndex`.
/// @dev The participating rollups (read off `RollupIdWithProofSystems[r].rollupId`) must be
///      strictly increasing — paired with the once-per-block-per-rollup invariant on
///      `_markVerifiedBlockPerRollup`, this prevents a single batch from verifying the same
///      rollup twice. `proofSystems[]` is the batch-global PS list (strictly increasing,
///      rejects address(0) and duplicates). Each rollup's `proofSystemIndex[]` is strictly
///      increasing too, indices in `[0, proofSystems.length)`, and its length must satisfy
///      that rollup's threshold (enforced by `IRollupContract.checkProofSystemsAndGetVkeys`).
/// @dev `blobIndices` selects which of the tx-level EIP-4844 blobs this batch consumes;
///      `callData` is batch-scoped (each PS's circuit gets its own region).
/// @dev `transientExecutionEntryCount` and `transientLookupCallCount` are pure on-chain
///      dispatch parameters — not bound by the proof — so the orchestrator can tune the
///      transient/persistent split without re-proving.
/// @dev `blockNumber` is the single L1 block the whole batch binds to. The registry forwards
///      it to every rollup's `getTimestampAndBlockHash(blockNumber)`, whose result folds into
///      each proof's public input. 0 = no block context, type(uint64).max = "latest context"
struct ProofSystemBatchPerVerificationEntries {
    ExecutionEntry[] entries;
    LookupCall[] l1ToL2lookupCalls;
    uint256 transientExecutionEntryCount;
    uint256 transientLookupCallCount;
    address[] proofSystems;
    RollupIdWithProofSystems[] rollupIdsWithProofSystems;
    uint256[] blobIndices;
    bytes callData;
    bytes[] proofs;
    uint64 blockNumber;
}

/// @notice Rollup configuration held by the central registry.
/// @dev Owner, threshold, and per-PS vkeys live on the per-rollup `IRollupContract` contract pointed
///      to by `rollupContract`. The central registry holds only the *state* (state root,
///      ether balance) and reads vkeys through `IRollupContract.checkProofSystemsAndGetVkeys`
struct RollupConfig {
    address rollupContract;
    bytes32 stateRoot;
    uint256 etherBalance;
}

/// @notice Per-rollup deferred-consumption queue + per-block reset marker
/// @dev `lastVerifiedBlock` doubles as:
///        (a) per-block reset marker — every `postAndVerifyBatch` that touches `rid` wipes this
///            rollup's queue and cursor (see `_markVerifiedBlockPerRollup`), so a same-block
///            re-verify REPLACES (does not append to) the prior batch's entries;
///        (b) read gate for consumers (entries can only be consumed in the block they were
///            posted — `executeCrossChainCall` / `executeL2TX` / `staticCallLookup` all gate
///            on `lastVerifiedBlock(rid) == block.number`), which also means a stale queue from
///            a prior block is never read — it's simply overwritten on the next verify;
///        (c) lockout signal for the registry's owner-escape path `EEZ.setStateRoot`,
///            which reverts `RollupBatchActiveThisBlock` when this equals `block.number`.
struct RollupVerification {
    uint256 lastVerifiedBlock;
    ExecutionEntry[] executionQueue;
    LookupCall[] lookupQueue;
    uint256 executionQueueIndex;
}

/// @notice Represents a state delta
/// @dev `currentState` is the rollup's expected state root immediately before this delta is applied.
///      It is checked on-chain against `rollups[rollupId].stateRoot`; mismatch reverts. This makes
///      entries content-addressed against the trajectory the proof committed to, which is what
///      lets the per-rollup queue model interleave consumption across rollups safely.
struct StateDelta {
    uint256 rollupId;
    bytes32 currentState;
    bytes32 newState;
    int256 etherDelta;
}

/// @notice Represents a cross-chain call within an execution entry (L2→L1 on L1)
/// @dev revertSpan > 0 opens an isolated revert context spanning the next revertSpan calls (including this one)
/// @dev isStatic dispatches the call via STATICCALL — read-only, carries no value, reverts on any state write
struct L2ToL1Call {
    bool isStatic;
    address targetAddress;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;
}

/// @notice Pre-computed result for a successful reentrant cross-chain call (L1→L2) triggered during execution
/// @dev Consumed sequentially from the entry's `expectedL1ToL2Calls` array. If a reentrant call itself
///      triggers another reentrant call, it consumes the next element in the same flat array.
/// @dev All entries here must succeed. Failed calls should use LookupCall instead.
/// @dev Position in the execution tree (L2→L1 call index, reentrant index, parent context)
///      is folded into the rolling hash rather than stored as explicit fields.
/// @dev `destinationRollupId` is the rollup this reentrant call targets. It is bound two ways:
///      `postAndVerifyBatch` requires it to be one of the host's verified rollups (the entry's
///      `stateDeltas`, or a top-level `LookupCall`'s `expectedStateRoots` pins), and at execution
///      `_consumeNestedAction` requires it to equal the calling proxy's rollup (`destRid`).
///      Together this guarantees a reentrant call can only reach a rollup the entry actually
///      proved — the `crossChainCallHash` alone is one-way, so the field carries the id in clear.
struct ExpectedL1ToL2Call {
    bytes32 crossChainCallHash;
    uint256 destinationRollupId;
    /// Iterations the reentrant frame's `_processNCalls` runs over the parent entry's `l2ToL1Calls[]`.
    /// Continues advancing the same global `_currentL2ToL1Call` cursor that the outer frame
    /// was using; outer resumes from `cursor + callCount` after the reentrant frame returns.
    /// See `ExecutionEntry` natspec for the partition invariant.
    uint256 callCount;
    bytes returnData;
}

/// @notice NESTED lookup: the pre-computed result of a reentrant cross-chain call that is
///         looked up rather than executed — a reentrant STATICCALL (static mode) or a
///         reverting reentrant call the caller try/catches (reverted mode). Lives INSIDE the
///         entry (`ExecutionEntry.expectedLookups`) — entry-scoped by construction, no queue
///         routing. Matched by `(crossChainCallHash, l2ToL1CallNumber, lastL1ToL2CallConsumed,
///         executingLookupIndex)`; the declared `destinationRollupId` is additionally checked
///         against the calling proxy's rollup at resolution.
/// @dev Reverted mode (`failed == true`) runs `l2ToL1Calls` as a mini-entry (tagged hash
///      schema, partitioned by `callCount` against `expectedL1ToL2Calls`) then reverts with
///      `returnData`; static mode runs them via STATICCALL (untagged schema) and returns
///      it. A reverted lookup's own deeper lookups resolve from the SAME host table (Solidity
///      forbids recursive structs) — the prover must keep keys collision-free across the
///      entry and its execution contexts. PROVER OBLIGATION: cross-rollup consistency of a
///      sub-call-less static read (the entry's deltas pin only the rollups they touch).
/// @dev `destinationRollupId` is the rollup this looked-up reentrant call targets — same proxy
///      protection as `ExpectedL1ToL2Call`: `postAndVerifyBatch` verifies it against the host's
///      `stateDeltas`/pins, and resolution (`staticCallLookup` / `_consumeNestedAction`) requires
///      it to equal the calling proxy's rollup (`destRid`).
struct ExpectedLookup {
    bytes32 crossChainCallHash;
    uint256 destinationRollupId;
    bytes returnData;
    bool failed;
    /// `_currentL2ToL1Call` at observation (1-indexed; a sub-execution's fresh sub-cursor inside one).
    uint64 l2ToL1CallNumber;
    /// `_lastL1ToL2CallConsumed` at observation.
    uint64 lastL1ToL2CallConsumed;
    /// Execution context at observation: 0 = fired at entry/host level; k = fired inside the
    /// sub-execution of `expectedLookups[k-1]` of the same host. Makes the key context-unambiguous
    /// (enforced — no longer a prover convention).
    uint64 executingLookupIndex;
    /// Sub-calls executed at resolution: STATICCALL (static mode) or real calls (reverted mode).
    L2ToL1Call[] l2ToL1Calls;
    /// Reverted-mode reentrant table for the sub-execution. Empty for static mode.
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;
    /// Reverted-mode top-level iterations over `l2ToL1Calls[]` (0 for static mode).
    uint256 callCount;
    /// Expected hash of the executed sub-calls: untagged schema (static), tagged (reverted).
    bytes32 rollingHash;
}

/// @notice Represents an execution entry with pre-computed calls and return hash verification
/// @dev Execution entries always SUCCEED at the top level — `executeCrossChainCall` returns
///      `entry.returnData` as success. There is no `failed` flag because **a reverting
///      top-level call isn't an execution; it's a lookup**. Reverting cross-chain results
///      are expressed via `LookupCall { failed: true }` consumed through `staticCallLookup`
///      (static-context entry point) or the reverted-lookup fallback in `_consumeNestedAction`.
///      Naturally-reverting INNER calls inside an entry are still expressible: the proxy
///      `.call` returns `(false, retData)` and the rolling hash captures it via `CALL_END`;
///      the entry's outer `executeCrossChainCall` still returns success with `entry.returnData`.
/// @dev `destinationRollupId` is the rollup whose queue this entry is routed to on L1
///      (per-rollup queue model). Must match the rollupId derived from the consumer
///      (proxyInfo.originalRollupId for proxy calls; the explicit rollupId arg for
///      executeL2TX).
///
/// @dev **`callCount` — flat-calls + reentrancy partition.**
///      `l2ToL1Calls[]` is the FULL flat list of every call this entry will execute, in
///      execution order. It is partitioned between the entry's outermost frame and any
///      reentrant (L1→L2) frames triggered during execution:
///        - `callCount`                       = iterations the entry's TOP-LEVEL `_processNCalls` runs.
///        - `expectedL1ToL2Calls[i].callCount` = iterations the i-th reentrant frame's `_processNCalls` runs.
///      And the invariant after the entry finishes:
///        callCount + Σ expectedL1ToL2Calls[i].callCount == l2ToL1Calls.length
///      The on-chain `_currentL2ToL1Call` cursor advances monotonically over `l2ToL1Calls[]` —
///      there's only one cursor across the whole tree. When a top-level call triggers a
///      reentrant cross-chain proxy invocation, control re-enters via `executeCrossChainCall`
///      → `_consumeNestedAction`, which calls `_processNCalls(expectedL1ToL2Calls[i].callCount)`
///      on the SAME `l2ToL1Calls[]` array, advancing the same cursor. Outer iteration resumes
///      where the cursor left off after the reentrant frame returns.
///
///      Worked example. `l2ToL1Calls.length = 5`:
///        - call 0: top-level, no reentry.
///        - call 1: top-level, triggers a reentrant call → matched against `expectedL1ToL2Calls[0]`,
///                  whose `callCount = 2` consumes calls 2 and 3 inside the reentrant frame.
///        - call 4: top-level, no reentry.
///      ⇒ `entry.callCount = 3` (calls 0, 1, 4 at the outer frame),
///        `expectedL1ToL2Calls[0].callCount = 2` (calls 2, 3 inside the reentrant frame),
///        and `_currentL2ToL1Call == 5` at the end (the `UnconsumedL2ToL1Calls` guard checks this).
struct ExecutionEntry {
    /// Initial state --> final state. PROVER OBLIGATION: the deltas must be the entry's true
    /// state transition, and every entry must carry at least one StateDelta (never empty) —
    /// asserted by the prover, not enforced on-chain.
    StateDelta[] stateDeltas;
    bytes32 proxyEntryHash; // hashed call (L1 -> L2), otherwise bytes32(0) for L2 txs
    uint256 destinationRollupId; // double check
    /// All calls executed by this entry, flat, in execution order. Partitioned between
    /// the entry's outermost frame and any reentrant (L1→L2) frames — see the natspec
    /// above for the `callCount` partition invariant.
    bytes returnData;
    L2ToL1Call[] l2ToL1Calls;
    /// Parallel partition table: each `ExpectedL1ToL2Call` consumes a slice of `l2ToL1Calls[]`
    /// during a reentrant frame. Order matches the order in which reentrant calls fire.
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;
    /// Nested lookups (reentrant static reads + try/catch'd reverting reentrant calls)
    /// consumed during this entry — entry-scoped; see `ExpectedLookup`.
    ExpectedLookup[] expectedLookups;
    /// Top-level iterations. Together with `expectedL1ToL2Calls[i].callCount`, partitions
    /// `l2ToL1Calls[]` across the execution tree. See the natspec above.
    uint256 callCount;
    bytes32 rollingHash;
}

/// @notice A rollup's expected state root at the moment a top-level lookup is observed.
/// @dev Content-addresses a `LookupCall` to a point on each pinned rollup's trajectory: a
///      candidate only MATCHES when every pin equals the live `rollups[rollupId].stateRoot`
///      (full-scan semantics — a mismatching candidate is skipped, it does not revert).
///      Split-independent and valid in the transient phase, unlike the old queue-cursor pins.
///      L1-only — L2 has no state roots.
struct ExpectedStateRootPerRollup {
    uint256 rollupId;
    bytes32 stateRoot;
}

/// @notice TOP-LEVEL lookup: the pre-computed result of a top-level cross-chain call that is
///         looked up rather than executed — a read-only call resolved via `staticCallLookup`,
///         or a reverting call executed via `_tryRevertedTopLevelLookup`. Lives in the storage
///         pool (`_transientLookupCalls` / per-rollup `lookupQueue`) and is consumable ONLY
///         outside an execution (`!_insideExecution()`). Nested lookups live inside
///         `ExecutionEntry.expectedLookups` instead — see `ExpectedLookup`.
/// @dev Match key: `crossChainCallHash` + `destinationRollupId == ` the calling proxy's rollup
///      + every `expectedStateRoots` pin equal to the live root (full scan — a non-matching
///      candidate is skipped, not reverted on). The `destinationRollupId` term is what makes the
///      transient pool (a single un-routed table) resolve only for the right rollup. Reverted mode
///      (`failed == true`) runs its sub-execution as a mini-entry (`l2ToL1Calls`
///      partitioned by `callCount` against `expectedL1ToL2Calls`, nested lookups from its own
///      `expectedLookups` table), then reverts with `returnData`. Static mode runs
///      `l2ToL1Calls` via STATICCALL (untagged schema) and returns `returnData` (or reverts
///      with it when `failed`). All proxies referenced by `l2ToL1Calls` must be deployed
///      before static resolution.
struct LookupCall {
    bytes32 crossChainCallHash;
    /// Rollup whose `lookupQueue` this lookup is published under, AND part of the resolution match
    /// (`staticCallLookup` / `_tryRevertedTopLevelLookup` require it to equal the calling proxy's
    /// rollup). For persistent lookups this is coherent by construction (queue-routed); for the
    /// transient pool it is the load-bearing check that the lookup resolves only for that rollup.
    /// postAndVerifyBatch also requires it to appear in `expectedStateRoots` (destination ∈ pins),
    /// pinning the routing target to proven state.
    uint256 destinationRollupId;
    bytes returnData;
    bool failed;
    /// Sub-calls executed during resolution. Static mode: STATICCALL, no `revertSpan`.
    /// Reverted mode: real calls (may host reentry and `revertSpan`), partitioned
    /// against `expectedL1ToL2Calls` exactly like `ExecutionEntry.l2ToL1Calls`.
    L2ToL1Call[] l2ToL1Calls;
    /// Reverted-mode reentrant table for the sub-execution. Empty for static mode.
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;
    /// Reverted-mode nested lookups consumed during the sub-execution (the sub-execution's own flat table —
    /// deeper reverted-lookup executions resolve from this same table). Empty for static mode.
    ExpectedLookup[] expectedLookups;
    /// Reverted-mode top-level iterations over `l2ToL1Calls[]` (the entry-style `callCount`
    /// partition). Zero for static mode.
    uint256 callCount;
    /// Expected rolling hash of the executed sub-calls — always checked (an empty `l2ToL1Calls[]`
    /// must carry `rollingHash == 0`). Untagged schema in static mode (`_processNLookupCalls`);
    /// tagged entry schema in reverted mode.
    bytes32 rollingHash;
    /// State-root pins — part of the MATCH predicate; see `ExpectedStateRootPerRollup`.
    ExpectedStateRootPerRollup[] expectedStateRoots;
}

/// @notice Stores the identity of an authorized CrossChainProxy
/// @dev Direction-neutral — shared by the L1 (`EEZ`) and L2 (`EEZL2`) managers via the
///      `EEZBase` proxy registry.
struct ProxyInfo {
    address originalAddress;
    uint64 originalRollupId;
}

/// @title IEEZ
/// @notice Shared interface for the cross-chain managers (L1 `EEZ`, L2 `EEZL2`). Carries only
///         the functions both sides implement identically and that `CrossChainProxy` / `Bridge`
///         depend on. The L1 execution structs above are consumed by `EEZ.sol`; the mirror-image
///         L2 structs live in `IEEZL2.sol`.
interface IEEZ {
    function executeCrossChainCall(address sourceAddress, bytes calldata callData)
        external
        payable
        returns (bytes memory result);
    function staticCallLookup(address sourceAddress, bytes calldata callData)
        external
        view
        returns (bytes memory result);
    function createCrossChainProxy(address originalAddress, uint256 originalRollupId) external returns (address proxy);
    function computeCrossChainProxyAddress(address originalAddress, uint256 originalRollupId)
        external
        view
        returns (address);
}
