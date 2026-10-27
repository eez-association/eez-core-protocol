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

// The user starts on L2. Both stored values stay at 0 throughout.
//
// L2 -> L1: ask for a value, allowing L1 to handle an unavailable price
//   L1 -> L2: ask for the price
//   L2: reverts with PriceUnavailable(0)
// L1: catches the error and returns 777 ("value unknown" in this test)
// L2: records 777.
//
// L2 -> L1: ask again, this time without handling the error on L1
//   L1 -> L2: ask for the price
//   L2: reverts with PriceUnavailable(0)
// L1: passes the same error back
// L2: catches the error and continues.
//
// Final result: first answer = 777; second answer = the exact original error.
// All contracts needed for these calls already exist. A setup failure must not
// be mistaken for the application's unavailable-price error.
// Included in default/all runs; live composer failures remain failures.

abstract contract StaticReadCatchesCallbackRevertAndChecksUncaughtPropagationL2Actions is CallPatternHelpers {
    function _tables(address actorL1, address actorL2) internal view returns (L2OriginTables memory t) {
        L1EntryBuilder memory h = _newL1Entry(actorL1, actorL2);
        t.statics = new L2Static[](0);
        t.l2 = new L2Entry[](0);
        t.statics = new L2Static[](2);
        for (uint256 i; i < 2; i++) {
            bool caught = i == 0;
            bytes memory data = _valuation(caught);
            bytes memory answer = caught ? _result(777) : _priceUnavailable();
            bytes32 fire = _beginL1Call(h, data, true, 0);
            _expectedL1ToL2Call(h, _price(), true, fire, new L2ToL1Call[](0), 0, false, _priceUnavailable());
            _endL1Call(h, caught, answer);
            t.statics[i] = _l2StaticEntry(
                h.a1,
                h.a2,
                data,
                0,
                _l2Callback(h.a1, h.a2, _price(), true),
                RH.appendStatic(0, false, _priceUnavailable()),
                caught,
                answer
            );
        }

        _finishL1Entry(h, t);
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1, "source transaction did not finish");
        require(source.total() == 0, "source rollback state");
        require(source.firstRead() == 777, "handled failure result");
        require(keccak256(source.failure()) == keccak256(_priceUnavailable()), "propagated failure bytes");
    }

    function _checkDestination(Actor destination) internal view {
        require(destination.total() == 0, "destination state/rollback");
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

contract ExecuteL2 is Script, StaticReadCatchesCallbackRevertAndChecksUncaughtPropagationL2Actions {
    function run() external {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        Actor source = Actor(vm.envAddress("ACTOR_L2"));
        uint256 balance = address(source).balance;
        vm.startBroadcast();
        manager.loadExecutionTable(t.l2, t.statics);
        source.runStaticReadCatchesCallbackRevertAndChecksUncaughtPropagation(); // exactly ONE user transaction, no table reloads
        vm.stopBroadcast();
        _checkSource(source);
        require(manager.entryIndex() == t.l2.length, "wrong final source cursor");
        require(address(source).balance == balance, "unexpected source value effects");
        console.log("done: source results, exact failures and cursor checked");
    }
}

contract Execute is Script, StaticReadCatchesCallbackRevertAndChecksUncaughtPropagationL2Actions {
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
            "CALLDATA=%s",
            vm.toString(abi.encodeCall(Actor.runStaticReadCatchesCallbackRevertAndChecksUncaughtPropagation, ()))
        );
    }
}

contract VerifyNetwork is Script, StaticReadCatchesCallbackRevertAndChecksUncaughtPropagationL2Actions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS destination");
    }
}

contract VerifyNetworkL2 is Script, StaticReadCatchesCallbackRevertAndChecksUncaughtPropagationL2Actions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS source");
    }
}

contract ComputeExpected is ComputeExpectedBase, StaticReadCatchesCallbackRevertAndChecksUncaughtPropagationL2Actions {
    function run() external view {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(t.l1[0])));
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _printL2Table(t.l2);
        _printL2StaticTable(t.statics);
        // L2 only resolves static reads: no mutable table or consumption events.
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("EXPECTED_L2_CALL_HASHES=[]");
        console.log("EVENTLESS_L2_HASHES=[]");
    }
}
