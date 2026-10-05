// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {EEZToken} from "../../../src/periphery/defiMock/EEZToken.sol";
import {EEZWrappedNative} from "../../../src/periphery/defiMock/EEZWrappedNative.sol";
import {MiniUniswapFactory} from "../../../src/periphery/defiMock/MiniUniswapFactory.sol";
import {MiniUniswapPair} from "../../../src/periphery/defiMock/MiniUniswapPair.sol";
import {MiniUniswapRouter} from "../../../src/periphery/defiMock/MiniUniswapRouter.sol";
import {MiniPermit2} from "../../../src/periphery/defiMock/MiniPermit2.sol";

contract RejectNativeValue {}

contract MiniUniswapNativeTest is Test {
    EEZToken internal token;
    EEZWrappedNative internal wrappedNative;
    MiniUniswapRouter internal router;
    MiniUniswapPair internal pair;
    MiniPermit2 internal permit;
    address internal alice = makeAddr("alice");

    function setUp() public {
        EEZL2 manager = new EEZL2(1, address(this), false, address(this));
        token = new EEZToken(address(manager), "Token", "TOK", address(this), 10_000 ether);
        wrappedNative = new EEZWrappedNative(address(manager));
        MiniUniswapFactory factory = new MiniUniswapFactory();
        permit = new MiniPermit2();
        router = new MiniUniswapRouter(address(factory), address(permit), address(wrappedNative));

        vm.deal(address(this), 10 ether);
        vm.deal(alice, 10 ether);
        wrappedNative.deposit{value: 1 ether}();
        assertTrue(token.approve(address(router), 1000 ether));
        assertTrue(wrappedNative.approve(address(router), 1 ether));
        router.addLiquidity(
            address(token),
            address(wrappedNative),
            1000 ether,
            1 ether,
            1000 ether,
            1 ether,
            address(this),
            block.timestamp
        );
        pair = MiniUniswapPair(factory.getPair(address(token), address(wrappedNative)));
        assertTrue(token.transfer(alice, 100 ether));
        vm.prank(alice);
        assertTrue(token.approve(address(permit), 100 ether));
        vm.prank(alice);
        permit.approve(address(token), address(router), uint160(100 ether), type(uint48).max);
    }

    function test_nativeInputWrapsExactValueAndLeavesNoRouterBalance() public {
        uint256 expectedOutput = router.getAmountOut(0.01 ether, 1 ether, 1000 ether);
        vm.prank(alice);
        uint256 output =
            router.swapNativeForToken{value: 0.01 ether}(address(token), expectedOutput, alice, block.timestamp);
        assertEq(output, expectedOutput);
        assertEq(token.balanceOf(alice), 100 ether + expectedOutput);
        assertEq(alice.balance, 9.99 ether);
        assertEq(address(router).balance, 0);
        assertEq(wrappedNative.balanceOf(address(router)), 0);
        assertEq(address(wrappedNative).balance, wrappedNative.totalSupply());
    }

    function test_tokenInputUnwrapsOutputToRecipient() public {
        uint256 expectedOutput = router.getAmountOut(10 ether, 1000 ether, 1 ether);
        vm.prank(alice);
        uint256 output = router.swapTokenForNative(address(token), 10 ether, expectedOutput, alice, block.timestamp);
        assertEq(output, expectedOutput);
        assertEq(token.balanceOf(alice), 90 ether);
        assertEq(alice.balance, 10 ether + expectedOutput);
        assertEq(address(router).balance, 0);
        assertEq(wrappedNative.balanceOf(address(router)), 0);
        assertEq(address(wrappedNative).balance, wrappedNative.totalSupply());
    }

    function test_failedNativeRecipientRestoresBalancesAndReserves() public {
        RejectNativeValue recipient = new RejectNativeValue();
        uint256 reserve0 = pair.reserve0();
        uint256 reserve1 = pair.reserve1();
        vm.prank(alice);
        vm.expectRevert("Native transfer failed");
        router.swapTokenForNative(address(token), 10 ether, 0, address(recipient), block.timestamp);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.allowance(alice, address(permit)), 100 ether);
        assertEq(pair.reserve0(), reserve0);
        assertEq(pair.reserve1(), reserve1);
        assertEq(address(wrappedNative).balance, wrappedNative.totalSupply());
    }

    function test_slippageRevertsBeforeSpendingInput() public {
        vm.prank(alice);
        vm.expectRevert("Insufficient output");
        router.swapTokenForNative(address(token), 10 ether, 1 ether, alice, block.timestamp);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.allowance(alice, address(permit)), 100 ether);
    }

    function test_expiredSwapRejectsAndRefundsNativeValue() public {
        // Use a literal deadline: the optimizer assumes block.timestamp is constant
        // within a transaction, while vm.warp deliberately breaks that assumption.
        uint256 deadline = 100;
        vm.warp(101);
        vm.prank(alice);
        vm.expectRevert("Expired");
        router.swapNativeForToken{value: 0.01 ether}(address(token), 0, alice, deadline);
        assertEq(alice.balance, 10 ether);
        assertEq(address(router).balance, 0);
    }
}
