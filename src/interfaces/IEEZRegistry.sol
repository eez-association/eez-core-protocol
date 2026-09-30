// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IEEZRegistry
/// @notice Minimal registry interface used by the per-rollup manager.
/// @dev Separate from IEEZ to keep rollup management independent of the cross-chain execution model.
interface IEEZRegistry {
    /// @notice Replaces a rollup's root through its registered management contract.
    /// @param rollupId Identifier of the rollup whose root is replaced.
    /// @param newRoot Replacement state root.
    function setRoot(uint64 rollupId, bytes32 newRoot) external;
}
