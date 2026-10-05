// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {InitializedBridge} from "../../script/DeployInitializedBridge.s.sol";

contract InitializedBridgeTest is Test {
    function test_constructorSetsConfigurationAndRejectsReinitialization() public {
        address manager = makeAddr("manager");
        address admin = makeAddr("admin");
        Bridge bridge = new InitializedBridge(manager, 1, admin);
        assertEq(address(bridge.manager()), manager);
        assertEq(bridge.rollupId(), 1);
        assertEq(bridge.admin(), admin);
        vm.expectRevert(Bridge.AlreadyInitialized.selector);
        bridge.initialize(manager, 1, address(this));
    }

    function test_invalidConfigurationRevertsCreation() public {
        vm.expectRevert(Bridge.ZeroAddress.selector);
        new InitializedBridge(address(0), 1, address(this));
        vm.expectRevert(Bridge.ZeroAddress.selector);
        new InitializedBridge(address(this), 1, address(0));
    }
}
