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
import {Counter, RevertCounter} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, noNestedActions, noCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  RevertCounter scenario — exercises CrossChainCall.revertSpan
//
//  Demonstrates the flatten model's native revert isolation:
//    1. User triggers entry consumption via proxy call on L1
//    2. Entry has calls[0] with revertSpan=1 targeting a RevertCounter
//    3. The call executes inside executeInContext (isolated self-call)
//    4. RevertCounter.increment() always reverts with "always reverts"
//    5. The revert is captured; rolling hash records (false, revertBytes)
//    6. Entry succeeds overall — revertSpan isolates the failure
//
//  This replaces the old REVERT action type from the scope-tree model.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertActions {
    using RollingHashBuilder for bytes32;

    function _revertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "always reverts");
    }

    /// @dev Outer action hash: alice calls counterProxy (proxy for Counter@L2) on L1.
    function _outerActionHash(address counter, address alice) internal pure returns (bytes32) {
        return actionHash(Action({
            rollupId: L2_ROLLUP_ID,
            destination: counter,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: alice,
            sourceRollup: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev Rolling hash: CALL_BEGIN(1) → CALL_END(1, false, revertData)
    ///      The call fails inside the isolated context but the entry succeeds.
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendCallEnd(1, false, _revertData());
    }

    function _l1Entries(address revertCounterL1, address counter, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-revert"),
            etherDelta: 0
        });

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: revertCounterL1,
            value: 0,
            data: abi.encodeWithSelector(RevertCounter.increment.selector),
            sourceAddress: alice,
            sourceRollup: L2_ROLLUP_ID,
            revertSpan: 1
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            actionHash: _outerActionHash(counter, alice),
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

/// @title DeployL2 — deploy a Counter on L2 (address reference for proxy)
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counter = new Counter();
        console.log("COUNTER_L2=%s", address(counter));
        vm.stopBroadcast();
    }
}

/// @title Deploy — on L1, deploy RevertCounter + create trigger proxy
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        Rollups rollups = Rollups(rollupsAddr);

        RevertCounter revertCounter = new RevertCounter();

        // Trigger proxy: proxy for (Counter@L2, L2_ROLLUP_ID) on L1
        address counterProxy;
        try rollups.createCrossChainProxy(counterL2, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2, L2_ROLLUP_ID);
        }

        console.log("REVERT_COUNTER_L1=%s", address(revertCounter));
        console.log("COUNTER_PROXY=%s", counterProxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════════════

contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata statics,
        address counterProxy
    ) external {
        rollups.postBatch(entries, statics, 0, 0, 0, "", "proof");
        // Trigger: call counterProxy.increment() — this consumes the entry
        (bool ok,) = counterProxy.call(abi.encodeWithSelector(Counter.increment.selector));
        require(ok, "entry consumption should succeed (revertSpan isolates failure)");
    }
}

contract Execute is Script, RevertActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address revertCounterL1 = vm.envAddress("REVERT_COUNTER_L1");
        address counterProxy = vm.envAddress("COUNTER_PROXY");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        // alice = batcher (msg.sender into the proxy)
        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(revertCounterL1, counterL2, address(batcher)),
            noStaticCalls(),
            counterProxy
        );

        console.log("done");
        console.log("revertCounter.counter=%s", RevertCounter(revertCounterL1).counter());
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(Counter.increment.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, RevertActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter(L2)";
        if (a == vm.envAddress("REVERT_COUNTER_L1")) return "RevertCounter";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2 = vm.envAddress("COUNTER_L2");
        address revertCounterL1 = vm.envAddress("REVERT_COUNTER_L1");
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(revertCounterL1, counterL2, alice);
        bytes32 l1Hash = _entryHash(l1[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call w/ revertSpan=1) ===");
        _logEntry(0, l1[0]);
    }
}
