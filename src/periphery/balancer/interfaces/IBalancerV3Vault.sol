// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal Balancer V3 ABI. Call all functions on the Vault address.
interface IBalancerV3Vault {
    function unlock(bytes calldata data) external returns (bytes memory result);
    function sendTo(IERC20 token, address to, uint256 amount) external;
    function settle(IERC20 token, uint256 amountHint) external returns (uint256 credit);
    function getReservesOf(IERC20 token) external view returns (uint256);
}
