// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Rollups} from "../../../src/Rollups.sol";
import {
    ICrossChainManager,
    Action,
    ExecutionEntry,
    StaticCall,
    CrossChainCall,
    NestedAction
} from "../../../src/ICrossChainManager.sol";

// ══════════════════════════════════════════════════════════════════════
//  Rolling hash tag constants (must match Rollups.sol / CrossChainManagerL2.sol)
// ══════════════════════════════════════════════════════════════════════
uint8 constant CALL_BEGIN = 1;
uint8 constant CALL_END = 2;
uint8 constant NESTED_BEGIN = 3;
uint8 constant NESTED_END = 4;

// ══════════════════════════════════════════════════════════════════════
//  Idempotent proxy creation helper
// ══════════════════════════════════════════════════════════════════════

/// @notice Returns existing proxy if already deployed, otherwise creates it.
function getOrCreateProxy(ICrossChainManager manager, address originalAddress, uint256 originalRollupId)
    returns (address proxy)
{
    try manager.createCrossChainProxy(originalAddress, originalRollupId) returns (address p) {
        proxy = p;
    } catch {
        proxy = manager.computeCrossChainProxyAddress(originalAddress, originalRollupId);
    }
}

/// @notice Action hash builder matching Rollups._computeActionInputHash.
function actionHash(Action memory a) pure returns (bytes32) {
    return keccak256(abi.encode(a.rollupId, a.destination, a.value, a.data, a.sourceAddress, a.sourceRollup));
}

// ══════════════════════════════════════════════════════════════════════
//  RollingHashBuilder — replay the same tagged-hash sequence that
//  Rollups._processNCalls / _consumeNestedAction produce on-chain.
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
//  L2TXBatcher — postBatch + executeL2TX in one tx (local mode).
//  Satisfies the same-block requirement.
// ══════════════════════════════════════════════════════════════════════

contract L2TXBatcher {
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, StaticCall[] calldata staticCalls) external {
        uint256 tc = (entries.length > 0 && entries[0].actionHash == bytes32(0)) ? 1 : 0;
        rollups.postBatch(entries, staticCalls, tc, 0, 0, "", "proof");
        rollups.executeL2TX();
    }
}

// ══════════════════════════════════════════════════════════════════════
//  Common empty helpers (saves boilerplate in E2E scripts)
// ══════════════════════════════════════════════════════════════════════

/// @notice Returns an empty StaticCall[] (for tests that don't use static calls).
function noStaticCalls() pure returns (StaticCall[] memory) {
    return new StaticCall[](0);
}

/// @notice Returns an empty StateDelta[] (for L2 entries).
function noStateDeltas() pure returns (ExecutionEntry memory e) {
    // kept for symmetry — callers normally build StateDelta[] directly
}

/// @notice Returns an empty NestedAction[].
function noNestedActions() pure returns (NestedAction[] memory) {
    return new NestedAction[](0);
}

/// @notice Returns an empty CrossChainCall[].
function noCalls() pure returns (CrossChainCall[] memory) {
    return new CrossChainCall[](0);
}
