// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../../src/L2/EEZL2.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntryL2,
    CrossChainCall
} from "../../../../../../src/interfaces/IEEZL2.sol";
import {IEEZ} from "../../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry,
    StaticExecutionEntry,
    ExpectedRootPerRollup,
    L2ToL1Call
} from "../../../../../../src/interfaces/IEEZ.sol";
import {Counter, ICounterView} from "../../../../../../test/mocks/CounterContracts.sol";
import {
    StaticCounterCallback,
    StaticCounterForwarder,
    StaticRoundTripReader
} from "../../../../../../test/mocks/StaticRoundTripContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    getOrCreateProxy,
    crossChainCallHashStatic,
    RollingHashBuilder,
    immediateSingleRollupBatch
} from "../../../shared/E2EHelpers.sol";

// Ready: included in automatic all/default runs.

// Top-level static lookup: L1 reader -> L2 view forwarder -> L2 callback helper -> STATIC L1 Counter.counter().
// The L2 forwarder implements counter() as a view function, so both cross-chain
// legs are static. No L2 delivery or state transition is permitted.
// L1: one static pool row executes the real return call; no ExecutionEntry/events.
// L2: prediction executes the forwarder on the fork only, never a mined delivery.
// Final state: L1 reader.counter=1, lastRead=1; L1 producer.counter remains 1.
// Deploy2 creates the L1 source proxy for the L2 callback helper BEFORE the trigger:
// _processStaticL2ToL1Calls cannot deploy a proxy inside its static frame.

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract TopLevelStaticReentrantCounterActions {
    /// Calldata of the reader's STATICCALL: Counter's auto-generated `counter()` getter,
    /// referenced through `ICounterView` (compile-checked — `Counter` implements it).
    function _counterCallData() internal pure returns (bytes memory) {
        return abi.encodeCall(ICounterView.counter, ());
    }

    /// Static read key: `EEZ.staticCrossChainCall` folds isStatic = true, source = the proxy's
    /// caller (the reader) at MAINNET, target = (ForwarderL2, L2), value 0, callGas 0.
    function _staticKey(address counterL2, address readerL1) internal pure returns (bytes32) {
        return crossChainCallHashStatic(readerL1, MAINNET_ROLLUP_ID, counterL2, L2_ROLLUP_ID, 0, _counterCallData());
    }

    /// L2 callback helper -> L1 producer: the prediction and real callback share this preimage.
    function _callbackKey(address producerL1, address callbackL2) internal pure returns (bytes32) {
        return crossChainCallHashStatic(callbackL2, L2_ROLLUP_ID, producerL1, MAINNET_ROLLUP_ID, 0, _counterCallData());
    }

    /// The ONE top-level static entry, keyed to the reader (the key folds the proxy caller):
    /// one real static return call to L1, pinned to L2's live root — the pin
    /// is part of the match predicate. `predicted` is the raw returndata of the off-chain
    /// prediction of the read.
    function _staticEntries(
        address counterL1,
        address callbackL2,
        address counterL2,
        address readerL1,
        bytes memory predicted
    )
        internal
        pure
        returns (StaticExecutionEntry[] memory entries)
    {
        ExpectedRootPerRollup[] memory pins = new ExpectedRootPerRollup[](1);
        pins[0] = ExpectedRootPerRollup({rollupId: L2_ROLLUP_ID, root: keccak256("l2-initial-state")});

        entries = new StaticExecutionEntry[](1);
        entries[0] = StaticExecutionEntry({
            expectedRoots: pins,
            proxyEntryHash: _staticKey(counterL2, readerL1),
            l2ToL1Calls: _returnCalls(counterL1, callbackL2),
            rollingHash: RollingHashBuilder.appendStatic(bytes32(0), true, predicted),
            destinationRollupId: L2_ROLLUP_ID,
            success: true,
            returnData: predicted
        });
    }

    function _returnCalls(address counterL1, address callbackL2) internal pure returns (L2ToL1Call[] memory calls) {
        calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: callbackL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _counterCallData()
        });
    }
}

// Deploy* contracts run in file order, including in the staged runner.
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter producer = new Counter();
        producer.increment();
        output("COUNTER_L1", address(producer));
        output("PREDICTED_STATIC_RESULT", abi.encode(producer.counter()));
        vm.stopBroadcast();
    }
}

