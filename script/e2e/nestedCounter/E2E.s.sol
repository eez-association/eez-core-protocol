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
    StaticLookup
} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticLookup as L2StaticLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    expectedL1toL2Hash,
    noStaticLookups,
    noL2StaticLookups,
    noCalls,
    noL2Calls,
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

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedActions {
    // ── L1 hashes ──────────────────────────────────────────────────────

    /// Inner reentry: CAP (on L1) reentrant-calls counterL2 via its proxy → executeCrossChainCall
    /// folds (target=counterL2 @ L2, source=cap @ MAINNET).
    function _l1InnerHash(address counterL2, address cap) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID, counterL2, 0, abi.encodeWithSelector(Counter.increment.selector), cap, MAINNET_ROLLUP_ID
        );
    }

    /// Outer/trigger (proxyEntryHash): alice triggers CAP via its L2-side proxy on L1.
    function _l1OuterHash(address cap, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID,
            cap,
            0,
            abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            alice,
            MAINNET_ROLLUP_ID
        );
    }

    /// Top-level call hash: the manager runs CAP.incrementProxy() ON L1 (target rollup = MAINNET)
    /// via the source proxy for (alice, L2) — the proven rollup. Matches `_processNCalls`'s CALL_BEGIN.
    function _l1TopCallHash(address cap, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(
            MAINNET_ROLLUP_ID,
            cap,
            0,
            abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            alice,
            L2_ROLLUP_ID
        );
    }

    // ── L2 hashes (mirror; addresses differ) ───────────────────────────

    /// Inner on L2: capL2 (on L2) reentrant-calls counterL1 on MAINNET.
    /// The L2 manager forces sourceRollupId=ROLLUP_ID (=L2) on the on-chain compute.
    function _l2InnerHash(address counterL1, address capL2) internal pure returns (bytes32) {
        return crossChainCallHash(
            MAINNET_ROLLUP_ID, counterL1, 0, abi.encodeWithSelector(Counter.increment.selector), capL2, L2_ROLLUP_ID
        );
    }

    /// Outer on L2 (proxyEntryHash): alice (logically on MAINNET) calls capL2 on L2 via
    /// executeIncomingCrossChainCall. Same shape as L1 outer (targetRollup=L2, sourceRollup=MAINNET)
    /// but with the L2-side capL2 address. On L2 this also equals the incoming top-level call's
    /// CALL_BEGIN hash (target on this L2 = L2_ROLLUP_ID, source on MAINNET).
    function _l2OuterHash(address capL2, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID,
            capL2,
            0,
            abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            alice,
            MAINNET_ROLLUP_ID
        );
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

        bytes32 proxyEntryHash = _l1OuterHash(cap, alice);

        // Top-level call: manager runs CAP.incrementProxy() on L1 via source proxy (alice, L2).
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID, // sub-call source must be in the entry's stateDeltas (the proven rollup)
            targetAddress: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector)
        });

        bytes32 ccTop = _l1TopCallHash(cap, alice);
        bytes32 ccInner = _l1InnerHash(counterL2, cap);

        // Rolling hash, threaded exactly as EEZ._executeEntry / _processNCalls / _resolveNestedReentrant.
        bytes32 rh = RollingHashBuilder.entryBegin(deltas, proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, ccTop); // top-level CAP.incrementProxy() begins
        bytes32 rhFire = rh; // reentry CAP->counterL2 fires at this rolling hash
        rh = RollingHashBuilder.appendNestedBegin(rh, ccInner);
        rh = RollingHashBuilder.appendNestedEnd(rh); // nested frame has no sub-calls
        rh = RollingHashBuilder.appendCallEnd(rh, true, ""); // incrementProxy returns void

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(ccInner, rhFire),
            l2ToL1Calls: noCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            proxyEntryHash: proxyEntryHash,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }

    // L2 mirror entry.  The outer call is the inbound call delivered by
    // executeIncomingCrossChainCall through the source proxy (alice on MAINNET, on L2).
    // NOTE: L2 rolling-hash + outgoing-call keying are PENDING EEZL2 (impl not migrated); re-verify when EEZL2.sol lands.
    function _l2Entries(address counterL1, address capL2, address alice)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 proxyEntryHash = _l2OuterHash(capL2, alice);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: capL2,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector)
        });

        // PENDING EEZL2: incoming top-level call CALL_BEGIN hash mirrors L1 — target on this L2
        // (L2_ROLLUP_ID), source on MAINNET (== proxyEntryHash here). Inner reentry uses _l2InnerHash.
        bytes32 ccTop = _l2OuterHash(capL2, alice);
        bytes32 ccInner = _l2InnerHash(counterL1, capL2);

        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, ccTop);
        bytes32 rhFire = rh;
        rh = RollingHashBuilder.appendNestedBegin(rh, ccInner);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(ccInner, rhFire), // PENDING EEZL2 keying
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: proxyEntryHash,
            incomingCalls: calls,
            expectedOutgoingCalls: nested,
            rollingHash: rh,
            success: true,
            returnData: ""
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
        StaticLookup[] calldata staticLookups,
        address capL2Proxy
    )
        external
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
                noL2StaticLookups()
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
            noStaticLookups(),
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
