// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {RootUpdate, L2ToL1Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2ExecutionEntry} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, RevertCounter, SafeCounterAndProxy} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    crossChainCallHashL2Out,
    noStaticEntries,
    noNestedActions,
    noL2Calls,
    noL2OutgoingCalls,
    noL2StaticEntries,
    immediateSingleRollupBatch,
    RollingHashBuilder
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  RevertCounterL2 — mirror of revertCounter: a cross-chain call whose
//  DESTINATION (RevertCounter on L1) naturally reverts; the revert IS the
//  response seen on L2. Two-sided, L2→L1.
//
//  L2 side (ExecuteL2) — trigger + source entry (same block as loadExecutionTable):
//    alice ──tx──▶ SafeCaller(L2).incrementProxy()
//      └─ try counterProxy.increment()            counterProxy = proxy for (RevertCounter@L1)
//           └─ EEZL2.executeCrossChainCall ─ consumes the entry:
//                { incomingCalls: [], success: false, returnData: Error("always reverts") }
//                runs (nothing) → hash verified → REVERTS with returnData
//         ◀─ revert Error("always reverts")
//      └─ catch → lastCallFailed = true; counter++     (trigger tx SUCCEEDS)
//    result: safeCallerL2.lastCallFailed == true, targetCounter == 0
//
//  L1 side (Execute) — system-driven mirror (immediate L2Tx during postAndVerifyBatch):
//    EEZ ─ immediate entry (proxyEntryHash = 0)
//      └─ l2ToL1Calls[0] ─ source proxy ─▶ RevertCounter(L1).increment()
//           ◀─ revert("always reverts")
//         folded as CALL_END(false, Error("always reverts")) — the entry itself SUCCEEDS
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertL2Actions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev Error(string) revert data produced by `RevertCounter.increment()`.
    function _revertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "always reverts");
    }

    /// @dev Proxy-entry identity: safeCallerL2 calls the L2 proxy for (RevertCounter@L1) — an
    ///      outgoing call, so the SOURCE L2 matches it with the L2-outgoing key (`callGas` = 0).
    function _proxyEntryHash(address revCounterL1, address safeCallerL2) internal pure returns (bytes32) {
        return
            crossChainCallHashL2Out(
                safeCallerL2, L2_ROLLUP_ID, revCounterL1, MAINNET_ROLLUP_ID, 0, _incrementCallData()
            );
    }

    /// @dev L2 source entry: nothing executes on L2 — success=false replays the destination's
    ///      revert to the caller (consumption runs, verifies, then reverts with returnData).
    function _l2Entries(
        address revCounterL1,
        address safeCallerL2
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 proxyEntryHash = _proxyEntryHash(revCounterL1, safeCallerL2);

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: proxyEntryHash,
            incomingCalls: noL2Calls(),
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: RollingHashBuilder.entryBeginL2(proxyEntryHash),
            success: false,
            returnData: _revertData()
        });
    }

    /// @dev L1 mirror entry — system-driven (proxyEntryHash=0), executed as an immediate L2Tx.
    ///      `l2ToL1Calls[0]` runs the real RevertCounter on L1; the natural revert folds as
    ///      CALL_END(false, ...). CALL_BEGIN folds targetRollupId = MAINNET.
    function _l1Entries(
        address revCounterL1,
        address safeCallerL2
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: safeCallerL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: revCounterL1,
            value: 0,
            data: _incrementCallData()
        });

        RootUpdate[] memory deltas = new RootUpdate[](1);
        deltas[0] = RootUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-reverted-call"),
            etherDelta: 0
        });

        bytes32 ccTop = crossChainCallHash(
            false, safeCallerL2, L2_ROLLUP_ID, revCounterL1, MAINNET_ROLLUP_ID, 0, _incrementCallData()
        );
        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, ccTop);
        rh = RollingHashBuilder.appendCallEnd(rh, false, _revertData());

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rootUpdates: deltas,
            proxyEntryHash: bytes32(0),
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

/// @title Deploy — deploy the always-reverting destination on L1
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        RevertCounter revCounter = new RevertCounter();
        console.log("REV_COUNTER_L1=%s", address(revCounter));
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — on L2, create the trigger proxy + the try/catch caller
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address revCounterL1 = vm.envAddress("REV_COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        // Trigger proxy: proxy for (RevertCounter@L1, MAINNET_ROLLUP_ID) on L2
        address counterProxy;
        try manager.createCrossChainProxy(revCounterL1, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = manager.computeCrossChainProxyAddress(revCounterL1, MAINNET_ROLLUP_ID);
        }

        // The caller: try/catches the reverting cross-chain call so the trigger tx succeeds.
        SafeCounterAndProxy safeCaller = new SafeCounterAndProxy(Counter(counterProxy));

        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        console.log("SAFE_CALLER_L2=%s", address(safeCaller));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — loadExecutionTable + trigger in same block
contract ExecuteL2 is Script, RevertL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address revCounterL1 = vm.envAddress("REV_COUNTER_L1");
        address safeCallerAddr = vm.envAddress("SAFE_CALLER_L2");

        vm.startBroadcast();
        EEZL2(managerAddr).loadExecutionTable(_l2Entries(revCounterL1, safeCallerAddr), noL2StaticEntries());

        // Trigger: the safe caller's proxy call consumes the entry, which reverts with the
        // destination's revert data; the try/catch records the failure.
        SafeCounterAndProxy safeCaller = SafeCounterAndProxy(safeCallerAddr);
        safeCaller.incrementProxy();

        require(safeCaller.lastCallFailed(), "cross-chain call must surface the destination revert");
        require(safeCaller.targetCounter() == 0, "no target result on a reverted call");

        console.log("done");
        console.log("safeCallerL2.lastCallFailed=true (destination revert propagated)");
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode output
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("SAFE_CALLER_L2");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector)));
    }
}

/// @title Execute — local mode: postBatch with the immediate L2Tx entry on L1.
/// @dev The entry's call runs the real RevertCounter on L1; the natural revert is captured
///      as CALL_END(false, ...) and the entry verifies and completes.
/// Env: ROLLUPS, PROOF_SYSTEM, REV_COUNTER_L1, SAFE_CALLER_L2
contract Execute is Script, RevertL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address revCounterL1 = vm.envAddress("REV_COUNTER_L1");
        address safeCallerAddr = vm.envAddress("SAFE_CALLER_L2");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(revCounterL1, safeCallerAddr), noStaticEntries()
                )
            );

        console.log("done");
        console.log("delivered call reverted naturally on L1; entry verified");
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, RevertL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("REV_COUNTER_L1")) return "RevertCounter(L1)";
        if (a == vm.envAddress("SAFE_CALLER_L2")) return "SafeCaller(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address revCounterL1 = vm.envAddress("REV_COUNTER_L1");
        address safeCallerAddr = vm.envAddress("SAFE_CALLER_L2");

        L2ExecutionEntry[] memory l2 = _l2Entries(revCounterL1, safeCallerAddr);
        ExecutionEntry[] memory l1 = _l1Entries(revCounterL1, safeCallerAddr);

        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        // NOTE: no EXPECTED_L2_CALL_HASHES — a success=false entry's consumption reverts,
        // unwinding its events; the loaded-table comparison pins it on L2 instead.
        _printL1Table(l1);
        _printL2Table(l2);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, no calls, success=false: destination revert replay) ===");
        _logL2Entry(0, l2[0]);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call w/ natural revert CALL_END(false)) ===");
        _logEntry(0, l1[0]);
    }
}
