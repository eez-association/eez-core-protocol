// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {
    Action,
    StateDelta,
    CrossChainCall,
    NestedAction,
    ExecutionEntry,
    StaticCall
} from "../../../src/ICrossChainManager.sol";
import {Counter} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, noNestedActions, noCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  RevertCounterL2 — mirror of revertCounter on the L2 side.
//
//  Models the canonical use case in the opposite direction: an L1→L2 cross-
//  chain call whose state effects must be rolled back on L2 even though
//  the destination call itself succeeds. The L2 manager's revertSpan
//  mechanism is identical to L1's: self-call into executeInContext, the
//  inner span runs the call (state mutates, success=true), then reverts
//  with ContextResult to roll back EVM state while the rolling hash and
//  cursors propagate out.
//
//  Flow (entirely on L2):
//    1. loadExecutionTable installs ONE entry with calls[0].revertSpan=1.
//    2. Alice calls counterProxy (L2 proxy for Counter@L1) — consumes the
//       entry by matching actionHash.
//    3. _processNCalls sees revertSpan=1, self-calls executeInContext(1).
//       Counter on L2 is incremented inside the span; rolling hash records
//       CALL_END(true, abi.encode(1)).
//    4. executeInContext reverts → state rolled back, hash/cursors restored
//       from ContextResult.
//    5. Net effect on L2: Counter.counter() == 0, even though the proof
//       commits to a successful call.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertL2Actions {
    using RollingHashBuilder for bytes32;

    function _successReturnData() internal pure returns (bytes memory) {
        return abi.encode(uint256(1));
    }

    /// @dev Outer action hash: alice calls counterProxy (Counter@L1) on L2.
    function _outerActionHash(address counterL1, address alice) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID
        }));
    }

    /// @dev Rolling hash: CALL_BEGIN(1) → CALL_END(1, true, abi.encode(1)).
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendCallEnd(1, true, _successReturnData());
    }

    function _l2Entries(address counterL2, address counterL1, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        // Inner call: a Counter.increment() on L2 wrapped in revertSpan=1 to
        // demonstrate the EVM state effect being rolled back while the rolling
        // hash still records the successful outcome. sourceRollupId mirrors the
        // entry's outer source (Alice on L2) per the spec convention.
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            targetAddress: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 1
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            actionHash: _outerActionHash(counterL1, alice),
            calls: calls,
            nestedActions: noNestedActions(),
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

/// @title Deploy — on L1, deploy Counter (address reference for proxy)
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — on L2, deploy Counter (force-revert target) + create trigger proxy
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        CrossChainManagerL2 manager = CrossChainManagerL2(managerAddr);

        Counter counterL2 = new Counter();

        // Trigger proxy: proxy for (Counter@L1, MAINNET_ROLLUP_ID) on L2
        address counterProxy;
        try manager.createCrossChainProxy(counterL1, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = manager.computeCrossChainProxyAddress(counterL1, MAINNET_ROLLUP_ID);
        }

        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — loadExecutionTable + trigger in same block
contract ExecuteL2 is Script, RevertL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address counterProxy = vm.envAddress("COUNTER_PROXY_L2");

        vm.startBroadcast();
        address alice = msg.sender;
        console.log("ExecuteL2: alice=%s counterProxy=%s", alice, counterProxy);

        CrossChainManagerL2(managerAddr).loadExecutionTable(
            _l2Entries(counterL2, counterL1, alice),
            noStaticCalls()
        );
        console.log("ExecuteL2: loadExecutionTable done");

        // Trigger: alice calls counterProxy.increment() — consumes the entry.
        (bool ok,) = counterProxy.call(abi.encodeWithSelector(Counter.increment.selector));
        require(ok, "trigger should succeed (revertSpan rolls back inner state, not outer flow)");

        // Invariant: counter on L2 stays at 0 — increment ran inside the span,
        // returned 1, then state was rolled back by executeInContext's revert.
        uint256 finalCounter = Counter(counterL2).counter();
        require(finalCounter == 0, "revertSpan must roll back successful state changes");

        console.log("ExecuteL2: trigger done");
        console.log("done");
        console.log("counterL2.counter=%s (expected 0 -- state rolled back)", finalCounter);
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode output
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_PROXY_L2");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(Counter.increment.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, RevertL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "Counter(L1)";
        if (a == vm.envAddress("COUNTER_L2")) return "Counter(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1 = vm.envAddress("COUNTER_L1");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address alice = msg.sender;

        ExecutionEntry[] memory l2 = _l2Entries(counterL2, counterL1, alice);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call w/ revertSpan=1, force-reverted success) ===");
        _logL2Entry(0, l2[0]);
    }
}
