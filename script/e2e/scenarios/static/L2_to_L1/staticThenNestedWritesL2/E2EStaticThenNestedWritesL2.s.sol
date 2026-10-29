// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {e2eRollupId} from "../../../shared/E2EHelpers.sol";

// E2E_EXCLUDE_FROM_ALL: Explicit selection only pending live validation.

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../../src/L2/EEZL2.sol";
import {
    IEEZ,
    RollupUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry,
    StaticExecutionEntry,
    ProofSystemBatchPerVerificationEntries
} from "../../../../../../src/interfaces/IEEZ.sol";
import {
    CrossChainCall,
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntryL2
} from "../../../../../../src/interfaces/IEEZL2.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    getOrCreateProxy,
    immediateSingleRollupBatch,
    crossChainCallHash,
    expectedL1toL2Hash,
    RollingHashBuilder,
    HashStep,
    noCalls,
    noL2Calls,
    noL2OutgoingCalls,
    noStaticEntries
} from "../../../shared/E2EHelpers.sol";

// One L2 trigger: source.run()
//   L2 -> STATIC L1 read() = 0 -> return (frame closed)
//   L2 -> CALL L1 writeAfterCallback()
//     L1 -> CALL L2 writeCallback(): write 1 -> return 1
//     L1: write 2 -> return 2
//   L2: write 3 -> return 3
// L1 view: ONE zero-hash L2Tx entry [static read, mutable call with nested callback].
// L2 view: ONE source entry executes the callback; static row pins cursor 0.
// No separate callback delivery. Final: L2 source=3, L1 destination=2.

/// @dev Scenario-local fixture: L2 triggers run(); the other chain executes writeAfterCallback.
contract StaticThenNestedWritesActorL2 {
    StaticThenNestedWritesActorL2 public peer;
    uint256 public value;
    uint256 public phase;
    uint256 public firstRead;
    uint256 public callbackResult;
    uint256 public remoteResult;
    uint256 public runs;
    uint256 public callbackWrites;
    uint256 public remoteWrites;

    function configure(address proxy) external {
        require(address(peer) == address(0), "already configured");
        peer = StaticThenNestedWritesActorL2(proxy);
    }

    function read() external view returns (uint256) {
        return value;
    }

    function run() external returns (uint256) {
        require(phase == 0 && value == 0 && runs == 0, "fresh source required");
        uint256 observed = peer.read(); // This STATICCALL finishes before any mutable call.
        require(observed == 0, "wrong initial static result");
        firstRead = observed;
        phase = 1;
        uint256 returned = peer.writeAfterCallback();
        require(returned == 2, "wrong remote return");
        require(phase == 2 && value == 1 && callbackWrites == 1, "callback must write first");
        remoteResult = returned;
        value = returned + 1; // Third write, after the remote frame returns.
        phase = 3;
        runs++;
        return value;
    }

    function writeAfterCallback() external returns (uint256) {
        require(phase == 0 && value == 0 && remoteWrites == 0, "fresh destination required");
        uint256 returned = peer.writeCallback();
        require(returned == 1 && value == 0, "callback must return before remote write");
        callbackResult = returned;
        value = returned + 1; // Second write.
        remoteWrites++;
        return value;
    }

    function writeCallback() external returns (uint256) {
        require(phase == 1 && value == 0 && callbackWrites == 0, "callback out of order");
        value = 1; // First write, inside the nested callback.
        callbackWrites++;
        phase = 2;
        return value;
    }

    function assertSource() external view {
        require(firstRead == 0 && remoteResult == 2, "source observations");
        require(value == 3 && phase == 3 && runs == 1, "source final state");
        require(callbackWrites == 1 && remoteWrites == 0 && callbackResult == 0, "source write counts");
    }

    function assertDestination() external view {
        require(value == 2 && callbackResult == 1 && remoteWrites == 1, "destination final state");
        require(phase == 0 && runs == 0 && callbackWrites == 0, "extra destination execution");
    }
}

