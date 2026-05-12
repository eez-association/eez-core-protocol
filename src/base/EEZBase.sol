// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEEZ} from "../interfaces/IEEZ.sol";

/// @title EEZBase
/// @notice Shared base for the L1 (`EEZ`) and L2 (`EEZL2`) cross-chain managers.
/// @dev Holds the rolling-hash machinery used identically by both: the four event-type
///      tag constants, the `_rollingHash` transient accumulator, and the helpers that
///      fold tagged events into it.
///
///      Other shared concerns (proxy creation, lookup-call resolution, revertSpan handling,
///      `_consumeNestedAction`, `_processNCalls`) are intentionally NOT extracted yet — the
///      children currently diverge in subtle ways (transient lookup tables on L1, ether
///      accounting on L1, etc.). Future iterations can pull more into this base once those
///      divergences are reconciled.
abstract contract EEZBase is IEEZ {
    // ── Rolling hash tag constants ──
    uint8 internal constant CALL_BEGIN = 1;
    uint8 internal constant CALL_END = 2;
    uint8 internal constant NESTED_BEGIN = 3;
    uint8 internal constant NESTED_END = 4;

    /// @notice Transient rolling hash accumulating tagged events across the entire entry
    bytes32 transient _rollingHash;

    // ──────────────────────────────────────────────
    //  Rolling hash helpers
    // ──────────────────────────────────────────────
    //
    // The entry-level `_rollingHash` accumulator is updated at four event points during
    // entry execution: at the start and end of each top-level call, and at the start and
    // end of each nested-action frame. Each event is tagged with a domain byte
    // (CALL_BEGIN/CALL_END/NESTED_BEGIN/NESTED_END) so the same set of inputs can't collide
    // across event types. The final value is checked against `entry.rollingHash` at the end
    // of execution. See `docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md` §E for the full specification.
    //
    // Static-call sub-hashes (`_rollingHashStaticResult`) use a simpler, untagged formula
    // because they're verified against `LookupCall.rollingHash`, a separate accumulator.

    /// @notice Folds a CALL_BEGIN event into `_rollingHash` for the given call number.
    function _rollingHashCallBegin(uint256 callNumber) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_BEGIN, callNumber));
    }

    /// @notice Folds a CALL_END event into `_rollingHash`, including the call's observed
    ///         outcome (success flag + raw return/revert data).
    function _rollingHashCallEnd(uint256 callNumber, bool success, bytes memory retData) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_END, callNumber, success, retData));
    }

    /// @notice Folds a NESTED_BEGIN event into `_rollingHash` for the given nested-action
    ///         index (1-indexed).
    function _rollingHashNestedBegin(uint256 nestedNumber) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_BEGIN, nestedNumber));
    }

    /// @notice Folds a NESTED_END event into `_rollingHash` for the given nested-action
    ///         index (1-indexed).
    function _rollingHashNestedEnd(uint256 nestedNumber) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_END, nestedNumber));
    }

    /// @notice Folds a static sub-call result into a local accumulator. Pure: doesn't touch
    ///         `_rollingHash` because lookup calls are verified against
    ///         `LookupCall.rollingHash`, a separate per-LookupCall accumulator.
    function _rollingHashStaticResult(bytes32 prev, bool success, bytes memory retData)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(prev, success, retData));
    }
}
