// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../src/EEZ.sol";
import {Rollup} from "../../src/rollupContract/Rollup.sol";
import {IProofSystem} from "../../src/interfaces/IProofSystem.sol";
import {ExecutionEntry, StateDelta, L2ToL1Call, ExpectedL1ToL2Call, LookupCall} from "../../src/interfaces/IEEZ.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {_deployBridge} from "../DeployBridge.s.sol";

contract MockProofSystem is IProofSystem {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

/// @notice Helper that executes postAndVerifyBatch + bridgeEther in a single transaction.
contract BridgeBatcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        uint256 rollupId,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        Bridge bridge,
        address destination
    )
        external
        payable
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";

        uint64[] memory psIdx = new uint64[](1);
        psIdx[0] = 0;
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: rollupId, proofSystemIndex: psIdx});

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            entries: entries,
            l1ToL2lookupCalls: lookupCalls,
            transientExecutionEntryCount: 0,
            transientLookupCallCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
        bridge.bridgeEther{value: msg.value}(rollupId, destination);
    }
}

/// @title E2EBridgeDeploy -- Deploy infra + bridge contracts
/// @dev Burns rollupId 0 (MAINNET); L2 rollup at id=1.
contract E2EBridgeDeploy is Script {
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function run() external {
        vm.startBroadcast();

        MockProofSystem ps = new MockProofSystem();
        EEZ rollups = new EEZ();

        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = DEFAULT_VK;

        Rollup burn = new Rollup(address(rollups), msg.sender, 1, psList, vks);
        rollups.registerRollup(address(burn), bytes32(0));

        Rollup l2Manager = new Rollup(address(rollups), msg.sender, 1, psList, vks);
        uint256 rid = rollups.registerRollup(address(l2Manager), keccak256("l2-initial-state"));
        require(rid == 1, "expected L2 rollupId = 1");

        bytes32 salt = keccak256("sync-rollups-bridge-v1");
        address bridgeAddr = _deployBridge(salt);
        Bridge bridge = Bridge(bridgeAddr);
        bridge.initialize(address(rollups), 0, msg.sender);

        console.log("PROOF_SYSTEM=%s", address(ps));
        console.log("ROLLUPS=%s", address(rollups));
        console.log("BRIDGE=%s", address(bridge));

        vm.stopBroadcast();
    }
}

/// @title E2EBridgeExecute -- postAndVerifyBatch + bridgeEther via BridgeBatcher (single tx)
contract E2EBridgeExecute is Script {
    function run(address rollupsAddr, address proofSystemAddr, address bridgeAddr) external {
        vm.startBroadcast();

        BridgeBatcher batcher = new BridgeBatcher();

        address destination = msg.sender;
        uint256 L2_ROLLUP_ID = 1;

        bytes32 callHash = keccak256(
            abi.encode(
                L2_ROLLUP_ID, // targetRollupId
                destination, // targetAddress (proxy.originalAddress)
                uint256(1 ether), // value
                bytes(""), // data
                bridgeAddr, // sourceAddress
                uint256(0) // sourceRollupId (MAINNET)
            )
        );

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-bridge"),
            etherDelta: int256(1 ether)
        });

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: stateDeltas,
            proxyEntryHash: callHash,
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: new L2ToL1Call[](0),
            expectedL1ToL2Calls: new ExpectedL1ToL2Call[](0),
            callCount: 0,
            returnData: "",
            rollingHash: bytes32(0)
        });

        LookupCall[] memory noLookups = new LookupCall[](0);

        batcher.execute{
            value: 1 ether
        }(EEZ(rollupsAddr), proofSystemAddr, L2_ROLLUP_ID, entries, noLookups, Bridge(bridgeAddr), destination);

        console.log("done");

        vm.stopBroadcast();
    }
}
