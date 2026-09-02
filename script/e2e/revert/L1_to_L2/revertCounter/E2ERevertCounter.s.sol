// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {RollupUpdate, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {Counter, RevertCounter, SafeCounterAndProxy} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    getOrCreateProxy,
    crossChainCallHash,
    noStaticEntries,
    noNestedActions,
    noCalls,
    RollingHashBuilder,
    immediateSingleRollupBatch
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  RevertCounter — a cross-chain call whose DESTINATION naturally reverts;
//  the revert IS the response. L1→L2, and a LOOKUP: nothing runs on L2.
//
//  No revertNextNCalls anywhere: the destination (`RevertCounter.increment()`
//  on L2) always reverts("always reverts"). The composer simulates the call on
//  L2, the prover signs that revert data into the source entry, and the L1
//  caller receives it as the call's result.
//
//  L1 side (Execute) — trigger + source entry:
//    alice ──tx──▶ SafeCaller(L1).incrementProxy()
//      └─ try counterProxy.increment()            counterProxy = proxy for (RevertCounter@L2)
//           └─ EEZ.executeCrossChainCall ─ consumes the entry:
//                { calls: [], success: false, returnData: Error("always reverts") }
//                runs (nothing) → hash verified → REVERTS with returnData
//                (cursor, root update and events unwind with the revert)
//         ◀─ revert Error("always reverts")
//      └─ catch → lastCallFailed = true; counter++     (trigger tx SUCCEEDS)
//    result: safeCaller.lastCallFailed == true, targetCounter == 0
//
//  L2 side: NO delivery. L2 state and the L2 root change only for cross-chain
//  work L1 can prove it executed; a call that reverts on L2 is not applied, so
//  no executeIncomingCrossChainCall tx exists for it (CORE spec §C, L2 prover
//  constraints). The revert data reaches the user through the L1 entry (and
//  the blob); nothing on L2 records the call.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertActions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev Error(string) revert data produced by `RevertCounter.increment()`.
    function _revertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "always reverts");
    }

    /// @dev Proxy-entry identity: safeCaller (on L1) calls the L1 proxy for (RevertCounter@L2).
    ///      Same hash on both sides (L2's executeIncomingCrossChainCall folds targetRollupId = L2).
    function _proxyEntryHash(address revCounterL2, address safeCaller) internal pure returns (bytes32) {
        return
            crossChainCallHash(
                false, safeCaller, MAINNET_ROLLUP_ID, revCounterL2, L2_ROLLUP_ID, 0, _incrementCallData()
            );
    }

    /// @dev L1 source entry: nothing executes on L1 — the entry only carries the destination's
    ///      outcome. success=false replays the destination's revert to the caller (consumption
    ///      runs, verifies, then reverts with returnData; the cursor advance unwinds with it).
    function _l1Entries(
        address revCounterL2,
        address safeCaller
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        RollupUpdate[] memory deltas = new RollupUpdate[](1);
        deltas[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-reverted-call"),
            etherDelta: 0
        });

        bytes32 proxyEntryHash = _proxyEntryHash(revCounterL2, safeCaller);

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltas,
            proxyEntryHash: proxyEntryHash,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(deltas, proxyEntryHash),
            success: false,
            returnData: _revertData()
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title DeployL2 — deploy the always-reverting destination on L2
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        RevertCounter revCounter = new RevertCounter();
        output("REV_COUNTER_L2", address(revCounter));
        vm.stopBroadcast();
    }
}

/// @title Deploy — on L1, create the trigger proxy + the try/catch caller
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address revCounterL2 = vm.envAddress("REV_COUNTER_L2");

        vm.startBroadcast();
        EEZ rollups = EEZ(rollupsAddr);

        // Trigger proxy: proxy for (RevertCounter@L2, L2_ROLLUP_ID) on L1
        address counterProxy = getOrCreateProxy(IEEZ(address(rollups)), revCounterL2, L2_ROLLUP_ID);

        // The caller: try/catches the reverting cross-chain call so the trigger tx succeeds.
        SafeCounterAndProxy safeCaller = new SafeCounterAndProxy(Counter(counterProxy));

        output("COUNTER_PROXY", counterProxy);
        output("SAFE_CALLER", address(safeCaller));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════════════

/// @title Execute — local mode: postAndVerifyBatch tx + trigger tx from the EOA.
///        The runner mines both in one block (execute_l1_same_block). There is no
///        ExecuteL2: the reverting call is a lookup, nothing is delivered on L2.
contract Execute is Script, RevertActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address revCounterL2 = vm.envAddress("REV_COUNTER_L2");
        address safeCallerAddr = vm.envAddress("SAFE_CALLER");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(revCounterL2, safeCallerAddr), noStaticEntries()
                )
            );

        // Trigger: the safe caller's proxy call consumes the entry, which reverts with the
        // destination's revert data; the try/catch records the failure.
        SafeCounterAndProxy safeCaller = SafeCounterAndProxy(safeCallerAddr);
        safeCaller.incrementProxy();

        require(safeCaller.lastCallFailed(), "cross-chain call must surface the destination revert");
        require(safeCaller.targetCounter() == 0, "no target result on a reverted call");

        console.log("done");
        console.log("safeCaller.lastCallFailed=true (destination revert propagated)");
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("SAFE_CALLER");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, RevertActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("REV_COUNTER_L2")) return "RevertCounter(L2)";
        if (a == vm.envAddress("SAFE_CALLER")) return "SafeCaller(L1)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address revCounterL2 = vm.envAddress("REV_COUNTER_L2");
        address safeCallerAddr = vm.envAddress("SAFE_CALLER");

        ExecutionEntry[] memory l1 = _l1Entries(revCounterL2, safeCallerAddr);

        // NO event-level L1 expectations: a success=false entry's consumption reverts,
        // unwinding its own ExecutionConsumed/EntryExecuted events. The L1 side is pinned
        // by the Execute assertions (local) and the posted-calldata table match (both modes).
        // NO L2 expectations at all: the call is a lookup, nothing is delivered on L2 — and
        // that absence is ASSERTED: the call's key must not appear in any L2 delivery /
        // consumption event or loaded table (VerifyL2Absent over the post-trigger range).
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("EXPECTED_L2_CALL_HASHES=[]");
        console.log("ABSENT_L2_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));
        _printL1Table(l1);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, no calls, success=false: signed destination revert) ===");
        _logEntry(0, l1[0]);
        console.log("");
        console.log(
            "=== EXPECTED L2: nothing (lookup - the reverting call is never delivered; key asserted absent) ==="
        );
    }
}
