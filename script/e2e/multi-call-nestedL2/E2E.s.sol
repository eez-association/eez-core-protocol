// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {
    EEZ,
    ProofSystemBatchPerVerificationEntries,
    ExpectedStateRootPerRollup,
    RollupIdWithProofSystems
} from "../../../src/EEZ.sol";
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
    expectedL1toL2Hash,
    noStaticLookups,
    noNestedActions,
    noL2Calls,
    noL2StaticLookups,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  MultiCallNestedL2 — L2-side mirror of multi-call-nested
//
//  Entry has 2 calls, both invoke CAP.incrementProxy(). Each call
//  triggers one nested call (CAP→counterProxy→_consumeNestedAction).
//
//  Rolling hash: CALL_BEGIN(1) NESTED_BEGIN(1) NESTED_END(1) CALL_END(1,true,"")
//               CALL_BEGIN(2) NESTED_BEGIN(2) NESTED_END(2) CALL_END(2,true,"")
//
//  After execution: CAP.counter()=2, CAP.targetCounter()=2
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract MultiCallNestedL2Actions {
    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _incrementProxyData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
    }

    /// @dev Inner action hash: CAP reentrant-calls counterProxy (Counter MAINNET) on L2
    ///      (outbound L2->L1, sourceRollupId=L2).
    function _innerActionHash(address counterL1, address cap) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, counterL1, 0, _incrementData(), cap, L2_ROLLUP_ID);
    }

    /// @dev Outer action hash (proxyEntryHash): alice calls capL1Proxy (CAP MAINNET) on L2.
    function _outerActionHash(address cap, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, cap, 0, _incrementProxyData(), alice, L2_ROLLUP_ID);
    }

    /// @dev L2 incoming top-level CALL_BEGIN hash: alice -> cap executed ON L2 (targetRollupId=L2).
    function _l2IncomingHash(address cap, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, cap, 0, _incrementProxyData(), alice, MAINNET_ROLLUP_ID);
    }

    /// @dev L1 mirror rolling hash for a single entry — one top-level Counter.increment().
    function _expectedRollingHashL1(StateDelta[] memory deltas, address counterL1, address cap, uint256 retVal)
        internal
        pure
        returns (bytes32 h)
    {
        bytes32 ccTop = crossChainCallHash(MAINNET_ROLLUP_ID, counterL1, 0, _incrementData(), cap, L2_ROLLUP_ID);
        h = RollingHashBuilder.entryBegin(deltas, bytes32(0));
        h = RollingHashBuilder.appendCallBegin(h, ccTop);
        h = RollingHashBuilder.appendCallEnd(h, true, abi.encode(retVal));
    }

    /// @dev L1 mirror entries. Two system-driven entries (proxyEntryHash=0), each draining
    ///      one Counter.increment() call on L1. Each call surfaces on L1 as a top-level
    ///      cross-chain invocation from CAP (on L2) to Counter (on MAINNET); CALL_BEGIN folds
    ///      targetRollupId=MAINNET. Each entry is drained by one executeL2Txs call.
    function _l1Entries(address counterL1, address cap) internal pure returns (ExecutionEntry[] memory entries) {
        L2ToL1Call memory innerCall = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: cap,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _incrementData()
        });
        L2ToL1Call[] memory calls0 = new L2ToL1Call[](1);
        calls0[0] = innerCall;
        L2ToL1Call[] memory calls1 = new L2ToL1Call[](1);
        calls1[0] = innerCall;

        StateDelta[] memory deltas0 = new StateDelta[](1);
        deltas0[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-mid"),
            etherDelta: 0
        });
        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-state-mid"),
            newState: keccak256("l2-state-final"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](2);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas0,
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls0,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: _expectedRollingHashL1(deltas0, counterL1, cap, 1),
            success: true,
            returnData: abi.encode(uint256(1))
        });
        entries[1] = ExecutionEntry({
            stateDeltas: deltas1,
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls1,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: _expectedRollingHashL1(deltas1, counterL1, cap, 2),
            success: true,
            returnData: abi.encode(uint256(2))
        });
    }

    /// @dev L2 anchor entry: 2 top-level incoming calls, each firing 1 nested outbound reentry.
    ///      Rolling hash threads CALL_BEGIN(ccTop) -> NESTED_BEGIN(ccInner) -> NESTED_END ->
    ///      CALL_END(true, "") twice; each nested key uses the live rolling hash at its fire point,
    ///      so the two ExpectedOutgoingCrossChainCalls get distinct keys despite identical ccInner.
    /// NOTE: PENDING EEZL2 — L2 rolling-hash seed/fold convention unconfirmed; re-verify when EEZL2.sol lands.
    function _l2Entries(address counterL1, address cap, address alice)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        CrossChainCall memory incoming = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: cap,
            value: 0,
            data: _incrementProxyData()
        });
        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = incoming;
        calls[1] = incoming;

        bytes32 ccTop = _l2IncomingHash(cap, alice);
        bytes32 ccInner = _innerActionHash(counterL1, cap);

        bytes32 rh = RollingHashBuilder.entryBeginL2(_outerActionHash(cap, alice));
        // call[0]
        rh = RollingHashBuilder.appendCallBegin(rh, ccTop);
        bytes32 rhFire0 = rh;
        rh = RollingHashBuilder.appendNestedBegin(rh, ccInner);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");
        // call[1]
        rh = RollingHashBuilder.appendCallBegin(rh, ccTop);
        bytes32 rhFire1 = rh;
        rh = RollingHashBuilder.appendNestedBegin(rh, ccInner);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](2);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(ccInner, rhFire0),
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });
        nested[1] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(ccInner, rhFire1),
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(2))
        });

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: _outerActionHash(cap, alice),
            incomingCalls: calls,
            expectedOutgoingCalls: nested,
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title Deploy — on L1, deploy Counter (address reference only)
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — on L2, create proxies + deploy CAP
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        // Proxy for Counter@MAINNET on L2
        address counterProxy;
        try manager.createCrossChainProxy(counterL1Addr, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = manager.computeCrossChainProxyAddress(counterL1Addr, MAINNET_ROLLUP_ID);
        }

        // Deploy CAP on L2, pointing to counterProxy
        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        // Proxy for CAP@MAINNET on L2 (the trigger point alice calls)
        address capL1Proxy;
        try manager.createCrossChainProxy(address(cap), MAINNET_ROLLUP_ID) returns (address p) {
            capL1Proxy = p;
        } catch {
            capL1Proxy = manager.computeCrossChainProxyAddress(address(cap), MAINNET_ROLLUP_ID);
        }

        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        console.log("COUNTER_AND_PROXY_L2=%s", address(cap));
        console.log("CAP_L1_PROXY=%s", capL1Proxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — loadExecutionTable + trigger via capL1Proxy in same block
contract ExecuteL2 is Script, MultiCallNestedL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address capL1Proxy = vm.envAddress("CAP_L1_PROXY");

        vm.startBroadcast();
        address alice = msg.sender;
        console.log("ExecuteL2: alice=%s cap=%s capL1Proxy=%s", alice, capAddr, capL1Proxy);

        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterL1Addr, capAddr, alice), noL2StaticLookups());
        console.log("ExecuteL2: loadExecutionTable done");

        // Trigger: alice calls capL1Proxy.incrementProxy()
        (bool ok,) = capL1Proxy.call(abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector));
        require(ok, "outer call failed");
        console.log("ExecuteL2: trigger done");

        console.log("done");
        console.log("cap.counter=%s", CounterAndProxy(capAddr).counter());
        console.log("cap.targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

/// @notice L1-side batcher: postBatch (deferred, 2 entries) + executeL2Txs twice in one tx.
/// @dev Two entries → two drains. Each executeL2Txs(rollupId) pops one entry from the L2
///      rollup's queue, advancing the cursor. immediateEntryCount=0 keeps both
///      entries in the deferred queue.
contract DeferredL2TXBatcherTwice {
    function execute(
        EEZ rollups,
        address proofSystem,
        uint64 rollupId,
        ExecutionEntry[] calldata entries,
        StaticLookup[] calldata staticLookups
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
        rps[0] = RollupIdWithProofSystems({rollupId: rollupId, proofSystemIndexes: psIdx});

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            expectedStateRootPerRollup: new ExpectedStateRootPerRollup[](0),
            entries: entries,
            staticLookups: staticLookups,
            immediateEntryCount: 0,
            immediateStaticLookupCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs,
            blockNumber: 0
        });
        rollups.postAndVerifyBatch(batch);
        rollups.executeL2Txs(rollupId);
        rollups.executeL2Txs(rollupId);
    }
}

