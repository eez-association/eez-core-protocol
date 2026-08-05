// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {StateUpdate, L2ToL1Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2ExecutionEntry} from "../../../../../src/interfaces/IEEZL2.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {Counter} from "../../../../../test/mocks/CounterContracts.sol";
import {CallTwice} from "../../../../../test/mocks/MultiCallContracts.sol";
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
//    postAndVerifyBatch carries ONE immediate system-driven entry
//    (proxyEntryHash=0) whose l2ToL1Calls[] carry BOTH inbound increments
//    from CallTwice-on-L2. The immediate L2Tx run executes it inline via
//    _processNCalls, forwarding through the lazily-created source proxy for
//    (CallTwice-on-L2, L2) into Counter.increment() on L1 twice → counter=2.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract MultiCallTwiceL2Actions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev Identity of the call as executed ON L1 (the CALL_BEGIN fold in the L1 entry).
    function _l1CallHash(address counterL1, address callTwiceL2) internal pure returns (bytes32) {
        return
            crossChainCallHash(false, callTwiceL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementCallData());
    }

    /// @dev L2-outgoing key the SOURCE L2 matches the outgoing calls with. Both proxy calls share
    ///      it — the manager forces sourceRollupId=ROLLUP_ID, sourceAddress is CallTwice-on-L2.
    function _l2EntryKey(address counterL1, address callTwiceL2) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(callTwiceL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementCallData());
    }

    /// @dev Two L2 source entries — same proxyEntryHash, sequential consumption, cached returns
    ///      1 then 2 (mirror of the L1 entries in multi-call-twice). Both carry the seed-only
    ///      rolling hash, so they share one (proxyEntryHash, rollingHash) identity.
    function _l2Entries(address counterL1, address callTwiceL2)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 proxyEntryHash = _l2EntryKey(counterL1, callTwiceL2);
        entries = new L2ExecutionEntry[](2);
        entries[0] = _buildL2Entry(proxyEntryHash, abi.encode(uint256(1)));
        entries[1] = _buildL2Entry(proxyEntryHash, abi.encode(uint256(2)));
    }

    function _buildL2Entry(bytes32 proxyEntryHash, bytes memory retData)
        private
        pure
        returns (L2ExecutionEntry memory)
    {
        return L2ExecutionEntry({
            proxyEntryHash: proxyEntryHash,
            incomingCalls: noL2Calls(),
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: RollingHashBuilder.entryBeginL2(proxyEntryHash),
            success: true,
            returnData: retData
        });
    }

    /// @dev Single L1 destination entry — system-driven (proxyEntryHash=0), executed as an
    ///      immediate L2Tx during `postAndVerifyBatch`. Both inbound increments are delivered
    ///      as l2ToL1Calls through the source proxy for (CallTwice-on-L2, L2), lazily created
    ///      by `_processNCalls`.
    function _l1Entries(address counterL1, address callTwiceL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            gas: 0,
            sourceAddress: callTwiceL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _incrementCallData()
        });
        calls[1] = calls[0];

        StateUpdate[] memory deltas = new StateUpdate[](1);
        deltas[0] = StateUpdate({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-multi-call-twiceL2"),
            etherDelta: 0
        });

        bytes32 ccTop = _l1CallHash(counterL1, callTwiceL2);
        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, ccTop);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));
        rh = RollingHashBuilder.appendCallBegin(rh, ccTop);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(2)));

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateUpdates: deltas,
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh,
            success: true,
            returnData: ""
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
        address counterProxy = getOrCreateProxy(IEEZ(managerAddr), counterL1Addr, MAINNET_ROLLUP_ID);
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
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterProxy = vm.envAddress("COUNTER_PROXY_L2");
        address callTwiceL2 = vm.envAddress("CALL_TWICE_L2");

        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2"))
            .loadExecutionTable(_l2Entries(counterL1Addr, callTwiceL2), noL2StaticEntries());
        (uint256 first, uint256 second) = CallTwice(callTwiceL2).callCounterTwice(counterProxy);

        console.log("done");
        console.log("first=%s second=%s", first, second);
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode: postBatch with the immediate L2Tx entry on L1.
/// @dev A leading zero-hash entry MUST be covered by `immediateEntryCount`
///      (`ImmediateCountStrandsLeadingL2Tx`), so it executes inline during `postAndVerifyBatch`.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L1, CALL_TWICE_L2
contract Execute is Script, MultiCallTwiceL2Actions {
    function run() external {
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"),
                    L2_ROLLUP_ID,
                    _l1Entries(counterL1, vm.envAddress("CALL_TWICE_L2")),
                    noStaticEntries()
                )
            );

        console.log("done");
        console.log("L1 counterL1=%s", Counter(counterL1).counter());
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
        _printL1Table(l1);
        _printL2Table(l2);

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
