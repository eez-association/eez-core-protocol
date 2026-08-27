// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {RootUpdate, L2ToL1Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, SelfCallerWithRevert} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    crossChainCallHashL2Out,
    expectedL1toL2Hash,
    noStaticEntries,
    noNestedActions,
    noL2Calls,
    noL2StaticEntries,
    immediateSingleRollupBatch,
    RollingHashBuilder
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  RevertFromOtherChain — a revert on the OTHER chain force-reverts a call
//  already executed on THIS chain: the real `revertNextNCalls` producer.
//  Two-sided, L1→L2 trigger.
//
//  L2 delivered execution (ExecuteL2) — where the REAL revert happens:
//    SYSTEM ──executeIncomingCrossChainCall(entries: [S.execute() from alice@L1])──▶ EEZL2
//      └─ S(L2).execute()                 S = SelfCallerWithRevert, target = proxy for (Counter@L1)
//           ├─ try this.innerCall()
//           │    ├─ counterProxy.increment() ─▶ consumes expectedOutgoingCalls[0] → 1 (cached)
//           │    └─ revert("inner scope revert")   ◀── frame dies: cursor + hash UNWIND
//           ├─ catch {}
//           └─ lastResult = counterProxy.increment() ─▶ RE-consumes the SAME row → 1
//    result: lastResult == 1; committed hash records exactly ONE nested frame
//
//  L1 side (Execute) — trigger + entry mirroring BOTH consumptions:
//    alice ──tx──▶ selfCallerProxy.call(execute())    proxy for (S@L2)
//      └─ EEZ.executeCrossChainCall ─ consumes the entry:
//           calls[0]  Counter(L1).increment()  revertNextNCalls=1   ◀── the UNWOUND consumption
//                     runs in executeInContextAndRevert: 0→1, returns 1, STATE ERASED
//           calls[1]  Counter(L1).increment()  plain                ◀── the SURVIVING one
//                     0→1, returns 1, COMMITS
//    result: Counter(L1).counter == 1
//
//  The span is load-bearing: without it the first increment would commit,
//  the second would return 2, and the rolling hash would diverge.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertFromOtherChainActions {
    function _executeData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SelfCallerWithRevert.execute.selector);
    }

    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev Trigger identity: alice calls the L1 proxy for (S@L2). Same hash on both sides.
    function _proxyEntryHash(address selfCallerL2, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(false, alice, MAINNET_ROLLUP_ID, selfCallerL2, L2_ROLLUP_ID, 0, _executeData());
    }

    /// @dev CALL_BEGIN identity of each increment executed ON L1, sourced from S on L2.
    function _incCallHash(address counterL1, address selfCallerL2) internal pure returns (bytes32) {
        return crossChainCallHash(false, selfCallerL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementData());
    }

    /// @dev L1 entry — mirrors BOTH increment consumptions S's L2 execution made:
    ///      calls[0] force-reverted (its L2-side frame reverted), calls[1] committed.
    ///      Both run on a counter at 0, so both return abi.encode(1).
    function _l1Entries(
        address selfCallerL2,
        address counterL1,
        address alice
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 1,
            isStatic: false,
            sourceAddress: selfCallerL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _incrementData()
        });
        calls[1] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: selfCallerL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _incrementData()
        });

        RootUpdate[] memory deltas = new RootUpdate[](1);
        deltas[0] = RootUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-revert-from-other-chain"),
            etherDelta: 0
        });

        bytes32 proxyEntryHash = _proxyEntryHash(selfCallerL2, alice);
        bytes32 ccInc = _incCallHash(counterL1, selfCallerL2);
        bytes32 rh = RollingHashBuilder.entryBegin(deltas, proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, ccInc);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));
        rh = RollingHashBuilder.appendCallBegin(rh, ccInc);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rootUpdates: deltas,
            proxyEntryHash: proxyEntryHash,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }

    /// @dev L2 entry — the delivered execution of S. Its ONE reentrant row is consumed twice:
    ///      innerCall()'s real revert rolls the cursor back, the second increment re-consumes it.
    ///      The committed hash records exactly one NESTED frame.
    function _l2Entries(
        address selfCallerL2,
        address counterL1,
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
            targetAddress: selfCallerL2,
            value: 0,
            data: _executeData()
        });

        bytes32 proxyEntryHash = _proxyEntryHash(selfCallerL2, alice);
        bytes32 ccOut =
            crossChainCallHashL2Out(selfCallerL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementData());

        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, proxyEntryHash);
        bytes32 rhFire = rh; // both consumptions fire here — the first one's folds unwind
        rh = RollingHashBuilder.appendNestedBegin(rh, ccOut);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(ccOut, rhFire),
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
//  Deploys — three stages: Counter on L1, then S + its counter proxy on L2,
//  then the trigger proxy (for S) back on L1.
// ═══════════════════════════════════════════════════════════════════════

