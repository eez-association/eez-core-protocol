// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {
    IEEZ,
    RootUpdate,
    L2ToL1Call,
    ExecutionEntry,
    StaticExecutionEntry
} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, RevertCounter, SafeCounterAndProxy} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    getOrCreateProxy,
    crossChainCallHash,
    crossChainCallHashL2Out,
    expectedL1toL2Hash,
    noStaticEntries,
    noL2StaticEntries,
    noNestedActions,
    noL2Calls,
    RollingHashBuilder,
    immediateSingleRollupBatch
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  NestedCallRevert — a real L1 -> L2 -> L1 call whose callback fails.
//
//  Alice calls the L1 proxy for SafeCounterAndProxy on L2. SafeCAP calls
//  its L2 proxy for RevertCounter on L1; that real target reverts, SafeCAP
//  catches the error, and the outer call succeeds. This topology makes the
//  network composer observe the same failed callback committed by the tables.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract NestedCallRevertActions {
    function _incrementProxyData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector);
    }

    function _incrementData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    function _revertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "always reverts");
    }

    function _outerHash(address scapL2, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(false, alice, MAINNET_ROLLUP_ID, scapL2, L2_ROLLUP_ID, 0, _incrementProxyData());
    }

    function _l1CallbackHash(address counterL1, address scapL2) internal pure returns (bytes32) {
        return crossChainCallHash(false, scapL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementData());
    }

    function _l2CallbackHash(address counterL1, address scapL2) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(scapL2, L2_ROLLUP_ID, counterL1, MAINNET_ROLLUP_ID, 0, _incrementData());
    }

    function _l1Entries(
        address counterL1,
        address scapL2,
        address alice
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        RootUpdate[] memory deltas = new RootUpdate[](1);
        deltas[0] = RootUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-nested-call-revert"),
            etherDelta: 0
        });

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            // The callback itself reverts, so the destination-side call array
            // carries the one-call rollback window observed by the composer.
            revertNextNCalls: 1,
            isStatic: false,
            sourceAddress: scapL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: counterL1,
            value: 0,
            data: _incrementData()
        });

        bytes32 proxyEntryHash = _outerHash(scapL2, alice);
        bytes32 rh = RollingHashBuilder.entryBegin(deltas, proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, _l1CallbackHash(counterL1, scapL2));
        rh = RollingHashBuilder.appendCallEnd(rh, false, _revertData());

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

    function _l2Entries(
        address counterL1,
        address scapL2,
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
            targetAddress: scapL2,
            value: 0,
            data: _incrementProxyData()
        });

        bytes32 proxyEntryHash = _outerHash(scapL2, alice);
        bytes32 innerCch = _l2CallbackHash(counterL1, scapL2);
        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, proxyEntryHash);
        bytes32 rhFire = rh;
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(innerCch, rhFire),
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: RollingHashBuilder.appendNestedBegin(rhFire, innerCch),
            success: false,
            returnData: _revertData()
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

// Deploy the real reverting callback target on L1.
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        RevertCounter counter = new RevertCounter();
        console.log("COUNTER_L1=%s", address(counter));
        vm.stopBroadcast();
    }
}

// Deploy SafeCAP on L2, wired to the L2 proxy for the L1 target.
contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        address counterProxy = getOrCreateProxy(IEEZ(managerAddr), counterL1, MAINNET_ROLLUP_ID);
        SafeCounterAndProxy scapL2 = new SafeCounterAndProxy(Counter(counterProxy));
        console.log("COUNTER_PROXY_L2=%s", counterProxy);
        console.log("SAFE_CAP_L2=%s", address(scapL2));
        vm.stopBroadcast();
    }
}

// Deploy the L1 trigger proxy for SafeCAP on L2.
contract Deploy2 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address scapL2 = vm.envAddress("SAFE_CAP_L2");

        vm.startBroadcast();
        address scapProxy = getOrCreateProxy(IEEZ(rollupsAddr), scapL2, L2_ROLLUP_ID);
        console.log("SAFE_CAP_PROXY=%s", scapProxy);
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is Script, NestedCallRevertActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address scapL2 = vm.envAddress("SAFE_CAP_L2");

        vm.startBroadcast();
        EEZL2(managerAddr).executeIncomingCrossChainCall(_l2Entries(counterL1, scapL2, msg.sender), noL2StaticEntries());
        require(SafeCounterAndProxy(scapL2).counter() == 1, "outer call must complete");
        require(SafeCounterAndProxy(scapL2).targetCounter() == 0, "reverted callback returned a value");
        require(SafeCounterAndProxy(scapL2).lastCallFailed(), "callback failure was not caught");
        console.log("done");
        vm.stopBroadcast();
    }
}

contract Execute is Script, NestedCallRevertActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address scapL2 = vm.envAddress("SAFE_CAP_L2");
        address scapProxy = vm.envAddress("SAFE_CAP_PROXY");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL1, scapL2, msg.sender), noStaticEntries()
                )
            );
        (bool ok,) = scapProxy.call(abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector));
        require(ok, "outer call failed");
        require(RevertCounter(counterL1).counter() == 0, "reverting callback changed state");
        console.log("done");
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("SAFE_CAP_PROXY"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(SafeCounterAndProxy.incrementProxy.selector)));
    }
}

contract ComputeExpected is ComputeExpectedBase, NestedCallRevertActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L1")) return "RevertCounter(L1)";
        if (a == vm.envAddress("SAFE_CAP_L2")) return "SafeCounterAndProxy(L2)";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == SafeCounterAndProxy.incrementProxy.selector) return "incrementProxy";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL1 = vm.envAddress("COUNTER_L1");
        address scapL2 = vm.envAddress("SAFE_CAP_L2");
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(counterL1, scapL2, alice);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL1, scapL2, alice);
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        _printL1CallHashes(l1);
        _printL2CallHashes(l2);
        _printL1Table(l1);
        _printL2Table(l2);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 naturally reverting L2-to-L1 callback) ===");
        _logEntry(0, l1[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 success=false outgoing callback) ===");
        _logL2Entry(0, l2[0]);
    }
}
