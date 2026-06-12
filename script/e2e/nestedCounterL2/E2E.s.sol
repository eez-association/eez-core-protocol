// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {IEEZ} from "../../../src/interfaces/IEEZ.sol";
import {
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry,
    LookupCall,
    ExpectedLookup
} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    LookupCall as L2LookupCall,
    ExpectedLookup as L2ExpectedLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noLookupCalls,
    noL2LookupCalls,
    getOrCreateProxy,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  NestedCounterL2 scenario — exercises expectedOutgoingCalls[] on L2 side (two-sided)
//
//  L2 side (ExecuteL2):
//    1. loadExecutionTable loads ONE entry with incomingCalls[] + expectedOutgoingCalls[].
//    2. Alice calls capL1Proxy (proxy for CAP@MAINNET on L2) → entry consumed.
//    3. _processNCalls: incomingCalls[0] routes via source proxy (alice, L1) → cap.incrementProxy().
//    4. CAP calls counterProxy (proxy for Counter@L1 on L2) → nested action consumed.
//    5. Nested action returns abi.encode(1) → CAP reads targetCounter=1.
//
//  L1 side (Execute):
//    1. postAndVerifyBatch loads ONE deferred entry
//       (proxyEntryHash=0 — system-driven) whose l2ToL1Calls describe the L1 mirror:
//       cap@L2 calls capL1@L1.incrementProxy().
//    2. executeL2TX(L2_ROLLUP_ID) drains via _processNCalls.
//    3. _processNCalls forwards through the lazily-created source proxy for
//       (cap@L2, L2_ROLLUP_ID) on L1 into capL1.incrementProxy() on L1.
//    4. capL1.target = counterL2TargetProxy (proxy on L1 for counterL2Target@L2) —
//       capL1 reentrant-calls cross-chain.  EEZ._consumeNestedAction matches the
//       inner hash against expectedL1ToL2Calls[0] and returns the cached 1.
//
//  Mirror of nestedCounter (which is L1-anchored).
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedL2Actions {
    using RollingHashBuilder for bytes32;

    // ── L2 hashes (the original anchor) ────────────────────────────────

    /// Inner: CAP (on L2) reentrant-calls Counter on MAINNET.
    function _l2InnerHash(address counterL1, address cap) internal pure returns (bytes32) {
        return crossChainCallHash(
            MAINNET_ROLLUP_ID, counterL1, 0, abi.encodeWithSelector(Counter.increment.selector), cap, L2_ROLLUP_ID
        );
    }

    /// Outer: alice calls capL1Proxy (proxy for CAP on MAINNET) on L2.
    function _l2OuterHash(address cap, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(
            MAINNET_ROLLUP_ID,
            cap,
            0,
            abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            alice,
            L2_ROLLUP_ID
        );
    }

    // ── L1 mirror hashes ───────────────────────────────────────────────

    /// Inner on L1: capL1 (on MAINNET) reentrant-calls counterL2Target on L2 via the
    /// L1-side cross-chain proxy. EEZ keeps sourceRollupId=MAINNET for L1-originated calls.
    function _l1InnerHash(address counterL2Target, address capL1) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID,
            counterL2Target,
            0,
            abi.encodeWithSelector(Counter.increment.selector),
            capL1,
            MAINNET_ROLLUP_ID
        );
    }

    /// Rolling hash chain: CALL_BEGIN(1) → NESTED_BEGIN(1) → NESTED_END(1) → CALL_END(1, true, "")
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendNestedBegin(1);
        h = h.appendNestedEnd(1);
        h = h.appendCallEnd(1, true, "");
    }

    function _l2Entries(address counterL1, address cap, address alice)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            targetAddress: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID, // matches the entry's outer src — Alice on L2
            revertSpan: 0
        });

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            crossChainCallHash: _l2InnerHash(counterL1, cap), callCount: 0, returnData: abi.encode(uint256(1))
        });

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: _l2OuterHash(cap, alice),
            incomingCalls: calls,
            expectedOutgoingCalls: nested,
            expectedLookups: new L2ExpectedLookup[](0),
            callCount: 1,
            returnData: "",
            rollingHash: _expectedRollingHash()
        });
    }

    /// L1 mirror entry — system-driven (proxyEntryHash=0); drained by executeL2TX(L2_ROLLUP_ID).
    /// `l2ToL1Calls[0]` is the inbound call delivered through the source proxy for (cap, L2) on L1.
    function _l1Entries(address counterL2Target, address capL1, address capL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: capL1,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: capL2,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            crossChainCallHash: _l1InnerHash(counterL2Target, capL1), callCount: 0, returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            expectedLookups: new ExpectedLookup[](0),
            callCount: 1,
            returnData: "",
            rollingHash: _expectedRollingHash()
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys — three-phase order matches multi-call-nested:
//    1. Deploy (L1) — just counterL1, the destination for the L2-anchored nested call.
//    2. DeployL2 (L2) — counterProxy (for counterL1) + cap + capL1Proxy + counterL2Target.
//    3. Deploy2 (L1) — L1-side proxy for counterL2Target + capL1 (mirror CAP).
// ═══════════════════════════════════════════════════════════════════════

// Outputs: COUNTER_L1 (the L2-anchored destination on MAINNET)
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));
        vm.stopBroadcast();
    }
}

