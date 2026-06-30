// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {
    EEZ,
    RollupConfig,
    ProofSystemBatchPerVerificationEntries,
    RollupIdWithProofSystems,
    RollupVerification
} from "../src/EEZ.sol";
import {Rollup} from "../src/rollupContract/Rollup.sol";
import {IRollupContract} from "../src/interfaces/IRollup.sol";
import {IProofSystem} from "../src/interfaces/IProofSystem.sol";
import {
    ExecutionEntry,
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    StaticLookup,
    ExpectedStateRootPerRollup,
    ProxyInfo
} from "../src/interfaces/IEEZ.sol";
import {CrossChainProxy} from "../src/base/CrossChainProxy.sol";
import {MockProofSystem} from "./mocks/MockProofSystem.sol";

/// @notice Shared fixture for all `*.t.sol` tests touching the L1 `EEZ` registry.
/// @dev Sets up a `EEZ` instance + a default `MockProofSystem`, and exposes builders for
///      the most common operations: deploying a `Rollup` manager, registering it, posting a
///      single-PS / single-rollup `ProofSystemBatchPerVerificationEntries`, building immediate entries, and
///      computing rolling-hash event tags.
///
///      Tests should:
///        1. `is Base` (extend this contract).
///        2. Call `setUpBase()` from their own `setUp()`.
///        3. Use `_makeRollup(initialState)` to register a fresh rollup with the default
///           shape (1 proof system, threshold 1, owner = `defaultOwner`).
///        4. Use `_postBatchOne(handle, entries, staticLookups, immediateEntryCount,
///           immediateStaticLookupCount)` to wrap a single sub-batch and post it.
///        5. Use the `_immediateEntry*` / `_empty*` builders for common shape primitives.
///        6. Use the `_h*` rolling-hash helpers to compute expected `entry.rollingHash`
///           values without hardcoding the tag formulas — they mirror `EEZBase` exactly.
abstract contract Base is Test {
    EEZ internal rollups;
    MockProofSystem internal ps;

    address internal defaultOwner = makeAddr("defaultOwner");
    bytes32 internal constant DEFAULT_VK = bytes32(uint256(0x100));

    // ── Rolling hash tag constants (mirror EEZBase.sol) ──
    uint8 internal constant CALL_BEGIN = 1;
    uint8 internal constant CALL_END = 2;
    uint8 internal constant NESTED_BEGIN = 3;
    uint8 internal constant NESTED_END = 4;
    uint8 internal constant CALL_NOT_FOUND = 5;

    // ── Readable isStatic flags (mirror EEZBase.sol) ──
    bool internal constant NOT_STATIC_CALL = false;
    bool internal constant IS_STATIC = true;

    /// @notice Per-test handle bundling the registered rollupId + its manager contract.
    struct RollupHandle {
        uint256 id;
        Rollup manager;
    }

    // ──────────────────────────────────────────────
    //  Setup
    // ──────────────────────────────────────────────

    function setUpBase() internal {
        rollups = new EEZ();
        ps = new MockProofSystem();
    }

    // ──────────────────────────────────────────────
    //  Rollup factory helpers
    // ──────────────────────────────────────────────

    /// @notice Default-shape rollup: one PS (the shared `ps`), threshold 1, owner = defaultOwner.
    function _makeRollup(bytes32 initialState) internal returns (RollupHandle memory handle) {
        return _makeRollupWithOwner(initialState, defaultOwner);
    }

    /// @notice Default-shape rollup with a caller-specified owner (useful when the test
    ///         needs to call owner ops on the manager).
    function _makeRollupWithOwner(bytes32 initialState, address owner_) internal returns (RollupHandle memory handle) {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = DEFAULT_VK;
        handle.manager = new Rollup(address(rollups), owner_, 1, psList, vks);
        handle.id = rollups.registerRollup(address(handle.manager), initialState);
    }

    /// @notice Custom-shape rollup. Deploys a `Rollup` manager with the given PS/vkey/threshold/owner
    ///         and registers it in the central registry.
    function _makeRollupCustom(
        bytes32 initialState,
        address[] memory psList,
        bytes32[] memory vks,
        uint256 threshold,
        address owner_
    )
        internal
        returns (RollupHandle memory handle)
    {
        handle.manager = new Rollup(address(rollups), owner_, threshold, psList, vks);
        handle.id = rollups.registerRollup(address(handle.manager), initialState);
    }

    /// @notice Reads `rollups[rid].stateRoot`.
    function _getRollupState(uint256 rid) internal view returns (bytes32) {
        (, bytes32 stateRoot,) = rollups.rollups(uint64(rid));
        return stateRoot;
    }

    /// @notice Reads `rollups[rid].rollupContract`.
    function _getRollupContract(uint256 rid) internal view returns (address) {
        (address rc,,) = rollups.rollups(uint64(rid));
        return rc;
    }

    /// @notice Reads `rollups[rid].etherBalance`.
    function _getRollupEtherBalance(uint256 rid) internal view returns (uint256) {
        (,, uint256 etherBalance) = rollups.rollups(uint64(rid));
        return etherBalance;
    }

    /// @notice Direct write to the `etherBalance` slot of `rollups[rid]`.
    /// @dev Storage layout: EEZBase owns slot 0 (`authorizedProxies`). EEZ then has
    ///      `rollupCounter` at slot 1 and `mapping(rid => RollupConfig) rollups` at slot 2.
    ///      Mapping value slot = `keccak256(abi.encode(rid, 2))`. `RollupConfig` is
    ///      `{rollupContract, stateRoot, etherBalance}` at slot offsets 0, 1, 2, so
    ///      `etherBalance` lives at `keccak256(abi.encode(rid, 2)) + 2`. Also funds the
    ///      contract's actual ETH balance to keep accounting consistent.
    function _fundRollup(uint256 rid, uint256 amount) internal {
        bytes32 baseSlot = keccak256(abi.encode(uint64(rid), uint256(2)));
        bytes32 etherBalanceSlot = bytes32(uint256(baseSlot) + 2);
        vm.store(address(rollups), etherBalanceSlot, bytes32(amount));
        vm.deal(address(rollups), address(rollups).balance + amount);
    }

    // ──────────────────────────────────────────────
    //  ProofSystemBatchPerVerificationEntries builders
    // ──────────────────────────────────────────────

    /// @notice Builds a single-PS / single-rollup `ProofSystemBatchPerVerificationEntries` using the default `ps`.
    function _singleSubBatch(
        RollupHandle memory r,
        ExecutionEntry[] memory entries,
        StaticLookup[] memory staticLookups,
        uint256 immediateEntryCount,
        uint256 immediateStaticLookupCount
    )
        internal
        view
        returns (ProofSystemBatchPerVerificationEntries memory batch)
    {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";

        uint64[] memory psIdx = new uint64[](1);
        psIdx[0] = 0;
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: uint64(r.id), proofSystemIndexes: psIdx});

        batch = ProofSystemBatchPerVerificationEntries({
            expectedStateRootPerRollup: new ExpectedStateRootPerRollup[](0),
            blockNumber: 0,
            entries: entries,
            staticLookups: staticLookups,
            immediateEntryCount: immediateEntryCount,
            immediateStaticLookupCount: immediateStaticLookupCount,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
    }

    /// @notice Wraps a single batch for `r` and calls `rollups.postAndVerifyBatch`.
    function _postBatchOne(
        RollupHandle memory r,
        ExecutionEntry[] memory entries,
        StaticLookup[] memory staticLookups,
        uint256 immediateEntryCount,
        uint256 immediateStaticLookupCount
    )
        internal
    {
        ProofSystemBatchPerVerificationEntries memory batch = _singleSubBatch(
            r, entries, staticLookups, immediateEntryCount, immediateStaticLookupCount
        );
        rollups.postAndVerifyBatch(batch);
    }

    /// @notice Convenience: post a single-rollup batch with no static lookups. Auto-detects whether
    ///         the leading entry is immediate (`proxyEntryHash == 0`) and sets `immediateEntryCount`
    ///         accordingly.
    function _postBatchAutoTransient(RollupHandle memory r, ExecutionEntry[] memory entries) internal {
        uint256 tc = (entries.length > 0 && entries[0].proxyEntryHash == bytes32(0)) ? 1 : 0;
        _postBatchOne(r, entries, _emptyStaticLookups(), tc, 0);
    }

    // ──────────────────────────────────────────────
    //  Entry / collection primitive builders
    // ──────────────────────────────────────────────

    function _emptyEntries() internal pure returns (ExecutionEntry[] memory arr) {
        arr = new ExecutionEntry[](0);
    }

    function _emptyStaticLookups() internal pure returns (StaticLookup[] memory arr) {
        arr = new StaticLookup[](0);
    }

    function _emptyCalls() internal pure returns (L2ToL1Call[] memory arr) {
        arr = new L2ToL1Call[](0);
    }

    function _emptyReentrant() internal pure returns (ExpectedL1ToL2Call[] memory arr) {
        arr = new ExpectedL1ToL2Call[](0);
    }

    function _emptyPins() internal pure returns (ExpectedStateRootPerRollup[] memory arr) {
        arr = new ExpectedStateRootPerRollup[](0);
    }

    /// @notice A single-delta array transitioning `rid` from `currentState` to `newState`.
    function _oneDelta(uint256 rid, bytes32 currentState, bytes32 newState, int256 etherDelta)
        internal
        pure
        returns (StateDelta[] memory deltas)
    {
        deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: uint64(rid), currentState: currentState, newState: newState, etherDelta: etherDelta});
    }

    /// @notice An immediate entry (`proxyEntryHash == 0`) transitioning `rid` from
    ///         `currentState` to `newState`, with no calls. `success = true`.
    function _immediateEntry(uint256 rid, bytes32 currentState, bytes32 newState)
        internal
        pure
        returns (ExecutionEntry memory entry)
    {
        entry.stateDeltas = _oneDelta(rid, currentState, newState, 0);
        entry.proxyEntryHash = bytes32(0);
        entry.destinationRollupId = uint64(rid);
        entry.l2ToL1Calls = _emptyCalls();
        entry.expectedL1ToL2Calls = _emptyReentrant();
        entry.rollingHash = _hEntryBegin(entry.stateDeltas, bytes32(0));
        entry.success = true;
        entry.returnData = "";
    }

    /// @notice An immediate entry with a single no-op state delta (`proxyEntryHash == 0`, empty
    ///         calls). The delta exists only so `destinationRollupId ∈ stateDeltas` (postBatch
    ///         requires it); entries built with this helper are not consumed, so the state values
    ///         are placeholders. Useful for tests that want to verify postAndVerifyBatch flow.
    function _emptyImmediateEntry(uint256 rid) internal pure returns (ExecutionEntry memory entry) {
        entry = _immediateEntry(rid, bytes32(0), bytes32(0));
    }

    // ──────────────────────────────────────────────
    //  Cross-chain call hash helper (mirrors EEZBase.computeCrossChainCallHash)
    // ──────────────────────────────────────────────

    /// @notice Mirror of `EEZBase.computeCrossChainCallHash`. Field order:
    ///         isStatic → source(addr,rid) → target(addr,rid) → value → data.
    function _ccHash(
        bool isStatic,
        address sourceAddress,
        uint64 sourceRollupId,
        address targetAddress,
        uint64 targetRollupId,
        uint256 value_,
        bytes memory data
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(isStatic, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value_, data)
        );
    }

    /// @notice Mirror of `EEZBase._computeExpectedL1toL2Hash`: position key for a reentrant call.
    function _expectedL1toL2Hash(bytes32 crossChainCallHash, bytes32 rollingHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(crossChainCallHash, rollingHash));
    }

    // ──────────────────────────────────────────────
    //  Rolling hash helpers (mirror EEZBase.sol's tag scheme)
    // ──────────────────────────────────────────────

    /// @notice Mirror of `EEZBase._rollingHashEntryBegin`: folds the entry's starting state
    ///         (`(rollupId, currentState)` per delta) closed with `proxyEntryHash`.
    function _hEntryBegin(StateDelta[] memory deltas, bytes32 proxyEntryHash) internal pure returns (bytes32) {
        bytes32 statesHash;
        for (uint256 i = 0; i < deltas.length; i++) {
            statesHash = keccak256(abi.encodePacked(statesHash, deltas[i].rollupId, deltas[i].currentState));
        }
        return keccak256(abi.encodePacked(statesHash, proxyEntryHash));
    }

    function _hCallBegin(bytes32 prev, bytes32 crossChainCallHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, CALL_BEGIN, crossChainCallHash));
    }

    function _hCallEnd(bytes32 prev, bool success, bytes memory retData) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, CALL_END, success, retData));
    }

    function _hNestedBegin(bytes32 prev, bytes32 crossChainCallHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, NESTED_BEGIN, crossChainCallHash));
    }

    function _hNestedEnd(bytes32 prev) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, NESTED_END));
    }

    function _hCallNotFound(bytes32 prev, bytes32 crossChainCallHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, CALL_NOT_FOUND, crossChainCallHash));
    }

    /// @notice Mirror of `EEZBase._rollingHashStaticResult` (untagged static sub-call schema).
    function _hStatic(bytes32 prev, bool success, bytes memory retData) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, success, retData));
    }
}
