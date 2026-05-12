// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {StateDelta, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry, LookupCall} from "../../../src/interfaces/IEEZ.sol";

/// @title ComputeExpectedBase — Shared formatting helpers for ComputeExpected contracts
/// @dev Each test's ComputeExpected inherits this and overrides _name() and _funcName().
///   The flatten model identifies entries by (crossChainCallHash, rollingHash) — both are bound
///   into the entry hash below and used for subset verification by Verify.s.sol.
abstract contract ComputeExpectedBase is Script {
    // ══════════════════════════════════════════════════════════════════
    //  Entry identity hash used by Verify.s.sol for subset matching.
    //  The flatten model binds all execution behaviour into rollingHash,
    //  so (crossChainCallHash, rollingHash) is a stable identifier for an entry.
    // ══════════════════════════════════════════════════════════════════

    function _entryHash(bytes32 crossChainCallHash, bytes32 rollingHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(crossChainCallHash, rollingHash));
    }

    function _entryHash(ExecutionEntry memory e) internal pure returns (bytes32) {
        return _entryHash(e.proxyEntryHash, e.rollingHash);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Address / selector naming — override per test.
    // ══════════════════════════════════════════════════════════════════

    function _name(address a) internal view virtual returns (string memory) {
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure virtual returns (string memory) {
        return vm.toString(bytes32(sel));
    }

    // ══════════════════════════════════════════════════════════════════
    //  L2ToL1Call formatting (the legacy `Action` struct was removed)
    // ══════════════════════════════════════════════════════════════════

    function _fmtCall(L2ToL1Call memory c) internal view returns (string memory) {
        string memory func = c.data.length == 0 ? "(ETH transfer)" : string.concat(".", _funcName(bytes4(c.data)), "()");
        string memory valStr = c.value > 0 ? string.concat("  value=", _fmtEther(c.value)) : "";
        string memory revertStr = c.revertSpan > 0 ? string.concat("  revertSpan=", vm.toString(c.revertSpan)) : "";
        return string.concat(
            "CALL ",
            _name(c.targetAddress),
            func,
            valStr,
            revertStr,
            "\n          from ",
            _name(c.sourceAddress),
            " @ rollup ",
            vm.toString(c.sourceRollupId)
        );
    }

    function _fmtNested(ExpectedL1ToL2Call memory n) internal pure returns (string memory) {
        return string.concat(
            "NESTED crossChainCallHash=",
            _shortHash(n.crossChainCallHash),
            "  callCount=",
            vm.toString(n.callCount),
            "  retData=",
            _shortBytes(n.returnData)
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  Entry formatting
    // ══════════════════════════════════════════════════════════════════

    /// @notice L1 deferred entry (with state deltas + rolling hash).
    function _logEntry(uint256 idx, ExecutionEntry memory e) internal view {
        bytes32 hash = _entryHash(e);
        bool immediate = e.proxyEntryHash == bytes32(0);
        console.log("  [%s] %s  entryHash=%s", idx, immediate ? "IMMEDIATE" : "DEFERRED", vm.toString(hash));
        console.log("      proxyEntryHash:  %s", vm.toString(e.proxyEntryHash));
        console.log("      rollingHash: %s", vm.toString(e.rollingHash));
        console.log(
            "      callCount=%s  calls=%s  nested=%s", e.callCount, e.L2ToL1Calls.length, e.expectedL1ToL2Calls.length
        );

        for (uint256 d = 0; d < e.stateDeltas.length; d++) {
            StateDelta memory sd = e.stateDeltas[d];
            string memory etherStr =
                sd.etherDelta == 0 ? "" : string.concat("  ether: ", _fmtEtherSigned(sd.etherDelta));
            console.log(
                string.concat(
                    "      state: rollup ", vm.toString(sd.rollupId), " -> ", _shortHash(sd.newState), etherStr
                )
            );
        }
        for (uint256 c = 0; c < e.L2ToL1Calls.length; c++) {
            console.log(string.concat("      ", _fmtCall(e.L2ToL1Calls[c])));
        }
        for (uint256 n = 0; n < e.expectedL1ToL2Calls.length; n++) {
            console.log(string.concat("      ", _fmtNested(e.expectedL1ToL2Calls[n])));
        }
        if (e.returnData.length > 0) {
            console.log("      returnData: %s", _shortBytes(e.returnData));
        }
        // POST-REFACTOR: ExecutionEntry.failed removed; reverts via LookupCall.
    }

    /// @notice L2 entry (no state deltas, no ether tracking).
    function _logL2Entry(uint256 idx, ExecutionEntry memory e) internal view {
        bytes32 hash = _entryHash(e);
        console.log("  [%s] entryHash=%s", idx, vm.toString(hash));
        console.log("      proxyEntryHash:  %s", vm.toString(e.proxyEntryHash));
        console.log("      rollingHash: %s", vm.toString(e.rollingHash));
        console.log(
            "      callCount=%s  calls=%s  nested=%s", e.callCount, e.L2ToL1Calls.length, e.expectedL1ToL2Calls.length
        );
        for (uint256 c = 0; c < e.L2ToL1Calls.length; c++) {
            console.log(string.concat("      ", _fmtCall(e.L2ToL1Calls[c])));
        }
        for (uint256 n = 0; n < e.expectedL1ToL2Calls.length; n++) {
            console.log(string.concat("      ", _fmtNested(e.expectedL1ToL2Calls[n])));
        }
        if (e.returnData.length > 0) {
            console.log("      returnData: %s", _shortBytes(e.returnData));
        }
    }

    function _logLookupCall(uint256 idx, LookupCall memory sc) internal pure {
        console.log("  [%s] STATIC crossChainCallHash=%s", idx, vm.toString(sc.crossChainCallHash));
        console.log(
            "      callNumber=%s  lastNA=%s  failed=%s",
            sc.callNumber,
            sc.lastNestedActionConsumed,
            sc.failed ? "true" : "false"
        );
        if (sc.returnData.length > 0) {
            console.log("      returnData: %s", _shortBytes(sc.returnData));
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  Summary
    // ══════════════════════════════════════════════════════════════════

    function _chainName(uint256 rollupId) internal pure returns (string memory) {
        if (rollupId == 0) return "L1";
        if (rollupId == 1) return "L2";
        return string.concat("rollup ", vm.toString(rollupId));
    }

    function _logEntrySummary(uint256 idx, ExecutionEntry memory e) internal pure {
        console.log(
            string.concat(
                "  [",
                vm.toString(idx),
                "] proxyEntryHash=",
                _shortHash(e.proxyEntryHash),
                "  calls=",
                vm.toString(e.L2ToL1Calls.length),
                "  nested=",
                vm.toString(e.expectedL1ToL2Calls.length)
            )
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  Primitives
    // ══════════════════════════════════════════════════════════════════

    function _shortHash(bytes32 h) internal pure returns (string memory) {
        string memory full = vm.toString(h);
        return string.concat(_sub(full, 0, 6), "..", _sub(full, 62, 66));
    }

    function _shortAddr(address a) internal pure returns (string memory) {
        string memory full = vm.toString(a);
        return string.concat(_sub(full, 0, 6), "..", _sub(full, 38, 42));
    }

    function _shortBytes(bytes memory b) internal pure returns (string memory) {
        if (b.length == 0) return "0x";
        if (b.length <= 36) return vm.toString(b);
        string memory full = vm.toString(b);
        return string.concat(_sub(full, 0, 10), "...(", vm.toString(b.length), " bytes)");
    }

    function _fmtEther(uint256 wei_) internal pure returns (string memory) {
        if (wei_ == 0) return "0";
        if (wei_ % 1 ether == 0) return string.concat(vm.toString(wei_ / 1 ether), " ETH");
        return string.concat(vm.toString(wei_), " wei");
    }

    function _fmtEtherSigned(int256 wei_) internal pure returns (string memory) {
        if (wei_ >= 0) return string.concat("+", _fmtEther(uint256(wei_)));
        return string.concat("-", _fmtEther(uint256(-wei_)));
    }

    function _sub(string memory str, uint256 s, uint256 e) internal pure returns (string memory) {
        bytes memory b = bytes(str);
        if (e > b.length) e = b.length;
        if (s >= e) return "";
        bytes memory r = new bytes(e - s);
        for (uint256 i = s; i < e; i++) {
            r[i - s] = b[i];
        }
        return string(r);
    }
}
