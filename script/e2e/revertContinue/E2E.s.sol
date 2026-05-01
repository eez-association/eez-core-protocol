// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {
    Action,
    StateDelta,
    CrossChainCall,
    NestedAction,
    ExecutionEntry,
    StaticCall
} from "../../../src/ICrossChainManager.sol";
import {Counter, SelfCallerWithRevert} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, noNestedActions, noCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  RevertContinue scenario — revert inside try/catch then continue
//
//  SelfCallerWithRevert.execute():
//    a. try this.innerCall() {} catch {}
//         — innerCall does target.increment() (the reentrant proxy call SUCCEEDS,
//           consuming nestedActions[0] and bumping the cursor), then innerCall()
//           wraps up with `revert("inner scope revert")`. The revert rolls back
//           innerCall()'s frame, including the NestedAction-cursor bump (which
//           is a transient-store write).
//    b. lastResult = target.increment()
//         — second reentrant call re-consumes nestedActions[0] from the same
//           cursor (since the bump was rolled back) and succeeds for real.
//
//  Net effect: exactly ONE nested action consumption survives. The rolling
//  hash only records that single surviving consumption — identical to a
//  scenario where innerCall() never ran.
//
//  Why NestedAction (not StaticCall failed=true): the reentrant call itself
//  succeeds; only the Solidity wrapper around it reverts. This is the textbook
//  pattern that makes "successful reentrant + EVM rollback" work, because the
//  cursor bump is a transient-store write that the EVM revert undoes.
//
//  This replaces the old REVERT_CONTINUE action type from the scope-tree model.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract RevertContinueActions {
    using RollingHashBuilder for bytes32;

    /// @dev Outer action hash: batcher calls selfCallerProxy.execute() on L1.
    function _outerActionHash(address selfCaller, address batcher) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: selfCaller,
            value: 0,
            data: abi.encodeWithSelector(SelfCallerWithRevert.execute.selector),
            sourceAddress: batcher,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev Inner action hash: SelfCallerWithRevert calls counterProxy.increment().
    function _innerActionHash(address counterL2, address selfCaller) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: selfCaller,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev Rolling hash: CALL_BEGIN(1) → NESTED_BEGIN(1) → NESTED_END(1) → CALL_END(1, true, "")
    ///      innerCall()'s revert rolls back the rolling-hash and cursor writes
    ///      from its successful reentrant consumption. The second target.increment()
    ///      call re-consumes nestedActions[0] from the rolled-back cursor — that
    ///      is the only consumption recorded in the surviving rolling hash.
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendNestedBegin(1);
        h = h.appendNestedEnd(1);
        h = h.appendCallEnd(1, true, "");
    }

    function _l1Entries(address selfCaller, address counterL2, address batcher)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-revertcontinue"),
            etherDelta: 0
        });

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            targetAddress: selfCaller,
            value: 0,
            data: abi.encodeWithSelector(SelfCallerWithRevert.execute.selector),
            sourceAddress: batcher,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        NestedAction[] memory nested = new NestedAction[](1);
        nested[0] = NestedAction({
            actionHash: _innerActionHash(counterL2, selfCaller),
            callCount: 0,
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            actionHash: _outerActionHash(selfCaller, batcher),
            calls: calls,
            nestedActions: nested,
            callCount: 1,
            returnData: "",
            failed: false,
            rollingHash: _expectedRollingHash()
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counter = new Counter();
        console.log("COUNTER_L2=%s", address(counter));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        Rollups rollups = Rollups(rollupsAddr);

        // Proxy for Counter@L2 on L1
        address counterProxy;
        try rollups.createCrossChainProxy(counterL2, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2, L2_ROLLUP_ID);
        }

        // Deploy SelfCallerWithRevert targeting the counterProxy
        SelfCallerWithRevert selfCaller = new SelfCallerWithRevert(Counter(counterProxy));

        // Proxy for SelfCallerWithRevert@L2 on L1 (trigger point)
        address selfCallerProxy;
        try rollups.createCrossChainProxy(address(selfCaller), L2_ROLLUP_ID) returns (address p) {
            selfCallerProxy = p;
        } catch {
            selfCallerProxy = rollups.computeCrossChainProxyAddress(address(selfCaller), L2_ROLLUP_ID);
        }

        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("SELF_CALLER=%s", address(selfCaller));
        console.log("SELF_CALLER_PROXY=%s", selfCallerProxy);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════════════

contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata statics,
        address selfCallerProxy
    ) external {
        rollups.postBatch(entries, statics, 0, 0, 0, "", "proof");
        (bool ok,) = selfCallerProxy.call(abi.encodeWithSelector(SelfCallerWithRevert.execute.selector));
        require(ok, "outer call failed");
    }
}

contract Execute is Script, RevertContinueActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address selfCallerAddr = vm.envAddress("SELF_CALLER");
        address selfCallerProxy = vm.envAddress("SELF_CALLER_PROXY");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(selfCallerAddr, counterL2, address(batcher)),
            noStaticCalls(),
            selfCallerProxy
        );

        console.log("done");
        console.log("selfCaller.lastResult=%s", SelfCallerWithRevert(selfCallerAddr).lastResult());
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

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, RevertContinueActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("SELF_CALLER")) return "SelfCallerWithRevert";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == SelfCallerWithRevert.execute.selector) return "execute";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2 = vm.envAddress("COUNTER_L2");
        address selfCallerAddr = vm.envAddress("SELF_CALLER");
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(selfCallerAddr, counterL2, alice);
        bytes32 l1Hash = _entryHash(l1[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, 1 nested - revert+continue) ===");
        _logEntry(0, l1[0]);
    }
}
