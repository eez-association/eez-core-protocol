// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {e2eRollupId} from "../../../shared/E2EHelpers.sol";

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../../src/interfaces/IEEZ.sol";
import {EEZL2} from "../../../../../../src/L2/EEZL2.sol";
import {RollupUpdate, L2ToL1Call, ExecutionEntry} from "../../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../../src/interfaces/IEEZL2.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    getOrCreateProxy,
    crossChainCallHash,
    crossChainCallHashL2Out,
    expectedL1toL2Hash,
    noStaticEntries,
    noNestedActions,
    noL2Calls,
    noL2StaticEntries,
    immediateSingleRollupBatch,
    RollingHashBuilder,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// E2E_EXCLUDE_FROM_ALL: targeted rollback regression; select explicitly.
// RevertFromOtherChainNoRetry — L1-triggered callback erased by an L2 parent revert.
//
// alice@L1 -> proxy(SelfCallerRevertOnly@L2).execute()
//   L2: try this.innerCall()
//         proxy(Counter@L1).increment() -> 1
//         revert("inner scope revert") -> cursor and nested hash folds unwind
//       catch: reverted = true; no retry
//   L1: one Counter.increment() with revertNextNCalls=1 -> returns 1, state erased
//
// The outer execute() succeeds, so there is one L2 delivery. Its nested row is
// resolved once but its consumption is erased. The L1 hash retains the callback
// evidence; Counter@L1 remains 0 and SelfCallerRevertOnly@L2.reverted is true.

uint64 constant MAINNET_ROLLUP_ID = 0;

contract Counter {
    uint256 public counter;

    function increment() external returns (uint256) {
        return ++counter;
    }
}

contract SelfCallerRevertOnly {
    Counter public immutable target;
    bool public reverted;

    constructor(Counter target_) {
        target = target_;
    }

    function execute() external {
        require(!reverted, "one trigger only");
        try this.innerCall() {
            revert("inner frame unexpectedly committed");
        } catch (bytes memory reason) {
            require(
                keccak256(reason) == keccak256(abi.encodeWithSignature("Error(string)", "inner scope revert")),
                "wrong inner revert"
            );
            reverted = true;
        }
    }

    function innerCall() external {
        require(msg.sender == address(this), "self only");
        require(target.increment() == 1, "wrong callback result");
        revert("inner scope revert");
    }
}

abstract contract RevertFromOtherChainNoRetryActions {
    /// @dev Expected L1 folds, in entry order, independent of the posted seed roots.
    ///      The deliberate rollback span preserves the first successful call's folds.
    ///      Its state unwinds; no second increment follows.
    function _l1Steps(address counterL1, address selfCallerL2) internal view returns (HashStep[][] memory steps) {
        steps = new HashStep[][](1);
        steps[0] = new HashStep[](2);
        steps[0][0] = RollingHashBuilder.stepCallBegin(_incCallHash(counterL1, selfCallerL2));
        steps[0][1] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(1)));
    }

    function _executeData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SelfCallerRevertOnly.execute.selector);
    }

    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev Trigger identity: alice calls the L1 proxy for (S@L2). Same hash on both sides.
    function _proxyEntryHash(address selfCallerL2, address alice) internal view returns (bytes32) {
        return crossChainCallHash(false, alice, MAINNET_ROLLUP_ID, selfCallerL2, e2eRollupId(), 0, _executeData());
    }

    /// @dev CALL_BEGIN identity of each increment executed ON L1, sourced from S on L2.
    function _incCallHash(address counterL1, address selfCallerL2) internal view returns (bytes32) {
        return crossChainCallHash(false, selfCallerL2, e2eRollupId(), counterL1, MAINNET_ROLLUP_ID, 0, _incrementData());
    }

    /// @dev The only increment returns 1 and is force-reverted with its L2 parent.
    function _l1Entries(
        address selfCallerL2,
        address counterL1,
        address alice
    )
        internal
        view
        returns (ExecutionEntry[] memory entries)
    {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 1,
            isStatic: false,
            sourceAddress: selfCallerL2,
            sourceRollupId: e2eRollupId(),
            targetAddress: counterL1,
            value: 0,
            data: _incrementData()
        });

        RollupUpdate[] memory deltas = new RollupUpdate[](1);
        deltas[0] = RollupUpdate({
            rollupId: e2eRollupId(),
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-revert-from-other-chain-no-retry"),
            etherDelta: 0
        });

        bytes32 proxyEntryHash = _proxyEntryHash(selfCallerL2, alice);
        bytes32 ccInc = _incCallHash(counterL1, selfCallerL2);
        bytes32 rh = RollingHashBuilder.entryBegin(deltas, proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, ccInc);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: deltas,
            proxyEntryHash: proxyEntryHash,
            destinationRollupId: e2eRollupId(),
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }

    /// @dev One delivered execute() with one successful outgoing row. The local
    ///      parent revert erases the row's nested folds; only execute() commits.
    function _l2Entries(
        address selfCallerL2,
        address counterL1,
        address alice
    )
        internal
        view
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
            crossChainCallHashL2Out(selfCallerL2, e2eRollupId(), counterL1, MAINNET_ROLLUP_ID, 0, _incrementData());

        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, proxyEntryHash);
        bytes32 rhFire = rh; // the only consumption and its nested folds unwind
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
        output("COUNTER_L1", address(counter));
        vm.stopBroadcast();
    }
}

