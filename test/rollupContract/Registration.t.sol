// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EEZ} from "../../src/EEZ.sol";
import {Rollup} from "../../src/rollupContract/Rollup.sol";

contract RollupRegistrationTest is Test {
    EEZ internal registry;
    Rollup internal manager;

    function setUp() public {
        registry = new EEZ(makeAddr("recovery"));
        manager = new Rollup(address(registry), address(this), 0, new address[](0), new bytes32[](0));
    }

    function testFuzz_UnauthorizedRegistrationRollsBackThenOwnerRegisters(
        address attacker,
        bytes32 maliciousRoot
    )
        public
    {
        vm.assume(attacker != address(this));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Rollup.UnauthorizedRegistrantAccount.selector, attacker));
        registry.registerRollup(address(manager), maliciousRoot);

        assertEq(registry.rollupCounter(), 0);
        assertEq(manager.rollupId(), 0);
        (address storedManager, bytes32 storedRoot, uint256 balance) = registry.rollups(1);
        assertEq(storedManager, address(0));
        assertEq(storedRoot, bytes32(0));
        assertEq(balance, 0);

        bytes32 approvedRoot = keccak256("owner-approved genesis");
        assertEq(registry.registerRollup(address(manager), approvedRoot), 1);
        assertEq(manager.rollupId(), 1);
        (storedManager, storedRoot, balance) = registry.rollups(1);
        assertEq(storedManager, address(manager));
        assertEq(storedRoot, approvedRoot);
        assertEq(balance, 0);
    }

    function test_OwnerCannotRegisterSameManagerTwice() public {
        bytes32 approvedRoot = keccak256("owner-approved genesis");
        registry.registerRollup(address(manager), approvedRoot);
        vm.expectRevert(Rollup.AlreadyRegistered.selector);
        registry.registerRollup(address(manager), keccak256("replacement"));
        assertEq(registry.rollupCounter(), 1);
        assertEq(manager.rollupId(), 1);
        (, bytes32 storedRoot,) = registry.rollups(1);
        assertEq(storedRoot, approvedRoot);
    }
}
