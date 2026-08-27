// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {RollupUpdate, L2ToL1Call, ExecutionEntry, StaticExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy} from "../../../../../test/mocks/CounterContracts.sol";
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
//  NestedCounter scenario — minimal single nested reentry, L1-anchored,
//  one genuine L1→L2→L1 round trip
//
//  Topology: CAP lives on L2 (target = the L2-side proxy for CounterL1 on
//  MAINNET); alice on L1 triggers CAP through its L1-side proxy.
//
//  Flow: alice → capL2Proxy.incrementProxy() (one L1→L2 top-level call) →
//  CAP runs on L2, increments its counter, and reentrant-calls CounterL1
//  back on L1 — the L2 manager matches expectedOutgoingCalls[0] and returns
//  the cached 1 (exercising the L2 nested table; the L1 nested table is
//  covered by the L2-anchored sibling nestedCounterL2).
//
//  L1 view (Execute): 1 entry — l2ToL1Calls[0] runs CAP's reentrant
//  CounterL1.increment() on L1 (returns 1); no L1 nested rows.
//  L2 view (ExecuteL2): 1 executeIncomingCrossChainCall delivery keyed by
//  the same cross-chain call hash as the L1 side; the entry wraps one
//  nested (outgoing) frame with cached result 1.
//
//  Final state: L1 CounterL1.counter == 1; L2 CAP.counter == 1,
//  CAP.targetCounter == 1.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedActions {
    /// Outer/trigger hash (proxyEntryHash on BOTH sides): alice on L1 calls capL2 on L2
    /// through the L1-side proxy. The inbound delivery keys on the same hash.
    function _outerHash(address capL2, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(
            false,
            alice,
            MAINNET_ROLLUP_ID,
            capL2,
            L2_ROLLUP_ID,
            0,
            abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector)
        );
    }

    /// L1 top-level call hash: capL2's reentrant CounterL1.increment() executes ON L1
    /// (target rollup = MAINNET; source = capL2 @ L2).
    function _l1TopCallHash(address counterL1, address capL2) internal pure returns (bytes32) {
        return crossChainCallHash(
            false,
            capL2,
            L2_ROLLUP_ID,
            counterL1,
            MAINNET_ROLLUP_ID,
            0,
            abi.encodeWithSelector(Counter.increment.selector)
        );
    }

    /// Inner on L2: capL2 (on L2) reentrant-calls counterL1 on MAINNET — the call LEAVES the L2, so
    /// it keys with the L2-outgoing hash (callGas=0; devnet deploys EEZL2 with useGasLeft=false).
    /// The L2 manager forces sourceRollupId=ROLLUP_ID (=L2) on the on-chain compute.
    function _l2InnerHash(address counterL1, address capL2) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(
            capL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, abi.encodeWithSelector(Counter.increment.selector)
        );
    }

    function _l1Entries(
        address counterL1,
        address capL2,
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
            newRoot: keccak256("l2-state-after-nested"),
            etherDelta: 0
        });

        bytes32 proxyEntryHash = _outerHash(capL2, alice);

        // Top-level L1 call: capL2's reentrant CounterL1.increment() runs on L1.
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: capL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector)
        });

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, _l1TopCallHash(counterL1, capL2));
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));

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

    // L2 mirror entry.  The outer call is the inbound call delivered by
    // executeIncomingCrossChainCall through the source proxy (alice on MAINNET, on L2) — bound
    // against the explicit params (callGas = 0); only the nested outgoing reentry can key on
    // observed gas (devnet runs `useGasLeft = false`).
    function _l2Entries(
        address counterL1,
        address capL2,
        address alice
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 proxyEntryHash = _outerHash(capL2, alice);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: capL2,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector)
        });

        // Incoming top-level call CALL_BEGIN hash — target on this L2 (L2_ROLLUP_ID), source on
        // MAINNET (== proxyEntryHash here). Inner reentry uses _l2InnerHash.
        bytes32 ccTop = _outerHash(capL2, alice);
        bytes32 ccInner = _l2InnerHash(counterL1, capL2);

        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, ccTop);
        bytes32 rhFire = rh;
        rh = RollingHashBuilder.appendNestedBegin(rh, ccInner);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(ccInner, rhFire), // ccInner is the L2-outgoing hash
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
//  Deploys — three-phase order (each phase needs the previous one's address):
//    1. Deploy (L1) — counterL1, the destination of CAP's reentrant call.
//    2. DeployL2 (L2) — L2-side proxy for counterL1 + capL2 targeting it.
//    3. Deploy2 (L1) — L1-side proxy for capL2 (the user-tx target).
// ═══════════════════════════════════════════════════════════════════════

