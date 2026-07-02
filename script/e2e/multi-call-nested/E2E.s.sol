// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {
    EEZ,
    ProofSystemBatchPerVerificationEntries,
    ExpectedStateRootPerRollup,
    RollupIdWithProofSystems
} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {IEEZ} from "../../../src/interfaces/IEEZ.sol";
import {
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry,
    StaticLookup
} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticLookup as L2StaticLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {CallTwiceNestedAndOnce} from "../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    expectedL1toL2Hash,
    noStaticLookups,
    noL2StaticLookups,
    noNestedActions,
    noL2OutgoingCalls,
    noCalls,
    noL2Calls,
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
//    [0] [1]: l2ToL1Calls=[CAP2's reentrant call to CounterL1]; CounterL1.increment runs on L1.
//    [2]:    l2ToL1Calls=[]; just the L2 state delta + entry returnData=1 (rolling hash = entry seed).
//
//  L2 view (ExecuteL2): an L2_APP makes the 3 calls against L2 trigger proxies.
//    [0] [1]: incomingCalls=[CAP2 on L2 with source=L2_APP]; CAP2 reentrant-calls CounterL1
//             via COUNTER_L1_PROXY_L2 → ExpectedOutgoingCrossChainCall returns 1, then 2.
//    [2]:    incomingCalls=[CounterL2 on L2]; CounterL2.increment runs on L2.
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
        return crossChainCallHash(L2_ROLLUP_ID, cap2L2, 0, _incrementProxyData(), app, MAINNET_ROLLUP_ID);
    }

    function _l1HashCounterL2(address counterL2, address app) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, counterL2, 0, _incrementData(), app, MAINNET_ROLLUP_ID);
    }

    /// @dev L1 top-level call hash: CAP2 (logically on L2) reentrant-calls CounterL1 on L1.
    ///      Executes ON L1, so targetRollupId = MAINNET; source = CAP2 @ L2.
    function _l1TopCallCounterL1(address counterL1, address cap2L2) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, counterL1, 0, _incrementData(), cap2L2, L2_ROLLUP_ID);
    }

    // ── L2 hashes (PENDING EEZL2: re-verify once EEZL2.sol lands) ──

    /// @dev L2 proxy-entry / top-level call hash for app→CAP2 on L2 (target on this L2 → ROLLUP_ID).
    function _l2HashCAP2(address cap2L2, address l2App) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, cap2L2, 0, _incrementProxyData(), l2App, MAINNET_ROLLUP_ID);
    }

    function _l2HashCounterL2(address counterL2, address l2App) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, counterL2, 0, _incrementData(), l2App, MAINNET_ROLLUP_ID);
    }

    /// @dev Inner reentrant (outgoing) hash on L2: CAP2 (on L2) calls CounterL1 MAINNET; the L2
    ///      manager forces sourceRollupId = ROLLUP_ID (=L2). Mirrors the L1 top-level call hash.
    function _l2InnerHashCounterL1(address counterL1, address cap2L2) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, counterL1, 0, _incrementData(), cap2L2, L2_ROLLUP_ID);
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

        StateDelta[] memory d0 = new StateDelta[](1);
        d0[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-mcn-step-1"),
            etherDelta: 0
        });
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-mcn-step-1"),
            newState: keccak256("l2-mcn-step-2"),
            etherDelta: 0
        });
        StateDelta[] memory d2 = new StateDelta[](1);
        d2[0] = StateDelta({
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
            stateDeltas: d0,
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
            stateDeltas: d1,
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
            stateDeltas: d2,
            proxyEntryHash: outerCounterL2,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(d2, outerCounterL2),
            success: true,
            returnData: abi.encode(uint256(1)) // app.execute decodes this as `simpleResult`
        });
    }

    // ── L2 entries (3) — PENDING EEZL2: re-verify once EEZL2.sol lands ──

    function _l2Entries(address counterL1, address cap2L2, address counterL2, address l2App)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        // Two distinct hashes per L2 entry:
        //  - proxyEntryHash (entry MATCH): what `executeCrossChainCall` computes when the trigger fires
        //    through the L2 ingress proxy — source = l2App @ ROLLUP_ID (forced), target = the proxy's
        //    original (cap2/counterL2 @ MAINNET). See EEZL2.executeCrossChainCall.
        //  - outer* (CALL_BEGIN fold): what `_processNCalls` folds from `incomingCalls[0]` — target @
        //    ROLLUP_ID (forced), source = l2App @ the call's `sourceRollupId` (MAINNET).
        bytes32 entryHashCAP2 =
            crossChainCallHash(MAINNET_ROLLUP_ID, cap2L2, 0, _incrementProxyData(), l2App, L2_ROLLUP_ID);
        bytes32 entryHashCounterL2 =
            crossChainCallHash(MAINNET_ROLLUP_ID, counterL2, 0, _incrementData(), l2App, L2_ROLLUP_ID);
        bytes32 outerCAP2 = _l2HashCAP2(cap2L2, l2App);
        bytes32 outerCounterL2 = _l2HashCounterL2(counterL2, l2App);
        bytes32 innerCounterL1 = _l2InnerHashCounterL1(counterL1, cap2L2);

        // Outer call shared by entries [0] and [1]: app→CAP2 on L2.
        // sourceRollupId is the REMOTE counterparty (MAINNET) — never this L2's own id,
        // which `_processNCalls` would reject with SameNetworkProxy when auto-creating the
        // source proxy.
        CrossChainCall memory cap2RunCall = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: l2App,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: cap2L2,
            value: 0,
            data: _incrementProxyData()
        });
        // Outer call for entry [2]: app→CounterL2 on L2.
        CrossChainCall memory counterL2RunCall = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: l2App,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: _incrementData()
        });

        CrossChainCall[] memory calls0 = new CrossChainCall[](1);
        calls0[0] = cap2RunCall;
        CrossChainCall[] memory calls1 = new CrossChainCall[](1);
        calls1[0] = cap2RunCall;
        CrossChainCall[] memory calls2 = new CrossChainCall[](1);
        calls2[0] = counterL2RunCall;

        entries = new L2ExecutionEntry[](3);

        // [0] / [1]: top-level CAP2 call wraps one nested (outgoing) reentry to CounterL1@MAINNET.
        // PENDING EEZL2: rolling-hash seed/append shape mirrors L1.
        bytes32 rh0 = RollingHashBuilder.entryBeginL2(entryHashCAP2);
        rh0 = RollingHashBuilder.appendCallBegin(rh0, outerCAP2);
        bytes32 rhFire0 = rh0;
        rh0 = RollingHashBuilder.appendNestedBegin(rh0, innerCounterL1);
        rh0 = RollingHashBuilder.appendNestedEnd(rh0);
        rh0 = RollingHashBuilder.appendCallEnd(rh0, true, ""); // incrementProxy returns void

        ExpectedOutgoingCrossChainCall[] memory nested0 = new ExpectedOutgoingCrossChainCall[](1);
        nested0[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(innerCounterL1, rhFire0),
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: entryHashCAP2,
            incomingCalls: calls0,
            expectedOutgoingCalls: nested0,
            rollingHash: rh0,
            success: true,
            returnData: ""
        });

        bytes32 rh1 = RollingHashBuilder.entryBeginL2(entryHashCAP2);
        rh1 = RollingHashBuilder.appendCallBegin(rh1, outerCAP2);
        bytes32 rhFire1 = rh1;
        rh1 = RollingHashBuilder.appendNestedBegin(rh1, innerCounterL1);
        rh1 = RollingHashBuilder.appendNestedEnd(rh1);
        rh1 = RollingHashBuilder.appendCallEnd(rh1, true, "");

        ExpectedOutgoingCrossChainCall[] memory nested1 = new ExpectedOutgoingCrossChainCall[](1);
        nested1[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(innerCounterL1, rhFire1),
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(2))
        });
        entries[1] = L2ExecutionEntry({
            proxyEntryHash: entryHashCAP2,
            incomingCalls: calls1,
            expectedOutgoingCalls: nested1,
            rollingHash: rh1,
            success: true,
            returnData: ""
        });

        // [2]: simple call to CounterL2 on L2, no nesting.
        bytes32 rh2 = RollingHashBuilder.entryBeginL2(entryHashCounterL2);
        rh2 = RollingHashBuilder.appendCallBegin(rh2, outerCounterL2);
        rh2 = RollingHashBuilder.appendCallEnd(rh2, true, abi.encode(uint256(1)));
        entries[2] = L2ExecutionEntry({
            proxyEntryHash: entryHashCounterL2,
            incomingCalls: calls2,
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: rh2,
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Batchers (one tx each → all consumption lands in the same block)
// ═══════════════════════════════════════════════════════════════════════

contract Batcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        StaticLookup[] calldata staticLookups,
        CallTwiceNestedAndOnce app,
        address nestedProxy,
        address simpleProxy
    )
        external
        returns (uint256)
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        uint64[] memory rids = new uint64[](1);
        rids[0] = L2_ROLLUP_ID;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](psList.length);
        for (uint256 _i = 0; _i < psList.length; _i++) {
            psIdx[_i] = uint64(_i);
        }
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](rids.length);
        for (uint256 _i = 0; _i < rids.length; _i++) {
            rps[_i] = RollupIdWithProofSystems({rollupId: rids[_i], proofSystemIndexes: psIdx});
        }

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            expectedStateRootPerRollup: new ExpectedStateRootPerRollup[](0),
            entries: entries,
            staticLookups: staticLookups,
            immediateEntryCount: 0,
            immediateStaticLookupCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs,
            blockNumber: 0
        });
        rollups.postAndVerifyBatch(batch);
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
        EEZL2 manager = EEZL2(managerAddr);

        // Proxy on L2 for CounterL1 on MAINNET — used by CAP2 to reach back to L1.
        address counterL1ProxyL2 = getOrCreateProxy(IEEZ(address(manager)), counterL1, MAINNET_ROLLUP_ID);

        // CAP2: lives on L2, its `target` is CounterL1's proxy on L2 (so target.increment()
        // becomes a cross-chain call back to L1).
        CounterAndProxy cap2 = new CounterAndProxy(Counter(counterL1ProxyL2));

        // CounterL2: plain counter on L2.
        Counter counterL2 = new Counter();

        // L2_APP: same CallTwiceNestedAndOnce contract, deployed on L2 to act as the L2-side
        // orchestrator. Its address (≠ L1 app's address) is what shows up as sourceAddress in
        // L2 entries — full source symmetry isn't possible without contract-level impersonation.
        CallTwiceNestedAndOnce l2App = new CallTwiceNestedAndOnce();

        // Trigger proxies on L2: tagged originalRollupId=MAINNET so the call hash inverts to
        // (rollup=MAINNET, target=<L2 contract addr>, sourceRollup=L2). This gives L2_APP a
        // proxy entry-point that consumes the L2 entries.
        address nestedProxyL2 = getOrCreateProxy(IEEZ(address(manager)), address(cap2), MAINNET_ROLLUP_ID);
        address simpleProxyL2 = getOrCreateProxy(IEEZ(address(manager)), address(counterL2), MAINNET_ROLLUP_ID);

        console.log("COUNTER_L1_PROXY_L2=%s", counterL1ProxyL2);
        console.log("COUNTER_AND_PROXY_L2=%s", address(cap2));
        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("L2_APP=%s", address(l2App));
        console.log("NESTED_PROXY_L2=%s", nestedProxyL2);
        console.log("SIMPLE_PROXY_L2=%s", simpleProxyL2);
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

/// @title Execute — L1 local mode: postAndVerifyBatch (3 entries) + app.execute() via Batcher
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
        Batcher batcher = new Batcher();

        // sourceAddress = the app contract: Batcher → app → proxy, so msg.sender at the
        // proxy is `app`. That's what the L1 entries' crossChainCallHashes commit to.
        uint256 simpleResult = batcher.execute(
            EEZ(rollupsAddr),
            proofSystemAddr,
            _l1Entries(counterL1, cap2, counterL2, app),
            noStaticLookups(),
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
        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterL1, cap2, counterL2, l2App), noL2StaticLookups());

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
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL1, cap2, counterL2, l2App);

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
