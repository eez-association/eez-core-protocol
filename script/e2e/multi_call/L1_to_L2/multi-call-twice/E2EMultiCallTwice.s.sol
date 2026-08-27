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
import {CallTwice} from "../../../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noStaticEntries,
    noNestedActions,
    noCalls,
    RollingHashBuilder,
    immediateSingleRollupBatch
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Multi-call scenario: same target twice, one L1 tx → two L2 deliveries
//
//  Source side (Execute on L1):
//    CallTwice.callCounterTwice(counterProxy) invokes increment() twice on
//    the SAME L1 proxy. Each invocation consumes an entry sequentially —
//    two entries with the SAME proxyEntryHash but different returnData
//    (uint256(1) and uint256(2)).
//
//  Destination side (ExecuteL2 on L2):
//    Each top-level call is delivered as its OWN executeIncomingCrossChainCall
//    tx carrying a 1-entry table (the delivery unit is the top-level call —
//    see EXECUTION_ENTRY_SPEC §1-to-1 rule). Both deliveries share the same
//    proxyEntryHash as the L1 entries (plain hash, source = the L1 CallTwice
//    contract); only returnData (1 vs 2) and the rolling hash differ.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract MultiCallActions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _callHash(address counterL2, address caller) internal pure returns (bytes32) {
        return crossChainCallHash(false, caller, MAINNET_ROLLUP_ID, counterL2, L2_ROLLUP_ID, 0, _incrementCallData());
    }

    function _l1Entries(address counterL2, address caller) internal pure returns (ExecutionEntry[] memory entries) {
        bytes32 ah = _callHash(counterL2, caller);

        RollupUpdate[] memory deltasA = new RollupUpdate[](1);
        deltasA[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-twice-1"),
            etherDelta: 0
        });

        RollupUpdate[] memory deltasB = new RollupUpdate[](1);
        deltasB[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-state-after-twice-1"),
            newRoot: keccak256("l2-state-after-twice-2"),
            etherDelta: 0
        });

        // No L1 top-level calls (the real increments run on L2 and return cached values), so each
        // entry's rolling hash is exactly its entry-begin seed (state deltas + proxyEntryHash).
        entries = new ExecutionEntry[](2);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltasA,
            proxyEntryHash: ah,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(deltasA, ah),
            success: true,
            returnData: abi.encode(uint256(1))
        });
        entries[1] = ExecutionEntry({
            rollupUpdates: deltasB,
            proxyEntryHash: ah,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(deltasB, ah),
            success: true,
            returnData: abi.encode(uint256(2))
        });
    }

    /// @dev Two L2-side mirror entries — one per inbound delivery. Each entry has
    /// a single CrossChainCall invoking Counter.increment() on counterL2 from
    /// `caller` (CallTwice on L1). Same proxyEntryHash as the L1 entries (the
    /// inbound key IS the L1-side cross-chain call hash). returnData and the
    /// rolling-hash CALL_END payload differ per entry (1 vs 2).
    function _l2Entries(address counterL2, address caller) internal pure returns (L2ExecutionEntry[] memory entries) {
        entries = new L2ExecutionEntry[](2);
        entries[0] = _buildL2Entry(counterL2, caller, abi.encode(uint256(1)));
        entries[1] = _buildL2Entry(counterL2, caller, abi.encode(uint256(2)));
    }

    /// @dev 1-entry table for the n-th executeIncomingCrossChainCall tx.
    function _l2TableForCall(
        address counterL2,
        address caller,
        uint256 n
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory table)
    {
        table = new L2ExecutionEntry[](1);
        table[0] = _buildL2Entry(counterL2, caller, abi.encode(n));
    }

    function _buildL2Entry(
        address counterL2,
        address caller,
        bytes memory retData
    )
        private
        pure
        returns (L2ExecutionEntry memory)
    {
        bytes32 ah = _callHash(counterL2, caller);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: caller,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: _incrementCallData()
        });

        // CALL_BEGIN folds the inbound call hash — identical to the entry key.
        bytes32 rh = RollingHashBuilder.entryBeginL2(ah);
        rh = RollingHashBuilder.appendCallBegin(rh, ah);
        rh = RollingHashBuilder.appendCallEnd(rh, true, retData);

        return L2ExecutionEntry({
            proxyEntryHash: ah,
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
        Counter counter = new Counter();
        console.log("COUNTER_L2=%s", address(counter));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        EEZ rollups = EEZ(rollupsAddr);

        address counterProxy;
        try rollups.createCrossChainProxy(counterL2Addr, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2Addr, L2_ROLLUP_ID);
        }

        CallTwice caller = new CallTwice();
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("CALL_TWICE=%s", address(caller));
        vm.stopBroadcast();
    }
}

/// @title ExecuteL2 — local mode: deliver both inbound calls the way the system does,
///        one executeIncomingCrossChainCall tx per top-level call, each with a 1-entry table.
/// Env: MANAGER_L2, COUNTER_L2, CALL_TWICE
contract ExecuteL2 is Script, MultiCallActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address callerAddr = vm.envAddress("CALL_TWICE");

        vm.startBroadcast();
        for (uint256 n = 1; n <= 2; n++) {
            EEZL2(managerAddr)
                .executeIncomingCrossChainCall(
                    _l2TableForCall(counterL2Addr, callerAddr, n), new L2StaticExecutionEntry[](0)
                );
        }

        console.log("done");
        console.log("L2 counter=%s", Counter(counterL2Addr).counter());
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode: postAndVerifyBatch tx + callCounterTwice tx from the EOA.
///        The runner mines both in one block (execute_l1_same_block), satisfying the
///        same-block consumption gate.
contract Execute is Script, MultiCallActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterProxy = vm.envAddress("COUNTER_PROXY");
        address callerAddr = vm.envAddress("CALL_TWICE");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL2Addr, callerAddr), noStaticEntries()
                )
            );
        (uint256 first, uint256 second) = CallTwice(callerAddr).callCounterTwice(counterProxy);
        console.log("done");
        console.log("first=%s second=%s", first, second);
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address caller = vm.envAddress("CALL_TWICE");
        address counterProxy = vm.envAddress("COUNTER_PROXY");
        console.log("TARGET=%s", caller);
        console.log("VALUE=0");
        console.log(
            "CALLDATA=%s", vm.toString(abi.encodeWithSelector(CallTwice.callCounterTwice.selector, counterProxy))
        );
    }
}

contract ComputeExpected is ComputeExpectedBase, MultiCallActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("CALL_TWICE")) return "CallTwice";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address callerAddr = vm.envAddress("CALL_TWICE");

        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, callerAddr);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL2Addr, callerAddr);
        bytes32 h0 = _entryHash(l1[0]);
        bytes32 h1 = _entryHash(l1[1]);
        bytes32 l2h0 = _entryHash(l2[0]);
        bytes32 l2h1 = _entryHash(l2[1]);

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(h0), vm.toString(h1));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2h0), vm.toString(l2h1));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));
        _printL2CallHashes(l2);
        _printL1Table(l1);
        _printL2Table(l2);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (2 entries, same proxyEntryHash) ===");
        for (uint256 i = 0; i < l1.length; i++) {
            _logEntry(i, l1[i]);
        }
        console.log("");
        console.log("=== EXPECTED L2 TABLE (2 entries, same proxyEntryHash) ===");
        for (uint256 i = 0; i < l2.length; i++) {
            _logL2Entry(i, l2[i]);
        }
    }
}
