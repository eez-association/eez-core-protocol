// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {ICrossChainManager} from "../../../src/ICrossChainManager.sol";
import {
    Action,
    StateDelta,
    CrossChainCall,
    NestedAction,
    ExecutionEntry,
    StaticCall
} from "../../../src/ICrossChainManager.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {CallTwiceNestedAndOnce} from "../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    actionHash,
    noStaticCalls,
    noNestedActions,
    noCalls,
    getOrCreateProxy,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  multi-call-nested — L1-anchored, with real L1↔L2↔L1 round-trip nesting
//
//  Actor cast (matches the legacy ActionType-model test, ported to flatten):
//    L1: CounterL1 (real), CallTwiceNestedAndOnce (app)
//    L2: CounterL1ProxyOnL2, CounterAndProxyL2 (CAP2; target=CounterL1ProxyOnL2),
//        CounterL2 (real), L2_APP (CallTwiceNestedAndOnce on L2)
//    L1: CAP2_PROXY_L1 (proxy for CAP2@L2), COUNTER_L2_PROXY_L1 (proxy for CounterL2@L2)
//    L2: NESTED_PROXY_L2 (proxy for CAP2@MAINNET; trigger ingress on L2),
//        SIMPLE_PROXY_L2 (proxy for CounterL2@MAINNET; trigger ingress on L2)
//
//  app.execute(nestedProxy, simpleProxy) on L1 makes 3 cross-chain calls:
//    1. nestedProxy.incrementProxy() → CAP2 on L2 → reentrant → CounterL1 on L1 (returns 1)
//    2. nestedProxy.incrementProxy() → CAP2 on L2 → reentrant → CounterL1 on L1 (returns 2)
//    3. simpleProxy.increment()      → CounterL2 on L2 (returns 1)
//
//  L1 view (Execute): each app call consumes one of 3 L1 entries.
//    [0] [1]: calls=[CAP2's reentrant call to CounterL1]; CounterL1.increment runs on L1.
//    [2]:    calls=[]; callCount=0; just the L2 state delta + entry returnData=1.
//
//  L2 view (ExecuteL2): an L2_APP makes the 3 calls against L2 trigger proxies.
//    [0] [1]: calls=[CAP2 on L2 with source=L2_APP]; CAP2 reentrant-calls CounterL1
//             via COUNTER_L1_PROXY_L2 → NestedAction lookup returns 1, then 2.
//    [2]:    calls=[CounterL2 on L2]; CounterL2.increment runs on L2.
//
//  Final state:
//    L1: CounterL1.counter == 2          (incremented by entries [0] and [1])
//        app.execute returns 1           (CounterL2's first return, surfaced via entry [2])
//    L2: CAP2.counter == 2, CAP2.targetCounter == 2,  CounterL2.counter == 1
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract MCNActions {
    using RollingHashBuilder for bytes32;

    // ── L1 outer action hashes (sourceRollup=MAINNET; the trigger lives on L1) ──

    function _l1HashCAP2(address cap2L2, address app) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: cap2L2,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: app,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    function _l1HashCounterL2(address counterL2, address app) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: app,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    // ── L2 outer action hashes (the L2 manager forces sourceRollup=ROLLUP_ID
    //    on every executeCrossChainCall; the trigger proxies on L2 are tagged
    //    originalRollupId=MAINNET so the hash inverts cleanly) ──

    function _l2HashCAP2(address cap2L2, address l2App) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: MAINNET_ROLLUP_ID,
            targetAddress: cap2L2,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: l2App,
            sourceRollupId: L2_ROLLUP_ID
        }));
    }

    function _l2HashCounterL2(address counterL2, address l2App) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: l2App,
            sourceRollupId: L2_ROLLUP_ID
        }));
    }

    /// @dev Inner reentrant hash on L2: CAP2 (running on L2) calls CounterL1@L1.
    function _l2InnerHashCounterL1(address counterL1, address cap2L2) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: cap2L2,
            sourceRollupId: L2_ROLLUP_ID
        }));
    }

    // ── Rolling hashes ──

    /// @dev L1 entries [0]/[1]: a single inner call (CAP2's reentrant call to CounterL1).
    function _l1NestedHash(uint256 retVal) internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendCallEnd(1, true, abi.encode(retVal));
    }

    /// @dev L2 entries [0]/[1]: outer call to CAP2 + 1 nested action (CAP2 → CounterL1).
    function _l2NestedHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendNestedBegin(1);
        h = h.appendNestedEnd(1);
        h = h.appendCallEnd(1, true, "");           // incrementProxy returns nothing
    }

    /// @dev L2 entry [2]: simple call to CounterL2.
    function _l2SimpleHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendCallEnd(1, true, abi.encode(uint256(1)));
    }

    // ── L1 entries (3) ──

    function _l1Entries(address counterL1, address cap2L2, address counterL2, address app)
        internal pure
        returns (ExecutionEntry[] memory entries)
    {
        // Inner call shared by entries [0] and [1]: CAP2 (logically on L2) reentrant-calls
        // CounterL1 on L1. The L1 manager auto-resolves CAP2's source-proxy and forwards.
        CrossChainCall memory cap2CallsCounterL1 = CrossChainCall({
            targetAddress: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: cap2L2,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });
        CrossChainCall[] memory calls0 = new CrossChainCall[](1);
        calls0[0] = cap2CallsCounterL1;
        CrossChainCall[] memory calls1 = new CrossChainCall[](1);
        calls1[0] = cap2CallsCounterL1;

        StateDelta[] memory d0 = new StateDelta[](1);
        d0[0] = StateDelta({rollupId: L2_ROLLUP_ID, newState: keccak256("l2-mcn-step-1"), etherDelta: 0});
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: L2_ROLLUP_ID, newState: keccak256("l2-mcn-step-2"), etherDelta: 0});
        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({rollupId: L2_ROLLUP_ID, newState: keccak256("l2-mcn-step-3"), etherDelta: 0});

        bytes32 outerCAP2 = _l1HashCAP2(cap2L2, app);
        bytes32 outerCounterL2 = _l1HashCounterL2(counterL2, app);

        entries = new ExecutionEntry[](3);
        entries[0] = ExecutionEntry({
            stateDeltas: d0,
            actionHash: outerCAP2,
            calls: calls0,
            nestedActions: noNestedActions(),
            callCount: 1,
            returnData: "",                              // incrementProxy() returns void
            failed: false,
            rollingHash: _l1NestedHash(1)
        });
        entries[1] = ExecutionEntry({
            stateDeltas: d1,
            actionHash: outerCAP2,                       // same hash, sequential consumption
            calls: calls1,
            nestedActions: noNestedActions(),
            callCount: 1,
            returnData: "",
            failed: false,
            rollingHash: _l1NestedHash(2)
        });
        entries[2] = ExecutionEntry({
            stateDeltas: d2,
            actionHash: outerCounterL2,
            calls: noCalls(),                            // no L1-side execution; CounterL2 is L2-local
            nestedActions: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(1)),          // app.execute decodes this as `simpleResult`
            failed: false,
            rollingHash: bytes32(0)
        });
    }

    // ── L2 entries (3) ──

    function _l2Entries(address counterL1, address cap2L2, address counterL2, address l2App)
        internal pure
        returns (ExecutionEntry[] memory entries)
    {
        bytes32 outerCAP2 = _l2HashCAP2(cap2L2, l2App);
        bytes32 outerCounterL2 = _l2HashCounterL2(counterL2, l2App);
        bytes32 innerCounterL1 = _l2InnerHashCounterL1(counterL1, cap2L2);

        // Outer call shared by entries [0] and [1]: app→CAP2 on L2.
        CrossChainCall memory cap2RunCall = CrossChainCall({
            targetAddress: cap2L2,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: l2App,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });
        // Outer call for entry [2]: app→CounterL2 on L2.
        CrossChainCall memory counterL2RunCall = CrossChainCall({
            targetAddress: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: l2App,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });

        CrossChainCall[] memory calls0 = new CrossChainCall[](1);
        calls0[0] = cap2RunCall;
        CrossChainCall[] memory calls1 = new CrossChainCall[](1);
        calls1[0] = cap2RunCall;
        CrossChainCall[] memory calls2 = new CrossChainCall[](1);
        calls2[0] = counterL2RunCall;

        NestedAction[] memory nested0 = new NestedAction[](1);
        nested0[0] = NestedAction({
            actionHash: innerCounterL1,
            callCount: 0,
            returnData: abi.encode(uint256(1))
        });
        NestedAction[] memory nested1 = new NestedAction[](1);
        nested1[0] = NestedAction({
            actionHash: innerCounterL1,
            callCount: 0,
            returnData: abi.encode(uint256(2))
        });

        entries = new ExecutionEntry[](3);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            actionHash: outerCAP2,
            calls: calls0,
            nestedActions: nested0,
            callCount: 1,
            returnData: "",
            failed: false,
            rollingHash: _l2NestedHash()
        });
        entries[1] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            actionHash: outerCAP2,
            calls: calls1,
            nestedActions: nested1,
            callCount: 1,
            returnData: "",
            failed: false,
            rollingHash: _l2NestedHash()
        });
        entries[2] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            actionHash: outerCounterL2,
            calls: calls2,
            nestedActions: noNestedActions(),
            callCount: 1,
            returnData: abi.encode(uint256(1)),
            failed: false,
            rollingHash: _l2SimpleHash()
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Batchers (one tx each → all consumption lands in the same block)
// ═══════════════════════════════════════════════════════════════════════

contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata statics,
        CallTwiceNestedAndOnce app,
        address nestedProxy,
        address simpleProxy
    ) external returns (uint256) {
        rollups.postBatch(entries, statics, 0, 0, 0, "", "proof");
        return app.execute(nestedProxy, simpleProxy);
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

/// @title DeployL2 — L2: CounterL1 proxy + CAP2 (target=that proxy) + CounterL2 + L2_APP + L2 trigger proxies
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        CrossChainManagerL2 manager = CrossChainManagerL2(managerAddr);

        // Proxy on L2 for CounterL1 on MAINNET — used by CAP2 to reach back to L1.
        address counterL1ProxyL2 = getOrCreateProxy(ICrossChainManager(address(manager)), counterL1, MAINNET_ROLLUP_ID);

        // CAP2: lives on L2, its `target` is CounterL1's proxy on L2 (so target.increment()
        // becomes a cross-chain call back to L1).
        CounterAndProxy cap2 = new CounterAndProxy(Counter(counterL1ProxyL2));

        // CounterL2: plain counter on L2.
        Counter counterL2 = new Counter();

        // L2_APP: same CallTwiceNestedAndOnce contract, deployed on L2 to act as the L2-side
        // orchestrator. Its address (≠ L1 app's address) is what shows up as sourceAddress in
        // L2 entries — full source symmetry isn't possible without contract-level impersonation.
        CallTwiceNestedAndOnce l2App = new CallTwiceNestedAndOnce();

        // Trigger proxies on L2: tagged originalRollupId=MAINNET so the actionHash inverts to
        // (rollup=MAINNET, target=<L2 contract addr>, sourceRollup=L2). This gives L2_APP a
        // proxy entry-point that consumes the L2 entries.
        address nestedProxyL2 = getOrCreateProxy(ICrossChainManager(address(manager)), address(cap2), MAINNET_ROLLUP_ID);
        address simpleProxyL2 = getOrCreateProxy(ICrossChainManager(address(manager)), address(counterL2), MAINNET_ROLLUP_ID);

        console.log("COUNTER_L1_PROXY_L2=%s", counterL1ProxyL2);
        console.log("COUNTER_AND_PROXY_L2=%s", address(cap2));
        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("L2_APP=%s", address(l2App));
        console.log("NESTED_PROXY_L2=%s", nestedProxyL2);
        console.log("SIMPLE_PROXY_L2=%s", simpleProxyL2);
        vm.stopBroadcast();
    }
}

