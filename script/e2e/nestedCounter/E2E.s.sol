// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
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
    Action,
    actionHash,
    noLookupCalls,
    noL2LookupCalls,
    getOrCreateProxy,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  NestedCounter scenario — exercises ExecutionEntry.expectedL1ToL2Calls[] (two-sided)
//
//  L1 side (Execute):
//    1. Alice triggers an outer entry consumption via the L1-side CAP@L2 proxy.
//    2. Entry.l2ToL1Calls[0] invokes CounterAndProxy.incrementProxy() (on L1).
//    3. CAP@L1 calls the counter proxy reentrantly — triggers a nested cross-chain call.
//    4. EEZ._consumeNestedAction matches expectedL1ToL2Calls[0] by crossChainCallHash.
//    5. Nested action returns abi.encode(uint256(1)) — CAP reads targetCounter = 1.
//
//  L2 side (ExecuteL2):
//    1. SYSTEM calls managerL2.executeIncomingCrossChainCall(capL2, 0, incrementProxyData,
//       alice, MAINNET_ROLLUP_ID, _l2Entries(...), ...) — the L2 outer hash mirrors the
//       L1 outer hash in shape (targetRollup=L2, sourceRollup=MAINNET) but with L2-side
//       addresses.
//    2. _processNCalls forwards through the lazily-created proxy for (alice, MAINNET) on
//       L2 into capL2.incrementProxy().
//    3. capL2.target = counterL1ProxyOnL2 — capL2 reentrant-calls back to L1 via the
//       L2-side cross-chain proxy. The L2 manager matches the inner hash against
//       expectedOutgoingCalls[0] and returns the cached 1.
//    4. After: capL2.counter == 1, capL2.targetCounter == 1.
//
//  The two sides exercise the same flatten primitive (one outer + one nested) — each on
//  its own anvil with its own addresses.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedActions {
    using RollingHashBuilder for bytes32;

    // ── L1 hashes ──────────────────────────────────────────────────────

    /// Inner: CAP (running cross-chain from L1's POV) calls counterL2 on L2.
    function _l1InnerHash(address counterL2, address cap) internal pure returns (bytes32) {
        return actionHash(
            Action({
                targetRollupId: L2_ROLLUP_ID,
                targetAddress: counterL2,
                value: 0,
                data: abi.encodeWithSelector(Counter.increment.selector),
                sourceAddress: cap,
                sourceRollupId: MAINNET_ROLLUP_ID
            })
        );
    }

    /// Outer: alice triggers CAP via its L2-side proxy.
    function _l1OuterHash(address cap, address alice) internal pure returns (bytes32) {
        return actionHash(
            Action({
                targetRollupId: L2_ROLLUP_ID,
                targetAddress: cap,
                value: 0,
                data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
                sourceAddress: alice,
                sourceRollupId: MAINNET_ROLLUP_ID
            })
        );
    }

    // ── L2 hashes (mirror; addresses differ) ───────────────────────────

    /// Inner on L2: capL2 (on L2) reentrant-calls counterL1 on MAINNET.
    /// The L2 manager forces sourceRollupId=ROLLUP_ID (=L2) on the on-chain compute.
    function _l2InnerHash(address counterL1, address capL2) internal pure returns (bytes32) {
        return actionHash(
            Action({
                targetRollupId: MAINNET_ROLLUP_ID,
                targetAddress: counterL1,
                value: 0,
                data: abi.encodeWithSelector(Counter.increment.selector),
                sourceAddress: capL2,
                sourceRollupId: L2_ROLLUP_ID
            })
        );
    }

    /// Outer on L2: alice (logically on MAINNET) calls capL2 on L2 via
    /// executeIncomingCrossChainCall.  Same shape as L1 outer (targetRollup=L2,
    /// sourceRollup=MAINNET) but with the L2-side capL2 address.
    function _l2OuterHash(address capL2, address alice) internal pure returns (bytes32) {
        return actionHash(
            Action({
                targetRollupId: L2_ROLLUP_ID,
                targetAddress: capL2,
                value: 0,
                data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
                sourceAddress: alice,
                sourceRollupId: MAINNET_ROLLUP_ID
            })
        );
    }

    /// Rolling hash chain: CALL_BEGIN(1) → NESTED_BEGIN(1) → NESTED_END(1) → CALL_END(1, true, "")
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendNestedBegin(1);
        // nested.callCount = 0 — no deeper calls inside the nested return
        h = h.appendNestedEnd(1);
        h = h.appendCallEnd(1, true, "");
    }

    function _l1Entries(address counterL2, address cap, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-nested"),
            etherDelta: 0
        });

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID, // matches the entry's outer src — Alice on Mainnet
            revertSpan: 0
        });

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            crossChainCallHash: _l1InnerHash(counterL2, cap), callCount: 0, returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            proxyEntryHash: _l1OuterHash(cap, alice),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            expectedLookups: new ExpectedLookup[](0),
            callCount: 1,
            returnData: "",
            rollingHash: _expectedRollingHash()
        });
    }

    // L2 mirror entry.  The outer call is the inbound call delivered by
    // executeIncomingCrossChainCall through the source proxy (alice on MAINNET, on L2).
    function _l2Entries(address counterL1, address capL2, address alice)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            targetAddress: capL2,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            crossChainCallHash: _l2InnerHash(counterL1, capL2), callCount: 0, returnData: abi.encode(uint256(1))
        });

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: _l2OuterHash(capL2, alice),
            incomingCalls: calls,
            expectedOutgoingCalls: nested,
            expectedLookups: new L2ExpectedLookup[](0),
            callCount: 1,
            returnData: "",
            rollingHash: _expectedRollingHash()
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys — three-phase order matches multi-call-nested:
//    1. Deploy (L1) — just counterL1, the destination for the L2 mirror's nested call.
//    2. DeployL2 (L2) — counterL2 + L2-side proxy for counterL1 + capL2.
//    3. Deploy2 (L1) — L1-side proxy for counterL2 + cap + cap's L2-facing proxy.
// ═══════════════════════════════════════════════════════════════════════

