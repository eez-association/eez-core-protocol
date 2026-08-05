// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// ─────────────────────────────────────────────────────────────────────────────
//  IEEZ — shared cross-chain interface + L1 (EEZ) execution structs.
//
//  Direction (L1, absolute): an `L2ToL1Call` is executed ON L1; an `ExpectedL1ToL2Call` is a
//  reentrant call LEAVING L1 during execution. The mirror-image L2 structs live in `IEEZL2.sol`
//  with self-relative names and a leaner layout (no `StateUpdate` / state-root pins).
// ─────────────────────────────────────────────────────────────────────────────

/// @notice A participating rollup + the subset of the batch's `proofSystems[]` it accepts.
struct RollupIdWithProofSystems {
    uint64 rollupId; // the rollup id
    uint64[] proofSystemIndexes; // indices into the batch's `proofSystems[]` selecting the systems this rollup will be verified against; strictly increasing
}

/// @notice A rollup's expected state root.
/// @dev A candidate matches when every pin equals the live `rollups[rollupId].stateRoot`.
struct ExpectedStateRootPerRollup {
    uint64 rollupId; // the rollup id
    bytes32 stateRoot; // the expected live state root
}

/// @notice One batch's payload — proof systems jointly attesting a set of rollups' state transitions.
/// @dev `rollupIdsWithProofSystems` and `proofSystems` are both strictly increasing (sorted, deduped,
///      rejects address(0)); together with the once-per-block-per-rollup invariant this stops a batch
///      from verifying a rollup twice. Each rollup's `proofSystemIndexes[]` is strictly increasing in
///      `[0, proofSystems.length)` and must meet that rollup's threshold (checked by its manager).
/// @dev `immediateEntryCount` / `immediateStaticEntryCount` are UNPROVEN dispatch params — not folded
///      into the public input, so the immediate/persistent split can be re-tuned without re-proving.
///      One invariant id enforced on-chain: the leading run of L2Txs always executes immediately.
struct ProofSystemBatchPerVerificationEntries {
    ExpectedStateRootPerRollup[] expectedStateRootPerRollup; // optional state-root assertions from the composer; any mismatch reverts the tx
    ExecutionEntry[] entries; // execution entries: immediate entries are executed in this call, remainder are saved in storage
    StaticExecutionEntry[] staticEntries; // top-level static entries
    uint256 immediateEntryCount; // number of leading `entries` executed this tx (immediate L2Txs + meta-hook (AA) entries, not queued)
    uint256 immediateStaticEntryCount; // number of leading `staticEntries`
    address[] proofSystems; // proof systems attesting this batch; strictly increasing, no address(0)
    RollupIdWithProofSystems[] rollupIdsWithProofSystems; // participating rollups + their accepted proof-system subsets; strictly increasing by rollupId
    uint256[] blobIndices; // indices of the tx's EIP-4844 blobs this batch consumes
    bytes callData; // batch-scoped calldata; its hash is folded into the public input
    bytes[] proofs; // one proof per `proofSystems` entry
    uint64 blockNumber; // L1 block the batch binds to (via `getCustomData`): 0 = none, type(uint64).max = latest
    bool bindMsgSenderInPublicInput; // true = fold msg.sender into the public input so only the submitter can land the batch (front-run protection); false = fold address(0) (anyone may submit)
}

/// @notice Rollup config in the central registry — just the state (root + ether balance) and the
///         manager pointer.
struct RollupConfig {
    address rollupContract; // per-rollup manager (owner / threshold / vkeys live here)
    bytes32 stateRoot; // current state root
    uint256 etherBalance; // rollup's ether balance
}

/// @notice Per-rollup verification record (`verificationByRollup[rollupId]`): the batch's entries
///         awaiting consumption, a cursor tracking how far the queue has been consumed, and the block
///         the rollup was last verified in. A verified batch leaves its entries here to be pulled later
///         in the SAME block by proxy calls / `executeL2Txs`, rather than executing them immediately.
/// @dev `lastVerifiedBlock`:
///      (a) reset marker — every batch touching this rollup first wipes its queues + cursor, so a
///          same-block re-verify REPLACES the prior batch instead of appending to it;
///      (b) read gate — consumers require `lastVerifiedBlock == block.number`, so a stale queue left
///          over from an earlier block is never read;
///      (c) `setStateRoot` lockout — reverts `RollupBatchActiveThisBlock` while `== block.number`.
struct RollupVerification {
    uint64 lastVerifiedBlock; // block of the last verified batch
    uint64 entryQueueIndex; // how many `entryQueue` entries have been consumed (packed with above)
    ExecutionEntry[] entryQueue; // entries awaiting consumption this block
    StaticExecutionEntry[] staticEntryQueue; // static entries awaiting resolution this block
}

