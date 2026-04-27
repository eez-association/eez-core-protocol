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
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, noNestedActions, noCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  NestedCounter scenario — exercises ExecutionEntry.nestedActions[]
//
//  Chain of events (entirely on L1):
//    1. Alice triggers an outer entry consumption via a proxy
//    2. Entry.calls[0] invokes CounterAndProxy.incrementProxy() (on L1)
//    3. CAP calls the counter proxy reentrantly — triggers a nested call
//    4. Rollups._consumeNestedAction matches nestedActions[0] by actionHash
//    5. Nested action returns abi.encode(uint256(1)) — CAP reads it as 1
//
//  This demonstrates the flatten primitive for precomputed reentrant returns.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedActions {
    using RollingHashBuilder for bytes32;

    /// @dev Inner action hash: CounterAndProxy calls the counter proxy reentrantly.
    function _innerActionHash(address counterL2, address cap) internal pure returns (bytes32) {
        return actionHash(Action({
            rollupId: L2_ROLLUP_ID,
            destination: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: cap,
            sourceRollup: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev Outer action hash: alice triggers CAP via its L2-side proxy.
    function _outerActionHash(address cap, address alice) internal pure returns (bytes32) {
        return actionHash(Action({
            rollupId: L2_ROLLUP_ID,
            destination: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollup: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev Rolling hash replay: CALL_BEGIN(1) → NESTED_BEGIN(1) → NESTED_END(1) → CALL_END(1, true, "")
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendNestedBegin(1);
        // nestedAction.callCount = 0 — no deeper calls inside the nested return
        h = h.appendNestedEnd(1);
        h = h.appendCallEnd(1, true, "");
    }

    function _l1Entries(address counterL2, address cap, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-nested"),
            etherDelta: 0
        });

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollup: L2_ROLLUP_ID, // proxy for (alice, L2) — will be auto-created
            revertSpan: 0
        });

        NestedAction[] memory nested = new NestedAction[](1);
        nested[0] = NestedAction({
            actionHash: _innerActionHash(counterL2, cap),
            callCount: 0,
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
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

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL2 = new Counter();
        console.log("COUNTER_L2=%s", address(counterL2));
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

        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        // Pre-compute CAP's L2-facing proxy address so Execute can trigger it
        address capL2Proxy;
        try rollups.createCrossChainProxy(address(cap), L2_ROLLUP_ID) returns (address p) {
            capL2Proxy = p;
        } catch {
            capL2Proxy = rollups.computeCrossChainProxyAddress(address(cap), L2_ROLLUP_ID);
        }

        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(cap));
        console.log("CAP_L2_PROXY=%s", capL2Proxy);
        vm.stopBroadcast();
    }
}

/// @notice Batcher: postBatch + trigger the outer entry via capL2Proxy.
///         Alice is the batcher itself (msg.sender into the proxy) in local mode.
contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata statics,
        address capL2Proxy
    ) external {
        rollups.postBatch(entries, statics, 0, 0, 0, "", "proof");
        (bool ok,) = capL2Proxy.call(abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector));
        require(ok, "outer call failed");
    }
}

contract Execute is Script, NestedActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");
        address capL2Proxy = vm.envAddress("CAP_L2_PROXY");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        // Alice = the Batcher contract itself (msg.sender into capL2Proxy).
        // The outer entry's actionHash must use alice = address(batcher).
        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(counterL2Addr, capAddr, address(batcher)),
            noStaticCalls(),
            capL2Proxy
        );

        console.log("done");
        console.log("cap.counter=%s", CounterAndProxy(capAddr).counter());
        console.log("cap.targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("CAP_L2_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector)));
    }
}

contract ComputeExpected is ComputeExpectedBase, NestedActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("COUNTER_AND_PROXY")) return "CounterAndProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");
        address alice = msg.sender; // placeholder for network mode

        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, capAddr, alice);
        bytes32 l1Hash = _entryHash(l1[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, 1 nested) ===");
        _logEntry(0, l1[0]);
    }
}
