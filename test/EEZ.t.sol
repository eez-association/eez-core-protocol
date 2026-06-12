// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {
    EEZ,
    RollupConfig,
    ProofSystemBatchPerVerificationEntries,
    RollupIdWithProofSystems,
    RollupVerification
} from "../src/EEZ.sol";
import {Rollup} from "../src/rollupContract/Rollup.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRollupContract} from "../src/interfaces/IRollup.sol";
import {IProofSystem} from "../src/interfaces/IProofSystem.sol";
import {
    ExecutionEntry,
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    LookupCall,
    ExpectedLookup,
    ProxyInfo,
    ExpectedStateRootPerRollup
} from "../src/interfaces/IEEZ.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {CrossChainProxy} from "../src/base/CrossChainProxy.sol";
import {IMetaCrossChainReceiver} from "../src/interfaces/IMetaCrossChainReceiver.sol";
import {MockProofSystem} from "./mocks/MockProofSystem.sol";
import {Counter, SafeCounterAndProxy} from "./mocks/CounterContracts.sol";

/// @notice Simple target contract for testing
contract TestTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    receive() external payable {}
}

/// @notice Target contract that always reverts
contract RevertingTarget {
    error TargetReverted();

    fallback() external payable {
        revert TargetReverted();
    }
}

/// @notice Receives ETH from an entry call and forwards part of it into a proxy as a
///         reentrant cross-chain call (exercises the `_entryEtherIn` accounting).
contract ValueForwarder {
    address public peer;

    function setPeer(address _peer) external {
        peer = _peer;
    }

    function forward(uint256 amount) external payable returns (uint256) {
        (bool ok,) = peer.call{value: amount}(abi.encodeWithSignature("deposit()"));
        require(ok, "forward failed");
        return msg.value;
    }
}

/// @notice Posts a batch and, during the meta hook, fires one proxy call so the failed-lookup
///         fallback can be exercised against the *transient* lookup table (which only exists
///         inside `postAndVerifyBatch`). Swallows the proxy revert so the batch still completes;
///         the captured `(success, returnData)` is asserted by the test.
contract MetaLookupCaller is IMetaCrossChainReceiver {
    EEZ public immutable eez;
    address public proxyAddr;
    bytes public proxyCallData;
    bool public hookRan;
    bool public callSuccess;
    bytes public callReturnData;

    constructor(EEZ _eez) {
        eez = _eez;
    }

    function setProxyCall(address _proxy, bytes calldata _cd) external {
        proxyAddr = _proxy;
        proxyCallData = _cd;
    }

    function post(ProofSystemBatchPerVerificationEntries calldata batch) external {
        eez.postAndVerifyBatch(batch);
    }

    function executeMetaCrossChainTransactions() external override {
        hookRan = true;
        (callSuccess, callReturnData) = proxyAddr.call(proxyCallData);
    }
}

