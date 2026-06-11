// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
//  IEEZ — shared cross-chain interface + L1 (EEZ) execution structs.
//
//  This file holds:
//    - `ProxyInfo` and the `IEEZ` interface: direction-neutral, shared by the L1
//      (`EEZ`) and L2 (`EEZL2`) managers and by `CrossChainProxy` / `Bridge`.
//    - The L1-canonical, directionally-named execution structs consumed by `EEZ.sol`:
//        * an `L2ToL1Call` is a cross-chain call executed/replayed on L1 (flat
//          `l2ToL1Calls[]` array, walked by the `_currentL2ToL1Call` cursor),
//        * an `ExpectedL1ToL2Call` is a reentrant L1→L2 call fired during execution
//          (the `expectedL1ToL2Calls[]` table, counted by `_lastL1ToL2CallConsumed`).
//
//  The mirror-image L2 structs land in `IEEZL2.sol` (next iteration) with the
//  directions flipped. The two will be layout-identical (same field order + types);
//  only the names differ, so `abi.encode(entry)` — the preimage of L1's per-entry
//  proof hash — is unaffected by the split.
//
//  Casing: types/events/errors are PascalCase (`L2ToL1Call`, `L1ToL2CallConsumed`,
//  `UnconsumedL2ToL1Calls`); variables / struct fields / params are mixedCase with
//  the connector capitalized (`l2ToL1Calls`, `_currentL2ToL1Call`).
// ─────────────────────────────────────────────────────────────────────────────

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
struct L2ToL1Call {
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
struct ExpectedL1ToL2Call {
    bytes32 crossChainCallHash;
    /// Iterations the reentrant frame's `_processNCalls` runs over the parent entry's `l2ToL1Calls[]`.
    /// Continues advancing the same global `_currentL2ToL1Call` cursor that the outer frame
    /// was using; outer resumes from `cursor + callCount` after the reentrant frame returns.
    /// See `ExecutionEntry` natspec for the partition invariant.
    uint256 callCount;
    bytes returnData;
}

/// @notice Represents an execution entry with pre-computed calls and return hash verification
/// @dev Execution entries always SUCCEED at the top level — `executeCrossChainCall` returns
///      `entry.returnData` as success. There is no `failed` flag because **a reverting
///      top-level call isn't an execution; it's a lookup**. Reverting cross-chain results
///      are expressed via `LookupCall { failed: true }` consumed through `staticCallLookup`
///      (static-context entry point) or the failed-reentry fallback in `_consumeNestedAction`.
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
    bytes32 proxyEntryHash; // hashed call (L2 -> L1), otherwise bytes32(0) for L2 txs
    uint256 destinationRollupId;
    /// All calls executed by this entry, flat, in execution order. Partitioned between
    /// the entry's outermost frame and any reentrant (L1→L2) frames — see the natspec
    /// above for the `callCount` partition invariant.
    L2ToL1Call[] l2ToL1Calls;
    /// Parallel partition table: each `ExpectedL1ToL2Call` consumes a slice of `l2ToL1Calls[]`
    /// during a reentrant frame. Order matches the order in which reentrant calls fire.
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;
    /// Top-level iterations. Together with `expectedL1ToL2Calls[i].callCount`, partitions
    /// `l2ToL1Calls[]` across the execution tree. See the natspec above.
    uint256 callCount;
    bytes returnData;
    bytes32 rollingHash;
}

/// @notice A rollup's expected queue cursor at the moment a static lookup is observed.
/// @dev Pins a static `LookupCall` to a specific multi-rollup consumption point: at resolve
///      time the contract requires `verificationByRollup[rollupId].executionQueueIndex == executionQueueIndex`,
///      so a cached read can't be replayed against a different interleaving of the per-rollup
///      queues. L1-only — L2 has a single rollup and ignores this list.
struct ExpectedQueueIndexPerRollup {
    uint256 rollupId;
    uint256 executionQueueIndex;
}

