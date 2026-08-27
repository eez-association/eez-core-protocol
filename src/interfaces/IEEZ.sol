// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// ─────────────────────────────────────────────────────────────────────────────
//  IEEZ — the `IEEZ` interface + the structs the `EEZ` contract consumes: the
//  `postAndVerifyBatch` batch payload and the execution entries it carries.
// ─────────────────────────────────────────────────────────────────────────────

/// @notice A participating rollup + the subset of the batch's `proofSystems[]` it accepts.
struct RollupIdWithProofSystems {
    uint64 rollupId; // the rollup id
    uint64[] proofSystemIndexes; // indices into the batch's `proofSystems[]` selecting the proof systems this rollup will be verified against; strictly increasing
}

/// @notice A rollup's expected root.
/// @dev Matches when `root` equals the live `rollups[rollupId].root`. Used as a
///      batch-level assertion (mismatch reverts the tx) and as part of a static entry's
///      match predicate.
struct ExpectedRootPerRollup {
    uint64 rollupId; // the rollup id
    bytes32 root; // the expected live root
}

/// @notice One batch's payload: everything `postAndVerifyBatch` needs to verify the posted data
///         (blobs + `callData`) against the proof systems approved by each participating rollup,
///         plus the execution/static entries to run or queue once verified.
/// @dev `rollupIdsWithProofSystems` and `proofSystems` are both strictly increasing (sorted, deduped,
///      rejects address(0)), so one batch can never verify the same rollup or proof system twice.
///      Each rollup's `proofSystemIndexes[]` is strictly increasing in
///      `[0, proofSystems.length)` and must meet that rollup's threshold (checked by its rollup contract).
/// @dev `immediateEntryCount` / `immediateStaticEntryCount` are UNPROVEN dispatch params — not folded
///      into the public input, so the immediate/persistent split can be re-tuned without re-proving.
///      One invariant is enforced on-chain: the leading run of L2Txs always executes immediately.
struct ProofSystemBatchPerVerificationEntries {
    ExpectedRootPerRollup[] expectedRootPerRollup; // optional root assertions from the composer; any mismatch reverts the tx
    ExecutionEntry[] entries; // execution entries: immediate entries are executed in this call, remainder are saved in storage
    StaticExecutionEntry[] staticEntries; // top-level static entries
    uint256 immediateEntryCount; // number of leading `entries` executed this tx (immediate L2Txs + meta-hook entries, not queued)
    uint256 immediateStaticEntryCount; // number of leading `staticEntries` resolvable this tx via the meta hook; remainder saved to storage. Only loaded when the meta hook fires (≥1 non-L2Tx entry in the immediate prefix) — with a pure-L2Tx immediate prefix the leading static entries are dropped, so set 0 there
    address[] proofSystems; // proof systems attesting this batch; strictly increasing, no address(0)
    RollupIdWithProofSystems[] rollupIdsWithProofSystems; // participating rollups + their accepted proof-system subsets; strictly increasing by rollupId
    uint256[] blobIndices; // indices of the tx's EIP-4844 blobs this batch consumes
    bytes callData; // batch-scoped calldata; its hash is folded into the public input
    bytes[] proofs; // one proof per `proofSystems` entry
    uint64 blockNumber; // L1 block the batch binds to (via `getCustomData`): 0 = none, type(uint64).max = latest
    bool bindMsgSenderInPublicInput; // true = fold msg.sender into the public input so only the submitter can land the batch (front-run protection); false = fold address(0) (anyone may submit)
}

/// @notice Rollup config in the central registry — just the state (root + ether balance) and a
///         pointer to the rollup's own contract.
struct RollupConfig {
    address rollupContract; // the rollup's own contract (owner / threshold / vkeys live here)
    bytes32 root; // current root
    uint256 etherBalance; // rollup's ether balance
}

