// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Rollup} from "../../src/rollupContract/Rollup.sol";

/// @notice Unit tests for the reference per-rollup manager. Uses this test contract as both the
///         registry (`ROLLUPS`) and the owner so registry-only and owner-only paths are reachable
///         without pranking gymnastics.
contract RollupTest is Test {
    Rollup internal rollup;

    bytes32 internal lastStateRoot;

    // Ascending proof-system addresses (strictly-increasing requirement).
    address internal ps1 = address(0x1001);
    address internal ps2 = address(0x1002);
    address internal ps3 = address(0x1003);

    bytes32 internal constant VK1 = bytes32(uint256(0x11));
    bytes32 internal constant VK2 = bytes32(uint256(0x22));

    address internal alice = makeAddr("alice");

    /// @dev Stand-in for `EEZ.setStateRoot` so the escape-hatch path resolves.
    function setStateRoot(uint256, bytes32 newStateRoot) external {
        lastStateRoot = newStateRoot;
    }

    function setUp() public {
        address[] memory psList = new address[](1);
        psList[0] = ps1;
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = VK1;
        // ROLLUPS = owner = this contract.
        rollup = new Rollup(address(this), address(this), 1, psList, vks);
    }

    // ── constructor reverts ─────────────────────────────────────

    function test_constructorZeroRegistryReverts() public {
        address[] memory psList = new address[](0);
        bytes32[] memory vks = new bytes32[](0);
        vm.expectRevert(Rollup.InvalidConfig.selector);
        new Rollup(address(0), address(this), 0, psList, vks);
    }

    function test_constructorLengthMismatchReverts() public {
        address[] memory psList = new address[](1);
        psList[0] = ps1;
        bytes32[] memory vks = new bytes32[](0);
        vm.expectRevert(Rollup.InvalidConfig.selector);
        new Rollup(address(this), address(this), 0, psList, vks);
    }

    function test_constructorZeroVkeyReverts() public {
        address[] memory psList = new address[](1);
        psList[0] = ps1;
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = bytes32(0);
        vm.expectRevert(Rollup.InvalidConfig.selector);
        new Rollup(address(this), address(this), 0, psList, vks);
    }

    function test_constructorDuplicatePsReverts() public {
        address[] memory psList = new address[](2);
        psList[0] = ps1;
        psList[1] = ps1;
        bytes32[] memory vks = new bytes32[](2);
        vks[0] = VK1;
        vks[1] = VK2;
        vm.expectRevert(abi.encodeWithSelector(Rollup.ProofSystemAlreadyAllowed.selector, ps1));
        new Rollup(address(this), address(this), 0, psList, vks);
    }

    // ── checkProofSystemsAndGetVkeys ────────────────────────────

    function test_checkProofSystemsBelowThresholdReverts() public {
        rollup.setThreshold(2);
        address[] memory q = new address[](1);
        q[0] = ps1;
        vm.expectRevert(abi.encodeWithSelector(Rollup.ThresholdNotMet.selector, 1, 2));
        rollup.checkProofSystemsAndGetVkeys(q);
    }

    function test_checkProofSystemsNonIncreasingReverts() public {
        rollup.addProofSystem(ps2, VK2);
        address[] memory q = new address[](2);
        q[0] = ps2;
        q[1] = ps1; // out of order
        vm.expectRevert(abi.encodeWithSelector(Rollup.ProofSystemNotAllowed.selector, ps1));
        rollup.checkProofSystemsAndGetVkeys(q);
    }

    function test_checkProofSystemsUnknownReverts() public {
        address[] memory q = new address[](1);
        q[0] = ps3; // never added
        vm.expectRevert(abi.encodeWithSelector(Rollup.ProofSystemNotAllowed.selector, ps3));
        rollup.checkProofSystemsAndGetVkeys(q);
    }

    function test_checkProofSystemsSuccessMulti() public {
        rollup.addProofSystem(ps2, VK2);
        address[] memory q = new address[](2);
        q[0] = ps1;
        q[1] = ps2;
        bytes32[] memory vks = rollup.checkProofSystemsAndGetVkeys(q);
        assertEq(vks[0], VK1);
        assertEq(vks[1], VK2);
    }

    // ── rollupContractRegistered ────────────────────────────────

    function test_registerNonRegistryReverts() public {
        vm.prank(alice);
        vm.expectRevert(Rollup.NotEEZRegistry.selector);
        rollup.rollupContractRegistered(1);
    }

    function test_registerTwiceReverts() public {
        rollup.rollupContractRegistered(5);
        assertEq(rollup.rollupId(), 5);
        vm.expectRevert(Rollup.AlreadyRegistered.selector);
        rollup.rollupContractRegistered(6);
    }

    // ── owner ops ───────────────────────────────────────────────

    function test_addProofSystemZeroVkeyReverts() public {
        vm.expectRevert(Rollup.InvalidConfig.selector);
        rollup.addProofSystem(ps2, bytes32(0));
    }

    function test_addProofSystemAlreadyAllowedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Rollup.ProofSystemAlreadyAllowed.selector, ps1));
        rollup.addProofSystem(ps1, VK2);
    }

    function test_addProofSystemSuccess() public {
        rollup.addProofSystem(ps2, VK2);
        assertEq(rollup.verificationKey(ps2), VK2);
    }

    function test_removeProofSystemNotAddedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Rollup.ProofSystemNotAdded.selector, ps3));
        rollup.removeProofSystem(ps3);
    }

    function test_removeProofSystemSuccess() public {
        rollup.removeProofSystem(ps1);
        assertEq(rollup.verificationKey(ps1), bytes32(0));
    }

    function test_updateVerificationKeyZeroReverts() public {
        vm.expectRevert(Rollup.InvalidConfig.selector);
        rollup.updateVerificationKey(ps1, bytes32(0));
    }

    function test_updateVerificationKeyNotAddedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Rollup.ProofSystemNotAdded.selector, ps3));
        rollup.updateVerificationKey(ps3, VK2);
    }

    function test_updateVerificationKeySuccess() public {
        rollup.updateVerificationKey(ps1, VK2);
        assertEq(rollup.verificationKey(ps1), VK2);
    }

    function test_setThreshold() public {
        rollup.setThreshold(3);
        assertEq(rollup.threshold(), 3);
    }

    function test_setStateRootEscapeHatch() public {
        rollup.rollupContractRegistered(1);
        rollup.setStateRoot(bytes32(uint256(0xDEAD)));
        assertEq(lastStateRoot, bytes32(uint256(0xDEAD)));
    }

    function test_ownerOpsOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rollup.setThreshold(9);
    }
}
