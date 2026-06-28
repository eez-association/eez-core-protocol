// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
//  IEEZ — shared cross-chain interface + L1 (EEZ) execution structs.
//
//  Direction (L1, absolute): an `L2ToL1Call` is executed ON L1; an `ExpectedL1ToL2Call` is a
//  reentrant call LEAVING L1 during execution. The mirror-image L2 structs live in `IEEZL2.sol`
//  with self-relative names and a leaner layout (no `StateDelta` / state-root pins).
// ─────────────────────────────────────────────────────────────────────────────

/// @notice A participating rollup + the subset of the batch's `proofSystems[]` it accepts.
/// @dev `proofSystemIndexes[]`: strictly-increasing indices into the batch's `proofSystems[]`,
///      resolved to PS addresses and handed to the rollup's `checkProofSystemsAndGetVkeys`.
struct RollupIdWithProofSystems {
    uint64 rollupId; // the participating rollup
    uint64[] proofSystemIndexes; // strictly-increasing indices into the batch's `proofSystems[]`
}

/// @notice One batch's payload — proof systems jointly attesting a set of rollups' state transitions.
/// @dev `rollupIdsWithProofSystems` and `proofSystems` are both strictly increasing (sorted, deduped,
///      rejects address(0)); together with the once-per-block-per-rollup invariant this stops a batch
///      from verifying a rollup twice. Each rollup's `proofSystemIndexes[]` is strictly increasing in
///      `[0, proofSystems.length)` and must meet that rollup's threshold (checked by its manager).
/// @dev `blobIndices` picks the tx-level EIP-4844 blobs; `callData` is batch-scoped.
///      `transientExecutionEntryCount` / `transientStaticLookupCount` are unproven dispatch params
///      (tune the transient/persistent split without re-proving). `blockNumber` binds the whole batch
///      to one L1 block (0 = none, type(uint64).max = latest).
struct ProofSystemBatchPerVerificationEntries {
    ExecutionEntry[] entries; // execution entries
    StaticLookup[] staticLookups; // top-level static-lookup
    uint256 transientExecutionEntryCount; // leading entries loaded transiently
    uint256 transientStaticLookupCount; // leading static lookups loaded transiently
    address[] proofSystems; // strictly increasing, no address(0)
    RollupIdWithProofSystems[] rollupIdsWithProofSystems; // strictly increasing by rollupId
    uint256[] blobIndices; // tx-level EIP-4844 blobs this batch consumes
    bytes callData; // batch-scoped calldata
    bytes[] proofs; // one proof per `proofSystems` entry
    uint64 blockNumber; // block binding: 0 = none, type(uint64).max = latest
}

/// @notice Rollup config in the central registry — just the state (root + ether balance) and the
///         manager pointer. Owner / threshold / vkeys live on the `rollupContract`.
struct RollupConfig {
    address rollupContract; // per-rollup manager (owner / threshold / vkeys live here)
    bytes32 stateRoot; // current state root
    uint256 etherBalance; // rollup's ether balance
}

/// @notice Per-rollup verification record (`verificationByRollup[rollupId]`): the batch's entries
///         awaiting consumption, a cursor tracking how far the queue has been consumed, and the block
///         the rollup was last verified in. A verified batch leaves its entries here to be pulled later
///         in the SAME block by proxy calls / `executeL2Txs`, rather than executing them inline.
/// @dev `lastVerifiedBlock`:
///      (a) reset marker — every batch touching this rollup first wipes its queues + cursor, so a
///          same-block re-verify REPLACES the prior batch instead of appending to it;
///      (b) read gate — consumers require `lastVerifiedBlock == block.number`, so a stale queue left
///          over from an earlier block is never read;
///      (c) `setStateRoot` lockout — reverts `RollupBatchActiveThisBlock` while `== block.number`.
struct RollupVerification {
    uint64 lastVerifiedBlock; // block of the last verified batch
    uint64 executionQueueIndex; // how many `executionQueue` entries have been consumed (packed with above)
    ExecutionEntry[] executionQueue; // entries awaiting consumption this block
    StaticLookup[] staticLookupQueue; // static lookups awaiting resolution this block
}

/// @notice A rollup's state transition for one entry.
/// @dev `currentState` (expected pre-state) is checked on-chain against `rollups[rollupId].stateRoot`
///      — content-addressing the entry to the proven trajectory, which is what lets the per-rollup
///      queues interleave safely.
struct StateDelta {
    uint64 rollupId; // the rollup this delta applies to
    bytes32 currentState; // expected pre-state, checked against `rollups[rollupId].stateRoot`
    bytes32 newState; // post-execution state root
    int256 etherDelta; // signed ether change for this rollup
}

/// @notice A cross-chain call executed on L1 (sourced from an L2 rollup).
/// @dev `isStatic` dispatches via STATICCALL (read-only, no value). `revertNextNCalls > 0` force-reverts
///      the state of the next N calls (this one included) — see `revertNextNCalls` handling in `EEZ`.
struct L2ToL1Call {
    uint16 revertNextNCalls; // >0 force-reverts the next N calls (this one included)
    bool isStatic; // dispatch via STATICCALL (read-only, no value)
    address sourceAddress; // originating address on the source rollup
    uint64 sourceRollupId; // originating rollup
    address targetAddress; // call target on L1
    uint256 value; // ether to send (0 when isStatic)
    bytes data; // calldata
}