/// @notice Per-rollup verification record (`verificationByRollup[rollupId]`): the batch's entries
///         awaiting consumption, a cursor tracking how far the queue has been consumed, and the block
///         the rollup was last verified in. A verified batch leaves its non-immediate entries here to be pulled later
///         in the SAME block by proxy calls / `executeL2Txs`, rather than executing them immediately.
/// @dev `lastVerifiedBlock`:
///      (a) reset marker — every batch touching this rollup first wipes its queues + cursor, so a
///          same-block re-verify REPLACES the prior batch instead of appending to it;
///      (b) read gate — `entryQueue` consumers (`executeCrossChainCall` / `executeL2Txs`) require
///          `lastVerifiedBlock == block.number`, so a stale entry queue from an earlier block is never
///          read. The `staticEntryQueue` is EXEMPT: static entries stay resolvable across blocks for
///          as long as their root pins hold;
///      (c) `setRoot` lockout — reverts `RollupBatchActiveThisBlock` while `== block.number`.
struct RollupVerification {
    uint64 lastVerifiedBlock; // block of the last verified batch
    uint64 entryQueueIndex; // how many `entryQueue` entries have been consumed (packed with above)
    ExecutionEntry[] entryQueue; // entries awaiting consumption this block
    StaticExecutionEntry[] staticEntryQueue; // static entries awaiting resolution; not block-gated (matchable while their root pins hold)
}

/// @notice A rollup's state transition for one entry.
/// @dev `currentRoot` is re-checked against the live root when the entry is consumed, so an entry
///      only ever runs from the exact state it was proven against — which is what makes skipping or
///      orphaning queued entries safe.
struct RootUpdate {
    uint64 rollupId; // the rollup this update applies to
    int192 etherDelta; // net ether change for this rollup (negative when outflows exceed inflows for this entry); int192 far exceeds total ETH supply and packs with `rollupId` into one storage slot
    bytes32 currentRoot; // expected pre-state, checked against `rollups[rollupId].root`
    bytes32 newRoot; // post-execution root
}

/// @notice A cross-chain call executed on L1 on behalf of a caller from another rollup.
struct L2ToL1Call {
    uint16 revertNextNCalls; // number of consecutive calls (this one included) to revert after being executed; 0 = none. Used when the revert is triggered on the other chain (the calls ran, but were rolled back on the source's network)
    bool isStatic; // whether to execute via STATICCALL (read-only, no value)
    uint64 gas; // gas limit for the target call; 0 = forward all remaining gas
    address sourceAddress; // originating address on the source rollup
    uint64 sourceRollupId; // originating rollup
    address targetAddress; // call target on L1
    uint256 value; // ether to send (0 when isStatic)
    bytes data; // calldata to execute on the target
}

/// @notice The pre-computed result of a reentrant cross-chain call fired from L1 toward another
///         rollup during execution — resolved locally against the current execution entry.
///         `expectedL1toL2Hash` is `keccak256(crossChainCallHash, _rollingHash)`: the call hash
///         folds the whole call's params (`isStatic`, target rollup, ...), and the `_rollingHash`
///         at the fire point pins the exact execution position.
/// @dev Resolving a match runs its `l2ToL1Calls[]` sub-calls:
///        - successful call: the sub-calls fold into the entry's rolling hash, wrapped in
///          NESTED_BEGIN / NESTED_END, and `returnData` is returned;
///        - static read: the sub-calls run via STATICCALL and are checked against
///          `revertedOrStaticRollingHash`, then `returnData` is returned (or reverted with, if `!success`);
///        - reverted call: the sub-calls run, are checked against `revertedOrStaticRollingHash`,
///          then everything reverts with `returnData`, rolling their state back.
struct ExpectedL1ToL2Call {
    bytes32 expectedL1toL2Hash; // position key: keccak256(crossChainCallHash, expectedRollingHash)
    L2ToL1Call[] l2ToL1Calls; // the reentrant frame's own sub-calls, run as expected to completion
    bytes32 revertedOrStaticRollingHash; // expected rolling hash of the frame's sub-calls for static reads / reverted calls; must be bytes32(0) for a successful call (checked on-chain)
    bool success; // indicates whether the reentrant call returns or reverts
    bytes returnData; // pre-computed return value (revert payload when !success)
}

