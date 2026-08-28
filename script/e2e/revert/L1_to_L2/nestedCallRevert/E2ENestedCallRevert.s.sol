// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {RollupUpdate, L2ToL1Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, RevertCounter, SafeCounterAndProxy} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    crossChainCallHashL2Out,
    expectedL1toL2Hash,
    noStaticEntries,
    noL2StaticEntries,
    noNestedActions,
    noL2Calls,
    getOrCreateProxy,
    RollingHashBuilder,
    immediateSingleRollupBatch
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  NestedCallRevert — nested reentrant call whose DESTINATION reverts;
//  the caller recovers with try/catch. Two-sided, L1→L2 trigger, one flow:
//  both tables are views of the SAME execution, and the revert data has a
//  real producer (RevertCounter.increment() on L1 → Error("always reverts")).
//
//  Topology (each role on exactly one chain, mirrors nestedCounter):
//    RevertCounter on L1  — the inner target; always reverts.
//    SafeCAP on L2        — SafeCounterAndProxy targeting the L2-side proxy
//                           for RevertCounter@L1; try/catches the failure.
//
//  L2 side (ExecuteL2) — system-driven delivery, where SafeCAP really runs:
//    SYSTEM ──executeIncomingCrossChainCall(entries: [incrementProxy from alice@L1])──▶ EEZL2
//      └─ SafeCAP(L2).incrementProxy()      target = proxy for (RevertCounter@L1)
//           ├─ try revCounterProxy.increment()
//           │    └─ EEZL2.executeCrossChainCall ─ nested: matches the success=false
//           │       expectedOutgoingCalls[0]  (key = keccak256(innerCch, rhAtFire))
//           │       ◀─ revert Error("always reverts")  ◀── NESTED_BEGIN fold + cursor UNWIND
//           ├─ catch → lastCallFailed = true
//           └─ counter++                                   (delivery COMMITS)
//    result: counter == 1, lastCallFailed == true, targetCounter == 0; the
//    committed hash carries only CALL_BEGIN/CALL_END for the inbound call — no NESTED tags
//
//  L1 side (Execute) — batch + trigger mined in one block:
//    alice ──tx──▶ scapProxy.call(incrementProxy())    proxy for (SafeCAP@L2)
//      └─ EEZ.executeCrossChainCall ─ consumes the entry:
//           calls[0]  RevertCounter(L1).increment()   ◀── SafeCAP's inner call, run FOR REAL
//                     reverts naturally → folded CALL_END(false, Error("always reverts"))
//           entry COMMITS (success = true)
//    result: RevertCounter(L1).counter == 0 — the same revert data appears on
//    both sides because ONE contract produces it
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

    /// @dev Error(string) revert data produced by `RevertCounter.increment()` on L1 —
    ///      the single real producer both tables replay.
    function _revertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "always reverts");
    }

    /// @dev Trigger identity (proxyEntryHash on BOTH sides): alice on L1 calls SafeCAP
    ///      on L2 through the L1-side proxy.
    function _outerHash(address scapL2, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(false, alice, MAINNET_ROLLUP_ID, scapL2, L2_ROLLUP_ID, 0, _incrementProxyData());
    }

    /// @dev CALL_BEGIN identity of SafeCAP's inner call executed ON L1 (target rollup =
    ///      MAINNET, source = SafeCAP @ L2).
    function _l1TopCallHash(address revCounterL1, address scapL2) internal pure returns (bytes32) {
        return crossChainCallHash(false, scapL2, L2_ROLLUP_ID, revCounterL1, MAINNET_ROLLUP_ID, 0, _incrementData());
    }

    /// @dev The same inner call keyed on L2: it LEAVES the L2, so it folds the L2-outgoing
    ///      hash (callGas=0; devnet deploys EEZL2 with useGasLeft=false). The manager forces
    ///      sourceRollupId=ROLLUP_ID for L2-issued reentrant calls.
    function _l2InnerHash(address revCounterL1, address scapL2) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(scapL2, L2_ROLLUP_ID, revCounterL1, MAINNET_ROLLUP_ID, 0, _incrementData());
    }

    /// @dev L1 entry — SafeCAP's execution as seen from L1: its one inner call runs on L1
    ///      for real and reverts naturally, captured as CALL_END(false, revertData) with
    ///      revertNextNCalls = 0. The entry itself commits.
    function _l1Entries(
        address revCounterL1,
        address scapL2,
        address alice
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        RollupUpdate[] memory deltas = new RollupUpdate[](1);
        deltas[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-nested-call-revert"),
            etherDelta: 0
        });

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: scapL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: revCounterL1,
            value: 0,
            data: _incrementData()
        });

        bytes32 proxyEntryHash = _outerHash(scapL2, alice);

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, _l1TopCallHash(revCounterL1, scapL2));
        rh = RollingHashBuilder.appendCallEnd(rh, false, _revertData());

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltas,
            proxyEntryHash: proxyEntryHash,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh,
            success: true,
            returnData: "" // incrementProxy returns void
        });
    }

    /// @dev L2 entry — the delivered execution of SafeCAP. Its inner call matches the
    ///      success=false outgoing row and reverts with the cached revert data; SafeCAP's
    ///      try/catch unwinds the NESTED_BEGIN fold + cursor bump, so the committed hash
    ///      carries no NESTED tags.
    function _l2Entries(
        address revCounterL1,
        address scapL2,
        address alice
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: scapL2,
            value: 0,
            data: _incrementProxyData()
        });

        bytes32 proxyEntryHash = _outerHash(scapL2, alice);
        bytes32 ccInner = _l2InnerHash(revCounterL1, scapL2);

        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, proxyEntryHash);
        bytes32 rhFire = rh; // running rolling hash at the instant the reentry fires
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        // Sub-frame hash at the revert point: NESTED_BEGIN over an empty sub-array (the
        // reverted L1 frame makes no calls back into this L2).
        bytes32 revertedSubHash = RollingHashBuilder.appendNestedBegin(rhFire, ccInner);

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(ccInner, rhFire),
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: revertedSubHash,
            success: false,
            returnData: _revertData()
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
//  Deploys — three phases (each needs the previous one's address):
//    1. Deploy (L1)   — RevertCounter, the always-reverting inner target.
//    2. DeployL2 (L2) — L2-side proxy for RevertCounter@L1 + SafeCAP targeting it.
//    3. Deploy2 (L1)  — L1-side proxy for SafeCAP@L2 (the user-tx target).
// ═══════════════════════════════════════════════════════════════════════

