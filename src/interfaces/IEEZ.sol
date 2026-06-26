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
    uint256 rollupId;
    uint64[] proofSystemIndexes;
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
    ExecutionEntry[] entries;
    StaticLookup[] staticLookups;
    uint256 transientExecutionEntryCount;
    uint256 transientStaticLookupCount;
    address[] proofSystems;
    RollupIdWithProofSystems[] rollupIdsWithProofSystems;
    uint256[] blobIndices;
    bytes callData;
    bytes[] proofs;
    uint64 blockNumber;
}

/// @notice Rollup config in the central registry — just the state (root + ether balance) and the
///         manager pointer. Owner / threshold / vkeys live on the `rollupContract`.
struct RollupConfig {
    address rollupContract;
    bytes32 stateRoot;
    uint256 etherBalance;
}

/// @notice Per-rollup deferred-consumption queue + per-block reset marker.
/// @dev `lastVerifiedBlock` triples as: (a) reset marker — every verify wipes this rollup's queue +
///      cursor, so a same-block re-verify REPLACES the prior batch; (b) read gate — consumers require
///      `lastVerifiedBlock(rid) == block.number`, so a stale queue is never read; (c) lockout for
///      `setStateRoot` (reverts `RollupBatchActiveThisBlock` when == block.number).
struct RollupVerification {
    uint256 lastVerifiedBlock;
    ExecutionEntry[] executionQueue;
    StaticLookup[] staticLookupQueue;
    uint256 executionQueueIndex;
}

/// @notice A rollup's state transition for one entry.
/// @dev `currentState` (expected pre-state) is checked on-chain against `rollups[rollupId].stateRoot`
///      — content-addressing the entry to the proven trajectory, which is what lets the per-rollup
///      queues interleave safely.
struct StateDelta {
    uint256 rollupId;
    bytes32 currentState;
    bytes32 newState;
    int256 etherDelta;
}

/// @notice A cross-chain call executed on L1 (sourced from an L2 rollup).
/// @dev `isStatic` dispatches via STATICCALL (read-only, no value). `revertNextNCalls > 0` force-reverts
///      the state of the next N calls (this one included) — see `revertNextNCalls` handling in `EEZ`.
struct L2ToL1Call {
    bool isStatic;
    address targetAddress;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertNextNCalls;
}

/// @notice Pre-computed result for a reentrant cross-chain call (L1→L2) fired during execution.
///         One unified `expectedL1ToL2Calls[]` table holds every flavour — plain SUCCESS, read-only
///         STATIC (`isStatic`), and try/catch'd REVERTED (`!success`) — each content-addressed by
///         `(crossChainCallHash, expectedRollingHash)`. `expectedRollingHash` is `_rollingHash` at
///         the instant the call fires, which uniquely pins the execution point (the hash folds every
///         prior call / nesting boundary).
/// @dev Every flavour carries its OWN `l2ToL1Calls[]` sub-array, run to completion (no shared
///      partition). Resolution:
///        - SUCCESS  (`!isStatic && success`): `_resolveNestedReentrant` runs the sub-array as a
///          COMMITTING sub-execution, folding into the host's continuous hash between NESTED_BEGIN/END.
///        - STATIC   (`isStatic`): `staticCallLookup` runs the sub-array via STATICCALL (untagged
///          hash vs `rollingHash`) and returns `returnData` (reverts with it if `!success`).
///        - REVERTED (`!success && !isStatic`): `_resolveNestedReentrant` runs the sub-array as a
///          mini-entry (tagged hash vs `rollingHash`) then reverts.
/// @dev A reverted sub-execution reuses the host table for its own reentrant calls (Solidity forbids
///      recursive structs). Both flavours open the frame with NESTED_BEGIN(crossChainCallHash);
///      SUCCESS closes it with NESTED_END into the host's continuous hash, REVERTED's frame is rolled
///      back by its terminal revert.
/// @dev `destinationRollupId`: the rollup this call targets. Bound at `postAndVerifyBatch` (∈ host's
///      verified set) and re-checked at resolution (== the calling proxy's rollup).
// TODO we can add isStatic, crosschainCallHahs and expectedRollingHahs in the same hash, drop destinationRollupID
struct ExpectedL1ToL2Call {
    bytes32 crossChainCallHash;
    uint256 destinationRollupId;
    /// `_rollingHash` at the instant this call fires — the content-addressed position key.
    bytes32 expectedRollingHash;
    /// Read-only STATICCALL mode (resolved through `staticCallLookup`).
    bool isStatic;
    /// false ⇒ reverting mode (caller try/catches); on an `isStatic` entry, a static read that itself reverts.
    bool success;
    bytes returnData;
    /// The reentrant frame's own sub-calls, run to completion (success commits, reverted rolls back,
    /// static runs read-only). Empty for a no-op frame.
    L2ToL1Call[] l2ToL1Calls;
    /// Expected hash of the sub-calls — unused (0) for SUCCESS (folds into the host hash), checked
    /// standalone for STATIC (untagged) and REVERTED (tagged, seeded with `expectedRollingHash`).
    // @claude we shoudl rename this as, revertedOrStaticRollingHash
    bytes32 rollingHash;
}

/// @notice A pre-computed TOP-LEVEL execution entry. Always SUCCEEDS at the top level
///         (`executeCrossChainCall` returns `returnData`); reverting REENTRANT calls are `success == false`
///         `ExpectedL1ToL2Call`s and a top-level reverting read is a `StaticLookup`.
/// @dev TODO @claude we currently do not support calling L1→L2 and reverting at the top level.
/// Maybe we can skip entries that are success == false
struct ExecutionEntry {
    StateDelta[] stateDeltas; // true state transition ≥1 enforced on-chain
    bytes32 proxyEntryHash; // inbound proxy-entry call hash; bytes32(0) for L2 txs
    uint256 destinationRollupId; // routes to a per-rollup queue; must match the consumer's rollup
    bytes returnData; // pre-computed top-level return value
    L2ToL1Call[] l2ToL1Calls; // the entry's TOP-LEVEL calls (reentrant frames carry their own)
    ExpectedL1ToL2Call[] expectedL1ToL2Calls; // unified reentrant (L1→L2) table; see `ExpectedL1ToL2Call`
    bytes32 rollingHash; // expected rolling hash over all calls + nestings
}

/// @notice A rollup's expected state root, pinning a `StaticLookup` to a trajectory point.
/// @dev A candidate MATCHES only when every pin equals the live `rollups[rollupId].stateRoot`
///      (full scan — a mismatch skips the candidate, no revert). L1-only.
struct ExpectedStateRootPerRollup {
    uint256 rollupId;
    bytes32 stateRoot;
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
    uint256 destinationRollupId; // routes the pool entry; must match the calling proxy's rollup
    bool success; // false ⇒ resolution reverts with `returnData` instead of returning it
    bytes returnData; // pre-computed return value (revert payload when !success)
    L2ToL1Call[] l2ToL1Calls; // read-only sub-calls run via STATICCALL during resolution
    bytes32 rollingHash; // expected (untagged) rolling hash of the sub-calls
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
