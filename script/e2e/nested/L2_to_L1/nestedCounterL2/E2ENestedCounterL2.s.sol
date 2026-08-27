// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {RollupUpdate, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
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
    noCalls,
    noL2OutgoingCalls,
    noL2Calls,
    getOrCreateProxy,
    immediateSingleRollupBatch,
    RollingHashBuilder
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  NestedCounterL2 scenario — minimal single nested reentry, L2-anchored,
//  one genuine L2→L1→L2 round trip (the mirror of nestedCounter)
//
//  Topology: CAP lives on L1 (target = the L1-side proxy for CounterL2 on
//  L2); alice on L2 triggers CAP through its L2-side proxy.
//
//  Flow: alice → capProxyL2.incrementProxy() (one outgoing L2→L1 call) →
//  CAP runs on L1 inside the L2Tx entry, increments its counter, and
//  reentrant-calls CounterL2 back on L2 — matched against
//  expectedL1ToL2Calls[0] (exercising the L1 nested table; the L2 nested
//  table is covered by the L1-anchored sibling nestedCounter).
//
//  L2 view (ExecuteL2): the user tx consumes ONE cached-result outgoing
//  entry (no calls execute on L2 for it); CAP's reentrant CounterL2 call
//  arrives back on L2 as its OWN executeIncomingCrossChainCall delivery
//  (see EXECUTION_ENTRY_SPEC §1-to-1 rule).
//  L1 view (Execute): 1 zero-hash L2Tx entry — l2ToL1Calls[0] runs
//  CAP.incrementProxy() on L1; its CounterL2 reentry resolves from
//  expectedL1ToL2Calls[0] (cached 1).
//
//  Final state: L1 CAP.counter == 1, CAP.targetCounter == 1;
//               L2 CounterL2.counter == 1.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedL2Actions {
    function _incrementProxyData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
    }

    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// Outgoing/trigger key: alice's call LEAVES the L2 through capProxyL2, so
    /// `EEZL2.executeCrossChainCall` keys it with the L2-outgoing hash (callGas=0 —
    /// devnet deploys EEZL2 with useGasLeft=false).
    function _outgoingHash(address capL1, address alice) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(alice, L2_ROLLUP_ID, capL1, MAINNET_ROLLUP_ID, 0, _incrementProxyData());
    }

    /// L1 top-level call hash: CAP.incrementProxy() executes ON L1 (target rollup =
    /// MAINNET; source = alice @ L2).
    function _l1TopCallHash(address capL1, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(false, alice, L2_ROLLUP_ID, capL1, MAINNET_ROLLUP_ID, 0, _incrementProxyData());
    }

    /// Inner L1→L2 reentry: CAP (on L1) calls CounterL2 via its L1-side proxy — keyed with
    /// the plain hash. The same hash keys the incoming delivery back on L2.
    function _innerHash(address counterL2, address capL1) internal pure returns (bytes32) {
        return crossChainCallHash(false, capL1, MAINNET_ROLLUP_ID, counterL2, L2_ROLLUP_ID, 0, _incrementData());
    }

    /// The user tx's outgoing entry — cached result only, nothing executes on L2 for it.
    function _l2OutgoingEntry(address capL1, address alice) internal pure returns (L2ExecutionEntry memory) {
        bytes32 key = _outgoingHash(capL1, alice);
        return L2ExecutionEntry({
            proxyEntryHash: key,
            incomingCalls: new CrossChainCall[](0),
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: RollingHashBuilder.entryBeginL2(key),
            success: true,
            returnData: "" // incrementProxy returns void
        });
    }

    /// CAP's reentrant CounterL2.increment(), delivered back on L2 as its own incoming
    /// execution (1-entry table).
    function _l2IncomingEntry(address counterL2, address capL1) internal pure returns (L2ExecutionEntry memory) {
        bytes32 key = _innerHash(counterL2, capL1);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: capL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: _incrementData()
        });

        bytes32 rh = RollingHashBuilder.entryBeginL2(key);
        rh = RollingHashBuilder.appendCallBegin(rh, key);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));
        return L2ExecutionEntry({
            proxyEntryHash: key,
            incomingCalls: calls,
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    /// Both L2-side executions in consumption order: the user's outgoing entry, then the
    /// inbound reentry delivery.
    function _l2Entries(
        address counterL2,
        address capL1,
        address alice
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        entries = new L2ExecutionEntry[](2);
        entries[0] = _l2OutgoingEntry(capL1, alice);
        entries[1] = _l2IncomingEntry(counterL2, capL1);
    }

    function _l1Entries(
        address counterL2,
        address capL1,
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
            newRoot: keccak256("l2-state-after-nested-l2"),
            etherDelta: 0
        });

        // The L2Tx entry's top-level call: CAP.incrementProxy() runs on L1, sourced at alice@L2.
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: capL1,
            value: 0,
            data: _incrementProxyData()
        });

        bytes32 ccInner = _innerHash(counterL2, capL1);

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, _l1TopCallHash(capL1, alice));
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
//    1. DeployL2 (L2) — CounterL2, the destination of CAP's reentrant call.
//    2. Deploy (L1) — L1-side proxy for CounterL2 + CAP targeting it.
//    3. DeployL2Trigger (L2) — L2-side proxy for CAP (the user-tx target).
// ═══════════════════════════════════════════════════════════════════════

