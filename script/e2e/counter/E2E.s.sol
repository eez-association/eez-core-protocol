// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {StateDelta, ExecutionEntry, LookupCall, ExpectedLookup} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    LookupCall as L2LookupCall,
    ExpectedLookup as L2ExpectedLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noLookupCalls,
    noNestedActions,
    noCalls,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Counter scenario — L1-starting, simplest case, two-sided
//
//  L1 side (Execute):
//    1. postAndVerifyBatch loads ONE deferred L1 entry
//       with precomputed return=uint256(1) and a StateDelta advancing L2's stateRoot
//    2. User calls CounterAndProxy.incrementProxy() on L1
//    3. CAP calls CounterProxy (L1 proxy for Counter@L2)
//    4. Proxy forwards to EEZ.executeCrossChainCall
//    5. Entry consumed, returns abi.encode(1); CAP: counter=1, targetCounter=1
//    6. L2 rollup stateRoot in the registry updated via StateDelta
//
//  L2 side (ExecuteL2):
//    1. SYSTEM_ADDRESS calls managerL2.executeIncomingCrossChainCall(...) loading
//       an L2-side entry whose proxyEntryHash mirrors the L1 one
//    2. _processNCalls forwards the inbound call through the lazily-created source
//       proxy (proxy_for_CAP@L1 on L2) into Counter@L2.increment()
//    3. Counter@L2.counter() advances to 1; rolling hash committed
//
//  Both halves use the same `_callHash(counterL2, capL1)` preimage — that is what
//  ties the L1 view (the cached returnData) to the L2 view (the actual execution).
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

/// @dev Centralized action + entry definitions — single source of truth for all contracts.
abstract contract CounterActions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _callHash(address counterL2, address counterAndProxy) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, counterL2, 0, _incrementCallData(), counterAndProxy, MAINNET_ROLLUP_ID);
    }

    /// @dev Single L1 entry — matches Scenario 1 of IntegrationTest.t.sol.
    function _l1Entries(address counterL2, address counterAndProxy)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-counter"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            proxyEntryHash: _callHash(counterL2, counterAndProxy),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            expectedLookups: new ExpectedLookup[](0),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            rollingHash: bytes32(0)
        });
    }

    /// @dev Single L2 entry — L2-side mirror that drives the actual Counter.increment() on L2.
    /// `calls[0]` is the inbound call delivered through the source proxy
    /// (lazily created by `_processNCalls`). Same `proxyEntryHash` as the L1 entry.
    function _l2Entries(address counterL2, address counterAndProxy)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            targetAddress: counterL2,
            value: 0,
            data: _incrementCallData(),
            sourceAddress: counterAndProxy,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        bytes32 rh = bytes32(0);
        rh = RollingHashBuilder.appendCallBegin(rh, 1);
        rh = RollingHashBuilder.appendCallEnd(rh, 1, true, abi.encode(uint256(1)));

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: _callHash(counterL2, counterAndProxy),
            incomingCalls: calls,
            expectedOutgoingCalls: new ExpectedOutgoingCrossChainCall[](0),
            expectedLookups: new L2ExpectedLookup[](0),
            callCount: 1,
            returnData: abi.encode(uint256(1)),
            rollingHash: rh
        });
    }
}

/// @notice Batcher: postAndVerifyBatch + incrementProxy in one tx (local mode only).
contract Batcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        CounterAndProxy cap
    )
        external
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
        cap.incrementProxy();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title DeployL2 — deploy Counter on L2
/// Outputs: COUNTER_L2
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL2 = new Counter();
        console.log("COUNTER_L2=%s", address(counterL2));
        vm.stopBroadcast();
    }
}

/// @title Deploy — on L1, create proxy for counterL2 + deploy CounterAndProxy
/// Env: ROLLUPS, COUNTER_L2
/// Outputs: COUNTER_PROXY, COUNTER_AND_PROXY
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

        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(cap));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — local mode: system-driven L2 simulation of the inbound call.
/// @dev Runs on L2. The local deployer (anvil account 0) is the SYSTEM_ADDRESS.
///      `_processNCalls` lazily creates the source proxy for (CAP on L1, MAINNET) on
///      first use, then forwards `Counter.increment()` through it to counterL2.
/// Env: MANAGER_L2, COUNTER_L2, COUNTER_AND_PROXY
contract ExecuteL2 is Script, CounterActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");

        vm.startBroadcast();
        EEZL2(managerAddr)
            .executeIncomingCrossChainCall(
                counterL2Addr,
                0,
                _incrementCallData(),
                capAddr,
                MAINNET_ROLLUP_ID,
                _l2Entries(counterL2Addr, capAddr),
                new L2LookupCall[](0)
            );

        console.log("done");
        console.log("L2 counter=%s", Counter(counterL2Addr).counter());
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode: postAndVerifyBatch + incrementProxy via Batcher
/// Env: ROLLUPS, COUNTER_L2, COUNTER_AND_PROXY
contract Execute is Script, CounterActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        batcher.execute(
            EEZ(rollupsAddr),
            proofSystemAddr,
            _l1Entries(counterL2Addr, capAddr),
            noLookupCalls(),
            CounterAndProxy(capAddr)
        );

        console.log("done");
        console.log("counter=%s", CounterAndProxy(capAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — network mode: outputs user tx fields (no Batcher)
/// Env: COUNTER_AND_PROXY
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_AND_PROXY");
        bytes memory data = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected — print expected table for verification
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, CounterActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("COUNTER_AND_PROXY")) return "CounterAndProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");

        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, capAddr);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL2Addr, capAddr);

        bytes32 l1Hash = _entryHash(l1[0]);
        bytes32 l2Hash = _entryHash(l2[0]);
        bytes32 l1CallHash = l1[0].proxyEntryHash;
        bytes32 l2CallHash = l2[0].proxyEntryHash;

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1CallHash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2CallHash));

        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry) ===");
        _logEntry(0, l1[0]);

        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(0, l2[0]);
    }
}
