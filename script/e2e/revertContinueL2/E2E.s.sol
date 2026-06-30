// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {StateDelta, L2ToL1Call, ExecutionEntry, StaticLookup} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticLookup as L2StaticLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";
import {Counter, SelfCallerWithRevert} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    expectedL1toL2Hash,
    noStaticLookups,
    noNestedActions,
    noL2Calls,
    noL2StaticLookups,
    deferredSingleRollupBatch,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  RevertContinueL2 scenario — L2-side mirror of revertContinue
//
//  SelfCallerWithRevert.execute():
//    a. try this.innerCall() {} catch {}
//         — innerCall does target.increment() (the reentrant proxy call SUCCEEDS,
//           consuming expectedOutgoingCalls[0] and bumping the cursor), then innerCall()
//           wraps up with `revert("inner scope revert")`. The revert rolls back
//           innerCall()'s frame, including the ExpectedOutgoingCrossChainCall-cursor bump.
//    b. lastResult = target.increment()
//         — second reentrant call re-consumes expectedOutgoingCalls[0] from the same
//           cursor (since the bump was rolled back) and succeeds for real.
//
//  Net effect: exactly ONE nested call consumption survives. ExpectedOutgoingCrossChainCall
//  is the correct primitive — the reentrant call itself succeeds; only the
//  Solidity wrapper around it reverts.
//
//  Chain of events (entirely on L2):
//    1. loadExecutionTable loads ONE entry with incomingCalls[] + expectedOutgoingCalls[]
//    2. Alice calls selfCallerProxy (proxy for SelfCallerWithRevert@MAINNET on L2)
//    3. _processNCalls: incomingCalls[0] routes via proxy → selfCaller.execute()
//    4. execute() does try this.innerCall() catch {} then target.increment()
//    5. innerCall(): counterProxy reentrant call SUCCEEDS, then innerCall reverts
//       — cursor bump rolled back by EVM
//    6. target.increment(): counterProxy reentrant call re-consumes expectedOutgoingCalls[0]
//    7. Nested call returns abi.encode(1) → lastResult=1
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertContinueL2Actions {
    function _executeData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SelfCallerWithRevert.execute.selector);
    }

    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev Outer action hash (proxyEntryHash): alice calls selfCallerProxy (SelfCallerWithRevert MAINNET) on L2.
    function _outerActionHash(address selfCaller, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, selfCaller, 0, _executeData(), alice, L2_ROLLUP_ID);
    }

    /// @dev L2 incoming top-level CALL_BEGIN hash: alice -> selfCaller executed ON L2 (targetRollupId=L2).
    function _l2IncomingHash(address selfCaller, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, selfCaller, 0, _executeData(), alice, MAINNET_ROLLUP_ID);
    }

    /// @dev Inner action hash: SelfCallerWithRevert reentrant-calls counterProxy (Counter L1) on L2
    ///      (outbound L2->L1, sourceRollupId=L2).
    function _innerActionHash(address counterL1, address selfCaller) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, counterL1, 0, _incrementData(), selfCaller, L2_ROLLUP_ID);
    }

    /// @dev L1 mirror entry: system-driven (proxyEntryHash=0) — drained by executeL2Txs.
    ///      `l2ToL1Calls[0]` is the inbound call from SelfCaller (on L2) to Counter on MAINNET,
    ///      delivered through the lazily-created source proxy for (SelfCaller, L2_ROLLUP_ID) on L1.
    ///      The L2-side inner reentrant call surfaces on L1 as a plain top-level call; CALL_BEGIN
    ///      folds targetRollupId=MAINNET.
    function _l1Entries(address counterL1, address selfCallerL2)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: selfCallerL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _incrementData()
        });

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-revertContinue"),
            etherDelta: 0
        });

        bytes32 ccTop =
            crossChainCallHash(MAINNET_ROLLUP_ID, counterL1, 0, _incrementData(), selfCallerL2, L2_ROLLUP_ID);
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

    /// @dev L2 anchor entry. Rolling hash: entryBeginL2(seed) -> CALL_BEGIN(ccTop) -> NESTED_BEGIN(ccInner)
    ///      -> NESTED_END -> CALL_END(true, ""). innerCall()'s revert rolls back the rolling-hash and cursor
    ///      writes from its first successful reentrant consumption; the second target.increment() re-consumes
    ///      expectedOutgoingCalls[0] from the rolled-back cursor — exactly ONE consumption survives.
    /// NOTE: PENDING EEZL2 — L2 rolling-hash seed/fold convention unconfirmed; re-verify when EEZL2.sol lands.
    function _l2Entries(address selfCaller, address counterL1, address alice)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: selfCaller,
            value: 0,
            data: _executeData()
        });

        bytes32 proxyEntryHash = _outerActionHash(selfCaller, alice);
        bytes32 ccInner = _innerActionHash(counterL1, selfCaller);

        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, _l2IncomingHash(selfCaller, alice));
        bytes32 rhFire = rh;
        rh = RollingHashBuilder.appendNestedBegin(rh, ccInner);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(ccInner, rhFire),
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: bytes32(0),
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

