// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
//  IEEZ — shared cross-chain interface + L1 (EEZ) execution structs.
//
//  This file holds:
//    - `ProxyInfo` and the `IEEZ` interface: direction-neutral, shared by the L1
//      (`EEZ`) and L2 (`EEZL2`) managers and by `CrossChainProxy` / `Bridge`.
//    - The L1-canonical, directionally-named execution structs consumed by `EEZ.sol`:
//        * an `L2ToL1Call` is a cross-chain call executed on L1 (flat
//          `l2ToL1Calls[]` array, walked by the `_currentL2ToL1Call` cursor),
//        * an `ExpectedL1ToL2Call` is a reentrant L1→L2 call fired during execution
//          (the `expectedL1ToL2Calls[]` table, counted by `_lastL1ToL2CallConsumed`).
//
//  The mirror-image L2 structs live in `IEEZL2.sol` with self-relative names and a
//  deliberately leaner layout (no `StateDelta`, `destinationRollupId`, or
//  `ExpectedStateRootPerRollup`) — L2 never hashes a whole entry/lookup, so its
//  layout is free to diverge from L1's.
//
//  Casing: types/events/errors are PascalCase (`L2ToL1Call`, `L1ToL2CallConsumed`,
//  `UnconsumedL2ToL1Calls`); variables / struct fields / params are mixedCase with
//  the connector capitalized (`l2ToL1Calls`, `_currentL2ToL1Call`).
// ─────────────────────────────────────────────────────────────────────────────

/// @notice One participating rollup in a `ProofSystemBatchPerVerificationEntries` together
///         with the SUBSET of the batch's global `proofSystems[]` that this rollup accepts.
/// @dev `proofSystemIndexes[]` is a list of indices into the parent batch's `proofSystems[]`,
///      strictly increasing. The on-chain registry resolves them to PS addresses and hands
///      that subset to this rollup's contract via `IRollupContract.checkProofSystemsAndGetVkeys`
struct RollupIdWithProofSystems {
    uint256 rollupId;
    uint64[] proofSystemIndexes;
}

/// @notice One batch's payload — a group of proof systems jointly attesting to a set of
///         rollups' state transitions. Each rollup picks the subset of `proofSystems[]` it
///         accepts via `RollupIdWithProofSystems[r].proofSystemIndexes`.
/// @dev The participating rollups (read off `RollupIdWithProofSystems[r].rollupId`) must be
///      strictly increasing — paired with the once-per-block-per-rollup invariant on
///      `_markVerifiedBlockPerRollup`, this prevents a single batch from verifying the same
///      rollup twice. `proofSystems[]` is the batch-global PS list (strictly increasing,
///      rejects address(0) and duplicates). Each rollup's `proofSystemIndexes[]` is strictly
///      increasing too, indices in `[0, proofSystems.length)`, and its length must satisfy
///      that rollup's threshold (enforced by `IRollupContract.checkProofSystemsAndGetVkeys`).
/// @dev `blobIndices` selects which of the tx-level EIP-4844 blobs this batch consumes;
///      `callData` is batch-scoped (each PS's circuit gets its own region).
/// @dev `transientExecutionEntryCount` and `transientStaticLookupCount` are pure on-chain
///      dispatch parameters — not bound by the proof — so the orchestrator can tune the
///      transient/persistent split without re-proving.
/// @dev `blockNumber` is the single L1 block the whole batch binds to. The registry forwards
///      it to every rollup's `getCustomData(blockNumber)`, whose result folds into the batch's
///      shared public input. 0 = no block context, type(uint64).max = "latest context"
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

/// @notice Rollup configuration held by the central registry.
/// @dev Owner, threshold, and per-PS vkeys live on the per-rollup `IRollupContract` contract pointed
///      to by `rollupContract`. The central registry holds only the *state* (state root,
///      ether balance) and reads vkeys through `IRollupContract.checkProofSystemsAndGetVkeys`
struct RollupConfig {
    address rollupContract;
    bytes32 stateRoot;
    uint256 etherBalance;
}

/// @notice Per-rollup deferred-consumption queue + per-block reset marker
/// @dev `lastVerifiedBlock` doubles as:
///        (a) per-block reset marker — every `postAndVerifyBatch` that touches `rid` wipes this
///            rollup's queue and cursor (see `_markVerifiedBlockPerRollup`), so a same-block
///            re-verify REPLACES (does not append to) the prior batch's entries;
///        (b) read gate for consumers (entries can only be consumed in the block they were
///            posted — `executeCrossChainCall` / `executeL2TX` / `staticCallLookup` all gate
///            on `lastVerifiedBlock(rid) == block.number`), which also means a stale queue from
///            a prior block is never read — it's simply overwritten on the next verify;
///        (c) lockout signal for the registry's owner-escape path `EEZ.setStateRoot`,
///            which reverts `RollupBatchActiveThisBlock` when this equals `block.number`.
struct RollupVerification {
    uint256 lastVerifiedBlock;
    ExecutionEntry[] executionQueue;
    StaticLookup[] staticLookupQueue;
    uint256 executionQueueIndex;
}

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

