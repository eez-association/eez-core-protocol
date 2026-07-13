// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "src/EEZ.sol";
import {EEZL2} from "src/L2/EEZL2.sol";
import {IEEZ} from "src/interfaces/IEEZ.sol";
import {StateDelta, L2ToL1Call, ExecutionEntry, LookupCall, ExpectedLookup} from "src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    LookupCall as L2LookupCall,
    ExpectedLookup as L2ExpectedLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "src/interfaces/IEEZL2.sol";
import {Counter} from "test/mocks/CounterContracts.sol";
import {CallTwice} from "test/mocks/MultiCallContracts.sol";
import {ComputeExpectedBase} from "script/e2e/shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    getOrCreateProxy,
    noLookupCalls,
    noL2LookupCalls,
    noNestedActions,
    RollingHashBuilder
} from "script/e2e/shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Multi-call scenario: same target twice, L2-starting (mirror of
//  multi_call/L1_to_L2/multi-call-twice)
//
//  Source side (ExecuteL2 on L2):
//    CallTwice on L2 invokes increment() twice on the SAME L2 proxy for
//    Counter on L1. Each proxy call consumes an L2 entry sequentially — two
//    entries with the SAME proxyEntryHash but different returnData
//    (uint256(1) and uint256(2)). No incomingCalls: the actual execution
//    happens on L1; the L2 side only serves the precomputed returns.
//
//  Destination side (Execute on L1):
//    postAndVerifyBatch loads ONE deferred system-driven entry
//    (proxyEntryHash=0) whose l2ToL1Calls[] carry BOTH inbound increments
//    from CallTwice-on-L2; executeL2TX(L2_ROLLUP_ID) drains it via
//    _processNCalls, forwarding through the lazily-created source proxy for
//    (CallTwice-on-L2, L2) into Counter.increment() on L1 twice → counter=2.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract MultiCallTwiceL2Actions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev L2-side hash: the proxy on L2 wraps (counterL1, MAINNET); the manager
    ///      forces sourceRollupId=ROLLUP_ID, sourceAddress is CallTwice-on-L2.
    function _callHash(address counterL1, address callTwiceL2) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, counterL1, 0, _incrementCallData(), callTwiceL2, L2_ROLLUP_ID);
    }

    /// @dev Two L2 source entries — same proxyEntryHash, sequential consumption,
    ///      cached returns 1 then 2 (mirror of the L1 entries in multi-call-twice).
    function _l2Entries(address counterL1, address callTwiceL2)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 ah = _callHash(counterL1, callTwiceL2);

        entries = new L2ExecutionEntry[](2);
        entries[0] = _buildL2Entry(ah, abi.encode(uint256(1)));
        entries[1] = _buildL2Entry(ah, abi.encode(uint256(2)));
    }

    function _buildL2Entry(bytes32 ah, bytes memory retData) private pure returns (L2ExecutionEntry memory) {
        return L2ExecutionEntry({
            proxyEntryHash: ah,
            incomingCalls: new CrossChainCall[](0),
            expectedOutgoingCalls: new ExpectedOutgoingCrossChainCall[](0),
            expectedLookups: new L2ExpectedLookup[](0),
            callCount: 0,
            returnData: retData,
            rollingHash: bytes32(0)
        });
    }

    /// @dev Single L1 destination entry — L2-TX style, system-driven (proxyEntryHash=0).
    ///      Both inbound increments are delivered as l2ToL1Calls through the source
    ///      proxy for (CallTwice-on-L2, L2), lazily created by `_processNCalls`.
    function _l1Entries(address counterL1, address callTwiceL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = L2ToL1Call({
            isStatic: false,
            targetAddress: counterL1,
            value: 0,
            data: _incrementCallData(),
            sourceAddress: callTwiceL2,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });
        calls[1] = calls[0];

        bytes32 rh = bytes32(0);
        rh = RollingHashBuilder.appendCallBegin(rh, 1);
        rh = RollingHashBuilder.appendCallEnd(rh, 1, true, abi.encode(uint256(1)));
        rh = RollingHashBuilder.appendCallBegin(rh, 2);
        rh = RollingHashBuilder.appendCallEnd(rh, 2, true, abi.encode(uint256(2)));

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-multi-call-twiceL2"),
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

/// @title Deploy — on L1, deploy Counter (the L1 target)
/// Outputs: COUNTER_L1
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — on L2, create proxy for counterL1 + deploy CallTwice
/// Env: MANAGER_L2, COUNTER_L1
/// Outputs: COUNTER_PROXY_L2, CALL_TWICE_L2
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        address counterProxy = getOrCreateProxy(IEEZ(address(manager)), counterL1Addr, MAINNET_ROLLUP_ID);

        CallTwice callTwiceL2 = new CallTwice();

        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        console.log("CALL_TWICE_L2=%s", address(callTwiceL2));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — local mode: loadExecutionTable (system) + callCounterTwice (user) in same block
/// Env: MANAGER_L2, COUNTER_L1, COUNTER_PROXY_L2, CALL_TWICE_L2
contract ExecuteL2 is Script, MultiCallTwiceL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterProxy = vm.envAddress("COUNTER_PROXY_L2");
        address callTwiceL2 = vm.envAddress("CALL_TWICE_L2");

        vm.startBroadcast();
        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterL1Addr, callTwiceL2), noL2LookupCalls());
        (uint256 first, uint256 second) = CallTwice(callTwiceL2).callCounterTwice(counterProxy);

        console.log("done");
        console.log("first=%s second=%s", first, second);
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
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L1, CALL_TWICE_L2
contract Execute is Script, MultiCallTwiceL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address callTwiceL2 = vm.envAddress("CALL_TWICE_L2");

        vm.startBroadcast();
        DeferredL2TXBatcher batcher = new DeferredL2TXBatcher();
        batcher.execute(
            EEZ(rollupsAddr), proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL1Addr, callTwiceL2), noLookupCalls()
        );

        console.log("done");
        console.log("L1 counterL1=%s", Counter(counterL1Addr).counter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode: outputs user tx fields for L2
/// Env: COUNTER_PROXY_L2, CALL_TWICE_L2
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("CALL_TWICE_L2");
        address counterProxy = vm.envAddress("COUNTER_PROXY_L2");
        bytes memory data = abi.encodeWithSelector(CallTwice.callCounterTwice.selector, counterProxy);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, MultiCallTwiceL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "Counter";
        if (a == vm.envAddress("CALL_TWICE_L2")) return "CallTwice(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address callTwiceL2 = vm.envAddress("CALL_TWICE_L2");

        L2ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, callTwiceL2);
        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, callTwiceL2);

        bytes32 l2h0 = _entryHash(l2[0]);
        bytes32 l2h1 = _entryHash(l2[1]);
        bytes32 l1h = _entryHash(l1[0]);

        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(l2h0), vm.toString(l2h1));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1h));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2[0].proxyEntryHash));

        console.log("");
        console.log("=== EXPECTED L2 TABLE (2 entries, same proxyEntryHash) ===");
        for (uint256 i = 0; i < l2.length; i++) {
            _logL2Entry(i, l2[i]);
        }

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 2 calls) ===");
        _logEntry(0, l1[0]);
    }
}
