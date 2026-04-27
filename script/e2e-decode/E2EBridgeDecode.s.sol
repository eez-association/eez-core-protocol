// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../src/Rollups.sol";
import {
    ExecutionEntry,
    StateDelta,
    CrossChainCall,
    NestedAction,
    StaticCall
} from "../../src/ICrossChainManager.sol";
import {IZKVerifier} from "../../src/IZKVerifier.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {_deployBridge} from "../DeployBridge.s.sol";

contract MockZKVerifier is IZKVerifier {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

/// @notice Helper that executes postBatch + bridgeEther in a single transaction
/// @dev Needed because executeCrossChainCall requires same block as postBatch
contract BridgeBatcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata staticCalls,
        Bridge bridge,
        uint256 rollupId,
        address destination
    ) external payable {
        rollups.postBatch(entries, staticCalls, 0, 0, 0, "", "proof");
        bridge.bridgeEther{value: msg.value}(rollupId, destination);
    }
}

/// @title E2EBridgeDeploy -- Deploy infra + bridge contracts
contract E2EBridgeDeploy is Script {
    function run() external {
        vm.startBroadcast();

        MockZKVerifier verifier = new MockZKVerifier();
        Rollups rollups = new Rollups(address(verifier), 1);
        rollups.createRollup(keccak256("l2-initial-state"), keccak256("verificationKey"), msg.sender);

        bytes32 salt = keccak256("sync-rollups-bridge-v1");
        address bridgeAddr = _deployBridge(salt);
        Bridge bridge = Bridge(bridgeAddr);
        bridge.initialize(address(rollups), 0, msg.sender);

        console.log("ROLLUPS=%s", address(rollups));
        console.log("BRIDGE=%s", address(bridge));

        vm.stopBroadcast();
    }
}

/// @title E2EBridgeExecute -- postBatch + bridgeEther via BridgeBatcher (single tx)
contract E2EBridgeExecute is Script {
    function run(address rollupsAddr, address bridgeAddr) external {
        vm.startBroadcast();

        BridgeBatcher batcher = new BridgeBatcher();

        address destination = msg.sender;
        uint256 L2_ROLLUP_ID = 1;

        // actionHash: what executeCrossChainCall builds when bridge calls proxy for (destination, L2)
        // proxy.originalAddress = destination, proxy.originalRollupId = L2
        // sourceAddress = bridgeAddr (bridge is msg.sender to proxy)
        bytes32 actionHash = keccak256(
            abi.encode(
                L2_ROLLUP_ID,       // rollupId
                destination,         // destination (proxy.originalAddress)
                uint256(1 ether),    // value
                bytes(""),           // data (empty ETH transfer)
                bridgeAddr,          // sourceAddress
                uint256(0)           // sourceRollup (MAINNET)
            )
        );

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-bridge"),
            etherDelta: 1 ether
        });

        CrossChainCall[] memory calls = new CrossChainCall[](0);
        NestedAction[] memory nestedActions = new NestedAction[](0);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: stateDeltas,
            actionHash: actionHash,
            calls: calls,
            nestedActions: nestedActions,
            callCount: 0,
            returnData: "",
            failed: false,
            rollingHash: bytes32(0)
        });

        StaticCall[] memory noStaticCalls = new StaticCall[](0);

        // Single tx: postBatch + bridgeEther
        batcher.execute{value: 1 ether}(
            Rollups(rollupsAddr),
            entries,
            noStaticCalls,
            Bridge(bridgeAddr),
            L2_ROLLUP_ID,
            destination
        );

        console.log("done");

        vm.stopBroadcast();
    }
}
