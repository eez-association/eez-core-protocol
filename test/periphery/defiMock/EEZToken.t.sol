// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;
import {Test} from "forge-std/Test.sol";
import {EEZToken} from "../../../src/periphery/defiMock/EEZToken.sol";
import {EEZWrappedNative} from "../../../src/periphery/defiMock/EEZWrappedNative.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";

// A contract can advertise proxy-like getters without belonging to EEZ's registry.
contract UnregisteredProxyLookalike {
    function originalRollupId() external pure returns (uint64) {
        return 0;
    }

    function transferToken(EEZToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract EEZTokenTest is Test {
    EEZL2 manager;
    EEZToken token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address spender = address(0x123);
    address aliceProxy;
    address bobProxy;
    address spenderProxy;

    function setUp() public {
        manager = new EEZL2(1, address(this), false, address(this));
        aliceProxy = manager.createCrossChainProxy(alice, 0);
        bobProxy = manager.createCrossChainProxy(bob, 0);
        spenderProxy = manager.createCrossChainProxy(spender, 0);
        token = new EEZToken(address(manager), "EEZ", "EEZ", aliceProxy, 100 ether);
    }

    function test_remoteTransferAndBalanceUseSameNamespace() public {
        vm.prank(aliceProxy);
        token.transfer(bob, 10 ether);
        assertEq(token.balanceOf(bobProxy), 10 ether);
        assertEq(token.balanceOf(bob), 0);
        vm.prank(spenderProxy);
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_remoteApprovalAndTransferFrom() public {
        vm.prank(aliceProxy);
        token.approve(spender, 20 ether);
        vm.prank(spenderProxy);
        assertEq(token.allowance(alice, spender), 20 ether);
        vm.prank(spenderProxy);
        token.transferFrom(alice, bob, 10 ether);
        assertEq(token.balanceOf(bobProxy), 10 ether);
        assertEq(token.allowance(aliceProxy, spenderProxy), 10 ether);
    }

    function test_unregisteredCallerCannotSpendProxyBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1 ether);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(aliceProxy, bob, 1 ether);
    }

    function test_localCallsRemainERC20() public {
        token = new EEZToken(address(manager), "Local", "LOC", alice, 100 ether);
        vm.prank(alice);
        token.approve(spender, 20 ether);
        vm.prank(spender);
        token.transferFrom(alice, bob, 10 ether);
        assertEq(token.balanceOf(bob), 10 ether);
        assertEq(token.balanceOf(bobProxy), 0);
    }

    function test_zeroRecipientStillRejected() public {
        vm.prank(aliceProxy);
        vm.expectRevert();
        token.transfer(address(0), 1);
    }

    function test_namespaceIsScopedToSourceChain() public {
        address otherChainProxy = manager.createCrossChainProxy(spender, 2);
        vm.prank(otherChainProxy);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_nativeWrapperBacking() public {
        EEZWrappedNative native = new EEZWrappedNative(address(manager));
        vm.deal(alice, 2 ether);
        vm.startPrank(alice);
        native.deposit{value: 1 ether}();
        native.withdraw(0.4 ether);
        vm.stopPrank();
        assertEq(native.balanceOf(alice), 0.6 ether);
        assertEq(address(native).balance, 0.6 ether);
        assertEq(alice.balance, 1.4 ether);
    }

    function test_infiniteRemoteAllowanceIsNotDecremented() public {
        vm.prank(aliceProxy);
        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spenderProxy);
        assertTrue(token.transferFrom(alice, bob, 1 ether));
        assertEq(token.allowance(aliceProxy, spenderProxy), type(uint256).max);
        assertEq(token.balanceOf(bobProxy), 1 ether);
    }

    function testFuzz_remoteTransferPreservesSupply(uint96 requestedAmount) public {
        uint256 amount = bound(uint256(requestedAmount), 0, 100 ether);
        vm.prank(aliceProxy);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(aliceProxy), 100 ether - amount);
        assertEq(token.balanceOf(bobProxy), amount);
        assertEq(token.totalSupply(), 100 ether);
    }

    function test_proxyLikeContractIsLocalUnlessEEZRegistersIt() public {
        UnregisteredProxyLookalike lookalike = new UnregisteredProxyLookalike();
        EEZToken localToken = new EEZToken(address(manager), "Local", "LOC", address(lookalike), 100 ether);
        assertTrue(lookalike.transferToken(localToken, bob, 10 ether));
        assertEq(localToken.balanceOf(bob), 10 ether);
        assertEq(localToken.balanceOf(bobProxy), 0);
    }
}
