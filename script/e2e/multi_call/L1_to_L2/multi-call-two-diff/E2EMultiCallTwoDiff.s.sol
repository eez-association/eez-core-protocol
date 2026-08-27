// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {RollupUpdate, ExecutionEntry, StaticExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter} from "../../../../../test/mocks/CounterContracts.sol";
import {CallTwoDifferent} from "../../../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noStaticEntries,
    noL2StaticEntries,
    noNestedActions,
    noCalls,
    RollingHashBuilder,
    immediateSingleRollupBatch
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Multi-call scenario: two different targets, one L1 tx → two L2 deliveries
//
//  Source side (Execute on L1):
//    CallTwoDifferent.callBothCounters(proxyA, proxyB) invokes increment()
//    on TWO different L2 Counter proxies. Two entries with DIFFERENT
//    proxyEntryHashes (different `targetAddress` in the preimage) — still
//    consumed sequentially. Each entry's cached returnData = uint256(1).
//
//  Destination side (ExecuteL2 on L2):
//    Each top-level call is delivered as its OWN executeIncomingCrossChainCall
//    tx carrying a 1-entry table (the delivery unit is the top-level call —
//    see EXECUTION_ENTRY_SPEC §1-to-1 rule); the inbound call is
//    entries[0].incomingCalls[0]. Each entry shares its L1 twin's
//    proxyEntryHash (plain hash, source = the L1 CallTwoDifferent contract).
//    Each counter goes 0->1.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract TwoDiffActions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _callHash(address target, address caller) internal pure returns (bytes32) {
        return crossChainCallHash(false, caller, MAINNET_ROLLUP_ID, target, L2_ROLLUP_ID, 0, _incrementCallData());
    }

    function _l1Entries(
        address counterA,
        address counterB,
        address caller
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        bytes32 hA = _callHash(counterA, caller);
        bytes32 hB = _callHash(counterB, caller);

        RollupUpdate[] memory deltas1 = new RollupUpdate[](1);
        deltas1[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-two-diff-1"),
            etherDelta: 0
        });

        RollupUpdate[] memory deltas2 = new RollupUpdate[](1);
        deltas2[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-state-after-two-diff-1"),
            newRoot: keccak256("l2-state-after-two-diff-2"),
            etherDelta: 0
        });

        // No L1 top-level calls (the real increments run on L2 and return cached values), so each
        // entry's rolling hash is exactly its entry-begin seed (state deltas + proxyEntryHash).
        entries = new ExecutionEntry[](2);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltas1,
            proxyEntryHash: hA,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(deltas1, hA),
            success: true,
            returnData: abi.encode(uint256(1))
        });
        entries[1] = ExecutionEntry({
            rollupUpdates: deltas2,
            proxyEntryHash: hB,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(deltas2, hB),
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    /// @dev Two L2-side mirror entries — one per inbound delivery (counterA then
    /// counterB). Each entry has a single CrossChainCall invoking
    /// Counter.increment() on its target from `caller` (CallTwoDifferent on
    /// L1). Each entry's proxyEntryHash IS the L1 twin's — the inbound key is
    /// the same cross-chain call hash on both sides. Both entries return
    /// abi.encode(1) (each L2 counter starts at 0 and is incremented once).
    function _l2Entries(
        address counterA,
        address counterB,
        address caller
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        entries = new L2ExecutionEntry[](2);
        entries[0] = _buildL2Entry(counterA, caller);
        entries[1] = _buildL2Entry(counterB, caller);
    }

    /// @dev 1-entry table for one target's executeIncomingCrossChainCall tx.
    function _l2TableForCall(address target, address caller) internal pure returns (L2ExecutionEntry[] memory table) {
        table = new L2ExecutionEntry[](1);
        table[0] = _buildL2Entry(target, caller);
    }

    function _buildL2Entry(address target, address caller) private pure returns (L2ExecutionEntry memory) {
        bytes32 entryHash = _callHash(target, caller);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: caller,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: target,
            value: 0,
            data: _incrementCallData()
        });

        bytes memory retData = abi.encode(uint256(1));
        // CALL_BEGIN folds the inbound call hash — identical to the entry key.
        bytes32 rh = RollingHashBuilder.entryBeginL2(entryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, entryHash);
        rh = RollingHashBuilder.appendCallEnd(rh, true, retData);

        return L2ExecutionEntry({
            proxyEntryHash: entryHash,
            incomingCalls: calls,
            expectedOutgoingCalls: new ExpectedOutgoingCrossChainCall[](0),
            rollingHash: rh,
            success: true,
            returnData: retData
        });
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterA = new Counter();
        Counter counterB = new Counter();

        console.log("COUNTER_A_L2=%s", address(counterA));
        console.log("COUNTER_B_L2=%s", address(counterB));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterA = vm.envAddress("COUNTER_A_L2");
        address counterB = vm.envAddress("COUNTER_B_L2");

        vm.startBroadcast();
        EEZ rollups = EEZ(rollupsAddr);

        address proxyA;
        try rollups.createCrossChainProxy(counterA, L2_ROLLUP_ID) returns (address p) {
            proxyA = p;
        } catch {
            proxyA = rollups.computeCrossChainProxyAddress(counterA, L2_ROLLUP_ID);
        }

        address proxyB;
        try rollups.createCrossChainProxy(counterB, L2_ROLLUP_ID) returns (address p) {
            proxyB = p;
        } catch {
            proxyB = rollups.computeCrossChainProxyAddress(counterB, L2_ROLLUP_ID);
        }

        CallTwoDifferent caller = new CallTwoDifferent();
        console.log("PROXY_A=%s", proxyA);
        console.log("PROXY_B=%s", proxyB);
        console.log("CALL_TWO_DIFF=%s", address(caller));
        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — local mode: deliver both inbound calls the way the system does,
///        one executeIncomingCrossChainCall tx per top-level call, each with a 1-entry table.
/// Env: MANAGER_L2, COUNTER_A_L2, COUNTER_B_L2, CALL_TWO_DIFF
contract ExecuteL2 is Script, TwoDiffActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterA = vm.envAddress("COUNTER_A_L2");
        address counterB = vm.envAddress("COUNTER_B_L2");
        address callerAddr = vm.envAddress("CALL_TWO_DIFF");

        vm.startBroadcast();
        address[2] memory targets = [counterA, counterB];
        for (uint256 i = 0; i < targets.length; i++) {
            EEZL2(managerAddr)
                .executeIncomingCrossChainCall(_l2TableForCall(targets[i], callerAddr), noL2StaticEntries());
        }

        console.log("done");
        console.log("L2 counterA=%s", Counter(counterA).counter());
        console.log("L2 counterB=%s", Counter(counterB).counter());
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode: postAndVerifyBatch tx + callBothCounters tx from the EOA.
///        The runner mines both in one block (execute_l1_same_block), satisfying the
///        same-block consumption gate.
contract Execute is Script, TwoDiffActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterA = vm.envAddress("COUNTER_A_L2");
        address counterB = vm.envAddress("COUNTER_B_L2");
        address proxyA = vm.envAddress("PROXY_A");
        address proxyB = vm.envAddress("PROXY_B");
        address callerAddr = vm.envAddress("CALL_TWO_DIFF");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterA, counterB, callerAddr), noStaticEntries()
                )
            );
        (uint256 a, uint256 b) = CallTwoDifferent(callerAddr).callBothCounters(proxyA, proxyB);
        console.log("done");
        console.log("a=%s b=%s", a, b);
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address caller = vm.envAddress("CALL_TWO_DIFF");
        address proxyA = vm.envAddress("PROXY_A");
        address proxyB = vm.envAddress("PROXY_B");
        console.log("TARGET=%s", caller);
        console.log("VALUE=0");
        console.log(
            "CALLDATA=%s",
            vm.toString(abi.encodeWithSelector(CallTwoDifferent.callBothCounters.selector, proxyA, proxyB))
        );
    }
}

