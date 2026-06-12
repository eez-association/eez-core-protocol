// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries} from "../src/EEZ.sol";
import {Rollup} from "../src/rollupContract/Rollup.sol";
import {ExecutionEntry} from "../src/interfaces/IEEZ.sol";

/// @notice Covers `ProofSystemBatchPerVerificationEntries.blockNumber`:
///         path coverage of `Rollup.getTimestampAndBlockHash` (0 / recent block /
///         `type(uint64).max` sentinel / `BlockHashUnavailable` reverts) AND the binding
///         guarantee — the returned (timestamp, blockHash) folds into `publicInputsHash`
///         exactly as `_verifyProofSystemBatch` computes it. The fold is asserted with a
///         pinned-hash `MockProofSystem`: the mock only accepts the exact hash the test
///         replicates off-band, so a successful post proves the registry computed it.
contract BlockNumberBindingTest is Base {
    RollupHandle internal r;

    bytes32 internal constant STATE0 = keccak256("state-0");
    bytes32 internal constant STATE1 = keccak256("state-1");

    function setUp() public {
        setUpBase();
        r = _makeRollup(STATE0);
    }

    // ──────────────────────────────────────────────
    //  Builders
    // ──────────────────────────────────────────────

    /// @notice Single-PS / single-rollup batch with one immediate entry, bound to `blockNumber`.
    function _batchWithBlockNumber(uint64 blockNumber)
        internal
        view
        returns (ProofSystemBatchPerVerificationEntries memory batch)
    {
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, STATE0, STATE1);
        batch = _singleSubBatch(r, entries, _emptyLookupCalls(), 1, 0);
        batch.blockNumber = blockNumber;
    }

    /// @notice Mirrors `_verifyProofSystemBatch`'s two-stage publicInputsHash for the
    ///         single-PS / single-rollup shape built by `_batchWithBlockNumber`.
    function _expectedPublicInputsHash(
        ProofSystemBatchPerVerificationEntries memory batch,
        uint256 timestamp,
        bytes32 blockHash
    )
        internal
        view
        returns (bytes32)
    {
        bytes32[] memory entryHashes = new bytes32[](batch.entries.length);
        for (uint256 i = 0; i < batch.entries.length; i++) {
            entryHashes[i] = keccak256(abi.encode(batch.entries[i]));
        }
        bytes32[] memory lookupCallHashes = new bytes32[](0);
        bytes32[] memory blobHashes = new bytes32[](0);

        bytes32 sharedPublicInput = keccak256(
            abi.encodePacked(
                abi.encode(entryHashes),
                abi.encode(lookupCallHashes),
                abi.encode(blobHashes),
                keccak256(batch.callData),
                batch.crossProofSystemInteractions
            )
        );

        bytes32 acc = keccak256(abi.encode(bytes32(0), r.id, DEFAULT_VK, blockHash, timestamp));
        return keccak256(abi.encodePacked(sharedPublicInput, acc));
    }

    function _assertEntryApplied() internal view {
        assertEq(_getRollupState(r.id), STATE1, "immediate entry should have applied");
    }

    // ──────────────────────────────────────────────
    //  Path coverage
    // ──────────────────────────────────────────────

    function test_RecentBlockNumber_Succeeds() public {
        vm.roll(1000);
        rollups.postAndVerifyBatch(_batchWithBlockNumber(999));
        assertEq(rollups.lastVerifiedBlock(r.id), block.number);
        _assertEntryApplied();
    }

    function test_LatestSentinel_Succeeds() public {
        vm.roll(500);
        rollups.postAndVerifyBatch(_batchWithBlockNumber(type(uint64).max));
        _assertEntryApplied();
    }

    function test_CurrentBlockNumber_Reverts() public {
        vm.roll(1000);
        ProofSystemBatchPerVerificationEntries memory batch = _batchWithBlockNumber(1000);
        vm.expectRevert(abi.encodeWithSelector(Rollup.BlockHashUnavailable.selector, uint64(1000)));
        rollups.postAndVerifyBatch(batch);
    }

    function test_FutureBlockNumber_Reverts() public {
        vm.roll(1000);
        ProofSystemBatchPerVerificationEntries memory batch = _batchWithBlockNumber(2000);
        vm.expectRevert(abi.encodeWithSelector(Rollup.BlockHashUnavailable.selector, uint64(2000)));
        rollups.postAndVerifyBatch(batch);
    }

    function test_OlderThan256Blocks_Reverts() public {
        vm.roll(1000); // blockhash window is [744, 999]
        ProofSystemBatchPerVerificationEntries memory batch = _batchWithBlockNumber(700);
        vm.expectRevert(abi.encodeWithSelector(Rollup.BlockHashUnavailable.selector, uint64(700)));
        rollups.postAndVerifyBatch(batch);
    }

    // ──────────────────────────────────────────────
    //  publicInputsHash binding
    // ──────────────────────────────────────────────

    function test_ZeroBlockNumber_BindsNoContext() public {
        ProofSystemBatchPerVerificationEntries memory batch = _batchWithBlockNumber(0);
        // 0 sentinel → manager returns (0, 0).
        ps.setExpectedPublicInputsHash(_expectedPublicInputsHash(batch, 0, bytes32(0)));
        rollups.postAndVerifyBatch(batch);
        _assertEntryApplied();
    }

    function test_BlockNumber_BindsRealBlockHash() public {
        vm.roll(1000);
        ProofSystemBatchPerVerificationEntries memory batch = _batchWithBlockNumber(990);
        bytes32 expectedBlockHash = blockhash(990);
        assertTrue(expectedBlockHash != bytes32(0), "fixture: blockhash(990) must resolve");
        // Specific-block path: timestamp is 0 (historical timestamps unrecoverable on-chain).
        ps.setExpectedPublicInputsHash(_expectedPublicInputsHash(batch, 0, expectedBlockHash));
        rollups.postAndVerifyBatch(batch);
        _assertEntryApplied();
    }

    function test_LatestSentinel_BindsTimestampAndPrevBlockHash() public {
        vm.roll(500);
        vm.warp(123_456);
        ProofSystemBatchPerVerificationEntries memory batch = _batchWithBlockNumber(type(uint64).max);
        ps.setExpectedPublicInputsHash(_expectedPublicInputsHash(batch, block.timestamp, blockhash(block.number - 1)));
        rollups.postAndVerifyBatch(batch);
        _assertEntryApplied();
    }

    /// @notice Non-vacuousness check for the pinned-hash tests: a batch bound to a different
    ///         block must produce a DIFFERENT publicInputsHash and fail verification.
    function test_DifferentBlockNumber_ChangesPublicInput() public {
        vm.roll(1000);
        ProofSystemBatchPerVerificationEntries memory batch = _batchWithBlockNumber(990);
        assertTrue(blockhash(990) != blockhash(991), "fixture: distinct block hashes required");
        // Pin the hash for block 991, then post a batch bound to 990.
        ps.setExpectedPublicInputsHash(_expectedPublicInputsHash(batch, 0, blockhash(991)));
        vm.expectRevert(EEZ.InvalidProof.selector);
        rollups.postAndVerifyBatch(batch);
    }
}
