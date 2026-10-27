// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {E2ERollupConfig} from "../../../shared/E2EHelpers.sol";

// E2E_EXCLUDE_FROM_ALL: PR #54 call-pattern scenarios; explicit selection only pending live validation.

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

// The user starts on L2. Each chain's value starts at 0.
//
// L2 -> L1: add 100 on L1
//   L1 -> L2: add 2 on L2
// L1: reverts
// L2: catches the error
// Result: both additions are undone (L2 = 0, L1 = 0).
//
// L2 -> L1: start the next operation
//   L1 -> L2: add 100 on L2
//     L2 -> L1: add 2 on L1
//   L2: reverts
// L1: catches the error, then adds 1
// Result: L2 = 0, L1 = 1.
//
// L2 -> L1: add 4
// Final result: L2 = 0, L1 = 5. The user's transaction succeeds.
// Both catches must receive the original error, including the returned value 2.
// Included in default/all runs; live composer failures remain failures.

abstract contract CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksL2Actions is CallPatternHelpers {
    function _tables(address actorL1, address actorL2) internal view returns (L2OriginTables memory t) {
        L1EntryBuilder memory h = _newL1Entry(actorL1, actorL2);
        t.statics = new L2Static[](0);
        address a1 = h.a1;
        address a2 = h.a2;
        // L1 failed remote root -> successful L2 child. Nested folds disappear
        // with the real L1 revert, but this required row remains in the table.
        bytes32 fire = _beginL1Call(h, _fail(), false, 0);
        _expectedL1ToL2Call(h, _bump(2), false, fire, new L2ToL1Call[](0), 0, true, _result(2));
        _endL1Call(h, false, _frameFailure(2));
        // L1 catches a failed L2 nested frame that first calls back into L1.
        fire = _beginL1Call(h, _catch(), false, 0);
        bytes32 sub = RH.appendNestedBegin(fire, _l1ToL2CallHash(a1, a2, _fail(), false));
        sub = RH.appendCallBegin(sub, _l2ToL1CallHash(a1, a2, _bump(2), false));
        sub = RH.appendCallEnd(sub, true, _result(2)); // no NESTED_END for failure
        _expectedL1ToL2Call(h, _fail(), false, fire, _l1Callback(a1, a2, _bump(2), false), sub, false, _frameFailure(2));
        _endL1Call(h, true, _result(1));
        _successfulL1Call(h, _bump(4), false, 0, 5);

        t.l2 = new L2Entry[](3);
        t.l2[0] = _l2SourceEntry(a1, a2, _fail(), false, _frameFailure(2), _bump(2), false, true, _result(2));
        t.l2[1] = _l2SourceEntry(a1, a2, _catch(), true, _result(1), _fail(), false, false, _frameFailure(2));
        fire = RH.appendCallBegin(RH.entryBeginL2(t.l2[1].proxyEntryHash), _l1ToL2CallHash(a1, a2, _fail(), false));
        t.l2[1].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](1);
        t.l2[1].expectedOutgoingCalls[0] = ExpectedOutgoingCrossChainCall(
            expectedL1toL2Hash(_l2ToL1CallHash(a1, a2, _bump(2), false), fire),
            new CrossChainCall[](0),
            0,
            true,
            _result(2)
        );
        t.l2[2] = _l2SourceEntryWithoutCallbacks(a1, a2, _bump(4), 5);

        _finishL1Entry(h, t);
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1, "source transaction did not finish");
        require(source.total() == 0, "source rollback state");
        require(source.result() == 5, "source continuation");
        require(keccak256(source.failure()) == keccak256(_frameFailure(2)), "source failure bytes");
    }

    function _checkDestination(Actor destination) internal view {
        require(destination.total() == 5, "destination state/rollback");
        require(destination.completed() == 0, "extra destination trigger");
        require(keccak256(destination.failure()) == keccak256(_frameFailure(2)), "nested failure bytes");
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

contract DeployConfigure is Script, E2ERollupConfig {
    function run() external {
        vm.startBroadcast();
        Actor(vm.envAddress("ACTOR_L1"))
            .configure(getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), vm.envAddress("ACTOR_L2"), _e2eRollupId()));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is Script, CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksL2Actions {
    function run() external {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        Actor source = Actor(vm.envAddress("ACTOR_L2"));
        uint256 balance = address(source).balance;
        vm.startBroadcast();
        manager.loadExecutionTable(t.l2, t.statics);
        source.runCatchRemoteAndNestedRevertsAfterSuccessfulCallbacks(); // exactly ONE user transaction, no table reloads
        vm.stopBroadcast();
        _checkSource(source);
        require(manager.entryIndex() == t.l2.length, "wrong final source cursor");
        require(address(source).balance == balance, "unexpected source value effects");
        console.log("done: source results, exact failures and cursor checked");
    }
}

contract Execute is Script, CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksL2Actions {
    function run() external {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        (,, uint256 beforeBalance) = manager.rollups(_e2eRollupId());
        ProofSystemBatchPerVerificationEntries memory batch =
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), _e2eRollupId(), t.l1, noStaticEntries());
        // The entire signed L2 transaction and its tables share ONE L1 host.
        batch.callData = vm.envBytes("RLP_ENCODED_TX");
        vm.startBroadcast();
        manager.postAndVerifyBatch(batch);
        vm.stopBroadcast();
        _checkDestination(Actor(vm.envAddress("ACTOR_L1")));
        (, bytes32 root, uint256 afterBalance) = manager.rollups(_e2eRollupId());
        require(root == t.l1[0].rollupUpdates[0].newRoot, "wrong final root");
        require(beforeBalance == afterBalance, "unexpected ether delta");
        console.log("done: real destination results and rollback checked");
    }
}

contract ExecuteNetworkL2 is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("ACTOR_L2"));
        console.log("VALUE=0");
        console.log(
            "CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runCatchRemoteAndNestedRevertsAfterSuccessfulCallbacks, ()))
        );
    }
}

contract VerifyNetwork is Script, CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksL2Actions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS destination");
    }
}

contract VerifyNetworkL2 is Script, CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksL2Actions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS source");
    }
}

contract ComputeExpected is ComputeExpectedBase, CatchRemoteAndNestedRevertsAfterSuccessfulCallbacksL2Actions {
    function run() external view {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(t.l1[0])));
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _printL2Table(t.l2);
        _printL2StaticTable(t.statics);
        console.log(
            "EXPECTED_L2_HASHES=[%s,%s,%s]",
            vm.toString(_entryHash(t.l2[0])),
            vm.toString(_entryHash(t.l2[1])),
            vm.toString(_entryHash(t.l2[2]))
        );
        // Entry 0 fails: its complete loaded table is checked, but its events disappear.
        console.log(
            "EXPECTED_L2_CALL_HASHES=[%s,%s]", vm.toString(t.l2[1].proxyEntryHash), vm.toString(t.l2[2].proxyEntryHash)
        );
        console.log("EVENTLESS_L2_HASHES=[]");
    }
}
