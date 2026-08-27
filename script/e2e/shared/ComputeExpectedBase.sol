// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {
    RollupUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry,
    StaticExecutionEntry
} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";
import {HashStep, RollingHashBuilder} from "./E2EHelpers.sol";

/// @title ComputeExpectedBase — Shared formatting helpers for ComputeExpected contracts
/// @dev Each test's ComputeExpected inherits this and overrides _name() and _funcName().
///   The flatten model identifies entries by (proxyEntryHash, rollingHash) — both are bound
///   into the entry hash below and used for subset verification by Verify.s.sol.
abstract contract ComputeExpectedBase is Script {
    // ══════════════════════════════════════════════════════════════════
    //  Entry identity hash used by Verify.s.sol for subset matching.
    //  The flatten model binds all execution behaviour into rollingHash,
    //  so (proxyEntryHash, rollingHash) is a stable identifier for an entry.
    //  NOT the protocol's entry hash (keccak256 of the whole struct, folded
    //  into the proof public input) — this is a test-side identity only.
    // ══════════════════════════════════════════════════════════════════

    function _entryHash(bytes32 proxyEntryHash, bytes32 rollingHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(proxyEntryHash, rollingHash));
    }

    function _entryHash(ExecutionEntry memory e) internal pure returns (bytes32) {
        return _entryHash(e.proxyEntryHash, e.rollingHash);
    }

    function _entryHash(L2ExecutionEntry memory e) internal pure returns (bytes32) {
        return _entryHash(e.proxyEntryHash, e.rollingHash);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Full expected tables — ABI-encoded blobs consumed by Verify.s.sol
    //  for field-by-field comparison (picked up by run/network.sh /
    //  run/local.sh via the EXPECTED_*_TABLE output lines).
    // ══════════════════════════════════════════════════════════════════

    function _printL1Table(ExecutionEntry[] memory entries) internal pure {
        bytes memory blob = abi.encode(entries);
        _printTableLine("EXPECTED_L1_TABLE=%s", blob);
    }

    function _printL2Table(L2ExecutionEntry[] memory entries) internal pure {
        bytes memory blob = abi.encode(entries);
        _printTableLine("EXPECTED_L2_TABLE=%s", blob);
    }

    /// @dev Separate frame for the hex conversion + log — keeps the via-ir stack of
    ///      callers that print both tables under the limit.
    function _printTableLine(string memory label, bytes memory blob) private pure {
        string memory hexStr = vm.toString(blob);
        console.log(label, hexStr);
    }

    /// @dev Prints EXPECTED_L1_STEPS — per-entry rolling-hash fold steps, index-aligned
    ///      with the expected L1 table, so the network verifier can replay each chain
    ///      over the REAL posted seed roots (VerifyL1BatchCalldata). Self-checking:
    ///      replaying each entry's steps over its own (placeholder) seed must reproduce
    ///      the entry's rollingHash, so the steps cannot drift from the table.
    function _printL1Steps(ExecutionEntry[] memory entries, HashStep[][] memory steps) internal pure {
        require(steps.length == entries.length, "steps/entries length mismatch");
        for (uint256 i = 0; i < entries.length; i++) {
            bytes32 seed = RollingHashBuilder.entryBegin(entries[i].rollupUpdates, entries[i].proxyEntryHash);
            require(RollingHashBuilder.foldSteps(seed, steps[i]) == entries[i].rollingHash, "steps drift from table");
        }
        _printTableLine("EXPECTED_L1_STEPS=%s", abi.encode(steps));
    }

    /// @dev Prints EXPECTED_L1_CALL_HASHES from the entries' non-zero proxyEntryHash keys —
    ///      the hash `ExecutionConsumed` emits per proxy-driven consumption. Zero-hash (L2Tx)
    ///      entries are skipped: they emit no call hash and are matched via EntryExecuted
    ///      instead (VerifyL1ZeroHashEntriesInRange keyed by EXPECTED_L1_HASHES). The runners
    ///      route on this line's presence, so print it whenever any L1 entry is proxy-keyed.
    function _printL1CallHashes(ExecutionEntry[] memory entries) internal pure {
        string memory acc = "";
        bool any;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].proxyEntryHash == bytes32(0)) continue;
            acc = any
                ? string.concat(acc, ",", vm.toString(entries[i].proxyEntryHash))
                : vm.toString(entries[i].proxyEntryHash);
            any = true;
        }
        if (any) console.log("EXPECTED_L1_CALL_HASHES=[%s]", acc);
    }

    /// @dev Prints EXPECTED_L2_CALL_HASHES from the entries' proxyEntryHash keys — the hash
    ///      every L2 consumption route emits (`CrossChainCallExecuted` for proxy-driven
    ///      outgoing calls, `IncomingCrossChainCallExecuted` for system-driven inbound ones),
    ///      so VerifyL2Calls / VerifyL2CallsInRange can match them. Duplicates are fine
    ///      (subset semantics).
    function _printL2CallHashes(L2ExecutionEntry[] memory entries) internal pure {
        string memory acc = "";
        for (uint256 i = 0; i < entries.length; i++) {
            acc = i == 0
                ? vm.toString(entries[i].proxyEntryHash)
                : string.concat(acc, ",", vm.toString(entries[i].proxyEntryHash));
        }
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", acc);
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
    //  Call formatting — L1 `L2ToL1Call` / L2 `CrossChainCall` overloads
    // ══════════════════════════════════════════════════════════════════

    function _fmtCall(L2ToL1Call memory c) internal view returns (string memory) {
        string memory func = c.data.length == 0 ? "(ETH transfer)" : string.concat(".", _funcName(bytes4(c.data)), "()");
        string memory valStr = c.value > 0 ? string.concat("  value=", _fmtEther(c.value)) : "";
        string memory revertStr =
            c.revertNextNCalls > 0 ? string.concat("  revertNextNCalls=", vm.toString(c.revertNextNCalls)) : "";
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

    function _fmtCall(CrossChainCall memory c) internal view returns (string memory) {
        string memory func = c.data.length == 0 ? "(ETH transfer)" : string.concat(".", _funcName(bytes4(c.data)), "()");
        string memory valStr = c.value > 0 ? string.concat("  value=", _fmtEther(c.value)) : "";
        string memory revertStr =
            c.revertNextNCalls > 0 ? string.concat("  revertNextNCalls=", vm.toString(c.revertNextNCalls)) : "";
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
            "NESTED expectedL1toL2Hash=",
            _shortHash(n.expectedL1toL2Hash),
            "  success=",
            n.success ? "true" : "false",
            "  subCalls=",
            vm.toString(n.l2ToL1Calls.length),
            "  retData=",
            _shortBytes(n.returnData)
        );
    }

    function _fmtNested(ExpectedOutgoingCrossChainCall memory n) internal pure returns (string memory) {
        return string.concat(
            "NESTED expectedOutgoingHash=",
            _shortHash(n.expectedOutgoingHash),
            "  success=",
            n.success ? "true" : "false",
            "  subCalls=",
            vm.toString(n.incomingCalls.length),
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
        bool l2tx = e.proxyEntryHash == bytes32(0);
        console.log("  [%s] %s  entryHash=%s", idx, l2tx ? "L2TX" : "PROXY", vm.toString(hash));
        console.log("      proxyEntryHash:  %s", vm.toString(e.proxyEntryHash));
        console.log("      rollingHash: %s", vm.toString(e.rollingHash));
        console.log(
            "      success=%s  calls=%s  nested=%s",
            e.success ? "true" : "false",
            e.l2ToL1Calls.length,
            e.expectedL1ToL2Calls.length
        );

        for (uint256 d = 0; d < e.rollupUpdates.length; d++) {
            RollupUpdate memory sd = e.rollupUpdates[d];
            string memory etherStr =
                sd.etherDelta == 0 ? "" : string.concat("  ether: ", _fmtEtherSigned(sd.etherDelta));
            console.log(
                string.concat(
                    "      state: rollup ", vm.toString(sd.rollupId), " -> ", _shortHash(sd.newRoot), etherStr
                )
            );
        }
        for (uint256 c = 0; c < e.l2ToL1Calls.length; c++) {
            console.log(string.concat("      ", _fmtCall(e.l2ToL1Calls[c])));
        }
        for (uint256 n = 0; n < e.expectedL1ToL2Calls.length; n++) {
            console.log(string.concat("      ", _fmtNested(e.expectedL1ToL2Calls[n])));
        }
        if (e.returnData.length > 0) {
            console.log("      returnData: %s", _shortBytes(e.returnData));
        }
    }

    /// @notice L2 entry (no state deltas, no ether tracking).
    function _logL2Entry(uint256 idx, L2ExecutionEntry memory e) internal view {
        bytes32 hash = _entryHash(e);
        console.log("  [%s] entryHash=%s", idx, vm.toString(hash));
        console.log("      proxyEntryHash:  %s", vm.toString(e.proxyEntryHash));
        console.log("      rollingHash: %s", vm.toString(e.rollingHash));
        console.log(
            "      success=%s  calls=%s  nested=%s",
            e.success ? "true" : "false",
            e.incomingCalls.length,
            e.expectedOutgoingCalls.length
        );
        for (uint256 c = 0; c < e.incomingCalls.length; c++) {
            console.log(string.concat("      ", _fmtCall(e.incomingCalls[c])));
        }
        for (uint256 n = 0; n < e.expectedOutgoingCalls.length; n++) {
            console.log(string.concat("      ", _fmtNested(e.expectedOutgoingCalls[n])));
        }
        if (e.returnData.length > 0) {
            console.log("      returnData: %s", _shortBytes(e.returnData));
        }
    }

    function _logStaticLookup(uint256 idx, StaticExecutionEntry memory sc) internal view {
        console.log("  [%s] TOP-LEVEL STATIC proxyEntryHash=%s", idx, vm.toString(sc.proxyEntryHash));
        console.log(
            "      success=%s  rootPins=%s  subCalls=%s",
            sc.success ? "true" : "false",
            vm.toString(sc.expectedRoots.length),
            vm.toString(sc.l2ToL1Calls.length)
        );
        if (sc.returnData.length > 0) {
            console.log("      returnData: %s", _shortBytes(sc.returnData));
        }
    }

    function _logStaticLookup(uint256 idx, L2StaticExecutionEntry memory sc) internal view {
        console.log("  [%s] TOP-LEVEL STATIC proxyEntryHash=%s", idx, vm.toString(sc.proxyEntryHash));
        console.log(
            "      success=%s  subCalls=%s", sc.success ? "true" : "false", vm.toString(sc.incomingCalls.length)
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
                vm.toString(e.l2ToL1Calls.length),
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
