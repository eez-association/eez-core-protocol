// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {EEZ} from "../src/EEZ.sol";
import {ExecutionEntry} from "../src/interfaces/IEEZ.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Checks the coordinates a consumer must reconstruct from decoded batch inputs.
contract ExecutionLogReconstructionTest is Base {
    address internal metaProxy;

    function setUp() public {
        setUpBase();
    }

    function executeMetaCrossChainTransactions() external {
        require(msg.sender == address(rollups), "only manager");
        (bool ok,) = metaProxy.call("");
        require(ok, "meta call failed");
    }

    function test_ImmediateCompletionUsesInputOrderBecauseBothIndicesAreZero() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(r.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _immediateEntry(r.id, bytes32(uint256(1)), bytes32(uint256(2)));

        vm.recordLogs();
        _postBatchOne(r, entries, _emptyStaticEntries(), 2, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 completionCount;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(rollups) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != EEZ.EntryExecuted.selector) continue;
            assertEq(uint256(logs[i].topics[1]), 0, "immediate index is local, not original");
            bytes32 rollingHash = abi.decode(logs[i].data, (bytes32));
            assertLt(completionCount, entries.length);
            assertEq(rollingHash, entries[completionCount].rollingHash);
            completionCount++;
        }
        assertEq(completionCount, 2);
    }

    function test_InterleavedDeferredQueuesNeedPostingInputForOriginalIndices() public {
        RollupHandle memory first = _makeRollup(bytes32(0));
        RollupHandle memory second = _makeRollup(bytes32(0));
        address firstProxy = rollups.createCrossChainProxy(L2_REMOTE, uint64(first.id));
        address secondProxy = rollups.createCrossChainProxy(L2_REMOTE, uint64(second.id));
        ExecutionEntry[] memory entries = new ExecutionEntry[](3);
        entries[0] = _deferredProxyEntry(first.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _deferredProxyEntry(second.id, bytes32(0), bytes32(uint256(2)));
        entries[2] = _deferredProxyEntry(first.id, bytes32(uint256(1)), bytes32(uint256(3)));

        rollups.postAndVerifyBatch(_twoRollupBatch(first.id, second.id, entries, _emptyStaticEntries(), 0, 0));
        vm.recordLogs();
        (bool okFirst,) = firstProxy.call("");
        assertTrue(okFirst);
        (bool okSecond,) = secondProxy.call("");
        assertTrue(okSecond);
        (bool okThird,) = firstProxy.call("");
        assertTrue(okThird);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256[] memory expectedOriginal = new uint256[](3);
        expectedOriginal[0] = 0;
        expectedOriginal[1] = 1;
        expectedOriginal[2] = 2;
        uint256 seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(rollups) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != EEZ.ExecutionConsumed.selector) continue;
            assertLt(seen, expectedOriginal.length);
            uint256 originalIndex = expectedOriginal[seen]; // decoded batch routing: [first, second, first]
            assertEq(uint256(logs[i].topics[2]), entries[originalIndex].destinationRollupId);
            assertEq(uint256(logs[i].topics[3]), originalIndex == 2 ? 1 : 0);
            seen++;
        }
        assertEq(seen, 3);
        assertEq(_getRollupState(first.id), bytes32(uint256(3)));
        assertEq(_getRollupState(second.id), bytes32(uint256(2)));
    }

    function test_MetaSuffixIndexNeedsImmediatePrefixOffset() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        metaProxy = rollups.createCrossChainProxy(L2_REMOTE, uint64(r.id));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(r.id, bytes32(0), bytes32(uint256(1)));
        entries[1] = _deferredProxyEntry(r.id, bytes32(uint256(1)), bytes32(uint256(2)));

        vm.recordLogs();
        _postBatchOne(r, entries, _emptyStaticEntries(), 2, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 completions;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(rollups) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != EEZ.EntryExecuted.selector) continue;
            assertEq(uint256(logs[i].topics[1]), 0, "both phases report local index zero");
            bytes32 rollingHash = abi.decode(logs[i].data, (bytes32));
            assertLt(completions, entries.length);
            assertEq(rollingHash, entries[completions].rollingHash);
            completions++;
        }
        assertEq(completions, 2);
    }

    function _deferredProxyEntry(
        uint256 rid,
        bytes32 beforeRoot,
        bytes32 afterRoot
    )
        internal
        view
        returns (ExecutionEntry memory entry)
    {
        entry = _immediateEntry(rid, beforeRoot, afterRoot);
        entry.proxyEntryHash =
            rollups.computeCrossChainCallHash(false, address(this), 0, L2_REMOTE, uint64(rid), 0, 0, "");
        entry.rollingHash = _hEntryBegin(entry.rollupUpdates, entry.proxyEntryHash);
    }
}
