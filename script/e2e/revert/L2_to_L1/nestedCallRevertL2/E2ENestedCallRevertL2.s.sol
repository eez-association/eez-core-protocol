// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {RollupUpdate, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2ExecutionEntry, CrossChainCall} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, RevertCounter, SafeCounterAndProxy} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
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
//  NestedCallRevertL2 — nested reentrant call whose DESTINATION reverts;
//  the caller recovers with try/catch. L2-anchored mirror of
//  nestedCallRevert: here SafeCAP runs ON L1 and its reentrant L1→L2 call
//  is the one that reverts, exercising the L1 manager's success=false
//  ExpectedL1ToL2Call path. ONE trigger tx (alice on L2), one flow: both
//  tables are views of the SAME execution, and the revert data has a real
//  producer (RevertCounter.increment() on L2 → Error("always reverts")),
//  executed inside the trigger consumption's own entry — no extra delivery.
//
//  Topology: RevertCounter on L2 (the inner target; always reverts);
//  SafeCAP on L1 (SafeCounterAndProxy targeting the L1-side proxy for
//  RevertCounter@L2); alice on L2 triggers SafeCAP through its L2-side proxy.
//
//  L1 side (Execute) — where SafeCAP really runs, as an immediate L2Tx entry:
//    postAndVerifyBatch ─ runs the zero-hash L2Tx entry:
//      └─ SafeCAP(L1).incrementProxy()      l2ToL1Calls[0], sourced alice@L2
//           ├─ try revCounterProxy.increment()
//           │    └─ EEZ.executeCrossChainCall ─ nested: matches the success=false
//           │       expectedL1ToL2Calls[0]  (key = keccak256(innerCch, rhAtFire))
//           │       ◀─ revert Error("always reverts")  ◀── NESTED_BEGIN fold + cursor UNWIND
//           ├─ catch → lastCallFailed = true
//           └─ counter++                                   (entry COMMITS)
//    result: counter == 1, lastCallFailed == true, targetCounter == 0; the
//    committed hash carries only the top-level CALL_BEGIN/CALL_END — no NESTED tags
//
//  L2 side (ExecuteL2) — the single trigger tx; consuming the outgoing
//  entry replays the round trip, running SafeCAP's inner call for real:
//    alice ──tx──▶ scapProxyL2.call(incrementProxy())    proxy for (SafeCAP@L1)
//      └─ EEZL2.executeCrossChainCall ─ consumes the outgoing entry:
//           incomingCalls[0] ─ source proxy ─▶ RevertCounter(L2).increment()
//                ◀─ revert("always reverts")   ◀── SafeCAP's inner call, run FOR REAL
//              folded CALL_END(false, Error("always reverts")); the entry
//              COMMITS and returns void to alice
//    result: RevertCounter(L2).counter == 0 — the same revert data appears
//    on both sides because ONE contract produces it
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedCallRevertL2Actions {
    function _incrementProxyData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector);
    }

    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev Error(string) revert data produced by `RevertCounter.increment()` on L2 —
    ///      the single real producer both tables replay.
    function _revertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "always reverts");
    }

    /// Outgoing/trigger key: alice's call LEAVES the L2 through scapProxyL2, so
    /// `EEZL2.executeCrossChainCall` keys it with the L2-outgoing hash (callGas=0 —
    /// devnet deploys EEZL2 with useGasLeft=false).
    function _outgoingHash(address scapL1, address alice) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(alice, L2_ROLLUP_ID, scapL1, MAINNET_ROLLUP_ID, 0, _incrementProxyData());
    }

    /// L1 top-level call hash: SafeCAP.incrementProxy() executes ON L1 (target rollup =
    /// MAINNET; source = alice @ L2).
    function _l1TopCallHash(address scapL1, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(false, alice, L2_ROLLUP_ID, scapL1, MAINNET_ROLLUP_ID, 0, _incrementProxyData());
    }

    /// Inner L1→L2 reentry: SafeCAP (on L1) calls RevertCounter on L2 via its L1-side proxy —
    /// keyed with the plain hash. The same hash keys the L1 nested row AND the CALL_BEGIN
    /// fold of the call's real execution inside the L2 outgoing entry.
    function _innerHash(address revCounterL2, address scapL1) internal pure returns (bytes32) {
        return crossChainCallHash(false, scapL1, MAINNET_ROLLUP_ID, revCounterL2, L2_ROLLUP_ID, 0, _incrementData());
    }

    /// The user tx's outgoing entry — the L2 view of the whole round trip (mirror of the
    /// sibling's L1 entry): `incomingCalls[0]` is SafeCAP's inner call, REALLY executed on
    /// L2 during the trigger consumption. RevertCounter reverts naturally, folded
    /// CALL_END(false, revertData); the entry itself commits and returns void to alice.
    function _l2OutgoingEntry(
        address revCounterL2,
        address scapL1,
        address alice
    )
        internal
        pure
        returns (L2ExecutionEntry memory)
    {
        bytes32 key = _outgoingHash(scapL1, alice);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: scapL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: revCounterL2,
            value: 0,
            data: _incrementData()
        });

        bytes32 rh = RollingHashBuilder.entryBeginL2(key);
        rh = RollingHashBuilder.appendCallBegin(rh, _innerHash(revCounterL2, scapL1));
        rh = RollingHashBuilder.appendCallEnd(rh, false, _revertData());

        return L2ExecutionEntry({
            proxyEntryHash: key,
            incomingCalls: calls,
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: rh,
            success: true,
            returnData: "" // incrementProxy returns void
        });
    }

    /// The complete L2-side table: the single outgoing entry above — one trigger tx, no
    /// separate delivery (the inner call rides the trigger consumption).
    function _l2Entries(
        address revCounterL2,
        address scapL1,
        address alice
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        entries = new L2ExecutionEntry[](1);
        entries[0] = _l2OutgoingEntry(revCounterL2, scapL1, alice);
    }

    /// L1 entry — SafeCAP's execution: its reverting reentry is a success=false row in the
    /// unified table; the NESTED_BEGIN fold + cursor bump unwind with the revert SafeCAP
    /// catches, so the committed hash only carries the top-level CALL_BEGIN/CALL_END.
    function _l1Entries(
        address revCounterL2,
        address scapL1,
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
            newRoot: keccak256("l2-state-after-nested-call-revert-l2"),
            etherDelta: 0
        });

        // The L2Tx entry's top-level call: SafeCAP.incrementProxy() runs on L1, sourced at alice@L2.
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: scapL1,
            value: 0,
            data: _incrementProxyData()
        });

        bytes32 ccInner = _innerHash(revCounterL2, scapL1);

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, _l1TopCallHash(scapL1, alice));
        bytes32 rhFire = rh; // SafeCAP's reentry to RevertCounter@L2 fires here
        rh = RollingHashBuilder.appendCallEnd(rh, true, ""); // no NESTED tags survive the try/catch

        // Sub-frame hash at the revert point: NESTED_BEGIN over an empty sub-array (the
        // reverted L2 frame makes no calls back into L1). No NESTED_END: the manager checks
        // `revertedOrStaticRollingHash` right after the sub-calls run and then reverts —
        // NESTED_END is folded only on the success path (`_resolveNestedReentrant`).
        bytes32 revertedSubHash = RollingHashBuilder.appendNestedBegin(rhFire, ccInner);

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(ccInner, rhFire),
            l2ToL1Calls: noCalls(),
            revertedOrStaticRollingHash: revertedSubHash,
            success: false,
            returnData: _revertData()
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltas,
            proxyEntryHash: bytes32(0), // pure L2 tx — consumed by postAndVerifyBatch/executeL2Txs
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys — three-phase order (each phase needs the previous one's address):
//    1. DeployL2 (L2) — RevertCounter, the always-reverting inner target.
//    2. Deploy (L1) — L1-side proxy for RevertCounter@L2 + SafeCAP targeting it.
//    3. DeployL2Trigger (L2) — L2-side proxy for SafeCAP (the user-tx target).
// ═══════════════════════════════════════════════════════════════════════

// Outputs: REV_COUNTER_L2 (destination of the nested reentrant call; always reverts)
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        RevertCounter revCounter = new RevertCounter();
        output("REV_COUNTER_L2", address(revCounter));
        vm.stopBroadcast();
    }
}

