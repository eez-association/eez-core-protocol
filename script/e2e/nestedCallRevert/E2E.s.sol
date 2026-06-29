// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
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
import {Counter, SafeCounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    expectedL1toL2Hash,
    noStaticLookups,
    noL2StaticLookups,
    noCalls,
    noL2Calls,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  NestedCallRevert - nested reentrant call that fails; caller recovers
//
//  SafeCounterAndProxy.incrementProxy():
//    try target.increment() returns (uint256 val) { targetCounter = val }
//    catch { lastCallFailed = true }
//    counter++
//
//  A reverting reentrant call is modeled as a `success=false` ExpectedL1ToL2Call
//  living INSIDE the entry's unified `expectedL1ToL2Calls` table, content-addressed
//  by `expectedL1toL2Hash(innerCch, rollingHashAtFire)`. `_resolveNestedReentrant`
//  opens the frame (NESTED_BEGIN), runs its (empty) sub-array, checks the sub-frame
//  rolling hash against `revertedOrStaticRollingHash`, then reverts with `returnData`.
//  The reverting frame (its NESTED_BEGIN fold + cursor bump) is rolled back when SCAP's
//  try/catch swallows the revert — so the entry's rolling hash only carries
//  CALL_BEGIN/CALL_END for the top-level SCAP call (no NESTED tags survive).
//
//  After execution:
//    SafeCounterAndProxy.counter() = 1
//    SafeCounterAndProxy.lastCallFailed() = true
//    SafeCounterAndProxy.targetCounter() = 0
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedCallRevertActions {
    function _incrementProxyData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector);
    }

    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev Proxy-entry hash: alice → SCAP via SCAP's proxy (target=SCAP @ L2, source=alice @ MAINNET).
    function _outerProxyEntryHash(address scap, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, scap, 0, _incrementProxyData(), alice, MAINNET_ROLLUP_ID);
    }

    /// @dev L1 top-level call hash for SCAP.incrementProxy executed ON L1 (target=SCAP @ MAINNET,
    ///      source=alice @ L2 — the entry sources its top-level call from the proven rollup).
    function _outerTopCallHash(address scap, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, scap, 0, _incrementProxyData(), alice, L2_ROLLUP_ID);
    }

    /// @dev Inner reentrant hash: SCAP's reentrant L1→L2 call to Counter L2 that reverts.
    ///      `executeCrossChainCall` folds srcRollup=MAINNET on L1, so source=SCAP @ MAINNET,
    ///      target=Counter @ L2.
    function _innerActionHash(address counterL2, address scap) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, counterL2, 0, _incrementData(), scap, MAINNET_ROLLUP_ID);
    }

    function _l1Entries(address scap, address alice, address counterL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-nested-call-revert"),
            etherDelta: 0
        });

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            // L1 calls must be sourced from a rollup in the entry's stateDeltas (L2), not MAINNET.
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: scap,
            value: 0,
            data: _incrementProxyData()
        });

        bytes32 proxyEntryHash = _outerProxyEntryHash(scap, alice);
        bytes32 topCallCch = _outerTopCallHash(scap, alice);
        bytes32 innerCch = _innerActionHash(counterL2, scap);

        // Rolling hash: entry seed → CALL_BEGIN(SCAP) → CALL_END(true, "").
        // The reverting reentrant frame is rolled back by SCAP's try/catch, so no NESTED tags persist.
        bytes32 rh = RollingHashBuilder.entryBegin(deltas, proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, topCallCch);
        bytes32 rhFire = rh; // running rolling hash at the instant the reentry fires
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        // Sub-frame rolling hash at the revert point: NESTED_BEGIN(innerCch) over an empty sub-array.
        bytes32 revertedSubHash = RollingHashBuilder.appendNestedBegin(rhFire, innerCch);

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(innerCch, rhFire),
            l2ToL1Calls: noCalls(),
            revertedOrStaticRollingHash: revertedSubHash,
            success: false,
            returnData: bytes("inner reverts")
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

    // ─────────────────────────────────────────────────────────────
    //  L2-side mirror — SafeCAP runs on L2; its inner call to the
    //  counterProxy (proxy on L2 for Counter on MAINNET) reverts via a
    //  `success=false` ExpectedOutgoingCrossChainCall in the entry.
    //  PENDING EEZL2: re-verify once EEZL2.sol lands.
    // ─────────────────────────────────────────────────────────────

    /// @dev Outer proxy-entry / top-level hash on L2: source (batcher MAINNET) → SafeCAP (on L2).
    function _outerHashL2(address scapL2, address batcherL1) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, scapL2, 0, _incrementProxyData(), batcherL1, MAINNET_ROLLUP_ID);
    }

    /// @dev Inner reentrant (outgoing) hash on L2: SafeCAP (on L2) calls Counter MAINNET.
    ///      Manager forces sourceRollupId=ROLLUP_ID (=L2) for L2-issued reentrant calls.
    function _innerActionHashL2(address counterL1, address scapL2) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, counterL1, 0, _incrementData(), scapL2, L2_ROLLUP_ID);
    }

    function _l2Entries(address scapL2, address batcherL1, address counterL1)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: batcherL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: scapL2,
            value: 0,
            data: _incrementProxyData()
        });

        bytes32 proxyEntryHash = _outerHashL2(scapL2, batcherL1);
        bytes32 innerCch = _innerActionHashL2(counterL1, scapL2);

        // PENDING EEZL2: rolling-hash seed/append shape mirrors L1.
        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, proxyEntryHash);
        bytes32 rhFire = rh;
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        bytes32 revertedSubHash = RollingHashBuilder.appendNestedBegin(rhFire, innerCch);

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(innerCch, rhFire),
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: revertedSubHash,
            success: false,
            returnData: bytes("inner reverts")
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
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title DeployL2 — L2: deploy Counter (the L1 inner-call target lives here only as an
/// address-reference for the off-chain hash; the inner reentrant never actually executes
/// because the success=false ExpectedL1ToL2Call short-circuits the proxy before it dispatches).
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counter = new Counter();
        console.log("COUNTER_L2=%s", address(counter));
        vm.stopBroadcast();
    }
}

