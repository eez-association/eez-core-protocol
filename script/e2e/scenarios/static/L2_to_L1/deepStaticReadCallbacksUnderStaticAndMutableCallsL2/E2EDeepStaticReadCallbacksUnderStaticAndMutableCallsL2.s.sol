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
// First request -- reads only; answers return from the innermost call outward:
// L2 -> L1: read (returns 3)
//   L1 -> L2: read (returns 2)
//     L2 -> L1: read (returns 1)
//       L1 -> L2: read the stored value (returns 0)
// Result: the user receives 3. Neither stored value changes.
//
// Second request -- an operation that reads before changing its own value:
// L2 -> L1: start the operation
//   L1 -> L2: read (returns 2)
//     L2 -> L1: read (returns 1)
//       L1 -> L2: read the stored value (returns 0)
// L1: the reads finished; add 1 locally and return the answer 2
//
// Final result: the user recorded 3 and 2; L2 = 0, L1 = 1.
// Every call beneath a read must remain read-only.
// Included in default/all runs; live composer failures remain failures.

abstract contract DeepStaticReadCallbacksUnderStaticAndMutableCallsL2Actions is CallPatternHelpers {
    function _tables(address actorL1, address actorL2) internal view returns (L2OriginTables memory t) {
        L1EntryBuilder memory h = _newL1Entry(actorL1, actorL2);
        t.statics = new L2Static[](0);
        address a1 = h.a1;
        address a2 = h.a2;
        _deepRows(h, _beginL1Call(h, _read(3), true, 0));
        _endL1Call(h, true, _result(3));
        _deepRows(h, _beginL1Call(h, _under(), false, 0));
        _endL1Call(h, true, _result(2));

        // No L2 mutable execution is open while resolving read(3): its
        // callback's outgoing read(1) requires its OWN top-level pool entry.
        t.statics = new L2Static[](2);
        t.statics[0] = _l2StaticEntry(
            a1,
            a2,
            _read(3),
            0,
            _l2Callback(a1, a2, _read(2), true),
            RH.appendStatic(0, true, _result(2)),
            true,
            _result(3)
        );
        t.statics[1] = _l2StaticEntry(
            a1,
            a2,
            _read(1),
            0,
            _l2Callback(a1, a2, _read(0), true),
            RH.appendStatic(0, true, _result(0)),
            true,
            _result(1)
        );
        t.l2 = new L2Entry[](1);
        t.l2[0] = _l2SourceEntry(a1, a2, _under(), true, _result(2), _read(2), true, true, _result(2));
        bytes32 fire =
            RH.appendCallBegin(RH.entryBeginL2(t.l2[0].proxyEntryHash), _l1ToL2CallHash(a1, a2, _read(2), true));
        t.l2[0].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](1);
        t.l2[0].expectedOutgoingCalls[0] = ExpectedOutgoingCrossChainCall(
            expectedL1toL2Hash(_l2ToL1CallHash(a1, a2, _read(1), true), fire),
            _l2Callback(a1, a2, _read(0), true),
            RH.appendStatic(0, true, _result(0)),
            true,
            _result(1)
        );

        _finishL1Entry(h, t);
    }

    function _deepRows(L1EntryBuilder memory h, bytes32 fire) private view {
        // STATIC resolution does not modify the host hash: the grandchild
        // read(0) has the SAME firing position as read(2), with a different key.
        _expectedL1ToL2Call(
            h,
            _read(2),
            true,
            fire,
            _l1Callback(h.a1, h.a2, _read(1), true),
            RH.appendStatic(0, true, _result(1)),
            true,
            _result(2)
        );
        _expectedL1ToL2Call(h, _read(0), true, fire, new L2ToL1Call[](0), 0, true, _result(0));
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1, "source transaction did not finish");
        require(source.total() == 0, "source rollback state");
        require(source.firstRead() == 3 && source.lastRead() == 2, "source deep reads");
    }

    function _checkDestination(Actor destination) internal view {
        require(destination.total() == 1, "destination state/rollback");
        require(destination.completed() == 0, "extra destination trigger");
        require(destination.lastRead() == 2, "real destination read result");
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

contract ExecuteL2 is Script, DeepStaticReadCallbacksUnderStaticAndMutableCallsL2Actions {
    function run() external {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        Actor source = Actor(vm.envAddress("ACTOR_L2"));
        uint256 balance = address(source).balance;
        vm.startBroadcast();
        manager.loadExecutionTable(t.l2, t.statics);
        source.runDeepStaticReadCallbacksUnderStaticAndMutableCalls(); // exactly ONE user transaction, no table reloads
        vm.stopBroadcast();
        _checkSource(source);
        require(manager.entryIndex() == t.l2.length, "wrong final source cursor");
        require(address(source).balance == balance, "unexpected source value effects");
        console.log("done: source results, exact failures and cursor checked");
    }
}

contract Execute is Script, DeepStaticReadCallbacksUnderStaticAndMutableCallsL2Actions {
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
            "CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runDeepStaticReadCallbacksUnderStaticAndMutableCalls, ()))
        );
    }
}

contract VerifyNetwork is Script, DeepStaticReadCallbacksUnderStaticAndMutableCallsL2Actions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS destination");
    }
}

contract VerifyNetworkL2 is Script, DeepStaticReadCallbacksUnderStaticAndMutableCallsL2Actions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS source");
    }
}

contract ComputeExpected is ComputeExpectedBase, DeepStaticReadCallbacksUnderStaticAndMutableCallsL2Actions {
    function run() external view {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(t.l1[0])));
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _printL2Table(t.l2);
        _printL2StaticTable(t.statics);
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(t.l2[0])));
        _printL2CallHashes(t.l2);
        console.log("EVENTLESS_L2_HASHES=[]");
    }
}