/// @notice A rollup's state transition for one entry.
/// @dev The on-chain pre-state check content-addresses the entry to the proven trajectory, which
///      is what lets the per-rollup queues interleave safely.
struct StateUpdate {
    uint64 rollupId; // the rollup this update applies to
    bytes32 currentState; // expected pre-state, checked against `rollups[rollupId].stateRoot`
    bytes32 newState; // post-execution state root
    int256 etherDelta; // signed ether change for this rollup
}

/// @notice A cross-chain call executed on L1 (sourced from an L2 rollup).
struct L2ToL1Call {
    uint16 revertNextNCalls; // number of consecutive calls (this one included) to force-revert; 0 = none
    bool isStatic; // whether to execute via STATICCALL (read-only, no value)
    uint64 gas; // gas limit for the target call; 0 = forward all remaining gas
    address sourceAddress; // originating address on the source rollup
    uint64 sourceRollupId; // originating rollup
    address targetAddress; // call target on L1
    uint256 value; // ether to send (0 when isStatic)
    bytes data; // calldata to execute on the target
}

/// @notice Pre-computed result for a reentrant cross-chain call (L1→L2) fired during execution.
///         One unified `expectedL1ToL2Calls[]` table holds every kind — plain SUCCESS, read-only
///         STATIC, and try/catch'd REVERTED (`!success`) — each content-addressed by a single
///         `expectedL1toL2Hash == keccak256(crossChainCallHash, expectedRollingHash)`. `crossChainCallHash`
///         folds `isStatic` (a static read keys distinctly from a state-changing call) plus the
///         routed rollup, so neither needs its own field; `expectedRollingHash` is `_rollingHash` at
///         the instant the call fires, which uniquely pins the execution point (the hash folds every
///         prior call / nesting boundary).
/// @dev Every kind carries its OWN `l2ToL1Calls[]` sub-array, run to completion (no shared
///      partition). Resolution:
///        - SUCCESS  (call key, `success`): `_resolveNestedReentrant` runs the sub-array as a
///          COMMITTING sub-execution, folding into the host's continuous hash between NESTED_BEGIN/END.
///        - STATIC   (static key): `staticCrossChainCall` runs the sub-array via STATICCALL (untagged
///          hash vs `rollingHash`) and returns `returnData` (reverts with it if `!success`).
///        - REVERTED (call key, `!success`): `_resolveNestedReentrant` runs the sub-array as a
///          mini-entry (tagged hash vs `rollingHash`) then reverts.
/// @dev A reverted sub-execution reuses the host table for its own reentrant calls (Solidity forbids
///      recursive structs). Both kinds open the frame with NESTED_BEGIN(crossChainCallHash);
///      SUCCESS closes it with NESTED_END into the host's continuous hash, REVERTED's frame is rolled
///      back by its terminal revert.
struct ExpectedL1ToL2Call {
    bytes32 expectedL1toL2Hash; // position key: keccak256(crossChainCallHash, expectedRollingHash)
    L2ToL1Call[] l2ToL1Calls; // the reentrant frame's own sub-calls, run to completion
    bytes32 revertedOrStaticRollingHash; // expected rolling hash of the frame's sub-calls; checked only for STATIC / REVERTED kinds
    bool success; // indicates whether the reentrant call returns or reverts
    bytes returnData; // pre-computed return value (revert payload when !success)
}

