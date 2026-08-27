// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RollupUpdate} from "../src/interfaces/IEEZ.sol";

/// @notice Protocol-mirror hash helpers shared by the L1 (`Base`) and L2 (`BaseL2`) test
///         fixtures: the rolling-hash tag folds, the cross-chain call hash, and the per-side
///         entry seeds. They mirror `EEZBase` / `EEZ` / `EEZL2` exactly so tests can compute
///         expected `entry.rollingHash` values without hardcoding the tag formulas.
abstract contract TestHashes {
    // ── Rolling hash tag constants (mirror EEZBase.sol) ──
    uint8 internal constant CALL_BEGIN = 1;
    uint8 internal constant CALL_END = 2;
    uint8 internal constant NESTED_BEGIN = 3;
    uint8 internal constant NESTED_END = 4;
    uint8 internal constant CALL_NOT_FOUND = 5;

    // ── Readable isStatic flags (mirror EEZBase.sol) ──
    bool internal constant NOT_STATIC_CALL = false;
    bool internal constant IS_STATIC = true;

    /// @notice Mirror of `EEZBase.computeCrossChainCallHash` with `callGas = 0` (use `_ccHashGas`
    ///         for L2-outgoing calls under `USE_GAS_LEFT`).
    function _ccHash(
        bool isStatic,
        address sourceAddress,
        uint64 sourceRollupId,
        address targetAddress,
        uint64 targetRollupId,
        uint256 value_,
        bytes memory data
    )
        internal
        pure
        returns (bytes32)
    {
        return _ccHashGas(isStatic, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value_, 0, data);
    }

    /// @notice Mirror of `EEZBase.computeCrossChainCallHash` with an explicit `callGas`.
    function _ccHashGas(
        bool isStatic,
        address sourceAddress,
        uint64 sourceRollupId,
        address targetAddress,
        uint64 targetRollupId,
        uint256 value_,
        uint64 callGas,
        bytes memory data
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(isStatic, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value_, callGas, data)
        );
    }

    /// @notice Mirror of `EEZ._rollingHashEntryBegin` (L1 seed): folds the entry's starting state
    ///         (`(rollupId, currentRoot)` per delta) closed with `proxyEntryHash`.
    function _hEntryBegin(RollupUpdate[] memory deltas, bytes32 proxyEntryHash) internal pure returns (bytes32) {
        bytes32 statesHash;
        for (uint256 i = 0; i < deltas.length; i++) {
            statesHash = keccak256(abi.encodePacked(statesHash, deltas[i].rollupId, deltas[i].currentRoot));
        }
        return keccak256(abi.encodePacked(statesHash, proxyEntryHash));
    }

    /// @notice Mirror of `EEZL2._seedRollingHash` (L2 seed): `keccak(bytes32(0), proxyEntryHash)`
    ///         (no state deltas on L2).
    function _hEntryBeginL2(bytes32 proxyEntryHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(0), proxyEntryHash));
    }

    function _hCallBegin(bytes32 prev, bytes32 crossChainCallHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, CALL_BEGIN, crossChainCallHash));
    }

    function _hCallEnd(bytes32 prev, bool success, bytes memory retData) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, CALL_END, success, retData));
    }

    function _hNestedBegin(bytes32 prev, bytes32 crossChainCallHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, NESTED_BEGIN, crossChainCallHash));
    }

    function _hNestedEnd(bytes32 prev) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, NESTED_END));
    }

    function _hCallNotFound(bytes32 prev, bytes32 crossChainCallHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, CALL_NOT_FOUND, crossChainCallHash));
    }

    /// @notice Mirror of `EEZBase._rollingHashStaticResult` (untagged static sub-call schema).
    function _hStatic(bytes32 prev, bool success, bytes memory retData) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, success, retData));
    }
}
