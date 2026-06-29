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
    StaticLookup,
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
///         reentrant cross-chain call (exercises the `_entryEtherDelta` accounting).
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

/// @notice Posts a batch and, during the meta hook, fires one proxy call so a reverting
///         transient entry can be exercised against the *transient* execution table (which only
///         exists inside `postAndVerifyBatch`). Swallows the proxy revert so the batch still
///         completes; the captured `(success, returnData)` is asserted by the test.
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

    uint64 constant MAINNET_ROLLUP_ID = 0;

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
    function _makeRollupLocal(bytes32 initialState, address owner_) internal returns (uint64 rid, Rollup rollup) {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = DEFAULT_VK;
        rollup = new Rollup(address(rollups), owner_, 1, psList, vks);
        rid = rollups.registerRollup(address(rollup), initialState);
    }

    /// @notice Cross-chain call hash for a top-level proxy entry, as `executeCrossChainCall` computes
    ///         it: source on L1 mainnet (rollup 0), target on the routed rollup. Test-local wrapper
    ///         over `Base._ccHash` kept for callsite compatibility.
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
        return _ccHash(
            NOT_STATIC_CALL, sourceAddress, uint64(sourceRollup), destination, uint64(rollupId), value_, data
        );
    }

    /// @notice Wrap entries into a single-PS / single-rollup batch and call postAndVerifyBatch.
    function _postBatchSingle(uint256 rid, ExecutionEntry[] memory entries, uint256 immediateCount) internal {
        _postBatchSingle(rid, entries, _emptyStaticLookups(), immediateCount, 0);
    }

    function _postBatchSingle(
        uint256 rid,
        ExecutionEntry[] memory entries,
        StaticLookup[] memory staticLookups,
        uint256 immediateCount,
        uint256 immediateStaticLookupCount
    )
        internal
    {
        uint256[] memory rids = new uint256[](1);
        rids[0] = rid;
        _postBatchSingleMulti(rids, entries, staticLookups, immediateCount, immediateStaticLookupCount);
    }

    function _postBatchSingleMulti(
        uint256[] memory rids,
        ExecutionEntry[] memory entries,
        StaticLookup[] memory staticLookups,
        uint256 immediateCount,
        uint256 immediateStaticLookupCount
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
            rps[_i] = RollupIdWithProofSystems({rollupId: uint64(rids[_i]), proofSystemIndexes: psIdx});
        }

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            blockNumber: 0,
            entries: entries,
            staticLookups: staticLookups,
            immediateEntryCount: immediateCount,
            immediateStaticLookupCount: immediateStaticLookupCount,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
    }

    /// @notice Wrap entries into a single-PS batch with `immediateEntryCount = 1` when the leading entry is immediate.
    function _postBatch(uint256 rid, ExecutionEntry[] memory entries) internal {
        uint256 ic = (entries.length > 0 && entries[0].proxyEntryHash == bytes32(0)) ? 1 : 0;
        _postBatchSingle(rid, entries, ic);
    }

    /// @notice Builds a reverting top-level entry (`success == false`): runs, verifies its rolling
    ///         hash, then reverts with `payload`, rolling back all state. Models a top-level
    ///         cross-chain call that reverts (the caller may try/catch the revert).
    function _revertedEntry(uint64 rid, bytes32 currentState, bytes32 proxyEntryHash, bytes memory payload)
        internal
        pure
        returns (ExecutionEntry memory e)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: rid, currentState: currentState, newState: keccak256("rev-newstate"), etherDelta: 0});
        e.stateDeltas = deltas;
        e.proxyEntryHash = proxyEntryHash;
        e.destinationRollupId = rid;
        e.l2ToL1Calls = new L2ToL1Call[](0);
        e.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        e.rollingHash = _hEntryBegin(deltas, proxyEntryHash);
        e.success = false;
        e.returnData = payload;
    }

    /// @notice Builds a minimal reverting top-level `StaticLookup` (no sub-calls), pinned to its own
    ///         destination at the live root so it is structurally valid.
    function _revertedStaticLookup(uint64 rid, bytes32 proxyEntryHash, bytes memory payload)
        internal
        view
        returns (StaticLookup memory lk)
    {
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: rid, stateRoot: _getRollupState(rid)});
        lk.expectedStateRoots = pins;
        lk.proxyEntryHash = proxyEntryHash;
        lk.destinationRollupId = rid;
        lk.l2ToL1Calls = new L2ToL1Call[](0);
        lk.rollingHash = bytes32(0);
        lk.success = false;
        lk.returnData = payload;
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
        (uint64 rid, Rollup r) = _makeRollupLocal(initialState, alice);
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
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        address targetAddr = address(0x1234);
        address proxy = rollups.createCrossChainProxy(targetAddr, rid);
        (, address origAddr,) = rollups.authorizedProxies(proxy);
        assertEq(origAddr, targetAddr);
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(proxy)
        }
        assertGt(codeSize, 0);
    }

    function test_ComputeCrossChainProxyAddress() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        address targetAddr = address(0x5678);
        address computed = rollups.computeCrossChainProxyAddress(targetAddr, rid);
        address actual = rollups.createCrossChainProxy(targetAddr, rid);
        assertEq(computed, actual);
    }

    function test_MultipleProxiesSameTarget() public {
        (uint64 r1,) = _makeRollupLocal(bytes32(0), alice);
        (uint64 r2,) = _makeRollupLocal(bytes32(0), alice);
        address proxy1 = rollups.createCrossChainProxy(address(0x9999), r1);
        address proxy2 = rollups.createCrossChainProxy(address(0x9999), r2);
        assertTrue(proxy1 != proxy2);
    }

    // ──────────────────────────────────────────────
    //  postAndVerifyBatch — immediate state update
    // ──────────────────────────────────────────────

    function test_PostBatch_ImmediateStateUpdate() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        bytes32 newState = keccak256("new state");
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rid, bytes32(0), newState);
        _postBatch(rid, entries);
        assertEq(_getRollupState(rid), newState);
    }

    function test_PostBatch_StateRootMismatch_ImmediateSkipped() public {
        (uint64 rid,) = _makeRollupLocal(keccak256("real"), alice);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        // wrong currentState — chain has keccak256("real"), entry claims bytes32(0).
        // Immediate L2Tx entries run inside a try/catch self-call: the StateRootMismatch revert is
        // swallowed and the entry is reported as `L2TxSkipped`.
        entries[0] = _immediateEntry(rid, bytes32(0), keccak256("new"));
        vm.expectEmit(true, false, false, false);
        emit EEZ.L2TxSkipped(0, "");
        _postBatch(rid, entries);
        // State unchanged because the immediate entry was skipped.
        assertEq(_getRollupState(rid), keccak256("real"));
    }

    function test_PostBatch_MultipleEEZ_OneEntryEach() public {
        (uint64 r1,) = _makeRollupLocal(bytes32(0), alice);
        (uint64 r2,) = _makeRollupLocal(bytes32(0), bob);

        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({rollupId: r1, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});
        deltas[1] = StateDelta({rollupId: r2, currentState: bytes32(0), newState: keccak256("s2"), etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = r1; // any rollup in batch is fine for inline
        entries[0].l2ToL1Calls = new L2ToL1Call[](0);
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].rollingHash = _hEntryBegin(deltas, bytes32(0));
        entries[0].success = true;

        uint256[] memory rids = new uint256[](2);
        // strictly increasing required
        rids[0] = r1 < r2 ? r1 : r2;
        rids[1] = r1 < r2 ? r2 : r1;
        _postBatchSingleMulti(rids, entries, _emptyStaticLookups(), 1, 0);

        assertEq(_getRollupState(r1), keccak256("s1"));
        assertEq(_getRollupState(r2), keccak256("s2"));
    }

    function test_PostBatch_InvalidProofReverts() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
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
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
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
        (uint64 r1,) = _makeRollupLocal(bytes32(0), alice);
        (uint64 r2,) = _makeRollupLocal(bytes32(0), bob);
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
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);

        // Block 1 — post a deferred entry that's never consumed
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (1));
        bytes32 ah = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);
        ExecutionEntry[] memory e1 = new ExecutionEntry[](1);
        StateDelta[] memory d1 = new StateDelta[](1);
        d1[0] = StateDelta({rollupId: rid, currentState: bytes32(0), newState: bytes32(0), etherDelta: 0});
        e1[0].stateDeltas = d1;
        e1[0].proxyEntryHash = ah;
        e1[0].destinationRollupId = rid;
        e1[0].l2ToL1Calls = new L2ToL1Call[](0);
        e1[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        e1[0].rollingHash = _hEntryBegin(d1, ah);
        e1[0].success = true;
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
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rid, bytes32(0), keccak256("s"));
        _postBatch(rid, entries);
        assertEq(rollups.lastVerifiedBlock(rid), block.number);
    }

    // NOTE: dropped after refactor — `postAndVerifyBatch` now
    // takes a single `ProofSystemBatchPerVerificationEntries`, not an array, so there's no
    // "empty array" edge case. The empty-batch validation lives inline in
    // `_validateBatchStructure` (e.g., empty `proofSystems[]` reverts `InvalidProofSystemConfig`)
    // and is exercised by other tests in this file.

    // ──────────────────────────────────────────────
    //  Sub-batch validation
    // ──────────────────────────────────────────────

    function test_SubBatch_DuplicateProofSystemReverts() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
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
        rps[0] = RollupIdWithProofSystems({rollupId: rid, proofSystemIndexes: psIdx});

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            blockNumber: 0,
            entries: new ExecutionEntry[](0),
            staticLookups: new StaticLookup[](0),
            immediateEntryCount: 0,
            immediateStaticLookupCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
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
    //   `checkProofSystemsAndGetVkeys` decides which addresses are allowed (returns non-zero
    //   vkey only for allowed PSes). An "unrelated" PS just reverts with
    //   `ProofSystemNotAllowed` from the manager, not from the registry.

    function test_SubBatch_NonIncreasingRollupIdsReverts() public {
        (uint64 r1,) = _makeRollupLocal(bytes32(0), alice);
        (uint64 r2,) = _makeRollupLocal(bytes32(0), bob);
        // pass them in reverse order
        uint256[] memory rids = new uint256[](2);
        rids[0] = r1 < r2 ? r2 : r1;
        rids[1] = r1 < r2 ? r1 : r2;

        ExecutionEntry[] memory entries = new ExecutionEntry[](0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        _postBatchSingleMulti(rids, entries, _emptyStaticLookups(), 0, 0);
    }

    // NOTE: `test_SubBatch_RollupInMultipleSubBatchesReverts` was dropped after the multi-
    // sub-batch model was collapsed into a single batch and the once-per-block-per-rollup
    // guard was lifted. See `test_PostBatch_SameBlockSameRollup*` for the replacement: a rollup
    // can now be verified multiple times within the same block.

    function test_SubBatch_RollupNotInBatchReverts() public {
        (uint64 r1,) = _makeRollupLocal(bytes32(0), alice);
        (uint64 r2,) = _makeRollupLocal(bytes32(0), bob); // not in this batch's rollupIds

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

    /// @notice Immediate static lookups without immediate entries are unreachable (no immediate
    ///         drain, no meta hook) — `_validateBatchStructure` rejects the shape.
    function test_SubBatch_TransientLookupsWithoutTransientEntriesReverts() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);

        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0] = _revertedStaticLookup(rid, keccak256("h"), hex"deadbeef");

        vm.expectRevert(EEZ.ImmediateStaticLookupsWithoutImmediateEntries.selector);
        _postBatchSingle(rid, new ExecutionEntry[](0), lookups, 0, 1);
    }

    // ──────────────────────────────────────────────
    //  Per-rollup queue routing (executeCrossChainCall / executeL2Txs)
    // ──────────────────────────────────────────────

    function test_ExecuteCrossChainCall_Simple() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 ah = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: rid,
            targetAddress: address(target),
            value: 0,
            data: cd
        });

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("after"), etherDelta: 0});

        // CALL_BEGIN folds the call's identity (target executed ON L1 = MAINNET, source on `rid`).
        bytes32 cch = _ccHash(NOT_STATIC_CALL, address(this), rid, address(target), MAINNET_ROLLUP_ID, 0, cd);
        bytes32 rh = _hEntryBegin(deltas, ah);
        rh = _hCallBegin(rh, cch);
        rh = _hCallEnd(rh, true, "");

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = ah;
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].rollingHash = rh;
        entries[0].success = true;
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
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
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
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);

        // Two entries: first is immediate (transient), second is a pure L2Tx in the persistent queue
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(rid, bytes32(0), keccak256("s1"));
        entries[1] = _immediateEntry(rid, keccak256("s1"), keccak256("s2"));
        _postBatchSingle(rid, entries, 1);

        assertEq(_getRollupState(rid), keccak256("s1"));
        rollups.executeL2Txs(rid);
        assertEq(_getRollupState(rid), keccak256("s2"));
    }

    function test_ExecuteL2TX_NotInCurrentBlockReverts() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        vm.expectRevert(abi.encodeWithSelector(EEZ.ExecutionNotInCurrentBlock.selector, rid));
        rollups.executeL2Txs(rid);
    }

    function test_ExecuteInContext_NotSelfReverts() public {
        vm.expectRevert(EEZBase.NotSelf.selector);
        rollups.executeInContextAndRevert(new L2ToL1Call[](0));
    }

    // ──────────────────────────────────────────────
    //  Ether accounting
    // ──────────────────────────────────────────────

    function test_PostBatch_EtherDeltasMustSumToZero() public {
        (uint64 r1,) = _makeRollupLocal(bytes32(0), alice);
        (uint64 r2,) = _makeRollupLocal(bytes32(0), bob);
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
        entries[0].rollingHash = _hEntryBegin(deltas, bytes32(0));
        entries[0].success = true;

        uint256[] memory rids = new uint256[](2);
        rids[0] = r1 < r2 ? r1 : r2;
        rids[1] = r1 < r2 ? r2 : r1;
        _postBatchSingleMulti(rids, entries, _emptyStaticLookups(), 1, 0);

        assertEq(_getRollupEtherBalance(r1), 3 ether);
        assertEq(_getRollupEtherBalance(r2), 2 ether);
    }

    function test_PostBatch_EtherDeltasNonZeroSum_ImmediateSkipped() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
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
        entries[0].rollingHash = _hEntryBegin(deltas, bytes32(0));
        entries[0].success = true;
        // EtherDeltaMismatch raised inside the immediate L2Tx run → caught → L2TxSkipped.
        vm.expectEmit(true, false, false, false);
        emit EEZ.L2TxSkipped(0, "");
        _postBatch(rid, entries);
        assertEq(_getRollupState(rid), bytes32(0));
        assertEq(_getRollupEtherBalance(rid), 5 ether);
    }

    function test_PostBatch_InsufficientRollupBalance_ImmediateSkipped() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: -1 ether});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = new L2ToL1Call[](0);
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].rollingHash = _hEntryBegin(deltas, bytes32(0));
        entries[0].success = true;
        // InsufficientRollupBalance raised inside the immediate L2Tx run → caught → L2TxSkipped.
        vm.expectEmit(true, false, false, false);
        emit EEZ.L2TxSkipped(0, "");
        _postBatch(rid, entries);
        assertEq(_getRollupState(rid), bytes32(0));
        assertEq(_getRollupEtherBalance(rid), 0);
    }

    /// @notice Builds the reentrant-value fixture: an entry call sends 2 ether to a
    ///         ValueForwarder, which forwards 1.5 ether back into a proxy as a reentrant
    ///         cross-chain call. Net for the rollup: -0.5 ether.
    function _reentrantValueEntry(uint64 rid, int256 etherDelta)
        internal
        returns (ExecutionEntry[] memory entries, ValueForwarder forwarder)
    {
        forwarder = new ValueForwarder();
        address remote = address(0xBEEF);
        forwarder.setPeer(rollups.createCrossChainProxy(remote, rid));

        bytes memory depositData = abi.encodeWithSignature("deposit()");
        // reentrant call hash: source = forwarder on L1 (mainnet), target = remote on `rid`.
        bytes32 nestedHash =
            _computeActionHash(rid, remote, 1.5 ether, depositData, address(forwarder), MAINNET_ROLLUP_ID);

        bytes memory forwardData = abi.encodeCall(ValueForwarder.forward, (1.5 ether));
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(0xD00D),
            sourceRollupId: rid,
            targetAddress: address(forwarder),
            value: 2 ether,
            data: forwardData
        });

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: etherDelta});

        // Rolling hash: the reentrant call fires right after the top call's CALL_BEGIN, so its
        // position key is keyed on `_rollingHash` at that instant. A SUCCESS frame folds
        // NESTED_BEGIN/END (no sub-calls), then the top call's CALL_END closes.
        bytes32 cchTop =
            _ccHash(NOT_STATIC_CALL, address(0xD00D), rid, address(forwarder), MAINNET_ROLLUP_ID, 2 ether, forwardData);
        bytes32 h = _hEntryBegin(deltas, bytes32(0));
        h = _hCallBegin(h, cchTop);
        bytes32 fireHash = h;
        h = _hNestedBegin(h, nestedHash);
        h = _hNestedEnd(h);
        h = _hCallEnd(h, true, abi.encode(uint256(2 ether)));

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: _expectedL1toL2Hash(nestedHash, fireHash),
            l2ToL1Calls: new L2ToL1Call[](0),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: ""
        });

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = nested;
        entries[0].rollingHash = h;
        entries[0].success = true;
        entries[0].returnData = "";
    }

    function test_ReentrantValue_CountedInEtherAccounting() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
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
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        _fundRollup(rid, 2 ether);

        // Delta pretends the reentrant 1.5 ether never came back → EtherDeltaMismatch
        // inside the immediate L2Tx run → caught → L2TxSkipped, all rolled back.
        (ExecutionEntry[] memory entries, ValueForwarder forwarder) = _reentrantValueEntry(rid, -2 ether);
        vm.expectEmit(true, false, false, false);
        emit EEZ.L2TxSkipped(0, "");
        _postBatch(rid, entries);

        assertEq(_getRollupState(rid), bytes32(0));
        assertEq(_getRollupEtherBalance(rid), 2 ether);
        assertEq(address(forwarder).balance, 0);
        assertEq(address(rollups).balance, 2 ether);
    }

    /// @notice Entry whose REENTRANT (nested) frame itself sends ether OUT of EEZ — the case a
    ///         per-frame local `etherOut` silently dropped. Top-level sends 2 ether to a forwarder;
    ///         the forwarder reenters with 1.5 ether; the nested frame then sends 1 ether out to
    ///         `sink`. True net = 1.5 in − 2 − 1 = −1.5 ether. A local accumulator (discarded when
    ///         the reentrant frame returns) would have seen only the 2-ether top-level outflow and
    ///         computed −0.5.
    /// @notice One-element `L2ToL1Call` array (source `0xD00D` on `rid`), built in a sub-frame to keep
    ///         `_nestedOutflowEntry` under the stack-depth limit under coverage instrumentation.
    function _nestedOutflowCall(uint64 rid, address tgt, uint256 value, bytes memory data)
        internal
        pure
        returns (L2ToL1Call[] memory arr)
    {
        arr = new L2ToL1Call[](1);
        arr[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(0xD00D),
            sourceRollupId: rid,
            targetAddress: tgt,
            value: value,
            data: data
        });
    }

    /// @notice Rolling hash for `_nestedOutflowEntry` (top-level forward + nested outflow + return).
    ///         Pulled out so the builder stays under the stack-depth limit under coverage instrumentation.
    function _nestedOutflowRollingHash(StateDelta[] memory deltas, bytes32 cchTop, bytes32 nestedHash, bytes32 cchSink)
        internal
        pure
        returns (bytes32 h, bytes32 fireHash)
    {
        h = _hEntryBegin(deltas, bytes32(0));
        h = _hCallBegin(h, cchTop); // top-level begin
        fireHash = h; // reentrant fires here
        h = _hNestedBegin(h, nestedHash); // reentry begin
        h = _hCallBegin(h, cchSink); // nested outflow begin
        h = _hCallEnd(h, true, ""); // nested outflow end — plain ETH transfer returns ""
        h = _hNestedEnd(h); // reentry end
        h = _hCallEnd(h, true, abi.encode(uint256(2 ether))); // forward() returns msg.value
    }

    function _nestedOutflowEntry(uint64 rid, address sink, int256 etherDelta)
        internal
        returns (ExecutionEntry[] memory entries, ValueForwarder forwarder)
    {
        forwarder = new ValueForwarder();
        address remote = address(0xBEEF);
        forwarder.setPeer(rollups.createCrossChainProxy(remote, rid));

        bytes memory depositData = abi.encodeWithSignature("deposit()");
        bytes32 nestedHash =
            _computeActionHash(rid, remote, 1.5 ether, depositData, address(forwarder), MAINNET_ROLLUP_ID);

        bytes memory forwardData = abi.encodeCall(ValueForwarder.forward, (1.5 ether));
        // Top-level call that drives the reentry.
        L2ToL1Call[] memory calls = _nestedOutflowCall(rid, address(forwarder), 2 ether, forwardData);
        // Consumed INSIDE the nested frame — sends 1 ether out of EEZ to `sink`.
        L2ToL1Call[] memory subCalls = _nestedOutflowCall(rid, sink, 1 ether, "");

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: etherDelta});

        bytes32 cchTop =
            _ccHash(NOT_STATIC_CALL, address(0xD00D), rid, address(forwarder), MAINNET_ROLLUP_ID, 2 ether, forwardData);

        // Extracted into a sub-frame to keep this builder under the stack-depth limit.
        (bytes32 h, bytes32 fireHash) = _nestedOutflowRollingHash(
            deltas, cchTop, nestedHash, _ccHash(NOT_STATIC_CALL, address(0xD00D), rid, sink, MAINNET_ROLLUP_ID, 1 ether, "")
        );

        // Assembled in a sub-frame to keep this builder under the stack-depth limit.
        entries = _assembleNestedOutflowEntry(rid, deltas, calls, subCalls, _expectedL1toL2Hash(nestedHash, fireHash), h);
    }

    /// @notice Final entry assembly for `_nestedOutflowEntry`, in a sub-frame for stack-depth headroom.
    function _assembleNestedOutflowEntry(
        uint64 rid,
        StateDelta[] memory deltas,
        L2ToL1Call[] memory calls,
        L2ToL1Call[] memory subCalls,
        bytes32 nestedKey,
        bytes32 rollingHash
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: nestedKey,
            l2ToL1Calls: subCalls,
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: ""
        });

        entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = nested;
        entries[0].rollingHash = rollingHash;
        entries[0].success = true;
        entries[0].returnData = "";
    }

    /// @notice The fixed accounting credits the FULL net outflow, including ether sent inside a
    ///         reentrant frame. Fails on the pre-fix code (local `etherOut` drops the nested 1 ether,
    ///         so the −1.5 delta mismatches the computed −0.5 → L2TxSkipped).
    function test_NestedOutflow_CountedInEtherAccounting() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        _fundRollup(rid, 2 ether);
        TestTarget sink = new TestTarget();

        (ExecutionEntry[] memory entries, ValueForwarder forwarder) =
            _nestedOutflowEntry(rid, address(sink), -1.5 ether);
        _postBatch(rid, entries);

        assertEq(_getRollupState(rid), keccak256("s1"), "entry must apply");
        assertEq(_getRollupEtherBalance(rid), 0.5 ether, "rollup debited the full net outflow");
        assertEq(address(sink).balance, 1 ether, "nested outflow physically left EEZ");
        assertEq(address(forwarder).balance, 0.5 ether);
        assertEq(address(rollups).balance, 0.5 ether, "booked balance == physical balance");
    }

    /// @notice Soundness: the delta a per-frame local would have accepted (−0.5, nested outflow
    ///         dropped) must now be REJECTED, otherwise EEZ would book 1 ether it no longer holds.
    function test_NestedOutflow_DroppedDeltaRejected() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        _fundRollup(rid, 2 ether);
        TestTarget sink = new TestTarget();

        (ExecutionEntry[] memory entries,) = _nestedOutflowEntry(rid, address(sink), -0.5 ether);
        vm.expectEmit(true, false, false, false);
        emit EEZ.L2TxSkipped(0, "");
        _postBatch(rid, entries);

        assertEq(_getRollupState(rid), bytes32(0), "unsound entry must not apply");
        assertEq(_getRollupEtherBalance(rid), 2 ether);
        assertEq(address(sink).balance, 0);
        assertEq(address(rollups).balance, 2 ether);
    }

    // ──────────────────────────────────────────────
    //  Owner ops on Rollup.sol (the per-rollup contract)
    // ──────────────────────────────────────────────

    function test_RollupSetStateRoot_ByOwner() public {
        (uint64 rid, Rollup r) = _makeRollupLocal(bytes32(0), alice);
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
        (uint64 rid, Rollup r) = _makeRollupLocal(bytes32(0), alice);
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
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 ah = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: rid,
            targetAddress: address(target),
            value: 0,
            data: cd
        });
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = ah;
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].rollingHash = bytes32(uint256(0xdead)); // wrong!
        entries[0].success = true;
        _postBatchSingle(rid, entries, 0);
        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        proxyAddr.call(cd);
    }

    /// @notice Providing more top-level calls than the entry's `rollingHash` accounts for diverges
    ///         the hash (every call folds CALL_BEGIN/END), surfacing as `RollingHashMismatch`. The
    ///         old dedicated `UnconsumedL2ToL1Calls` error is gone — `_processNCalls` runs the WHOLE
    ///         array and completeness is enforced structurally by the rolling hash.
    function test_UnconsumedCalls_Reverts() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 ah = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: rid,
            targetAddress: address(target),
            value: 0,
            data: cd
        });
        calls[1] = calls[0];
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s"), etherDelta: 0});

        // rollingHash accounts for ONE call; two are provided → divergence.
        bytes32 cch = _ccHash(NOT_STATIC_CALL, address(this), rid, address(target), MAINNET_ROLLUP_ID, 0, cd);
        bytes32 rh = _hEntryBegin(deltas, ah);
        rh = _hCallBegin(rh, cch);
        rh = _hCallEnd(rh, true, "");

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = ah;
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].rollingHash = rh;
        entries[0].success = true;
        _postBatchSingle(rid, entries, 0);
        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
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
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
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
        (uint64 rid, Rollup r) = _makeRollupLocal(bytes32(0), alice);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit EEZ.StateUpdated(rid, keccak256("escape"));
        r.setStateRoot(keccak256("escape"));
    }

    // ──────────────────────────────────────────────
    //  Top-level reverting entries (success == false)
    // ──────────────────────────────────────────────
    //
    // A top-level cross-chain call that reverts is a normal `ExecutionEntry` with `success == false`:
    // it runs, verifies its rolling hash, then reverts with the cached `returnData`, rolling back all
    // state effects (including the cursor advance) so the caller's try/catch sees the revert and the
    // queue is not consumed. (There is no separate reverted-lookup pool for state-changing calls; the
    // read-only `StaticLookup` pool serves static reads via `staticCallLookup`.)

    /// @notice Deferred path: the reverting entry sits in `verificationByRollup[rid].executionQueue`
    ///         and a top-level proxy call reverts with its cached returnData; the cursor advance rolls
    ///         back with the revert, so a second identical call reverts identically.
    function test_RevertedLookup_TopLevel_Deferred() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes memory payload = hex"deadbeef";
        // Hash exactly as `executeCrossChainCall` computes it: source = this test (it calls the proxy).
        bytes32 h = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _revertedEntry(rid, bytes32(0), h, payload);
        _postBatchSingle(rid, entries, 0); // deferred — queued, consumed via the proxy

        uint256 cursorBefore = rollups.executionQueueIndex(rid);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, payload);
        assertEq(rollups.executionQueueIndex(rid), cursorBefore, "reverting entry rolls back the cursor advance");

        // Repeatable: a second identical call reverts identically, still no advance.
        (ok, ret) = proxyAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, payload);
        assertEq(rollups.executionQueueIndex(rid), cursorBefore);
    }

    /// @notice Transient path: the reverting entry lives in `_transientExecutions` and is hit by a
    ///         proxy call fired from inside the meta hook (the only window the transient table exists).
    function test_RevertedLookup_TopLevel_Transient() public {
        (uint64 rid, Rollup rollup) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        MetaLookupCaller caller = new MetaLookupCaller(rollups);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes memory payload = hex"c0ffee";
        // The meta-hook caller is what calls through the proxy, so it's the hash's sourceAddress.
        bytes32 h = _computeActionHash(rid, address(target), 0, cd, address(caller), MAINNET_ROLLUP_ID);
        caller.setProxyCall(proxyAddr, cd);

        // One reverting transient entry whose `proxyEntryHash != 0` so the leading L2Tx run stops and
        // the meta hook fires; the caller drives it via the proxy.
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _revertedEntry(rid, bytes32(0), h, payload);

        // immediateEntryCount = 1 → the entry stays in the transient table for the meta hook.
        RollupHandle memory handle = RollupHandle({id: rid, manager: rollup});
        ProofSystemBatchPerVerificationEntries memory batch =
            _singleSubBatch(handle, entries, _emptyStaticLookups(), 1, 0);
        caller.post(batch);

        assertTrue(caller.hookRan(), "meta hook did not run");
        assertFalse(caller.callSuccess(), "proxy call should have reverted");
        assertEq(caller.callReturnData(), payload);
    }

    /// @notice Negative path: rollup verified this block but no entry matches → ExecutionNotFound.
    function test_RevertedLookup_TopLevel_NoMatchReverts() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);
        // Verify the rollup this block, but post nothing to consume.
        _postBatchSingle(rid, _emptyEntries(), _emptyStaticLookups(), 0, 0);

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
    //  Reverting-entry sub-execution
    // ──────────────────────────────────────────────
    //
    // A `success == false` entry can carry a real sub-execution: `l2ToL1Calls[]` that run for real
    // and then get discarded by the terminal revert. The rolling hash is still verified BEFORE the
    // revert, so the sub-calls genuinely run.

    /// @notice Reverting entry whose execution runs one real sub-call `subTarget.setValue(subValue)`
    ///         then reverts `payload`.
    function _revertedEntryWithSubcall(
        uint64 rid,
        bytes32 proxyEntryHash,
        bytes memory payload,
        address subTarget,
        uint256 subValue
    )
        internal
        view
        returns (ExecutionEntry memory e)
    {
        bytes memory subCd = abi.encodeCall(TestTarget.setValue, (subValue));
        L2ToL1Call[] memory subCalls = new L2ToL1Call[](1);
        subCalls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: rid,
            targetAddress: subTarget,
            value: 0,
            data: subCd
        });
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: rid, currentState: _getRollupState(rid), newState: keccak256("rev"), etherDelta: 0});

        bytes32 cch = _ccHash(NOT_STATIC_CALL, address(this), rid, subTarget, MAINNET_ROLLUP_ID, 0, subCd);
        bytes32 h = _hEntryBegin(deltas, proxyEntryHash);
        h = _hCallBegin(h, cch);
        h = _hCallEnd(h, true, "");

        e.stateDeltas = deltas;
        e.proxyEntryHash = proxyEntryHash;
        e.destinationRollupId = rid;
        e.l2ToL1Calls = subCalls;
        e.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        e.rollingHash = h;
        e.success = false;
        e.returnData = payload;
    }

    /// @notice Happy path: the reverting entry runs its sub-execution, then reverts with the cached
    ///         `returnData`; the sub-call's state change is discarded by the revert and the queue is
    ///         not advanced.
    function test_RevertedLookup_SubExecution_RunsAndReverts() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes32 h = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);
        bytes memory payload = hex"deadbeef";

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _revertedEntryWithSubcall(rid, h, payload, address(target), 99);
        _postBatchSingle(rid, entries, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, payload, "must revert with the entry's returnData");
        assertEq(target.value(), 0, "sub-execution state must be discarded by the terminal revert");
        assertEq(rollups.executionQueueIndex(rid), 0, "reverting entry rolls back the cursor advance");
    }

    /// @notice Proves the sub-execution actually RUNS the sub-calls: a wrong `rollingHash` makes the
    ///         post-execution check fire `RollingHashMismatch` (impossible if the calls were skipped).
    function test_RevertedLookup_SubExecution_WrongHashReverts() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes32 h = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);

        ExecutionEntry memory e = _revertedEntryWithSubcall(rid, h, hex"deadbeef", address(target), 99);
        e.rollingHash = keccak256("wrong"); // != the hash the real sub-execution produces
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = e;
        _postBatchSingle(rid, entries, 0);

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

    /// @notice State precondition is part of the MATCH: a reverting entry whose `currentState` no
    ///         longer holds is skipped, and with no other candidate the call ends `ExecutionNotFound`.
    function test_RevertedLookup_StateRootPin_MismatchSkips() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice); // live root is 0
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes32 h = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _revertedEntry(rid, keccak256("wrong-root"), h, hex"deadbeef"); // stale currentState
        _postBatchSingle(rid, entries, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        assertEq(sel, EEZBase.ExecutionNotFound.selector, "stale currentState must skip the candidate");
    }

    /// @notice An entry whose `currentState` equals the LIVE state root matches and reverts with its
    ///         cached returnData.
    function test_RevertedLookup_StateRootPin_MatchResolves() public {
        (uint64 rid,) = _makeRollupLocal(keccak256("live-root"), alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes memory payload = hex"deadbeef";
        bytes32 h = _computeActionHash(rid, address(target), 0, cd, address(this), MAINNET_ROLLUP_ID);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _revertedEntry(rid, keccak256("live-root"), h, payload);
        _postBatchSingle(rid, entries, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, payload, "live currentState must match and revert with the cached returnData");
    }

    /// @notice REVERTED reentrant call: a reentrant (L1→L2) call resolved as a `success == false`
    ///         `ExpectedL1ToL2Call` reverts; the caller's try/catch absorbs it. The reverting frame's
    ///         folds roll back, so the host entry still completes.
    function test_NestedRevertedLookup_EntryScoped_RevertsAndCatches() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);

        // Inner target: proxy on L1 for a Counter living on rollup `rid`.
        address counterL2 = address(0xC0117E6);
        address counterProxy = rollups.createCrossChainProxy(counterL2, rid);
        SafeCounterAndProxy scap = new SafeCounterAndProxy(Counter(counterProxy));

        bytes memory outerCd = abi.encodeCall(SafeCounterAndProxy.incrementProxy, ());
        bytes memory innerCd = abi.encodeCall(Counter.increment, ());
        bytes32 innerHash = _computeActionHash(rid, counterL2, 0, innerCd, address(scap), MAINNET_ROLLUP_ID);

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(0xD00D),
            sourceRollupId: rid,
            targetAddress: address(scap),
            value: 0,
            data: outerCd
        });

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});

        bytes32 cchTop = _ccHash(NOT_STATIC_CALL, address(0xD00D), rid, address(scap), MAINNET_ROLLUP_ID, 0, outerCd);
        // The reentrant call fires after the top call's CALL_BEGIN.
        bytes32 fireHash = _hCallBegin(_hEntryBegin(deltas, bytes32(0)), cchTop);

        ExpectedL1ToL2Call[] memory reentrant = new ExpectedL1ToL2Call[](1);
        reentrant[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: _expectedL1toL2Hash(innerHash, fireHash),
            l2ToL1Calls: new L2ToL1Call[](0),
            // REVERTED frame checks its mid-call hash == _rollingHash after NESTED_BEGIN (no sub-calls).
            revertedOrStaticRollingHash: _hNestedBegin(fireHash, innerHash),
            success: false,
            returnData: bytes("inner reverts")
        });

        // The reverted reentrant frame's folds roll back, so the host's hash is just the top call.
        bytes32 h = _hCallEnd(fireHash, true, "");

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0); // immediate
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = reentrant;
        entries[0].rollingHash = h;
        entries[0].success = true;
        entries[0].returnData = "";

        _postBatch(rid, entries);

        assertEq(_getRollupState(rid), keccak256("s1"), "entry must complete");
        assertEq(scap.counter(), 1, "outer call must run");
        assertTrue(scap.lastCallFailed(), "inner reentrant call must revert via the reverted reentrant entry");
        assertEq(scap.targetCounter(), 0, "inner call must not have executed");
    }

    /// @notice The reentrant position key (`keccak(crossChainCallHash, _rollingHash)`) gates the match:
    ///         a reentrant entry stamped at the wrong rolling-hash position never matches, so the call
    ///         folds CALL_NOT_FOUND, the entry's rolling hash diverges, and the immediate entry is skipped.
    function test_NestedRevertedLookup_WrongExecutingLookupIndex_NoMatch() public {
        (uint64 rid,) = _makeRollupLocal(bytes32(0), alice);

        address counterL2 = address(0xC0117E6);
        address counterProxy = rollups.createCrossChainProxy(counterL2, rid);
        SafeCounterAndProxy scap = new SafeCounterAndProxy(Counter(counterProxy));

        bytes memory outerCd = abi.encodeCall(SafeCounterAndProxy.incrementProxy, ());

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(0xD00D),
            sourceRollupId: rid,
            targetAddress: address(scap),
            value: 0,
            data: outerCd
        });

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rid, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});

        bytes32 cchTop = _ccHash(NOT_STATIC_CALL, address(0xD00D), rid, address(scap), MAINNET_ROLLUP_ID, 0, outerCd);
        bytes32 fireHash = _hCallBegin(_hEntryBegin(deltas, bytes32(0)), cchTop);

        ExpectedL1ToL2Call[] memory reentrant = new ExpectedL1ToL2Call[](1);
        reentrant[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: keccak256("wrong-position"), // never matches the fire-time key
            l2ToL1Calls: new L2ToL1Call[](0),
            revertedOrStaticRollingHash: bytes32(0),
            success: false,
            returnData: bytes("inner reverts")
        });

        // The entry's hash is the would-be-success value (no CALL_NOT_FOUND fold); the actual run
        // folds CALL_NOT_FOUND → divergence → skip.
        bytes32 h = _hCallEnd(fireHash, true, "");

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = rid;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = reentrant;
        entries[0].rollingHash = h;
        entries[0].success = true;
        entries[0].returnData = "";

        // No reentrant match → CALL_NOT_FOUND → RollingHashMismatch → the immediate entry is skipped.
        vm.expectEmit(true, false, false, false);
        emit EEZ.L2TxSkipped(0, "");
        _postBatch(rid, entries);
        assertEq(_getRollupState(rid), bytes32(0), "entry must not commit");
    }
}
