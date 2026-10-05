// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {EEZL2} from "../../src/L2/EEZL2.sol";
import {IEEZ} from "../../src/interfaces/IEEZ.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {EEZBridge} from "../../src/periphery/EEZBridge.sol";
import {EEZBridgedToken} from "../../src/periphery/EEZBridgedToken.sol";
import {EEZToken} from "../../src/periphery/defiMock/EEZToken.sol";

contract EEZBridgeTest is Test {
    EEZL2 manager;
    EEZBridge bridge;
    address counterpart = address(0xBEEF);
    address original = address(0xCAFE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address spender = address(0x1234);
    address bridgeProxy;

    function setUp() public {
        manager = new EEZL2(1, address(this), false, address(this));
        bridge = new EEZBridge(address(manager), 1, address(this));
        bridge.setCanonicalBridgeAddress(counterpart);
        bridgeProxy = manager.createCrossChainProxy(counterpart, 0);
    }

    function receiveToken(address to, uint256 amount) internal returns (EEZBridgedToken token) {
        vm.prank(bridgeProxy);
        bridge.receiveTokens(original, 0, to, amount, "Source Token", "SRC", 6, 0);
        token = EEZBridgedToken(bridge.getWrappedToken(original, 0));
    }

    function test_bridgeNativelyDeploysEEZTokenAndReusesIt() public {
        EEZBridgedToken token = receiveToken(alice, 100);
        assertEq(address(token.EEZContract()), address(manager));
        assertEq(token.BRIDGE(), address(bridge));
        assertEq(token.name(), "Source Token");
        assertEq(token.symbol(), "SRC");
        assertEq(token.decimals(), 6);
        assertEq(token.balanceOf(alice), 100);
        assertEq(address(receiveToken(alice, 20)), address(token));
        assertEq(token.totalSupply(), 120);
        (address origin, uint64 rollup) = bridge.wrappedTokenInfo(address(token));
        assertEq(origin, original);
        assertEq(rollup, 0);
    }

    function test_bridgeCreatedTokenTranslatesTransfersAndAllowances() public {
        address aliceProxy = manager.createCrossChainProxy(alice, 0);
        address bobProxy = manager.createCrossChainProxy(bob, 0);
        address spenderProxy = manager.createCrossChainProxy(spender, 0);
        EEZBridgedToken token = receiveToken(aliceProxy, 100);
        vm.prank(aliceProxy);
        token.approve(spender, 60);
        vm.prank(spenderProxy);
        assertEq(token.allowance(alice, spender), 60);
        vm.prank(spenderProxy);
        token.transferFrom(alice, bob, 40);
        assertEq(token.balanceOf(aliceProxy), 60);
        assertEq(token.balanceOf(bobProxy), 40);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(aliceProxy, spenderProxy), 20);
        vm.prank(aliceProxy);
        token.transfer(bob, 10);
        vm.prank(spenderProxy);
        assertEq(token.balanceOf(bob), 50);
    }

    function test_onlyBridgeMintsAndBurns() public {
        EEZBridgedToken token = receiveToken(alice, 100);
        vm.expectRevert(EEZBridgedToken.OnlyBridge.selector);
        token.mint(alice, 1);
        vm.expectRevert(EEZBridgedToken.OnlyBridge.selector);
        token.burn(alice, 1);
        vm.expectRevert(Bridge.UnauthorizedCaller.selector);
        bridge.receiveTokens(original, 0, alice, 1, "Fake", "FAKE", 18, 0);
    }

    function test_bridgeBurnsItsEEZTokenOnReturn() public {
        EEZBridgedToken token = receiveToken(alice, 100);
        vm.mockCall(
            address(manager), abi.encodeWithSelector(IEEZ.executeCrossChainCall.selector), abi.encode(bytes(""))
        );
        vm.prank(alice);
        bridge.bridgeTokens(address(token), 30, 0, alice);
        assertEq(token.balanceOf(alice), 70);
        assertEq(token.totalSupply(), 70);
        assertEq(token.balanceOf(address(bridge)), 0);
    }

    function test_locksAndReleasesOriginalEEZTokenWithoutTranslatingRecipient() public {
        EEZToken token = new EEZToken(address(manager), "Local", "LOC", alice, 100);
        vm.mockCall(
            address(manager), abi.encodeWithSelector(IEEZ.executeCrossChainCall.selector), abi.encode(bytes(""))
        );
        vm.startPrank(alice);
        token.approve(address(bridge), 30);
        bridge.bridgeTokens(address(token), 30, 0, alice);
        vm.stopPrank();
        assertEq(token.balanceOf(address(bridge)), 30);
        vm.prank(bridgeProxy);
        bridge.receiveTokens(address(token), 1, bob, 30, "Local", "LOC", 18, 0);
        assertEq(token.balanceOf(bob), 30);
        assertEq(token.balanceOf(address(bridge)), 0);
    }

    function test_constructorRejectsMissingManagerAndReinitialization() public {
        vm.expectRevert(EEZBridge.InvalidManager.selector);
        new EEZBridge(address(0x123), 1, address(this));
        vm.expectRevert(Bridge.AlreadyInitialized.selector);
        bridge.initialize(address(manager), 1, alice);
    }

    function testFuzz_remoteTransferConservesBridgeSupply(uint96 requested) public {
        uint256 amount = bound(requested, 0, 1_000_000);
        address aliceProxy = manager.createCrossChainProxy(alice, 0);
        address bobProxy = manager.createCrossChainProxy(bob, 0);
        EEZBridgedToken token = receiveToken(aliceProxy, 1_000_000);
        vm.prank(aliceProxy);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(aliceProxy) + token.balanceOf(bobProxy), token.totalSupply());
        assertEq(token.balanceOf(bobProxy), amount);
    }
}
