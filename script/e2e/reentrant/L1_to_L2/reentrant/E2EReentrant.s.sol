// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {
    StateUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry,
    StaticExecutionEntry
} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {ReentrantCounter} from "../../../../../test/mocks/ReentrantCounter.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    crossChainCallHashL2Out,
    noStaticEntries,
    noCalls,
    expectedL1toL2Hash,
    RollingHashBuilder,
    immediateSingleRollupBatch
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Reentrant — 4-hop cross-chain reentrant chain via deepCall(3)
//
//  L1.dC(3) -> L2.dC(2) -> L1.dC(1) -> L2.dC(0)
//
//  ReentrantCounter.deepCall(N):
//    if N > 0: peer.deepCall(N-1)   // cross-chain via proxy
//    return ++count
//
//  DERIVATION-TRUE model: the trigger is a PLAIN L1 call — alice calls
//  rcL1.deepCall(3) directly, no protocol involvement. Every protocol
//  object below is derivable from executions that literally happen:
//
//  The call that enters the protocol is made by rcL1's OWN CODE:
//  rcL1.deepCall(3) calls its peer proxy (rcL2 @ L2) with dC(2). That
//  proxy call IS the cross-chain call — the composer/prover delivers
//  exactly it on L2, and the L1 entry is keyed by exactly it:
//    proxyEntryHash = H(rcL1@MAINNET -> rcL2@L2, dC(2))   (same key both sides)
//
//  L1 entry (consumed by the peer-proxy call, top-level):
//    l2ToL1Calls[0]: rcL1.dC(1) from rcL2@L2 — the one call the L2
//      execution sends back to run ON L1. While it runs, rcL1's code
//      calls the peer proxy with dC(0) => expectedL1ToL2Calls[0] frame
//      (sub-array empty: rcL2.dC(0) makes no calls back; retData = 1).
//      rcL1.count++ -> 1, dC(1) returns 1.
//    entry.returnData = 2 (what rcL2.dC(2) returns) — handed to rcL1's
//      peer call; the outer dC(3) then does count++ -> 2.
//
//  L2 entry (system-delivered via executeIncomingCrossChainCall):
//    incomingCalls[0]: rcL2.dC(2) from rcL1@MAINNET (the delivered call —
//      target has real code). rcL2's code calls its peer proxy with dC(1)
//      => expectedOutgoingCalls[0] frame (retData = 1, the L1 dC(1)
//      result; sub-array = [rcL2.dC(0) from rcL1] — the call L1's dC(1)
//      execution sends back). rcL2.count++ -> 1 then -> 2.
//
//  After execution: rcL1.count = 2, rcL2.count = 2.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract ReentrantActions {
    // ── calldata ──

    function _dc(uint256 n) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ReentrantCounter.deepCall.selector, n);
    }

    // ── shared proxy-entry identity ──

    /// @dev The cross-chain call rcL1's code makes: rcL1 -> rcL2Proxy.dC(2). L1's
    ///      executeCrossChainCall folds source=rcL1 MAINNET, target=rcL2 L2; the L2
    ///      delivery folds the same eight fields — one key on both sides.
    function _sharedProxyEntryHash(address rcL2, address rcL1) internal pure returns (bytes32) {
        return crossChainCallHash(false, rcL1, MAINNET_ROLLUP_ID, rcL2, L2_ROLLUP_ID, 0, _dc(2));
    }

    // ── L1 cross-chain call hashes ──

    /// @dev L1 entry call dC(1): executed ON L1 (target rcL1 MAINNET), sourced from rcL2 L2.
    function _cchSub1(address rcL1, address rcL2) internal pure returns (bytes32) {
        return crossChainCallHash(false, rcL2, L2_ROLLUP_ID, rcL1, MAINNET_ROLLUP_ID, 0, _dc(1));
    }

    /// @dev L1 reentry dC(0): rcL1 -> rcL2Proxy.dC(0) fired while dC(1) runs. Source=rcL1
    ///      MAINNET, target=rcL2 L2.
    function _cchReentry0(address rcL2, address rcL1) internal pure returns (bytes32) {
        return crossChainCallHash(false, rcL1, MAINNET_ROLLUP_ID, rcL2, L2_ROLLUP_ID, 0, _dc(0));
    }

    // ── L2 cross-chain call hashes (self = L2_ROLLUP_ID). The outgoing reentry keys with
    //    the L2-outgoing hash (`callGas` = 0 — the devnet deploys `EEZL2` with
    //    `useGasLeft = false`); calls executed ON the L2 fold CALL_BEGIN with callGas = 0. ──

    /// @dev L2 top-level incoming dC(2): executed ON L2 (target rcL2 L2), sourced from rcL1
    ///      MAINNET. Equals `_sharedProxyEntryHash` — same eight fields.
    function _cchL2Top2(address rcL2, address rcL1) internal pure returns (bytes32) {
        return crossChainCallHash(false, rcL1, MAINNET_ROLLUP_ID, rcL2, L2_ROLLUP_ID, 0, _dc(2));
    }

    /// @dev L2 outgoing reentry dC(1): rcL2 -> rcL1Proxy.dC(1). Source rollup forced to L2;
    ///      target=rcL1 MAINNET. Outgoing — L2-outgoing key (NESTED_BEGIN fold + expectedOutgoingHash).
    function _cchL2Out1(address rcL1, address rcL2) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(rcL2, L2_ROLLUP_ID, rcL1, MAINNET_ROLLUP_ID, 0, _dc(1));
    }

    /// @dev L2 Frame incoming sub-call dC(0): executed ON L2 (target rcL2 L2), sourced from rcL1 MAINNET.
    function _cchL2Sub0(address rcL2, address rcL1) internal pure returns (bytes32) {
        return crossChainCallHash(false, rcL1, MAINNET_ROLLUP_ID, rcL2, L2_ROLLUP_ID, 0, _dc(0));
    }

    // ── Entry builders ──

    function _l1Entries(address rcL1, address rcL2) internal pure returns (ExecutionEntry[] memory entries) {
        StateUpdate[] memory deltas = new StateUpdate[](1);
        deltas[0] = StateUpdate({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-reentrant"),
            etherDelta: 0
        });

        bytes32 proxyEntryHash = _sharedProxyEntryHash(rcL2, rcL1);

        // The one call the L2 execution sends back to run ON L1: rcL1.dC(1) from rcL2.
        L2ToL1Call[] memory topCalls = new L2ToL1Call[](1);
        topCalls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: rcL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: rcL1,
            value: 0,
            data: _dc(1)
        });

        // Rolling hash — thread `rh`, capturing the fire-time value at the reentry so the
        // expectedL1toL2Hash key uses the exact running hash the contract sees.
        bytes32 cch1 = _cchSub1(rcL1, rcL2);
        bytes32 cch0 = _cchReentry0(rcL2, rcL1);

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, cch1); // dC(1) begins on L1
        bytes32 rhFire = rh; // reentry dC(0) fires here (rcL1's code calls its peer)
        rh = RollingHashBuilder.appendNestedBegin(rh, cch0);
        rh = RollingHashBuilder.appendNestedEnd(rh); // frame sub-array empty
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1))); // dC(1) returns 1

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(cch0, rhFire),
            l2ToL1Calls: noCalls(), // rcL2.dC(0) makes no calls back to L1
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            // rcL2.dC(0) returns ++count == 1.
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateUpdates: deltas,
            proxyEntryHash: proxyEntryHash,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: topCalls,
            expectedL1ToL2Calls: nested,
            rollingHash: rh,
            success: true,
            // Returned to rcL1's peer call: rcL2.deepCall(2) returns ++count == 2.
            returnData: abi.encode(uint256(2))
        });
    }

    /// @dev L2-side entry, delivered via executeIncomingCrossChainCall(rcL2, 0, dC(2),
    ///      rcL1, MAINNET, ...): incomingCalls[0] IS the inbound call and proxyEntryHash
    ///      is the hash of those explicit params (== the shared key).
    function _l2Entries(address rcL1, address rcL2) internal pure returns (L2ExecutionEntry[] memory entries) {
        bytes32 proxyEntryHash = _sharedProxyEntryHash(rcL2, rcL1);

        // Top-level incoming call: rcL2.dC(2) from rcL1 — the delivered call itself.
        CrossChainCall[] memory topCalls = new CrossChainCall[](1);
        topCalls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: rcL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: rcL2,
            value: 0,
            data: _dc(2)
        });

        // Outgoing frame's own incoming sub-array: rcL2.dC(0) from rcL1 — the call L1's
        // dC(1) execution sends back to L2.
        CrossChainCall[] memory frameSub = new CrossChainCall[](1);
        frameSub[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: rcL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: rcL2,
            value: 0,
            data: _dc(0)
        });

        bytes32 cch2 = _cchL2Top2(rcL2, rcL1);
        bytes32 cch1 = _cchL2Out1(rcL1, rcL2);
        bytes32 cch0 = _cchL2Sub0(rcL2, rcL1);

        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, cch2); // top-level incoming dC(2) begins
        bytes32 rhFire = rh; // outgoing reentry dC(1) fires here (rcL2's code calls its peer)
        rh = RollingHashBuilder.appendNestedBegin(rh, cch1);
        rh = RollingHashBuilder.appendCallBegin(rh, cch0); // incoming sub-call dC(0) begins
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1))); // dC(0) returns 1
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(2))); // dC(2) returns 2

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(cch1, rhFire),
            incomingCalls: frameSub,
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            // rcL1.dC(1) returns ++count == 1.
            returnData: abi.encode(uint256(1))
        });

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: proxyEntryHash,
            incomingCalls: topCalls,
            expectedOutgoingCalls: nested,
            rollingHash: rh,
            success: true,
            // Top-level rcL2.deepCall(2) returns ++count == 2 after the chain.
            returnData: abi.encode(uint256(2))
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
        EEZ rollups = EEZ(rollupsAddr);

        // Proxy for rcL2@L2 on L1 (rcL1's peer)
        address rcL2ProxyOnL1;
        try rollups.createCrossChainProxy(rcL2Addr, L2_ROLLUP_ID) returns (address p) {
            rcL2ProxyOnL1 = p;
        } catch {
            rcL2ProxyOnL1 = rollups.computeCrossChainProxyAddress(rcL2Addr, L2_ROLLUP_ID);
        }

        // Deploy rcL1 on L1 with peer = rcL2ProxyOnL1
        ReentrantCounter rcL1 = new ReentrantCounter(rcL2ProxyOnL1);

        console.log("REENTRANT_L1=%s", address(rcL1));
        console.log("RC_L2_PROXY_ON_L1=%s", rcL2ProxyOnL1);
        vm.stopBroadcast();
    }
}

