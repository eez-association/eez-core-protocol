// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {RollupUpdate, L2ToL1Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, ICounterView, StaticReadCounter} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    getOrCreateProxy,
    crossChainCallHash,
    crossChainCallHashStatic,
    expectedL1toL2Hash,
    noNestedActions,
    noL2Calls,
    noL2StaticEntries,
    noStaticEntries,
    immediateSingleRollupBatch,
    RollingHashBuilder,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  NestedStaticCounter scenario — L1-starting, NESTED static read:
//  L1 -> L2 -> STATIC read of L1, all inside one delivery frame
//
//  Topology: CounterL1 on L1 (incremented to 1 during deploy) is the
//  static-read target; StaticReadCounter on L2 reads it through the L2-side
//  proxy; alice on L1 triggers the reader through its L1-side proxy.
//
//  L1 side (Execute):
//    1. postAndVerifyBatch loads ONE deferred proxy-keyed entry with
//       precomputed return abi.encode(1); its l2ToL1Calls[0] is the reader's
//       static read with isStatic = true
//    2. alice -> readerProxyL1.increment()   (the ONE user trigger)
//       -> EEZ.executeCrossChainCall consumes the entry:
//          _processNCalls EXECUTES the read for REAL — STATICCALL through
//          readerProxyL1 into the live CounterL1 — and folds
//          CALL_BEGIN(staticCcHash) / CALL_END(true, abi.encode(1)) with the
//          real returndata; then the entry returns cached abi.encode(1)
//
//  L2 side (ExecuteL2): SYSTEM drives executeIncomingCrossChainCall:
//    incomingCalls[0] = (alice on L1 -> readerL2.increment())
//      readerL2 STATICCALLs counterL1ProxyL2.counter()   [inside the execution]
//        -> EEZL2.staticCrossChainCall -> the entry's unified
//           expectedOutgoingCalls table, STATIC-kind row keyed
//           keccak(staticCcHash, rollingHash-at-fire) -> cached abi.encode(1)
//      readerL2.lastRead = 1; increment() returns 1
//      -> CALL_END(true, abi.encode(1))
//
//  The cross-chain tie for the read: the L1-executed static call and the L2
//  STATIC row fold the SAME staticCcHash digest (isStatic folded, source =
//  readerL2 at the L2's rollup id, callGas 0), and the L2 row's cached value
//  must equal what the real CounterL1 returns on L1. On the reader's chain a
//  static read folds NOTHING into the rolling hash — its position is enforced
//  by the row key, its value by the surrounding CALL_END retData.
//
//  Final state: L2 readerL2.counter == 1, readerL2.lastRead == 1;
//               L1 CounterL1.counter == 1 (unchanged by the flow).
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedStaticActions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(StaticReadCounter.increment.selector);
    }

    /// Calldata of the reader's STATICCALL: Counter's auto-generated `counter()` getter,
    /// referenced through `ICounterView` (compile-checked — `Counter` implements it).
    function _counterCallData() internal pure returns (bytes memory) {
        return abi.encodeCall(ICounterView.counter, ());
    }

    /// Inbound call key (alice on L1 -> readerL2): same digest on both sides — L1's
    /// executeCrossChainCall and L2's executeIncomingCrossChainCall both fold
    /// targetRollupId = L2_ROLLUP_ID and callGas 0.
    function _callHash(address readerL2, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(false, alice, MAINNET_ROLLUP_ID, readerL2, L2_ROLLUP_ID, 0, _incrementCallData());
    }

    /// Nested static read key (readerL2 -> CounterL1): EEZL2's static path folds
    /// isStatic = true and source rollup = its OWN id; static keys never fold gas.
    function _staticHash(address counterL1, address readerL2) internal pure returns (bytes32) {
        return crossChainCallHashStatic(readerL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _counterCallData());
    }

    /// Single L1 entry — the SOURCE side. The reader's static read of CounterL1 EXECUTES for
    /// real here: l2ToL1Calls[0] carries isStatic = true, so `_processNCalls` dispatches it
    /// via STATICCALL against the live CounterL1 and folds the real returndata — the same
    /// staticCcHash digest the L2 STATIC row keys on.
    function _l1Entries(
        address counterL1,
        address readerL2,
        address alice
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        RollupUpdate[] memory deltas = new RollupUpdate[](1);
        deltas[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-nested-static"),
            etherDelta: 0
        });

        // The read as it executes ON L1: read-only dispatch, sourced at the reader on L2.
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: readerL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _counterCallData()
        });

        bytes32 proxyEntryHash = _callHash(readerL2, alice);
        bytes32 rh = RollingHashBuilder.entryBegin(deltas, proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, _staticHash(counterL1, readerL2));
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1))); // the REAL CounterL1 value

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltas,
            proxyEntryHash: proxyEntryHash,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    /// Single L2 entry — the DESTINATION side, with the STATIC-kind row in the unified
    /// reentrant table serving the reader's in-execution read of CounterL1.
    function _l2Entries(
        address counterL1,
        address readerL2,
        address alice
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: readerL2,
            value: 0,
            data: _incrementCallData()
        });

        bytes32 proxyEntryHash = _callHash(readerL2, alice);
        // L2 folds the same digest into the inbound call's CALL_BEGIN (targetRollupId = own id).
        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, proxyEntryHash);
        bytes32 rhFire = rh; // the reader's static read of CounterL1 fires here
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(_staticHash(counterL1, readerL2), rhFire),
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: bytes32(0), // no static sub-calls (empty array folds 0)
            success: true,
            returnData: abi.encode(uint256(1))
        });

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: proxyEntryHash,
            incomingCalls: calls,
            expectedOutgoingCalls: nested,
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys — three phases (each needs the previous one's address):
//    1. Deploy (L1) — CounterL1, the static-read target, set to 1.
//    2. DeployL2 (L2) — L2-side proxy for CounterL1 + the reader targeting it.
//    3. Deploy2 (L1) — L1-side proxy for the reader (the user-tx target).
// ═══════════════════════════════════════════════════════════════════════

/// Outputs: COUNTER_L1
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        counterL1.increment();
        output("COUNTER_L1", address(counterL1));
        vm.stopBroadcast();
    }
}

