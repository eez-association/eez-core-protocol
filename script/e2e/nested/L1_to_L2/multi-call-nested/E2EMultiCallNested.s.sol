// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {
    StateUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry,
    StaticExecutionEntry
} from "../../../../../src/interfaces/IEEZ.sol";
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
    noNestedActions,
    noL2OutgoingCalls,
    noCalls,
    noL2Calls,
    getOrCreateProxy,
    RollingHashBuilder,
    immediateSingleRollupBatch
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  multi-call-nested — L1-anchored, with real L1↔L2↔L1 round-trip nesting
//
//  Actor cast:
//    L1: CounterL1 (real), CallTwiceNestedAndOnce (app)
//    L2: CounterL1ProxyOnL2, CounterAndProxyL2 (CAP2; target=CounterL1ProxyOnL2),
//        CounterL2 (real)
//    L1: CAP2_PROXY_L1 (proxy for CAP2@L2), COUNTER_L2_PROXY_L1 (proxy for CounterL2@L2)
//
//  app.execute(cap2ProxyL1, counterL2ProxyL1) on L1 makes 3 cross-chain calls:
//    1. cap2ProxyL1.incrementProxy()   → CAP2 on L2 → reentrant → CounterL1 on L1 (returns 1)
//    2. cap2ProxyL1.incrementProxy()   → CAP2 on L2 → reentrant → CounterL1 on L1 (returns 2)
//    3. counterL2ProxyL1.increment()   → CounterL2 on L2 (returns 1)
//
//  L1 view (Execute): each app call consumes one of 3 L1 entries.
//    [0] [1]: l2ToL1Calls=[CAP2's reentrant call to CounterL1]; CounterL1.increment runs on L1.
//    [2]:    l2ToL1Calls=[]; just the L2 state delta + entry returnData=1 (rolling hash = entry seed).
//
//  L2 view (ExecuteL2): each top-level call is delivered as its OWN
//  executeIncomingCrossChainCall tx with a 1-entry table (the delivery unit is
//  the top-level call — see EXECUTION_ENTRY_SPEC §1-to-1 rule), keyed by the
//  same cross-chain call hash as the L1 side (source = the L1 app).
//    delivery 1/2: incomingCalls=[CAP2 with source=app]; CAP2 reentrant-calls CounterL1
//                  via COUNTER_L1_PROXY_L2 → ExpectedOutgoingCrossChainCall returns 1, then 2.
//    delivery 3:  incomingCalls=[CounterL2]; CounterL2.increment runs on L2.
//
//  Final state:
//    L1: CounterL1.counter == 2          (incremented by entries [0] and [1])
//        app.execute returns 1           (CounterL2's first return, surfaced via entry [2])
//    L2: CAP2.counter == 2, CAP2.targetCounter == 2,  CounterL2.counter == 1
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract MCNActions {
    function _incrementProxyData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
    }

    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    // ── L1 proxy-entry hashes (sourceRollup=MAINNET; the trigger lives on L1) ──

    function _l1HashCAP2(address cap2L2, address app) internal pure returns (bytes32) {
        return crossChainCallHash(false, app, MAINNET_ROLLUP_ID, cap2L2, L2_ROLLUP_ID, 0, _incrementProxyData());
    }

    function _l1HashCounterL2(address counterL2, address app) internal pure returns (bytes32) {
        return crossChainCallHash(false, app, MAINNET_ROLLUP_ID, counterL2, L2_ROLLUP_ID, 0, _incrementData());
    }

    /// @dev L1 top-level call hash: CAP2 (logically on L2) reentrant-calls CounterL1 on L1.
    ///      Executes ON L1, so targetRollupId = MAINNET; source = CAP2 @ L2.
    function _l1TopCallCounterL1(address counterL1, address cap2L2) internal pure returns (bytes32) {
        return crossChainCallHash(false, cap2L2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementData());
    }

    // ── L2 hashes ──

    /// @dev Inner reentrant (outgoing) hash on L2: CAP2 (on L2) calls CounterL1 MAINNET — the call
    ///      LEAVES the L2, so it keys with the L2-outgoing hash (callGas=0; devnet deploys
    ///      EEZL2 with useGasLeft=false). The L2 manager forces sourceRollupId = ROLLUP_ID (=L2).
    function _l2InnerHashCounterL1(address counterL1, address cap2L2) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(cap2L2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementData());
    }

    // ── L1 entries (3) ──

    function _l1Entries(address counterL1, address cap2L2, address counterL2, address app)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        // Inner call shared by entries [0] and [1]: CAP2 (logically on L2) reentrant-calls
        // CounterL1 on L1. The L1 manager auto-resolves CAP2's source-proxy and forwards.
        L2ToL1Call memory cap2CallsCounterL1 = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: cap2L2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _incrementData()
        });
        L2ToL1Call[] memory calls0 = new L2ToL1Call[](1);
        calls0[0] = cap2CallsCounterL1;
        L2ToL1Call[] memory calls1 = new L2ToL1Call[](1);
        calls1[0] = cap2CallsCounterL1;

        StateUpdate[] memory d0 = new StateUpdate[](1);
        d0[0] = StateUpdate({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-mcn-step-1"),
            etherDelta: 0
        });
        StateUpdate[] memory d1 = new StateUpdate[](1);
        d1[0] = StateUpdate({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-mcn-step-1"),
            newState: keccak256("l2-mcn-step-2"),
            etherDelta: 0
        });
        StateUpdate[] memory d2 = new StateUpdate[](1);
        d2[0] = StateUpdate({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-mcn-step-2"),
            newState: keccak256("l2-mcn-step-3"),
            etherDelta: 0
        });

        bytes32 outerCAP2 = _l1HashCAP2(cap2L2, app);
        bytes32 outerCounterL2 = _l1HashCounterL2(counterL2, app);
        bytes32 topCallCch = _l1TopCallCounterL1(counterL1, cap2L2);

        entries = new ExecutionEntry[](3);

        // [0] / [1]: one top-level L1 call (CAP2 → CounterL1) returning 1 then 2; no L1→L2 reentry.
        bytes32 rh0 = RollingHashBuilder.entryBegin(d0, outerCAP2);
        rh0 = RollingHashBuilder.appendCallBegin(rh0, topCallCch);
        rh0 = RollingHashBuilder.appendCallEnd(rh0, true, abi.encode(uint256(1)));
        entries[0] = ExecutionEntry({
            stateUpdates: d0,
            proxyEntryHash: outerCAP2,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls0,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh0,
            success: true,
            returnData: "" // incrementProxy() returns void
        });

        bytes32 rh1 = RollingHashBuilder.entryBegin(d1, outerCAP2);
        rh1 = RollingHashBuilder.appendCallBegin(rh1, topCallCch);
        rh1 = RollingHashBuilder.appendCallEnd(rh1, true, abi.encode(uint256(2)));
        entries[1] = ExecutionEntry({
            stateUpdates: d1,
            proxyEntryHash: outerCAP2, // same hash, sequential consumption
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls1,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh1,
            success: true,
            returnData: ""
        });

        // [2]: no L1-side execution (CounterL2 is L2-local); rolling hash is just the entry seed.
        entries[2] = ExecutionEntry({
            stateUpdates: d2,
            proxyEntryHash: outerCounterL2,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(d2, outerCounterL2),
            success: true,
            returnData: abi.encode(uint256(1)) // app.execute decodes this as `simpleResult`
        });
    }

    // ── L2 entries (3) ──

    function _l2Entries(address counterL1, address cap2L2, address counterL2, address app)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        entries = new L2ExecutionEntry[](3);
        entries[0] = _l2Cap2Entry(counterL1, cap2L2, app, 1);
        entries[1] = _l2Cap2Entry(counterL1, cap2L2, app, 2);
        entries[2] = _l2CounterEntry(counterL2, app);
    }

    /// @dev 1-entry table for the n-th CAP2 delivery (executeIncomingCrossChainCall tx).
    function _l2TableForCap2(address counterL1, address cap2L2, address app, uint256 n)
        internal
        pure
        returns (L2ExecutionEntry[] memory table)
    {
        table = new L2ExecutionEntry[](1);
        table[0] = _l2Cap2Entry(counterL1, cap2L2, app, n);
    }

    /// @dev 1-entry table for the CounterL2 delivery.
    function _l2TableForCounter(address counterL2, address app)
        internal
        pure
        returns (L2ExecutionEntry[] memory table)
    {
        table = new L2ExecutionEntry[](1);
        table[0] = _l2CounterEntry(counterL2, app);
    }

    /// @dev CAP2 delivery entry: top-level app→CAP2 call (inbound key = the L1-side hash,
    ///      folded again by CALL_BEGIN) wrapping one nested (outgoing) reentry to CounterL1
    ///      on MAINNET whose cached result is abi.encode(n).
    function _l2Cap2Entry(address counterL1, address cap2L2, address app, uint256 n)
        private
        pure
        returns (L2ExecutionEntry memory)
    {
        bytes32 entryHash = _l1HashCAP2(cap2L2, app);
        bytes32 innerCounterL1 = _l2InnerHashCounterL1(counterL1, cap2L2);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: app,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: cap2L2,
            value: 0,
            data: _incrementProxyData()
        });

        bytes32 rh = RollingHashBuilder.entryBeginL2(entryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, entryHash);
        bytes32 rhFire = rh;
        rh = RollingHashBuilder.appendNestedBegin(rh, innerCounterL1);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, ""); // incrementProxy returns void

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(innerCounterL1, rhFire),
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(n)
        });
        return L2ExecutionEntry({
            proxyEntryHash: entryHash,
            incomingCalls: calls,
            expectedOutgoingCalls: nested,
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }

    /// @dev CounterL2 delivery entry: simple inbound increment, no nesting.
    function _l2CounterEntry(address counterL2, address app) private pure returns (L2ExecutionEntry memory) {
        bytes32 entryHash = _l1HashCounterL2(counterL2, app);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: app,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: _incrementData()
        });

        bytes32 rh = RollingHashBuilder.entryBeginL2(entryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, entryHash);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));
        return L2ExecutionEntry({
            proxyEntryHash: entryHash,
            incomingCalls: calls,
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title Deploy — L1: CounterL1 + CallTwiceNestedAndOnce app
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        CallTwiceNestedAndOnce app = new CallTwiceNestedAndOnce();
        console.log("COUNTER_L1=%s", address(counterL1));
        console.log("CALL_TWICE_NESTED=%s", address(app));
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — L2: CounterL1 proxy + CAP2 (target=that proxy) + CounterL2
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        // Proxy on L2 for CounterL1 on MAINNET — used by CAP2 to reach back to L1.
        address counterL1ProxyL2 = getOrCreateProxy(IEEZ(address(manager)), counterL1, MAINNET_ROLLUP_ID);

        // CAP2: lives on L2, its `target` is CounterL1's proxy on L2 (so target.increment()
        // becomes a cross-chain call back to L1).
        CounterAndProxy cap2 = new CounterAndProxy(Counter(counterL1ProxyL2));

        // CounterL2: plain counter on L2.
        Counter counterL2 = new Counter();

        console.log("COUNTER_L1_PROXY_L2=%s", counterL1ProxyL2);
        console.log("COUNTER_AND_PROXY_L2=%s", address(cap2));
        console.log("COUNTER_L2=%s", address(counterL2));
        vm.stopBroadcast();
    }
}

