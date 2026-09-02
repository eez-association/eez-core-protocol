// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {RollupUpdate, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {
    Counter,
    CounterAndProxy,
    ICounterView,
    StaticReadCounter
} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    getOrCreateProxy,
    crossChainCallHash,
    crossChainCallHashL2Out,
    crossChainCallHashStatic,
    expectedL1toL2Hash,
    noL2Calls,
    noL2StaticEntries,
    noStaticEntries,
    immediateSingleRollupBatch,
    RollingHashBuilder
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  NestedStaticCounterL2 scenario — L2-starting, nested static read at depth 2:
//  L2 -> L1 -> L2 -> STATIC read of L1, all inside ONE open frame
//
//  Topology: CounterL1 on L1 (value 1 after deploy) is the static-read target;
//  StaticReadCounter on L2 reads it through the L2-side proxy; CAP on L1
//  targets the L1-side proxy of the reader; alice on L2 triggers CAP through
//  its L2-side proxy.
//
//  Flow: alice -> capProxyL2.incrementProxy()  (ONE outgoing L2->L1 call)
//    -> CAP runs on L1 inside the immediate L2Tx entry, increments its counter,
//       and reentrant-calls readerL2.increment() back on L2
//       (expectedL1ToL2Calls[0], cached return abi.encode(1))
//    -> on L2, that reentry executes from the SAME source entry's
//       incomingCalls; during it readerL2 STATICCALLs
//       counterL1ProxyL2.counter()
//       -> STATIC-kind row of the entry's expectedOutgoingCalls, keyed
//          keccak(staticCcHash, rollingHash-at-fire) -> cached abi.encode(1)
//
//  L2 view (ExecuteL2): the user tx consumes ONE outgoing entry; the reader's
//  increment executes from its incomingCalls, and the static read resolves from
//  its unified table — no second L2 tx, no static pool entry.
//  L1 view (Execute): 1 zero-hash L2Tx entry — l2ToL1Calls[0] runs
//  CAP.incrementProxy(); its readerL2 reentry resolves from
//  expectedL1ToL2Calls[0] (cached 1), and that frame's OWN sub-array carries
//  the reader's static read with isStatic = true — `_processNCalls` EXECUTES
//  it for REAL (STATICCALL through readerProxyL1 into the live CounterL1)
//  inside the NESTED frame, folding the same staticCcHash digest the L2
//  STATIC row keys on, with the real returndata.
//
//  Final state: L1 CAP.counter == 1, CAP.targetCounter == 1, CounterL1 == 1;
//               L2 readerL2.counter == 1, readerL2.lastRead == 1.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedStaticL2Actions {
    function _incrementProxyData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
    }

    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(StaticReadCounter.increment.selector);
    }

    /// Calldata of the reader's STATICCALL: Counter's auto-generated `counter()` getter,
    /// referenced through `ICounterView` (compile-checked — `Counter` implements it).
    function _counterCallData() internal pure returns (bytes memory) {
        return abi.encodeCall(ICounterView.counter, ());
    }

    /// Trigger key: alice's call LEAVES the L2 through capProxyL2, so the source entry is
    /// keyed with the L2-outgoing hash (callGas 0 — the devnet deploys useGasLeft = false).
    function _outgoingHash(address capL1, address alice) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(alice, L2_ROLLUP_ID, capL1, MAINNET_ROLLUP_ID, 0, _incrementProxyData());
    }

    /// L1 top-level call hash: CAP.incrementProxy() executes ON L1 (target rollup = MAINNET).
    function _l1TopCallHash(address capL1, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(false, alice, L2_ROLLUP_ID, capL1, MAINNET_ROLLUP_ID, 0, _incrementProxyData());
    }

    /// Inner L1->L2 reentry (CAP -> readerL2): the same digest folds L1's NESTED_BEGIN and
    /// the CALL_BEGIN of its execution inside the L2 source entry.
    function _innerHash(address readerL2, address capL1) internal pure returns (bytes32) {
        return crossChainCallHash(false, capL1, MAINNET_ROLLUP_ID, readerL2, L2_ROLLUP_ID, 0, _incrementData());
    }

    /// Nested static read key (readerL2 -> CounterL1): isStatic = true, source rollup = the
    /// L2's own id; static keys never fold gas.
    function _staticHash(address counterL1, address readerL2) internal pure returns (bytes32) {
        return crossChainCallHashStatic(readerL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _counterCallData());
    }

    /// The user tx's ONE outgoing entry. CAP's nested reader call rides this same open frame
    /// (incomingCalls), and the reader's static read resolves from this entry's unified table.
    function _l2Entries(
        address counterL1,
        address readerL2,
        address capL1,
        address alice
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 key = _outgoingHash(capL1, alice);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: capL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: readerL2,
            value: 0,
            data: _incrementData()
        });

        bytes32 rh = RollingHashBuilder.entryBeginL2(key);
        rh = RollingHashBuilder.appendCallBegin(rh, _innerHash(readerL2, capL1));
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
            proxyEntryHash: key,
            incomingCalls: calls,
            expectedOutgoingCalls: nested,
            rollingHash: rh,
            success: true,
            returnData: "" // incrementProxy returns void
        });
    }

    /// The complete L2 transaction as ONE zero-hash L2Tx entry on L1. The reentrant frame's
    /// own sub-array carries the reader's static read (isStatic = true), EXECUTED for real
    /// against the live CounterL1 while the frame resolves.
    function _l1Entries(
        address counterL1,
        address readerL2,
        address capL1,
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
            newRoot: keccak256("l2-state-after-nested-static-l2"),
            etherDelta: 0
        });

        // The L2Tx entry's top-level call: CAP.incrementProxy() runs on L1, sourced at alice on L2.
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: capL1,
            value: 0,
            data: _incrementProxyData()
        });

        // The frame's own sub-call: the reader's static read, executed ON L1 via STATICCALL.
        L2ToL1Call[] memory frameCalls = new L2ToL1Call[](1);
        frameCalls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: readerL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _counterCallData()
        });

        bytes32 ccInner = _innerHash(readerL2, capL1);

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        rh = RollingHashBuilder.appendCallBegin(rh, _l1TopCallHash(capL1, alice));
        bytes32 rhFire = rh; // CAP's reentry to the reader fires here
        rh = RollingHashBuilder.appendNestedBegin(rh, ccInner);
        // Inside the committing frame: the real static read of CounterL1.
        rh = RollingHashBuilder.appendCallBegin(rh, _staticHash(counterL1, readerL2));
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1))); // the REAL CounterL1 value
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, ""); // incrementProxy returns void

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(ccInner, rhFire),
            l2ToL1Calls: frameCalls,
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltas,
            proxyEntryHash: bytes32(0), // pure L2 tx — executed as an immediate L2Tx
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys — four phases (each needs the previous one's address):
//    1. Deploy (L1) — CounterL1, the static-read target, set to 1.
//    2. DeployL2 (L2) — L2-side proxy for CounterL1 + the reader targeting it.
//    3. Deploy2 (L1) — L1-side proxy for the reader + CAP targeting it.
//    4. DeployL2Trigger (L2) — L2-side proxy for CAP (the user-tx target).
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
/// Outputs: READER_PROXY_L1, CAP_L1
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address readerL2Addr = vm.envAddress("READER_L2");

        vm.startBroadcast();
        address readerProxyL1 = getOrCreateProxy(IEEZ(rollupsAddr), readerL2Addr, L2_ROLLUP_ID);
        CounterAndProxy cap = new CounterAndProxy(Counter(readerProxyL1));
        output("READER_PROXY_L1", readerProxyL1);
        output("CAP_L1", address(cap));
        vm.stopBroadcast();
    }
}