// Outputs: COUNTER_L1 (destination of the nested reentrant call)
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));
        vm.stopBroadcast();
    }
}

// Env: MANAGER_L2, COUNTER_L1
// Outputs: COUNTER_L1_PROXY_L2 (proxy on L2 for counterL1 on MAINNET — capL2.target),
//          COUNTER_AND_PROXY_L2 (CAP on L2, the real cross-chain callee).
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        // Proxy on L2 for counterL1 on MAINNET — used by capL2 to reach back to L1.
        address counterL1ProxyL2 = getOrCreateProxy(IEEZ(address(manager)), counterL1Addr, MAINNET_ROLLUP_ID);

        // capL2 — CAP on L2 whose `target` is the L2-side proxy for counterL1.
        // capL2.incrementProxy() reentrant-calls counterL1 via the proxy.
        CounterAndProxy capL2 = new CounterAndProxy(Counter(counterL1ProxyL2));

        console.log("COUNTER_L1_PROXY_L2=%s", counterL1ProxyL2);
        console.log("COUNTER_AND_PROXY_L2=%s", address(capL2));
        vm.stopBroadcast();
    }
}

// Env: ROLLUPS, COUNTER_AND_PROXY_L2
// Outputs: CAP_L2_PROXY (L1-side proxy for capL2 on L2 — the user-tx target).
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address capL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        vm.startBroadcast();
        address capL2Proxy = getOrCreateProxy(IEEZ(rollupsAddr), capL2Addr, L2_ROLLUP_ID);
        console.log("CAP_L2_PROXY=%s", capL2Proxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

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
            .executeIncomingCrossChainCall(_l2Entries(counterL1Addr, capL2Addr, alice), noL2StaticEntries());

        console.log("done");
        console.log("capL2.counter=%s", CounterAndProxy(capL2Addr).counter());
        console.log("capL2.targetCounter=%s", CounterAndProxy(capL2Addr).targetCounter());
        vm.stopBroadcast();
    }
}

/// Execute — local mode: postAndVerifyBatch tx + outer trigger tx from the EOA.
/// The runner mines both in one block (execute_l1_same_block), satisfying the
/// same-block consumption gate.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L1, COUNTER_AND_PROXY_L2, CAP_L2_PROXY
contract Execute is Script, NestedActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address capL2Proxy = vm.envAddress("CAP_L2_PROXY");

        vm.startBroadcast();
        // Alice = the broadcaster EOA (msg.sender into capL2Proxy).
        // The outer entry's crossChainCallHash must use alice = msg.sender.
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL1Addr, capL2Addr, msg.sender), noStaticEntries()
                )
            );
        (bool ok,) = capL2Proxy.call(abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector));
        require(ok, "outer call failed");

        console.log("done");
        console.log("counterL1=%s (expected 1)", Counter(counterL1Addr).counter());
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
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L2")) return "CAP(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");
        // Both sides' trigger source is the script broadcaster EOA acting as alice.
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, capL2Addr, alice);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, capL2Addr, alice);

        bytes32 l1Hash = _entryHash(l1[0]);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2[0].proxyEntryHash));
        _printL1Table(l1);
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, no nested) ===");
        _logEntry(0, l1[0]);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 1 nested) ===");
        _logL2Entry(0, l2[0]);
    }
}
