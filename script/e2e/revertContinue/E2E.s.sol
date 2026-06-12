// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry,
    LookupCall,
    ExpectedLookup
} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    LookupCall as L2LookupCall,
    ExpectedLookup as L2ExpectedLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";
import {Counter, SelfCallerWithRevert} from "../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noLookupCalls,
    noNestedActions,
    noCalls,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  RevertContinue scenario — revert inside try/catch then continue
//
//  SelfCallerWithRevert.execute():
//    a. try this.innerCall() {} catch {}
//         — innerCall does target.increment() (the reentrant proxy call SUCCEEDS,
//           consuming nested slot 0 and bumping the cursor), then innerCall()
//           wraps up with `revert("inner scope revert")`. The revert rolls back
//           innerCall()'s frame, including the nested-cursor bump (which
//           is a transient-store write).
//    b. lastResult = target.increment()
//         — second reentrant call re-consumes nested slot 0 from the same
//           cursor (since the bump was rolled back) and succeeds for real.
//
//  Net effect: exactly ONE nested action consumption survives. The rolling
//  hash only records that single surviving consumption — identical to a
//  scenario where innerCall() never ran.
//
//  Why ExpectedL1ToL2Call (not LookupCall failed=true): the reentrant call itself
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
        return crossChainCallHash(
            L2_ROLLUP_ID,
            selfCaller,
            0,
            abi.encodeWithSelector(SelfCallerWithRevert.execute.selector),
            batcher,
            MAINNET_ROLLUP_ID
        );
    }

    /// @dev Inner action hash: SelfCallerWithRevert calls counterProxy.increment().
    function _innerActionHash(address counterL2, address selfCaller) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID,
            counterL2,
            0,
            abi.encodeWithSelector(Counter.increment.selector),
            selfCaller,
            MAINNET_ROLLUP_ID
        );
    }

    /// @dev Rolling hash: CALL_BEGIN(1) → NESTED_BEGIN(1) → NESTED_END(1) → CALL_END(1, true, "")
    ///      innerCall()'s revert rolls back the rolling-hash and cursor writes
    ///      from its successful reentrant consumption. The second target.increment()
    ///      call re-consumes nested slot 0 from the rolled-back cursor — that
    ///      is the only consumption recorded in the surviving rolling hash.
    function _expectedRollingHash() internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = h.appendCallBegin(1);
        h = h.appendNestedBegin(1);
        h = h.appendNestedEnd(1);
        h = h.appendCallEnd(1, true, "");
    }

    // ─────────────────────────────────────────────────────────────
    //  L2-side mirror — SelfCallerWithRevert runs on L2; its inner reentrant call
    //  to counterProxy (proxy on L2 for Counter on MAINNET) succeeds via an
    //  ExpectedOutgoingCrossChainCall. innerCall()'s revert rolls back the consumption; the
    //  second target.increment() re-consumes the same slot. Same rolling-hash
    //  shape as the L1 side.
    // ─────────────────────────────────────────────────────────────

    /// @dev Outer action hash on L2: source-proxy (for batcher on MAINNET) calls SelfCaller (on L2).
    function _outerActionHashL2(address selfCallerL2, address batcherL1) internal pure returns (bytes32) {
        return crossChainCallHash(
            L2_ROLLUP_ID,
            selfCallerL2,
            0,
            abi.encodeWithSelector(SelfCallerWithRevert.execute.selector),
            batcherL1,
            MAINNET_ROLLUP_ID
        );
    }

    /// @dev Inner action hash on L2: SelfCaller (on L2) calls counterProxy (Counter on MAINNET).
    ///      Manager forces sourceRollupId=ROLLUP_ID (=L2) for L2-issued reentrant calls.
    function _innerActionHashL2(address counterL1, address selfCallerL2) internal pure returns (bytes32) {
        return crossChainCallHash(
            MAINNET_ROLLUP_ID,
            counterL1,
            0,
            abi.encodeWithSelector(Counter.increment.selector),
            selfCallerL2,
            L2_ROLLUP_ID
        );
    }

    function _l2Entries(address selfCallerL2, address counterL1, address batcherL1)
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            targetAddress: selfCallerL2,
            value: 0,
            data: abi.encodeWithSelector(SelfCallerWithRevert.execute.selector),
            sourceAddress: batcherL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](1);
        nested[0] = ExpectedOutgoingCrossChainCall({
            crossChainCallHash: _innerActionHashL2(counterL1, selfCallerL2),
            callCount: 0,
            returnData: abi.encode(uint256(1))
        });

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: _outerActionHashL2(selfCallerL2, batcherL1),
            incomingCalls: calls,
            expectedOutgoingCalls: nested,
            expectedLookups: new L2ExpectedLookup[](0),
            callCount: 1,
            returnData: "",
            rollingHash: _expectedRollingHash()
        });
    }

    function _l1Entries(address selfCaller, address counterL2, address batcher)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-revertcontinue"),
            etherDelta: 0
        });

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: selfCaller,
            value: 0,
            data: abi.encodeWithSelector(SelfCallerWithRevert.execute.selector),
            sourceAddress: batcher,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            crossChainCallHash: _innerActionHash(counterL2, selfCaller),
            callCount: 0,
            returnData: abi.encode(uint256(1))
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            proxyEntryHash: _outerActionHash(selfCaller, batcher),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: nested,
            expectedLookups: new ExpectedLookup[](0),
            callCount: 1,
            returnData: "",
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
        EEZ rollups = EEZ(rollupsAddr);

        // Placeholder Counter on L1 - only its address is referenced by the L2-side
        // inner action hash. Never invoked (the L2 inner ExpectedOutgoingCrossChainCall returns the
        // cached value, so the proxy's downstream call to this counter never happens).
        Counter counterL1 = new Counter();

        // Proxy for Counter (on L2) on L1
        address counterProxy;
        try rollups.createCrossChainProxy(counterL2, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2, L2_ROLLUP_ID);
        }

        // Deploy SelfCallerWithRevert targeting the counterProxy
        SelfCallerWithRevert selfCaller = new SelfCallerWithRevert(Counter(counterProxy));

        // Proxy for SelfCallerWithRevert (on L2) on L1 (trigger point)
        address selfCallerProxy;
        try rollups.createCrossChainProxy(address(selfCaller), L2_ROLLUP_ID) returns (address p) {
            selfCallerProxy = p;
        } catch {
            selfCallerProxy = rollups.computeCrossChainProxyAddress(address(selfCaller), L2_ROLLUP_ID);
        }

        console.log("COUNTER_L1=%s", address(counterL1));
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("SELF_CALLER=%s", address(selfCaller));
        console.log("SELF_CALLER_PROXY=%s", selfCallerProxy);
        vm.stopBroadcast();
    }
}