// Env: ROLLUPS, REV_COUNTER_L2
// Outputs: REV_COUNTER_PROXY_L1 (proxy on L1 for RevertCounter@L2 — SafeCAP.target),
//          SAFE_CAP_L1 (SafeCAP on L1, the real cross-chain callee).
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address revCounterL2 = vm.envAddress("REV_COUNTER_L2");

        vm.startBroadcast();
        address revCounterProxyL1 = getOrCreateProxy(IEEZ(rollupsAddr), revCounterL2, L2_ROLLUP_ID);

        // SafeCAP on L1: try/catches target.increment() through the proxy, so the
        // destination's revert is recovered from and the entry commits.
        SafeCounterAndProxy scap = new SafeCounterAndProxy(Counter(revCounterProxyL1));

        output("REV_COUNTER_PROXY_L1", revCounterProxyL1);
        output("SAFE_CAP_L1", address(scap));
        vm.stopBroadcast();
    }
}

// Env: MANAGER_L2, SAFE_CAP_L1
// Outputs: SAFE_CAP_PROXY_L2 (proxy on L2 for SafeCAP on MAINNET — the user-tx target)
contract DeployL2Trigger is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address scapL1 = vm.envAddress("SAFE_CAP_L1");

        vm.startBroadcast();
        address scapProxyL2 = getOrCreateProxy(IEEZ(managerAddr), scapL1, MAINNET_ROLLUP_ID);
        output("SAFE_CAP_PROXY_L2", scapProxyL2);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// ExecuteL2 — local mode: loadExecutionTable + alice's trigger tx, nothing else. The
