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
import {Counter, CounterAndProxy, NestedCaller} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  DeepNested scenario - two levels of nested actions
//
//  Chain of events (on L1):
//    1. Alice triggers entry via nestedCallerProxy
//    2. Entry's calls[0] invokes NestedCaller.callNested()
//    3. NestedCaller calls cap.incrementProxy() -> nestedActions[0]
//       - nestedActions[0] has callCount=1 which triggers _processNCalls(1)
//       - Inside that, CAP calls counterProxy -> nestedActions[1]
//    4. Both nested actions consumed, deep rolling hash verified
//
//  Rolling hash tape:
//    CALL_BEGIN(1)
//      NESTED_BEGIN(1)           <- NestedCaller -> CAP proxy
//        CALL_BEGIN(2)           <- nestedActions[0].callCount=1
//          NESTED_BEGIN(2)       <- CAP -> Counter proxy
//          NESTED_END(2)
//        CALL_END(2, true, "")
//      NESTED_END(1)
//    CALL_END(1, true, "")
//
//  Replaces deepScopeL2 from main (scope arrays don't exist in flatten).
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract DeepNestedActions {
    using RollingHashBuilder for bytes32;

    /// @dev innermost: CAP calls counterProxy -> increment()
    function _counterActionHash(address counterL2, address cap) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: cap,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev middle: NestedCaller calls capProxy -> incrementProxy()
    function _capActionHash(address cap, address nestedCaller) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: nestedCaller,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev outer trigger: alice calls nestedCallerProxy -> callNested()
    function _outerActionHash(address nestedCaller, address alice) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: nestedCaller,
            value: 0,
            data: abi.encodeWithSelector(NestedCaller.callNested.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);        // calls[0] -> NestedCaller.callNested()  (_ccn=1)
        h = h.appendNestedBegin(1);       // NestedCaller -> capProxy -> nestedActions[0]
        h = h.appendCallBegin(2);         // calls[1] inside nested (_ccn=2)
        h = h.appendNestedBegin(2);       // CAP -> counterProxy -> nestedActions[1]
        h = h.appendNestedEnd(2);
        h = h.appendCallEnd(2, true, ""); // calls[1] ends (_ccn=2)
        h = h.appendNestedEnd(1);
        // _currentCallNumber is now 2 (advanced by nested), so outer CALL_END uses 2
        h = h.appendCallEnd(2, true, ""); // calls[0] ends (_ccn still 2)
    }

    function _l1Entries(
        address counterL2,
        address cap,
        address nestedCaller,
        address alice
    ) internal pure returns (ExecutionEntry[] memory entries) {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-deep-nested"),
            etherDelta: 0
        });

        // calls[0]: outer — manager calls NestedCaller.callNested() via sourceProxy(alice, MAINNET).
        //           Source rollup mirrors _outerActionHash (Alice on Mainnet).
        // calls[1]: inner — inside nestedActions[0]'s _processNCalls(1), manager calls
        //           CAP.incrementProxy() via sourceProxy(nestedCaller, MAINNET) — mirrors
        //           _capActionHash (NestedCaller on Mainnet). During this call, CAP calls
        //           counterProxy → triggers _consumeNestedAction(nestedActions[1]).
        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = CrossChainCall({
            targetAddress: nestedCaller,
            value: 0,
            data: abi.encodeWithSelector(NestedCaller.callNested.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });
        calls[1] = CrossChainCall({
            targetAddress: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: nestedCaller,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        NestedAction[] memory nested = new NestedAction[](2);
        nested[0] = NestedAction({
            actionHash: _capActionHash(cap, nestedCaller),
            callCount: 1,
            returnData: ""
        });
        nested[1] = NestedAction({
            actionHash: _counterActionHash(counterL2, cap),
            callCount: 0,
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            actionHash: _outerActionHash(nestedCaller, alice),
            calls: calls,
            nestedActions: nested,
            callCount: 1,
            returnData: "",
            failed: false,
            rollingHash: _expectedRollingHash()
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
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        Rollups rollups = Rollups(rollupsAddr);

        // counterProxy: proxy for Counter@L2 on L1
        address counterProxy;
        try rollups.createCrossChainProxy(counterL2, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2, L2_ROLLUP_ID);
        }

        // CAP: CounterAndProxy(counterProxy) on L1
        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        // capProxy: proxy for CAP@L2 on L1
        address capProxy;
        try rollups.createCrossChainProxy(address(cap), L2_ROLLUP_ID) returns (address p) {
            capProxy = p;
        } catch {
            capProxy = rollups.computeCrossChainProxyAddress(address(cap), L2_ROLLUP_ID);
        }

        // NestedCaller wraps CAP — calls cap.incrementProxy()
        NestedCaller nc = new NestedCaller(CounterAndProxy(capProxy));

        // ncProxy: proxy for NestedCaller@L2 on L1 (trigger point)
        address ncProxy;
        try rollups.createCrossChainProxy(address(nc), L2_ROLLUP_ID) returns (address p) {
            ncProxy = p;
        } catch {
            ncProxy = rollups.computeCrossChainProxyAddress(address(nc), L2_ROLLUP_ID);
        }

        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(cap));
        console.log("CAP_PROXY=%s", capProxy);
        console.log("NESTED_CALLER=%s", address(nc));
        console.log("NESTED_CALLER_PROXY=%s", ncProxy);
        vm.stopBroadcast();
    }
}

contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata statics,
        address ncProxy
    ) external {
        rollups.postBatch(entries, statics, 0, 0, 0, "", "proof");
        (bool ok,) = ncProxy.call(abi.encodeWithSelector(NestedCaller.callNested.selector));
        require(ok, "outer call failed");
    }
}

contract Execute is Script, DeepNestedActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");
        address ncAddr = vm.envAddress("NESTED_CALLER");
        address ncProxy = vm.envAddress("NESTED_CALLER_PROXY");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(counterL2, capAddr, ncAddr, address(batcher)),
            noStaticCalls(),
            ncProxy
        );

        console.log("done");
        console.log("nc.counter=%s", NestedCaller(ncAddr).counter());
        console.log("cap.counter=%s", CounterAndProxy(capAddr).counter());
        console.log("cap.targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("NESTED_CALLER_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(NestedCaller.callNested.selector)));
    }
}

contract ComputeExpected is ComputeExpectedBase, DeepNestedActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("COUNTER_AND_PROXY")) return "CounterAndProxy";
        if (a == vm.envAddress("NESTED_CALLER")) return "NestedCaller";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        if (sel == NestedCaller.callNested.selector) return "callNested";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2 = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");
        address ncAddr = vm.envAddress("NESTED_CALLER");
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(counterL2, capAddr, ncAddr, alice);
        bytes32 l1Hash = _entryHash(l1[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, 2 nested - deep) ===");
        _logEntry(0, l1[0]);
    }
}
