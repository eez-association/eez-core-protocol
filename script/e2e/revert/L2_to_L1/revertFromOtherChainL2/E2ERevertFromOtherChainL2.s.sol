// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {RollupUpdate, L2ToL1Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2ExecutionEntry} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, SelfCallerRevertOnly} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    getOrCreateProxy,
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
//  RevertFromOtherChainL2 — the SIMPLEST `revertNextNCalls` producer:
//  one cross-chain call, made inside an L2 frame that then reverts.
//  The other chain (L1) ran the call and must force-revert it. L2-triggered.
//  (The variant that re-calls after the revert is revertFromOtherChainAndCallAgainL2.)
//
//  L2 side (ExecuteL2) — trigger + REAL revert (same block as loadExecutionTable):
//    alice ──tx──▶ S(L2).execute()        S = SelfCallerRevertOnly, target = proxy for (Counter@L1)
//      └─ try this.innerCall()
//           ├─ counterProxy.increment() ─▶ consumes the source entry (top-level) → 1
//           └─ revert("inner scope revert")   ◀── frame dies: consumption UNWINDS
//         catch → reverted = true
//    result: S.reverted == true; zero committed trace of the consumption on L2
//
//  L1 side (Execute) — mirrors the one unwound consumption (immediate L2Tx):
//    EEZ ─ immediate entry (proxyEntryHash = 0)
//      └─ calls[0]  Counter(L1).increment()  revertNextNCalls=1
//                   runs in executeInContextAndRevert: 0→1, returns 1, STATE ERASED
//    result: Counter(L1).counter == 0 — the span erases the only call
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertFromOtherChainL2Actions {
    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev Source-entry identity: S (on L2) calls the L2 proxy for (Counter@L1) — an outgoing
    ///      call, matched with the L2-outgoing key (`callGas` = 0). Its one consumption unwinds
    ///      with innerCall()'s revert.
    function _proxyEntryHash(address counterL1, address selfCallerL2) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(selfCallerL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementData());
    }

    /// @dev Identity of the call as executed ON L1 (the CALL_BEGIN fold in the L1 entry).
    function _l1CallHash(address counterL1, address selfCallerL2) internal pure returns (bytes32) {
        return crossChainCallHash(false, selfCallerL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementData());
    }

    /// @dev L2 source entry: hands S the pre-computed L1 result (abi.encode(1)); the L1 span
    ///      backs it with a real execution whose state is then erased.
    function _l2Entries(
        address counterL1,
        address selfCallerL2
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 proxyEntryHash = _proxyEntryHash(counterL1, selfCallerL2);

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: proxyEntryHash,
            incomingCalls: noL2Calls(),
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: RollingHashBuilder.entryBeginL2(proxyEntryHash),
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    /// @dev L1 entry — ONE call wrapped in revertNextNCalls=1: it runs (returning the 1 the L2
    ///      consumption observed) and its state is erased, because the L2 frame that consumed
    ///      it reverted.
    function _l1Entries(
        address counterL1,
        address selfCallerL2
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 1,
            isStatic: false,
            sourceAddress: selfCallerL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _incrementData()
        });

        RollupUpdate[] memory deltas = new RollupUpdate[](1);
        deltas[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-revertFromOtherChainL2"),
            etherDelta: 0
        });

        bytes32 ccInc = _l1CallHash(counterL1, selfCallerL2);
        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, ccInc);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltas,
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

/// @title Deploy — the real Counter on L1 (the force-reverted target)
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counter = new Counter();
        console.log("COUNTER_L1=%s", address(counter));
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — on L2: proxy for Counter@L1 + SelfCallerRevertOnly targeting it.
///        No trigger proxy: alice calls S directly.
/// Env: MANAGER_L2, COUNTER_L1
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        address counterProxy = getOrCreateProxy(IEEZ(address(manager)), counterL1, MAINNET_ROLLUP_ID);

        SelfCallerRevertOnly selfCaller = new SelfCallerRevertOnly(Counter(counterProxy));

        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        console.log("SELF_CALLER_L2=%s", address(selfCaller));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — loadExecutionTable + direct trigger in same block.
contract ExecuteL2 is Script, RevertFromOtherChainL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address selfCallerL2 = vm.envAddress("SELF_CALLER_L2");

        vm.startBroadcast();
        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterL1, selfCallerL2), noL2StaticEntries());

        // Trigger: alice calls S directly; the one consumption unwinds with innerCall()'s revert.
        SelfCallerRevertOnly(selfCallerL2).execute();

        require(SelfCallerRevertOnly(selfCallerL2).reverted(), "inner frame must have reverted");

        console.log("done");
        console.log("selfCallerL2.reverted=true (consumption unwound on L2)");
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode output (direct call to S)
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("SELF_CALLER_L2");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(SelfCallerRevertOnly.execute.selector)));
    }
}

/// @title Execute — local mode: postBatch with the immediate L2Tx entry on L1.
///        The span assertion: Counter(L1) ends at 0.
contract Execute is Script, RevertFromOtherChainL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address selfCallerL2 = vm.envAddress("SELF_CALLER_L2");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL1, selfCallerL2), noStaticEntries()
                )
            );

        // The one call ran (returning 1) and was force-reverted — nothing commits.
        uint256 finalCounter = Counter(counterL1).counter();
        require(finalCounter == 0, "revertNextNCalls must erase the call's state");

        console.log("done");
        console.log("counterL1.counter=%s (expected 0 -- increment force-reverted)", finalCounter);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, RevertFromOtherChainL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "Counter(L1)";
        if (a == vm.envAddress("SELF_CALLER_L2")) return "SelfCallerRevertOnly(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == SelfCallerRevertOnly.execute.selector) return "execute";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1 = vm.envAddress("COUNTER_L1");
        address selfCallerL2 = vm.envAddress("SELF_CALLER_L2");

        L2ExecutionEntry[] memory l2 = _l2Entries(counterL1, selfCallerL2);
        ExecutionEntry[] memory l1 = _l1Entries(counterL1, selfCallerL2);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        // NO event-level L2 expectations: the entry's only consumption unwinds with the
        // frame revert, taking its ExecutionConsumed AND EntryExecuted events with it.
        // The L2 side is pinned by the ExecuteL2 assertion; L1 by EntryExecuted + table.
        _printL1Table(l1);
        _printL2Table(l2);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, no calls, consumed once - unwound) ===");
        _logL2Entry(0, l2[0]);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call w/ span=1 - other-chain revert mirrored) ===");
        _logEntry(0, l1[0]);
    }
}
