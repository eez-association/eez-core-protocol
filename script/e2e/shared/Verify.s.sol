// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {StateDelta, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry, LookupCall} from "../../../src/interfaces/IEEZ.sol";

// ══════════════════════════════════════════════════════════════════════
//  Shared helpers — event signatures + formatting
// ══════════════════════════════════════════════════════════════════════

abstract contract VerifyHelpers is Script {
    // BatchPosted(uint256 subBatchCount)
    // POST-REFACTOR: BatchPosted no longer carries the full entries array — the on-chain
    // event was simplified to just the sub-batch count. Off-chain decoders that need the
    // entries should subscribe to ExecutionConsumed / EntryExecuted instead.
    bytes32 constant SIG_BATCH_POSTED = keccak256("BatchPosted(uint256)");

    // ExecutionConsumed on L1: (bytes32 crossChainCallHash, uint256 rollupId, uint256 cursor)
    bytes32 constant SIG_EXECUTION_CONSUMED_L1 = keccak256("ExecutionConsumed(bytes32,uint256,uint256)");

    // IncomingCrossChainCallExecuted on L2: emitted by `executeIncomingCrossChainCall`.
    bytes32 constant SIG_INCOMING_CROSSCHAIN_CALL =
        keccak256("IncomingCrossChainCallExecuted(bytes32,address,uint256,bytes,address,uint256)");

    // ExecutionTableLoaded(ExecutionEntry[] entries) — L2 only.
    //   ExecutionEntry = (StateDelta[], bytes32, uint256, L2ToL1Call[], ExpectedL1ToL2Call[], uint256, bytes, bytes32)
    //                       deltas        cchHash  destRid  calls            nested            cnt   ret    rollingHash
    //   StateDelta     = (uint256, bytes32, bytes32, int256)
    //                     rid       curr     new      etherDelta
    //   L2ToL1Call = (address, uint256, bytes, address, uint256, uint256)
    //   ExpectedL1ToL2Call   = (bytes32, uint256, bytes)
    bytes32 constant SIG_TABLE_LOADED = keccak256(
        "ExecutionTableLoaded(((uint256,bytes32,bytes32,int256)[],bytes32,uint256,(address,uint256,bytes,address,uint256,uint256)[],(bytes32,uint256,bytes)[],uint256,bytes,bytes32)[])"
    );

    // CrossChainCallExecuted(bytes32 crossChainCallHash, address proxy, address sourceAddress, bytes callData, uint256 value)
    bytes32 constant SIG_CROSSCHAIN_CALL = keccak256("CrossChainCallExecuted(bytes32,address,address,bytes,uint256)");

    function _entryHash(ExecutionEntry memory e) internal pure returns (bytes32) {
        return keccak256(abi.encode(e.proxyEntryHash, e.rollingHash));
    }

    function _shortHash(bytes32 h) internal pure returns (string memory) {
        string memory full = vm.toString(h);
        return string.concat(_sub(full, 0, 6), "..", _sub(full, 62, 66));
    }

    function _shortBytes(bytes memory b) internal pure returns (string memory) {
        if (b.length == 0) return "0x";
        if (b.length <= 36) return vm.toString(b);
        string memory full = vm.toString(b);
        return string.concat(_sub(full, 0, 10), "...(", vm.toString(b.length), " bytes)");
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

    function _printEntryDetailed(uint256 idx, ExecutionEntry memory e) internal pure {
        bool immediate = e.proxyEntryHash == bytes32(0);
        console.log(
            "  [%s] %s  crossChainCallHash=%s", idx, immediate ? "IMMEDIATE" : "DEFERRED", vm.toString(e.proxyEntryHash)
        );
        console.log("      rollingHash: %s", vm.toString(e.rollingHash));
        console.log(
            "      callCount=%s  calls=%s  nested=%s", e.callCount, e.L2ToL1Calls.length, e.expectedL1ToL2Calls.length
        );
        for (uint256 d = 0; d < e.stateDeltas.length; d++) {
            StateDelta memory sd = e.stateDeltas[d];
            console.log(
                string.concat(
                    "      stateDelta: rollup ",
                    vm.toString(sd.rollupId),
                    " -> ",
                    _shortHash(sd.newState),
                    "  ether=",
                    vm.toString(sd.etherDelta)
                )
            );
        }
        for (uint256 c = 0; c < e.L2ToL1Calls.length; c++) {
            L2ToL1Call memory cc = e.L2ToL1Calls[c];
            console.log(
                string.concat(
                    "      call[",
                    vm.toString(c),
                    "]: target=",
                    vm.toString(cc.targetAddress),
                    "  value=",
                    vm.toString(cc.value),
                    "  revertSpan=",
                    vm.toString(cc.revertSpan)
                )
            );
            console.log(
                string.concat(
                    "               from=",
                    vm.toString(cc.sourceAddress),
                    " @ rollup ",
                    vm.toString(cc.sourceRollupId),
                    "  data=",
                    _shortBytes(cc.data)
                )
            );
        }
        for (uint256 n = 0; n < e.expectedL1ToL2Calls.length; n++) {
            ExpectedL1ToL2Call memory na = e.expectedL1ToL2Calls[n];
            console.log(
                string.concat(
                    "      nested[",
                    vm.toString(n),
                    "]: crossChainCallHash=",
                    _shortHash(na.crossChainCallHash),
                    "  callCount=",
                    vm.toString(na.callCount)
                )
            );
        }
        if (e.returnData.length > 0) {
            console.log("      returnData: %s", _shortBytes(e.returnData));
        }
        // POST-REFACTOR: ExecutionEntry.failed was removed. Reverting top-level cross-chain
        // calls are now expressed via LookupCall, not via a flag on ExecutionEntry.
        console.log("      entryHash: %s", vm.toString(_entryHash(e)));
    }

    // ── Log collection: decode BatchPosted ──

    function _collectBatchEntries(Vm.EthGetLogs[] memory logs) internal pure returns (ExecutionEntry[] memory) {
        uint256 totalCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_BATCH_POSTED) {
                (ExecutionEntry[] memory entries,) = abi.decode(logs[i].data, (ExecutionEntry[], bytes32));
                totalCount += entries.length;
            }
        }
        ExecutionEntry[] memory all = new ExecutionEntry[](totalCount);
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_BATCH_POSTED) {
                (ExecutionEntry[] memory entries,) = abi.decode(logs[i].data, (ExecutionEntry[], bytes32));
                for (uint256 j = 0; j < entries.length; j++) {
                    all[idx++] = entries[j];
                }
            }
        }
        return all;
    }

    // ── Log collection: decode ExecutionTableLoaded ──

    function _collectTableEntries(Vm.EthGetLogs[] memory logs) internal pure returns (ExecutionEntry[] memory) {
        uint256 totalCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_TABLE_LOADED) {
                ExecutionEntry[] memory entries = abi.decode(logs[i].data, (ExecutionEntry[]));
                totalCount += entries.length;
            }
        }
        ExecutionEntry[] memory all = new ExecutionEntry[](totalCount);
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_TABLE_LOADED) {
                ExecutionEntry[] memory entries = abi.decode(logs[i].data, (ExecutionEntry[]));
                for (uint256 j = 0; j < entries.length; j++) {
                    all[idx++] = entries[j];
                }
            }
        }
        return all;
    }

    function _findMissingHashes(bytes32[] memory actual, bytes32[] calldata expected)
        internal
        pure
        returns (bytes32[] memory)
    {
        bytes32[] memory tmp = new bytes32[](expected.length);
        uint256 count;
        for (uint256 i = 0; i < expected.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < actual.length; j++) {
                if (actual[j] == expected[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) tmp[count++] = expected[i];
        }
        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = tmp[i];
        }
        return result;
    }
}

