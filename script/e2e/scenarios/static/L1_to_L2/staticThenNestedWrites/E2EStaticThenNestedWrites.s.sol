// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// E2E_EXCLUDE_FROM_ALL: Explicit selection only pending live validation.

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../../src/L2/EEZL2.sol";
import {
    IEEZ,
    RollupUpdate,
    L2ToL1Call,
    ExecutionEntry,
    StaticExecutionEntry,
    ExpectedRootPerRollup,
    ProofSystemBatchPerVerificationEntries
} from "../../../../../../src/interfaces/IEEZ.sol";
import {
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
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
    noNestedActions,
    noL2Calls,
    noL2StaticEntries
} from "../../../shared/E2EHelpers.sol";

// One L1 trigger: source.run()
//   L1 -> STATIC L2 read() = 0 -> return (frame closed)
//   L1 -> CALL L2 writeAfterCallback()
//     L2 -> CALL L1 writeCallback(): write 1 -> return 1
//     L2: write 2 -> return 2
//   L1: write 3 -> return 3
// L1 view: one root-pinned static lookup, then ONE mutable entry executing the callback.
// L2 view: ONE delivery executes the remote call with a nested outgoing callback row.
// No static-read delivery. Final: L1 source=3, L2 destination=2.

/// @dev Scenario-local fixture: L1 triggers run(); the other chain executes writeAfterCallback.
contract StaticThenNestedWritesActor {
    StaticThenNestedWritesActor public peer;
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
        peer = StaticThenNestedWritesActor(proxy);
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

/// @dev Both chain views of this L1-originating flow use the same call identities.
abstract contract StaticThenNestedWritesActions is Script {
    uint64 internal constant L2_ID = 1;

    struct Tables {
        ExecutionEntry[] l1;
        L2ExecutionEntry[] l2;
        StaticExecutionEntry[] l1Static;
        StaticExecutionEntryL2[] l2Static;
        HashStep[][] steps;
    }

    function _readData() internal pure returns (bytes memory) {
        return abi.encodeCall(StaticThenNestedWritesActor.read, ());
    }

    function _remoteData() internal pure returns (bytes memory) {
        return abi.encodeCall(StaticThenNestedWritesActor.writeAfterCallback, ());
    }

    function _callbackData() internal pure returns (bytes memory) {
        return abi.encodeCall(StaticThenNestedWritesActor.writeCallback, ());
    }

    function _readHash(address actorL1, address actorL2) internal pure returns (bytes32) {
        return crossChainCallHash(true, actorL1, 0, actorL2, L2_ID, 0, _readData());
    }

    function _remoteHash(address actorL1, address actorL2) internal pure returns (bytes32) {
        return crossChainCallHash(false, actorL1, 0, actorL2, L2_ID, 0, _remoteData());
    }

    function _callbackHash(address actorL1, address actorL2) internal pure returns (bytes32) {
        return crossChainCallHash(false, actorL2, L2_ID, actorL1, 0, 0, _callbackData());
    }

    function _updates() internal pure returns (RollupUpdate[] memory updates) {
        updates = new RollupUpdate[](1);
        updates[0] = RollupUpdate({
            rollupId: L2_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("static-then-nested-writes-final"),
            etherDelta: 0
        });
    }

    function _l1Steps(address actorL1, address actorL2) internal pure returns (HashStep[][] memory steps) {
        steps = new HashStep[][](1);
        // L1 executes only the callback inside the mutable source entry.
        steps[0] = new HashStep[](2);
        steps[0][0] = RollingHashBuilder.stepCallBegin(_callbackHash(actorL1, actorL2));
        steps[0][1] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(1)));
    }

    function _l1Entries(address actorL1, address actorL2) internal pure returns (ExecutionEntry[] memory entries) {
        RollupUpdate[] memory updates = _updates();
        bytes32 key = _remoteHash(actorL1, actorL2);
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: actorL2,
            sourceRollupId: L2_ID,
            targetAddress: actorL1,
            value: 0,
            data: _callbackData()
        });
        bytes32 seed = RollingHashBuilder.entryBegin(updates, key);
        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: updates,
            proxyEntryHash: key,
            destinationRollupId: L2_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.foldSteps(seed, _l1Steps(actorL1, actorL2)[0]),
            success: true,
            returnData: abi.encode(uint256(2)) // Produced by the real L2 writeAfterCallback.
        });
    }

    function _l2Entries(address actorL1, address actorL2) internal pure returns (L2ExecutionEntry[] memory entries) {
        bytes32 key = _remoteHash(actorL1, actorL2);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        // Only the mutable remote frame is delivered; the static read is a lookup.
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: actorL1,
            sourceRollupId: 0,
            targetAddress: actorL2,
            value: 0,
            data: _remoteData()
        });
        bytes32 rh = RollingHashBuilder.entryBeginL2(key);
        rh = RollingHashBuilder.appendCallBegin(rh, key);
        bytes32 rhFire = rh;
        bytes32 callbackHash = _callbackHash(actorL1, actorL2);
        rh = RollingHashBuilder.appendNestedBegin(rh, callbackHash);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(2)));

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(callbackHash, rhFire),
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1)) // Produced by the real L1 writeCallback.
        });
        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: key,
            incomingCalls: calls,
            expectedOutgoingCalls: nested,
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(2))
        });
    }

    function _l1Statics(
        address actorL1,
        address actorL2,
        bytes memory predictedRead
    )
        internal
        pure
        returns (StaticExecutionEntry[] memory entries)
    {
        require(keccak256(predictedRead) == keccak256(abi.encode(uint256(0))), "initial producer result");
        ExpectedRootPerRollup[] memory roots = new ExpectedRootPerRollup[](1);
        roots[0] = ExpectedRootPerRollup({rollupId: L2_ID, root: _updates()[0].currentRoot});
        entries = new StaticExecutionEntry[](1);
        entries[0] = StaticExecutionEntry({
            expectedRoots: roots,
            proxyEntryHash: _readHash(actorL1, actorL2),
            l2ToL1Calls: noCalls(),
            rollingHash: bytes32(0),
            destinationRollupId: L2_ID,
            success: true,
            returnData: predictedRead // Raw bytes from the actual L2 producer during deployment.
        });
    }

    function _expected() internal view returns (Tables memory t) {
        address actorL1 = vm.envAddress("ACTOR_L1");
        address actorL2 = vm.envAddress("ACTOR_L2");
        t.l1 = _l1Entries(actorL1, actorL2);
        t.l2 = _l2Entries(actorL1, actorL2);
        t.l1Static = _l1Statics(actorL1, actorL2, vm.envBytes("PREDICTED_STATIC_RESULT"));
        t.l2Static = noL2StaticEntries();
        t.steps = _l1Steps(actorL1, actorL2);
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        output("ACTOR_L1", address(new StaticThenNestedWritesActor()));
        vm.stopBroadcast();
    }
}