/// @title Deploy — the real Counter on L1 (the force-reverted target)
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        Counter counter = new Counter();
        console.log("COUNTER_L1=%s", address(counter));
        vm.stopBroadcast();
    }
}

/// @title DeployL2Side — on L2: proxy for Counter@L1 + SelfCallerWithRevert targeting it
/// Env: MANAGER_L2, COUNTER_L1
contract DeployL2Side is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        address counterProxy;
        try manager.createCrossChainProxy(counterL1, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = manager.computeCrossChainProxyAddress(counterL1, MAINNET_ROLLUP_ID);
        }

        SelfCallerWithRevert selfCaller = new SelfCallerWithRevert(Counter(counterProxy));

        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        console.log("SELF_CALLER_L2=%s", address(selfCaller));
        vm.stopBroadcast();
    }
}

/// @title DeployTriggerProxy — on L1: the trigger proxy for (S@L2)
/// Env: ROLLUPS, SELF_CALLER_L2
contract DeployTriggerProxy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address selfCallerL2 = vm.envAddress("SELF_CALLER_L2");

        vm.startBroadcast();
        EEZ rollups = EEZ(rollupsAddr);

        address selfCallerProxy;
        try rollups.createCrossChainProxy(selfCallerL2, L2_ROLLUP_ID) returns (address p) {
            selfCallerProxy = p;
        } catch {
            selfCallerProxy = rollups.computeCrossChainProxyAddress(selfCallerL2, L2_ROLLUP_ID);
        }

        console.log("SELF_CALLER_PROXY=%s", selfCallerProxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════════════

/// @title Execute — local mode: postAndVerifyBatch + trigger in one block.
///        The span assertion: Counter(L1) ends at 1, not 2.
contract Execute is Script, RevertFromOtherChainActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address selfCallerL2 = vm.envAddress("SELF_CALLER_L2");
        address selfCallerProxy = vm.envAddress("SELF_CALLER_PROXY");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(selfCallerL2, counterL1, msg.sender), noStaticEntries()
                )
            );

        (bool ok,) = selfCallerProxy.call(_executeData());
        require(ok, "trigger should succeed");

        // calls[0] ran and was force-reverted (its L2 frame reverted); calls[1] committed.
        uint256 finalCounter = Counter(counterL1).counter();
        require(finalCounter == 1, "revertNextNCalls must erase exactly the first increment");

        console.log("done");
        console.log("counterL1.counter=%s (expected 1 -- first increment force-reverted)", finalCounter);
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("SELF_CALLER_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(SelfCallerWithRevert.execute.selector)));
    }
}

/// @title ExecuteL2 — local mode: system-driven delivery of S's execution.
/// @dev innerCall()'s real revert rolls back the first reentrant consumption; the second
///      re-consumes the same row. lastResult == 1 proves exactly one survived.
/// Env: MANAGER_L2, COUNTER_L1, SELF_CALLER_L2
contract ExecuteL2 is Script, RevertFromOtherChainActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address selfCallerL2 = vm.envAddress("SELF_CALLER_L2");

        vm.startBroadcast();
        address alice = msg.sender;

        EEZL2(managerAddr)
            .executeIncomingCrossChainCall(_l2Entries(selfCallerL2, counterL1, alice), noL2StaticEntries());

        uint256 lastResult = SelfCallerWithRevert(selfCallerL2).lastResult();
        require(lastResult == 1, "exactly one reentrant consumption must survive");

        console.log("done");
        console.log("selfCallerL2.lastResult=%s (expected 1)", lastResult);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, RevertFromOtherChainActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "Counter(L1)";
        if (a == vm.envAddress("SELF_CALLER_L2")) return "SelfCallerWithRevert(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == SelfCallerWithRevert.execute.selector) return "execute";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1 = vm.envAddress("COUNTER_L1");
        address selfCallerL2 = vm.envAddress("SELF_CALLER_L2");
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(selfCallerL2, counterL1, alice);
        L2ExecutionEntry[] memory l2 = _l2Entries(selfCallerL2, counterL1, alice);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2[0].proxyEntryHash));
        _printL1Table(l1);
        _printL2Table(l2);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 2 calls: [span=1, plain] - other-chain revert mirrored) ===");
        _logEntry(0, l1[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 1 nested row consumed twice) ===");
        _logL2Entry(0, l2[0]);
    }
}