// Outputs: COUNTER_L1 (used by L2 mirror's nested cross-chain call destination)
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));
        vm.stopBroadcast();
    }
}

// Env: MANAGER_L2, COUNTER_L1
// Outputs: COUNTER_L2 (the L2 destination for the L1-anchored nested call),
//          COUNTER_L1_PROXY_L2 (proxy on L2 for counterL1 on MAINNET — capL2.target),
//          COUNTER_AND_PROXY_L2 (the L2 mirror's CAP).
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        // counterL2 — destination for the L1 entry's nested cross-chain call
        Counter counterL2 = new Counter();

        // Proxy on L2 for counterL1 on MAINNET — used by capL2 to reach back to L1.
        address counterL1ProxyL2 = getOrCreateProxy(IEEZ(address(manager)), counterL1Addr, MAINNET_ROLLUP_ID);

        // capL2 — CAP on L2 whose `target` is the L2-side proxy for counterL1.
        // capL2.incrementProxy() reentrant-calls counterL1 via the proxy.
        CounterAndProxy capL2 = new CounterAndProxy(Counter(counterL1ProxyL2));

        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("COUNTER_L1_PROXY_L2=%s", counterL1ProxyL2);
        console.log("COUNTER_AND_PROXY_L2=%s", address(capL2));
        vm.stopBroadcast();
    }
}