contract DeployL2 is Script {
    function run() external {
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        require(!manager.USE_GAS_LEFT(), "scenario requires gas-independent keys");
        vm.startBroadcast();
        StaticThenNestedWritesActor actor = new StaticThenNestedWritesActor();
        actor.configure(getOrCreateProxy(IEEZ(address(manager)), vm.envAddress("ACTOR_L1"), 0));
        output("ACTOR_L2", address(actor));
        (bool ok, bytes memory result) = address(actor).staticcall(abi.encodeCall(StaticThenNestedWritesActor.read, ()));
        require(ok, "producer prediction failed");
        output("PREDICTED_STATIC_RESULT", result);
        vm.stopBroadcast();
    }
}

contract DeployConfigure is Script {
    function run() external {
        vm.startBroadcast();
        StaticThenNestedWritesActor(vm.envAddress("ACTOR_L1"))
            .configure(getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), vm.envAddress("ACTOR_L2"), 1));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is StaticThenNestedWritesActions {
    function run() external {
        Tables memory t = _expected();
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        StaticThenNestedWritesActor actor = StaticThenNestedWritesActor(vm.envAddress("ACTOR_L2"));
        vm.startBroadcast();
        require(actor.read() == 0, "initial producer changed");
        manager.executeIncomingCrossChainCall(t.l2, t.l2Static);
        actor.assertDestination();
        require(manager.entryIndex() == 1, "expected one mutable consumption");
        vm.stopBroadcast();
        console.log("done: L2 state, exact results and consumption checked");
    }
}

contract Execute is StaticThenNestedWritesActions {
    function run() external {
        Tables memory t = _expected();
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        StaticThenNestedWritesActor actor = StaticThenNestedWritesActor(vm.envAddress("ACTOR_L1"));
        (,, uint256 balance) = manager.rollups(1);
        ProofSystemBatchPerVerificationEntries memory batch =
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), 1, t.l1, t.l1Static);
        vm.startBroadcast();
        manager.postAndVerifyBatch(batch);
        require(actor.run() == 3, "source return bytes");
        actor.assertSource();
        vm.stopBroadcast();
        (, bytes32 root, uint256 afterBalance) = manager.rollups(1);
        require(root == t.l1[0].rollupUpdates[0].newRoot, "wrong final root");
        require(balance == afterBalance, "unexpected ether delta");
        console.log("done: L1 state, exact results and root checked");
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("ACTOR_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(StaticThenNestedWritesActor.run, ())));
    }
}

contract VerifyNetwork is Script {
    function run() external view {
        StaticThenNestedWritesActor(vm.envAddress("ACTOR_L1")).assertSource();
        console.log("VERIFY_PASS L1 persisted writes and results");
    }
}

contract VerifyNetworkL2 is Script {
    function run() external view {
        StaticThenNestedWritesActor(vm.envAddress("ACTOR_L2")).assertDestination();
        console.log("VERIFY_PASS L2 persisted writes and results");
    }
}

contract ComputeExpected is ComputeExpectedBase, StaticThenNestedWritesActions {
    function run() external view {
        Tables memory t = _expected();
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(t.l1[0])));
        _printL1CallHashes(t.l1);
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _logEntry(0, t.l1[0]);
        _printL1StaticTable(t.l1Static);
        _logStaticLookup(0, t.l1Static[0]);
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(t.l2[0])));
        _printL2CallHashes(t.l2);
        _printL2Table(t.l2);
        _logL2Entry(0, t.l2[0]);
        _printL2StaticTable(t.l2Static);
        console.log("EVENTLESS_L2_HASHES=[]");
        console.log("ABSENT_L2_HASHES=[%s]", vm.toString(t.l1Static[0].proxyEntryHash));
    }
}
