// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {
    IEEZ,
    StateDelta,
    ExecutionEntry,
    StaticLookup,
    L2ToL1Call,
    ExpectedL1ToL2Call
} from "../../../src/interfaces/IEEZ.sol";
import {
    StaticLookup as L2StaticLookup,
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
function getOrCreateProxy(IEEZ manager, address originalAddress, uint64 originalRollupId) returns (address proxy) {
    try manager.createCrossChainProxy(originalAddress, originalRollupId) returns (address p) {
        proxy = p;
    } catch {
        proxy = manager.computeCrossChainProxyAddress(originalAddress, originalRollupId);
    }
}

// ══════════════════════════════════════════════════════════════════════
//  Cross-chain call hash — matches `EEZBase.computeCrossChainCallHash`:
//    keccak256(abi.encode(isStatic, sourceAddress, sourceRollupId,
//                         targetAddress, targetRollupId, value, data))
//  abi.encode left-pads every integer to 32 bytes, so passing uint256
//  rollupIds here yields identical bytes to the contract's uint64 fields.
// ══════════════════════════════════════════════════════════════════════

/// @notice Full hash builder (state-changing OR static). `isStatic` is folded into the key, so a
///         static read keys distinctly from a state-changing call to the same target.
function crossChainCallHashFull(
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
    return keccak256(abi.encode(isStatic, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, data));
}

/// @notice Convenience: non-static cross-chain call hash. Field order mirrors the legacy helper
///         (target first) so existing call sites keep working; `isStatic` is fixed to false.
function crossChainCallHash(
    uint256 targetRollupId,
    address targetAddress,
    uint256 value,
    bytes memory data,
    address sourceAddress,
    uint256 sourceRollupId
)
    pure
    returns (bytes32)
{
    return crossChainCallHashFull(false, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, data);
}

/// @notice Convenience: STATIC cross-chain call hash (same field order as `crossChainCallHash`).
function crossChainCallHashStatic(
    uint256 targetRollupId,
    address targetAddress,
    uint256 value,
    bytes memory data,
    address sourceAddress,
    uint256 sourceRollupId
)
    pure
    returns (bytes32)
{
    return crossChainCallHashFull(true, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, data);
}

// ══════════════════════════════════════════════════════════════════════
//  RollingHashBuilder — reproduce the tagged-hash sequence EEZ/EEZL2
//  produce on-chain (EEZBase fold helpers). All folds use abi.encodePacked,
//  so widths matter: tags are uint8 (1 byte), rollupId is uint64 (8 bytes).
// ══════════════════════════════════════════════════════════════════════

library RollingHashBuilder {
    /// @notice Entry-begin seed (L1): folds the ordered `(rollupId, currentState)` state context,
    ///         then closes with the entry identity (`proxyEntryHash`).
    ///   seed         = keccak(…keccak(0, rollupId_1, currentState_1)…, rollupId_n, currentState_n)
    ///   _rollingHash = keccak(seed, proxyEntryHash)
    function entryBegin(StateDelta[] memory deltas, bytes32 proxyEntryHash) internal pure returns (bytes32) {
        bytes32 statesHash;
        for (uint256 i = 0; i < deltas.length; i++) {
            statesHash = keccak256(abi.encodePacked(statesHash, deltas[i].rollupId, deltas[i].currentState));
        }
        return keccak256(abi.encodePacked(statesHash, proxyEntryHash));
    }

    /// @notice Entry-begin seed (L2): no state deltas, so the state fold collapses to keccak(0, ...) —
    ///         i.e. the seed is keccak(bytes32(0), proxyEntryHash). Mirrors the L1 convention with an
    ///         empty delta set. NOTE: pending the EEZL2 migration; re-verify once EEZL2.sol lands.
    function entryBeginL2(bytes32 proxyEntryHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(0), proxyEntryHash));
    }

    /// @notice keccak256(prev ++ CALL_BEGIN ++ crossChainCallHash)
    function appendCallBegin(bytes32 prev, bytes32 ccHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, CALL_BEGIN, ccHash));
    }

    /// @notice keccak256(prev ++ CALL_END ++ success ++ retData)
    function appendCallEnd(bytes32 prev, bool success, bytes memory retData) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, CALL_END, success, retData));
    }

    /// @notice keccak256(prev ++ NESTED_BEGIN ++ crossChainCallHash)
    function appendNestedBegin(bytes32 prev, bytes32 ccHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, NESTED_BEGIN, ccHash));
    }

    /// @notice keccak256(prev ++ NESTED_END)
    function appendNestedEnd(bytes32 prev) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, NESTED_END));
    }

    /// @notice keccak256(prev ++ CALL_NOT_FOUND ++ crossChainCallHash) — reentrant no-match divergence.
    function appendCallNotFound(bytes32 prev, bytes32 ccHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, CALL_NOT_FOUND, ccHash));
    }

    /// @notice Static sub-call accumulator (untagged): keccak256(prev ++ success ++ retData).
    function appendStatic(bytes32 prev, bool success, bytes memory retData) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, success, retData));
    }
}

/// @notice Position key for a unified reentrant (L1→L2) table entry:
///         keccak256(crossChainCallHash, rollingHashAtFire). Matches `EEZBase._computeExpectedL1toL2Hash`.
function expectedL1toL2Hash(bytes32 ccHash, bytes32 rollingHashAtFire) pure returns (bytes32) {
    return keccak256(abi.encodePacked(ccHash, rollingHashAtFire));
}

// ══════════════════════════════════════════════════════════════════════
//  L2TXBatcher — postAndVerifyBatch + executeL2Txs in one tx (local mode).
//  Wraps the caller's entries into a single sub-batch with the supplied
//  proofSystem + rollupId, marks the leading run of proxyEntryHash==0 entries
//  as immediate, then drains via executeL2Txs(rollupId).
// ══════════════════════════════════════════════════════════════════════

contract L2TXBatcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        uint64 rollupId,
        ExecutionEntry[] calldata entries,
        StaticLookup[] calldata staticLookups
    )
        external
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

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            entries: entries,
            staticLookups: staticLookups,
            immediateEntryCount: ic,
            immediateStaticLookupCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs,
            blockNumber: 0
        });
        rollups.postAndVerifyBatch(batch);
        rollups.executeL2Txs(rollupId);
    }
}

// ══════════════════════════════════════════════════════════════════════
//  Common empty helpers (saves boilerplate in E2E scripts)
// ══════════════════════════════════════════════════════════════════════

/// @notice Returns an empty StaticLookup[] (L1) — for flows with no top-level static lookups.
function noStaticLookups() pure returns (StaticLookup[] memory) {
    return new StaticLookup[](0);
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

/// @notice Returns an empty StaticLookup[] (IEEZL2).
function noL2StaticLookups() pure returns (L2StaticLookup[] memory) {
    return new L2StaticLookup[](0);
}

/// @notice Returns an empty ExpectedOutgoingCrossChainCall[] (IEEZL2).
function noL2OutgoingCalls() pure returns (ExpectedOutgoingCrossChainCall[] memory) {
    return new ExpectedOutgoingCrossChainCall[](0);
}

/// @notice Returns an empty CrossChainCall[] (IEEZL2).
function noL2Calls() pure returns (CrossChainCall[] memory) {
    return new CrossChainCall[](0);
}
