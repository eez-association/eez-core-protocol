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
// L1 -> L2: add 100 on L2
//   L2 -> L1: add 2 on L1
// L2: reverts
// L1: catches the error
// Result: both additions are undone (L1 = 0, L2 = 0).
//
// L1 -> L2: start the next operation
//   L2 -> L1: add 100 on L1
//     L1 -> L2: add 2 on L2
//   L1: reverts
// L2: catches the error, then adds 1
// Result: L1 = 0, L2 = 1.
//
// L1 -> L2: add 4
// Final result: L1 = 0, L2 = 5. The user's transaction succeeds.
// Both catches must receive the original error, including the returned value 2.
// Included in default/all runs; live composer failures remain failures.

abstract contract CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksActions is CallPatternHelpers {
    struct ScenarioTables {
        ExecutionEntry[] l1;
        L2Entry[] l2;
        StaticExecutionEntry[] statics;
        HashStep[][] steps;
    }

    function _tables(address a1, address a2) internal pure returns (ScenarioTables memory t) {
        t.l1 = new ExecutionEntry[](3);
        t.l2 = new L2Entry[](2);
        t.statics = new StaticExecutionEntry[](0);
        t.steps = new HashStep[][](3);
        bytes32 initial = keccak256("l2-initial-state");
        bytes32 middle = keccak256("l2-caught-nested-failure");
        bytes32 finalRoot = keccak256("l2-after-continuation");

        // Failed remote ROOT: its successful L1 child executes and then rolls back.
        t.l1[0] = _originEntry(
            _l1ToL2CallHash(a1, a2, _fail(), false),
            initial,
            initial,
            _l1Callback(a1, a2, _bump(2), false),
            false,
            _frameFailure(2)
        );
        bytes32 rh = RH.entryBegin(t.l1[0].rollupUpdates, t.l1[0].proxyEntryHash);
        rh = RH.appendCallBegin(rh, _l2ToL1CallHash(a1, a2, _bump(2), false));
        t.l1[0].rollingHash = RH.appendCallEnd(rh, true, _result(2));
        t.steps[0] = new HashStep[](2);
        t.steps[0][0] = RH.stepCallBegin(_l2ToL1CallHash(a1, a2, _bump(2), false));
        t.steps[0][1] = RH.stepCallEnd(true, _result(2));

        // Successful remote root catches a failed L1 NESTED frame with an L2 child.
        t.l1[1] = _originEntry(
            _l1ToL2CallHash(a1, a2, _catch(), false),
            initial,
            middle,
            _l1Callback(a1, a2, _fail(), false),
            true,
            _result(1)
        );
        rh = RH.entryBegin(t.l1[1].rollupUpdates, t.l1[1].proxyEntryHash);
        bytes32 fire = RH.appendCallBegin(rh, _l2ToL1CallHash(a1, a2, _fail(), false));
        t.l1[1].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](1);
        t.l1[1].expectedL1ToL2Calls[0] = ExpectedL1ToL2Call(
            expectedL1toL2Hash(_l1ToL2CallHash(a1, a2, _bump(2), false), fire), new L2ToL1Call[](0), 0, true, _result(2)
        );
        // The application's natural revert erases its nested folds, not its row.
        t.l1[1].rollingHash = RH.appendCallEnd(fire, false, _frameFailure(2));
        t.steps[1] = new HashStep[](2);
        t.steps[1][0] = RH.stepCallBegin(_l2ToL1CallHash(a1, a2, _fail(), false));
        t.steps[1][1] = RH.stepCallEnd(false, _frameFailure(2));

        t.l1[2] = _originEntry(
            _l1ToL2CallHash(a1, a2, _bump(4), false), middle, finalRoot, new L2ToL1Call[](0), true, _result(5)
        );
        t.steps[2] = new HashStep[](0);

        // Only the two SUCCESSFUL top-level calls have system deliveries.
        t.l2[0] = _delivery(a1, a2, _catch(), 1);
        fire = RH.appendCallBegin(RH.entryBeginL2(t.l2[0].proxyEntryHash), t.l2[0].proxyEntryHash);
        bytes32 failedHash = RH.appendNestedBegin(fire, _l2ToL1CallHash(a1, a2, _fail(), false));
        failedHash = RH.appendCallBegin(failedHash, _l1ToL2CallHash(a1, a2, _bump(2), false));
        failedHash = RH.appendCallEnd(failedHash, true, _result(2));
        t.l2[0].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](1);
        t.l2[0].expectedOutgoingCalls[0] = ExpectedOutgoingCrossChainCall(
            expectedL1toL2Hash(_l2ToL1CallHash(a1, a2, _fail(), false), fire),
            _l2Callback(a1, a2, _bump(2), false),
            failedHash,
            false,
            _frameFailure(2)
        );
        t.l2[1] = _delivery(a1, a2, _bump(4), 5);
    }

    function _originEntry(
        bytes32 key,
        bytes32 beforeRoot,
        bytes32 afterRoot,
        L2ToL1Call[] memory callbacks,
        bool success,
        bytes memory result
    )
        private
        pure
        returns (ExecutionEntry memory e)
    {
        e.rollupUpdates = new RollupUpdate[](1);
        e.rollupUpdates[0] = RollupUpdate(1, 0, beforeRoot, afterRoot);
        e.proxyEntryHash = key;
        e.destinationRollupId = 1;
        e.l2ToL1Calls = callbacks;
        e.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        e.rollingHash = RH.entryBegin(e.rollupUpdates, key);
        e.success = success;
        e.returnData = result;
    }

    function _delivery(
        address a1,
        address a2,
        bytes memory data,
        uint256 result
    )
        private
        pure
        returns (L2Entry memory e)
    {
        e.proxyEntryHash = _l1ToL2CallHash(a1, a2, data, false);
        e.incomingCalls = _l2Callback(a1, a2, data, false);
        e.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        bytes32 rh = RH.appendCallBegin(RH.entryBeginL2(e.proxyEntryHash), e.proxyEntryHash);
        e.rollingHash = RH.appendCallEnd(rh, true, _result(result));
        e.success = true;
        e.returnData = _result(result);
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1 && source.result() == 5, "successful source continuation");
        require(source.total() == 0, "failed root's L1 callback survived");
        require(keccak256(source.failure()) == keccak256(_frameFailure(2)), "wrong remote failure data");
    }

    function _checkDestination(Actor destination) internal view {
        require(destination.total() == 5 && destination.completed() == 0, "L2 rollback/continuation");
        require(keccak256(destination.failure()) == keccak256(_frameFailure(2)), "wrong nested failure data");
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        output("ACTOR_L1", address(new Actor()));
        vm.stopBroadcast();
    }
}

