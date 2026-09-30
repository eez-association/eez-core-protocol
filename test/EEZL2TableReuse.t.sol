// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseL2} from "./BaseL2.t.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {
    ExecutionEntry,
    StaticExecutionEntryL2,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../src/interfaces/IEEZL2.sol";

contract EEZL2TableStorageHarness is EEZL2 {
    constructor(uint64 rollupId, address system) EEZL2(rollupId, system, false, system) {}

    function storedEntryHash(uint256 index) external view returns (bytes32) {
        return keccak256(abi.encode(entries[index]));
    }

    function storedStaticEntryHash(uint256 index) external view returns (bytes32) {
        return keccak256(abi.encode(staticEntries[index]));
    }
}

contract EEZL2TableReuseTest is BaseL2 {
    EEZL2TableStorageHarness internal harness;
    address internal proxy;
    address internal constant REMOTE = address(0xABCD);
    address internal constant RECIPIENT = address(0xBEEF);

    function setUp() public override {
        harness = new EEZL2TableStorageHarness(TEST_ROLLUP_ID, SYSTEM_ADDRESS);
        manager = harness;
        proxy = manager.createCrossChainProxy(REMOTE, REMOTE_ROLLUP_ID);
        vm.deal(SYSTEM_ADDRESS, 10 ether);
    }

    function _key(uint256 n, bool isStatic) internal view returns (bytes32) {
        return _ccHash(isStatic, address(this), TEST_ROLLUP_ID, REMOTE, REMOTE_ROLLUP_ID, 0, abi.encode(n));
    }

    function _tables(uint256 count)
        internal
        view
        returns (ExecutionEntry[] memory rows, StaticExecutionEntryL2[] memory statics)
    {
        rows = new ExecutionEntry[](count);
        statics = new StaticExecutionEntryL2[](count);
        for (uint256 i; i < count; i++) {
            rows[i] = _buildNoCalls(_key(i, false), abi.encode(i));
            statics[i].proxyEntryHash = _key(i, true);
            statics[i].incomingCalls = new CrossChainCall[](0);
            statics[i].success = true;
            statics[i].returnData = abi.encode(i);
        }
    }

    function _assertCall(uint256 n, bool isStatic, bool expectedSuccess, bytes memory expectedData) internal {
        bool success;
        bytes memory data;
        if (isStatic) (success, data) = proxy.staticcall(abi.encode(n));
        else (success, data) = proxy.call(abi.encode(n));
        assertEq(success, expectedSuccess);
        assertEq(data, expectedData);
    }

    function _assertMissing(uint256 n, bool isStatic) internal {
        _assertCall(
            n, isStatic, false, abi.encodeWithSelector(EEZL2.EntryNotFound.selector, _key(n, isStatic), uint64(0))
        );
    }

    function _replacement(bool nextBlock) internal {
        (ExecutionEntry[] memory rows, StaticExecutionEntryL2[] memory statics) = _tables(3);
        _loadEntries(rows, statics);
        bytes32 retained = harness.storedEntryHash(2);
        bytes32 retainedStatic = harness.storedStaticEntryHash(2);
        _assertCall(0, false, true, abi.encode(uint256(0)));
        assertEq(manager.entryIndex(), 1);
        if (nextBlock) {
            vm.roll(block.number + 1);
            _assertCall(1, false, false, abi.encodeWithSelector(EEZL2.ExecutionNotInCurrentBlock.selector));
        }

        (rows, statics) = _tables(1);
        rows[0] = _buildNoCalls(_key(9, false), abi.encode(uint256(99)));
        statics[0].proxyEntryHash = _key(9, true);
        statics[0].returnData = abi.encode(uint256(99));
        _loadEntries(rows, statics);
        assertEq(manager.entriesLength(), 1);
        assertEq(manager.staticEntriesLength(), 1);
        assertEq(manager.entryIndex(), 0);
        assertEq(manager.lastLoadBlock(), block.number);
        assertEq(harness.storedEntryHash(2), retained);
        assertEq(harness.storedStaticEntryHash(2), retainedStatic);
        _assertMissing(0, false);
        _assertMissing(2, false);
        _assertMissing(2, true);
        _assertCall(9, true, true, abi.encode(uint256(99)));
        _assertCall(9, false, true, abi.encode(uint256(99)));
        assertEq(manager.entryIndex(), 1);
        _assertMissing(9, false);
    }

    function test_ReplacementInSameBlockHidesRetainedRows() public {
        _replacement(false);
    }

    function test_ReplacementInNextBlockRefreshesGateAndHidesRetainedRows() public {
        _replacement(true);
    }

    function test_EmptyReplacementRetainsStorageAndFundingButDisablesBothTables() public {
        (ExecutionEntry[] memory rows, StaticExecutionEntryL2[] memory statics) = _tables(2);
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable{value: 2 ether}(rows, statics);
        bytes32 retained = harness.storedEntryHash(0);
        bytes32 retainedStatic = harness.storedStaticEntryHash(1);
        _loadEntries(new ExecutionEntry[](0), new StaticExecutionEntryL2[](0));
        assertEq(manager.entriesLength(), 0);
        assertEq(manager.staticEntriesLength(), 0);
        assertEq(manager.entryIndex(), 0);
        assertEq(address(manager).balance, 2 ether);
        assertEq(harness.storedEntryHash(0), retained);
        assertEq(harness.storedStaticEntryHash(1), retainedStatic);
        _assertMissing(0, false);
        _assertMissing(1, true);
    }

    function test_ReusedSlotsReplaceAllNestedDataAndShortenBytes() public {
        (ExecutionEntry[] memory rows, StaticExecutionEntryL2[] memory statics) = _tables(1);
        rows[0].incomingCalls = new CrossChainCall[](2);
        rows[0].incomingCalls[0] = _cc(RECIPIENT, 7, new bytes(96), REMOTE, REMOTE_ROLLUP_ID);
        rows[0].incomingCalls[1] = rows[0].incomingCalls[0];
        rows[0].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](2);
        for (uint256 i; i < 2; i++) {
            rows[0].expectedOutgoingCalls[i].expectedOutgoingHash = bytes32(i + 1);
            rows[0].expectedOutgoingCalls[i].incomingCalls = rows[0].incomingCalls;
            rows[0].expectedOutgoingCalls[i].returnData = new bytes(96);
        }
        rows[0].returnData = new bytes(96);
        statics[0].incomingCalls = rows[0].incomingCalls;
        statics[0].returnData = new bytes(96);
        _loadEntries(rows, statics);

        rows[0].incomingCalls = new CrossChainCall[](1);
        rows[0].incomingCalls[0] = _cc(REMOTE, 3, hex"123456", RECIPIENT, MAINNET);
        rows[0].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](1);
        rows[0].expectedOutgoingCalls[0].incomingCalls = rows[0].incomingCalls;
        rows[0].expectedOutgoingCalls[0].returnData = hex"ab";
        rows[0].returnData = hex"cd";
        rows[0].success = false;
        statics[0].incomingCalls = rows[0].incomingCalls;
        statics[0].returnData = hex"ef";
        statics[0].expectedEntryIndex = 3;
        _loadEntries(rows, statics);
        assertEq(harness.storedEntryHash(0), keccak256(abi.encode(rows[0])));
        assertEq(harness.storedStaticEntryHash(0), keccak256(abi.encode(statics[0])));

        (rows, statics) = _tables(1);
        _loadEntries(rows, statics);
        assertEq(harness.storedEntryHash(0), keccak256(abi.encode(rows[0])));
        assertEq(harness.storedStaticEntryHash(0), keccak256(abi.encode(statics[0])));
        _assertCall(0, true, true, abi.encode(uint256(0)));
        _assertCall(0, false, true, abi.encode(uint256(0)));
    }

    function _failedDelivery(bool terminalRevert) internal {
        (ExecutionEntry[] memory oldRows, StaticExecutionEntryL2[] memory oldStatics) = _tables(2);
        oldStatics[0].expectedEntryIndex = 1;
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable{value: 2 ether}(oldRows, oldStatics);
        _assertCall(0, false, true, abi.encode(uint256(0)));
        uint256 loadBlock = manager.lastLoadBlock();
        uint256 systemBalance = SYSTEM_ADDRESS.balance;
        uint256 recipientBalance = RECIPIENT.balance;
        vm.roll(loadBlock + 1);

        CrossChainCall memory call = _cc(RECIPIENT, 1 ether, "", REMOTE, REMOTE_ROLLUP_ID);
        bytes32 inboundHash = _incomingCallHash(call);
        ExecutionEntry[] memory incoming = new ExecutionEntry[](1);
        incoming[0] = _buildSimpleEntry(inboundHash, call, hex"1234", _rhSingle(inboundHash, call, true, ""));
        if (terminalRevert) incoming[0].success = false;
        else incoming[0].rollingHash = bytes32(uint256(123));
        if (terminalRevert) vm.expectRevert(bytes(hex"1234"));
        else vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall{value: 0.5 ether}(incoming, new StaticExecutionEntryL2[](0));

        assertEq(manager.entriesLength(), 2);
        assertEq(manager.staticEntriesLength(), 2);
        assertEq(manager.entryIndex(), 1);
        assertEq(manager.lastLoadBlock(), loadBlock);
        assertEq(address(manager).balance, 2 ether);
        assertEq(SYSTEM_ADDRESS.balance, systemBalance);
        assertEq(RECIPIENT.balance, recipientBalance);
        assertEq(harness.storedEntryHash(0), keccak256(abi.encode(oldRows[0])));
        assertEq(harness.storedEntryHash(1), keccak256(abi.encode(oldRows[1])));
        assertEq(harness.storedStaticEntryHash(0), keccak256(abi.encode(oldStatics[0])));
        vm.roll(loadBlock);
        _assertCall(0, true, true, abi.encode(uint256(0)));
        _assertCall(1, false, true, abi.encode(uint256(1)));
    }

    function test_FailedHashValidationRestoresTablesCursorBlockAndBalances() public {
        _failedDelivery(false);
    }

    function test_TerminalIncomingRevertRestoresTablesCursorBlockAndBalances() public {
        _failedDelivery(true);
    }

    function test_SuccessfulIncomingReplacementLeavesOnlyItsFollowupRowsActive() public {
        (ExecutionEntry[] memory rows, StaticExecutionEntryL2[] memory statics) = _tables(3);
        _loadEntries(rows, statics);
        (rows, statics) = _tables(2);
        CrossChainCall memory call = _cc(RECIPIENT, 1 ether, "", REMOTE, REMOTE_ROLLUP_ID);
        bytes32 inboundHash = _incomingCallHash(call);
        rows[0] = _buildSimpleEntry(inboundHash, call, "", _rhSingle(inboundHash, call, true, ""));
        statics[0].expectedEntryIndex = 1;
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall{value: 1 ether}(rows, statics);
        assertEq(manager.entriesLength(), 2);
        assertEq(manager.staticEntriesLength(), 2);
        assertEq(manager.entryIndex(), 1);
        assertEq(RECIPIENT.balance, 1 ether);
        _assertMissing(2, false);
        _assertMissing(2, true);
        _assertCall(0, true, true, abi.encode(uint256(0)));
        _assertCall(1, false, true, abi.encode(uint256(1)));
    }

    function _emptyReplacementGas(uint256 oldSize) internal returns (uint256 used) {
        (ExecutionEntry[] memory rows, StaticExecutionEntryL2[] memory statics) = _tables(oldSize);
        _loadEntries(rows, statics);
        rows = new ExecutionEntry[](0);
        statics = new StaticExecutionEntryL2[](0);
        vm.prank(SYSTEM_ADDRESS);
        uint256 before = gasleft();
        manager.loadExecutionTable(rows, statics);
        used = before - gasleft();
    }

    function test_EmptyReplacementCostDoesNotGrowWithPreviousTableSize() public {
        uint256 snapshot = vm.snapshotState();
        uint256 small = _emptyReplacementGas(1);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        uint256 large = _emptyReplacementGas(32);
        assertApproxEqAbs(small, large, 100);
        assertLt(large, 60_000);
    }
}