/// @notice Represents a cross-chain call within an execution entry (L2→L1 on L1)
/// @dev revertNextNCalls > 0 opens an isolated revert context spanning the next revertNextNCalls calls (including this one)
/// @dev isStatic dispatches the call via STATICCALL — read-only, carries no value, reverts on any state write
struct L2ToL1Call {
    bool isStatic;
    address targetAddress;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertNextNCalls;
}

/// @notice Pre-computed result for a reentrant cross-chain call (L1→L2) triggered during
///         execution. UNIFIED record: a single `expectedL1ToL2Calls[]` table now holds every
///         flavour of reentrant call — a plain SUCCESS, a read-only STATICCALL (`isStatic`), and
///         a reverting call the caller try/catches (`failed`). The old separate `ExpectedLookup`
///         table and its 4-tuple coordinate key are gone: position is now content-addressed by
///         `currentRollingHash` (the value of `_rollingHash` at the instant the call fires),
///         which uniquely pins the execution point because the rolling hash folds every prior
///         call / nesting boundary.
/// @dev Resolution by role (all keyed by `(crossChainCallHash, currentRollingHash)`): EVERY
///      flavour carries its OWN `l2ToL1Calls[]` sub-array and runs it to completion — there is no
///      shared flat array partitioned by a `callCount` anymore, so the field is gone.
///        - plain SUCCESS (`!isStatic && !failed`): consumed by `_consumeNestedAction`, which runs
///          this entry's `l2ToL1Calls[]` as a sub-execution that COMMITS (state + rolling-hash
///          contributions persist), folding into the host's continuous rolling hash between
///          NESTED_BEGIN/END, then returns `returnData`. `rollingHash` here is unused (0).
///        - STATIC read (`isStatic`): resolved by `staticCallLookup`'s in-execution branch via
///          `_resolveStaticLookup` — runs its OWN `l2ToL1Calls[]` in STATICCALL context (untagged
///          schema, checked against `rollingHash`) and returns `returnData` (reverts with it when
///          `failed`).
///        - REVERTED (`failed && !isStatic`): resolved by `_consumeNestedAction`'s fallback via
///          `_executeRevertedNestedLookup` — runs its OWN `l2ToL1Calls[]` as a mini-entry (tagged
///          schema, checked against `rollingHash`, seeded with `currentRollingHash`), then reverts
///          with `returnData` (state rolled back).
/// @dev Sub-execution context separation: a REVERTED entry's sub-execution reuses the SAME host
///      `expectedL1ToL2Calls[]` for its own reentrant calls (Solidity forbids recursive structs).
///      To keep keys unambiguous across contexts, the sub-execution SEEDS `_rollingHash` with this
///      entry's `currentRollingHash` instead of resetting to 0 — every context therefore has a
///      distinct rolling-hash namespace, which is what replaces the old `executingLookupIndex`. A
///      SUCCESS sub-execution needs no seed: it folds into the host's single continuous hash.
/// @dev `destinationRollupId` is the rollup this reentrant call targets, bound two ways:
///      `postAndVerifyBatch` requires it to be one of the host's verified rollups (the entry's
///      `stateDeltas`, or a top-level `StaticLookup`'s `expectedStateRoots` pins), and at resolution
///      (`_consumeNestedAction` / `staticCallLookup`) it must equal the calling proxy's rollup.
struct ExpectedL1ToL2Call {
    bytes32 crossChainCallHash;
    uint256 destinationRollupId;
    /// `_rollingHash` at the instant this call fires — the content-addressed position key.
    bytes32 currentRollingHash;
    /// Read-only STATICCALL mode (resolved through `staticCallLookup`).
    bool isStatic;
    /// Reverting mode (the caller try/catches the revert). For an `isStatic` entry, marks a
    /// static read that itself reverts with `returnData`.
    bool failed;
    bytes returnData;
    /// The reentrant frame's own flat sub-calls, run to completion in every mode (success commits,
    /// reverted rolls back, static runs read-only). Empty for a no-op frame.
    L2ToL1Call[] l2ToL1Calls;
    /// Expected hash of the executed sub-calls — folded into the host's continuous hash for SUCCESS
    /// (unused, 0), checked standalone for STATIC (untagged) and REVERTED (tagged, seeded with
    /// `currentRollingHash`).
    bytes32 rollingHash;
}

