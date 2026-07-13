// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {StateDelta, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry, LookupCall} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    ExpectedLookup as L2ExpectedLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";

// ══════════════════════════════════════════════════════════════════════
//  Legacy (pre-addStatic, commit 5c51e02) struct layouts — used ONLY to
//  decode `ExecutionTableLoaded` events emitted by devnets that still run
//  the protocol pinned before PR #32 (`isStatic` on the call struct).
//  Hash formulas (crossChainCallHash, rolling-hash folds, entryHash) are
//  identical across versions, so decoded legacy entries convert losslessly
//  into current structs with `isStatic = false`.
// ══════════════════════════════════════════════════════════════════════

struct LegacyCrossChainCall {
    address targetAddress;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;
}

struct LegacyExpectedLookup {
    bytes32 crossChainCallHash;
    bytes returnData;
    bool failed;
    uint64 callNumber;
    uint64 lastOutgoingCallConsumed;
    uint64 executingLookupIndex;
    LegacyCrossChainCall[] incomingCalls;
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls;
    uint256 callCount;
    bytes32 rollingHash;
}

struct LegacyL2ExecutionEntry {
    bytes32 proxyEntryHash;
    LegacyCrossChainCall[] incomingCalls;
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls;
    LegacyExpectedLookup[] expectedLookups;
    uint256 callCount;
    bytes returnData;
    bytes32 rollingHash;
}

// ══════════════════════════════════════════════════════════════════════
//  Shared helpers — event signatures + formatting
// ══════════════════════════════════════════════════════════════════════

