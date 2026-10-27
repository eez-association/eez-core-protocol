// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {E2ERollupConfig} from "../../../shared/E2EHelpers.sol";

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
//   L2 -> L1: add 100
//     L1 -> L2: add 2 (returns 2)
//   L1: reverts with FrameFailed(2)
// L2: catches that error, then adds 1 and returns 1.
// Final: L1 = 0, L2 = 1. There are no earlier or later root calls.
// Explicit selection only until validated on the live network.

abstract contract CatchNestedRevertAfterCallbackActions is CallPatternHelpers {
    struct ScenarioTables {
        ExecutionEntry[] l1;
        L2Entry[] l2;
        StaticExecutionEntry[] statics;
        HashStep[][] steps;
    }

    function _tables(address actorL1, address actorL2) internal view returns (ScenarioTables memory t) {
        t.statics = new StaticExecutionEntry[](0);
        t.l1 = new ExecutionEntry[](1);
        t.l2 = new L2Entry[](1);
        t.steps = new HashStep[][](1);
        ExecutionEntry memory e;
        e.rollupUpdates = new RollupUpdate[](1);
        e.rollupUpdates[0] =
            RollupUpdate(_e2eRollupId(), 0, keccak256("l2-initial-state"), keccak256("focused-nested-failure"));
        e.proxyEntryHash = _l1ToL2CallHash(actorL1, actorL2, _catch(), false);
        e.destinationRollupId = _e2eRollupId();
        e.l2ToL1Calls = _l1Callback(actorL1, actorL2, _fail(), false);
        bytes32 fire = RH.appendCallBegin(
            RH.entryBegin(e.rollupUpdates, e.proxyEntryHash), _l2ToL1CallHash(actorL1, actorL2, _fail(), false)
        );
        e.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](1);
        e.expectedL1ToL2Calls[0] = ExpectedL1ToL2Call(
            expectedL1toL2Hash(_l1ToL2CallHash(actorL1, actorL2, _bump(2), false), fire),
            new L2ToL1Call[](0),
            0,
            true,
            _result(2)
        );
        e.rollingHash = RH.appendCallEnd(fire, false, _frameFailure(2));
        e.success = true;
        e.returnData = _result(1);
        t.l1[0] = e;
        t.steps[0] = new HashStep[](2);
        t.steps[0][0] = RH.stepCallBegin(_l2ToL1CallHash(actorL1, actorL2, _fail(), false));
        t.steps[0][1] = RH.stepCallEnd(false, _frameFailure(2));

        L2Entry memory delivery;
        delivery.proxyEntryHash = e.proxyEntryHash;
        delivery.incomingCalls = _l2Callback(actorL1, actorL2, _catch(), false);
        fire = RH.appendCallBegin(RH.entryBeginL2(delivery.proxyEntryHash), delivery.proxyEntryHash);
        bytes32 failedHash = RH.appendNestedBegin(fire, _l2ToL1CallHash(actorL1, actorL2, _fail(), false));
        failedHash = RH.appendCallBegin(failedHash, _l1ToL2CallHash(actorL1, actorL2, _bump(2), false));
        failedHash = RH.appendCallEnd(failedHash, true, _result(2));
        delivery.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](1);
        delivery.expectedOutgoingCalls[0] = ExpectedOutgoingCrossChainCall(
            expectedL1toL2Hash(_l2ToL1CallHash(actorL1, actorL2, _fail(), false), fire),
            _l2Callback(actorL1, actorL2, _bump(2), false),
            failedHash,
            false,
            _frameFailure(2)
        );
        delivery.rollingHash = RH.appendCallEnd(fire, true, _result(1));
        delivery.success = true;
        delivery.returnData = _result(1);
        t.l2[0] = delivery;
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1 && source.total() == 0, "source completion/rollback");
        require(source.result() == 1, "caught nested result");
    }

    function _checkDestination(Actor destination) internal view {
        require(destination.completed() == 0 && destination.total() == 1, "destination state");
        require(keccak256(destination.failure()) == keccak256(_frameFailure(2)), "exact nested failure");
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        output("ACTOR_L1", address(new Actor()));
        vm.stopBroadcast();
    }
}

contract DeployL2 is Script, CatchNestedRevertAfterCallbackActions {
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

contract DeployConfigure is Script, E2ERollupConfig {
    function run() external {
        vm.startBroadcast();
        Actor(vm.envAddress("ACTOR_L1"))
            .configure(getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), vm.envAddress("ACTOR_L2"), _e2eRollupId()));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is Script, CatchNestedRevertAfterCallbackActions {
    function run() external {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2")).executeIncomingCrossChainCall(t.l2, noL2StaticEntries());
        vm.stopBroadcast();
        _checkDestination(Actor(vm.envAddress("ACTOR_L2")));
        console.log("done: real L2 delivery checked");
    }
}

contract Execute is Script, CatchNestedRevertAfterCallbackActions {
    function run() external {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));

        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        (,, uint256 balance) = manager.rollups(_e2eRollupId());
        vm.startBroadcast();
        manager.postAndVerifyBatch(
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), _e2eRollupId(), t.l1, t.statics)
        );
        Actor(vm.envAddress("ACTOR_L1")).runCatchNestedRevertAfterCallback();
        vm.stopBroadcast();
        _checkSource(Actor(vm.envAddress("ACTOR_L1")));
        (, bytes32 root, uint256 afterBalance) = manager.rollups(_e2eRollupId());
        require(root == t.l1[0].rollupUpdates[0].newRoot, "wrong final root");
        require(balance == afterBalance, "unexpected ether delta");
        console.log("done: successful L1 source transaction");
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("ACTOR_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runCatchNestedRevertAfterCallback, ())));
    }
}

contract VerifyNetwork is Script, CatchNestedRevertAfterCallbackActions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS source");
    }
}

contract VerifyNetworkL2 is Script, CatchNestedRevertAfterCallbackActions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS destination");
    }
}

contract ComputeExpected is ComputeExpectedBase, CatchNestedRevertAfterCallbackActions {
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
