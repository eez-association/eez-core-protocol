// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {CrossChainManagerL2} from "../src/CrossChainManagerL2.sol";
import {CrossChainProxy} from "../src/CrossChainProxy.sol";
import {
    ExecutionEntry,
    StateDelta,
    CrossChainCall,
    NestedAction,
    StaticCall,
    ProxyInfo
} from "../src/ICrossChainManager.sol";

contract L2TestTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    function setAndReturn(uint256 _value) external returns (uint256) {
        value = _value;
        return _value;
    }

    function reverting() external pure {
        revert("boom");
    }

    receive() external payable {}
}

contract RevertingTarget {
    fallback() external payable {
        revert("always reverts");
    }
}

contract CrossChainManagerL2Test is Test {
    CrossChainManagerL2 public manager;
    L2TestTarget public target;

    uint256 constant TEST_ROLLUP_ID = 42;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);

    // Rolling hash tag constants (matching contract)
    uint8 constant CALL_BEGIN = 1;
    uint8 constant CALL_END = 2;
    uint8 constant NESTED_BEGIN = 3;
    uint8 constant NESTED_END = 4;

    function setUp() public {
        manager = new CrossChainManagerL2(TEST_ROLLUP_ID, SYSTEM_ADDRESS);
        target = new L2TestTarget();
    }

    /// @notice Compute the action input hash the same way the contracts do
    function _computeActionHash(
        uint256 rollupId,
        address destination,
        uint256 value_,
        bytes memory data,
        address sourceAddress,
        uint256 sourceRollup
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(rollupId, destination, value_, data, sourceAddress, sourceRollup));
    }

    /// @notice Compute rolling hash for a single successful call with given retData
    function _rollingHashSingleCall(bytes memory retData) internal pure returns (bytes32) {
        bytes32 hash = bytes32(0);
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(1)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(1), true, retData));
        return hash;
    }

    /// @notice Compute rolling hash for a single failed call with given retData
    function _rollingHashSingleFailedCall(bytes memory retData) internal pure returns (bytes32) {
        bytes32 hash = bytes32(0);
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(1)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(1), false, retData));
        return hash;
    }

    /// @notice Helper to load a single entry into the execution table
    function _loadSingleEntry(ExecutionEntry memory entry) internal {
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = entry;
        StaticCall[] memory noStatic = new StaticCall[](0);
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries, noStatic);
    }

    /// @notice Helper to build a simple entry with one call, no nested actions
    function _buildSimpleEntry(
        bytes32 actionHash,
        CrossChainCall memory cc,
        bytes memory returnData,
        bytes32 rollingHash
    ) internal pure returns (ExecutionEntry memory entry) {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = cc;
        entry.stateDeltas = new StateDelta[](0);
        entry.actionHash = actionHash;
        entry.calls = calls;
        entry.nestedActions = new NestedAction[](0);
        entry.callCount = 1;
        entry.returnData = returnData;
        entry.failed = false;
        entry.rollingHash = rollingHash;
    }

    /// @notice Helper to build a no-call entry (just actionHash match, return data)
    function _buildNoCalls(bytes32 actionHash, bytes memory returnData) internal pure returns (ExecutionEntry memory entry) {
        entry.stateDeltas = new StateDelta[](0);
        entry.actionHash = actionHash;
        entry.calls = new CrossChainCall[](0);
        entry.nestedActions = new NestedAction[](0);
        entry.callCount = 0;
        entry.returnData = returnData;
        entry.failed = false;
        entry.rollingHash = bytes32(0);
    }

    // ── Constructor ──

    function test_Constructor_SetsRollupId() public view {
        assertEq(manager.ROLLUP_ID(), TEST_ROLLUP_ID);
    }

    function test_Constructor_SetsSystemAddress() public view {
        assertEq(manager.SYSTEM_ADDRESS(), SYSTEM_ADDRESS);
    }

    // ── loadExecutionTable ──

    function test_LoadExecutionTable_RevertsIfNotSystem() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](0);
        StaticCall[] memory noStatic = new StaticCall[](0);
        vm.expectRevert(CrossChainManagerL2.Unauthorized.selector);
        manager.loadExecutionTable(entries, noStatic);
        vm.prank(address(0xBEEF));
        vm.expectRevert(CrossChainManagerL2.Unauthorized.selector);
        manager.loadExecutionTable(entries, noStatic);
    }

    function test_LoadExecutionTable_SystemCanLoadEmpty() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](0);
        StaticCall[] memory noStatic = new StaticCall[](0);
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries, noStatic);
        assertEq(manager.executionIndex(), 0);
    }

    function test_LoadExecutionTable_StoresEntries() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);

        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID,
            address(target),
            0,
            callData,
            address(this),
            TEST_ROLLUP_ID
        );

        CrossChainCall memory cc = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.setValue, (42)),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });

        bytes memory retData = "";
        bytes32 rollingHash = _rollingHashSingleCall(retData);

        ExecutionEntry memory entry = _buildSimpleEntry(actionHash, cc, "", rollingHash);
        _loadSingleEntry(entry);

        (bool success,) = proxy.call(callData);
        assertTrue(success);
        assertEq(target.value(), 42);
    }

    function test_LoadExecutionTable_MultipleEntries() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID
        );

        CrossChainCall memory cc = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.setValue, (42)),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });

        bytes memory retData = "";
        bytes32 rollingHash = _rollingHashSingleCall(retData);

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);
        for (uint256 i = 0; i < 3; i++) {
            entries[i] = _buildSimpleEntry(actionHash, cc, "", rollingHash);
        }
        StaticCall[] memory noStatic = new StaticCall[](0);
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries, noStatic);

        for (uint256 i = 0; i < 3; i++) {
            (bool success,) = proxy.call(callData);
            assertTrue(success);
        }
        vm.expectRevert(CrossChainManagerL2.ExecutionNotFound.selector);
        (bool s,) = proxy.call(callData);
        s;
    }

    // ── createCrossChainProxy ──

    function test_CreateCrossChainProxy() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        (address origAddr, uint64 origRollup) = manager.authorizedProxies(proxy);
        assertEq(origAddr, address(target));
        assertEq(uint256(origRollup), TEST_ROLLUP_ID);
        uint256 codeSize;
        assembly { codeSize := extcodesize(proxy) }
        assertTrue(codeSize > 0);
    }

    function test_CreateCrossChainProxy_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit CrossChainManagerL2.CrossChainProxyCreated(
            manager.computeCrossChainProxyAddress(address(target), TEST_ROLLUP_ID),
            address(target),
            TEST_ROLLUP_ID
        );
        manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
    }

    function test_ComputeCrossChainProxyAddress_MatchesActual() public {
        address computed = manager.computeCrossChainProxyAddress(address(target), TEST_ROLLUP_ID);
        address actual = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        assertEq(computed, actual);
    }

    function test_MultipleProxies_DifferentRollups() public {
        address proxy1 = manager.createCrossChainProxy(address(target), 1);
        address proxy2 = manager.createCrossChainProxy(address(target), 2);
        assertTrue(proxy1 != proxy2);
    }

    function test_MultipleProxies_DifferentAddresses() public {
        L2TestTarget target2 = new L2TestTarget();
        address proxy1 = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        address proxy2 = manager.createCrossChainProxy(address(target2), TEST_ROLLUP_ID);
        assertTrue(proxy1 != proxy2);
    }

    // ── executeCrossChainCall ──

    function test_ExecuteCrossChainCall_RevertsUnauthorizedProxy() public {
        vm.expectRevert(CrossChainManagerL2.UnauthorizedProxy.selector);
        manager.executeCrossChainCall(address(this), "");
    }

    function test_ExecuteCrossChainCall_RevertsExecutionNotInCurrentBlock() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        vm.expectRevert(CrossChainManagerL2.ExecutionNotInCurrentBlock.selector);
        (bool s,) = proxy.call(callData);
        s;
    }

    function test_ExecuteCrossChainCall_RevertsExecutionNotFound() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);

        ExecutionEntry[] memory entries = new ExecutionEntry[](0);
        StaticCall[] memory noStatic = new StaticCall[](0);
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries, noStatic);

        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        // Load empty table so block check passes
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(new ExecutionEntry[](0));
        vm.expectRevert(CrossChainManagerL2.ExecutionNotFound.selector);
        (bool s,) = proxy.call(callData);
        s;
    }

    function test_ExecuteCrossChainCall_SimpleResult() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID
        );

        CrossChainCall memory cc = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.setValue, (42)),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });

        bytes memory retData = "";
        bytes32 rollingHash = _rollingHashSingleCall(retData);

        ExecutionEntry memory entry = _buildSimpleEntry(actionHash, cc, "", rollingHash);
        _loadSingleEntry(entry);

        (bool success,) = proxy.call(callData);
        assertTrue(success);
        assertEq(target.value(), 42);
    }

    function test_ExecuteCrossChainCall_ResultWithReturnData() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.getValue, ());

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID
        );

        CrossChainCall memory cc = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.getValue, ()),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });

        bytes memory retData = abi.encode(uint256(0));
        bytes32 rollingHash = _rollingHashSingleCall(retData);

        bytes memory entryReturnData = abi.encode(uint256(999));

        ExecutionEntry memory entry = _buildSimpleEntry(actionHash, cc, entryReturnData, rollingHash);
        _loadSingleEntry(entry);

        (bool success, bytes memory ret) = proxy.call(callData);
        assertTrue(success);
        assertEq(ret, entryReturnData);
    }

    function test_ExecuteCrossChainCall_FailedEntryReverts() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID
        );

        ExecutionEntry memory entry = _buildNoCalls(actionHash, abi.encodeWithSignature("Error(string)", "test fail"));
        entry.failed = true;

        _loadSingleEntry(entry);

        (bool success,) = proxy.call(callData);
        assertFalse(success);
    }

    function test_ExecuteCrossChainCall_ConsumesInFifoOrder() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.getValue, ());

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID
        );

        CrossChainCall memory cc = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.getValue, ()),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });

        bytes memory retData = abi.encode(uint256(0));
        bytes32 rollingHash = _rollingHashSingleCall(retData);

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _buildSimpleEntry(actionHash, cc, abi.encode(uint256(111)), rollingHash);
        entries[1] = _buildSimpleEntry(actionHash, cc, abi.encode(uint256(222)), rollingHash);
        StaticCall[] memory noStatic = new StaticCall[](0);
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries, noStatic);

        (bool s1, bytes memory r1) = proxy.call(callData);
        assertTrue(s1);
        assertEq(abi.decode(r1, (uint256)), 111);
        (bool s2, bytes memory r2) = proxy.call(callData);
        assertTrue(s2);
        assertEq(abi.decode(r2, (uint256)), 222);
        vm.expectRevert(CrossChainManagerL2.ExecutionNotFound.selector);
        (bool s3,) = proxy.call(callData);
        s3;
    }

    // ── CrossChainProxy direct tests ──

    function test_Proxy_ExecuteOnBehalf_NonManagerFallsThrough() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        CrossChainProxy p = CrossChainProxy(payable(proxy));
        vm.prank(address(0xDEAD));
        vm.expectRevert(CrossChainManagerL2.ExecutionNotInCurrentBlock.selector);
        p.executeOnBehalf(address(target), abi.encodeCall(L2TestTarget.setValue, (42)));
    }

    // ── Rolling hash mismatch ──

    function test_RollingHashMismatch_Reverts() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID
        );

        CrossChainCall memory cc = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.setValue, (42)),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });

        ExecutionEntry memory entry = _buildSimpleEntry(actionHash, cc, "", bytes32(uint256(0xDEAD)));
        _loadSingleEntry(entry);

        vm.expectRevert(CrossChainManagerL2.RollingHashMismatch.selector);
        (bool s,) = proxy.call(callData);
        s;
    }

    // ── UnconsumedCalls ──

    function test_UnconsumedCalls_Reverts() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID
        );

        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.setValue, (42)),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });
        calls[1] = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.setValue, (99)),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });

        bytes memory retData = "";
        bytes32 rollingHash = _rollingHashSingleCall(retData);

        ExecutionEntry memory entry;
        entry.stateDeltas = new StateDelta[](0);
        entry.actionHash = actionHash;
        entry.calls = calls;
        entry.nestedActions = new NestedAction[](0);
        entry.callCount = 1;
        entry.returnData = "";
        entry.failed = false;
        entry.rollingHash = rollingHash;

        _loadSingleEntry(entry);

        vm.expectRevert(CrossChainManagerL2.UnconsumedCalls.selector);
        (bool s,) = proxy.call(callData);
        s;
    }

    // ── Multiple calls in entry ──

    function test_ExecuteCrossChainCall_MultipleCalls() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID
        );

        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.setValue, (10)),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });
        calls[1] = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.setValue, (20)),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });

        bytes32 hash = bytes32(0);
        bytes memory ret1 = "";
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(1)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(1), true, ret1));
        bytes memory ret2 = "";
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(2)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(2), true, ret2));

        ExecutionEntry memory entry;
        entry.stateDeltas = new StateDelta[](0);
        entry.actionHash = actionHash;
        entry.calls = calls;
        entry.nestedActions = new NestedAction[](0);
        entry.callCount = 2;
        entry.returnData = "";
        entry.failed = false;
        entry.rollingHash = hash;

        _loadSingleEntry(entry);

        (bool success,) = proxy.call(callData);
        assertTrue(success);
        assertEq(target.value(), 20);
    }

    // ── executeInContext: NotSelf ──

    function test_ExecuteInContext_NotSelf() public {
        vm.expectRevert(CrossChainManagerL2.NotSelf.selector);
        manager.executeInContext(1);
    }

    // ── revertSpan (isolated context) ──

    function test_ExecuteCrossChainCall_WithRevertSpan() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        RevertingTarget revTarget = new RevertingTarget();
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID
        );

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: address(revTarget),
            value: 0,
            data: hex"deadbeef",
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 1
        });

        bytes memory revertData = abi.encodeWithSignature("Error(string)", "always reverts");
        bytes32 hash = bytes32(0);
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(1)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(1), false, revertData));

        ExecutionEntry memory entry;
        entry.stateDeltas = new StateDelta[](0);
        entry.actionHash = actionHash;
        entry.calls = calls;
        entry.nestedActions = new NestedAction[](0);
        entry.callCount = 1;
        entry.returnData = "";
        entry.failed = false;
        entry.rollingHash = hash;

        _loadSingleEntry(entry);

        (bool success,) = proxy.call(callData);
        assertTrue(success);
    }

    // ══════════════════════════════════════════════
    //  Event tests
    // ══════════════════════════════════════════════

    // ── ExecutionTableLoaded ──

    function _findExecutionTableLoadedLog(Vm.Log[] memory logs) internal pure returns (bool found, uint256 idx) {
        bytes32 sel = CrossChainManagerL2.ExecutionTableLoaded.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    function test_ExecutionTableLoaded_EmitsOnLoad() public {
        bytes32 hash1 = bytes32(uint256(1));
        bytes32 hash2 = bytes32(uint256(2));

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _buildNoCalls(hash1, "");
        entries[1] = _buildNoCalls(hash2, "");

        vm.recordLogs();
        StaticCall[] memory noStatic = new StaticCall[](0);
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries, noStatic);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found,) = _findExecutionTableLoadedLog(logs);
        assertTrue(found, "ExecutionTableLoaded event not found");
    }

    function test_ExecutionTableLoaded_EmptyBatch() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](0);

        vm.recordLogs();
        StaticCall[] memory noStatic = new StaticCall[](0);
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries, noStatic);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found,) = _findExecutionTableLoadedLog(logs);
        assertTrue(found, "ExecutionTableLoaded event not found for empty batch");
    }

    // ── ExecutionConsumed ──

    function test_ExecutionConsumed_EmitsOnConsume() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID
        );

        CrossChainCall memory cc = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.setValue, (42)),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });

        bytes memory retData = "";
        bytes32 rollingHash = _rollingHashSingleCall(retData);

        ExecutionEntry memory entry = _buildSimpleEntry(actionHash, cc, "", rollingHash);
        _loadSingleEntry(entry);

        vm.recordLogs();
        (bool success,) = proxy.call(callData);
        assertTrue(success);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = CrossChainManagerL2.ExecutionConsumed.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], actionHash);
                found = true;
                break;
            }
        }
        assertTrue(found, "ExecutionConsumed event not found");
    }

    function test_ExecutionConsumed_EmitsForEachConsumption() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID
        );

        CrossChainCall memory cc = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.setValue, (42)),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });

        bytes memory retData = "";
        bytes32 rollingHash = _rollingHashSingleCall(retData);

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _buildSimpleEntry(actionHash, cc, "", rollingHash);
        entries[1] = _buildSimpleEntry(actionHash, cc, "", rollingHash);
        StaticCall[] memory noStatic = new StaticCall[](0);
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries, noStatic);

        vm.recordLogs();
        (bool s1,) = proxy.call(callData);
        assertTrue(s1);
        (bool s2,) = proxy.call(callData);
        assertTrue(s2);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = CrossChainManagerL2.ExecutionConsumed.selector;
        uint256 consumedCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], actionHash);
                consumedCount++;
            }
        }
        assertEq(consumedCount, 2);
    }

    // ── CrossChainCallExecuted ──

    function test_CrossChainCallExecuted_EmitsOnProxyCall() public {
        address proxy = manager.createCrossChainProxy(address(target), TEST_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        bytes32 actionHash = _computeActionHash(
            TEST_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID
        );

        CrossChainCall memory cc = CrossChainCall({
            destination: address(target),
            value: 0,
            data: abi.encodeCall(L2TestTarget.setValue, (42)),
            sourceAddress: address(this),
            sourceRollup: TEST_ROLLUP_ID,
            revertSpan: 0
        });

        bytes memory retData = "";
        bytes32 rollingHash = _rollingHashSingleCall(retData);

        ExecutionEntry memory entry = _buildSimpleEntry(actionHash, cc, "", rollingHash);
        _loadSingleEntry(entry);

        vm.recordLogs();
        (bool success,) = proxy.call(callData);
        assertTrue(success);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = CrossChainManagerL2.CrossChainCallExecuted.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], actionHash);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), proxy);
                (address src, bytes memory cd, uint256 val) = abi.decode(logs[i].data, (address, bytes, uint256));
                assertEq(src, address(this));
                assertEq(cd, callData);
                assertEq(val, 0);
                found = true;
                break;
            }
        }
        assertTrue(found, "CrossChainCallExecuted event not found");
    }

    // ══════════════════════════════════════════════
    //  Tests from old file that are fundamentally incompatible with new system
    //  (Action/ActionType structs, newScope, executeIncomingCrossChainCall,
    //   scope-based navigation, pendingEntryCount, etc.)
    //  See problems/questions.md for full list and explanations.
    // ══════════════════════════════════════════════
}
