// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ProofSystemBatchPerVerificationEntries,
    ExpectedRootPerRollup,
    RollupIdWithProofSystems
} from "../../../src/EEZ.sol";
import {
    IEEZ,
    RollupUpdate,
    ExecutionEntry,
    StaticExecutionEntry,
    L2ToL1Call,
    ExpectedL1ToL2Call
} from "../../../src/interfaces/IEEZ.sol";
import {
    StaticExecutionEntry as L2StaticExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";

// ══════════════════════════════════════════════════════════════════════
//  Rolling hash tag constants (must match EEZBase.sol)
// ══════════════════════════════════════════════════════════════════════
uint8 constant CALL_BEGIN = 1;
uint8 constant CALL_END = 2;
uint8 constant NESTED_BEGIN = 3;
uint8 constant NESTED_END = 4;
uint8 constant CALL_NOT_FOUND = 5;

uint64 constant MAINNET_ROLLUP_ID = 0;

// ══════════════════════════════════════════════════════════════════════
//  Idempotent proxy creation helper
// ══════════════════════════════════════════════════════════════════════

/// @notice Returns existing proxy if already deployed, otherwise creates it.
/// @dev Compute-first, NOT try/create/catch: a create that succeeds in forge's
///      local simulation but collides on-chain (the same proxy identity created
///      by an earlier run — proxy salts have no chain/domain separation, so
///      identities recur across scenarios) gets RECORDED and then hard-fails
///      the on-chain simulation replay.
function getOrCreateProxy(IEEZ manager, address originalAddress, uint64 originalRollupId) returns (address proxy) {
    proxy = manager.computeCrossChainProxyAddress(originalAddress, originalRollupId);
    if (proxy.code.length == 0) {
        proxy = manager.createCrossChainProxy(originalAddress, originalRollupId);
    }
}

// ══════════════════════════════════════════════════════════════════════
//  Cross-chain call hash — matches `EEZBase.computeCrossChainCallHash`:
//    keccak256(abi.encode(isStatic, sourceAddress, sourceRollupId,
//                         targetAddress, targetRollupId, value, callGas, data))
//  `callGas` folds 0 (the devnet deploys every `EEZL2` with `useGasLeft = false`).
//  abi.encode left-pads every integer to 32 bytes, so passing uint256
//  rollupIds here yields identical bytes to the contract's uint64 fields.
// ══════════════════════════════════════════════════════════════════════

/// @notice Hash builder (state-changing OR static) with `callGas = 0`. `isStatic` makes a
///         static read key distinctly from a state-changing call to the same target.
function crossChainCallHash(
    bool isStatic,
    address sourceAddress,
    uint256 sourceRollupId,
    address targetAddress,
    uint256 targetRollupId,
    uint256 value,
    bytes memory data
)
    pure
    returns (bytes32)
{
    return crossChainCallHashWithGas(
        isStatic, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, 0, data
    );
}

/// @notice Full hash builder for observed events, where the emitted callGas must
///         remain part of the preimage even if the current devnet normally uses zero.
function crossChainCallHashWithGas(
    bool isStatic,
    address sourceAddress,
    uint256 sourceRollupId,
    address targetAddress,
    uint256 targetRollupId,
    uint256 value,
    uint256 callGas,
    bytes memory data
)
    pure
    returns (bytes32)
{
    return keccak256(
        abi.encode(isStatic, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, callGas, data)
    );
}

/// @notice Key for a mutable call LEAVING an L2 (`EEZL2.executeCrossChainCall` top-level matching
///         and the cch inside nested `expectedOutgoingHash` rows) — the sites to touch if
///         `useGasLeft` flips on; the devnet runs false, so `callGas` folds 0.
function crossChainCallHashL2Out(
    address sourceAddress,
    uint256 sourceRollupId,
    address targetAddress,
    uint256 targetRollupId,
    uint256 value,
    bytes memory data
)
    pure
    returns (bytes32)
{
    return crossChainCallHash(false, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, data);
}

/// @notice Convenience: STATIC cross-chain call hash.
function crossChainCallHashStatic(
    address sourceAddress,
    uint256 sourceRollupId,
    address targetAddress,
    uint256 targetRollupId,
    uint256 value,
    bytes memory data
)
    pure
    returns (bytes32)
{
    return crossChainCallHash(true, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, data);
}

// ══════════════════════════════════════════════════════════════════════
//  RollingHashBuilder — reproduce the tagged-hash sequence EEZ/EEZL2
//  produce on-chain (EEZBase fold helpers). All folds use abi.encodePacked,
//  so widths matter: tags are uint8 (1 byte), rollupId is uint64 (8 bytes).
// ══════════════════════════════════════════════════════════════════════

library RollingHashBuilder {
    /// @notice Entry-begin seed (L1): folds the ordered `(rollupId, currentRoot)` state context,
    ///         then closes with the entry identity (`proxyEntryHash`).
    ///   seed         = keccak(…keccak(0, rollupId_1, currentRoot_1)…, rollupId_n, currentRoot_n)
    ///   _rollingHash = keccak(seed, proxyEntryHash)
    function entryBegin(RollupUpdate[] memory deltas, bytes32 proxyEntryHash) internal pure returns (bytes32) {
        bytes32 statesHash;
        for (uint256 i = 0; i < deltas.length; i++) {
            statesHash = keccak256(abi.encodePacked(statesHash, deltas[i].rollupId, deltas[i].currentRoot));
        }
        return keccak256(abi.encodePacked(statesHash, proxyEntryHash));
    }

    /// @notice Entry-begin seed (L2): no state deltas, so the state fold collapses to keccak(0, ...) —
    ///         i.e. the seed is keccak(bytes32(0), proxyEntryHash). Mirrors the L1 convention with an
    ///         empty delta set.
    function entryBeginL2(bytes32 proxyEntryHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(0), proxyEntryHash));
    }

    /// @notice keccak256(prev ++ CALL_BEGIN ++ crossChainCallHash)
    function appendCallBegin(bytes32 prev, bytes32 ccHash) internal pure returns (bytes32) {
        return _fold(prev, stepCallBegin(ccHash));
    }

    /// @notice keccak256(prev ++ CALL_END ++ success ++ retData)
    function appendCallEnd(bytes32 prev, bool success, bytes memory retData) internal pure returns (bytes32) {
        return _fold(prev, stepCallEnd(success, retData));
    }

    /// @notice keccak256(prev ++ NESTED_BEGIN ++ crossChainCallHash)
    function appendNestedBegin(bytes32 prev, bytes32 ccHash) internal pure returns (bytes32) {
        return _fold(prev, stepNestedBegin(ccHash));
    }

    /// @notice keccak256(prev ++ NESTED_END)
    function appendNestedEnd(bytes32 prev) internal pure returns (bytes32) {
        return _fold(prev, stepNestedEnd());
    }

    /// @notice keccak256(prev ++ CALL_NOT_FOUND ++ crossChainCallHash) — reentrant no-match divergence.
    function appendCallNotFound(bytes32 prev, bytes32 ccHash) internal pure returns (bytes32) {
        return _fold(prev, stepCallNotFound(ccHash));
    }

    /// @notice Static sub-call accumulator (untagged): keccak256(prev ++ success ++ retData).
    function appendStatic(bytes32 prev, bool success, bytes memory retData) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, success, retData));
    }

    // ── Recorded steps ──────────────────────────────────────────────────
    // A HashStep is one fold with the seed factored out, so the chain can be
    // replayed over a DIFFERENT seed. ComputeExpected can only guess placeholder
    // roots, but the on-chain seed folds the real ones — exporting the
    // steps (EXPECTED_L1_STEPS) lets the network verifier rebuild the exact
    // rolling hash from the POSTED roots and compare it to the posted entry's.

    function stepCallBegin(bytes32 ccHash) internal pure returns (HashStep memory) {
        return HashStep(CALL_BEGIN, abi.encodePacked(ccHash));
    }

    function stepCallEnd(bool success, bytes memory retData) internal pure returns (HashStep memory) {
        return HashStep(CALL_END, abi.encodePacked(success, retData));
    }

    function stepNestedBegin(bytes32 ccHash) internal pure returns (HashStep memory) {
        return HashStep(NESTED_BEGIN, abi.encodePacked(ccHash));
    }

    function stepNestedEnd() internal pure returns (HashStep memory) {
        return HashStep(NESTED_END, "");
    }

    function stepCallNotFound(bytes32 ccHash) internal pure returns (HashStep memory) {
        return HashStep(CALL_NOT_FOUND, abi.encodePacked(ccHash));
    }

    /// @notice Replays recorded steps over a seed: rh = keccak256(rh ++ tag ++ payload)
    ///         per step — identical to the append* folds above by construction.
    function foldSteps(bytes32 seed, HashStep[] memory steps) internal pure returns (bytes32 rh) {
        rh = seed;
        for (uint256 i = 0; i < steps.length; i++) {
            rh = _fold(rh, steps[i]);
        }
    }

    /// @notice One tagged fold — the single definition the append* helpers and
    ///         foldSteps share: keccak256(prev ++ tag ++ payload).
    function _fold(bytes32 prev, HashStep memory step) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, step.tag, step.payload));
    }
}

