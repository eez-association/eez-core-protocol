// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {RollupUpdate, L2ToL1Call, ExecutionEntry, StaticExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    crossChainCallHashL2Out,
    noStaticEntries,
    noNestedActions,
    noL2Calls,
    noL2OutgoingCalls,
    noL2StaticEntries,
    immediateSingleRollupBatch,
    RollingHashBuilder,
    HashStep
} from "../../../shared/E2EHelpers.sol";

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
//    1. postAndVerifyBatch carries ONE immediate entry
//       (proxyEntryHash=0 — no source-side hash to match; system-driven) whose
//       l2ToL1Calls describe the inbound call from CAP (L2) to Counter (L1)
//    2. The immediate L2Tx run executes the entry inline via _processNCalls
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

    // The SAME logical call (CAP on L2 → Counter on L1) is hashed on both sides: L1's CALL_BEGIN
    // fold and the source L2's outgoing key both fold `callGas` = 0 (devnet runs
    // `useGasLeft = false`), so the digests coincide; under `useGasLeft = true` the outgoing key
    // binds the observed gas and differs.

    /// @dev Identity of the call as executed ON L1 (the CALL_BEGIN fold in the L1 entry).
    function _l1CallHash(address counterL1, address capL2) internal pure returns (bytes32) {
        return crossChainCallHash(false, capL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementCallData());
    }

    /// @dev L2-outgoing key the SOURCE L2 matches the outgoing call with.
    function _l2EntryKey(address counterL1, address capL2) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(capL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementCallData());
    }

    /// @dev Single L2 entry — the SOURCE side. Consumed by an outbound `executeCrossChainCall`
    /// (CAP L2 -> Counter L1 proxy); it carries no incoming calls and returns precomputed `uint256(1)`,
    /// so the rolling hash is just the entry-begin seed.
    function _l2Entries(
        address counterL1,
        address counterAndProxyL2
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 proxyEntryHash = _l2EntryKey(counterL1, counterAndProxyL2);
        // Seed-only rolling hash (no incoming calls).
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

    /// @dev Single L1 entry — the DESTINATION side. System-driven (proxyEntryHash=0), executed as an
    /// immediate L2Tx during `postAndVerifyBatch`. `l2ToL1Calls[0]` is the inbound call delivered through the source proxy for
    /// CAP-on-L2 (lazily created during processing); it executes ON L1, so CALL_BEGIN folds the call
    /// hash with targetRollupId = MAINNET.
    function _l1Entries(
        address counterL1,
        address counterAndProxyL2
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: counterAndProxyL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _incrementCallData()
        });

        RollupUpdate[] memory deltas = new RollupUpdate[](1);
        deltas[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-counter"),
            etherDelta: 0
        });

        bytes32 ccTop = _l1CallHash(counterL1, counterAndProxyL2);
        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, ccTop);
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
            returnData: "" // L2Tx entries must be canonical: success == true, empty returnData
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
///      loadExecutionTable directly. The run/local.sh `execute_l2_same_block` wrapper disables
///      automine, lets both txs queue, then mines them together — same-block guarantee satisfied.
/// Env: MANAGER_L2, COUNTER_L1, COUNTER_AND_PROXY_L2
contract ExecuteL2 is Script, CounterL2Actions {
    function run() external {
        address capAddr = vm.envAddress("COUNTER_AND_PROXY_L2");

        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2"))
            .loadExecutionTable(_l2Entries(vm.envAddress("COUNTER_L1"), capAddr), noL2StaticEntries());
        CounterAndProxy(capAddr).incrementProxy();

        console.log("done");
        console.log("counter=%s", CounterAndProxy(capAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode: postBatch with the immediate L2Tx entry on L1.
/// @dev Drives the L1-side simulation of the L2-originated cross-chain call. `immediateEntryCount`
///      covers the leading zero-hash run, so the entry executes inline during `postAndVerifyBatch`.
///      The lazily-created source proxy for (CAP-on-L2, L2_ROLLUP_ID) lives on L1 and is created
///      inside `_processNCalls` during the immediate L2Tx run.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L1, COUNTER_AND_PROXY_L2
contract Execute is Script, CounterL2Actions {
    function run() external {
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"),
                    L2_ROLLUP_ID,
                    _l1Entries(counterL1, vm.envAddress("COUNTER_AND_PROXY_L2")),
                    noStaticEntries()
                )
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
        _printL1Table(l1);
        HashStep[][] memory steps = new HashStep[][](1); // mirrors _l1Entries' fold chain
        steps[0] = new HashStep[](2);
        steps[0][0] = RollingHashBuilder.stepCallBegin(_l1CallHash(counterL1Addr, capAddr));
        steps[0][1] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(1)));
        _printL1Steps(l1, steps);
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (1 entry) ===");
        _logL2Entry(0, l2[0]);

        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (1 entry) ===");
        _logEntry(0, l1[0]);
    }
}