/// @title DeployL2 — on L2, create proxies + deploy SelfCallerWithRevert
/// Env: MANAGER_L2, COUNTER_L1
/// Outputs: COUNTER_PROXY_L2, SELF_CALLER, SELF_CALLER_PROXY
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        // Proxy for Counter@L1 on L2
        address counterProxy;
        try manager.createCrossChainProxy(counterL1Addr, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = manager.computeCrossChainProxyAddress(counterL1Addr, MAINNET_ROLLUP_ID);
        }

        // Deploy SelfCallerWithRevert on L2, targeting the counterProxy
        SelfCallerWithRevert selfCaller = new SelfCallerWithRevert(Counter(counterProxy));

        // Proxy for SelfCallerWithRevert@MAINNET on L2 (the trigger point alice calls)
        address selfCallerProxy;
        try manager.createCrossChainProxy(address(selfCaller), MAINNET_ROLLUP_ID) returns (address p) {
            selfCallerProxy = p;
        } catch {
            selfCallerProxy = manager.computeCrossChainProxyAddress(address(selfCaller), MAINNET_ROLLUP_ID);
        }

        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        console.log("SELF_CALLER=%s", address(selfCaller));
        console.log("SELF_CALLER_PROXY=%s", selfCallerProxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — loadExecutionTable + trigger via selfCallerProxy in same block
contract ExecuteL2 is Script, RevertContinueL2Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address selfCallerAddr = vm.envAddress("SELF_CALLER");
        address selfCallerProxy = vm.envAddress("SELF_CALLER_PROXY");

        vm.startBroadcast();
        // alice = msg.sender (the broadcaster)
        address alice = msg.sender;
        console.log("ExecuteL2: alice=%s selfCaller=%s selfCallerProxy=%s", alice, selfCallerAddr, selfCallerProxy);

        EEZL2(managerAddr).loadExecutionTable(_l2Entries(selfCallerAddr, counterL1Addr, alice), noL2StaticLookups());
        console.log("ExecuteL2: loadExecutionTable done");

        // Trigger: alice calls selfCallerProxy.execute()
        (bool ok,) = selfCallerProxy.call(abi.encodeWithSelector(SelfCallerWithRevert.execute.selector));
        require(ok, "outer call failed");
        console.log("ExecuteL2: trigger done");

        console.log("done");
        console.log("selfCaller.lastResult=%s", SelfCallerWithRevert(selfCallerAddr).lastResult());
        vm.stopBroadcast();
    }
}

/// @notice Inline L2-TX batcher — postBatch (deferred) + executeL2Txs in one tx.
/// @dev Pins immediateEntryCount=0 so the zero-hash entry stays in the deferred
///      queue and is drained by the subsequent executeL2Txs(rollupId) call.
/// @dev Builds the L1 entry INTERNALLY (inherits `RevertContinueL2Actions`) so the caller never
///      ABI-encodes the nested `ExecutionEntry[]` across the call boundary — only the single
///      deferred-batch encode for `postAndVerifyBatch` remains, keeping clear of the via-ir stack
///      limit. `immediateEntryCount` is 0 so the zero-hash entry stays in the deferred queue and is
///      drained by `executeL2Txs`.
contract DeferredL2TXBatcher is RevertContinueL2Actions {
    function execute(EEZ rollups, address proofSystem, address counterL1, address selfCallerL2) external {
        rollups.postAndVerifyBatch(
            deferredSingleRollupBatch(proofSystem, L2_ROLLUP_ID, _l1Entries(counterL1, selfCallerL2), noStaticLookups())
        );
        rollups.executeL2Txs(L2_ROLLUP_ID);
    }
}

/// @title Execute - L1-side mirror. Deferred postBatch + executeL2Txs runs the actual
///        Counter.increment() on L1 (the destination of the L2-anchored inner reentrant call).
contract Execute is Script {
    function run() external {
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        DeferredL2TXBatcher batcher = new DeferredL2TXBatcher();
        batcher.execute(
            EEZ(vm.envAddress("ROLLUPS")), vm.envAddress("PROOF_SYSTEM"), counterL1, vm.envAddress("SELF_CALLER")
        );

        console.log("Execute: done");
        console.log("L1 counter=%s", Counter(counterL1).counter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetworkL2 — network mode output
contract ExecuteNetworkL2 is Script {
    function run() external view {
        address target = vm.envAddress("SELF_CALLER_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(SelfCallerWithRevert.execute.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, RevertContinueL2Actions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "Counter";
        if (a == vm.envAddress("SELF_CALLER")) return "SelfCallerWithRevert";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == SelfCallerWithRevert.execute.selector) return "execute";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address selfCallerAddr = vm.envAddress("SELF_CALLER");
        address alice = msg.sender;

        L2ExecutionEntry[] memory l2 = _l2Entries(selfCallerAddr, counterL1Addr, alice);
        ExecutionEntry[] memory l1 = _l1Entries(counterL1Addr, selfCallerAddr);
        bytes32 l2Hash = _entryHash(l2[0]);
        bytes32 l1Hash = _entryHash(l1[0]);

        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 1 nested - revert+continue) ===");
        _logL2Entry(0, l2[0]);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call - L2 mirror destination on L1) ===");
        _logEntry(0, l1[0]);
    }
}