/// @notice Pre-computed result for a lookup call or a call that reverts.
/// @dev Two modes, split on `failed`:
///      - **Static (`failed == false`)** — read-only reentry resolved via `staticCallLookup`.
///        `l2ToL1Calls[]` (if any) replay in STATICCALL context and are hashed into `rollingHash`
///        with the untagged static schema; reentry is encoded as *separate*
///        `LookupCall`s sharing the same `(l2ToL1CallNumber, lastL1ToL2CallConsumed)`.
///        `expectedQueueIndices[]` pins the per-rollup queue positions (L1).
///      - **Failed (`failed == true`)** — a reverting reentrant call resolved via the
///        `_consumeNestedAction` fallback. When it carries a sub-execution (`callCount > 0`),
///        it replays as a mini-entry: `l2ToL1Calls[]` run as real calls and `expectedL1ToL2Calls[]`
///        supply reentry, folded into `rollingHash` with the tagged `CALL_*/NESTED_*`
///        schema and checked like an entry, then the call reverts with `returnData`.
///      Loaded via postAndVerifyBatch (L1). All proxies referenced by `l2ToL1Calls` must be
///      deployed before resolution.
struct LookupCall {
    bytes32 crossChainCallHash;
    /// Rollup whose `lookupQueue` this lookup is routed to on L1 (per-rollup queue model).
    /// INVARIANT: MUST equal the destRID the lookup is keyed to (the target rollup is already
    /// bound into `crossChainCallHash`, so this field is redundant with it — "implicit"). It's
    /// kept explicit because it's load-bearing for `failed` lookups: the queue this is published
    /// under is `verificationByRollup[destinationRollupId].lookupQueue`, and `_replayFailedLookup`
    /// re-derives that queue from this field mid-replay (`_currentFailedLookup`) — recovering the
    /// rollup directly instead of re-deriving the hash preimage. Set it wrong and the replay reads
    /// the wrong queue.
    uint256 destinationRollupId;
    bytes returnData;
    bool failed;
    /// 1-indexed global L2→L1 call number — the value of `_currentL2ToL1Call` at the moment
    /// this lookup call was observed by the prover. Used as part of the lookup key in
    /// `staticCallLookup` and the failed-lookup-call fallback in `_consumeNestedAction`.
    /// For a static read observed *inside* a failed lookup's sub-execution, this is the
    /// failed lookup's fresh sub-cursor value. NOTE: the lookup key does NOT encode which
    /// context is active — the prover must keep keys collision-free across the entry and
    /// any failed-lookup sub-executions.
    uint64 l2ToL1CallNumber;
    /// Disambiguates multiple lookup calls fired during the same outer call (e.g., a
    /// reentrant view query that triggers further static lookups). Matches
    /// `_lastL1ToL2CallConsumed` at the moment of observation.
    uint64 lastL1ToL2CallConsumed;
    /// Sub-calls replayed during resolution. Static mode: STATICCALL, no `revertSpan`.
    /// Failed mode: real calls (may host reentry and `revertSpan`), partitioned
    /// against `expectedL1ToL2Calls` exactly like `ExecutionEntry.l2ToL1Calls`.
    L2ToL1Call[] l2ToL1Calls;
    /// Failed-mode reentrant table — reentrant L1→L2 calls triggered while replaying `l2ToL1Calls[]`.
    /// Reuses the entry struct and is consumed sequentially by `_consumeNestedAction` while
    /// `_insideFailedLookup` is set. Empty for static-mode lookups.
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;
    /// Failed-mode top-level iterations over `l2ToL1Calls[]` (the entry-style `callCount`
    /// partition: `callCount + Σ expectedL1ToL2Calls[i].callCount == l2ToL1Calls.length`). Zero
    /// for static-mode lookups.
    uint256 callCount;
    /// Expected rolling hash of the replayed sub-calls — checked at resolution when `l2ToL1Calls[]`
    /// is non-empty. Static mode uses the untagged schema (`_processNLookupCalls`); failed
    /// mode uses the tagged entry schema (`_replayFailedLookup`).
    bytes32 rollingHash;
    /// Static-mode per-rollup queue-cursor pins (L1 only); see `ExpectedQueueIndexPerRollup`.
    /// if it's used alongside l2ToL1CallNumber and lastL1ToL2CallConsumed, there should be only the
    /// unaffected rollups by that execution (otherwise is redundant)
    ExpectedQueueIndexPerRollup[] expectedQueueIndices;
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