/// @notice A pre-computed TOP-LEVEL execution entry. When `success` is true the top-level call returns
///         `returnData` (`executeCrossChainCall`); when false the entry is run, verified, then reverted with
///         `returnData` so all of its state effects roll back (the caller may try/catch). Reverting REENTRANT
///         calls are `success == false` `ExpectedL1ToL2Call`s and a top-level reverting read is a `StaticExecutionEntry`.
struct ExecutionEntry {
    StateUpdate[] stateUpdates; // per-rollup state updates — the entry's full state transition (≥1, enforced on-chain)
    bytes32 proxyEntryHash; // inbound proxy-entry call hash (crossChainCallHash); bytes32(0) for L2 txs
    L2ToL1Call[] l2ToL1Calls; // L2→L1 calls to be executed, run in order; reentrant frames (nested L1→L2 calls) carry their own sub-arrays
    ExpectedL1ToL2Call[] expectedL1ToL2Calls; // expected L1→L2 calls, each of those opens a reentrant frame
    bytes32 rollingHash; // expected rolling hash, which contains all calls, their return/revert values and reentrant frames
    uint64 destinationRollupId; // rollup whose queue this entry routes to; must match the consumer's rollup
    bool success; // indicates whether the entry returns or reverts
    bytes returnData; // pre-computed top-level return value (revert payload when !success)
}

/// @notice A pre-computed TOP-LEVEL static entry: a read-only cross-chain call resolved via
///         `staticCrossChainCall` OUTSIDE any execution, from the pool (`_transientStaticEntries` /
///         per-rollup `staticEntryQueue`). Reverting top-level reads land here; state-changing ones
///         are `ExecutionEntry`s.
/// @dev Field order mirrors `ExecutionEntry`; no reentrant table (a reentrant read re-enters the pool
///      as ANOTHER `StaticExecutionEntry`). Match: `proxyEntryHash` + `destinationRollupId` + all
///      `expectedStateRoots` pins live (full scan). Referenced proxies must already be deployed.
struct StaticExecutionEntry {
    ExpectedStateRootPerRollup[] expectedStateRoots; // expected live state roots per rollup; part of the MATCH predicate (full scan)
    bytes32 proxyEntryHash; // inbound proxy-entry call hash (crossChainCallHash); mirrors `ExecutionEntry.proxyEntryHash`
    L2ToL1Call[] l2ToL1Calls; // L2→L1 calls to be executed read-only via STATICCALL, run in order (no reentrant frames)
    bytes32 rollingHash; // expected rolling hash, which contains all calls and their return/revert values (untagged static schema: keccak(prev, success, retData))
    uint64 destinationRollupId; // rollup whose static pool this entry routes to; must match the calling proxy's rollup
    bool success; // indicates whether resolution returns or reverts (false ⇒ reverts with `returnData`)
    bytes returnData; // pre-computed return value (revert payload when !success)
}

/// @notice Stores the identity of an authorized CrossChainProxy
/// @dev Direction-neutral — shared by the L1 (`EEZ`) and L2 (`EEZL2`) managers via the
///      `EEZBase` proxy registry.
struct ProxyInfo {
    bool isProxy; // existence flag, set on registration
    address originalAddress; // address this proxy points to
    uint64 originalRollupId; // rollup this proxy points to
}

/// @title IEEZ
/// @notice Shared interface for the cross-chain managers (L1 `EEZ`, L2 `EEZL2`). Carries only
///         the functions both sides implement identically and that `CrossChainProxy` / `Bridge`
///         depend on. The L1 execution structs above are consumed by `EEZ.sol`; the mirror-image
///         L2 structs live in `IEEZL2.sol`.
interface IEEZ {
    /// @notice Executes a cross-chain call initiated by an authorized proxy.
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return result The pre-computed return data of the matched entry
    function executeCrossChainCall(address sourceAddress, bytes calldata callData)
        external
        payable
        returns (bytes memory result);

    /// @notice Resolves a read-only cross-chain call initiated by an authorized proxy.
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return result The pre-computed return data of the matched static entry
    function staticCrossChainCall(address sourceAddress, bytes calldata callData)
        external
        view
        returns (bytes memory result);

    /// @notice Creates the CrossChainProxy for an address on another rollup.
    /// @param originalAddress The address this proxy represents on the source rollup
    /// @param originalRollupId The source rollup ID
    /// @return proxy The deployed proxy address
    function createCrossChainProxy(address originalAddress, uint64 originalRollupId) external returns (address proxy);

    /// @notice Recipient of ether swept from proxies (ether sent to a proxy address before deployment).
    function RECOVERY_ADDRESS() external view returns (address);

    /// @notice Computes the deterministic CREATE2 address of the CrossChainProxy for an (address, rollup) pair.
    /// @param originalAddress The address this proxy represents on the source rollup
    /// @param originalRollupId The source rollup ID
    function computeCrossChainProxyAddress(address originalAddress, uint64 originalRollupId)
        external
        view
        returns (address);
}
