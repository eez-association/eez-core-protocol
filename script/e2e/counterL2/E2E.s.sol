// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {StateDelta, L2ToL1Call, ExecutionEntry, StaticLookup} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticLookup as L2StaticLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noStaticLookups,
    noNestedActions,
    noL2Calls,
    noL2OutgoingCalls,
    noL2StaticLookups,
    deferredSingleRollupBatch,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  CounterL2 scenario — L2-starting, simplest case, two-sided
//
//  L2 side (ExecuteL2):
//    1. SYSTEM loads ONE entry on L2 with precomputed return=uint256(1)
//    2. User calls CAP.incrementProxy() on L2
//    3. CAP calls CounterProxy (L2 proxy for Counter on L1) -> managerL2.executeCrossChainCall
//    4. Entry consumed, returns abi.encode(1); CAP (L2): counter=1, targetCounter=1
//
//  L1 side (Execute):
//    1. postAndVerifyBatch loads ONE deferred entry
//       (proxyEntryHash=0 — no source-side hash to match; system-driven) whose
//       l2ToL1Calls describe the inbound call from CAP (L2) to Counter (L1)
//    2. executeL2Txs(L2_ROLLUP_ID) drains the entry via _processNCalls
//    3. _processNCalls forwards through the lazily-created source proxy
//       (proxy_for_CAP_on_L2 deployed on L1) into Counter.increment() on L1
//    4. Counter.counter() on L1 advances to 1
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract CounterL2Actions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _callHash(address counterL1, address capL2) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, counterL1, 0, _incrementCallData(), capL2, L2_ROLLUP_ID);
    }

    /// @dev Single L2 entry — the SOURCE side. Consumed by an outbound `executeCrossChainCall`
    /// (CAP L2 -> Counter L1 proxy); it carries no incoming calls and returns precomputed `uint256(1)`,
    /// so the rolling hash is just the entry-begin seed.
    /// NOTE: L2 rolling-hash seed (`entryBeginL2`) is pending the EEZL2 migration; re-verify when EEZL2.sol lands.
    function _l2Entries(address counterL1, address counterAndProxyL2)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 proxyEntryHash = _callHash(counterL1, counterAndProxyL2);
        // PENDING EEZL2: seed-only rolling hash (no incoming calls).
        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: proxyEntryHash,
            incomingCalls: noL2Calls(),
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    /// @dev Single L1 entry — the DESTINATION side. System-driven (proxyEntryHash=0), drained by
    /// `executeL2Txs`. `l2ToL1Calls[0]` is the inbound call delivered through the source proxy for
    /// CAP-on-L2 (lazily created during processing); it executes ON L1, so CALL_BEGIN folds the call
    /// hash with targetRollupId = MAINNET.
    function _l1Entries(address counterL1, address counterAndProxyL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: counterAndProxyL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _incrementCallData()
        });

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-counter"),
            etherDelta: 0
        });

        bytes32 ccTop = _callHash(counterL1, counterAndProxyL2);
        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, ccTop);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(1))
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
/// @dev Runs on L2. SYSTEM_ADDRESS is the local deployer (anvil account 0), so the deployer can call
///      loadExecutionTable directly. The run-local.sh `execute_l2_same_block` wrapper disables
///      automine, lets both txs queue, then mines them together — same-block guarantee satisfied.
/// Env: MANAGER_L2, COUNTER_L1, COUNTER_AND_PROXY_L2
contract ExecuteL2 is Script, CounterL2Actions {
    function run() external {
        address capAddr = vm.envAddress("COUNTER_AND_PROXY_L2");

        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2"))
            .loadExecutionTable(_l2Entries(vm.envAddress("COUNTER_L1"), capAddr), noL2StaticLookups());
        CounterAndProxy(capAddr).incrementProxy();

        console.log("done");
        console.log("counter=%s", CounterAndProxy(capAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

/// @notice Inline L2-TX batcher — postBatch (deferred) + executeL2Txs in one tx.
/// @dev Builds the L1 entry INTERNALLY (inherits `CounterL2Actions`) so the caller never ABI-encodes
///      the nested `ExecutionEntry[]` across the call boundary — only the single deferred-batch encode
///      for `postAndVerifyBatch` remains, keeping clear of the via-ir stack limit. `immediateEntryCount`
///      is 0 so the zero-hash entry stays in the deferred queue and is drained by `executeL2Txs`.
contract DeferredL2TXBatcher is CounterL2Actions {
    function execute(EEZ rollups, address proofSystem, address counterL1, address capL2) external {
        rollups.postAndVerifyBatch(
            deferredSingleRollupBatch(proofSystem, L2_ROLLUP_ID, _l1Entries(counterL1, capL2), noStaticLookups())
        );
        rollups.executeL2Txs(L2_ROLLUP_ID);
    }
}

/// @title Execute — local mode: postBatch (deferred) + executeL2Txs on L1.
/// @dev Drives the L1-side simulation of the L2-originated cross-chain call. The lazily-created source
///      proxy for (CAP-on-L2, L2_ROLLUP_ID) lives on L1 and is created inside `_processNCalls` during
///      executeL2Txs.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L1, COUNTER_AND_PROXY_L2
contract Execute is Script {
    function run() external {
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        DeferredL2TXBatcher batcher = new DeferredL2TXBatcher();
        batcher.execute(
            EEZ(vm.envAddress("ROLLUPS")),
            vm.envAddress("PROOF_SYSTEM"),
            counterL1,
            vm.envAddress("COUNTER_AND_PROXY_L2")
        );

        console.log("done");
        console.log("L1 counterL1=%s", Counter(counterL1).counter());
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
