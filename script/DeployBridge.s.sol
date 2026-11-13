// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Bridge} from "../src/periphery/Bridge.sol";

abstract contract BridgeDeployment is Script {
    address internal constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant FACTORY_CODE_HASH = 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 internal constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    function _predict(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, salt, keccak256(initCode))))));
    }

    function _proxyCode(
        address implementation,
        address bridgeAdmin,
        address upgradeOwner
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, upgradeOwner, abi.encodeCall(Bridge.initialize, (bridgeAdmin)))
        );
    }

    function _deploy(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        require(FACTORY.codehash == FACTORY_CODE_HASH, "Unexpected CREATE2 factory code");
        deployed = _predict(salt, initCode);
        if (deployed.code.length == 0) {
            (bool ok,) = FACTORY.call(abi.encodePacked(salt, initCode));
            require(ok && deployed.code.length != 0, "CREATE2 deployment failed");
        }
    }

    function _implementation(bytes32 salt) internal returns (address implementation) {
        implementation = _deploy(salt, type(Bridge).creationCode);
        require(implementation.codehash == keccak256(type(Bridge).runtimeCode), "Implementation code mismatch");
    }

    function _slotAddress(address target, bytes32 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(target, slot))));
    }

    function _proxy(
        address implementation,
        bytes32 salt,
        address bridgeAdmin,
        address upgradeOwner
    )
        internal
        returns (Bridge bridge)
    {
        require(bridgeAdmin != address(0) && upgradeOwner != address(0), "Zero admin/upgrade owner");
        address proxy = _deploy(salt, _proxyCode(implementation, bridgeAdmin, upgradeOwner));
        bridge = Bridge(proxy);
        address proxyAdmin = _slotAddress(proxy, ADMIN_SLOT);
        require(_slotAddress(proxy, IMPLEMENTATION_SLOT) == implementation, "Proxy implementation mismatch");
        require(ProxyAdmin(proxyAdmin).owner() == upgradeOwner, "Upgrade owner mismatch");
        require(bridge.admin() == bridgeAdmin, "Bridge admin mismatch");
        console.log("BRIDGE_IMPLEMENTATION", implementation);
        console.log("BRIDGE_PROXY", proxy);
        console.log("BRIDGE_PROXY_ADMIN", proxyAdmin);
        console.log("BRIDGE_ADMIN", bridgeAdmin);
    }
}

/// @notice Predict addresses for the broadcasting deployer, who will be the bridge admin.
contract BridgeComputeAddress is BridgeDeployment {
    function run(
        bytes32 implementationSalt,
        bytes32 proxySalt,
        address upgradeOwner
    )
        external
        returns (address implementation, address bridge)
    {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        vm.stopBroadcast();
        implementation = _predict(implementationSalt, type(Bridge).creationCode);
        bridge = _predict(proxySalt, _proxyCode(implementation, deployer, upgradeOwner));
        console.log("BRIDGE_IMPLEMENTATION", implementation);
        console.log("BRIDGE_PROXY", bridge);
        console.log("BRIDGE_ADMIN", deployer);
    }
}

/// @notice Optional combined implementation + proxy deployment. Configuration is a separate admin-only step.
contract DeployBridge is BridgeDeployment {
    function run(bytes32 implementationSalt, bytes32 proxySalt, address upgradeOwner) external returns (Bridge bridge) {
        require(upgradeOwner != address(0), "Zero upgrade owner");
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address implementation = _implementation(implementationSalt);
        bridge = _proxy(implementation, proxySalt, deployer, upgradeOwner);
        vm.stopBroadcast();
    }
}

/// @notice Run on each chain to deploy its bridge implementation with CREATE2.
contract DeployBridgeImplementation is BridgeDeployment {
    function run(bytes32 salt) external returns (address implementation) {
        vm.startBroadcast();
        implementation = _implementation(salt);
        vm.stopBroadcast();
        console.log("BRIDGE_IMPLEMENTATION", implementation);
    }
}

/// @notice Run after implementation deployment; atomically sets the broadcasting wallet as bridge admin.
contract DeployBridgeProxy is BridgeDeployment {
    function run(address implementation, bytes32 salt, address upgradeOwner) external returns (Bridge bridge) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        bridge = _proxy(implementation, salt, deployer, upgradeOwner);
        vm.stopBroadcast();
    }
}

/// @notice Admin-only, one-time setup after the two bridge proxy addresses are known.
contract ConfigureBridge is Script {
    function run(address bridge, address EEZContract, address counterpartBridge, uint64 localRollupId) external {
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        require(Bridge(bridge).admin() == broadcaster, "Broadcast as bridge admin");
        Bridge(bridge).initializeBridge(EEZContract, counterpartBridge, localRollupId);
        vm.stopBroadcast();
        console.log("BRIDGE_PROXY", bridge);
        console.log("EEZ_CONTRACT", EEZContract);
        console.log("COUNTERPART_BRIDGE", counterpartBridge);
        console.log("BRIDGE_ROLLUP_ID", uint256(localRollupId));
    }
}

/// @dev Deterministic CREATE2 factory (keyless deployment).
///      This factory is pre-deployed on most EVM chains (Ethereum, Optimism, Arbitrum, etc.)
///      and Foundry's Anvil includes it by default.
///      If the factory is missing on a new or custom chain, use DeployCreate2Factory below.
///      There is no built-in Foundry/cast command to deploy it -- it requires broadcasting
///      a pre-signed raw transaction (the factory uses a keyless deployment scheme where
///      r=s=0x2222...2222, so no one holds the deployer's private key).
address constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
address constant FACTORY_SIGNER = 0x3fAB184622Dc19b6109349B94811493BF2a45362;

/// @title DeployCreate2Factory
/// @dev Only needed if the factory is not already on the target chain.
///      Run the same command twice (forge can't fund + send a pre-signed tx atomically):
///        forge script script/DeployBridge.s.sol:DeployCreate2Factory --rpc-url $RPC --broadcast --private-key $PK
///      First run funds the signer, second run publishes the pre-signed factory tx.
contract DeployCreate2Factory is Script {
    function run() external {
        if (CREATE2_FACTORY.code.length > 0) {
            console.log("CREATE2 factory already deployed at %s", CREATE2_FACTORY);
            return;
        }

        if (FACTORY_SIGNER.balance < 0.01 ether) {
            vm.startBroadcast();
            (bool ok,) = FACTORY_SIGNER.call{value: 0.01 ether}("");
            require(ok);
            vm.stopBroadcast();
            console.log("Signer funded  - run this command again to deploy the factory");
            return;
        }

        // Signer is funded  - send the pre-signed keyless deployment tx
        // RLP([nonce=0, gasPrice=100gwei, gasLimit=100k, to=empty, value=0, bytecode, v=27, r=0x22..22, s=0x22..22])
        vm.rpc(
            "eth_sendRawTransaction",
            "[\"0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222\"]"
        );
        console.log("CREATE2 factory deployed at %s", CREATE2_FACTORY);
    }
}
