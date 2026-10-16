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

// L1 -> L2: start one operation
//   L2 -> L1: read (returns 1)
//     L1 -> L2: read the stored value (returns 0)
// L2: after the reads finish, add 1 and return the answer 1.
// Final: L1 = 0, L2 = 1. All calls beneath the read are read-only.
// Explicit selection only until validated on the live network.

abstract contract MutableCallMakesReadThatCallsBackActions is CallPatternHelpers {
    struct ScenarioTables {
        ExecutionEntry[] l1;
        L2Entry[] l2;
        StaticExecutionEntry[] statics;
        HashStep[][] steps;
    }

    function _tables(address actorL1, address actorL2) internal pure returns (ScenarioTables memory t) {
        t.statics = new StaticExecutionEntry[](0);
        t.l1 = new ExecutionEntry[](1);
        t.l2 = new L2Entry[](1);
        t.steps = new HashStep[][](1);
        bytes memory operation = abi.encodeCall(Actor.readThenAddOne, ());
        ExecutionEntry memory e;
        e.rollupUpdates = new RollupUpdate[](1);
        e.rollupUpdates[0] = RollupUpdate(1, 0, keccak256("l2-initial-state"), keccak256("focused-nested-read"));
        e.proxyEntryHash = _l1ToL2CallHash(actorL1, actorL2, operation, false);
        e.destinationRollupId = 1;
        e.l2ToL1Calls = _l1Callback(actorL1, actorL2, _read(1), true);
        bytes32 fire = RH.appendCallBegin(
            RH.entryBegin(e.rollupUpdates, e.proxyEntryHash), _l2ToL1CallHash(actorL1, actorL2, _read(1), true)
        );
        e.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](1);
        e.expectedL1ToL2Calls[0] = ExpectedL1ToL2Call(
            expectedL1toL2Hash(_l1ToL2CallHash(actorL1, actorL2, _read(0), true), fire),
            new L2ToL1Call[](0),
            0,
            true,
            _result(0)
        );
        e.rollingHash = RH.appendCallEnd(fire, true, _result(1));
        e.success = true;
        e.returnData = _result(1);
        t.l1[0] = e;
        t.steps[0] = new HashStep[](2);
        t.steps[0][0] = RH.stepCallBegin(_l2ToL1CallHash(actorL1, actorL2, _read(1), true));
        t.steps[0][1] = RH.stepCallEnd(true, _result(1));

        L2Entry memory delivery;
        delivery.proxyEntryHash = e.proxyEntryHash;
        delivery.incomingCalls = _l2Callback(actorL1, actorL2, operation, false);
        fire = RH.appendCallBegin(RH.entryBeginL2(delivery.proxyEntryHash), delivery.proxyEntryHash);
        delivery.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](1);
        delivery.expectedOutgoingCalls[0] = ExpectedOutgoingCrossChainCall(
            expectedL1toL2Hash(_l2ToL1CallHash(actorL1, actorL2, _read(1), true), fire),
            _l2Callback(actorL1, actorL2, _read(0), true),
            RH.appendStatic(0, true, _result(0)),
            true,
            _result(1)
        );
        delivery.rollingHash = RH.appendCallEnd(fire, true, _result(1));
        delivery.success = true;
        delivery.returnData = _result(1);
        t.l2[0] = delivery;
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1 && source.total() == 0, "source completion/rollback");
        require(source.result() == 1, "mutable call read result");
    }

    function _checkDestination(Actor destination) internal view {
        require(destination.completed() == 0 && destination.total() == 1, "destination state");
        require(destination.lastRead() == 1, "real nested read result");
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        output("ACTOR_L1", address(new Actor()));
        vm.stopBroadcast();
    }
}

contract DeployL2 is Script, MutableCallMakesReadThatCallsBackActions {
    function run() external {
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        require(!manager.USE_GAS_LEFT(), "scenario requires gas-independent keys");
        vm.startBroadcast();
        Actor actor = new Actor();
        actor.configure(getOrCreateProxy(IEEZ(address(manager)), vm.envAddress("ACTOR_L1"), 0));
        output("ACTOR_L2", address(actor));
        vm.stopBroadcast();
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

contract ExecuteL2 is Script, MutableCallMakesReadThatCallsBackActions {
    function run() external {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2")).executeIncomingCrossChainCall(t.l2, noL2StaticEntries());
        vm.stopBroadcast();
        _checkDestination(Actor(vm.envAddress("ACTOR_L2")));
        console.log("done: real L2 delivery checked");
    }
}

contract Execute is Script, MutableCallMakesReadThatCallsBackActions {
    function run() external {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));

        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        (,, uint256 balance) = manager.rollups(1);
        vm.startBroadcast();
        manager.postAndVerifyBatch(immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), 1, t.l1, t.statics));
        Actor(vm.envAddress("ACTOR_L1")).runMutableCallMakesReadThatCallsBack();
        vm.stopBroadcast();
        _checkSource(Actor(vm.envAddress("ACTOR_L1")));
        (, bytes32 root, uint256 afterBalance) = manager.rollups(1);
        require(root == t.l1[0].rollupUpdates[0].newRoot, "wrong final root");
        require(balance == afterBalance, "unexpected ether delta");
        console.log("done: successful L1 source transaction");
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("ACTOR_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runMutableCallMakesReadThatCallsBack, ())));
    }
}

contract VerifyNetwork is Script, MutableCallMakesReadThatCallsBackActions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS source");
    }
}

contract VerifyNetworkL2 is Script, MutableCallMakesReadThatCallsBackActions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS destination");
    }
}

contract ComputeExpected is ComputeExpectedBase, MutableCallMakesReadThatCallsBackActions {
    function run() external view {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(t.l1[0])));
        _printL1CallHashes(t.l1);
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(t.l2[0])));
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _printL2Table(t.l2);
        _printL2CallHashes(t.l2);
    }
}
