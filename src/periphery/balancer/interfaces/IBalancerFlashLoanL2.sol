// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice L2 callback reached through an EEZ proxy representing the L1 borrower.
interface IBalancerFlashLoanL2 {
    function claimAndBridgeBack(uint256 amount) external;
}
