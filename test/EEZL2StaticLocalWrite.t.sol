// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseL2} from "./BaseL2.t.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {ExecutionEntry, CrossChainCall, StaticExecutionEntryL2} from "../src/interfaces/IEEZL2.sol";

/// @notice A remote quote reads the caller's local rate through a static callback.
///         This tests local table resolution, not a production proof or two-chain execution.
contract EEZL2StaticLocalWriteTest is BaseL2 {
    uint256 public rate;

    function test_LocalWriteBetweenStaticCallbacksDoesNotAdvanceCursor() public {
        address remoteQuote = address(0xBEEF);
        address proxy = manager.createCrossChainProxy(remoteQuote, REMOTE_ROLLUP_ID);
        bytes memory readData = abi.encodeWithSignature("quote()");
        bytes32 readHash = _ccHash(IS_STATIC, address(this), TEST_ROLLUP_ID, remoteQuote, REMOTE_ROLLUP_ID, 0, readData);

        CrossChainCall[] memory callbacks = new CrossChainCall[](1);
        callbacks[0] = _cc(address(this), 0, abi.encodeWithSignature("rate()"), remoteQuote, REMOTE_ROLLUP_ID);
        callbacks[0].isStatic = true;

        // Both reads have the same call hash and live cursor (zero).
        // Callback hashes distinguish the candidates without consuming either row.
        StaticExecutionEntryL2[] memory statics = new StaticExecutionEntryL2[](2);
        for (uint256 i; i < 2; i++) {
            statics[i].expectedEntryIndex = 0;
            statics[i].proxyEntryHash = readHash;
            statics[i].incomingCalls = callbacks;
            statics[i].rollingHash = _hStatic(bytes32(0), true, abi.encode(i + 1));
            statics[i].success = true;
            statics[i].returnData = abi.encode(i + 1);
        }
        _loadEntries(new ExecutionEntry[](0), statics);

        rate = 1;
        (bool ok, bytes memory result) = proxy.staticcall(readData);
        assertTrue(ok);
        assertEq(abi.decode(result, (uint256)), 1);
        assertEq(manager.entryIndex(), 0);

        // Ordinary application storage write: no EEZ mutable entry is consumed.
        rate = 2;
        (ok, result) = proxy.staticcall(readData);
        assertTrue(ok);
        assertEq(abi.decode(result, (uint256)), 2);
        assertEq(manager.entryIndex(), 0);
        assertEq(rate, 2);

        // Reads can reuse an earlier row; retry does not advance a hidden cursor.
        rate = 1;
        (ok, result) = proxy.staticcall(readData);
        assertTrue(ok);
        assertEq(abi.decode(result, (uint256)), 1);
        assertEq(manager.entryIndex(), 0);

        // Exhausting the candidates reports a lookup miss.
        rate = 3;
        (ok, result) = proxy.staticcall(readData);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZL2.EntryNotFound.selector, readHash, uint64(0)));
    }
}
