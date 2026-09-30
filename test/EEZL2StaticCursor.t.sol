// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseL2} from "./BaseL2.t.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {ExecutionEntry, CrossChainCall, StaticExecutionEntryL2} from "../src/interfaces/IEEZL2.sol";

contract StaticCursorTarget {
    uint256 public value;

    function setValue(uint256 next) external {
        value = next;
    }
}

contract EEZL2StaticCursorTest is BaseL2 {
    // Same read key before/after a real write. Also covers forward-scan skips,
    // failed entry rollback, repeatable static reads, and table replacement.
    function testFuzz_StaticReadPinsLiveCursor(uint8 skipped, bool revertEntry) public {
        uint256 pos = bound(uint256(skipped), 0, 3);
        StaticCursorTarget target = new StaticCursorTarget();
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory readData = abi.encodeWithSignature("value()");
        bytes memory writeData = abi.encodeCall(StaticCursorTarget.setValue, (6));
        bytes32 readHash =
            _ccHash(IS_STATIC, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, 0, readData);
        bytes32 writeHash = _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, 0, writeData);
        CrossChainCall memory call = _cc(address(target), 0, writeData, address(this), REMOTE_ROLLUP_ID);
        ExecutionEntry[] memory entries = new ExecutionEntry[](pos + 1);
        for (uint256 i; i < pos; i++) {
            entries[i] = _buildNoCalls(bytes32(i + 1), "");
        }
        entries[pos] = _buildSimpleEntry(writeHash, call, "", _rhSingle(writeHash, call, true, ""));
        entries[pos].success = !revertEntry;

        StaticExecutionEntryL2[] memory statics = new StaticExecutionEntryL2[](2);
        // Put the future row first: a hash match with the wrong cursor must be skipped.
        statics[0].expectedEntryIndex = pos + 1;
        statics[0].proxyEntryHash = readHash;
        statics[0].success = true;
        statics[0].returnData = abi.encode(uint256(6));
        statics[1].proxyEntryHash = readHash;
        statics[1].success = true;
        statics[1].returnData = abi.encode(uint256(0));
        _loadEntries(entries, statics);

        assertEq(_read(proxy, readData), 0);
        assertEq(_read(proxy, readData), 0);
        (bool ok,) = proxy.call(writeData);
        assertEq(ok, !revertEntry);
        uint256 expected = revertEntry ? 0 : 6;
        assertEq(target.value(), expected);
        assertEq(manager.entryIndex(), revertEntry ? 0 : pos + 1);
        assertEq(_read(proxy, readData), expected);
        assertEq(_read(proxy, readData), expected);

        // Replacing the table resets the cursor and discards the old static rows.
        statics = new StaticExecutionEntryL2[](1);
        statics[0].proxyEntryHash = readHash;
        statics[0].success = true;
        statics[0].returnData = abi.encode(uint256(9));
        _loadEntries(new ExecutionEntry[](0), statics);
        assertEq(manager.entryIndex(), 0);
        assertEq(_read(proxy, readData), 9);

        // Same hash but only a future cursor: no fallback to the wrong version.
        statics[0].expectedEntryIndex = 1;
        _loadEntries(new ExecutionEntry[](0), statics);
        (ok, readData) = proxy.staticcall(readData);
        assertFalse(ok);
        assertEq(readData, abi.encodeWithSelector(EEZL2.EntryNotFound.selector, readHash, uint64(0)));
    }

    function test_StaticReadAfterIncomingDelivery() public {
        StaticCursorTarget target = new StaticCursorTarget();
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory readData = abi.encodeWithSignature("value()");
        CrossChainCall memory call =
            _cc(address(target), 0, abi.encodeCall(StaticCursorTarget.setValue, (6)), address(this), REMOTE_ROLLUP_ID);
        bytes32 inboundHash = _incomingCallHash(call);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _buildSimpleEntry(inboundHash, call, "", _rhSingle(inboundHash, call, true, ""));
        StaticExecutionEntryL2[] memory statics = new StaticExecutionEntryL2[](1);
        statics[0].expectedEntryIndex = 1;
        statics[0].proxyEntryHash =
            _ccHash(IS_STATIC, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, 0, readData);
        statics[0].success = true;
        statics[0].returnData = abi.encode(uint256(6));
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall(entries, statics);
        assertEq(manager.entryIndex(), 1);
        assertEq(target.value(), 6);
        assertEq(_read(proxy, readData), 6);
    }

    function _read(address proxy, bytes memory data) internal view returns (uint256) {
        (bool ok, bytes memory result) = proxy.staticcall(data);
        require(ok, "static read failed");
        return abi.decode(result, (uint256));
    }
}
