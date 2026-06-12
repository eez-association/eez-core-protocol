// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DecodeExecutions
/// @notice Decodes cross-chain events from a block (or recorded logs) and shows the
///         execution flow. Works against the post-multi-prover ABI: events on both
///         L1 (EEZ.sol) and L2 (EEZL2.sol).
///
/// NOTE: Pre-execution entry payload is NOT decoded by this script.
///       Post-refactor, `BatchPosted(uint256 rollupCount)` carries only the
///       number of rollups verified; the full `ExecutionEntry[]` payload lives in the
///       `postAndVerifyBatch` transaction input calldata. Decoding tx input from inside
///       a Forge script is awkward (no direct cheatcode for it), so this
///       decoder reports execution flow purely from emitted events. The events
///       it relies on are rich enough for almost all debugging use cases:
///       BatchPosted, RollupCreated, StateUpdated,
///       L2ExecutionPerformed, ImmediateEntrySkipped, ExecutionConsumed,
///       L2TXExecuted, EntryExecuted, CrossChainCallExecuted, CallResult,
///       L1ToL2CallConsumed (L1) / OutgoingCallConsumed (L2), RevertSpanExecuted,
///       CrossChainProxyCreated,
///       and the L2-only ExecutionTableLoaded / IncomingCrossChainCallExecuted.
///       For a full pre-execution dump of entries, decode the postAndVerifyBatch tx
///       input off-chain (e.g. with `cast calldata-decode`).
///
/// Usage:
///   forge script script/DecodeExecutions.s.sol:DecodeExecutions \
///     --rpc-url <RPC> --sig "runBlock(uint256,address)" <BLOCK> <CONTRACT>
contract DecodeExecutions is Script {
    // ── Event signatures (L1 + L2 share most of these) ──
    bytes32 constant SIG_BATCH_POSTED = keccak256("BatchPosted(uint256)");
    bytes32 constant SIG_ROLLUP_CREATED = keccak256("RollupCreated(uint256,address,bytes32)");
    bytes32 constant SIG_STATE_UPDATED = keccak256("StateUpdated(uint256,bytes32)");
    bytes32 constant SIG_L2_EXEC_PERFORMED = keccak256("L2ExecutionPerformed(uint256,bytes32)");
    bytes32 constant SIG_IMMEDIATE_SKIPPED = keccak256("ImmediateEntrySkipped(uint256,bytes)");
    bytes32 constant SIG_EXECUTION_CONSUMED_L1 = keccak256("ExecutionConsumed(bytes32,uint256,uint256)");
    bytes32 constant SIG_EXECUTION_CONSUMED_L2 = keccak256("ExecutionConsumed(bytes32,uint256)");
    bytes32 constant SIG_L2TX_EXECUTED = keccak256("L2TXExecuted(uint256,uint256)");
    bytes32 constant SIG_ENTRY_EXECUTED = keccak256("EntryExecuted(uint256,bytes32,uint256,uint256)");
    bytes32 constant SIG_CROSSCHAIN_CALL_EXECUTED =
        keccak256("CrossChainCallExecuted(bytes32,address,address,bytes,uint256)");
    bytes32 constant SIG_CALL_RESULT = keccak256("CallResult(uint256,uint256,bool,bytes)");
    bytes32 constant SIG_L1_TO_L2_CALL_CONSUMED = keccak256("L1ToL2CallConsumed(uint256,uint256,bytes32,uint256)");
    bytes32 constant SIG_OUTGOING_CALL_CONSUMED = keccak256("OutgoingCallConsumed(uint256,uint256,bytes32,uint256)");
    bytes32 constant SIG_REVERT_SPAN = keccak256("RevertSpanExecuted(uint256,uint256,uint256)");
    bytes32 constant SIG_PROXY_CREATED = keccak256("CrossChainProxyCreated(address,address,uint256)");
    // L2-only:
    bytes32 constant SIG_TABLE_LOADED = keccak256(
        "ExecutionTableLoaded((bytes32,(address,uint256,bytes,address,uint256,uint256)[],(bytes32,uint256,bytes)[],uint256,bytes,bytes32)[])"
    );
    bytes32 constant SIG_INCOMING_CALL =
        keccak256("IncomingCrossChainCallExecuted(bytes32,address,uint256,bytes,address,uint256)");

    // ──────────────────── Public entry points ────────────────────

    function runBlock(uint256 blockNumber, address target) external view {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blockNumber, blockNumber, target, topics);

        console.log("================================================================");
        console.log("BLOCK %s | %s logs | target %s", blockNumber, logs.length, vm.toString(target));
        console.log("================================================================");

        _processBlock(logs);
    }

    /// @notice Decode a Vm.Log[] array (e.g. from vm.recordLogs / vm.getRecordedLogs).
    function decodeRecordedLogs(Vm.Log[] memory logs) external view {
        console.log("================================================================");
        console.log("RECORDED LOGS | %s logs", logs.length);
        console.log("================================================================");

        // Convert Vm.Log[] to a uniform shape — recorded logs have no tx hash,
        // so we lump everything into one synthetic "tx".
        for (uint256 i = 0; i < logs.length; i++) {
            _printLog(logs[i].topics, logs[i].data, logs[i].emitter, "    ");
        }
    }

    // ──────────────────── Block processing ────────────────────

    function _processBlock(Vm.EthGetLogs[] memory logs) internal view {
        if (logs.length == 0) {
            console.log("(no logs)");
            return;
        }

        // Group sequentially by tx hash (logs from eth_getLogs come in order).
        bytes32 currentTx = bytes32(0);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].transactionHash != currentTx) {
                if (i > 0) console.log("");
                console.log("---- tx %s ----", vm.toString(logs[i].transactionHash));
                currentTx = logs[i].transactionHash;
            }
            _printLog(logs[i].topics, logs[i].data, logs[i].emitter, "    ");
        }

        // One-line summary
        console.log("");
        console.log("  SUMMARY: %s", _buildSummary(logs));
    }

    // ──────────────────── Per-log dispatcher ────────────────────

    function _printLog(bytes32[] memory topics, bytes memory data, address emitter, string memory p) internal pure {
        if (topics.length == 0) {
            console.log(string.concat(p, "(anonymous log from ", _shortAddr(emitter), ")"));
            return;
        }

        bytes32 sig = topics[0];

        if (sig == SIG_BATCH_POSTED) {
            _printBatchPosted(topics, p);
        } else if (sig == SIG_ROLLUP_CREATED) {
            _printRollupCreated(topics, data, p);
        } else if (sig == SIG_STATE_UPDATED) {
            _printStateUpdated(topics, data, p);
        } else if (sig == SIG_L2_EXEC_PERFORMED) {
            _printL2ExecPerformed(topics, data, p);
        } else if (sig == SIG_IMMEDIATE_SKIPPED) {
            _printImmediateSkipped(topics, data, p);
        } else if (sig == SIG_EXECUTION_CONSUMED_L1) {
            _printExecutionConsumedL1(topics, p);
        } else if (sig == SIG_EXECUTION_CONSUMED_L2) {
            _printExecutionConsumedL2(topics, p);
        } else if (sig == SIG_L2TX_EXECUTED) {
            _printL2TXExecuted(topics, p);
        } else if (sig == SIG_ENTRY_EXECUTED) {
            _printEntryExecuted(topics, data, p);
        } else if (sig == SIG_CROSSCHAIN_CALL_EXECUTED) {
            _printCrossChainCallExecuted(topics, data, p);
        } else if (sig == SIG_CALL_RESULT) {
            _printCallResult(topics, data, p);
        } else if (sig == SIG_L1_TO_L2_CALL_CONSUMED) {
            _printNestedCallConsumed(topics, data, p, "L1ToL2CallConsumed");
        } else if (sig == SIG_OUTGOING_CALL_CONSUMED) {
            _printNestedCallConsumed(topics, data, p, "OutgoingCallConsumed");
        } else if (sig == SIG_REVERT_SPAN) {
            _printRevertSpan(topics, data, p);
        } else if (sig == SIG_PROXY_CREATED) {
            _printProxyCreated(topics, p);
        } else if (sig == SIG_TABLE_LOADED) {
            console.log(string.concat(p, "ExecutionTableLoaded (full entries in tx input)"));
        } else if (sig == SIG_INCOMING_CALL) {
            _printIncomingCall(topics, data, p);
        } else {
            console.log(string.concat(p, "(unknown event sig=", _shortHash(sig), " from ", _shortAddr(emitter), ")"));
        }
    }

    // ──────────────────── Per-event formatters ────────────────────

    function _printBatchPosted(bytes32[] memory topics, string memory p) internal pure {
        // event BatchPosted(uint256 indexed rollupCount)
        uint256 count = uint256(topics[1]);
        console.log(string.concat(p, "BatchPosted(rollups=", vm.toString(count), ")"));
    }

    function _printRollupCreated(bytes32[] memory topics, bytes memory data, string memory p) internal pure {
        // event RollupCreated(uint256 indexed rollupId, address indexed rollupContract, bytes32 initialState)
        uint256 rollupId = uint256(topics[1]);
        address rollupContract = address(uint160(uint256(topics[2])));
        bytes32 initialState = abi.decode(data, (bytes32));
        console.log(
            string.concat(
                p,
                "RollupCreated(id=",
                vm.toString(rollupId),
                ", contract=",
                _shortAddr(rollupContract),
                ", initState=",
                _shortHash(initialState),
                ")"
            )
        );
    }

    function _printStateUpdated(bytes32[] memory topics, bytes memory data, string memory p) internal pure {
        // StateUpdated(uint256 indexed rollupId, bytes32 newStateRoot)
        uint256 rollupId = uint256(topics[1]);
        bytes32 newState = abi.decode(data, (bytes32));
        console.log(
            string.concat(p, "StateUpdated(id=", vm.toString(rollupId), ", newState=", _shortHash(newState), ")")
        );
    }

    function _printL2ExecPerformed(bytes32[] memory topics, bytes memory data, string memory p) internal pure {
        // L2ExecutionPerformed(uint256 indexed rollupId, bytes32 newState)
        uint256 rollupId = uint256(topics[1]);
        bytes32 newState = abi.decode(data, (bytes32));
        console.log(
            string.concat(
                p, "L2ExecutionPerformed(rollup=", vm.toString(rollupId), ", newState=", _shortHash(newState), ")"
            )
        );
    }

    function _printImmediateSkipped(bytes32[] memory topics, bytes memory data, string memory p) internal pure {
        // ImmediateEntrySkipped(uint256 indexed transientIdx, bytes revertData)
        uint256 idx = uint256(topics[1]);
        bytes memory revertData = abi.decode(data, (bytes));
        console.log(
            string.concat(
                p, "ImmediateEntrySkipped(idx=", vm.toString(idx), ", revertData=", _shortBytes(revertData), ")"
            )
        );
    }

    function _printExecutionConsumedL1(bytes32[] memory topics, string memory p) internal pure {
        // ExecutionConsumed(bytes32 indexed crossChainCallHash, uint256 indexed rollupId, uint256 indexed executionQueueIndex)
        bytes32 cchash = topics[1];
        uint256 rollupId = uint256(topics[2]);
        uint256 cursor = uint256(topics[3]);
        console.log(
            string.concat(
                p,
                "ExecutionConsumed(hash=",
                _shortHash(cchash),
                ", rollup=",
                vm.toString(rollupId),
                ", cursor=",
                vm.toString(cursor),
                ")"
            )
        );
    }

    function _printExecutionConsumedL2(bytes32[] memory topics, string memory p) internal pure {
        // L2 variant: ExecutionConsumed(bytes32 indexed crossChainCallHash, uint256 indexed executionQueueIndex)
        bytes32 cchash = topics[1];
        uint256 entryIndex = uint256(topics[2]);
        console.log(
            string.concat(
                p, "ExecutionConsumed(hash=", _shortHash(cchash), ", entryIdx=", vm.toString(entryIndex), ")  [L2]"
            )
        );
    }

    function _printL2TXExecuted(bytes32[] memory topics, string memory p) internal pure {
        // L2TXExecuted(uint256 indexed rollupId, uint256 indexed executionQueueIndex)
        uint256 rollupId = uint256(topics[1]);
        uint256 cursor = uint256(topics[2]);
        console.log(
            string.concat(p, "L2TXExecuted(rollup=", vm.toString(rollupId), ", cursor=", vm.toString(cursor), ")")
        );
    }

    function _printEntryExecuted(bytes32[] memory topics, bytes memory data, string memory p) internal pure {
        // EntryExecuted(uint256 indexed entryIndex, bytes32 rollingHash, uint256 callsProcessed, uint256 nestedConsumed)
        // (L1: l2ToL1CallsProcessed/l1ToL2CallsConsumed; L2: callsProcessed/outgoingCallsConsumed — same ABI)
        uint256 entryIndex = uint256(topics[1]);
        (bytes32 rollingHash, uint256 callsProcessed, uint256 nestedConsumed) =
            abi.decode(data, (bytes32, uint256, uint256));
        console.log(
            string.concat(
                p,
                "EntryExecuted(idx=",
                vm.toString(entryIndex),
                ", rollingHash=",
                _shortHash(rollingHash),
                ", calls=",
                vm.toString(callsProcessed),
                ", nested=",
                vm.toString(nestedConsumed),
                ")"
            )
        );
    }

    function _printCrossChainCallExecuted(bytes32[] memory topics, bytes memory data, string memory p) internal pure {
        // CrossChainCallExecuted(bytes32 indexed cchash, address indexed proxy, address sourceAddress, bytes callData, uint256 value)
        bytes32 cchash = topics[1];
        address proxy = address(uint160(uint256(topics[2])));
        (address sourceAddress, bytes memory callData, uint256 value) = abi.decode(data, (address, bytes, uint256));
        console.log(
            string.concat(
                p,
                "CrossChainCallExecuted(hash=",
                _shortHash(cchash),
                ", proxy=",
                _shortAddr(proxy),
                ", src=",
                _shortAddr(sourceAddress),
                ", value=",
                vm.toString(value),
                ", call=",
                _selectorName(callData),
                ")"
            )
        );
    }

    function _printCallResult(bytes32[] memory topics, bytes memory data, string memory p) internal pure {
        // CallResult(uint256 indexed entryIndex, uint256 indexed callNumber, bool success, bytes returnData)
        uint256 entryIndex = uint256(topics[1]);
        uint256 callNumber = uint256(topics[2]);
        (bool success, bytes memory ret) = abi.decode(data, (bool, bytes));
        console.log(
            string.concat(
                p,
                "CallResult(entry=",
                vm.toString(entryIndex),
                ", call#=",
                vm.toString(callNumber),
                ", ",
                success ? "ok" : "FAILED",
                ", ret=",
                _shortBytes(ret),
                ")"
            )
        );
    }

    function _printNestedCallConsumed(bytes32[] memory topics, bytes memory data, string memory p, string memory name)
        internal
        pure
    {
        // L1: L1ToL2CallConsumed(uint256 indexed entryIndex, uint256 indexed l1ToL2CallNumber, bytes32 cchash, uint256 callCount)
        // L2: OutgoingCallConsumed(uint256 indexed entryIndex, uint256 indexed nestedNumber, bytes32 cchash, uint256 callCount)
        uint256 entryIndex = uint256(topics[1]);
        uint256 nestedNumber = uint256(topics[2]);
        (bytes32 cchash, uint256 callCount) = abi.decode(data, (bytes32, uint256));
        console.log(
            string.concat(
                p,
                name,
                "(entry=",
                vm.toString(entryIndex),
                ", nested#=",
                vm.toString(nestedNumber),
                ", hash=",
                _shortHash(cchash),
                ", callCount=",
                vm.toString(callCount),
                ")"
            )
        );
    }

    function _printRevertSpan(bytes32[] memory topics, bytes memory data, string memory p) internal pure {
        // RevertSpanExecuted(uint256 indexed entryIndex, uint256 startCallNumber, uint256 span)
        uint256 entryIndex = uint256(topics[1]);
        (uint256 startCallNumber, uint256 span) = abi.decode(data, (uint256, uint256));
        console.log(
            string.concat(
                p,
                "RevertSpanExecuted(entry=",
                vm.toString(entryIndex),
                ", start=",
                vm.toString(startCallNumber),
                ", span=",
                vm.toString(span),
                ")"
            )
        );
    }

    function _printProxyCreated(bytes32[] memory topics, string memory p) internal pure {
        // CrossChainProxyCreated(address indexed proxy, address indexed originalAddress, uint256 indexed originalRollupId)
        address proxy = address(uint160(uint256(topics[1])));
        address original = address(uint160(uint256(topics[2])));
        uint256 originalRollupId = uint256(topics[3]);
        console.log(
            string.concat(
                p,
                "CrossChainProxyCreated(proxy=",
                _shortAddr(proxy),
                ", original=",
                _shortAddr(original),
                ", origRollupId=",
                vm.toString(originalRollupId),
                ")"
            )
        );
    }

    function _printIncomingCall(bytes32[] memory topics, bytes memory data, string memory p) internal pure {
        // IncomingCrossChainCallExecuted(bytes32 indexed cchash, address dest, uint256 value, bytes data, address src, uint256 srcRollup)
        bytes32 cchash = topics[1];
        (address dest, uint256 value, bytes memory innerData, address src, uint256 srcRollup) =
            abi.decode(data, (address, uint256, bytes, address, uint256));
        console.log(
            string.concat(
                p,
                "IncomingCrossChainCallExecuted(hash=",
                _shortHash(cchash),
                ", dest=",
                _shortAddr(dest),
                ", value=",
                vm.toString(value),
                ", src=",
                _shortAddr(src),
                ", srcRollup=",
                vm.toString(srcRollup),
                ", call=",
                _selectorName(innerData),
                ")"
            )
        );
    }

    // ──────────────────── Summary ────────────────────

    function _buildSummary(Vm.EthGetLogs[] memory logs) internal pure returns (string memory line) {
        // Walk events and produce a compact one-liner
        uint256 batches;
        uint256 entriesExec;
        uint256 callsExec;
        uint256 callsFailed;
        uint256 nested;
        uint256 reverts;
        uint256 l2tx;
        uint256 immediateSkipped;
        uint256 stateUpdates;
        uint256 proxiesCreated;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            bytes32 sig = logs[i].topics[0];
            if (sig == SIG_BATCH_POSTED) {
                batches++;
            } else if (sig == SIG_ENTRY_EXECUTED) {
                entriesExec++;
            } else if (sig == SIG_CALL_RESULT) {
                callsExec++;
                (bool success,) = abi.decode(logs[i].data, (bool, bytes));
                if (!success) callsFailed++;
            } else if (sig == SIG_L1_TO_L2_CALL_CONSUMED || sig == SIG_OUTGOING_CALL_CONSUMED) {
                nested++;
            } else if (sig == SIG_REVERT_SPAN) {
                reverts++;
            } else if (sig == SIG_L2TX_EXECUTED) {
                l2tx++;
            } else if (sig == SIG_IMMEDIATE_SKIPPED) {
                immediateSkipped++;
            } else if (sig == SIG_STATE_UPDATED) {
                stateUpdates++;
            } else if (sig == SIG_PROXY_CREATED) {
                proxiesCreated++;
            }
        }

        line = string.concat(
            "batches=",
            vm.toString(batches),
            " entries=",
            vm.toString(entriesExec),
            " calls=",
            vm.toString(callsExec),
            "(failed=",
            vm.toString(callsFailed),
            ") nested=",
            vm.toString(nested),
            " revertSpans=",
            vm.toString(reverts),
            " l2tx=",
            vm.toString(l2tx),
            " skipped=",
            vm.toString(immediateSkipped),
            " stateUpdates=",
            vm.toString(stateUpdates),
            " proxies=",
            vm.toString(proxiesCreated)
        );
    }

    // ──────────────────── String helpers ────────────────────

    function _shortAddr(address a) internal pure returns (string memory) {
        if (a == address(0)) return "0x0";
        string memory full = vm.toString(a);
        return string.concat(_substring(full, 0, 6), "..", _substring(full, 38, 42));
    }

    function _shortHash(bytes32 h) internal pure returns (string memory) {
        string memory full = vm.toString(h);
        return string.concat(_substring(full, 0, 6), "..", _substring(full, 62, 66));
    }

    function _shortBytes(bytes memory b) internal pure returns (string memory) {
        if (b.length == 0) return "0x";
        if (b.length <= 32) return vm.toString(b);
        // Truncate long byte arrays
        bytes memory head = new bytes(16);
        for (uint256 i = 0; i < 16; i++) {
            head[i] = b[i];
        }
        return string.concat(vm.toString(head), "..(len=", vm.toString(b.length), ")");
    }

    function _selectorName(bytes memory data) internal pure returns (string memory) {
        if (data.length < 4) return "()";
        bytes4 sel = bytes4(data[0]) | (bytes4(data[1]) >> 8) | (bytes4(data[2]) >> 16) | (bytes4(data[3]) >> 24);
        if (sel == bytes4(keccak256("increment()"))) return "increment()";
        if (sel == bytes4(keccak256("decrement()"))) return "decrement()";
        if (sel == bytes4(keccak256("setNumber(uint256)"))) return "setNumber(uint256)";
        if (sel == bytes4(keccak256("incrementProxy()"))) return "incrementProxy()";
        if (sel == bytes4(keccak256("hello()"))) return "hello()";
        if (sel == bytes4(keccak256("number()"))) return "number()";
        if (sel == bytes4(keccak256("greet()"))) return "greet()";
        if (sel == bytes4(keccak256("greet(string)"))) return "greet(string)";
        if (sel == bytes4(keccak256("executeCrossChainCall(address,bytes)"))) {
            return "executeCrossChainCall(address,bytes)";
        }
        if (sel == bytes4(keccak256("staticCallLookup(address,bytes)"))) return "staticCallLookup(address,bytes)";
        // Fall back to raw 4-byte selector
        return vm.toString(abi.encodePacked(sel));
    }

    function _substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (endIndex > strBytes.length) endIndex = strBytes.length;
        if (startIndex >= endIndex) return "";
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }
}
