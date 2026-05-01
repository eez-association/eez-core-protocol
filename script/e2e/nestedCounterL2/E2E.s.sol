// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {
    Action,
    StateDelta,
    CrossChainCall,
    NestedAction,
    ExecutionEntry,
    StaticCall
} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, noNestedActions, noCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  NestedCounterL2 scenario — exercises nestedActions[] on L2 side
//
//  Chain of events (entirely on L2):
//    1. loadExecutionTable loads ONE entry with calls[] + nestedActions[]
//    2. Alice calls capL1Proxy (proxy for CAP@MAINNET on L2) → entry consumed
//    3. _processNCalls: calls[0] routes via proxy for (alice,L1) → cap.incrementProxy()
//    4. CAP calls counterProxy (proxy for Counter@L1 on L2) → nested action consumed
//    5. Nested action returns abi.encode(1) → CAP reads targetCounter=1
//
//  Mirror of nestedCounter (which is entirely on L1).
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedL2Actions {
    using RollingHashBuilder for bytes32;

    /// @dev Inner action hash: CAP calls counterProxy (Counter@L1) on L2.
    function _innerActionHash(address counterL1, address cap) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: cap,
            sourceRollupId: L2_ROLLUP_ID
        }));
    }

    /// @dev Outer action hash: alice calls capL1Proxy (CAP@MAINNET) on L2.
    function _outerActionHash(address cap, address alice) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: MAINNET_ROLLUP_ID,
            targetAddress: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID
        }));
    }

    /// @dev Rolling hash: CALL_BEGIN(1) → NESTED_BEGIN(1) → NESTED_END(1) → CALL_END(1, true, "")
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendNestedBegin(1);
        h = h.appendNestedEnd(1);
        h = h.appendCallEnd(1, true, "");
    }

    function _l2Entries(address counterL1, address cap, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            targetAddress: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID, // matches the entry's outer src — Alice on L2
            revertSpan: 0
        });

        NestedAction[] memory nested = new NestedAction[](1);
        nested[0] = NestedAction({
            actionHash: _innerActionHash(counterL1, cap),
            callCount: 0,
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            actionHash: _outerActionHash(cap, alice),
            calls: calls,
            nestedActions: nested,
            callCount: 1,
            returnData: "",
            failed: false,
            rollingHash: _expectedRollingHash()
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title Deploy — on L1, deploy Counter (address reference only)
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — on L2, create proxies + deploy CAP
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        CrossChainManagerL2 manager = CrossChainManagerL2(managerAddr);

        // Proxy for Counter@L1 on L2
        address counterProxy;
        try manager.createCrossChainProxy(counterL1Addr, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = manager.computeCrossChainProxyAddress(counterL1Addr, MAINNET_ROLLUP_ID);
        }

        // Deploy CAP on L2, pointing to counterProxy
        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        // Proxy for CAP@MAINNET on L2 (the trigger point alice calls)
        address capL1Proxy;
        try manager.createCrossChainProxy(address(cap), MAINNET_ROLLUP_ID) returns (address p) {
            capL1Proxy = p;
        } catch {
            capL1Proxy = manager.computeCrossChainProxyAddress(address(cap), MAINNET_ROLLUP_ID);
        }

        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        console.log("COUNTER_AND_PROXY_L2=%s", address(cap));
        console.log("CAP_L1_PROXY=%s", capL1Proxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — loadExecutionTable + trigger via capL1Proxy in same block
contract ExecuteL2 is Script, NestedL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address capL1Proxy = vm.envAddress("CAP_L1_PROXY");

        vm.startBroadcast();
        // alice = msg.sender (the broadcaster)
        address alice = msg.sender;
        console.log("ExecuteL2: alice=%s cap=%s capL1Proxy=%s", alice, capAddr, capL1Proxy);

        CrossChainManagerL2(managerAddr).loadExecutionTable(
            _l2Entries(counterL1Addr, capAddr, alice),
            noStaticCalls()
        );
        console.log("ExecuteL2: loadExecutionTable done");

        // Trigger: alice calls capL1Proxy.incrementProxy()
        (bool ok,) = capL1Proxy.call(abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector));
        require(ok, "outer call failed");
        console.log("ExecuteL2: trigger done");

        console.log("done");
        console.log("cap.counter=%s", CounterAndProxy(capAddr).counter());
        console.log("cap.targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode output
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("CAP_L1_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, NestedL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "Counter";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L2")) return "CounterAndProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address alice = msg.sender;

        ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, capAddr, alice);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 1 nested) ===");
        _logL2Entry(0, l2[0]);
    }
}
