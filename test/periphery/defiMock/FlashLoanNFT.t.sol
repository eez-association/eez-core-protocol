// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlashLoan, IFlashLoanReceiver} from "../../../src/periphery/defiMock/FlashLoan.sol";
import {FlashLoanersNFT} from "../../../src/periphery/defiMock/FlashLoanersNFT.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @notice Repays the loan in full inside the callback (happy path).
contract RepayingReceiver is IFlashLoanReceiver {
    function onFlashLoan(address token, uint256 amount) external override {
        IERC20(token).transfer(msg.sender, amount);
    }
}

/// @notice Keeps the borrowed tokens, so the repayment check must fail.
contract NonRepayingReceiver is IFlashLoanReceiver {
    function onFlashLoan(address, uint256) external override {}
}

contract FlashLoanNFTTest is Test {
    MockToken token;
    FlashLoan pool;
    FlashLoanersNFT nft;

    address alice = makeAddr("alice");

    function setUp() public {
        token = new MockToken();
        pool = new FlashLoan();
        nft = new FlashLoanersNFT(address(token));

        // Fund the flash loan pool with liquidity
        token.transfer(address(pool), 100_000e18);
    }

    function test_flashLoanRepaymentEnforced() public {
        // Not enough liquidity
        vm.expectRevert("Not enough liquidity");
        vm.prank(alice);
        pool.flashLoan(address(token), 200_000e18);
    }

    function test_legitimateClaim() public {
        // Give alice real tokens
        token.transfer(alice, 10_000e18);

        // Alice claims directly (no flash loan needed)
        vm.prank(alice);
        nft.claim();

        assertEq(nft.balanceOf(alice), 1);
    }

    function test_cannotClaimBelowMinBalance() public {
        token.transfer(alice, 9_999e18);

        vm.expectRevert("Balance too low");
        vm.prank(alice);
        nft.claim();
    }

    function test_cannotClaimTwice() public {
        token.transfer(alice, 10_000e18);

        vm.startPrank(alice);
        nft.claim();
        vm.expectRevert("Already claimed");
        nft.claim();
        vm.stopPrank();
    }

    function test_flashLoanRepaidSuccessfully() public {
        RepayingReceiver receiver = new RepayingReceiver();
        // Fund the receiver so it can repay from its own balance.
        token.transfer(address(receiver), 10_000e18);

        vm.prank(address(receiver));
        pool.flashLoan(address(token), 10_000e18);

        // Pool keeps its liquidity after a clean repayment.
        assertEq(token.balanceOf(address(pool)), 100_000e18);
    }

    function test_flashLoanNotRepaidReverts() public {
        NonRepayingReceiver receiver = new NonRepayingReceiver();

        vm.prank(address(receiver));
        vm.expectRevert("Flash loan not repaid");
        pool.flashLoan(address(token), 10_000e18);
    }
}