contract EEZTest is Base {
    TestTarget public target;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant MAINNET_ROLLUP_ID = 0;

    function setUp() public {
        setUpBase();
        target = new TestTarget();
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    /// @notice Deploy a `Rollup` with one PS / one vkey / threshold=1, register it, return ids.
    /// @dev Test-local overload of `Base._makeRollup` that returns the (id, manager) pair instead
    ///      of `RollupHandle`. Existing test sites use the tuple form.
    function _makeRollupLocal(bytes32 initialState, address owner_) internal returns (uint256 rid, Rollup rollup) {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = DEFAULT_VK;
        rollup = new Rollup(address(rollups), owner_, 1, psList, vks);
        rid = rollups.registerRollup(address(rollup), initialState);
    }

    /// @notice Action-hash computation. Test-local helper kept for callsite compatibility;
    ///         identical to `Base._hashCall` and `EEZ.computeCrossChainCallHash`.
    function _computeActionHash(
        uint256 rollupId,
        address destination,
        uint256 value_,
        bytes memory data,
        address sourceAddress,
        uint256 sourceRollup
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(rollupId, destination, value_, data, sourceAddress, sourceRollup));
    }

    /// @notice Wrap entries into a single-PS / single-rollup ProofSystemBatchPerVerificationEntries and call postAndVerifyBatch.
    function _postBatchSingle(uint256 rid, ExecutionEntry[] memory entries, uint256 transientCount) internal {
        LookupCall[] memory noStatic = new LookupCall[](0);
        _postBatchSingle(rid, entries, noStatic, transientCount, 0);
    }

    function _postBatchSingle(
        uint256 rid,
        ExecutionEntry[] memory entries,
        LookupCall[] memory lookupCalls,
        uint256 transientCount,
        uint256 transientLookupCallCount
    )
        internal
    {
        uint256[] memory rids = new uint256[](1);
        rids[0] = rid;
        _postBatchSingleMulti(rids, entries, lookupCalls, transientCount, transientLookupCallCount);
    }

    function _postBatchSingleMulti(
        uint256[] memory rids,
        ExecutionEntry[] memory entries,
        LookupCall[] memory lookupCalls,
        uint256 transientCount,
        uint256 transientLookupCallCount
    )
        internal
    {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
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
            transientExecutionEntryCount: transientCount,
            transientLookupCallCount: transientLookupCallCount,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
    }

    /// @notice Wrap entries into a single-PS batch with `transientCount = 1` when the leading entry is immediate.
    function _postBatch(uint256 rid, ExecutionEntry[] memory entries) internal {
        uint256 tc = (entries.length > 0 && entries[0].proxyEntryHash == bytes32(0)) ? 1 : 0;
        _postBatchSingle(rid, entries, tc);
    }

    // ──────────────────────────────────────────────
    //  Rollup creation
    // ──────────────────────────────────────────────
    //
    // NOTE: previous `ProofSystemRegistry` tests (RegisterProofSystem,
    // DuplicateRegistrationReverts, ZeroAddressReverts) were dropped when the central
    // PS registry was removed. Each rollup's manager now defines its own allowed PS set.

    function test_CreateRollup() public {
        bytes32 initialState = keccak256("initial");
        (uint256 rid, Rollup r) = _makeRollupLocal(initialState, alice);
        // registerRollup pre-increments rollupCounter, so id 0 (MAINNET_ROLLUP_ID) is
        // skipped and the first user-registered rollup lands at id 1.
        assertEq(rid, 1);
        assertEq(_getRollupState(rid), initialState);
        assertEq(_getRollupContract(rid), address(r));
        // After registration, the Rollup's `rollupId` is set via the rollupContractRegistered callback
        assertEq(r.rollupId(), rid);
        assertEq(r.owner(), alice);
        assertEq(r.threshold(), 1);
        assertEq(r.verificationKey(address(ps)), DEFAULT_VK);
    }

    function test_CreateRollup_ZeroAddressContractReverts() public {
        vm.expectRevert(EEZ.InvalidRollupContract.selector);
        rollups.registerRollup(address(0), bytes32(0));
    }

    function test_CreateRollup_RegistryItselfReverts() public {
        vm.expectRevert(EEZ.InvalidRollupContract.selector);
        rollups.registerRollup(address(rollups), bytes32(0));
    }

    // NOTE: tests dropped after refactor:
    // - test_CreateRollup_DuplicateContractReverts: registry no longer enforces unique
    //   rollupContract addresses; the per-rollup manager is responsible for its own
    //   one-shot semantic if it wants one (the reference Rollup.sol does NOT — handoff
    //   re-registration is allowed).
    // - test_RollupId_NotRegisteredReverts: `rollupIdOf` view was removed when the
    //   reverse-lookup mapping was dropped. Manager passes rollupId explicitly via
    //   callbacks now.

    // ──────────────────────────────────────────────
    //  CrossChainProxy creation
    // ──────────────────────────────────────────────

    function test_CreateCrossChainProxy() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        address targetAddr = address(0x1234);
        address proxy = rollups.createCrossChainProxy(targetAddr, rid);
        (address origAddr,) = rollups.authorizedProxies(proxy);
        assertEq(origAddr, targetAddr);
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(proxy)
        }
        assertGt(codeSize, 0);
    }

    function test_ComputeCrossChainProxyAddress() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        address targetAddr = address(0x5678);
        address computed = rollups.computeCrossChainProxyAddress(targetAddr, rid);
        address actual = rollups.createCrossChainProxy(targetAddr, rid);
        assertEq(computed, actual);
    }

    function test_MultipleProxiesSameTarget() public {
        (uint256 r1,) = _makeRollupLocal(bytes32(0), alice);
        (uint256 r2,) = _makeRollupLocal(bytes32(0), alice);
        address proxy1 = rollups.createCrossChainProxy(address(0x9999), r1);
        address proxy2 = rollups.createCrossChainProxy(address(0x9999), r2);
        assertTrue(proxy1 != proxy2);
    }

    // ──────────────────────────────────────────────
    //  postAndVerifyBatch — immediate state update
    // ──────────────────────────────────────────────

    function test_PostBatch_ImmediateStateUpdate() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        bytes32 newState = keccak256("new state");
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rid, bytes32(0), newState);
        _postBatch(rid, entries);
        assertEq(_getRollupState(rid), newState);
    }

    function test_PostBatch_StateRootMismatch_ImmediateSkipped() public {
        (uint256 rid,) = _makeRollupLocal(keccak256("real"), alice);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        // wrong currentState — chain has keccak256("real"), entry claims bytes32(0).
        // Immediate entries are run inside an attemptApplyImmediate try/catch: the StateRootMismatch
        // revert is swallowed and the entry is reported as `ImmediateEntrySkipped`.
        entries[0] = _immediateEntry(rid, bytes32(0), keccak256("new"));
        vm.expectEmit(true, false, false, false);
        emit EEZ.ImmediateEntrySkipped(0, "");
        _postBatch(rid, entries);
        // State unchanged because the immediate entry was skipped.
        assertEq(_getRollupState(rid), keccak256("real"));
    }

    function test_PostBatch_MultipleEEZ_OneEntryEach() public {
        (uint256 r1,) = _makeRollupLocal(bytes32(0), alice);
        (uint256 r2,) = _makeRollupLocal(bytes32(0), bob);

        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({rollupId: r1, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});
        deltas[1] = StateDelta({rollupId: r2, currentState: bytes32(0), newState: keccak256("s2"), etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = r1; // any rollup in batch is fine for inline
        entries[0].l2ToL1Calls = new L2ToL1Call[](0);
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].rollingHash = bytes32(0);

        uint256[] memory rids = new uint256[](2);
        // strictly increasing required
        rids[0] = r1 < r2 ? r1 : r2;
        rids[1] = r1 < r2 ? r2 : r1;
        _postBatchSingleMulti(rids, entries, new LookupCall[](0), 1, 0);

        assertEq(_getRollupState(r1), keccak256("s1"));
        assertEq(_getRollupState(r2), keccak256("s2"));
    }

    function test_PostBatch_InvalidProofReverts() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rid, bytes32(0), keccak256("s"));
        // Verification on with no pinned hash — rejects every proof.
        ps.setShouldVerify(true);
        vm.expectRevert(EEZ.InvalidProof.selector);
        _postBatch(rid, entries);
    }

    /// @notice Multiple verifications for the same rollup in the same block are allowed:
    ///         the second batch picks up where the first left off (state has advanced to s1,
    ///         the second batch transitions s1 → s2). Each verify wipes the rollup's queue,
    ///         so the second batch fully replaces the first's entries.
    function test_PostBatch_SameBlockSameRollupOk() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        ExecutionEntry[] memory entries1 = new ExecutionEntry[](1);
        entries1[0] = _immediateEntry(rid, bytes32(0), keccak256("s1"));
        _postBatch(rid, entries1);
        assertEq(_getRollupState(rid), keccak256("s1"));

        ExecutionEntry[] memory entries2 = new ExecutionEntry[](1);
        entries2[0] = _immediateEntry(rid, keccak256("s1"), keccak256("s2"));
        _postBatch(rid, entries2);
        assertEq(_getRollupState(rid), keccak256("s2"));
    }

    function test_PostBatch_SameBlockDifferentEEZOk() public {
        (uint256 r1,) = _makeRollupLocal(bytes32(0), alice);
        (uint256 r2,) = _makeRollupLocal(bytes32(0), bob);
        ExecutionEntry[] memory e1 = new ExecutionEntry[](1);
        e1[0] = _immediateEntry(r1, bytes32(0), keccak256("s1"));
        _postBatch(r1, e1);

        ExecutionEntry[] memory e2 = new ExecutionEntry[](1);
        e2[0] = _immediateEntry(r2, bytes32(0), keccak256("s2"));
        _postBatch(r2, e2);

        assertEq(_getRollupState(r1), keccak256("s1"));
        assertEq(_getRollupState(r2), keccak256("s2"));
    }

    function test_PostBatch_DifferentBlocks_LazyReset() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);

        // Block 1 — post a deferred entry that's never consumed
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (1));
        bytes32 ah = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);
        ExecutionEntry[] memory e1 = new ExecutionEntry[](1);
        e1[0].stateDeltas = new StateDelta[](0);
        e1[0].proxyEntryHash = ah;
        e1[0].destinationRollupId = rid;
        e1[0].l2ToL1Calls = new L2ToL1Call[](0);
        e1[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        e1[0].rollingHash = bytes32(0);
        _postBatchSingle(rid, e1, 0);
        assertEq(rollups.queueLength(rid), 1);

        // New block — lazy reset clears the stale queue
        vm.roll(block.number + 1);
        ExecutionEntry[] memory e2 = new ExecutionEntry[](1);
        e2[0] = _immediateEntry(rid, bytes32(0), keccak256("s2"));
        _postBatch(rid, e2);
        assertEq(_getRollupState(rid), keccak256("s2"));
        assertEq(rollups.queueLength(rid), 0);
        assertEq(rollups.executionQueueIndex(rid), 0);
    }

    function test_PostBatch_LastVerifiedBlock() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rid, bytes32(0), keccak256("s"));
        _postBatch(rid, entries);
        assertEq(rollups.lastVerifiedBlock(rid), block.number);
    }

    // NOTE: dropped after refactor — `postAndVerifyBatch` now
    // takes a single `ProofSystemBatchPerVerificationEntries`, not an array, so there's no
    // "empty array" edge case. The empty-batch validation lives inline in
    // `_validateStructure` (e.g., empty `proofSystems[]` reverts `InvalidProofSystemConfig`)
    // and is exercised by other tests in this file.

    // ──────────────────────────────────────────────
    //  Sub-batch validation
    // ──────────────────────────────────────────────

    function test_SubBatch_DuplicateProofSystemReverts() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        address[] memory psList = new address[](2);
        psList[0] = address(ps);
        psList[1] = address(ps); // duplicate (also unsorted)
        bytes[] memory proofs = new bytes[](2);
        proofs[0] = "p1";
        proofs[1] = "p2";

        uint64[] memory psIdx = new uint64[](2);
        psIdx[0] = 0;
        psIdx[1] = 1;
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: rid, proofSystemIndex: psIdx});

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            blockNumber: 0,
            entries: new ExecutionEntry[](0),
            l1ToL2lookupCalls: new LookupCall[](0),
            transientExecutionEntryCount: 0,
            transientLookupCallCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });

        vm.expectRevert(abi.encodeWithSelector(EEZ.DuplicateProofSystem.selector, address(ps)));
        rollups.postAndVerifyBatch(batch);
    }

    // NOTE: dropped after refactor:
    //   test_SubBatch_UnregisteredProofSystemReverts — there is no central PS registry
    //   anymore. Any address can be supplied as a proof system; the per-rollup manager's
    //   `getVkeysFromProofSystems` decides which addresses are allowed (returns non-zero
    //   vkey only for allowed PSes). An "unrelated" PS just reverts with
    //   `ProofSystemNotAllowed` from the manager, not from the registry.

    function test_SubBatch_NonIncreasingRollupIdsReverts() public {
        (uint256 r1,) = _makeRollupLocal(bytes32(0), alice);
        (uint256 r2,) = _makeRollupLocal(bytes32(0), bob);
        // pass them in reverse order
        uint256[] memory rids = new uint256[](2);
        rids[0] = r1 < r2 ? r2 : r1;
        rids[1] = r1 < r2 ? r1 : r2;

        ExecutionEntry[] memory entries = new ExecutionEntry[](0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        _postBatchSingleMulti(rids, entries, new LookupCall[](0), 0, 0);
    }

    // NOTE: `test_SubBatch_RollupInMultipleSubBatchesReverts` was dropped after the multi-
    // sub-batch model was collapsed into a single batch and the once-per-block-per-rollup
    // guard in `_markVerifiedThisBlock` was lifted. See `test_PostBatch_SameBlockSameRollup*`
    // for the replacement: a rollup can now be verified multiple times within the same block
    // and entries simply accumulate on its queue.

    function test_SubBatch_RollupNotInBatchReverts() public {
        (uint256 r1,) = _makeRollupLocal(bytes32(0), alice);
        (uint256 r2,) = _makeRollupLocal(bytes32(0), bob); // not in this batch's rollupIds

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: r2, currentState: bytes32(0), newState: keccak256("x"), etherDelta: 0});
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = r1;
        entries[0].l2ToL1Calls = new L2ToL1Call[](0);
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].rollingHash = bytes32(0);

        vm.expectRevert(abi.encodeWithSelector(EEZ.RollupNotInBatch.selector, r2));
        _postBatchSingle(r1, entries, 1);
    }

    /// @notice Transient lookups without transient entries are unreachable (no immediate drain,
    ///         no meta hook) — `_validateStructure` rejects the shape.
    function test_SubBatch_TransientLookupsWithoutTransientEntriesReverts() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);

        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = _revertedLookup(rid, keccak256("h"), hex"deadbeef");

        vm.expectRevert(EEZ.TransientLookupCallsWithoutTransientEntries.selector);
        _postBatchSingle(rid, new ExecutionEntry[](0), lookups, 0, 1);
    }

    // ──────────────────────────────────────────────
    //  Per-rollup queue routing (executeCrossChainCall / executeL2TX)
    // ──────────────────────────────────────────────

    function test_ExecuteCrossChainCall_Simple() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 ah = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: address(target),
            value: 0,
            data: cd,
            sourceAddress: address(this),
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });
        bytes32 rh = _rollingHashSingleCall("");

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("after"), etherDelta: 0});
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = ah;
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].callCount = 1;
        entries[0].rollingHash = rh;
        _postBatchSingle(rid, entries, 0); // deferred — must consume via proxy

        (bool ok,) = proxyAddr.call(cd);
        assertTrue(ok);
        assertEq(target.value(), 42);
        assertEq(_getRollupState(rid), keccak256("after"));
    }

    function test_ExecuteCrossChainCall_UnauthorizedProxyReverts() public {
        _makeRollupLocal(bytes32(0), alice);
        vm.expectRevert(EEZBase.UnauthorizedProxy.selector);
        rollups.executeCrossChainCall(alice, "");
    }

    function test_ExecuteCrossChainCall_NotInCurrentBlockReverts() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);
        // No postAndVerifyBatch in this block → proxy call should revert
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (1));
        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        assertEq(sel, EEZ.ExecutionNotInCurrentBlock.selector);
    }

    function test_ExecuteL2TX() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);

        // Two entries: first is immediate (transient), second is a pure L2TX in the persistent queue
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(rid, bytes32(0), keccak256("s1"));
        entries[1] = _immediateEntry(rid, keccak256("s1"), keccak256("s2"));
        _postBatchSingle(rid, entries, 1);

        assertEq(_getRollupState(rid), keccak256("s1"));
        rollups.executeL2TX(rid);
        assertEq(_getRollupState(rid), keccak256("s2"));
    }

    function test_ExecuteL2TX_NotInCurrentBlockReverts() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        vm.expectRevert(abi.encodeWithSelector(EEZ.ExecutionNotInCurrentBlock.selector, rid));
        rollups.executeL2TX(rid);
    }

    function test_ExecuteInContext_NotSelfReverts() public {
        vm.expectRevert(EEZBase.NotSelf.selector);
        rollups.executeInContextAndRevert(1);
    }

    // ──────────────────────────────────────────────
    //  Ether accounting
    // ──────────────────────────────────────────────

    function test_PostBatch_EtherDeltasMustSumToZero() public {
        (uint256 r1,) = _makeRollupLocal(bytes32(0), alice);
        (uint256 r2,) = _makeRollupLocal(bytes32(0), bob);
        _fundRollup(r1, 5 ether);

        StateDelta[] memory deltas = new StateDelta[](2);
        // sort by rollupId so the deltas are ordered consistently with the strictly-increasing rollupIds
        if (r1 < r2) {
            deltas[0] =
                StateDelta({rollupId: r1, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: -2 ether});
            deltas[1] =
                StateDelta({rollupId: r2, currentState: bytes32(0), newState: keccak256("s2"), etherDelta: 2 ether});
        } else {
            deltas[0] =
                StateDelta({rollupId: r2, currentState: bytes32(0), newState: keccak256("s2"), etherDelta: 2 ether});
            deltas[1] =
                StateDelta({rollupId: r1, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: -2 ether});
        }

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = r1;
        entries[0].l2ToL1Calls = new L2ToL1Call[](0);
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].rollingHash = bytes32(0);

        uint256[] memory rids = new uint256[](2);
        rids[0] = r1 < r2 ? r1 : r2;
        rids[1] = r1 < r2 ? r2 : r1;
        _postBatchSingleMulti(rids, entries, new LookupCall[](0), 1, 0);

        assertEq(_getRollupEtherBalance(r1), 3 ether);
        assertEq(_getRollupEtherBalance(r2), 2 ether);
    }

    function test_PostBatch_EtherDeltasNonZeroSum_ImmediateSkipped() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        _fundRollup(rid, 5 ether);
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 1 ether});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = new L2ToL1Call[](0);
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].rollingHash = bytes32(0);
        // EtherDeltaMismatch raised inside attemptApplyImmediate → caught → ImmediateEntrySkipped.
        vm.expectEmit(true, false, false, false);
        emit EEZ.ImmediateEntrySkipped(0, "");
        _postBatch(rid, entries);
        assertEq(_getRollupState(rid), bytes32(0));
        assertEq(_getRollupEtherBalance(rid), 5 ether);
    }

    function test_PostBatch_InsufficientRollupBalance_ImmediateSkipped() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: -1 ether});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = new L2ToL1Call[](0);
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].rollingHash = bytes32(0);
        // InsufficientRollupBalance raised inside attemptApplyImmediate → caught → ImmediateEntrySkipped.
        vm.expectEmit(true, false, false, false);
        emit EEZ.ImmediateEntrySkipped(0, "");
        _postBatch(rid, entries);
        assertEq(_getRollupState(rid), bytes32(0));
        assertEq(_getRollupEtherBalance(rid), 0);
    }

    /// @notice Builds the reentrant-value fixture: an entry call sends 2 ether to a
    ///         ValueForwarder, which forwards 1.5 ether back into a proxy as a reentrant
    ///         cross-chain call. Net for the rollup: -0.5 ether.
    function _reentrantValueEntry(uint256 rid, int256 etherDelta)
        internal
        returns (ExecutionEntry[] memory entries, ValueForwarder forwarder)
    {
        forwarder = new ValueForwarder();
        address remote = address(0xBEEF);
        forwarder.setPeer(rollups.createCrossChainProxy(remote, rid));

        bytes memory depositData = abi.encodeWithSignature("deposit()");
        bytes32 nestedHash = _hashCall(rid, remote, 1.5 ether, depositData, address(forwarder), 0);

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: address(forwarder),
            value: 2 ether,
            data: abi.encodeCall(ValueForwarder.forward, (1.5 ether)),
            sourceAddress: address(0xD00D),
            sourceRollupId: rid,
            revertSpan: 0
        });

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({crossChainCallHash: nestedHash, callCount: 0, returnData: ""});

        bytes32 h = bytes32(0);
        h = _hCallBegin(h, 1);
        h = _hNestedBegin(h, 1);
        h = _hNestedEnd(h, 1);
        h = _hCallEnd(h, 1, true, abi.encode(uint256(2 ether)));

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: etherDelta});

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = nested;
        entries[0].callCount = 1;
        entries[0].returnData = "";
        entries[0].rollingHash = h;
    }

    function test_ReentrantValue_CountedInEtherAccounting() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        _fundRollup(rid, 2 ether);

        // 2 ether out at the top level, 1.5 ether back in reentrantly → net -0.5 ether.
        (ExecutionEntry[] memory entries, ValueForwarder forwarder) = _reentrantValueEntry(rid, -0.5 ether);
        _postBatch(rid, entries);

        assertEq(_getRollupState(rid), keccak256("s1"));
        assertEq(_getRollupEtherBalance(rid), 1.5 ether);
        assertEq(address(forwarder).balance, 0.5 ether);
        assertEq(address(rollups).balance, 1.5 ether);
    }

    function test_ReentrantValue_NotCredited_ImmediateSkipped() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        _fundRollup(rid, 2 ether);

        // Delta pretends the reentrant 1.5 ether never came back → EtherDeltaMismatch
        // inside attemptApplyImmediate → caught → ImmediateEntrySkipped, all rolled back.
        (ExecutionEntry[] memory entries, ValueForwarder forwarder) = _reentrantValueEntry(rid, -2 ether);
        vm.expectEmit(true, false, false, false);
        emit EEZ.ImmediateEntrySkipped(0, "");
        _postBatch(rid, entries);

        assertEq(_getRollupState(rid), bytes32(0));
        assertEq(_getRollupEtherBalance(rid), 2 ether);
        assertEq(address(forwarder).balance, 0);
        assertEq(address(rollups).balance, 2 ether);
    }

    // ──────────────────────────────────────────────
    //  Owner ops on Rollup.sol (the per-rollup contract)
    // ──────────────────────────────────────────────

    function test_RollupSetStateRoot_ByOwner() public {
        (uint256 rid, Rollup r) = _makeRollupLocal(bytes32(0), alice);
        vm.prank(alice);
        r.setStateRoot(keccak256("escape"));
        assertEq(_getRollupState(rid), keccak256("escape"));
    }

    function test_RollupSetStateRoot_NotOwnerReverts() public {
        (, Rollup r) = _makeRollupLocal(bytes32(0), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        r.setStateRoot(keccak256("escape"));
    }

    function test_RollupSetStateRoot_MidFlowReverts() public {
        (uint256 rid, Rollup r) = _makeRollupLocal(bytes32(0), alice);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rid, bytes32(0), keccak256("s"));
        _postBatch(rid, entries);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EEZ.RollupBatchActiveThisBlock.selector, rid));
        r.setStateRoot(keccak256("escape"));
    }

    function test_RollupTransferOwnership() public {
        (, Rollup r) = _makeRollupLocal(bytes32(0), alice);
        vm.prank(alice);
        r.transferOwnership(bob);
        assertEq(r.owner(), bob);
        vm.prank(bob);
        r.setStateRoot(keccak256("bob's state"));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        r.setStateRoot(keccak256("alice's state"));
    }

    function test_RollupSetVerificationKey() public {
        (, Rollup r) = _makeRollupLocal(bytes32(0), alice);
        bytes32 newVk = keccak256("new vk");
        vm.prank(alice);
        r.updateVerificationKey(address(ps), newVk);
        assertEq(r.verificationKey(address(ps)), newVk);
    }

    // NOTE: `test_SetRollupContract_Handoff` was dropped — the registry no longer exposes
    // a `setRollupContract` handoff path. Once a manager is registered via `registerRollup`
    // it owns that rollupId for the lifetime of the registry. A future replacement (force
    // inbox / governance handoff) is tracked separately.

    // ──────────────────────────────────────────────
    //  Rolling-hash failure modes
    // ──────────────────────────────────────────────

    function test_RollingHashMismatch_Reverts() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 ah = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: address(target),
            value: 0,
            data: cd,
            sourceAddress: address(this),
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = ah;
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].callCount = 1;
        entries[0].rollingHash = bytes32(uint256(0xdead)); // wrong!
        _postBatchSingle(rid, entries, 0);
        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        proxyAddr.call(cd);
    }

    function test_UnconsumedCalls_Reverts() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 ah = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = L2ToL1Call({
            targetAddress: address(target),
            value: 0,
            data: cd,
            sourceAddress: address(this),
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });
        calls[1] = calls[0];
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = ah;
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].callCount = 1; // promise only one call but provide two
        entries[0].rollingHash = _rollingHashSingleCall("");
        _postBatchSingle(rid, entries, 0);
        vm.expectRevert(EEZ.UnconsumedL2ToL1Calls.selector);
        proxyAddr.call(cd);
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    function test_Event_RollupCreated() public {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = DEFAULT_VK;
        Rollup r = new Rollup(address(rollups), alice, 1, psList, vks);
        vm.expectEmit(true, true, true, true);
        // registerRollup skips id 0 (MAINNET_ROLLUP_ID), so this fresh rollup lands at id 1.
        emit EEZ.RollupCreated(1, address(r), keccak256("init"));
        rollups.registerRollup(address(r), keccak256("init"));
    }

    function test_Event_BatchPosted() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rid, bytes32(0), keccak256("s"));
        vm.recordLogs();
        _postBatch(rid, entries);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = EEZ.BatchPosted.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function test_Event_StateUpdated_OnEscape() public {
        (uint256 rid, Rollup r) = _makeRollupLocal(bytes32(0), alice);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit EEZ.StateUpdated(rid, keccak256("escape"));
        r.setStateRoot(keccak256("escape"));
    }

    // ──────────────────────────────────────────────
    //  Top-level reverted-LookupCall fallback
    // ──────────────────────────────────────────────
    //
    // A reverting top-level cross-chain call isn't an `ExecutionEntry` — it's a
    // `LookupCall { failed: true }`. When `_consumeAndExecute` finds no matching entry it
    // delegates to `_tryRevertedTopLevelLookup`, which scans the transient table then the
    // routed rollup's `lookupQueue` for a `failed` lookup matching `crossChainCallHash` with
    // every state-root pin live, and reverts with the cached `returnData`. The entry cursor
    // is never advanced — the lookup consumes no queue slot. See docs §D.3 / §F.4.

    /// @notice Builds a top-level reverted `LookupCall` (no sub-calls, no pins).
    function _revertedLookup(uint256 rid, bytes32 hash, bytes memory payload)
        internal
        pure
        returns (LookupCall memory lc)
    {
        lc.crossChainCallHash = hash;
        lc.destinationRollupId = rid;
        lc.returnData = payload;
        lc.failed = true;
        lc.l2ToL1Calls = new L2ToL1Call[](0);
        lc.rollingHash = bytes32(0);
    }

    /// @notice Deferred path: the reverted lookup sits in `verificationByRollup[rid].lookupQueue`
    ///         and a top-level proxy call reverts with its cached returnData without advancing the cursor.
    function test_RevertedLookup_TopLevel_Deferred() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes memory payload = hex"deadbeef";
        // Hash exactly as `executeCrossChainCall` computes it: source = this test (it calls the proxy).
        bytes32 h = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);

        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = _revertedLookup(rid, h, payload);
        // transientLookupCallCount = 0 → published to the per-rollup lookupQueue.
        _postBatchSingle(rid, _emptyEntries(), lookups, 0, 0);

        uint256 cursorBefore = rollups.executionQueueIndex(rid);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, payload);
        assertEq(rollups.executionQueueIndex(rid), cursorBefore, "reverted lookup must not advance the cursor");

        // Content-addressed + repeatable: a second identical call reverts identically, still no advance.
        (ok, ret) = proxyAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, payload);
        assertEq(rollups.executionQueueIndex(rid), cursorBefore);
    }

    /// @notice Transient path: the reverted lookup lives in `_transientLookupCalls` and is hit by a
    ///         proxy call fired from inside the meta hook (the only window the transient table exists).
    function test_RevertedLookup_TopLevel_Transient() public {
        (uint256 rid, Rollup rollup) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        MetaLookupCaller caller = new MetaLookupCaller(rollups);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes memory payload = hex"c0ffee";
        // The meta-hook caller is what calls through the proxy, so it's the hash's sourceAddress.
        bytes32 h = _computeActionHash(rid, address(target), 0, cd, address(caller), MAINNET_ROLLUP_ID);
        caller.setProxyCall(proxyAddr, cd);

        // One undrained transient entry (proxyEntryHash != 0 and != h) so the meta hook fires.
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _emptyImmediateEntry(rid);
        entries[0].proxyEntryHash = keccak256("dummy-undrained");

        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = _revertedLookup(rid, h, payload);

        // transientExecutionEntryCount = 1, transientLookupCallCount = 1 → both stay in transient tables.
        RollupHandle memory handle = RollupHandle({id: rid, manager: rollup});
        ProofSystemBatchPerVerificationEntries memory batch = _singleSubBatch(handle, entries, lookups, 1, 1);
        caller.post(batch);

        assertTrue(caller.hookRan(), "meta hook did not run");
        assertFalse(caller.callSuccess(), "proxy call should have reverted");
        assertEq(caller.callReturnData(), payload);
    }

    /// @notice Negative path: rollup verified this block but no entry and no lookup match → ExecutionNotFound.
    function test_RevertedLookup_TopLevel_NoMatchReverts() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);
        // Verify the rollup this block, but post nothing to consume or look up.
        _postBatchSingle(rid, _emptyEntries(), _emptyLookupCalls(), 0, 0);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        assertEq(sel, EEZBase.ExecutionNotFound.selector);
    }

    // ──────────────────────────────────────────────
    //  Reverted-LookupCall sub-execution (_executeRevertedTopLevelLookup)
    // ──────────────────────────────────────────────
    //
    // A `failed` LookupCall can carry a real sub-execution: `calls[]` that run for real (with
    // `callCount` top-level iterations) and then get discarded by the terminal revert. Exercised
    // here via the TOP-LEVEL fallback (`_tryRevertedTopLevelLookup`), which routes through
    // `_executeRevertedTopLevelLookup` (nested lookups use `_executeRevertedNestedLookup` on the entry's table).

    /// @notice Top-level reverted LookupCall whose sub-execution runs one real sub-call
    ///         `subTarget.setValue(subValue)` (callCount = 1) then reverts `payload`.
    function _revertedLookupWithSubcall(
        uint256 rid,
        bytes32 hash,
        bytes memory payload,
        address subTarget,
        uint256 subValue
    )
        internal
        view
        returns (LookupCall memory lc)
    {
        L2ToL1Call[] memory subCalls = new L2ToL1Call[](1);
        subCalls[0] = L2ToL1Call({
            targetAddress: subTarget,
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (subValue)),
            sourceAddress: address(this),
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });
        lc.crossChainCallHash = hash;
        lc.destinationRollupId = rid;
        lc.returnData = payload;
        lc.failed = true;
        lc.l2ToL1Calls = subCalls;
        lc.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        lc.expectedLookups = new ExpectedLookup[](0);
        lc.callCount = 1;
        lc.rollingHash = _rollingHashSingleCall(""); // CALL_BEGIN(1) → CALL_END(1, true, "")
        lc.expectedStateRoots = new ExpectedStateRootPerRollup[](0);
    }

    /// @notice Happy path: the reverted lookup runs its sub-execution, then reverts with the
    ///         cached `returnData`; the sub-call's state change is discarded by the revert and the
    ///         queue is not advanced.
    function test_RevertedLookup_SubExecution_RunsAndReverts() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes32 h = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);
        bytes memory payload = hex"deadbeef";

        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = _revertedLookupWithSubcall(rid, h, payload, address(target), 99);
        _postBatchSingle(rid, _emptyEntries(), lookups, 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, payload, "must revert with the lookup's returnData");
        assertEq(target.value(), 0, "sub-execution state must be discarded by the terminal revert");
        assertEq(rollups.executionQueueIndex(rid), 0, "reverted lookup must not advance the queue");
    }

    /// @notice Proves the sub-execution actually RUNS the sub-calls: a wrong `rollingHash` makes the
    ///         post-execution check fire `RollingHashMismatch` (impossible if the calls were skipped).
    function test_RevertedLookup_SubExecution_WrongHashReverts() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes32 h = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);

        LookupCall memory lc = _revertedLookupWithSubcall(rid, h, hex"deadbeef", address(target), 99);
        lc.rollingHash = keccak256("wrong"); // != the hash the real sub-execution produces
        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = lc;
        _postBatchSingle(rid, _emptyEntries(), lookups, 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        assertEq(
            sel, EEZBase.RollingHashMismatch.selector, "the sub-execution must run the sub-calls and check the hash"
        );
    }

    /// @notice State-root pins are part of the MATCH (full-scan): a lookup pinned to a wrong
    ///         root is skipped, and with no other candidate the call ends `ExecutionNotFound`.
    function test_RevertedLookup_StateRootPin_MismatchSkips() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes32 h = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);

        LookupCall memory lc = _revertedLookup(rid, h, hex"deadbeef"); // plain reverted lookup
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: rid, stateRoot: keccak256("wrong-root")}); // live root is 0
        lc.expectedStateRoots = pins;
        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = lc;
        _postBatchSingle(rid, _emptyEntries(), lookups, 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        assertEq(sel, EEZBase.ExecutionNotFound.selector, "wrong root pin must skip the candidate");
    }

    /// @notice A lookup pinned to the LIVE state root matches and reverts with its cached returnData.
    function test_RevertedLookup_StateRootPin_MatchResolves() public {
        (uint256 rid,) = _makeRollupLocal(keccak256("live-root"), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes memory payload = hex"deadbeef";
        bytes32 h = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);

        LookupCall memory lc = _revertedLookup(rid, h, payload);
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: rid, stateRoot: keccak256("live-root")});
        lc.expectedStateRoots = pins;
        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = lc;
        _postBatchSingle(rid, _emptyEntries(), lookups, 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, payload, "live root pin must match and revert with the cached returnData");
    }

    /// @notice NESTED reverted lookup, entry-scoped: a reentrant call with no ExpectedL1ToL2Call
    ///         match falls back to the entry's own `expectedLookups`, reverts with the cached
    ///         revert, and the caller's try/catch absorbs it.
    function test_NestedRevertedLookup_EntryScoped_RevertsAndCatches() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);

        // Inner target: proxy on L1 for a Counter living on rollup `rid`.
        address counterL2 = address(0xC0117E6);
        address counterProxy = rollups.createCrossChainProxy(counterL2, rid);
        SafeCounterAndProxy scap = new SafeCounterAndProxy(Counter(counterProxy));

        bytes memory outerCd = abi.encodeCall(SafeCounterAndProxy.incrementProxy, ());
        bytes memory innerCd = abi.encodeCall(Counter.increment, ());
        bytes32 innerHash = _computeActionHash(rid, counterL2, 0, innerCd, address(scap), MAINNET_ROLLUP_ID);

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: address(scap),
            value: 0,
            data: outerCd,
            sourceAddress: address(0xD00D),
            sourceRollupId: rid,
            revertSpan: 0
        });

        ExpectedLookup[] memory lookups = new ExpectedLookup[](1);
        lookups[0] = ExpectedLookup({
            crossChainCallHash: innerHash,
            returnData: bytes("inner reverts"),
            failed: true,
            l2ToL1CallNumber: 1,
            lastL1ToL2CallConsumed: 0,
            executingLookupIndex: 0,
            l2ToL1Calls: new L2ToL1Call[](0),
            expectedL1ToL2Calls: new ExpectedL1ToL2Call[](0),
            callCount: 0,
            rollingHash: bytes32(0)
        });

        // incrementProxy() returns nothing → CALL_END(1, true, "").
        bytes32 h = _rollingHashSingleCall("");

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0); // immediate
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].expectedLookups = lookups;
        entries[0].callCount = 1;
        entries[0].returnData = "";
        entries[0].rollingHash = h;

        _postBatch(rid, entries);

        assertEq(_getRollupState(rid), keccak256("s1"), "entry must complete");
        assertEq(scap.counter(), 1, "outer call must run");
        assertTrue(scap.lastCallFailed(), "inner reentrant call must revert via the entry-scoped lookup");
        assertEq(scap.targetCounter(), 0, "inner call must not have executed");
    }

    /// @notice The `executingLookupIndex` coordinate gates the nested match: a lookup stamped
    ///         as fired inside a sub-execution (k != 0) must NOT resolve at entry level.
    function test_NestedRevertedLookup_WrongExecutingLookupIndex_NoMatch() public {
        (uint256 rid,) = _makeRollupLocal(bytes32(0), alice);

        address counterL2 = address(0xC0117E6);
        address counterProxy = rollups.createCrossChainProxy(counterL2, rid);
        SafeCounterAndProxy scap = new SafeCounterAndProxy(Counter(counterProxy));

        bytes memory outerCd = abi.encodeCall(SafeCounterAndProxy.incrementProxy, ());
        bytes memory innerCd = abi.encodeCall(Counter.increment, ());
        bytes32 innerHash = _computeActionHash(rid, counterL2, 0, innerCd, address(scap), MAINNET_ROLLUP_ID);

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            targetAddress: address(scap),
            value: 0,
            data: outerCd,
            sourceAddress: address(0xD00D),
            sourceRollupId: rid,
            revertSpan: 0
        });

        ExpectedLookup[] memory lookups = new ExpectedLookup[](1);
        lookups[0] = ExpectedLookup({
            crossChainCallHash: innerHash,
            returnData: bytes("inner reverts"),
            failed: true,
            l2ToL1CallNumber: 1,
            lastL1ToL2CallConsumed: 0,
            executingLookupIndex: 1, // wrong context: claims it fires inside expectedLookups[0]'s sub-execution
            l2ToL1Calls: new L2ToL1Call[](0),
            expectedL1ToL2Calls: new ExpectedL1ToL2Call[](0),
            callCount: 0,
            rollingHash: bytes32(0)
        });

        bytes32 h = _rollingHashSingleCall("");

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].expectedLookups = lookups;
        entries[0].callCount = 1;
        entries[0].returnData = "";
        entries[0].rollingHash = h;

        // No match at entry level → deferred no-match → the immediate entry is skipped.
        vm.expectEmit(true, false, false, false);
        emit EEZ.ImmediateEntrySkipped(0, "");
        _postBatch(rid, entries);
        assertEq(_getRollupState(rid), bytes32(0), "entry must not commit");
    }
}