/// @title Deploy2 — L1: trigger proxies for CAP2 L2 and CounterL2 L2
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address cap2 = vm.envAddress("COUNTER_AND_PROXY_L2");
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        EEZ rollups = EEZ(rollupsAddr);

        address cap2ProxyL1 = getOrCreateProxy(IEEZ(address(rollups)), cap2, L2_ROLLUP_ID);
        address counterL2ProxyL1 = getOrCreateProxy(IEEZ(address(rollups)), counterL2, L2_ROLLUP_ID);

        console.log("CAP2_PROXY_L1=%s", cap2ProxyL1);
        console.log("COUNTER_L2_PROXY_L1=%s", counterL2ProxyL1);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title Execute — L1 local mode: postAndVerifyBatch tx (3 entries) + app.execute() tx from
///        the EOA. The runner mines both in one block (execute_l1_same_block), satisfying the
///        same-block consumption gate.
contract Execute is Script, MCNActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address cap2 = vm.envAddress("COUNTER_AND_PROXY_L2");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address cap2ProxyL1 = vm.envAddress("CAP2_PROXY_L1");
        address counterL2ProxyL1 = vm.envAddress("COUNTER_L2_PROXY_L1");
        address app = vm.envAddress("CALL_TWICE_NESTED");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL1, cap2, counterL2, app), noStaticEntries()
                )
            );

        // sourceAddress = the app contract: EOA → app → proxy, so msg.sender at the
        // proxy is `app`. That's what the L1 entries' crossChainCallHashes commit to.
        uint256 simpleResult = CallTwiceNestedAndOnce(app).execute(cap2ProxyL1, counterL2ProxyL1);

        console.log("done");
        console.log("counterL1=%s (expected 2)", Counter(counterL1).counter());
        console.log("simpleResult=%s (expected 1)", simpleResult);
        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — L2 local mode: deliver the three inbound calls the way the system does,