/// Env: MANAGER_L2, CAP_L1
/// Outputs: CAP_PROXY_L2
contract DeployL2Trigger is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address capL1Addr = vm.envAddress("CAP_L1");

        vm.startBroadcast();
        address capProxyL2 = getOrCreateProxy(IEEZ(managerAddr), capL1Addr, MAINNET_ROLLUP_ID);
        output("CAP_PROXY_L2", capProxyL2);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — local mode: loadExecutionTable + alice's single trigger tx. The nested
///        reader call executes inside that trigger's source entry; the reader's static read
///        resolves from the entry's unified table.
/// Env: MANAGER_L2, COUNTER_L1, READER_L2, CAP_L1, CAP_PROXY_L2
contract ExecuteL2 is Script, NestedStaticL2Actions {
    function run() external {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        StaticReadCounter reader = StaticReadCounter(vm.envAddress("READER_L2"));
        address capL1Addr = vm.envAddress("CAP_L1");
        address capProxyL2 = vm.envAddress("CAP_PROXY_L2");

        vm.startBroadcast();
        address alice = msg.sender;

        EEZL2(vm.envAddress("MANAGER_L2"))
            .loadExecutionTable(_l2Entries(counterL1Addr, address(reader), capL1Addr, alice), noL2StaticEntries());
        (bool ok,) = capProxyL2.call(_incrementProxyData());
        require(ok, "outgoing call failed");

        require(reader.lastRead() == 1, "nested static read returned wrong value");
        require(reader.counter() == 1, "reader did not run");
        console.log("done");
        console.log("readerL2.lastRead=%s (expected 1)", reader.lastRead());
        console.log("readerL2.counter=%s (expected 1)", reader.counter());
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode: postAndVerifyBatch with the single immediate L2Tx entry.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L1, READER_L2, CAP_L1
contract Execute is Script, NestedStaticL2Actions {
    function run() external {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address readerL2Addr = vm.envAddress("READER_L2");
        CounterAndProxy cap = CounterAndProxy(vm.envAddress("CAP_L1"));

        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"),
                    L2_ROLLUP_ID,
                    _l1Entries(counterL1Addr, readerL2Addr, address(cap), msg.sender),
                    noStaticEntries()
                )
            );

        require(cap.counter() == 1, "CAP did not run");
        require(cap.targetCounter() == 1, "cached nested return mismatch");
        // The static row's cached value must match the real L1 producer.
        require(Counter(counterL1Addr).counter() == 1, "CounterL1 not at 1");
        console.log("done");
        console.log("cap.counter=%s (expected 1)", cap.counter());
        console.log("cap.targetCounter=%s (expected 1)", cap.targetCounter());
        console.log("counterL1=%s (expected 1)", Counter(counterL1Addr).counter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode: user tx fields for the L2 trigger
/// Env: CAP_PROXY_L2
contract ExecuteNetworkL2 is Script, NestedStaticL2Actions {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("CAP_PROXY_L2"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(_incrementProxyData()));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, NestedStaticL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "CounterL1";
        if (a == vm.envAddress("READER_L2")) return "StaticReadCounter(L2)";
        if (a == vm.envAddress("CAP_L1")) return "CAP(L1)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == StaticReadCounter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        if (sel == ICounterView.counter.selector) return "counter";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address readerL2Addr = vm.envAddress("READER_L2");
        address capL1Addr = vm.envAddress("CAP_L1");
        // The trigger source is the script broadcaster EOA acting as alice.
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, readerL2Addr, capL1Addr, alice);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, readerL2Addr, capL1Addr, alice);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        _printL1CallHashes(l1); // zero-hash entry — prints nothing; verification routes via EXPECTED_L1_HASHES
        _printL2CallHashes(l2);
        _printL1Table(l1);
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 L2Tx entry, 1 call + 1 nested with 1 REAL static read) ===");
        _logEntry(0, l1[0]);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 outgoing entry, 1 nested call + 1 STATIC row) ===");
        _logL2Entry(0, l2[0]);
    }
}