// Outputs: REV_COUNTER_L1 (destination of the nested reentrant call; always reverts)
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        RevertCounter revCounter = new RevertCounter();
        console.log("REV_COUNTER_L1=%s", address(revCounter));
        vm.stopBroadcast();
    }
}

// Env: MANAGER_L2, REV_COUNTER_L1
// Outputs: REV_COUNTER_PROXY_L2 (proxy on L2 for RevertCounter on MAINNET — SafeCAP.target),
//          SAFE_CAP_L2 (SafeCAP on L2, the real cross-chain callee).
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address revCounterL1 = vm.envAddress("REV_COUNTER_L1");

        vm.startBroadcast();
        address revCounterProxyL2 = getOrCreateProxy(IEEZ(managerAddr), revCounterL1, MAINNET_ROLLUP_ID);

        // SafeCAP on L2: try/catches target.increment() through the proxy, so the
        // destination's revert is recovered from and the delivery commits.
        SafeCounterAndProxy scapL2 = new SafeCounterAndProxy(Counter(revCounterProxyL2));

        console.log("REV_COUNTER_PROXY_L2=%s", revCounterProxyL2);
        console.log("SAFE_CAP_L2=%s", address(scapL2));
        vm.stopBroadcast();
    }
}

// Env: ROLLUPS, SAFE_CAP_L2
// Outputs: SAFE_CAP_PROXY (L1-side proxy for SafeCAP on L2 — the user-tx target).
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address scapL2 = vm.envAddress("SAFE_CAP_L2");

        vm.startBroadcast();
        address scapProxy = getOrCreateProxy(IEEZ(rollupsAddr), scapL2, L2_ROLLUP_ID);
        console.log("SAFE_CAP_PROXY=%s", scapProxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════════════

/// ExecuteL2 — local mode: SYSTEM-driven delivery of the trigger. SafeCAP's inner
/// call hits `_consumeNestedCall`, matches the success=false expectedOutgoingCalls[0]
/// and reverts with the cached Error("always reverts"); the try/catch records it.
/// Env: MANAGER_L2, REV_COUNTER_L1, SAFE_CAP_L2
contract ExecuteL2 is Script, NestedCallRevertActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address revCounterL1 = vm.envAddress("REV_COUNTER_L1");
        address scapL2 = vm.envAddress("SAFE_CAP_L2");

        vm.startBroadcast();
        address alice = msg.sender; // SYSTEM_ADDRESS is the broadcaster; it stands in for "alice on MAINNET"
        console.log("ExecuteL2: manager=%s scapL2=%s alice=%s", managerAddr, scapL2, alice);

        EEZL2(managerAddr).executeIncomingCrossChainCall(_l2Entries(revCounterL1, scapL2, alice), noL2StaticEntries());

        SafeCounterAndProxy scap = SafeCounterAndProxy(scapL2);
        require(scap.counter() == 1, "SafeCAP must commit its own increment");
        require(scap.lastCallFailed(), "inner revert must be caught and recorded");
        require(scap.targetCounter() == 0, "no target result on a reverted inner call");

        console.log("done");
        console.log("scapL2.counter=%s", scap.counter());
        console.log("scapL2.targetCounter=%s", scap.targetCounter());
        console.log("scapL2.lastCallFailed=%s", scap.lastCallFailed());
        vm.stopBroadcast();
    }
}

