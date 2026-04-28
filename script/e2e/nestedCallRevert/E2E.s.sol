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
import {Counter, SafeCounterAndProxy} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  NestedCallRevert - nested reentrant call that fails; caller recovers
//
//  SafeCounterAndProxy.incrementProxy():
//    try target.increment() returns (uint256 val) { targetCounter = val }
//    catch { lastCallFailed = true }
//    counter++
//
//  When target is a proxy whose nested action has failed data, the call
//  reverts. SafeCounterAndProxy catches it. But the nested action
//  consumption is rolled back by the revert. The entry only declares
//  one nestedAction whose consumption never sticks.
//
//  Result: nestedActions.length must be 0 (none consumed successfully),
//  and the rolling hash only has CALL_BEGIN/CALL_END with no NESTED tags.
//
//  After execution:
//    SafeCounterAndProxy.counter() = 1
//    SafeCounterAndProxy.lastCallFailed() = true
//    SafeCounterAndProxy.targetCounter() = 0
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedCallRevertActions {
    using RollingHashBuilder for bytes32;

    function _outerActionHash(address scap, address alice) internal pure returns (bytes32) {
        return actionHash(Action({
            rollupId: L2_ROLLUP_ID,
            destination: scap,
            value: 0,
            data: abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollup: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev Rolling hash: just CALL_BEGIN(1) -> CALL_END(1, true, "")
    ///      The nested call attempt reverts (rolled back), so no NESTED tags survive.
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendCallEnd(1, true, "");
    }

    function _l1Entries(address scap, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-nested-call-revert"),
            etherDelta: 0
        });

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: scap,
            value: 0,
            data: abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollup: L2_ROLLUP_ID,
            revertSpan: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            actionHash: _outerActionHash(scap, alice),
            calls: calls,
            nestedActions: new NestedAction[](0),
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

        // counterProxy: proxy for Counter@L2 on L1 (NOT an actual Counter)
        address counterProxy;
        try rollups.createCrossChainProxy(counterL2, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2, L2_ROLLUP_ID);
        }

        // SafeCounterAndProxy wraps counterProxy — try/catch on target.increment()
        SafeCounterAndProxy scap = new SafeCounterAndProxy(Counter(counterProxy));

        // Trigger proxy: proxy for (SCAP, L2_ROLLUP_ID) on L1
        address scapProxy;
        try rollups.createCrossChainProxy(address(scap), L2_ROLLUP_ID) returns (address p) {
            scapProxy = p;
        } catch {
            scapProxy = rollups.computeCrossChainProxyAddress(address(scap), L2_ROLLUP_ID);
        }

        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("SAFE_CAP=%s", address(scap));
        console.log("SAFE_CAP_PROXY=%s", scapProxy);
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
        address scapProxy
    ) external {
        rollups.postBatch(entries, statics, 0, 0, 0, "", "proof");
        (bool ok,) = scapProxy.call(abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector));
        require(ok, "outer call failed");
    }
}

contract Execute is Script, NestedCallRevertActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address scapAddr = vm.envAddress("SAFE_CAP");
        address scapProxy = vm.envAddress("SAFE_CAP_PROXY");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(scapAddr, address(batcher)),
            noStaticCalls(),
            scapProxy
        );

        console.log("done");
        console.log("scap.counter=%s", SafeCounterAndProxy(scapAddr).counter());
        console.log("scap.targetCounter=%s", SafeCounterAndProxy(scapAddr).targetCounter());
        console.log("scap.lastCallFailed=%s", SafeCounterAndProxy(scapAddr).lastCallFailed());
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("SAFE_CAP_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, NestedCallRevertActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("SAFE_CAP")) return "SafeCounterAndProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == SafeCounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address scapAddr = vm.envAddress("SAFE_CAP");
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(scapAddr, alice);
        bytes32 l1Hash = _entryHash(l1[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, 0 nested - call reverts in try/catch) ===");
        _logEntry(0, l1[0]);
    }
}
