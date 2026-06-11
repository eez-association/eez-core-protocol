// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
//  IEEZL2 — L2 (EEZL2) execution structs.
//
//  L2 uses SELF-RELATIVE directional names, mirroring L1's directional style
//  (L1: `l2ToL1Calls` / `expectedL1ToL2Calls`). An L2's cross-chain counterparty
//  can be ANY rollup — L1 (mainnet) OR another L2 — so absolute names like
//  `l1ToL2Calls` would bake in a direction that is frequently wrong. Naming the
//  direction relative to THIS chain stays correct for every counterparty:
//    - an `incomingCalls[]` entry is a cross-chain call executed ON this L2 on
//      behalf of a remote caller (delivered through the caller's proxy). The
//      flat array is walked by the `_currentIncomingCall` cursor.
//    - an `expectedOutgoingCalls[]` entry is the pre-computed result of a
//      reentrant cross-chain call fired FROM this L2 toward a remote rollup
//      during execution (counted by the `_lastOutgoingCallConsumed` cursor).
//
//  Deliberately LEANER than L1's structs: L2 has a single rollup, no state deltas,
//  and no per-rollup queue interleaving, so the L1-only fields are dropped entirely
//  (no `StateDelta`, `destinationRollupId`, or `ExpectedQueueIndexPerRollup`). L2
//  never hashes a whole entry/lookup, so its layout is free to diverge from L1's.
//
//  Casing: types/events/errors are PascalCase (`CrossChainCall`, `OutgoingCallConsumed`,
//  `UnconsumedOutgoingCalls`); variables / struct fields / params are mixedCase
//  (`incomingCalls`, `expectedOutgoingCalls`, `_currentIncomingCall`).
// ─────────────────────────────────────────────────────────────────────────────

/// @notice A cross-chain call executed/replayed within an execution entry
/// @dev revertSpan > 0 opens an isolated revert context spanning the next revertSpan calls (including this one)
struct CrossChainCall {
    address targetAddress;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;
}

