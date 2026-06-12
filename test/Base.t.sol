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
    LookupCall,
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
///        4. Use `_postBatchOne(handle, entries, lookupCalls, transientCount,
///           transientLookupCallCount)` to wrap a single sub-batch and post it.
///        5. Use the `_immediateEntry*` / `_emptyEntries` / `_emptyLookupCalls` builders for
///           common shape primitives.
///        6. Use the `_h*` rolling-hash helpers to compute expected `entry.rollingHash`
///           values without hardcoding the tag formulas.
abstract contract Base is Test {
    EEZ internal rollups;
    MockProofSystem internal ps;

    address internal defaultOwner = makeAddr("defaultOwner");
    bytes32 internal constant DEFAULT_VK = bytes32(uint256(0x100));

    // ── Rolling hash tag constants (mirror EEZ.sol) ──
    uint8 internal constant CALL_BEGIN = 1;
    uint8 internal constant CALL_END = 2;
    uint8 internal constant NESTED_BEGIN = 3;
    uint8 internal constant NESTED_END = 4;

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
        (, bytes32 stateRoot,) = rollups.rollups(rid);
        return stateRoot;
    }

    /// @notice Reads `rollups[rid].rollupContract`.
    function _getRollupContract(uint256 rid) internal view returns (address) {
        (address rc,,) = rollups.rollups(rid);
        return rc;
    }

    /// @notice Reads `rollups[rid].etherBalance`.
    function _getRollupEtherBalance(uint256 rid) internal view returns (uint256) {
        (,, uint256 etherBalance) = rollups.rollups(rid);
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
        bytes32 baseSlot = keccak256(abi.encode(rid, uint256(2)));
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
        LookupCall[] memory lookupCalls,
        uint256 transientCount,
        uint256 transientLookupCallCount
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
        rps[0] = RollupIdWithProofSystems({rollupId: r.id, proofSystemIndex: psIdx});

        batch = ProofSystemBatchPerVerificationEntries({
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
    }

    /// @notice Wraps a single batch for `r` and calls `rollups.postAndVerifyBatch`.
    function _postBatchOne(
        RollupHandle memory r,
        ExecutionEntry[] memory entries,
        LookupCall[] memory lookupCalls,
        uint256 transientCount,
        uint256 transientLookupCallCount
    )
        internal
    {
        ProofSystemBatchPerVerificationEntries memory batch = _singleSubBatch(
            r, entries, lookupCalls, transientCount, transientLookupCallCount
        );
        rollups.postAndVerifyBatch(batch);
    }

    /// @notice Convenience: post a single-rollup batch with no lookup calls. Auto-detects whether
    ///         the leading entry is immediate (`proxyEntryHash == 0`) and sets `transientCount`
    ///         accordingly.
    function _postBatchAutoTransient(RollupHandle memory r, ExecutionEntry[] memory entries) internal {
        uint256 tc = (entries.length > 0 && entries[0].proxyEntryHash == bytes32(0)) ? 1 : 0;
        _postBatchOne(r, entries, _emptyLookupCalls(), tc, 0);
    }

    // ──────────────────────────────────────────────
    //  Entry / collection primitive builders
    // ──────────────────────────────────────────────

    function _emptyEntries() internal pure returns (ExecutionEntry[] memory arr) {
        arr = new ExecutionEntry[](0);
    }

    function _emptyLookupCalls() internal pure returns (LookupCall[] memory arr) {
        arr = new LookupCall[](0);
    }

    function _emptyCalls() internal pure returns (L2ToL1Call[] memory arr) {
        arr = new L2ToL1Call[](0);
    }

    function _emptyNested() internal pure returns (ExpectedL1ToL2Call[] memory arr) {
        arr = new ExpectedL1ToL2Call[](0);
    }

    /// @notice An immediate entry (`proxyEntryHash == 0`) transitioning `rid` from
    ///         `currentState` to `newState`, with no calls.
    function _immediateEntry(uint256 rid, bytes32 currentState, bytes32 newState)
        internal
        pure
        returns (ExecutionEntry memory entry)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rid, currentState: currentState, newState: newState, etherDelta: 0});
        entry.stateDeltas = deltas;
        entry.proxyEntryHash = bytes32(0);
        entry.destinationRollupId = rid;
        entry.l2ToL1Calls = _emptyCalls();
        entry.expectedL1ToL2Calls = _emptyNested();
        entry.callCount = 0;
        entry.returnData = "";
        entry.rollingHash = bytes32(0);
    }

    /// @notice An immediate entry with no state deltas at all (`proxyEntryHash == 0`,
    ///         empty deltas/calls). Useful for tests that want to verify
    ///         postAndVerifyBatch flow without state changes.
    function _emptyImmediateEntry(uint256 rid) internal pure returns (ExecutionEntry memory entry) {
        entry.stateDeltas = new StateDelta[](0);
        entry.proxyEntryHash = bytes32(0);
        entry.destinationRollupId = rid;
        entry.l2ToL1Calls = _emptyCalls();
        entry.expectedL1ToL2Calls = _emptyNested();
        entry.callCount = 0;
        entry.returnData = "";
        entry.rollingHash = bytes32(0);
    }

    // ──────────────────────────────────────────────
    //  Cross-chain call hash helper (mirrors EEZ.computeCrossChainCallHash)
    // ──────────────────────────────────────────────

    function _hashCall(
        uint256 targetRollupId,
        address targetAddress,
        uint256 value_,
        bytes memory data,
        address sourceAddress,
        uint256 sourceRollupId
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(targetRollupId, targetAddress, value_, data, sourceAddress, sourceRollupId));
    }

    // ──────────────────────────────────────────────
    //  Rolling hash helpers (mirror EEZ.sol's tag scheme)
    // ──────────────────────────────────────────────

    function _hCallBegin(bytes32 prev, uint256 callNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, CALL_BEGIN, callNumber));
    }

    function _hCallEnd(bytes32 prev, uint256 callNumber, bool success, bytes memory retData)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(prev, CALL_END, callNumber, success, retData));
    }

    function _hNestedBegin(bytes32 prev, uint256 nestedNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, NESTED_BEGIN, nestedNumber));
    }

    function _hNestedEnd(bytes32 prev, uint256 nestedNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, NESTED_END, nestedNumber));
    }

    /// @notice Rolling hash of a single successful top-level call returning `retData`.
    function _rollingHashSingleCall(bytes memory retData) internal pure returns (bytes32 h) {
        h = bytes32(0);
        h = _hCallBegin(h, 1);
        h = _hCallEnd(h, 1, true, retData);
    }
}