// ══════════════════════════════════════════════════════════════════════
//  VerifyL1Batch — check BatchPosted logs in a given block contain
//  all expected entry hashes (subset match).
// ══════════════════════════════════════════════════════════════════════

contract VerifyL1Batch is VerifyHelpers {
    /// @dev Input is the LIST OF EXPECTED CROSS-CHAIN-CALL HASHES (`proxyEntryHash` values)
    /// that should have been consumed in the L1 block. The current branch's `BatchPosted`
    /// event no longer carries entries; consumption is signalled via `ExecutionConsumed`
    /// whose first topic is the consumed entry's `crossChainCallHash`. This verifier
    /// extracts those hashes and checks every expected hash is present.
    function run(uint256 blockNumber, address rollups, bytes32[] calldata expectedCallHashes) external view {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blockNumber, blockNumber, rollups, topics);

        // Collect every consumed call hash from ExecutionConsumed events in this block.
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_EXECUTION_CONSUMED_L1) count++;
        }
        bytes32[] memory actualHashes = new bytes32[](count);
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_EXECUTION_CONSUMED_L1) {
                actualHashes[idx++] = logs[i].topics[1]; // indexed crossChainCallHash
            }
        }

        bytes32[] memory missing = _findMissingHashes(actualHashes, expectedCallHashes);

        if (missing.length > 0) {
            console.log(
                "FAIL: %s/%s expected call hashes missing in L1 block %s",
                missing.length,
                expectedCallHashes.length,
                blockNumber
            );
            console.log("");
            console.log("=== ACTUAL CONSUMED HASHES (L1 block %s, %s) ===", blockNumber, actualHashes.length);
            for (uint256 i = 0; i < actualHashes.length; i++) {
                console.log("  %s", vm.toString(actualHashes[i]));
            }
            console.log("");
            console.log("=== MISSING CALL HASHES ===");
            for (uint256 i = 0; i < missing.length; i++) {
                console.log("  %s", vm.toString(missing[i]));
            }
            revert("Verification failed");
        }

        console.log(
            "PASS: %s/%s expected call hashes consumed in L1 block %s",
            expectedCallHashes.length,
            expectedCallHashes.length,
            blockNumber
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_BATCH_POSTED) {
                console.log("L1_BATCH_TX=%s", vm.toString(logs[i].transactionHash));
                break;
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
//  VerifyL2Blocks — check ExecutionTableLoaded events in one of the
//  given blocks contain all expected entry hashes.
// ══════════════════════════════════════════════════════════════════════

contract VerifyL2Blocks is VerifyHelpers {
    function run(uint256[] calldata l2Blocks, address managerL2, bytes32[] calldata expectedEntryHashes) external view {
        if (l2Blocks.length == 0) {
            console.log("FAIL: no L2 blocks to check");
            revert("No L2 blocks");
        }

        for (uint256 i = 0; i < l2Blocks.length; i++) {
            ExecutionEntry[] memory entries = _getEntries(l2Blocks[i], managerL2);
            if (_allPresent(entries, expectedEntryHashes)) {
                console.log(
                    "PASS: all %s expected entries found at L2 block %s", expectedEntryHashes.length, l2Blocks[i]
                );
                bytes32[] memory topics = new bytes32[](0);
                Vm.EthGetLogs[] memory blkLogs = vm.eth_getLogs(l2Blocks[i], l2Blocks[i], managerL2, topics);
                for (uint256 j = 0; j < blkLogs.length; j++) {
                    if (blkLogs[j].topics[0] == SIG_TABLE_LOADED) {
                        console.log("L2_TABLE_TX=%s", vm.toString(blkLogs[j].transactionHash));
                        break;
                    }
                }
                return;
            }
        }

        console.log("FAIL: expected entries not found in any of %s L2 blocks", l2Blocks.length);
        for (uint256 i = 0; i < l2Blocks.length; i++) {
            ExecutionEntry[] memory entries = _getEntries(l2Blocks[i], managerL2);
            console.log("");
            console.log("=== L2 BLOCK %s (%s entries) ===", l2Blocks[i], entries.length);
            for (uint256 j = 0; j < entries.length; j++) {
                _printEntryDetailed(j, entries[j]);
            }
        }
        console.log("");
        console.log("=== MISSING ENTRY HASHES ===");
        for (uint256 i = 0; i < expectedEntryHashes.length; i++) {
            console.log("  %s", vm.toString(expectedEntryHashes[i]));
        }
        revert("Verification failed");
    }

    function _getEntries(uint256 blockNumber, address managerL2) internal view returns (ExecutionEntry[] memory) {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blockNumber, blockNumber, managerL2, topics);
        return _collectTableEntries(logs);
    }

    function _allPresent(ExecutionEntry[] memory entries, bytes32[] calldata expectedEntryHashes)
        internal
        pure
        returns (bool)
    {
        bytes32[] memory actualHashes = new bytes32[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            actualHashes[i] = _entryHash(entries[i]);
        }
        for (uint256 i = 0; i < expectedEntryHashes.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < actualHashes.length; j++) {
                if (actualHashes[j] == expectedEntryHashes[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }
}

// ══════════════════════════════════════════════════════════════════════
//  VerifyL2Calls — check CrossChainCallExecuted events on L2 match
//  expected action hashes (for L1→L2 direction).
// ══════════════════════════════════════════════════════════════════════

contract VerifyL2Calls is VerifyHelpers {
    function run(uint256[] calldata l2Blocks, address managerL2, bytes32[] calldata expectedCallHashes) external view {
        if (l2Blocks.length == 0) {
            console.log("FAIL: no L2 blocks to check");
            revert("No L2 blocks");
        }

        bytes32[] memory found = _collectActionHashes(l2Blocks, managerL2);
        bytes32[] memory missing = _findMissingHashes(found, expectedCallHashes);

        if (missing.length > 0) {
            console.log("FAIL: %s/%s expected L2 calls missing", missing.length, expectedCallHashes.length);
            console.log("");
            console.log("=== ACTUAL CROSS-CHAIN CALL HASHES ===");
            for (uint256 i = 0; i < found.length; i++) {
                console.log("  %s", vm.toString(found[i]));
            }
            console.log("");
            console.log("=== MISSING CALL HASHES ===");
            for (uint256 i = 0; i < missing.length; i++) {
                console.log("  %s", vm.toString(missing[i]));
            }
            revert("Verification failed");
        }

        console.log("PASS: %s/%s expected L2 calls verified", expectedCallHashes.length, expectedCallHashes.length);
        for (uint256 i = 0; i < l2Blocks.length; i++) {
            bytes32[] memory topics = new bytes32[](0);
            Vm.EthGetLogs[] memory blkLogs = vm.eth_getLogs(l2Blocks[i], l2Blocks[i], managerL2, topics);
            for (uint256 j = 0; j < blkLogs.length; j++) {
                if (blkLogs[j].topics[0] == SIG_CROSSCHAIN_CALL) {
                    console.log("L2_CALL_TX=%s", vm.toString(blkLogs[j].transactionHash));
                }
            }
        }
    }

    function _collectActionHashes(uint256[] calldata blocks, address managerL2)
        internal
        view
        returns (bytes32[] memory)
    {
        // Accept BOTH event signatures: CrossChainCallExecuted (emitted when a proxy on L2
        // calls into the manager via executeL1ToL2Call) AND IncomingCrossChainCallExecuted
        // (emitted when SYSTEM drives executeIncomingCrossChainCall). The crossChainCallHash
        // is the first indexed param of both, so topics[1] extracts it uniformly.
        uint256 count;
        for (uint256 i = 0; i < blocks.length; i++) {
            bytes32[] memory topics = new bytes32[](0);
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blocks[i], blocks[i], managerL2, topics);
            for (uint256 j = 0; j < logs.length; j++) {
                bytes32 sig = logs[j].topics[0];
                if (sig == SIG_CROSSCHAIN_CALL || sig == SIG_INCOMING_CROSSCHAIN_CALL) count++;
            }
        }
        bytes32[] memory result = new bytes32[](count);
        uint256 idx;
        for (uint256 i = 0; i < blocks.length; i++) {
            bytes32[] memory topics = new bytes32[](0);
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blocks[i], blocks[i], managerL2, topics);
            for (uint256 j = 0; j < logs.length; j++) {
                bytes32 sig = logs[j].topics[0];
                if (sig == SIG_CROSSCHAIN_CALL || sig == SIG_INCOMING_CROSSCHAIN_CALL) {
                    result[idx++] = logs[j].topics[1];
                }
            }
        }
        return result;
    }
}

// ══════════════════════════════════════════════════════════════════════
//  VerifyL2Absent — check specific entry hashes are NOT present on L2.
//  Used for terminal revert scenarios where no L2 table should exist.
// ══════════════════════════════════════════════════════════════════════

contract VerifyL2Absent is VerifyHelpers {
    function run(uint256[] calldata l2Blocks, address managerL2, bytes32[] calldata absentEntryHashes) external view {
        bytes32[] memory actualHashes = _collectEntryHashes(l2Blocks, managerL2);

        for (uint256 i = 0; i < absentEntryHashes.length; i++) {
            for (uint256 j = 0; j < actualHashes.length; j++) {
                if (actualHashes[j] == absentEntryHashes[i]) {
                    console.log("FAIL: unexpected L2 entry found: %s", vm.toString(absentEntryHashes[i]));
                    revert("Unexpected L2 entry");
                }
            }
        }

        if (actualHashes.length == 0) {
            console.log("PASS: no L2 table entries found (expected for terminal revert)");
        } else {
            console.log(
                "PASS: %s L2 entries found but none match the %s absent hashes",
                actualHashes.length,
                absentEntryHashes.length
            );
        }
    }

    function _collectEntryHashes(uint256[] calldata blocks, address managerL2)
        internal
        view
        returns (bytes32[] memory)
    {
        uint256 count;
        for (uint256 i = 0; i < blocks.length; i++) {
            bytes32[] memory topics = new bytes32[](0);
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blocks[i], blocks[i], managerL2, topics);
            ExecutionEntry[] memory entries = _collectTableEntries(logs);
            count += entries.length;
        }
        bytes32[] memory result = new bytes32[](count);
        uint256 idx;
        for (uint256 i = 0; i < blocks.length; i++) {
            bytes32[] memory topics = new bytes32[](0);
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blocks[i], blocks[i], managerL2, topics);
            ExecutionEntry[] memory entries = _collectTableEntries(logs);
            for (uint256 j = 0; j < entries.length; j++) {
                result[idx++] = _entryHash(entries[j]);
            }
        }
        return result;
    }
}

