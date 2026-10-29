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

// E2E_EXCLUDE_FROM_ALL: testnet/devnet fee quote rejects this top-level retry; explicit runs only.
// One L1 user transaction; both cross-chain calls are top-level:
// alice -> Caller(L1).execute()
//   ├─ try this.callThenRevert()
//   │    ├─ target.increment() -> Counter(L2), returns 1
//   │    └─ revert LocalFrameReverted(1) on L1
//   ├─ catch the exact local error
//   └─ target.increment() -> 1; this consumption commits
// L1: one prepared row is consumed twice; the first consumption is rolled back.
// L2: one delivery for the retry; Counter.counter == 1.
// No L2-to-L1 callbacks: l2ToL1Calls and expectedL1ToL2Calls are empty.

uint64 constant MAINNET_ROLLUP_ID = 0;

contract Counter {
    uint256 public counter;

    function increment() external returns (uint256) {
        return ++counter;
    }
}

contract LocalCounterRevertAndRetryCaller {
    error LocalFrameReverted(uint256 result);

    Counter public immutable target;
    bool public caught;
    uint256 public lastResult;

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
        lastResult = target.increment();
        require(lastResult == 1, "retry must see counter at zero");
    }

    function callThenRevert() external {
        require(msg.sender == address(this), "self only");
        uint256 result = target.increment();
        revert LocalFrameReverted(result);
    }
}

abstract contract LocalCounterRevertAndRetryActions {
    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeCall(Counter.increment, ());
    }

    function _callHash(address counterL2, address callerL1) internal view returns (bytes32) {
        return crossChainCallHash(false, callerL1, MAINNET_ROLLUP_ID, counterL2, e2eRollupId(), 0, _incrementData());
    }

    function _l1Entries(address counterL2, address callerL1) internal view returns (ExecutionEntry[] memory entries) {
        RollupUpdate[] memory updates = new RollupUpdate[](1);
        updates[0] = RollupUpdate({
            rollupId: e2eRollupId(),
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
        LocalCounterRevertAndRetryCaller caller = LocalCounterRevertAndRetryCaller(callerL1);
        require(caller.caught(), "missing local revert");
        require(caller.lastResult() == 1, "wrong retry result");
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counter = new Counter();
        output("COUNTER_L2", address(counter));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(address(manager)), vm.envAddress("COUNTER_L2"), e2eRollupId());
        LocalCounterRevertAndRetryCaller caller = new LocalCounterRevertAndRetryCaller(Counter(proxy));
        output("COUNTER_PROXY", proxy);
        output("CALLER_L1", address(caller));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is Script, LocalCounterRevertAndRetryActions {
    function run() external {
        address counter = vm.envAddress("COUNTER_L2");
        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2"))
            .executeIncomingCrossChainCall(_l2Entries(counter, vm.envAddress("CALLER_L1")), noL2StaticEntries());
        vm.stopBroadcast();
        require(Counter(counter).counter() == 1, "only the retry is delivered");
        console.log("done: L2 counter=1");
    }
}

contract Execute is Script, LocalCounterRevertAndRetryActions {
    function run() external {
        address caller = vm.envAddress("CALLER_L1");
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        ExecutionEntry[] memory entries = _l1Entries(vm.envAddress("COUNTER_L2"), caller);
        vm.startBroadcast();
        manager.postAndVerifyBatch(
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), e2eRollupId(), entries, noStaticEntries())
        );
        LocalCounterRevertAndRetryCaller(caller).execute();
        vm.stopBroadcast();

        _checkCaller(caller);
        (, bytes32 root,) = manager.rollups(e2eRollupId());
        require(root == entries[0].rollupUpdates[0].newRoot, "retry root not committed");
        require(manager.entryQueueIndex(e2eRollupId()) == 1, "wrong surviving consumption count");
        console.log("done: one retry committed");
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("CALLER_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(LocalCounterRevertAndRetryCaller.execute, ())));
    }
}

contract VerifyNetwork is Script, LocalCounterRevertAndRetryActions {
    function run() external view {
        _checkCaller(vm.envAddress("CALLER_L1"));
        console.log("VERIFY_PASS L1 local revert and exact first result; retry=true");
    }
}

contract VerifyNetworkL2 is Script {
    function run() external view {
        require(Counter(vm.envAddress("COUNTER_L2")).counter() == 1, "wrong L2 counter");
        console.log("VERIFY_PASS L2 counter=1");
    }
}

contract ComputeExpected is ComputeExpectedBase, LocalCounterRevertAndRetryActions {
    function run() external view {
        address counter = vm.envAddress("COUNTER_L2");
        address caller = vm.envAddress("CALLER_L1");
        ExecutionEntry[] memory l1 = _l1Entries(counter, caller);
        HashStep[][] memory steps = new HashStep[][](1);
        steps[0] = new HashStep[](0);
        L2Entry[] memory l2 = _l2Entries(counter, caller);
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        _printL1CallHashes(l1);
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        _printL2CallHashes(l2);
        _printL2Table(l2);
        _printL1Steps(l1, steps);
        _printL1Table(l1);
    }
}
