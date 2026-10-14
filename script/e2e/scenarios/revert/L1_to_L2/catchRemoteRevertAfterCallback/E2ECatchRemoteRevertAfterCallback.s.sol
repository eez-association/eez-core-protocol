// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

// L1 -> L2: add 100
//   L2 -> L1: add 2 (returns 2)
// L2: reverts with FrameFailed(2)
// L1: catches that exact error and finishes successfully.
// Final: both values are 0. This is the ONLY L1 -> L2 root call.
// The real L2 failure is checked in a setup simulation; it has no mined delivery.
// Focused scenario: included in default/all runs.

abstract contract CatchRemoteRevertAfterCallbackActions is CallPatternHelpers {
    struct ScenarioTables {
        ExecutionEntry[] l1;
        L2Entry[] l2;
        StaticExecutionEntry[] statics;
        HashStep[][] steps;
    }

    function _tables(address actorL1, address actorL2) internal pure returns (ScenarioTables memory t) {
        t.statics = new StaticExecutionEntry[](0);
        t.l1 = new ExecutionEntry[](1);
        t.l2 = new L2Entry[](0);
        t.steps = new HashStep[][](1);
        ExecutionEntry memory e;
        e.rollupUpdates = new RollupUpdate[](1);
        e.rollupUpdates[0] = RollupUpdate(1, 0, keccak256("l2-initial-state"), keccak256("l2-initial-state"));
        e.proxyEntryHash = _l1ToL2CallHash(actorL1, actorL2, _fail(), false);
        e.destinationRollupId = 1;
        e.l2ToL1Calls = _l1Callback(actorL1, actorL2, _bump(2), false);
        e.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        bytes32 rh = RH.appendCallBegin(
            RH.entryBegin(e.rollupUpdates, e.proxyEntryHash), _l2ToL1CallHash(actorL1, actorL2, _bump(2), false)
        );
        e.rollingHash = RH.appendCallEnd(rh, true, _result(2));
        e.success = false;
        e.returnData = _frameFailure(2);
        t.l1[0] = e;
        t.steps[0] = new HashStep[](2);
        t.steps[0][0] = RH.stepCallBegin(_l2ToL1CallHash(actorL1, actorL2, _bump(2), false));
        t.steps[0][1] = RH.stepCallEnd(true, _result(2));
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1 && source.total() == 0, "source completion/rollback");
        require(keccak256(source.failure()) == keccak256(_frameFailure(2)), "exact remote failure");
    }

    function _checkDestination(Actor destination) internal view {
        require(destination.completed() == 0 && destination.total() == 0, "destination state");
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        output("ACTOR_L1", address(new Actor()));
        vm.stopBroadcast();
    }
}

contract DeployL2 is Script, CatchRemoteRevertAfterCallbackActions {
    function run() external {
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        require(!manager.USE_GAS_LEFT(), "scenario requires gas-independent keys");
        vm.startBroadcast();
        Actor actor = new Actor();
        actor.configure(getOrCreateProxy(IEEZ(address(manager)), vm.envAddress("ACTOR_L1"), 0));
        output("ACTOR_L2", address(actor));
        vm.stopBroadcast();

        // Simulate the real L2 producer; these prediction tables are never broadcast.
        uint256 snapshot = vm.snapshotState();
        L2Entry[] memory prediction = new L2Entry[](1);
        prediction[0] = _l2SourceEntryWithoutCallbacks(vm.envAddress("ACTOR_L1"), address(actor), _bump(2), 2);
        vm.prank(manager.SYSTEM_ADDRESS());
        manager.loadExecutionTable(prediction, noL2StaticEntries());
        (bool ok, bytes memory actual) = address(actor).call(_fail());
        require(!ok && keccak256(actual) == keccak256(_frameFailure(2)), "real L2 failure prediction");
        require(actor.total() == 0 && manager.entryIndex() == 0, "prediction must leave no effects");
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

contract Execute is Script, CatchRemoteRevertAfterCallbackActions {
    function run() external {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        require(
            keccak256(vm.envBytes("PREDICTED_REMOTE_RESULT")) == keccak256(t.l1[0].returnData),
            "use the real producer result"
        );
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        (,, uint256 balance) = manager.rollups(1);
        vm.startBroadcast();
        manager.postAndVerifyBatch(immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), 1, t.l1, t.statics));
        Actor(vm.envAddress("ACTOR_L1")).runCatchRemoteRevertAfterCallback();
        vm.stopBroadcast();
        _checkSource(Actor(vm.envAddress("ACTOR_L1")));
        (, bytes32 root, uint256 afterBalance) = manager.rollups(1);
        require(root == keccak256("l2-initial-state"), "wrong final root");
        require(balance == afterBalance, "unexpected ether delta");
        console.log("done: successful L1 source transaction");
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("ACTOR_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runCatchRemoteRevertAfterCallback, ())));
    }
}

contract VerifyNetwork is Script, CatchRemoteRevertAfterCallbackActions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS source");
    }
}

contract VerifyNetworkL2 is Script, CatchRemoteRevertAfterCallbackActions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS destination");
    }
}

contract ComputeExpected is ComputeExpectedBase, CatchRemoteRevertAfterCallbackActions {
    function run() external view {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        console.log("EXPECTED_L1_HASHES=[]");
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("ABSENT_L2_HASHES=[%s]", vm.toString(t.l1[0].proxyEntryHash));
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _printL2Table(t.l2);
        _printL2CallHashes(t.l2);
    }
}