abstract contract VerifyHelpers is Script {
    // EntryExecuted(uint256 indexed entryIndex, bytes32 rollingHash, uint256 callsProcessed, uint256 nestedConsumed)
    // Same signature on the legacy (5c51e02) and current versions.
    bytes32 constant SIG_ENTRY_EXECUTED = keccak256("EntryExecuted(uint256,bytes32,uint256,uint256)");

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

    // ExecutionTableLoaded(ExecutionEntry[] entries) — L2 only (IEEZL2 structs; no
    // StateDelta[] / destinationRollupId on L2).
    //   ExecutionEntry     = (bytes32, CrossChainCall[], ExpectedOutgoingCrossChainCall[], ExpectedLookup[], uint256, bytes, bytes32)
    //                         proxyEntryHash  incomingCalls  expectedOutgoingCalls          expectedLookups  cnt     ret    rollingHash
    //   CrossChainCall     = (bool, address, uint256, bytes, address, uint256, uint256)  // leading isStatic
    //   ExpectedOutgoingCrossChainCall = (bytes32, uint256, bytes)
    //   ExpectedLookup     = (bytes32, bytes, bool, uint64, uint64, uint64, CrossChainCall[], ExpectedOutgoingCrossChainCall[], uint256, bytes32)
    bytes32 constant SIG_TABLE_LOADED = keccak256(
        "ExecutionTableLoaded((bytes32,(bool,address,uint256,bytes,address,uint256,uint256)[],(bytes32,uint256,bytes)[],(bytes32,bytes,bool,uint64,uint64,uint64,(bool,address,uint256,bytes,address,uint256,uint256)[],(bytes32,uint256,bytes)[],uint256,bytes32)[],uint256,bytes,bytes32)[])"
    );

    // Legacy (pre-addStatic) ExecutionTableLoaded — CrossChainCall without the
    // leading `bool isStatic`. Emitted by devnets pinned at commit 5c51e02.
    // On-chain verified: 0x21308ad7ef0fc59e2833a7359701342f27a35f3273aa2f83a37bf57a873ecc95
    bytes32 constant SIG_TABLE_LOADED_LEGACY = keccak256(
        "ExecutionTableLoaded((bytes32,(address,uint256,bytes,address,uint256,uint256)[],(bytes32,uint256,bytes)[],(bytes32,bytes,bool,uint64,uint64,uint64,(address,uint256,bytes,address,uint256,uint256)[],(bytes32,uint256,bytes)[],uint256,bytes32)[],uint256,bytes,bytes32)[])"
    );

    // CrossChainCallExecuted(bytes32 crossChainCallHash, address proxy, address sourceAddress, bytes callData, uint256 value)
    bytes32 constant SIG_CROSSCHAIN_CALL = keccak256("CrossChainCallExecuted(bytes32,address,address,bytes,uint256)");

    function _entryHash(ExecutionEntry memory e) internal pure returns (bytes32) {
        return keccak256(abi.encode(e.proxyEntryHash, e.rollingHash));
    }

    function _entryHash(L2ExecutionEntry memory e) internal pure returns (bytes32) {
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
            "      callCount=%s  calls=%s  nested=%s", e.callCount, e.l2ToL1Calls.length, e.expectedL1ToL2Calls.length
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
        for (uint256 c = 0; c < e.l2ToL1Calls.length; c++) {
            L2ToL1Call memory cc = e.l2ToL1Calls[c];
            console.log("      call[%s]: target=%s", c, cc.targetAddress);
            console.log("        isStatic=%s  value=%s  revertSpan=%s", cc.isStatic, cc.value, cc.revertSpan);
            console.log("        from=%s @ rollup %s", cc.sourceAddress, cc.sourceRollupId);
            console.log("        data=%s", _shortBytes(cc.data));
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

    /// @dev L2 (IEEZL2) entry — no stateDeltas / destinationRollupId.
    function _printEntryDetailed(uint256 idx, L2ExecutionEntry memory e) internal pure {
        bool immediate = e.proxyEntryHash == bytes32(0);
        console.log(
            "  [%s] %s  crossChainCallHash=%s", idx, immediate ? "IMMEDIATE" : "DEFERRED", vm.toString(e.proxyEntryHash)
        );
        console.log("      rollingHash: %s", vm.toString(e.rollingHash));
        console.log(
            "      callCount=%s  calls=%s  nested=%s",
            e.callCount,
            e.incomingCalls.length,
            e.expectedOutgoingCalls.length
        );
        for (uint256 c = 0; c < e.incomingCalls.length; c++) {
            CrossChainCall memory cc = e.incomingCalls[c];
            console.log("      call[%s]: target=%s", c, cc.targetAddress);
            console.log("        isStatic=%s  value=%s  revertSpan=%s", cc.isStatic, cc.value, cc.revertSpan);
            console.log("        from=%s @ rollup %s", cc.sourceAddress, cc.sourceRollupId);
            console.log("        data=%s", _shortBytes(cc.data));
        }
        for (uint256 n = 0; n < e.expectedOutgoingCalls.length; n++) {
            ExpectedOutgoingCrossChainCall memory na = e.expectedOutgoingCalls[n];
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

    // ── Log collection: decode ExecutionTableLoaded (L2 entries) ──
    //    Accepts BOTH the current layout and the legacy (pre-addStatic) layout;
    //    legacy entries are converted to current structs with `isStatic = false`.

    function _collectTableEntries(Vm.EthGetLogs[] memory logs) internal pure returns (L2ExecutionEntry[] memory) {
        uint256 totalCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_TABLE_LOADED) {
                L2ExecutionEntry[] memory entries = abi.decode(logs[i].data, (L2ExecutionEntry[]));
                totalCount += entries.length;
            } else if (logs[i].topics[0] == SIG_TABLE_LOADED_LEGACY) {
                LegacyL2ExecutionEntry[] memory entries = abi.decode(logs[i].data, (LegacyL2ExecutionEntry[]));
                totalCount += entries.length;
            }
        }
        L2ExecutionEntry[] memory all = new L2ExecutionEntry[](totalCount);
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_TABLE_LOADED) {
                L2ExecutionEntry[] memory entries = abi.decode(logs[i].data, (L2ExecutionEntry[]));
                for (uint256 j = 0; j < entries.length; j++) {
                    all[idx++] = entries[j];
                }
            } else if (logs[i].topics[0] == SIG_TABLE_LOADED_LEGACY) {
                LegacyL2ExecutionEntry[] memory entries = abi.decode(logs[i].data, (LegacyL2ExecutionEntry[]));
                for (uint256 j = 0; j < entries.length; j++) {
                    all[idx++] = _fromLegacy(entries[j]);
                }
            }
        }
        return all;
    }

    function _fromLegacy(LegacyL2ExecutionEntry memory e) internal pure returns (L2ExecutionEntry memory n) {
        n.proxyEntryHash = e.proxyEntryHash;
        n.incomingCalls = _fromLegacyCalls(e.incomingCalls);
        n.expectedOutgoingCalls = e.expectedOutgoingCalls;
        n.expectedLookups = new L2ExpectedLookup[](e.expectedLookups.length);
        for (uint256 i = 0; i < e.expectedLookups.length; i++) {
            LegacyExpectedLookup memory l = e.expectedLookups[i];
            n.expectedLookups[i] = L2ExpectedLookup({
                crossChainCallHash: l.crossChainCallHash,
                returnData: l.returnData,
                failed: l.failed,
                callNumber: l.callNumber,
                lastOutgoingCallConsumed: l.lastOutgoingCallConsumed,
                executingLookupIndex: l.executingLookupIndex,
                incomingCalls: _fromLegacyCalls(l.incomingCalls),
                expectedOutgoingCalls: l.expectedOutgoingCalls,
                callCount: l.callCount,
                rollingHash: l.rollingHash
            });
        }
        n.callCount = e.callCount;
        n.returnData = e.returnData;
        n.rollingHash = e.rollingHash;
    }

    function _fromLegacyCalls(LegacyCrossChainCall[] memory calls) internal pure returns (CrossChainCall[] memory) {
        CrossChainCall[] memory result = new CrossChainCall[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            result[i] = CrossChainCall({
                isStatic: false,
                targetAddress: calls[i].targetAddress,
                value: calls[i].value,
                data: calls[i].data,
                sourceAddress: calls[i].sourceAddress,
                sourceRollupId: calls[i].sourceRollupId,
                revertSpan: calls[i].revertSpan
            });
        }
        return result;
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
//  VerifyL1BatchInRange — range variant of VerifyL1Batch for L2-starting
//  scenarios, where the L1 settlement block is not known a priori (the
//  batch no longer encodes L2 block references in callData). Scans
//  [fromBlock..toBlock] for ExecutionConsumed events and requires every
//  expected call hash to appear somewhere in the range.
// ══════════════════════════════════════════════════════════════════════

contract VerifyL1BatchInRange is VerifyHelpers {
    function run(uint256 fromBlock, uint256 toBlock, address rollups, bytes32[] calldata expectedCallHashes)
        external
        view
    {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(fromBlock, toBlock, rollups, topics);

        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_EXECUTION_CONSUMED_L1) count++;
        }
        bytes32[] memory actualHashes = new bytes32[](count);
        uint256 idx;
        uint256 matchBlock;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_EXECUTION_CONSUMED_L1) {
                actualHashes[idx++] = logs[i].topics[1];
                if (matchBlock == 0) matchBlock = logs[i].blockNumber;
            }
        }

        bytes32[] memory missing = _findMissingHashes(actualHashes, expectedCallHashes);
        if (missing.length > 0) {
            _report(fromBlock, toBlock, actualHashes, missing, expectedCallHashes.length);
            revert("Verification failed");
        }

        console.log(
            "PASS: %s/%s expected call hashes consumed in L1 range", expectedCallHashes.length, expectedCallHashes.length
        );
        console.log("L1_MATCH_BLOCK=%s", matchBlock);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_BATCH_POSTED) {
                console.log("L1_BATCH_TX=%s", vm.toString(logs[i].transactionHash));
                break;
            }
        }
    }

    /// @dev Failure diagnostics in a separate frame (via-ir stack pressure).
    function _report(
        uint256 fromBlock,
        uint256 toBlock,
        bytes32[] memory actualHashes,
        bytes32[] memory missing,
        uint256 expectedCount
    )
        internal
        pure
    {
        console.log(
            "FAIL: %s/%s expected call hashes missing in L1 blocks %s",
            missing.length,
            expectedCount,
            string.concat(vm.toString(fromBlock), "..", vm.toString(toBlock))
        );
        console.log("=== ACTUAL CONSUMED HASHES (%s) ===", actualHashes.length);
        for (uint256 i = 0; i < actualHashes.length; i++) {
            console.log("  %s", vm.toString(actualHashes[i]));
        }
        console.log("=== MISSING CALL HASHES ===");
        for (uint256 i = 0; i < missing.length; i++) {
            console.log("  %s", vm.toString(missing[i]));
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
//  VerifyL1ZeroHashEntriesInRange — L1 settlement check for L2-starting
//  scenarios whose L1 entries are system-driven (`proxyEntryHash == 0`,
//  drained via executeL2TX). Those consumptions emit NO ExecutionConsumed
//  call hash; instead we match EntryExecuted events: each carries the
//  entry's final rollingHash, and for zero-hash entries
//  entryHash == keccak256(abi.encode(bytes32(0), rollingHash)) — directly
//  comparable against ComputeExpected's EXPECTED_L1_HASHES.
// ══════════════════════════════════════════════════════════════════════

contract VerifyL1ZeroHashEntriesInRange is VerifyHelpers {
    function run(uint256 fromBlock, uint256 toBlock, address rollups, bytes32[] calldata expectedEntryHashes)
        external
        view
    {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(fromBlock, toBlock, rollups, topics);

        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_ENTRY_EXECUTED) count++;
        }
        bytes32[] memory actualHashes = new bytes32[](count);
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_ENTRY_EXECUTED) {
                (bytes32 rollingHash,,) = abi.decode(logs[i].data, (bytes32, uint256, uint256));
                actualHashes[idx++] = keccak256(abi.encode(bytes32(0), rollingHash));
            }
        }

        bytes32[] memory missing = _findMissingHashes(actualHashes, expectedEntryHashes);
        if (missing.length > 0) {
            console.log(
                "FAIL: %s/%s expected zero-hash entry hashes missing (EntryExecuted scan)",
                missing.length,
                expectedEntryHashes.length
            );
            for (uint256 i = 0; i < missing.length; i++) {
                console.log("  missing: %s", vm.toString(missing[i]));
            }
            revert("Verification failed");
        }

        console.log(
            "PASS: %s/%s expected L1 entries executed in range", expectedEntryHashes.length, expectedEntryHashes.length
        );
        // Pin the block/tx of the first matching EntryExecuted.
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != SIG_ENTRY_EXECUTED) continue;
            (bytes32 rollingHash,,) = abi.decode(logs[i].data, (bytes32, uint256, uint256));
            bytes32 h = keccak256(abi.encode(bytes32(0), rollingHash));
            for (uint256 j = 0; j < expectedEntryHashes.length; j++) {
                if (h == expectedEntryHashes[j]) {
                    console.log("L1_MATCH_BLOCK=%s", logs[i].blockNumber);
                    console.log("L1_BATCH_TX=%s", vm.toString(logs[i].transactionHash));
                    return;
                }
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
            L2ExecutionEntry[] memory entries = _getEntries(l2Blocks[i], managerL2);
            if (_allPresent(entries, expectedEntryHashes)) {
                console.log(
                    "PASS: all %s expected entries found at L2 block %s", expectedEntryHashes.length, l2Blocks[i]
                );
                bytes32[] memory topics = new bytes32[](0);
                Vm.EthGetLogs[] memory blkLogs = vm.eth_getLogs(l2Blocks[i], l2Blocks[i], managerL2, topics);
                for (uint256 j = 0; j < blkLogs.length; j++) {
                    if (blkLogs[j].topics[0] == SIG_TABLE_LOADED || blkLogs[j].topics[0] == SIG_TABLE_LOADED_LEGACY) {
                        console.log("L2_TABLE_TX=%s", vm.toString(blkLogs[j].transactionHash));
                        break;
                    }
                }
                return;
            }
        }

        _reportL2Failure(l2Blocks, managerL2, expectedEntryHashes);
        revert("Verification failed");
    }

    /// @dev Failure diagnostics for `run`, split into its own frame to keep `run` under the
    ///      via-ir stack limit (the inlined i/j/c loop nest would otherwise overflow).
    function _reportL2Failure(uint256[] calldata l2Blocks, address managerL2, bytes32[] calldata expectedEntryHashes)
        internal
        view
    {
        console.log("FAIL: expected entries not found in any of %s L2 blocks", l2Blocks.length);
        for (uint256 i = 0; i < l2Blocks.length; i++) {
            L2ExecutionEntry[] memory entries = _getEntries(l2Blocks[i], managerL2);
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
    }

    function _getEntries(uint256 blockNumber, address managerL2) internal view returns (L2ExecutionEntry[] memory) {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blockNumber, blockNumber, managerL2, topics);
        return _collectTableEntries(logs);
    }

    function _allPresent(L2ExecutionEntry[] memory entries, bytes32[] calldata expectedEntryHashes)
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
//  VerifyL2CallsInRange — range variant of VerifyL2Calls for L1-starting
//  scenarios, where the L2 sync block that executed the inbound calls is
//  not known a priori. One eth_getLogs over [fromBlock..toBlock]; prints
//  L2_MATCH_BLOCK (block of the first expected-hash hit) on success so
//  the caller can pin table verification to that block.
// ══════════════════════════════════════════════════════════════════════

