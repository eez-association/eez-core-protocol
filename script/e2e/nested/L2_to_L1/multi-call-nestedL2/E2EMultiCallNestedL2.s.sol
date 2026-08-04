// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {StateUpdate, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
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
//  L2 view (ExecuteL2): the user tx consumes TWO cached-result outgoing
//  entries (same key, sequential); CAP's two reentrant CounterL2 calls
//  arrive back as their OWN executeIncomingCrossChainCall deliveries
//  (see EXECUTION_ENTRY_SPEC §1-to-1 rule).
//  L1 view (Execute): 2 zero-hash L2Tx entries, each running one
//  CAP.incrementProxy() with one nested row (cached 1, then 2) —
//  exercising the L1 nested table twice.
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
    /// the plain hash. The same hash keys each incoming delivery back on L2.
    function _innerHash(address counterL2, address capL1) internal pure returns (bytes32) {
        return crossChainCallHash(false, capL1, MAINNET_ROLLUP_ID, counterL2, L2_ROLLUP_ID, 0, _incrementData());
    }

    /// One cached-result outgoing entry — nothing executes on L2 for it. The App calls the
    /// proxy twice, consuming two identical entries sequentially.
    function _l2OutgoingEntry(address capL1, address app) internal pure returns (L2ExecutionEntry memory) {
        bytes32 key = _outgoingHash(capL1, app);
        return L2ExecutionEntry({
            proxyEntryHash: key,
            incomingCalls: new CrossChainCall[](0),
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: RollingHashBuilder.entryBeginL2(key),
            success: true,
            returnData: "" // incrementProxy returns void
        });
    }

    /// CAP's n-th reentrant CounterL2.increment(), delivered back on L2 as its own incoming
    /// execution (1-entry table); returns abi.encode(n).
    function _l2IncomingEntry(address counterL2, address capL1, uint256 n)
        internal
        pure
        returns (L2ExecutionEntry memory)
    {
        bytes32 key = _innerHash(counterL2, capL1);
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
        rh = RollingHashBuilder.appendCallBegin(rh, key);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(n));
        return L2ExecutionEntry({
            proxyEntryHash: key,
            incomingCalls: calls,
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: rh,
            success: true,
            returnData: abi.encode(n)
        });
    }

    /// All four L2-side executions in consumption order: the two outgoing entries the user
    /// tx consumes, then the two inbound reentry deliveries.
    function _l2Entries(address counterL2, address capL1, address app)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        entries = new L2ExecutionEntry[](4);
        entries[0] = _l2OutgoingEntry(capL1, app);
        entries[1] = _l2OutgoingEntry(capL1, app);
        entries[2] = _l2IncomingEntry(counterL2, capL1, 1);
        entries[3] = _l2IncomingEntry(counterL2, capL1, 2);
    }

    /// The n-th L2Tx entry: CAP.incrementProxy() runs on L1 with one nested reentry
    /// (cached abi.encode(n)).
    function _l1Entry(address counterL2, address capL1, address app, StateUpdate[] memory deltas, uint256 n)
        internal
        pure
        returns (ExecutionEntry memory)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
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

        bytes32 ccInner = _innerHash(counterL2, capL1);

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, _l1TopCallHash(capL1, app));
        bytes32 rhFire = rh; // CAP's reentry to CounterL2 fires here
        rh = RollingHashBuilder.appendNestedBegin(rh, ccInner);
        rh = RollingHashBuilder.appendNestedEnd(rh); // the reentry runs no L1 sub-calls
        rh = RollingHashBuilder.appendCallEnd(rh, true, ""); // incrementProxy returns void

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(ccInner, rhFire),
            l2ToL1Calls: noCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(n)
        });

        return ExecutionEntry({
            stateUpdates: deltas,
            proxyEntryHash: bytes32(0), // pure L2 tx — consumed by postAndVerifyBatch/executeL2Txs
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }

    function _l1Entries(address counterL2, address capL1, address app)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateUpdate[] memory d0 = new StateUpdate[](1);
        d0[0] = StateUpdate({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-mcnl2-step-1"),
            etherDelta: 0
        });
        StateUpdate[] memory d1 = new StateUpdate[](1);
        d1[0] = StateUpdate({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-mcnl2-step-1"),
            newState: keccak256("l2-mcnl2-step-2"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](2);
        entries[0] = _l1Entry(counterL2, capL1, app, d0, 1);
        entries[1] = _l1Entry(counterL2, capL1, app, d1, 2);
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

/// ExecuteL2 — local mode: loadExecutionTable + the App trigger tx, then the two
/// SYSTEM-driven inbound deliveries of CAP's reentrant CounterL2.increment() calls.
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
        L2ExecutionEntry[] memory table = new L2ExecutionEntry[](2);
        table[0] = _l2OutgoingEntry(capL1Addr, appAddr);
        table[1] = _l2OutgoingEntry(capL1Addr, appAddr);
        EEZL2(managerAddr).loadExecutionTable(table, noL2StaticEntries());

        uint256 simpleResult = CallTwiceNestedAndOnce(appAddr).execute(capProxyL2, simpleCounterAddr);

        for (uint256 n = 1; n <= 2; n++) {
            L2ExecutionEntry[] memory incoming = new L2ExecutionEntry[](1);
            incoming[0] = _l2IncomingEntry(counterL2Addr, capL1Addr, n);
            EEZL2(managerAddr).executeIncomingCrossChainCall(incoming, noL2StaticEntries());
        }

        console.log("done");
        console.log("counterL2=%s (expected 2)", Counter(counterL2Addr).counter());
        console.log("simpleCounter=%s (expected 1)", Counter(simpleCounterAddr).counter());
        console.log("simpleResult=%s (expected 1)", simpleResult);
        vm.stopBroadcast();
    }
}

/// Execute — local mode: postAndVerifyBatch with the two immediate L2Tx entries.
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

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(_entryHash(l1[0])), vm.toString(_entryHash(l1[1])));
        console.log(
            string.concat(
                "EXPECTED_L2_HASHES=[",
                vm.toString(_entryHash(l2[0])),
                ",",
                vm.toString(_entryHash(l2[1])),
                ",",
                vm.toString(_entryHash(l2[2])),
                ",",
                vm.toString(_entryHash(l2[3])),
                "]"
            )
        );
        _printL1CallHashes(l1);
        console.log(
            string.concat(
                "EXPECTED_L2_CALL_HASHES=[",
                vm.toString(l2[0].proxyEntryHash),
                ",",
                vm.toString(l2[1].proxyEntryHash),
                ",",
                vm.toString(l2[2].proxyEntryHash),
                ",",
                vm.toString(l2[3].proxyEntryHash),
                "]"
            )
        );
        _printL1Table(l1);
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (2 L2Tx entries, 1 call + 1 nested each) ===");
        _logEntry(0, l1[0]);
        _logEntry(1, l1[1]);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (2 outgoing entries + 2 incoming deliveries) ===");
        for (uint256 i = 0; i < l2.length; i++) {
            _logL2Entry(i, l2[i]);
        }
    }
}