/// @notice One recorded rolling-hash fold (see RollingHashBuilder step helpers):
///         `tag` is the protocol tag byte; `payload` the packed fold argument
///         (crossChainCallHash for BEGIN tags, success ++ retData for CALL_END,
///         empty for NESTED_END).
struct HashStep {
    uint8 tag;
    bytes payload;
}

/// @notice Position key for a unified reentrant (L1→L2) table entry:
///         keccak256(crossChainCallHash, rollingHashAtFire). Matches `EEZBase._computeExpectedL1toL2Hash`.
function expectedL1toL2Hash(bytes32 ccHash, bytes32 rollingHashAtFire) pure returns (bytes32) {
    return keccak256(abi.encodePacked(ccHash, rollingHashAtFire));
}

/// @notice Builds a single-rollup batch whose leading run of `proxyEntryHash == 0` entries is
///         marked immediate — they execute inline during `postAndVerifyBatch` (the batch-structure
///         check rejects a leading zero-hash entry left uncovered by `immediateEntryCount`). Any
///         remainder past the leading run is published to the per-rollup queue. Kept as a free
///         function so its array-building locals live in their own stack frame — callers that
///         inline this construction can trip the via-ir ABI-encoder stack limit when encoding the
///         nested `ExecutionEntry[]`.
function immediateSingleRollupBatch(
    address proofSystem,
    uint64 rollupId,
    ExecutionEntry[] memory entries,
    StaticExecutionEntry[] memory staticEntries
)
    pure
    returns (ProofSystemBatchPerVerificationEntries memory batch)
{
    // immediateEntryCount = count of leading entries whose proxyEntryHash == 0 (L2 txs run inline).
    uint256 ic = 0;
    while (ic < entries.length && entries[ic].proxyEntryHash == bytes32(0)) {
        ic++;
    }

    address[] memory psList = new address[](1);
    psList[0] = proofSystem;
    bytes[] memory proofs = new bytes[](1);
    proofs[0] = "proof";
    uint64[] memory psIdx = new uint64[](1);
    psIdx[0] = 0;
    RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](1);
    rps[0] = RollupIdWithProofSystems({rollupId: rollupId, proofSystemIndexes: psIdx});
    batch = ProofSystemBatchPerVerificationEntries({
        expectedRootPerRollup: new ExpectedRootPerRollup[](0),
        entries: entries,
        staticEntries: staticEntries,
        immediateEntryCount: ic,
        immediateStaticEntryCount: 0,
        proofSystems: psList,
        rollupIdsWithProofSystems: rps,
        blobIndices: new uint256[](0),
        callData: "",
        proofs: proofs,
        blockNumber: 0,
        bindMsgSenderInPublicInput: false
    });
}

