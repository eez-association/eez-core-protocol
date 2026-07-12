// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "src/EEZ.sol";
import {EEZL2} from "src/L2/EEZL2.sol";
import {StateDelta, L2ToL1Call, ExecutionEntry, LookupCall, ExpectedLookup} from "src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    LookupCall as L2LookupCall,
    ExpectedLookup as L2ExpectedLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "src/interfaces/IEEZL2.sol";
import {Counter} from "test/mocks/CounterContracts.sol";
import {CallTwoDifferent} from "test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "script/e2e/shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noLookupCalls,
    noL2LookupCalls,
    noNestedActions,
    RollingHashBuilder
} from "script/e2e/shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Multi-call scenario: two different targets, L2-starting (mirror of
//  multi_call/L1_to_L2/multi-call-two-diff)
//
//  Source side (ExecuteL2 on L2):
//    CallTwoDifferent on L2 invokes increment() on TWO different L2 proxies,
//    each wrapping a distinct Counter on L1. Two L2 entries with DIFFERENT
//    proxyEntryHashes (different targetAddress in the preimage), consumed
//    sequentially; each caches returnData = uint256(1). No incomingCalls —
//    the actual executions happen on L1.
//
//  Destination side (Execute on L1):
//    postAndVerifyBatch loads ONE deferred system-driven entry
//    (proxyEntryHash=0) whose l2ToL1Calls[] carry both inbound increments
//    (counterA then counterB) from CallTwoDifferent-on-L2;
//    executeL2TX(L2_ROLLUP_ID) drains it via _processNCalls → each L1
//    counter goes 0→1.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract TwoDiffL2Actions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev L2-side hash: the proxy on L2 wraps (target-on-L1, MAINNET); the manager
    ///      forces sourceRollupId=ROLLUP_ID, sourceAddress is CallTwoDifferent-on-L2.
    function _callHash(address counterL1, address callerL2) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, counterL1, 0, _incrementCallData(), callerL2, L2_ROLLUP_ID);
    }

    /// @dev Two L2 source entries — different proxyEntryHashes (A then B),
    ///      sequential consumption, each cached return = uint256(1).
    function _l2Entries(address counterA, address counterB, address callerL2)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        entries = new L2ExecutionEntry[](2);
        entries[0] = _buildL2Entry(_callHash(counterA, callerL2));
        entries[1] = _buildL2Entry(_callHash(counterB, callerL2));
    }

    function _buildL2Entry(bytes32 ah) private pure returns (L2ExecutionEntry memory) {
        return L2ExecutionEntry({
            proxyEntryHash: ah,
            incomingCalls: new CrossChainCall[](0),
            expectedOutgoingCalls: new ExpectedOutgoingCrossChainCall[](0),
            expectedLookups: new L2ExpectedLookup[](0),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            rollingHash: bytes32(0)
        });
    }

    /// @dev Single L1 destination entry — L2-TX style, system-driven (proxyEntryHash=0).
    ///      l2ToL1Calls[0] increments counterA, l2ToL1Calls[1] increments counterB,
    ///      both from (CallTwoDifferent-on-L2, L2) via the lazily-created source proxy.
    function _l1Entries(address counterA, address counterB, address callerL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = L2ToL1Call({
            isStatic: false,
            targetAddress: counterA,
            value: 0,
            data: _incrementCallData(),
            sourceAddress: callerL2,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });
        calls[1] = L2ToL1Call({
            isStatic: false,
            targetAddress: counterB,
            value: 0,
            data: _incrementCallData(),
            sourceAddress: callerL2,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });

        bytes32 rh = bytes32(0);
        rh = RollingHashBuilder.appendCallBegin(rh, 1);
        rh = RollingHashBuilder.appendCallEnd(rh, 1, true, abi.encode(uint256(1)));
        rh = RollingHashBuilder.appendCallBegin(rh, 2);
        rh = RollingHashBuilder.appendCallEnd(rh, 2, true, abi.encode(uint256(1)));

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-multi-call-two-diffL2"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            expectedLookups: new ExpectedLookup[](0),
            callCount: 2,
            returnData: "",
            rollingHash: rh
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

/// @title DeployL2 — on L2, create proxies for both L1 counters + deploy CallTwoDifferent
/// Env: MANAGER_L2, COUNTER_A_L1, COUNTER_B_L1
/// Outputs: PROXY_A_L2, PROXY_B_L2, CALL_TWO_DIFF_L2
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterA = vm.envAddress("COUNTER_A_L1");
        address counterB = vm.envAddress("COUNTER_B_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);
        address proxyA = _proxy(manager, counterA);
        address proxyB = _proxy(manager, counterB);

        CallTwoDifferent callerL2 = new CallTwoDifferent();

        console.log("PROXY_A_L2=%s", proxyA);
        console.log("PROXY_B_L2=%s", proxyB);
        console.log("CALL_TWO_DIFF_L2=%s", address(callerL2));
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

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — local mode: loadExecutionTable (system) + callBothCounters (user) in same block
/// Env: MANAGER_L2, COUNTER_A_L1, COUNTER_B_L1, PROXY_A_L2, PROXY_B_L2, CALL_TWO_DIFF_L2
contract ExecuteL2 is Script, TwoDiffL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterA = vm.envAddress("COUNTER_A_L1");
        address counterB = vm.envAddress("COUNTER_B_L1");
        address proxyA = vm.envAddress("PROXY_A_L2");
        address proxyB = vm.envAddress("PROXY_B_L2");
        address callerL2 = vm.envAddress("CALL_TWO_DIFF_L2");

        vm.startBroadcast();
        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterA, counterB, callerL2), noL2LookupCalls());
        (uint256 a, uint256 b) = CallTwoDifferent(callerL2).callBothCounters(proxyA, proxyB);

        console.log("done");
        console.log("a=%s b=%s", a, b);
        vm.stopBroadcast();
    }
}

/// @notice Inline L2-TX batcher — postAndVerifyBatch (deferred) + executeL2TX in one tx.
contract DeferredL2TXBatcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        uint256 rollupId,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls
    )
        external
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";

        uint64[] memory psIdx = new uint64[](1);
        psIdx[0] = 0;
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: rollupId, proofSystemIndex: psIdx});

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            blockNumber: 0,
            entries: entries,
            l1ToL2lookupCalls: lookupCalls,
            transientExecutionEntryCount: 0,
            transientLookupCallCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
        rollups.executeL2TX(rollupId);
    }
}

/// @title Execute — local mode: postAndVerifyBatch (deferred) + executeL2TX on L1.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_A_L1, COUNTER_B_L1, CALL_TWO_DIFF_L2
contract Execute is Script, TwoDiffL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterA = vm.envAddress("COUNTER_A_L1");
        address counterB = vm.envAddress("COUNTER_B_L1");
        address callerL2 = vm.envAddress("CALL_TWO_DIFF_L2");

        vm.startBroadcast();
        DeferredL2TXBatcher batcher = new DeferredL2TXBatcher();
        batcher.execute(
            EEZ(rollupsAddr), proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterA, counterB, callerL2), noLookupCalls()
        );

        console.log("done");
        console.log("L1 counterA=%s", Counter(counterA).counter());
        console.log("L1 counterB=%s", Counter(counterB).counter());
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

contract ComputeExpected is ComputeExpectedBase, TwoDiffL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_A_L1")) return "CounterA";
        if (a == vm.envAddress("COUNTER_B_L1")) return "CounterB";
        if (a == vm.envAddress("CALL_TWO_DIFF_L2")) return "CallTwoDiff(L2)";
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
