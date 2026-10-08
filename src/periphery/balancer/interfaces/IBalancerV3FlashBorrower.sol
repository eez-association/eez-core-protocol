// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice L1 entry point reached through an EEZ proxy representing the L2 executor.
interface IBalancerV3FlashBorrower {
    /// @notice Borrow exactly minAmount, reverting if live liquidity is insufficient.
    function execute(uint256 minAmount) external returns (uint256 amount);
}