contract DeployL2 is Script {
    function run() external {
        require(!EEZL2(vm.envAddress("MANAGER_L2")).USE_GAS_LEFT(), "scenario requires gas-independent L2 keys");
        vm.startBroadcast();
        address proxy =
            getOrCreateProxy(IEEZ(vm.envAddress("MANAGER_L2")), vm.envAddress("COUNTER_L1"), MAINNET_ROLLUP_ID);
        StaticCounterCallback callback = new StaticCounterCallback(proxy);
        StaticCounterForwarder forwarder = new StaticCounterForwarder(address(callback));
        output("CALLBACK_L2", address(callback));
        output("COUNTER_L2", address(forwarder));
        output("COUNTER_L1_PROXY_L2", proxy);
        vm.stopBroadcast();
    }
}

contract Deploy2 is Script {
    function run() external {
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), vm.envAddress("COUNTER_L2"), L2_ROLLUP_ID);
        address callbackProxy =
            getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), vm.envAddress("CALLBACK_L2"), L2_ROLLUP_ID);
        require(callbackProxy.code.length != 0, "L1 return-call proxy missing");
        output("CALLBACK_PROXY", callbackProxy);
        StaticRoundTripReader reader = new StaticRoundTripReader(
            proxy, vm.envAddress("ROLLUPS"), vm.envAddress("CALLBACK_L2"), L2_ROLLUP_ID, false
        );
        output("COUNTER_PROXY", proxy);
        output("READER_L1", address(reader));
        vm.stopBroadcast();
    }
}

// Predict by executing the real L2 forwarder on the fork only. Nothing is mined.
contract DeployPredictionL2 is Script, TopLevelStaticReentrantCounterActions {
    function run() external {
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        vm.startBroadcast();
        address sourceProxy = getOrCreateProxy(IEEZ(address(manager)), vm.envAddress("READER_L1"), MAINNET_ROLLUP_ID);
        vm.stopBroadcast();
        StaticExecutionEntryL2[] memory rows = new StaticExecutionEntryL2[](1);
        rows[0].proxyEntryHash = _callbackKey(vm.envAddress("COUNTER_L1"), vm.envAddress("CALLBACK_L2"));
        rows[0].incomingCalls = new CrossChainCall[](0);
        rows[0].success = true;
        rows[0].returnData = vm.envBytes("PREDICTED_STATIC_RESULT");
        vm.prank(manager.SYSTEM_ADDRESS());
        manager.loadExecutionTable(new L2ExecutionEntry[](0), rows);
        vm.prank(sourceProxy);
        (bool ok, bytes memory result) = vm.envAddress("COUNTER_L2").staticcall(_counterCallData());
        require(ok && keccak256(result) == keccak256(rows[0].returnData), "forwarder prediction mismatch");
        output("PREDICTED_STATIC_RESULT", result);
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title Execute — local mode: postAndVerifyBatch (static entry only) + the user trigger,
///        then the NO-TX query. The runner mines the two txs in one block; the top-level
///        static entry requires matching root pins and current-block verification.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L2, PREDICTED_STATIC_RESULT, COUNTER_PROXY, READER_L1
contract Execute is Script, TopLevelStaticReentrantCounterActions {
    function run() external {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        StaticRoundTripReader reader = StaticRoundTripReader(vm.envAddress("READER_L1"));
        // Prediction of the forwarder result, captured from its live L1 producer.
        bytes memory predicted = vm.envBytes("PREDICTED_STATIC_RESULT");
        uint256 predictedValue = abi.decode(predicted, (uint256));

        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"),
                    L2_ROLLUP_ID,
                    new ExecutionEntry[](0),
                    _staticEntries(
                        vm.envAddress("COUNTER_L1"),
                        vm.envAddress("CALLBACK_L2"),
                        counterL2Addr,
                        address(reader),
                        predicted
                    )
                )
            );
        reader.increment();

        require(reader.lastRead() == predictedValue, "static read returned wrong value");
        require(reader.counter() == 1, "reader did not run");
        address callbackProxy =
            IEEZ(vm.envAddress("ROLLUPS")).computeCrossChainProxyAddress(vm.envAddress("CALLBACK_L2"), L2_ROLLUP_ID);
        require(callbackProxy.code.length != 0, "callback proxy not deployed");
        require(reader.missingProxyError().length == 0, "unexpected missing-proxy observation");
        require(Counter(vm.envAddress("COUNTER_L1")).counter() == predictedValue, "L1 producer changed");
        (, bytes32 root,) = EEZ(vm.envAddress("ROLLUPS")).rollups(L2_ROLLUP_ID);
        require(root == keccak256("l2-initial-state"), "lookup moved L2 root");
        vm.stopBroadcast();

        // Standard no-tx query: an eth_call through the proxy AS the reader resolves the SAME
        // entry the trigger used — nothing is broadcast (forge never records static calls).
        vm.prank(address(reader));
        uint256 probed = Counter(vm.envAddress("COUNTER_PROXY")).counter();
        require(probed == predictedValue, "no-tx static query returned wrong value");

        console.log("done");
        console.log("reader.lastRead=%s (predicted %s)", reader.lastRead(), predictedValue);
        console.log("no-tx query counter()=%s", probed);
    }
}

