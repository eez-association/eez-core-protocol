// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {
    EEZ,
    ProofSystemBatchPerVerificationEntries,
    ExpectedStateRootPerRollup,
    RollupIdWithProofSystems
} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry,
    StaticLookup
} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticLookup as L2StaticLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";
import {ReentrantCounter} from "../../../test/mocks/ReentrantCounter.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noStaticLookups,
    noCalls,
    expectedL1toL2Hash,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Reentrant — 4-hop cross-chain reentrant chain via deepCall(3)
//
//  L1.dC(3) -> L2.dC(2) -> L1.dC(1) -> L2.dC(0)
//
//  ReentrantCounter.deepCall(N):
//    if N > 0: peer.deepCall(N-1)   // cross-chain via proxy
//    return ++count
//
//  NEW (flatten) model — L1 (1 entry, 1 top-level call, 2 expectedL1ToL2Calls):
//    l2ToL1Calls[0]: rcL1.dC(3) from batcher (top-level, executed ON L1)
//      -> reenters rcL2Proxy.dC(2)  => expectedL1ToL2Calls[0] (Frame A), keyed at rhFireA
//         Frame A sub-array = [ rcL1.dC(1) from rcL2 ]
//           -> reenters rcL2Proxy.dC(0)  => expectedL1ToL2Calls[1] (Frame B), keyed at rhFireB
//              Frame B sub-array = [] (rcL2.dC(0) makes no further peer call)
//              -> rcL1.count++ -> 1, dC(1) returns 1
//      -> rcL1.count++ -> 2, dC(3) returns 2
//
//  NEW model — L2 (1 entry, 1 top-level incomingCall, 1 expectedOutgoingCall):
//    incomingCalls[0]: rcL2.dC(2) from rcL1 (top-level, executed ON L2)
//      -> reenters rcL1Proxy.dC(1)  => expectedOutgoingCalls[0] (Frame), keyed at rhFire
//         Frame sub-array (incomingCalls) = [ rcL2.dC(0) from rcL1 ]
//           -> rcL2.count++ -> 1, dC(0) returns 1
//      -> rcL2.count++ -> 2, dC(2) returns 2
//
//  After execution: rcL1.count=2, rcL2.count=2
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract ReentrantActions {
    // ── calldata ──

    function _dc(uint256 n) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ReentrantCounter.deepCall.selector, n);
    }

    // ── L1 cross-chain call hashes ──

    /// @dev L1 proxy-entry identity: batcher -> rcL1.dC(3). The proxy for (rcL1, L2) folds
    ///      source=batcher MAINNET, target=rcL1 L2.
    function _l1ProxyEntryHash(address rcL1, address batcher) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, rcL1, 0, _dc(3), batcher, MAINNET_ROLLUP_ID);
    }

    /// @dev L1 top-level call dC(3): executed ON L1 (target rcL1 MAINNET), sourced from batcher L2
    ///      (the call's `sourceRollupId` must be in the entry's stateDeltas).
    function _cchTop3(address rcL1, address batcher) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, rcL1, 0, _dc(3), batcher, L2_ROLLUP_ID);
    }

    /// @dev L1 reentry dC(2): rcL1 -> rcL2Proxy.dC(2). executeCrossChainCall folds source=rcL1 MAINNET,
    ///      target=rcL2 L2.
    function _cchReentry2(address rcL2, address rcL1) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, rcL2, 0, _dc(2), rcL1, MAINNET_ROLLUP_ID);
    }

    /// @dev L1 Frame-A sub-call dC(1): executed ON L1 (target rcL1 MAINNET), sourced from rcL2 L2.
    function _cchSub1(address rcL1, address rcL2) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, rcL1, 0, _dc(1), rcL2, L2_ROLLUP_ID);
    }

    /// @dev L1 reentry dC(0): rcL1 -> rcL2Proxy.dC(0). Source=rcL1 MAINNET, target=rcL2 L2.
    function _cchReentry0(address rcL2, address rcL1) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, rcL2, 0, _dc(0), rcL1, MAINNET_ROLLUP_ID);
    }

    // ── L2 cross-chain call hashes (self = L2_ROLLUP_ID). PENDING EEZL2. ──

    /// @dev L2 proxy-entry identity: alice -> rcL1Proxy.dC(2). The L2 manager forces source rollup =
    ///      ROLLUP_ID (L2); target=rcL1 MAINNET.
    function _l2ProxyEntryHash(address rcL1, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, rcL1, 0, _dc(2), alice, L2_ROLLUP_ID);
    }

    /// @dev L2 top-level incoming dC(2): executed ON L2 (target rcL2 L2), sourced from rcL1 MAINNET.
    function _cchL2Top2(address rcL2, address rcL1) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, rcL2, 0, _dc(2), rcL1, MAINNET_ROLLUP_ID);
    }

    /// @dev L2 outgoing reentry dC(1): rcL2 -> rcL1Proxy.dC(1). Source rollup forced to L2; target=rcL1 MAINNET.
    function _cchL2Out1(address rcL1, address rcL2) internal pure returns (bytes32) {
        return crossChainCallHash(MAINNET_ROLLUP_ID, rcL1, 0, _dc(1), rcL2, L2_ROLLUP_ID);
    }

    /// @dev L2 Frame incoming sub-call dC(0): executed ON L2 (target rcL2 L2), sourced from rcL1 MAINNET.
    function _cchL2Sub0(address rcL2, address rcL1) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, rcL2, 0, _dc(0), rcL1, MAINNET_ROLLUP_ID);
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
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-reentrant"),
            etherDelta: 0
        });

        bytes32 proxyEntryHash = _l1ProxyEntryHash(rcL1, batcher);

        // Top-level calls: just rcL1.dC(3).
        L2ToL1Call[] memory topCalls = new L2ToL1Call[](1);
        topCalls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: batcher,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: rcL1,
            value: 0,
            data: _dc(3)
        });

        // Frame A's own sub-array: rcL1.dC(1) sourced from rcL2.
        L2ToL1Call[] memory frameASub = new L2ToL1Call[](1);
        frameASub[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: rcL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: rcL1,
            value: 0,
            data: _dc(1)
        });

        // Rolling hash — thread `rh`, capturing the fire-time value at each reentry so the
        // expectedL1toL2Hash keys use the exact running hash the contract sees.
        bytes32 cch3 = _cchTop3(rcL1, batcher);
        bytes32 cch2 = _cchReentry2(rcL2, rcL1);
        bytes32 cch1 = _cchSub1(rcL1, rcL2);
        bytes32 cch0 = _cchReentry0(rcL2, rcL1);

        bytes32 rh = RollingHashBuilder.entryBegin(deltas, proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, cch3); // top-level dC(3) begins
        bytes32 rhFireA = rh; // reentry dC(2) fires here
        rh = RollingHashBuilder.appendNestedBegin(rh, cch2);
        rh = RollingHashBuilder.appendCallBegin(rh, cch1); // Frame A sub-call dC(1) begins
        bytes32 rhFireB = rh; // reentry dC(0) fires here
        rh = RollingHashBuilder.appendNestedBegin(rh, cch0);
        rh = RollingHashBuilder.appendNestedEnd(rh); // Frame B sub-array empty
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1))); // dC(1) returns 1
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(2))); // dC(3) returns 2

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](2);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(cch2, rhFireA),
            l2ToL1Calls: frameASub,
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            // rcL2.dC(2) returns ++count == 2.
            returnData: abi.encode(uint256(2))
        });
        nested[1] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(cch0, rhFireB),
            l2ToL1Calls: noCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            // rcL2.dC(0) returns ++count == 1.
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            proxyEntryHash: proxyEntryHash,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: topCalls,
            expectedL1ToL2Calls: nested,
            rollingHash: rh,
            success: true,
            // Top-level rcL1.deepCall(3) returns ++count == 2 after the chain.
            returnData: abi.encode(uint256(2))
        });
    }

    /// @dev L2-side mirror. NOTE: L2 rolling-hash + key schema is pending the EEZL2 migration; re-verify
    ///      when EEZL2.sol lands.
    function _l2Entries(address rcL1, address rcL2, address alice)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 proxyEntryHash = _l2ProxyEntryHash(rcL1, alice);

        // Top-level incoming call: rcL2.dC(2) from rcL1.
        CrossChainCall[] memory topCalls = new CrossChainCall[](1);
        topCalls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: rcL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: rcL2,
            value: 0,
            data: _dc(2)
        });

        // Outgoing frame's own incoming sub-array: rcL2.dC(0) from rcL1.
        CrossChainCall[] memory frameSub = new CrossChainCall[](1);
        frameSub[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: rcL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: rcL2,
            value: 0,
            data: _dc(0)
        });

        // PENDING EEZL2: rolling-hash + expectedOutgoingHash schema mirrors the L1 model; can't be
        // verified until EEZL2.sol lands.
        bytes32 cch2 = _cchL2Top2(rcL2, rcL1);
        bytes32 cch1 = _cchL2Out1(rcL1, rcL2);
        bytes32 cch0 = _cchL2Sub0(rcL2, rcL1);

        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, cch2); // top-level incoming dC(2) begins
        bytes32 rhFire = rh; // outgoing reentry dC(1) fires here
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