/// @title DeployL2Step2 - deploy SelfCallerWithRevert on L2 plus the inner-counter proxy
/// (proxy on L2 for Counter on MAINNET). Runs after Deploy logs COUNTER_L1 on L1.
contract DeployL2Step2 is Script {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");

        vm.startBroadcast();
        EEZL2 manager = EEZL2(managerAddr);

        // Proxy on L2 for Counter on MAINNET
        address counterProxyL2;
        try manager.createCrossChainProxy(counterL1, MAINNET_ROLLUP_ID) returns (address p) {
            counterProxyL2 = p;
        } catch {
            counterProxyL2 = manager.computeCrossChainProxyAddress(counterL1, MAINNET_ROLLUP_ID);
        }

        // SelfCallerWithRevert on L2 targeting the L2-side counter proxy.
        SelfCallerWithRevert selfCallerL2 = new SelfCallerWithRevert(Counter(counterProxyL2));

        console.log("COUNTER_PROXY_L2=%s", counterProxyL2);
        console.log("SELF_CALLER_L2=%s", address(selfCallerL2));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Execute
// ═══════════════════════════════════════════════════════════════════════

contract Batcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        address selfCallerProxy
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
            blockNumber: 0,
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
        (bool ok,) = selfCallerProxy.call(abi.encodeWithSelector(SelfCallerWithRevert.execute.selector));
        require(ok, "outer call failed");
    }
}

// ExecuteL2 - L2-side mirror. SYSTEM-driven via executeIncomingCrossChainCall:
// loads the L2 entry (1 outer call + 1 ExpectedOutgoingCrossChainCall) and runs SelfCaller (on L2) execute().
// execute() does try this.innerCall() catch {} then target.increment(). innerCall consumes the
// nested call and then reverts (rolling back the cursor bump). target.increment() then
// re-consumes the same nested slot for real, returning 1 → lastResult=1.
contract ExecuteL2 is Script, RevertContinueActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL1 = vm.envAddress("COUNTER_L1");
        address selfCallerL2 = vm.envAddress("SELF_CALLER_L2");

        vm.startBroadcast();
        address triggerSource = msg.sender;
        console.log("ExecuteL2: manager=%s selfCallerL2=%s triggerSource=%s", managerAddr, selfCallerL2, triggerSource);

        EEZL2(managerAddr)
            .executeIncomingCrossChainCall(
                selfCallerL2,
                0,
                abi.encodeWithSelector(SelfCallerWithRevert.execute.selector),
                triggerSource,
                MAINNET_ROLLUP_ID,
                _l2Entries(selfCallerL2, counterL1, triggerSource),
                new L2LookupCall[](0)
            );

        console.log("ExecuteL2: done");
        console.log("selfCallerL2.lastResult=%s", SelfCallerWithRevert(selfCallerL2).lastResult());
        vm.stopBroadcast();
    }
}

contract Execute is Script, RevertContinueActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2 = vm.envAddress("COUNTER_L2");
        address selfCallerAddr = vm.envAddress("SELF_CALLER");
        address selfCallerProxy = vm.envAddress("SELF_CALLER_PROXY");

        vm.startBroadcast();
        Batcher batcher = new Batcher();

        batcher.execute(
            EEZ(rollupsAddr),
            proofSystemAddr,
            _l1Entries(selfCallerAddr, counterL2, address(batcher)),
            noLookupCalls(),
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
        address counterL1 = vm.envAddress("COUNTER_L1");
        address selfCallerL2 = vm.envAddress("SELF_CALLER_L2");
        address alice = msg.sender;

        ExecutionEntry[] memory l1 = _l1Entries(selfCallerAddr, counterL2, alice);
        L2ExecutionEntry[] memory l2 = _l2Entries(selfCallerL2, counterL1, alice);
        bytes32 l1Hash = _entryHash(l1[0]);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry, 1 call, 1 nested - revert+continue) ===");
        _logEntry(0, l1[0]);
        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry, 1 call, 1 nested - revert+continue mirror) ===");
        _logL2Entry(0, l2[0]);
    }
}