/// @title Deploy — L1: deploy the L1 trigger contracts plus a placeholder Counter that
/// represents "Counter on MAINNET" from the L2 mirror's perspective (used only as an
/// address constant in the L2 inner action hash; never invoked because the L2-side
/// reentrant call short-circuits via the success=false ExpectedOutgoingCrossChainCall).
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        EEZ rollups = EEZ(rollupsAddr);

        // Placeholder Counter on L1 — only its address matters (referenced by the L2
        // inner action hash). Never called.
        Counter counterL1 = new Counter();

        // counterProxy: proxy for Counter@L2 on L1 (NOT an actual Counter)
        address counterProxy;
        try rollups.createCrossChainProxy(counterL2, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2, L2_ROLLUP_ID);
        }

        // SafeCounterAndProxy wraps counterProxy — try/catch on target.increment()
        SafeCounterAndProxy scap = new SafeCounterAndProxy(Counter(counterProxy));

        // Trigger proxy: proxy for (SCAP, L2_ROLLUP_ID) on L1
        address scapProxy;
        try rollups.createCrossChainProxy(address(scap), L2_ROLLUP_ID) returns (address p) {
            scapProxy = p;
        } catch {
            scapProxy = rollups.computeCrossChainProxyAddress(address(scap), L2_ROLLUP_ID);
        }

        console.log("COUNTER_L1=%s", address(counterL1));
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("SAFE_CAP=%s", address(scap));
        console.log("SAFE_CAP_PROXY=%s", scapProxy);
        vm.stopBroadcast();
    }
}

/// @title DeployL2Step2 - L2: deploy SafeCAP and its inner-counter proxy (proxy on L2 for
/// Counter on MAINNET). Runs after Deploy (which logs COUNTER_L1 on L1).
contract DeployL2Step2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        // Proxy on L2 for Counter@MAINNET — never actually invoked end-to-end because the
        // L2 success=false ExpectedOutgoingCrossChainCall short-circuits the proxy's reentrant call.
        address counterProxyL2;
        try manager.createCrossChainProxy(counterL1, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxyL2 = p;
        } catch {
            counterProxyL2 = manager.computeCrossChainProxyAddress(counterL1, MAINNET_ROLLUP_ID);
        }

        // SafeCAP on L2 targeting the L2-side counter proxy. When invoked through its
        // own source-proxy by `_processNCalls`, `target.increment()` dispatches into
        // managerL2._consumeNestedCall which matches the success=false ExpectedOutgoingCrossChainCall
        // and reverts. SafeCAP's try/catch sets lastCallFailed=true.
        SafeCounterAndProxy scapL2 = new SafeCounterAndProxy(Counter(counterProxyL2));

        console.log("COUNTER_PROXY_L2=%s", counterProxyL2);
        console.log("SAFE_CAP_L2=%s", address(scapL2));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════════════

