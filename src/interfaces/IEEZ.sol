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
///         STATIC (`isStatic`), and try/catch'd REVERTED (`failed`) — each content-addressed by
///         `(crossChainCallHash, expectedRollingHash)`. `expectedRollingHash` is `_rollingHash` at
///         the instant the call fires, which uniquely pins the execution point (the hash folds every
///         prior call / nesting boundary).
/// @dev Every flavour carries its OWN `l2ToL1Calls[]` sub-array, run to completion (no shared
///      partition). Resolution:
///        - SUCCESS  (`!isStatic && !failed`): `_consumeNestedAction` runs the sub-array as a
///          COMMITTING sub-execution, folding into the host's continuous hash between NESTED_BEGIN/END.
///        - STATIC   (`isStatic`): `staticCallLookup` runs the sub-array via STATICCALL (untagged
///          hash vs `rollingHash`) and returns `returnData` (reverts with it if `failed`).
///        - REVERTED (`failed && !isStatic`): `_executeRevertedNestedLookup` runs the sub-array as a
///          mini-entry (tagged hash vs `rollingHash`, seeded with `expectedRollingHash`) then reverts.
/// @dev A reverted sub-execution reuses the host table for its own reentrant calls (Solidity forbids
///      recursive structs); SEEDING `_rollingHash` with this entry's `expectedRollingHash` gives each
///      context a distinct namespace. A success sub-execution needs no seed (continuous hash).
/// @dev `destinationRollupId`: the rollup this call targets. Bound at `postAndVerifyBatch` (∈ host's
///      verified set) and re-checked at resolution (== the calling proxy's rollup).
struct ExpectedL1ToL2Call {
    bytes32 crossChainCallHash;
    uint256 destinationRollupId;
    /// `_rollingHash` at the instant this call fires — the content-addressed position key.
    bytes32 expectedRollingHash;
    /// Read-only STATICCALL mode (resolved through `staticCallLookup`).
    bool isStatic;
    /// Reverting mode (caller try/catches). On an `isStatic` entry: a static read that itself reverts.
    bool failed;
    bytes returnData;
    /// The reentrant frame's own sub-calls, run to completion (success commits, reverted rolls back,
    /// static runs read-only). Empty for a no-op frame.
    L2ToL1Call[] l2ToL1Calls;
    /// Expected hash of the sub-calls — unused (0) for SUCCESS (folds into the host hash), checked
    /// standalone for STATIC (untagged) and REVERTED (tagged, seeded with `expectedRollingHash`).
    bytes32 rollingHash;
}

/// @notice A pre-computed top-level execution entry.
/// @dev Always SUCCEEDS at the top level (`executeCrossChainCall` returns `entry.returnData`); no
///      entry-level `failed` flag. Reverting REENTRANT calls are `failed` entries in
///      `expectedL1ToL2Calls`; a top-level reverting read is a `StaticLookup`. An inner call that
///      naturally reverts is still fine — the proxy `.call` returns `(false, retData)` captured via
///      `CALL_END`, and the entry still returns success. @claude currentl we do no support calling L1 to L2 and revert top level
/// @dev `l2ToL1Calls[]` is the entry's TOP-LEVEL calls only, run to completion; each reentrant frame
///      carries its own sub-array (no shared cursor partition, no `callCount`). `destinationRollupId`
///      routes the entry to a per-rollup queue and must match the consumer's rollup.
struct ExecutionEntry {
    /// The entry's true state transition (PROVER OBLIGATION). ≥1 delta is enforced on-chain
    /// (`_validateBatchStructure`), so every entry is state-pinned to the `StateRootMismatch` backstop.
    StateDelta[] stateDeltas;
    bytes32 proxyEntryHash; // hashed L1→L2 call, else bytes32(0) for L2 txs
    uint256 destinationRollupId;
    /// The entry's TOP-LEVEL calls (reentrant frames carry their own — see `ExpectedL1ToL2Call`).
    bytes returnData;
    L2ToL1Call[] l2ToL1Calls;
    /// Unified reentrant (L1→L2) table — success / static / reverted, matched by
    /// `(crossChainCallHash, expectedRollingHash)`. See `ExpectedL1ToL2Call`.
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;
    bytes32 rollingHash;
}

/// @notice A rollup's expected state root, pinning a `StaticLookup` to a trajectory point.
/// @dev A candidate MATCHES only when every pin equals the live `rollups[rollupId].stateRoot`
///      (full scan — a mismatch skips the candidate, no revert). L1-only.
struct ExpectedStateRootPerRollup {
    uint256 rollupId;
    bytes32 stateRoot;
}

/// @notice TOP-LEVEL STATIC lookup: a read-only cross-chain call resolved via `staticCallLookup`,
///         consumed OUTSIDE any execution (`!_insideExecution()`) from the pool
///         (`_transientStaticLookups` / per-rollup `staticLookupQueue`). The only top-level pooled
///         shape — a state-changing top-level call is a normal `ExecutionEntry`; reentrant calls
///         during execution live in `ExecutionEntry.expectedL1ToL2Calls`.
/// @dev No reentrant table: a reentrant call observed while resolving runs in STATICCALL context, so
///      it re-enters the pool branch and resolves as ANOTHER `StaticLookup`. Match key:
///      `crossChainCallHash` + `destinationRollupId == ` the calling proxy's rollup + all
///      `expectedStateRoots` pins live (full scan). Resolution runs `l2ToL1Calls` via STATICCALL
///      (untagged hash vs `rollingHash`) and returns `returnData` (or reverts with it if `failed`);
///      all referenced proxies must already be deployed.
struct StaticLookup {
    bytes32 crossChainCallHash;
    /// Publishing queue + resolution match (must equal the calling proxy's rollup — load-bearing for
    /// the un-routed transient pool). `postAndVerifyBatch` requires destination ∈ `expectedStateRoots`.
    uint256 destinationRollupId;
    bytes returnData;
    /// A read that itself reverts: resolution reverts with `returnData` instead of returning it.
    bool failed;
    /// Read-only sub-calls executed during resolution via STATICCALL (no `revertNextNCalls`, no value).
    L2ToL1Call[] l2ToL1Calls;
    /// Expected rolling hash of the executed sub-calls — always checked (an empty `l2ToL1Calls[]`
    /// must carry `rollingHash == 0`). Untagged static schema (`_processNStaticCalls`).
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
