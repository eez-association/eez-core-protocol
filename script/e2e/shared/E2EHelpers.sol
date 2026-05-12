// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {IEEZ, ExecutionEntry, LookupCall, L2ToL1Call, ExpectedL1ToL2Call} from "../../../src/interfaces/IEEZ.sol";

// ══════════════════════════════════════════════════════════════════════
//  Rolling hash tag constants (must match EEZ.sol / EEZL2.sol)
// ══════════════════════════════════════════════════════════════════════
uint8 constant CALL_BEGIN = 1;
uint8 constant CALL_END = 2;
uint8 constant NESTED_BEGIN = 3;
uint8 constant NESTED_END = 4;

// ══════════════════════════════════════════════════════════════════════
//  Idempotent proxy creation helper
// ══════════════════════════════════════════════════════════════════════

/// @notice Returns existing proxy if already deployed, otherwise creates it.
function getOrCreateProxy(IEEZ manager, address originalAddress, uint256 originalRollupId) returns (address proxy) {
    try manager.createCrossChainProxy(originalAddress, originalRollupId) returns (address p) {
        proxy = p;
    } catch {
        proxy = manager.computeCrossChainProxyAddress(originalAddress, originalRollupId);
    }
}

/// @notice Cross-chain call hash builder matching `EEZ.computeCrossChainCallHash`.
/// @dev Same formula on L1 and L2; off-chain tooling and on-chain code share this preimage.
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
    return keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId));
}

/// @notice **Backward-compatibility shim** for legacy E2E scripts.
/// @dev The `Action` struct was removed from `IEEZ.sol`. E2E flow scripts
///      pre-refactor used it heavily as an off-chain "tooling-side" record of the inputs
///      that hash to `crossChainCallHash`. Re-defined here with the same field order so
///      existing scripts can keep using `Action({...})` literals; computing the hash via
///      `actionHash(...)` (also shimmed) routes to the canonical formula.
///      New code should call `crossChainCallHash(...)` directly with individual fields.
struct Action {
    uint256 targetRollupId;
    address targetAddress;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollupId;
}

/// @notice Backward-compat: `actionHash(Action)` → `crossChainCallHash(...)`.
function actionHash(Action memory a) pure returns (bytes32) {
    return crossChainCallHash(a.targetRollupId, a.targetAddress, a.value, a.data, a.sourceAddress, a.sourceRollupId);
}

/// @notice Backward-compat alias: `noStaticCalls()` returns an empty `LookupCall[]`.
function noStaticCalls() pure returns (LookupCall[] memory) {
    return new LookupCall[](0);
}

// ══════════════════════════════════════════════════════════════════════
//  RollingHashBuilder — replay the same tagged-hash sequence that
//  EEZ._processNCalls / _consumeNestedAction produce on-chain.
// ══════════════════════════════════════════════════════════════════════

library RollingHashBuilder {
    /// @notice keccak256(prev ++ CALL_BEGIN ++ callNumber)
    function appendCallBegin(bytes32 prev, uint256 callNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, CALL_BEGIN, callNumber));
    }

    /// @notice keccak256(prev ++ CALL_END ++ callNumber ++ success ++ retData)
    function appendCallEnd(bytes32 prev, uint256 callNumber, bool success, bytes memory retData)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(prev, CALL_END, callNumber, success, retData));
    }

    /// @notice keccak256(prev ++ NESTED_BEGIN ++ nestedNumber)
    function appendNestedBegin(bytes32 prev, uint256 nestedNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, NESTED_BEGIN, nestedNumber));
    }

    /// @notice keccak256(prev ++ NESTED_END ++ nestedNumber)
    function appendNestedEnd(bytes32 prev, uint256 nestedNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, NESTED_END, nestedNumber));
    }
}

// ══════════════════════════════════════════════════════════════════════
//  L2TXBatcher — postAndVerifyBatch + executeL2TX in one tx (local mode).
//  Satisfies the same-block requirement.
//
//  POST-REFACTOR: postAndVerifyBatch now takes `ProofSystemBatchPerVerificationEntries[]`. The batcher wraps the
//  caller's entries into a single sub-batch with the supplied proofSystem + rollupId,
//  then drains immediate entries (transientCount = leading-zero-actionHash run length)
//  and finally calls executeL2TX(rollupId).
// ══════════════════════════════════════════════════════════════════════

contract L2TXBatcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        uint256 rollupId,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls
    )
        external
    {
        // Compute transientCount as the count of leading entries whose proxyEntryHash == 0
        // (immediate entries — no source action to match, run inline during the batch call).
        uint256 tc = 0;
        while (tc < entries.length && entries[tc].proxyEntryHash == bytes32(0)) {
            tc++;
        }

        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";

        uint64[] memory psIdx = new uint64[](1);
        psIdx[0] = 0;
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: rollupId, proofSystemIndex: psIdx});

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            entries: entries,
            l1ToL2lookupCalls: lookupCalls,
            transientExecutionEntryCount: tc,
            transientLookupCallCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
        rollups.executeL2TX(rollupId);
    }
}

// ══════════════════════════════════════════════════════════════════════
//  Common empty helpers (saves boilerplate in E2E scripts)
// ══════════════════════════════════════════════════════════════════════

/// @notice Returns an empty LookupCall[] (for flows that don't use lookup calls).
function noLookupCalls() pure returns (LookupCall[] memory) {
    return new LookupCall[](0);
}

/// @notice Returns an empty ExpectedL1ToL2Call[].
function noNestedActions() pure returns (ExpectedL1ToL2Call[] memory) {
    return new ExpectedL1ToL2Call[](0);
}

/// @notice Returns an empty L2ToL1Call[].
function noCalls() pure returns (L2ToL1Call[] memory) {
    return new L2ToL1Call[](0);
}