contract ExecuteL2 is Script, ReentrantActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address rcL1Addr = vm.envAddress("REENTRANT_L1");
        address rcL2Addr = vm.envAddress("REENTRANT_L2");
        address rcL1ProxyOnL2 = vm.envAddress("RC_L1_PROXY_ON_L2");

        vm.startBroadcast();
        address alice = msg.sender;

        EEZL2(managerAddr).loadExecutionTable(_l2Entries(rcL1Addr, rcL2Addr, alice), new L2StaticLookup[](0));

        // Trigger: alice calls rcL1ProxyOnL2.deepCall(2)
        (bool ok,) = rcL1ProxyOnL2.call(abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(2)));
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
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        StaticLookup[] calldata staticLookups,
        address rcL1ProxyOnL1
    )
        external
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        uint64[] memory rids = new uint64[](1);
        rids[0] = L2_ROLLUP_ID;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](psList.length);
        for (uint256 _i = 0; _i < psList.length; _i++) {
            psIdx[_i] = uint64(_i);
        }
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](rids.length);
        for (uint256 _i = 0; _i < rids.length; _i++) {
            rps[_i] = RollupIdWithProofSystems({rollupId: rids[_i], proofSystemIndexes: psIdx});
        }

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            expectedStateRootPerRollup: new ExpectedStateRootPerRollup[](0),
            entries: entries,
            staticLookups: staticLookups,
            immediateEntryCount: 0,
            immediateStaticLookupCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs,
            blockNumber: 0
        });
        rollups.postAndVerifyBatch(batch);
        (bool ok,) = rcL1ProxyOnL1.call(abi.encodeWithSelector(ReentrantCounter.deepCall.selector, uint256(3)));
        require(ok, "L1 trigger failed");
    }
}

contract Execute is Script, ReentrantActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address rcL1Addr = vm.envAddress("REENTRANT_L1");
        address rcL2Addr = vm.envAddress("REENTRANT_L2");
        address rcL1ProxyOnL1 = vm.envAddress("RC_L1_PROXY_ON_L1");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        batcher.execute(
            EEZ(rollupsAddr),
            proofSystemAddr,
            _l1Entries(rcL1Addr, rcL2Addr, address(batcher)),
            noStaticLookups(),
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
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(rcL1Addr, rcL2Addr, alice);
        bytes32 l1Hash = _entryHash(l1[0]);

        L2ExecutionEntry[] memory l2 = _l2Entries(rcL1Addr, rcL2Addr, alice);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, 2 nested - reentrant) ===");
        _logEntry(0, l1[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 1 nested - reentrant) ===");
        _logL2Entry(0, l2[0]);
    }
}
