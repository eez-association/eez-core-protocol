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
//  (no `StateDelta`, `destinationRollupId`, or `ExpectedStateRootPerRollup`). L2
//  never hashes a whole entry/lookup, so its layout is free to diverge from L1's.
//
//  Casing: types/events/errors are PascalCase (`CrossChainCall`, `OutgoingCallConsumed`,
//  `UnconsumedOutgoingCalls`); variables / struct fields / params are mixedCase
//  (`incomingCalls`, `expectedOutgoingCalls`, `_currentIncomingCall`).
// ─────────────────────────────────────────────────────────────────────────────

/// @notice A cross-chain call executed within an execution entry
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

/// @notice NESTED lookup: the pre-computed result of a reentrant cross-chain call that is
///         looked up rather than executed — a reentrant STATICCALL (static mode) or a
///         reverting reentrant call the caller try/catches (reverted mode). Lives INSIDE the
///         entry (`ExecutionEntry.expectedLookups`) — entry-scoped by construction. Matched by
///         `(crossChainCallHash, callNumber, lastOutgoingCallConsumed)`.
/// @dev Reverted mode (`failed == true`) runs `incomingCalls` as a mini-entry (tagged hash
///      schema, partitioned by `callCount` against `expectedOutgoingCalls`) then reverts with
///      `returnData`; static mode runs them via STATICCALL (untagged schema) and returns
///      it. A reverted lookup's own deeper lookups resolve from the SAME host table (Solidity
///      forbids recursive structs) — the prover must keep keys collision-free across the
///      entry and its execution contexts.
struct ExpectedLookup {
    bytes32 crossChainCallHash;
    bytes returnData;
    bool failed;
    /// `_currentIncomingCall` at observation (1-indexed; a sub-execution's fresh sub-cursor inside one).
    uint64 callNumber;
    /// `_lastOutgoingCallConsumed` at observation.
    uint64 lastOutgoingCallConsumed;
    /// Execution context at observation: 0 = fired at entry/host level; k = fired inside the
    /// sub-execution of `expectedLookups[k-1]` of the same host. Makes the key context-unambiguous
    /// (enforced — no longer a prover convention).
    uint64 executingLookupIndex;
    /// Sub-calls executed at resolution: STATICCALL (static mode) or real calls (reverted mode).
    CrossChainCall[] incomingCalls;
    /// Reverted-mode reentrant table for the sub-execution. Empty for static mode.
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls;
    /// Reverted-mode top-level iterations over `incomingCalls[]` (0 for static mode).
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
    /// Nested lookups (reentrant static reads + try/catch'd reverting reentrant calls)
    /// consumed during this entry — entry-scoped; see `ExpectedLookup`.
    ExpectedLookup[] expectedLookups;
    /// Top-level iterations. Together with `expectedOutgoingCalls[i].callCount`, partitions
    /// `incomingCalls[]` across the execution tree. See the natspec above.
    uint256 callCount;
    bytes returnData;
    bytes32 rollingHash;
}

/// @notice TOP-LEVEL lookup: the pre-computed result of a top-level cross-chain call that is
///         looked up rather than executed — a read-only call resolved via `staticCallLookup`,
///         or a reverting call executed via `_tryRevertedTopLevelLookup`. Lives in the
///         persistent `lookupCalls` table and is consumable ONLY outside an execution
///         (`!_insideExecution()`). Nested lookups live inside
///         `ExecutionEntry.expectedLookups` instead — see `ExpectedLookup`.
/// @dev Match key: `crossChainCallHash` alone (L2 has no state roots, so no pins). Failed
///      mode (`failed == true`) runs its sub-execution as a mini-entry (`incomingCalls`
///      partitioned by `callCount` against `expectedOutgoingCalls`, nested lookups from its
///      own `expectedLookups` table), then reverts with `returnData`. Static mode runs
///      `incomingCalls` via STATICCALL (untagged schema) and returns `returnData` (or reverts
///      with it when `failed`). All proxies referenced by `incomingCalls` must be deployed
///      before static resolution. Loaded via loadExecutionTable / executeIncomingCrossChainCall.
struct LookupCall {
    bytes32 crossChainCallHash;
    bytes returnData;
    bool failed;
    /// Sub-calls executed during resolution. Static mode: STATICCALL, no `revertSpan`.
    /// Reverted mode: real calls (may host reentry and `revertSpan`), partitioned
    /// against `expectedOutgoingCalls` exactly like `ExecutionEntry.incomingCalls`.
    CrossChainCall[] incomingCalls;
    /// Reverted-mode reentrant table for the sub-execution. Empty for static mode.
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls;
    /// Reverted-mode nested lookups consumed during the sub-execution (the sub-execution's own flat table —
    /// deeper reverted-lookup executions resolve from this same table). Empty for static mode.
    ExpectedLookup[] expectedLookups;
    /// Reverted-mode top-level iterations over `incomingCalls[]` (the entry-style `callCount`
    /// partition). Zero for static mode.
    uint256 callCount;
    /// Expected rolling hash of the executed sub-calls — always checked (an empty
    /// `incomingCalls[]` must carry `rollingHash == 0`). Untagged schema in static mode
    /// (`_processNLookupCalls`); tagged entry schema in reverted mode.
    bytes32 rollingHash;
}