/// @dev Both chain views of this L2-originating flow use the same call identities.
abstract contract StaticThenNestedWritesL2Actions is Script {
    struct Tables {
        ExecutionEntry[] l1;
        L2ExecutionEntry[] l2;
        StaticExecutionEntry[] l1Static;
        StaticExecutionEntryL2[] l2Static;
        HashStep[][] steps;
    }

    function _readData() internal pure returns (bytes memory) {
        return abi.encodeCall(StaticThenNestedWritesActorL2.read, ());
    }

    function _remoteData() internal pure returns (bytes memory) {
        return abi.encodeCall(StaticThenNestedWritesActorL2.writeAfterCallback, ());
    }

    function _callbackData() internal pure returns (bytes memory) {
        return abi.encodeCall(StaticThenNestedWritesActorL2.writeCallback, ());
    }

    function _readHash(address actorL1, address actorL2) internal view returns (bytes32) {
        return crossChainCallHash(true, actorL2, e2eRollupId(), actorL1, 0, 0, _readData());
    }

    function _remoteHash(address actorL1, address actorL2) internal view returns (bytes32) {
        return crossChainCallHash(false, actorL2, e2eRollupId(), actorL1, 0, 0, _remoteData());
    }

    function _callbackHash(address actorL1, address actorL2) internal view returns (bytes32) {
        return crossChainCallHash(false, actorL1, 0, actorL2, e2eRollupId(), 0, _callbackData());
    }

    function _updates() internal view returns (RollupUpdate[] memory updates) {
        updates = new RollupUpdate[](1);
        updates[0] = RollupUpdate({
            rollupId: e2eRollupId(),
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("static-then-nested-writes-final"),
            etherDelta: 0
        });
    }

    function _l1Steps(address actorL1, address actorL2) internal view returns (HashStep[][] memory steps) {
        steps = new HashStep[][](1);
        // The read closes before the mutable call opens its callback frame.
        steps[0] = new HashStep[](6);
        steps[0][0] = RollingHashBuilder.stepCallBegin(_readHash(actorL1, actorL2));
        steps[0][1] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(0)));
        steps[0][2] = RollingHashBuilder.stepCallBegin(_remoteHash(actorL1, actorL2));
        steps[0][3] = RollingHashBuilder.stepNestedBegin(_callbackHash(actorL1, actorL2));
        steps[0][4] = RollingHashBuilder.stepNestedEnd();
        steps[0][5] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(2)));
    }

    function _l1Entries(address actorL1, address actorL2) internal view returns (ExecutionEntry[] memory entries) {
        RollupUpdate[] memory updates = _updates();
        // ONE L2 user transaction becomes ONE zero-hash entry on L1.
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: actorL2,
            sourceRollupId: e2eRollupId(),
            targetAddress: actorL1,
            value: 0,
            data: _readData()
        });
        calls[1] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: actorL2,
            sourceRollupId: e2eRollupId(),
            targetAddress: actorL1,
            value: 0,
            data: _remoteData()
        });

        bytes32 seed = RollingHashBuilder.entryBegin(updates, bytes32(0));
        bytes32 rh = RollingHashBuilder.appendCallBegin(seed, _readHash(actorL1, actorL2));
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(0)));
        rh = RollingHashBuilder.appendCallBegin(rh, _remoteHash(actorL1, actorL2));
        bytes32 rhFire = rh; // writeAfterCallback calls back before writing its own value.
        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(_callbackHash(actorL1, actorL2), rhFire),
            l2ToL1Calls: noCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: updates,
            proxyEntryHash: bytes32(0),
            destinationRollupId: e2eRollupId(),
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            rollingHash: RollingHashBuilder.foldSteps(seed, _l1Steps(actorL1, actorL2)[0]),
            success: true,
            returnData: "" // Canonical L2Tx entry; the call's result is folded above.
        });
    }

    function _l2Entries(address actorL1, address actorL2) internal view returns (L2ExecutionEntry[] memory entries) {
        bytes32 key = _remoteHash(actorL1, actorL2);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        // The callback executes inside the original source entry; no new delivery.
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: actorL1,
            sourceRollupId: 0,
            targetAddress: actorL2,
            value: 0,
            data: _callbackData()
        });
        bytes32 rh = RollingHashBuilder.entryBeginL2(key);
        rh = RollingHashBuilder.appendCallBegin(rh, _callbackHash(actorL1, actorL2));
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));
        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: key,
            incomingCalls: calls,
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(2))
        });
    }

    function _l2Statics(
        address actorL1,
        address actorL2
    )
        internal
        view
        returns (StaticExecutionEntryL2[] memory entries)
    {
        entries = new StaticExecutionEntryL2[](1);
        entries[0] = StaticExecutionEntryL2({
            expectedEntryIndex: 0, // Read completes before the one mutable consumption.
            proxyEntryHash: _readHash(actorL1, actorL2),
            incomingCalls: noL2Calls(),
            rollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(0)) // Real producer: L1 calls[0].
        });
    }

    function _expected() internal view returns (Tables memory t) {
        address actorL1 = vm.envAddress("ACTOR_L1");
        address actorL2 = vm.envAddress("ACTOR_L2");
        t.l1 = _l1Entries(actorL1, actorL2);
        t.l2 = _l2Entries(actorL1, actorL2);
        t.l1Static = noStaticEntries();
        t.l2Static = _l2Statics(actorL1, actorL2);
        t.steps = _l1Steps(actorL1, actorL2);
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        output("ACTOR_L1", address(new StaticThenNestedWritesActorL2()));
        vm.stopBroadcast();
    }
}

