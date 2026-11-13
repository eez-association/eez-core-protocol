// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {e2eRollupId} from "../../../shared/E2EHelpers.sol";

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {IEEZ, ExecutionEntry, RollupUpdate} from "../../../../../../src/interfaces/IEEZ.sol";
import {EEZL2} from "../../../../../../src/L2/EEZL2.sol";
import {ExecutionEntry as L2Entry, CrossChainCall} from "../../../../../../src/interfaces/IEEZL2.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noCalls,
    noNestedActions,
    noL2OutgoingCalls,
    RollingHashBuilder,
    output,
    getOrCreateProxy,
    noStaticEntries,
    noL2StaticEntries,
    immediateSingleRollupBatch,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// One L1 user transaction; two distinct top-level cross-chain calls:
// alice -> Caller(L1).execute()
//   |-- try this.callThenRevert()
//   |     |-- erasedTarget.increment() -> Counter A(L2), returns 1
//   |     `-- revert LocalFrameReverted(1) on L1
//   |-- catch the exact local error and persist caught=true
//   `-- committedTarget.increment() -> Counter B(L2), returns 1; commits
// L1: row A temporarily advances R0 -> RA, then rolls back to R0 and cursor 0.
//     Row B skips A's different identity, commits R0 -> RB, leaves cursor 2.
//     Only B has surviving consumption/completion events.
// L2: SYSTEM -> executeIncomingCrossChainCall([B]) -> Counter B.increment() -> 1.
//     No delivery/table/event for A. Final counters: A=0, B=1.
// A's cached result comes from a restored fork-only producer call during setup.
// No L2-to-L1 callbacks. This is a different second call, not an identical retry.

uint64 constant MAINNET_ROLLUP_ID = 0;

contract Counter {
    uint256 public counter;

    function increment() external returns (uint256) {
        return ++counter;
    }
}

contract LocalCounterRevertThenOtherCallCaller {
    error LocalFrameReverted(uint256 result);

    Counter public immutable erasedTarget;
    Counter public immutable committedTarget;
    bool public caught;
    uint256 public lastResult;

    constructor(Counter erasedTarget_, Counter committedTarget_) {
        require(address(erasedTarget_) != address(committedTarget_), "distinct targets required");
        erasedTarget = erasedTarget_;
        committedTarget = committedTarget_;
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
        lastResult = committedTarget.increment();
        require(lastResult == 1, "wrong second call result");
    }

    function callThenRevert() external {
        require(msg.sender == address(this), "self only");
        uint256 result = erasedTarget.increment();
        revert LocalFrameReverted(result);
    }
}

