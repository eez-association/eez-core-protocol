// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {RollupUpdate, L2ToL1Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2ExecutionEntry} from "../../../../../src/interfaces/IEEZL2.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    getOrCreateProxy,
    crossChainCallHash,
    crossChainCallHashL2Out,
    noStaticEntries,
    noNestedActions,
    noL2Calls,
    noL2OutgoingCalls,
    noL2StaticEntries,
    immediateSingleRollupBatch,
    RollingHashBuilder,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  BridgeL2 scenario — L2→L1 ETH release, two-sided
//
//  L2 (ExecuteL2): BridgeSenderL2.bridge{value: AMOUNT}() → L1_PROXY → the
//    manager consumes the source entry and burns the ETH (sent to SYSTEM).
//  L1 (Execute): one immediate zero-hash L2Tx entry — the source proxy pays
//    BridgeReceiverL1 AMOUNT; etherDelta = -AMOUNT releases the escrow.
//
//  A release needs PRIOR escrow (ether in the registry + rollup 1's
//  `etherBalance` credit — `InsufficientRollupBalance` otherwise). Local mode
//  sets both on the anvil node (see _fundEscrow); network mode fires only the
//  L2 trigger, so the devnet must already hold escrow — a full sequential run
//  does (`bridge` deposits the same 0.001 ether and sorts first).
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;
// Kept small on purpose — the scenario is meant to run on real testnets too.
uint256 constant BRIDGE_AMOUNT = 0.001 ether;

contract BridgeSenderL2 {
    address public immutable L1_PROXY;

    constructor(address l1Proxy) {
        L1_PROXY = l1Proxy;
    }

    function bridge() external payable {
        (bool ok,) = L1_PROXY.call{value: msg.value}("");
        require(ok, "bridge failed");
    }
}

contract BridgeReceiverL1 {
    receive() external payable {}
}

abstract contract BridgeL2Actions {
    /// Identity of the release call as executed ON L1.
    function _l1CallHash(address receiverL1, address senderL2) internal pure returns (bytes32) {
        return crossChainCallHash(false, senderL2, L2_ROLLUP_ID, receiverL1, MAINNET_ROLLUP_ID, BRIDGE_AMOUNT, "");
    }

    /// L2-outgoing key the source L2 matches the bridge call with.
    function _l2EntryKey(address receiverL1, address senderL2) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(senderL2, L2_ROLLUP_ID, receiverL1, MAINNET_ROLLUP_ID, BRIDGE_AMOUNT, "");
    }

    /// The SOURCE entry alice's bridge call consumes on L2 (no incoming calls).
    function _l2Entries(address receiverL1, address senderL2)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 proxyEntryHash = _l2EntryKey(receiverL1, senderL2);
        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: proxyEntryHash,
            incomingCalls: noL2Calls(),
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: RollingHashBuilder.entryBeginL2(proxyEntryHash),
            success: true,
            returnData: ""
        });
    }

    /// The L2 user tx as ONE immediate zero-hash L2Tx entry releasing the escrow on L1.
    function _l1Entries(address receiverL1, address senderL2) internal pure returns (ExecutionEntry[] memory entries) {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: senderL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: receiverL1,
            value: BRIDGE_AMOUNT,
            data: ""
        });

        RollupUpdate[] memory deltas = new RollupUpdate[](1);
        deltas[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-bridge-l2"),
            etherDelta: -int192(int256(BRIDGE_AMOUNT))
        });

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, _l1CallHash(receiverL1, senderL2));
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltas,
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title Deploy — on L1, deploy the receiver of the released ether.
/// Outputs: BRIDGE_RECEIVER_L1
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        BridgeReceiverL1 receiver = new BridgeReceiverL1();
        output("BRIDGE_RECEIVER_L1", address(receiver));
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — on L2, create the receiver's proxy + the sender targeting it.
/// Env: MANAGER_L2, BRIDGE_RECEIVER_L1
/// Outputs: L1_PROXY_L2, BRIDGE_SENDER_L2
contract DeployL2 is Script {
    function run() external {
        address receiverL1 = vm.envAddress("BRIDGE_RECEIVER_L1");
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("MANAGER_L2")), receiverL1, MAINNET_ROLLUP_ID);
        BridgeSenderL2 sender = new BridgeSenderL2(proxy);
        output("L1_PROXY_L2", proxy);
        output("BRIDGE_SENDER_L2", address(sender));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — local mode: loadExecutionTable + alice's bridge trigger, one block.
