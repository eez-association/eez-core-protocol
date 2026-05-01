// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Represents an action used to build the entrypoint hash
/// @dev Off-chain only. Not used by any on-chain function. Exists for tooling to compute
///      actionHash = keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId))
/// @dev Field declaration order matches the abi.encode preimage; do not reorder without
///      updating _computeActionInputHash in Rollups / CrossChainManagerL2.
struct Action {
    uint256 targetRollupId;
    address targetAddress;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollupId;
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

/// @notice Represents a cross-chain call within an execution entry
/// @dev revertSpan > 0 opens an isolated revert context spanning the next revertSpan calls (including this one)
struct CrossChainCall {
    address targetAddress;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;
}

/// @notice Pre-computed result for a successful reentrant cross-chain call triggered during execution
/// @dev Consumed sequentially from the entry's nestedActions array. If a nested action itself
///      triggers a reentrant call, it consumes the next element in the same flat array.
/// @dev All nested actions must succeed. Failed calls should use LookupCall instead.
/// @dev Position in the execution tree (crossChainCall index, nested action index, parent context)
///      is folded into the entry-level rolling hash rather than stored as explicit fields.
struct NestedAction {
    bytes32 actionHash;
    /// Iterations the nested frame's `_processNCalls` runs over the parent entry's `calls[]`.
    /// Continues advancing the same global `_currentCallNumber` cursor that the outer frame
    /// was using; outer resumes from `cursor + nested.callCount` after the nested returns.
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
///      See `src/TODO.md` for the design discussion.
/// @dev `destinationRollupId` is the rollup whose queue this entry is routed to on L1
///      (per-rollup queue model). Must match the rollupId derived from the consumer
///      (proxyInfo.originalRollupId for proxy calls; the explicit rollupId arg for
///      executeL2TX). On L2 there's a single rollup, so the field is unused by the on-chain
///      execution path — it's still set by tooling for parity with L1, and may be read by
///      off-chain indexers, but no L2 contract logic reads it.
///
/// @dev **`callCount` — flat-calls + nesting partition.**
///      `calls[]` is the FULL flat list of every call this entry will execute, in execution
///      order. It is partitioned between the entry's outermost frame and any reentrant
///      (nested) frames triggered during execution:
///        - `callCount`                = iterations the entry's TOP-LEVEL `_processNCalls` runs.
///        - `nestedActions[i].callCount` = iterations the i-th nested frame's `_processNCalls` runs.
///      And the invariant after the entry finishes:
///        callCount + Σ nestedActions[i].callCount == calls.length
///      The on-chain `_currentCallNumber` cursor advances monotonically over `calls[]` —
///      there's only one cursor across the whole tree. When a top-level call triggers a
///      reentrant cross-chain proxy invocation, control re-enters via `executeCrossChainCall`
///      → `_consumeNestedAction`, which calls `_processNCalls(nestedActions[i].callCount)`
///      on the SAME `calls[]` array, advancing the same cursor. Outer iteration resumes
///      where the cursor left off after the nested frame returns.
///
///      Worked example. `calls.length = 5`:
///        - call 0: top-level, no reentry.
///        - call 1: top-level, triggers a reentrant call → matched against `nestedActions[0]`,
///                  whose `callCount = 2` consumes calls 2 and 3 inside the nested frame.
///        - call 4: top-level, no reentry.
///      ⇒ `entry.callCount = 3` (calls 0, 1, 4 at the outer frame),
///        `nestedActions[0].callCount = 2` (calls 2, 3 inside the nested frame),
///        and `_currentCallNumber == 5` at the end (the `UnconsumedCalls` guard checks this).
struct ExecutionEntry {
    StateDelta[] stateDeltas;
    bytes32 actionHash;
    uint256 destinationRollupId;
    /// All calls executed by this entry, flat, in execution order. Partitioned between
    /// the entry's outermost frame and any reentrant (nested) frames — see the natspec
    /// above for the `callCount` partition invariant.
    CrossChainCall[] calls;
    /// Parallel partition table: each `NestedAction` consumes a slice of `calls[]` during
    /// a reentrant frame. Order matches the order in which reentrant calls fire.
    NestedAction[] nestedActions;
    /// Top-level iterations. Together with `nestedActions[i].callCount`, partitions `calls[]`
    /// across the execution tree. See the natspec above.
    uint256 callCount;
    bytes returnData;
    bytes32 rollingHash;
}

/// @notice Pre-computed result for a lookup call or a call that reverts
/// @dev Used for read-only calls and for calls whose revert needs to be replayed.
///      Loaded via postBatch (L1) or loadExecutionTable (L2).
///      All proxies referenced by `calls` must be deployed before staticCallLookup is called.
struct LookupCall {
    bytes32 actionHash;
    /// Rollup whose `lookupQueue` this entry is routed to on L1 (per-rollup queue model).
    /// On L2 there's a single rollup, so the field is unused by the on-chain execution
    /// path — same semantic as `ExecutionEntry.destinationRollupId`.
    uint256 destinationRollupId;
    bytes returnData;
    bool failed;
    /// 1-indexed global call number — the value of `_currentCallNumber` at the moment
    /// this lookup call was observed by the prover. Used as part of the lookup key in
    /// `staticCallLookup` and the failed-lookup-call fallback in `_consumeNestedAction`.
    uint64 callNumber;
    /// Disambiguates multiple lookup calls fired during the same outer call (e.g., a
    /// reentrant view query that triggers further static lookups). Matches
    /// `_lastNestedActionConsumed` at the moment of observation.
    uint64 lastNestedActionConsumed;
    /// Optional sub-calls to replay in static context (no `revertSpan` allowed). Empty
    /// `calls[]` means the cached `returnData` / `failed` bypasses any sub-call replay.
    CrossChainCall[] calls;
    /// Expected hash of the sub-call results — checked at lookup time when `calls[]` is
    /// non-empty. See `_processNLookupCalls` for the hashing scheme.
    bytes32 rollingHash;
}

/// @notice Stores the identity of an authorized CrossChainProxy
struct ProxyInfo {
    address originalAddress;
    uint64 originalRollupId;
}

/// @title ICrossChainManager
/// @notice Interface for cross-chain manager contracts (L1 Rollups and L2 CrossChainManagerL2)
interface ICrossChainManager {
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
