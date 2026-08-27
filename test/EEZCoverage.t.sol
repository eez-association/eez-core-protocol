// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../src/EEZ.sol";
import {IRollupContract} from "../src/interfaces/IRollup.sol";
import {IMetaCrossChainReceiver} from "../src/interfaces/IMetaCrossChainReceiver.sol";
import {
    ExecutionEntry,
    RollupUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    StaticExecutionEntry,
    ExpectedRootPerRollup
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
///         `L2TxNotAllowedDuringExecution` guard.
contract L2TXReenter {
    EEZ public immutable eez;
    uint256 public immutable rid;

    constructor(EEZ _eez, uint256 _rid) {
        eez = _eez;
        rid = _rid;
    }

    function poke() external {
        // The inner call reverts `L2TxNotAllowedDuringExecution`; swallow it so the outer
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

    uint64 internal constant MAINNET_ROLLUP_ID = 0;

    function setUp() public {
        setUpBase();
        target = new SimpleTarget();
    }

    // ──────────────────────────────────────────────
    //  _validateBatchStructure guards
    // ──────────────────────────────────────────────

    function test_Validate_EmptyProofSystems() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address[] memory psList = new address[](0);
        bytes[] memory proofs = new bytes[](0);
        ProofSystemBatchPerVerificationEntries memory b =
            _raw(_emptyEntries(), _emptyStaticEntries(), psList, proofs, _rpsOne(r.id, 1), 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_ProofsLengthMismatch() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes[] memory proofs = new bytes[](2); // mismatch
        ProofSystemBatchPerVerificationEntries memory b =
            _raw(_emptyEntries(), _emptyStaticEntries(), psList, proofs, _rpsOne(r.id, 1), 0, 0);
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
            _raw(_emptyEntries(), _emptyStaticEntries(), psList, proofs, rps, 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_UnregisteredRollup() public {
        // rollupId 999 has no manager registered.
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(999, _emptyEntries(), _emptyStaticEntries(), 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_EmptyProofSystemIndex() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), _emptyStaticEntries(), 0, 0);
        b.rollupIdsWithProofSystems[0].proofSystemIndexes = new uint64[](0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_IndexOutOfRange() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), _emptyStaticEntries(), 0, 0);
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
        RollupHandle memory r = _makeRollupCustom(bytes32(0), psList, vks, 1, alice);

        bytes[] memory proofs = new bytes[](2);
        proofs[0] = "p0";
        proofs[1] = "p1";
        uint64[] memory idx = new uint64[](2);
        idx[0] = 0;
        idx[1] = 0; // duplicate
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: uint64(r.id), proofSystemIndexes: idx});
        ProofSystemBatchPerVerificationEntries memory b =
            _raw(_emptyEntries(), _emptyStaticEntries(), psList, proofs, rps, 0, 0);
        vm.expectRevert(EEZ.InvalidProofSystemConfig.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_RollupUpdatesNotIncreasing() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        RollupUpdate[] memory deltas = new RollupUpdate[](2);
        deltas[0] = RollupUpdate({rollupId: uint64(r.id), currentRoot: bytes32(0), newRoot: bytes32(0), etherDelta: 0});
        deltas[1] = RollupUpdate({rollupId: uint64(r.id), currentRoot: bytes32(0), newRoot: bytes32(0), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyStaticEntries(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.RollupUpdatesNotStrictlyIncreasing.selector, uint64(r.id)));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_EntryDestinationNotInDeltas() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, _oneDelta(r.id, bytes32(0), bytes32(0), 0));
        entries[0].destinationRollupId = 12345; // not in deltas
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyStaticEntries(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.EntryDestinationNotInRollupUpdates.selector, uint64(12345)));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_CallSourceNotVerified() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        RollupUpdate[] memory deltas = _oneDelta(r.id, bytes32(0), bytes32(0), 0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        // sourceRollupId 9999 is not in the entry's deltas.
        entries[0].l2ToL1Calls = _oneCall(_call(address(this), 9999, address(target), 0, ""));
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyStaticEntries(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.CallSourceNotVerified.selector, uint64(9999)));
        rollups.postAndVerifyBatch(b);
    }

    /// @notice A reentrant frame's own sub-call whose `sourceRollupId` isn't in the entry's deltas
    ///         trips the reentrant-walk source check. (The unified `ExpectedL1ToL2Call` carries no
    ///         destination field, so the old validation-time reentrant-destination check is gone — a
    ///         reentrant TARGET is now validated at runtime via `ReentrantDestinationNotVerified`.)
    function test_Validate_ReentrantCallSourceNotVerified() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        RollupUpdate[] memory deltas = _oneDelta(r.id, bytes32(0), bytes32(0), 0);

        ExpectedL1ToL2Call[] memory reentrant = new ExpectedL1ToL2Call[](1);
        reentrant[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: bytes32(0),
            // sourceRollupId 8888 is not in the entry's deltas.
            l2ToL1Calls: _oneCall(_call(address(this), 8888, address(target), 0, "")),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: ""
        });
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].expectedL1ToL2Calls = reentrant;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyStaticEntries(), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.CallSourceNotVerified.selector, uint64(8888)));
        rollups.postAndVerifyBatch(b);
    }

    /// @notice A top-level `StaticExecutionEntry`'s read-only sub-call whose `sourceRollupId` isn't among the
    ///         lookup's `expectedRoots` pins trips the static-lookup source check.
    function test_Validate_LookupCallSourceNotVerified() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        StaticExecutionEntry[] memory lookups = new StaticExecutionEntry[](1);
        lookups[0] = _shellLookup(r.id);
        // sourceRollupId 7777 is not among the lookup's pins.
        lookups[0].l2ToL1Calls = _oneCall(_staticCall(address(this), 7777, address(target), ""));
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), lookups, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.CallSourceNotVerified.selector, uint64(7777)));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_PinsNotIncreasing() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        StaticExecutionEntry[] memory lookups = new StaticExecutionEntry[](1);
        lookups[0] = _shellLookup(r.id);
        // Both pins must be in-batch (membership is checked per-pin) so the duplicate trips the
        // strictly-increasing guard rather than RollupNotInBatch.
        ExpectedRootPerRollup[] memory pins = new ExpectedRootPerRollup[](2);
        pins[0] = ExpectedRootPerRollup({rollupId: uint64(r.id), root: bytes32(0)});
        pins[1] = ExpectedRootPerRollup({rollupId: uint64(r.id), root: bytes32(0)}); // not increasing
        lookups[0].expectedRoots = pins;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), lookups, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.ExpectedRootsNotStrictlyIncreasing.selector, uint64(r.id)));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_PinRollupNotInBatch() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        StaticExecutionEntry[] memory lookups = new StaticExecutionEntry[](1);
        lookups[0] = _shellLookup(r.id);
        ExpectedRootPerRollup[] memory pins = new ExpectedRootPerRollup[](1);
        pins[0] = ExpectedRootPerRollup({rollupId: 999, root: bytes32(0)}); // not in batch
        lookups[0].expectedRoots = pins;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), lookups, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.RollupNotInBatch.selector, uint64(999)));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_LookupDestinationNotPinned() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        StaticExecutionEntry[] memory lookups = new StaticExecutionEntry[](1);
        lookups[0] = _shellLookup(r.id);
        lookups[0].destinationRollupId = 555; // not among pins
        ExpectedRootPerRollup[] memory pins = new ExpectedRootPerRollup[](1);
        pins[0] = ExpectedRootPerRollup({rollupId: uint64(r.id), root: _getRollupState(r.id)});
        lookups[0].expectedRoots = pins;
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), lookups, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EEZ.StaticEntryDestinationNotPinned.selector, uint64(555)));
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_ImmediateCountExceedsEntries() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        // immediateEntryCount 1 > 0 entries.
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), _emptyStaticEntries(), 1, 0);
        vm.expectRevert(EEZ.ImmediateCountExceedsEntries.selector);
        rollups.postAndVerifyBatch(b);
    }

    function test_Validate_ImmediateStaticLookupCountExceeds() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _emptyImmediateEntry(r.id);
        // immediateEntryCount 1 <= 1 entry OK, but immediateStaticEntryCount 1 > 0 lookups → second bound.
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, entries, _emptyStaticEntries(), 1, 1);
        vm.expectRevert(EEZ.ImmediateStaticEntryCountExceedsStaticEntries.selector);
        rollups.postAndVerifyBatch(b);
    }

    // ──────────────────────────────────────────────
    //  vkey-matrix length guard + multi-PS verification
    // ──────────────────────────────────────────────

    function test_FetchVkMatrix_WrongLengthReverts() public {
        BadVkeyManager bad = new BadVkeyManager();
        uint256 rid = rollups.registerRollup(address(bad), bytes32(0));
        // Single PS queried → manager returns 2 vkeys → length mismatch.
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(rid, _emptyEntries(), _emptyStaticEntries(), 0, 0);
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
        RollupHandle memory rAll = _makeRollupCustom(bytes32(0), psSorted, vks3, 1, alice);

        address[] memory ps1 = new address[](1);
        ps1[0] = psSorted[0];
        bytes32[] memory vk1 = new bytes32[](1);
        vk1[0] = DEFAULT_VK;
        RollupHandle memory rOne = _makeRollupCustom(bytes32(0), ps1, vk1, 1, alice);

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
            _raw(_emptyEntries(), _emptyStaticEntries(), psSorted, proofs, rps, 0, 0);
        rollups.postAndVerifyBatch(b);
        assertEq(rollups.lastVerifiedBlock(uint64(rAll.id)), block.number);
        assertEq(rollups.lastVerifiedBlock(uint64(rOne.id)), block.number);
    }

    // ──────────────────────────────────────────────
    //  Guards: self-call, reentry, setRoot
    // ──────────────────────────────────────────────

    function test_AttemptApplyImmediate_NotSelfReverts() public {
        vm.expectRevert(EEZBase.NotSelf.selector);
        rollups._attemptExecuteImmediateL2Txs(_emptyImmediateEntry(1));
    }

    function test_PostBatchReentry_Reverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ReenterPostBatch caller = new ReenterPostBatch(rollups);

        // Inner batch the hook will try to post (any valid-ish batch — guard fires first).
        ProofSystemBatchPerVerificationEntries memory inner =
            _stdBatch(r.id, _emptyEntries(), _emptyStaticEntries(), 0, 0);
        caller.setInner(inner);

        // Outer batch: one undrained immediate entry so the meta hook fires.
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _emptyImmediateEntry(r.id);
        entries[0].proxyEntryHash = keccak256("undrained");
        ProofSystemBatchPerVerificationEntries memory outer = _stdBatch(r.id, entries, _emptyStaticEntries(), 1, 0);

        vm.expectRevert(EEZ.PostBatchReentry.selector);
        caller.post(outer);
    }

    function test_SetRoot_NotRollupContractReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        vm.prank(alice); // not the manager contract
        vm.expectRevert(EEZ.NotRollupContract.selector);
        rollups.setRoot(uint64(r.id), keccak256("x"));
    }

    function test_CreateProxy_SameNetworkReverts() public {
        // L1's own network id is MAINNET_ROLLUP_ID (0) → proxy creation forbidden.
        vm.expectRevert(abi.encodeWithSelector(EEZBase.SameNetworkProxy.selector, MAINNET_ROLLUP_ID));
        rollups.createCrossChainProxy(address(target), MAINNET_ROLLUP_ID);
    }

    // ──────────────────────────────────────────────
    //  Execution-path branches
    // ──────────────────────────────────────────────

    /// @notice An entry whose single call carries `revertNextNCalls = 1`: the call runs, its state
    ///         effect is rolled back, and cursors/hash escape via `ContextResult`.
    function test_Execution_RevertSpan() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        bytes memory cd = abi.encodeCall(SimpleTarget.setValue, (123));
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 1,
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: uint64(r.id),
            targetAddress: address(target),
            value: 0,
            data: cd
        });
        RollupUpdate[] memory deltas = _oneDelta(r.id, bytes32(0), keccak256("s1"), 0);
        bytes32 cch = _ccHash(NOT_STATIC_CALL, address(this), uint64(r.id), address(target), MAINNET_ROLLUP_ID, 0, cd);
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
        RollupHandle memory r = _makeRollup(bytes32(0));
        target.setValue(42);
        bytes memory cd = abi.encodeCall(SimpleTarget.getValue, ());
        RollupUpdate[] memory deltas = _oneDelta(r.id, bytes32(0), keccak256("s1"), 0);
        bytes32 cch = _ccHash(IS_STATIC, address(this), uint64(r.id), address(target), MAINNET_ROLLUP_ID, 0, cd);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].l2ToL1Calls = _oneCall(_staticCall(address(this), uint64(r.id), address(target), cd));
        entries[0].rollingHash = _oneCallHash(deltas, bytes32(0), cch, true, abi.encode(uint256(42)));

        _postBatchOneAuto(r, entries, 1);
        assertEq(_getRollupState(r.id), keccak256("s1"));
    }

    /// @notice `executeL2Txs` re-entered from inside an entry call reverts with
    ///         `L2TxNotAllowedDuringExecution` — swallowed by the target as a failed inner call.
    function test_Execution_L2TXDuringExecutionGuard() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        L2TXReenter reenter = new L2TXReenter(rollups, r.id);
        bytes memory cd = abi.encodeCall(L2TXReenter.poke, ());
        RollupUpdate[] memory deltas = _oneDelta(r.id, bytes32(0), keccak256("s1"), 0);
        bytes32 cch = _ccHash(NOT_STATIC_CALL, address(this), uint64(r.id), address(reenter), MAINNET_ROLLUP_ID, 0, cd);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].l2ToL1Calls = _oneCall(_call(address(this), uint64(r.id), address(reenter), 0, cd));
        entries[0].rollingHash = _oneCallHash(deltas, bytes32(0), cch, true, ""); // poke swallows the inner revert

        _postBatchOneAuto(r, entries, 1);
        assertEq(_getRollupState(r.id), keccak256("s1"));
    }

    /// @notice An entry promising one reentrant call that never gets made reverts. Completeness of
    ///         the unified `expectedL1ToL2Calls` table is enforced by the rolling hash (not a
    ///         table-length check): the declared NESTED frame never folds in, so the entry's actual
    ///         hash diverges and it reverts `RollingHashMismatch`.
    function test_Execution_UnconsumedReentrantReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        bytes memory cd = abi.encodeCall(SimpleTarget.setValue, (1));
        // Inbound proxy-entry hash (this → target on r.id, no value).
        bytes32 ah = _ccHash(NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, address(target), uint64(r.id), 0, cd);

        RollupUpdate[] memory deltas = _oneDelta(r.id, bytes32(0), keccak256("s1"), 0);

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
        _postBatchOne(r, entries, _emptyStaticEntries(), 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        _assertRevertSelector(ret, EEZBase.RollingHashMismatch.selector);
    }

    // ──────────────────────────────────────────────
    //  CrossChainProxy transparent-proxy routing
    // ──────────────────────────────────────────────

    /// @notice `executeOnBehalf` from a non-EEZ caller routes through `_fallback` (transparent
    ///         proxy admin pattern) → `executeCrossChainCall`, which reverts (no batch this block).
    function test_Proxy_ExecuteOnBehalfFromNonEEZ() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        vm.prank(alice);
        (bool ok,) =
            proxyAddr.call(abi.encodeWithSignature("executeOnBehalf(address,bytes)", address(target), bytes("")));
        assertFalse(ok); // routed through _fallback, reverted in EEZ (not verified this block)
    }

    /// @notice `staticCheck()` from a non-self caller routes through `_fallback`.
    function test_Proxy_StaticCheckFromNonSelf() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        vm.prank(alice);
        (bool ok,) = proxyAddr.call(abi.encodeWithSignature("staticCheck()"));
        assertFalse(ok);
    }

    /// @notice A bare call with an unknown selector hits `fallback()` → `_fallback`.
    function test_Proxy_BareFallback() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
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
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        bytes memory cd = abi.encodeCall(SimpleTarget.setValue, (1));
        bytes32 ah = _ccHash(NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, address(target), uint64(r.id), 0, cd);

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 2, // span of 2 overruns the single-element array
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: uint64(r.id),
            targetAddress: address(target),
            value: 0,
            data: cd
        });
        RollupUpdate[] memory deltas = _oneDelta(r.id, bytes32(0), keccak256("s1"), 0);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].proxyEntryHash = ah;
        entries[0].l2ToL1Calls = calls;
        entries[0].rollingHash = bytes32(0); // unreached — reverts before the hash check
        _postBatchOne(r, entries, _emptyStaticEntries(), 0, 0);

        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        assertFalse(ok);
        _assertRevertSelector(ret, EEZ.RevertSpanOutOfBounds.selector);
    }

    /// @notice A reentrant call whose destination rollup is verified this block but is NOT among the
    ///         executing entry's `rollupUpdates` trips the runtime proxy-protection check
    ///         (`ReentrantDestinationNotVerified`). The entry's top-level call captures that revert as its
    ///         `CALL_END` result; pinning the rolling hash to that exact error data proves the path.
    function test_Reentrant_DestinationNotVerified() public {
        // rA runs the entry; rB is verified in the same batch but absent from the entry's deltas.
        RollupHandle memory rA = _makeRollup(bytes32(0));
        RollupHandle memory rB = _makeRollup(bytes32(0));
        (uint256 rLo, uint256 rHi) = rA.id < rB.id ? (rA.id, rB.id) : (rB.id, rA.id);

        CrossReenter reenter = new CrossReenter();
        address rBproxy = rollups.createCrossChainProxy(address(target), uint64(rB.id));
        bytes memory innerData = abi.encodeCall(SimpleTarget.setValue, (5));

        bytes memory outerData = abi.encodeCall(CrossReenter.reenter, (rBproxy, innerData));
        address topProxy = rollups.createCrossChainProxy(address(reenter), uint64(rA.id));

        // Built in a sub-frame to keep this test under the stack-depth limit under coverage instrumentation.
        ExecutionEntry[] memory entries = _reentrantDestEntry(rA.id, address(reenter), outerData, uint64(rB.id));

        ProofSystemBatchPerVerificationEntries memory b =
            _twoRollupBatch(rLo, rHi, entries, _emptyStaticEntries(), 0, 0);
        rollups.postAndVerifyBatch(b);

        (bool ok,) = topProxy.call(outerData);
        assertTrue(ok, "entry commits; the reentrant call reverted ReentrantDestinationNotVerified(rB)");
        assertEq(_getRollupState(rA.id), keccak256("s1"));
    }

    /// @notice A top-level `StaticExecutionEntry` carrying TWO `expectedRoots` pins (strictly increasing)
    ///         exercises the multi-pin validation loop and the multi-pin `_rootsMatch` scan, then
    ///         resolves successfully.
    function test_Validate_TopLevelStaticLookup_TwoPins() public {
        RollupHandle memory rA = _makeRollup(bytes32(0));
        RollupHandle memory rB = _makeRollup(bytes32(0));
        (uint256 rLo, uint256 rHi) = rA.id < rB.id ? (rA.id, rB.id) : (rB.id, rA.id);

        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(rLo));
        bytes memory cd = abi.encodeCall(SimpleTarget.getValue, ());
        bytes memory payload = abi.encode(uint256(321));
        bytes32 h = _ccHash(IS_STATIC, alice, MAINNET_ROLLUP_ID, address(target), uint64(rLo), 0, cd);

        StaticExecutionEntry memory lk;
        lk.proxyEntryHash = h;
        lk.destinationRollupId = uint64(rLo);
        lk.l2ToL1Calls = new L2ToL1Call[](0);
        lk.rollingHash = bytes32(0);
        lk.success = true;
        lk.returnData = payload;
        ExpectedRootPerRollup[] memory pins = new ExpectedRootPerRollup[](2);
        pins[0] = ExpectedRootPerRollup({rollupId: uint64(rLo), root: _getRollupState(rLo)});
        pins[1] = ExpectedRootPerRollup({rollupId: uint64(rHi), root: _getRollupState(rHi)});
        lk.expectedRoots = pins;
        StaticExecutionEntry[] memory lookups = new StaticExecutionEntry[](1);
        lookups[0] = lk;

        ProofSystemBatchPerVerificationEntries memory b = _twoRollupBatch(rLo, rHi, _emptyEntries(), lookups, 0, 0);
        rollups.postAndVerifyBatch(b);

        vm.prank(proxyAddr);
        bytes memory res = rollups.staticCrossChainCall(alice, cd);
        assertEq(res, payload);
    }

    /// @notice A batch carrying a non-empty `blobIndices` exercises the `blobhash(...)` loop in
    ///         `_verifyProofSystemBatch`. With no real blobs `blobhash(0)` returns 0; the line still runs
    ///         and the batch verifies (MockProofSystem accepts by default).
    function test_PostBatch_NonEmptyBlobIndices() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ProofSystemBatchPerVerificationEntries memory b = _stdBatch(r.id, _emptyEntries(), _emptyStaticEntries(), 0, 0);
        uint256[] memory blobs = new uint256[](1);
        blobs[0] = 0;
        b.blobIndices = blobs;
        rollups.postAndVerifyBatch(b);
        assertEq(rollups.lastVerifiedBlock(uint64(r.id)), block.number);
    }

    /// @notice Meta-hook path: an immediate static lookup is loaded into the transient pool
    ///         (`immediateStaticEntryCount > 0`), and a transient (meta-hook) entry consumed during the
    ///         hook fires a reentrant call resolved against the TRANSIENT `expectedL1ToL2Calls` table.
    function test_MetaHook_ImmediateStaticLookupAndTransientReentrant() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        MetaProxyCaller caller = new MetaProxyCaller(rollups);
        ReentrantForwarder fwd = new ReentrantForwarder();

        address innerTarget = L2_REMOTE;
        address reentrantProxy = rollups.createCrossChainProxy(innerTarget, uint64(r.id));
        bytes memory innerData = "";

        bytes memory outerData = abi.encodeCall(ReentrantForwarder.forward, (reentrantProxy, innerData));
        address topProxy = rollups.createCrossChainProxy(address(fwd), uint64(r.id));

        L2ToL1Call[] memory calls = _oneCall(_call(address(caller), uint64(r.id), address(fwd), 0, outerData));
        RollupUpdate[] memory deltas = _oneDelta(r.id, bytes32(0), keccak256("s1"), 0);

        bytes32 ah =
            _ccHash(NOT_STATIC_CALL, address(caller), MAINNET_ROLLUP_ID, address(fwd), uint64(r.id), 0, outerData);
        bytes32 cchTop =
            _ccHash(NOT_STATIC_CALL, address(caller), uint64(r.id), address(fwd), MAINNET_ROLLUP_ID, 0, outerData);
        bytes32 reentrantCch =
            _ccHash(NOT_STATIC_CALL, address(fwd), MAINNET_ROLLUP_ID, innerTarget, uint64(r.id), 0, innerData);

        // Built in a sub-frame to keep this test under the stack-depth limit under coverage instrumentation.
        (bytes32 h, ExpectedL1ToL2Call[] memory reentrant) =
            _metaReentrantTableAndHash(deltas, ah, cchTop, reentrantCch);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].proxyEntryHash = ah; // != 0 → leading L2Tx run stops, meta hook fires
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = reentrant;
        entries[0].rollingHash = h;

        StaticExecutionEntry[] memory lookups = new StaticExecutionEntry[](1);
        lookups[0] = _shellLookup(r.id); // pushed into the transient pool (immediateStaticEntryCount = 1)

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

    /// @notice Single-entry builder for `test_Reentrant_DestinationNotVerified`: a top-level call into
    ///         `reenter` whose reentrant call into `rB`'s proxy reverts `ReentrantDestinationNotVerified`.
    ///         Pulled out for stack-depth headroom.
    function _reentrantDestEntry(
        uint256 rAid,
        address reenter,
        bytes memory outerData,
        uint64 rBid
    )
        internal
        view
        returns (ExecutionEntry[] memory entries)
    {
        RollupUpdate[] memory deltas = _oneDelta(rAid, bytes32(0), keccak256("s1"), 0);
        L2ToL1Call[] memory calls = _oneCall(_call(address(this), uint64(rAid), reenter, 0, outerData));

        bytes32 ah = _ccHash(NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, reenter, uint64(rAid), 0, outerData);
        bytes32 cchTop = _ccHash(NOT_STATIC_CALL, address(this), uint64(rAid), reenter, MAINNET_ROLLUP_ID, 0, outerData);
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
    function _metaReentrantTableAndHash(
        RollupUpdate[] memory deltas,
        bytes32 ah,
        bytes32 cchTop,
        bytes32 reentrantCch
    )
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

    /// @notice A minimal `StaticExecutionEntry` pinned to `rid`'s live root; resolution reverts (`success == false`).
    function _shellLookup(uint256 rid) internal view returns (StaticExecutionEntry memory lc) {
        lc.proxyEntryHash = keccak256("h");
        lc.destinationRollupId = uint64(rid);
        lc.returnData = "";
        lc.success = false;
        lc.l2ToL1Calls = _emptyCalls();
        lc.rollingHash = bytes32(0);
        ExpectedRootPerRollup[] memory pins = new ExpectedRootPerRollup[](1);
        pins[0] = ExpectedRootPerRollup({rollupId: uint64(rid), root: _getRollupState(rid)});
        lc.expectedRoots = pins;
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
    function _postBatchOneAuto(RollupHandle memory r, ExecutionEntry[] memory entries, uint256 tc) internal {
        _postBatchOne(r, entries, _emptyStaticEntries(), tc, 0);
    }
}