/// @notice Pre-computed result for a reentrant cross-chain call (L1→L2) fired during execution.
///         One unified `expectedL1ToL2Calls[]` table holds every flavour — plain SUCCESS, read-only
///         STATIC, and try/catch'd REVERTED (`!success`) — each content-addressed by a single
///         `expectedL1toL2Hash == keccak256(crossChainCallHash, expectedRollingHash)`. `crossChainCallHash`
///         folds `isStatic` (a static read keys distinctly from a state-changing call) plus the
///         routed rollup, so neither needs its own field; `expectedRollingHash` is `_rollingHash` at
///         the instant the call fires, which uniquely pins the execution point (the hash folds every
///         prior call / nesting boundary).
/// @dev Every flavour carries its OWN `l2ToL1Calls[]` sub-array, run to completion (no shared
///      partition). Resolution:
///        - SUCCESS  (call key, `success`): `_resolveNestedReentrant` runs the sub-array as a
///          COMMITTING sub-execution, folding into the host's continuous hash between NESTED_BEGIN/END.
///        - STATIC   (static key): `staticCallLookup` runs the sub-array via STATICCALL (untagged
///          hash vs `rollingHash`) and returns `returnData` (reverts with it if `!success`).
///        - REVERTED (call key, `!success`): `_resolveNestedReentrant` runs the sub-array as a
///          mini-entry (tagged hash vs `rollingHash`) then reverts.
/// @dev A reverted sub-execution reuses the host table for its own reentrant calls (Solidity forbids
///      recursive structs). Both flavours open the frame with NESTED_BEGIN(crossChainCallHash);
///      SUCCESS closes it with NESTED_END into the host's continuous hash, REVERTED's frame is rolled
///      back by its terminal revert.
struct ExpectedL1ToL2Call {
    bytes32 expectedL1toL2Hash; // position key: keccak256(crossChainCallHash, expectedRollingHash)
    L2ToL1Call[] l2ToL1Calls; // the reentrant frame's own sub-calls, run to completion
    bytes32 revertedOrStaticRollingHash; // expected middle-call rollingHash: checked for STATIC / REVERTED
    bool success; // indicates whether the reentrant call returns or reverts
    bytes returnData; // pre-computed return value (revert payload when !success)
}

/// @notice A pre-computed TOP-LEVEL execution entry. When `success` is true the top-level call returns
///         `returnData` (`executeCrossChainCall`); when false the entry is run, verified, then reverted with
///         `returnData` so all of its state effects roll back (the caller may try/catch). Reverting REENTRANT
///         calls are `success == false` `ExpectedL1ToL2Call`s and a top-level reverting read is a `StaticLookup`.
struct ExecutionEntry {
    StateDelta[] stateDeltas; // the entry's true state transition (≥1, enforced on-chain)
    bytes32 proxyEntryHash; // inbound proxy-entry call hash; bytes32(0) for L2 txs
    uint64 destinationRollupId; // routes to a per-rollup queue; must match the consumer's rollup
    L2ToL1Call[] l2ToL1Calls; // the entry's TOP-LEVEL calls (reentrant frames carry their own)
    ExpectedL1ToL2Call[] expectedL1ToL2Calls; // unified reentrant (L1→L2) table; see `ExpectedL1ToL2Call`
    bytes32 rollingHash; // expected rolling hash over all calls + nestings
    bool success; // indicates whether the entry returns or reverts
    bytes returnData; // pre-computed top-level return value (revert payload when !success)
}

/// @notice A rollup's expected state root, pinning a `StaticLookup` to a trajectory point.
/// @dev A candidate MATCHES only when every pin equals the live `rollups[rollupId].stateRoot`
///      (full scan — a mismatch skips the candidate, no revert). L1-only.
struct ExpectedStateRootPerRollup {
    uint64 rollupId; // the pinned rollup
    bytes32 stateRoot; // must equal live `rollups[rollupId].stateRoot` for the match
}

/// @notice A pre-computed TOP-LEVEL static lookup: a read-only cross-chain call resolved via
///         `staticCallLookup` OUTSIDE any execution, from the pool (`_transientStaticLookups` /
///         per-rollup `staticLookupQueue`). Reverting top-level reads land here; state-changing ones
///         are `ExecutionEntry`s.
/// @dev Field order mirrors `ExecutionEntry`; no reentrant table (a reentrant read re-enters the pool
///      as ANOTHER `StaticLookup`). Match: `proxyEntryHash` + `destinationRollupId` + all
///      `expectedStateRoots` pins live (full scan). Referenced proxies must already be deployed.
struct StaticLookup {
    ExpectedStateRootPerRollup[] expectedStateRoots; // state-root pins — part of the MATCH predicate
    bytes32 proxyEntryHash; // inbound proxy-entry call hash (mirrors `ExecutionEntry.proxyEntryHash`)
    uint64 destinationRollupId; // routes the pool entry; must match the calling proxy's rollup
    bool success; // indicates whether resolution returns or reverts (false ⇒ reverts with `returnData`)
    bytes returnData; // pre-computed return value (revert payload when !success)
    L2ToL1Call[] l2ToL1Calls; // read-only sub-calls run via STATICCALL during resolution
    bytes32 rollingHash; // expected rolling hash of the sub-calls (untagged static schema: keccak(prev, success, retData))
}

/// @notice Stores the identity of an authorized CrossChainProxy
/// @dev Direction-neutral — shared by the L1 (`EEZ`) and L2 (`EEZL2`) managers via the
///      `EEZBase` proxy registry.
struct ProxyInfo {
    bool isProxy; // existence flag, set on registration
    address originalAddress; // Address this proxy points to
    uint64 originalRollupId; // Rollup this proxy points to
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
    function createCrossChainProxy(address originalAddress, uint64 originalRollupId) external returns (address proxy);
    function computeCrossChainProxyAddress(address originalAddress, uint64 originalRollupId)
        external
        view
        returns (address);
}
