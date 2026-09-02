// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {RollupUpdate, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2ExecutionEntry, CrossChainCall} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, SelfCallerWithRevert} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    crossChainCallHash,
    crossChainCallHashL2Out,
    expectedL1toL2Hash,
    getOrCreateProxy,
    immediateSingleRollupBatch,
    noCalls,
    noL2OutgoingCalls,
    noL2StaticEntries,
    noStaticEntries,
    RollingHashBuilder
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
// RevertFromOtherChainNested — a successful L1→L2 reentrant row is consumed, its
// enclosing Solidity frame reverts, and the identical call consumes the
// same row again. Both tables describe ONE L2 user trigger and one open frame.
//
// L2 trigger and real callback execution:
//   alice ─tx─▶ proxy(SelfCaller@L1).execute()
//     ├─ callback[0] SelfCaller@L1 → Counter@L2.increment()
//     │    returns 1, then innerCall() reverts: state/result span is erased
//     └─ callback[1] identical retry returns 1 and commits
//   final Counter@L2.counter == 1, proving the first callback did not persist.
//
// L1 immediate L2Tx execution:
//   SelfCaller@L1.execute()
//     ├─ try this.innerCall()
//     │    └─ proxy(Counter@L2).increment(): consumes reentrant row 0
//     │       innerCall reverts; catch absorbs it; cursor and folds unwind
//     └─ proxy(Counter@L2).increment(): retries and consumes row 0 again
//   final lastResult == 1; only the retry's NESTED_BEGIN/NESTED_END survives.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertFromOtherChainNestedActions {
    function _executeData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SelfCallerWithRevert.execute.selector);
    }

    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _outerHash(address selfCallerL1, address alice) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(alice, L2_ROLLUP_ID, selfCallerL1, MAINNET_ROLLUP_ID, 0, _executeData());
    }

    function _l1TopHash(address selfCallerL1, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(false, alice, L2_ROLLUP_ID, selfCallerL1, MAINNET_ROLLUP_ID, 0, _executeData());
    }

    function _innerHash(address counterL2, address selfCallerL1) internal pure returns (bytes32) {
        return crossChainCallHash(false, selfCallerL1, MAINNET_ROLLUP_ID, counterL2, L2_ROLLUP_ID, 0, _incrementData());
    }

    function _callback(
        address counterL2,
        address selfCallerL1,
        uint16 revertNextNCalls
    )
        private
        pure
        returns (CrossChainCall memory)
    {
        return CrossChainCall({
            revertNextNCalls: revertNextNCalls,
            isStatic: false,
            gas: 0,
            sourceAddress: selfCallerL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: _incrementData()
        });
    }

    function _l2Entries(
        address counterL2,
        address selfCallerL1,
        address alice
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 key = _outerHash(selfCallerL1, alice);
        bytes32 inner = _innerHash(counterL2, selfCallerL1);

        CrossChainCall[] memory callbacks = new CrossChainCall[](2);
        callbacks[0] = _callback(counterL2, selfCallerL1, 1);
        callbacks[1] = _callback(counterL2, selfCallerL1, 0);

        bytes32 rh = RollingHashBuilder.entryBeginL2(key);
        rh = RollingHashBuilder.appendCallBegin(rh, inner);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));
        rh = RollingHashBuilder.appendCallBegin(rh, inner);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: key,
            incomingCalls: callbacks,
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }

    function _l1Entries(
        address counterL2,
        address selfCallerL1,
        address alice
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        RollupUpdate[] memory updates = new RollupUpdate[](1);
        updates[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            etherDelta: 0,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-revert-and-retry")
        });

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            gas: 0,
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: selfCallerL1,
            value: 0,
            data: _executeData()
        });

        bytes32 inner = _innerHash(counterL2, selfCallerL1);
        bytes32 rh = RollingHashBuilder.entryBegin(updates, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, _l1TopHash(selfCallerL1, alice));
        bytes32 rhFire = rh;
        // The first resolution occurs at the same rhFire but unwinds completely.
        // The retry therefore matches the same position-pinned row and is the only
        // nested resolution represented in the committed rolling hash.
        rh = RollingHashBuilder.appendNestedBegin(rh, inner);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(inner, rhFire),
            l2ToL1Calls: noCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: updates,
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            rollingHash: rh,
            success: true,
            returnData: ""
        });
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
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2 = vm.envAddress("COUNTER_L2");
        vm.startBroadcast();
        address counterProxyL1 = getOrCreateProxy(IEEZ(rollupsAddr), counterL2, L2_ROLLUP_ID);
        SelfCallerWithRevert selfCaller = new SelfCallerWithRevert(Counter(counterProxyL1));
        output("COUNTER_PROXY_L1", counterProxyL1);
        output("SELF_CALLER_L1", address(selfCaller));
        vm.stopBroadcast();
    }
}

contract DeployL2Trigger is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address selfCallerL1 = vm.envAddress("SELF_CALLER_L1");
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(managerAddr), selfCallerL1, MAINNET_ROLLUP_ID);
        output("SELF_CALLER_PROXY_L2", proxy);
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is Script, RevertFromOtherChainNestedActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address selfCallerL1 = vm.envAddress("SELF_CALLER_L1");
        address proxy = vm.envAddress("SELF_CALLER_PROXY_L2");
        vm.startBroadcast();
        address alice = msg.sender;
        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterL2, selfCallerL1, alice), noL2StaticEntries());
        (bool ok,) = proxy.call(_executeData());
        require(ok, "outer outgoing call failed");
        require(Counter(counterL2).counter() == 1, "first callback must unwind and retry must commit");
        console.log("done");
        console.log("counterL2.counter=%s (expected 1)", Counter(counterL2).counter());
        vm.stopBroadcast();
    }
}

contract Execute is Script, RevertFromOtherChainNestedActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystem = vm.envAddress("PROOF_SYSTEM");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address selfCallerL1 = vm.envAddress("SELF_CALLER_L1");
        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystem, L2_ROLLUP_ID, _l1Entries(counterL2, selfCallerL1, msg.sender), noStaticEntries()
                )
            );
        require(SelfCallerWithRevert(selfCallerL1).lastResult() == 1, "same reentrant row was not retried");
        console.log("done");
        console.log("selfCallerL1.lastResult=%s (expected 1)", SelfCallerWithRevert(selfCallerL1).lastResult());
        vm.stopBroadcast();
    }
}

contract ExecuteNetworkL2 is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("SELF_CALLER_PROXY_L2"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(SelfCallerWithRevert.execute.selector)));
    }
}

contract ComputeExpected is ComputeExpectedBase, RevertFromOtherChainNestedActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter(L2)";
        if (a == vm.envAddress("SELF_CALLER_L1")) return "SelfCallerWithRevert(L1)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == SelfCallerWithRevert.execute.selector) return "execute";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2 = vm.envAddress("COUNTER_L2");
        address selfCallerL1 = vm.envAddress("SELF_CALLER_L1");
        address alice = msg.sender;
        ExecutionEntry[] memory l1 = _l1Entries(counterL2, selfCallerL1, alice);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL2, selfCallerL1, alice);
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2[0].proxyEntryHash));
        _printL1Table(l1);
        _printL2Table(l2);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (one L2Tx; successful reentrant row retried after rollback) ===");
        _logEntry(0, l1[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (first callback erased; retry committed) ===");
        _logL2Entry(0, l2[0]);
    }
}