/// @title Deploy2 — L1: trigger proxies for CAP2@L2 and CounterL2@L2
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address cap2 = vm.envAddress("COUNTER_AND_PROXY_L2");
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        Rollups rollups = Rollups(rollupsAddr);

        address cap2ProxyL1 = getOrCreateProxy(ICrossChainManager(address(rollups)), cap2, L2_ROLLUP_ID);
        address counterL2ProxyL1 = getOrCreateProxy(ICrossChainManager(address(rollups)), counterL2, L2_ROLLUP_ID);

        console.log("CAP2_PROXY_L1=%s", cap2ProxyL1);
        console.log("COUNTER_L2_PROXY_L1=%s", counterL2ProxyL1);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title Execute — L1 local mode: postBatch (3 entries) + app.execute() via Batcher
contract Execute is Script, MCNActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address cap2 = vm.envAddress("COUNTER_AND_PROXY_L2");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address cap2ProxyL1 = vm.envAddress("CAP2_PROXY_L1");
        address counterL2ProxyL1 = vm.envAddress("COUNTER_L2_PROXY_L1");
        address app = vm.envAddress("CALL_TWICE_NESTED");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        // sourceAddress = the app contract: Batcher → app → proxy, so msg.sender at the
        // proxy is `app`. That's what the L1 entries' actionHashes commit to.
        uint256 simpleResult = batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(counterL1, cap2, counterL2, app),
            noStaticCalls(),
            CallTwiceNestedAndOnce(app),
            cap2ProxyL1,
            counterL2ProxyL1
        );

        console.log("done");
        console.log("counterL1=%s (expected 2)", Counter(counterL1).counter());
        console.log("simpleResult=%s (expected 1)", simpleResult);
        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — L2 local mode: loadExecutionTable + L2_APP.execute()
