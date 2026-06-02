// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {StateDelta, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry, LookupCall} from "../../../src/interfaces/IEEZ.sol";
import {Counter} from "../../../test/mocks/CounterContracts.sol";
import {CallTwoDifferent} from "../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noLookupCalls,
    noNestedActions,
    noCalls,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Multi-call scenario: two different targets, two-sided
//
//  Source side (Execute on L1):
//    CallTwoDifferent.callBothCounters(proxyA, proxyB) invokes increment()
//    on TWO different L2 Counter proxies. Two entries with DIFFERENT
//    proxyEntryHashes (different `targetAddress` in the preimage) — still
//    consumed sequentially. Each entry's cached returnData = uint256(1).
//
//  Destination side (ExecuteL2 on L2):
//    A CallTwoDifferentL2 trigger contract on L2 invokes increment() on two
//    trigger proxies (originalRollupId=MAINNET, one per counter). SYSTEM loads
//    both entries once; the trigger calls consume them sequentially via
//    managerL2.executeL1ToL2Call. Each counter goes 0->1.
//
//  L1 and L2 proxyEntryHashes DIFFER (the L2 side's sourceAddress is the L2
//  trigger contract, not the L1 CallTwoDifferent) — see TWO_SIDED_MIGRATION.md
//  Pattern C.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract TwoDiffActions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _callHash(address target, address caller) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, target, 0, _incrementCallData(), caller, MAINNET_ROLLUP_ID);
    }

    /// @dev L2-side hash: trigger proxy on L2 has originalRollupId=MAINNET.
    function _l2CallHash(address target, address l2Caller) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, target, 0, _incrementCallData(), l2Caller, L2_ROLLUP_ID);
    }

    function _l1Entries(address counterA, address counterB, address caller)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        bytes32 hA = _callHash(counterA, caller);
        bytes32 hB = _callHash(counterB, caller);

        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-two-diff-1"),
            etherDelta: 0
        });

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-state-after-two-diff-1"),
            newState: keccak256("l2-state-after-two-diff-2"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](2);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas1,
            proxyEntryHash: hA,
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            rollingHash: bytes32(0)
        });
        entries[1] = ExecutionEntry({
            stateDeltas: deltas2,
            proxyEntryHash: hB,
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            rollingHash: bytes32(0)
        });
    }

    /// @dev Two L2-side mirror entries — one per inbound call (counterA then
    /// counterB). Each entry has a single L2ToL1Call invoking
    /// Counter.increment() on its target from `caller` (CallTwoDifferent on
    /// L1). Each entry's proxyEntryHash matches the L1 entry with the same
    /// target. Both entries return abi.encode(1) (each L2 counter starts at
    /// 0 and is incremented once).
    function _l2Entries(address counterA, address counterB, address l2Caller)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        bytes32 hA = _l2CallHash(counterA, l2Caller);
        bytes32 hB = _l2CallHash(counterB, l2Caller);

        entries = new ExecutionEntry[](2);
        entries[0] = _buildL2Entry(counterA, l2Caller, hA);
        entries[1] = _buildL2Entry(counterB, l2Caller, hB);
    }

    function _buildL2Entry(address target, address l2Caller, bytes32 entryHash)
        private
        pure
        returns (ExecutionEntry memory)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: target,
            value: 0,
            data: _incrementCallData(),
            sourceAddress: l2Caller,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });

        bytes memory retData = abi.encode(uint256(1));
        bytes32 rh = bytes32(0);
        rh = RollingHashBuilder.appendCallBegin(rh, 1);
        rh = RollingHashBuilder.appendCallEnd(rh, 1, true, retData);

        return ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: entryHash,
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            callCount: 1,
            returnData: retData,
            rollingHash: rh
        });
    }
}

contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");

        vm.startBroadcast();
        Counter counterA = new Counter();
        Counter counterB = new Counter();

        EEZL2 manager = EEZL2(managerAddr);
        address triggerProxyA = _proxy(manager, address(counterA));
        address triggerProxyB = _proxy(manager, address(counterB));

        CallTwoDifferent callTwoDiffL2 = new CallTwoDifferent();

        console.log("COUNTER_A_L2=%s", address(counterA));
        console.log("COUNTER_B_L2=%s", address(counterB));
        console.log("TRIGGER_PROXY_A_L2=%s", triggerProxyA);
        console.log("TRIGGER_PROXY_B_L2=%s", triggerProxyB);
        console.log("CALL_TWO_DIFF_L2=%s", address(callTwoDiffL2));
        vm.stopBroadcast();
    }

    function _proxy(EEZL2 manager, address target) internal returns (address) {
        try manager.createCrossChainProxy(target, MAINNET_ROLLUP_ID) returns (address p) {
            return p;
        } catch {
            return manager.computeCrossChainProxyAddress(target, MAINNET_ROLLUP_ID);
        }
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

contract Batcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        CallTwoDifferent caller,
        address pA,
        address pB
    )
        external
        returns (uint256 a, uint256 b)
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        uint256[] memory rids = new uint256[](1);
        rids[0] = L2_ROLLUP_ID;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](psList.length);
        for (uint256 _i = 0; _i < psList.length; _i++) {
            psIdx[_i] = uint64(_i);
        }
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](rids.length);
        for (uint256 _i = 0; _i < rids.length; _i++) {
            rps[_i] = RollupIdWithProofSystems({rollupId: rids[_i], proofSystemIndex: psIdx});
        }

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            blockNumber: 0,
            entries: entries,
            l1ToL2lookupCalls: lookupCalls,
            transientExecutionEntryCount: 0,
            transientLookupCallCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
        (a, b) = caller.callBothCounters(pA, pB);
    }
}

/// @title ExecuteL2 — local mode: drive Counter.increment() once on each of the two L2 counters
///        via a CallTwoDifferent trigger on L2.
/// Env: MANAGER_L2, COUNTER_A_L2, COUNTER_B_L2, TRIGGER_PROXY_A_L2, TRIGGER_PROXY_B_L2, CALL_TWO_DIFF_L2
contract ExecuteL2 is Script, TwoDiffActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterA = vm.envAddress("COUNTER_A_L2");
        address counterB = vm.envAddress("COUNTER_B_L2");
        address triggerA = vm.envAddress("TRIGGER_PROXY_A_L2");
        address triggerB = vm.envAddress("TRIGGER_PROXY_B_L2");
        address callerL2 = vm.envAddress("CALL_TWO_DIFF_L2");

        vm.startBroadcast();
        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterA, counterB, callerL2), noLookupCalls());
        CallTwoDifferent(callerL2).callBothCounters(triggerA, triggerB);

        console.log("done");
        console.log("L2 counterA=%s", Counter(counterA).counter());
        console.log("L2 counterB=%s", Counter(counterB).counter());
        vm.stopBroadcast();
    }
}

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
        Batcher batcher = new Batcher();
        (uint256 a, uint256 b) = batcher.execute(
            EEZ(rollupsAddr),
            proofSystemAddr,
            _l1Entries(counterA, counterB, callerAddr),
            noLookupCalls(),
            CallTwoDifferent(callerAddr),
            proxyA,
            proxyB
        );
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
        address callerL2 = vm.envAddress("CALL_TWO_DIFF_L2");

        ExecutionEntry[] memory l1 = _l1Entries(counterA, counterB, callerAddr);
        ExecutionEntry[] memory l2 = _l2Entries(counterA, counterB, callerL2);
        bytes32 h0 = _entryHash(l1[0]);
        bytes32 h1 = _entryHash(l1[1]);
        bytes32 l2h0 = _entryHash(l2[0]);
        bytes32 l2h1 = _entryHash(l2[1]);

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(h0), vm.toString(h1));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2h0), vm.toString(l2h1));
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
