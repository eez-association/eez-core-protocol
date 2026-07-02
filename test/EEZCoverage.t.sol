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
    StaticLookup,
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

/// @notice Re-enters `executeL2Txs` from inside an entry's call to exercise the
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
        try eez.executeL2Txs(uint64(rid)) {} catch {}
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
///         tripping the `_getVerificationKeysPerRollup` length guard.
contract BadVkeyManager is IRollupContract {
    function rollupContractRegistered(uint64) external {}

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

/// @notice Calls a proxy and bubbles up its raw revert data, so a reverting reentrant call's error
///         surfaces verbatim to the calling entry frame (used to exercise `ReentrantDestinationNotVerified`).
contract CrossReenter {
    function reenter(address proxy, bytes calldata data) external {
        (bool ok, bytes memory ret) = proxy.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @notice Fires one reentrant cross-chain call through a proxy, requires it to succeed, returns a
///         constant — drives a successful reentrant frame from inside an entry.
contract ReentrantForwarder {
    function forward(address proxy, bytes calldata data) external returns (uint256) {
        (bool ok,) = proxy.call(data);
        require(ok, "reentrant forward failed");
        return 7;
    }
}

/// @notice Meta hook that drives one proxy call during `executeMetaCrossChainTransactions`, so a
///         transient (meta-hook) entry can be consumed within `postAndVerifyBatch`.
contract MetaProxyCaller is IMetaCrossChainReceiver {
    EEZ public immutable eez;
    address public proxyAddr;
    bytes public proxyCallData;
    bool public hookRan;
    bool public callSuccess;

    constructor(EEZ _eez) {
        eez = _eez;
    }

    function setProxyCall(address _proxy, bytes calldata _cd) external {
        proxyAddr = _proxy;
        proxyCallData = _cd;
    }

    function post(ProofSystemBatchPerVerificationEntries calldata b) external {
        eez.postAndVerifyBatch(b);
    }

    function executeMetaCrossChainTransactions() external override {
        hookRan = true;
        (callSuccess,) = proxyAddr.call(proxyCallData);
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
        rps[0] = RollupIdWithProofSystems({rollupId: uint64(rid), proofSystemIndexes: idx});
    }

    function _raw(
        ExecutionEntry[] memory entries,
        StaticLookup[] memory lookups,
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
        b.staticLookups = lookups;
        b.immediateEntryCount = tc;
        b.immediateStaticLookupCount = tlc;
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
        StaticLookup[] memory lookups,
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
    //  _validateBatchStructure guards
    // ──────────────────────────────────────────────

    function test_Validate_EmptyProofSystems() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address[] memory psList = new address[](0);
        bytes[] memory proofs = new bytes[](0);
        ProofSystemBatchPerVerificationEntries memory b =
            _raw(_emptyEntries(), _emptyStaticLookups(), psList, proofs, _rpsOne(r.id, 1), 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_ProofsLengthMismatch() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes[] memory proofs = new bytes[](2); // mismatch
        ProofSystemBatchPerVerificationEntries memory b =
            _raw(_emptyEntries(), _emptyStaticLookups(), psList, proofs, _rpsOne(r.id, 1), 0, 0);
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
            _raw(_emptyEntries(), _emptyStaticLookups(), psList, proofs, rps, 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_UnregisteredRollup() public {
        // rollupId 999 has no manager registered.
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(999, _emptyEntries(), _emptyStaticLookups(), 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_EmptyProofSystemIndex() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), _emptyStaticLookups(), 0, 0);
        b.rollupIdsWithProofSystems[0].proofSystemIndexes = new uint64[](0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_IndexOutOfRange() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), _emptyStaticLookups(), 0, 0);
        uint64[] memory idx = new uint64[](1);
        idx[0] = 5; // >= psLen (1)
        b.rollupIdsWithProofSystems[0].proofSystemIndexes = idx;
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
        rps[0] = RollupIdWithProofSystems({rollupId: uint64(r.id), proofSystemIndexes: idx});
        ProofSystemBatchPerVerificationEntries memory b =
            _raw(_emptyEntries(), _emptyStaticLookups(), psList, proofs, rps, 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_StateDeltasNotIncreasing() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({rollupId: uint64(r.id), currentState: bytes32(0), newState: bytes32(0), etherDelta: 0});
        deltas[1] = StateDelta({rollupId: uint64(r.id), currentState: bytes32(0), newState: bytes32(0), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyStaticLookups(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.StateDeltasNotStrictlyIncreasing.selector, uint64(r.id)));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_EntryDestinationNotInDeltas() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: uint64(r.id), currentState: bytes32(0), newState: bytes32(0), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].destinationRollupId = 12345; // not in deltas
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyStaticLookups(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.EntryDestinationNotInStateDeltas.selector, uint64(12345)));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_CallSourceNotVerified() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: uint64(r.id), currentState: bytes32(0), newState: bytes32(0), etherDelta: 0});
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: 9999, // not in deltas
            targetAddress: address(target),
            value: 0,
            data: ""
        });
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].l2ToL1Calls = calls;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyStaticLookups(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.CallSourceNotVerified.selector, uint64(9999)));
        rollups.postAndVerifyBatch(b);
    }

    /// @notice A reentrant frame's own sub-call whose `sourceRollupId` isn't in the entry's deltas
    ///         trips the reentrant-walk source check. (The unified `ExpectedL1ToL2Call` carries no
    ///         destination field, so the old validation-time reentrant-destination check is gone — a
    ///         reentrant TARGET is now validated at runtime via `ReentrantDestinationNotVerified`.)
    function test_Validate_ReentrantCallSourceNotVerified() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: uint64(r.id), currentState: bytes32(0), newState: bytes32(0), etherDelta: 0});

        L2ToL1Call[] memory subCalls = new L2ToL1Call[](1);
        subCalls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: 8888, // not in deltas
            targetAddress: address(target),
            value: 0,
            data: ""
        });
        ExpectedL1ToL2Call[] memory reentrant = new ExpectedL1ToL2Call[](1);
        reentrant[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: bytes32(0),
            l2ToL1Calls: subCalls,
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: ""
        });
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].expectedL1ToL2Calls = reentrant;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyStaticLookups(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.CallSourceNotVerified.selector, uint64(8888)));
        rollups.postAndVerifyBatch(b);
    }

    /// @notice A top-level `StaticLookup`'s read-only sub-call whose `sourceRollupId` isn't among the
    ///         lookup's `expectedStateRoots` pins trips the static-lookup source check.
    function test_Validate_LookupCallSourceNotVerified() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0] = _shellLookup(r.id);
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: address(this),
            sourceRollupId: 7777, // not among the pins
            targetAddress: address(target),
            value: 0,
            data: ""
        });
        lookups[0].l2ToL1Calls = calls;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), lookups, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.CallSourceNotVerified.selector, uint64(7777)));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_PinsNotIncreasing() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0] = _shellLookup(r.id);
        // Both pins must be in-batch (membership is checked per-pin) so the duplicate trips the
        // strictly-increasing guard rather than RollupNotInBatch.
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](2);
        pins[0] = ExpectedStateRootPerRollup({rollupId: uint64(r.id), stateRoot: bytes32(0)});
        pins[1] = ExpectedStateRootPerRollup({rollupId: uint64(r.id), stateRoot: bytes32(0)}); // not increasing
        lookups[0].expectedStateRoots = pins;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), lookups, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.ExpectedStateRootsNotStrictlyIncreasing.selector, uint64(r.id)));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_PinRollupNotInBatch() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0] = _shellLookup(r.id);
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: 999, stateRoot: bytes32(0)}); // not in batch
        lookups[0].expectedStateRoots = pins;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), lookups, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.RollupNotInBatch.selector, uint64(999)));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_LookupDestinationNotPinned() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0] = _shellLookup(r.id);
        lookups[0].destinationRollupId = 555; // not among pins
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: uint64(r.id), stateRoot: _getRollupState(r.id)});
        lookups[0].expectedStateRoots = pins;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), lookups, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.LookupDestinationNotPinned.selector, uint64(555)));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_ImmediateCountExceedsEntries() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        // immediateEntryCount 1 > 0 entries.
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), _emptyStaticLookups(), 1, 0);
        vm.expectRevert(EEZ.ImmediateCountExceedsEntries.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_ImmediateStaticLookupCountExceeds() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _emptyImmediateEntry(r.id);
        // immediateEntryCount 1 <= 1 entry OK, but immediateStaticLookupCount 1 > 0 lookups → second bound.
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyStaticLookups(), 1, 1);
        vm.expectRevert(EEZ.ImmediateStaticLookupCountExceedsStaticLookups.selector);
        rollups.postAndVerifyBatch(b);
    }

    // ──────────────────────────────────────────────
    //  vkey-matrix length guard + multi-PS verification
    // ──────────────────────────────────────────────

    function test_FetchVkMatrix_WrongLengthReverts() public {
        BadVkeyManager bad = new BadVkeyManager();
        uint256 rid = rollups.registerRollup(address(bad), bytes32(0));
        // Single PS queried → manager returns 2 vkeys → length mismatch.
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(rid, _emptyEntries(), _emptyStaticLookups(), 0, 0);
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
        rps[0] =
            RollupIdWithProofSystems({rollupId: uint64(idLo), proofSystemIndexes: idLo == rAll.id ? idxAll : idxOne});
        rps[1] =
            RollupIdWithProofSystems({rollupId: uint64(idHi), proofSystemIndexes: idHi == rAll.id ? idxAll : idxOne});

        ProofSystemBatchPerVerificationEntries memory b =
            _raw(_emptyEntries(), _emptyStaticLookups(), psSorted, proofs, rps, 0, 0);
        rollups.postAndVerifyBatch(b);
        assertEq(rollups.lastVerifiedBlock(uint64(rAll.id)), block.number);
        assertEq(rollups.lastVerifiedBlock(uint64(rOne.id)), block.number);
    }

    // ──────────────────────────────────────────────
    //  Guards: self-call, reentry, setStateRoot
    // ──────────────────────────────────────────────

    function test_AttemptApplyImmediate_NotSelfReverts() public {
        vm.expectRevert(EEZBase.NotSelf.selector);
        rollups._attemptExecuteImmediateL2Txs(_emptyImmediateEntry(1));
    }

    function test_PostBatchReentry_Reverts() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        ReenterPostBatch caller = new ReenterPostBatch(rollups);

        // Inner batch the hook will try to post (any valid-ish batch — guard fires first).
        ProofSystemBatchPerVerificationEntries memory inner =
            _stdBatch(r.id, _emptyEntries(), _emptyStaticLookups(), 0, 0);
        caller.setInner(inner);

        // Outer batch: one undrained immediate entry so the meta hook fires.
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _emptyImmediateEntry(r.id);
        entries[0].proxyEntryHash = keccak256("undrained");
        ProofSystemBatchPerVerificationEntries memory outer = _stdBatch(r.id, entries, _emptyStaticLookups(), 1, 0);

        vm.expectRevert(EEZ.PostBatchReentry.selector);
        caller.post(outer);
    }

    function test_SetStateRoot_NotRollupContractReverts() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        vm.prank(alice); // not the manager contract
        vm.expectRevert(EEZ.NotRollupContract.selector);
        rollups.setStateRoot(uint64(r.id), keccak256("x"));
    }

    function test_CreateProxy_SameNetworkReverts() public {
        // L1's own network id is MAINNET (0) → proxy creation forbidden.
        vm.expectRevert(abi.encodeWithSelector(EEZBase.SameNetworkProxy.selector, uint64(MAINNET)));
        rollups.createCrossChainProxy(address(target), uint64(MAINNET));
    }

    // ──────────────────────────────────────────────
    //  Execution-path branches
    // ──────────────────────────────────────────────

    /// @notice An entry whose single call carries `revertNextNCalls = 1`: the call runs, its state
    ///         effect is rolled back, and cursors/hash escape via `ContextResult`.
    function test_Execution_RevertSpan() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        bytes memory cd = abi.encodeCall(SimpleTarget.setValue, (123));
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 1,
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: uint64(r.id),
            targetAddress: address(target),
            value: 0,
            data: cd
        });
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: uint64(r.id), currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});
        bytes32 cch = _ccHash(NOT_STATIC_CALL, address(this), uint64(r.id), address(target), uint64(MAINNET), 0, cd);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].l2ToL1Calls = calls;
        entries[0].rollingHash = _oneCallHash(deltas, bytes32(0), cch, true, "");

        _postBatchOneAuto(r, entries, 1);
        // State delta applied, but the forced-revert discarded the setValue effect.
        assertEq(_getRollupState(r.id), keccak256("s1"));
        assertEq(target.value(), 0);
    }

    /// @notice A top-level `isStatic` flat call dispatches via STATICCALL and reads `getValue()`.
    function test_Execution_StaticFlatCall() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        target.setValue(42);
        bytes memory cd = abi.encodeCall(SimpleTarget.getValue, ());
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: address(this),
            sourceRollupId: uint64(r.id),
            targetAddress: address(target),
            value: 0,
            data: cd
        });
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: uint64(r.id), currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});
        bytes32 cch = _ccHash(IS_STATIC, address(this), uint64(r.id), address(target), uint64(MAINNET), 0, cd);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].l2ToL1Calls = calls;
        entries[0].rollingHash = _oneCallHash(deltas, bytes32(0), cch, true, abi.encode(uint256(42)));

        _postBatchOneAuto(r, entries, 1);
        assertEq(_getRollupState(r.id), keccak256("s1"));
    }

    /// @notice `executeL2Txs` re-entered from inside an entry call reverts with
    ///         `L2TXNotAllowedDuringExecution` — swallowed by the target as a failed inner call.
    function test_Execution_L2TXDuringExecutionGuard() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        L2TXReenter reenter = new L2TXReenter(rollups, r.id);
        bytes memory cd = abi.encodeCall(L2TXReenter.poke, ());
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: uint64(r.id),
            targetAddress: address(reenter),
            value: 0,
            data: cd
        });
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: uint64(r.id), currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});
        bytes32 cch = _ccHash(NOT_STATIC_CALL, address(this), uint64(r.id), address(reenter), uint64(MAINNET), 0, cd);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].l2ToL1Calls = calls;
        entries[0].rollingHash = _oneCallHash(deltas, bytes32(0), cch, true, ""); // poke swallows the inner revert

        _postBatchOneAuto(r, entries, 1);
        assertEq(_getRollupState(r.id), keccak256("s1"));
    }

    /// @notice An entry promising one reentrant call that never gets made reverts. Completeness of
    ///         the unified `expectedL1ToL2Calls` table is enforced by the rolling hash (not a
    ///         table-length check): the declared NESTED frame never folds in, so the entry's actual
    ///         hash diverges and it reverts `RollingHashMismatch`.
    function test_Execution_UnconsumedReentrantReverts() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        bytes memory cd = abi.encodeCall(SimpleTarget.setValue, (1));
        // Inbound proxy-entry hash (this → target on r.id, no value).
        bytes32 ah = _ccHash(NOT_STATIC_CALL, address(this), uint64(MAINNET), address(target), uint64(r.id), 0, cd);

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: uint64(r.id), currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});

        // Declared hash folds a NESTED frame for a reentrant call the entry never fires (it has no
        // top-level call that re-enters EEZ), so the actual hash stays at the entry-begin seed.
        bytes32 reentrantCch =
            _ccHash(NOT_STATIC_CALL, address(this), uint64(r.id), address(target), uint64(r.id), 0, cd);
        bytes32 rhAtFire = _hEntryBegin(deltas, ah);
        bytes32 h = _hNestedBegin(rhAtFire, reentrantCch);
        h = _hNestedEnd(h);

        ExpectedL1ToL2Call[] memory reentrant = new ExpectedL1ToL2Call[](1);
        reentrant[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: _expectedL1toL2Hash(reentrantCch, rhAtFire),
            l2ToL1Calls: _emptyCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: ""
        });

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].proxyEntryHash = ah;
        entries[0].expectedL1ToL2Calls = reentrant;
        entries[0].rollingHash = h;
        _postBatchOne(r, entries, _emptyStaticLookups(), 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        assertEq(sel, EEZBase.RollingHashMismatch.selector);
    }

    // ──────────────────────────────────────────────
    //  CrossChainProxy transparent-proxy routing
    // ──────────────────────────────────────────────

    /// @notice `executeOnBehalf` from a non-EEZ caller routes through `_fallback` (transparent
    ///         proxy admin pattern) → `executeCrossChainCall`, which reverts (no batch this block).
    function test_Proxy_ExecuteOnBehalfFromNonEEZ() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        vm.prank(alice);
        (bool ok,) =
            proxyAddr.call(abi.encodeWithSignature("executeOnBehalf(address,bytes)", address(target), bytes("")));
        assertFalse(ok); // routed through _fallback, reverted in EEZ (not verified this block)
    }

    /// @notice `staticCheck()` from a non-self caller routes through `_fallback`.
    function test_Proxy_StaticCheckFromNonSelf() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        vm.prank(alice);
        (bool ok,) = proxyAddr.call(abi.encodeWithSignature("staticCheck()"));
        assertFalse(ok);
    }

    /// @notice A bare call with an unknown selector hits `fallback()` → `_fallback`.
    function test_Proxy_BareFallback() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        (bool ok,) = proxyAddr.call(abi.encodeWithSignature("nonexistentFn()"));
        assertFalse(ok);
    }

    // ──────────────────────────────────────────────
    //  Execution-path branches: more coverage
    // ──────────────────────────────────────────────

    /// @notice A `revertNextNCalls` span overrunning its call array reverts `RevertSpanOutOfBounds`.
    ///         Deferred entry so the revert surfaces through the proxy (an immediate entry would be
    ///         swallowed into `L2TxSkipped`).
    function test_Execution_RevertSpanOutOfBounds() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        bytes memory cd = abi.encodeCall(SimpleTarget.setValue, (1));
        bytes32 ah = _ccHash(NOT_STATIC_CALL, address(this), uint64(MAINNET), address(target), uint64(r.id), 0, cd);

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 2, // span of 2 overruns the single-element array
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: uint64(r.id),
            targetAddress: address(target),
            value: 0,
            data: cd
        });
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: uint64(r.id), currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].proxyEntryHash = ah;
        entries[0].l2ToL1Calls = calls;
        entries[0].rollingHash = bytes32(0); // unreached — reverts before the hash check
        _postBatchOne(r, entries, _emptyStaticLookups(), 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        assertEq(sel, EEZ.RevertSpanOutOfBounds.selector);
    }

    /// @notice A reentrant call whose destination rollup is verified this block but is NOT among the
    ///         executing entry's `stateDeltas` trips the runtime proxy-protection check
    ///         (`ReentrantDestinationNotVerified`). The entry's top-level call captures that revert as its
    ///         `CALL_END` result; pinning the rolling hash to that exact error data proves the path.
    function test_Reentrant_DestinationNotVerified() public {
        // rA runs the entry; rB is verified in the same batch but absent from the entry's deltas.
        Base.RollupHandle memory rA = _makeRollup(bytes32(0));
        Base.RollupHandle memory rB = _makeRollup(bytes32(0));
        (uint256 rLo, uint256 rHi) = rA.id < rB.id ? (rA.id, rB.id) : (rB.id, rA.id);

        CrossReenter reenter = new CrossReenter();
        address rBproxy = rollups.createCrossChainProxy(address(target), uint64(rB.id));
        bytes memory innerData = abi.encodeCall(SimpleTarget.setValue, (5));

        bytes memory outerData = abi.encodeCall(CrossReenter.reenter, (rBproxy, innerData));
        address topProxy = rollups.createCrossChainProxy(address(reenter), uint64(rA.id));

        // Built in a sub-frame to keep this test under the stack-depth limit under coverage instrumentation.
        ExecutionEntry[] memory entries = _reentrantDestEntry(rA.id, address(reenter), outerData, uint64(rB.id));

        ProofSystemBatchPerVerificationEntries memory b =
            _twoRollupBatch(rLo, rHi, entries, _emptyStaticLookups(), 0, 0);
        rollups.postAndVerifyBatch(b);

        (bool ok,) = topProxy.call(outerData);
        assertTrue(ok, "entry commits; the reentrant call reverted ReentrantDestinationNotVerified(rB)");
        assertEq(_getRollupState(rA.id), keccak256("s1"));
    }

    /// @notice A top-level `StaticLookup` carrying TWO `expectedStateRoots` pins (strictly increasing)
    ///         exercises the multi-pin validation loop and the multi-pin `_stateRootsMatch` scan, then
    ///         resolves successfully.
    function test_Validate_TopLevelStaticLookup_TwoPins() public {
        Base.RollupHandle memory rA = _makeRollup(bytes32(0));
        Base.RollupHandle memory rB = _makeRollup(bytes32(0));
        (uint256 rLo, uint256 rHi) = rA.id < rB.id ? (rA.id, rB.id) : (rB.id, rA.id);

        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(rLo));
        bytes memory cd = abi.encodeCall(SimpleTarget.getValue, ());
        bytes memory payload = abi.encode(uint256(321));
        bytes32 h = _ccHash(IS_STATIC, alice, uint64(MAINNET), address(target), uint64(rLo), 0, cd);

        StaticLookup memory lk;
        lk.proxyEntryHash = h;
        lk.destinationRollupId = uint64(rLo);
        lk.l2ToL1Calls = new L2ToL1Call[](0);
        lk.rollingHash = bytes32(0);
        lk.success = true;
        lk.returnData = payload;
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](2);
        pins[0] = ExpectedStateRootPerRollup({rollupId: uint64(rLo), stateRoot: _getRollupState(rLo)});
        pins[1] = ExpectedStateRootPerRollup({rollupId: uint64(rHi), stateRoot: _getRollupState(rHi)});
        lk.expectedStateRoots = pins;
        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0] = lk;

        ProofSystemBatchPerVerificationEntries memory b = _twoRollupBatch(rLo, rHi, _emptyEntries(), lookups, 0, 0);
        rollups.postAndVerifyBatch(b);

        vm.prank(proxyAddr);
        bytes memory res = rollups.staticCallLookup(alice, cd);
        assertEq(res, payload);
    }

    /// @notice A batch carrying a non-empty `blobIndices` exercises the `blobhash(...)` loop in
    ///         `_verifyProofSystemBatch`. With no real blobs `blobhash(0)` returns 0; the line still runs
    ///         and the batch verifies (MockProofSystem accepts by default).
    function test_PostBatch_NonEmptyBlobIndices() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), _emptyStaticLookups(), 0, 0);
        uint256[] memory blobs = new uint256[](1);
        blobs[0] = 0;
        b.blobIndices = blobs;
        rollups.postAndVerifyBatch(b);
        assertEq(rollups.lastVerifiedBlock(uint64(r.id)), block.number);
    }

    /// @notice Meta-hook path: an immediate static lookup is loaded into the transient pool
    ///         (`immediateStaticLookupCount > 0`), and a transient (meta-hook) entry consumed during the
    ///         hook fires a reentrant call resolved against the TRANSIENT `expectedL1ToL2Calls` table.
    function test_MetaHook_ImmediateStaticLookupAndTransientReentrant() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        MetaProxyCaller caller = new MetaProxyCaller(rollups);
        ReentrantForwarder fwd = new ReentrantForwarder();

        address innerTarget = address(0xBEEF);
        address reentrantProxy = rollups.createCrossChainProxy(innerTarget, uint64(r.id));
        bytes memory innerData = "";

        bytes memory outerData = abi.encodeCall(ReentrantForwarder.forward, (reentrantProxy, innerData));
        address topProxy = rollups.createCrossChainProxy(address(fwd), uint64(r.id));

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(caller),
            sourceRollupId: uint64(r.id),
            targetAddress: address(fwd),
            value: 0,
            data: outerData
        });
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: uint64(r.id), currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});

        bytes32 ah =
            _ccHash(NOT_STATIC_CALL, address(caller), uint64(MAINNET), address(fwd), uint64(r.id), 0, outerData);
        bytes32 cchTop =
            _ccHash(NOT_STATIC_CALL, address(caller), uint64(r.id), address(fwd), uint64(MAINNET), 0, outerData);
        bytes32 reentrantCch =
            _ccHash(NOT_STATIC_CALL, address(fwd), uint64(MAINNET), innerTarget, uint64(r.id), 0, innerData);

        // Built in a sub-frame to keep this test under the stack-depth limit under coverage instrumentation.
        (bytes32 h, ExpectedL1ToL2Call[] memory reentrant) =
            _metaReentrantTableAndHash(deltas, ah, cchTop, reentrantCch);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].proxyEntryHash = ah; // != 0 → leading L2Tx run stops, meta hook fires
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = reentrant;
        entries[0].rollingHash = h;

        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0] = _shellLookup(r.id); // pushed into the transient pool (immediateStaticLookupCount = 1)

        caller.setProxyCall(topProxy, outerData);
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, lookups, 1, 1);
        caller.post(b);

        assertTrue(caller.hookRan(), "meta hook must run");
        assertTrue(caller.callSuccess(), "transient entry consumed; reentrant resolved against the transient table");
        assertEq(_getRollupState(r.id), keccak256("s1"));
    }

    // ──────────────────────────────────────────────
    //  Local helpers
    // ──────────────────────────────────────────────

    /// @notice Two-rollup single-PS batch (both rollups list the default `ps`), sorted by rollupId.
    function _twoRollupBatch(
        uint256 rLo,
        uint256 rHi,
        ExecutionEntry[] memory entries,
        StaticLookup[] memory lookups,
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
        uint64[] memory idx = new uint64[](1);
        idx[0] = 0;
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](2);
        rps[0] = RollupIdWithProofSystems({rollupId: uint64(rLo), proofSystemIndexes: idx});
        rps[1] = RollupIdWithProofSystems({rollupId: uint64(rHi), proofSystemIndexes: idx});
        b = _raw(entries, lookups, psList, proofs, rps, tc, tlc);
    }

    /// @notice Single-entry builder for `test_Reentrant_DestinationNotVerified`: a top-level call into
    ///         `reenter` whose reentrant call into `rB`'s proxy reverts `ReentrantDestinationNotVerified`.
    ///         Pulled out for stack-depth headroom.
    function _reentrantDestEntry(uint256 rAid, address reenter, bytes memory outerData, uint64 rBid)
        internal
        view
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: uint64(rAid), currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: uint64(rAid),
            targetAddress: reenter,
            value: 0,
            data: outerData
        });

        bytes32 ah = _ccHash(NOT_STATIC_CALL, address(this), uint64(MAINNET), reenter, uint64(rAid), 0, outerData);
        bytes32 cchTop = _ccHash(NOT_STATIC_CALL, address(this), uint64(rAid), reenter, uint64(MAINNET), 0, outerData);
        bytes memory errData = abi.encodeWithSelector(EEZ.ReentrantDestinationNotVerified.selector, rBid);
        bytes32 h = _hCallEnd(_hCallBegin(_hEntryBegin(deltas, ah), cchTop), false, errData);

        entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(rAid, deltas);
        entries[0].proxyEntryHash = ah;
        entries[0].l2ToL1Calls = calls;
        entries[0].rollingHash = h;
    }

    /// @notice Rolling hash + transient reentrant table for the meta-hook test (top-level call with one
    ///         successful empty reentrant frame returning `7`). Pulled out for stack-depth headroom.
    function _metaReentrantTableAndHash(StateDelta[] memory deltas, bytes32 ah, bytes32 cchTop, bytes32 reentrantCch)
        internal
        pure
        returns (bytes32 h, ExpectedL1ToL2Call[] memory reentrant)
    {
        bytes32 hAtFire = _hCallBegin(_hEntryBegin(deltas, ah), cchTop);
        h = _hNestedBegin(hAtFire, reentrantCch);
        h = _hNestedEnd(h);
        h = _hCallEnd(h, true, abi.encode(uint256(7)));

        reentrant = new ExpectedL1ToL2Call[](1);
        reentrant[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: _expectedL1toL2Hash(reentrantCch, hAtFire),
            l2ToL1Calls: _emptyCalls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: ""
        });
    }

    /// @notice A "shell" entry: given deltas, default everything else; destination = deltas[0].rollupId.
    function _shellEntry(uint256 destRid, StateDelta[] memory deltas) internal pure returns (ExecutionEntry memory e) {
        e.stateDeltas = deltas;
        e.proxyEntryHash = bytes32(0);
        e.destinationRollupId = uint64(destRid);
        e.l2ToL1Calls = new L2ToL1Call[](0);
        e.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        e.rollingHash = bytes32(0);
        e.success = true;
        e.returnData = "";
    }

    /// @notice A minimal `StaticLookup` pinned to `rid`'s live root; resolution reverts (`success == false`).
    function _shellLookup(uint256 rid) internal view returns (StaticLookup memory lc) {
        lc.proxyEntryHash = keccak256("h");
        lc.destinationRollupId = uint64(rid);
        lc.returnData = "";
        lc.success = false;
        lc.l2ToL1Calls = new L2ToL1Call[](0);
        lc.rollingHash = bytes32(0);
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: uint64(rid), stateRoot: _getRollupState(rid)});
        lc.expectedStateRoots = pins;
    }

    /// @notice Rolling hash for an entry with exactly one top-level call.
    function _oneCallHash(
        StateDelta[] memory deltas,
        bytes32 proxyEntryHash,
        bytes32 crossChainCallHash,
        bool success,
        bytes memory retData
    )
        internal
        pure
        returns (bytes32 h)
    {
        h = _hEntryBegin(deltas, proxyEntryHash);
        h = _hCallBegin(h, crossChainCallHash);
        h = _hCallEnd(h, success, retData);
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

    /// @notice Posts a single-rollup batch from a `RollupHandle` with explicit immediate count.
    function _postBatchOneAuto(Base.RollupHandle memory r, ExecutionEntry[] memory entries, uint256 tc) internal {
        _postBatchOne(r, entries, _emptyStaticLookups(), tc, 0);
    }
}