/// trigger consumption runs SafeCAP's inner call on the real RevertCounter, which
/// reverts naturally — captured as CALL_END(false); the consumption still commits.
/// Env: MANAGER_L2, REV_COUNTER_L2, SAFE_CAP_L1, SAFE_CAP_PROXY_L2
contract ExecuteL2 is Script, NestedCallRevertL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address revCounterL2 = vm.envAddress("REV_COUNTER_L2");
        address scapL1 = vm.envAddress("SAFE_CAP_L1");
        address scapProxyL2 = vm.envAddress("SAFE_CAP_PROXY_L2");

        vm.startBroadcast();
        address alice = msg.sender;

        EEZL2(managerAddr).loadExecutionTable(_l2Entries(revCounterL2, scapL1, alice), noL2StaticEntries());

        (bool ok,) = scapProxyL2.call(_incrementProxyData());
        require(ok, "outgoing call failed");

        require(RevertCounter(revCounterL2).counter() == 0, "reverted inner call must commit nothing on L2");

        console.log("done");
        console.log(
            "revCounterL2.counter=%s (expected 0 -- inner call reverted)", RevertCounter(revCounterL2).counter()
        );
        vm.stopBroadcast();
    }
}

/// Execute — local mode: postAndVerifyBatch with the single immediate L2Tx entry. SafeCAP's
/// inner call hits `_consumeNestedCall`, matches the success=false expectedL1ToL2Calls[0]
/// and reverts with the cached Error("always reverts"); the try/catch records it.
/// Env: ROLLUPS, PROOF_SYSTEM, REV_COUNTER_L2, SAFE_CAP_L1
contract Execute is Script, NestedCallRevertL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address revCounterL2 = vm.envAddress("REV_COUNTER_L2");
        address scapL1 = vm.envAddress("SAFE_CAP_L1");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(revCounterL2, scapL1, msg.sender), noStaticEntries()
                )
            );

        SafeCounterAndProxy scap = SafeCounterAndProxy(scapL1);
        require(scap.counter() == 1, "SafeCAP must commit its own increment");
        require(scap.lastCallFailed(), "inner revert must be caught and recorded");
        require(scap.targetCounter() == 0, "no target result on a reverted inner call");

        console.log("done");
        console.log("scap.counter=%s", scap.counter());
        console.log("scap.targetCounter=%s", scap.targetCounter());
        console.log("scap.lastCallFailed=%s", scap.lastCallFailed());
        vm.stopBroadcast();
    }
}

/// ExecuteNetworkL2 — network mode: user tx fields for the L2 trigger.
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("SAFE_CAP_PROXY_L2");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, NestedCallRevertL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("REV_COUNTER_L2")) return "RevertCounter(L2)";
        if (a == vm.envAddress("SAFE_CAP_L1")) return "SafeCAP(L1)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == SafeCounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address revCounterL2 = vm.envAddress("REV_COUNTER_L2");
        address scapL1 = vm.envAddress("SAFE_CAP_L1");
        // The trigger source is the script broadcaster EOA acting as alice.
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(revCounterL2, scapL1, alice);
        L2ExecutionEntry[] memory l2 = _l2Entries(revCounterL2, scapL1, alice);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        _printL1CallHashes(l1);
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2[0].proxyEntryHash));
        _printL1Table(l1);
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 L2Tx entry, 1 call, 1 success=false reentrant) ===");
        _logEntry(0, l1[0]);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 outgoing entry, 1 really-executed reverting call) ===");
        _logL2Entry(0, l2[0]);
    }
}