/// Execute — local mode: postAndVerifyBatch tx + outer trigger tx from the EOA; the
/// runner mines both in one block (execute_l1_same_block). The entry's one call runs
/// the real RevertCounter on L1 and reverts naturally; the entry still commits.
/// Env: ROLLUPS, PROOF_SYSTEM, REV_COUNTER_L1, SAFE_CAP_L2, SAFE_CAP_PROXY
contract Execute is Script, NestedCallRevertActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address revCounterL1 = vm.envAddress("REV_COUNTER_L1");
        address scapL2 = vm.envAddress("SAFE_CAP_L2");
        address scapProxy = vm.envAddress("SAFE_CAP_PROXY");

        vm.startBroadcast();
        // Alice = the broadcaster EOA (msg.sender into scapProxy); the outer entry's
        // crossChainCallHash must use alice = msg.sender.
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(revCounterL1, scapL2, msg.sender), noStaticEntries()
                )
            );
        (bool ok,) = scapProxy.call(_incrementProxyData());
        require(ok, "outer call failed");

        require(RevertCounter(revCounterL1).counter() == 0, "reverted inner call must commit nothing on L1");

        console.log("done");
        console.log(
            "revCounterL1.counter=%s (expected 0 -- inner call reverted)", RevertCounter(revCounterL1).counter()
        );
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
        if (a == vm.envAddress("REV_COUNTER_L1")) return "RevertCounter(L1)";
        if (a == vm.envAddress("SAFE_CAP_L2")) return "SafeCAP(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == SafeCounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address revCounterL1 = vm.envAddress("REV_COUNTER_L1");
        address scapL2 = vm.envAddress("SAFE_CAP_L2");
        // Both sides' trigger source is the script broadcaster EOA acting as alice.
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(revCounterL1, scapL2, alice);
        L2ExecutionEntry[] memory l2 = _l2Entries(revCounterL1, scapL2, alice);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        _printL1CallHashes(l1);
        _printL2CallHashes(l2);
        _printL1Table(l1);
        _printL2Table(l2);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call w/ natural revert CALL_END(false)) ===");
        _logEntry(0, l1[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 1 success=false outgoing reentrant) ===");
        _logL2Entry(0, l2[0]);
    }
}
