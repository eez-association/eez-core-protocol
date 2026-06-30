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
import {Counter, CounterAndProxy, NestedCaller} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    expectedL1toL2Hash,
    noStaticLookups,
    noCalls,
    noL2Calls,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  DeepNested scenario - two levels of nested actions, two-sided.
//
//  L1 side (Execute):
//    1. Alice triggers entry via nestedCallerProxy (proxy on L1 for NC@L2)
//    2. Entry's calls[0] invokes NestedCaller@L1.callNested() via a source
//       proxy for alice on Mainnet.
//    3. NestedCaller calls capProxy (proxy on L1 for CAP@L2) reentrantly →
//       expectedL1ToL2Calls[0] consumed.
//       - expectedL1ToL2Calls[0].callCount=1 triggers _processNCalls(1)
//       - Inside that, manager invokes CAP@L1.incrementProxy() via source
//         proxy for NC; CAP calls counterProxy (proxy on L1 for Counter@L2)
//         reentrantly → expectedL1ToL2Calls[1] consumed (callCount=0, returns 1).
//    4. Both reentrant calls consumed, deep rolling hash verified.
//
//  L2 side (ExecuteL2) — system-driven mirror:
//    1. SYSTEM_ADDRESS calls managerL2.executeIncomingCrossChainCall(
//         ncL2, 0, callNested, alice, MAINNET, l2Entries, lookups
//       ).
//    2. Same call chain runs on L2 against real NC/CAP/Counter contracts
//       deployed on L2, with cross-chain proxies on L2 routing the
//       reentrant calls back through managerL2 (so outgoing-call consumption
//       fires identically). Final state: Counter.counter()==1, CAP.counter==1,
//       CAP.targetCounter==1, NC.counter==1.
//
//  Rolling hash tape (identical on both sides):
//    CALL_BEGIN(1)                <- calls[0] = NC.callNested()
//      NESTED_BEGIN(1)            <- NC -> CAP proxy (nested[0])
//        CALL_BEGIN(2)            <- calls[1] = CAP.incrementProxy()
//          NESTED_BEGIN(2)        <- CAP -> Counter proxy (nested[1])
//          NESTED_END(2)          <- nested[1].callCount=0
//        CALL_END(2, true, "")    <- incrementProxy returns void
//      NESTED_END(1)
//    CALL_END(2, true, "")        <- callNumber still 2 after nested chain
//
//  Replaces deepScopeL2 from main (scope arrays don't exist in flatten).
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

