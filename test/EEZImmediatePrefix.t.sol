// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries} from "../src/EEZ.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {ExecutionEntry} from "../src/interfaces/IEEZ.sol";

contract EEZImmediatePrefixTest is Base {
    address internal proxy;
    bool internal hookRan;

    function setUp() public {
        setUpBase();
    }

    function executeMetaCrossChainTransactions() external {
        require(msg.sender == address(rollups), "only registry");
        hookRan = true;
        (bool ok,) = proxy.call("");
        require(ok, "proxy failed");
    }

    function _proxyEntry(
        uint256 rid,
        bytes32 beforeRoot,
        bytes32 afterRoot,
        address caller
    )
        internal
        returns (ExecutionEntry memory entry)
    {
        proxy = rollups.createCrossChainProxy(L2_REMOTE, uint64(rid));
        entry = _immediateEntry(rid, beforeRoot, afterRoot);
        entry.proxyEntryHash = rollups.computeCrossChainCallHash(false, caller, 0, L2_REMOTE, uint64(rid), 0, 0, "");
        entry.rollingHash = _hEntryBegin(entry.rollupUpdates, entry.proxyEntryHash);
    }

    function test_RejectsTruncatedLeadingL2TxPrefix() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(r.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _immediateEntry(r.id, bytes32(uint256(1)), bytes32(uint256(2)));
        for (uint256 count; count < 2; count++) {
            vm.expectRevert(EEZ.ImmediateCountStrandsLeadingL2Tx.selector);
            _postBatchOne(r, entries, _emptyStaticEntries(), count, 0);
        }
        assertEq(_getRollupState(r.id), bytes32(0));
        _postBatchOne(r, entries, _emptyStaticEntries(), 2, 0);
        assertEq(_getRollupState(r.id), bytes32(uint256(2)));
    }

    function test_ProxyFirstAllowsEOAPosterAndDeferredL2Tx() public {
        address caller = makeAddr("non-AA caller");
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _proxyEntry(r.id, bytes32(0), bytes32(uint256(1)), caller);
        entries[1] = _immediateEntry(r.id, bytes32(uint256(1)), bytes32(uint256(2)));
        ProofSystemBatchPerVerificationEntries memory batch = _stdBatch(r.id, entries, _emptyStaticEntries(), 0, 0);
        vm.prank(caller);
        rollups.postAndVerifyBatch(batch);
        assertEq(_getRollupState(r.id), bytes32(0));
        assertEq(rollups.queueLength(uint64(r.id)), 2);
        vm.prank(caller);
        (bool ok,) = proxy.call("");
        assertTrue(ok);
        rollups.executeL2Txs(uint64(r.id));
        assertEq(_getRollupState(r.id), bytes32(uint256(2)));
        assertFalse(hookRan);
    }

    function test_RestoresOriginalBoundaryCheckAfterProxy() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _proxyEntry(r.id, bytes32(0), bytes32(uint256(1)), address(this));
        entries[1] = _immediateEntry(r.id, bytes32(uint256(1)), bytes32(uint256(2)));
        vm.expectRevert(EEZ.ImmediateCountStrandsLeadingL2Tx.selector);
        _postBatchOne(r, entries, _emptyStaticEntries(), 1, 0);
        assertFalse(hookRan);
        assertEq(_getRollupState(r.id), bytes32(0));
    }

    function test_ImmediatePrefixLeavesDependentL2TxQueued() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](3);
        entries[0] = _immediateEntry(r.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _proxyEntry(r.id, bytes32(uint256(1)), bytes32(uint256(2)), address(this));
        entries[2] = _immediateEntry(r.id, bytes32(uint256(2)), bytes32(uint256(3)));
        _postBatchOne(r, entries, _emptyStaticEntries(), 1, 0);
        assertEq(_getRollupState(r.id), bytes32(uint256(1)));
        assertEq(rollups.queueLength(uint64(r.id)), 2);
        assertFalse(hookRan);
        (bool ok,) = proxy.call("");
        assertTrue(ok);
        rollups.executeL2Txs(uint64(r.id));
        assertEq(_getRollupState(r.id), bytes32(uint256(3)));
    }

    function test_SkippedImmediateEntryIsNotQueuedAgain() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(r.id, bytes32(uint256(99)), bytes32(uint256(1)));
        entries[1] = _immediateEntry(r.id, bytes32(0), bytes32(uint256(2)));
        _postBatchOne(r, entries, _emptyStaticEntries(), 2, 0);
        assertEq(_getRollupState(r.id), bytes32(uint256(2)));
        assertEq(rollups.queueLength(uint64(r.id)), 0);
        vm.expectRevert(EEZBase.ExecutionNotFound.selector);
        rollups.executeL2Txs(uint64(r.id));
    }

    function test_AllImmediateEntriesFailReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, bytes32(uint256(99)), bytes32(uint256(1)));
        vm.expectRevert(EEZ.AllImmediateL2TxsFailed.selector);
        _postBatchOne(r, entries, _emptyStaticEntries(), 1, 0);
        assertEq(rollups.lastVerifiedBlock(uint64(r.id)), 0);
        assertEq(_getRollupState(r.id), bytes32(0));
    }
}
