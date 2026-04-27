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
import {Counter, RevertCounter} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, noNestedActions, noCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  RevertCounterL2 — exercises revertSpan on L2 side
//
//  Mirror of revertCounter (L1). Entirely on L2:
//    1. loadExecutionTable with one entry having calls[0].revertSpan=1
//    2. Alice calls counterProxy (Counter@L1) on L2 → entry consumed
//    3. Entry's calls[0] targets RevertCounter (on L2) → always reverts
//    4. Revert isolated by executeInContext; rolling hash captures failure
//    5. Entry succeeds — revertSpan isolates the revert
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertL2Actions {
    using RollingHashBuilder for bytes32;

    function _revertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "always reverts");
    }

    /// @dev Outer action hash: alice calls counterProxy (Counter@L1) on L2.
    function _outerActionHash(address counterL1, address alice) internal pure returns (bytes32) {
        return actionHash(Action({
            rollupId: MAINNET_ROLLUP_ID,
            destination: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: alice,
            sourceRollup: L2_ROLLUP_ID
        }));
    }

    /// @dev Rolling hash: CALL_BEGIN(1) → CALL_END(1, false, revertData)
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendCallEnd(1, false, _revertData());
    }

    function _l2Entries(address revertCounterL2, address counterL1, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: revertCounterL2,
            value: 0,
            data: abi.encodeWithSelector(RevertCounter.increment.selector),
            sourceAddress: alice,
            sourceRollup: MAINNET_ROLLUP_ID,
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

/// @title Deploy — on L1, deploy Counter (address reference)
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — on L2, deploy RevertCounter + create trigger proxy
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        CrossChainManagerL2 manager = CrossChainManagerL2(managerAddr);

        RevertCounter revertCounter = new RevertCounter();

        // Trigger proxy: proxy for (Counter@L1, MAINNET_ROLLUP_ID) on L2
        address counterProxy;
        try manager.createCrossChainProxy(counterL1, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = manager.computeCrossChainProxyAddress(counterL1, MAINNET_ROLLUP_ID);
        }

        console.log("REVERT_COUNTER_L2=%s", address(revertCounter));
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
        address revertCounterL2 = vm.envAddress("REVERT_COUNTER_L2");
        address counterProxy = vm.envAddress("COUNTER_PROXY_L2");

        vm.startBroadcast();
        address alice = msg.sender;
        console.log("ExecuteL2: alice=%s counterProxy=%s", alice, counterProxy);

        CrossChainManagerL2(managerAddr).loadExecutionTable(
            _l2Entries(revertCounterL2, counterL1, alice),
            noStaticCalls()
        );
        console.log("ExecuteL2: loadExecutionTable done");

        // Trigger: alice calls counterProxy.increment() — entry consumed, revertSpan isolates
        (bool ok,) = counterProxy.call(abi.encodeWithSelector(Counter.increment.selector));
        require(ok, "entry should succeed (revertSpan isolates failure)");
        console.log("ExecuteL2: trigger done");

        console.log("done");
        console.log("revertCounter.counter=%s", RevertCounter(revertCounterL2).counter());
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
        if (a == vm.envAddress("REVERT_COUNTER_L2")) return "RevertCounter";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1 = vm.envAddress("COUNTER_L1");
        address revertCounterL2 = vm.envAddress("REVERT_COUNTER_L2");
        address alice = msg.sender;

        ExecutionEntry[] memory l2 = _l2Entries(revertCounterL2, counterL1, alice);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call w/ revertSpan=1) ===");
        _logL2Entry(0, l2[0]);
    }
}
