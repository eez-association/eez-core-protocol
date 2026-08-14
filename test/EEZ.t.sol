// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries} from "../src/EEZ.sol";
import {Rollup} from "../src/rollupContract/Rollup.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ExecutionEntry,
    StateUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    StaticExecutionEntry,
    ExpectedStateRootPerRollup
} from "../src/interfaces/IEEZ.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {IMetaCrossChainReceiver} from "../src/interfaces/IMetaCrossChainReceiver.sol";
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

/// @notice Target contract that always reverts. Currently unused — kept as a placeholder target.
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

    uint64 internal constant MAINNET_ROLLUP_ID = 0;

    function setUp() public {
        setUpBase();
        target = new TestTarget();
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    /// @notice Appends a no-op SUCCESSFUL immediate L2Tx (`root → same root`, no ether) to `entries`.
    ///         Used by skip tests: the intended-bad immediate entry stays at index 0 (still skipped +
    ///         rolled back), and this surviving entry keeps the leading run from being 100% failed —
    ///         otherwise `AllImmediateL2TxsFailed` would unwind the whole post. The no-op leaves state
    ///         and ether untouched, so the test's post-conditions are unchanged.
    function _withNoopImmediate(ExecutionEntry[] memory entries, uint256 rid, bytes32 root)
        internal
        pure
        returns (ExecutionEntry[] memory out)
    {
        out = new ExecutionEntry[](entries.length + 1);
        for (uint256 k = 0; k < entries.length; k++) {
            out[k] = entries[k];
        }
        out[entries.length] = _immediateEntry(rid, root, root);
    }

    /// @notice A non-L2Tx queued entry (`proxyEntryHash != 0`). Occupies the boundary slot past the
    ///         immediate prefix so a queued L2Tx can legally sit behind it (the
    ///         `ImmediateCountStrandsLeadingL2Tx` guard forbids a leading L2Tx at the boundary). Never
    ///         consumed by these tests, so its state values are placeholders.
    function _boundaryEntry(uint256 rid) internal pure returns (ExecutionEntry memory entry) {
        entry = _immediateEntry(rid, bytes32(0), bytes32(0));
        entry.proxyEntryHash = keccak256("boundary"); // non-zero ⇒ not an L2Tx
        entry.rollingHash = _hEntryBegin(entry.stateUpdates, entry.proxyEntryHash);
    }

    /// @notice Builds a reverting top-level entry (`success == false`): runs, verifies its rolling
    ///         hash, then reverts with `payload`, rolling back all state. Models a top-level
    ///         cross-chain call that reverts (the caller may try/catch the revert).
    function _revertedEntry(uint64 rid, bytes32 currentState, bytes32 proxyEntryHash, bytes memory payload)
        internal
        pure
        returns (ExecutionEntry memory e)
    {
        e = _shellEntry(rid, _oneDelta(rid, currentState, keccak256("rev-newstate"), 0));
        e.proxyEntryHash = proxyEntryHash;
        e.rollingHash = _hEntryBegin(e.stateUpdates, proxyEntryHash);
        e.success = false;
        e.returnData = payload;
    }

    /// @notice Builds a minimal reverting top-level `StaticExecutionEntry` (no sub-calls), pinned to its own
    ///         destination at the live root so it is structurally valid.
    function _revertedStaticLookup(uint64 rid, bytes32 proxyEntryHash, bytes memory payload)
        internal
        view
        returns (StaticExecutionEntry memory lk)
    {
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: rid, stateRoot: _getRollupState(rid)});
        lk.expectedStateRoots = pins;
        lk.proxyEntryHash = proxyEntryHash;
        lk.destinationRollupId = rid;
        lk.l2ToL1Calls = _emptyCalls();
        lk.rollingHash = bytes32(0);
        lk.success = false;
        lk.returnData = payload;
    }

    // ──────────────────────────────────────────────
    //  Rollup creation
    // ──────────────────────────────────────────────

    function test_CreateRollup() public {
        bytes32 initialState = keccak256("initial");
        RollupHandle memory r = _makeRollupWithOwner(initialState, alice);
        // registerRollup pre-increments rollupCounter, so id 0 (MAINNET_ROLLUP_ID) is
        // skipped and the first user-registered rollup lands at id 1.
        assertEq(r.id, 1);
        assertEq(_getRollupState(r.id), initialState);
        assertEq(_getRollupContract(r.id), address(r.manager));
        // After registration, the Rollup's `rollupId` is set via the rollupContractRegistered callback
        assertEq(r.manager.rollupId(), r.id);
        assertEq(r.manager.owner(), alice);
        assertEq(r.manager.threshold(), 1);
        assertEq(r.manager.verificationKey(address(ps)), DEFAULT_VK);
    }

    function test_CreateRollup_ZeroAddressContractReverts() public {
        vm.expectRevert(EEZ.InvalidRollupContract.selector);
        rollups.registerRollup(address(0), bytes32(0));
    }

    function test_CreateRollup_RegistryItselfReverts() public {
        vm.expectRevert(EEZ.InvalidRollupContract.selector);
        rollups.registerRollup(address(rollups), bytes32(0));
    }

    // ──────────────────────────────────────────────
    //  CrossChainProxy creation
    // ──────────────────────────────────────────────

    function test_CreateCrossChainProxy() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address targetAddr = address(0x1234);
        address proxy = rollups.createCrossChainProxy(targetAddr, uint64(r.id));
        (, address origAddr,) = rollups.authorizedProxies(proxy);
        assertEq(origAddr, targetAddr);
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(proxy)
        }
        assertGt(codeSize, 0);
    }

    function test_ComputeCrossChainProxyAddress() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address targetAddr = address(0x5678);
        address computed = rollups.computeCrossChainProxyAddress(targetAddr, uint64(r.id));
        address actual = rollups.createCrossChainProxy(targetAddr, uint64(r.id));
        assertEq(computed, actual);
    }

    function test_CreateCrossChainProxy_SweepsPredeployedEther() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address targetAddr = address(0x1234);
        address predicted = rollups.computeCrossChainProxyAddress(targetAddr, uint64(r.id));
        vm.deal(predicted, 3 ether);

        uint256 recoveryBalanceBefore = rollups.RECOVERY_ADDRESS().balance;
        address proxy = rollups.createCrossChainProxy(targetAddr, uint64(r.id));

        assertEq(proxy, predicted);
        assertEq(proxy.balance, 0);
        assertEq(rollups.RECOVERY_ADDRESS().balance, recoveryBalanceBefore + 3 ether);
    }

    function test_MultipleProxiesSameTarget() public {
        RollupHandle memory r1 = _makeRollup(bytes32(0));
        RollupHandle memory r2 = _makeRollup(bytes32(0));
        address proxy1 = rollups.createCrossChainProxy(address(0x9999), uint64(r1.id));
        address proxy2 = rollups.createCrossChainProxy(address(0x9999), uint64(r2.id));
        assertTrue(proxy1 != proxy2);
    }

    // ──────────────────────────────────────────────
    //  postAndVerifyBatch — immediate state update
    // ──────────────────────────────────────────────

    function test_PostBatch_ImmediateStateUpdate() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        bytes32 newState = keccak256("new state");
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, bytes32(0), newState);
        _postBatchAutoTransient(r, entries);
        assertEq(_getRollupState(r.id), newState);
    }

    function test_PostBatch_ExpectedStateRootPin_Match() public {
        RollupHandle memory r = _makeRollup(keccak256("root"));
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: uint64(r.id), stateRoot: keccak256("root")});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, keccak256("root"), keccak256("next"));
        _postBatchWithPins(r, entries, pins);
        assertEq(_getRollupState(r.id), keccak256("next"));
    }

    function test_PostBatch_ExpectedStateRootPin_Mismatch_Reverts() public {
        RollupHandle memory r = _makeRollup(keccak256("root"));
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: uint64(r.id), stateRoot: keccak256("WRONG")});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, keccak256("root"), keccak256("next"));
        vm.expectRevert(abi.encodeWithSelector(EEZ.ExpectedStateRootMismatch.selector, uint64(r.id)));
        _postBatchWithPins(r, entries, pins);
    }

    function test_PostBatch_StateRootMismatch_ImmediateSkipped() public {
        RollupHandle memory r = _makeRollup(keccak256("real"));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        // wrong currentState — chain has keccak256("real"), entry claims bytes32(0).
        // Immediate L2Tx entries run inside a try/catch self-call: the StateRootMismatch revert is
        // swallowed and the entry is reported as `L2TxSkipped`.
        entries[0] = _immediateEntry(r.id, bytes32(0), keccak256("new"));
        // Pair the bad entry with a surviving no-op so the run isn't 100% failed (else the whole post
        // unwinds with AllImmediateL2TxsFailed); the bad one at index 0 is still skipped.
        entries = _withNoopImmediate(entries, r.id, keccak256("real"));
        vm.expectEmit(true, false, false, false);
        emit EEZ.L2TxSkipped(0, "");
        _postBatchOne(r, entries, _emptyStaticEntries(), 2, 0);
        // State unchanged because the immediate entry was skipped.
        assertEq(_getRollupState(r.id), keccak256("real"));
    }

    function test_PostBatch_MultipleEEZ_OneEntryEach() public {
        // registerRollup assigns strictly increasing ids, so r1.id < r2.id.
        RollupHandle memory r1 = _makeRollup(bytes32(0));
        RollupHandle memory r2 = _makeRollup(bytes32(0));

        StateUpdate[] memory deltas = new StateUpdate[](2);
        deltas[0] =
            StateUpdate({rollupId: uint64(r1.id), currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});
        deltas[1] =
            StateUpdate({rollupId: uint64(r2.id), currentState: bytes32(0), newState: keccak256("s2"), etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r1.id, deltas); // any rollup in batch is fine for inline
        entries[0].rollingHash = _hEntryBegin(deltas, bytes32(0));

        rollups.postAndVerifyBatch(_twoRollupBatch(r1.id, r2.id, entries, _emptyStaticEntries(), 1, 0));

        assertEq(_getRollupState(r1.id), keccak256("s1"));
        assertEq(_getRollupState(r2.id), keccak256("s2"));
    }

    function test_PostBatch_InvalidProofReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, bytes32(0), keccak256("s"));
        // Verification on with no pinned hash — rejects every proof.
        ps.setShouldVerify(true);
        vm.expectRevert(EEZ.InvalidProof.selector);
        _postBatchAutoTransient(r, entries);
    }

    /// @notice Multiple verifications for the same rollup in the same block are allowed:
    ///         the second batch picks up where the first left off (state has advanced to s1,
    ///         the second batch transitions s1 → s2). Each verify wipes the rollup's queue,
    ///         so the second batch fully replaces the first's entries.
    function test_PostBatch_SameBlockSameRollupOk() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries1 = new ExecutionEntry[](1);
        entries1[0] = _immediateEntry(r.id, bytes32(0), keccak256("s1"));
        _postBatchAutoTransient(r, entries1);
        assertEq(_getRollupState(r.id), keccak256("s1"));

        ExecutionEntry[] memory entries2 = new ExecutionEntry[](1);
        entries2[0] = _immediateEntry(r.id, keccak256("s1"), keccak256("s2"));
        _postBatchAutoTransient(r, entries2);
        assertEq(_getRollupState(r.id), keccak256("s2"));
    }

    function test_PostBatch_SameBlockDifferentEEZOk() public {
        RollupHandle memory r1 = _makeRollup(bytes32(0));
        RollupHandle memory r2 = _makeRollup(bytes32(0));
        ExecutionEntry[] memory e1 = new ExecutionEntry[](1);
        e1[0] = _immediateEntry(r1.id, bytes32(0), keccak256("s1"));
        _postBatchAutoTransient(r1, e1);

        ExecutionEntry[] memory e2 = new ExecutionEntry[](1);
        e2[0] = _immediateEntry(r2.id, bytes32(0), keccak256("s2"));
        _postBatchAutoTransient(r2, e2);

        assertEq(_getRollupState(r1.id), keccak256("s1"));
        assertEq(_getRollupState(r2.id), keccak256("s2"));
    }

    function test_PostBatch_DifferentBlocks_LazyReset() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);

        // Block 1 — post a deferred entry that's never consumed
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (1));
        bytes32 ah = _ccHash(NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, address(target), rid, 0, cd);
        ExecutionEntry[] memory e1 = new ExecutionEntry[](1);
        e1[0] = _shellEntry(rid, _oneDelta(rid, bytes32(0), bytes32(0), 0));
        e1[0].proxyEntryHash = ah;
        e1[0].rollingHash = _hEntryBegin(e1[0].stateUpdates, ah);
        _postBatchOne(r, e1, _emptyStaticEntries(), 0, 0);
        assertEq(rollups.queueLength(rid), 1);

        // New block — lazy reset clears the stale queue
        vm.roll(block.number + 1);
        ExecutionEntry[] memory e2 = new ExecutionEntry[](1);
        e2[0] = _immediateEntry(rid, bytes32(0), keccak256("s2"));
        _postBatchAutoTransient(r, e2);
        assertEq(_getRollupState(rid), keccak256("s2"));
        assertEq(rollups.queueLength(rid), 0);
        assertEq(rollups.entryQueueIndex(rid), 0);
    }

    function test_PostBatch_LastVerifiedBlock() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, bytes32(0), keccak256("s"));
        _postBatchAutoTransient(r, entries);
        assertEq(rollups.lastVerifiedBlock(uint64(r.id)), block.number);
    }

    // ──────────────────────────────────────────────
    //  Sub-batch validation
    // ──────────────────────────────────────────────
    //
    // A rollup may appear in several batches within one block — see test_PostBatch_SameBlockSameRollupOk.

    function test_SubBatch_DuplicateProofSystemReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address[] memory psList = new address[](2);
        psList[0] = address(ps);
        psList[1] = address(ps); // duplicate (also unsorted)
        bytes[] memory proofs = new bytes[](2);
        proofs[0] = "p1";
        proofs[1] = "p2";

        ProofSystemBatchPerVerificationEntries memory batch =
            _raw(_emptyEntries(), _emptyStaticEntries(), psList, proofs, _rpsOne(r.id, 2), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(EEZ.DuplicateProofSystem.selector, address(ps)));
        rollups.postAndVerifyBatch(batch);
    }

    function test_SubBatch_NonIncreasingRollupIdsReverts() public {
        RollupHandle memory r1 = _makeRollup(bytes32(0));
        RollupHandle memory r2 = _makeRollup(bytes32(0));
        // r1.id < r2.id (registration order) — pass them in reverse order.
        ProofSystemBatchPerVerificationEntries memory batch =
            _twoRollupBatch(r2.id, r1.id, _emptyEntries(), _emptyStaticEntries(), 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(batch);
    }

    function test_SubBatch_RollupNotInBatchReverts() public {
        RollupHandle memory r1 = _makeRollup(bytes32(0));
        RollupHandle memory r2 = _makeRollup(bytes32(0)); // not in this batch's rollupIds

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r1.id, _oneDelta(r2.id, bytes32(0), keccak256("x"), 0));

        vm.expectRevert(abi.encodeWithSelector(EEZ.RollupNotInBatch.selector, uint64(r2.id)));
        _postBatchOne(r1, entries, _emptyStaticEntries(), 1, 0);
    }

    /// @notice Immediate static lookups without immediate entries are unreachable (no immediate
    ///         drain, no meta hook) — `_validateBatchStructure` rejects the shape.
    function test_SubBatch_TransientLookupsWithoutTransientEntriesReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));

        StaticExecutionEntry[] memory lookups = new StaticExecutionEntry[](1);
        lookups[0] = _revertedStaticLookup(uint64(r.id), keccak256("h"), hex"deadbeef");

        vm.expectRevert(EEZ.ImmediateStaticEntriesWithoutImmediateEntries.selector);
        _postBatchOne(r, _emptyEntries(), lookups, 0, 1);
    }

    // ──────────────────────────────────────────────
    //  Per-rollup queue routing (executeCrossChainCall / executeL2Txs)
    // ──────────────────────────────────────────────

    function test_ExecuteCrossChainCall_Simple() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 ah = _ccHash(NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, address(target), rid, 0, cd);

        StateUpdate[] memory deltas = _oneDelta(rid, bytes32(0), keccak256("after"), 0);

        // CALL_BEGIN folds the call's identity (target executed ON L1 = MAINNET, source on `rid`).
        bytes32 cch = _ccHash(NOT_STATIC_CALL, address(this), rid, address(target), MAINNET_ROLLUP_ID, 0, cd);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(rid, deltas);
        entries[0].proxyEntryHash = ah;
        entries[0].l2ToL1Calls = _oneCall(_call(address(this), rid, address(target), 0, cd));
        entries[0].rollingHash = _oneCallHash(deltas, ah, cch, true, "");
        _postBatchOne(r, entries, _emptyStaticEntries(), 0, 0); // deferred — must consume via proxy

        (bool ok,) = proxyAddr.call(cd);
        assertTrue(ok);
        assertEq(target.value(), 42);
        assertEq(_getRollupState(rid), keccak256("after"));
    }

    function test_ExecuteCrossChainCall_UnauthorizedProxyReverts() public {
        _makeRollup(bytes32(0));
        vm.expectRevert(EEZBase.UnauthorizedProxy.selector);
        rollups.executeCrossChainCall(alice, "");
    }

    function test_ExecuteCrossChainCall_NotInCurrentBlockReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        // No postAndVerifyBatch in this block → proxy call should revert
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (1));
        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        _assertRevertSelector(ret, EEZ.ExecutionNotInCurrentBlock.selector);
    }

    function test_ExecuteL2TX() public {
        RollupHandle memory r = _makeRollup(bytes32(0));

        // Three entries: [0] immediate (transient), [1] a non-L2Tx boundary entry (so the queued L2Tx
        // isn't a *leading* one — ImmediateCountStrandsLeadingL2Tx forbids that), [2] a pure L2Tx in the
        // persistent queue. executeL2Txs scans past the boundary entry to consume the queued L2Tx.
        ExecutionEntry[] memory entries = new ExecutionEntry[](3);
        entries[0] = _immediateEntry(r.id, bytes32(0), keccak256("s1"));
        entries[1] = _boundaryEntry(r.id);
        entries[2] = _immediateEntry(r.id, keccak256("s1"), keccak256("s2"));
        _postBatchOne(r, entries, _emptyStaticEntries(), 1, 0);

        assertEq(_getRollupState(r.id), keccak256("s1"));
        rollups.executeL2Txs(uint64(r.id));
        assertEq(_getRollupState(r.id), keccak256("s2"));
    }

    function test_ExecuteL2TX_NotInCurrentBlockReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(EEZ.ExecutionNotInCurrentBlock.selector, uint64(r.id)));
        rollups.executeL2Txs(uint64(r.id));
    }

    function test_ExecuteInContext_NotSelfReverts() public {
        vm.expectRevert(EEZBase.NotSelf.selector);
        rollups.executeInContextAndRevert(_emptyCalls());
    }

    // ──────────────────────────────────────────────
    //  Ether accounting
    // ──────────────────────────────────────────────

    function test_PostBatch_EtherDeltasMustSumToZero() public {
        // registerRollup assigns strictly increasing ids, so the deltas below are sorted.
        RollupHandle memory r1 = _makeRollup(bytes32(0));
        RollupHandle memory r2 = _makeRollup(bytes32(0));
        _fundRollup(r1.id, 5 ether);

        StateUpdate[] memory deltas = new StateUpdate[](2);
        deltas[0] = StateUpdate({
            rollupId: uint64(r1.id), currentState: bytes32(0), newState: keccak256("s1"), etherDelta: -2 ether
        });
        deltas[1] = StateUpdate({
            rollupId: uint64(r2.id), currentState: bytes32(0), newState: keccak256("s2"), etherDelta: 2 ether
        });

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r1.id, deltas);
        entries[0].rollingHash = _hEntryBegin(deltas, bytes32(0));

        rollups.postAndVerifyBatch(_twoRollupBatch(r1.id, r2.id, entries, _emptyStaticEntries(), 1, 0));

        assertEq(_getRollupEtherBalance(r1.id), 3 ether);
        assertEq(_getRollupEtherBalance(r2.id), 2 ether);
    }

    function test_PostBatch_EtherDeltasNonZeroSum_ImmediateSkipped() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        _fundRollup(r.id, 5 ether);
        StateUpdate[] memory deltas = _oneDelta(r.id, bytes32(0), keccak256("s1"), 1 ether);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].rollingHash = _hEntryBegin(deltas, bytes32(0));
        // EtherDeltaMismatch raised inside the immediate L2Tx run → caught → L2TxSkipped.
        // A surviving no-op keeps the run from being 100% failed (AllImmediateL2TxsFailed).
        entries = _withNoopImmediate(entries, r.id, bytes32(0));
        vm.expectEmit(true, false, false, false);
        emit EEZ.L2TxSkipped(0, "");
        _postBatchOne(r, entries, _emptyStaticEntries(), 2, 0);
        assertEq(_getRollupState(r.id), bytes32(0));
        assertEq(_getRollupEtherBalance(r.id), 5 ether);
    }

    function test_PostBatch_InsufficientRollupBalance_ImmediateSkipped() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        StateUpdate[] memory deltas = _oneDelta(r.id, bytes32(0), keccak256("s1"), -1 ether);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].rollingHash = _hEntryBegin(deltas, bytes32(0));
        // InsufficientRollupBalance raised inside the immediate L2Tx run → caught → L2TxSkipped.
        // A surviving no-op keeps the run from being 100% failed (AllImmediateL2TxsFailed).
        entries = _withNoopImmediate(entries, r.id, bytes32(0));
        vm.expectEmit(true, false, false, false);
        emit EEZ.L2TxSkipped(0, "");
        _postBatchOne(r, entries, _emptyStaticEntries(), 2, 0);
        assertEq(_getRollupState(r.id), bytes32(0));
        assertEq(_getRollupEtherBalance(r.id), 0);
    }

    /// @notice Builds the reentrant-value fixture: an entry call sends 2 ether to a
    ///         ValueForwarder, which forwards 1.5 ether back into a proxy as a reentrant
    ///         cross-chain call. Net for the rollup: -0.5 ether.
    function _reentrantValueEntry(uint64 rid, int256 etherDelta)
        internal
        returns (ExecutionEntry[] memory entries, ValueForwarder forwarder)
    {
        forwarder = new ValueForwarder();
        forwarder.setPeer(rollups.createCrossChainProxy(L2_REMOTE, rid));

        bytes memory depositData = abi.encodeWithSignature("deposit()");
        // reentrant call hash: source = forwarder on L1 (mainnet), target = L2_REMOTE on `rid`.
        bytes32 nestedHash =
            _ccHash(NOT_STATIC_CALL, address(forwarder), MAINNET_ROLLUP_ID, L2_REMOTE, rid, 1.5 ether, depositData);

        bytes memory forwardData = abi.encodeCall(ValueForwarder.forward, (1.5 ether));
        StateUpdate[] memory deltas = _oneDelta(rid, bytes32(0), keccak256("s1"), etherDelta);

        // Rolling hash: the reentrant call fires right after the top call's CALL_BEGIN, so its
        // position key is keyed on `_rollingHash` at that instant. A SUCCESS frame folds
        // NESTED_BEGIN/END (no sub-calls), then the top call's CALL_END closes.
        bytes32 cchTop =
            _ccHash(NOT_STATIC_CALL, L2_SENDER, rid, address(forwarder), MAINNET_ROLLUP_ID, 2 ether, forwardData);
        bytes32 h = _hEntryBegin(deltas, bytes32(0));
        h = _hCallBegin(h, cchTop);
        bytes32 fireHash = h;
        h = _hNestedBegin(h, nestedHash);
        h = _hNestedEnd(h);
        h = _hCallEnd(h, true, abi.encode(uint256(2 ether)));

        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: _expectedL1toL2Hash(nestedHash, fireHash),
            l2ToL1Calls: _emptyCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: ""
        });

        entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(rid, deltas);
        entries[0].l2ToL1Calls = _oneCall(_call(L2_SENDER, rid, address(forwarder), 2 ether, forwardData));
        entries[0].expectedL1ToL2Calls = nested;
        entries[0].rollingHash = h;
    }

    function test_ReentrantValue_CountedInEtherAccounting() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        _fundRollup(rid, 2 ether);

        // 2 ether out at the top level, 1.5 ether back in reentrantly → net -0.5 ether.
        (ExecutionEntry[] memory entries, ValueForwarder forwarder) = _reentrantValueEntry(rid, -0.5 ether);
        _postBatchAutoTransient(r, entries);

        assertEq(_getRollupState(rid), keccak256("s1"));
        assertEq(_getRollupEtherBalance(rid), 1.5 ether);
        assertEq(address(forwarder).balance, 0.5 ether);
        assertEq(address(rollups).balance, 1.5 ether);
    }

    function test_ReentrantValue_NotCredited_ImmediateSkipped() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        _fundRollup(rid, 2 ether);

        // Delta pretends the reentrant 1.5 ether never came back → EtherDeltaMismatch
        // inside the immediate L2Tx run → caught → L2TxSkipped, all rolled back.
        (ExecutionEntry[] memory entries, ValueForwarder forwarder) = _reentrantValueEntry(rid, -2 ether);
        // A surviving no-op keeps the run from being 100% failed (AllImmediateL2TxsFailed).
        entries = _withNoopImmediate(entries, rid, bytes32(0));
        vm.expectEmit(true, false, false, false);
        emit EEZ.L2TxSkipped(0, "");
        _postBatchOne(r, entries, _emptyStaticEntries(), 2, 0);

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
    /// @notice Rolling hash for `_nestedOutflowEntry` (top-level forward + nested outflow + return).
    ///         Pulled out so the builder stays under the stack-depth limit under coverage instrumentation.
    function _nestedOutflowRollingHash(StateUpdate[] memory deltas, bytes32 cchTop, bytes32 nestedHash, bytes32 cchSink)
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
        forwarder.setPeer(rollups.createCrossChainProxy(L2_REMOTE, rid));

        bytes memory depositData = abi.encodeWithSignature("deposit()");
        bytes32 nestedHash =
            _ccHash(NOT_STATIC_CALL, address(forwarder), MAINNET_ROLLUP_ID, L2_REMOTE, rid, 1.5 ether, depositData);

        bytes memory forwardData = abi.encodeCall(ValueForwarder.forward, (1.5 ether));
        // Top-level call that drives the reentry.
        L2ToL1Call[] memory calls = _oneCall(_call(L2_SENDER, rid, address(forwarder), 2 ether, forwardData));
        // Consumed INSIDE the nested frame — sends 1 ether out of EEZ to `sink`.
        L2ToL1Call[] memory subCalls = _oneCall(_call(L2_SENDER, rid, sink, 1 ether, ""));

        StateUpdate[] memory deltas = _oneDelta(rid, bytes32(0), keccak256("s1"), etherDelta);

        bytes32 cchTop =
            _ccHash(NOT_STATIC_CALL, L2_SENDER, rid, address(forwarder), MAINNET_ROLLUP_ID, 2 ether, forwardData);

        // Extracted into a sub-frame to keep this builder under the stack-depth limit.
        (bytes32 h, bytes32 fireHash) = _nestedOutflowRollingHash(
            deltas, cchTop, nestedHash, _ccHash(NOT_STATIC_CALL, L2_SENDER, rid, sink, MAINNET_ROLLUP_ID, 1 ether, "")
        );

        // Assembled in a sub-frame to keep this builder under the stack-depth limit.
        entries =
            _assembleNestedOutflowEntry(rid, deltas, calls, subCalls, _expectedL1toL2Hash(nestedHash, fireHash), h);
    }

    /// @notice Final entry assembly for `_nestedOutflowEntry`, in a sub-frame for stack-depth headroom.
    function _assembleNestedOutflowEntry(
        uint64 rid,
        StateUpdate[] memory deltas,
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
        entries[0] = _shellEntry(rid, deltas);
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = nested;
        entries[0].rollingHash = rollingHash;
    }

    /// @notice The fixed accounting credits the FULL net outflow, including ether sent inside a
    ///         reentrant frame. Fails on the pre-fix code (local `etherOut` drops the nested 1 ether,
    ///         so the −1.5 delta mismatches the computed −0.5 → L2TxSkipped).
    function test_NestedOutflow_CountedInEtherAccounting() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        _fundRollup(rid, 2 ether);
        TestTarget sink = new TestTarget();

        (ExecutionEntry[] memory entries, ValueForwarder forwarder) =
            _nestedOutflowEntry(rid, address(sink), -1.5 ether);
        _postBatchAutoTransient(r, entries);

        assertEq(_getRollupState(rid), keccak256("s1"), "entry must apply");
        assertEq(_getRollupEtherBalance(rid), 0.5 ether, "rollup debited the full net outflow");
        assertEq(address(sink).balance, 1 ether, "nested outflow physically left EEZ");
        assertEq(address(forwarder).balance, 0.5 ether);
        assertEq(address(rollups).balance, 0.5 ether, "booked balance == physical balance");
    }

    /// @notice Soundness: the delta a per-frame local would have accepted (−0.5, nested outflow
    ///         dropped) must now be REJECTED, otherwise EEZ would book 1 ether it no longer holds.
    function test_NestedOutflow_DroppedDeltaRejected() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        _fundRollup(rid, 2 ether);
        TestTarget sink = new TestTarget();

        (ExecutionEntry[] memory entries,) = _nestedOutflowEntry(rid, address(sink), -0.5 ether);
        // A surviving no-op keeps the run from being 100% failed (AllImmediateL2TxsFailed).
        entries = _withNoopImmediate(entries, rid, bytes32(0));
        vm.expectEmit(true, false, false, false);
        emit EEZ.L2TxSkipped(0, "");
        _postBatchOne(r, entries, _emptyStaticEntries(), 2, 0);

        assertEq(_getRollupState(rid), bytes32(0), "unsound entry must not apply");
        assertEq(_getRollupEtherBalance(rid), 2 ether);
        assertEq(address(sink).balance, 0);
        assertEq(address(rollups).balance, 2 ether);
    }

    // ──────────────────────────────────────────────
    //  Owner ops on Rollup.sol (the per-rollup contract)
    // ──────────────────────────────────────────────

    function test_RollupSetStateRoot_ByOwner() public {
        RollupHandle memory r = _makeRollupWithOwner(bytes32(0), alice);
        vm.prank(alice);
        r.manager.setStateRoot(keccak256("escape"));
        assertEq(_getRollupState(r.id), keccak256("escape"));
    }

    function test_RollupSetStateRoot_NotOwnerReverts() public {
        RollupHandle memory r = _makeRollupWithOwner(bytes32(0), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        r.manager.setStateRoot(keccak256("escape"));
    }

    function test_RollupSetStateRoot_MidFlowReverts() public {
        RollupHandle memory r = _makeRollupWithOwner(bytes32(0), alice);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, bytes32(0), keccak256("s"));
        _postBatchAutoTransient(r, entries);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EEZ.RollupBatchActiveThisBlock.selector, uint64(r.id)));
        r.manager.setStateRoot(keccak256("escape"));
    }

    function test_RollupTransferOwnership() public {
        RollupHandle memory r = _makeRollupWithOwner(bytes32(0), alice);
        vm.prank(alice);
        r.manager.transferOwnership(bob);
        assertEq(r.manager.owner(), bob);
        vm.prank(bob);
        r.manager.setStateRoot(keccak256("bob's state"));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        r.manager.setStateRoot(keccak256("alice's state"));
    }

    function test_RollupSetVerificationKey() public {
        RollupHandle memory r = _makeRollupWithOwner(bytes32(0), alice);
        bytes32 newVk = keccak256("new vk");
        vm.prank(alice);
        r.manager.updateVerificationKey(address(ps), newVk);
        assertEq(r.manager.verificationKey(address(ps)), newVk);
    }

    // ──────────────────────────────────────────────
    //  Rolling-hash failure modes
    // ──────────────────────────────────────────────

    function test_RollingHashMismatch_Reverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 ah = _ccHash(NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, address(target), rid, 0, cd);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(rid, _oneDelta(rid, bytes32(0), keccak256("s"), 0));
        entries[0].proxyEntryHash = ah;
        entries[0].l2ToL1Calls = _oneCall(_call(address(this), rid, address(target), 0, cd));
        entries[0].rollingHash = bytes32(uint256(0xdead)); // wrong!
        _postBatchOne(r, entries, _emptyStaticEntries(), 0, 0);
        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        proxyAddr.call(cd);
    }

    /// @notice Providing more top-level calls than the entry's `rollingHash` accounts for diverges
    ///         the hash (every call folds CALL_BEGIN/END), surfacing as `RollingHashMismatch`. The
    ///         old dedicated `UnconsumedL2ToL1Calls` error is gone — `_processNCalls` runs the WHOLE
    ///         array and completeness is enforced structurally by the rolling hash.
    function test_UnconsumedCalls_Reverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);
        bytes memory cd = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 ah = _ccHash(NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, address(target), rid, 0, cd);
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = _call(address(this), rid, address(target), 0, cd);
        calls[1] = calls[0];
        StateUpdate[] memory deltas = _oneDelta(rid, bytes32(0), keccak256("s"), 0);

        // rollingHash accounts for ONE call; two are provided → divergence.
        bytes32 cch = _ccHash(NOT_STATIC_CALL, address(this), rid, address(target), MAINNET_ROLLUP_ID, 0, cd);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(rid, deltas);
        entries[0].proxyEntryHash = ah;
        entries[0].l2ToL1Calls = calls;
        entries[0].rollingHash = _oneCallHash(deltas, ah, cch, true, "");
        _postBatchOne(r, entries, _emptyStaticEntries(), 0, 0);
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
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, bytes32(0), keccak256("s"));
        vm.recordLogs();
        _postBatchAutoTransient(r, entries);
        assertTrue(_findLog(vm.getRecordedLogs(), EEZ.BatchPosted.selector));
    }

    function test_Event_StateUpdated_OnEscape() public {
        RollupHandle memory r = _makeRollupWithOwner(bytes32(0), alice);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit EEZ.StateUpdated(uint64(r.id), keccak256("escape"));
        r.manager.setStateRoot(keccak256("escape"));
    }

    // ──────────────────────────────────────────────
    //  Top-level reverting entries (success == false)
    // ──────────────────────────────────────────────
    //
    // A top-level cross-chain call that reverts is a normal `ExecutionEntry` with `success == false`:
    // it runs, verifies its rolling hash, then reverts with the cached `returnData`, rolling back all
    // state effects (including the cursor advance) so the caller's try/catch sees the revert and the
    // queue is not consumed. (There is no separate reverted-lookup pool for state-changing calls; the
    // read-only `StaticExecutionEntry` pool serves static reads via `staticCrossChainCall`.)

    /// @notice Deferred path: the reverting entry sits in `verificationByRollup[rid].entryQueue`
    ///         and a top-level proxy call reverts with its cached returnData; the cursor advance rolls
    ///         back with the revert, so a second identical call reverts identically.
    function test_RevertedLookup_TopLevel_Deferred() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes memory payload = hex"deadbeef";
        // Hash exactly as `executeCrossChainCall` computes it: source = this test (it calls the proxy).
        bytes32 h = _ccHash(NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, address(target), rid, 0, cd);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _revertedEntry(rid, bytes32(0), h, payload);
        _postBatchOne(r, entries, _emptyStaticEntries(), 0, 0); // deferred — queued, consumed via the proxy

        uint256 cursorBefore = rollups.entryQueueIndex(rid);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, payload);
        assertEq(rollups.entryQueueIndex(rid), cursorBefore, "reverting entry rolls back the cursor advance");

        // Repeatable: a second identical call reverts identically, still no advance.
        (ok, ret) = proxyAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, payload);
        assertEq(rollups.entryQueueIndex(rid), cursorBefore);
    }

    /// @notice Transient path: the reverting entry lives in `_transientEntries` and is hit by a
    ///         proxy call fired from inside the meta hook (the only window the transient table exists).
    function test_RevertedLookup_TopLevel_Transient() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        MetaLookupCaller caller = new MetaLookupCaller(rollups);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes memory payload = hex"c0ffee";
        // The meta-hook caller is what calls through the proxy, so it's the hash's sourceAddress.
        bytes32 h = _ccHash(NOT_STATIC_CALL, address(caller), MAINNET_ROLLUP_ID, address(target), rid, 0, cd);
        caller.setProxyCall(proxyAddr, cd);

        // One reverting transient entry whose `proxyEntryHash != 0` so the leading L2Tx run stops and
        // the meta hook fires; the caller drives it via the proxy.
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _revertedEntry(rid, bytes32(0), h, payload);

        // immediateEntryCount = 1 → the entry stays in the transient table for the meta hook.
        ProofSystemBatchPerVerificationEntries memory batch = _singleSubBatch(r, entries, _emptyStaticEntries(), 1, 0);
        caller.post(batch);

        assertTrue(caller.hookRan(), "meta hook did not run");
        assertFalse(caller.callSuccess(), "proxy call should have reverted");
        assertEq(caller.callReturnData(), payload);
    }

    /// @notice Negative path: rollup verified this block but no entry matches → ExecutionNotFound.
    function test_RevertedLookup_TopLevel_NoMatchReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        // Verify the rollup this block, but post nothing to consume.
        _postBatchOne(r, _emptyEntries(), _emptyStaticEntries(), 0, 0);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        _assertRevertSelector(ret, EEZBase.ExecutionNotFound.selector);
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
        StateUpdate[] memory deltas = _oneDelta(rid, _getRollupState(rid), keccak256("rev"), 0);

        bytes32 cch = _ccHash(NOT_STATIC_CALL, address(this), rid, subTarget, MAINNET_ROLLUP_ID, 0, subCd);

        e = _shellEntry(rid, deltas);
        e.proxyEntryHash = proxyEntryHash;
        e.l2ToL1Calls = _oneCall(_call(address(this), rid, subTarget, 0, subCd));
        e.rollingHash = _oneCallHash(deltas, proxyEntryHash, cch, true, "");
        e.success = false;
        e.returnData = payload;
    }

    /// @notice Happy path: the reverting entry runs its sub-execution, then reverts with the cached
    ///         `returnData`; the sub-call's state change is discarded by the revert and the queue is
    ///         not advanced.
    function test_RevertedLookup_SubExecution_RunsAndReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes32 h = _ccHash(NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, address(target), rid, 0, cd);
        bytes memory payload = hex"deadbeef";

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _revertedEntryWithSubcall(rid, h, payload, address(target), 99);
        _postBatchOne(r, entries, _emptyStaticEntries(), 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, payload, "must revert with the entry's returnData");
        assertEq(target.value(), 0, "sub-execution state must be discarded by the terminal revert");
        assertEq(rollups.entryQueueIndex(rid), 0, "reverting entry rolls back the cursor advance");
    }

    /// @notice Proves the sub-execution actually RUNS the sub-calls: a wrong `rollingHash` makes the
    ///         post-execution check fire `RollingHashMismatch` (impossible if the calls were skipped).
    function test_RevertedLookup_SubExecution_WrongHashReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes32 h = _ccHash(NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, address(target), rid, 0, cd);

        ExecutionEntry memory e = _revertedEntryWithSubcall(rid, h, hex"deadbeef", address(target), 99);
        e.rollingHash = keccak256("wrong"); // != the hash the real sub-execution produces
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = e;
        _postBatchOne(r, entries, _emptyStaticEntries(), 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        // The sub-execution must run the sub-calls and check the hash.
        _assertRevertSelector(ret, EEZBase.RollingHashMismatch.selector);
    }

    /// @notice State precondition is part of the MATCH: a reverting entry whose `currentState` no
    ///         longer holds is skipped, and with no other candidate the call ends `ExecutionNotFound`.
    function test_RevertedLookup_StateRootPin_MismatchSkips() public {
        RollupHandle memory r = _makeRollup(bytes32(0)); // live root is 0
        uint64 rid = uint64(r.id);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes32 h = _ccHash(NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, address(target), rid, 0, cd);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _revertedEntry(rid, keccak256("wrong-root"), h, hex"deadbeef"); // stale currentState
        _postBatchOne(r, entries, _emptyStaticEntries(), 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        // Stale currentState must skip the candidate.
        _assertRevertSelector(ret, EEZBase.ExecutionNotFound.selector);
    }

    /// @notice An entry whose `currentState` equals the LIVE state root matches and reverts with its
    ///         cached returnData.
    function test_RevertedLookup_StateRootPin_MatchResolves() public {
        RollupHandle memory r = _makeRollup(keccak256("live-root"));
        uint64 rid = uint64(r.id);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rid);

        bytes memory cd = abi.encodeCall(TestTarget.setValue, (7));
        bytes memory payload = hex"deadbeef";
        bytes32 h = _ccHash(NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, address(target), rid, 0, cd);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _revertedEntry(rid, keccak256("live-root"), h, payload);
        _postBatchOne(r, entries, _emptyStaticEntries(), 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, payload, "live currentState must match and revert with the cached returnData");
    }

    /// @notice REVERTED reentrant call: a reentrant (L1→L2) call resolved as a `success == false`
    ///         `ExpectedL1ToL2Call` reverts; the caller's try/catch absorbs it. The reverting frame's
    ///         folds roll back, so the host entry still completes.
    function test_NestedRevertedLookup_EntryScoped_RevertsAndCatches() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);

        // Inner target: proxy on L1 for a Counter living on rollup `rid`.
        address counterL2 = address(0xC0117E6);
        address counterProxy = rollups.createCrossChainProxy(counterL2, rid);
        SafeCounterAndProxy scap = new SafeCounterAndProxy(Counter(counterProxy));

        bytes memory outerCd = abi.encodeCall(SafeCounterAndProxy.incrementProxy, ());
        bytes memory innerCd = abi.encodeCall(Counter.increment, ());
        bytes32 innerHash = _ccHash(NOT_STATIC_CALL, address(scap), MAINNET_ROLLUP_ID, counterL2, rid, 0, innerCd);

        StateUpdate[] memory deltas = _oneDelta(rid, bytes32(0), keccak256("s1"), 0);

        bytes32 cchTop = _ccHash(NOT_STATIC_CALL, L2_SENDER, rid, address(scap), MAINNET_ROLLUP_ID, 0, outerCd);
        // The reentrant call fires after the top call's CALL_BEGIN.
        bytes32 fireHash = _hCallBegin(_hEntryBegin(deltas, bytes32(0)), cchTop);

        ExpectedL1ToL2Call[] memory reentrant = new ExpectedL1ToL2Call[](1);
        reentrant[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: _expectedL1toL2Hash(innerHash, fireHash),
            l2ToL1Calls: _emptyCalls(),
            // REVERTED frame checks its mid-call hash == _rollingHash after NESTED_BEGIN (no sub-calls).
            revertedOrStaticRollingHash: _hNestedBegin(fireHash, innerHash),
            success: false,
            returnData: bytes("inner reverts")
        });

        // The reverted reentrant frame's folds roll back, so the host's hash is just the top call.
        bytes32 h = _hCallEnd(fireHash, true, "");

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(rid, deltas); // immediate (`proxyEntryHash == 0`)
        entries[0].l2ToL1Calls = _oneCall(_call(L2_SENDER, rid, address(scap), 0, outerCd));
        entries[0].expectedL1ToL2Calls = reentrant;
        entries[0].rollingHash = h;

        _postBatchAutoTransient(r, entries);

        assertEq(_getRollupState(rid), keccak256("s1"), "entry must complete");
        assertEq(scap.counter(), 1, "outer call must run");
        assertTrue(scap.lastCallFailed(), "inner reentrant call must revert via the reverted reentrant entry");
        assertEq(scap.targetCounter(), 0, "inner call must not have executed");
    }

    /// @notice The reentrant position key (`keccak(crossChainCallHash, _rollingHash)`) gates the match:
    ///         a reentrant entry stamped at the wrong rolling-hash position never matches, so the call
    ///         folds CALL_NOT_FOUND, the entry's rolling hash diverges, and the immediate entry is skipped.
    function test_NestedRevertedLookup_WrongExecutingLookupIndex_NoMatch() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);

        address counterL2 = address(0xC0117E6);
        address counterProxy = rollups.createCrossChainProxy(counterL2, rid);
        SafeCounterAndProxy scap = new SafeCounterAndProxy(Counter(counterProxy));

        bytes memory outerCd = abi.encodeCall(SafeCounterAndProxy.incrementProxy, ());

        StateUpdate[] memory deltas = _oneDelta(rid, bytes32(0), keccak256("s1"), 0);

        bytes32 cchTop = _ccHash(NOT_STATIC_CALL, L2_SENDER, rid, address(scap), MAINNET_ROLLUP_ID, 0, outerCd);
        bytes32 fireHash = _hCallBegin(_hEntryBegin(deltas, bytes32(0)), cchTop);

        ExpectedL1ToL2Call[] memory reentrant = new ExpectedL1ToL2Call[](1);
        reentrant[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: keccak256("wrong-position"), // never matches the fire-time key
            l2ToL1Calls: _emptyCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: false,
            returnData: bytes("inner reverts")
        });

        // The entry's hash is the would-be-success value (no CALL_NOT_FOUND fold); the actual run
        // folds CALL_NOT_FOUND → divergence → skip.
        bytes32 h = _hCallEnd(fireHash, true, "");

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(rid, deltas);
        entries[0].l2ToL1Calls = _oneCall(_call(L2_SENDER, rid, address(scap), 0, outerCd));
        entries[0].expectedL1ToL2Calls = reentrant;
        entries[0].rollingHash = h;

        // No reentrant match → CALL_NOT_FOUND → RollingHashMismatch → the immediate entry is skipped.
        // A surviving no-op keeps the run from being 100% failed (AllImmediateL2TxsFailed).
        entries = _withNoopImmediate(entries, rid, bytes32(0));
        vm.expectEmit(true, false, false, false);
        emit EEZ.L2TxSkipped(0, "");
        _postBatchOne(r, entries, _emptyStaticEntries(), 2, 0);
        assertEq(_getRollupState(rid), bytes32(0), "entry must not commit");
    }
}
