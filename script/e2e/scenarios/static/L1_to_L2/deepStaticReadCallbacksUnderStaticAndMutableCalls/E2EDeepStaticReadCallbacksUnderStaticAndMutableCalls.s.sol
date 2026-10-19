// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// E2E_EXCLUDE_FROM_ALL: PR #54 call-pattern scenarios; explicit selection only pending live validation.

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../../src/L2/EEZL2.sol";
import {
    IEEZ,
    ExecutionEntry,
    RollupUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    StaticExecutionEntry,
    ExpectedRootPerRollup
} from "../../../../../../src/interfaces/IEEZ.sol";
import {
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    ExecutionEntry as L2Entry,
    StaticExecutionEntryL2 as L2Static
} from "../../../../../../src/interfaces/IEEZL2.sol";
import {CallPatternActor as Actor} from "../../../../../../test/mocks/CallPatternContracts.sol";
import {CallPatternHelpers} from "../../../shared/CallPatternHelpers.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    getOrCreateProxy,
    immediateSingleRollupBatch,
    noL2StaticEntries,
    RollingHashBuilder as RH,
    HashStep,
    expectedL1toL2Hash
} from "../../../shared/E2EHelpers.sol";

// The user starts on L1. Each chain's value starts at 0.
//
// First request -- reads only; answers return from the innermost call outward:
// L1 -> L2: read (returns 3)
//   L2 -> L1: read (returns 2)
//     L1 -> L2: read (returns 1)
//       L2 -> L1: read the stored value (returns 0)
// Result: the user receives 3. Neither stored value changes.
//
// Second request -- an operation that reads before changing its own value:
// L1 -> L2: start the operation
//   L2 -> L1: read (returns 2)
//     L1 -> L2: read (returns 1)
//       L2 -> L1: read the stored value (returns 0)
// L2: the reads finished; add 1 locally and return the answer 2
//
// Final result: the user recorded 3 and 2; L1 = 0, L2 = 1.
// Every call beneath a read must remain read-only.
// Included in default/all runs; live composer failures remain failures.

abstract contract DeepStaticReadCallbacksUnderStaticAndMutableCallsActions is CallPatternHelpers {
    struct ScenarioTables {
        ExecutionEntry[] l1;
        L2Entry[] l2;
        StaticExecutionEntry[] statics;
        HashStep[][] steps;
    }

    function _tables(address a1, address a2) internal pure returns (ScenarioTables memory t) {
        t.l1 = new ExecutionEntry[](1);
        t.l2 = new L2Entry[](1);
        t.steps = new HashStep[][](1);
        t.statics = new StaticExecutionEntry[](2);
        ExpectedRootPerRollup[] memory pins = new ExpectedRootPerRollup[](1);
        pins[0] = ExpectedRootPerRollup(1, keccak256("l2-initial-state"));

        // Top-level read(3) -> callback read(2) -> read(1) -> callback read(0).
        // Static callbacks do not open a mutable execution context on L1:
        // read(1) must resolve from a SECOND top-level pool entry.
        t.statics[0] = StaticExecutionEntry(
            pins,
            _l1ToL2CallHash(a1, a2, _read(3), true),
            _l1Callback(a1, a2, _read(2), true),
            RH.appendStatic(0, true, _result(2)),
            1,
            true,
            _result(3)
        );
        t.statics[1] = StaticExecutionEntry(
            pins,
            _l1ToL2CallHash(a1, a2, _read(1), true),
            _l1Callback(a1, a2, _read(0), true),
            RH.appendStatic(0, true, _result(0)),
            1,
            true,
            _result(1)
        );

        // Mutable outer context: L2 readUnderMutable -> L1 read(2) ->
        // L2 read(1) -> L1 read(0). read(1) now belongs to a nested STATIC row.
        ExecutionEntry memory source;
        source.rollupUpdates = new RollupUpdate[](1);
        source.rollupUpdates[0] = RollupUpdate(1, 0, pins[0].root, keccak256("l2-after-deep-reads"));
        source.proxyEntryHash = _l1ToL2CallHash(a1, a2, _under(), false);
        source.destinationRollupId = 1;
        source.l2ToL1Calls = _l1Callback(a1, a2, _read(2), true);
        bytes32 fire = RH.appendCallBegin(
            RH.entryBegin(source.rollupUpdates, source.proxyEntryHash), _l2ToL1CallHash(a1, a2, _read(2), true)
        );
        source.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](1);
        source.expectedL1ToL2Calls[0] = ExpectedL1ToL2Call(
            expectedL1toL2Hash(_l1ToL2CallHash(a1, a2, _read(1), true), fire),
            _l1Callback(a1, a2, _read(0), true),
            RH.appendStatic(0, true, _result(0)),
            true,
            _result(1)
        );
        source.rollingHash = RH.appendCallEnd(fire, true, _result(2));
        source.success = true;
        source.returnData = _result(2);
        t.l1[0] = source;
        t.steps[0] = new HashStep[](2);
        t.steps[0][0] = RH.stepCallBegin(_l2ToL1CallHash(a1, a2, _read(2), true));
        t.steps[0][1] = RH.stepCallEnd(true, _result(2));

        L2Entry memory delivery;
        delivery.proxyEntryHash = source.proxyEntryHash;
        delivery.incomingCalls = _l2Callback(a1, a2, _under(), false);
        fire = RH.appendCallBegin(RH.entryBeginL2(delivery.proxyEntryHash), delivery.proxyEntryHash);
        delivery.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](2);
        delivery.expectedOutgoingCalls[0] = ExpectedOutgoingCrossChainCall(
            expectedL1toL2Hash(_l2ToL1CallHash(a1, a2, _read(2), true), fire),
            _l2Callback(a1, a2, _read(1), true),
            RH.appendStatic(0, true, _result(1)),
            true,
            _result(2)
        );
        // Both nested reads fire at the same unchanged hash in static context.
        delivery.expectedOutgoingCalls[1] = ExpectedOutgoingCrossChainCall(
            expectedL1toL2Hash(_l2ToL1CallHash(a1, a2, _read(0), true), fire),
            new CrossChainCall[](0),
            0,
            true,
            _result(0)
        );
        delivery.rollingHash = RH.appendCallEnd(fire, true, _result(2));
        delivery.success = true;
        delivery.returnData = _result(2);
        t.l2[0] = delivery;
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1 && source.total() == 0, "source read-only callbacks");
        require(source.firstRead() == 3 && source.lastRead() == 2, "deep read results");
    }

    function _checkDestination(Actor destination) internal view {
        require(destination.total() == 1 && destination.completed() == 0, "one mutable delivery");
        require(destination.lastRead() == 2, "real L2 nested read result");
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        output("ACTOR_L1", address(new Actor()));
        vm.stopBroadcast();
    }
}