// Outputs: COUNTER_L2 (destination of the nested reentrant call)
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
// Outputs: CAP_PROXY_L2 (proxy on L2 for CAP on MAINNET — the user-tx target)
contract DeployL2Trigger is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address capL1Addr = vm.envAddress("CAP_L1");

        vm.startBroadcast();
        address capProxyL2 = getOrCreateProxy(IEEZ(managerAddr), capL1Addr, MAINNET_ROLLUP_ID);
        console.log("CAP_PROXY_L2=%s", capProxyL2);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// ExecuteL2 — local mode: loadExecutionTable + alice's trigger tx, then the SYSTEM-driven
/// inbound delivery of CAP's reentrant CounterL2.increment() as its own tx.
/// Env: MANAGER_L2, COUNTER_L2, CAP_L1, CAP_PROXY_L2
contract ExecuteL2 is Script, NestedL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capL1Addr = vm.envAddress("CAP_L1");
        address capProxyL2 = vm.envAddress("CAP_PROXY_L2");

        vm.startBroadcast();
        address alice = msg.sender;

        L2ExecutionEntry[] memory table = new L2ExecutionEntry[](1);
        table[0] = _l2OutgoingEntry(capL1Addr, alice);
        EEZL2(managerAddr).loadExecutionTable(table, noL2StaticEntries());

        (bool ok,) = capProxyL2.call(_incrementProxyData());
        require(ok, "outgoing call failed");

        L2ExecutionEntry[] memory incoming = new L2ExecutionEntry[](1);
        incoming[0] = _l2IncomingEntry(counterL2Addr, capL1Addr);
        EEZL2(managerAddr).executeIncomingCrossChainCall(incoming, noL2StaticEntries());

        console.log("done");
        console.log("counterL2=%s (expected 1)", Counter(counterL2Addr).counter());
        vm.stopBroadcast();
    }
}

/// Execute — local mode: postAndVerifyBatch with the single immediate L2Tx entry.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L2, CAP_L1
contract Execute is Script, NestedL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capL1Addr = vm.envAddress("CAP_L1");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL2Addr, capL1Addr, msg.sender), noStaticEntries()
                )
            );

        console.log("done");
        console.log("cap.counter=%s (expected 1)", CounterAndProxy(capL1Addr).counter());
        console.log("cap.targetCounter=%s (expected 1)", CounterAndProxy(capL1Addr).targetCounter());
        vm.stopBroadcast();
    }
}

/// ExecuteNetworkL2 — network mode: user tx fields for the L2 trigger.
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("CAP_PROXY_L2");
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
        if (a == vm.envAddress("COUNTER_L2")) return "CounterL2";
        if (a == vm.envAddress("CAP_L1")) return "CAP(L1)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capL1Addr = vm.envAddress("CAP_L1");
        // The trigger source is the script broadcaster EOA acting as alice.
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, capL1Addr, alice);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL2Addr, capL1Addr, alice);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(_entryHash(l2[0])), vm.toString(_entryHash(l2[1])));
        _printL1CallHashes(l1);
        console.log(
            "EXPECTED_L2_CALL_HASHES=[%s,%s]", vm.toString(l2[0].proxyEntryHash), vm.toString(l2[1].proxyEntryHash)
        );
        _printL1Table(l1);
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 L2Tx entry, 1 call, 1 nested) ===");
        _logEntry(0, l1[0]);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (outgoing entry + incoming delivery) ===");
        _logL2Entry(0, l2[0]);
        _logL2Entry(1, l2[1]);
    }
}
