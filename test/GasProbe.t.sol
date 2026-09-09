// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

    /// @dev Static twin of `_probeOutgoing`: a top-level static miss reverts
    ///      `EntryNotFound(hash, callGas)` too, so the same two-probe recipe recovers the gas a
    ///      later identical STATICCALL will fold.
    function _probeStatic(bytes memory data) internal returns (bytes32 hash, uint64 g) {
        _loadEntries(new ExecutionEntry[](0), new StaticExecutionEntry[](0));
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(caller);
            (bool ok, bytes memory err) = proxyAddr.staticcall{gas: CALL_GAS}(data);
            require(!ok && bytes4(err) == EEZL2.EntryNotFound.selector, "probe: expected EntryNotFound");
            assembly {
                hash := mload(add(err, 0x24))
                g := mload(add(err, 0x44))
            }
        }
    }

    function test_StaticObservedGasRejectsZeroGasKey() public {
        bytes memory data = hex"12345678";
        bytes32 zeroGasHash = _ccHash(true, caller, TEST_ROLLUP_ID, remoteTarget, REMOTE_ROLLUP_ID, 0, data);
        _loadStatic(zeroGasHash, "zero-gas-key", true);
        vm.prank(caller);
        (bool ok, bytes memory ret) = proxyAddr.staticcall{gas: CALL_GAS}(data);
        assertFalse(ok);
        assertEq(bytes4(ret), EEZL2.EntryNotFound.selector);
        (bytes32 missedHash, uint64 g) = abi.decode(_slice(ret, 4), (bytes32, uint64));
        assertTrue(g != 0, "observed gas is folded");
        assertTrue(missedHash != zeroGasHash, "static key under USE_GAS_LEFT differs from the zero-gas key");
    }

    function test_StaticProbeReproducesCallGasExactly() public {
        bytes memory data = hex"12345678";
        (bytes32 h1, uint64 g1) = _probeStatic(data);
        (bytes32 h2, uint64 g2) = _probeStatic(data);
        assertEq(g1, g2, "warm static probes are stable");
        assertEq(h1, h2);
        assertEq(
            h2,
            manager.computeCrossChainCallHash(
                true, caller, TEST_ROLLUP_ID, remoteTarget, REMOTE_ROLLUP_ID, 0, g2, data
            ),
            "reported hash is the static key built from the reported gas"
        );

        _loadStatic(h2, "static-probed-ok", true);
        vm.prank(caller);
        (bool ok, bytes memory ret) = proxyAddr.staticcall{gas: CALL_GAS}(data);
        assertTrue(ok, "real static read matches the probed hash");
        assertEq(ret, "static-probed-ok");
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[from + i];
        }
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
