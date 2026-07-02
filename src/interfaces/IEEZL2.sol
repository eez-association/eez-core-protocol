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
//      behalf of a remote caller (delivered through the caller's proxy). Each
//      frame carries its OWN flat array, walked by a plain local index.
//    - an `expectedOutgoingCalls[]` entry is the pre-computed result of a
//      reentrant cross-chain call fired FROM this L2 toward a remote rollup
//      during execution (forward-scanned by the `_lastOutgoingCallConsumed` cursor).
//
//  Deliberately LEANER than L1's structs: L2 has a single rollup, no state deltas,
//  and no per-rollup queue interleaving, so the L1-only fields are dropped entirely
//  (no `StateDelta`, `destinationRollupId`, or `ExpectedStateRootPerRollup`). L2
//  never hashes a whole entry/lookup, so its layout is free to diverge from L1's.
//
//  Casing: types/events/errors are PascalCase (`CrossChainCall`, `OutgoingCallConsumed`,
//  `UnconsumedOutgoingCalls`); variables / struct fields / params are mixedCase
//  (`incomingCalls`, `expectedOutgoingCalls`, `_lastOutgoingCallConsumed`).
// ─────────────────────────────────────────────────────────────────────────────

/// @notice A cross-chain call executed on this L2 (sourced from a remote rollup).
/// @dev `isStatic` dispatches via STATICCALL (read-only, no value). `revertNextNCalls > 0`
///      force-reverts the state of the next N calls (this one included) — see `revertNextNCalls`
///      handling in `EEZL2`. Field layout is identical to L1's `L2ToL1Call`.
struct CrossChainCall {
    uint16 revertNextNCalls; // >0 force-reverts the next N calls (this one included)
    bool isStatic; // dispatch via STATICCALL (read-only, no value)
    address sourceAddress; // originating address on the source rollup
    uint64 sourceRollupId; // originating rollup
    address targetAddress; // call target on this L2
    uint256 value; // ether to send (0 when isStatic)
    bytes data; // calldata
}

/// @notice Pre-computed result for a reentrant cross-chain call (outgoing, leaving this L2) fired
///         during execution. One unified `expectedOutgoingCalls[]` table holds every flavour —
///         plain SUCCESS, read-only STATIC, and try/catch'd REVERTED (`!success`) — each
///         content-addressed by a single `expectedOutgoingHash == keccak256(crossChainCallHash,
///         expectedRollingHash)`. `crossChainCallHash` folds `isStatic` (a static read keys
///         distinctly from a state-changing call) plus the routed rollup, so neither needs its own
///         field; `expectedRollingHash` is `_rollingHash` at the instant the call fires, which
///         uniquely pins the execution point (the hash folds every prior call / nesting boundary).
/// @dev Every flavour carries its OWN `incomingCalls[]` sub-array, run to completion (no shared
///      partition / `callCount`). Resolution:
///        - SUCCESS  (call key, `success`): `_resolveNestedReentrant` runs the sub-array as a
///          COMMITTING sub-execution, folding into the host's continuous hash between NESTED_BEGIN/END.
///        - STATIC   (static key): `staticCallLookup` runs the sub-array via STATICCALL (untagged
///          hash vs `revertedOrStaticRollingHash`) and returns `returnData` (reverts with it if `!success`).
///        - REVERTED (call key, `!success`): `_resolveNestedReentrant` runs the sub-array as a
///          mini-entry (tagged hash vs `revertedOrStaticRollingHash`) then reverts.
/// @dev A reverted sub-execution reuses the host table for its own reentrant calls (Solidity forbids
///      recursive structs); the live `_rollingHash` folded into each key keeps the contexts distinct.
struct ExpectedOutgoingCrossChainCall {
    bytes32 expectedOutgoingHash; // position key: keccak256(crossChainCallHash, expectedRollingHash)
    CrossChainCall[] incomingCalls; // the reentrant frame's own sub-calls, run to completion
    bytes32 revertedOrStaticRollingHash; // expected sub-call rollingHash: checked for STATIC / REVERTED
    bool success; // indicates whether the reentrant call returns or reverts
    bytes returnData; // pre-computed return value (revert payload when !success)
}

/// @notice A pre-computed TOP-LEVEL execution entry. When `success` is true the top-level call returns
///         `returnData` (`executeCrossChainCall`); when false the entry is run, verified, then reverted with
///         `returnData` so all of its state effects roll back (the caller may try/catch). Reverting REENTRANT
///         calls are `success == false` `ExpectedOutgoingCrossChainCall`s and a top-level reverting read is a
///         `StaticLookup`. A `bytes32(0)` `proxyEntryHash` is unreachable on L2 — there is no zero-hash
///         consumption path (`executeL2Txs` is L1-only).
struct ExecutionEntry {
    bytes32 proxyEntryHash; // inbound proxy-entry call hash; never bytes32(0) on L2
    CrossChainCall[] incomingCalls; // the entry's TOP-LEVEL calls (reentrant frames carry their own)
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls; // unified reentrant table; see above
    bytes32 rollingHash; // expected rolling hash over all calls + nestings
    bool success; // indicates whether the entry returns or reverts
    bytes returnData; // pre-computed top-level return value (revert payload when !success)
}

/// @notice A pre-computed TOP-LEVEL static lookup: a read-only cross-chain call resolved via
///         `staticCallLookup` OUTSIDE any execution, from the persistent `staticLookups` pool.
///         Reverting top-level reads land here (`success == false`); state-changing top-level
///         calls are `ExecutionEntry`s.
/// @dev Field order mirrors `ExecutionEntry`; no reentrant table (a reentrant read re-enters the pool
///      as ANOTHER `StaticLookup`). Match: `proxyEntryHash` alone (L2 has no state roots to pin).
///      Referenced proxies must already be deployed (CREATE2 is unavailable inside a STATICCALL frame).
struct StaticLookup {
    bytes32 proxyEntryHash; // inbound proxy-entry call hash (mirrors `ExecutionEntry.proxyEntryHash`)
    CrossChainCall[] incomingCalls; // read-only sub-calls run via STATICCALL during resolution
    bytes32 rollingHash; // expected rolling hash of the sub-calls (untagged static schema: keccak(prev, success, retData))
    bool success; // indicates whether resolution returns or reverts (false ⇒ reverts with `returnData`)
    bytes returnData; // pre-computed return value (revert payload when !success)
}
