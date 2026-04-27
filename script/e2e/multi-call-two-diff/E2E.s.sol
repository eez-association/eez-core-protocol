// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {
    Action,
    StateDelta,
    CrossChainCall,
    NestedAction,
    ExecutionEntry,
    StaticCall
} from "../../../src/ICrossChainManager.sol";
import {Counter} from "../../../test/mocks/CounterContracts.sol";
import {CallTwoDifferent} from "../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, noNestedActions, noCalls} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Multi-call scenario: two different targets
//
//  CallTwoDifferent.callBothCounters(proxyA, proxyB) invokes increment()
//  on two DIFFERENT L2 Counter proxies. Two entries with DIFFERENT
//  actionHashes — still consumed sequentially.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract TwoDiffActions {
    function _callAction(address target, address caller) internal pure returns (Action memory) {
        return Action({
            rollupId: L2_ROLLUP_ID,
            destination: target,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: caller,
            sourceRollup: MAINNET_ROLLUP_ID
        });
    }

    function _l1Entries(address counterA, address counterB, address caller)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        bytes32 hA = actionHash(_callAction(counterA, caller));
        bytes32 hB = actionHash(_callAction(counterB, caller));

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-two-diff-1"),
            etherDelta: 0
        });

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-two-diff-2"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](2);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas1,
            actionHash: hA,
            calls: noCalls(),
            nestedActions: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            failed: false,
            rollingHash: bytes32(0)
        });
        entries[1] = ExecutionEntry({
            stateDeltas: deltas2,
            actionHash: hB,
            calls: noCalls(),
            nestedActions: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            failed: false,
            rollingHash: bytes32(0)
        });
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterA = new Counter();
        Counter counterB = new Counter();
        console.log("COUNTER_A_L2=%s", address(counterA));
        console.log("COUNTER_B_L2=%s", address(counterB));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterA = vm.envAddress("COUNTER_A_L2");
        address counterB = vm.envAddress("COUNTER_B_L2");

        vm.startBroadcast();
        Rollups rollups = Rollups(rollupsAddr);

        address proxyA;
        try rollups.createCrossChainProxy(counterA, L2_ROLLUP_ID) returns (address p) { proxyA = p; }
        catch { proxyA = rollups.computeCrossChainProxyAddress(counterA, L2_ROLLUP_ID); }

        address proxyB;
        try rollups.createCrossChainProxy(counterB, L2_ROLLUP_ID) returns (address p) { proxyB = p; }
        catch { proxyB = rollups.computeCrossChainProxyAddress(counterB, L2_ROLLUP_ID); }

        CallTwoDifferent caller = new CallTwoDifferent();
        console.log("PROXY_A=%s", proxyA);
        console.log("PROXY_B=%s", proxyB);
        console.log("CALL_TWO_DIFF=%s", address(caller));
        vm.stopBroadcast();
    }
}

contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata statics,
        CallTwoDifferent caller,
        address pA,
        address pB
    ) external returns (uint256 a, uint256 b) {
        rollups.postBatch(entries, statics, 0, 0, 0, "", "proof");
        (a, b) = caller.callBothCounters(pA, pB);
    }
}

contract Execute is Script, TwoDiffActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterA = vm.envAddress("COUNTER_A_L2");
        address counterB = vm.envAddress("COUNTER_B_L2");
        address proxyA = vm.envAddress("PROXY_A");
        address proxyB = vm.envAddress("PROXY_B");
        address callerAddr = vm.envAddress("CALL_TWO_DIFF");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        (uint256 a, uint256 b) = batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(counterA, counterB, callerAddr),
            noStaticCalls(),
            CallTwoDifferent(callerAddr),
            proxyA,
            proxyB
        );
        console.log("done");
        console.log("a=%s b=%s", a, b);
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address caller = vm.envAddress("CALL_TWO_DIFF");
        address proxyA = vm.envAddress("PROXY_A");
        address proxyB = vm.envAddress("PROXY_B");
        console.log("TARGET=%s", caller);
        console.log("VALUE=0");
        console.log(
            "CALLDATA=%s",
            vm.toString(abi.encodeWithSelector(CallTwoDifferent.callBothCounters.selector, proxyA, proxyB))
        );
    }
}

contract ComputeExpected is ComputeExpectedBase, TwoDiffActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_A_L2")) return "CounterA";
        if (a == vm.envAddress("COUNTER_B_L2")) return "CounterB";
        if (a == vm.envAddress("CALL_TWO_DIFF")) return "CallTwoDiff";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterA = vm.envAddress("COUNTER_A_L2");
        address counterB = vm.envAddress("COUNTER_B_L2");
        address callerAddr = vm.envAddress("CALL_TWO_DIFF");

        ExecutionEntry[] memory l1 = _l1Entries(counterA, counterB, callerAddr);
        bytes32 h0 = _entryHash(l1[0]);
        bytes32 h1 = _entryHash(l1[1]);

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(h0), vm.toString(h1));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (2 entries, different actionHashes) ===");
        for (uint256 i = 0; i < l1.length; i++) {
            _logEntry(i, l1[i]);
        }
    }
}