///        one executeIncomingCrossChainCall tx per top-level call, each with a 1-entry table.
contract ExecuteL2 is Script, MCNActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address cap2 = vm.envAddress("COUNTER_AND_PROXY_L2");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address app = vm.envAddress("CALL_TWICE_NESTED");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);
        for (uint256 n = 1; n <= 2; n++) {
            manager.executeIncomingCrossChainCall(
                cap2,
                0,
                _incrementProxyData(),
                app,
                MAINNET_ROLLUP_ID,
                _l2TableForCap2(counterL1, cap2, app, n),
                noL2StaticEntries()
            );
        }
        manager.executeIncomingCrossChainCall(
            counterL2,
            0,
            _incrementData(),
            app,
            MAINNET_ROLLUP_ID,
            _l2TableForCounter(counterL2, app),
            noL2StaticEntries()
        );

        console.log("done");
        console.log("cap2.counter=%s (expected 2)", CounterAndProxy(cap2).counter());
        console.log("cap2.targetCounter=%s (expected 2)", CounterAndProxy(cap2).targetCounter());
        console.log("counterL2=%s (expected 1)", Counter(counterL2).counter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — network mode: user tx fields for the L1 trigger
contract ExecuteNetwork is Script {
    function run() external view {
        address app = vm.envAddress("CALL_TWICE_NESTED");
        address cap2ProxyL1 = vm.envAddress("CAP2_PROXY_L1");
        address counterL2ProxyL1 = vm.envAddress("COUNTER_L2_PROXY_L1");

        bytes memory data =
            abi.encodeWithSelector(CallTwiceNestedAndOnce.execute.selector, cap2ProxyL1, counterL2ProxyL1);

        console.log("TARGET=%s", app);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, MCNActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L2")) return "CAP2";
        if (a == vm.envAddress("COUNTER_L2")) return "CounterL2";
        if (a == vm.envAddress("CALL_TWICE_NESTED")) return "App(L1)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1 = vm.envAddress("COUNTER_L1");
        address cap2 = vm.envAddress("COUNTER_AND_PROXY_L2");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address app = vm.envAddress("CALL_TWICE_NESTED");

        ExecutionEntry[] memory l1 = _l1Entries(counterL1, cap2, counterL2, app);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL1, cap2, counterL2, app);

        bytes32 l1h0 = _entryHash(l1[0]);
        bytes32 l1h1 = _entryHash(l1[1]);
        bytes32 l1h2 = _entryHash(l1[2]);
        bytes32 l2h0 = _entryHash(l2[0]);
        bytes32 l2h1 = _entryHash(l2[1]);
        bytes32 l2h2 = _entryHash(l2[2]);

        console.log(
            string.concat(
                "EXPECTED_L1_HASHES=[", vm.toString(l1h0), ",", vm.toString(l1h1), ",", vm.toString(l1h2), "]"
            )
        );
        console.log(
            string.concat(
                "EXPECTED_L2_HASHES=[", vm.toString(l2h0), ",", vm.toString(l2h1), ",", vm.toString(l2h2), "]"
            )
        );
        _printL1CallHashes(l1);
        _printL2CallHashes(l2);
        _printL1Table(l1);
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (3 entries) ===");
        _logEntry(0, l1[0]);
        _logEntry(1, l1[1]);
        _logEntry(2, l1[2]);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (3 entries) ===");
        _logL2Entry(0, l2[0]);
        _logL2Entry(1, l2[1]);
        _logL2Entry(2, l2[2]);
    }
}
