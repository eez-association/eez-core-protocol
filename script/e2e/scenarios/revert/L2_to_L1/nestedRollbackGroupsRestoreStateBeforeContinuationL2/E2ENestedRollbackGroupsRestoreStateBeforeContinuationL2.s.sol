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

// The user starts on L2. L1's value starts at 0.
//
// L2: start outer group
//   L2 -> L1: add 1 (returns 1)
//   L2: start inner group
//     L2 -> L1: add 2 (returns 3)
//     L2 -> L1: add 4 (returns 7)
//   L2: revert inner group; catch its error
//   Result: L1 is back at 1.
//   L2 -> L1: check that the value is 1, then add 8 (returns 9)
// L2: revert outer group; catch its error
// Result: L1 is back at 0.
//
// L2 -> L1: repeat the original add-1 request (returns 1)
// L2 -> L1: check that the value is 1, then add 16 (returns 17)
//
// Final result: L1 = 17. Every addition succeeded when it ran.
// Undoing only at the end is wrong: the check before adding 8 would see 7.
// The repeated request has the same answer; no local write changes it.
// Included in default/all runs; live composer failures remain failures.

abstract contract NestedRollbackGroupsRestoreStateBeforeContinuationL2Actions is CallPatternHelpers {
    function _tables(address actorL1, address actorL2) internal view returns (L2OriginTables memory t) {
        L1EntryBuilder memory h = _newL1Entry(actorL1, actorL2);
        t.statics = new L2Static[](0);
        // Outer [A, inner[B,C], D]. The inner slice ends BEFORE D.
        // Controlled rollback preserves successful results and folds.
        _successfulL1Call(h, _bump(1), false, 4, 1);
        _successfulL1Call(h, _bump(2), false, 2, 3);
        _successfulL1Call(h, _bump(4), false, 0, 7);
        _successfulL1Call(h, _observe(1, 8), false, 0, 9);
        _successfulL1Call(h, _bump(1), false, 0, 1);
        _successfulL1Call(h, _observe(1, 16), false, 0, 17);
        t.l2 = new L2Entry[](5);
        t.l2[0] = _l2SourceEntryWithoutCallbacks(h.a1, h.a2, _bump(1), 1); // reused after outer rollback
        t.l2[1] = _l2SourceEntryWithoutCallbacks(h.a1, h.a2, _bump(2), 3);
        t.l2[2] = _l2SourceEntryWithoutCallbacks(h.a1, h.a2, _bump(4), 7);
        t.l2[3] = _l2SourceEntryWithoutCallbacks(h.a1, h.a2, _observe(1, 8), 9);
        t.l2[4] = _l2SourceEntryWithoutCallbacks(h.a1, h.a2, _observe(1, 16), 17);

        _finishL1Entry(h, t);
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1, "source transaction did not finish");
        require(source.total() == 0, "source rollback state");
        require(source.result() == 17, "outer group result");
    }

    function _checkDestination(Actor destination) internal view {
        require(destination.total() == 17, "destination state/rollback");
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

contract ExecuteL2 is Script, NestedRollbackGroupsRestoreStateBeforeContinuationL2Actions {
    function run() external {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        Actor source = Actor(vm.envAddress("ACTOR_L2"));
        uint256 balance = address(source).balance;
        vm.startBroadcast();
        manager.loadExecutionTable(t.l2, t.statics);
        source.runNestedRollbackGroupsRestoreStateBeforeContinuation(); // exactly ONE user transaction, no table reloads
        vm.stopBroadcast();
        _checkSource(source);
        require(manager.entryIndex() == t.l2.length, "wrong final source cursor");
        require(address(source).balance == balance, "unexpected source value effects");
        console.log("done: source results, exact failures and cursor checked");
    }
}

contract Execute is Script, NestedRollbackGroupsRestoreStateBeforeContinuationL2Actions {
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
            "CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runNestedRollbackGroupsRestoreStateBeforeContinuation, ()))
        );
    }
}

contract VerifyNetwork is Script, NestedRollbackGroupsRestoreStateBeforeContinuationL2Actions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS destination");
    }
}

contract VerifyNetworkL2 is Script, NestedRollbackGroupsRestoreStateBeforeContinuationL2Actions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS source");
    }
}

contract ComputeExpected is ComputeExpectedBase, NestedRollbackGroupsRestoreStateBeforeContinuationL2Actions {
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
            if (i > 0 && i < 4) eventless = _append(eventless, vm.toString(_entryHash(t.l2[i])));
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