/// Env: MANAGER_L2, BRIDGE_RECEIVER_L1, BRIDGE_SENDER_L2
contract ExecuteL2 is Script, BridgeL2Actions {
    function run() external {
        address receiverL1 = vm.envAddress("BRIDGE_RECEIVER_L1");
        address senderL2 = vm.envAddress("BRIDGE_SENDER_L2");
        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2")).loadExecutionTable(_l2Entries(receiverL1, senderL2), noL2StaticEntries());
        BridgeSenderL2(senderL2).bridge{value: BRIDGE_AMOUNT}();
        console.log("done");
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode: fund the escrow on the anvil node, then post the batch whose
///        immediate L2Tx entry releases it to the receiver.
/// Env: ROLLUPS, PROOF_SYSTEM, BRIDGE_RECEIVER_L1, BRIDGE_SENDER_L2
contract Execute is Script, BridgeL2Actions {
    // Slot of the `rollups` mapping in EEZ; etherBalance is the third word of RollupConfig.
    uint256 internal constant ROLLUPS_MAPPING_SLOT = 2;

    function run() external {
        address receiverL1 = vm.envAddress("BRIDGE_RECEIVER_L1");
        address senderL2 = vm.envAddress("BRIDGE_SENDER_L2");
        EEZ rollups = EEZ(vm.envAddress("ROLLUPS"));
        uint256 receiverBefore = receiverL1.balance;

        _fundEscrow(rollups);

        vm.startBroadcast();
        rollups.postAndVerifyBatch(
            immediateSingleRollupBatch(
                vm.envAddress("PROOF_SYSTEM"), L2_ROLLUP_ID, _l1Entries(receiverL1, senderL2), noStaticEntries()
            )
        );

        require(receiverL1.balance == receiverBefore + BRIDGE_AMOUNT, "receiver did not get the bridged ether");
        console.log("done");
        vm.stopBroadcast();
    }

    /// LOCAL-ONLY escrow cheat (Execute never runs in network mode): vm.rpc admin calls set the
    /// registry's ether + rollup 1's escrow credit on the node itself — nothing is broadcast.
    /// Self-checked through the public getter, so a storage-layout move fails loudly.
    function _fundEscrow(EEZ rollups) private {
        string memory registry = vm.toString(address(rollups));
        string memory amount = vm.toString(bytes32(BRIDGE_AMOUNT));
        vm.rpc("anvil_setBalance", string.concat('["', registry, '","', amount, '"]'));

        bytes32 escrowSlot = bytes32(uint256(keccak256(abi.encode(uint256(L2_ROLLUP_ID), ROLLUPS_MAPPING_SLOT))) + 2);
        vm.rpc("anvil_setStorageAt", string.concat('["', registry, '","', vm.toString(escrowSlot), '","', amount, '"]'));

        (,, uint256 escrow) = rollups.rollups(L2_ROLLUP_ID);
        require(escrow == BRIDGE_AMOUNT, "escrow cheat missed - EEZ storage layout moved?");
        require(address(rollups).balance == BRIDGE_AMOUNT, "balance cheat did not reach the node");
    }
}

/// @title ExecuteNetworkL2 — network mode: user tx fields for the L2 bridge trigger.
/// @dev PRECONDITION: rollup 1 must already hold escrow >= BRIDGE_AMOUNT on the devnet
///      (ether in the registry + `rollups(1).etherBalance`) — run `one_way/L1_to_L2/bridge`
///      first if unsure; a full sequential run satisfies it automatically.
/// Env: BRIDGE_SENDER_L2
contract ExecuteNetworkL2 is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("BRIDGE_SENDER_L2"));
        console.log("VALUE=%s", vm.toString(BRIDGE_AMOUNT));
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(BridgeSenderL2.bridge.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, BridgeL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("BRIDGE_RECEIVER_L1")) return "BridgeReceiverL1";
        if (a == vm.envAddress("BRIDGE_SENDER_L2")) return "BridgeSenderL2";
        return _shortAddr(a);
    }

    function run() external view {
        address receiverL1 = vm.envAddress("BRIDGE_RECEIVER_L1");
        address senderL2 = vm.envAddress("BRIDGE_SENDER_L2");
        L2ExecutionEntry[] memory l2 = _l2Entries(receiverL1, senderL2);
        ExecutionEntry[] memory l1 = _l1Entries(receiverL1, senderL2);

        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2[0].proxyEntryHash));
        // Steps before the table on purpose — see the via-ir gotcha in BUILD_AND_REVIEW_E2E_TESTS.md.
        HashStep[][] memory steps = new HashStep[][](1);
        steps[0] = new HashStep[](2);
        steps[0][0] = RollingHashBuilder.stepCallBegin(_l1CallHash(receiverL1, senderL2));
        steps[0][1] = RollingHashBuilder.stepCallEnd(true, "");
        _printL1Steps(l1, steps);
        _printL1Table(l1);
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(0, l2[0]);
        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry, ETH release) ===");
        _logEntry(0, l1[0]);
    }
}