contract DeployL2 is Script, CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksActions {
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
        L2Entry[] memory prediction = new L2Entry[](1);
        prediction[0] = _l2SourceEntryWithoutCallbacks(vm.envAddress("ACTOR_L1"), address(actor), _bump(2), 2);
        vm.prank(manager.SYSTEM_ADDRESS());
        manager.loadExecutionTable(prediction, noL2StaticEntries());
        (bool ok, bytes memory actual) = address(actor).call(_fail());
        require(!ok && keccak256(actual) == keccak256(_frameFailure(2)), "real L2 failure prediction");
        require(actor.total() == 0 && manager.entryIndex() == 0, "prediction rollback");
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

contract ExecuteL2 is Script, CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksActions {
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

contract Execute is Script, CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksActions {
    function run() external {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        require(
            keccak256(vm.envBytes("PREDICTED_REMOTE_RESULT")) == keccak256(t.l1[0].returnData),
            "source table must use real producer result"
        );
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        (,, uint256 beforeBalance) = manager.rollups(1);
        vm.startBroadcast();
        manager.postAndVerifyBatch(immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), 1, t.l1, t.statics));
        Actor(vm.envAddress("ACTOR_L1")).runCatchRemoteAndNestedRevertsAfterSuccessfulCallbacks();
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
            "CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runCatchRemoteAndNestedRevertsAfterSuccessfulCallbacks, ()))
        );
    }
}

contract VerifyNetwork is Script, CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksActions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS source");
    }
}

contract VerifyNetworkL2 is Script, CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksActions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS destination");
    }
}

contract ComputeExpected is ComputeExpectedBase, CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksActions {
    function run() external view {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        // The failed entry has no surviving consumption event; its full table is still verified.
        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(_entryHash(t.l1[1])), vm.toString(_entryHash(t.l1[2])));
        console.log(
            "EXPECTED_L1_CALL_HASHES=[%s,%s]", vm.toString(t.l1[1].proxyEntryHash), vm.toString(t.l1[2].proxyEntryHash)
        );
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(_entryHash(t.l2[0])), vm.toString(_entryHash(t.l2[1])));
        console.log("ABSENT_L2_HASHES=[%s]", vm.toString(t.l1[0].proxyEntryHash));
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _printL2Table(t.l2);
        _printL2CallHashes(t.l2);
    }
}