/// @notice Represents an execution entry with pre-computed calls and return hash verification
/// @dev Execution entries always SUCCEED at the top level — `executeCrossChainCall` returns
///      `entry.returnData` as success. There is no `failed` flag at the entry level. A reverting
///      REENTRANT call (try/catch'd during execution) is a `failed` entry in
///      `expectedL1ToL2Calls` (see `ExpectedL1ToL2Call`); a read-only call resolved outside an
///      execution is a `StaticLookup`. Naturally-reverting INNER calls inside an entry are still
///      expressible: the proxy `.call` returns `(false, retData)` and the rolling hash captures it
///      via `CALL_END`;
///      the entry's outer `executeCrossChainCall` still returns success with `entry.returnData`.
/// @dev `destinationRollupId` is the rollup whose queue this entry is routed to on L1
///      (per-rollup queue model). Must match the rollupId derived from the consumer
///      (proxyInfo.originalRollupId for proxy calls; the explicit rollupId arg for
///      executeL2TX).
///
/// @dev **No flat-array partition.** `l2ToL1Calls[]` is the entry's TOP-LEVEL calls ONLY, run to
///      completion by `_processNCalls(l2ToL1Calls.length)`. Each reentrant (L1→L2) frame carries
///      its OWN `expectedL1ToL2Calls[i].l2ToL1Calls[]` sub-array (also run to completion), so there
///      is no shared cursor partition and no `callCount` field. A top-level call that triggers a
///      reentrant cross-chain proxy invocation re-enters via `executeCrossChainCall` →
///      `_consumeNestedAction`, which runs that reentrant entry's own sub-array in a saved/restored
///      cursor frame (success) or a seeded sub-execution (reverted); the outer cursor resumes
///      untouched afterwards. The end check is simply `_currentL2ToL1Call == l2ToL1Calls.length`.
struct ExecutionEntry {
    /// Initial state --> final state. PROVER OBLIGATION: the deltas must be the entry's true
    /// state transition, and every entry must carry at least one StateDelta (never empty) —
    /// asserted by the prover, not enforced on-chain.
    StateDelta[] stateDeltas;
    bytes32 proxyEntryHash; // hashed call (L1 -> L2), otherwise bytes32(0) for L2 txs
    uint256 destinationRollupId; // double check
    /// The entry's TOP-LEVEL calls, flat, in execution order (reentrant frames carry their own
    /// sub-calls — see `ExpectedL1ToL2Call`). Run to completion.
    bytes returnData;
    L2ToL1Call[] l2ToL1Calls;
    /// Unified reentrant (L1→L2) table: plain successes, reentrant static reads, and try/catch'd
    /// reverting reentrant calls, distinguished by the `isStatic` / `failed` flags and matched by
    /// `(crossChainCallHash, currentRollingHash)`. Each entry carries its own sub-calls.
    /// See `ExpectedL1ToL2Call`.
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;
    bytes32 rollingHash;
}

/// @notice A rollup's expected state root at the moment a top-level lookup is observed.
/// @dev Content-addresses a `StaticLookup` to a point on each pinned rollup's trajectory: a
///      candidate only MATCHES when every pin equals the live `rollups[rollupId].stateRoot`
///      (full-scan semantics — a mismatching candidate is skipped, it does not revert).
///      Split-independent and valid in the transient phase, unlike the old queue-cursor pins.
///      L1-only — L2 has no state roots.
struct ExpectedStateRootPerRollup {
    uint256 rollupId;
    bytes32 stateRoot;
}

/// @notice TOP-LEVEL STATIC lookup: the pre-computed result of a read-only cross-chain call made
///         OUTSIDE any execution (`!_insideExecution()`), resolved via `staticCallLookup`. Lives in
///         the storage pool (`_transientStaticLookups` / per-rollup `staticLookupQueue`). This is now the
///         ONLY top-level pooled shape — there is no reverted (state-changing) top-level path; a
///         top-level call that mutates and reverts is expressed as a normal `ExecutionEntry`, and
///         reentrant calls fired DURING an entry's execution live in
///         `ExecutionEntry.expectedL1ToL2Calls` (see `ExpectedL1ToL2Call`).
/// @dev A static lookup is just `l2ToL1Calls` (N read-only sub-calls) plus `returnData`. It has NO
///      reentrant table: a reentrant cross-chain call observed while resolving it runs in STATICCALL
///      context (`_insideExecution() == false`), so it re-enters `staticCallLookup`'s pool branch and
///      resolves as ANOTHER `StaticLookup` matched on hash + the same state-root pins.
/// @dev Match key: `crossChainCallHash` + `destinationRollupId == ` the calling proxy's rollup
///      + every `expectedStateRoots` pin equal to the live root (full scan — a non-matching
///      candidate is skipped, not reverted on). The `destinationRollupId` term is what makes the
///      transient pool (a single un-routed table) resolve only for the right rollup. Resolution runs
///      `l2ToL1Calls` via STATICCALL (untagged schema, checked against `rollingHash`) and returns
///      `returnData` — or reverts with it when `failed` (a read that itself reverts). All proxies
///      referenced by `l2ToL1Calls` must be deployed before static resolution.
struct StaticLookup {
    bytes32 crossChainCallHash;
    /// Rollup whose `staticLookupQueue` this lookup is published under, AND part of the resolution match
    /// (`staticCallLookup` requires it to equal the calling proxy's rollup). For persistent lookups
    /// this is coherent by construction (queue-routed); for the transient pool it is the load-bearing
    /// check that the lookup resolves only for that rollup. postAndVerifyBatch also requires it to
    /// appear in `expectedStateRoots` (destination ∈ pins), pinning the routing target to proven state.
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
