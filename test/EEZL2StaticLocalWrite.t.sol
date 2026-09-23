// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseL2} from "./BaseL2.t.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
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
        // Supplying both intended answers cannot make the second row reachable.
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
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector));
        assertEq(manager.entryIndex(), 0);
        assertEq(rate, 2);

        // The second answer is valid for this state; first-match selection blocked it.
        StaticExecutionEntryL2[] memory replacement = new StaticExecutionEntryL2[](1);
        replacement[0] = statics[1];
        _loadEntries(new ExecutionEntry[](0), replacement);
        (ok, result) = proxy.staticcall(readData);
        assertTrue(ok);
        assertEq(abi.decode(result, (uint256)), 2);
    }
}