/// Env: MANAGER_L2, COUNTER_L1
/// Outputs: COUNTER_L1_PROXY_L2, READER_L2
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        address counterProxyL2 = getOrCreateProxy(IEEZ(managerAddr), counterL1Addr, MAINNET_ROLLUP_ID);
        StaticReadCounter reader = new StaticReadCounter(Counter(counterProxyL2));
        output("COUNTER_L1_PROXY_L2", counterProxyL2);
        output("READER_L2", address(reader));
        vm.stopBroadcast();
    }
}

/// Env: ROLLUPS, READER_L2
/// Outputs: READER_PROXY_L1
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address readerL2Addr = vm.envAddress("READER_L2");

        vm.startBroadcast();
        address readerProxyL1 = getOrCreateProxy(IEEZ(rollupsAddr), readerL2Addr, L2_ROLLUP_ID);
        output("READER_PROXY_L1", readerProxyL1);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — local mode: system-driven simulation of the inbound call.
/// @dev Runs on L2 (the local deployer is SYSTEM_ADDRESS). The reader's static read
///      resolves from the entry's unified table while the delivery executes.
/// Env: MANAGER_L2, COUNTER_L1, READER_L2
contract ExecuteL2 is Script, NestedStaticActions {
    function run() external {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        StaticReadCounter reader = StaticReadCounter(vm.envAddress("READER_L2"));

        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2"))
            .executeIncomingCrossChainCall(_l2Entries(counterL1Addr, address(reader), msg.sender), noL2StaticEntries());

        require(reader.lastRead() == 1, "nested static read returned wrong value");
        require(reader.counter() == 1, "reader did not run");
        console.log("done");
        console.log("readerL2.lastRead=%s (expected 1)", reader.lastRead());
        console.log("readerL2.counter=%s (expected 1)", reader.counter());
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode: postAndVerifyBatch + the user trigger, mined in one block.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L1, READER_L2, READER_PROXY_L1
contract Execute is Script, NestedStaticActions {
    function run() external {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address readerL2Addr = vm.envAddress("READER_L2");
        address readerProxyL1 = vm.envAddress("READER_PROXY_L1");

        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"),
                    L2_ROLLUP_ID,
                    _l1Entries(counterL1Addr, readerL2Addr, msg.sender),
                    noStaticEntries()
                )
            );
        (bool ok, bytes memory ret) = readerProxyL1.call(_incrementCallData());
        require(ok, "trigger call failed");
        require(abi.decode(ret, (uint256)) == 1, "cached return mismatch");
        // The static row's cached value must match the real L1 producer.
        require(Counter(counterL1Addr).counter() == 1, "CounterL1 not at 1");

        console.log("done");
        console.log("counterL1=%s (expected 1)", Counter(counterL1Addr).counter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — network mode: user tx fields for the L1 trigger
/// Env: READER_PROXY_L1
contract ExecuteNetwork is Script, NestedStaticActions {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("READER_PROXY_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(_incrementCallData()));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, NestedStaticActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("READER_L2")) return "StaticReadCounter(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == StaticReadCounter.increment.selector) return "increment";
        if (sel == ICounterView.counter.selector) return "counter";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address readerL2Addr = vm.envAddress("READER_L2");
        // The trigger source is the script broadcaster EOA acting as alice.
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, readerL2Addr, alice);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, readerL2Addr, alice);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        _printL1CallHashes(l1);
        _printL2CallHashes(l2);
        _printL1Table(l1);
        HashStep[][] memory steps = new HashStep[][](1); // mirrors _l1Entries' fold chain
        steps[0] = new HashStep[](2);
        steps[0][0] = RollingHashBuilder.stepCallBegin(_staticHash(counterL1Addr, readerL2Addr));
        steps[0][1] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(1)));
        _printL1Steps(l1, steps);
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 proxy-keyed entry, 1 REAL static read call) ===");
        _logEntry(0, l1[0]);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 delivery entry, 1 call + 1 STATIC row) ===");
        _logL2Entry(0, l2[0]);
    }
}