contract DeploySetupL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address rcL1Addr = vm.envAddress("REENTRANT_L1");
        address rcL2Addr = vm.envAddress("REENTRANT_L2");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

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

/// @title ExecuteL2 — system-driven delivery of the cross-chain call, exactly as the
///        composer produces it: one executeIncomingCrossChainCall for the top-level
///        call rcL1's code made on L1, targeting the real rcL2.
/// @dev SYSTEM_ADDRESS is the local deployer, so the broadcaster can call it directly.
contract ExecuteL2 is Script, ReentrantActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address rcL1Addr = vm.envAddress("REENTRANT_L1");
        address rcL2Addr = vm.envAddress("REENTRANT_L2");

        vm.startBroadcast();

        EEZL2(managerAddr)
            .executeIncomingCrossChainCall(
                rcL2Addr,
                0,
                _dc(2),
                rcL1Addr,
                MAINNET_ROLLUP_ID,
                _l2Entries(rcL1Addr, rcL2Addr),
                new L2StaticExecutionEntry[](0)
            );

        uint256 finalCount = ReentrantCounter(rcL2Addr).count();
        require(finalCount == 2, "rcL2.count must be 2 after the reentrant chain");

        console.log("done");
        console.log("rcL2.count=%s", finalCount);
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute L1
// ═══════════════════════════════════════════════════════════════════════

