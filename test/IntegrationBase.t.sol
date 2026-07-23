// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    EEZ,
    ProofSystemBatchPerVerificationEntries,
    ExpectedStateRootPerRollup,
    RollupIdWithProofSystems
} from "../src/EEZ.sol";
import {Rollup} from "../src/rollupContract/Rollup.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {ExecutionEntry, StateUpdate, StaticExecutionEntry} from "../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry
} from "../src/interfaces/IEEZL2.sol";
import {MockProofSystem} from "./mocks/MockProofSystem.sol";

/// @notice Shared dual-manager fixture for the `IntegrationTest*` suites.
/// @dev Deploys the L1 `EEZ` registry with one registered rollup (id = `L2_ROLLUP_ID`, managed
///      by a reference `Rollup` contract attested by a single `MockProofSystem`) plus the L2-side
///      `EEZL2` manager. Owns the shared constants, the cross-chain call hash + rolling-hash fold
///      helpers (mirroring `EEZBase`), the single-PS batch builder `_postBatchToL2`, the
///      system-address table loader `_loadL2Table`, and the empty-array builders.
///
///      Suites extend this contract, override `setUp`, call `super.setUp()`, then deploy their
///      own application contracts and proxies.
abstract contract IntegrationBase is Test {
    // ── L1 contracts ──
    EEZ public rollups;
    MockProofSystem public ps;
    Rollup public l2Manager; // per-rollup IRollupContract manager for L2_ROLLUP_ID

    // ── L2 contracts ──
    EEZL2 public managerL2;

    // ── Constants ──
    uint64 constant L2_ROLLUP_ID = 1;
    uint64 constant MAINNET_ROLLUP_ID = 0;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");
    /// @dev Initial state root the L2 rollup is registered with; entries consuming the rollup's
    ///      first transition pin it as their `currentState`.
    bytes32 constant L2_GENESIS_STATE = keccak256("l2-initial-state");

    // ── Rolling hash tag constants (must match EEZBase) ──
    uint8 constant CALL_BEGIN = 1;
    uint8 constant CALL_END = 2;
    uint8 constant NESTED_BEGIN = 3;
    uint8 constant NESTED_END = 4;

    // ── Actors ──
    address public alice = makeAddr("alice");

    function setUp() public virtual {
        // ── L1 infrastructure ──
        rollups = new EEZ(makeAddr("recovery"));
        ps = new MockProofSystem();

        // registerRollup pre-increments rollupCounter, so id 0 (MAINNET_ROLLUP_ID) is
        // skipped and the first registered rollup lands at id 1 = L2_ROLLUP_ID.
        {
            address[] memory psList = new address[](1);
            psList[0] = address(ps);
            bytes32[] memory vks = new bytes32[](1);
            vks[0] = DEFAULT_VK;
            l2Manager = new Rollup(address(rollups), address(this), 1, psList, vks);
            uint64 rid = rollups.registerRollup(address(l2Manager), L2_GENESIS_STATE);
            require(rid == L2_ROLLUP_ID, "expected L2_ROLLUP_ID = 1");
        }

        // ── L2 infrastructure ──
        managerL2 = new EEZL2(L2_ROLLUP_ID, SYSTEM_ADDRESS);
    }

    /// @notice Reads `rollups[rollupId].stateRoot`.
    function _getRollupState(uint64 rollupId) internal view returns (bytes32) {
        (, bytes32 stateRoot,) = rollups.rollups(rollupId);
        return stateRoot;
    }

    // ──────────────────────────────────────────────
    //  Batch / execution-table posting helpers
    // ──────────────────────────────────────────────

    /// @notice Wraps a single sub-batch (one PS attesting the L2 rollup) with no static entries
    ///         and no immediate prefix, and posts it.
    function _postBatchToL2(ExecutionEntry[] memory entries) internal {
        _postBatchToL2(entries, _emptyStaticEntries(), 0, 0);
    }

    /// @notice Same, with a leading immediate-entry prefix of `immediateEntryCount`.
    function _postBatchToL2(ExecutionEntry[] memory entries, uint256 immediateEntryCount) internal {
        _postBatchToL2(entries, _emptyStaticEntries(), immediateEntryCount, 0);
    }

    /// @notice Wraps a single sub-batch routed to the L2 rollup's queue and posts it.
    function _postBatchToL2(
        ExecutionEntry[] memory entries,
        StaticExecutionEntry[] memory staticEntries,
        uint256 immediateEntryCount,
        uint256 immediateStaticEntryCount
    )
        internal
    {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        uint64[] memory rids = new uint64[](1);
        rids[0] = L2_ROLLUP_ID;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](psList.length);
        for (uint256 _i = 0; _i < psList.length; _i++) {
            psIdx[_i] = uint64(_i);
        }
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](rids.length);
        for (uint256 _i = 0; _i < rids.length; _i++) {
            rps[_i] = RollupIdWithProofSystems({rollupId: rids[_i], proofSystemIndexes: psIdx});
        }

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            expectedStateRootPerRollup: new ExpectedStateRootPerRollup[](0),
            blockNumber: 0,
            bindMsgSenderInPublicInput: false,
            entries: entries,
            staticEntries: staticEntries,
            immediateEntryCount: immediateEntryCount,
            immediateStaticEntryCount: immediateStaticEntryCount,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
    }

    /// @notice Loads the L2 execution table as `SYSTEM_ADDRESS`.
    function _loadL2Table(L2ExecutionEntry[] memory entries, L2StaticExecutionEntry[] memory staticEntries) internal {
        vm.prank(SYSTEM_ADDRESS);
        managerL2.loadExecutionTable(entries, staticEntries);
    }

    // ──────────────────────────────────────────────
    //  Cross-chain call hash + rolling-hash helpers (mirror EEZBase's tag scheme)
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

    /// @notice Mirror of L1 `EEZBase._rollingHashEntryBegin`: folds the entry's starting state
    ///         (`(rollupId, currentState)` per delta) closed with `proxyEntryHash`.
    function _hEntryBegin(StateUpdate[] memory deltas, bytes32 proxyEntryHash) internal pure returns (bytes32) {
        bytes32 statesHash;
        for (uint256 i = 0; i < deltas.length; i++) {
            statesHash = keccak256(abi.encodePacked(statesHash, deltas[i].rollupId, deltas[i].currentState));
        }
        return keccak256(abi.encodePacked(statesHash, proxyEntryHash));
    }

    /// @notice Mirror of `EEZL2._seedRollingHash`: empty state-delta prefix (L2 has no state
    ///         deltas) closed with `proxyEntryHash`.
    function _hEntryBeginL2(bytes32 proxyEntryHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(0), proxyEntryHash));
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

    // ──────────────────────────────────────────────
    //  Empty-array builders
    // ──────────────────────────────────────────────

    /// @notice Empty L1 StaticExecutionEntry array (used by postAndVerifyBatch).
    function _emptyStaticEntries() internal pure returns (StaticExecutionEntry[] memory) {
        return new StaticExecutionEntry[](0);
    }

    /// @notice Empty L2 StaticExecutionEntry array (used by loadExecutionTable).
    function _emptyL2StaticEntries() internal pure returns (L2StaticExecutionEntry[] memory) {
        return new L2StaticExecutionEntry[](0);
    }
}