/// @title DeployL2Side — on L2: proxy for Counter@L1 + SelfCallerRevertOnly targeting it
/// Env: MANAGER_L2, COUNTER_L1
contract DeployL2Side is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        address counterProxy = getOrCreateProxy(IEEZ(address(manager)), counterL1, MAINNET_ROLLUP_ID);

        SelfCallerRevertOnly selfCaller = new SelfCallerRevertOnly(Counter(counterProxy));

        output("COUNTER_PROXY_L2", counterProxy);
        output("SELF_CALLER_L2", address(selfCaller));
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

        address selfCallerProxy = getOrCreateProxy(IEEZ(address(rollups)), selfCallerL2, e2eRollupId());

        output("SELF_CALLER_PROXY", selfCallerProxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════════════

/// @title Execute — local mode: postAndVerifyBatch + trigger in one block.
///        The span assertion: Counter(L1) stays at 0.
contract Execute is Script, RevertFromOtherChainNoRetryActions {
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
                    proofSystemAddr, e2eRollupId(), _l1Entries(selfCallerL2, counterL1, msg.sender), noStaticEntries()
                )
            );

        (bool ok,) = selfCallerProxy.call(_executeData());
        require(ok, "trigger should succeed");

        // The only callback ran and was force-reverted with its L2 parent.
        uint256 finalCounter = Counter(counterL1).counter();
        require(finalCounter == 0, "revertNextNCalls must erase the only increment");

        console.log("done");
        console.log("counterL1.counter=%s (expected 0 -- only increment force-reverted)", finalCounter);
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("SELF_CALLER_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(SelfCallerRevertOnly.execute.selector)));
    }
}

/// @title ExecuteL2 — local mode: system-driven delivery of S's execution.
/// @dev innerCall() reverts after the callback; execute() catches it and records reverted=true.
/// Env: MANAGER_L2, COUNTER_L1, SELF_CALLER_L2
contract ExecuteL2 is Script, RevertFromOtherChainNoRetryActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address selfCallerL2 = vm.envAddress("SELF_CALLER_L2");

        vm.startBroadcast();
        address alice = msg.sender;

        EEZL2(managerAddr)
            .executeIncomingCrossChainCall(_l2Entries(selfCallerL2, counterL1, alice), noL2StaticEntries());

        require(SelfCallerRevertOnly(selfCallerL2).reverted(), "inner frame must have reverted");

        console.log("done");
        console.log("selfCallerL2.reverted=true (no retry)");
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  VerifyNetwork — persisted state checks
// ═══════════════════════════════════════════════════════════════════════

contract VerifyNetwork is Script {
    function run() external view {
        require(Counter(vm.envAddress("COUNTER_L1")).counter() == 0, "unexpected L1 counter");
        console.log("VERIFY_PASS L1 counter=0");
    }
}

contract VerifyNetworkL2 is Script {
    function run() external view {
        require(SelfCallerRevertOnly(vm.envAddress("SELF_CALLER_L2")).reverted(), "unexpected L2 result");
        console.log("VERIFY_PASS L2 result");
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, RevertFromOtherChainNoRetryActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "Counter(L1)";
        if (a == vm.envAddress("SELF_CALLER_L2")) return "SelfCallerRevertOnly(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == SelfCallerRevertOnly.execute.selector) return "execute";
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
        _printL1Steps(l1, _l1Steps(counterL1, selfCallerL2));
        _printL1Table(l1);
        _printL2Table(l2);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call: [span=1] - other-chain revert mirrored) ===");
        _logEntry(0, l1[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 1 nested row consumed then unwound) ===");
        _logL2Entry(0, l2[0]);
    }
}
