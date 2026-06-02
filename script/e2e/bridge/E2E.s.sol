// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {StateDelta, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry, LookupCall} from "../../../src/interfaces/IEEZ.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noLookupCalls,
    noNestedActions,
    noCalls,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Bridge scenario — L1→L2 with ETH value transfer, two-sided
//
//  L1 side (Execute):
//    BridgeSender.bridge{value: 1 ether}() → L2_PROXY.call{value: 1 ether}("")
//    → EEZ.executeL1ToL2Call consumes the L1 entry; manager balance grows by 1 ether
//    (the etherDelta on the StateDelta records the cross-chain effect on L2's view).
//
//  L2 side (ExecuteL2):
//    SYSTEM_ADDRESS calls managerL2.executeIncomingCrossChainCall{value: 1 ether}(...)
//    → _processNCalls forwards through the source proxy into BridgeReceiver, which
//    accepts the ETH via receive(). After: BridgeReceiver.balance == 1 ether.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

/// @notice Minimal user contract: receives a value-bearing call and forwards it to the L2 proxy.
contract BridgeSender {
    address public immutable L2_PROXY;
    address public immutable L2_DESTINATION;

    constructor(address l2Proxy, address l2Destination) {
        L2_PROXY = l2Proxy;
        L2_DESTINATION = l2Destination;
    }

    function bridge() external payable {
        (bool ok,) = L2_PROXY.call{value: msg.value}("");
        require(ok, "bridge failed");
    }
}

/// @notice Minimal L2-side receiver: accepts ETH via receive() so the bridged value lands here.
contract BridgeReceiver {
    receive() external payable {}
}

abstract contract BridgeActions {
    function _callHash(address l2Destination, address sender) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, l2Destination, 1 ether, "", sender, MAINNET_ROLLUP_ID);
    }

    function _l1Entries(address l2Destination, address sender) internal pure returns (ExecutionEntry[] memory entries) {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-bridge"),
            etherDelta: int256(1 ether)
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            proxyEntryHash: _callHash(l2Destination, sender),
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            callCount: 0,
            returnData: "",
            rollingHash: bytes32(0)
        });
    }

    function _l2Entries(address l2Destination, address sender) internal pure returns (ExecutionEntry[] memory entries) {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: l2Destination,
            value: 1 ether,
            data: "",
            sourceAddress: sender,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        bytes32 rh = bytes32(0);
        rh = RollingHashBuilder.appendCallBegin(rh, 1);
        rh = RollingHashBuilder.appendCallEnd(rh, 1, true, "");

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: _callHash(l2Destination, sender),
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            callCount: 1,
            returnData: "",
            rollingHash: rh
        });
    }
}

/// @title DeployL2 — deploy the real L2 receiver that will accept the bridged ETH.
/// Outputs: L2_DESTINATION
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        BridgeReceiver receiver = new BridgeReceiver();
        console.log("L2_DESTINATION=%s", address(receiver));
        vm.stopBroadcast();
    }
}

/// @title Deploy — on L1, create L2-destination proxy + deploy BridgeSender
/// Env: ROLLUPS, L2_DESTINATION
/// Outputs: L2_PROXY, BRIDGE_SENDER
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address l2DestAddr = vm.envAddress("L2_DESTINATION");

        vm.startBroadcast();
        EEZ rollups = EEZ(rollupsAddr);

        address l2Proxy;
        try rollups.createCrossChainProxy(l2DestAddr, L2_ROLLUP_ID) returns (address p) {
            l2Proxy = p;
        } catch {
            l2Proxy = rollups.computeCrossChainProxyAddress(l2DestAddr, L2_ROLLUP_ID);
        }

        BridgeSender sender = new BridgeSender(l2Proxy, l2DestAddr);
        console.log("L2_PROXY=%s", l2Proxy);
        console.log("BRIDGE_SENDER=%s", address(sender));
        vm.stopBroadcast();
    }
}

/// @notice Batcher: postAndVerifyBatch + bridge() with value in one tx.
contract Batcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        BridgeSender sender
    )
        external
        payable
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        uint256[] memory rids = new uint256[](1);
        rids[0] = L2_ROLLUP_ID;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](psList.length);
        for (uint256 _i = 0; _i < psList.length; _i++) {
            psIdx[_i] = uint64(_i);
        }
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](rids.length);
        for (uint256 _i = 0; _i < rids.length; _i++) {
            rps[_i] = RollupIdWithProofSystems({rollupId: rids[_i], proofSystemIndex: psIdx});
        }

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            blockNumber: 0,
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
        sender.bridge{value: msg.value}();
    }
}

/// @title ExecuteL2 — local mode: system-driven L2 simulation of the bridged ETH.
/// @dev SYSTEM_ADDRESS attaches the same `value` as the L1 entry; managerL2 forwards
///      it through the lazily-created source proxy into BridgeReceiver.receive().
/// Env: MANAGER_L2, L2_DESTINATION, BRIDGE_SENDER
contract ExecuteL2 is Script, BridgeActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address l2DestAddr = vm.envAddress("L2_DESTINATION");
        address senderAddr = vm.envAddress("BRIDGE_SENDER");

        vm.startBroadcast();
        EEZL2(managerAddr)
        .executeIncomingCrossChainCall{
            value: 1 ether
        }(l2DestAddr, 1 ether, "", senderAddr, MAINNET_ROLLUP_ID, _l2Entries(l2DestAddr, senderAddr), noLookupCalls());

        console.log("done");
        console.log("L2 receiver balance=%s", l2DestAddr.balance);
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode
contract Execute is Script, BridgeActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address l2DestAddr = vm.envAddress("L2_DESTINATION");
        address senderAddr = vm.envAddress("BRIDGE_SENDER");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        batcher.execute{
            value: 1 ether
        }(
            EEZ(rollupsAddr),
            proofSystemAddr,
            _l1Entries(l2DestAddr, senderAddr),
            noLookupCalls(),
            BridgeSender(senderAddr)
        );
        console.log("done");
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — network mode: outputs user tx fields
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("BRIDGE_SENDER");
        console.log("TARGET=%s", target);
        console.log("VALUE=1000000000000000000"); // 1 ether
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(BridgeSender.bridge.selector)));
    }
}

contract ComputeExpected is ComputeExpectedBase, BridgeActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("L2_DESTINATION")) return "L2Destination";
        if (a == vm.envAddress("BRIDGE_SENDER")) return "BridgeSender";
        return _shortAddr(a);
    }

    function run() external view {
        address l2DestAddr = vm.envAddress("L2_DESTINATION");
        address senderAddr = vm.envAddress("BRIDGE_SENDER");

        ExecutionEntry[] memory l1 = _l1Entries(l2DestAddr, senderAddr);
        ExecutionEntry[] memory l2 = _l2Entries(l2DestAddr, senderAddr);
        bytes32 l1Hash = _entryHash(l1[0]);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 ETH bridge) ===");
        _logEntry(0, l1[0]);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 ETH receive) ===");
        _logL2Entry(0, l2[0]);
    }
}
