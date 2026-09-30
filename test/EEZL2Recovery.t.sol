// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseL2} from "./BaseL2.t.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";

contract RejectL2Recovery {
    receive() external payable {
        revert("recovery rejected");
    }
}

contract EEZL2RecoveryTest is BaseL2 {
    address internal constant RECOVERY = address(0xCAFE);
    address internal constant REMOTE = address(0xBEEF);

    function setUp() public override {
        manager = new EEZL2(TEST_ROLLUP_ID, SYSTEM_ADDRESS, false, RECOVERY);
    }

    function test_ConstructorKeepsRecoveryAndSystemIndependent() public view {
        assertEq(manager.RECOVERY_ADDRESS(), RECOVERY);
        assertEq(manager.SYSTEM_ADDRESS(), SYSTEM_ADDRESS);
        assertTrue(RECOVERY != SYSTEM_ADDRESS);
    }

    function test_ConstructorRejectsZeroRecovery() public {
        vm.expectRevert(EEZL2.InvalidRecoveryAddress.selector);
        new EEZL2(TEST_ROLLUP_ID, SYSTEM_ADDRESS, false, address(0));
    }

    function test_ZeroSystemConventionStillAllowsNonzeroRecovery() public {
        EEZL2 zeroSystem = new EEZL2(TEST_ROLLUP_ID, address(0), false, RECOVERY);
        assertEq(zeroSystem.SYSTEM_ADDRESS(), address(0));
        assertEq(zeroSystem.RECOVERY_ADDRESS(), RECOVERY);
    }

    function test_BothProxyCreationPathsSweepToRecovery() public {
        uint256 systemBefore = SYSTEM_ADDRESS.balance;
        uint256 recoveryBefore = RECOVERY.balance;
        address first = manager.computeCrossChainProxyAddress(REMOTE, REMOTE_ROLLUP_ID);
        vm.deal(first, 1 ether);
        assertEq(manager.createCrossChainProxy(REMOTE, REMOTE_ROLLUP_ID), first);
        address second = manager.computeCrossChainProxyAddress(REMOTE, MAINNET);
        vm.deal(second, 2 ether);
        assertEq(manager.getOrCreateCrossChainProxy(REMOTE, MAINNET), second);
        assertEq(RECOVERY.balance, recoveryBefore + 3 ether);
        assertEq(SYSTEM_ADDRESS.balance, systemBefore);
        assertEq(first.balance, 0);
        assertEq(second.balance, 0);
        assertEq(address(manager).balance, 0);
    }

    function test_OutgoingValueStillGoesToSystem() public {
        address proxy = manager.createCrossChainProxy(REMOTE, REMOTE_ROLLUP_ID);
        bytes memory data = hex"1234";
        bytes32 key = _outgoingCallHash(address(this), REMOTE, REMOTE_ROLLUP_ID, 1 ether, 0, data);
        _loadSingle(_buildNoCalls(key, ""));
        vm.deal(address(this), 1 ether);
        uint256 systemBefore = SYSTEM_ADDRESS.balance;
        uint256 recoveryBefore = RECOVERY.balance;
        (bool ok,) = proxy.call{value: 1 ether}(data);
        assertTrue(ok);
        assertEq(SYSTEM_ADDRESS.balance, systemBefore + 1 ether);
        assertEq(RECOVERY.balance, recoveryBefore);
        assertEq(address(manager).balance, 0);
    }

    function test_RejectedRecoveryRemainsBestEffortWithoutSystemFallback() public {
        RejectL2Recovery rejecter = new RejectL2Recovery();
        manager = new EEZL2(TEST_ROLLUP_ID, SYSTEM_ADDRESS, false, address(rejecter));
        address predicted = manager.computeCrossChainProxyAddress(REMOTE, REMOTE_ROLLUP_ID);
        vm.deal(predicted, 1 ether);
        uint256 systemBefore = SYSTEM_ADDRESS.balance;
        assertEq(manager.createCrossChainProxy(REMOTE, REMOTE_ROLLUP_ID), predicted);
        assertGt(predicted.code.length, 0);
        assertEq(predicted.balance, 1 ether);
        assertEq(SYSTEM_ADDRESS.balance, systemBefore);
        assertEq(address(rejecter).balance, 0);
    }
}
