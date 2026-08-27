// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    RootUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry,
    ProofSystemBatchPerVerificationEntries
} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";
import {ComputeExpectedBase} from "./ComputeExpectedBase.sol";
import {crossChainCallHash, HashStep, RollingHashBuilder} from "./E2EHelpers.sol";

// ══════════════════════════════════════════════════════════════════════
//  Minimal read interfaces for live on-chain checks
// ══════════════════════════════════════════════════════════════════════

interface IRollupsRegistryView {
    function rollups(uint64 rollupId) external view returns (address rollupContract, bytes32 root, uint256 etherBalance);
}

interface IEEZL2View {
    function ROLLUP_ID() external view returns (uint64);
}

// ══════════════════════════════════════════════════════════════════════
//  Shared helpers — event signatures + formatting. Inherits the entry-hash
//  and short-formatting primitives (_entryHash, _shortHash, _shortBytes,
//  _sub) from ComputeExpectedBase so there is a single implementation.
// ══════════════════════════════════════════════════════════════════════

abstract contract VerifyHelpers is ComputeExpectedBase {
    // EntryExecuted(uint256 indexed entryIndex, bytes32 rollingHash, uint256 callsProcessed, uint256 consumed)
    // Same signature on L1 (l2ToL1Calls / expectedL1ToL2Calls) and L2 (incomingCalls / expectedOutgoingCalls).
    bytes32 constant SIG_ENTRY_EXECUTED = keccak256("EntryExecuted(uint256,bytes32,uint256,uint256)");

    // BatchPosted(uint256 rollupCount) — carries only the count; the posted entries travel in the
    // postAndVerifyBatch tx calldata (see VerifyL1BatchCalldata).
    bytes32 constant SIG_BATCH_POSTED = keccak256("BatchPosted(uint256)");

    // ExecutionConsumed on L1: (bytes32 crossChainCallHash, uint64 rollupId, uint256 entryQueueIndex) — all indexed
    bytes32 constant SIG_EXECUTION_CONSUMED_L1 = keccak256("ExecutionConsumed(bytes32,uint64,uint256)");

    // IncomingCrossChainCallExecuted on L2: emitted by `executeIncomingCrossChainCall`.
    bytes32 constant SIG_INCOMING_CROSSCHAIN_CALL =
        keccak256("IncomingCrossChainCallExecuted(bytes32,bool,address,uint64,address,uint256,uint64,bytes)");

    // ExecutionTableLoaded(ExecutionEntry[] entries, StaticExecutionEntry[] staticEntries) — L2 only
    // (IEEZL2 structs; no RootUpdate[] / destinationRollupId on L2).
    //   ExecutionEntry  = (bytes32, CrossChainCall[], ExpectedOutgoingCrossChainCall[], bytes32, bool, bytes)
    //                      proxyEntryHash  incomingCalls  expectedOutgoingCalls          rollingHash success ret
    //   CrossChainCall  = (uint16, bool, uint64, address, uint64, address, uint256, bytes)  // revertNextNCalls, isStatic, gas, ...
    //   ExpectedOutgoingCrossChainCall = (bytes32, CrossChainCall[], bytes32, bool, bytes)
    //   StaticExecutionEntry           = (bytes32, CrossChainCall[], bytes32, bool, bytes)
    bytes32 constant SIG_TABLE_LOADED = keccak256(
        "ExecutionTableLoaded((bytes32,(uint16,bool,uint64,address,uint64,address,uint256,bytes)[],(bytes32,(uint16,bool,uint64,address,uint64,address,uint256,bytes)[],bytes32,bool,bytes)[],bytes32,bool,bytes)[],(bytes32,(uint16,bool,uint64,address,uint64,address,uint256,bytes)[],bytes32,bool,bytes)[])"
    );

    // L2's outgoing-call event — 6 fields, trailing uint64 callGas. Only matched against L2
    // manager logs; L1's 5-field `CrossChainCallExecuted` overload has a different topic0.
    bytes32 constant SIG_CROSSCHAIN_CALL =
        keccak256("CrossChainCallExecuted(bytes32,address,address,bytes,uint256,uint64)");

    function _printEntryDetailed(uint256 idx, ExecutionEntry memory e) internal pure {
        bool l2tx = e.proxyEntryHash == bytes32(0);
        console.log("  [%s] %s  crossChainCallHash=%s", idx, l2tx ? "L2TX" : "PROXY", vm.toString(e.proxyEntryHash));
        console.log("      rollingHash: %s", vm.toString(e.rollingHash));
        console.log(
            "      success=%s  calls=%s  nested=%s", e.success, e.l2ToL1Calls.length, e.expectedL1ToL2Calls.length
        );
        for (uint256 d = 0; d < e.rootUpdates.length; d++) {
            RootUpdate memory sd = e.rootUpdates[d];
            console.log(
                string.concat(
                    "      rootUpdate: rollup ",
                    vm.toString(sd.rollupId),
                    " -> ",
                    _shortHash(sd.newRoot),
                    "  ether=",
                    vm.toString(sd.etherDelta)
                )
            );
        }
        for (uint256 c = 0; c < e.l2ToL1Calls.length; c++) {
            L2ToL1Call memory cc = e.l2ToL1Calls[c];
            console.log("      call[%s]: target=%s", c, cc.targetAddress);
            console.log(
                "        isStatic=%s  value=%s  revertNextNCalls=%s", cc.isStatic, cc.value, cc.revertNextNCalls
            );
            console.log("        from=%s @ rollup %s", cc.sourceAddress, cc.sourceRollupId);
            console.log("        data=%s", _shortBytes(cc.data));
        }
        for (uint256 n = 0; n < e.expectedL1ToL2Calls.length; n++) {
            ExpectedL1ToL2Call memory na = e.expectedL1ToL2Calls[n];
            console.log(
                string.concat(
                    "      nested[",
                    vm.toString(n),
                    "]: expectedL1toL2Hash=",
                    _shortHash(na.expectedL1toL2Hash),
                    "  success=",
                    na.success ? "true" : "false"
                )
            );
        }
        if (e.returnData.length > 0) {
            console.log("      returnData: %s", _shortBytes(e.returnData));
        }
        console.log("      entryHash: %s", vm.toString(_entryHash(e)));
    }

    /// @dev L2 (IEEZL2) entry — no rootUpdates / destinationRollupId.
    function _printEntryDetailed(uint256 idx, L2ExecutionEntry memory e) internal pure {
        bool l2tx = e.proxyEntryHash == bytes32(0);
        console.log("  [%s] %s  crossChainCallHash=%s", idx, l2tx ? "L2TX" : "PROXY", vm.toString(e.proxyEntryHash));
        console.log("      rollingHash: %s", vm.toString(e.rollingHash));
        console.log(
            "      success=%s  calls=%s  nested=%s", e.success, e.incomingCalls.length, e.expectedOutgoingCalls.length
        );
        for (uint256 c = 0; c < e.incomingCalls.length; c++) {
            CrossChainCall memory cc = e.incomingCalls[c];
            console.log("      call[%s]: target=%s", c, cc.targetAddress);
            console.log(
                "        isStatic=%s  value=%s  revertNextNCalls=%s", cc.isStatic, cc.value, cc.revertNextNCalls
            );
            console.log("        from=%s @ rollup %s", cc.sourceAddress, cc.sourceRollupId);
            console.log("        data=%s", _shortBytes(cc.data));
        }
        for (uint256 n = 0; n < e.expectedOutgoingCalls.length; n++) {
            ExpectedOutgoingCrossChainCall memory na = e.expectedOutgoingCalls[n];
            console.log(
                string.concat(
                    "      nested[",
                    vm.toString(n),
                    "]: expectedOutgoingHash=",
                    _shortHash(na.expectedOutgoingHash),
                    "  success=",
                    na.success ? "true" : "false"
                )
            );
        }
        if (e.returnData.length > 0) {
            console.log("      returnData: %s", _shortBytes(e.returnData));
        }
        console.log("      entryHash: %s", vm.toString(_entryHash(e)));
    }

    // ── Log collection: decode ExecutionTableLoaded (L2 entries) ──

    function _collectTableEntries(Vm.EthGetLogs[] memory logs) internal pure returns (L2ExecutionEntry[] memory) {
        uint256 totalCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_TABLE_LOADED) {
                L2ExecutionEntry[] memory entries = abi.decode(logs[i].data, (L2ExecutionEntry[]));
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
            }
        }
        return all;
    }

    /// @dev First indexed param (topics[1]) of every log matching `sig`, in log order.
    ///      Collection only — duplicates are kept so the multiplicity-aware matchers
    ///      (`_findMissingHashes`, `_allPresent`) see every event occurrence.
    function _collectTopic1(Vm.EthGetLogs[] memory logs, bytes32 sig) internal pure returns (bytes32[] memory) {
        return _collectTopic1(logs, sig, sig);
    }

    /// @dev Two-signature variant: logs matching EITHER signature (e.g. the proxy-driven
    ///      and system-driven L2 call-executed events, which both index the call hash).
    function _collectTopic1(
        Vm.EthGetLogs[] memory logs,
        bytes32 sigA,
        bytes32 sigB
    )
        internal
        pure
        returns (bytes32[] memory)
    {
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sigA || logs[i].topics[0] == sigB) count++;
        }
        bytes32[] memory result = new bytes32[](count);
        uint256 idx;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sigA || logs[i].topics[0] == sigB) {
                result[idx++] = logs[i].topics[1];
            }
        }
        return result;
    }

    /// @dev Concatenated target-contract logs of every listed block (blocks are queried one
    ///      by one — the list may be sparse, and unlisted in-between blocks must not leak in).
    function _getLogsUnion(
        uint256[] calldata blockNumbers,
        address target
    )
        internal
        view
        returns (Vm.EthGetLogs[] memory)
    {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[][] memory perBlock = new Vm.EthGetLogs[][](blockNumbers.length);
        uint256 total;
        for (uint256 i = 0; i < blockNumbers.length; i++) {
            perBlock[i] = vm.eth_getLogs(blockNumbers[i], blockNumbers[i], target, topics);
            total += perBlock[i].length;
        }
        Vm.EthGetLogs[] memory all = new Vm.EthGetLogs[](total);
        uint256 idx;
        for (uint256 i = 0; i < perBlock.length; i++) {
            for (uint256 j = 0; j < perBlock[i].length; j++) {
                all[idx++] = perBlock[i][j];
            }
        }
        return all;
    }

    /// @dev Multiplicity-aware: each actual hash satisfies at most one expected slot, so
    ///      N-call scenarios emitting the same hash N times need N actual events.
    function _findMissingHashes(
        bytes32[] memory actual,
        bytes32[] calldata expected
    )
        internal
        pure
        returns (bytes32[] memory)
    {
        bytes32[] memory tmp = new bytes32[](expected.length);
        bool[] memory used = new bool[](actual.length);
        uint256 count;
        for (uint256 i = 0; i < expected.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < actual.length; j++) {
                if (!used[j] && actual[j] == expected[i]) {
                    used[j] = true;
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

    // ══════════════════════════════════════════════════════════════════
    //  Field-level verification (expected-table blobs)
    //
    //  ComputeExpected prints EXPECTED_L1_TABLE / EXPECTED_L2_TABLE as
    //  abi.encode(entries) blobs; the runners pass them through so every
    //  entry field can be compared, not just the (proxyEntryHash,
    //  rollingHash) identity. Empty blob = checks skipped (back-compat).
    // ══════════════════════════════════════════════════════════════════

    /// @dev EntryExecuted payload: (rollingHash, callsProcessed, consumed) —
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

    function _outgoingEq(
        ExpectedOutgoingCrossChainCall memory a,
        ExpectedOutgoingCrossChainCall memory b
    )
        internal
        pure
        returns (bool)
    {
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

    /// @dev `nestedConsumed` is checked as an UPPER BOUND, not exactly: the consumed cursor
    ///      only advances past reentrant rows whose frame COMMITS — a `success: false` row's
    ///      terminal revert rolls the advance back, and static-kind rows are position-pinned,
    ///      never consumed. Correctness is not weakened: the rolling hash folds every
    ///      NESTED_BEGIN/END boundary, so a missing or extra frame diverges `rollingHash`.
    function _hasTriple(
        ExecutedTriple[] memory triples,
        bytes32 rh,
        uint256 calls,
        uint256 maxNested
    )
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < triples.length; i++) {
            if (
                triples[i].rollingHash == rh && triples[i].callsProcessed == calls
                    && triples[i].nestedConsumed <= maxNested
            ) {
                return true;
            }
        }
        return false;
    }

    function _hasCountsTriple(
        ExecutedTriple[] memory triples,
        uint256 calls,
        uint256 maxNested
    )
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < triples.length; i++) {
            if (triples[i].callsProcessed == calls && triples[i].nestedConsumed <= maxNested) return true;
        }
        return false;
    }

    // ── L1: per-entry field checks against ExecutionConsumed / EntryExecuted + live roots ──

    function _verifyL1EntryFields(
        Vm.EthGetLogs[] memory logs,
        address rollupsAddr,
        bytes memory expectedTable
    )
        internal
        view
        returns (bool ok)
    {
        ExecutionEntry[] memory expected = abi.decode(expectedTable, (ExecutionEntry[]));
        if (expected.length == 0) {
            console.log("NOTE: expected L1 table decodes to 0 entries - field checks are vacuous");
        }
        ExecutedTriple[] memory executed = _collectExecutedTriples(logs);
        ok = true;
        for (uint256 i = 0; i < expected.length; i++) {
            if (!_checkL1Entry(logs, executed, i, expected[i])) ok = false;
        }
        if (!_checkLiveRoots(rollupsAddr, expected)) ok = false;
        if (ok) {
            console.log(
                "PASS: L1 field checks on %s entries (EntryExecuted, rollupId, rootUpdates, live roots)",
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
        // EntryExecuted must report (rollingHash, callsProcessed) exactly; nestedConsumed is an
        // upper bound (see _hasTriple). A `success: false` entry emits the event and then
        // reverts — the log is discarded with the rollback — so it is only required for
        // committing entries.
        if (e.success && !_hasTriple(executed, e.rollingHash, e.l2ToL1Calls.length, e.expectedL1ToL2Calls.length)) {
            // Root-agnostic fallback: the expected rollingHash folds placeholder state
            // roots, so it cannot match a live devnet's real-root settlement. Accept an
            // EntryExecuted with the right call/nested counts — the entry's full content
            // (and, with EXPECTED_L1_STEPS, its exact rebased rolling hash) is pinned by
            // the posted-calldata comparison.
            if (_hasCountsTriple(executed, e.l2ToL1Calls.length, e.expectedL1ToL2Calls.length)) {
                console.log("NOTE: entry %s EntryExecuted matched by counts only (rolling hash is root-dependent)", i);
            } else {
                console.log(
                    "FAIL: entry %s: no EntryExecuted matching (rollingHash, callsProcessed, nestedConsumed)", i
                );
                console.log(
                    "      want rollingHash=%s calls=%s nested<=%s",
                    vm.toString(e.rollingHash),
                    e.l2ToL1Calls.length,
                    e.expectedL1ToL2Calls.length
                );
                ok = false;
            }
        }
        // Prover obligation: at least one RootUpdate (`EntryHasNoRootUpdates` on-chain).
        // Per-update root movement is deliberately NOT required: entries executed in the same
        // L2 block share one root transition, so all but one legitimately carry
        // currentRoot == newRoot. Movement is asserted per rollup across the whole table
        // instead (_checkLiveRoots).
        if (e.rootUpdates.length == 0) {
            console.log("FAIL: entry %s carries no RootUpdate (unpinned from RootMismatch backstop)", i);
            ok = false;
        }
    }

    /// @dev Reads the live registry root per touched rollup: it must equal the last update's
    ///      newRoot (exact settlement), or at minimum have moved off the pre-batch root.
    function _checkLiveRoots(address rollupsAddr, ExecutionEntry[] memory expected) internal view returns (bool ok) {
        uint256 maxUpdates;
        for (uint256 i = 0; i < expected.length; i++) {
            maxUpdates += expected[i].rootUpdates.length;
        }
        uint64[] memory rids = new uint64[](maxUpdates);
        bytes32[] memory pre = new bytes32[](maxUpdates);
        bytes32[] memory post = new bytes32[](maxUpdates);
        bool[] memory hasSuccessfulEntry = new bool[](maxUpdates);
        uint256 n;
        for (uint256 i = 0; i < expected.length; i++) {
            for (uint256 d = 0; d < expected[i].rootUpdates.length; d++) {
                RootUpdate memory sd = expected[i].rootUpdates[d];
                bool seen = false;
                for (uint256 k = 0; k < n; k++) {
                    if (rids[k] == sd.rollupId) {
                        post[k] = sd.newRoot; // updates apply in entry order — track the final root
                        if (expected[i].success) hasSuccessfulEntry[k] = true;
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    rids[n] = sd.rollupId;
                    pre[n] = sd.currentRoot;
                    post[n] = sd.newRoot;
                    hasSuccessfulEntry[n] = expected[i].success;
                    n++;
                }
            }
        }
        ok = true;
        for (uint256 k = 0; k < n; k++) {
            // The table as a whole must move each touched rollup's root (per-entry movement is
            // not required — same-L2-block entries share one transition).
            if (pre[k] == post[k] && hasSuccessfulEntry[k]) {
                console.log("FAIL: rollup %s root does not move across the table", rids[k]);
                ok = false;
            } else if (pre[k] == post[k]) {
                // A failed entry's frame rolls its RootUpdate and event back.
                // Its L2 checkpoint is persisted by the preceding successful
                // carrier (often the unmatched anchor), so an expected table
                // containing only failed entries is intentionally a no-op.
                console.log("PASS: rollup %s failed-entry table uses carrier no-op root", rids[k]);
            }
            (, bytes32 live,) = IRollupsRegistryView(rollupsAddr).rollups(rids[k]);
            if (live == post[k]) {
                console.log("PASS: rollup %s live root == expected newRoot", rids[k]);
            } else if (live != pre[k]) {
                console.log("PASS: rollup %s root changed (advanced beyond this batch)", rids[k]);
            } else {
                console.log("FAIL: rollup %s root UNCHANGED - still the pre-batch root:", rids[k]);
                console.log("      %s", vm.toString(live));
                ok = false;
            }
        }
    }

    // ── L1: posted-batch calldata comparison. The batch entries ACTUALLY posted
    //    on-chain (decoded from the settlement tx's postAndVerifyBatch input) are
    //    field-matched against the expected table — the L1 analogue of the L2
    //    ExecutionTableLoaded comparison. RootUpdate ROOTS are checked structurally
    //    and against the live registry, never against the expected blob:
    //    ComputeExpected cannot predict real roots off-chain. ──

    /// @dev Root-agnostic pairing key for posted <-> expected entries. ComputeExpected
    ///      builds entries over PLACEHOLDER roots while a live devnet settles real
    ///      ones, and the roots leak into every hash: the rolling-hash seed folds each
    ///      (rollupId, currentRoot) pair, and nested keys fold the live rolling hash.
    ///      Fold only root-independent content: identity, routing, outcome, every flat
    ///      call, per-update (rollupId, etherDelta), and nested rows' own content.
    ///      Per-call return data is NOT bound here (it lives only in the rolling hash);
    ///      the chain already verified the posted rollingHash against actual execution,
    ///      so a content match on a settled batch pins everything except the roots.
    function _contentMatchHash(ExecutionEntry memory e) internal pure returns (bytes32 h) {
        h = keccak256(abi.encode(e.proxyEntryHash, e.destinationRollupId, e.success, e.returnData));
        for (uint256 d = 0; d < e.rootUpdates.length; d++) {
            h = keccak256(abi.encode(h, e.rootUpdates[d].rollupId, e.rootUpdates[d].etherDelta));
        }
        for (uint256 c = 0; c < e.l2ToL1Calls.length; c++) {
            h = keccak256(abi.encode(h, e.l2ToL1Calls[c]));
        }
        for (uint256 n = 0; n < e.expectedL1ToL2Calls.length; n++) {
            h = keccak256(abi.encode(h, _nestedContentHash(e.expectedL1ToL2Calls[n])));
        }
    }

    function _nestedContentHash(ExpectedL1ToL2Call memory n) internal pure returns (bytes32 h) {
        h = keccak256(abi.encode(n.success, n.returnData));
        for (uint256 c = 0; c < n.l2ToL1Calls.length; c++) {
            h = keccak256(abi.encode(h, n.l2ToL1Calls[c]));
        }
    }

    /// @dev Pair expected[i] against an unused posted entry: exact (proxyEntryHash,
    ///      rollingHash) identity first — binding in local mode, where the test itself
    ///      posts the placeholder roots — falling back to the root-agnostic content key
    ///      for live devnets. Returns the posted index or type(uint256).max.
    function _findPostedTwin(
        ExecutionEntry[] memory posted,
        bool[] memory used,
        ExecutionEntry memory e
    )
        internal
        pure
        returns (uint256)
    {
        for (uint256 j = 0; j < posted.length; j++) {
            if (!used[j] && _entryHash(posted[j]) == _entryHash(e)) return j;
        }
        for (uint256 j = 0; j < posted.length; j++) {
            if (!used[j] && _contentMatchHash(posted[j]) == _contentMatchHash(e)) return j;
        }
        return type(uint256).max;
    }

    function _verifyL1PostedEntries(
        ExecutionEntry[] memory posted,
        address rollupsAddr,
        bytes memory expectedTable,
        bytes memory expectedSteps
    )
        internal
        view
        returns (bool ok)
    {
        ExecutionEntry[] memory expected = abi.decode(expectedTable, (ExecutionEntry[]));
        ExecutionEntry[] memory matched = new ExecutionEntry[](expected.length);
        uint256 nMatched;
        // Recorded fold steps (index-aligned with `expected`) let us rebuild each
        // entry's EXACT rolling hash from the POSTED seed roots — the only part
        // ComputeExpected cannot predict — closing the per-call-result gap the
        // content match leaves open. Optional: absent steps degrade to content-only.
        HashStep[][] memory steps;
        if (expectedSteps.length > 0) {
            steps = abi.decode(expectedSteps, (HashStep[][]));
            if (steps.length != expected.length) {
                console.log("FAIL: EXPECTED_L1_STEPS has %s entries, table has %s", steps.length, expected.length);
                return false;
            }
        } else {
            console.log("NOTE: no EXPECTED_L1_STEPS - posted rolling hashes not replay-verified");
        }
        // Entries are queue-consumed in order and the match keys are NOT unique
        // (e.g. two identical increments) — match each posted entry at most once,
        // in posting order.
        bool[] memory used = new bool[](posted.length);
        ok = true;
        for (uint256 i = 0; i < expected.length; i++) {
            uint256 j = _findPostedTwin(posted, used, expected[i]);
            if (j == type(uint256).max) {
                console.log("FAIL: expected entry %s not in posted batch (no identity or content match)", i);
                ok = false;
                continue;
            }
            used[j] = true;
            matched[nMatched++] = posted[j];
            if (!_comparePostedEntry(posted[j], expected[i], i)) ok = false;
            if (steps.length > 0) {
                bytes32 seed = RollingHashBuilder.entryBegin(posted[j].rootUpdates, posted[j].proxyEntryHash);
                bytes32 rebased = RollingHashBuilder.foldSteps(seed, steps[i]);
                if (rebased != posted[j].rollingHash) {
                    console.log("FAIL: entry %s posted rollingHash not reproduced by replaying expected steps", i);
                    console.log("      posted %s rebased %s", vm.toString(posted[j].rollingHash), vm.toString(rebased));
                    ok = false;
                }
            }
        }
        assembly {
            mstore(matched, nMatched)
        }
        // Contiguity across OUR matched entries only — a live devnet batch also carries other
        // actors' entries (and possibly stacked alternatives, see docs/CAVEATS.md) whose
        // updates legitimately don't chain with ours.
        if (!_checkPostedUpdateChain(matched)) ok = false;
        // structural invariants the contracts enforce on every posted entry
        for (uint256 i = 0; i < matched.length; i++) {
            if (!_checkPostedEntryStructure(matched[i], i)) ok = false;
        }
        // live-root + root-movement check against the REAL posted updates (exact roots,
        // unlike the expected blob's local placeholders)
        if (!_checkLiveRoots(rollupsAddr, matched)) ok = false;
        if (ok) {
            console.log(
                "PASS: posted batch calldata matches expected table (%s entries, field-by-field)", expected.length
            );
            if (steps.length > 0) {
                console.log("PASS: posted rolling hashes reproduced from posted roots (%s entries)", expected.length);
            }
        }
    }

    function _comparePostedEntry(
        ExecutionEntry memory a,
        ExecutionEntry memory e,
        uint256 i
    )
        internal
        pure
        returns (bool ok)
    {
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
        if (a.success != e.success) {
            console.log("FAIL: entry %s success: posted %s expected %s", i, a.success, e.success);
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
        if (!_comparePostedUpdates(a.rootUpdates, e.rootUpdates, i)) ok = false;
        if (!_comparePostedCalls(a.l2ToL1Calls, e.l2ToL1Calls, i)) ok = false;
        if (!_comparePostedNested(a.expectedL1ToL2Calls, e.expectedL1ToL2Calls, i)) ok = false;
    }

    /// @dev rollupId and etherDelta are deterministic and compared exactly; the
    ///      roots themselves are only sanity-checked (posted update must not be a
    ///      no-op) — their live settlement is covered by _checkLiveRoots.
    function _comparePostedUpdates(
        RootUpdate[] memory a,
        RootUpdate[] memory e,
        uint256 i
    )
        internal
        pure
        returns (bool ok)
    {
        ok = true;
        if (a.length == 0) {
            console.log("FAIL: entry %s posted with no RootUpdate (unpinned from RootMismatch backstop)", i);
            ok = false;
        }
        if (a.length != e.length) {
            console.log("FAIL: entry %s rootUpdates.length: posted %s expected %s", i, a.length, e.length);
            ok = false;
        }
        uint256 m = a.length < e.length ? a.length : e.length;
        for (uint256 d = 0; d < m; d++) {
            if (a[d].rollupId != e[d].rollupId || a[d].etherDelta != e[d].etherDelta) {
                console.log(
                    string.concat(
                        "FAIL: entry ",
                        vm.toString(i),
                        " rootUpdate ",
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

    /// @dev Per-rollup update-chain contiguity across the MATCHED posted entries, in posting
    ///      order: every update must continue from the previous one (pre == previous post).
    ///      This is a composer convention for e2e batches, not a contract invariant — the
    ///      contracts only require `currentRoot == live root` at consumption, and
    ///      docs/CAVEATS.md blesses stacked alternatives that share a pre-state. Root
    ///      MOVEMENT is asserted separately in _checkLiveRoots.
    function _checkPostedUpdateChain(ExecutionEntry[] memory posted) internal pure returns (bool ok) {
        ok = true;
        uint256 maxUpdates;
        for (uint256 i = 0; i < posted.length; i++) {
            maxUpdates += posted[i].rootUpdates.length;
        }
        uint64[] memory rids = new uint64[](maxUpdates);
        bytes32[] memory lastPost = new bytes32[](maxUpdates);
        uint256 n;
        for (uint256 i = 0; i < posted.length; i++) {
            for (uint256 d = 0; d < posted[i].rootUpdates.length; d++) {
                RootUpdate memory sd = posted[i].rootUpdates[d];
                bool seen = false;
                for (uint256 k = 0; k < n; k++) {
                    if (rids[k] != sd.rollupId) continue;
                    seen = true;
                    if (sd.currentRoot != lastPost[k]) {
                        console.log(
                            "FAIL: rollup %s posted update chain broken at entry %s (pre != previous post)",
                            sd.rollupId,
                            i
                        );
                        ok = false;
                    }
                    lastPost[k] = sd.newRoot;
                    break;
                }
                if (!seen) {
                    rids[n] = sd.rollupId;
                    lastPost[n] = sd.newRoot;
                    n++;
                }
            }
        }
    }

    /// @dev Structural invariants `_validateBatchStructure` enforces on every posted entry —
    ///      asserting them here binds the decoded calldata to the contract's own rules, not
    ///      just to the expected blob (a wrong-but-consistent pair would fool pure equality).
    function _checkPostedEntryStructure(ExecutionEntry memory e, uint256 i) internal pure returns (bool ok) {
        ok = true;
        // rootUpdates strictly increasing by rollupId, all > MAINNET (rollup 0 has no root)
        for (uint256 d = 0; d < e.rootUpdates.length; d++) {
            uint64 prev = d == 0 ? 0 : e.rootUpdates[d - 1].rollupId;
            if (e.rootUpdates[d].rollupId <= prev) {
                console.log("FAIL: entry %s rootUpdates not strictly increasing at %s", i, d);
                ok = false;
            }
            if (!e.success && e.rootUpdates[d].currentRoot != e.rootUpdates[d].newRoot) {
                console.log("FAIL: failed entry %s root update %s is not a carrier no-op", i, d);
                ok = false;
            }
        }
        // proxy protection: destination + every call's source rollup must be in the update set
        if (!_inUpdates(e.rootUpdates, e.destinationRollupId)) {
            console.log("FAIL: entry %s destinationRollupId %s not in rootUpdates", i, e.destinationRollupId);
            ok = false;
        }
        if (!_checkCallsStructure(e.rootUpdates, e.l2ToL1Calls, i)) ok = false;
        for (uint256 nf = 0; nf < e.expectedL1ToL2Calls.length; nf++) {
            if (!_checkCallsStructure(e.rootUpdates, e.expectedL1ToL2Calls[nf].l2ToL1Calls, i)) ok = false;
        }
    }

    function _checkCallsStructure(
        RootUpdate[] memory updates,
        L2ToL1Call[] memory calls,
        uint256 i
    )
        internal
        pure
        returns (bool ok)
    {
        ok = true;
        for (uint256 c = 0; c < calls.length; c++) {
            if (!_inUpdates(updates, calls[c].sourceRollupId)) {
                console.log("FAIL: entry %s call source rollup %s not in rootUpdates", i, calls[c].sourceRollupId);
                ok = false;
            }
            if (calls[c].isStatic && calls[c].value != 0) {
                console.log("FAIL: entry %s static call %s carries value (StaticCallWithValue)", i, c);
                ok = false;
            }
        }
    }

    function _inUpdates(RootUpdate[] memory updates, uint64 rid) internal pure returns (bool) {
        for (uint256 d = 0; d < updates.length; d++) {
            if (updates[d].rollupId == rid) return true;
        }
        return false;
    }

    function _comparePostedCalls(
        L2ToL1Call[] memory a,
        L2ToL1Call[] memory e,
        uint256 i
    )
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

    function _comparePostedNested(
        ExpectedL1ToL2Call[] memory a,
        ExpectedL1ToL2Call[] memory e,
        uint256 i
    )
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

    // Struct equality via encoded hashes, each in its own frame (via-ir stack).
    function _l1CallEq(L2ToL1Call memory a, L2ToL1Call memory b) internal pure returns (bool) {
        bytes32 ha = keccak256(abi.encode(a));
        bytes32 hb = keccak256(abi.encode(b));
        return ha == hb;
    }

    /// @dev Root-agnostic: skips expectedL1toL2Hash and revertedOrStaticRollingHash —
    ///      both fold the live rolling hash, whose seed folds the real (locally
    ///      unpredictable) roots. A wrong key cannot settle anyway: it diverges
    ///      the on-chain rolling hash (CALL_NOT_FOUND) and the entry reverts.
    function _l1NestedEq(ExpectedL1ToL2Call memory a, ExpectedL1ToL2Call memory b) internal pure returns (bool) {
        return _nestedContentHash(a) == _nestedContentHash(b);
    }

    function _diffL1Call(uint256 c, L2ToL1Call memory a, L2ToL1Call memory e) internal pure {
        if (a.revertNextNCalls != e.revertNextNCalls) {
            console.log(
                "      call[%s].revertNextNCalls: posted %s expected %s", c, a.revertNextNCalls, e.revertNextNCalls
            );
        }
        if (a.isStatic != e.isStatic) {
            console.log("      call[%s].isStatic: posted %s expected %s", c, a.isStatic, e.isStatic);
        }
        if (a.gas != e.gas) {
            console.log("      call[%s].gas: posted %s expected %s", c, a.gas, e.gas);
        }
        if (a.sourceAddress != e.sourceAddress) {
            console.log("      call[%s].sourceAddress: posted %s expected %s", c, a.sourceAddress, e.sourceAddress);
        }
        if (a.sourceRollupId != e.sourceRollupId) {
            console.log("      call[%s].sourceRollupId: posted %s expected %s", c, a.sourceRollupId, e.sourceRollupId);
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
    }

    // ── L2: full-struct comparison of the loaded table + invariants + EntryExecuted ──

    function _verifyL2TableFields(
        L2ExecutionEntry[] memory actual,
        Vm.EthGetLogs[] memory logs,
        bytes memory expectedTable,
        bytes32[] memory eventlessEntryHashes
    )
        internal
        pure
        returns (bool ok)
    {
        L2ExecutionEntry[] memory expected = abi.decode(expectedTable, (L2ExecutionEntry[]));
        if (expected.length == 0) {
            console.log("NOTE: expected L2 table decodes to 0 entries - field checks are vacuous");
        }
        ExecutedTriple[] memory executed = _collectExecutedTriples(logs);
        ok = true;
        for (uint256 i = 0; i < expected.length; i++) {
            bool eventlessAllowed = _containsHash(eventlessEntryHashes, _entryHash(expected[i]));
            if (!_checkL2Entry(actual, executed, i, expected[i], eventlessAllowed)) ok = false;
        }
        if (ok) {
            console.log(
                "PASS: L2 field checks on %s entries (full struct, invariants, execution-event policy)", expected.length
            );
        }
    }

    function _containsHash(bytes32[] memory values, bytes32 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == needle) return true;
        }
        return false;
    }

    function _checkL2Entry(
        L2ExecutionEntry[] memory actual,
        ExecutedTriple[] memory executed,
        uint256 i,
        L2ExecutionEntry memory e,
        bool eventlessAllowed
    )
        internal
        pure
        returns (bool ok)
    {
        ok = true;
        // Full struct equality: at least ONE loaded entry with the same (proxyEntryHash,
        // rollingHash) must match every field. The identity is NOT unique — two cached
        // source entries can share a seed-only rolling hash and differ only in returnData
        // (e.g. multi-call-twiceL2) — so a non-equal twin is not a failure by itself.
        uint256 firstHashMatch = type(uint256).max;
        bool matchedExact = false;
        for (uint256 j = 0; j < actual.length; j++) {
            if (_entryHash(actual[j]) != _entryHash(e)) continue;
            if (firstHashMatch == type(uint256).max) firstHashMatch = j;
            if (_l2EntryEq(actual[j], e)) {
                matchedExact = true;
                break;
            }
        }
        if (firstHashMatch == type(uint256).max) {
            console.log("FAIL: entry %s: no loaded entry with matching entryHash", i);
            ok = false;
        } else if (!matchedExact) {
            console.log("FAIL: entry %s: loaded table entry differs from expected:", i);
            _diffL2Entry(actual[firstHashMatch], e);
            ok = false;
        }
        // Structural invariants
        if (e.proxyEntryHash == bytes32(0)) {
            console.log("FAIL: entry %s: zero proxyEntryHash is invalid on L2", i);
            ok = false;
        }
        for (uint256 c = 0; c < e.incomingCalls.length; c++) {
            // StaticCallWithValue on-chain; revertNextNCalls carries no static restriction.
            if (e.incomingCalls[c].isStatic && e.incomingCalls[c].value != 0) {
                console.log("FAIL: entry %s call %s: static call must have value == 0", i, c);
                ok = false;
            }
        }
        // EntryExecuted must report (rollingHash, callsProcessed) exactly; outgoingConsumed is
        // an upper bound (see _hasTriple). A `success: false` entry's event is discarded with
        // its rollback — only required for committing entries.
        if (e.success && !_hasTriple(executed, e.rollingHash, e.incomingCalls.length, e.expectedOutgoingCalls.length)) {
            if (eventlessAllowed) {
                // The loaded entry is exact, but its only consumption occurred
                // inside an enclosing application frame that intentionally
                // reverted. EEZL2's EntryExecuted event unwinds with that frame.
                console.log("NOTE: entry %s is explicitly eventless after enclosing-frame rollback", i);
            } else {
                console.log(
                    "FAIL: entry %s: no EntryExecuted matching (rollingHash, callsProcessed, outgoingConsumed)", i
                );
                ok = false;
            }
        }
    }

    function _diffL2Entry(L2ExecutionEntry memory a, L2ExecutionEntry memory e) internal pure {
        if (a.success != e.success) {
            console.log("      success: actual %s expected %s", a.success, e.success);
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
    }

    function _diffCall(uint256 c, CrossChainCall memory a, CrossChainCall memory e) internal pure {
        if (a.revertNextNCalls != e.revertNextNCalls) {
            console.log(
                "      call[%s].revertNextNCalls: actual %s expected %s", c, a.revertNextNCalls, e.revertNextNCalls
            );
        }
        if (a.isStatic != e.isStatic) {
            console.log("      call[%s].isStatic: actual %s expected %s", c, a.isStatic, e.isStatic);
        }
        if (a.gas != e.gas) {
            console.log("      call[%s].gas: actual %s expected %s", c, a.gas, e.gas);
        }
        if (a.sourceAddress != e.sourceAddress) {
            console.log("      call[%s].sourceAddress: actual %s expected %s", c, a.sourceAddress, e.sourceAddress);
        }
        if (a.sourceRollupId != e.sourceRollupId) {
            console.log("      call[%s].sourceRollupId: actual %s expected %s", c, a.sourceRollupId, e.sourceRollupId);
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
    }

    // ── L2: IncomingCrossChainCallExecuted events — recompute the hash from the
    //    emitted fields (format check, needs no expected data) and compare the
    //    fields against the expected entry's inbound call (incomingCalls[0]). ──

    function _verifyIncomingCallEvents(
        Vm.EthGetLogs[] memory logs,
        address managerL2,
        bytes memory expectedTable
    )
        internal
        view
        returns (bool ok)
    {
        ok = true;
        uint64 rid;
        try IEEZL2View(managerL2).ROLLUP_ID() returns (uint64 r) {
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
        uint64 rid,
        L2ExecutionEntry[] memory expected
    )
        internal
        pure
        returns (bool ok)
    {
        ok = true;
        // Event data is in hash-formula field order; the inbound binding folds the call's OWN gas.
        (
            bool isStatic,
            address src,
            uint256 srcRollup,
            address dest,
            uint256 value,
            uint256 callGas,
            bytes memory data
        ) = abi.decode(eventData, (bool, address, uint256, address, uint256, uint256, bytes));
        bytes32 computed = keccak256(abi.encode(isStatic, src, srcRollup, dest, uint256(rid), value, callGas, data));
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
                    || c.sourceRollupId != srcRollup || c.isStatic != isStatic || c.gas != callGas
            ) {
                console.log("FAIL: entry %s: inbound call event fields differ from expected incomingCalls[0]:", j);
                _diffCall(
                    0,
                    CrossChainCall(
                        c.revertNextNCalls, isStatic, uint64(callGas), src, uint64(srcRollup), dest, value, data
                    ),
                    c
                );
                ok = false;
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
//  VerifyL1BatchInRange — check ExecutionConsumed logs in [fromBlock..
//  toBlock] contain all expected call hashes (subset match). `BatchPosted`
//  carries no entries; consumption is signalled via `ExecutionConsumed`
//  whose first topic is the consumed entry's `crossChainCallHash`.
//  A known settlement block (L1-trigger flows) is the fromBlock == toBlock
//  degenerate range; L2-starting scenarios scan a real range because the
//  settlement block is not known a priori (batches don't encode L2 block
//  references).
// ══════════════════════════════════════════════════════════════════════

contract VerifyL1BatchInRange is VerifyHelpers {
    function run(
        uint256 fromBlock,
        uint256 toBlock,
        address rollups,
        bytes32[] calldata expectedCallHashes
    )
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

        bytes32[] memory actualHashes = _collectTopic1(logs, SIG_EXECUTION_CONSUMED_L1);
        uint256 matchBlock;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_EXECUTION_CONSUMED_L1) {
                matchBlock = logs[i].blockNumber;
                break;
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
        // Every BatchPosted tx is a candidate — sibling jobs may settle in the same
        // range, so the calldata stage must be able to try them all.
        bool first = true;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SIG_BATCH_POSTED) {
                if (first) console.log("L1_BATCH_TX=%s", vm.toString(logs[i].transactionHash));
                first = false;
                console.log("L1_BATCH_TX_CANDIDATE=%s", vm.toString(logs[i].transactionHash));
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
//  drained via executeL2Txs). Those consumptions emit NO ExecutionConsumed
//  call hash; instead we match EntryExecuted events: each carries the
//  entry's final rollingHash, and for zero-hash entries
//  entryHash == keccak256(abi.encode(bytes32(0), rollingHash)) — directly
//  comparable against ComputeExpected's EXPECTED_L1_HASHES.
// ══════════════════════════════════════════════════════════════════════

contract VerifyL1ZeroHashEntriesInRange is VerifyHelpers {
    function run(
        uint256 fromBlock,
        uint256 toBlock,
        address rollups,
        bytes32[] calldata expectedEntryHashes
    )
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
                if (logs[i].data.length < 96) continue; // foreign layout — don't decode
                (bytes32 rollingHash,,) = abi.decode(logs[i].data, (bytes32, uint256, uint256));
                actualHashes[idx++] = keccak256(abi.encode(bytes32(0), rollingHash));
            }
        }
        assembly {
            mstore(actualHashes, idx)
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
        // distinct settlement tx with a matching event as a candidate. Call hashes
        // are not unique across runs — parallel or repeated jobs of the same
        // scenario can emit identical rolling hashes — so the first match may be
        // a sibling job's batch; the runner disambiguates by checking each
        // candidate tx's calldata.
        bytes32[] memory seenTxs = new bytes32[](logs.length);
        uint256 nSeen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != SIG_ENTRY_EXECUTED) continue;
            if (logs[i].data.length < 96) continue; // foreign layout — don't decode
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

/// @title VerifyL1SettlementTxsInRange — root-agnostic settlement discovery (network,
/// zero-hash entries). The expected entry hashes fold placeholder roots, but the
/// on-chain rolling-hash seed folds the REAL roots the composer settles, so event-level
/// hash matching cannot work against a live devnet. Instead: list every distinct tx in
/// range that emitted EntryExecuted on the registry (first as L1_MATCH_BLOCK /
/// L1_BATCH_TX, all as L1_BATCH_TX_CANDIDATE) and let the runner pin OUR settlement by
/// decoding each candidate's posted calldata (VerifyL1BatchCalldata, roots neutralized).
/// Reverts while nothing has settled so the runner's deadline loop keeps waiting.
contract VerifyL1SettlementTxsInRange is VerifyHelpers {
    function run(uint256 fromBlock, uint256 toBlock, address rollups) external view {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(fromBlock, toBlock, rollups, topics);
        bytes32[] memory seenTxs = new bytes32[](logs.length);
        uint256 nSeen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != SIG_ENTRY_EXECUTED) continue;
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
        if (nSeen == 0) revert("no settlement txs in range yet");
        console.log("PASS: %s settlement tx(s) with EntryExecuted in range", nSeen);
    }
}

// ══════════════════════════════════════════════════════════════════════
//  VerifyL1BatchCalldata — decode the settlement tx's postAndVerifyBatch
//  input and compare the POSTED entries field-by-field against the
//  expected table. The L1 analogue of the L2 ExecutionTableLoaded check:
//  L1 events never carry the entries, but the tx calldata does.
// ══════════════════════════════════════════════════════════════════════

contract VerifyL1BatchCalldata is VerifyHelpers {
    // postAndVerifyBatch(ProofSystemBatchPerVerificationEntries) — derived from the full
    // tuple signature (forge inspect EEZ methodIdentifiers).
    bytes4 constant SEL_POST_BATCH = 0xcafef125;

    function run(
        bytes calldata batchInput,
        address rollups,
        bytes calldata expectedTable,
        bytes calldata expectedSteps
    )
        external
        view
    {
        require(expectedTable.length > 0, "expected table required");
        require(batchInput.length > 4, "batch input too short");
        bytes4 sel = bytes4(batchInput[:4]);
        if (sel != SEL_POST_BATCH) {
            console.log("Unknown settlement tx selector: %s", vm.toString(abi.encodePacked(sel)));
            revert("settlement tx is not postAndVerifyBatch (update SEL_POST_BATCH if the ABI changed)");
        }
        ProofSystemBatchPerVerificationEntries memory b =
            abi.decode(batchInput[4:], (ProofSystemBatchPerVerificationEntries));
        console.log("Posted batch decoded from calldata: %s entries", b.entries.length);
        // Immediate-prefix rules the contract enforces (`ImmediateCountExceedsEntries`,
        // `ImmediateCountStrandsLeadingL2Tx`): the count is in bounds and never strands a
        // leading zero-hash L2Tx into the queue.
        if (b.immediateEntryCount > b.entries.length) {
            console.log("FAIL: immediateEntryCount %s exceeds entries %s", b.immediateEntryCount, b.entries.length);
            revert("Posted-batch calldata verification failed");
        }
        if (b.immediateEntryCount < b.entries.length && b.entries[b.immediateEntryCount].proxyEntryHash == bytes32(0)) {
            console.log("FAIL: immediateEntryCount %s strands a leading zero-hash L2Tx", b.immediateEntryCount);
            revert("Posted-batch calldata verification failed");
        }
        if (!_verifyL1PostedEntries(b.entries, rollups, expectedTable, expectedSteps)) {
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
        bytes32[] memory noEventlessEntries = new bytes32[](0);
        _run(l2Blocks, managerL2, expectedEntryHashes, "", noEventlessEntries);
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
        external
        view
    {
        bytes32[] memory noEventlessEntries = new bytes32[](0);
        _run(l2Blocks, managerL2, expectedEntryHashes, expectedTable, noEventlessEntries);
    }

    function run(
        uint256[] calldata l2Blocks,
        address managerL2,
        bytes32[] calldata expectedEntryHashes,
        bytes memory expectedTable,
        bytes32[] calldata eventlessEntryHashes
    )
        external
        view
    {
        _run(l2Blocks, managerL2, expectedEntryHashes, expectedTable, eventlessEntryHashes);
    }

    function _run(
        uint256[] calldata l2Blocks,
        address managerL2,
        bytes32[] calldata expectedEntryHashes,
        bytes memory expectedTable,
        bytes32[] memory eventlessEntryHashes
    )
        internal
        view
    {
        if (l2Blocks.length == 0) {
            console.log("FAIL: no L2 blocks to check");
            revert("No L2 blocks");
        }

        // The system delivers one tx per top-level call, so the expected entries may be
        // spread over several sync blocks — verify against the union of all listed blocks.
        Vm.EthGetLogs[] memory logs = _getLogsUnion(l2Blocks, managerL2);
        L2ExecutionEntry[] memory entries = _collectTableEntries(logs);
        if (!_allPresent(entries, expectedEntryHashes)) {
            _reportL2Failure(l2Blocks, managerL2, expectedEntryHashes);
            revert("Verification failed");
        }
        if (expectedTable.length > 0 && !_verifyL2TableFields(entries, logs, expectedTable, eventlessEntryHashes)) {
            revert("Field verification failed");
        }
        console.log(
            "PASS: all %s expected entries found across %s L2 block(s)", expectedEntryHashes.length, l2Blocks.length
        );
        for (uint256 j = 0; j < logs.length; j++) {
            if (logs[j].topics[0] == SIG_TABLE_LOADED) {
                console.log("L2_TABLE_TX=%s", vm.toString(logs[j].transactionHash));
                break;
            }
        }
    }

    /// @dev Failure diagnostics for `run`, split into its own frame to keep `run` under the
    ///      via-ir stack limit (the inlined i/j/c loop nest would otherwise overflow).
    function _reportL2Failure(
        uint256[] calldata l2Blocks,
        address managerL2,
        bytes32[] calldata expectedEntryHashes
    )
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

    function _allPresent(
        L2ExecutionEntry[] memory entries,
        bytes32[] calldata expectedEntryHashes
    )
        internal
        pure
        returns (bool)
    {
        bytes32[] memory actualHashes = new bytes32[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            actualHashes[i] = _entryHash(entries[i]);
        }
        // Multiplicity-aware: each loaded entry satisfies at most one expected slot.
        bool[] memory used = new bool[](actualHashes.length);
        for (uint256 i = 0; i < expectedEntryHashes.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < actualHashes.length; j++) {
                if (!used[j] && actualHashes[j] == expectedEntryHashes[i]) {
                    used[j] = true;
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
        // Both consumption events count as an executed call (see _collectActionHashes).
        Vm.EthGetLogs[] memory allLogs = _getLogsUnion(l2Blocks, managerL2);
        for (uint256 i = 0; i < allLogs.length; i++) {
            bytes32 sig = allLogs[i].topics[0];
            if (sig == SIG_CROSSCHAIN_CALL || sig == SIG_INCOMING_CROSSCHAIN_CALL) {
                console.log("L2_CALL_TX=%s", vm.toString(allLogs[i].transactionHash));
            }
        }
    }

    function _collectActionHashes(
        uint256[] calldata blocks,
        address managerL2
    )
        internal
        view
        returns (bytes32[] memory)
    {
        // Accept both L2 consumption events: the 6-field CrossChainCallExecuted overload
        // (proxy-driven executeCrossChainCall) AND IncomingCrossChainCallExecuted
        // (system-driven executeIncomingCrossChainCall). The crossChainCallHash is the first
        // indexed param of both, so topics[1] extracts it uniformly. L2-manager logs only —
        // L1's 5-field CrossChainCallExecuted has a different topic0 and would never match.
        return _collectTopic1(_getLogsUnion(blocks, managerL2), SIG_CROSSCHAIN_CALL, SIG_INCOMING_CROSSCHAIN_CALL);
    }
}

// ══════════════════════════════════════════════════════════════════════
//  VerifyL2CallsInRange — range variant of VerifyL2Calls for L1-starting
//  scenarios, where the L2 sync blocks that executed the inbound calls are
//  not known a priori. One eth_getLogs over [fromBlock..toBlock]; prints
//  every block holding an expected-hash hit (L2_MATCH_BLOCKS) so the
//  caller can pin table verification to those blocks — one delivery tx
//  per top-level call means the hits may span several blocks.
// ══════════════════════════════════════════════════════════════════════

contract VerifyL2CallsInRange is VerifyHelpers {
    function run(
        uint256 fromBlock,
        uint256 toBlock,
        address managerL2,
        bytes32[] calldata expectedCallHashes
    )
        external
        view
    {
        bytes32[] memory topics = new bytes32[](0);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(fromBlock, toBlock, managerL2, topics);

        bytes32[] memory found = _collectTopic1(logs, SIG_CROSSCHAIN_CALL, SIG_INCOMING_CROSSCHAIN_CALL);
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
        _printMatchBlocks(logs, expectedCallHashes);
    }

    /// @dev Every distinct block holding an expected-hash log is a sync block — the system
    ///      delivers one tx per top-level call, so N calls may spread over several blocks.
    ///      Prints L2_MATCH_BLOCK (first, kept for message text) and the full L2_MATCH_BLOCKS
    ///      list the runner feeds into table verification.
    function _printMatchBlocks(Vm.EthGetLogs[] memory logs, bytes32[] calldata expectedCallHashes) internal pure {
        uint256[] memory blocks = new uint256[](logs.length);
        uint256 nBlocks;
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 sig = logs[i].topics[0];
            if (sig != SIG_CROSSCHAIN_CALL && sig != SIG_INCOMING_CROSSCHAIN_CALL) continue;
            bool isExpected = false;
            for (uint256 j = 0; j < expectedCallHashes.length; j++) {
                if (logs[i].topics[1] == expectedCallHashes[j]) {
                    isExpected = true;
                    break;
                }
            }
            if (!isExpected) continue;
            if (nBlocks == 0) {
                console.log("L2_MATCH_BLOCK=%s", logs[i].blockNumber);
                console.log("L2_CALL_TX=%s", vm.toString(logs[i].transactionHash));
            }
            bool seen = false;
            for (uint256 k = 0; k < nBlocks; k++) {
                if (blocks[k] == logs[i].blockNumber) {
                    seen = true;
                    break;
                }
            }
            if (!seen) blocks[nBlocks++] = logs[i].blockNumber;
        }
        string memory list = "";
        for (uint256 k = 0; k < nBlocks; k++) {
            list = k == 0 ? vm.toString(blocks[k]) : string.concat(list, ",", vm.toString(blocks[k]));
        }
        console.log("L2_MATCH_BLOCKS=[%s]", list);
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
