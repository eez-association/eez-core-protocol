// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IFlashLoanReceiver {
    function onFlashLoan(address token, uint256 amount) external;
}

contract FlashLoan is ReentrancyGuard {
    using SafeERC20 for IERC20;

    function flashLoan(address token, uint256 amount) external nonReentrant {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        require(balanceBefore >= amount, "Not enough liquidity");

        IERC20(token).safeTransfer(msg.sender, amount);

        IFlashLoanReceiver(msg.sender).onFlashLoan(token, amount);

        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        require(balanceAfter >= balanceBefore, "Flash loan not repaid");
    }
}