// ══════════════════════════════════════════════════════════════════════
//  Common empty helpers (saves boilerplate in E2E scripts)
// ══════════════════════════════════════════════════════════════════════

/// @notice Returns an empty StaticExecutionEntry[] (L1) — for flows with no top-level static lookups.
function noStaticEntries() pure returns (StaticExecutionEntry[] memory) {
    return new StaticExecutionEntry[](0);
}

/// @notice Returns an empty ExpectedL1ToL2Call[] (unified reentrant table).
function noNestedActions() pure returns (ExpectedL1ToL2Call[] memory) {
    return new ExpectedL1ToL2Call[](0);
}

/// @notice Returns an empty L2ToL1Call[].
function noCalls() pure returns (L2ToL1Call[] memory) {
    return new L2ToL1Call[](0);
}

// L2 (IEEZL2) variants — Solidity can't overload free functions by return type alone,
// so the L2-typed empties get an `L2` infix.

/// @notice Returns an empty StaticExecutionEntry[] (IEEZL2).
function noL2StaticEntries() pure returns (L2StaticExecutionEntry[] memory) {
    return new L2StaticExecutionEntry[](0);
}

/// @notice Returns an empty ExpectedOutgoingCrossChainCall[] (IEEZL2).
function noL2OutgoingCalls() pure returns (ExpectedOutgoingCrossChainCall[] memory) {
    return new ExpectedOutgoingCrossChainCall[](0);
}

/// @notice Returns an empty CrossChainCall[] (IEEZL2).
function noL2Calls() pure returns (CrossChainCall[] memory) {
    return new CrossChainCall[](0);
}
