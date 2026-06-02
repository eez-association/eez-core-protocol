// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {StateDelta, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry, LookupCall} from "../../../src/interfaces/IEEZ.sol";
import {Counter, SafeCounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {crossChainCallHash, noLookupCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  NestedCallRevert - nested reentrant call that fails; caller recovers
//
//  SafeCounterAndProxy.incrementProxy():
//    try target.increment() returns (uint256 val) { targetCounter = val }
//    catch { lastCallFailed = true }
//    counter++
//
//  Per CAVEATS.md, a reverting reentrant call is modeled as a `StaticCall`
//  with `failed = true` (NOT a ExpectedL1ToL2Call — a failed ExpectedL1ToL2Call's revert
//  rolls back the consumption-cursor bump, making consumption silent and
//  unverifiable). _consumeNestedAction's fallback path scans persistent
//  staticCalls keyed by (actionHash, _currentCallNumber, lastNestedActionConsumed)
//  and reverts with the cached returnData when a `failed=true` StaticCall matches.
//
//  Result: nestedActions.length must be 0 and staticCalls contains the
//  failed=true entry. The rolling hash only has CALL_BEGIN/CALL_END
//  (no NESTED tags), since the failed reentrant call is replayed as a
//  static-call revert outside the rolling-hash chain.
//
//  After execution:
//    SafeCounterAndProxy.counter() = 1
//    SafeCounterAndProxy.lastCallFailed() = true
//    SafeCounterAndProxy.targetCounter() = 0
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedCallRevertActions {
    using RollingHashBuilder for bytes32;

    function _outerActionHash(address scap, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID,
            scap,
            0,
            abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector),
            alice,
            MAINNET_ROLLUP_ID
        );
    }

    /// @dev Inner action hash: SCAP's reentrant call to Counter@L2 that reverts.
    ///      `executeL1ToL2Call` hardcodes srcRollup=MAINNET on L1, so this
    ///      hash uses MAINNET as the source rollup.
    function _innerActionHash(address counterL2, address scap) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID, counterL2, 0, abi.encodeWithSelector(Counter.increment.selector), scap, MAINNET_ROLLUP_ID
        );
    }

    /// @dev Rolling hash: just CALL_BEGIN(1) -> CALL_END(1, true, "")
    ///      The reentrant call is replayed as a `failed=true` static-call revert
    ///      that SCAP catches; no NESTED tags appear in the rolling hash.
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendCallEnd(1, true, "");
    }

    function _l1Entries(address scap, address alice) internal pure returns (ExecutionEntry[] memory entries) {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-nested-call-revert"),
            etherDelta: 0
        });

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: scap,
            value: 0,
            data: abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            proxyEntryHash: _outerActionHash(scap, alice),
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: calls,
            expectedL1ToL2Calls: new ExpectedL1ToL2Call[](0),
            callCount: 1,
            returnData: "",
            rollingHash: _expectedRollingHash()
        });
    }

    /// @dev LookupCall that models the reverting reentrant call. Keyed by
    ///      (innerActionHash, callNumber=1, lastNestedActionConsumed=0) — the
    ///      same key the lookup uses when SCAP's inner call hits the manager.
    ///      `failed=true` makes _resolveStaticCall revert with returnData.
    function _l1LookupCalls(address counterL2, address scap) internal pure returns (LookupCall[] memory statics) {
        statics = new LookupCall[](1);
        statics[0] = LookupCall({
            crossChainCallHash: _innerActionHash(counterL2, scap),
            destinationRollupId: L2_ROLLUP_ID,
            returnData: bytes("inner reverts"),
            failed: true,
            callNumber: 1,
            lastNestedActionConsumed: 0,
            calls: new L2ToL1Call[](0),
            rollingHash: bytes32(0)
        });
    }

    // ─────────────────────────────────────────────────────────────
    //  L2-side mirror — SafeCAP runs on L2; its inner call to the
    //  counterProxy (proxy on L2 for Counter on MAINNET) reverts via
    //  the L2 lookupCall (failed=true) fallback in _consumeNestedAction.
    // ─────────────────────────────────────────────────────────────

    /// @dev Outer action hash on L2: source-proxy (for batcher on MAINNET) calls SafeCAP (on L2).
    function _outerActionHashL2(address scapL2, address batcherL1) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID,
            scapL2,
            0,
            abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector),
            batcherL1,
            MAINNET_ROLLUP_ID
        );
    }

    /// @dev Inner action hash on L2: SafeCAP (on L2) calls counterProxy (Counter on MAINNET).
    ///      Manager forces sourceRollupId=ROLLUP_ID (=L2) for L2-issued reentrant calls.
    function _innerActionHashL2(address counterL1, address scapL2) internal pure returns (bytes32) {
        return crossChainCallHash(
            MAINNET_ROLLUP_ID, counterL1, 0, abi.encodeWithSelector(Counter.increment.selector), scapL2, L2_ROLLUP_ID
        );
    }

    function _l2Entries(address scapL2, address batcherL1) internal pure returns (ExecutionEntry[] memory entries) {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: scapL2,
            value: 0,
            data: abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector),
            sourceAddress: batcherL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: _outerActionHashL2(scapL2, batcherL1),
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: calls,
            expectedL1ToL2Calls: new ExpectedL1ToL2Call[](0),
            callCount: 1,
            returnData: "",
            rollingHash: _expectedRollingHash()
        });
    }

    /// @dev LookupCall on L2 modelling the reverting reentrant call to Counter on MAINNET.
    ///      Same mechanism as the L1-side LookupCall — _consumeNestedAction falls back
    ///      to the persistent lookupCalls list and reverts with `returnData` when the
    ///      key (hash, callNumber=1, lastNestedActionConsumed=0) matches.
    function _l2LookupCalls(address counterL1, address scapL2) internal pure returns (LookupCall[] memory statics) {
        statics = new LookupCall[](1);
        statics[0] = LookupCall({
            crossChainCallHash: _innerActionHashL2(counterL1, scapL2),
            destinationRollupId: L2_ROLLUP_ID,
            returnData: bytes("inner reverts"),
            failed: true,
            callNumber: 1,
            lastNestedActionConsumed: 0,
            calls: new L2ToL1Call[](0),
            rollingHash: bytes32(0)
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title DeployL2 — L2: deploy Counter (the L1 inner-call target lives here only as an
/// address-reference for the off-chain hash; the inner reentrant never actually executes
/// because the LookupCall {failed:true} short-circuits the proxy before it dispatches).
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
/// reentrant call short-circuits via LookupCall {failed:true}).
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
        // L2 LookupCall {failed:true} short-circuits the proxy's reentrant call.
        address counterProxyL2;
        try manager.createCrossChainProxy(counterL1, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxyL2 = p;
        } catch {
            counterProxyL2 = manager.computeCrossChainProxyAddress(counterL1, MAINNET_ROLLUP_ID);
        }

        // SafeCAP on L2 targeting the L2-side counter proxy. When invoked through its
        // own source-proxy by `_processNCalls`, `target.increment()` dispatches into
        // managerL2._consumeNestedAction which finds the matching failed=true LookupCall
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
        LookupCall[] calldata lookupCalls,
        address scapProxy
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
        (bool ok,) = scapProxy.call(abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector));
        require(ok, "outer call failed");
    }
}

// ExecuteL2 - L2-side mirror. SYSTEM-driven via executeIncomingCrossChainCall:
// loads the L2 entry + the failed=true LookupCall, then runs SafeCAP (on L2) incrementProxy().
// SafeCAP's inner reentrant call hits managerL2._consumeNestedAction, falls back to the
// persistent lookupCalls list (no ExpectedL1ToL2Call match), finds the failed=true
// LookupCall and reverts with the cached returnData. SafeCAP's try/catch catches it.
// Final state on L2: SafeCAP.counter=1, SafeCAP.lastCallFailed=true, SafeCAP.targetCounter=0.
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
        // is a separate proof; only the rolling-hash / call-shape / LookupCall key matter.
        address triggerSource = msg.sender;
        console.log("ExecuteL2: manager=%s scapL2=%s triggerSource=%s", managerAddr, scapL2, triggerSource);

        EEZL2(managerAddr)
            .executeIncomingCrossChainCall(
                scapL2,
                0,
                abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector),
                triggerSource,
                MAINNET_ROLLUP_ID,
                _l2Entries(scapL2, triggerSource),
                _l2LookupCalls(counterL1, scapL2)
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
            _l1Entries(scapAddr, address(batcher)),
            _l1LookupCalls(counterL2, scapAddr),
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

        ExecutionEntry[] memory l1 = _l1Entries(scapAddr, alice);
        LookupCall[] memory statics = _l1LookupCalls(counterL2, scapAddr);
        ExecutionEntry[] memory l2 = _l2Entries(scapL2, alice);
        LookupCall[] memory l2Statics = _l2LookupCalls(counterL1, scapL2);
        bytes32 l1Hash = _entryHash(l1[0]);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("");
        console.log(
            "=== EXPECTED L1 TABLE (1 entry, 1 call, 0 nested - reentrant revert via failed=true LookupCall) ==="
        );
        _logEntry(0, l1[0]);
        console.log("=== EXPECTED L1 STATIC CALLS (1 failed=true entry) ===");
        _logLookupCall(0, statics[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 0 nested) ===");
        _logL2Entry(0, l2[0]);
        console.log("=== EXPECTED L2 STATIC CALLS (1 failed=true entry) ===");
        _logLookupCall(0, l2Statics[0]);
    }
}
