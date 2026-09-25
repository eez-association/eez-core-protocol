// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {DeploymentBase} from "../../deployment/Deploy.s.sol";
import {UpgradeEEZ} from "../../deployment/Upgrade.s.sol";
import {CrossChainProxy} from "../../src/base/CrossChainProxy.sol";
import {EEZ} from "../../src/EEZ.sol";
import {Rollup} from "../../src/rollupContract/Rollup.sol";
import {ECDSAProofSystem} from "../../src/proofSystems/ECDSAProofSystem.sol";

// Exercise the same deployment helpers used by the broadcast entry points.
contract DeploymentHarness is DeploymentBase {
    function deployEEZ(address recovery, address upgradeOwner) external returns (EEZ) {
        return _deployEEZ(recovery, upgradeOwner);
    }

    function deployRollup(
        address eez,
        address owner,
        address upgradeOwner,
        address ps,
        bytes32 key
    )
        external
        returns (Rollup)
    {
        address[] memory systems = new address[](1);
        systems[0] = ps;
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        return _deployRollup(eez, owner, upgradeOwner, 1, systems, keys);
    }
}

contract DeploymentTest is Test {
    bytes32 constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 constant KEY = keccak256("verification key");
    address upgradeOwner = makeAddr("upgrade owner");
    address recovery = makeAddr("recovery");
    address attacker = makeAddr("attacker");
    EEZ eez;
    Rollup rollup;
    ECDSAProofSystem proof;
    DeploymentHarness deployer;

    function setUp() public {
        deployer = new DeploymentHarness();
        eez = deployer.deployEEZ(recovery, upgradeOwner);
        proof = new ECDSAProofSystem(address(this), makeAddr("signer"));
        rollup = deployer.deployRollup(address(eez), address(this), upgradeOwner, address(proof), KEY);
        eez.registerRollup(address(rollup), keccak256("genesis"));
    }

    function _admin(address proxy) internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(proxy, ADMIN_SLOT)))));
    }

    function testDeploymentConfigurationAndPermissions() public view {
        assertEq(eez.RECOVERY_ADDRESS(), recovery);
        assertEq(eez.PROXY_INIT_CODE_HASH(), keccak256(type(CrossChainProxy).creationCode));
        assertEq(rollup.EEZContract(), address(eez));
        assertEq(rollup.owner(), address(this));
        assertEq(rollup.threshold(), 1);
        assertEq(rollup.verificationKey(address(proof)), KEY);
        assertEq(rollup.rollupId(), 1);
        assertEq(eez.rollupCounter(), 1);
        assertEq(_admin(address(eez)).owner(), upgradeOwner);
        assertEq(_admin(address(rollup)).owner(), upgradeOwner);
        assertTrue(address(_admin(address(eez))) != address(_admin(address(rollup))));
    }

    function testProxyAndImplementationCannotBeReinitialized() public {
        address implementation = address(uint160(uint256(vm.load(address(rollup), IMPLEMENTATION_SLOT))));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        rollup.initialize(attacker, 0, new address[](0), new bytes32[](0));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Rollup(implementation).initialize(attacker, 0, new address[](0), new bytes32[](0));
    }

    function testRejectsZeroProxyOwner() public {
        Rollup implementation = new Rollup(address(eez));
        bytes memory data = abi.encodeCall(Rollup.initialize, (address(0), 0, new address[](0), new bytes32[](0)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new TransparentUpgradeableProxy(address(implementation), upgradeOwner, data);
    }

    function testUnauthorizedUpgradeAndOperationalChangesRevert() public {
        EEZ next = new EEZ(recovery);
        ProxyAdmin admin = _admin(address(eez));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(eez)), address(next), "");
        vm.prank(upgradeOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, upgradeOwner));
        rollup.setThreshold(0);
    }

    function testUpgradeScriptRejectsDifferentProxyCreationCodeHash() public {
        EEZ next = new EEZ(recovery);
        UpgradeEEZ upgrade = new UpgradeEEZ();
        bytes32 originalImplementation = vm.load(address(eez), IMPLEMENTATION_SLOT);
        bytes32 differentHash = bytes32(uint256(eez.PROXY_INIT_CODE_HASH()) ^ 1);
        vm.mockCall(address(next), abi.encodeWithSignature("PROXY_INIT_CODE_HASH()"), abi.encode(differentHash));

        vm.expectRevert(bytes("Cross-chain proxy bytecode mismatch"));
        upgrade.run(address(eez), address(next), "");

        assertEq(vm.load(address(eez), IMPLEMENTATION_SLOT), originalImplementation);
    }

    function testUpgradePreservesStateAndCrossChainProxyAddresses() public {
        address original = makeAddr("L2 account");
        address crossChainProxy = eez.createCrossChainProxy(original, 1);
        bytes32 root = keccak256("updated root");
        rollup.setRoot(root);
        rollup.setThreshold(2);
        bytes32 nextKey = keccak256("rotated key");
        rollup.updateVerificationKey(address(proof), nextKey);
        EEZ nextEEZ = new EEZ(recovery);
        Rollup nextRollup = new Rollup(address(eez));
        ProxyAdmin eezAdmin = _admin(address(eez));
        ProxyAdmin rollupAdmin = _admin(address(rollup));
        vm.startPrank(upgradeOwner);
        eezAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(eez)), address(nextEEZ), "");
        rollupAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(rollup)), address(nextRollup), "");
        vm.stopPrank();
        assertEq(address(uint160(uint256(vm.load(address(eez), IMPLEMENTATION_SLOT)))), address(nextEEZ));
        assertEq(address(uint160(uint256(vm.load(address(rollup), IMPLEMENTATION_SLOT)))), address(nextRollup));
        assertEq(rollup.owner(), address(this));
        assertEq(rollup.EEZContract(), address(eez));
        assertEq(rollup.threshold(), 2);
        assertEq(rollup.verificationKey(address(proof)), nextKey);
        assertEq(rollup.rollupId(), 1);
        assertEq(eez.rollupCounter(), 1);
        (address storedRollup, bytes32 storedRoot,) = eez.rollups(1);
        assertEq(storedRollup, address(rollup));
        assertEq(storedRoot, root);
        assertEq(eez.computeCrossChainProxyAddress(original, 1), crossChainProxy);
        assertEq(eez.getOrCreateCrossChainProxy(original, 1), crossChainProxy);
        rollup.setRoot(keccak256("post-upgrade root"));
        (, storedRoot,) = eez.rollups(1);
        assertEq(storedRoot, keccak256("post-upgrade root"));
    }

    function testImplementationHasNoOperationalConfigurationAndIsLocked() public {
        Rollup direct = new Rollup(address(eez));
        assertEq(direct.owner(), address(0));
        assertEq(direct.EEZContract(), address(eez));
        assertEq(direct.threshold(), 0);
        assertEq(direct.rollupId(), 0);
        assertEq(direct.verificationKey(address(proof)), bytes32(0));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        direct.initialize(attacker, 0, new address[](0), new bytes32[](0));
    }
}
