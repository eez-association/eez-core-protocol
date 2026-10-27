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

// One user transaction starts on L2. Both values start at 0.
//
// L2 -> L1: read (returns 0)
// L2 -> L1: add 10
//   L1 -> L2: add 3 (returns 3)
// L1: returns 13, the sum of both values
// Result: L1 = 10, L2 = 3.
//
// L2 -> L1: start another operation and add 100
//   L1 -> L2: add 2 (returns 5)
// L1: reverts
// L2: catches the error
// Result: failed work disappears; L1 = 10, L2 = 3.
//
// L2: start a group
//   L2 -> L1: read (returns 10)
//   L2 -> L1: add 5 (returns 15)
// L2: revert the group; catch its error
// L2 -> L1: read again (must still return 10)
// L2 -> L1: add 1 (returns 11)
//
// Final result: L1 = 11, L2 = 3. All of this stays in ONE user transaction.
// Included in default/all runs; live composer failures remain failures.

abstract contract StaticReadThenNestedWriteCaughtRevertAndRollbackL2Actions is CallPatternHelpers {
    function _tables(address actorL1, address actorL2) internal view returns (L2OriginTables memory t) {
        L1EntryBuilder memory h = _newL1Entry(actorL1, actorL2);
        t.statics = new L2Static[](0);
        address a1 = h.a1;
        address a2 = h.a2;
        _successfulL1Call(h, _read(0), true, 0, 0);
        bytes32 fire = _beginL1Call(h, _purchase(), false, 0);
        _expectedL1ToL2Call(h, _bump(3), false, fire, new L2ToL1Call[](0), 0, true, _result(3));
        _appendL1HashStep(h, RH.stepNestedBegin(_l1ToL2CallHash(a1, a2, _bump(3), false)));
        _appendL1HashStep(h, RH.stepNestedEnd());
        _endL1Call(h, true, _result(13));

        fire = _beginL1Call(h, _fail(), false, 0);
        _expectedL1ToL2Call(h, _bump(2), false, fire, new L2ToL1Call[](0), 0, true, _result(5));
        _endL1Call(h, false, _frameFailure(5));
        _successfulL1Call(h, _read(0), true, 2, 10);
        _successfulL1Call(h, _bump(5), false, 0, 15);
        _successfulL1Call(h, _read(0), true, 0, 10);
        _successfulL1Call(h, _bump(1), false, 0, 11);

        // ALL mutable sources and both cursor-pinned static entries belong to
        // this single signed L2 transaction and this single L1 settlement host.
        t.l2 = new L2Entry[](4);
        t.l2[0] = _l2SourceEntry(a1, a2, _purchase(), true, _result(13), _bump(3), false, true, _result(3));
        t.l2[1] = _l2SourceEntry(a1, a2, _fail(), false, _frameFailure(5), _bump(2), false, true, _result(5));
        t.l2[2] = _l2SourceEntryWithoutCallbacks(a1, a2, _bump(5), 15);
        t.l2[3] = _l2SourceEntryWithoutCallbacks(a1, a2, _bump(1), 11);
        t.statics = new L2Static[](2);
        t.statics[0] = _l2StaticEntry(a1, a2, _read(0), 0, new CrossChainCall[](0), 0, true, _result(0));
        // Failed entry and enclosing local rollback both restore cursor 1.
        t.statics[1] = _l2StaticEntry(a1, a2, _read(0), 1, new CrossChainCall[](0), 0, true, _result(10));

        _finishL1Entry(h, t);
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1, "source transaction did not finish");
        require(source.total() == 3, "source rollback state");
        require(source.firstRead() == 0 && source.lastRead() == 10 && source.result() == 11, "mixed reads/results");
        require(keccak256(source.failure()) == keccak256(_frameFailure(5)), "mixed failure bytes");
    }

    function _checkDestination(Actor destination) internal view {
        require(destination.total() == 11, "destination state/rollback");
        require(destination.completed() == 0, "extra destination trigger");
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

contract ExecuteL2 is Script, StaticReadThenNestedWriteCaughtRevertAndRollbackL2Actions {
    function run() external {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        Actor source = Actor(vm.envAddress("ACTOR_L2"));
        uint256 balance = address(source).balance;
        vm.startBroadcast();
        manager.loadExecutionTable(t.l2, t.statics);
        source.runStaticReadThenNestedWriteCaughtRevertAndRollback(); // exactly ONE user transaction, no table reloads
        vm.stopBroadcast();
        _checkSource(source);
        require(manager.entryIndex() == t.l2.length, "wrong final source cursor");
        require(address(source).balance == balance, "unexpected source value effects");
        console.log("done: source results, exact failures and cursor checked");
    }
}

contract Execute is Script, StaticReadThenNestedWriteCaughtRevertAndRollbackL2Actions {
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
            "CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runStaticReadThenNestedWriteCaughtRevertAndRollback, ()))
        );
    }
}

contract VerifyNetwork is Script, StaticReadThenNestedWriteCaughtRevertAndRollbackL2Actions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS destination");
    }
}

contract VerifyNetworkL2 is Script, StaticReadThenNestedWriteCaughtRevertAndRollbackL2Actions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS source");
    }
}

contract ComputeExpected is ComputeExpectedBase, StaticReadThenNestedWriteCaughtRevertAndRollbackL2Actions {
    function run() external view {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(t.l1[0])));
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _printL2Table(t.l2);
        _printL2StaticTable(t.statics);
        string memory hashes;
        string memory eventless;
        string memory calls;
        for (uint256 i; i < t.l2.length; i++) {
            hashes = _append(hashes, vm.toString(_entryHash(t.l2[i])));
            if (!t.l2[i].success) continue;
            if (i == 2) eventless = _append(eventless, vm.toString(_entryHash(t.l2[i])));
            else calls = _append(calls, vm.toString(t.l2[i].proxyEntryHash));
        }
        console.log("EXPECTED_L2_HASHES=[%s]", hashes);
        // Failed/rolled-back entries are checked in loaded calldata; their
        // consumption events were correctly erased by the EVM.
        console.log("EVENTLESS_L2_HASHES=[%s]", eventless);
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", calls);
    }

    function _append(string memory list, string memory item) private pure returns (string memory) {
        return bytes(list).length == 0 ? item : string.concat(list, ",", item);
    }
}
