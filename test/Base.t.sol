// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../src/EEZ.sol";
import {Rollup} from "../src/rollupContract/Rollup.sol";
import {
    ExecutionEntry,
    StateUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    StaticExecutionEntry,
    ExpectedStateRootPerRollup
} from "../src/interfaces/IEEZ.sol";
import {MockProofSystem} from "./mocks/MockProofSystem.sol";
import {TestHashes} from "./TestHashes.sol";

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
///        4. Use `_postBatchOne(handle, entries, staticEntries, immediateEntryCount,
///           immediateStaticEntryCount)` to wrap a single sub-batch and post it.
///        5. Use the `_immediateEntry*` / `_empty*` builders for common shape primitives.
///        6. Use the `_h*` rolling-hash helpers (from `TestHashes`) to compute expected
///           `entry.rollingHash` values without hardcoding the tag formulas — they mirror
///           `EEZBase` exactly.
abstract contract Base is Test, TestHashes {
    EEZ internal rollups;
    MockProofSystem internal ps;

    address internal defaultOwner = makeAddr("defaultOwner");
    bytes32 internal constant DEFAULT_VK = bytes32(uint256(0x100));

    // ── Placeholder rollup-side actors (no code behind them) ──
    /// @notice Rollup-side source address of an L2→L1 call.
    address internal constant L2_SENDER = address(0xD00D);
    /// @notice Rollup-side contract fronted by an L1 cross-chain proxy.
    address internal constant L2_REMOTE = address(0xBEEF);

    /// @notice Per-test handle bundling the registered rollupId + its manager contract.
    struct RollupHandle {
        uint256 id;
        Rollup manager;
    }

    // ──────────────────────────────────────────────
    //  Setup
    // ──────────────────────────────────────────────

    function setUpBase() internal {
        rollups = new EEZ(makeAddr("recovery"));
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

    /// @notice `RollupIdWithProofSystems[1]` for `rid` selecting proof-system indices `0..nPs-1`.
    function _rpsOne(uint256 rid, uint256 nPs) internal pure returns (RollupIdWithProofSystems[] memory rps) {
        uint64[] memory idx = new uint64[](nPs);
        for (uint256 i = 0; i < nPs; i++) {
            idx[i] = uint64(i);
        }
        rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: uint64(rid), proofSystemIndexes: idx});
    }

    /// @notice Raw batch builder: every list is caller-supplied; `blockNumber = 0`, no pins,
    ///         no blobs, empty `callData`, submitter-unbound.
    function _raw(
        ExecutionEntry[] memory entries,
        StaticExecutionEntry[] memory staticEntries,
        address[] memory psList,
        bytes[] memory proofs,
        RollupIdWithProofSystems[] memory rps,
        uint256 immediateEntryCount,
        uint256 immediateStaticEntryCount
    )
        internal
        pure
        returns (ProofSystemBatchPerVerificationEntries memory b)
    {
        b.blockNumber = 0;
        b.entries = entries;
        b.staticEntries = staticEntries;
        b.immediateEntryCount = immediateEntryCount;
        b.immediateStaticEntryCount = immediateStaticEntryCount;
        b.proofSystems = psList;
        b.rollupIdsWithProofSystems = rps;
        b.blobIndices = new uint256[](0);
        b.callData = "";
        b.proofs = proofs;
    }

    /// @notice Default single-PS ([`ps`] + ["proof"]) batch keyed by a raw `rid`. Unlike
    ///         `_singleSubBatch` it needs no `RollupHandle`, so it can also target
    ///         unregistered ids (for validation-guard tests).
    function _stdBatch(
        uint256 rid,
        ExecutionEntry[] memory entries,
        StaticExecutionEntry[] memory staticEntries,
        uint256 immediateEntryCount,
        uint256 immediateStaticEntryCount
    )
        internal
        view
        returns (ProofSystemBatchPerVerificationEntries memory b)
    {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        b = _raw(
            entries, staticEntries, psList, proofs, _rpsOne(rid, 1), immediateEntryCount, immediateStaticEntryCount
        );
    }

    /// @notice Two-rollup single-PS batch (both rollups list the default `ps`). The ids are used
    ///         in the order given — pass them strictly increasing for a valid batch.
    function _twoRollupBatch(
        uint256 ridFirst,
        uint256 ridSecond,
        ExecutionEntry[] memory entries,
        StaticExecutionEntry[] memory staticEntries,
        uint256 immediateEntryCount,
        uint256 immediateStaticEntryCount
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
        rps[0] = RollupIdWithProofSystems({rollupId: uint64(ridFirst), proofSystemIndexes: idx});
        rps[1] = RollupIdWithProofSystems({rollupId: uint64(ridSecond), proofSystemIndexes: idx});
        b = _raw(entries, staticEntries, psList, proofs, rps, immediateEntryCount, immediateStaticEntryCount);
    }

    /// @notice Builds a single-PS / single-rollup `ProofSystemBatchPerVerificationEntries` using the default `ps`.
    function _singleSubBatch(
        RollupHandle memory r,
        ExecutionEntry[] memory entries,
        StaticExecutionEntry[] memory staticEntries,
        uint256 immediateEntryCount,
        uint256 immediateStaticEntryCount
    )
        internal
        view
        returns (ProofSystemBatchPerVerificationEntries memory batch)
    {
        batch = _stdBatch(r.id, entries, staticEntries, immediateEntryCount, immediateStaticEntryCount);
    }

    /// @notice Wraps a single batch for `r` and calls `rollups.postAndVerifyBatch`.
    function _postBatchOne(
        RollupHandle memory r,
        ExecutionEntry[] memory entries,
        StaticExecutionEntry[] memory staticEntries,
        uint256 immediateEntryCount,
        uint256 immediateStaticEntryCount
    )
        internal
    {
        ProofSystemBatchPerVerificationEntries memory batch = _singleSubBatch(
            r, entries, staticEntries, immediateEntryCount, immediateStaticEntryCount
        );
        rollups.postAndVerifyBatch(batch);
    }

    /// @notice Convenience: post a single-rollup batch with no static lookups. Auto-detects whether
    ///         the leading entry is immediate (`proxyEntryHash == 0`) and sets `immediateEntryCount`
    ///         accordingly.
    function _postBatchAutoTransient(RollupHandle memory r, ExecutionEntry[] memory entries) internal {
        uint256 tc = (entries.length > 0 && entries[0].proxyEntryHash == bytes32(0)) ? 1 : 0;
        _postBatchOne(r, entries, _emptyStaticEntries(), tc, 0);
    }

    /// @notice Posts a single-rollup batch whose whole `entries` prefix is immediate, carrying
    ///         `expectedStateRootPerRollup` pins (mismatch reverts `ExpectedStateRootMismatch`).
    function _postBatchWithPins(
        RollupHandle memory r,
        ExecutionEntry[] memory entries,
        ExpectedStateRootPerRollup[] memory pins
    )
        internal
    {
        ProofSystemBatchPerVerificationEntries memory batch =
            _singleSubBatch(r, entries, _emptyStaticEntries(), entries.length, 0);
        batch.expectedStateRootPerRollup = pins;
        rollups.postAndVerifyBatch(batch);
    }

    // ──────────────────────────────────────────────
    //  Entry / collection primitive builders
    // ──────────────────────────────────────────────

    function _emptyEntries() internal pure returns (ExecutionEntry[] memory arr) {
        arr = new ExecutionEntry[](0);
    }

    function _emptyStaticEntries() internal pure returns (StaticExecutionEntry[] memory arr) {
        arr = new StaticExecutionEntry[](0);
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
        returns (StateUpdate[] memory deltas)
    {
        deltas = new StateUpdate[](1);
        deltas[0] = StateUpdate({
            rollupId: uint64(rid), currentState: currentState, newState: newState, etherDelta: etherDelta
        });
    }

    /// @notice An immediate entry (`proxyEntryHash == 0`) transitioning `rid` from
    ///         `currentState` to `newState`, with no calls. `success = true`.
    function _immediateEntry(uint256 rid, bytes32 currentState, bytes32 newState)
        internal
        pure
        returns (ExecutionEntry memory entry)
    {
        entry.stateUpdates = _oneDelta(rid, currentState, newState, 0);
        entry.proxyEntryHash = bytes32(0);
        entry.destinationRollupId = uint64(rid);
        entry.l2ToL1Calls = _emptyCalls();
        entry.expectedL1ToL2Calls = _emptyReentrant();
        entry.rollingHash = _hEntryBegin(entry.stateUpdates, bytes32(0));
        entry.success = true;
        entry.returnData = "";
    }

    /// @notice An immediate entry with a single no-op state delta (`proxyEntryHash == 0`, empty
    ///         calls). The delta exists only so `destinationRollupId ∈ stateUpdates` (postBatch
    ///         requires it); entries built with this helper are not consumed, so the state values
    ///         are placeholders. Useful for tests that want to verify postAndVerifyBatch flow.
    function _emptyImmediateEntry(uint256 rid) internal pure returns (ExecutionEntry memory entry) {
        entry = _immediateEntry(rid, bytes32(0), bytes32(0));
    }

    /// @notice A "shell" entry: given deltas, default everything else (`proxyEntryHash = 0`,
    ///         no calls, `rollingHash = 0`, `success = true`); destination = `destRid`.
    function _shellEntry(uint256 destRid, StateUpdate[] memory deltas) internal pure returns (ExecutionEntry memory e) {
        e.stateUpdates = deltas;
        e.proxyEntryHash = bytes32(0);
        e.destinationRollupId = uint64(destRid);
        e.l2ToL1Calls = _emptyCalls();
        e.expectedL1ToL2Calls = _emptyReentrant();
        e.rollingHash = bytes32(0);
        e.success = true;
        e.returnData = "";
    }

    /// @notice Rolling hash for an entry with exactly one top-level call.
    function _oneCallHash(
        StateUpdate[] memory deltas,
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

    /// @notice Compact default-shape call: state-changing (`isStatic = false`), no forced revert.
    function _call(address src, uint64 srcRid, address tgt, uint256 value_, bytes memory data)
        internal
        pure
        returns (L2ToL1Call memory c)
    {
        c = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: src,
            sourceRollupId: srcRid,
            targetAddress: tgt,
            value: value_,
            data: data
        });
    }

    /// @notice Compact read-only call: dispatched via STATICCALL (`isStatic = true`, no value).
    function _staticCall(address src, uint64 srcRid, address tgt, bytes memory data)
        internal
        pure
        returns (L2ToL1Call memory c)
    {
        c = _call(src, srcRid, tgt, 0, data);
        c.isStatic = true;
    }

    /// @notice Wraps one call into a single-element array (the common `l2ToL1Calls` shape).
    function _oneCall(L2ToL1Call memory c) internal pure returns (L2ToL1Call[] memory arr) {
        arr = new L2ToL1Call[](1);
        arr[0] = c;
    }

    // ──────────────────────────────────────────────
    //  Assertion helpers
    // ──────────────────────────────────────────────

    /// @notice Asserts a raw revert payload `ret` begins with the 4-byte selector `expected`.
    function _assertRevertSelector(bytes memory ret, bytes4 expected) internal pure {
        assertGe(ret.length, 4, "revert data shorter than a selector");
        assertEq(bytes4(ret), expected, "unexpected revert selector");
    }

    /// @notice True when `logs` contains an event whose topic0 equals `selector`.
    function _findLog(Vm.Log[] memory logs, bytes32 selector) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == selector) {
                return true;
            }
        }
        return false;
    }

    // ──────────────────────────────────────────────
    //  Reentrant position-key helper
    // ──────────────────────────────────────────────

    /// @notice Mirror of `EEZBase._computeExpectedL1toL2Hash`: position key for a reentrant call.
    function _expectedL1toL2Hash(bytes32 crossChainCallHash, bytes32 rollingHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(crossChainCallHash, rollingHash));
    }
}