contract Batcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        StaticLookup[] calldata staticLookups,
        address scapProxy
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
        (bool ok,) = scapProxy.call(abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector));
        require(ok, "outer call failed");
    }
}

// ExecuteL2 - L2-side mirror. SYSTEM-driven via executeIncomingCrossChainCall:
// loads the L2 entry (with the success=false ExpectedOutgoingCrossChainCall), then runs
// SafeCAP (on L2) incrementProxy(). SafeCAP's inner reentrant call hits managerL2._consumeNestedCall,
// matches the success=false outgoing entry and reverts with the cached returnData. SafeCAP's
// try/catch catches it. Final state on L2: SafeCAP.counter=1, SafeCAP.lastCallFailed=true,
// SafeCAP.targetCounter=0.
contract ExecuteL2 is Script, NestedCallRevertActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address scapL2 = vm.envAddress("SAFE_CAP_L2");

        vm.startBroadcast();
        // The L1-side `_l1Entries` was built with `sourceAddress = address(batcher)` — but the
        // Batcher contract lives on L1 and is created per-tx, so we can't reference it from L2.
        // Instead we mirror the structural shape: source = msg.sender (the broadcaster acting as
        // the L1 trigger). The two halves do NOT need identical sourceAddresses because each side
        // is a separate proof; only the rolling-hash / call-shape / lookup key matter.
        address triggerSource = msg.sender;
        console.log("ExecuteL2: manager=%s scapL2=%s triggerSource=%s", managerAddr, scapL2, triggerSource);

        EEZL2(managerAddr)
            .executeIncomingCrossChainCall(
                scapL2,
                0,
                abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector),
                triggerSource,
                MAINNET_ROLLUP_ID,
                _l2Entries(scapL2, triggerSource, counterL1),
                noL2StaticLookups()
            );

        console.log("ExecuteL2: done");
        console.log("scapL2.counter=%s", SafeCounterAndProxy(scapL2).counter());
        console.log("scapL2.targetCounter=%s", SafeCounterAndProxy(scapL2).targetCounter());
        console.log("scapL2.lastCallFailed=%s", SafeCounterAndProxy(scapL2).lastCallFailed());
        vm.stopBroadcast();
    }
}

contract Execute is Script, NestedCallRevertActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address scapAddr = vm.envAddress("SAFE_CAP");
        address scapProxy = vm.envAddress("SAFE_CAP_PROXY");
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        batcher.execute(
            EEZ(rollupsAddr),
            proofSystemAddr,
            _l1Entries(scapAddr, address(batcher), counterL2),
            noStaticLookups(),
            scapProxy
        );

        console.log("done");
        console.log("scap.counter=%s", SafeCounterAndProxy(scapAddr).counter());
        console.log("scap.targetCounter=%s", SafeCounterAndProxy(scapAddr).targetCounter());
        console.log("scap.lastCallFailed=%s", SafeCounterAndProxy(scapAddr).lastCallFailed());
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("SAFE_CAP_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, NestedCallRevertActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("SAFE_CAP")) return "SafeCounterAndProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == SafeCounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address scapAddr = vm.envAddress("SAFE_CAP");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address scapL2 = vm.envAddress("SAFE_CAP_L2");
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(scapAddr, alice, counterL2);
        L2ExecutionEntry[] memory l2 = _l2Entries(scapL2, alice, counterL1);
        bytes32 l1Hash = _entryHash(l1[0]);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("");
        console.log(
            "=== EXPECTED L1 TABLE (1 entry, 1 top-level call, 1 success=false reentrant in expectedL1ToL2Calls) ==="
        );
        _logEntry(0, l1[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 top-level call, 1 success=false outgoing reentrant) ===");
        _logL2Entry(0, l2[0]);
    }
}
