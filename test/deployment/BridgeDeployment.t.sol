// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {WrappedToken} from "../../src/periphery/WrappedToken.sol";
import {
    DeployBridge,
    DeployBridgeImplementation,
    DeployBridgeProxy,
    BridgeComputeAddress,
    ConfigureBridge
} from "../../script/DeployBridge.s.sol";
import {UpgradeBridge} from "../../script/UpgradeBridge.s.sol";
import {MockManager, AcceptingProxy, GoodToken} from "../periphery/Bridge.t.sol";

contract BridgeV2Mock is Bridge {
    uint256 public migrationValue;

    function migrate(uint256 value) external {
        require(msg.sender == ERC1967Utils.getAdmin(), "Only ProxyAdmin");
        require(value == 42, "Invalid migration");
        migrationValue = value;
    }
}

contract BridgeDeploymentTest is Test {
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant IMPLEMENTATION_SALT = keccak256("bridge implementation v1");
    bytes32 constant PROXY_SALT = keccak256("bridge proxy v1");
    bytes32 constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    address bridgeAdmin = DEFAULT_SENDER;
    address upgradeOwner = makeAddr("upgrade owner");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");
    MockManager manager;
    AcceptingProxy remoteProxy;

    function setUp() public {
        vm.etch(
            FACTORY,
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        remoteProxy = new AcceptingProxy();
        manager = new MockManager(address(remoteProxy));
    }

    function _deploy() internal returns (Bridge bridge) {
        bridge = new DeployBridge().run(IMPLEMENTATION_SALT, PROXY_SALT, upgradeOwner);
    }

    function _configured() internal returns (Bridge bridge) {
        bridge = _deploy();
        vm.prank(bridgeAdmin);
        bridge.initializeBridge(address(manager), address(0), 7);
    }

    function _admin(address proxy) internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(proxy, ADMIN_SLOT)))));
    }

    function testDeploymentSetsOnlyAdminAndKeepsImplementationStorageSeparate() public {
        (address implementation, address predicted) =
            new BridgeComputeAddress().run(IMPLEMENTATION_SALT, PROXY_SALT, upgradeOwner);
        address deployedImplementation = new DeployBridgeImplementation().run(IMPLEMENTATION_SALT);
        Bridge bridge = new DeployBridgeProxy().run(deployedImplementation, PROXY_SALT, upgradeOwner);
        assertEq(implementation, deployedImplementation);
        assertEq(address(bridge), predicted);
        assertEq(address(uint160(uint256(vm.load(predicted, IMPLEMENTATION_SLOT)))), implementation);
        assertEq(bridge.admin(), bridgeAdmin);
        assertEq(_admin(predicted).owner(), upgradeOwner);
        assertEq(address(bridge.EEZContract()), address(0));
        assertEq(bridge.rollupId(), 0);
        assertEq(bridge.canonicalBridgeAddress(), address(0));
        vm.prank(attacker);
        vm.expectRevert(Bridge.AlreadyInitialized.selector);
        bridge.initialize(attacker);
        assertEq(Bridge(implementation).admin(), address(1));
        vm.prank(attacker);
        vm.expectRevert(Bridge.AlreadyInitialized.selector);
        Bridge(implementation).initialize(attacker);
        assertEq(bridge.admin(), bridgeAdmin);
    }

    function testOnlyBridgeAdminCanConfigureOnceIncludingL1AndZeroCounterpart() public {
        Bridge bridge = _deploy();
        vm.prank(attacker);
        vm.expectRevert(Bridge.OnlyAdmin.selector);
        bridge.initializeBridge(address(manager), attacker, 7);
        vm.prank(upgradeOwner);
        vm.expectRevert(Bridge.OnlyAdmin.selector);
        bridge.initializeBridge(address(manager), attacker, 7);
        vm.prank(bridgeAdmin);
        bridge.initializeBridge(address(manager), address(0), 0);
        vm.prank(bridgeAdmin);
        vm.expectRevert(Bridge.AlreadyInitialized.selector);
        bridge.initializeBridge(address(manager), attacker, 9);
        assertEq(address(bridge.EEZContract()), address(manager));
        assertEq(bridge.rollupId(), 0);
        assertEq(bridge.canonicalBridgeAddress(), address(0));
        vm.prank(bridgeAdmin);
        (bool mutableCounterpartSetter,) =
            address(bridge).call(abi.encodeWithSignature("setCanonicalBridgeAddress(address)", attacker));
        assertFalse(mutableCounterpartSetter);
    }

    function testAnyPrepopulatedConfigurationFieldRejectsSetup() public {
        Bridge bridge = _deploy();
        uint256 snapshot = vm.snapshotState();
        // EEZContract and rollupId share slot 0; admin is slot 1 and counterpart is slot 2.
        bytes32[3] memory slots = [bytes32(uint256(0)), bytes32(uint256(0)), bytes32(uint256(2))];
        bytes32[3] memory values =
            [bytes32(uint256(uint160(attacker))), bytes32(uint256(7) << 160), bytes32(uint256(1))];
        for (uint256 i; i < slots.length; ++i) {
            vm.store(address(bridge), slots[i], values[i]);
            vm.prank(bridgeAdmin);
            vm.expectRevert(Bridge.AlreadyInitialized.selector);
            bridge.initializeBridge(address(manager), address(0), 0);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testInvalidSetupRollsBackAndAdminCanRetry() public {
        Bridge bridge = _deploy();
        vm.prank(bridgeAdmin);
        vm.expectRevert(Bridge.ZeroAddress.selector);
        bridge.initializeBridge(address(0), attacker, 7);
        assertEq(address(bridge.EEZContract()), address(0));
        assertEq(bridge.canonicalBridgeAddress(), address(0));
        assertEq(bridge.rollupId(), 0);
        vm.prank(bridgeAdmin);
        bridge.initializeBridge(address(manager), attacker, 7);
        assertEq(bridge.canonicalBridgeAddress(), attacker);
    }

    function testAdminCannotTransferRenounceOrReconfigure() public {
        Bridge bridge = _configured();
        vm.startPrank(bridgeAdmin);
        (bool transferred,) = address(bridge).call(abi.encodeWithSignature("transferOwnership(address)", attacker));
        (bool renounced,) = address(bridge).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(transferred);
        assertFalse(renounced);
        vm.expectRevert(Bridge.AlreadyInitialized.selector);
        bridge.initializeBridge(address(manager), attacker, 8);
        vm.stopPrank();
        assertEq(bridge.admin(), bridgeAdmin);
    }

    function testSameProxyAddressAcrossChainsWithDifferentConfiguration() public {
        MockManager otherManager = new MockManager(address(remoteProxy));
        uint256 snapshot = vm.snapshotState();
        vm.chainId(11155111);
        Bridge l1 = _deploy();
        vm.prank(bridgeAdmin);
        l1.initializeBridge(address(manager), address(0), 0);
        address predicted = address(l1);
        bytes32 implementation = vm.load(predicted, IMPLEMENTATION_SLOT);
        assertTrue(vm.revertToState(snapshot));
        vm.chainId(696990);
        Bridge l2 = _deploy();
        vm.prank(bridgeAdmin);
        l2.initializeBridge(address(otherManager), attacker, 7);
        assertEq(address(l2), predicted);
        assertEq(vm.load(predicted, IMPLEMENTATION_SLOT), implementation);
        assertEq(address(l2.EEZContract()), address(otherManager));
        assertEq(l2.rollupId(), 7);
        assertEq(l2.canonicalBridgeAddress(), attacker);
    }

    function _predictedProxy(
        address implementation,
        address initialAdmin,
        address upgrader
    )
        internal
        pure
        returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, upgrader, abi.encodeCall(Bridge.initialize, (initialAdmin)))
        );
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, PROXY_SALT, keccak256(initCode)))))
            );
    }

    function testDifferentAdminOrUpgradeOwnerChangesProxyAddress() public {
        BridgeComputeAddress compute = new BridgeComputeAddress();
        (address implementation, address proxy) = compute.run(IMPLEMENTATION_SALT, PROXY_SALT, upgradeOwner);
        (, address changedUpgradeOwner) = compute.run(IMPLEMENTATION_SALT, PROXY_SALT, attacker);
        assertEq(proxy, _predictedProxy(implementation, bridgeAdmin, upgradeOwner));
        assertNotEq(proxy, _predictedProxy(implementation, attacker, upgradeOwner));
        assertNotEq(proxy, changedUpgradeOwner);
    }

    function testCopiedDeploymentCannotStealAdminAndRerunsReuseProxy() public {
        address implementation = new DeployBridgeImplementation().run(IMPLEMENTATION_SALT);
        bytes memory initCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, upgradeOwner, abi.encodeCall(Bridge.initialize, (bridgeAdmin)))
        );
        vm.prank(attacker);
        (bool ok,) = FACTORY.call(abi.encodePacked(PROXY_SALT, initCode));
        assertTrue(ok);
        Bridge bridge = _configured();
        assertEq(bridge.admin(), bridgeAdmin);
        assertEq(address(_deploy()), address(bridge));
        assertEq(bridge.rollupId(), 7);
    }

    function testInvalidAdminRollsBackProxyCreation() public {
        address implementation = new DeployBridgeImplementation().run(IMPLEMENTATION_SALT);
        address predicted = _predictedProxy(implementation, address(0), upgradeOwner);
        bytes memory initCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, upgradeOwner, abi.encodeCall(Bridge.initialize, (address(0))))
        );
        (bool ok,) = FACTORY.call(abi.encodePacked(PROXY_SALT, initCode));
        assertFalse(ok);
        assertEq(predicted.code.length, 0);
    }

    function testRejectsUnexpectedFactoryCode() public {
        DeployBridge deploy = new DeployBridge();
        vm.etch(FACTORY, hex"00");
        vm.expectRevert(bytes("Unexpected CREATE2 factory code"));
        deploy.run(IMPLEMENTATION_SALT, PROXY_SALT, upgradeOwner);
    }

    function testBridgeAdminCannotUpgradeProxy() public {
        Bridge bridge = _configured();
        BridgeV2Mock next = new BridgeV2Mock();
        ProxyAdmin proxyAdmin = _admin(address(bridge));
        vm.prank(bridgeAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bridgeAdmin));
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(bridge)), address(next), "");
    }

    function testUpgradePreservesConfigurationEscrowAndWrappedTokens() public {
        Bridge bridge = _configured();
        GoodToken original = new GoodToken();
        original.transfer(alice, 100 ether);
        vm.startPrank(alice);
        original.approve(address(bridge), 40 ether);
        bridge.bridgeTokens(address(original), 40 ether, 9, alice);
        vm.stopPrank();
        address foreignToken = makeAddr("foreign token");
        vm.prank(address(remoteProxy));
        bridge.receiveTokens(foreignToken, 9, alice, 100 ether, "Foreign", "FOR", 18, 9);
        WrappedToken wrapped = WrappedToken(bridge.getWrappedToken(foreignToken, 9));
        assertEq(wrapped.BRIDGE(), address(bridge));
        BridgeV2Mock next = new BridgeV2Mock();
        ProxyAdmin proxyAdmin = _admin(address(bridge));
        vm.prank(upgradeOwner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(bridge)), address(next), abi.encodeCall(BridgeV2Mock.migrate, (42))
        );
        assertEq(BridgeV2Mock(address(bridge)).migrationValue(), 42);
        assertEq(next.migrationValue(), 0);
        assertEq(bridge.admin(), bridgeAdmin);
        assertEq(address(bridge.EEZContract()), address(manager));
        assertEq(bridge.rollupId(), 7);
        assertEq(bridge.canonicalBridgeAddress(), address(0));
        assertEq(original.balanceOf(address(bridge)), 40 ether);
        assertEq(bridge.getWrappedToken(foreignToken, 9), address(wrapped));
        (address origin, uint64 originId) = bridge.wrappedTokenInfo(address(wrapped));
        assertEq(origin, foreignToken);
        assertEq(originId, 9);
        vm.prank(address(remoteProxy));
        bridge.receiveTokens(foreignToken, 9, alice, 20 ether, "Foreign", "FOR", 18, 9);
        assertEq(wrapped.balanceOf(alice), 120 ether);
        vm.prank(alice);
        bridge.bridgeTokens(address(wrapped), 30 ether, 9, alice);
        assertEq(wrapped.balanceOf(alice), 90 ether);
        vm.prank(address(remoteProxy));
        bridge.receiveTokens(address(original), 7, alice, 40 ether, "Good Token", "GOOD", 18, 9);
        assertEq(original.balanceOf(alice), 100 ether);
        vm.prank(bridgeAdmin);
        vm.expectRevert(Bridge.AlreadyInitialized.selector);
        bridge.initializeBridge(address(manager), attacker, 8);
    }

    function testRevertingMigrationRollsBackAndCanRetry() public {
        Bridge bridge = _configured();
        bytes32 previous = vm.load(address(bridge), IMPLEMENTATION_SLOT);
        BridgeV2Mock next = new BridgeV2Mock();
        ProxyAdmin proxyAdmin = _admin(address(bridge));
        vm.prank(upgradeOwner);
        vm.expectRevert(bytes("Invalid migration"));
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(bridge)), address(next), abi.encodeCall(BridgeV2Mock.migrate, (43))
        );
        assertEq(vm.load(address(bridge), IMPLEMENTATION_SLOT), previous);
        assertEq(bridge.admin(), bridgeAdmin);
        vm.prank(upgradeOwner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(bridge)), address(next), abi.encodeCall(BridgeV2Mock.migrate, (42))
        );
        assertEq(BridgeV2Mock(address(bridge)).migrationValue(), 42);
    }

    function testConfigurationAndUpgradeScriptsUseBroadcastOwner() public {
        Bridge bridge = new DeployBridge().run(IMPLEMENTATION_SALT, PROXY_SALT, DEFAULT_SENDER);
        new ConfigureBridge().run(address(bridge), address(manager), address(0), 7);
        assertEq(address(bridge.EEZContract()), address(manager));
        assertEq(bridge.rollupId(), 7);
        BridgeV2Mock next = new BridgeV2Mock();
        new UpgradeBridge().run(address(bridge), address(next), abi.encodeCall(BridgeV2Mock.migrate, (42)));
        assertEq(BridgeV2Mock(address(bridge)).migrationValue(), 42);
    }

    function testUpgradeScriptRejectsMissingImplementation() public {
        Bridge bridge = _configured();
        UpgradeBridge upgrade = new UpgradeBridge();
        vm.expectRevert(bytes("Contract has no code"));
        upgrade.run(address(bridge), attacker, "");
    }
}
