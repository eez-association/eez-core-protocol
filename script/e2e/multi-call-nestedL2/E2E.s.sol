// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {StateDelta, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry, LookupCall} from "../../../src/interfaces/IEEZ.sol";
import {Counter, CounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {Action, actionHash, noLookupCalls, noStaticCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  MultiCallNestedL2 — L2-side mirror of multi-call-nested
//
//  Entry has 2 calls, both invoke CAP.incrementProxy(). Each call
//  triggers one nested action (CAP→counterProxy→_consumeNestedAction).
//
//  Rolling hash: CALL_BEGIN(1) NESTED_BEGIN(1) NESTED_END(1) CALL_END(1,true,"")
//               CALL_BEGIN(2) NESTED_BEGIN(2) NESTED_END(2) CALL_END(2,true,"")
//
//  After execution: CAP.counter()=2, CAP.targetCounter()=2
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract MultiCallNestedL2Actions {
    using RollingHashBuilder for bytes32;

    /// @dev Inner action hash: CAP calls counterProxy (Counter@MAINNET) on L2.
    function _innerActionHash(address counterL1, address cap) internal pure returns (bytes32) {
        return actionHash(
            Action({
                targetRollupId: MAINNET_ROLLUP_ID,
                targetAddress: counterL1,
                value: 0,
                data: abi.encodeWithSelector(Counter.increment.selector),
                sourceAddress: cap,
                sourceRollupId: L2_ROLLUP_ID
            })
        );
    }

    /// @dev Outer action hash: alice calls capL1Proxy (CAP@MAINNET) on L2.
    function _outerActionHash(address cap, address alice) internal pure returns (bytes32) {
        return actionHash(
            Action({
                targetRollupId: MAINNET_ROLLUP_ID,
                targetAddress: cap,
                value: 0,
                data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
                sourceAddress: alice,
                sourceRollupId: L2_ROLLUP_ID
            })
        );
    }

    /// @dev Rolling hash: 2 calls, each with 1 nested action
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        // call[0]: CAP.incrementProxy() -> nested[0]
        h = h.appendCallBegin(1);
        h = h.appendNestedBegin(1);
        h = h.appendNestedEnd(1);
        h = h.appendCallEnd(1, true, "");
        // call[1]: CAP.incrementProxy() -> nested[1]
        h = h.appendCallBegin(2);
        h = h.appendNestedBegin(2);
        h = h.appendNestedEnd(2);
        h = h.appendCallEnd(2, true, "");
    }

    /// @dev L1 mirror rolling hash for a single entry — top-level Counter.increment().
    function _expectedRollingHashL1(uint256 retVal) internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendCallEnd(1, true, abi.encode(retVal));
    }

    /// @dev L1 mirror entries. Two system-driven entries (proxyEntryHash=0), each draining
    ///      one Counter.increment() call on L1. Each call surfaces on L1 as a top-level
    ///      cross-chain invocation from CAP (on L2) to Counter (on MAINNET). Each entry is
    ///      drained by one executeL2TX call.
    function _l1Entries(address counterL1, address cap) internal pure returns (ExecutionEntry[] memory entries) {
        L2ToL1Call memory innerCall = L2ToL1Call({
            targetAddress: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: cap,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });
        L2ToL1Call[] memory calls0 = new L2ToL1Call[](1);
        calls0[0] = innerCall;
        L2ToL1Call[] memory calls1 = new L2ToL1Call[](1);
        calls1[0] = innerCall;

        entries = new ExecutionEntry[](2);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: calls0,
            expectedL1ToL2Calls: new ExpectedL1ToL2Call[](0),
            callCount: 1,
            returnData: abi.encode(uint256(1)),
            rollingHash: _expectedRollingHashL1(1)
        });
        entries[1] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: calls1,
            expectedL1ToL2Calls: new ExpectedL1ToL2Call[](0),
            callCount: 1,
            returnData: abi.encode(uint256(2)),
            rollingHash: _expectedRollingHashL1(2)
        });
    }

    function _l2Entries(address counterL1, address cap, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = L2ToL1Call({
            targetAddress: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });
        calls[1] = L2ToL1Call({
            targetAddress: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });

        bytes32 innerHash = _innerActionHash(counterL1, cap);
        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](2);
        nested[0] =
            ExpectedL1ToL2Call({crossChainCallHash: innerHash, callCount: 0, returnData: abi.encode(uint256(1))});
        nested[1] =
            ExpectedL1ToL2Call({crossChainCallHash: innerHash, callCount: 0, returnData: abi.encode(uint256(2))});

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: _outerActionHash(cap, alice),
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            callCount: 2,
            returnData: "",
            rollingHash: _expectedRollingHash()
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

        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterL1Addr, capAddr, alice), noStaticCalls());
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

/// @notice L1-side batcher: postBatch (deferred, 2 entries) + executeL2TX twice in one tx.
/// @dev Two entries → two drains. Each executeL2TX(rollupId) pops one entry from the L2
///      rollup's queue, advancing the cursor. transientExecutionEntryCount=0 keeps both
///      entries in the deferred queue.
contract DeferredL2TXBatcherTwice {
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
        rollups.executeL2TX(rollupId);
    }
}

/// @title Execute - L1-side mirror. Drains the two L2-anchored inner Counter.increment()
///        calls on the real L1 Counter via two executeL2TX invocations.
contract Execute is Script, MultiCallNestedL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address cap = vm.envAddress("COUNTER_AND_PROXY_L2");

        vm.startBroadcast();
        DeferredL2TXBatcherTwice batcher = new DeferredL2TXBatcherTwice();
        batcher.execute(EEZ(rollupsAddr), proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL1, cap), noLookupCalls());

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

        ExecutionEntry[] memory l2 = _l2Entries(counterL1Addr, capAddr, alice);
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