contract DeployL2 is Script, DeepStaticReadCallbacksUnderStaticAndMutableCallsActions {
    function run() external {
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        require(!manager.USE_GAS_LEFT(), "scenario requires gas-independent keys");
        vm.startBroadcast();
        Actor actor = new Actor();
        actor.configure(getOrCreateProxy(IEEZ(address(manager)), vm.envAddress("ACTOR_L1"), 0));
        output("ACTOR_L2", address(actor));
        vm.stopBroadcast();

        // Prediction only, like topLevelStaticReentrantCounter: these tables
        // are never broadcast and create no additional remote execution.
        uint256 snapshot = vm.snapshotState();
        L2Static[] memory prediction = new L2Static[](2);
        address a1 = vm.envAddress("ACTOR_L1");
        address a2 = address(actor);
        prediction[0] = _l2StaticEntry(
            a1,
            a2,
            _read(2),
            0,
            _l2Callback(a1, a2, _read(1), true),
            RH.appendStatic(0, true, _result(1)),
            true,
            _result(2)
        );
        prediction[1] = _l2StaticEntry(a1, a2, _read(0), 0, new CrossChainCall[](0), 0, true, _result(0));
        vm.prank(manager.SYSTEM_ADDRESS());
        manager.loadExecutionTable(new L2Entry[](0), prediction);
        (bool ok, bytes memory actual) = address(actor).staticcall(_read(3));
        require(ok && keccak256(actual) == keccak256(_result(3)), "real L2 static prediction");
        require(actor.total() == 0 && manager.entryIndex() == 0, "prediction must be read-only");
        require(vm.revertToState(snapshot), "restore prediction fork");
        output("PREDICTED_REMOTE_RESULT", actual);
    }
}

contract DeployConfigure is Script {
    function run() external {
        vm.startBroadcast();
        Actor(vm.envAddress("ACTOR_L1"))
            .configure(getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), vm.envAddress("ACTOR_L2"), 1));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is Script, DeepStaticReadCallbacksUnderStaticAndMutableCallsActions {
    function run() external {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        vm.startBroadcast();
        for (uint256 i; i < t.l2.length; i++) {
            L2Entry[] memory delivery = new L2Entry[](1);
            delivery[0] = t.l2[i];
            manager.executeIncomingCrossChainCall(delivery, noL2StaticEntries());
        }
        vm.stopBroadcast();
        _checkDestination(Actor(vm.envAddress("ACTOR_L2")));
        console.log("done: real L2 execution and rollback checked");
    }
}

contract Execute is Script, DeepStaticReadCallbacksUnderStaticAndMutableCallsActions {
    function run() external {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        require(
            keccak256(vm.envBytes("PREDICTED_REMOTE_RESULT")) == keccak256(t.statics[0].returnData),
            "source table must use real producer result"
        );
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        (,, uint256 beforeBalance) = manager.rollups(1);
        vm.startBroadcast();
        manager.postAndVerifyBatch(immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), 1, t.l1, t.statics));
        Actor(vm.envAddress("ACTOR_L1")).runDeepStaticReadCallbacksUnderStaticAndMutableCalls();
        vm.stopBroadcast();
        _checkSource(Actor(vm.envAddress("ACTOR_L1")));
        (, bytes32 root, uint256 afterBalance) = manager.rollups(1);
        require(root == t.l1[t.l1.length - 1].rollupUpdates[0].newRoot, "wrong final root");
        require(beforeBalance == afterBalance, "unexpected ether delta");
        console.log("done: successful L1 source transaction");
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("ACTOR_L1"));
        console.log("VALUE=0");
        console.log(
            "CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runDeepStaticReadCallbacksUnderStaticAndMutableCalls, ()))
        );
    }
}

contract VerifyNetwork is Script, DeepStaticReadCallbacksUnderStaticAndMutableCallsActions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS source");
    }
}

contract VerifyNetworkL2 is Script, DeepStaticReadCallbacksUnderStaticAndMutableCallsActions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS destination");
    }
}

contract ComputeExpected is ComputeExpectedBase, DeepStaticReadCallbacksUnderStaticAndMutableCallsActions {
    function run() external view {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(t.l1[0])));
        _printL1CallHashes(t.l1);
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(t.l2[0])));
        console.log(
            "ABSENT_L2_HASHES=[%s,%s]",
            vm.toString(t.statics[0].proxyEntryHash),
            vm.toString(t.statics[1].proxyEntryHash)
        );
        _printL1StaticTable(t.statics);
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _printL2Table(t.l2);
        _printL2CallHashes(t.l2);
    }
}
