// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {RollupUpdate, L2ToL1Call, ExecutionEntry, ExpectedL1ToL2Call} from "../../../../../src/interfaces/IEEZ.sol";
import {
    CrossChainCall,
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntryL2 as L2StaticExecutionEntry
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, ICounterView} from "../../../../../test/mocks/CounterContracts.sol";
import {
    StaticCounterCallback,
    StaticCounterForwarder,
    StaticRoundTripReader
} from "../../../../../test/mocks/StaticRoundTripContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    getOrCreateProxy,
    crossChainCallHashStatic,
    expectedL1toL2Hash,
    noCalls,
    noStaticEntries,
    immediateSingleRollupBatch,
    RollingHashBuilder,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// Ready: included in automatic all/default runs.
// L2 reader.increment() -> STATIC L1 forwarder.counter() -> L1 callback helper -> STATIC L2 producer.counter().
// L2: load an empty mutable table + one static row, then trigger in the SAME block.
// The row executes its callback through the L2 source proxy of the L1 callback helper.
// L1: ONE immediate zero-hash L2Tx entry executes the real forwarder; its callback
// resolves from a position-pinned nested static row. No later L2 delivery is allowed.
// Final state: reader.counter=1, lastRead=1; producer.counter remains 1.

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract TopLevelStaticReentrantCounterL2Actions {
    /// Calldata of the reader's STATICCALL: Counter's auto-generated `counter()` getter,
    /// referenced through `ICounterView` (compile-checked — `Counter` implements it).
    function _counterCallData() internal pure returns (bytes memory) {
        return abi.encodeCall(ICounterView.counter, ());
    }

    /// Static read key, same digest on BOTH sides: `EEZL2.staticCrossChainCall` folds
    /// isStatic = true, source = the reader at the L2's OWN rollup id, target =
    /// (ForwarderL1, MAINNET), value 0, callGas 0. This fixture requires USE_GAS_LEFT = false;
    /// L1's `_processL2ToL1Calls` folds the identical preimage for the
    /// executed isStatic call.
    function _staticKey(address counterL1, address readerL2) internal pure returns (bytes32) {
        return crossChainCallHashStatic(readerL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _counterCallData());
    }

    /// L1 callback helper -> L2 producer: keyed at the parent CALL_BEGIN on L1.
    function _callbackKey(address producerL2, address callbackL1) internal pure returns (bytes32) {
        return crossChainCallHashStatic(callbackL1, MAINNET_ROLLUP_ID, producerL2, L2_ROLLUP_ID, 0, _counterCallData());
    }

    /// The ONE pool static entry, keyed to the reader (the key folds the proxy caller):
    /// one real static callback to the L2 producer, cached abi.encode(1). L2 has no
    /// root pins — the same-block load gate bounds staleness instead.
    function _staticEntries(
        address producerL2,
        address callbackL1,
        address counterL1,
        address readerL2
    )
        internal
        pure
        returns (L2StaticExecutionEntry[] memory entries)
    {
        entries = new L2StaticExecutionEntry[](1);
        entries[0] = L2StaticExecutionEntry({
            expectedEntryIndex: 0,
            proxyEntryHash: _staticKey(counterL1, readerL2),
            incomingCalls: _callbacks(producerL2, callbackL1),
            rollingHash: RollingHashBuilder.appendStatic(bytes32(0), true, abi.encode(uint256(1))),
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    function _callbacks(address producerL2, address callbackL1) internal pure returns (CrossChainCall[] memory calls) {
        calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: callbackL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: producerL2,
            value: 0,
            data: _counterCallData()
        });
    }

    /// The L2 user tx as ONE zero-hash L2Tx entry on L1: its only cross-chain activity is
    /// the static read, EXECUTED for real here — l2ToL1Calls[0] carries isStatic = true, so
    /// `_processL2ToL1Calls` dispatches it via STATICCALL against the live L1 forwarder and folds
    /// the real returndata.
    function _l1Entries(
        address producerL2,
        address callbackL1,
        address counterL1,
        address readerL2
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
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
        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        bytes32 callbackKey = _callbackKey(producerL2, callbackL1);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(callbackKey, rh),
            l2ToL1Calls: noCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltas,
            proxyEntryHash: bytes32(0), // pure L2 tx — executed as an immediate L2Tx
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }
}

// Deploy in dependency order; the L2 callback source proxy exists before any static read.
contract DeployProducerL2 is Script {
    function run() external {
        require(!EEZL2(vm.envAddress("MANAGER_L2")).USE_GAS_LEFT(), "scenario requires gas-independent L2 keys");
        vm.startBroadcast();
        Counter producer = new Counter();
        producer.increment();
        output("PRODUCER_L2", address(producer));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), vm.envAddress("PRODUCER_L2"), L2_ROLLUP_ID);
        StaticCounterCallback callback = new StaticCounterCallback(proxy);
        output("CALLBACK_L1", address(callback));
        output("COUNTER_L1", address(new StaticCounterForwarder(address(callback))));
        vm.stopBroadcast();
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        address proxy =
            getOrCreateProxy(IEEZ(vm.envAddress("MANAGER_L2")), vm.envAddress("COUNTER_L1"), MAINNET_ROLLUP_ID);
        address callbackProxy =
            getOrCreateProxy(IEEZ(vm.envAddress("MANAGER_L2")), vm.envAddress("CALLBACK_L1"), MAINNET_ROLLUP_ID);
        require(callbackProxy.code.length != 0, "L2 callback source proxy missing");
        output("CALLBACK_PROXY", callbackProxy);
        output("COUNTER_PROXY_L2", proxy);
        output(
            "READER_L2",
            address(
                new StaticRoundTripReader(
                    proxy, vm.envAddress("MANAGER_L2"), vm.envAddress("CALLBACK_L1"), MAINNET_ROLLUP_ID, false
                )
            )
        );
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — local mode: loadExecutionTable (system) + the user trigger, mined
///        in one block (the L2 pool is only resolvable in the block it was loaded).
/// Env: MANAGER_L2, COUNTER_L1, READER_L2
contract ExecuteL2 is Script, TopLevelStaticReentrantCounterL2Actions {
    function run() external {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        StaticRoundTripReader reader = StaticRoundTripReader(vm.envAddress("READER_L2"));

        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2"))
            .loadExecutionTable(
                new L2ExecutionEntry[](0),
                _staticEntries(
                    vm.envAddress("PRODUCER_L2"), vm.envAddress("CALLBACK_L1"), counterL1Addr, address(reader)
                )
            );
        reader.increment();
        require(EEZL2(vm.envAddress("MANAGER_L2")).entryIndex() == 0, "static read consumed mutable entry");

        require(reader.lastRead() == 1, "static read returned wrong value");
        require(reader.counter() == 1, "reader did not run");
        address callbackProxy = IEEZ(vm.envAddress("MANAGER_L2"))
            .computeCrossChainProxyAddress(vm.envAddress("CALLBACK_L1"), MAINNET_ROLLUP_ID);
        require(callbackProxy.code.length != 0, "callback proxy not deployed");
        require(reader.missingProxyError().length == 0, "unexpected missing-proxy observation");
        require(Counter(vm.envAddress("PRODUCER_L2")).counter() == 1, "producer changed");

        console.log("done");
        console.log("reader.lastRead=%s (expected 1)", reader.lastRead());
        console.log("reader.counter=%s (expected 1)", reader.counter());
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode: postAndVerifyBatch with the immediate L2Tx entry that
///        EXECUTES the static read for real on L1 (STATICCALL into the live L1 forwarder).
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L1, READER_L2
contract Execute is Script, TopLevelStaticReentrantCounterL2Actions {
    function run() external {
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"),
                    L2_ROLLUP_ID,
                    _l1Entries(
                        vm.envAddress("PRODUCER_L2"),
                        vm.envAddress("CALLBACK_L1"),
                        counterL1Addr,
                        vm.envAddress("READER_L2")
                    ),
                    noStaticEntries()
                )
            );

        // The L1 forwarder cannot be queried outside its position-pinned execution frame.
        console.log("done");

        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode: user tx fields for the L2 trigger
/// Env: READER_L2
contract ExecuteNetworkL2 is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("READER_L2"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(StaticRoundTripReader.increment.selector)));
    }
}

