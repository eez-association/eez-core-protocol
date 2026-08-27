// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title VerifiedRollupsTransient
/// @notice Holds the executing entry's allowed rollup-id set in transient storage: a count word,
///         then one id per slot. A non-zero count doubles as the "an entry is executing" flag.
///         Reverts roll the set back exactly like storage. Manual region (same convention as
///         `ExpectedL1ToL2CallTransient`) because Solidity's `transient` keyword does not cover arrays.
/// @dev The count word is authoritative: clearing leaves stale id words behind, which the
///      count-bounded reads never see.
abstract contract VerifiedRollupsTransient {
    /// @dev ERC-7201 namespaced, so the region never collides with other transient regions.
    uint256 private constant _VERIFIED_ROLLUPS_SLOT = uint256(
        keccak256(abi.encode(uint256(keccak256("eez.transient.VerifiedRollups")) - 1)) & ~bytes32(uint256(0xff))
    );

    /// @notice Appends `rollupId` to the set (id `i` lives at slot + 1 + i).
    function _pushVerifiedRollup(uint64 rollupId) internal {
        uint256 slot = _VERIFIED_ROLLUPS_SLOT;
        assembly ("memory-safe") {
            let count := add(tload(slot), 1)
            tstore(slot, count)
            tstore(add(slot, count), rollupId)
        }
    }

    /// @notice Empties the set — one tstore of the count word.
    function _clearVerifiedRollups() internal {
        uint256 slot = _VERIFIED_ROLLUPS_SLOT;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @notice Number of ids held; 0 means no entry is executing.
    function _verifiedRollupCount() internal view returns (uint256 count) {
        uint256 slot = _VERIFIED_ROLLUPS_SLOT;
        assembly ("memory-safe") {
            count := tload(slot)
        }
    }

    /// @notice True iff `rollupId` is in the set. Linear scan (the set is an entry's few rollup updates).
    function _containsVerifiedRollup(uint64 rollupId) internal view returns (bool found) {
        uint256 slot = _VERIFIED_ROLLUPS_SLOT;
        assembly ("memory-safe") {
            // Ids live at slot+1 .. slot+count; iszero(gt(i, count)) is `i <= count` (the EVM has
            // no LE opcode).
            let count := tload(slot)
            for { let i := 1 } iszero(gt(i, count)) { i := add(i, 1) } {
                if eq(tload(add(slot, i)), rollupId) {
                    found := 1
                    break
                }
            }
        }
    }
}