contract VerifyL2CallsInRange is VerifyHelpers {
    function run(uint256 fromBlock, uint256 toBlock, address managerL2, bytes32[] calldata expectedCallHashes)
        external
        view
    {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(fromBlock, toBlock, managerL2, topics);

        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 sig = logs[i].topics[0];
            if (sig == SIG_CROSSCHAIN_CALL || sig == SIG_INCOMING_CROSSCHAIN_CALL) count++;
        }
        bytes32[] memory found = new bytes32[](count);
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 sig = logs[i].topics[0];
            if (sig == SIG_CROSSCHAIN_CALL || sig == SIG_INCOMING_CROSSCHAIN_CALL) {
                found[idx++] = logs[i].topics[1];
            }
        }

        bytes32[] memory missing = _findMissingHashes(found, expectedCallHashes);
        if (missing.length > 0) {
            console.log("FAIL: %s/%s expected L2 calls missing in range", missing.length, expectedCallHashes.length);
            for (uint256 i = 0; i < missing.length; i++) {
                console.log("  missing: %s", vm.toString(missing[i]));
            }
            revert("Verification failed");
        }

        console.log("PASS: %s/%s expected L2 calls found in range", expectedCallHashes.length, expectedCallHashes.length);
        // First log whose hash is one of the expected — that block is the sync block.
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 sig = logs[i].topics[0];
            if (sig != SIG_CROSSCHAIN_CALL && sig != SIG_INCOMING_CROSSCHAIN_CALL) continue;
            for (uint256 j = 0; j < expectedCallHashes.length; j++) {
                if (logs[i].topics[1] == expectedCallHashes[j]) {
                    console.log("L2_MATCH_BLOCK=%s", logs[i].blockNumber);
                    console.log("L2_CALL_TX=%s", vm.toString(logs[i].transactionHash));
                    return;
                }
            }
        }
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
            L2ExecutionEntry[] memory entries = _collectTableEntries(logs);
            count += entries.length;
        }
        bytes32[] memory result = new bytes32[](count);
        uint256 idx;
        for (uint256 i = 0; i < blocks.length; i++) {
            bytes32[] memory topics = new bytes32[](0);
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blocks[i], blocks[i], managerL2, topics);
            L2ExecutionEntry[] memory entries = _collectTableEntries(logs);
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