/// @title Execute - L1-side mirror. Drains the two L2-anchored inner Counter.increment()
///        calls on the real L1 Counter via two executeL2Txs invocations.
contract Execute is Script, MultiCallNestedL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address cap = vm.envAddress("COUNTER_AND_PROXY_L2");

        vm.startBroadcast();
        DeferredL2TXBatcherTwice batcher = new DeferredL2TXBatcherTwice();
        batcher.execute(EEZ(rollupsAddr), proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL1, cap), noStaticLookups());

        console.log("Execute: done");
        console.log("L1 counter=%s (expected 2)", Counter(counterL1).counter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode output
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("CAP_L1_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, MultiCallNestedL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "Counter";
        if (a == vm.envAddress("COUNTER_AND_PROXY_L2")) return "CounterAndProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY_L2");
        address alice = msg.sender;

        L2ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, capAddr, alice);
        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, capAddr);
        bytes32 l2Hash = _entryHash(l2[0]);
        bytes32 l1Hash0 = _entryHash(l1[0]);
        bytes32 l1Hash1 = _entryHash(l1[1]);

        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log(string.concat("EXPECTED_L1_HASHES=[", vm.toString(l1Hash0), ",", vm.toString(l1Hash1), "]"));
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 2 calls, 2 nested) ===");
        _logL2Entry(0, l2[0]);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (2 entries, 1 call each - L2 mirror on L1) ===");
        _logEntry(0, l1[0]);
        _logEntry(1, l1[1]);
    }
}
