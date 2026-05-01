// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../../src/CrossChainManagerL2.sol";
import {
    Action,
    StateDelta,
    CrossChainCall,
    NestedAction,
    ExecutionEntry,
    StaticCall
} from "../../../src/ICrossChainManager.sol";
import {ReentrantCounter} from "../../../test/mocks/ReentrantCounter.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Reentrant — 4-hop cross-chain reentrant chain via deepCall(3)
//
//  L1.dC(3) -> L2.dC(2) -> L1.dC(1) -> L2.dC(0)
//
//  ReentrantCounter.deepCall(N):
//    if N > 0: peer.deepCall(N-1)   // cross-chain via proxy
//    return ++count
//
//  On L1 (1 entry, 2 calls, 2 nestedActions):
//    calls[0]: rcL1.dC(3) from batcher
//      -> calls rcL2ProxyOnL1.dC(2) -> nestedAction[0] consumed (callCount=1)
//        calls[1]: rcL1.dC(1) from rcL2 (inside nestedAction[0])
//          -> calls rcL2ProxyOnL1.dC(0) -> nestedAction[1] consumed (callCount=0)
//          -> rcL1.count++ -> 1, returns 1
//      -> rcL1.count++ -> 2, returns 2
//
//  On L2 (1 entry, 2 calls, 1 nestedAction):
//    calls[0]: rcL2.dC(2) from rcL1
//      -> calls rcL1ProxyOnL2.dC(1) -> nestedAction[0] consumed (callCount=1)
//        calls[1]: rcL2.dC(0) from rcL1 (inside nestedAction[0])
//          -> no peer call (remainingCalls=0)
//          -> rcL2.count++ -> 1, returns 1
//      -> rcL2.count++ -> 2, returns 2
//
//  After execution: rcL1.count=2, rcL2.count=2
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract ReentrantActions {
    using RollingHashBuilder for bytes32;

    // ── Action hash builders ──

    /// @dev L1 outer: batcher calls rcL1Proxy(rcL1@L2) on L1 with dC(3)
    function _l1OuterActionHash(address rcL1, address batcher) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: rcL1,
            value: 0,
            data: abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(3)),
            sourceAddress: batcher,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev L1 nestedAction[0]: rcL1 calls rcL2Proxy(rcL2@L2) on L1 with dC(2)
    function _l1NestedHash0(address rcL2, address rcL1) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: rcL2,
            value: 0,
            data: abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(2)),
            sourceAddress: rcL1,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev L1 nestedAction[1]: rcL1 calls rcL2Proxy(rcL2@L2) on L1 with dC(0)
    function _l1NestedHash1(address rcL2, address rcL1) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: L2_ROLLUP_ID,
            targetAddress: rcL2,
            value: 0,
            data: abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(0)),
            sourceAddress: rcL1,
            sourceRollupId: MAINNET_ROLLUP_ID
        }));
    }

    /// @dev L2 outer: alice calls rcL1Proxy(rcL1@MAINNET) on L2 with dC(2)
    function _l2OuterActionHash(address rcL1, address alice) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: MAINNET_ROLLUP_ID,
            targetAddress: rcL1,
            value: 0,
            data: abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(2)),
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID
        }));
    }

    /// @dev L2 nestedAction[0]: rcL2 calls rcL1Proxy(rcL1@MAINNET) on L2 with dC(1)
    function _l2NestedHash0(address rcL1, address rcL2) internal pure returns (bytes32) {
        return actionHash(Action({
            targetRollupId: MAINNET_ROLLUP_ID,
            targetAddress: rcL1,
            value: 0,
            data: abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(1)),
            sourceAddress: rcL2,
            sourceRollupId: L2_ROLLUP_ID
        }));
    }

    // ── Rolling hashes ──

    /// @dev L1: CALL_BEGIN(1) NESTED_BEGIN(1) CALL_BEGIN(2) NESTED_BEGIN(2) NESTED_END(2)
    ///          CALL_END(2,true,enc(1)) NESTED_END(1) CALL_END(2,true,enc(2))
    function _l1RollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendNestedBegin(1);
        h = h.appendCallBegin(2);
        h = h.appendNestedBegin(2);
        h = h.appendNestedEnd(2);
        h = h.appendCallEnd(2, true, abi.encode(uint256(1)));
        h = h.appendNestedEnd(1);
        h = h.appendCallEnd(2, true, abi.encode(uint256(2)));
    }

    /// @dev L2: CALL_BEGIN(1) NESTED_BEGIN(1) CALL_BEGIN(2)
    ///          CALL_END(2,true,enc(1)) NESTED_END(1) CALL_END(2,true,enc(2))
    function _l2RollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendNestedBegin(1);
        h = h.appendCallBegin(2);
        h = h.appendCallEnd(2, true, abi.encode(uint256(1)));
        h = h.appendNestedEnd(1);
        h = h.appendCallEnd(2, true, abi.encode(uint256(2)));
    }

    // ── Entry builders ──

    function _l1Entries(address rcL1, address rcL2, address batcher)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-reentrant"),
            etherDelta: 0
        });

        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = CrossChainCall({
            targetAddress: rcL1,
            value: 0,
            data: abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(3)),
            sourceAddress: batcher,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });
        calls[1] = CrossChainCall({
            targetAddress: rcL1,
            value: 0,
            data: abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(1)),
            sourceAddress: rcL2,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });

        NestedAction[] memory nested = new NestedAction[](2);
        nested[0] = NestedAction({
            actionHash: _l1NestedHash0(rcL2, rcL1),
            callCount: 1,
            returnData: abi.encode(uint256(2))
        });
        nested[1] = NestedAction({
            actionHash: _l1NestedHash1(rcL2, rcL1),
            callCount: 0,
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            actionHash: _l1OuterActionHash(rcL1, batcher),
            calls: calls,
            nestedActions: nested,
            callCount: 1,
            // Top-level rcL1.deepCall(3) returns ++count == 2 after the chain.
            returnData: abi.encode(uint256(2)),
            failed: false,
            rollingHash: _l1RollingHash()
        });
    }

    function _l2Entries(address rcL1, address rcL2, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = CrossChainCall({
            targetAddress: rcL2,
            value: 0,
            data: abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(2)),
            sourceAddress: rcL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });
        calls[1] = CrossChainCall({
            targetAddress: rcL2,
            value: 0,
            data: abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(0)),
            sourceAddress: rcL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        NestedAction[] memory nested = new NestedAction[](1);
        nested[0] = NestedAction({
            actionHash: _l2NestedHash0(rcL1, rcL2),
            callCount: 1,
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            actionHash: _l2OuterActionHash(rcL1, alice),
            calls: calls,
            nestedActions: nested,
            callCount: 1,
            // Top-level rcL2.deepCall(2) returns ++count == 2 after the chain.
            returnData: abi.encode(uint256(2)),
            failed: false,
            rollingHash: _l2RollingHash()
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        ReentrantCounter rcL2 = new ReentrantCounter(address(0));
        console.log("REENTRANT_L2=%s", address(rcL2));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address rcL2Addr = vm.envAddress("REENTRANT_L2");

        vm.startBroadcast();
        Rollups rollups = Rollups(rollupsAddr);

        // Proxy for rcL2@L2 on L1 (rcL1's peer)
        address rcL2ProxyOnL1;
        try rollups.createCrossChainProxy(rcL2Addr, L2_ROLLUP_ID) returns (address p) {
            rcL2ProxyOnL1 = p;
        } catch {
            rcL2ProxyOnL1 = rollups.computeCrossChainProxyAddress(rcL2Addr, L2_ROLLUP_ID);
        }

        // Deploy rcL1 on L1 with peer = rcL2ProxyOnL1
        ReentrantCounter rcL1 = new ReentrantCounter(rcL2ProxyOnL1);

        // Trigger proxy: rcL1@L2 on L1
        address rcL1ProxyOnL1;
        try rollups.createCrossChainProxy(address(rcL1), L2_ROLLUP_ID) returns (address p) {
            rcL1ProxyOnL1 = p;
        } catch {
            rcL1ProxyOnL1 = rollups.computeCrossChainProxyAddress(address(rcL1), L2_ROLLUP_ID);
        }

        console.log("REENTRANT_L1=%s", address(rcL1));
        console.log("RC_L2_PROXY_ON_L1=%s", rcL2ProxyOnL1);
        console.log("RC_L1_PROXY_ON_L1=%s", rcL1ProxyOnL1);
        vm.stopBroadcast();
    }
}

contract DeploySetupL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address rcL1Addr = vm.envAddress("REENTRANT_L1");
        address rcL2Addr = vm.envAddress("REENTRANT_L2");

        vm.startBroadcast();
        CrossChainManagerL2 manager = CrossChainManagerL2(managerAddr);

        // Proxy for rcL1@MAINNET on L2 (rcL2's peer)
        address rcL1ProxyOnL2;
        try manager.createCrossChainProxy(rcL1Addr, MAINNET_ROLLUP_ID) returns (address p) {
            rcL1ProxyOnL2 = p;
        } catch {
            rcL1ProxyOnL2 = manager.computeCrossChainProxyAddress(rcL1Addr, MAINNET_ROLLUP_ID);
        }

        // Set rcL2's peer
        ReentrantCounter(rcL2Addr).setPeer(rcL1ProxyOnL2);

        console.log("RC_L1_PROXY_ON_L2=%s", rcL1ProxyOnL2);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute L2
// ═══════════════════════════════════════════════════════════════════════

contract ExecuteL2 is Script, ReentrantActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address rcL1Addr = vm.envAddress("REENTRANT_L1");
        address rcL2Addr = vm.envAddress("REENTRANT_L2");
        address rcL1ProxyOnL2 = vm.envAddress("RC_L1_PROXY_ON_L2");

        vm.startBroadcast();
        address alice = msg.sender;

        CrossChainManagerL2(managerAddr).loadExecutionTable(
            _l2Entries(rcL1Addr, rcL2Addr, alice),
            noStaticCalls()
        );

        // Trigger: alice calls rcL1ProxyOnL2.deepCall(2)
        (bool ok,) = rcL1ProxyOnL2.call(
            abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(2))
        );
        require(ok, "L2 trigger failed");

        console.log("done");
        console.log("rcL2.count=%s", ReentrantCounter(rcL2Addr).count());
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute L1
// ═══════════════════════════════════════════════════════════════════════

contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata statics,
        address rcL1ProxyOnL1
    ) external {
        rollups.postBatch(entries, statics, 0, 0, 0, "", "proof");
        (bool ok,) = rcL1ProxyOnL1.call(
            abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(3))
        );
        require(ok, "L1 trigger failed");
    }
}

contract Execute is Script, ReentrantActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address rcL1Addr = vm.envAddress("REENTRANT_L1");
        address rcL2Addr = vm.envAddress("REENTRANT_L2");
        address rcL1ProxyOnL1 = vm.envAddress("RC_L1_PROXY_ON_L1");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(rcL1Addr, rcL2Addr, address(batcher)),
            noStaticCalls(),
            rcL1ProxyOnL1
        );

        console.log("done");
        console.log("rcL1.count=%s", ReentrantCounter(rcL1Addr).count());
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("RC_L1_PROXY_ON_L1");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(
            abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(3))
        ));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, ReentrantActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("REENTRANT_L1")) return "ReentrantCounter(L1)";
        if (a == vm.envAddress("REENTRANT_L2")) return "ReentrantCounter(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == ReentrantCounter.deepCall.selector) return "deepCall";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address rcL1Addr = vm.envAddress("REENTRANT_L1");
        address rcL2Addr = vm.envAddress("REENTRANT_L2");
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(rcL1Addr, rcL2Addr, alice);
        bytes32 l1Hash = _entryHash(l1[0]);

        ExecutionEntry[] memory l2 = _l2Entries(rcL1Addr, rcL2Addr, alice);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 2 calls, 2 nested - reentrant) ===");
        _logEntry(0, l1[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 2 calls, 1 nested - reentrant) ===");
        _logL2Entry(0, l2[0]);
    }
}
