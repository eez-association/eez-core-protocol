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
//  RevertCounter scenario — exercises L2ToL1Call.revertSpan as a
//  FORCED revert: the destination call SUCCEEDS, but its EVM state effects
//  are rolled back at the protocol layer. Two-sided.
//
//  Models the canonical use case: an L2→L1 cross-chain call that ran
//  successfully on the destination, but its prover output marks it as
//  reverted in the source-chain view of the world (e.g., a higher-level
//  transaction the call was part of was rolled back). When the destination
//  replays the entry, revertSpan=1 forces the state effects to disappear
//  while the rolling hash still commits to (success=true, retData=1).
//
//  L1 side (Execute):
//    1. postAndVerifyBatch loads ONE deferred
//       entry. Its calls[0] targets the real Counter on L1 with
//       revertSpan=1.
//    2. Alice triggers consumption by calling counterProxy (L1 proxy for
//       Counter on L2). Trigger and inner call are independent — the
//       trigger just selects this entry by matching actionHash.
//    3. _processNCalls sees revertSpan=1 → self-calls executeInContext(1).
//       Inside that frame, Counter.increment() runs successfully, returns
//       abi.encode(1), and the rolling hash records CALL_END(true, ...).
//    4. executeInContext reverts with ContextResult, the EVM rolls back
//       the counter increment, and the outer flow restores the rolling
//       hash + cursors from the revert payload.
//    5. Net effect: Counter.counter() == 0 on L1, even though the proof
//       commits to a successful call.
//
//  L2 side (ExecuteL2) — system-driven mirror:
//    1. SYSTEM_ADDRESS calls managerL2.executeIncomingCrossChainCall(
//         counterL2, 0, increment, alice, MAINNET, l2Entries, lookups
//       ) which loads ONE entry whose calls[0] targets the real Counter
//       on L2 with revertSpan=1.
//    2. _processNCalls runs the inner span; Counter on L2 increments,
//       executeInContext reverts, state rolled back.
//    3. Net effect on L2: Counter.counter() == 0, rolling hash commits
//       to CALL_END(true, abi.encode(1)).
//
//  Contrast with revertSpan=0: a naturally-reverting destination already
//  produces (success=false, retData=revertReason) under revertSpan=0, so
//  revertSpan>0 buys nothing for that case. The mechanism only earns its
//  keep when state would otherwise survive — i.e., a forced revert.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertActions {
    using RollingHashBuilder for bytes32;

    /// @dev `Counter.increment()` returns `abi.encode(uint256(1))` for a fresh
    ///      counter. The proxy's `executeOnBehalf` returns the destination's
    ///      raw return bytes via assembly, so the manager sees this exact
    ///      payload as `retData` and hashes it into CALL_END.
    function _successReturnData() internal pure returns (bytes memory) {
        return abi.encode(uint256(1));
    }

    /// @dev Outer action hash: alice calls counterProxy (proxy for Counter@L2) on L1.
    ///      This is just the trigger — it selects which entry to consume.
    function _outerActionHash(address counterL2, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID, counterL2, 0, abi.encodeWithSelector(Counter.increment.selector), alice, MAINNET_ROLLUP_ID
        );
    }

    /// @dev Rolling hash: CALL_BEGIN(1) → CALL_END(1, true, abi.encode(1)).
    ///      The call succeeds inside the isolated context. Its state changes
    ///      are reverted by executeInContext, but the hash records the
    ///      successful outcome.
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendCallEnd(1, true, _successReturnData());
    }

    function _l1Entries(address counterL1, address counterL2, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-forced-revert"),
            etherDelta: 0
        });

        // Inner call: a Counter.increment() on L1 wrapped in revertSpan=1 to
        // demonstrate the EVM state effect being rolled back while the rolling
        // hash still records the successful outcome. sourceRollupId mirrors the
        // entry's outer source (Alice on Mainnet) per the spec convention.
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: counterL1,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 1
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            proxyEntryHash: _outerActionHash(counterL2, alice),
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            callCount: 1,
            returnData: "",
            rollingHash: _expectedRollingHash()
        });
    }

    /// @dev L2 mirror entry — same shape, with the inner call targeting the real
    /// Counter on L2. proxyEntryHash matches the outer trigger that SYSTEM passes
    /// to executeIncomingCrossChainCall (counterL2 destination, alice on Mainnet
    /// as the source). The mirror is independent of the L1 side; it does not need
    /// to share alice with the L1 batcher, since the cryptographic tie is the call
    /// hash of the OUTER call (destination + sourceAddress + sourceRollupId), which
    /// each side computes from its own broadcaster.
    function _l2Entries(address counterL2, address alice) internal pure returns (ExecutionEntry[] memory entries) {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 1
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: _outerActionHash(counterL2, alice),
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

/// @title DeployL2 — deploy a Counter on L2 (address reference for proxy)
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counter = new Counter();
        console.log("COUNTER_L2=%s", address(counter));
        vm.stopBroadcast();
    }
}

