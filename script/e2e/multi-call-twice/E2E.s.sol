// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {CrossChainManagerL2} from "../../../src/L2/CrossChainManagerL2.sol";
import {
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry,
    LookupCall
} from "../../../src/ICrossChainManager.sol";
import {Counter} from "../../../test/mocks/CounterContracts.sol";
import {CallTwice} from "../../../test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noLookupCalls,
    noNestedActions,
    noCalls,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Multi-call scenario: same target twice, two-sided
//
//  Source side (Execute on L1):
//    CallTwice.callCounterTwice(counterProxy) invokes increment() twice on
//    the SAME L1 proxy. Each invocation consumes an entry sequentially —
//    two entries with the SAME proxyEntryHash but different returnData
//    (uint256(1) and uint256(2)).
//
//  Destination side (ExecuteL2 on L2):
//    Counter@L2.increment() is invoked twice. Because
//    `executeIncomingCrossChainCall` only consumes `entries[0]` and replaces
//    the execution table on each call, we invoke it twice — once per entry.
//    First call: counter 0->1, returns abi.encode(1). Second: 1->2, returns
//    abi.encode(2). Both L2 entries share the L1 entries' proxyEntryHash.
//
//  Both halves use the same `_callHash(counterL2, caller)` preimage — that
//  is what ties the L1 view (cached returnData) to the L2 view (actual
//  execution of Counter.increment()).
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract MultiCallActions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _callHash(address counterL2, address caller) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, counterL2, 0, _incrementCallData(), caller, MAINNET_ROLLUP_ID);
    }

    function _l1Entries(address counterL2, address caller) internal pure returns (ExecutionEntry[] memory entries) {
        bytes32 ah = _callHash(counterL2, caller);

        StateDelta[] memory deltasA = new StateDelta[](1);
        deltasA[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-twice-1"),
            etherDelta: 0
        });

        StateDelta[] memory deltasB = new StateDelta[](1);
        deltasB[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-state-after-twice-1"),
            newState: keccak256("l2-state-after-twice-2"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](2);
        entries[0] = ExecutionEntry({
            stateDeltas: deltasA,
            proxyEntryHash: ah,
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            rollingHash: bytes32(0)
        });
        entries[1] = ExecutionEntry({
            stateDeltas: deltasB,
            proxyEntryHash: ah,
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            callCount: 0,
            returnData: abi.encode(uint256(2)),
            rollingHash: bytes32(0)
        });
    }

    /// @dev Two L2-side mirror entries — one per inbound call. Each entry has
    /// a single L2ToL1Call invoking Counter.increment() on counterL2 from
    /// `caller` (CallTwice on L1). Same proxyEntryHash as the L1 entries.
    /// returnData and rolling-hash CALL_END payload differ per entry (1 vs 2).
    function _l2Entries(address counterL2, address caller) internal pure returns (ExecutionEntry[] memory entries) {
        bytes32 ah = _callHash(counterL2, caller);

        entries = new ExecutionEntry[](2);
        entries[0] = _buildL2Entry(counterL2, caller, ah, abi.encode(uint256(1)));
        entries[1] = _buildL2Entry(counterL2, caller, ah, abi.encode(uint256(2)));
    }

    function _buildL2Entry(address counterL2, address caller, bytes32 ah, bytes memory retData)
        private
        pure
        returns (ExecutionEntry memory)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: counterL2,
            value: 0,
            data: _incrementCallData(),
            sourceAddress: caller,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        bytes32 rh = bytes32(0);
        rh = RollingHashBuilder.appendCallBegin(rh, 1);
        rh = RollingHashBuilder.appendCallEnd(rh, 1, true, retData);

        return ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: ah,
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

contract Batcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        CallTwice caller,
        address counterProxy
    )
        external
        returns (uint256 first, uint256 second)
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
        rollups.postVerifyAndExecuteOrSaveExecutionsFromBatch(batch);
        (first, second) = caller.callCounterTwice(counterProxy);
    }
}

/// @title ExecuteL2 — local mode: drive Counter.increment() twice on L2.
/// @dev `executeIncomingCrossChainCall` only consumes `entries[0]` and resets
///      the L2 execution table on each call. To exercise the two sequential
///      L2 executions matching the L1 entries, invoke it twice — once with
///      the first L2 entry (returnData = 1), once with the second (= 2).
/// Env: MANAGER_L2, COUNTER_L2, CALL_TWICE
contract ExecuteL2 is Script, MultiCallActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address callerAddr = vm.envAddress("CALL_TWICE");

        vm.startBroadcast();
        CrossChainManagerL2 m = CrossChainManagerL2(managerAddr);

        ExecutionEntry[] memory all = _l2Entries(counterL2Addr, callerAddr);

        ExecutionEntry[] memory e1 = new ExecutionEntry[](1);
        e1[0] = all[0];
        m.executeIncomingCrossChainCall(
            counterL2Addr, 0, _incrementCallData(), callerAddr, MAINNET_ROLLUP_ID, e1, noLookupCalls()
        );

        ExecutionEntry[] memory e2 = new ExecutionEntry[](1);
        e2[0] = all[1];
        m.executeIncomingCrossChainCall(
            counterL2Addr, 0, _incrementCallData(), callerAddr, MAINNET_ROLLUP_ID, e2, noLookupCalls()
        );

        console.log("done");
        console.log("L2 counter=%s", Counter(counterL2Addr).counter());
        vm.stopBroadcast();
    }
}

contract Execute is Script, MultiCallActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterProxy = vm.envAddress("COUNTER_PROXY");
        address callerAddr = vm.envAddress("CALL_TWICE");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        (uint256 first, uint256 second) = batcher.execute(
            EEZ(rollupsAddr),
            proofSystemAddr,
            _l1Entries(counterL2Addr, callerAddr),
            noLookupCalls(),
            CallTwice(callerAddr),
            counterProxy
        );
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
        ExecutionEntry[] memory l2 = _l2Entries(counterL2Addr, callerAddr);
        bytes32 h0 = _entryHash(l1[0]);
        bytes32 h1 = _entryHash(l1[1]);
        bytes32 l2h0 = _entryHash(l2[0]);
        bytes32 l2h1 = _entryHash(l2[1]);

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(h0), vm.toString(h1));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2h0), vm.toString(l2h1));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));
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