/// @title Execute — local mode: postAndVerifyBatch tx + a PLAIN trigger call from the EOA.
///        The trigger is not a protocol op: alice calls rcL1.deepCall(3) directly, and the
///        protocol entry is consumed by the peer-proxy call rcL1's own code makes (dC(2)).
///        The runner mines batch + trigger in one block (execute_l1_same_block).
contract Execute is Script, ReentrantActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address rcL1Addr = vm.envAddress("REENTRANT_L1");
        address rcL2Addr = vm.envAddress("REENTRANT_L2");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(proofSystemAddr, L2_ROLLUP_ID, _l1Entries(rcL1Addr, rcL2Addr), noStaticEntries())
            );
        // Trigger: plain call — rcL1's code fires the cross-chain leg itself.
        (bool ok,) = rcL1Addr.call(_dc(3));
        require(ok, "L1 trigger failed");

        uint256 finalCount = ReentrantCounter(rcL1Addr).count();
        require(finalCount == 2, "rcL1.count must be 2 after the reentrant chain");

        console.log("done");
        console.log("rcL1.count=%s", finalCount);
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        // Plain contract call — the cross-chain call is made by rcL1's code, not the user.
        address target = vm.envAddress("REENTRANT_L1");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(3))));
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

        ExecutionEntry[] memory l1 = _l1Entries(rcL1Addr, rcL2Addr);
        bytes32 l1Hash = _entryHash(l1[0]);

        L2ExecutionEntry[] memory l2 = _l2Entries(rcL1Addr, rcL2Addr);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        _printL1CallHashes(l1);
        _printL2CallHashes(l2);
        _printL1Table(l1);
        _printL2Table(l2);
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, 1 nested - reentrant) ===");
        _logEntry(0, l1[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 1 nested - reentrant) ===");
        _logL2Entry(0, l2[0]);
    }
}
