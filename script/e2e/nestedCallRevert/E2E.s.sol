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
//  Per CAVEATS.md, a reverting reentrant call is modeled as a `StaticCall`
//  with `failed = true` (NOT a NestedAction — a failed NestedAction's revert
//  rolls back the consumption-cursor bump, making consumption silent and
//  unverifiable). _consumeNestedAction's fallback path scans persistent
//  staticCalls keyed by (actionHash, _currentCallNumber, lastNestedActionConsumed)
//  and reverts with the cached returnData when a `failed=true` StaticCall matches.
//
//  Result: nestedActions.length must be 0 and staticCalls contains the
//  failed=true entry. The rolling hash only has CALL_BEGIN/CALL_END
//  (no NESTED tags), since the failed reentrant call is replayed as a
//  static-call revert outside the rolling-hash chain.
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
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: scap,
            value: 0,
            data: abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev Inner action hash: SCAP's reentrant call to Counter@L2 that reverts.
    ///      `executeCrossChainCall` hardcodes srcRollup=MAINNET on L1, so this
    ///      hash uses MAINNET as the source rollup.
    function _innerActionHash(address counterL2, address scap) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: abi.encodeWithSelector(Counter.increment.selector),
            sourceAddress: scap,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev Rolling hash: just CALL_BEGIN(1) -> CALL_END(1, true, "")
    ///      The reentrant call is replayed as a `failed=true` static-call revert
    ///      that SCAP catches; no NESTED tags appear in the rolling hash.
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
            targetAddress: scap,
            value: 0,
            data: abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
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

    /// @dev StaticCall that models the reverting reentrant call. Keyed by
    ///      (innerActionHash, callNumber=1, lastNestedActionConsumed=0) — the
    ///      same key the lookup uses when SCAP's inner call hits the manager.
    ///      `failed=true` makes _resolveStaticCall revert with returnData.
    function _l1StaticCalls(address counterL2, address scap)
        internal
        pure
        returns (StaticCall[] memory statics)
    {
        statics = new StaticCall[](1);
        statics[0] = StaticCall({
            actionHash: _innerActionHash(counterL2, scap),
            returnData: bytes("inner reverts"),
            failed: true,
            stateRoot: bytes32(0),
            callNumber: 1,
            lastNestedActionConsumed: 0,
            calls: new CrossChainCall[](0),
            rollingHash: bytes32(0)
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
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(scapAddr, address(batcher)),
            _l1StaticCalls(counterL2, scapAddr),
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
        address counterL2 = vm.envAddress("COUNTER_L2");
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(scapAddr, alice);
        StaticCall[] memory statics = _l1StaticCalls(counterL2, scapAddr);
        bytes32 l1Hash = _entryHash(l1[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, 0 nested - reentrant revert via failed=true StaticCall) ===");
        _logEntry(0, l1[0]);
        console.log("=== EXPECTED L1 STATIC CALLS (1 failed=true entry) ===");
        _logStaticCall(0, statics[0]);
    }
}
