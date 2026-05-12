// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {StateDelta, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry, LookupCall} from "../../../src/interfaces/IEEZ.sol";
import {Counter} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noLookupCalls,
    noNestedActions,
    noCalls,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  RevertCounterL2 — mirror of revertCounter on the L2 side, two-sided.
//
//  Models the canonical use case in the opposite direction: an L1→L2 cross-
//  chain call whose state effects must be rolled back on L2 even though
//  the destination call itself succeeds. The L2 manager's revertSpan
//  mechanism is identical to L1's: self-call into executeInContext, the
//  inner span runs the call (state mutates, success=true), then reverts
//  with ContextResult to roll back EVM state while the rolling hash and
//  cursors propagate out.
//
//  L2 side (ExecuteL2):
//    1. loadExecutionTable installs ONE entry with calls[0].revertSpan=1.
//    2. Alice calls counterProxy (L2 proxy for Counter on L1) — consumes
//       the entry by matching actionHash.
//    3. _processNCalls sees revertSpan=1, self-calls executeInContext(1).
//       Counter on L2 is incremented inside the span; rolling hash records
//       CALL_END(true, abi.encode(1)).
//    4. executeInContext reverts → state rolled back, hash/cursors restored
//       from ContextResult.
//    5. Net effect on L2: Counter.counter() == 0, even though the proof
//       commits to a successful call.
//
//  L1 side (Execute) — system-driven mirror:
//    1. postAndVerifyBatch loads a deferred entry
//       (proxyEntryHash=0; transientExecutionEntryCount=0) routed to the L2
//       rollup queue. calls[0] targets the real Counter on L1 with
//       revertSpan=1, source=(alice, L2_ROLLUP_ID).
//    2. executeL2TX(L2_ROLLUP_ID) drains the entry; _processNCalls handles
//       revertSpan exactly as L2 does — the inner span successfully calls
//       Counter on L1, returns abi.encode(1), and executeInContext reverts.
//    3. Net effect on L1: Counter.counter() == 0, rolling hash records
//       CALL_END(true, abi.encode(1)), entry verified.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertL2Actions {
    using RollingHashBuilder for bytes32;

    function _successReturnData() internal pure returns (bytes memory) {
        return abi.encode(uint256(1));
    }

    /// @dev Outer action hash: alice calls counterProxy (Counter@L1) on L2.
    function _outerActionHash(address counterL1, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(
            MAINNET_ROLLUP_ID, counterL1, 0, abi.encodeWithSelector(Counter.increment.selector), alice, L2_ROLLUP_ID
        );
    }

    /// @dev Rolling hash: CALL_BEGIN(1) → CALL_END(1, true, abi.encode(1)).
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendCallEnd(1, true, _successReturnData());
    }

    function _l2Entries(address counterL2, address counterL1, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        // Inner call: a Counter.increment() on L2 wrapped in revertSpan=1 to
        // demonstrate the EVM state effect being rolled back while the rolling
        // hash still records the successful outcome. sourceRollupId mirrors the
        // entry's outer source (Alice on L2) per the spec convention.
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 1
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: _outerActionHash(counterL1, alice),
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            callCount: 1,
            returnData: "",
            rollingHash: _expectedRollingHash()
        });
    }

    /// @dev Single L1 entry — destination-side mirror, system-driven (proxyEntryHash=0).
    /// `L2ToL1Calls[0]` targets the real Counter on L1 with revertSpan=1; the inner
    /// span increments it, returns abi.encode(1), and executeInContext rolls back state.
    /// Source matches the L2-anchored entry: (alice, L2_ROLLUP_ID).
    function _l1Entries(address counterL1, address counterL2, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 1
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            callCount: 1,
            returnData: "",
            rollingHash: _expectedRollingHash()
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title Deploy — on L1, deploy Counter (address reference for proxy)
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL1 = new Counter();
        console.log("COUNTER_L1=%s", address(counterL1));
        vm.stopBroadcast();
    }
}

/// @title DeployL2 — on L2, deploy Counter (force-revert target) + create trigger proxy
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        Counter counterL2 = new Counter();

        // Trigger proxy: proxy for (Counter@L1, MAINNET_ROLLUP_ID) on L2
        address counterProxy;
        try manager.createCrossChainProxy(counterL1, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = manager.computeCrossChainProxyAddress(counterL1, MAINNET_ROLLUP_ID);
        }

        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — loadExecutionTable + trigger in same block
contract ExecuteL2 is Script, RevertL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address counterProxy = vm.envAddress("COUNTER_PROXY_L2");

        vm.startBroadcast();
        address alice = msg.sender;
        console.log("ExecuteL2: alice=%s counterProxy=%s", alice, counterProxy);

        EEZL2(managerAddr).loadExecutionTable(_l2Entries(counterL2, counterL1, alice), noLookupCalls());
        console.log("ExecuteL2: loadExecutionTable done");

        // Trigger: alice calls counterProxy.increment() — consumes the entry.
        (bool ok,) = counterProxy.call(abi.encodeWithSelector(Counter.increment.selector));
        require(ok, "trigger should succeed (revertSpan rolls back inner state, not outer flow)");

        // Invariant: counter on L2 stays at 0 — increment ran inside the span,
        // returned 1, then state was rolled back by executeInContext's revert.
        uint256 finalCounter = Counter(counterL2).counter();
        require(finalCounter == 0, "revertSpan must roll back successful state changes");

        console.log("ExecuteL2: trigger done");
        console.log("done");
        console.log("counterL2.counter=%s (expected 0 -- state rolled back)", finalCounter);
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode output
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_PROXY_L2");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(Counter.increment.selector)));
    }
}

/// @notice Inline L2-TX batcher — postBatch (deferred) + executeL2TX on L1.
/// @dev Forces transientExecutionEntryCount=0 so the proxyEntryHash=0 entry
///      stays in the deferred queue and is drained by executeL2TX(rollupId).
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
/// @dev Destination-side mirror of the L2-originated cross-chain call. The L1
///      anvil holds the real Counter contract; the deferred entry contains a
///      revertSpan=1 call targeting it. _processNCalls runs Counter.increment()
///      inside executeInContext, which reverts and rolls back the state — net
///      effect: Counter.counter() == 0 on L1.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L1, COUNTER_L2
contract Execute is Script, RevertL2Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        address alice = msg.sender;

        DeferredL2TXBatcher batcher = new DeferredL2TXBatcher();
        batcher.execute(
            EEZ(rollupsAddr), proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL1, counterL2, alice), noLookupCalls()
        );

        uint256 finalCounter = Counter(counterL1).counter();
        require(finalCounter == 0, "revertSpan must roll back successful state changes on L1");

        console.log("done");
        console.log("counterL1.counter=%s (expected 0 -- state rolled back)", finalCounter);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, RevertL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "Counter(L1)";
        if (a == vm.envAddress("COUNTER_L2")) return "Counter(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1 = vm.envAddress("COUNTER_L1");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address alice = msg.sender;

        ExecutionEntry[] memory l2 = _l2Entries(counterL2, counterL1, alice);
        bytes32 l2Hash = _entryHash(l2[0]);

        ExecutionEntry[] memory l1 = _l1Entries(counterL1, counterL2, alice);
        bytes32 l1Hash = _entryHash(l1[0]);

        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2[0].proxyEntryHash));
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call w/ revertSpan=1, force-reverted success) ===");
        _logL2Entry(0, l2[0]);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call w/ revertSpan=1, system-driven mirror) ===");
        _logEntry(0, l1[0]);
    }
}