abstract contract DeepNestedActions {
    /// @dev nested[1] reentry: CAP (on L1) reentrant-calls counterProxy -> Counter L2.increment()
    function _counterActionHash(address counterL2, address cap) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID, counterL2, 0, abi.encodeWithSelector(Counter.increment.selector), cap, MAINNET_ROLLUP_ID
        );
    }

    /// @dev nested[0] reentry: NestedCaller (on L1) reentrant-calls capProxy -> CAP L2.incrementProxy()
    function _capActionHash(address cap, address nestedCaller) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID,
            cap,
            0,
            abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            nestedCaller,
            MAINNET_ROLLUP_ID
        );
    }

    /// @dev outer trigger (proxyEntryHash): alice calls nestedCallerProxy -> callNested()
    function _outerActionHash(address nestedCaller, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID,
            nestedCaller,
            0,
            abi.encodeWithSelector(NestedCaller.callNested.selector),
            alice,
            MAINNET_ROLLUP_ID
        );
    }

    /// @dev top-level call: manager runs NestedCaller.callNested() ON L1 (target rollup = MAINNET)
    ///      via the source proxy for (alice, L2). Matches `_processNCalls`'s CALL_BEGIN.
    function _l1OuterCallHash(address nestedCaller, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(
            MAINNET_ROLLUP_ID,
            nestedCaller,
            0,
            abi.encodeWithSelector(NestedCaller.callNested.selector),
            alice,
            L2_ROLLUP_ID
        );
    }

    /// @dev call inside nested[0]'s frame: manager runs CAP.incrementProxy() ON L1 (target rollup =
    ///      MAINNET) via the source proxy for (nestedCaller, L2).
    function _l1CapCallHash(address cap, address nestedCaller) internal pure returns (bytes32) {
        return crossChainCallHash(
            MAINNET_ROLLUP_ID,
            cap,
            0,
            abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            nestedCaller,
            L2_ROLLUP_ID
        );
    }

    // ── L2 mirror action hashes ──
    // On L2, reentrant calls hash with sourceRollupId = ROLLUP_ID = L2_ROLLUP_ID (forced by
    // executeCrossChainCall). The cross-chain proxies on L2 are created with originalRollupId =
    // MAINNET_ROLLUP_ID (the remote network — a proxy may never represent the L2's own id, else
    // SameNetworkProxy(1)), so each reentrant hash's targetRollupId is MAINNET_ROLLUP_ID. The
    // proxies still route through managerL2 to trigger nested-action consumption.

    /// @dev L2 nested[1]: CAP on L2 calls counterProxyOnL2 (representing Counter on L2)
    function _l2CounterActionHash(address counterL2, address capL2) internal pure returns (bytes32) {
        return crossChainCallHash(
            MAINNET_ROLLUP_ID, counterL2, 0, abi.encodeWithSelector(Counter.increment.selector), capL2, L2_ROLLUP_ID
        );
    }

    /// @dev L2 nested[0]: NestedCaller on L2 calls capProxyOnL2 (representing CAP on L2)
    function _l2CapActionHash(address capL2, address ncL2) internal pure returns (bytes32) {
        return crossChainCallHash(
            MAINNET_ROLLUP_ID,
            capL2,
            0,
            abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            ncL2,
            L2_ROLLUP_ID
        );
    }

    /// @dev L2 outer (proxyEntryHash AND incoming top-level CALL_BEGIN): SYSTEM-driven call to
    ///      NestedCaller on L2 with source = (alice, MAINNET); target on this L2 (L2_ROLLUP_ID).
    function _l2OuterActionHash(address ncL2, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID, ncL2, 0, abi.encodeWithSelector(NestedCaller.callNested.selector), alice, MAINNET_ROLLUP_ID
        );
    }

    /// @dev L2 call inside nested[0]'s frame: manager runs CAP L2.incrementProxy() on this L2
    ///      (target rollup = L2_ROLLUP_ID) via sourceProxy(ncL2, MAINNET). PENDING EEZL2.
    function _l2CapCallHash(address capL2, address ncL2) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID,
            capL2,
            0,
            abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            ncL2,
            MAINNET_ROLLUP_ID
        );
    }

    function _l1Entries(address counterL2, address cap, address nestedCaller, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-deep-nested"),
            etherDelta: 0
        });

        bytes32 proxyEntryHash = _outerActionHash(nestedCaller, alice);

        // Top-level call: manager runs NestedCaller.callNested() on L1 via sourceProxy(alice, L2).
        L2ToL1Call[] memory topCalls = new L2ToL1Call[](1);
        topCalls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: nestedCaller,
            value: 0,
            data: abi.encodeWithSelector(NestedCaller.callNested.selector)
        });

        // nested[0]'s own sub-array: while NC->cap reentry runs, the manager executes
        // CAP.incrementProxy() on L1 via sourceProxy(nestedCaller, L2).
        L2ToL1Call[] memory capCalls = new L2ToL1Call[](1);
        capCalls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: nestedCaller,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector)
        });

        bytes32 ccOuter = _l1OuterCallHash(nestedCaller, alice);
        bytes32 ccCap = _capActionHash(cap, nestedCaller);
        bytes32 ccCapCall = _l1CapCallHash(cap, nestedCaller);
        bytes32 ccCounter = _counterActionHash(counterL2, cap);

        // Rolling hash, threaded through the two-level nesting (matches EEZ exactly):
        //   CALL_BEGIN(NC.callNested)
        //     NESTED_BEGIN(NC->cap)
        //       CALL_BEGIN(CAP.incrementProxy)
        //         NESTED_BEGIN(CAP->counter) NESTED_END
        //       CALL_END(true,"")
        //     NESTED_END
        //   CALL_END(true,"")
        bytes32 rh = RollingHashBuilder.entryBegin(deltas, proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, ccOuter);
        bytes32 rhFire0 = rh; // NC->cap reentry fires here
        rh = RollingHashBuilder.appendNestedBegin(rh, ccCap);
        rh = RollingHashBuilder.appendCallBegin(rh, ccCapCall);
        bytes32 rhFire1 = rh; // CAP->counter reentry fires here
        rh = RollingHashBuilder.appendNestedBegin(rh, ccCounter);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](2);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(ccCap, rhFire0),
            l2ToL1Calls: capCalls,
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: ""
        });
        nested[1] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(ccCounter, rhFire1),
            l2ToL1Calls: noCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
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
            returnData: ""
        });
    }

    /// @dev L2 mirror entry — same structural shape as the L1 entry, but with all
    /// addresses resolved on the L2 chain. The reentrant chain runs through real
    /// L2 contracts (NestedCaller → CAP → Counter) wired via cross-chain proxies on
    /// L2 that route back through managerL2, so the nested-call consumption fires
    /// identically. The rolling hash mirrors the L1 entry's structure.
    /// NOTE: L2 rolling-hash + outgoing-call keying are PENDING EEZL2 (impl not migrated); re-verify when EEZL2.sol lands.
    function _l2Entries(address counterL2, address capL2, address ncL2, address alice)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        bytes32 proxyEntryHash = _l2OuterActionHash(ncL2, alice);

        // incomingCalls[0]: outer — manager runs NestedCaller@L2 via sourceProxy(alice, MAINNET).
        CrossChainCall[] memory topCalls = new CrossChainCall[](1);
        topCalls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: ncL2,
            value: 0,
            data: abi.encodeWithSelector(NestedCaller.callNested.selector)
        });

        // nested[0]'s own sub-array: manager runs CAP@L2.incrementProxy() via sourceProxy(ncL2, MAINNET).
        CrossChainCall[] memory capCalls = new CrossChainCall[](1);
        capCalls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: ncL2,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: capL2,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector)
        });

        // PENDING EEZL2: rolling-hash threading + outgoing keying mirror the L1 algorithm.
        bytes32 ccOuter = _l2OuterActionHash(ncL2, alice);
        bytes32 ccCap = _l2CapActionHash(capL2, ncL2);
        bytes32 ccCapCall = _l2CapCallHash(capL2, ncL2);
        bytes32 ccCounter = _l2CounterActionHash(counterL2, capL2);

        bytes32 rh = RollingHashBuilder.entryBeginL2(proxyEntryHash);
        rh = RollingHashBuilder.appendCallBegin(rh, ccOuter);
        bytes32 rhFire0 = rh;
        rh = RollingHashBuilder.appendNestedBegin(rh, ccCap);
        rh = RollingHashBuilder.appendCallBegin(rh, ccCapCall);
        bytes32 rhFire1 = rh;
        rh = RollingHashBuilder.appendNestedBegin(rh, ccCounter);
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](2);
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(ccCap, rhFire0), // PENDING EEZL2 keying
            incomingCalls: capCalls,
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: ""
        });
        nested[1] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(ccCounter, rhFire1), // PENDING EEZL2 keying
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: proxyEntryHash,
            incomingCalls: topCalls,
            expectedOutgoingCalls: nested,
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }
}

