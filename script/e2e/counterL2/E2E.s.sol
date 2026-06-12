// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {StateDelta, L2ToL1Call, ExecutionEntry, LookupCall, ExpectedLookup} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    LookupCall as L2LookupCall,
    ExpectedLookup as L2ExpectedLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {crossChainCallHash, noLookupCalls, noNestedActions, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  CounterL2 scenario — L2-starting, simplest case, two-sided
//
//  L2 side (ExecuteL2):
//    1. SYSTEM loads ONE entry on L2 with precomputed return=uint256(1)
//    2. User calls CAP.incrementProxy() on L2
//    3. CAP calls CounterProxy (L2 proxy for Counter on L1) → managerL2.executeCrossChainCall
//    4. Entry consumed, returns abi.encode(1); CAP (L2): counter=1, targetCounter=1
//
//  L1 side (Execute):
//    1. postAndVerifyBatch loads ONE deferred entry
//       (proxyEntryHash=0 — no source-side hash to match; system-driven) whose
//       l2ToL1Calls describe the inbound call from CAP (L2) to Counter (L1)
//    2. executeL2TX(L2_ROLLUP_ID) drains the entry via _processNCalls
//    3. _processNCalls forwards through the lazily-created source proxy
//       (proxy_for_CAP_on_L2 deployed on L1) into Counter.increment() on L1
//    4. Counter.counter() on L1 advances to 1
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract CounterL2Actions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _callHash(address counterL1, address capL2) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, counterL1, 0, _incrementCallData(), capL2, L2_ROLLUP_ID);
    }

    function _l2Entries(address counterL1, address counterAndProxyL2)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: _callHash(counterL1, counterAndProxyL2),
            incomingCalls: new CrossChainCall[](0),
            expectedOutgoingCalls: new ExpectedOutgoingCrossChainCall[](0),
            expectedLookups: new L2ExpectedLookup[](0),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            rollingHash: bytes32(0)
        });
    }

    /// @dev Single L1 entry — L2-TX style, system-driven (proxyEntryHash=0).
    /// `l2ToL1Calls[0]` is the inbound call delivered through the source proxy
    /// for CAP-on-L2 (lazily created by `_processNCalls`).
    function _l1Entries(address counterL1, address counterAndProxyL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: counterL1,
            value: 0,
            data: _incrementCallData(),
            sourceAddress: counterAndProxyL2,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });

        bytes32 rh = bytes32(0);
        rh = RollingHashBuilder.appendCallBegin(rh, 1);
        rh = RollingHashBuilder.appendCallEnd(rh, 1, true, abi.encode(uint256(1)));

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            expectedLookups: new ExpectedLookup[](0),
            callCount: 1,
            returnData: abi.encode(uint256(1)),
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

/// @title DeployL2 — on L2, create proxy for counterL1 + deploy CounterAndProxy
/// Env: MANAGER_L2, COUNTER_L1
/// Outputs: COUNTER_PROXY_L2, COUNTER_AND_PROXY_L2
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        address counterProxy;
        try manager.createCrossChainProxy(counterL1Addr, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = manager.computeCrossChainProxyAddress(counterL1Addr, MAINNET_ROLLUP_ID);
        }

        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        console.log("COUNTER_AND_PROXY_L2=%s", address(cap));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — local mode: loadExecutionTable (system) + incrementProxy (user) in same block
/// @dev Runs on L2. SYSTEM_ADDRESS is the local deployer (anvil account 0),
///      so the deployer can call loadExecutionTable directly. The run-local.sh
///      `execute_l2_same_block` wrapper disables automine, lets both txs queue,
///      then mines them together — same-block guarantee satisfied.
/// Env: MANAGER_L2, COUNTER_L1, COUNTER_AND_PROXY_L2
contract ExecuteL2 is Script, CounterL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY_L2");

        console.log("ExecuteL2: manager=%s counterL1=%s cap=%s", managerAddr, counterL1Addr, capAddr);

        vm.startBroadcast();
        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterL1Addr, capAddr), new L2LookupCall[](0));
        console.log("ExecuteL2: loadExecutionTable done");

        CounterAndProxy(capAddr).incrementProxy();
        console.log("ExecuteL2: incrementProxy done");

        console.log("done");
        console.log("counter=%s", CounterAndProxy(capAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

/// @notice Inline L2-TX batcher — postBatch (deferred) + executeL2TX in one tx.
/// @dev We override `transientExecutionEntryCount=0` so the zero-hash entry stays in the
///      deferred queue and is drained by the subsequent `executeL2TX(rollupId)` call.
///      The shared `L2TXBatcher` auto-detects leading zero-hash entries as transient,
///      which would consume the entry inline during postBatch and leave nothing for
///      executeL2TX to drain.
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
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
        rollups.executeL2TX(rollupId);
    }
}

/// @title Execute — local mode: postBatch (deferred) + executeL2TX on L1.
/// @dev Drives the L1-side simulation of the L2-originated cross-chain call.
///      The lazily-created source proxy for (CAP-on-L2, L2_ROLLUP_ID) lives on L1
///      and is created inside `_processNCalls` during executeL2TX.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L1, COUNTER_AND_PROXY_L2
contract Execute is Script, CounterL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        vm.startBroadcast();
        DeferredL2TXBatcher batcher = new DeferredL2TXBatcher();
        batcher.execute(
            EEZ(rollupsAddr), proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL1Addr, capL2Addr), noLookupCalls()
        );

        console.log("done");
        console.log("L1 counterL1=%s", Counter(counterL1Addr).counter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode: outputs user tx fields for L2
/// Env: COUNTER_AND_PROXY_L2
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_AND_PROXY_L2");
        bytes memory data = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, CounterL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "Counter";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L2")) return "CounterAndProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY_L2");

        L2ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, capAddr);
        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, capAddr);

        bytes32 l2Hash = _entryHash(l2[0]);
        bytes32 l1Hash = _entryHash(l1[0]);
        bytes32 callHash = l2[0].proxyEntryHash;

        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(callHash));

        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(0, l2[0]);

        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry) ===");
        _logEntry(0, l1[0]);
    }
}
