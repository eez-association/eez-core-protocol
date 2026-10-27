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

// L1 -> L2: read (returns 2)
//   L2 -> L1: read (returns 1)
//     L1 -> L2: read the stored value (returns 0)
// Final: the user records 2. Neither value changes.
// One read request is enough: its callback makes another read.
// The actual L2 result is checked in setup; neither read has an L2 delivery.
// Explicit selection only until validated on the live network.

abstract contract StaticReadCallsBackAndReadsAgainActions is CallPatternHelpers {
    struct ScenarioTables {
        ExecutionEntry[] l1;
        L2Entry[] l2;
        StaticExecutionEntry[] statics;
        HashStep[][] steps;
    }

    function _tables(address actorL1, address actorL2) internal view returns (ScenarioTables memory t) {
        t.statics = new StaticExecutionEntry[](0);
        t.l1 = new ExecutionEntry[](0);
        t.l2 = new L2Entry[](0);
        t.steps = new HashStep[][](0);
        ExpectedRootPerRollup[] memory pins = new ExpectedRootPerRollup[](1);
        pins[0] = ExpectedRootPerRollup(_e2eRollupId(), keccak256("l2-initial-state"));
        // The callback's outgoing read also occurs outside mutable execution.
        // It needs a separate top-level static entry, not a nested row.
        t.statics = new StaticExecutionEntry[](2);
        t.statics[0] = StaticExecutionEntry(
            pins,
            _l1ToL2CallHash(actorL1, actorL2, _read(2), true),
            _l1Callback(actorL1, actorL2, _read(1), true),
            RH.appendStatic(0, true, _result(1)),
            _e2eRollupId(),
            true,
            _result(2)
        );
        t.statics[1] = StaticExecutionEntry(
            pins,
            _l1ToL2CallHash(actorL1, actorL2, _read(0), true),
            new L2ToL1Call[](0),
            0,
            _e2eRollupId(),
            true,
            _result(0)
        );
    }

    function _checkSource(Actor source) internal view {
        require(source.completed() == 1 && source.total() == 0, "source completion/rollback");
        require(source.firstRead() == 2, "read callback's own read");
    }

    function _checkDestination(Actor destination) internal view {
        require(destination.completed() == 0 && destination.total() == 0, "destination state");
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        output("ACTOR_L1", address(new Actor()));
        vm.stopBroadcast();
    }
}

contract DeployL2 is Script, StaticReadCallsBackAndReadsAgainActions {
    function run() external {
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        require(!manager.USE_GAS_LEFT(), "scenario requires gas-independent keys");
        vm.startBroadcast();
        Actor actor = new Actor();
        actor.configure(getOrCreateProxy(IEEZ(address(manager)), vm.envAddress("ACTOR_L1"), 0));
        output("ACTOR_L2", address(actor));
        vm.stopBroadcast();

        // Simulate the real L2 producer; these prediction tables are never broadcast.
        uint256 snapshot = vm.snapshotState();
        L2Static[] memory prediction = new L2Static[](1);
        prediction[0] = _l2StaticEntry(
            vm.envAddress("ACTOR_L1"),
            address(actor),
            _read(1),
            0,
            _l2Callback(vm.envAddress("ACTOR_L1"), address(actor), _read(0), true),
            RH.appendStatic(0, true, _result(0)),
            true,
            _result(1)
        );
        vm.prank(manager.SYSTEM_ADDRESS());
        manager.loadExecutionTable(new L2Entry[](0), prediction);
        (bool ok, bytes memory actual) = address(actor).staticcall(_read(2));
        require(ok && keccak256(actual) == keccak256(_result(2)), "real L2 read prediction");
        require(actor.total() == 0 && manager.entryIndex() == 0, "prediction must leave no effects");
        require(vm.revertToState(snapshot), "restore prediction fork");
        output("PREDICTED_REMOTE_RESULT", actual);
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

contract Execute is Script, StaticReadCallsBackAndReadsAgainActions {
    function run() external {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        require(
            keccak256(vm.envBytes("PREDICTED_REMOTE_RESULT")) == keccak256(t.statics[0].returnData),
            "use the real producer result"
        );
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        (,, uint256 balance) = manager.rollups(_e2eRollupId());
        vm.startBroadcast();
        manager.postAndVerifyBatch(
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), _e2eRollupId(), t.l1, t.statics)
        );
        Actor(vm.envAddress("ACTOR_L1")).runStaticReadCallsBackAndReadsAgain();
        vm.stopBroadcast();
        _checkSource(Actor(vm.envAddress("ACTOR_L1")));
        (, bytes32 root, uint256 afterBalance) = manager.rollups(_e2eRollupId());
        require(root == keccak256("l2-initial-state"), "wrong final root");
        require(balance == afterBalance, "unexpected ether delta");
        console.log("done: successful L1 source transaction");
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("ACTOR_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(Actor.runStaticReadCallsBackAndReadsAgain, ())));
    }
}

contract VerifyNetwork is Script, StaticReadCallsBackAndReadsAgainActions {
    function run() external view {
        _checkSource(Actor(vm.envAddress("ACTOR_L1")));
        console.log("VERIFY_PASS source");
    }
}

contract VerifyNetworkL2 is Script, StaticReadCallsBackAndReadsAgainActions {
    function run() external view {
        _checkDestination(Actor(vm.envAddress("ACTOR_L2")));
        console.log("VERIFY_PASS destination");
    }
}

contract ComputeExpected is ComputeExpectedBase, StaticReadCallsBackAndReadsAgainActions {
    function run() external view {
        ScenarioTables memory t = _tables(vm.envAddress("ACTOR_L1"), vm.envAddress("ACTOR_L2"));
        console.log("EXPECTED_L1_HASHES=[]");
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        console.log("EXPECTED_L2_HASHES=[]");
        console.log(
            "ABSENT_L2_HASHES=[%s,%s]",
            vm.toString(t.statics[0].proxyEntryHash),
            vm.toString(t.statics[1].proxyEntryHash)
        );
        _printL1StaticTable(t.statics);
        _printL1Steps(t.l1, t.steps);
        _printL1Table(t.l1);
        _printL2Table(t.l2);
        _printL2CallHashes(t.l2);
    }
}