contract DeployL2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        // Real Counter contract on L2 — destination of the deepest reentrant call.
        Counter counter = new Counter();

        // Proxy on L2 representing "Counter@L2" — routes back through managerL2
        // so reentrant calls trigger _consumeNestedAction with the matching hash.
        address counterProxyOnL2;
        try manager.createCrossChainProxy(address(counter), MAINNET_ROLLUP_ID) returns (address p) {
            counterProxyOnL2 = p;
        } catch {
            counterProxyOnL2 = manager.computeCrossChainProxyAddress(address(counter), MAINNET_ROLLUP_ID);
        }

        // Real CounterAndProxy on L2, wrapping counterProxyOnL2 (so cap.incrementProxy()
        // triggers a reentrant cross-chain call to managerL2 instead of a local call).
        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxyOnL2));

        // Proxy on L2 representing "CAP@L2" — used by NestedCaller as its `target`.
        address capProxyOnL2;
        try manager.createCrossChainProxy(address(cap), MAINNET_ROLLUP_ID) returns (address p) {
            capProxyOnL2 = p;
        } catch {
            capProxyOnL2 = manager.computeCrossChainProxyAddress(address(cap), MAINNET_ROLLUP_ID);
        }

        // Real NestedCaller on L2 — destination of the outer call. Wraps capProxyOnL2
        // so callNested() triggers a reentrant cross-chain call.
        NestedCaller nc = new NestedCaller(CounterAndProxy(capProxyOnL2));

        console.log("COUNTER_L2=%s", address(counter));
        console.log("COUNTER_PROXY_ON_L2=%s", counterProxyOnL2);
        console.log("CAP_L2=%s", address(cap));
        console.log("CAP_PROXY_ON_L2=%s", capProxyOnL2);
        console.log("NESTED_CALLER_L2=%s", address(nc));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2 = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        EEZ rollups = EEZ(rollupsAddr);

        // counterProxy: proxy for Counter@L2 on L1
        address counterProxy;
        try rollups.createCrossChainProxy(counterL2, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2, L2_ROLLUP_ID);
        }

        // CAP: CounterAndProxy(counterProxy) on L1
        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        // capProxy: proxy for CAP@L2 on L1
        address capProxy;
        try rollups.createCrossChainProxy(address(cap), L2_ROLLUP_ID) returns (address p) {
            capProxy = p;
        } catch {
            capProxy = rollups.computeCrossChainProxyAddress(address(cap), L2_ROLLUP_ID);
        }

        // NestedCaller wraps CAP — calls cap.incrementProxy()
        NestedCaller nc = new NestedCaller(CounterAndProxy(capProxy));

        // ncProxy: proxy for NestedCaller@L2 on L1 (trigger point)
        address ncProxy;
        try rollups.createCrossChainProxy(address(nc), L2_ROLLUP_ID) returns (address p) {
            ncProxy = p;
        } catch {
            ncProxy = rollups.computeCrossChainProxyAddress(address(nc), L2_ROLLUP_ID);
        }

        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(cap));
        console.log("CAP_PROXY=%s", capProxy);
        console.log("NESTED_CALLER=%s", address(nc));
        console.log("NESTED_CALLER_PROXY=%s", ncProxy);
        vm.stopBroadcast();
    }
}

