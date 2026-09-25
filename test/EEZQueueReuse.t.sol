// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {EEZ} from "../src/EEZ.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {
    ExecutionEntry,
    StaticExecutionEntry,
    ExpectedRootPerRollup,
    ExpectedL1ToL2Call,
    RollupUpdate
} from "../src/interfaces/IEEZ.sol";

/// @notice Exposes retained storage so queue resets can be distinguished from deletion.
contract EEZQueueStorageHarness is EEZ {
    constructor() EEZ(address(0xCAFE)) {}

    function storedEntryHash(uint64 rid, uint256 index) external view returns (bytes32) {
        return keccak256(abi.encode(verificationByRollup[rid].entryQueue[index]));
    }

    function storedStaticEntryHash(uint64 rid, uint256 index) external view returns (bytes32) {
        return keccak256(abi.encode(verificationByRollup[rid].staticEntryQueue[index]));
    }

    function staticQueueLength(uint64 rid) external view returns (uint256) {
        return verificationByRollup[rid].staticEntryQueueIndex;
    }

    function transientQueueState() external view returns (uint256, uint256, uint256) {
        return (_transientEntriesLength, _transientStaticEntriesLength, _transientEntryIndex);
    }

    function storedTransientEntryHash(uint256 index) external view returns (bytes32) {
        return keccak256(abi.encode(_transientEntries[index]));
    }

    function storedTransientStaticEntryHash(uint256 index) external view returns (bytes32) {
        return keccak256(abi.encode(_transientStaticEntries[index]));
    }
}

