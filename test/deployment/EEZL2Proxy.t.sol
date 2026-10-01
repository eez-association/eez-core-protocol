// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ExecutionEntry, StaticExecutionEntryL2} from "../../src/interfaces/IEEZL2.sol";
import {EEZL2RecoveryTest} from "../EEZL2Recovery.t.sol";
import {DeploymentBase} from "../../deployment/Deploy.s.sol";
import {UpgradeEEZL2} from "../../deployment/Upgrade.s.sol";
import {EEZL2} from "../../src/L2/EEZL2.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract L2DeploymentHarness is DeploymentBase {
    function deploy(uint64 id, address system, bool gasMode, address recovery, address owner) external returns (EEZL2) {
        return _deployL2(id, system, gasMode, recovery, owner);
    }
}

// Run recovery and outgoing-call integration tests through the production proxy deployment.
contract EEZL2ProxyTest is EEZL2RecoveryTest {
    bytes32 constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    address upgradeOwner = address(0xABCD);

    function setUp() public override {
        manager = new L2DeploymentHarness().deploy(TEST_ROLLUP_ID, SYSTEM_ADDRESS, false, RECOVERY, upgradeOwner);
    }

    function testProxyUpgradePreservesStateAndAddresses() public {
        address remoteProxy = manager.createCrossChainProxy(REMOTE, MAINNET);
        _loadSingle(_buildNoCalls(bytes32(uint256(1)), ""));
        uint256 loadedBlock = manager.lastLoadBlock();
        EEZL2 next = new EEZL2(TEST_ROLLUP_ID, SYSTEM_ADDRESS, false, RECOVERY);
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(address(manager), ADMIN_SLOT)))));
        assertEq(admin.owner(), upgradeOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(manager)), address(next), "");
        vm.prank(upgradeOwner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(manager)), address(next), "");
        assertEq(manager.ROLLUP_ID(), TEST_ROLLUP_ID);
        assertEq(manager.SYSTEM_ADDRESS(), SYSTEM_ADDRESS);
        assertEq(manager.RECOVERY_ADDRESS(), RECOVERY);
        assertFalse(manager.USE_GAS_LEFT());
        assertEq(manager.entriesLength(), 1);
        assertEq(manager.lastLoadBlock(), loadedBlock);
        assertEq(next.entriesLength(), 0);
        assertEq(manager.getOrCreateCrossChainProxy(REMOTE, MAINNET), remoteProxy);
        vm.expectRevert(EEZL2.Unauthorized.selector);
        manager.loadExecutionTable(new ExecutionEntry[](0), new StaticExecutionEntryL2[](0));
    }

    function testUpgradeScriptRejectsChangedSystemAddress() public {
        EEZL2 next = new EEZL2(TEST_ROLLUP_ID, address(0x1234), false, RECOVERY);
        UpgradeEEZL2 upgrade = new UpgradeEEZL2();
        vm.expectRevert(bytes("System address mismatch"));
        upgrade.run(address(manager), address(next), "");
    }

    function testDeploymentRejectsZeroUpgradeOwner() public {
        L2DeploymentHarness deployer = new L2DeploymentHarness();
        vm.expectRevert(bytes("Zero address"));
        deployer.deploy(TEST_ROLLUP_ID, SYSTEM_ADDRESS, false, RECOVERY, address(0));
    }
}