/// @notice Pre-computed result for a successful reentrant outgoing cross-chain call triggered during execution
/// @dev Consumed sequentially from the entry's `expectedOutgoingCalls` array. If an outgoing call itself
///      triggers another reentrant call, it consumes the next element in the same flat array.
/// @dev All entries here must succeed. Failed calls should use LookupCall instead.
/// @dev Position in the execution tree (call index, outgoing index, parent context)
///      is folded into the rolling hash rather than stored as explicit fields.
struct ExpectedOutgoingCrossChainCall {
    bytes32 crossChainCallHash;
    /// Iterations the reentrant frame's `_processNCalls` runs over the parent entry's `incomingCalls[]`.
    /// Continues advancing the same global `_currentIncomingCall` cursor that the outer frame
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
///
/// @dev **`callCount` — flat-calls + reentrancy partition.**
///      `incomingCalls[]` is the FULL flat list of every call this entry will execute, in
///      execution order. It is partitioned between the entry's outermost frame and any
///      reentrant (outgoing) frames triggered during execution:
///        - `callCount`                          = iterations the entry's TOP-LEVEL `_processNCalls` runs.
///        - `expectedOutgoingCalls[i].callCount` = iterations the i-th reentrant frame's `_processNCalls` runs.
///      And the invariant after the entry finishes:
///        callCount + Σ expectedOutgoingCalls[i].callCount == incomingCalls.length
///      The on-chain `_currentIncomingCall` cursor advances monotonically over `incomingCalls[]` —
///      there's only one cursor across the whole tree. When a top-level call triggers a reentrant
///      cross-chain proxy invocation, control re-enters via `executeCrossChainCall`
///      → `_consumeNestedAction`, which calls `_processNCalls(expectedOutgoingCalls[i].callCount)`
///      on the SAME `incomingCalls[]` array, advancing the same cursor. Outer iteration resumes
///      where the cursor left off after the reentrant frame returns.
///
///      Worked example. `incomingCalls.length = 5`:
///        - call 0: top-level, no reentry.
///        - call 1: top-level, triggers a reentrant call → matched against `expectedOutgoingCalls[0]`,
///                  whose `callCount = 2` consumes calls 2 and 3 inside the reentrant frame.
///        - call 4: top-level, no reentry.
///      ⇒ `entry.callCount = 3` (calls 0, 1, 4 at the outer frame),
///        `expectedOutgoingCalls[0].callCount = 2` (calls 2, 3 inside the reentrant frame),
///        and `_currentIncomingCall == 5` at the end (the `UnconsumedIncomingCalls` guard checks this).
struct ExecutionEntry {
    /// Hash of the inbound call. Never bytes32(0) on L2 — there is no zero-hash consumption
    /// path (`executeL2TX` is L1-only), and a zero-hash entry would block the table.
    bytes32 proxyEntryHash;
    /// All calls executed by this entry, flat, in execution order. Partitioned between
    /// the entry's outermost frame and any reentrant (outgoing) frames — see the natspec
    /// above for the `callCount` partition invariant.
    CrossChainCall[] incomingCalls;
    /// Parallel partition table: each `ExpectedOutgoingCrossChainCall` consumes a slice of `incomingCalls[]`
    /// during a reentrant frame. Order matches the order in which reentrant calls fire.
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls;
    /// Top-level iterations. Together with `expectedOutgoingCalls[i].callCount`, partitions
    /// `incomingCalls[]` across the execution tree. See the natspec above.
    uint256 callCount;
    bytes returnData;
    bytes32 rollingHash;
}

/// @notice Pre-computed result for a lookup call or a call that reverts.
/// @dev Two modes, split on `failed`:
///      - **Static (`failed == false`)** — read-only reentry resolved via `staticCallLookup`.
///        `incomingCalls[]` (if any) replay in STATICCALL context and are hashed into `rollingHash`
///        with the untagged static schema; reentry is encoded as *separate*
///        `LookupCall`s sharing the same `(callNumber, lastOutgoingCallConsumed)`.
///      - **Failed (`failed == true`)** — a reverting reentrant call resolved via the
///        `_consumeNestedAction` fallback. When it carries a sub-execution (`callCount > 0`),
///        it replays as a mini-entry: `incomingCalls[]` run as real calls and
///        `expectedOutgoingCalls[]` supply reentry, folded into `rollingHash` with the tagged
///        `CALL_*/NESTED_*` schema and checked like an entry, then the call reverts with
///        `returnData`.
///      Loaded via loadExecutionTable (L2). All proxies referenced by `incomingCalls` must be
///      deployed before resolution.
struct LookupCall {
    bytes32 crossChainCallHash;
    bytes returnData;
    bool failed;
    /// 1-indexed global call number — the value of `_currentIncomingCall` at the moment this
    /// lookup call was observed by the prover. Used as part of the lookup key in `staticCallLookup`
    /// and the failed-lookup-call fallback in `_consumeNestedAction`. For a static read
    /// observed *inside* a failed lookup's sub-execution, this is the failed lookup's fresh
    /// sub-cursor value. NOTE: the lookup key does NOT encode which context is active — the
    /// prover must keep keys collision-free across the entry and any failed-lookup
    /// sub-executions.
    uint64 callNumber;
    /// Disambiguates multiple lookup calls fired during the same outer call (e.g., a
    /// reentrant view query that triggers further static lookups). Matches
    /// `_lastOutgoingCallConsumed` at the moment of observation.
    uint64 lastOutgoingCallConsumed;
    /// Sub-calls replayed during resolution. Static mode: STATICCALL, no `revertSpan`.
    /// Failed mode: real calls (may host reentry and `revertSpan`), partitioned
    /// against `expectedOutgoingCalls` exactly like `ExecutionEntry.incomingCalls`.
    CrossChainCall[] incomingCalls;
    /// Failed-mode reentrant table — outgoing calls triggered while replaying `incomingCalls[]`.
    /// Reuses the entry struct and is consumed sequentially by `_consumeNestedAction` while
    /// `_insideFailedLookup` is set. Empty for static-mode lookups.
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls;
    /// Failed-mode top-level iterations over `incomingCalls[]` (the entry-style `callCount`
    /// partition: `callCount + Σ expectedOutgoingCalls[i].callCount == incomingCalls.length`).
    /// Zero for static-mode lookups.
    uint256 callCount;
    /// Expected rolling hash of the replayed sub-calls — checked at resolution when
    /// `incomingCalls[]` is non-empty. Static mode uses the untagged schema
    /// (`_processNLookupCalls`); failed mode uses the tagged entry schema (`_replayFailedLookup`).
    bytes32 rollingHash;
}