contract DeployL2 is Script {
    function run() external {
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        require(!manager.USE_GAS_LEFT(), "scenario requires gas-independent keys");
        vm.startBroadcast();
        StaticThenNestedWritesActorL2 actor = new StaticThenNestedWritesActorL2();
        actor.configure(getOrCreateProxy(IEEZ(address(manager)), vm.envAddress("ACTOR_L1"), 0));
        output("ACTOR_L2", address(actor));
        vm.stopBroadcast();
    }
}

contract DeployConfigure is Script {
    function run() external {
        vm.startBroadcast();
        StaticThenNestedWritesActorL2(vm.envAddress("ACTOR_L1"))
            .configure(getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), vm.envAddress("ACTOR_L2"), e2eRollupId()));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is StaticThenNestedWritesL2Actions {
    function run() external {
        Tables memory t = _expected();
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        StaticThenNestedWritesActorL2 actor = StaticThenNestedWritesActorL2(vm.envAddress("ACTOR_L2"));
        vm.startBroadcast();
        manager.loadExecutionTable(t.l2, t.l2Static);
        require(actor.run() == 3, "source return bytes");
        actor.assertSource();
        require(manager.entryIndex() == 1, "expected one mutable consumption");
        vm.stopBroadcast();
        console.log("done: L2 state, exact results and consumption checked");
    }
}

contract Execute is StaticThenNestedWritesL2Actions {
    function run() external {
        Tables memory t = _expected();
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        StaticThenNestedWritesActorL2 actor = StaticThenNestedWritesActorL2(vm.envAddress("ACTOR_L1"));
        (,, uint256 balance) = manager.rollups(e2eRollupId());
        ProofSystemBatchPerVerificationEntries memory batch =
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), e2eRollupId(), t.l1, t.l1Static);
        batch.callData = vm.envBytes("RLP_ENCODED_TX");
        vm.startBroadcast();
        manager.postAndVerifyBatch(batch);
        actor.assertDestination();
        vm.stopBroadcast();
        (, bytes32 root, uint256 afterBalance) = manager.rollups(e2eRollupId());
        require(root == t.l1[0].rollupUpdates[0].newRoot, "wrong final root");
        require(balance == afterBalance, "unexpected ether delta");
        console.log("done: L1 state, exact results and root checked");
    }
}

contract ExecuteNetworkL2 is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("ACTOR_L2"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(StaticThenNestedWritesActorL2.run, ())));
    }
}

contract VerifyNetwork is Script {
    function run() external view {
        StaticThenNestedWritesActorL2(vm.envAddress("ACTOR_L1")).assertDestination();
        console.log("VERIFY_PASS L1 persisted writes and results");
    }
}

contract VerifyNetworkL2 is Script {
    function run() external view {
        StaticThenNestedWritesActorL2(vm.envAddress("ACTOR_L2")).assertSource();
        console.log("VERIFY_PASS L2 persisted writes and results");
    }
}

contract ComputeExpected is ComputeExpectedBase, StaticThenNestedWritesL2Actions {
    function run() external view {
        Tables memory t = _expected();
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(t.l1[0])));
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _logEntry(0, t.l1[0]);
        _printL1StaticTable(t.l1Static);
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(t.l2[0])));
        _printL2CallHashes(t.l2);
        _printL2Table(t.l2);
        _logL2Entry(0, t.l2[0]);
        _printL2StaticTable(t.l2Static);
        _logStaticLookup(0, t.l2Static[0]);
        console.log("EVENTLESS_L2_HASHES=[]");
    }
}
