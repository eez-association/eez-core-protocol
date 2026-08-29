// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {ExecutionEntry, StaticExecutionEntry, ExpectedRootPerRollup} from "../../../../../src/interfaces/IEEZ.sol";
import {Counter, ICounterView, StaticReadCounter} from "../../../../../test/mocks/CounterContracts.sol";
import {
    getOrCreateProxy,
    crossChainCallHashStatic,
    noCalls,
    immediateSingleRollupBatch
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  TopLevelStaticCounter scenario — L1-starting, TOP-LEVEL static read of L2 state
//
//  Topology: Counter lives on L2 (incremented to 1 during deploy);
//  StaticReadCounter lives on L1, targeting the L1-side proxy of CounterL2.
//
//  L1 side (Execute — both txs mined in one block):
//    1. postAndVerifyBatch publishes ONE top-level StaticExecutionEntry (the
//       batch carries NO ExecutionEntry) into L2's staticEntryQueue, keyed to
//       the reader (the key folds the proxy caller) and pinned to L2's live
//       root. Its cached returnData is the PREDICTION — never hardcoded:
//       DeployL2 performs the actual staticcall against the live CounterL2 and
//       exports the raw returndata as PREDICTED_STATIC_RESULT (env bytes), the
//       way a composer predicts the result off-chain from the L2 node. Generic:
//       works for any static call and return type.
//    2. alice -> reader.increment()          (the ONE user trigger)
//         reader STATICCALLs counterL2ProxyL1.counter()
//         -> proxy detects the static frame -> EEZ.staticCrossChainCall
//         -> outside any execution -> staticEntryQueue scan
//            (key + destinationRollupId + live root pin)
//         -> returns the cached prediction; reader stores it in lastRead
//    3. NO-TX query: an eth_call through the proxy AS the reader resolves the
//       SAME entry — the standard interface for a client to learn the read's
//       result with only the trigger tx on-chain.
//
//  L2 side: NOTHING executes — a top-level static read has no destination-side
//  delivery; the producer is CounterL2's live state, captured at deploy.
//
//  Verification: static resolution is a `view` path — it emits no events, so
//  this scenario has no ComputeExpected (the runner fails a ComputeExpected
//  that drives zero verifiers). The proof is the trigger tx + the no-tx query:
//  a wrong key, destination, or root pin reverts them (ExecutionNotFound), and
//  Execute asserts both against the predicted value.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract StaticCounterActions {
    /// Calldata of the reader's STATICCALL: Counter's auto-generated `counter()` getter,
    /// referenced through `ICounterView` (compile-checked — `Counter` implements it).
    function _counterCallData() internal pure returns (bytes memory) {
        return abi.encodeCall(ICounterView.counter, ());
    }

    /// Static read key: `EEZ.staticCrossChainCall` folds isStatic = true, source = the proxy's
    /// caller (the reader) at MAINNET, target = (CounterL2, L2), value 0, callGas 0.
    function _staticKey(address counterL2, address readerL1) internal pure returns (bytes32) {
        return crossChainCallHashStatic(readerL1, MAINNET_ROLLUP_ID, counterL2, L2_ROLLUP_ID, 0, _counterCallData());
    }

    /// The ONE top-level static entry, keyed to the reader (the key folds the proxy caller):
    /// no sub-calls (an empty array folds rollingHash 0), pinned to L2's live root — the pin
    /// is part of the match predicate. `predicted` is the raw returndata of the off-chain
    /// prediction of the read.
    function _staticEntries(
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
            l2ToL1Calls: noCalls(),
            rollingHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            success: true,
            returnData: predicted
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title DeployL2 — deploy Counter on L2, give it a live value, then perform the actual
///        staticcall and export its raw returndata: the off-chain PREDICTION the L1 static
///        entry caches verbatim (nothing hardcoded, any return type works).
/// Outputs: COUNTER_L2, PREDICTED_STATIC_RESULT
contract DeployL2 is Script, StaticCounterActions {
    function run() external {
        vm.startBroadcast();
        Counter counterL2 = new Counter();
        counterL2.increment();
        (bool ok, bytes memory result) = address(counterL2).staticcall(_counterCallData());
        require(ok, "prediction staticcall failed");
        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("PREDICTED_STATIC_RESULT=%s", vm.toString(result));
        vm.stopBroadcast();
    }
}

/// @title Deploy — on L1, create the proxy for CounterL2 + deploy the reader targeting it
/// Env: ROLLUPS, COUNTER_L2
/// Outputs: COUNTER_PROXY, READER_L1
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        address counterProxy = getOrCreateProxy(IEEZ(rollupsAddr), counterL2Addr, L2_ROLLUP_ID);
        StaticReadCounter reader = new StaticReadCounter(Counter(counterProxy));
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("READER_L1=%s", address(reader));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title Execute — local mode: postAndVerifyBatch (static entry only) + the user trigger,
///        then the NO-TX query. The runner mines the two txs in one block; the top-level
///        static path itself has no block gate — the entry stays matchable while its root
///        pin equals the live L2 root.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L2, PREDICTED_STATIC_RESULT, COUNTER_PROXY, READER_L1
contract Execute is Script, StaticCounterActions {
    function run() external {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        StaticReadCounter reader = StaticReadCounter(vm.envAddress("READER_L1"));
        // The off-chain prediction: the read's raw returndata, captured on L2 at deploy time.
        bytes memory predicted = vm.envBytes("PREDICTED_STATIC_RESULT");
        uint256 predictedValue = abi.decode(predicted, (uint256));

        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"),
                    L2_ROLLUP_ID,
                    new ExecutionEntry[](0),
                    _staticEntries(counterL2Addr, address(reader), predicted)
                )
            );
        reader.increment();

        require(reader.lastRead() == predictedValue, "static read returned wrong value");
        require(reader.counter() == 1, "reader did not run");
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
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(StaticReadCounter.increment.selector)));
    }
}