contract Batcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        StaticLookup[] calldata staticLookups,
        address ncProxy
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
        (bool ok,) = ncProxy.call(abi.encodeWithSelector(NestedCaller.callNested.selector));
        require(ok, "outer call failed");
    }
}

contract Execute is Script, DeepNestedActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");
        address ncAddr = vm.envAddress("NESTED_CALLER");
        address ncProxy = vm.envAddress("NESTED_CALLER_PROXY");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        console.log("BATCHER_L1=%s", address(batcher));

        batcher.execute(
            EEZ(rollupsAddr),
            proofSystemAddr,
            _l1Entries(counterL2, capAddr, ncAddr, address(batcher)),
            noStaticLookups(),
            ncProxy
        );

        console.log("done");
        console.log("nc.counter=%s", NestedCaller(ncAddr).counter());
        console.log("cap.counter=%s", CounterAndProxy(capAddr).counter());
        console.log("cap.targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("NESTED_CALLER_PROXY");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(NestedCaller.callNested.selector)));
    }
}

/// @title ExecuteL2 — local mode: SYSTEM-driven L2 mirror of the deep-nested chain.
/// @dev SYSTEM_ADDRESS is the local deployer (anvil account 0), so the broadcaster
///      calls executeIncomingCrossChainCall directly. _processNCalls lazily creates
///      the source proxy for `(alice, MAINNET_ROLLUP_ID)` and forwards callNested()
///      into NestedCaller (on L2), which calls capProxyOnL2 → managerL2 consumes
///      a nested call → CAP (on L2) incrementProxy → counterProxyOnL2 → consumes
///      another nested call → Counter returns the cached abi.encode(1). Final
///      state: counter==1, cap.counter==1, cap.targetCounter==1, nc.counter==1.
/// Env: MANAGER_L2, COUNTER_L2, CAP_L2, NESTED_CALLER_L2
contract ExecuteL2 is Script, DeepNestedActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address capL2 = vm.envAddress("CAP_L2");
        address ncL2 = vm.envAddress("NESTED_CALLER_L2");

        vm.startBroadcast();
        address alice = msg.sender;

        EEZL2(managerAddr)
            .executeIncomingCrossChainCall(
                ncL2,
                0,
                abi.encodeWithSelector(NestedCaller.callNested.selector),
                alice,
                MAINNET_ROLLUP_ID,
                _l2Entries(counterL2, capL2, ncL2, alice),
                new L2StaticLookup[](0)
            );

        console.log("done");
        console.log("nc.counter=%s", NestedCaller(ncL2).counter());
        console.log("cap.counter=%s", CounterAndProxy(capL2).counter());
        console.log("cap.targetCounter=%s", CounterAndProxy(capL2).targetCounter());
        // Counter.counter stays at 0 — the innermost call is short-circuited by
        // expectedOutgoingCalls[1]'s cached returnData rather than reaching the real Counter.
        console.log("counter.counter=%s (cached return; never actually incremented)", Counter(counterL2).counter());
        vm.stopBroadcast();
    }
}

contract ComputeExpected is ComputeExpectedBase, DeepNestedActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("COUNTER_AND_PROXY")) return "CounterAndProxy";
        if (a == vm.envAddress("NESTED_CALLER")) return "NestedCaller";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        if (sel == CounterAndProxy.incrementProxy.selector) return "incrementProxy";
        if (sel == NestedCaller.callNested.selector) return "callNested";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address counterL2 = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");
        address ncAddr = vm.envAddress("NESTED_CALLER");
        address capL2 = vm.envAddress("CAP_L2");
        address ncL2 = vm.envAddress("NESTED_CALLER_L2");
        // L1 source is the Batcher contract Execute deploys. L2 source is the script broadcaster
        // (SYSTEM) acting as alice. BATCHER_L1 is exported by run-local.sh from Execute output.
        address aliceL1 = vm.envOr("BATCHER_L1", msg.sender);
        address aliceL2 = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(counterL2, capAddr, ncAddr, aliceL1);
        bytes32 l1Hash = _entryHash(l1[0]);

        L2ExecutionEntry[] memory l2 = _l2Entries(counterL2, capL2, ncL2, aliceL2);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2[0].proxyEntryHash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, 2 nested - deep) ===");
        _logEntry(0, l1[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 2 nested - mirror) ===");
        _logL2Entry(0, l2[0]);
    }
}