// Env: ROLLUPS, COUNTER_L2
// Outputs: COUNTER_PROXY (L1-side proxy for counterL2 on L2), COUNTER_AND_PROXY
//          (L1-side CAP whose target is COUNTER_PROXY), CAP_L2_PROXY.
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        EEZ rollups = EEZ(rollupsAddr);

        // L1-side proxy for counterL2 on L2 — CAP.target = this proxy.
        address counterProxy = getOrCreateProxy(IEEZ(address(rollups)), counterL2Addr, L2_ROLLUP_ID);

        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        // Pre-compute CAP's L2-facing proxy on L1 so Execute can trigger it.
        address capL2Proxy = getOrCreateProxy(IEEZ(address(rollups)), address(cap), L2_ROLLUP_ID);

        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(cap));
        console.log("CAP_L2_PROXY=%s", capL2Proxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// Batcher: postAndVerifyBatch + trigger the outer entry via capL2Proxy.
///          Alice is the batcher itself (msg.sender into the proxy) in local mode.
contract Batcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        address capL2Proxy
    )
        external
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        uint256[] memory rids = new uint256[](1);
        rids[0] = L2_ROLLUP_ID;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](psList.length);
        for (uint256 _i = 0; _i < psList.length; _i++) {
            psIdx[_i] = uint64(_i);
        }
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](rids.length);
        for (uint256 _i = 0; _i < rids.length; _i++) {
            rps[_i] = RollupIdWithProofSystems({rollupId: rids[_i], proofSystemIndex: psIdx});
        }

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
        (bool ok,) = capL2Proxy.call(abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector));
        require(ok, "outer call failed");
    }
}

/// ExecuteL2 — local mode: SYSTEM-driven L2 simulation of the inbound nested call.
/// `_processNCalls` lazily creates the source proxy for (alice, MAINNET) on first use,
/// then forwards capL2.incrementProxy() through it; capL2's reentrant call to its
/// counterL1 proxy hits `_consumeNestedAction`, which matches expectedOutgoingCalls[0].
/// Env: MANAGER_L2, COUNTER_L1, COUNTER_AND_PROXY_L2
contract ExecuteL2 is Script, NestedActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        vm.startBroadcast();
        address alice = msg.sender; // SYSTEM_ADDRESS is the broadcaster; it stands in for "alice on MAINNET"
        console.log("ExecuteL2: alice=%s capL2=%s counterL1=%s", alice, capL2Addr, counterL1Addr);

        EEZL2(managerAddr)
            .executeIncomingCrossChainCall(
                capL2Addr,
                0,
                abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
                alice,
                MAINNET_ROLLUP_ID,
                _l2Entries(counterL1Addr, capL2Addr, alice),
                noL2LookupCalls()
            );

        console.log("done");
        console.log("capL2.counter=%s", CounterAndProxy(capL2Addr).counter());
        console.log("capL2.targetCounter=%s", CounterAndProxy(capL2Addr).targetCounter());
        vm.stopBroadcast();
    }
}

/// Execute — local mode: postAndVerifyBatch + trigger via Batcher.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L2, COUNTER_AND_PROXY, CAP_L2_PROXY
contract Execute is Script, NestedActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");
        address capL2Proxy = vm.envAddress("CAP_L2_PROXY");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        console.log("BATCHER_L1=%s", address(batcher));

        // Alice = the Batcher contract itself (msg.sender into capL2Proxy).
        // The outer entry's crossChainCallHash must use alice = address(batcher).
        batcher.execute(
            EEZ(rollupsAddr),
            proofSystemAddr,
            _l1Entries(counterL2Addr, capAddr, address(batcher)),
            noLookupCalls(),
            capL2Proxy
        );

        console.log("done");
        console.log("cap.counter=%s", CounterAndProxy(capAddr).counter());
        console.log("cap.targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("CAP_L2_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, NestedActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "CounterL2";
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("COUNTER_AND_PROXY")) return "CAP(L1)";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L2")) return "CAP(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");
        address capL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");
        // L1 source is the Batcher contract Execute deploys; L2 source is the script
        // broadcaster (SYSTEM) acting as alice. BATCHER_L1 is exported by run-local.sh
        // from Execute's output.
        address aliceL1 = vm.envOr("BATCHER_L1", msg.sender);
        address aliceL2 = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, capAddr, aliceL1);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, capL2Addr, aliceL2);

        bytes32 l1Hash = _entryHash(l1[0]);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2[0].proxyEntryHash));

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, 1 nested) ===");
        _logEntry(0, l1[0]);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 1 nested) ===");
        _logL2Entry(0, l2[0]);
    }
}
