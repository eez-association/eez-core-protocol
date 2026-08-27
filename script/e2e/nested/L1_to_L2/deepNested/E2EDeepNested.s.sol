// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {
    RootUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry,
    StaticExecutionEntry
} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy, NestedCaller} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    crossChainCallHashL2Out,
    expectedL1toL2Hash,
    noStaticEntries,
    noL2StaticEntries,
    noCalls,
    getOrCreateProxy,
    RollingHashBuilder,
    immediateSingleRollupBatch
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  DeepNested scenario — two levels of genuine cross-chain nesting, one
//  L1→L2→L1→L2 ping-pong
//
//  Topology (each hop crosses a chain boundary):
//    L2: CounterL2 (real, the innermost destination)
//    L1: CounterL2ProxyL1 = proxy(CounterL2@L2); CAP = CounterAndProxy(that proxy)
//    L2: CapProxyL2 = proxy(CAP@MAINNET); NC = NestedCaller(CapProxyL2)
//    L1: NcProxyL1 = proxy(NC@L2) — the user-tx target
//
//  Flow: alice → NcProxyL1.callNested() (top-level L1→L2 call) → NC runs on
//  L2, calls CAP back on L1 (nested outgoing frame) → CAP runs on L1,
//  reentrant-calls CounterL2 on L2 (nested L1→L2 row) → CounterL2.increment()
//  runs on L2 as the outgoing frame's own sub-call.
//
//  L1 view (Execute): 1 entry — l2ToL1Calls[0] runs NC's reentrant
//  CAP.incrementProxy() on L1; while CAP runs, its CounterL2 call resolves
//  from expectedL1ToL2Calls[0] (cached 1).
//  L2 view (ExecuteL2): 1 executeIncomingCrossChainCall delivery; the entry
//  wraps one nested (outgoing) frame whose OWN sub-array carries the
//  CAP→CounterL2 call — the sub-call executes on L2 during frame resolution.
//
//  Final state: L2 CounterL2.counter == 1, NC.counter == 1;
//               L1 CAP.counter == 1, CAP.targetCounter == 1.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract DeepNestedActions {
    function _callNestedData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(NestedCaller.callNested.selector);
    }

    function _incrementProxyData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
    }

    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// Outer/trigger hash (proxyEntryHash on BOTH sides): alice on L1 calls NC on L2.
    function _outerHash(address ncL2, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(false, alice, MAINNET_ROLLUP_ID, ncL2, L2_ROLLUP_ID, 0, _callNestedData());
    }

    /// L1 top-level call hash: NC's reentrant CAP.incrementProxy() executes ON L1
    /// (target rollup = MAINNET; source = NC @ L2).
    function _l1TopCallHash(address capL1, address ncL2) internal pure returns (bytes32) {
        return crossChainCallHash(false, ncL2, L2_ROLLUP_ID, capL1, MAINNET_ROLLUP_ID, 0, _incrementProxyData());
    }

    /// Inner L1→L2 reentry: CAP (on L1) calls CounterL2 via its L1-side proxy — keyed with
    /// the plain hash. The same preimage is the CALL_BEGIN fold of the L2 frame's sub-call.
    function _innerHash(address counterL2, address capL1) internal pure returns (bytes32) {
        return crossChainCallHash(false, capL1, MAINNET_ROLLUP_ID, counterL2, L2_ROLLUP_ID, 0, _incrementData());
    }

    /// L2 nested (outgoing) key: NC (on L2) calls CAP on MAINNET — the call LEAVES the L2, so
    /// it keys with the L2-outgoing hash (callGas=0; devnet deploys EEZL2 with useGasLeft=false).
    function _l2OutgoingHash(address capL1, address ncL2) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(ncL2, L2_ROLLUP_ID, capL1, MAINNET_ROLLUP_ID, 0, _incrementProxyData());
    }

    function _l1Entries(
        address counterL2,
        address capL1,
        address ncL2,
        address alice
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        RootUpdate[] memory deltas = new RootUpdate[](1);
        deltas[0] = RootUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-deep-nested"),
            etherDelta: 0
        });

        bytes32 proxyEntryHash = _outerHash(ncL2, alice);

        // Top-level L1 call: NC's reentrant CAP.incrementProxy() runs on L1.
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: ncL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: capL1,
            value: 0,
            data: _incrementProxyData()
        });

        bytes32 ccInner = _innerHash(counterL2, capL1);

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, _l1TopCallHash(capL1, ncL2));
        bytes32 rhFire = rh; // CAP's reentry to CounterL2 fires here
        rh = RollingHashBuilder.appendNestedBegin(rh, ccInner);
        rh = RollingHashBuilder.appendNestedEnd(rh); // the reentry runs no L1 sub-calls
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
            rootUpdates: deltas,
            proxyEntryHash: proxyEntryHash,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            rollingHash: rh,
            success: true,
            returnData: "" // callNested returns void
        });
    }

    function _l2Entries(
        address counterL2,
        address capL1,
        address ncL2,
        address alice
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 proxyEntryHash = _outerHash(ncL2, alice);
        bytes32 ccOutgoing = _l2OutgoingHash(capL1, ncL2);
        bytes32 ccSubCall = _innerHash(counterL2, capL1);

        // Inbound top-level call: alice → NC on L2.
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: ncL2,
            value: 0,
            data: _callNestedData()
        });

        // The outgoing frame's OWN sub-call: CAP (on MAINNET) → CounterL2, executed on L2
        // during frame resolution.
        CrossChainCall[] memory frameCalls = new CrossChainCall[](1);
        frameCalls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: capL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: _incrementData()
        });

        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, proxyEntryHash);
        bytes32 rhFire = rh; // NC's outgoing call to CAP fires here
        rh = RollingHashBuilder.appendNestedBegin(rh, ccOutgoing);
        rh = RollingHashBuilder.appendCallBegin(rh, ccSubCall); // frame sub-call: CounterL2.increment()
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, ""); // callNested returns void

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(ccOutgoing, rhFire),
            incomingCalls: frameCalls,
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: "" // incrementProxy returns void
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
//  Deploys — four-phase order (each phase needs the previous one's address):
//    1. DeployL2 (L2) — CounterL2, the innermost destination.
//    2. Deploy (L1) — L1-side proxy for CounterL2 + CAP targeting it.
//    3. DeployL2Nested (L2) — L2-side proxy for CAP + NC targeting it.
//    4. Deploy2 (L1) — L1-side proxy for NC (the user-tx target).
// ═══════════════════════════════════════════════════════════════════════