/// @title ExecuteNetwork — network mode: user tx fields for the L1 trigger
/// Env: READER_L1
contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("READER_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(StaticRoundTripReader.increment.selector)));
    }
}

/// @title VerifyNetwork — network mode: read-only asserts on the reader's persisted state
///        after the trigger. The trigger succeeding already proves the composer posted a
///        resolvable static entry (reader.increment() reverts ExecutionNotFound otherwise);
///        this pins the value it returned. The entry's content is matched from the batch
///        calldata (ComputeExpected); the no-tx query is deliberately NOT re-issued here —
///        it requires current-block verification and live root pins; deferred probes
///        cannot rely on either condition still holding.
/// Env: READER_L1, PREDICTED_STATIC_RESULT
contract VerifyNetwork is Script {
    function run() external view {
        StaticRoundTripReader reader = StaticRoundTripReader(vm.envAddress("READER_L1"));
        uint256 predictedValue = abi.decode(vm.envBytes("PREDICTED_STATIC_RESULT"), (uint256));

        require(reader.lastRead() == predictedValue, "static read returned wrong value");
        require(reader.counter() == 1, "reader did not run");
        address callbackProxy =
            IEEZ(vm.envAddress("ROLLUPS")).computeCrossChainProxyAddress(vm.envAddress("CALLBACK_L2"), L2_ROLLUP_ID);
        require(callbackProxy.code.length != 0, "callback proxy not deployed");
        require(reader.missingProxyError().length == 0, "unexpected missing-proxy observation");
        require(Counter(vm.envAddress("COUNTER_L1")).counter() == predictedValue, "L1 producer changed");

        console.log(
            "VERIFY_PASS reader.lastRead=%s reader.counter=%s (predicted %s)",
            reader.lastRead(),
            reader.counter(),
            predictedValue
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected — the batch carries ONE top-level static entry and no
//  ExecutionEntry, so every event-level list is empty; the L1 proof is the
//  posted-calldata match of the static entry (root pin neutralized). No delivery
//  executes on L2. Prediction runs only on the fork.
// ═══════════════════════════════════════════════════════════════════════

/// Env: COUNTER_L2, READER_L1, PREDICTED_STATIC_RESULT
contract ComputeExpected is ComputeExpectedBase, TopLevelStaticReentrantCounterActions {
    function run() external view {
        StaticExecutionEntry[] memory s = _staticEntries(
            vm.envAddress("COUNTER_L1"),
            vm.envAddress("CALLBACK_L2"),
            vm.envAddress("COUNTER_L2"),
            vm.envAddress("READER_L1"),
            vm.envBytes("PREDICTED_STATIC_RESULT")
        );

        console.log("EXPECTED_L1_CALL_HASHES=[]");
        console.log("EXPECTED_L1_HASHES=[]");
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("EXPECTED_L2_CALL_HASHES=[]");
        // The read is a lookup: its key must leave no trace on L2 (no delivery, no loaded
        // entry or static entry) — asserted by VerifyL2Absent over the post-trigger range.
        console.log("ABSENT_L2_HASHES=[%s]", vm.toString(s[0].proxyEntryHash));
        _printL1StaticTable(s);

        console.log("");
        console.log(
            "=== EXPECTED L1 STATIC POOL (1 top-level entry, no ExecutionEntry, no events; key asserted absent on L2) ==="
        );
        _logStaticLookup(0, s[0]);
    }
}
