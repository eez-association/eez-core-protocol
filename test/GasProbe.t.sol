// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EEZBase} from "../src/base/EEZBase.sol";
import {BaseL2} from "./BaseL2.t.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {CrossChainCall, ExecutionEntry, StaticExecutionEntry} from "../src/interfaces/IEEZL2.sol";

/// @title GasProbeTest
/// @notice Validates the callGas observation technique the test harnesses rely on: `callGas`
///         is captured before any matching, so a failed probe call reports — via
///         `EntryNotFound(hash, callGas)` — the exact value a later identical call will fold
///         into its hash, provided both calls attach the same explicit `CALL_GAS`. The first
///         probe warms the access path; the second measures warm; the real call then matches.
contract GasProbeTest is BaseL2 {
    address internal caller = address(0xCA11);
    address internal remoteTarget = address(0xBEEF);
    address internal proxyAddr;

    function setUp() public override {
        super.setUp();
        // The shared fixture runs with `useGasLeft = false`; this suite validates the observed-gas
        // keying itself, so it replaces the manager with a `useGasLeft = true` deployment.
        manager = new EEZL2(TEST_ROLLUP_ID, SYSTEM_ADDRESS, true);
        proxyAddr = manager.createCrossChainProxy(remoteTarget, REMOTE_ROLLUP_ID);
        vm.deal(caller, 10 ether);
    }

    function test_probeReproducesCallGasExactly() public {
        bytes memory data = abi.encodeWithSignature("doSomething(uint256)", 7);

        uint64 g1 = _probeOutgoing(caller, proxyAddr, 0, data);
        uint64 g2 = _probeOutgoing(caller, proxyAddr, 0, data);
        assertEq(g1, g2, "warm probes are stable");
        assertTrue(g2 != 0);

        // Build the entry from the observation; the real call must match it.
        bytes32 cch = _outgoingCallHash(caller, remoteTarget, REMOTE_ROLLUP_ID, 0, g2, data);
        _loadSingle(_buildNoCalls(cch, "probed-ok"));
        vm.prank(caller);
        (bool ok, bytes memory ret) = proxyAddr.call{gas: CALL_GAS}(data);
        assertTrue(ok, "real call matches the probed hash");
        assertEq(ret, "probed-ok");
    }

    function test_probeWithValue() public {
        bytes memory data = abi.encodeWithSignature("deposit()");

        uint64 g = _probeOutgoing(caller, proxyAddr, 1 ether, data);
        assertTrue(g != 0);

        bytes32 cch = _outgoingCallHash(caller, remoteTarget, REMOTE_ROLLUP_ID, 1 ether, g, data);
        _loadSingle(_buildNoCalls(cch, "value-ok"));
        vm.prank(caller);
        (bool ok, bytes memory ret) = proxyAddr.call{value: 1 ether, gas: CALL_GAS}(data);
        assertTrue(ok, "real value call matches the probed hash");
        assertEq(ret, "value-ok");
    }

    function _loadStatic(bytes32 hash, bytes memory result, bool success) internal {
        StaticExecutionEntry[] memory rows = new StaticExecutionEntry[](1);
        rows[0].proxyEntryHash = hash;
        rows[0].incomingCalls = new CrossChainCall[](0);
        rows[0].success = success;
        rows[0].returnData = result;
        _loadEntries(new ExecutionEntry[](0), rows);
    }

    function test_StaticObservedGasRejectsZeroGasKey() public {
        bytes memory data = hex"12345678";
        bytes32 hash = _ccHash(true, caller, TEST_ROLLUP_ID, remoteTarget, REMOTE_ROLLUP_ID, 0, data);
        _loadStatic(hash, "zero-gas-key", true);
        vm.prank(caller);
        (bool ok, bytes memory ret) = proxyAddr.staticcall{gas: CALL_GAS}(data);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(EEZBase.ExecutionNotFound.selector));
    }

    function test_StaticGasDisabledKeepsZeroGasKey() public {
        manager = new EEZL2(TEST_ROLLUP_ID, SYSTEM_ADDRESS, false);
        proxyAddr = manager.createCrossChainProxy(remoteTarget, REMOTE_ROLLUP_ID);
        bytes memory data = hex"12345678";
        bytes32 hash = _ccHash(true, caller, TEST_ROLLUP_ID, remoteTarget, REMOTE_ROLLUP_ID, 0, data);
        _loadStatic(hash, "zero-gas-ok", true);
        vm.prank(caller);
        (bool ok, bytes memory ret) = proxyAddr.staticcall{gas: CALL_GAS}(data);
        assertTrue(ok);
        assertEq(ret, "zero-gas-ok");
        vm.prank(caller);
        (ok, ret) = proxyAddr.staticcall{gas: CALL_GAS - 1000}(data);
        assertTrue(ok);
        assertEq(ret, "zero-gas-ok");
    }
}