// Outputs: COUNTER_L2
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL2 = new Counter();
        console.log("COUNTER_L2=%s", address(counterL2));
        vm.stopBroadcast();
    }
}

// Env: ROLLUPS, COUNTER_L2
// Outputs: COUNTER_L2_PROXY_L1 (proxy on L1 for CounterL2 — CAP.target), CAP_L1
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        address counterL2ProxyL1 = getOrCreateProxy(IEEZ(rollupsAddr), counterL2Addr, L2_ROLLUP_ID);
        CounterAndProxy cap = new CounterAndProxy(Counter(counterL2ProxyL1));
        console.log("COUNTER_L2_PROXY_L1=%s", counterL2ProxyL1);
        console.log("CAP_L1=%s", address(cap));
        vm.stopBroadcast();
    }
}

// Env: MANAGER_L2, CAP_L1
// Outputs: CAP_PROXY_L2 (proxy on L2 for CAP on MAINNET — NC.target), NESTED_CALLER_L2
contract DeployL2Nested is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address capL1Addr = vm.envAddress("CAP_L1");

        vm.startBroadcast();
        address capProxyL2 = getOrCreateProxy(IEEZ(managerAddr), capL1Addr, MAINNET_ROLLUP_ID);
        NestedCaller nc = new NestedCaller(CounterAndProxy(capProxyL2));
        console.log("CAP_PROXY_L2=%s", capProxyL2);
        console.log("NESTED_CALLER_L2=%s", address(nc));
        vm.stopBroadcast();
    }
}