contract EEZQueueReuseTest is Base {
    EEZQueueStorageHarness internal harness;
    address internal hookProxy;
    uint64 internal hookRollupId;
    uint256 internal hookLength;
    bool internal revertHook;

    function setUp() public {
        setUpBase();
        harness = new EEZQueueStorageHarness();
        rollups = harness;
    }

    function _queuedEntry(
        uint64 rid,
        uint256 key,
        bytes memory payload
    )
        internal
        view
        returns (ExecutionEntry memory entry)
    {
        entry = _immediateEntry(rid, bytes32(0), bytes32(0));
        entry.proxyEntryHash = _ccHash(NOT_STATIC_CALL, address(this), 0, L2_REMOTE, rid, 0, abi.encode(key));
        entry.rollingHash = _hEntryBegin(entry.rollupUpdates, entry.proxyEntryHash);
        entry.returnData = payload;
    }

    function _queuedStaticEntry(
        uint64 rid,
        uint256 key,
        bytes memory payload
    )
        internal
        view
        returns (StaticExecutionEntry memory entry)
    {
        entry.expectedRoots = new ExpectedRootPerRollup[](1);
        entry.expectedRoots[0] = ExpectedRootPerRollup({rollupId: rid, root: bytes32(0)});
        entry.proxyEntryHash = _ccHash(IS_STATIC, address(this), 0, L2_REMOTE, rid, 0, abi.encode(key));
        entry.destinationRollupId = rid;
        entry.l2ToL1Calls = _emptyCalls();
        entry.success = true;
        entry.returnData = payload;
    }

    function _assertCall(
        address proxy,
        uint256 key,
        bool isStatic,
        bool expectedSuccess,
        bytes memory expectedData
    )
        internal
    {
        bool success;
        bytes memory result;
        if (isStatic) {
            (success, result) = proxy.staticcall(abi.encode(key));
        } else {
            (success, result) = proxy.call(abi.encode(key));
        }
        assertEq(success, expectedSuccess);
        assertEq(result, expectedData);
    }

    function executeMetaCrossChainTransactions() external {
        assertEq(msg.sender, address(rollups));
        (uint256 entryLength, uint256 staticLength, uint256 cursor) = harness.transientQueueState();
        assertEq(entryLength, hookLength);
        assertEq(staticLength, hookLength);
        assertEq(cursor, 0);
        _assertCall(hookProxy, 0, true, true, abi.encode(uint256(0)));
        _assertCall(hookProxy, 0, false, true, abi.encode(uint256(0)));
        (entryLength, staticLength, cursor) = harness.transientQueueState();
        assertEq(entryLength, hookLength);
        assertEq(staticLength, hookLength);
        assertEq(cursor, 1);

        // Even a fully consumed transient queue must keep the batch reentry guard active.
        (bool reentered, bytes memory reason) = address(rollups)
            .call(
                abi.encodeCall(
                    EEZ.postAndVerifyBatch, (_stdBatch(hookRollupId, _emptyEntries(), _emptyStaticEntries(), 0, 0))
                )
            );
        assertFalse(reentered);
        assertEq(reason, abi.encodeWithSelector(EEZ.PostBatchReentry.selector));
        if (revertHook) revert("hook failed");
    }

    function _assertTransientCleared(uint256 previousLength) internal view {
        (uint256 entryLength, uint256 staticLength, uint256 cursor) = harness.transientQueueState();
        assertEq(entryLength, 0);
        assertEq(staticLength, 0);
        assertEq(cursor, 0);
        ExecutionEntry memory emptyEntry;
        StaticExecutionEntry memory emptyStaticEntry;
        for (uint256 i = 0; i < previousLength; i++) {
            assertEq(harness.storedTransientEntryHash(i), keccak256(abi.encode(emptyEntry)));
            assertEq(harness.storedTransientStaticEntryHash(i), keccak256(abi.encode(emptyStaticEntry)));
        }
    }

    function test_TransientMappingsDeleteUsedSlotsAndAllowAnotherBatch() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        hookRollupId = uint64(r.id);
        hookProxy = rollups.createCrossChainProxy(L2_REMOTE, hookRollupId);
        hookLength = 2;
        ExecutionEntry[] memory entries = new ExecutionEntry[](3);
        StaticExecutionEntry[] memory staticEntries = new StaticExecutionEntry[](3);
        for (uint256 i = 0; i < 3; i++) {
            entries[i] = _queuedEntry(hookRollupId, i, abi.encode(i));
            staticEntries[i] = _queuedStaticEntry(hookRollupId, i, abi.encode(i));
        }
        // The hook leaves slot 1 unconsumed. Cleanup must delete its nested arrays and long bytes too.
        bytes memory longData = new bytes(96);
        longData[95] = 0xff;
        entries[1].returnData = longData;
        entries[1].l2ToL1Calls = _oneCall(_call(L2_SENDER, hookRollupId, address(this), 0, longData));
        staticEntries[1].returnData = longData;
        staticEntries[1].l2ToL1Calls = _oneCall(_staticCall(L2_SENDER, hookRollupId, address(this), longData));

        _postBatchOne(r, entries, staticEntries, 2, 2);
        _assertTransientCleared(2);
        assertEq(rollups.queueLength(hookRollupId), 1);
        assertEq(harness.staticQueueLength(hookRollupId), 1);
        _assertCall(hookProxy, 2, false, true, abi.encode(uint256(2)));
        _assertCall(hookProxy, 2, true, true, abi.encode(uint256(2)));

        // Same transaction: lengths and cursor must already be reset, without waiting for tx end.
        hookLength = 1;
        entries = new ExecutionEntry[](1);
        staticEntries = new StaticExecutionEntry[](1);
        entries[0] = _queuedEntry(hookRollupId, 0, abi.encode(uint256(0)));
        staticEntries[0] = _queuedStaticEntry(hookRollupId, 0, abi.encode(uint256(0)));
        _postBatchOne(r, entries, staticEntries, 1, 1);
        _assertTransientCleared(2);
        assertEq(rollups.queueLength(hookRollupId), 0);
        assertEq(harness.staticQueueLength(hookRollupId), 0);
    }

    function test_RevertingHookRollsBackMappingsAndCounters() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        hookRollupId = uint64(r.id);
        hookProxy = rollups.createCrossChainProxy(L2_REMOTE, hookRollupId);
        hookLength = 1;
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        StaticExecutionEntry[] memory staticEntries = new StaticExecutionEntry[](1);
        entries[0] = _queuedEntry(hookRollupId, 0, abi.encode(uint256(0)));
        staticEntries[0] = _queuedStaticEntry(hookRollupId, 0, abi.encode(uint256(0)));
        _postBatchOne(r, entries, staticEntries, 0, 0);

        revertHook = true;
        vm.expectRevert(bytes("hook failed"));
        _postBatchOne(r, entries, staticEntries, 1, 1);
        _assertTransientCleared(1);
        assertEq(rollups.queueLength(hookRollupId), 1);
        assertEq(rollups.entryQueueIndex(hookRollupId), 0);
        assertEq(harness.staticQueueLength(hookRollupId), 1);
        _assertCall(hookProxy, 0, false, true, abi.encode(uint256(0)));
        _assertCall(hookProxy, 0, true, true, abi.encode(uint256(0)));
    }

    function test_ReplacementInSameBlock() public {
        _checkReplacement(false);
    }

    function test_ReplacementInNextBlock() public {
        _checkReplacement(true);
    }

    function _checkReplacement(bool nextBlock) internal {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        address proxy = rollups.createCrossChainProxy(L2_REMOTE, rid);
        ExecutionEntry[] memory entries = new ExecutionEntry[](3);
        StaticExecutionEntry[] memory staticEntries = new StaticExecutionEntry[](3);
        for (uint256 i = 0; i < 3; i++) {
            entries[i] = _queuedEntry(rid, i, abi.encode(i));
            staticEntries[i] = _queuedStaticEntry(rid, i, abi.encode(i));
        }
        _postBatchOne(r, entries, staticEntries, 0, 0);
        _assertCall(proxy, 0, false, true, abi.encode(uint256(0)));
        assertEq(rollups.entryQueueIndex(rid), 1);

        bytes32 retainedEntry = harness.storedEntryHash(rid, 2);
        bytes32 retainedStaticEntry = harness.storedStaticEntryHash(rid, 2);
        if (nextBlock) vm.roll(block.number + 1);

        entries = new ExecutionEntry[](1);
        staticEntries = new StaticExecutionEntry[](1);
        entries[0] = _queuedEntry(rid, 0, hex"aabb");
        staticEntries[0] = _queuedStaticEntry(rid, 0, hex"ccdd");
        _postBatchOne(r, entries, staticEntries, 0, 0);

        assertEq(rollups.queueLength(rid), 1);
        assertEq(rollups.entryQueueIndex(rid), 0);
        assertEq(harness.staticQueueLength(rid), 1);
        assertEq(harness.storedEntryHash(rid, 2), retainedEntry, "reset must retain unused entries");
        assertEq(harness.storedStaticEntryHash(rid, 2), retainedStaticEntry, "reset must retain unused static entries");

        // Old tail entries still match the live root and hash, but are outside the active bounds.
        bytes memory notFound = abi.encodeWithSelector(EEZBase.ExecutionNotFound.selector);
        _assertCall(proxy, 2, false, false, notFound);
        _assertCall(proxy, 2, true, false, notFound);
        _assertCall(proxy, 0, false, true, hex"aabb");
        _assertCall(proxy, 0, false, false, notFound);
        _assertCall(proxy, 0, true, true, hex"ccdd");
        _assertCall(proxy, 0, true, true, hex"ccdd"); // Static reads remain repeatable.

        bytes32 activeEntry = harness.storedEntryHash(rid, 0);
        bytes32 activeStaticEntry = harness.storedStaticEntryHash(rid, 0);
        _postBatchOne(r, _emptyEntries(), _emptyStaticEntries(), 0, 0);
        assertEq(rollups.queueLength(rid), 0);
        assertEq(rollups.entryQueueIndex(rid), 0);
        assertEq(harness.staticQueueLength(rid), 0);
        assertEq(harness.storedEntryHash(rid, 0), activeEntry);
        assertEq(harness.storedStaticEntryHash(rid, 0), activeStaticEntry);
        _assertCall(proxy, 0, false, false, notFound);
        _assertCall(proxy, 0, true, false, notFound);

        // Growing again must overwrite retained tail slots before exposing them.
        entries = new ExecutionEntry[](3);
        staticEntries = new StaticExecutionEntry[](3);
        for (uint256 i = 0; i < 3; i++) {
            entries[i] = _queuedEntry(rid, i + 10, abi.encode(i + 10));
            staticEntries[i] = _queuedStaticEntry(rid, i + 10, abi.encode(i + 10));
        }
        _postBatchOne(r, entries, staticEntries, 0, 0);
        _assertCall(proxy, 2, false, false, notFound);
        _assertCall(proxy, 2, true, false, notFound);
        _assertCall(proxy, 12, false, true, abi.encode(uint256(12)));
        assertEq(rollups.entryQueueIndex(rid), 3);
        _assertCall(proxy, 12, true, true, abi.encode(uint256(12)));
    }

    function test_ResetOnlyTouchesVerifiedRollup() public {
        RollupHandle memory a = _makeRollup(bytes32(0));
        RollupHandle memory b = _makeRollup(bytes32(0));
        address proxyB = rollups.createCrossChainProxy(L2_REMOTE, uint64(b.id));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        StaticExecutionEntry[] memory staticEntries = new StaticExecutionEntry[](2);
        entries[0] = _queuedEntry(uint64(a.id), 0, hex"aa");
        entries[1] = _queuedEntry(uint64(b.id), 0, hex"bb");
        staticEntries[0] = _queuedStaticEntry(uint64(a.id), 0, hex"cc");
        staticEntries[1] = _queuedStaticEntry(uint64(b.id), 0, hex"dd");
        rollups.postAndVerifyBatch(_twoRollupBatch(a.id, b.id, entries, staticEntries, 0, 0));

        _postBatchOne(a, _emptyEntries(), _emptyStaticEntries(), 0, 0);
        assertEq(rollups.queueLength(uint64(a.id)), 0);
        assertEq(harness.staticQueueLength(uint64(a.id)), 0);
        assertEq(rollups.queueLength(uint64(b.id)), 1);
        assertEq(harness.staticQueueLength(uint64(b.id)), 1);
        _assertCall(proxyB, 0, false, true, hex"bb");
        _assertCall(proxyB, 0, true, true, hex"dd");
    }

    function test_ReusedSlotsReplaceAllNestedData() public {
        RollupHandle memory a = _makeRollup(bytes32(0));
        RollupHandle memory b = _makeRollup(bytes32(0));
        uint64 rid = uint64(a.id);
        address proxy = rollups.createCrossChainProxy(L2_REMOTE, rid);
        bytes memory longData = new bytes(96);
        longData[95] = 0xff;
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        StaticExecutionEntry[] memory staticEntries = new StaticExecutionEntry[](1);
        entries[0] = _queuedEntry(rid, 0, longData);
        entries[0].rollupUpdates = new RollupUpdate[](2);
        entries[0].rollupUpdates[0] =
            RollupUpdate({rollupId: rid, etherDelta: 0, currentRoot: bytes32(0), newRoot: bytes32(0)});
        entries[0].rollupUpdates[1] =
            RollupUpdate({rollupId: uint64(b.id), etherDelta: 0, currentRoot: bytes32(0), newRoot: bytes32(0)});
        entries[0].l2ToL1Calls = _oneCall(_call(L2_SENDER, rid, address(this), 0, longData));
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](1);
        entries[0].expectedL1ToL2Calls[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: keccak256("old nested call"),
            l2ToL1Calls: entries[0].l2ToL1Calls,
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: longData
        });
        entries[0].success = false;
        staticEntries[0] = _queuedStaticEntry(rid, 0, longData);
        staticEntries[0].expectedRoots = new ExpectedRootPerRollup[](2);
        staticEntries[0].expectedRoots[0] = ExpectedRootPerRollup({rollupId: rid, root: bytes32(0)});
        staticEntries[0].expectedRoots[1] = ExpectedRootPerRollup({rollupId: uint64(b.id), root: bytes32(0)});
        staticEntries[0].l2ToL1Calls = _oneCall(_staticCall(L2_SENDER, rid, address(this), longData));
        staticEntries[0].success = false;
        rollups.postAndVerifyBatch(_twoRollupBatch(a.id, b.id, entries, staticEntries, 0, 0));

        entries[0] = _queuedEntry(rid, 1, hex"ab");
        staticEntries[0] = _queuedStaticEntry(rid, 1, hex"cd");
        _postBatchOne(a, entries, staticEntries, 0, 0);
        assertEq(harness.storedEntryHash(rid, 0), keccak256(abi.encode(entries[0])));
        assertEq(harness.storedStaticEntryHash(rid, 0), keccak256(abi.encode(staticEntries[0])));
        _assertCall(proxy, 1, false, true, hex"ab");
        _assertCall(proxy, 1, true, true, hex"cd");
    }
}
