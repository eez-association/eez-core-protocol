// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {IEEZ, ExecutionEntry, RollupUpdate} from "../../../../../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2Entry} from "../../../../../../src/interfaces/IEEZL2.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noCalls,
    noNestedActions,
    RollingHashBuilder,
    output,
    getOrCreateProxy,
    noStaticEntries,
    immediateSingleRollupBatch,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// E2E_EXCLUDE_FROM_ALL: targeted L1 parent rollback regression; select explicitly.
// One L1 user transaction; one top-level cross-chain call:
// alice -> Caller(L1).execute()
//   ├─ try this.callThenRevert()
//   │    ├─ target.increment() -> Counter(L2), returns 1
//   │    └─ revert LocalFrameReverted(1) on L1
//   ├─ catch the exact local error
//   └─ stop after the catch
// L1: one prepared row is consumed, then its state and events are rolled back.
// L2: no delivery; Counter.counter == 0. The result is checked in a fork-only prediction.
// No L2-to-L1 callbacks: l2ToL1Calls and expectedL1ToL2Calls are empty.

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

contract Counter {
    uint256 public counter;

    function increment() external returns (uint256) {
        return ++counter;
    }
}

contract LocalCounterRevertNoRetryCaller {
    error LocalFrameReverted(uint256 result);

    Counter public immutable target;
    bool public caught;

    constructor(Counter target_) {
        target = target_;
    }

    function execute() external {
        require(!caught, "one trigger only");
        try this.callThenRevert() {
            revert("local frame unexpectedly committed");
        } catch (bytes memory reason) {
            // Missing tables or remote failures must not masquerade as our local revert.
            require(
                keccak256(reason) == keccak256(abi.encodeWithSelector(LocalFrameReverted.selector, uint256(1))),
                "wrong local revert or remote result"
            );
            caught = true;
        }
    }

    function callThenRevert() external {
        require(msg.sender == address(this), "self only");
        uint256 result = target.increment();
        revert LocalFrameReverted(result);
    }
}

abstract contract LocalCounterRevertNoRetryActions {
    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeCall(Counter.increment, ());
    }

    function _callHash(address counterL2, address callerL1) internal pure returns (bytes32) {
        return crossChainCallHash(false, callerL1, MAINNET_ROLLUP_ID, counterL2, L2_ROLLUP_ID, 0, _incrementData());
    }

    function _l1Entries(address counterL2, address callerL1) internal pure returns (ExecutionEntry[] memory entries) {
        RollupUpdate[] memory updates = new RollupUpdate[](1);
        updates[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            etherDelta: 0,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-local-counter-increment")
        });
        bytes32 key = _callHash(counterL2, callerL1);
        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: updates,
            proxyEntryHash: key,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(updates, key),
            destinationRollupId: L2_ROLLUP_ID,
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    function _checkCaller(address callerL1) internal view {
        LocalCounterRevertNoRetryCaller caller = LocalCounterRevertNoRetryCaller(callerL1);
        require(caller.caught(), "missing local revert");
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counter = new Counter();
        output("COUNTER_L2", address(counter));
        vm.stopBroadcast();
        // Fixture check: execute the actual producer for the cached return value.
        // This fork-only call is restored; it does not test delivery or settlement.
        uint256 snapshot = vm.snapshotState();
        require(counter.increment() == 1, "prediction must return one");
        require(vm.revertToState(snapshot), "restore producer prediction");
        require(counter.counter() == 0, "prediction must leave counter unchanged");
    }
}

contract Deploy is Script {
    function run() external {
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(address(manager)), vm.envAddress("COUNTER_L2"), L2_ROLLUP_ID);
        LocalCounterRevertNoRetryCaller caller = new LocalCounterRevertNoRetryCaller(Counter(proxy));
        output("COUNTER_PROXY", proxy);
        output("CALLER_L1", address(caller));
        vm.stopBroadcast();
    }
}

// No ExecuteL2: the erased call must never be delivered.

contract Execute is Script, LocalCounterRevertNoRetryActions {
    function run() external {
        address caller = vm.envAddress("CALLER_L1");
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        ExecutionEntry[] memory entries = _l1Entries(vm.envAddress("COUNTER_L2"), caller);
        vm.startBroadcast();
        manager.postAndVerifyBatch(
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), L2_ROLLUP_ID, entries, noStaticEntries())
        );
        LocalCounterRevertNoRetryCaller(caller).execute();
        vm.stopBroadcast();

        _checkCaller(caller);
        (, bytes32 root,) = manager.rollups(L2_ROLLUP_ID);
        require(root == entries[0].rollupUpdates[0].currentRoot, "local revert must restore root");
        require(manager.entryQueueIndex(L2_ROLLUP_ID) == 0, "wrong surviving consumption count");
        console.log("done: local frame reverted without retry");
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("CALLER_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(LocalCounterRevertNoRetryCaller.execute, ())));
    }
}

contract VerifyNetwork is Script, LocalCounterRevertNoRetryActions {
    function run() external view {
        _checkCaller(vm.envAddress("CALLER_L1"));
        console.log("VERIFY_PASS L1 local revert and exact first result; retry=false");
    }
}

contract VerifyNetworkL2 is Script {
    function run() external view {
        require(Counter(vm.envAddress("COUNTER_L2")).counter() == 0, "wrong L2 counter");
        console.log("VERIFY_PASS L2 counter=0");
    }
}

contract ComputeExpected is ComputeExpectedBase, LocalCounterRevertNoRetryActions {
    function run() external view {
        address counter = vm.envAddress("COUNTER_L2");
        address caller = vm.envAddress("CALLER_L1");
        ExecutionEntry[] memory l1 = _l1Entries(counter, caller);
        HashStep[][] memory steps = new HashStep[][](1);
        steps[0] = new HashStep[](0);
        // The successful counter call is erased by its L1 parent. Keep its posted
        // table expectation, require no surviving L1 events, and assert L2 nondelivery.
        console.log("EXPECTED_L1_HASHES=[]");
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("EXPECTED_L2_CALL_HASHES=[]");
        console.log("EVENTLESS_L1_CALL_HASHES=[\"%s\"]", vm.toString(l1[0].proxyEntryHash));
        console.log("ABSENT_L2_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));
        _printL2Table(new L2Entry[](0));
        _printL1Steps(l1, steps);
        _printL1Table(l1);
    }
}