/// @dev Both txs land in the same block via the run-local.sh evm_setAutomine wrapper.
contract ExecuteL2 is Script, MCNActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address cap2 = vm.envAddress("COUNTER_AND_PROXY_L2");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address l2App = vm.envAddress("L2_APP");
        address nestedProxyL2 = vm.envAddress("NESTED_PROXY_L2");
        address simpleProxyL2 = vm.envAddress("SIMPLE_PROXY_L2");

        vm.startBroadcast();
        CrossChainManagerL2(managerAddr).loadExecutionTable(
            _l2Entries(counterL1, cap2, counterL2, l2App),
            noStaticCalls()
        );

        uint256 simpleResult = CallTwiceNestedAndOnce(l2App).execute(nestedProxyL2, simpleProxyL2);

        console.log("done");
        console.log("cap2.counter=%s (expected 2)", CounterAndProxy(cap2).counter());
        console.log("cap2.targetCounter=%s (expected 2)", CounterAndProxy(cap2).targetCounter());
        console.log("counterL2=%s (expected 1)", Counter(counterL2).counter());
        console.log("simpleResult=%s (expected 1)", simpleResult);
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
        if (a == vm.envAddress("L2_APP")) return "App(L2)";
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
        address l2App = vm.envAddress("L2_APP");

        ExecutionEntry[] memory l1 = _l1Entries(counterL1, cap2, counterL2, app);
        ExecutionEntry[] memory l2 = _l2Entries(counterL1, cap2, counterL2, l2App);

        bytes32 l1h0 = _entryHash(l1[0]);
        bytes32 l1h1 = _entryHash(l1[1]);
        bytes32 l1h2 = _entryHash(l1[2]);
        bytes32 l2h0 = _entryHash(l2[0]);
        bytes32 l2h1 = _entryHash(l2[1]);
        bytes32 l2h2 = _entryHash(l2[2]);

        console.log(
            string.concat(
                "EXPECTED_L1_HASHES=[",
                vm.toString(l1h0), ",", vm.toString(l1h1), ",", vm.toString(l1h2), "]"
            )
        );
        console.log(
            string.concat(
                "EXPECTED_L2_HASHES=[",
                vm.toString(l2h0), ",", vm.toString(l2h1), ",", vm.toString(l2h2), "]"
            )
        );

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
