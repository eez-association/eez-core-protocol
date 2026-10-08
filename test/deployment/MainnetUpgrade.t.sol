// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MainnetUpgrade} from "../../deployment/MainnetUpgrade.s.sol";
import {EEZ} from "../../src/EEZ.sol";
import {EEZL2} from "../../src/L2/EEZL2.sol";

contract MainnetUpgradeTest is Test {
    MainnetUpgrade upgrade;
    address managerAddress;
    address owner;

    function setUp() public {
        upgrade = new MainnetUpgrade();
        managerAddress = makeAddr("manager");
        owner = makeAddr("upgrade owner");
    }

    function testRejectsWrongChain() public {
        vm.chainId(31337);
        vm.expectRevert(bytes("Unexpected chain"));
        upgrade.run(managerAddress, owner, false);
    }

    function testRejectsMissingManager() public {
        vm.chainId(1);
        vm.expectRevert(bytes("Missing manager"));
        upgrade.run(managerAddress, owner, false);
    }

    function _fork(string memory name) internal {
        string memory rpc = vm.envOr(name, string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        upgrade = new MainnetUpgrade();
        managerAddress =
            vm.envAddress(block.chainid == 1 ? "MAINNET_UPGRADE_TEST_L1_MANAGER" : "MAINNET_UPGRADE_TEST_L2_MANAGER");
        owner = vm.envAddress("MAINNET_UPGRADE_TEST_OWNER");
    }

    function testForkL1UpgradeAndRepeat() public {
        _fork("MAINNET_UPGRADE_TEST_L1_RPC");
        EEZ manager = EEZ(managerAddress);
        uint64 count = manager.rollupCounter();
        (bool ok, bytes memory state) =
            address(manager).staticcall(abi.encodeWithSignature("rollups(uint64)", uint64(1)));
        assertTrue(ok);
        address proxy = manager.computeCrossChainProxyAddress(makeAddr("cross-chain caller"), 1);
        upgrade.run(managerAddress, owner, false);
        upgrade.verify(managerAddress, owner);
        assertEq(manager.rollupCounter(), count);
        (ok, state) = _compareRollup(address(manager), state);
        assertTrue(ok);
        assertEq(manager.computeCrossChainProxyAddress(makeAddr("cross-chain caller"), 1), proxy);
        // Successful reruns must recognize the exact target and avoid deploying again.
        assertTrue(upgrade.check(managerAddress, owner, false));
        upgrade.run(managerAddress, owner, false);
    }

    function _compareRollup(address manager, bytes memory beforeState) internal view returns (bool, bytes memory) {
        (bool ok, bytes memory afterState) = manager.staticcall(abi.encodeWithSignature("rollups(uint64)", uint64(1)));
        assertTrue(ok);
        assertEq(afterState, beforeState);
        return (ok, afterState);
    }

    function testForkL2UpgradeAndRepeat() public {
        _fork("MAINNET_UPGRADE_TEST_L2_RPC");
        EEZL2 manager = EEZL2(managerAddress);
        bytes memory state = abi.encode(
            manager.lastLoadBlock(), manager.entryIndex(), manager.entriesLength(), manager.staticEntriesLength()
        );
        address proxy = manager.computeCrossChainProxyAddress(makeAddr("cross-chain caller"), 0);
        upgrade.run(managerAddress, owner, false);
        upgrade.verify(managerAddress, owner);
        assertEq(
            abi.encode(
                manager.lastLoadBlock(), manager.entryIndex(), manager.entriesLength(), manager.staticEntriesLength()
            ),
            state
        );
        assertEq(manager.computeCrossChainProxyAddress(makeAddr("cross-chain caller"), 0), proxy);
        upgrade.run(managerAddress, owner, false);
    }

    function testForkRejectsWrongSigningKey() public {
        _fork("MAINNET_UPGRADE_TEST_L1_RPC");
        vm.setEnv("UPGRADE_PRIVATE_KEY", vm.addr(1) == owner ? "2" : "1"); // Public test keys only.
        vm.expectRevert(bytes("Wrong UPGRADE_PRIVATE_KEY"));
        upgrade.check(managerAddress, owner, true);
    }
}