/// @notice A pre-computed TOP-LEVEL execution entry. When `success` is true the top-level call returns
///         `returnData` (`executeCrossChainCall`); when false the entry is run, verified, then reverted with
///         `returnData` so all of its state effects roll back (the caller may try/catch). A top-level
///         STATICCALL is a `StaticExecutionEntry` instead.
/// @dev `expectedL1ToL2Calls[]` is the entry's SINGLE reentrant table: every reentrant call fired
///      anywhere during the entry resolves against it — including one fired by a sub-call inside a
///      reentrant frame, since an `ExpectedL1ToL2Call` cannot carry a child table of its own
///      (Solidity forbids recursive structs).
struct ExecutionEntry {
    RootUpdate[] rootUpdates; // per-rollup state updates — the entry's full state transition (≥1, enforced on-chain)
    bytes32 proxyEntryHash; // inbound proxy-entry call hash (crossChainCallHash); bytes32(0) for L2 txs
    L2ToL1Call[] l2ToL1Calls; // L2→L1 calls to be executed, run in order; reentrant frames (nested L1→L2 calls) carry their own L2→L1 calls
    ExpectedL1ToL2Call[] expectedL1ToL2Calls; // pre-computed results for reentrant L1→L2 calls
    bytes32 rollingHash; // expected rolling hash, which contains all calls (including the ones inside expectedL1ToL2Calls), their return/revert values
    uint64 destinationRollupId; // rollup this entry is destined for — published into that rollup's queue, and only consumable by a call targeting that rollup or by `executeL2Txs` for that rollup
    bool success; // indicates whether the entry returns or reverts
    bytes returnData; // return data of the whole execution (revert payload when !success)
}

/// @notice A pre-computed TOP-LEVEL static entry: a read-only cross-chain call resolved via
///         `staticCrossChainCall` OUTSIDE any execution, from the pool (`_transientStaticEntries` /
///         per-rollup `staticEntryQueue`). Every top-level STATICCALL resolves here.
/// @dev Field order mirrors `ExecutionEntry`; no reentrant table (a reentrant read re-enters the pool
///      as ANOTHER `StaticExecutionEntry`). Match: `proxyEntryHash` + `destinationRollupId` + all
///      `expectedRoots` pins live (full scan). Used proxies must already be deployed.
struct StaticExecutionEntry {
    ExpectedRootPerRollup[] expectedRoots; // expected live roots per rollup
    bytes32 proxyEntryHash; // inbound proxy-entry call hash (crossChainCallHash); mirrors `ExecutionEntry.proxyEntryHash`
    L2ToL1Call[] l2ToL1Calls; // L2→L1 calls to be executed read-only via STATICCALL, run in order (no reentrant frames)
    bytes32 rollingHash; // expected rolling hash, which contains all calls and their return/revert values (untagged static schema: keccak(prev, success, retData))
    uint64 destinationRollupId; // rollup this static entry is destined for — published into that rollup's static queue, and only resolvable by a static call targeting that rollup
    bool success; // indicates whether resolution returns or reverts (false ⇒ reverts with `returnData`)
    bytes returnData; // return value (revert payload when !success)
}

/// @notice Stores the identity of an authorized CrossChainProxy
/// @dev Direction-neutral — used by the `EEZBase` proxy registry.
struct ProxyInfo {
    bool isProxy; // existence flag, set on registration
    address originalAddress; // address this proxy points to
    uint64 originalRollupId; // rollup this proxy points to
}

/// @title IEEZ
/// @notice Interface of the EEZ contract. Carries only the functions that `CrossChainProxy` /
///         `Bridge` depend on. The L1 execution structs above are consumed by `EEZ.sol`.
interface IEEZ {
    /// @notice Executes a cross-chain call initiated by an authorized proxy.
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return result The pre-computed return data of the matched entry
    function executeCrossChainCall(
        address sourceAddress,
        bytes calldata callData
    )
        external
        payable
        returns (bytes memory result);

    /// @notice Resolves a read-only cross-chain call initiated by an authorized proxy.
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return result The pre-computed return data of the matched static entry
    function staticCrossChainCall(
        address sourceAddress,
        bytes calldata callData
    )
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
    function computeCrossChainProxyAddress(
        address originalAddress,
        uint64 originalRollupId
    )
        external
        view
        returns (address);
}
