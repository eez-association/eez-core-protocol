// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../src/EEZ.sol";
import {Rollup} from "../src/rollupContract/Rollup.sol";
import {IRollupContract} from "../src/interfaces/IRollup.sol";
import {IMetaCrossChainReceiver} from "../src/interfaces/IMetaCrossChainReceiver.sol";
import {
    ExecutionEntry,
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExpectedLookup,
    LookupCall,
    ExpectedStateRootPerRollup
} from "../src/interfaces/IEEZ.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {MockProofSystem} from "./mocks/MockProofSystem.sol";

/// @notice Simple call target used by the execution-path coverage tests.
contract SimpleTarget {
    uint256 public value;

    function setValue(uint256 v) external {
        value = v;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    receive() external payable {}
}

/// @notice Re-enters `executeL2TX` from inside an entry's call to exercise the
///         `L2TXNotAllowedDuringExecution` guard.
contract L2TXReenter {
    EEZ public immutable eez;
    uint256 public immutable rid;

    constructor(EEZ _eez, uint256 _rid) {
        eez = _eez;
        rid = _rid;
    }

    function poke() external {
        // The inner call reverts `L2TXNotAllowedDuringExecution`; swallow it so the outer
        // cross-chain call resolves with a deterministic (empty) return.
        try eez.executeL2TX(rid) {} catch {}
    }
}

/// @notice Meta hook that re-enters `postAndVerifyBatch` — must trip the `PostBatchReentry` guard.
contract ReenterPostBatch is IMetaCrossChainReceiver {
    EEZ public immutable eez;
    ProofSystemBatchPerVerificationEntries internal _inner;

    constructor(EEZ _eez) {
        eez = _eez;
    }

    function setInner(ProofSystemBatchPerVerificationEntries calldata b) external {
        _inner = b;
    }

    function post(ProofSystemBatchPerVerificationEntries calldata b) external {
        eez.postAndVerifyBatch(b);
    }

    function executeMetaCrossChainTransactions() external override {
        eez.postAndVerifyBatch(_inner);
    }
}

/// @notice An `IRollupContract` manager that returns a vkey array of the wrong length,
///         tripping the `_fetchVkMatrix` length guard.
contract BadVkeyManager is IRollupContract {
    function rollupContractRegistered(uint256) external {}

    function checkProofSystemsAndGetVkeys(address[] calldata) external pure returns (bytes32[] memory vkeys) {
        // Caller passes 1 PS but we return 2 → length mismatch.
        vkeys = new bytes32[](2);
        vkeys[0] = bytes32(uint256(1));
        vkeys[1] = bytes32(uint256(2));
    }

    function getCustomData(uint64) external pure returns (bytes memory) {
        return "";
    }
}

/// @notice Coverage-focused tests for `EEZ` validation guards and execution-path branches not
///         already exercised by `EEZ.t.sol`.
contract EEZCoverageTest is Base {
    SimpleTarget internal target;
    address internal alice = makeAddr("alice");

    uint256 internal constant MAINNET = 0;

    function setUp() public {
        setUpBase();
        target = new SimpleTarget();
    }

    // ──────────────────────────────────────────────
    //  Raw-batch builders
    // ──────────────────────────────────────────────

    function _rpsOne(uint256 rid, uint256 nPs) internal pure returns (RollupIdWithProofSystems[] memory rps) {
        uint64[] memory idx = new uint64[](nPs);
        for (uint256 i = 0; i < nPs; i++) {
            idx[i] = uint64(i);
        }
        rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: rid, proofSystemIndex: idx});
    }

    function _raw(
        ExecutionEntry[] memory entries,
        LookupCall[] memory lookups,
        address[] memory psList,
        bytes[] memory proofs,
        RollupIdWithProofSystems[] memory rps,
        uint256 tc,
        uint256 tlc
    )
        internal
        pure
        returns (ProofSystemBatchPerVerificationEntries memory b)
    {
        b.blockNumber = 0;
        b.entries = entries;
        b.l1ToL2lookupCalls = lookups;
        b.transientExecutionEntryCount = tc;
        b.transientLookupCallCount = tlc;
        b.proofSystems = psList;
        b.rollupIdsWithProofSystems = rps;
        b.blobIndices = new uint256[](0);
        b.callData = "";
        b.proofs = proofs;
    }

    /// @notice Default single-PS [ps] + ["proof"] for a single rollup with `nPs` index slots.
    function _stdBatch(
        uint256 rid,
        ExecutionEntry[] memory entries,
        LookupCall[] memory lookups,
        uint256 tc,
        uint256 tlc
    )
        internal
        view
        returns (ProofSystemBatchPerVerificationEntries memory b)
    {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        b = _raw(entries, lookups, psList, proofs, _rpsOne(rid, 1), tc, tlc);
    }

    // ──────────────────────────────────────────────
    //  _validateStructure guards
    // ──────────────────────────────────────────────

    function test_Validate_EmptyProofSystems() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address[] memory psList = new address[](0);
        bytes[] memory proofs = new bytes[](0);
        ProofSystemBatchPerVerificationEntries memory b =
            _raw(_emptyEntries(), _emptyLookupCalls(), psList, proofs, _rpsOne(r.id, 1), 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_ProofsLengthMismatch() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes[] memory proofs = new bytes[](2); // mismatch
        ProofSystemBatchPerVerificationEntries memory b =
            _raw(_emptyEntries(), _emptyLookupCalls(), psList, proofs, _rpsOne(r.id, 1), 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_EmptyRollups() public {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](0);
        ProofSystemBatchPerVerificationEntries memory b =
            _raw(_emptyEntries(), _emptyLookupCalls(), psList, proofs, rps, 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_UnregisteredRollup() public {
        // rollupId 999 has no manager registered.
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(999, _emptyEntries(), _emptyLookupCalls(), 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_EmptyProofSystemIndex() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), _emptyLookupCalls(), 0, 0);
        b.rollupIdsWithProofSystems[0].proofSystemIndex = new uint64[](0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_IndexOutOfRange() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), _emptyLookupCalls(), 0, 0);
        uint64[] memory idx = new uint64[](1);
        idx[0] = 5; // >= psLen (1)
        b.rollupIdsWithProofSystems[0].proofSystemIndex = idx;
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_DuplicateIndices() public {
        // Two PS so indices [0,0] are in-range but non-increasing.
        MockProofSystem ps2 = new MockProofSystem();
        (address[] memory psList, bytes32[] memory vks) = _twoPsSorted(ps2);
        Base.RollupHandle memory r = _makeRollupCustom(bytes32(0), psList, vks, 1, alice);

        bytes[] memory proofs = new bytes[](2);
        proofs[0] = "p0";
        proofs[1] = "p1";
        uint64[] memory idx = new uint64[](2);
        idx[0] = 0;
        idx[1] = 0; // duplicate
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: r.id, proofSystemIndex: idx});
        ProofSystemBatchPerVerificationEntries memory b =
            _raw(_emptyEntries(), _emptyLookupCalls(), psList, proofs, rps, 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_StateDeltasNotIncreasing() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({rollupId: r.id, currentState: bytes32(0), newState: bytes32(0), etherDelta: 0});
        deltas[1] = StateDelta({rollupId: r.id, currentState: bytes32(0), newState: bytes32(0), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyLookupCalls(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.StateDeltasNotStrictlyIncreasing.selector, r.id));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_EntryDestinationNotInDeltas() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: r.id, currentState: bytes32(0), newState: bytes32(0), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].destinationRollupId = 12345; // not in deltas
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyLookupCalls(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.EntryDestinationNotInStateDeltas.selector, 12345));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_CallSourceNotVerified() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: r.id, currentState: bytes32(0), newState: bytes32(0), etherDelta: 0});
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            isStatic: false,
            targetAddress: address(target),
            value: 0,
            data: "",
            sourceAddress: address(this),
            sourceRollupId: 9999, // not in deltas
            revertSpan: 0
        });
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].l2ToL1Calls = calls;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyLookupCalls(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.CallSourceNotVerified.selector, 9999));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_ReentrantDestinationNotVerified() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: r.id, currentState: bytes32(0), newState: bytes32(0), etherDelta: 0});
        ExpectedL1ToL2Call[] memory reentrant = new ExpectedL1ToL2Call[](1);
        reentrant[0] = ExpectedL1ToL2Call({
            crossChainCallHash: bytes32(0), destinationRollupId: 8888, callCount: 0, returnData: ""
        });
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].expectedL1ToL2Calls = reentrant;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyLookupCalls(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.ReentrantDestinationNotVerified.selector, 8888));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_LookupReentrantDestinationNotVerified() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: r.id, currentState: bytes32(0), newState: bytes32(0), etherDelta: 0});
        ExpectedLookup[] memory lookups = new ExpectedLookup[](1);
        lookups[0] = ExpectedLookup({
            crossChainCallHash: bytes32(0),
            destinationRollupId: 7777,
            returnData: "",
            failed: true,
            l2ToL1CallNumber: 0,
            lastL1ToL2CallConsumed: 0,
            executingLookupIndex: 0,
            l2ToL1Calls: new L2ToL1Call[](0),
            expectedL1ToL2Calls: new ExpectedL1ToL2Call[](0),
            callCount: 0,
            rollingHash: bytes32(0)
        });
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].expectedLookups = lookups;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyLookupCalls(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.ReentrantDestinationNotVerified.selector, 7777));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_PinsNotIncreasing() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = _shellLookup(r.id);
        // Both pins must be in-batch (membership is checked per-pin) so the duplicate trips the
        // strictly-increasing guard rather than RollupNotInBatch.
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](2);
        pins[0] = ExpectedStateRootPerRollup({rollupId: r.id, stateRoot: bytes32(0)});
        pins[1] = ExpectedStateRootPerRollup({rollupId: r.id, stateRoot: bytes32(0)}); // not increasing
        lookups[0].expectedStateRoots = pins;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), lookups, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.ExpectedStateRootsNotStrictlyIncreasing.selector, r.id));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_PinRollupNotInBatch() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = _shellLookup(r.id);
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: 999, stateRoot: bytes32(0)}); // not in batch
        lookups[0].expectedStateRoots = pins;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), lookups, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.RollupNotInBatch.selector, 999));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_LookupDestinationNotPinned() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = _shellLookup(r.id);
        lookups[0].destinationRollupId = 555; // not among pins
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: r.id, stateRoot: _getRollupState(r.id)});
        lookups[0].expectedStateRoots = pins;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), lookups, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.LookupDestinationNotPinned.selector, 555));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_TransientCountExceedsEntries() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), _emptyLookupCalls(), 1, 0); // tc 1 > 0 entries
        vm.expectRevert(EEZ.TransientCountExceedsEntries.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_TransientLookupCountExceeds() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _emptyImmediateEntry(r.id);
        // tc 1 <= 1 entry OK, but tlc 1 > 0 lookups → second bound.
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyLookupCalls(), 1, 1);
        vm.expectRevert(EEZ.TransientLookupCallCountExceedsLookupCalls.selector);
        rollups.postAndVerifyBatch(b);
    }

    // ──────────────────────────────────────────────
    //  vkMatrix length guard + multi-PS verification
    // ──────────────────────────────────────────────

    function test_FetchVkMatrix_WrongLengthReverts() public {
        BadVkeyManager bad = new BadVkeyManager();
        uint256 rid = rollups.registerRollup(address(bad), bytes32(0));
        // Single PS queried → manager returns 2 vkeys → length mismatch.
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(rid, _emptyEntries(), _emptyLookupCalls(), 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    /// @notice Three global PSes, two rollups — one rollup lists all three, the other only the
    ///         first. Exercises the binary search (`_findIndexPosition`) hit + miss branches and
    ///         the per-PS attesting-rollup skip (`continue`).
    function test_MultiPS_FindIndexAndSkip() public {
        MockProofSystem psB = new MockProofSystem();
        MockProofSystem psC = new MockProofSystem();
        address[] memory psSorted = new address[](3);
        psSorted[0] = address(ps);
        psSorted[1] = address(psB);
        psSorted[2] = address(psC);
        _sort3(psSorted);

        bytes32[] memory vks3 = new bytes32[](3);
        vks3[0] = DEFAULT_VK;
        vks3[1] = DEFAULT_VK;
        vks3[2] = DEFAULT_VK;
        Base.RollupHandle memory rAll = _makeRollupCustom(bytes32(0), psSorted, vks3, 1, alice);

        address[] memory ps1 = new address[](1);
        ps1[0] = psSorted[0];
        bytes32[] memory vk1 = new bytes32[](1);
        vk1[0] = DEFAULT_VK;
        Base.RollupHandle memory rOne = _makeRollupCustom(bytes32(0), ps1, vk1, 1, alice);

        bytes[] memory proofs = new bytes[](3);
        proofs[0] = "p0";
        proofs[1] = "p1";
        proofs[2] = "p2";

        // rps sorted by rollupId.
        (uint256 idLo, uint256 idHi) = rAll.id < rOne.id ? (rAll.id, rOne.id) : (rOne.id, rAll.id);
        uint64[] memory idxAll = new uint64[](3);
        idxAll[0] = 0;
        idxAll[1] = 1;
        idxAll[2] = 2;
        uint64[] memory idxOne = new uint64[](1);
        idxOne[0] = 0;

        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](2);
        rps[0] = RollupIdWithProofSystems({rollupId: idLo, proofSystemIndex: idLo == rAll.id ? idxAll : idxOne});
        rps[1] = RollupIdWithProofSystems({rollupId: idHi, proofSystemIndex: idHi == rAll.id ? idxAll : idxOne});

        ProofSystemBatchPerVerificationEntries memory b =
            _raw(_emptyEntries(), _emptyLookupCalls(), psSorted, proofs, rps, 0, 0);
        rollups.postAndVerifyBatch(b);
        assertEq(rollups.lastVerifiedBlock(rAll.id), block.number);
        assertEq(rollups.lastVerifiedBlock(rOne.id), block.number);
    }

    // ──────────────────────────────────────────────
    //  Guards: self-call, reentry, setStateRoot
    // ──────────────────────────────────────────────

    function test_AttemptApplyImmediate_NotSelfReverts() public {
        vm.expectRevert(EEZBase.NotSelf.selector);
        rollups.attemptApplyImmediate(0);
    }

    function test_PostBatchReentry_Reverts() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        ReenterPostBatch caller = new ReenterPostBatch(rollups);

        // Inner batch the hook will try to post (any valid-ish batch — guard fires first).
        ProofSystemBatchPerVerificationEntries memory inner =
            _stdBatch(r.id, _emptyEntries(), _emptyLookupCalls(), 0, 0);
        caller.setInner(inner);

        // Outer batch: one undrained transient entry so the meta hook fires.
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _emptyImmediateEntry(r.id);
        entries[0].proxyEntryHash = keccak256("undrained");
        ProofSystemBatchPerVerificationEntries memory outer = _stdBatch(r.id, entries, _emptyLookupCalls(), 1, 0);

        vm.expectRevert(EEZ.PostBatchReentry.selector);
        caller.post(outer);
    }

    function test_SetStateRoot_NotRollupContractReverts() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        vm.prank(alice); // not the manager contract
        vm.expectRevert(EEZ.NotRollupContract.selector);
        rollups.setStateRoot(r.id, keccak256("x"));
    }

    function test_CreateProxy_SameNetworkReverts() public {
        // L1's own network id is MAINNET (0) → proxy creation forbidden.
        vm.expectRevert(abi.encodeWithSelector(EEZBase.SameNetworkProxy.selector, MAINNET));
        rollups.createCrossChainProxy(address(target), MAINNET);
    }

    // ──────────────────────────────────────────────
    //  Execution-path branches
    // ──────────────────────────────────────────────

    /// @notice An entry whose single call carries `revertSpan = 1`: the call runs, its state
    ///         effect is rolled back, and cursors/hash escape via `ContextResult`.
    function test_Execution_RevertSpan() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            isStatic: false,
            targetAddress: address(target),
            value: 0,
            data: abi.encodeCall(SimpleTarget.setValue, (123)),
            sourceAddress: address(this),
            sourceRollupId: r.id,
            revertSpan: 1
        });
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: r.id, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].l2ToL1Calls = calls;
        entries[0].callCount = 1;
        entries[0].rollingHash = _rollingHashSingleCall("");

        _postBatchOneAuto(r, entries, 1);
        // State delta applied, but the forced-revert discarded the setValue effect.
        assertEq(_getRollupState(r.id), keccak256("s1"));
        assertEq(target.value(), 0);
    }

    /// @notice A top-level `isStatic` flat call dispatches via STATICCALL and reads `getValue()`.
    function test_Execution_StaticFlatCall() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        target.setValue(42);
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            isStatic: true,
            targetAddress: address(target),
            value: 0,
            data: abi.encodeCall(SimpleTarget.getValue, ()),
            sourceAddress: address(this),
            sourceRollupId: r.id,
            revertSpan: 0
        });
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: r.id, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].l2ToL1Calls = calls;
        entries[0].callCount = 1;
        entries[0].rollingHash = _rollingHashSingleCall(abi.encode(uint256(42)));

        _postBatchOneAuto(r, entries, 1);
        assertEq(_getRollupState(r.id), keccak256("s1"));
    }

    /// @notice `executeL2TX` re-entered from inside an entry call reverts with
    ///         `L2TXNotAllowedDuringExecution` — captured as a failed inner call.
    function test_Execution_L2TXDuringExecutionGuard() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        L2TXReenter reenter = new L2TXReenter(rollups, r.id);
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            isStatic: false,
            targetAddress: address(reenter),
            value: 0,
            data: abi.encodeCall(L2TXReenter.poke, ()),
            sourceAddress: address(this),
            sourceRollupId: r.id,
            revertSpan: 0
        });
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: r.id, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].l2ToL1Calls = calls;
        entries[0].callCount = 1;
        entries[0].rollingHash = _rollingHashSingleCall(""); // poke swallows the inner revert

        _postBatchOneAuto(r, entries, 1);
        assertEq(_getRollupState(r.id), keccak256("s1"));
    }

    /// @notice An entry promising one reentrant call that never gets made reverts
    ///         `UnconsumedL1ToL2Calls`.
    function test_Execution_UnconsumedReentrantReverts() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), r.id);
        bytes memory cd = abi.encodeCall(SimpleTarget.setValue, (1));
        bytes32 ah = _hashCall(r.id, address(target), 0, cd, address(this), MAINNET);

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            isStatic: false,
            targetAddress: address(target),
            value: 0,
            data: cd,
            sourceAddress: address(this),
            sourceRollupId: r.id,
            revertSpan: 0
        });
        ExpectedL1ToL2Call[] memory reentrant = new ExpectedL1ToL2Call[](1);
        reentrant[0] = ExpectedL1ToL2Call({
            crossChainCallHash: keccak256("never"), destinationRollupId: r.id, callCount: 0, returnData: ""
        });

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: r.id, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].proxyEntryHash = ah;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = reentrant;
        entries[0].callCount = 1;
        entries[0].rollingHash = _rollingHashSingleCall("");
        _postBatchOne(r, entries, _emptyLookupCalls(), 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        assertEq(sel, EEZ.UnconsumedL1ToL2Calls.selector);
    }

    // ──────────────────────────────────────────────
    //  CrossChainProxy transparent-proxy routing
    // ──────────────────────────────────────────────

    /// @notice `executeOnBehalf` from a non-EEZ caller routes through `_fallback` (transparent
    ///         proxy admin pattern) → `executeCrossChainCall`, which reverts (no batch this block).
    function test_Proxy_ExecuteOnBehalfFromNonEEZ() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), r.id);
        vm.prank(alice);
        (bool ok,) =
            proxyAddr.call(abi.encodeWithSignature("executeOnBehalf(address,bytes)", address(target), bytes("")));
        assertFalse(ok); // routed through _fallback, reverted in EEZ (not verified this block)
    }

    /// @notice `staticCheck()` from a non-self caller routes through `_fallback`.
    function test_Proxy_StaticCheckFromNonSelf() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), r.id);
        vm.prank(alice);
        (bool ok,) = proxyAddr.call(abi.encodeWithSignature("staticCheck()"));
        assertFalse(ok);
    }

    /// @notice A bare call with an unknown selector hits `fallback()` → `_fallback`.
    function test_Proxy_BareFallback() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), r.id);
        (bool ok,) = proxyAddr.call(abi.encodeWithSignature("nonexistentFn()"));
        assertFalse(ok);
    }

    // ──────────────────────────────────────────────
    //  Local helpers
    // ──────────────────────────────────────────────

    /// @notice A "shell" entry: given deltas, default everything else; destination = deltas[0].rollupId.
    function _shellEntry(uint256 destRid, StateDelta[] memory deltas) internal pure returns (ExecutionEntry memory e) {
        e.stateDeltas = deltas;
        e.proxyEntryHash = bytes32(0);
        e.destinationRollupId = destRid;
        e.l2ToL1Calls = new L2ToL1Call[](0);
        e.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        e.expectedLookups = new ExpectedLookup[](0);
        e.callCount = 0;
        e.returnData = "";
        e.rollingHash = bytes32(0);
    }

    /// @notice A minimal valid top-level `LookupCall` pinned to `rid`'s live root.
    function _shellLookup(uint256 rid) internal view returns (LookupCall memory lc) {
        lc.crossChainCallHash = keccak256("h");
        lc.destinationRollupId = rid;
        lc.returnData = "";
        lc.failed = true;
        lc.l2ToL1Calls = new L2ToL1Call[](0);
        lc.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        lc.expectedLookups = new ExpectedLookup[](0);
        lc.callCount = 0;
        lc.rollingHash = bytes32(0);
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: rid, stateRoot: _getRollupState(rid)});
        lc.expectedStateRoots = pins;
    }

    function _twoPsSorted(MockProofSystem ps2) internal view returns (address[] memory psList, bytes32[] memory vks) {
        psList = new address[](2);
        (address a, address b) = address(ps) < address(ps2) ? (address(ps), address(ps2)) : (address(ps2), address(ps));
        psList[0] = a;
        psList[1] = b;
        vks = new bytes32[](2);
        vks[0] = DEFAULT_VK;
        vks[1] = DEFAULT_VK;
    }

    function _sort3(address[] memory a) internal pure {
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (a[j] < a[i]) {
                    (a[i], a[j]) = (a[j], a[i]);
                }
            }
        }
    }

    /// @notice Posts a single-rollup batch from a `RollupHandle` with explicit transient count.
    function _postBatchOneAuto(Base.RollupHandle memory r, ExecutionEntry[] memory entries, uint256 tc) internal {
        _postBatchOne(r, entries, _emptyLookupCalls(), tc, 0);
    }
}