abstract contract LocalCounterRevertThenOtherCallActions is Script {
    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeCall(Counter.increment, ());
    }

    function _callHash(address counterL2, address callerL1) internal view returns (bytes32) {
        return crossChainCallHash(false, callerL1, MAINNET_ROLLUP_ID, counterL2, e2eRollupId(), 0, _incrementData());
    }

    function _l1Entries(
        address erasedCounter,
        address committedCounter,
        address caller
    )
        internal
        view
        returns (ExecutionEntry[] memory entries)
    {
        require(erasedCounter != committedCounter, "distinct call keys required");
        entries = new ExecutionEntry[](2);
        entries[0] = _l1Entry(erasedCounter, caller, keccak256("l2-erased-counter-increment"));
        entries[1] = _l1Entry(committedCounter, caller, keccak256("l2-committed-counter-increment"));
    }

    function _l1Entry(address counter, address caller, bytes32 newRoot) internal view returns (ExecutionEntry memory) {
        RollupUpdate[] memory updates = new RollupUpdate[](1);
        // Both calls start from R0: A's temporary root update is erased before B.
        updates[0] = RollupUpdate({
            rollupId: e2eRollupId(), etherDelta: 0, currentRoot: keccak256("l2-initial-state"), newRoot: newRoot
        });
        bytes32 key = _callHash(counter, caller);
        return ExecutionEntry({
            rollupUpdates: updates,
            proxyEntryHash: key,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(updates, key),
            destinationRollupId: e2eRollupId(),
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    function _l2Entries(address counterL2, address callerL1) internal view returns (L2Entry[] memory entries) {
        bytes32 key = _callHash(counterL2, callerL1);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            gas: 0,
            sourceAddress: callerL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: _incrementData()
        });
        bytes32 rh = RollingHashBuilder.entryBeginL2(key);
        rh = RollingHashBuilder.appendCallBegin(rh, key);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));
        entries = new L2Entry[](1);
        entries[0] = L2Entry({
            proxyEntryHash: key,
            incomingCalls: calls,
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    function _checkCaller(address callerL1) internal view {
        LocalCounterRevertThenOtherCallCaller caller = LocalCounterRevertThenOtherCallCaller(callerL1);
        require(caller.caught(), "missing local revert");
        require(caller.lastResult() == 1, "wrong second call result");
    }

    function _checkCounters() internal view {
        require(Counter(vm.envAddress("ERASED_COUNTER_L2")).counter() == 0, "erased call reached L2");
        require(Counter(vm.envAddress("COMMITTED_COUNTER_L2")).counter() == 1, "second call not delivered exactly once");
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter erased = new Counter();
        Counter committed = new Counter();
        output("ERASED_COUNTER_L2", address(erased));
        output("COMMITTED_COUNTER_L2", address(committed));
        vm.stopBroadcast();

        // Fixture-only prediction: execute A's real producer and restore its state.
        // This does not broadcast a delivery or establish live settlement.
        uint256 snapshot = vm.snapshotState();
        require(erased.increment() == 1, "prediction must return one");
        require(vm.revertToState(snapshot), "restore producer prediction");
        require(erased.counter() == 0 && committed.counter() == 0, "prediction changed counters");
    }
}

contract Deploy is Script {
    function run() external {
        IEEZ manager = IEEZ(vm.envAddress("ROLLUPS"));
        vm.startBroadcast();
        address erasedProxy = getOrCreateProxy(manager, vm.envAddress("ERASED_COUNTER_L2"), e2eRollupId());
        address committedProxy = getOrCreateProxy(manager, vm.envAddress("COMMITTED_COUNTER_L2"), e2eRollupId());
        LocalCounterRevertThenOtherCallCaller caller =
            new LocalCounterRevertThenOtherCallCaller(Counter(erasedProxy), Counter(committedProxy));
        output("CALLER_L1", address(caller));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is LocalCounterRevertThenOtherCallActions {
    function run() external {
        address counter = vm.envAddress("COMMITTED_COUNTER_L2");
        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2"))
            .executeIncomingCrossChainCall(_l2Entries(counter, vm.envAddress("CALLER_L1")), noL2StaticEntries());
        vm.stopBroadcast();
        _checkCounters();
        require(EEZL2(vm.envAddress("MANAGER_L2")).entryIndex() == 1, "wrong L2 delivery cursor");
        console.log("done: erased counter=0, committed counter=1");
    }
}

contract Execute is LocalCounterRevertThenOtherCallActions {
    function run() external {
        address caller = vm.envAddress("CALLER_L1");
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        ExecutionEntry[] memory entries =
            _l1Entries(vm.envAddress("ERASED_COUNTER_L2"), vm.envAddress("COMMITTED_COUNTER_L2"), caller);
        vm.startBroadcast();
        manager.postAndVerifyBatch(
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), e2eRollupId(), entries, noStaticEntries())
        );
        LocalCounterRevertThenOtherCallCaller(caller).execute();
        vm.stopBroadcast();

        _checkCaller(caller);
        (, bytes32 root,) = manager.rollups(e2eRollupId());
        require(root == entries[1].rollupUpdates[0].newRoot, "second call root not committed");
        // The cursor is a row index: B consumes row 1 after skipping erased row 0.
        require(manager.entryQueueIndex(e2eRollupId()) == 2, "wrong L1 queue cursor");
        console.log("done: first call erased, different second call committed");
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("CALLER_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(LocalCounterRevertThenOtherCallCaller.execute, ())));
    }
}

contract VerifyNetwork is LocalCounterRevertThenOtherCallActions {
    function run() external view {
        _checkCaller(vm.envAddress("CALLER_L1"));
        console.log("VERIFY_PASS L1 exact erased result and committed second result");
    }
}

contract VerifyNetworkL2 is LocalCounterRevertThenOtherCallActions {
    function run() external view {
        _checkCounters();
        console.log("VERIFY_PASS L2 erased counter=0, committed counter=1");
    }
}

contract ComputeExpected is ComputeExpectedBase, LocalCounterRevertThenOtherCallActions {
    function run() external view {
        address caller = vm.envAddress("CALLER_L1");
        address committedCounter = vm.envAddress("COMMITTED_COUNTER_L2");
        ExecutionEntry[] memory l1 = _l1Entries(vm.envAddress("ERASED_COUNTER_L2"), committedCounter, caller);
        L2Entry[] memory l2 = _l2Entries(committedCounter, caller);
        HashStep[][] memory steps = new HashStep[][](2);
        steps[0] = new HashStep[](0);
        steps[1] = new HashStep[](0);

        // Only B survives at the event level. Both posted L1 rows remain required;
        // A is pinned by exact persisted trigger evidence and explicit nondelivery.
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[1])));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1[1].proxyEntryHash));
        console.log("EVENTLESS_L1_CALL_HASHES=[\"%s\"]", vm.toString(l1[0].proxyEntryHash));
        console.log("ABSENT_L2_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        _printL2CallHashes(l2);
        _printL1Steps(l1, steps);
        _printL1Table(l1);
        _printL2Table(l2);
        _printL1StaticTable(noStaticEntries());
        _printL2StaticTable(noL2StaticEntries());
    }
}
