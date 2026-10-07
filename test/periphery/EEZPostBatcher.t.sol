// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "../Base.t.sol";
import {EEZ} from "../../src/EEZ.sol";
import {EEZPostBatcher} from "../../src/periphery/EEZPostBatcher.sol";
import {ExecutionEntry, RollupUpdate, ProofSystemBatchPerVerificationEntries} from "../../src/interfaces/IEEZ.sol";

/// @dev Test-only callback implementation that consumes a transient entry through its proxy.
contract EEZPostBatcherCallbackHarness is EEZPostBatcher {
    address public immutable proxy;
    bool public callbackRan;
    bytes public callbackResult;

    constructor(EEZ eez_, address proxy_) EEZPostBatcher(eez_) {
        proxy = proxy_;
    }

    function executeMetaCrossChainTransactions() external override {
        if (msg.sender != address(eez)) revert OnlyEEZ();
        callbackRan = true;
        (bool success, bytes memory result) = proxy.call("");
        require(success, "transient proxy call failed");
        callbackResult = result;
    }
}

contract EEZPostBatcherTest is Base {
    EEZPostBatcher internal batcher;

    function setUp() public {
        setUpBase();
        batcher = new EEZPostBatcher(rollups);
    }

    function test_PostsSuccessfulImmediateEntries() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(r.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _immediateEntry(r.id, bytes32(uint256(1)), bytes32(uint256(2)));

        batcher.postBatch(this.buildBatch(r.id, entries, 2), true);

        assertEq(_getRollupState(r.id), bytes32(uint256(2)));
    }

    function test_DefaultEntryPointAcceptsOriginalEEZInterface() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(r.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _immediateEntry(r.id, bytes32(uint256(1)), bytes32(uint256(2)));

        // Call through the original EEZ type to exercise its exact ABI and selector.
        EEZ(address(batcher)).postAndVerifyBatch(this.buildBatch(r.id, entries, 2));

        assertEq(_getRollupState(r.id), bytes32(uint256(2)));
    }

    function test_DefaultEntryPointChecksRootsAndRollsBackOnMismatch() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(r.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _immediateEntry(r.id, bytes32(uint256(99)), bytes32(uint256(2)));
        ProofSystemBatchPerVerificationEntries memory batch = this.buildBatch(r.id, entries, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                EEZPostBatcher.LastImmediateRootMismatch.selector,
                uint64(r.id),
                bytes32(uint256(2)),
                bytes32(uint256(1))
            )
        );
        EEZ(address(batcher)).postAndVerifyBatch(batch);

        assertEq(_getRollupState(r.id), bytes32(0));
        assertEq(rollups.lastVerifiedBlock(uint64(r.id)), 0);
    }

    function test_ExecutesTransientImmediateEntryThroughBatcherCallback() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxy = rollups.createCrossChainProxy(L2_REMOTE, uint64(r.id));
        EEZPostBatcherCallbackHarness callbackBatcher = new EEZPostBatcherCallbackHarness(rollups, proxy);
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(r.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _immediateEntry(r.id, bytes32(uint256(1)), bytes32(uint256(2)));
        entries[1].proxyEntryHash =
            rollups.computeCrossChainCallHash(false, address(callbackBatcher), 0, L2_REMOTE, uint64(r.id), 0, 0, "");
        entries[1].rollingHash = _hEntryBegin(entries[1].rollupUpdates, entries[1].proxyEntryHash);
        entries[1].returnData = abi.encode(uint256(42));

        // Both entries are immediate. The nonzero proxy hash sends the second entry
        // through the transient table and the batcher's callback, with no persistent queue.
        callbackBatcher.postBatch(this.buildBatch(r.id, entries, 2), true);

        assertTrue(callbackBatcher.callbackRan());
        assertEq(callbackBatcher.callbackResult(), abi.encode(uint256(42)));
        assertEq(_getRollupState(r.id), bytes32(uint256(2)));
        assertEq(rollups.queueLength(uint64(r.id)), 0);
    }

    function test_MismatchRollsBackEarlierExecutionAndQueuePublication() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](3);
        entries[0] = _immediateEntry(r.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _immediateEntry(r.id, bytes32(uint256(99)), bytes32(uint256(2)));
        entries[2] = _metaEntry(r.id, bytes32(uint256(2)), bytes32(uint256(3)));
        ProofSystemBatchPerVerificationEntries memory batch = this.buildBatch(r.id, entries, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                EEZPostBatcher.LastImmediateRootMismatch.selector,
                uint64(r.id),
                bytes32(uint256(2)),
                bytes32(uint256(1))
            )
        );
        batcher.postBatch(batch, true);

        assertEq(_getRollupState(r.id), bytes32(0));
        assertEq(rollups.lastVerifiedBlock(uint64(r.id)), 0);
        assertEq(rollups.queueLength(uint64(r.id)), 0);
    }

    function test_DisabledCheckAllowsSkippedLastImmediateEntry() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(r.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _immediateEntry(r.id, bytes32(uint256(99)), bytes32(uint256(2)));

        batcher.postBatch(this.buildBatch(r.id, entries, 2), false);

        assertEq(_getRollupState(r.id), bytes32(uint256(1)));
    }

    function test_ChecksLastImmediateEntryInsteadOfLastBatchEntry() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(r.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _metaEntry(r.id, bytes32(uint256(1)), bytes32(uint256(2)));

        batcher.postBatch(this.buildBatch(r.id, entries, 1), true);

        assertEq(_getRollupState(r.id), bytes32(uint256(1)));
        assertEq(rollups.queueLength(uint64(r.id)), 1);
    }

    function test_NoImmediateEntriesRequiresNoRootCheck() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _metaEntry(r.id, bytes32(0), bytes32(uint256(1)));

        batcher.postBatch(this.buildBatch(r.id, entries, 0), true);

        assertEq(_getRollupState(r.id), bytes32(0));
        assertEq(rollups.queueLength(uint64(r.id)), 1);
    }

    function test_EmptyCallbackReturnsWithCheckDisabled() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _metaEntry(r.id, bytes32(0), bytes32(uint256(1)));

        batcher.postBatch(this.buildBatch(r.id, entries, 1), false);

        assertEq(_getRollupState(r.id), bytes32(0));
        assertEq(rollups.lastVerifiedBlock(uint64(r.id)), block.number);
    }

    function test_UnconsumedMetaEntryRevertsWithCheckEnabled() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _metaEntry(r.id, bytes32(0), bytes32(uint256(1)));
        ProofSystemBatchPerVerificationEntries memory batch = this.buildBatch(r.id, entries, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                EEZPostBatcher.LastImmediateRootMismatch.selector, uint64(r.id), bytes32(uint256(1)), bytes32(0)
            )
        );
        batcher.postBatch(batch, true);

        assertEq(rollups.lastVerifiedBlock(uint64(r.id)), 0);
    }

    function test_ChecksEveryRollupInLastImmediateEntry() public {
        RollupHandle memory first = _makeRollup(bytes32(0));
        RollupHandle memory second = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(first.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _immediateEntry(first.id, bytes32(uint256(1)), bytes32(uint256(1)));
        entries[1].rollupUpdates = new RollupUpdate[](2);
        entries[1].rollupUpdates[0] = RollupUpdate(uint64(first.id), 0, bytes32(uint256(1)), bytes32(uint256(1)));
        entries[1].rollupUpdates[1] = RollupUpdate(uint64(second.id), 0, bytes32(uint256(99)), bytes32(uint256(2)));
        entries[1].rollingHash = _hEntryBegin(entries[1].rollupUpdates, bytes32(0));
        ProofSystemBatchPerVerificationEntries memory batch = this.buildTwoRollupBatch(first.id, second.id, entries);

        vm.expectRevert(
            abi.encodeWithSelector(
                EEZPostBatcher.LastImmediateRootMismatch.selector, uint64(second.id), bytes32(uint256(2)), bytes32(0)
            )
        );
        batcher.postBatch(batch, true);

        assertEq(_getRollupState(first.id), bytes32(0));
        assertEq(_getRollupState(second.id), bytes32(0));
    }

    function test_PropagatesEEZBatchValidationErrors() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ProofSystemBatchPerVerificationEntries memory batch = this.buildBatch(r.id, _emptyEntries(), 1);

        vm.expectRevert(EEZ.ImmediateCountExceedsEntries.selector);
        batcher.postBatch(batch, true);
    }

    function test_CallbackOnlyAcceptsEEZ() public {
        vm.expectRevert(EEZPostBatcher.OnlyEEZ.selector);
        batcher.executeMetaCrossChainTransactions();
    }

    // External fixture builders keep the deeply nested batch ABI separate from test setup
    // to avoid a solc via-IR stack-depth failure when the shared builders are inlined.
    function buildBatch(
        uint256 rid,
        ExecutionEntry[] memory entries,
        uint256 immediateEntryCount
    )
        external
        view
        returns (ProofSystemBatchPerVerificationEntries memory)
    {
        return _stdBatch(rid, entries, _emptyStaticEntries(), immediateEntryCount, 0);
    }

    function buildTwoRollupBatch(
        uint256 first,
        uint256 second,
        ExecutionEntry[] memory entries
    )
        external
        view
        returns (ProofSystemBatchPerVerificationEntries memory)
    {
        return _twoRollupBatch(first, second, entries, _emptyStaticEntries(), 2, 0);
    }

    function _metaEntry(
        uint256 rid,
        bytes32 beforeRoot,
        bytes32 afterRoot
    )
        internal
        pure
        returns (ExecutionEntry memory entry)
    {
        entry = _immediateEntry(rid, beforeRoot, afterRoot);
        entry.proxyEntryHash = keccak256("meta entry");
        entry.rollingHash = _hEntryBegin(entry.rollupUpdates, entry.proxyEntryHash);
    }
}
