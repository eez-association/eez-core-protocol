// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
/// @dev `l2toL1LookupCallIndex` / `l2toL1LookupCallCount` describe the contiguous slice of the
///      containing entry's `expectedLookupCalls[]` that reentrant lookups triggered DURING this
///      call resolve against — the same partition idea `ExpectedL1ToL2Call.callCount` uses for
///      `calls[]`. `count == 0` means this call triggers no reentrant lookups.
struct L2ToL1Call {
    address targetAddress;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;
    uint256 l2toL1LookupCallIndex;
    uint256 l2toL1LookupCallCount;
}

/// @notice Pre-computed result for a successful reentrant cross-chain call triggered during execution
/// @dev Consumed SEQUENTIALLY from the entry's `expectedL1ToL2Calls` array — the i-th reentrant
///      success consumes element i. The reentrant call's `crossChainCallHash` is NOT stored here;
///      it is folded into the rolling hash at `NESTED_BEGIN`, so a wrong reentrant call diverges
///      the entry's final hash. Failed reentrant calls use `ExpectedL1ToL2Lookup` instead.
struct ExpectedL1ToL2Call {
    /// Iterations the nested frame's `_processNCalls` runs over the parent entry's `calls[]`.
    /// Continues advancing the same global `_currentL2toL1Call` cursor that the outer frame
    /// was using; outer resumes from `cursor + nested.callCount` after the nested returns.
    /// See `ExecutionEntry` natspec for the partition invariant.
    uint256 callCount;
    bytes returnData;
}

/// @notice Pre-computed result for a reentrant lookup triggered DURING an execution — either a
///         failed reentrant call (caller catches the revert) or a read-only reentrant STATICCALL.
/// @dev Lives on the entry as `expectedLookupCalls[]`; each `L2ToL1Call` owns a contiguous slice
///      (`l2toL1LookupCallIndex` .. `+l2toL1LookupCallCount`). Matched within that slice by
///      `crossChainCallHash` (its preimage already binds the target rollup, so `destinationRollupId`
///      is informational). Unlike `LookupCall`, there is no sub-call replay — the entry's main
///      rolling hash already covers everything that ran.
struct ExpectedL1ToL2Lookup {
    bytes32 crossChainCallHash;
    uint256 destinationRollupId;
    bytes returnData;
    bool failed;
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
///      executeL2TX). On EEZL2 there's less flexibiltiy, since the current implementation is a simple list
///      instead to a per-rollup list, since it's not expected to have "multiple" orders or possible executions.
///      Those should be "managed" by the chain operator properly, therefore the destinationRollupId is not used in
///      the current implementation

///
/// @dev **`callCount` — flat-calls + nesting partition.**
///      `calls[]` is the FULL flat list of every call this entry will execute, in execution
///      order. It is partitioned between the entry's outermost frame and any reentrant
///      (nested) frames triggered during execution:
///        - `callCount`                = iterations the entry's TOP-LEVEL `_processNCalls` runs.
///        - `nestedActions[i].callCount` = iterations the i-th nested frame's `_processNCalls` runs.
///      And the invariant after the entry finishes:
///        callCount + Σ nestedActions[i].callCount == calls.length
///      The on-chain `_currentL2toL1Call` cursor advances monotonically over `calls[]` —
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
///        and `_currentL2toL1Call == 5` at the end (the `UnconsumedCalls` guard checks this).
struct ExecutionEntry {
    StateDelta[] stateDeltas; // initial state --> Final state
    bytes32 proxyEntryHash; // hashed call (l1 -> L2) itherwise bytes32(0) for L2 txs
    uint256 destinationRollupId;
    /// All calls executed by this entry, flat, in execution order. Partitioned between
    /// the entry's outermost frame and any reentrant (nested) frames — see the natspec
    /// above for the `callCount` partition invariant.
    L2ToL1Call[] L2ToL1Calls;
    /// Parallel partition table: each `ExpectedL1ToL2Call` consumes a slice of `calls[]` during
    /// a reentrant frame. Consumed sequentially as reentrant SUCCESS calls fire.
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;
    /// Reentrant LOOKUP table (failed reentry + read-only static reentry). Content-addressed by
    /// `crossChainCallHash` within the slice owned by each `L2ToL1Call`
    /// (`l2toL1LookupCallIndex` / `l2toL1LookupCallCount`).
    ExpectedL1ToL2Lookup[] expectedLookupCalls;
    /// Top-level iterations. Together with `expectedL1ToL2Calls[i].callCount`, partitions `calls[]`
    /// across the execution tree. See the natspec above.
    uint256 callCount;
    bytes returnData;
    bytes32 rollingHash;
}

/// @notice (rollupId, expected state root) pair binding a directly-executed `LookupCall` to a
///         specific on-chain state.
struct RollupStateRoot {
    uint256 rollupId;
    bytes32 stateRoot;
}

/// @notice Pre-computed result for a DIRECTLY-EXECUTED (top-level) lookup call or reverting call.
/// @dev Used for top-level read-only calls and for top-level calls whose revert is replayed.
///      Reentrant lookups now live on the entry as `ExpectedL1ToL2Lookup` instead. Loaded via
///      postAndVerifyBatch (L1) or loadExecutionTable (L2). All proxies referenced by `calls`
///      must be deployed before staticCallLookup is called.
struct LookupCall {
    bytes32 crossChainCallHash;
    /// Rollup whose `lookupQueue` this entry is routed to on L1 (per-rollup queue model).
    /// On L2 there's a single rollup, so the field is unused by the on-chain execution
    /// path — same semantic as `ExecutionEntry.destinationRollupId`.
    uint256 destinationRollupId;
    bytes returnData;
    bool failed;
    /// Optional sub-calls to replay in static context (no `revertSpan` allowed). Empty
    /// `calls[]` means the cached `returnData` / `failed` bypasses any sub-call replay.
    L2ToL1Call[] calls; // this works for jjust static but for revertet calls we need as well nested calls
    /// Expected hash of the sub-call results — checked at lookup time when `calls[]` is
    /// non-empty. See `_processNLookupCalls` for the hashing scheme.
    bytes32 rollingHash;
    /// State roots this lookup is bound to. On L1, each entry is checked against
    /// `rollups[rollupId].stateRoot` before the lookup resolves (reverts on mismatch). On L2
    /// (no state-root registry) the field is unused — same divergence as `stateDeltas`.
    RollupStateRoot[] rollupStateRoots;
}

/// @notice Stores the identity of an authorized CrossChainProxy
struct ProxyInfo {
    address originalAddress;
    uint64 originalRollupId;
}

/// @title IEEZ
/// @notice Interface for cross-chain manager contracts (L1 EEZ and L2 EEZL2)
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
