// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {RollupUpdate, L2ToL1Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, ICounterView, StaticReadCounter} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    getOrCreateProxy,
    crossChainCallHashStatic,
    noL2Calls,
    noNestedActions,
    noStaticEntries,
    immediateSingleRollupBatch,
    RollingHashBuilder,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  StaticCounterL2 scenario — L2-starting, TOP-LEVEL static read of L1 state
//
//  Topology: Counter lives on L1 (incremented to 1 during deploy);
//  StaticReadCounter lives on L2, targeting the L2-side proxy of CounterL1.
//
//  L2 side (ExecuteL2 — both txs mined in one block; the L2 static pool is
//  same-block gated, lastLoadBlock == block.number):
//    1. SYSTEM loads a table with NO ExecutionEntry and ONE
//       StaticExecutionEntry, keyed to the reader (the key folds the proxy
//       caller); matched by hash alone
//    2. alice -> reader.increment()          (the ONE user trigger)
//         reader STATICCALLs counterL1ProxyL2.counter()
//         -> proxy detects the static frame -> EEZL2.staticCrossChainCall
//         -> outside any execution -> same-block staticEntries pool scan
//         -> returns cached abi.encode(1); reader stores lastRead = 1
//
//  L1 side (Execute): the read targets L1 state, so it EXECUTES for real there
//  — the L2 user tx maps to ONE immediate zero-hash L2Tx entry whose
//  l2ToL1Calls[0] is the read with isStatic = true: `_processNCalls`
//  dispatches it via STATICCALL through the reader's L1-side source proxy into
//  the live CounterL1 and folds CALL_BEGIN(staticCcHash) /
//  CALL_END(true, abi.encode(1)) with the real returndata.
//
//  The cross-chain tie: the L2 pool entry's key and the L1-executed call fold
//  the SAME staticCcHash digest (isStatic folded, source = the reader at the
//  L2's rollup id, callGas 0), and the cached value must equal what the real
//  CounterL1 returns. Only the L1 side emits events (EntryExecuted), so
//  ComputeExpected exports the L1 expectations; the L2 side is pinned by the
//  trigger tx reverting on any mismatch plus the in-script asserts.
//
//  Final state: L2 reader.counter == 1, reader.lastRead == 1;
//               L1 CounterL1.counter == 1 (unchanged by the flow).
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract StaticCounterL2Actions {
    /// Calldata of the reader's STATICCALL: Counter's auto-generated `counter()` getter,
    /// referenced through `ICounterView` (compile-checked — `Counter` implements it).
    function _counterCallData() internal pure returns (bytes memory) {
        return abi.encodeCall(ICounterView.counter, ());
    }

    /// Static read key, same digest on BOTH sides: `EEZL2.staticCrossChainCall` folds
    /// isStatic = true, source = the reader at the L2's OWN rollup id, target =
    /// (CounterL1, MAINNET), value 0, callGas 0 (static keys never fold gas, even under
    /// USE_GAS_LEFT) — and L1's `_processNCalls` folds the identical preimage for the
    /// executed isStatic call.
    function _staticKey(address counterL1, address readerL2) internal pure returns (bytes32) {
        return crossChainCallHashStatic(readerL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _counterCallData());
    }

    /// The ONE pool static entry, keyed to the reader (the key folds the proxy caller):
    /// no sub-calls (an empty array folds rollingHash 0), cached abi.encode(1). L2 has no
    /// root pins — the same-block load gate bounds staleness instead.
    function _staticEntries(
        address counterL1,
        address readerL2
    )
        internal
        pure
        returns (L2StaticExecutionEntry[] memory entries)
    {
        entries = new L2StaticExecutionEntry[](1);
        entries[0] = L2StaticExecutionEntry({
            proxyEntryHash: _staticKey(counterL1, readerL2),
            incomingCalls: noL2Calls(),
            rollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    /// The L2 user tx as ONE zero-hash L2Tx entry on L1: its only cross-chain activity is
    /// the static read, EXECUTED for real here — l2ToL1Calls[0] carries isStatic = true, so
    /// `_processNCalls` dispatches it via STATICCALL against the live CounterL1 and folds
    /// the real returndata.
    function _l1Entries(address counterL1, address readerL2) internal pure returns (ExecutionEntry[] memory entries) {
        RollupUpdate[] memory deltas = new RollupUpdate[](1);
        deltas[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-static-l2"),
            etherDelta: 0
        });

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: readerL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _counterCallData()
        });

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, _staticKey(counterL1, readerL2));
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1))); // the REAL CounterL1 value

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltas,
            proxyEntryHash: bytes32(0), // pure L2 tx — executed as an immediate L2Tx
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title Deploy — deploy Counter on L1 and set its live value to 1 (the read's real producer)
/// Outputs: COUNTER_L1
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        counterL1.increment();
        // Pins the producer: nothing in the flow mutates it, so this is the exact live
        // value the static entry's cached returnData (abi.encode(1)) must equal.
        require(counterL1.counter() == 1, "CounterL1 not at 1");
        console.log("COUNTER_L1=%s", address(counterL1));
        console.log("counterL1.counter=%s (the value the static read must return)", counterL1.counter());
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — on L2, create the proxy for CounterL1 + deploy the reader targeting it
/// Env: MANAGER_L2, COUNTER_L1
/// Outputs: COUNTER_PROXY_L2, READER_L2
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        address counterProxyL2 = getOrCreateProxy(IEEZ(managerAddr), counterL1Addr, MAINNET_ROLLUP_ID);
        StaticReadCounter reader = new StaticReadCounter(Counter(counterProxyL2));
        console.log("COUNTER_PROXY_L2=%s", counterProxyL2);
        console.log("READER_L2=%s", address(reader));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — local mode: loadExecutionTable (system) + the user trigger, mined
///        in one block (the L2 pool is only resolvable in the block it was loaded).
/// Env: MANAGER_L2, COUNTER_L1, READER_L2
contract ExecuteL2 is Script, StaticCounterL2Actions {
    function run() external {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        StaticReadCounter reader = StaticReadCounter(vm.envAddress("READER_L2"));

        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2"))
            .loadExecutionTable(new L2ExecutionEntry[](0), _staticEntries(counterL1Addr, address(reader)));
        reader.increment();

        require(reader.lastRead() == 1, "static read returned wrong value");
        require(reader.counter() == 1, "reader did not run");

        console.log("done");
        console.log("reader.lastRead=%s (expected 1)", reader.lastRead());
        console.log("reader.counter=%s (expected 1)", reader.counter());
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode: postAndVerifyBatch with the immediate L2Tx entry that
///        EXECUTES the static read for real on L1 (STATICCALL into the live CounterL1).
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L1, READER_L2
contract Execute is Script, StaticCounterL2Actions {
    function run() external {
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"),
                    L2_ROLLUP_ID,
                    _l1Entries(counterL1Addr, vm.envAddress("READER_L2")),
                    noStaticEntries()
                )
            );

        require(Counter(counterL1Addr).counter() == 1, "CounterL1 not at 1");
        console.log("done");
        console.log("counterL1=%s (expected 1, read-only flow)", Counter(counterL1Addr).counter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode: user tx fields for the L2 trigger
/// Env: READER_L2
contract ExecuteNetworkL2 is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("READER_L2"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(StaticReadCounter.increment.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected — only the L1 side has entries/events; the L2 side is a
//  pool of static entries (no ExecutionEntry, no consumption events), pinned
//  by the trigger + probe asserts in ExecuteL2.
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, StaticCounterL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("READER_L2")) return "StaticReadCounter(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == ICounterView.counter.selector) return "counter";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address readerL2Addr = vm.envAddress("READER_L2");

        _printL1Expectations(counterL1Addr, readerL2Addr);
        _logL2Pool(counterL1Addr, readerL2Addr);
    }

    // Separate frames keep the via-ir ABI-encoder stack of the nested entry arrays in check.
    function _printL1Expectations(address counterL1Addr, address readerL2Addr) private view {
        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, readerL2Addr);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        // Steps printed BEFORE the table on purpose: the reverse order makes solc's via-ir
        // backend run out of stack encoding the HashStep[][] blob next to the table encode.
        HashStep[][] memory steps = new HashStep[][](1); // mirrors _l1Entries' fold chain
        steps[0] = new HashStep[](2);
        steps[0][0] = RollingHashBuilder.stepCallBegin(_staticKey(counterL1Addr, readerL2Addr));
        steps[0][1] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(1)));
        _printL1Steps(l1, steps);
        _printL1Table(l1);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 L2Tx entry, 1 REAL static read call) ===");
        _logEntry(0, l1[0]);
    }

    function _logL2Pool(address counterL1Addr, address readerL2Addr) private view {
        console.log("");
        console.log("=== EXPECTED L2 STATIC POOL (1 entry, no events) ===");
        _logStaticLookup(0, _staticEntries(counterL1Addr, readerL2Addr)[0]);
    }
}
