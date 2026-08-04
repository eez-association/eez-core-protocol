// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExpectedLookup,
    ExecutionEntry,
    LookupCall,
    ExpectedStateRootPerRollup,
    RollupIdWithProofSystems,
    ProofSystemBatchPerVerificationEntries
} from "../../../src/interfaces/IEEZ.sol";
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

// ── Legacy L1 (IEEZ @ 5c51e02) — used to decode `postAndVerifyBatch` calldata
//    posted by legacy devnets. vs current: L2ToL1Call has no leading `isStatic`,
//    ExpectedL1ToL2Call / ExpectedLookup have no `destinationRollupId`, the
//    entry's `returnData` sits after `callCount` (not before `l2ToL1Calls`),
//    and the batch carries an extra `crossProofSystemInteractions` word.
//    Selector verified against live devnet settlement txs: 0x8b1a095a. ──

struct LegacyL2ToL1Call {
    address targetAddress;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;
}

struct LegacyExpectedL1ToL2Call {
    bytes32 crossChainCallHash;
    uint256 callCount;
    bytes returnData;
}

struct LegacyL1ExpectedLookup {
    bytes32 crossChainCallHash;
    bytes returnData;
    bool failed;
    uint64 l2ToL1CallNumber;
    uint64 lastL1ToL2CallConsumed;
    uint64 executingLookupIndex;
    LegacyL2ToL1Call[] l2ToL1Calls;
    LegacyExpectedL1ToL2Call[] expectedL1ToL2Calls;
    uint256 callCount;
    bytes32 rollingHash;
}

struct LegacyL1ExecutionEntry {
    StateDelta[] stateDeltas;
    bytes32 proxyEntryHash;
    uint256 destinationRollupId;
    LegacyL2ToL1Call[] l2ToL1Calls;
    LegacyExpectedL1ToL2Call[] expectedL1ToL2Calls;
    LegacyL1ExpectedLookup[] expectedLookups;
    uint256 callCount;
    bytes returnData;
    bytes32 rollingHash;
}

struct LegacyL1LookupCall {
    bytes32 crossChainCallHash;
    uint256 destinationRollupId;
    bytes returnData;
    bool failed;
    LegacyL2ToL1Call[] l2ToL1Calls;
    LegacyExpectedL1ToL2Call[] expectedL1ToL2Calls;
    LegacyL1ExpectedLookup[] expectedLookups;
    uint256 callCount;
    bytes32 rollingHash;
    ExpectedStateRootPerRollup[] expectedStateRoots;
}

struct LegacyL1Batch {
    LegacyL1ExecutionEntry[] entries;
    LegacyL1LookupCall[] l1ToL2lookupCalls;
    uint256 transientExecutionEntryCount;
    uint256 transientLookupCallCount;
    address[] proofSystems;
    RollupIdWithProofSystems[] rollupIdsWithProofSystems;
    bytes32 crossProofSystemInteractions;
    uint256[] blobIndices;
    bytes callData;
    bytes[] proofs;
    uint64 blockNumber;
}

// ══════════════════════════════════════════════════════════════════════
//  Minimal read interfaces for live on-chain checks
// ══════════════════════════════════════════════════════════════════════

interface IRollupsRegistryView {
    function rollups(uint256 rollupId)
        external
        view
        returns (address rollupContract, bytes32 stateRoot, uint256 etherBalance);
}

interface IEEZL2View {
    function ROLLUP_ID() external view returns (uint256);
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

    // ══════════════════════════════════════════════════════════════════
    //  Field-level verification (expected-table blobs)
    //
    //  ComputeExpected prints EXPECTED_L1_TABLE / EXPECTED_L2_TABLE as
    //  abi.encode(entries) blobs; the runners pass them through so every
    //  entry field can be compared, not just the (proxyEntryHash,
    //  rollingHash) identity. Empty blob = checks skipped (back-compat).
    // ══════════════════════════════════════════════════════════════════

    /// @dev EntryExecuted payload: (rollingHash, callsProcessed, nestedConsumed) —
    ///      same layout on L1 (l2ToL1Calls / expectedL1ToL2Calls) and L2
    ///      (incomingCalls / expectedOutgoingCalls).
    struct ExecutedTriple {
        bytes32 rollingHash;
        uint256 callsProcessed;
        uint256 nestedConsumed;
    }

    function _bytesEq(bytes memory a, bytes memory b) internal pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    // Struct equality via encoded hashes. Kept in dedicated frames — inlining the
    // double abi.encode of nested dynamic structs blows the via-ir stack limit.
    function _l2EntryEq(L2ExecutionEntry memory a, L2ExecutionEntry memory b) internal pure returns (bool) {
        bytes32 ha = keccak256(abi.encode(a));
        bytes32 hb = keccak256(abi.encode(b));
        return ha == hb;
    }

    function _outgoingEq(ExpectedOutgoingCrossChainCall memory a, ExpectedOutgoingCrossChainCall memory b)
        internal
        pure
        returns (bool)
    {
        bytes32 ha = keccak256(abi.encode(a));
        bytes32 hb = keccak256(abi.encode(b));
        return ha == hb;
    }

    function _lookupEq(L2ExpectedLookup memory a, L2ExpectedLookup memory b) internal pure returns (bool) {
        bytes32 ha = keccak256(abi.encode(a));
        bytes32 hb = keccak256(abi.encode(b));
        return ha == hb;
    }

