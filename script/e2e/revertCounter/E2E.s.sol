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
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, noNestedActions, noCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  RevertCounter scenario — exercises CrossChainCall.revertSpan as a
//  FORCED revert: the destination call SUCCEEDS, but its EVM state effects
//  are rolled back at the protocol layer.
//
//  Models the canonical use case: an L2→L1 cross-chain call that ran
//  successfully on L1, but L2's prover output marks it as reverted in the
//  L2 view of the world (e.g., a higher-level transaction the call was
//  part of was rolled back on L2). When L1 replays the entry, revertSpan=1
//  forces the L1 state effects to disappear while the rolling hash still
//  commits to (success=true, returnData=abi.encode(1)).
//
//  Flow:
//    1. postBatch loads ONE deferred entry. Its calls[0] targets Counter
//       on L1 with revertSpan=1.
//    2. Alice triggers consumption by calling counterProxy (L1 proxy for
//       Counter@L2). Trigger and inner call are independent — the trigger
//       just selects this entry by matching actionHash.
//    3. _processNCalls sees revertSpan=1 → self-calls executeInContext(1).
//       Inside that frame, Counter.increment() runs successfully, returns
//       abi.encode(1), and the rolling hash records CALL_END(true, ...).
//    4. executeInContext reverts with ContextResult, the EVM rolls back
//       the counter increment, and the outer flow restores the rolling
//       hash + cursors from the revert payload.
//    5. Net effect: Counter.counter() == 0 on L1, even though the proof
//       commits to a successful call.
//
//  Contrast with revertSpan=0: a naturally-reverting destination already
//  produces (success=false, retData=revertReason) under revertSpan=0, so
//  revertSpan>0 buys nothing for that case. The mechanism only earns its
//  keep when state would otherwise survive — i.e., a forced revert.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertActions {
    using RollingHashBuilder for bytes32;

    /// @dev `Counter.increment()` returns `abi.encode(uint256(1))` for a fresh
    ///      counter. The proxy's `executeOnBehalf` returns the destination's
    ///      raw return bytes via assembly, so the manager sees this exact
    ///      payload as `retData` and hashes it into CALL_END.
    function _successReturnData() internal pure returns (bytes memory) {
        return abi.encode(uint256(1));
    }

    /// @dev Outer action hash: alice calls counterProxy (proxy for Counter@L2) on L1.
    ///      This is just the trigger — it selects which entry to consume.
    function _outerActionHash(address counterL2, address alice) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev Rolling hash: CALL_BEGIN(1) → CALL_END(1, true, abi.encode(1)).
    ///      The call succeeds inside the isolated context. Its state changes
    ///      are reverted by executeInContext, but the hash records the
    ///      successful outcome.
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendCallEnd(1, true, _successReturnData());
    }

    function _l1Entries(address counterL1, address counterL2, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-forced-revert"),
            etherDelta: 0
        });

        // Inner call: a Counter.increment() on L1 wrapped in revertSpan=1 to
        // demonstrate the EVM state effect being rolled back while the rolling
        // hash still records the successful outcome. sourceRollupId mirrors the
        // entry's outer source (Alice on Mainnet) per the spec convention.
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            targetAddress: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 1
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            actionHash: _outerActionHash(counterL2, alice),
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

/// @title Deploy — on L1, deploy Counter (force-revert target) + create trigger proxy
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        Rollups rollups = Rollups(rollupsAddr);

        Counter counterL1 = new Counter();

        // Trigger proxy: proxy for (Counter@L2, L2_ROLLUP_ID) on L1
        address counterProxy;
        try rollups.createCrossChainProxy(counterL2, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2, L2_ROLLUP_ID);
        }

        console.log("COUNTER_L1=%s", address(counterL1));
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
        // Trigger: call counterProxy.increment() — consumes the entry.
        // The inner call in the entry runs inside executeInContext and is force-reverted.
        (bool ok,) = counterProxy.call(abi.encodeWithSelector(Counter.increment.selector));
        require(ok, "trigger should succeed (revertSpan rolls back the inner call's state, not the outer flow)");
    }
}

contract Execute is Script, RevertActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address counterProxy = vm.envAddress("COUNTER_PROXY");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        // alice = batcher (msg.sender into the proxy)
        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(counterL1, counterL2, address(batcher)),
            noStaticCalls(),
            counterProxy
        );

        // Invariant: counter on L1 stays at 0 — the increment ran, returned 1,
        // but executeInContext's revert rolled the state change back. The
        // rolling hash still committed to (success=true, retData=1).
        uint256 finalCounter = Counter(counterL1).counter();
        require(finalCounter == 0, "revertSpan must roll back successful state changes");

        console.log("done");
        console.log("counterL1.counter=%s (expected 0 -- state rolled back)", finalCounter);
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
        if (a == vm.envAddress("COUNTER_L1")) return "Counter(L1)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2 = vm.envAddress("COUNTER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(counterL1, counterL2, alice);
        bytes32 l1Hash = _entryHash(l1[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call w/ revertSpan=1, force-reverted success) ===");
        _logEntry(0, l1[0]);
    }
}
