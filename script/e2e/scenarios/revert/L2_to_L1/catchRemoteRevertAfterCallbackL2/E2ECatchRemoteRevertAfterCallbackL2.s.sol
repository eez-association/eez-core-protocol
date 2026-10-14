// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../../src/L2/EEZL2.sol";
import {IEEZ, L2ToL1Call, ProofSystemBatchPerVerificationEntries} from "../../../../../../src/interfaces/IEEZ.sol";
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
    noStaticEntries,
    RollingHashBuilder as RH,
    expectedL1toL2Hash
} from "../../../shared/E2EHelpers.sol";

// L2 -> L1: add 100
//   L1 -> L2: add 2 (returns 2)
// L1: reverts with FrameFailed(2)
// L2: catches that exact error and finishes successfully.
// Final: both values are 0. There is no second outgoing call.
// Focused scenario: included in default/all runs.

abstract contract CatchRemoteRevertAfterCallbackL2Actions is CallPatternHelpers {
    function _tables(address actorL1, address actorL2) internal pure returns (L2OriginTables memory t) {
        L1EntryBuilder memory h = _newL1Entry(actorL1, actorL2);
        t.statics = new L2Static[](0);
        bytes32 fire = _beginL1Call(h, _fail(), false, 0);
        _expectedL1ToL2Call(h, _bump(2), false, fire, new L2ToL1Call[](0), 0, true, _result(2));
        _endL1Call(h, false, _frameFailure(2));
        t.l2 = new L2Entry[](1);
        t.l2[0] = _l2SourceEntry(actorL1, actorL2, _fail(), false, _frameFailure(2), _bump(2), false, true, _result(2));
        _finishL1Entry(h, t);
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1, "source transaction did not finish");
        require(source.total() == 0, "source callback state");
        require(keccak256(source.failure()) == keccak256(_frameFailure(2)), "exact remote failure");
    }

    function _checkDestination(Actor destination) internal view {
        require(destination.completed() == 0, "extra destination trigger");
        require(destination.total() == 0, "destination state");
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        output("ACTOR_L1", address(new Actor()));
        vm.stopBroadcast();
    }
}

contract DeployL2 is Script {
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

contract ExecuteL2 is Script, CatchRemoteRevertAfterCallbackL2Actions {
    function run() external {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        Actor source = Actor(vm.envAddress("ACTOR_L2"));
        uint256 balance = address(source).balance;
        vm.startBroadcast();
        manager.loadExecutionTable(t.l2, t.statics);
        source.runCatchRemoteRevertAfterCallback();
        vm.stopBroadcast();
        _checkSource(source);
        require(manager.entryIndex() == 0, "wrong source position after execution");
        require(address(source).balance == balance, "unexpected value effects");
        console.log("done: source result and position checked");
    }
}

contract Execute is Script, CatchRemoteRevertAfterCallbackL2Actions {
    function run() external {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        (,, uint256 balance) = manager.rollups(1);
        ProofSystemBatchPerVerificationEntries memory batch =
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), 1, t.l1, noStaticEntries());
        batch.callData = vm.envBytes("RLP_ENCODED_TX");
        vm.startBroadcast();
        manager.postAndVerifyBatch(batch);
        vm.stopBroadcast();
        _checkDestination(Actor(vm.envAddress("ACTOR_L1")));
        (, bytes32 root, uint256 afterBalance) = manager.rollups(1);
        require(root == t.l1[0].rollupUpdates[0].newRoot, "wrong final root");
        require(balance == afterBalance, "unexpected ether delta");
        console.log("done: real destination result checked");
    }
}

contract ExecuteNetworkL2 is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("ACTOR_L2"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runCatchRemoteRevertAfterCallback, ())));
    }
}

contract VerifyNetwork is Script, CatchRemoteRevertAfterCallbackL2Actions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS destination");
    }
}

contract VerifyNetworkL2 is Script, CatchRemoteRevertAfterCallbackL2Actions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS source");
    }
}

contract ComputeExpected is ComputeExpectedBase, CatchRemoteRevertAfterCallbackL2Actions {
    function run() external view {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(t.l1[0])));
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _printL2Table(t.l2);
        string memory hashes;
        for (uint256 i; i < t.l2.length; i++) {
            hashes = string.concat(hashes, i == 0 ? "" : ",", vm.toString(_entryHash(t.l2[i])));
        }
        console.log("EXPECTED_L2_HASHES=[%s]", hashes);
        console.log("EXPECTED_L2_CALL_HASHES=[]");
        // Failed entries are already eventless; no successful-entry exemption applies.
        console.log("EVENTLESS_L2_HASHES=[]");
    }
}
