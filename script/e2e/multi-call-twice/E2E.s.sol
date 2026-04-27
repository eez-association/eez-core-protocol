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
import {CallTwice} from "../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, noNestedActions, noCalls} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Multi-call scenario: same target twice
//
//  CallTwice.callCounterTwice(counterProxy) invokes increment() twice.
//  Each invocation consumes an entry sequentially — two entries with the
//  SAME actionHash but different returnData (1 and 2).
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract MultiCallActions {
    function _callAction(address counterL2, address caller) internal pure returns (Action memory) {
        return Action({
            rollupId: L2_ROLLUP_ID,
            destination: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: caller,
            sourceRollup: MAINNET_ROLLUP_ID
        });
    }

    function _l1Entries(address counterL2, address caller)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        bytes32 ah = actionHash(_callAction(counterL2, caller));

        StateDelta[] memory deltasA = new StateDelta[](1);
        deltasA[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-twice-1"),
            etherDelta: 0
        });

        StateDelta[] memory deltasB = new StateDelta[](1);
        deltasB[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-twice-2"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](2);
        entries[0] = ExecutionEntry({
            stateDeltas: deltasA,
            actionHash: ah,
            calls: noCalls(),
            nestedActions: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            failed: false,
            rollingHash: bytes32(0)
        });
        entries[1] = ExecutionEntry({
            stateDeltas: deltasB,
            actionHash: ah,
            calls: noCalls(),
            nestedActions: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(2)),
            failed: false,
            rollingHash: bytes32(0)
        });
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counter = new Counter();
        console.log("COUNTER_L2=%s", address(counter));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        Rollups rollups = Rollups(rollupsAddr);

        address counterProxy;
        try rollups.createCrossChainProxy(counterL2Addr, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2Addr, L2_ROLLUP_ID);
        }

        CallTwice caller = new CallTwice();
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("CALL_TWICE=%s", address(caller));
        vm.stopBroadcast();
    }
}

contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata statics,
        CallTwice caller,
        address counterProxy
    ) external returns (uint256 first, uint256 second) {
        rollups.postBatch(entries, statics, 0, 0, 0, "", "proof");
        (first, second) = caller.callCounterTwice(counterProxy);
    }
}

contract Execute is Script, MultiCallActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterProxy = vm.envAddress("COUNTER_PROXY");
        address callerAddr = vm.envAddress("CALL_TWICE");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        (uint256 first, uint256 second) = batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(counterL2Addr, callerAddr),
            noStaticCalls(),
            CallTwice(callerAddr),
            counterProxy
        );
        console.log("done");
        console.log("first=%s second=%s", first, second);
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address caller = vm.envAddress("CALL_TWICE");
        address counterProxy = vm.envAddress("COUNTER_PROXY");
        console.log("TARGET=%s", caller);
        console.log("VALUE=0");
        console.log(
            "CALLDATA=%s",
            vm.toString(abi.encodeWithSelector(CallTwice.callCounterTwice.selector, counterProxy))
        );
    }
}

contract ComputeExpected is ComputeExpectedBase, MultiCallActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("CALL_TWICE")) return "CallTwice";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address callerAddr = vm.envAddress("CALL_TWICE");

        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, callerAddr);
        bytes32 h0 = _entryHash(l1[0]);
        bytes32 h1 = _entryHash(l1[1]);

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(h0), vm.toString(h1));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (2 entries, same actionHash) ===");
        for (uint256 i = 0; i < l1.length; i++) {
            _logEntry(i, l1[i]);
        }
    }
}