// ══════════════════════════════════════════════════════════════════════
//  VerifyL1BatchRange — scan a block range for matching entries.
// ══════════════════════════════════════════════════════════════════════

contract VerifyL1BatchRange is VerifyHelpers {
    function run(uint256 blockFrom, uint256 blockTo, address rollups, bytes32[] calldata expectedEntryHashes)
        external
        view
    {
        for (uint256 b = blockFrom; b <= blockTo; b++) {
            bytes32[] memory topics = new bytes32[](0);
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(b, b, rollups, topics);
            ExecutionEntry[] memory entries = _collectBatchEntries(logs);
            if (entries.length == 0) continue;

            bytes32[] memory actualHashes = new bytes32[](entries.length);
            for (uint256 i = 0; i < entries.length; i++) {
                actualHashes[i] = _entryHash(entries[i]);
            }

            bytes32[] memory missing = _findMissingHashes(actualHashes, expectedEntryHashes);
            if (missing.length == 0) {
                console.log(
                    "PASS: %s/%s expected entries found in block %s",
                    expectedEntryHashes.length,
                    expectedEntryHashes.length,
                    b
                );
                console.log("L1_MATCH_BLOCK=%s", b);
                for (uint256 i = 0; i < logs.length; i++) {
                    if (logs[i].topics[0] == SIG_BATCH_POSTED) {
                        console.log("L1_BATCH_TX=%s", vm.toString(logs[i].transactionHash));
                        break;
                    }
                }
                return;
            }
        }

        console.log("FAIL: expected entries not found in blocks %s..%s", blockFrom, blockTo);
        for (uint256 b = blockFrom; b <= blockTo; b++) {
            bytes32[] memory topics = new bytes32[](0);
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(b, b, rollups, topics);
            ExecutionEntry[] memory entries = _collectBatchEntries(logs);
            if (entries.length == 0) continue;
            console.log("");
            console.log("=== L1 BLOCK %s (%s entries) ===", b, entries.length);
            for (uint256 i = 0; i < entries.length; i++) {
                _printEntryDetailed(i, entries[i]);
            }
        }
        console.log("");
        console.log("=== MISSING ENTRY HASHES ===");
        for (uint256 i = 0; i < expectedEntryHashes.length; i++) {
            console.log("  %s", vm.toString(expectedEntryHashes[i]));
        }
        revert("Verification failed");
    }
}