contract ComputeExpected is ComputeExpectedBase, TwoDiffActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_A_L2")) return "CounterA";
        if (a == vm.envAddress("COUNTER_B_L2")) return "CounterB";
        if (a == vm.envAddress("CALL_TWO_DIFF")) return "CallTwoDiff";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterA = vm.envAddress("COUNTER_A_L2");
        address counterB = vm.envAddress("COUNTER_B_L2");
        address callerAddr = vm.envAddress("CALL_TWO_DIFF");

        ExecutionEntry[] memory l1 = _l1Entries(counterA, counterB, callerAddr);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterA, counterB, callerAddr);
        bytes32 h0 = _entryHash(l1[0]);
        bytes32 h1 = _entryHash(l1[1]);
        bytes32 l2h0 = _entryHash(l2[0]);
        bytes32 l2h1 = _entryHash(l2[1]);

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(h0), vm.toString(h1));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2h0), vm.toString(l2h1));
        _printL2CallHashes(l2);
        _printL1Table(l1);
        _printL2Table(l2);
        console.log(
            "EXPECTED_L1_CALL_HASHES=[%s,%s]", vm.toString(l1[0].proxyEntryHash), vm.toString(l1[1].proxyEntryHash)
        );
        console.log("");
        console.log("=== EXPECTED L1 TABLE (2 entries, different proxyEntryHashes) ===");
        for (uint256 i = 0; i < l1.length; i++) {
            _logEntry(i, l1[i]);
        }
        console.log("");
        console.log("=== EXPECTED L2 TABLE (2 entries, different proxyEntryHashes) ===");
        for (uint256 i = 0; i < l2.length; i++) {
            _logL2Entry(i, l2[i]);
        }
    }
}
