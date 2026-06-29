// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Bridge} from "../src/periphery/Bridge.sol";

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

/// @title BridgeComputeAddress
/// @dev forge script script/DeployBridge.s.sol:BridgeComputeAddress --sig "run(bytes32)" $SALT
contract BridgeComputeAddress is Script {
    function run(bytes32 salt) external view {
        address predicted = _computeBridgeAddress(salt);
        console.log("Predicted BRIDGE=%s", predicted);
    }
}

/// @title BridgeDeployL1
/// @dev forge script script/DeployBridge.s.sol:BridgeDeployL1 \
///   --rpc-url $L1_RPC --broadcast --private-key $PK --sig "run(address,bytes32)" $ROLLUPS $SALT
contract BridgeDeployL1 is Script {
    function run(address rollups, bytes32 salt) external {
        vm.startBroadcast();
        address bridge = _deployBridge(salt);
        Bridge(bridge).initialize(rollups, 0, msg.sender);
        console.log("BRIDGE_L1=%s", bridge);
        vm.stopBroadcast();
    }
}

/// @title BridgeDeployL2  - same deterministic address, no setCanonicalBridgeAddress needed
/// @dev forge script script/DeployBridge.s.sol:BridgeDeployL2 \
///   --rpc-url $L2_RPC --broadcast --private-key $PK --sig "run(address,uint64,bytes32)" $MANAGER $ROLLUP_ID $SALT
contract BridgeDeployL2 is Script {
    function run(address managerL2, uint64 rollupId, bytes32 salt) external {
        vm.startBroadcast();
        address bridge = _deployBridge(salt);
        Bridge(bridge).initialize(managerL2, rollupId, msg.sender);
        console.log("BRIDGE_L2=%s", bridge);
        vm.stopBroadcast();
    }
}

function _computeBridgeAddress(bytes32 salt) view returns (address) {
    bytes memory initCode = type(Bridge).creationCode;
    return
        address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, keccak256(initCode))))));
}

function _deployBridge(bytes32 salt) returns (address deployed) {
    deployed = _computeBridgeAddress(salt);
    (bool success,) = CREATE2_FACTORY.call(abi.encodePacked(salt, type(Bridge).creationCode));
    require(success, "CREATE2 deployment failed");
    require(deployed.code.length > 0, "Bridge not deployed at expected address");
}
