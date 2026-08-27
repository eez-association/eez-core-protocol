// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {RollupUpdate, L2ToL1Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2ExecutionEntry} from "../../../../../src/interfaces/IEEZL2.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {Counter} from "../../../../../test/mocks/CounterContracts.sol";
import {CallTwoDifferent} from "../../../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    crossChainCallHashL2Out,
    getOrCreateProxy,
    noStaticEntries,
    noNestedActions,
    noL2Calls,
    noL2OutgoingCalls,
    noL2StaticEntries,
    immediateSingleRollupBatch,
    RollingHashBuilder
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Multi-call scenario: two different targets, L2-starting (mirror of
//  multi_call/L1_to_L2/multi-call-two-diff)
//
//  Source side (ExecuteL2 on L2):
//    CallTwoDifferent on L2 invokes increment() once on each of TWO L2
//    proxies (Counter A and Counter B on L1). Each proxy call consumes an
//    L2 entry sequentially — two entries with DIFFERENT proxyEntryHashes
//    (different targets), each returning uint256(1). No incomingCalls: the
//    actual executions happen on L1.
//
//  Destination side (Execute on L1):
//    postAndVerifyBatch carries ONE immediate system-driven entry
//    (proxyEntryHash=0) whose l2ToL1Calls[] carry both inbound increments
//    (A then B) from CallTwoDifferent-on-L2. The immediate L2Tx run
//    executes it inline, forwarding through the lazily-created source proxy
//    into each counter once → counterA=1, counterB=1.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract MultiCallTwoDiffL2Actions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev Identity of a call as executed ON L1 (the CALL_BEGIN fold in the L1 entry).
    function _l1CallHash(address counterL1, address callerL2) internal pure returns (bytes32) {
        return crossChainCallHash(false, callerL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementCallData());
    }

    /// @dev L2-outgoing key the SOURCE L2 matches an outgoing call with — one per target counter.
    function _l2EntryKey(address counterL1, address callerL2) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(callerL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementCallData());
    }

    /// @dev Two L2 source entries — different proxyEntryHashes (counter A, then counter B),
    ///      consumed sequentially, each returning the counter's new value uint256(1).
    function _l2Entries(
        address counterA,
        address counterB,
        address callerL2
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        entries = new L2ExecutionEntry[](2);
        entries[0] = _buildL2Entry(_l2EntryKey(counterA, callerL2));
        entries[1] = _buildL2Entry(_l2EntryKey(counterB, callerL2));
    }

    function _buildL2Entry(bytes32 proxyEntryHash) private pure returns (L2ExecutionEntry memory) {
        return L2ExecutionEntry({
            proxyEntryHash: proxyEntryHash,
            incomingCalls: noL2Calls(),
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: RollingHashBuilder.entryBeginL2(proxyEntryHash),
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    /// @dev Single L1 destination entry — system-driven (proxyEntryHash=0), executed as an
    ///      immediate L2Tx during `postAndVerifyBatch`. l2ToL1Calls[0] targets counter A,
    ///      l2ToL1Calls[1] targets counter B; both from CallTwoDifferent-on-L2.
    function _l1Entries(
        address counterA,
        address counterB,
        address callerL2
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = _buildL1Call(counterA, callerL2);
        calls[1] = _buildL1Call(counterB, callerL2);

        RollupUpdate[] memory deltas = new RollupUpdate[](1);
        deltas[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-multi-call-two-diffL2"),
            etherDelta: 0
        });

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, _l1CallHash(counterA, callerL2));
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));
        rh = RollingHashBuilder.appendCallBegin(rh, _l1CallHash(counterB, callerL2));
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

    function _buildL1Call(address counterL1, address callerL2) private pure returns (L2ToL1Call memory) {
        return L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            gas: 0,
            sourceAddress: callerL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _incrementCallData()
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title Deploy — on L1, deploy the two target Counters
/// Outputs: COUNTER_A_L1, COUNTER_B_L1
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterA = new Counter();
        Counter counterB = new Counter();
        console.log("COUNTER_A_L1=%s", address(counterA));
        console.log("COUNTER_B_L1=%s", address(counterB));
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — on L2, create proxies for both counters + deploy CallTwoDifferent
/// Env: MANAGER_L2, COUNTER_A_L1, COUNTER_B_L1
/// Outputs: PROXY_A_L2, PROXY_B_L2, CALL_TWO_DIFF_L2
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterA = vm.envAddress("COUNTER_A_L1");
        address counterB = vm.envAddress("COUNTER_B_L1");

        vm.startBroadcast();
        address proxyA = getOrCreateProxy(IEEZ(managerAddr), counterA, MAINNET_ROLLUP_ID);
        address proxyB = getOrCreateProxy(IEEZ(managerAddr), counterB, MAINNET_ROLLUP_ID);
        CallTwoDifferent callerL2 = new CallTwoDifferent();

        console.log("PROXY_A_L2=%s", proxyA);
        console.log("PROXY_B_L2=%s", proxyB);
        console.log("CALL_TWO_DIFF_L2=%s", address(callerL2));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — local mode: loadExecutionTable (system) + callBothCounters (user) in same block
/// Env: MANAGER_L2, COUNTER_A_L1, COUNTER_B_L1, PROXY_A_L2, PROXY_B_L2, CALL_TWO_DIFF_L2
contract ExecuteL2 is Script, MultiCallTwoDiffL2Actions {
    function run() external {
        address counterA = vm.envAddress("COUNTER_A_L1");
        address counterB = vm.envAddress("COUNTER_B_L1");
        address proxyA = vm.envAddress("PROXY_A_L2");
        address proxyB = vm.envAddress("PROXY_B_L2");
        address callerL2 = vm.envAddress("CALL_TWO_DIFF_L2");

        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2"))
            .loadExecutionTable(_l2Entries(counterA, counterB, callerL2), noL2StaticEntries());
        (uint256 a, uint256 b) = CallTwoDifferent(callerL2).callBothCounters(proxyA, proxyB);

        console.log("done");
        console.log("a=%s b=%s", a, b);
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode: postBatch with the immediate L2Tx entry on L1.
/// @dev A leading zero-hash entry MUST be covered by `immediateEntryCount`
///      (`ImmediateCountStrandsLeadingL2Tx`), so it executes inline during `postAndVerifyBatch`.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_A_L1, COUNTER_B_L1, CALL_TWO_DIFF_L2
contract Execute is Script, MultiCallTwoDiffL2Actions {
    function run() external {
        address counterA = vm.envAddress("COUNTER_A_L1");
        address counterB = vm.envAddress("COUNTER_B_L1");

        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"),
                    L2_ROLLUP_ID,
                    _l1Entries(counterA, counterB, vm.envAddress("CALL_TWO_DIFF_L2")),
                    noStaticEntries()
                )
            );

        console.log("done");
        console.log("L1 counterA=%s counterB=%s", Counter(counterA).counter(), Counter(counterB).counter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode: outputs user tx fields for L2
/// Env: PROXY_A_L2, PROXY_B_L2, CALL_TWO_DIFF_L2
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("CALL_TWO_DIFF_L2");
        address proxyA = vm.envAddress("PROXY_A_L2");
        address proxyB = vm.envAddress("PROXY_B_L2");
        bytes memory data = abi.encodeWithSelector(CallTwoDifferent.callBothCounters.selector, proxyA, proxyB);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, MultiCallTwoDiffL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_A_L1")) return "CounterA";
        if (a == vm.envAddress("COUNTER_B_L1")) return "CounterB";
        if (a == vm.envAddress("CALL_TWO_DIFF_L2")) return "CallTwoDifferent(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterA = vm.envAddress("COUNTER_A_L1");
        address counterB = vm.envAddress("COUNTER_B_L1");
        address callerL2 = vm.envAddress("CALL_TWO_DIFF_L2");

        L2ExecutionEntry[] memory l2 = _l2Entries(counterA, counterB, callerL2);
        ExecutionEntry[] memory l1 = _l1Entries(counterA, counterB, callerL2);

        bytes32 l2h0 = _entryHash(l2[0]);
        bytes32 l2h1 = _entryHash(l2[1]);
        bytes32 l1h = _entryHash(l1[0]);

        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2h0), vm.toString(l2h1));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1h));
        console.log(
            "EXPECTED_L2_CALL_HASHES=[%s,%s]", vm.toString(l2[0].proxyEntryHash), vm.toString(l2[1].proxyEntryHash)
        );
        _printL1Table(l1);
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (2 entries, different proxyEntryHashes) ===");
        for (uint256 i = 0; i < l2.length; i++) {
            _logL2Entry(i, l2[i]);
        }

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 2 calls) ===");
        _logEntry(0, l1[0]);
    }
}
