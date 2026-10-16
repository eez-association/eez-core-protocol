// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

// L2 -> L1: read (returns 0)
// L2 -> L1: add 100
// L1: reverts with FrameFailed(0)
// L2: catches that exact error and finishes successfully.
// Final: both values remain 0. The failed write has no callback,
// isolating a read mixed with a failed root call.
// Explicit selection only until validated on the live network.

abstract contract StaticReadThenCatchFailedWriteL2Actions is CallPatternHelpers {
    function _tables(address actorL1, address actorL2) internal pure returns (L2OriginTables memory t) {
        L1EntryBuilder memory h = _newL1Entry(actorL1, actorL2);
        t.statics = new L2Static[](0);
        _successfulL1Call(h, _read(0), true, 0, 0);
        bytes memory data = abi.encodeCall(Actor.failAfterWrite, ());
        _beginL1Call(h, data, false, 0);
        _endL1Call(h, false, _frameFailure(0));
        t.l2 = new L2Entry[](1);
        t.l2[0] = _l2SourceEntry(actorL1, actorL2, data, false, _frameFailure(0), "", false, true, "");
        t.statics = new L2Static[](1);
        t.statics[0] = _l2StaticEntry(actorL1, actorL2, _read(0), 0, new CrossChainCall[](0), 0, true, _result(0));
        _finishL1Entry(h, t);
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1, "source transaction did not finish");
        require(source.total() == 0, "source callback state");
        require(
            source.firstRead() == 0 && keccak256(source.failure()) == keccak256(_frameFailure(0)),
            "read then failed write"
        );
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

contract ExecuteL2 is Script, StaticReadThenCatchFailedWriteL2Actions {
    function run() external {
        L2OriginTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        Actor source = Actor(vm.envAddress("ACTOR_L2"));
        uint256 balance = address(source).balance;
        vm.startBroadcast();
        manager.loadExecutionTable(t.l2, t.statics);
        source.runStaticReadThenCatchFailedWrite();
        vm.stopBroadcast();
        _checkSource(source);
        require(manager.entryIndex() == 0, "wrong source position after execution");
        require(address(source).balance == balance, "unexpected value effects");
        console.log("done: source result and position checked");
    }
}

contract Execute is Script, StaticReadThenCatchFailedWriteL2Actions {
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
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runStaticReadThenCatchFailedWrite, ())));
    }
}

contract VerifyNetwork is Script, StaticReadThenCatchFailedWriteL2Actions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS destination");
    }
}

contract VerifyNetworkL2 is Script, StaticReadThenCatchFailedWriteL2Actions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS source");
    }
}

contract ComputeExpected is ComputeExpectedBase, StaticReadThenCatchFailedWriteL2Actions {
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
        console.log("EXPECTED_L2_CALL_HASHES=[]");
        // Failed entries are already eventless; no successful-entry exemption applies.
        console.log("EVENTLESS_L2_HASHES=[]");
    }
}