    function _collectExecutedTriples(Vm.EthGetLogs[] memory logs) internal pure returns (ExecutedTriple[] memory) {
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_ENTRY_EXECUTED) count++;
        }
        ExecutedTriple[] memory triples = new ExecutedTriple[](count);
        uint256 kept;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != SIG_ENTRY_EXECUTED) continue;
            if (logs[i].data.length < 96) continue; // foreign layout — don't decode
            (bytes32 rh, uint256 c, uint256 n) = abi.decode(logs[i].data, (bytes32, uint256, uint256));
            triples[kept++] = ExecutedTriple(rh, c, n);
        }
        assembly {
            mstore(triples, kept)
        }
        return triples;
    }

    function _hasTriple(ExecutedTriple[] memory triples, bytes32 rh, uint256 calls, uint256 nested)
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < triples.length; i++) {
            if (
                triples[i].rollingHash == rh && triples[i].callsProcessed == calls
                    && triples[i].nestedConsumed == nested
            ) {
                return true;
            }
        }
        return false;
    }

    // ── L1: per-entry field checks against ExecutionConsumed / EntryExecuted + live state roots ──

    function _verifyL1EntryFields(Vm.EthGetLogs[] memory logs, address rollupsAddr, bytes memory expectedTable)
        internal
        view
        returns (bool ok)
    {
        ExecutionEntry[] memory expected = abi.decode(expectedTable, (ExecutionEntry[]));
        ExecutedTriple[] memory executed = _collectExecutedTriples(logs);
        ok = true;
        for (uint256 i = 0; i < expected.length; i++) {
            if (!_checkL1Entry(logs, executed, i, expected[i])) ok = false;
        }
        if (!_checkLiveStateRoots(rollupsAddr, expected)) ok = false;
        if (ok) {
            console.log(
                "PASS: L1 field checks on %s entries (EntryExecuted, rollupId, stateDeltas, partition, live roots)",
                expected.length
            );
        }
    }

    function _checkL1Entry(
        Vm.EthGetLogs[] memory logs,
        ExecutedTriple[] memory executed,
        uint256 i,
        ExecutionEntry memory e
    )
        internal
        pure
        returns (bool ok)
    {
        ok = true;
        // ExecutionConsumed must route the entry to its declared destination rollup
        if (e.proxyEntryHash != bytes32(0)) {
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] != SIG_EXECUTION_CONSUMED_L1 || logs[j].topics.length < 3) continue;
                if (logs[j].topics[1] != e.proxyEntryHash) continue;
                if (uint256(logs[j].topics[2]) != e.destinationRollupId) {
                    console.log(
                        "FAIL: entry %s consumed on rollup %s, expected destinationRollupId %s",
                        i,
                        uint256(logs[j].topics[2]),
                        e.destinationRollupId
                    );
                    ok = false;
                }
            }
        }
        // EntryExecuted must report the exact (rollingHash, callsProcessed, nestedConsumed)
        if (!_hasTriple(executed, e.rollingHash, e.l2ToL1Calls.length, e.expectedL1ToL2Calls.length)) {
            console.log("FAIL: entry %s: no EntryExecuted matching (rollingHash, callsProcessed, nestedConsumed)", i);
            console.log(
                "      want rollingHash=%s calls=%s nested=%s",
                vm.toString(e.rollingHash),
                e.l2ToL1Calls.length,
                e.expectedL1ToL2Calls.length
            );
            ok = false;
        }
        // Prover obligation: at least one StateDelta, and every delta MUST move the
        // state root (any execution changes L2 state, regardless of ether movement)
        if (e.stateDeltas.length == 0) {
            console.log("FAIL: entry %s carries no StateDelta (unpinned from StateRootMismatch backstop)", i);
            ok = false;
        }
        for (uint256 d = 0; d < e.stateDeltas.length; d++) {
            if (e.stateDeltas[d].currentState == e.stateDeltas[d].newState) {
                console.log(
                    "FAIL: entry %s stateDelta %s does not move the state root (currentState == newState)", i, d
                );
                ok = false;
            }
        }
        // Partition invariant: callCount + nested callCounts == flat array length
        uint256 total = e.callCount;
        for (uint256 n = 0; n < e.expectedL1ToL2Calls.length; n++) {
            total += e.expectedL1ToL2Calls[n].callCount;
        }
        if (total != e.l2ToL1Calls.length) {
            console.log(
                "FAIL: entry %s partition invariant: callCount sum %s != flat calls %s", i, total, e.l2ToL1Calls.length
            );
            ok = false;
        }
    }

    /// @dev Reads the live registry root per touched rollup: it must equal the last delta's
    ///      newState (exact settlement), or at minimum have moved off the pre-batch root.
    function _checkLiveStateRoots(address rollupsAddr, ExecutionEntry[] memory expected)
        internal
        view
        returns (bool ok)
    {
        uint256 maxDeltas;
        for (uint256 i = 0; i < expected.length; i++) {
            maxDeltas += expected[i].stateDeltas.length;
        }
        uint256[] memory rids = new uint256[](maxDeltas);
        bytes32[] memory pre = new bytes32[](maxDeltas);
        bytes32[] memory post = new bytes32[](maxDeltas);
        uint256 n;
        for (uint256 i = 0; i < expected.length; i++) {
            for (uint256 d = 0; d < expected[i].stateDeltas.length; d++) {
                StateDelta memory sd = expected[i].stateDeltas[d];
                bool seen = false;
                for (uint256 k = 0; k < n; k++) {
                    if (rids[k] == sd.rollupId) {
                        post[k] = sd.newState; // deltas apply in entry order — track the final root
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    rids[n] = sd.rollupId;
                    pre[n] = sd.currentState;
                    post[n] = sd.newState;
                    n++;
                }
            }
        }
        ok = true;
        for (uint256 k = 0; k < n; k++) {
            (, bytes32 live,) = IRollupsRegistryView(rollupsAddr).rollups(rids[k]);
            if (live == post[k]) {
                console.log("PASS: rollup %s live state root == expected newState", rids[k]);
            } else if (live != pre[k]) {
                console.log("PASS: rollup %s state root changed (advanced beyond this batch)", rids[k]);
            } else {
                console.log("FAIL: rollup %s state root UNCHANGED - still the pre-batch root:", rids[k]);
                console.log("      %s", vm.toString(live));
                ok = false;
            }
        }
    }

    // ── L1: posted-batch calldata comparison. The batch entries ACTUALLY posted
    //    on-chain (decoded from the settlement tx's postAndVerifyBatch input) are
    //    field-matched against the expected table — the L1 analogue of the L2
    //    ExecutionTableLoaded comparison. StateDelta ROOTS are checked structurally
    //    and against the live registry, never against the expected blob:
    //    ComputeExpected cannot predict real state roots off-chain. ──

    function _fromLegacyL1Entries(LegacyL1ExecutionEntry[] memory entries)
        internal
        pure
        returns (ExecutionEntry[] memory out)
    {
        out = new ExecutionEntry[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            out[i] = _fromLegacyL1(entries[i]);
        }
    }

    function _fromLegacyL1(LegacyL1ExecutionEntry memory e) internal pure returns (ExecutionEntry memory n) {
        n.stateDeltas = e.stateDeltas;
        n.proxyEntryHash = e.proxyEntryHash;
        n.destinationRollupId = e.destinationRollupId;
        n.returnData = e.returnData;
        n.l2ToL1Calls = _fromLegacyL1Calls(e.l2ToL1Calls);
        n.expectedL1ToL2Calls = _fromLegacyL1Nested(e.expectedL1ToL2Calls);
        n.expectedLookups = new ExpectedLookup[](e.expectedLookups.length);
        for (uint256 k = 0; k < e.expectedLookups.length; k++) {
            LegacyL1ExpectedLookup memory l = e.expectedLookups[k];
            n.expectedLookups[k] = ExpectedLookup({
                crossChainCallHash: l.crossChainCallHash,
                destinationRollupId: 0, // absent in the legacy ABI
                returnData: l.returnData,
                failed: l.failed,
                l2ToL1CallNumber: l.l2ToL1CallNumber,
                lastL1ToL2CallConsumed: l.lastL1ToL2CallConsumed,
                executingLookupIndex: l.executingLookupIndex,
                l2ToL1Calls: _fromLegacyL1Calls(l.l2ToL1Calls),
                expectedL1ToL2Calls: _fromLegacyL1Nested(l.expectedL1ToL2Calls),
                callCount: l.callCount,
                rollingHash: l.rollingHash
            });
        }
        n.callCount = e.callCount;
        n.rollingHash = e.rollingHash;
    }

    function _fromLegacyL1Calls(LegacyL2ToL1Call[] memory calls) internal pure returns (L2ToL1Call[] memory out) {
        out = new L2ToL1Call[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            out[i] = L2ToL1Call({
                isStatic: false,
                targetAddress: calls[i].targetAddress,
                value: calls[i].value,
                data: calls[i].data,
                sourceAddress: calls[i].sourceAddress,
                sourceRollupId: calls[i].sourceRollupId,
                revertSpan: calls[i].revertSpan
            });
        }
    }

    function _fromLegacyL1Nested(LegacyExpectedL1ToL2Call[] memory calls)
        internal
        pure
        returns (ExpectedL1ToL2Call[] memory out)
    {
        out = new ExpectedL1ToL2Call[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            out[i] = ExpectedL1ToL2Call({
                crossChainCallHash: calls[i].crossChainCallHash,
                destinationRollupId: 0, // absent in the legacy ABI
                callCount: calls[i].callCount,
                returnData: calls[i].returnData
            });
        }
    }

    /// @dev Fields the legacy ABI cannot encode are fabricated by the decoder
    ///      (isStatic = false, nested destinationRollupId = 0) — copy them from
    ///      the expected side so the comparison only covers real posted data.
    function _neutralizeLegacyL1Fields(ExecutionEntry memory a, ExecutionEntry memory e) internal pure {
        uint256 m = a.l2ToL1Calls.length < e.l2ToL1Calls.length ? a.l2ToL1Calls.length : e.l2ToL1Calls.length;
        for (uint256 c = 0; c < m; c++) {
            a.l2ToL1Calls[c].isStatic = e.l2ToL1Calls[c].isStatic;
        }
        m = a.expectedL1ToL2Calls.length < e.expectedL1ToL2Calls.length
            ? a.expectedL1ToL2Calls.length
            : e.expectedL1ToL2Calls.length;
        for (uint256 c = 0; c < m; c++) {
            a.expectedL1ToL2Calls[c].destinationRollupId = e.expectedL1ToL2Calls[c].destinationRollupId;
        }
        m = a.expectedLookups.length < e.expectedLookups.length ? a.expectedLookups.length : e.expectedLookups.length;
        for (uint256 k = 0; k < m; k++) {
            _neutralizeLegacyL1Lookup(a.expectedLookups[k], e.expectedLookups[k]);
        }
    }

    function _neutralizeLegacyL1Lookup(ExpectedLookup memory a, ExpectedLookup memory e) internal pure {
        a.destinationRollupId = e.destinationRollupId;
        uint256 m = a.l2ToL1Calls.length < e.l2ToL1Calls.length ? a.l2ToL1Calls.length : e.l2ToL1Calls.length;
        for (uint256 c = 0; c < m; c++) {
            a.l2ToL1Calls[c].isStatic = e.l2ToL1Calls[c].isStatic;
        }
        m = a.expectedL1ToL2Calls.length < e.expectedL1ToL2Calls.length
            ? a.expectedL1ToL2Calls.length
            : e.expectedL1ToL2Calls.length;
        for (uint256 c = 0; c < m; c++) {
            a.expectedL1ToL2Calls[c].destinationRollupId = e.expectedL1ToL2Calls[c].destinationRollupId;
        }
    }

    /// @dev Match key for pairing posted <-> expected entries. (proxyEntryHash,
    ///      rollingHash) alone collides across parallel jobs running the same
    ///      scenario against a shared devnet: the rolling hash only folds
    ///      (callNumber, success, retData), never call addresses or calldata, and
    ///      immediate entries all share proxyEntryHash == 0 — so identical
    ///      scenarios batched together are indistinguishable and every job would
    ///      match the first such posted entry. Fold the flat-call content too.
    ///      isStatic is excluded: the legacy ABI does not encode it.
    function _postedMatchHash(ExecutionEntry memory e) internal pure returns (bytes32 h) {
        h = keccak256(abi.encode(e.proxyEntryHash, e.rollingHash));
        for (uint256 c = 0; c < e.l2ToL1Calls.length; c++) {
            L2ToL1Call memory call = e.l2ToL1Calls[c];
            h = keccak256(
                abi.encode(
                    h, call.targetAddress, call.value, call.data, call.sourceAddress, call.sourceRollupId, call.revertSpan
                )
            );
        }
    }

    function _verifyL1PostedEntries(
        ExecutionEntry[] memory posted,
        address rollupsAddr,
        bytes memory expectedTable,
        bool legacyAbi
    )
        internal
        view
        returns (bool ok)
    {
        ExecutionEntry[] memory expected = abi.decode(expectedTable, (ExecutionEntry[]));
        ExecutionEntry[] memory matched = new ExecutionEntry[](expected.length);
        uint256 nMatched;
        // Entries are queue-consumed in order and the match key is NOT unique
        // (e.g. two identical increments in one job) — match each posted entry
        // at most once, in posting order.
        bool[] memory used = new bool[](posted.length);
        ok = true;
        for (uint256 i = 0; i < expected.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < posted.length; j++) {
                if (used[j] || _postedMatchHash(posted[j]) != _postedMatchHash(expected[i])) continue;
                used[j] = true;
                found = true;
                matched[nMatched++] = posted[j];
                if (!_comparePostedEntry(posted[j], expected[i], i, legacyAbi)) ok = false;
                break;
            }
            if (!found) {
                console.log("FAIL: expected entry %s not in posted batch (no (proxyEntryHash, rollingHash, calls) match)", i);
                ok = false;
            }
        }
        assembly {
            mstore(matched, nMatched)
        }
        // root movement + contiguity across the WHOLE posted batch
        if (!_checkPostedDeltaChain(posted)) ok = false;
        // live-root check against the REAL posted deltas (exact roots, unlike the
        // expected blob's local placeholders)
        if (!_checkLiveStateRoots(rollupsAddr, matched)) ok = false;
        if (ok) {
            console.log(
                "PASS: posted batch calldata matches expected table (%s entries, field-by-field)", expected.length
            );
            if (legacyAbi) {
                console.log("      (legacy ABI: isStatic / nested destinationRollupId not encoded, skipped)");
            }
        }
    }

    function _comparePostedEntry(ExecutionEntry memory a, ExecutionEntry memory e, uint256 i, bool legacyAbi)
        internal
        pure
        returns (bool ok)
    {
        if (legacyAbi) _neutralizeLegacyL1Fields(a, e);
        ok = true;
        if (a.destinationRollupId != e.destinationRollupId) {
            console.log(
                "FAIL: entry %s destinationRollupId: posted %s expected %s",
                i,
                a.destinationRollupId,
                e.destinationRollupId
            );
            ok = false;
        }
        if (a.callCount != e.callCount) {
            console.log("FAIL: entry %s callCount: posted %s expected %s", i, a.callCount, e.callCount);
            ok = false;
        }
        if (!_bytesEq(a.returnData, e.returnData)) {
            console.log(
                "FAIL: entry %s returnData: posted %s expected %s",
                i,
                _shortBytes(a.returnData),
                _shortBytes(e.returnData)
            );
            ok = false;
        }
        if (!_comparePostedDeltas(a.stateDeltas, e.stateDeltas, i)) ok = false;
        if (!_comparePostedCalls(a.l2ToL1Calls, e.l2ToL1Calls, i)) ok = false;
        if (!_comparePostedNested(a.expectedL1ToL2Calls, e.expectedL1ToL2Calls, i)) ok = false;
        if (!_comparePostedLookups(a.expectedLookups, e.expectedLookups, i)) ok = false;
    }

    /// @dev rollupId and etherDelta are deterministic and compared exactly; the
    ///      roots themselves are only sanity-checked (posted delta must not be a
    ///      no-op) — their live settlement is covered by _checkLiveStateRoots.
    function _comparePostedDeltas(StateDelta[] memory a, StateDelta[] memory e, uint256 i)
        internal
        pure
        returns (bool ok)
    {
        ok = true;
        if (a.length == 0) {
            console.log("FAIL: entry %s posted with no StateDelta (unpinned from StateRootMismatch backstop)", i);
            ok = false;
        }
        if (a.length != e.length) {
            console.log("FAIL: entry %s stateDeltas.length: posted %s expected %s", i, a.length, e.length);
            ok = false;
        }
        uint256 m = a.length < e.length ? a.length : e.length;
        for (uint256 d = 0; d < m; d++) {
            if (a[d].rollupId != e[d].rollupId || a[d].etherDelta != e[d].etherDelta) {
                console.log(
                    string.concat(
                        "FAIL: entry ",
                        vm.toString(i),
                        " stateDelta ",
                        vm.toString(d),
                        ": posted (rollup ",
                        vm.toString(a[d].rollupId),
                        ", ether ",
                        vm.toString(a[d].etherDelta),
                        ") expected (rollup ",
                        vm.toString(e[d].rollupId),
                        ", ether ",
                        vm.toString(e[d].etherDelta),
                        ")"
                    )
                );
                ok = false;
            }
        }
    }

    /// @dev Per-rollup delta-chain checks across ALL posted entries, in posting
    ///      order: every delta must continue from the previous one (pre ==
    ///      previous post) and the chain as a whole MUST move the root.
    ///      Per-entry movement cannot be required: state roots are per-L2-block,
    ///      so entries executed in the same L2 block share one root transition
    ///      and all but one of them legitimately post currentState == newState
    ///      (observed on the devnet: two same-block calls -> B->C then C->C).
    function _checkPostedDeltaChain(ExecutionEntry[] memory posted) internal pure returns (bool ok) {
        ok = true;
        uint256 maxDeltas;
        for (uint256 i = 0; i < posted.length; i++) {
            maxDeltas += posted[i].stateDeltas.length;
        }
        uint256[] memory rids = new uint256[](maxDeltas);
        bytes32[] memory firstPre = new bytes32[](maxDeltas);
        bytes32[] memory lastPost = new bytes32[](maxDeltas);
        uint256 n;
        for (uint256 i = 0; i < posted.length; i++) {
            for (uint256 d = 0; d < posted[i].stateDeltas.length; d++) {
                StateDelta memory sd = posted[i].stateDeltas[d];
                bool seen = false;
                for (uint256 k = 0; k < n; k++) {
                    if (rids[k] != sd.rollupId) continue;
                    seen = true;
                    if (sd.currentState != lastPost[k]) {
                        console.log(
                            "FAIL: rollup %s posted delta chain broken at entry %s (pre != previous post)",
                            sd.rollupId,
                            i
                        );
                        ok = false;
                    }
                    lastPost[k] = sd.newState;
                    break;
                }
                if (!seen) {
                    rids[n] = sd.rollupId;
                    firstPre[n] = sd.currentState;
                    lastPost[n] = sd.newState;
                    n++;
                }
            }
        }
        for (uint256 k = 0; k < n; k++) {
            if (firstPre[k] == lastPost[k]) {
                console.log("FAIL: rollup %s state root does not move across the posted batch", rids[k]);
                ok = false;
            }
        }
    }

    function _comparePostedCalls(L2ToL1Call[] memory a, L2ToL1Call[] memory e, uint256 i)
        internal
        pure
        returns (bool ok)
    {
        ok = true;
        if (a.length != e.length) {
            console.log("FAIL: entry %s l2ToL1Calls.length: posted %s expected %s", i, a.length, e.length);
            ok = false;
        }
        uint256 m = a.length < e.length ? a.length : e.length;
        for (uint256 c = 0; c < m; c++) {
            if (_l1CallEq(a[c], e[c])) continue;
            console.log("FAIL: entry %s l2ToL1Calls[%s] differs (posted vs expected):", i, c);
            _diffL1Call(c, a[c], e[c]);
            ok = false;
        }
    }

    function _comparePostedNested(ExpectedL1ToL2Call[] memory a, ExpectedL1ToL2Call[] memory e, uint256 i)
        internal
        pure
        returns (bool ok)
    {
        ok = true;
        if (a.length != e.length) {
            console.log("FAIL: entry %s expectedL1ToL2Calls.length: posted %s expected %s", i, a.length, e.length);
            ok = false;
        }
        uint256 m = a.length < e.length ? a.length : e.length;
        for (uint256 c = 0; c < m; c++) {
            if (!_l1NestedEq(a[c], e[c])) {
                console.log("FAIL: entry %s expectedL1ToL2Calls[%s] differs (posted vs expected)", i, c);
                ok = false;
            }
        }
    }

    function _comparePostedLookups(ExpectedLookup[] memory a, ExpectedLookup[] memory e, uint256 i)
        internal
        pure
        returns (bool ok)
    {
        ok = true;
        if (a.length != e.length) {
            console.log("FAIL: entry %s expectedLookups.length: posted %s expected %s", i, a.length, e.length);
            ok = false;
        }
        uint256 m = a.length < e.length ? a.length : e.length;
        for (uint256 c = 0; c < m; c++) {
            if (!_l1LookupEq(a[c], e[c])) {
                console.log("FAIL: entry %s expectedLookups[%s] differs (posted vs expected)", i, c);
                ok = false;
            }
        }
    }

    // Struct equality via encoded hashes, each in its own frame (via-ir stack).
    function _l1CallEq(L2ToL1Call memory a, L2ToL1Call memory b) internal pure returns (bool) {
        bytes32 ha = keccak256(abi.encode(a));
        bytes32 hb = keccak256(abi.encode(b));
        return ha == hb;
    }

    function _l1NestedEq(ExpectedL1ToL2Call memory a, ExpectedL1ToL2Call memory b) internal pure returns (bool) {
        bytes32 ha = keccak256(abi.encode(a));
        bytes32 hb = keccak256(abi.encode(b));
        return ha == hb;
    }

    function _l1LookupEq(ExpectedLookup memory a, ExpectedLookup memory b) internal pure returns (bool) {
        bytes32 ha = keccak256(abi.encode(a));
        bytes32 hb = keccak256(abi.encode(b));
        return ha == hb;
    }

    function _diffL1Call(uint256 c, L2ToL1Call memory a, L2ToL1Call memory e) internal pure {
        if (a.isStatic != e.isStatic) {
            console.log("      call[%s].isStatic: posted %s expected %s", c, a.isStatic, e.isStatic);
        }
        if (a.targetAddress != e.targetAddress) {
            console.log("      call[%s].targetAddress: posted %s expected %s", c, a.targetAddress, e.targetAddress);
        }
        if (a.value != e.value) {
            console.log("      call[%s].value: posted %s expected %s", c, a.value, e.value);
        }
        if (!_bytesEq(a.data, e.data)) {
            console.log("      call[%s].data: posted %s expected %s", c, _shortBytes(a.data), _shortBytes(e.data));
        }
        if (a.sourceAddress != e.sourceAddress) {
            console.log("      call[%s].sourceAddress: posted %s expected %s", c, a.sourceAddress, e.sourceAddress);
        }
        if (a.sourceRollupId != e.sourceRollupId) {
            console.log("      call[%s].sourceRollupId: posted %s expected %s", c, a.sourceRollupId, e.sourceRollupId);
        }
        if (a.revertSpan != e.revertSpan) {
            console.log("      call[%s].revertSpan: posted %s expected %s", c, a.revertSpan, e.revertSpan);
        }
    }

    // ── L2: full-struct comparison of the loaded table + invariants + EntryExecuted ──

    function _verifyL2TableFields(
        L2ExecutionEntry[] memory actual,
        Vm.EthGetLogs[] memory logs,
        bytes memory expectedTable
    )
        internal
        pure
        returns (bool ok)
    {
        L2ExecutionEntry[] memory expected = abi.decode(expectedTable, (L2ExecutionEntry[]));
        ExecutedTriple[] memory executed = _collectExecutedTriples(logs);
        ok = true;
        for (uint256 i = 0; i < expected.length; i++) {
            if (!_checkL2Entry(actual, executed, i, expected[i])) ok = false;
        }
        if (ok) {
            console.log("PASS: L2 field checks on %s entries (full struct, invariants, EntryExecuted)", expected.length);
        }
    }

    function _checkL2Entry(
        L2ExecutionEntry[] memory actual,
        ExecutedTriple[] memory executed,
        uint256 i,
        L2ExecutionEntry memory e
    )
        internal
        pure
        returns (bool ok)
    {
        ok = true;
        // Full struct equality vs the loaded entry with the same (proxyEntryHash, rollingHash)
        bool found = false;
        for (uint256 j = 0; j < actual.length; j++) {
            if (_entryHash(actual[j]) != _entryHash(e)) continue;
            found = true;
            if (!_l2EntryEq(actual[j], e)) {
                console.log("FAIL: entry %s: loaded table entry differs from expected:", i);
                _diffL2Entry(actual[j], e);
                ok = false;
            }
        }
        if (!found) {
            console.log("FAIL: entry %s: no loaded entry with matching entryHash", i);
            ok = false;
        }
        // Structural invariants
        if (e.proxyEntryHash == bytes32(0)) {
            console.log("FAIL: entry %s: zero proxyEntryHash is invalid on L2", i);
            ok = false;
        }
        uint256 total = e.callCount;
        for (uint256 c = 0; c < e.expectedOutgoingCalls.length; c++) {
            total += e.expectedOutgoingCalls[c].callCount;
        }
        if (total != e.incomingCalls.length) {
            console.log(
                "FAIL: entry %s partition invariant: callCount sum %s != flat calls %s",
                i,
                total,
                e.incomingCalls.length
            );
            ok = false;
        }
        for (uint256 c = 0; c < e.incomingCalls.length; c++) {
            if (e.incomingCalls[c].isStatic && (e.incomingCalls[c].value != 0 || e.incomingCalls[c].revertSpan != 0)) {
                console.log("FAIL: entry %s call %s: static call must have value == 0 and revertSpan == 0", i, c);
                ok = false;
            }
        }
        // EntryExecuted must report the exact (rollingHash, callsProcessed, outgoingConsumed)
        if (!_hasTriple(executed, e.rollingHash, e.incomingCalls.length, e.expectedOutgoingCalls.length)) {
            console.log("FAIL: entry %s: no EntryExecuted matching (rollingHash, callsProcessed, outgoingConsumed)", i);
            ok = false;
        }
    }

    function _diffL2Entry(L2ExecutionEntry memory a, L2ExecutionEntry memory e) internal pure {
        if (a.callCount != e.callCount) {
            console.log("      callCount: actual %s expected %s", a.callCount, e.callCount);
        }
        if (!_bytesEq(a.returnData, e.returnData)) {
            console.log("      returnData: actual %s expected %s", _shortBytes(a.returnData), _shortBytes(e.returnData));
        }
        if (a.incomingCalls.length != e.incomingCalls.length) {
            console.log(
                "      incomingCalls.length: actual %s expected %s", a.incomingCalls.length, e.incomingCalls.length
            );
        }
        uint256 m = a.incomingCalls.length < e.incomingCalls.length ? a.incomingCalls.length : e.incomingCalls.length;
        for (uint256 c = 0; c < m; c++) {
            _diffCall(c, a.incomingCalls[c], e.incomingCalls[c]);
        }
        if (a.expectedOutgoingCalls.length != e.expectedOutgoingCalls.length) {
            console.log(
                "      expectedOutgoingCalls.length: actual %s expected %s",
                a.expectedOutgoingCalls.length,
                e.expectedOutgoingCalls.length
            );
        }
        m = a.expectedOutgoingCalls.length < e.expectedOutgoingCalls.length
            ? a.expectedOutgoingCalls.length
            : e.expectedOutgoingCalls.length;
        for (uint256 c = 0; c < m; c++) {
            if (!_outgoingEq(a.expectedOutgoingCalls[c], e.expectedOutgoingCalls[c])) {
                console.log("      expectedOutgoingCalls[%s] differs", c);
            }
        }
        if (a.expectedLookups.length != e.expectedLookups.length) {
            console.log(
                "      expectedLookups.length: actual %s expected %s",
                a.expectedLookups.length,
                e.expectedLookups.length
            );
        }
        m = a.expectedLookups.length < e.expectedLookups.length ? a.expectedLookups.length : e.expectedLookups.length;
        for (uint256 c = 0; c < m; c++) {
            if (!_lookupEq(a.expectedLookups[c], e.expectedLookups[c])) {
                console.log("      expectedLookups[%s] differs", c);
            }
        }
    }

    function _diffCall(uint256 c, CrossChainCall memory a, CrossChainCall memory e) internal pure {
        if (a.isStatic != e.isStatic) {
            console.log("      call[%s].isStatic: actual %s expected %s", c, a.isStatic, e.isStatic);
        }
        if (a.targetAddress != e.targetAddress) {
            console.log("      call[%s].targetAddress: actual %s expected %s", c, a.targetAddress, e.targetAddress);
        }
        if (a.value != e.value) {
            console.log("      call[%s].value: actual %s expected %s", c, a.value, e.value);
        }
        if (!_bytesEq(a.data, e.data)) {
            console.log("      call[%s].data: actual %s expected %s", c, _shortBytes(a.data), _shortBytes(e.data));
        }
        if (a.sourceAddress != e.sourceAddress) {
            console.log("      call[%s].sourceAddress: actual %s expected %s", c, a.sourceAddress, e.sourceAddress);
        }
        if (a.sourceRollupId != e.sourceRollupId) {
            console.log("      call[%s].sourceRollupId: actual %s expected %s", c, a.sourceRollupId, e.sourceRollupId);
        }
        if (a.revertSpan != e.revertSpan) {
            console.log("      call[%s].revertSpan: actual %s expected %s", c, a.revertSpan, e.revertSpan);
        }
    }

    // ── L2: IncomingCrossChainCallExecuted events — recompute the hash from the
    //    emitted fields (format check, needs no expected data) and compare the
    //    fields against the expected entry's inbound call (incomingCalls[0]). ──

    function _verifyIncomingCallEvents(Vm.EthGetLogs[] memory logs, address managerL2, bytes memory expectedTable)
        internal
        view
        returns (bool ok)
    {
        ok = true;
        uint256 rid;
        try IEEZL2View(managerL2).ROLLUP_ID() returns (uint256 r) {
            rid = r;
        } catch {
            console.log("NOTE: manager has no ROLLUP_ID() - skipping incoming-call hash recompute");
            return true;
        }
        L2ExecutionEntry[] memory expected =
            expectedTable.length > 0 ? abi.decode(expectedTable, (L2ExecutionEntry[])) : new L2ExecutionEntry[](0);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != SIG_INCOMING_CROSSCHAIN_CALL) continue;
            if (!_checkIncomingEvent(logs[i].topics[1], logs[i].data, rid, expected)) ok = false;
        }
    }

    /// @dev Own frame per event — the decode + recompute + compare locals overflow
    ///      the via-ir stack when inlined into the log loop.
    function _checkIncomingEvent(
        bytes32 emittedHash,
        bytes memory eventData,
        uint256 rid,
        L2ExecutionEntry[] memory expected
    )
        internal
        pure
        returns (bool ok)
    {
        ok = true;
        (address dest, uint256 value, bytes memory data, address src, uint256 srcRollup) =
            abi.decode(eventData, (address, uint256, bytes, address, uint256));
        bytes32 computed = keccak256(abi.encode(rid, dest, value, data, src, srcRollup));
        if (computed != emittedHash) {
            console.log("FAIL: IncomingCrossChainCallExecuted fields do not hash to the emitted crossChainCallHash");
            console.log("      emitted    %s", vm.toString(emittedHash));
            console.log("      recomputed %s", vm.toString(computed));
            ok = false;
        }
        for (uint256 j = 0; j < expected.length; j++) {
            if (expected[j].proxyEntryHash != emittedHash || expected[j].incomingCalls.length == 0) continue;
            CrossChainCall memory c = expected[j].incomingCalls[0];
            if (
                c.targetAddress != dest || c.value != value || !_bytesEq(c.data, data) || c.sourceAddress != src
                    || c.sourceRollupId != srcRollup
            ) {
                console.log("FAIL: entry %s: inbound call event fields differ from expected incomingCalls[0]:", j);
                _diffCall(0, CrossChainCall(c.isStatic, dest, value, data, src, srcRollup, c.revertSpan), c);
                ok = false;
            }
        }
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
        run(blockNumber, rollups, expectedCallHashes, "");
    }

    /// @dev Blob-aware variant: `expectedTable` is abi.encode(ExecutionEntry[]) from
    ///      ComputeExpected. Adds per-entry field checks (EntryExecuted, rollupId routing,
    ///      stateDeltas, partition invariant) and the live state-root movement check.
    function run(
        uint256 blockNumber,
        address rollups,
        bytes32[] calldata expectedCallHashes,
        bytes memory expectedTable
    )
        public
        view
    {
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

        if (expectedTable.length > 0 && !_verifyL1EntryFields(logs, rollups, expectedTable)) {
            revert("Field verification failed");
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
        run(fromBlock, toBlock, rollups, expectedCallHashes, "");
    }

    function run(
        uint256 fromBlock,
        uint256 toBlock,
        address rollups,
        bytes32[] calldata expectedCallHashes,
        bytes memory expectedTable
    )
        public
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

        if (expectedTable.length > 0 && !_verifyL1EntryFields(logs, rollups, expectedTable)) {
            revert("Field verification failed");
        }

        console.log(
            "PASS: %s/%s expected call hashes consumed in L1 range",
            expectedCallHashes.length,
            expectedCallHashes.length
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
        run(fromBlock, toBlock, rollups, expectedEntryHashes, "");
    }

    function run(
        uint256 fromBlock,
        uint256 toBlock,
        address rollups,
        bytes32[] calldata expectedEntryHashes,
        bytes memory expectedTable
    )
        public
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

        if (expectedTable.length > 0 && !_verifyL1EntryFields(logs, rollups, expectedTable)) {
            revert("Field verification failed");
        }

        console.log(
            "PASS: %s/%s expected L1 entries executed in range", expectedEntryHashes.length, expectedEntryHashes.length
        );
        // Pin the block/tx of the first matching EntryExecuted, and emit EVERY
        // distinct settlement tx with a matching event as a candidate. Parallel
        // runs of the same scenario are indistinguishable at the event level —
        // EntryExecuted only carries the rolling hash, which never folds call
        // addresses — so the first match may be a sibling job's batch; the
        // runner disambiguates by checking each candidate tx's calldata.
        bytes32[] memory seenTxs = new bytes32[](logs.length);
        uint256 nSeen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != SIG_ENTRY_EXECUTED) continue;
            (bytes32 rollingHash,,) = abi.decode(logs[i].data, (bytes32, uint256, uint256));
            bytes32 h = keccak256(abi.encode(bytes32(0), rollingHash));
            bool matched = false;
            for (uint256 j = 0; j < expectedEntryHashes.length; j++) {
                if (h == expectedEntryHashes[j]) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
            bool dup = false;
            for (uint256 k = 0; k < nSeen; k++) {
                if (seenTxs[k] == logs[i].transactionHash) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            seenTxs[nSeen++] = logs[i].transactionHash;
            if (nSeen == 1) {
                console.log("L1_MATCH_BLOCK=%s", logs[i].blockNumber);
                console.log("L1_BATCH_TX=%s", vm.toString(logs[i].transactionHash));
            }
            console.log("L1_BATCH_TX_CANDIDATE=%s", vm.toString(logs[i].transactionHash));
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
//  VerifyL1BatchCalldata — decode the settlement tx's postAndVerifyBatch
//  input and compare the POSTED entries field-by-field against the
//  expected table. The L1 analogue of the L2 ExecutionTableLoaded check:
//  L1 events never carry the entries, but the tx calldata does.
// ══════════════════════════════════════════════════════════════════════

contract VerifyL1BatchCalldata is VerifyHelpers {
    // postAndVerifyBatch selectors, derived from the full tuple signatures.
    // Current = HEAD ABI (forge inspect EEZ methodIdentifiers); legacy =
    // pre-addStatic 5c51e02 ABI, verified against live devnet settlement txs.
    bytes4 constant SEL_POST_BATCH = 0xd1fc6b5a;
    bytes4 constant SEL_POST_BATCH_LEGACY = 0x8b1a095a;

    function run(bytes calldata batchInput, address rollups, bytes calldata expectedTable) external view {
        require(expectedTable.length > 0, "expected table required");
        require(batchInput.length > 4, "batch input too short");
        bytes4 sel = bytes4(batchInput[:4]);
        ExecutionEntry[] memory posted;
        bool legacyAbi;
        if (sel == SEL_POST_BATCH) {
            ProofSystemBatchPerVerificationEntries memory b =
                abi.decode(batchInput[4:], (ProofSystemBatchPerVerificationEntries));
            posted = b.entries;
        } else if (sel == SEL_POST_BATCH_LEGACY) {
            LegacyL1Batch memory b = abi.decode(batchInput[4:], (LegacyL1Batch));
            posted = _fromLegacyL1Entries(b.entries);
            legacyAbi = true;
        } else {
            console.log("Unknown settlement tx selector: %s", vm.toString(abi.encodePacked(sel)));
            revert("settlement tx is not postAndVerifyBatch (update selectors if the ABI changed)");
        }
        console.log("Posted batch decoded from calldata: %s entries", posted.length);
        if (!_verifyL1PostedEntries(posted, rollups, expectedTable, legacyAbi)) {
            revert("Posted-batch calldata verification failed");
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
//  VerifyL2Blocks — check ExecutionTableLoaded events in one of the
//  given blocks contain all expected entry hashes.
// ══════════════════════════════════════════════════════════════════════

contract VerifyL2Blocks is VerifyHelpers {
    function run(uint256[] calldata l2Blocks, address managerL2, bytes32[] calldata expectedEntryHashes) external view {
        run(l2Blocks, managerL2, expectedEntryHashes, "");
    }

    /// @dev Blob-aware variant: `expectedTable` is abi.encode(L2ExecutionEntry[]) from
    ///      ComputeExpected. On the block that matches the entry hashes, additionally
    ///      compares every entry field, checks structural invariants, and matches the
    ///      EntryExecuted result fields.
    function run(
        uint256[] calldata l2Blocks,
        address managerL2,
        bytes32[] calldata expectedEntryHashes,
        bytes memory expectedTable
    )
        public
        view
    {
        if (l2Blocks.length == 0) {
            console.log("FAIL: no L2 blocks to check");
            revert("No L2 blocks");
        }

        for (uint256 i = 0; i < l2Blocks.length; i++) {
            L2ExecutionEntry[] memory entries = _getEntries(l2Blocks[i], managerL2);
            if (_allPresent(entries, expectedEntryHashes)) {
                bytes32[] memory topics = new bytes32[](0);
                Vm.EthGetLogs[] memory blkLogs = vm.eth_getLogs(l2Blocks[i], l2Blocks[i], managerL2, topics);
                if (expectedTable.length > 0 && !_verifyL2TableFields(entries, blkLogs, expectedTable)) {
                    revert("Field verification failed");
                }
                console.log(
                    "PASS: all %s expected entries found at L2 block %s", expectedEntryHashes.length, l2Blocks[i]
                );
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
        run(l2Blocks, managerL2, expectedCallHashes, "");
    }

    /// @dev Blob-aware variant: for every IncomingCrossChainCallExecuted event, recomputes
    ///      the crossChainCallHash from the emitted fields + ROLLUP_ID() (format check,
    ///      runs even with an empty blob) and, when `expectedTable` is given, compares the
    ///      event fields against the expected entry's inbound call.
    function run(
        uint256[] calldata l2Blocks,
        address managerL2,
        bytes32[] calldata expectedCallHashes,
        bytes memory expectedTable
    )
        public
        view
    {
        if (l2Blocks.length == 0) {
            console.log("FAIL: no L2 blocks to check");
            revert("No L2 blocks");
        }

        bool fieldsOk = true;
        for (uint256 i = 0; i < l2Blocks.length; i++) {
            bytes32[] memory topics = new bytes32[](0);
            Vm.EthGetLogs[] memory blkLogs = vm.eth_getLogs(l2Blocks[i], l2Blocks[i], managerL2, topics);
            if (!_verifyIncomingCallEvents(blkLogs, managerL2, expectedTable)) fieldsOk = false;
        }
        if (!fieldsOk) revert("Field verification failed");

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

        console.log(
            "PASS: %s/%s expected L2 calls found in range", expectedCallHashes.length, expectedCallHashes.length
        );
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
