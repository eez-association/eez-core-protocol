// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {StateDelta, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry, LookupCall} from "../../../src/interfaces/IEEZ.sol";
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
//    Counter on L2.increment() is invoked twice via a CallTwiceL2 trigger
//    contract on L2. SYSTEM loads the L2 table with both entries; CallTwiceL2
//    then calls a trigger proxy (originalRollupId=MAINNET, originalAddress=
//    counterL2) twice. Each proxy call forwards to managerL2.executeL1ToL2Call,
//    which consumes entries[0] then entries[1] sequentially via executionIndex.
//    _consumeAndExecute resets _rollingHash to 0 between entries, so each
//    entry's rollingHash starts fresh at CB(1)→CE(1, true, retData).
//
//  Note: L1 and L2 proxyEntryHashes DIFFER because the destination-side
//  sourceAddress is the L2 trigger contract (CallTwiceL2), not the L1
//  CallTwice. Cross-chain symmetry stops at the destination boundary —
//  multi-entry sequential consumption requires its own L2 trigger.
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

    /// @dev L2-side hash: trigger proxy on L2 has originalRollupId=MAINNET, so
    ///      the manager computes hash(MAINNET, counterL2, ..., source=callTwiceL2, L2).
    function _l2CallHash(address counterL2, address callTwiceL2) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, counterL2, 0, _incrementCallData(), callTwiceL2, L2_ROLLUP_ID);
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
    function _l2Entries(address counterL2, address callTwiceL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        bytes32 ah = _l2CallHash(counterL2, callTwiceL2);

        // Each L2 entry is consumed by a separate `executeL1ToL2Call` invocation
        // (driven by callTwiceL2 calling the trigger proxy twice). `_consumeAndExecute`
        // resets `_rollingHash` to 0 at the start of each entry — so both entries
        // have rh = CB(1)→CE(1, true, retData) starting fresh.
        entries = new ExecutionEntry[](2);
        entries[0] = _buildL2Entry(counterL2, callTwiceL2, ah, abi.encode(uint256(1)));
        entries[1] = _buildL2Entry(counterL2, callTwiceL2, ah, abi.encode(uint256(2)));
    }

    function _buildL2Entry(address counterL2, address callTwiceL2, bytes32 ah, bytes memory retData)
        private
        pure
        returns (ExecutionEntry memory)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: counterL2,
            value: 0,
            data: _incrementCallData(),
            sourceAddress: callTwiceL2,
            sourceRollupId: L2_ROLLUP_ID,
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
        address managerAddr = vm.envAddress("MANAGER_L2");

        vm.startBroadcast();
        Counter counter = new Counter();

        // Trigger proxy on L2 for the real counter, tagged as originalRollupId=MAINNET so the
        // hash computed by managerL2.executeL1ToL2Call matches the L2 entries' proxyEntryHash.
        EEZL2 manager = EEZL2(managerAddr);
        address counterTriggerProxy;
        try manager.createCrossChainProxy(address(counter), MAINNET_ROLLUP_ID) returns (address p) {
            counterTriggerProxy = p;
        } catch {
            counterTriggerProxy = manager.computeCrossChainProxyAddress(address(counter), MAINNET_ROLLUP_ID);
        }

        // L2-side trigger contract: identical to the L1 CallTwice. Its address is what the
        // L2 entries' sourceAddress commits to.
        CallTwice callTwiceL2 = new CallTwice();

        console.log("COUNTER_L2=%s", address(counter));
        console.log("COUNTER_TRIGGER_PROXY_L2=%s", counterTriggerProxy);
        console.log("CALL_TWICE_L2=%s", address(callTwiceL2));
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
        (first, second) = caller.callCounterTwice(counterProxy);
    }
}

/// @title ExecuteL2 — local mode: drive Counter.increment() twice on L2 via a trigger contract.
/// @dev SYSTEM loads the two-entry table; CallTwiceL2 calls the trigger proxy twice.
///      Each proxy call forwards to managerL2.executeL1ToL2Call which consumes the next
///      entry sequentially. `_consumeAndExecute` resets `_rollingHash` per entry.
/// Env: MANAGER_L2, COUNTER_L2, COUNTER_TRIGGER_PROXY_L2, CALL_TWICE_L2
contract ExecuteL2 is Script, MultiCallActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address triggerProxy = vm.envAddress("COUNTER_TRIGGER_PROXY_L2");
        address callTwiceL2 = vm.envAddress("CALL_TWICE_L2");

        vm.startBroadcast();
        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterL2Addr, callTwiceL2), noLookupCalls());
        CallTwice(callTwiceL2).callCounterTwice(triggerProxy);

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
        address callTwiceL2Addr = vm.envAddress("CALL_TWICE_L2");

        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, callerAddr);
        ExecutionEntry[] memory l2 = _l2Entries(counterL2Addr, callTwiceL2Addr);
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
