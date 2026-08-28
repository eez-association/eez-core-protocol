// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {RollupUpdate, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy} from "../../../../../test/mocks/CounterContracts.sol";
import {CallTwiceNestedAndOnce} from "../../../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    crossChainCallHashL2Out,
    expectedL1toL2Hash,
    noStaticEntries,
    noL2StaticEntries,
    noCalls,
    noL2OutgoingCalls,
    getOrCreateProxy,
    immediateSingleRollupBatch,
    RollingHashBuilder
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  multi-call-nestedL2 — L2-anchored, two genuine L2→L1→L2 round trips
//  plus one purely local call (the mirror of multi-call-nested)
//
//  Topology:
//    L2: CounterL2 (destination of CAP's reentry), SimpleCounterL2 (local),
//        App = CallTwiceNestedAndOnce
//    L1: CounterL2ProxyL1 = proxy(CounterL2@L2); CAP = CounterAndProxy(that proxy)
//    L2: CapProxyL2 = proxy(CAP@MAINNET) — the App's cross-chain target
//
//  alice → App.execute(capProxyL2, simpleCounterL2) makes 3 calls:
//    1. capProxyL2.incrementProxy()  → outgoing L2→L1 → CAP runs on L1 →
//       reentrant CounterL2.increment() back on L2 (cached 1)
//    2. same again (cached 2)
//    3. simpleCounterL2.increment()  → plain local L2 call (returns 1, no manager)
//
//  L2 view (ExecuteL2): the user tx consumes TWO source entries (same key,
//  sequential). Each entry carries CAP's reentrant CounterL2 call in its own
//  incomingCalls array, keeping the complete round trip in the open frame.
//  L1 view (Execute): ONE zero-hash L2Tx entry for the one L2 user tx. It
//  runs both CAP.incrementProxy() calls sequentially, with one nested row
//  per call (cached 1, then 2).
//
//  Final state: L1 CAP.counter == 2, CAP.targetCounter == 2;
//               L2 CounterL2.counter == 2, SimpleCounterL2.counter == 1.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract MultiCallNestedL2Actions {
    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _incrementProxyData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
    }

    /// Outgoing/trigger key: the App's call LEAVES the L2 through capProxyL2, so
    /// `EEZL2.executeCrossChainCall` keys it with the L2-outgoing hash (callGas=0 —
    /// devnet deploys EEZL2 with useGasLeft=false). Source = the App contract.
    function _outgoingHash(address capL1, address app) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(app, L2_ROLLUP_ID, capL1, MAINNET_ROLLUP_ID, 0, _incrementProxyData());
    }

    /// L1 top-level call hash: CAP.incrementProxy() executes ON L1 (target rollup =
    /// MAINNET; source = the App @ L2).
    function _l1TopCallHash(address capL1, address app) internal pure returns (bytes32) {
        return crossChainCallHash(false, app, L2_ROLLUP_ID, capL1, MAINNET_ROLLUP_ID, 0, _incrementProxyData());
    }

    /// Inner L1→L2 reentry: CAP (on L1) calls CounterL2 via its L1-side proxy — keyed with
    /// the plain hash. The same hash folds each CALL_BEGIN of its execution inside the outgoing entries.
    function _innerHash(address counterL2, address capL1) internal pure returns (bytes32) {
        return crossChainCallHash(false, capL1, MAINNET_ROLLUP_ID, counterL2, L2_ROLLUP_ID, 0, _incrementData());
    }

    /// One outgoing source entry. Its matching nested call back to CounterL2 executes
    /// inside the same open frame through incomingCalls.
    function _l2OutgoingEntry(
        address counterL2,
        address capL1,
        address app,
        uint256 n
    )
        internal
        pure
        returns (L2ExecutionEntry memory)
    {
        bytes32 key = _outgoingHash(capL1, app);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: capL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: _incrementData()
        });

        bytes32 rh = RollingHashBuilder.entryBeginL2(key);
        rh = RollingHashBuilder.appendCallBegin(rh, _innerHash(counterL2, capL1));
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(n));
        return L2ExecutionEntry({
            proxyEntryHash: key,
            incomingCalls: calls,
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: rh,
            success: true,
            returnData: "" // incrementProxy returns void
        });
    }

    /// The two source entries consumed by the single L2 user tx. Each contains its
    /// own nested incoming execution; there are no synthetic delivery entries.
    function _l2Entries(
        address counterL2,
        address capL1,
        address app
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        entries = new L2ExecutionEntry[](2);
        entries[0] = _l2OutgoingEntry(counterL2, capL1, app, 1);
        entries[1] = _l2OutgoingEntry(counterL2, capL1, app, 2);
    }

    /// The single L2Tx entry for the single L2 user transaction. Both outgoing
    /// L2→L1 calls are top-level calls in order; each owns one nested L1→L2 row.
    function _l1Entries(
        address counterL2,
        address capL1,
        address app
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: app,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: capL1,
            value: 0,
            data: _incrementProxyData()
        });
        calls[1] = calls[0];

        bytes32 ccInner = _innerHash(counterL2, capL1);

        RollupUpdate[] memory deltas = new RollupUpdate[](1);
        deltas[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-multi-call-nested-l2"),
            etherDelta: 0
        });

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, _l1TopCallHash(capL1, app));
        bytes32 rhFire0 = rh;
        rh = RollingHashBuilder.appendNestedBegin(rh, ccInner);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");
        rh = RollingHashBuilder.appendCallBegin(rh, _l1TopCallHash(capL1, app));
        bytes32 rhFire1 = rh;
        rh = RollingHashBuilder.appendNestedBegin(rh, ccInner);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](2);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(ccInner, rhFire0),
            l2ToL1Calls: noCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });
        nested[1] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(ccInner, rhFire1),
            l2ToL1Calls: noCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(2))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltas,
            proxyEntryHash: bytes32(0), // pure L2 tx — consumed by postAndVerifyBatch/executeL2Txs
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys — three-phase order (each phase needs the previous one's address):
//    1. DeployL2 (L2) — CounterL2, SimpleCounterL2, the App.
//    2. Deploy (L1) — L1-side proxy for CounterL2 + CAP targeting it.
//    3. DeployL2Trigger (L2) — L2-side proxy for CAP (the App's target).
// ═══════════════════════════════════════════════════════════════════════

// Outputs: COUNTER_L2, SIMPLE_COUNTER_L2, APP_L2
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL2 = new Counter();
        Counter simpleCounter = new Counter();
        CallTwiceNestedAndOnce app = new CallTwiceNestedAndOnce();
        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("SIMPLE_COUNTER_L2=%s", address(simpleCounter));
        console.log("APP_L2=%s", address(app));
        vm.stopBroadcast();
    }
}

