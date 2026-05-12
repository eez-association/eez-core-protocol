// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {StateDelta, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry, LookupCall} from "../../../src/interfaces/IEEZ.sol";
import {Counter, CounterAndProxy, NestedCaller} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    Action,
    actionHash,
    noStaticCalls,
    noLookupCalls,
    crossChainCallHash,
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
//       nestedActions[0] consumed.
//       - nestedActions[0].callCount=1 triggers _processNCalls(1)
//       - Inside that, manager invokes CAP@L1.incrementProxy() via source
//         proxy for NC; CAP calls counterProxy (proxy on L1 for Counter@L2)
//         reentrantly → nestedActions[1] consumed (callCount=0, returns 1).
//    4. Both nested actions consumed, deep rolling hash verified.
//
//  L2 side (ExecuteL2) — system-driven mirror:
//    1. SYSTEM_ADDRESS calls managerL2.executeIncomingCrossChainCall(
//         ncL2, 0, callNested, alice, MAINNET, l2Entries, lookups
//       ).
//    2. Same call chain runs on L2 against real NC/CAP/Counter contracts
//       deployed on L2, with cross-chain proxies on L2 routing the
//       reentrant calls back through managerL2 (so nestedAction consumption
//       fires identically). Final state: Counter.counter()==1, CAP.counter==1,
//       CAP.targetCounter==1, NC.counter==1.
//
//  Rolling hash tape (identical on both sides):
//    CALL_BEGIN(1)                <- calls[0] = NC.callNested()
//      NESTED_BEGIN(1)            <- NC -> CAP proxy (nestedActions[0])
//        CALL_BEGIN(2)            <- calls[1] = CAP.incrementProxy()
//          NESTED_BEGIN(2)        <- CAP -> Counter proxy (nestedActions[1])
//          NESTED_END(2)          <- nestedActions[1].callCount=0
//        CALL_END(2, true, "")    <- incrementProxy returns void
//      NESTED_END(1)
//    CALL_END(2, true, "")        <- callNumber still 2 after nested chain
//
//  Replaces deepScopeL2 from main (scope arrays don't exist in flatten).
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract DeepNestedActions {
    using RollingHashBuilder for bytes32;

    /// @dev innermost: CAP calls counterProxy -> increment()
    function _counterActionHash(address counterL2, address cap) internal pure returns (bytes32) {
        return actionHash(
            Action({
                targetRollupId: L2_ROLLUP_ID,
                targetAddress: counterL2,
                value: 0,
                data: abi.encodeWithSelector(Counter.increment.selector),
                sourceAddress: cap,
                sourceRollupId: MAINNET_ROLLUP_ID
            })
        );
    }

    /// @dev middle: NestedCaller calls capProxy -> incrementProxy()
    function _capActionHash(address cap, address nestedCaller) internal pure returns (bytes32) {
        return actionHash(
            Action({
                targetRollupId: L2_ROLLUP_ID,
                targetAddress: cap,
                value: 0,
                data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
                sourceAddress: nestedCaller,
                sourceRollupId: MAINNET_ROLLUP_ID
            })
        );
    }

    /// @dev outer trigger: alice calls nestedCallerProxy -> callNested()
    function _outerActionHash(address nestedCaller, address alice) internal pure returns (bytes32) {
        return actionHash(
            Action({
                targetRollupId: L2_ROLLUP_ID,
                targetAddress: nestedCaller,
                value: 0,
                data: abi.encodeWithSelector(NestedCaller.callNested.selector),
                sourceAddress: alice,
                sourceRollupId: MAINNET_ROLLUP_ID
            })
        );
    }

    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1); // calls[0] -> NestedCaller.callNested()  (_ccn=1)
        h = h.appendNestedBegin(1); // NestedCaller -> capProxy -> nestedActions[0]
        h = h.appendCallBegin(2); // calls[1] inside nested (_ccn=2)
        h = h.appendNestedBegin(2); // CAP -> counterProxy -> nestedActions[1]
        h = h.appendNestedEnd(2);
        h = h.appendCallEnd(2, true, ""); // calls[1] ends (_ccn=2)
        h = h.appendNestedEnd(1);
        // _currentCallNumber is now 2 (advanced by nested), so outer CALL_END uses 2
        h = h.appendCallEnd(2, true, ""); // calls[0] ends (_ccn still 2)
    }

    // ── L2 mirror action hashes ──
    // On L2, reentrant calls hash with sourceRollupId = ROLLUP_ID = L2_ROLLUP_ID.
    // The cross-chain proxies on L2 are created with originalRollupId = L2_ROLLUP_ID
    // (a self-referential proxy chain that still routes through managerL2 to trigger
    // nested-action consumption).

    /// @dev L2 nested[1]: CAP on L2 calls counterProxyOnL2 (representing Counter on L2)
    function _l2CounterActionHash(address counterL2, address capL2) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID, counterL2, 0, abi.encodeWithSelector(Counter.increment.selector), capL2, L2_ROLLUP_ID
        );
    }

    /// @dev L2 nested[0]: NestedCaller on L2 calls capProxyOnL2 (representing CAP on L2)
    function _l2CapActionHash(address capL2, address ncL2) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID, capL2, 0, abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector), ncL2, L2_ROLLUP_ID
        );
    }

    /// @dev L2 outer: SYSTEM-driven call to NestedCaller on L2 with source = (alice, MAINNET).
    function _l2OuterActionHash(address ncL2, address alice) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID, ncL2, 0, abi.encodeWithSelector(NestedCaller.callNested.selector), alice, MAINNET_ROLLUP_ID
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

        // calls[0]: outer — manager calls NestedCaller.callNested() via sourceProxy(alice, MAINNET).
        //           Source rollup mirrors _outerActionHash (Alice on Mainnet).
        // calls[1]: inner — inside nestedActions[0]'s _processNCalls(1), manager calls
        //           CAP.incrementProxy() via sourceProxy(nestedCaller, MAINNET) — mirrors
        //           _capActionHash (NestedCaller on Mainnet). During this call, CAP calls
        //           counterProxy → triggers _consumeNestedAction(nestedActions[1]).
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = L2ToL1Call({
            targetAddress: nestedCaller,
            value: 0,
            data: abi.encodeWithSelector(NestedCaller.callNested.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });
        calls[1] = L2ToL1Call({
            targetAddress: cap,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: nestedCaller,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](2);
        nested[0] =
            ExpectedL1ToL2Call({crossChainCallHash: _capActionHash(cap, nestedCaller), callCount: 1, returnData: ""});
        nested[1] = ExpectedL1ToL2Call({
            crossChainCallHash: _counterActionHash(counterL2, cap), callCount: 0, returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            proxyEntryHash: _outerActionHash(nestedCaller, alice),
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            callCount: 1,
            returnData: "",
            rollingHash: _expectedRollingHash()
        });
    }

    /// @dev L2 mirror entry — same structural shape as the L1 entry, but with all
    /// addresses resolved on the L2 chain. The reentrant chain runs through real
    /// L2 contracts (NestedCaller → CAP → Counter) wired via cross-chain proxies on
    /// L2 that route back through managerL2, so the nested-action consumption fires
    /// identically. The rolling hash is byte-for-byte identical to the L1 entry's.
    function _l2Entries(address counterL2, address capL2, address ncL2, address alice)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        // calls[0]: outer — manager calls NestedCaller@L2 via sourceProxy(alice, MAINNET).
        // calls[1]: inner — inside nestedActions[0]'s _processNCalls(1), manager calls
        //           CAP@L2 via sourceProxy(ncL2, L2). During this call, CAP calls
        //           counterProxyOnL2 → triggers _consumeNestedAction(nestedActions[1]).
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = L2ToL1Call({
            targetAddress: ncL2,
            value: 0,
            data: abi.encodeWithSelector(NestedCaller.callNested.selector),
            sourceAddress: alice,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });
        calls[1] = L2ToL1Call({
            targetAddress: capL2,
            value: 0,
            data: abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector),
            sourceAddress: ncL2,
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](2);
        nested[0] =
            ExpectedL1ToL2Call({crossChainCallHash: _l2CapActionHash(capL2, ncL2), callCount: 1, returnData: ""});
        nested[1] = ExpectedL1ToL2Call({
            crossChainCallHash: _l2CounterActionHash(counterL2, capL2), callCount: 0, returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: new StateDelta[](0),
            proxyEntryHash: _l2OuterActionHash(ncL2, alice),
            destinationRollupId: L2_ROLLUP_ID,
            L2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            callCount: 1,
            returnData: "",
            rollingHash: _expectedRollingHash()
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
        try manager.createCrossChainProxy(address(counter), L2_ROLLUP_ID) returns (address p) {
            counterProxyOnL2 = p;
        } catch {
            counterProxyOnL2 = manager.computeCrossChainProxyAddress(address(counter), L2_ROLLUP_ID);
        }

        // Real CounterAndProxy on L2, wrapping counterProxyOnL2 (so cap.incrementProxy()
        // triggers a reentrant cross-chain call to managerL2 instead of a local call).
        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxyOnL2));

        // Proxy on L2 representing "CAP@L2" — used by NestedCaller as its `target`.
        address capProxyOnL2;
        try manager.createCrossChainProxy(address(cap), L2_ROLLUP_ID) returns (address p) {
            capProxyOnL2 = p;
        } catch {
            capProxyOnL2 = manager.computeCrossChainProxyAddress(address(cap), L2_ROLLUP_ID);
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
        LookupCall[] calldata lookupCalls,
        address ncProxy
    )
        external
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        uint256[] memory rids = new uint256[](1);
        rids[0] = L2_ROLLUP_ID;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](psList.length);
        for (uint256 _i = 0; _i < psList.length; _i++) {
            psIdx[_i] = uint64(_i);
        }
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](rids.length);
        for (uint256 _i = 0; _i < rids.length; _i++) {
            rps[_i] = RollupIdWithProofSystems({rollupId: rids[_i], proofSystemIndex: psIdx});
        }

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            entries: entries,
            l1ToL2lookupCalls: lookupCalls,
            transientExecutionEntryCount: 0,
            transientLookupCallCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
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

        batcher.execute(
            EEZ(rollupsAddr),
            proofSystemAddr,
            _l1Entries(counterL2, capAddr, ncAddr, address(batcher)),
            noLookupCalls(),
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
///      a nested action → CAP (on L2) incrementProxy → counterProxyOnL2 → consumes
///      another nested action → Counter returns the cached abi.encode(1). Final
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
                noLookupCalls()
            );

        console.log("done");
        console.log("nc.counter=%s", NestedCaller(ncL2).counter());
        console.log("cap.counter=%s", CounterAndProxy(capL2).counter());
        console.log("cap.targetCounter=%s", CounterAndProxy(capL2).targetCounter());
        // Counter.counter stays at 0 — the innermost call is short-circuited by
        // nestedAction[1]'s cached returnData rather than reaching the real Counter.
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
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(counterL2, capAddr, ncAddr, alice);
        bytes32 l1Hash = _entryHash(l1[0]);

        ExecutionEntry[] memory l2 = _l2Entries(counterL2, capL2, ncL2, alice);
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