/// @title Deploy — on L1, deploy Counter (force-revert target) + create trigger proxy
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        EEZ rollups = EEZ(rollupsAddr);

        Counter counterL1 = new Counter();

        // Trigger proxy: proxy for (Counter@L2, L2_ROLLUP_ID) on L1
        address counterProxy;
        try rollups.createCrossChainProxy(counterL2, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2, L2_ROLLUP_ID);
        }

        console.log("COUNTER_L1=%s", address(counterL1));
        console.log("COUNTER_PROXY=%s", counterProxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════════════

contract Batcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        address counterProxy
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
        // Trigger: call counterProxy.increment() — consumes the entry.
        // The inner call in the entry runs inside executeInContext and is force-reverted.
        (bool ok,) = counterProxy.call(abi.encodeWithSelector(Counter.increment.selector));
        require(ok, "trigger should succeed (revertSpan rolls back the inner call's state, not the outer flow)");
    }
}

contract Execute is Script, RevertActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address counterProxy = vm.envAddress("COUNTER_PROXY");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        // alice = batcher (msg.sender into the proxy)
        batcher.execute(
            EEZ(rollupsAddr),
            proofSystemAddr,
            _l1Entries(counterL1, counterL2, address(batcher)),
            noLookupCalls(),
            counterProxy
        );

        // Invariant: counter on L1 stays at 0 — the increment ran, returned 1,
        // but executeInContext's revert rolled the state change back. The
        // rolling hash still committed to (success=true, retData=1).
        uint256 finalCounter = Counter(counterL1).counter();
        require(finalCounter == 0, "revertSpan must roll back successful state changes");

        console.log("done");
        console.log("counterL1.counter=%s (expected 0 -- state rolled back)", finalCounter);
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(Counter.increment.selector)));
    }
}

/// @title ExecuteL2 — local mode: system-driven L2 mirror via executeIncomingCrossChainCall.
/// @dev SYSTEM_ADDRESS is the local deployer (anvil account 0), so the broadcaster can call
///      executeIncomingCrossChainCall directly. The L2 entry's calls[0] targets the real
///      Counter on L2 with revertSpan=1; the inner span increments it, then state is rolled
///      back by executeInContext. Net effect: Counter.counter() == 0 on L2 too.
///      `_processNCalls` lazily creates the source proxy for (alice, MAINNET_ROLLUP_ID).
/// Env: MANAGER_L2, COUNTER_L2
contract ExecuteL2 is Script, RevertActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        address alice = msg.sender;

        EEZL2(managerAddr)
            .executeIncomingCrossChainCall(
                counterL2,
                0,
                abi.encodeWithSelector(Counter.increment.selector),
                alice,
                MAINNET_ROLLUP_ID,
                _l2Entries(counterL2, alice),
                noLookupCalls()
            );

        uint256 finalCounter = Counter(counterL2).counter();
        require(finalCounter == 0, "revertSpan must roll back successful state changes on L2");

        console.log("done");
        console.log("counterL2.counter=%s (expected 0 -- state rolled back)", finalCounter);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, RevertActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter(L2)";
        if (a == vm.envAddress("COUNTER_L1")) return "Counter(L1)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2 = vm.envAddress("COUNTER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(counterL1, counterL2, alice);
        bytes32 l1Hash = _entryHash(l1[0]);

        ExecutionEntry[] memory l2 = _l2Entries(counterL2, alice);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call w/ revertSpan=1, force-reverted success) ===");
        _logEntry(0, l1[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call w/ revertSpan=1, system-driven mirror) ===");
        _logL2Entry(0, l2[0]);
    }
}