// Env: MANAGER_L2, COUNTER_L1
// Outputs: COUNTER_PROXY_L2, COUNTER_AND_PROXY_L2, CAP_L1_PROXY, COUNTER_L2_TARGET
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        // Proxy for counterL1 on MAINNET — used by cap (on L2) to reach L1.
        address counterProxy = getOrCreateProxy(IEEZ(address(manager)), counterL1Addr, MAINNET_ROLLUP_ID);

        // cap on L2 — target is counterProxy.
        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        // Proxy on L2 for cap on MAINNET (trigger point alice calls).
        address capL1Proxy = getOrCreateProxy(IEEZ(address(manager)), address(cap), MAINNET_ROLLUP_ID);

        // counterL2Target — separate Counter on L2 used by the L1 mirror's nested call.
        Counter counterL2Target = new Counter();

        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        console.log("COUNTER_AND_PROXY_L2=%s", address(cap));
        console.log("CAP_L1_PROXY=%s", capL1Proxy);
        console.log("COUNTER_L2_TARGET=%s", address(counterL2Target));
        vm.stopBroadcast();
    }
}

// Env: ROLLUPS, COUNTER_L2_TARGET
// Outputs: COUNTER_L2_TARGET_PROXY, COUNTER_AND_PROXY_L1
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2TargetAddr = vm.envAddress("COUNTER_L2_TARGET");

        vm.startBroadcast();

        // L1-side proxy for counterL2Target on L2 — capL1.target = this proxy.
        address counterL2TargetProxy = getOrCreateProxy(IEEZ(rollupsAddr), counterL2TargetAddr, L2_ROLLUP_ID);

        // capL1 — CAP on L1 whose target is the L1-side proxy for counterL2Target.
        // capL1.incrementProxy() reentrant-calls counterL2Target via the cross-chain proxy.
        CounterAndProxy capL1 = new CounterAndProxy(Counter(counterL2TargetProxy));

        console.log("COUNTER_L2_TARGET_PROXY=%s", counterL2TargetProxy);
        console.log("COUNTER_AND_PROXY_L1=%s", address(capL1));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// ExecuteL2 — loadExecutionTable + trigger via capL1Proxy in same block.
contract ExecuteL2 is Script, NestedL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address capL1Proxy = vm.envAddress("CAP_L1_PROXY");

        vm.startBroadcast();
        address alice = msg.sender;
        console.log("ExecuteL2: alice=%s cap=%s capL1Proxy=%s", alice, capAddr, capL1Proxy);

        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterL1Addr, capAddr, alice), noL2LookupCalls());
        console.log("ExecuteL2: loadExecutionTable done");

        (bool ok,) = capL1Proxy.call(abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector));
        require(ok, "outer call failed");
        console.log("ExecuteL2: trigger done");

        console.log("done");
        console.log("cap.counter=%s", CounterAndProxy(capAddr).counter());
        console.log("cap.targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

/// Inline L2-TX batcher — postBatch (deferred) + executeL2TX in one tx.
/// Overrides transientExecutionEntryCount=0 so the zero-hash entry stays in the deferred
/// queue and is drained by the subsequent executeL2TX(rollupId) call.
contract DeferredL2TXBatcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        uint256 rollupId,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls
    )
        external
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";

        uint64[] memory psIdx = new uint64[](1);
        psIdx[0] = 0;
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: rollupId, proofSystemIndex: psIdx});

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            blockNumber: 0,
            entries: entries,
            l1ToL2lookupCalls: lookupCalls,
            transientExecutionEntryCount: 0,
            transientLookupCallCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
        rollups.executeL2TX(rollupId);
    }
}

/// Execute — L1 mirror: postBatch (deferred) + executeL2TX drains the entry, running
/// the nested-call pattern entirely on L1.
contract Execute is Script, NestedL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2TargetAddr = vm.envAddress("COUNTER_L2_TARGET");
        address capL1Addr = vm.envAddress("COUNTER_AND_PROXY_L1");
        address capL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        vm.startBroadcast();
        DeferredL2TXBatcher batcher = new DeferredL2TXBatcher();
        batcher.execute(
            EEZ(rollupsAddr),
            proofSystemAddr,
            L2_ROLLUP_ID,
            _l1Entries(counterL2TargetAddr, capL1Addr, capL2Addr),
            noLookupCalls()
        );

        console.log("done");
        console.log("capL1.counter=%s", CounterAndProxy(capL1Addr).counter());
        console.log("capL1.targetCounter=%s", CounterAndProxy(capL1Addr).targetCounter());
        vm.stopBroadcast();
    }
}

contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("CAP_L1_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, NestedL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("COUNTER_L2_TARGET")) return "CounterL2Target";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L2")) return "CAP(L2)";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L1")) return "CAP(L1)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterL2TargetAddr = vm.envAddress("COUNTER_L2_TARGET");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address capL1Addr = vm.envAddress("COUNTER_AND_PROXY_L1");
        address alice = msg.sender;

        L2ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, capAddr, alice);
        ExecutionEntry[] memory l1 = _l1Entries(counterL2TargetAddr, capL1Addr, capAddr);

        bytes32 l2Hash = _entryHash(l2[0]);
        bytes32 l1Hash = _entryHash(l1[0]);

        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2[0].proxyEntryHash));

        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 1 nested) ===");
        _logL2Entry(0, l2[0]);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, 1 nested) ===");
        _logEntry(0, l1[0]);
    }
}
