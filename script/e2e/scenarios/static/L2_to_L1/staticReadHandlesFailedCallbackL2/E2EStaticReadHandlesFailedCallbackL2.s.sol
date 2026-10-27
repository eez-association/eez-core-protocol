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

// L2 -> L1: ask for a value
//   L1 -> L2: ask for the price
//   L2: reverts with PriceUnavailable(0)
// L1: catches the error and returns 777 ("value unknown" in this test).
// Final: the user records 777; both values remain 0.
// Explicit selection only until validated on the live network.

abstract contract StaticReadHandlesFailedCallbackL2Actions is CallPatternHelpers {
    function _tables(address actorL1, address actorL2) internal view returns (L2OriginTables memory t) {
        L1EntryBuilder memory h = _newL1Entry(actorL1, actorL2);
        t.statics = new L2Static[](0);
        bytes memory data = _valuation(true);
        bytes32 fire = _beginL1Call(h, data, true, 0);
        _expectedL1ToL2Call(h, _price(), true, fire, new L2ToL1Call[](0), 0, false, _priceUnavailable());
        _endL1Call(h, true, _result(777));
        t.l2 = new L2Entry[](0);
        t.statics = new L2Static[](1);
        t.statics[0] = _l2StaticEntry(
            actorL1,
            actorL2,
            data,
            0,
            _l2Callback(actorL1, actorL2, _price(), true),
            RH.appendStatic(0, false, _priceUnavailable()),
            true,
            _result(777)
        );
        _finishL1Entry(h, t);
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1, "source transaction did not finish");
        require(source.total() == 0, "source callback state");
        require(source.firstRead() == 777 && source.failure().length == 0, "handled read failure");
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

contract DeployConfigure is Script, E2ERollupConfig {
    function run() external {
        vm.startBroadcast();
        Actor(vm.envAddress("ACTOR_L1"))
            .configure(getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), vm.envAddress("ACTOR_L2"), _e2eRollupId()));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is Script, StaticReadHandlesFailedCallbackL2Actions {
    function run() external {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        Actor source = Actor(vm.envAddress("ACTOR_L2"));
        uint256 balance = address(source).balance;
        vm.startBroadcast();
        manager.loadExecutionTable(t.l2, t.statics);
        source.runStaticReadHandlesFailedCallback();
        vm.stopBroadcast();
        _checkSource(source);
        require(manager.entryIndex() == t.l2.length, "wrong source position after execution");
        require(address(source).balance == balance, "unexpected value effects");
        console.log("done: source result and position checked");
    }
}

contract Execute is Script, StaticReadHandlesFailedCallbackL2Actions {
    function run() external {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        (,, uint256 balance) = manager.rollups(_e2eRollupId());
        ProofSystemBatchPerVerificationEntries memory batch =
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), _e2eRollupId(), t.l1, noStaticEntries());
        batch.callData = vm.envBytes("RLP_ENCODED_TX");
        vm.startBroadcast();
        manager.postAndVerifyBatch(batch);
        vm.stopBroadcast();
        _checkDestination(Actor(vm.envAddress("ACTOR_L1")));
        (, bytes32 root, uint256 afterBalance) = manager.rollups(_e2eRollupId());
        require(root == t.l1[0].rollupUpdates[0].newRoot, "wrong final root");
        require(balance == afterBalance, "unexpected ether delta");
        console.log("done: real destination result checked");
    }
}

contract ExecuteNetworkL2 is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("ACTOR_L2"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runStaticReadHandlesFailedCallback, ())));
    }
}

contract VerifyNetwork is Script, StaticReadHandlesFailedCallbackL2Actions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS destination");
    }
}

contract VerifyNetworkL2 is Script, StaticReadHandlesFailedCallbackL2Actions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS source");
    }
}

contract ComputeExpected is ComputeExpectedBase, StaticReadHandlesFailedCallbackL2Actions {
    function run() external view {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(t.l1[0])));
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _printL2Table(t.l2);
        _printL2StaticTable(t.statics);
        string memory hashes;
        for (uint256 i; i < t.l2.length; i++) {
            hashes = string.concat(hashes, i == 0 ? "" : ",", vm.toString(_entryHash(t.l2[i])));
        }
        console.log("EXPECTED_L2_HASHES=[%s]", hashes);
        _printL2CallHashes(t.l2);
        console.log("EVENTLESS_L2_HASHES=[]");
    }
}
