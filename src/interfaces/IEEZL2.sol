// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// ─────────────────────────────────────────────────────────────────────────────
//  IEEZL2 — L2 (EEZL2) execution structs. The `IEEZ` interface itself (implemented
//  by both EEZ contracts) and the L1 counterpart structs live in `IEEZ.sol`.
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
//  (no `StateUpdate`, `destinationRollupId`, or `ExpectedStateRootPerRollup`). L2
//  never hashes a whole entry/static entry, so its layout is free to diverge from L1's.
//
//  Casing: types/events/errors are PascalCase (`CrossChainCall`,
//  `CrossChainCallExecuted`, `EntryNotFound`); variables / struct fields / params are
//  mixedCase (`incomingCalls`, `expectedOutgoingCalls`, `_lastOutgoingCallConsumed`).
// ─────────────────────────────────────────────────────────────────────────────

/// @notice A cross-chain call executed on this L2 (sourced from a remote rollup).
/// @dev Field layout is identical to L1's `L2ToL1Call`.
struct CrossChainCall {
    uint16 revertNextNCalls; // number of consecutive calls (this one included) to revert after being executed; 0 = none. Used when the revert is triggered on the other chain (the calls ran, but were rolled back on the source's network)
    bool isStatic; // whether to execute via STATICCALL (read-only, no value)
    uint64 gas; // gas limit for the target call; 0 = forward all remaining gas
    address sourceAddress; // originating address on the source rollup
    uint64 sourceRollupId; // originating rollup
    address targetAddress; // call target on this L2
    uint256 value; // ether to send (0 when isStatic)
    bytes data; // calldata to execute on the target
}

/// @notice The pre-computed result of a reentrant cross-chain call fired from this L2 toward another
///         rollup during execution — resolved locally against the current execution entry.
///         `expectedOutgoingHash` is `keccak256(crossChainCallHash, _rollingHash)`: the call hash
///         folds the whole call's params (`isStatic`, target rollup, ...), and the `_rollingHash`
///         at the fire point pins the exact execution position.
/// @dev Resolving a match runs its `incomingCalls[]` sub-calls:
///        - successful call: the sub-calls fold into the entry's rolling hash, wrapped in
///          NESTED_BEGIN / NESTED_END, and `returnData` is returned;
///        - static read: the sub-calls run via STATICCALL and are checked against
///          `revertedOrStaticRollingHash`, then `returnData` is returned (or reverted with, if `!success`);
///        - reverted call: the sub-calls run, are checked against `revertedOrStaticRollingHash`,
///          then everything reverts with `returnData`, rolling their state back.
struct ExpectedOutgoingCrossChainCall {
    bytes32 expectedOutgoingHash; // position key: keccak256(crossChainCallHash, expectedRollingHash)
    CrossChainCall[] incomingCalls; // the reentrant frame's own sub-calls, run to completion
    bytes32 revertedOrStaticRollingHash; // expected rolling hash of the frame's sub-calls for static reads / reverted calls; must be bytes32(0) for a successful call (checked on-chain)
    bool success; // indicates whether the reentrant call returns or reverts
    bytes returnData; // pre-computed return value (revert payload when !success)
}

/// @notice A pre-computed TOP-LEVEL execution entry. When `success` is true the top-level call returns
///         `returnData` (`executeCrossChainCall`); when false the entry is run, verified, then reverted with
///         `returnData` so all of its state effects roll back (the caller may try/catch). A top-level
///         STATICCALL is a `StaticExecutionEntry` instead. A `bytes32(0)` `proxyEntryHash` is unreachable
///         on L2 — there is no zero-hash consumption path (`executeL2Txs` is L1-only).
/// @dev `expectedOutgoingCalls[]` is the entry's SINGLE reentrant table: every reentrant call fired
///      anywhere during the entry resolves against it — including one fired by a sub-call inside a
///      reentrant frame, since an `ExpectedOutgoingCrossChainCall` cannot carry a child table of
///      its own (Solidity forbids recursive structs). Calls from different nesting levels cannot collide:
///      each call's key folds the `_rollingHash` at its fire point, which is unique to that execution position.
struct ExecutionEntry {
    bytes32 proxyEntryHash; // inbound proxy-entry call hash (crossChainCallHash); never bytes32(0) on L2
    CrossChainCall[] incomingCalls; // incoming calls to be executed, run in order; reentrant frames (nested outgoing calls) carry their own sub-arrays
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls; // pre-computed results for reentrant outgoing calls (successful, static, and reverted — one table)
    bytes32 rollingHash; // expected rolling hash, which contains all calls, their return/revert values and reentrant frames
    bool success; // indicates whether the entry returns or reverts
    bytes returnData; // pre-computed top-level return value (revert payload when !success)
}

/// @notice A pre-computed TOP-LEVEL static entry: a read-only cross-chain call resolved via
///         `staticCrossChainCall` OUTSIDE any execution, from the `staticEntries` pool.
///         Reverting top-level reads land here (`success == false`); state-changing top-level
///         calls are `ExecutionEntry`s.
/// @dev Field order mirrors `ExecutionEntry`; no reentrant table (a reentrant read re-enters the pool
///      as ANOTHER `StaticExecutionEntry`). Match: `proxyEntryHash` alone, same block as load only
///      (no pins on L2 — the block gate bounds staleness).
///      Referenced proxies must already be deployed (CREATE2 is unavailable inside a STATICCALL frame).
struct StaticExecutionEntry {
    bytes32 proxyEntryHash; // inbound proxy-entry call hash (crossChainCallHash); mirrors `ExecutionEntry.proxyEntryHash`
    CrossChainCall[] incomingCalls; // incoming calls to be executed read-only via STATICCALL, run in order (no reentrant frames)
    bytes32 rollingHash; // expected rolling hash, which contains all calls and their return/revert values (untagged static schema: keccak(prev, success, retData))
    bool success; // indicates whether resolution returns or reverts (false ⇒ reverts with `returnData`)
    bytes returnData; // pre-computed return value (revert payload when !success)
}