/// @title VerifyNetworkL2 — network mode: read-only asserts on L2 after the trigger,
///        mirroring ExecuteL2's. The trigger succeeding proves the system loaded a
///        resolvable static pool entry in the same block; this pins the cached value
///        the reader actually consumed.
/// Env: READER_L2
contract VerifyNetworkL2 is Script {
    function run() external view {
        StaticRoundTripReader reader = StaticRoundTripReader(vm.envAddress("READER_L2"));
        require(reader.lastRead() == 1, "static read returned wrong value");
        require(reader.counter() == 1, "reader did not run");
        address callbackProxy = IEEZ(vm.envAddress("MANAGER_L2"))
            .computeCrossChainProxyAddress(vm.envAddress("CALLBACK_L1"), MAINNET_ROLLUP_ID);
        require(callbackProxy.code.length != 0, "callback proxy not deployed");
        require(reader.missingProxyError().length == 0, "unexpected missing-proxy observation");
        require(Counter(vm.envAddress("PRODUCER_L2")).counter() == 1, "producer changed");
        console.log("VERIFY_PASS reader.lastRead=%s reader.counter=%s", reader.lastRead(), reader.counter());
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected — only the L1 side has entries/events; the L2 side is a
//  pool of static entries (no ExecutionEntry, no consumption events), pinned
//  by the trigger + probe asserts in ExecuteL2.
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, TopLevelStaticReentrantCounterL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "StaticForwarder(L1)";
        if (a == vm.envAddress("READER_L2")) return "StaticRoundTripReader(L2)";
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
        ExecutionEntry[] memory l1 =
            _l1Entries(vm.envAddress("PRODUCER_L2"), vm.envAddress("CALLBACK_L1"), counterL1Addr, readerL2Addr);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        // Steps printed BEFORE the table on purpose: the reverse order makes solc's via-ir
        // backend run out of stack encoding the HashStep[][] blob next to the table encode.
        HashStep[][] memory steps = new HashStep[][](1); // mirrors _l1Entries' fold chain
        steps[0] = new HashStep[](2);
        steps[0][0] = RollingHashBuilder.stepCallBegin(_staticKey(counterL1Addr, readerL2Addr));
        steps[0][1] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(1)));
        _printL1CallHashes(l1);
        _printL1Steps(l1, steps);
        _printL1Table(l1);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 L2Tx entry, 1 REAL static read call) ===");
        _logEntry(0, l1[0]);
    }

    function _logL2Pool(address counterL1Addr, address readerL2Addr) private view {
        // The L2 table holds ONLY the static pool entry, resolved via the view path —
        // no ExecutionEntry, no consumption events, so there are no L2 entry hashes to
        // match; VerifyNetworkL2's reader asserts are the L2-side proof.
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("EXPECTED_L2_CALL_HASHES=[]");
        console.log("");
        console.log("=== EXPECTED L2 STATIC POOL (1 entry, no events) ===");
        _logStaticLookup(
            0,
            _staticEntries(vm.envAddress("PRODUCER_L2"), vm.envAddress("CALLBACK_L1"), counterL1Addr, readerL2Addr)[0]
        );
    }
}