// Env: ROLLUPS, NESTED_CALLER_L2
// Outputs: NC_PROXY_L1 (proxy on L1 for NC on L2 — the user-tx target)
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address ncL2Addr = vm.envAddress("NESTED_CALLER_L2");

        vm.startBroadcast();
        address ncProxyL1 = getOrCreateProxy(IEEZ(rollupsAddr), ncL2Addr, L2_ROLLUP_ID);
        console.log("NC_PROXY_L1=%s", ncProxyL1);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// ExecuteL2 — local mode: SYSTEM-driven inbound delivery of alice's callNested().
/// NC's outgoing call to CAP resolves against expectedOutgoingCalls[0]; the frame's own
/// sub-call runs CounterL2.increment() on L2.
/// Env: MANAGER_L2, COUNTER_L2, CAP_L1, NESTED_CALLER_L2
contract ExecuteL2 is Script, DeepNestedActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capL1Addr = vm.envAddress("CAP_L1");
        address ncL2Addr = vm.envAddress("NESTED_CALLER_L2");

        vm.startBroadcast();
        address alice = msg.sender;
        EEZL2(managerAddr)
            .executeIncomingCrossChainCall(_l2Entries(counterL2Addr, capL1Addr, ncL2Addr, alice), noL2StaticEntries());

        console.log("done");
        console.log("counterL2=%s (expected 1)", Counter(counterL2Addr).counter());
        console.log("nc.counter=%s (expected 1)", NestedCaller(ncL2Addr).counter());
        vm.stopBroadcast();
    }
}

/// Execute — local mode: postAndVerifyBatch tx + outer trigger tx from the EOA.
/// The runner mines both in one block (execute_l1_same_block), satisfying the
/// same-block consumption gate.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L2, CAP_L1, NESTED_CALLER_L2, NC_PROXY_L1
contract Execute is Script, DeepNestedActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capL1Addr = vm.envAddress("CAP_L1");
        address ncL2Addr = vm.envAddress("NESTED_CALLER_L2");
        address ncProxyL1 = vm.envAddress("NC_PROXY_L1");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr,
                    L2_ROLLUP_ID,
                    _l1Entries(counterL2Addr, capL1Addr, ncL2Addr, msg.sender),
                    noStaticEntries()
                )
            );
        (bool ok,) = ncProxyL1.call(_callNestedData());
        require(ok, "outer call failed");

        console.log("done");
        console.log("cap.counter=%s (expected 1)", CounterAndProxy(capL1Addr).counter());
        console.log("cap.targetCounter=%s (expected 1)", CounterAndProxy(capL1Addr).targetCounter());
        vm.stopBroadcast();
    }
}

/// ExecuteNetwork — network mode: user tx fields for the L1 trigger.
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("NC_PROXY_L1");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(NestedCaller.callNested.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, DeepNestedActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "CounterL2";
        if (a == vm.envAddress("CAP_L1")) return "CAP(L1)";
        if (a == vm.envAddress("NESTED_CALLER_L2")) return "NC(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        if (sel == NestedCaller.callNested.selector) return "callNested";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capL1Addr = vm.envAddress("CAP_L1");
        address ncL2Addr = vm.envAddress("NESTED_CALLER_L2");
        // Both sides' trigger source is the script broadcaster EOA acting as alice.
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, capL1Addr, ncL2Addr, alice);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL2Addr, capL1Addr, ncL2Addr, alice);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2[0].proxyEntryHash));
        _printL1Table(l1);
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, 1 nested) ===");
        _logEntry(0, l1[0]);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 1 nested with 1 sub-call) ===");
        _logL2Entry(0, l2[0]);
    }
}