// Env: ROLLUPS, COUNTER_L2
// Outputs: COUNTER_L2_PROXY_L1 (proxy on L1 for CounterL2 — CAP.target), CAP_L1
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        address counterL2ProxyL1 = getOrCreateProxy(IEEZ(rollupsAddr), counterL2Addr, L2_ROLLUP_ID);
        CounterAndProxy cap = new CounterAndProxy(Counter(counterL2ProxyL1));
        console.log("COUNTER_L2_PROXY_L1=%s", counterL2ProxyL1);
        console.log("CAP_L1=%s", address(cap));
        vm.stopBroadcast();
    }
}

// Env: MANAGER_L2, CAP_L1
// Outputs: CAP_PROXY_L2 (proxy on L2 for CAP on MAINNET — the App's cross-chain target)
contract DeployL2Trigger is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address capL1Addr = vm.envAddress("CAP_L1");

        vm.startBroadcast();
        address capProxyL2 = getOrCreateProxy(IEEZ(managerAddr), capL1Addr, MAINNET_ROLLUP_ID);
        console.log("CAP_PROXY_L2=%s", capProxyL2);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// ExecuteL2 — local mode: loadExecutionTable + one App trigger tx. Both nested
/// CounterL2.increment() calls execute inside their originating source entries.
/// Env: MANAGER_L2, COUNTER_L2, SIMPLE_COUNTER_L2, APP_L2, CAP_L1, CAP_PROXY_L2
contract ExecuteL2 is Script, MultiCallNestedL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address simpleCounterAddr = vm.envAddress("SIMPLE_COUNTER_L2");
        address appAddr = vm.envAddress("APP_L2");
        address capL1Addr = vm.envAddress("CAP_L1");
        address capProxyL2 = vm.envAddress("CAP_PROXY_L2");

        vm.startBroadcast();
        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterL2Addr, capL1Addr, appAddr), noL2StaticEntries());

        uint256 simpleResult = CallTwiceNestedAndOnce(appAddr).execute(capProxyL2, simpleCounterAddr);

        console.log("done");
        console.log("counterL2=%s (expected 2)", Counter(counterL2Addr).counter());
        console.log("simpleCounter=%s (expected 1)", Counter(simpleCounterAddr).counter());
        console.log("simpleResult=%s (expected 1)", simpleResult);
        vm.stopBroadcast();
    }
}

/// Execute — local mode: postAndVerifyBatch with one immediate L2Tx entry.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L2, APP_L2, CAP_L1
contract Execute is Script, MultiCallNestedL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address appAddr = vm.envAddress("APP_L2");
        address capL1Addr = vm.envAddress("CAP_L1");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL2Addr, capL1Addr, appAddr), noStaticEntries()
                )
            );

        console.log("done");
        console.log("cap.counter=%s (expected 2)", CounterAndProxy(capL1Addr).counter());
        console.log("cap.targetCounter=%s (expected 2)", CounterAndProxy(capL1Addr).targetCounter());
        vm.stopBroadcast();
    }
}

/// ExecuteNetworkL2 — network mode: user tx fields for the L2 trigger.
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address appAddr = vm.envAddress("APP_L2");
        address capProxyL2 = vm.envAddress("CAP_PROXY_L2");
        address simpleCounterAddr = vm.envAddress("SIMPLE_COUNTER_L2");

        console.log("TARGET=%s", appAddr);
        console.log("VALUE=0");
        console.log(
            "CALLDATA=%s",
            vm.toString(abi.encodeWithSelector(CallTwiceNestedAndOnce.execute.selector, capProxyL2, simpleCounterAddr))
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, MultiCallNestedL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "CounterL2";
        if (a == vm.envAddress("CAP_L1")) return "CAP(L1)";
        if (a == vm.envAddress("APP_L2")) return "App(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capL1Addr = vm.envAddress("CAP_L1");
        address appAddr = vm.envAddress("APP_L2");

        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, capL1Addr, appAddr);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL2Addr, capL1Addr, appAddr);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(_entryHash(l2[0])), vm.toString(_entryHash(l2[1])));
        _printL1CallHashes(l1);
        console.log(
            "EXPECTED_L2_CALL_HASHES=[%s,%s]", vm.toString(l2[0].proxyEntryHash), vm.toString(l2[1].proxyEntryHash)
        );
        _printL1Table(l1);
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 L2Tx entry, 2 calls + 2 nested rows) ===");
        _logEntry(0, l1[0]);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (2 outgoing entries with nested incoming calls) ===");
        for (uint256 i = 0; i < l2.length; i++) {
            _logL2Entry(i, l2[i]);
        }
    }
}
