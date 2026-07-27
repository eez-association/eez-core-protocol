// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ExecutionEntry,
    StateUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    StaticExecutionEntry,
    ExpectedStateRootPerRollup
} from "../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    StaticExecutionEntry as L2StaticExecutionEntry
} from "../../src/interfaces/IEEZL2.sol";
import {TestHashes} from "../../test/TestHashes.sol";
import {ScenarioStore, CallNode, TxSpec} from "./ScenarioStore.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  TableGenerator — the Blob → Table direction.
//
//  Walks the ScenarioStore call forest once, in message order, and builds every
//  chain's execution artifacts exactly as the prover would:
//
//   L1 (chain 0):  one `ExecutionEntry` per L2-origin transaction (the L2Tx
//     host, `proxyEntryHash == 0`, holding every call that executes on L1) and
//     one per L1-origin root call; `StaticExecutionEntry` pool rows for
//     top-level static reads fired from L1. State deltas come from a fabricated
//     per-rollup root ledger (`genesisRoot` → keccak steps) with the ether
//     invariant accounted per entry.
//
//   Each L2 chain:  a sequence of UNITS in execution order — kind 1 is an
//     origin group (`loadExecutionTable` + the origin actor's own tx consumes
//     the entries), kind 2 is an inbound delivery (one entry driven by
//     `executeIncomingCrossChainCall`).
//
//  Rolling hashes are simulated per chain with the exact `EEZBase` fold schema
//  (via `TestHashes`), including reentrant frames, reverted-frame branch
//  restore, and Snapshot/Revert regions:
//    - on the region-hosting chain the folds are branched (its own EVM revert
//      undoes them natively),
//    - on every other chain the executed calls get `revertNextNCalls` span
//      markers (protocol-level rollback), with hash folds preserved.
// ─────────────────────────────────────────────────────────────────────────────

contract TableGenerator is TestHashes {
    uint64 internal constant L1_CHAIN = 0;
    uint256 internal constant NO_FRAME = type(uint256).max;

    error GeneratorInvariant(string reason);

    ScenarioStore internal _store;
    uint64[] internal _gasByNode;
    bool internal _generated;

    // ── outputs: L1 ──
    ExecutionEntry[] internal _l1Entries;
    StaticExecutionEntry[] internal _l1Statics;
    uint256[] internal _l1EntryTxIdx; // parallel to _l1Entries: owning transaction
    uint256[] internal _l1StaticTxIdx; // parallel to _l1Statics

    // per-L1-entry state-delta aux (filled by the prescan)
    mapping(uint256 => uint64[]) internal _l1Touched;
    mapping(uint256 => mapping(uint64 => bool)) internal _l1TouchedSeen;
    mapping(uint256 => mapping(uint64 => int256)) internal _l1Ether;

    // ── outputs: L2 units ──
    struct UnitTag {
        uint64 chainId;
        uint8 kind; // 1 = origin group (load + own tx), 2 = inbound delivery
        uint256 inboundNodeId; // kind 2: node driven by executeIncomingCrossChainCall
        uint256 txIndex;
    }

    UnitTag[] internal _units;
    mapping(uint256 => L2ExecutionEntry[]) internal _unitEntries;
    mapping(uint256 => L2StaticExecutionEntry[]) internal _unitStatics;

    // ── fabricated per-rollup state-root ledger ──
    uint64[] internal _rollupIds;
    mapping(uint64 => bool) internal _rollupSeen;
    mapping(uint64 => bool) internal _ledgerInit;
    mapping(uint64 => bytes32) internal _ledger;

    // ── walk state ──
    struct Ctx {
        bool hasHost; // an open host entry exists on this chain
        bool hostIsL1;
        uint256 hostEntry; // index into _l1Entries / position within the unit's entries
        uint256 hostUnit; // L2 only
        bytes32 liveHash;
        uint256[] frameStack; // open reentrant-row indices; insertion target = top row's sub-array
    }

    mapping(uint64 => Ctx) internal _ctx;
    mapping(uint64 => uint256) internal _openOriginUnit; // chainId → unitIdx + 1 (0 = none), reset per tx

    // region (Snapshot … Revert) state — v1 supports one region at a time
    bool internal _regionActive;
    uint64 internal _regionHost; // executing chain when the Snapshot appeared
    bool internal _regionBranched; // host had an open entry → hash branch
    bytes32 internal _regionSavedHash;
    bool internal _regionIsRootLevel;
    uint256 internal _regionNonce; // keys span tracking per region (mappings can't be cleared)
    mapping(bytes32 => bool) internal _regionArraySeen; // per-array span tracking
    mapping(bytes32 => uint256) internal _regionSpanStart;
    // ledger snapshot for L1-origin root-level regions (entries chain, then roll back)
    uint64[] internal _regionLedgerIds;
    mapping(uint64 => bool) internal _regionLedgerSaved;
    mapping(uint64 => bytes32) internal _regionLedgerVal;

    // ──────────────────────────────────────────────
    //  Public API
    // ──────────────────────────────────────────────

    /// @notice Fabricated genesis state root a rollup must be registered with.
    function genesisRoot(uint64 rid) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("blobfw-genesis", rid));
    }

    /// @param gasByNode Observed `callGas` per store node id (0 for L1-sourced and static nodes) —
    ///        folded into the source-side keys of calls leaving an L2.
    function generate(ScenarioStore store, uint64[] calldata gasByNode) external {
        if (_generated) revert GeneratorInvariant("already generated");
        _generated = true;
        _store = store;
        _gasByNode = gasByNode;

        uint256 txN = store.txCount();
        for (uint256 t = 0; t < txN; t++) {
            _generateTx(t);
        }
    }

    // ── output getters ──

    function l1Entries() external view returns (ExecutionEntry[] memory) {
        return _l1Entries;
    }

    function l1StaticEntries() external view returns (StaticExecutionEntry[] memory) {
        return _l1Statics;
    }

    function l1EntryTxIndexes() external view returns (uint256[] memory) {
        return _l1EntryTxIdx;
    }

    function l1StaticTxIndexes() external view returns (uint256[] memory) {
        return _l1StaticTxIdx;
    }

    function unitCount() external view returns (uint256) {
        return _units.length;
    }

    function unitTag(uint256 i) external view returns (UnitTag memory) {
        return _units[i];
    }

    function unitEntries(uint256 i) external view returns (L2ExecutionEntry[] memory) {
        return _unitEntries[i];
    }

    function unitStatics(uint256 i) external view returns (L2StaticExecutionEntry[] memory) {
        return _unitStatics[i];
    }

    function rollupIds() external view returns (uint64[] memory) {
        return _rollupIds;
    }

    /// @notice The expected live state root of `rid` after every entry has been consumed.
    function finalRoot(uint64 rid) external view returns (bytes32) {
        return _ledgerInit[rid] ? _ledger[rid] : genesisRoot(rid);
    }

    // ──────────────────────────────────────────────
    //  Transaction walk
    // ──────────────────────────────────────────────

    function _generateTx(uint256 t) internal {
        TxSpec memory txSpec = _store.getTx(t);
        _txCursor = t;
        uint64 origin = txSpec.originChain;
        bool l2Origin = origin != L1_CHAIN;
        if (l2Origin) _touchRollupGlobal(origin);

        uint256 l1HostIdx;
        if (l2Origin) {
            // The tx's single L1 commitment: hosts every call that executes on L1.
            // Root-level regions on an L2 origin roll back on L1 via span markers,
            // so their ether contributions are suppressed.
            l1HostIdx = _openL1Entry(bytes32(0), origin, t);
            bool spanActive = false;
            uint256 spanEnd = 0;
            for (uint256 i = 0; i < txSpec.rootCalls.length; i++) {
                CallNode memory root = _store.getNode(txSpec.rootCalls[i]);
                if (!spanActive && root.revertSpan > 0) {
                    spanActive = true;
                    spanEnd = i + root.revertSpan - 1;
                }
                _prescan(txSpec.rootCalls[i], l1HostIdx, true, origin, spanActive);
                if (spanActive && i == spanEnd) spanActive = false;
            }
            _sealL1Header(l1HostIdx);
        }

        uint256 regionEnd = type(uint256).max;
        for (uint256 i = 0; i < txSpec.rootCalls.length; i++) {
            CallNode memory n = _store.getNode(txSpec.rootCalls[i]);
            if (n.revertSpan > 0) {
                _openRegion(origin, true);
                regionEnd = i + n.revertSpan - 1;
            }
            if (n.isStatic) {
                _rootStatic(origin, n, t);
            } else {
                _rootCall(t, origin, txSpec.rootCalls[i], n);
            }
            if (regionEnd == i) {
                _closeRegion();
                regionEnd = type(uint256).max;
            }
        }

        if (l2Origin) {
            // Close the L2Tx host: its rolling hash accumulated every L1-executed fold.
            ExecutionEntry storage host = _l1Entries[l1HostIdx];
            host.rollingHash = _ctx[L1_CHAIN].liveHash;
            host.success = true;
            host.returnData = "";
            _ctx[L1_CHAIN].hasHost = false;
        }

        // Origin units don't span transactions.
        _openOriginUnit[origin] = 0;
    }

    /// @notice One mutable root call: consumes an origin-side entry on the origin chain
    ///         and executes on the destination side.
    function _rootCall(uint256 t, uint64 origin, uint256 nodeId, CallNode memory n) internal {
        if (n.fromChain != origin) revert GeneratorInvariant("root call fromChain != origin");
        bytes32 cch = _nodeCch(n);

        if (origin == L1_CHAIN) {
            // Origin entry on L1, consumed by the driver's proxy call. A root-level
            // region on an L1 origin does NOT suppress ether: each consumption is
            // fully verified (accumulator included) before the driver's own revert
            // rolls it back — only the ledger advance is undone (see _closeRegion).
            uint256 idx = _openL1Entry(cch, n.toChain, t);
            _prescan(nodeId, idx, true, origin, false);
            _sealL1Header(idx);

            _execCall(nodeId, n);

            ExecutionEntry storage e = _l1Entries[idx];
            e.rollingHash = _ctx[L1_CHAIN].liveHash;
            e.success = n.success;
            e.returnData = n.returnData;
            _ctx[L1_CHAIN].hasHost = false;

            if (!n.success) {
                // A failed consumption reverts its own delta application — the live
                // roots never advance.
                _rollbackLedgerForEntry(idx);
            }
        } else {
            // Origin entry on the L2 origin chain, consumed by the driver's proxy call.
            uint256 unitIdx = _originUnit(origin, t);
            bytes32 srcCch = _sourceCch(nodeId, n);
            L2ExecutionEntry storage e = _unitEntries[unitIdx].push();
            e.proxyEntryHash = srcCch;
            uint256 entryPos = _unitEntries[unitIdx].length - 1;

            Ctx storage c = _ctx[origin];
            c.hasHost = true;
            c.hostIsL1 = false;
            c.hostUnit = unitIdx;
            c.hostEntry = entryPos;
            c.liveHash = _hEntryBeginL2(srcCch);
            _clearFrames(c);

            _execCall(nodeId, n);

            // Re-fetch: pushes to the same unit may have moved nothing (storage), but
            // keep the reference honest.
            L2ExecutionEntry storage sealed_ = _unitEntries[unitIdx][entryPos];
            sealed_.rollingHash = _ctx[origin].liveHash;
            sealed_.success = n.success;
            sealed_.returnData = n.returnData;
            _ctx[origin].hasHost = false;
        }
    }

    // ──────────────────────────────────────────────
    //  Call execution (destination + caller sides)
    // ──────────────────────────────────────────────

    /// @notice Destination-side handling of a mutable call + recursion into children.
    ///         The caller side (reentrant row / origin entry) is handled by the caller.
    function _execCall(uint256 nodeId, CallNode memory n) internal {
        uint64 dest = n.toChain;
        bytes32 cch = _nodeCch(n);

        if (dest == L1_CHAIN) {
            if (!_ctx[L1_CHAIN].hasHost) revert GeneratorInvariant("call into L1 with no host");
            _appendCall(L1_CHAIN, n);
            _foldCallBegin(L1_CHAIN, cch);
            _walkChildren(n);
            _foldCallEnd(L1_CHAIN, n.success, n.returnData);
        } else if (_ctx[dest].hasHost) {
            // Callback into an already-executing chain: lands at its insertion point.
            _appendCall(dest, n);
            _foldCallBegin(dest, cch);
            _walkChildren(n);
            _foldCallEnd(dest, n.success, n.returnData);
        } else {
            // Inbound delivery: a fresh unit whose single entry is driven by
            // executeIncomingCrossChainCall (incomingCalls[0] is the inbound call).
            _touchRollupGlobal(dest);
            uint256 unitIdx = _newUnit(dest, 2, nodeId);
            L2ExecutionEntry storage e = _unitEntries[unitIdx].push();
            e.proxyEntryHash = cch;
            uint16 marker = (_regionActive && dest != _regionHost) ? 1 : 0;
            e.incomingCalls.push(_l2CallStruct(n, marker));

            Ctx storage c = _ctx[dest];
            c.hasHost = true;
            c.hostIsL1 = false;
            c.hostUnit = unitIdx;
            c.hostEntry = 0;
            c.liveHash = _hEntryBeginL2(cch);
            _clearFrames(c);

            _foldCallBegin(dest, cch);
            _walkChildren(n);
            _foldCallEnd(dest, n.success, n.returnData);

            L2ExecutionEntry storage sealed_ = _unitEntries[unitIdx][0];
            sealed_.rollingHash = _ctx[dest].liveHash;
            sealed_.success = n.success;
            sealed_.returnData = n.returnData;
            _ctx[dest].hasHost = false;
        }
    }

    /// @notice Walks a node's children: each mutable child opens a reentrant row on the
    ///         executing chain (the caller side) and recurses; static children become
    ///         STATIC rows / destination-array reads. Handles region brackets.
    function _walkChildren(CallNode memory n) internal {
        uint64 execChain = n.toChain;
        uint256 regionEnd = type(uint256).max;
        for (uint256 i = 0; i < n.children.length; i++) {
            CallNode memory child = _store.getNode(n.children[i]);
            if (child.revertSpan > 0) {
                _openRegion(execChain, false);
                regionEnd = i + child.revertSpan - 1;
            }
            if (child.isStatic) {
                _reentrantStatic(execChain, child);
            } else {
                _reentrantCall(execChain, n.children[i], child);
            }
            if (regionEnd == i) {
                _closeRegion();
                regionEnd = type(uint256).max;
            }
        }
    }

    /// @notice A mutable call leaving `execChain` mid-execution: a row in the host's
    ///         unified reentrant table, keyed by the live rolling hash at fire time.
    function _reentrantCall(uint64 execChain, uint256 nodeId, CallNode memory n) internal {
        if (n.fromChain != execChain) revert GeneratorInvariant("child fromChain != executing chain");
        Ctx storage c = _ctx[execChain];
        if (!c.hasHost) revert GeneratorInvariant("reentrant call with no host");

        bytes32 cch = _sourceCch(nodeId, n);
        bytes32 fireHash = c.liveHash;
        bytes32 key = keccak256(abi.encodePacked(cch, fireHash));

        uint256 rowIdx = _pushRow(execChain, key);
        c.liveHash = _hNestedBegin(c.liveHash, cch);
        c.frameStack.push(rowIdx);

        _execCall(nodeId, n);

        c.frameStack.pop();
        if (n.success) {
            c.liveHash = _hNestedEnd(c.liveHash);
            _sealRow(execChain, rowIdx, bytes32(0), true, n.returnData);
        } else {
            // REVERTED frame: the mini-entry hash is checked, then the terminal revert
            // rolls the host hash (and cursor) back to the fire point.
            _sealRow(execChain, rowIdx, c.liveHash, false, n.returnData);
            c.liveHash = fireHash;
        }
    }

    // ──────────────────────────────────────────────
    //  Static calls (top-level reads may carry leaf sub-reads of the reader chain)
    // ──────────────────────────────────────────────

    /// @notice Top-level static read fired while the origin chain is idle: a pool
    ///         `StaticExecutionEntry` on the origin (caller) chain, its sub-read
    ///         array holding the read's own static children (re-run live on the
    ///         origin during resolution, verified by the untagged accumulator).
    ///         When the read TARGETS an executing chain (the L2Tx host when it
    ///         targets L1), it is additionally evaluated there via STATICCALL — an
    ///         `isStatic` row with real CALL_BEGIN/CALL_END folds, its sub-reads
    ///         matched as STATIC rows at that exact execution point.
    function _rootStatic(uint64 origin, CallNode memory n, uint256 t) internal {
        bytes32 cch = _nodeCch(n);
        _touchRollupGlobal(n.toChain);
        bytes32 subHash = bytes32(0); // untagged accumulator over the sub-read array
        if (origin == L1_CHAIN) {
            StaticExecutionEntry storage se = _l1Statics.push();
            _l1StaticTxIdx.push(t);
            se.proxyEntryHash = cch;
            se.destinationRollupId = n.toChain;
            for (uint256 i = 0; i < n.children.length; i++) {
                CallNode memory sub = _store.getNode(n.children[i]);
                se.l2ToL1Calls.push(_l1CallStruct(sub, 0));
                subHash = _hStatic(subHash, sub.success, sub.returnData);
            }
            se.rollingHash = subHash;
            se.success = n.success;
            se.returnData = n.returnData;
            se.expectedStateRoots
                .push(ExpectedStateRootPerRollup({rollupId: n.toChain, stateRoot: _ledgerGet(n.toChain)}));
        } else {
            uint256 unitIdx = _originUnit(origin, t);
            L2StaticExecutionEntry storage se = _unitStatics[unitIdx].push();
            se.proxyEntryHash = cch;
            for (uint256 i = 0; i < n.children.length; i++) {
                CallNode memory sub = _store.getNode(n.children[i]);
                se.incomingCalls.push(_l2CallStruct(sub, 0));
                subHash = _hStatic(subHash, sub.success, sub.returnData);
            }
            se.rollingHash = subHash;
            se.success = n.success;
            se.returnData = n.returnData;

            if (n.toChain == L1_CHAIN || _ctx[n.toChain].hasHost) {
                // Destination executing: the read really runs there.
                _appendCall(n.toChain, n);
                _foldCallBegin(n.toChain, cch);
                for (uint256 i = 0; i < n.children.length; i++) {
                    CallNode memory sub = _store.getNode(n.children[i]);
                    bytes32 key = keccak256(abi.encodePacked(_nodeCch(sub), _ctx[n.toChain].liveHash));
                    uint256 rowIdx = _pushRow(n.toChain, key);
                    _sealRow(n.toChain, rowIdx, bytes32(0), sub.success, sub.returnData);
                }
                _foldCallEnd(n.toChain, n.success, n.returnData);
            }
        }
    }

    /// @notice Static read fired from an executing chain: a STATIC-kind row in the
    ///         host's unified table (host hash untouched); if the destination chain is
    ///         itself executing, the read also lands in its arrays as an `isStatic`
    ///         call (evaluated at that exact execution point).
    function _reentrantStatic(uint64 execChain, CallNode memory n) internal {
        if (n.fromChain != execChain) revert GeneratorInvariant("static child fromChain != executing chain");
        Ctx storage c = _ctx[execChain];
        if (!c.hasHost) revert GeneratorInvariant("reentrant static with no host");

        bytes32 cch = _nodeCch(n); // folds isStatic = true
        bytes32 key = keccak256(abi.encodePacked(cch, c.liveHash));
        uint256 rowIdx = _pushRow(execChain, key);
        _sealRow(execChain, rowIdx, bytes32(0), n.success, n.returnData);

        if (n.toChain == L1_CHAIN || _ctx[n.toChain].hasHost) {
            // Destination executing: the read is evaluated there via STATICCALL.
            _appendCall(n.toChain, n);
            _foldCallBegin(n.toChain, cch);
            _foldCallEnd(n.toChain, n.success, n.returnData);
        }
        // Destination idle: the read resolves against its settled state — nothing to record.
    }

    // ──────────────────────────────────────────────
    //  Regions (Snapshot … Revert)
    // ──────────────────────────────────────────────

    function _openRegion(uint64 hostChain, bool rootLevel) internal {
        if (_regionActive) revert GeneratorInvariant("nested region");
        _regionActive = true;
        _regionNonce++;
        _regionHost = hostChain;
        _regionIsRootLevel = rootLevel;
        _regionBranched = _ctx[hostChain].hasHost;
        if (_regionBranched) {
            // The host's own EVM revert undoes its folds natively.
            _regionSavedHash = _ctx[hostChain].liveHash;
        }
    }

    function _closeRegion() internal {
        if (_regionBranched) {
            _ctx[_regionHost].liveHash = _regionSavedHash;
        }
        if (_regionIsRootLevel && _regionHost == L1_CHAIN) {
            // The driver's revert rolls back the in-region consumptions on L1 —
            // restore the fabricated ledger to the region-start roots.
            for (uint256 i = 0; i < _regionLedgerIds.length; i++) {
                uint64 rid = _regionLedgerIds[i];
                _ledger[rid] = _regionLedgerVal[rid];
                _regionLedgerSaved[rid] = false;
            }
            delete _regionLedgerIds;
        }
        _regionActive = false;
        _regionBranched = false;
        _regionIsRootLevel = false;
    }

    // ──────────────────────────────────────────────
    //  Prescan: touched rollups + ether deltas for one L1 entry
    // ──────────────────────────────────────────────

    /// @notice Recursively collects, for the L1 entry `entryIdx`, every rollup its
    ///         hosted subtree touches and the entry's per-rollup ether contributions.
    /// @param suppressEther true inside a region whose L1 effects roll back at the
    ///        protocol layer (span markers / actor-level revert), so the ether never
    ///        counts toward the entry's accumulator invariant.
    function _prescan(uint256 nodeId, uint256 entryIdx, bool isRoot, uint64 origin, bool suppressEther) internal {
        CallNode memory n = _store.getNode(nodeId);
        if (n.fromChain != L1_CHAIN) _touch(entryIdx, n.fromChain);
        if (n.toChain != L1_CHAIN) _touch(entryIdx, n.toChain);

        if (!suppressEther && !n.isStatic && n.value > 0) {
            if (n.toChain == L1_CHAIN) {
                // A call into L1 pays out of the source rollup's balance (only if it succeeds).
                if (n.success) _etherAdd(entryIdx, n.fromChain, -int256(n.value));
            } else if (n.fromChain == L1_CHAIN) {
                // Ether leaving L1 toward a rollup. The entry-point value of a root call
                // counts regardless of success (the accumulator is SET to msg.value);
                // a failed reentrant row's transfer rolls back with its revert.
                if (isRoot || n.success) _etherAdd(entryIdx, n.toChain, int256(n.value));
            } else if (n.success) {
                // L2 → L2 move: net zero across the L1 manager, balances shift.
                _etherAdd(entryIdx, n.fromChain, -int256(n.value));
                _etherAdd(entryIdx, n.toChain, int256(n.value));
            }
        }

        _prescanChildren(n.children, entryIdx, origin, suppressEther);
    }

    function _prescanChildren(uint256[] memory children, uint256 entryIdx, uint64 origin, bool suppressEther) internal {
        bool spanActive = false;
        uint256 spanEnd = 0;
        for (uint256 i = 0; i < children.length; i++) {
            uint16 span = _store.nodeRevertSpan(children[i]);
            if (!spanActive && span > 0) {
                spanActive = true;
                spanEnd = i + span - 1;
            }
            // Intra-entry regions always suppress L1 ether (their L1 effects roll
            // back via markers or the hosting actor's own revert).
            _prescan(children[i], entryIdx, false, origin, suppressEther || spanActive);
            if (spanActive && i == spanEnd) spanActive = false;
        }
    }

    // ──────────────────────────────────────────────
    //  L1 entry lifecycle
    // ──────────────────────────────────────────────

    function _openL1Entry(bytes32 proxyEntryHash, uint64 destinationRollupId, uint256 txIdx)
        internal
        returns (uint256 idx)
    {
        _touchRollupGlobal(destinationRollupId);
        ExecutionEntry storage e = _l1Entries.push();
        e.proxyEntryHash = proxyEntryHash;
        e.destinationRollupId = destinationRollupId;
        idx = _l1Entries.length - 1;
        _l1EntryTxIdx.push(txIdx);
        _touch(idx, destinationRollupId);
    }

    /// @notice Builds the sealed header (sorted state deltas from the ledger) and
    ///         initializes the L1 walk context with the entry's seed hash.
    function _sealL1Header(uint256 idx) internal {
        ExecutionEntry storage e = _l1Entries[idx];

        // Sort touched rollups ascending (strictly-increasing on-chain requirement).
        uint64[] storage touched = _l1Touched[idx];
        uint64[] memory sorted = new uint64[](touched.length);
        for (uint256 i = 0; i < touched.length; i++) {
            uint64 v = touched[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1] > v) {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = v;
        }

        for (uint256 i = 0; i < sorted.length; i++) {
            uint64 rid = sorted[i];
            bytes32 cur = _ledgerGet(rid);
            bytes32 newRoot = keccak256(abi.encodePacked("blobfw-step", cur, idx));
            e.stateUpdates
                .push(
                    StateUpdate({rollupId: rid, currentState: cur, newState: newRoot, etherDelta: _l1Ether[idx][rid]})
                );
            _ledgerSet(rid, newRoot);
        }

        Ctx storage c = _ctx[L1_CHAIN];
        c.hasHost = true;
        c.hostIsL1 = true;
        c.hostEntry = idx;
        c.liveHash = _hEntryBegin(e.stateUpdates, e.proxyEntryHash);
        _clearFrames(c);
    }

    /// @notice Undoes the ledger advance of a failed (success = false) L1 entry — its
    ///         consumption reverts, so the live roots stay at the entry's currentState.
    function _rollbackLedgerForEntry(uint256 idx) internal {
        ExecutionEntry storage e = _l1Entries[idx];
        for (uint256 i = 0; i < e.stateUpdates.length; i++) {
            _ledger[e.stateUpdates[i].rollupId] = e.stateUpdates[i].currentState;
        }
    }

    function _touch(uint256 entryIdx, uint64 rid) internal {
        if (rid == L1_CHAIN) return;
        _touchRollupGlobal(rid);
        if (!_l1TouchedSeen[entryIdx][rid]) {
            _l1TouchedSeen[entryIdx][rid] = true;
            _l1Touched[entryIdx].push(rid);
        }
    }

    function _etherAdd(uint256 entryIdx, uint64 rid, int256 delta) internal {
        _l1Ether[entryIdx][rid] += delta;
    }

    function _touchRollupGlobal(uint64 rid) internal {
        if (rid == L1_CHAIN || _rollupSeen[rid]) return;
        _rollupSeen[rid] = true;
        _rollupIds.push(rid);
    }

    function _ledgerGet(uint64 rid) internal returns (bytes32) {
        if (!_ledgerInit[rid]) {
            _ledgerInit[rid] = true;
            _ledger[rid] = genesisRoot(rid);
        }
        return _ledger[rid];
    }

    function _ledgerSet(uint64 rid, bytes32 root) internal {
        if (_regionActive && _regionIsRootLevel && _regionHost == L1_CHAIN && !_regionLedgerSaved[rid]) {
            _regionLedgerSaved[rid] = true;
            _regionLedgerVal[rid] = _ledger[rid];
            _regionLedgerIds.push(rid);
        }
        _ledger[rid] = root;
    }

    // ──────────────────────────────────────────────
    //  Units
    // ──────────────────────────────────────────────

    function _newUnit(uint64 chainId, uint8 kind, uint256 inboundNodeId) internal returns (uint256 idx) {
        idx = _units.length;
        _units.push(UnitTag({chainId: chainId, kind: kind, inboundNodeId: inboundNodeId, txIndex: _currentTx()}));
    }

    uint256 internal _txCursor;

    function _currentTx() internal view returns (uint256) {
        return _txCursor;
    }

    /// @notice Lazily creates the per-tx origin group unit for `origin`.
    function _originUnit(uint64 origin, uint256 t) internal returns (uint256 idx) {
        _txCursor = t;
        if (_openOriginUnit[origin] != 0) return _openOriginUnit[origin] - 1;
        idx = _newUnit(origin, 1, 0);
        _openOriginUnit[origin] = idx + 1;
    }

    // ──────────────────────────────────────────────
    //  Insertion / fold plumbing
    // ──────────────────────────────────────────────

    function _clearFrames(Ctx storage c) internal {
        while (c.frameStack.length > 0) {
            c.frameStack.pop();
        }
    }

    /// @notice Appends the call struct at chain `y`'s current insertion point (host
    ///         top-level array, or the open reentrant frame's own sub-array) and
    ///         applies region span markers when `y` is not the region host.
    function _appendCall(uint64 y, CallNode memory n) internal {
        Ctx storage c = _ctx[y];
        bytes32 arrayKey;
        uint256 newIdx;
        uint256 frame = c.frameStack.length == 0 ? NO_FRAME : c.frameStack[c.frameStack.length - 1];

        if (c.hostIsL1) {
            ExecutionEntry storage e = _l1Entries[c.hostEntry];
            if (frame == NO_FRAME) {
                e.l2ToL1Calls.push(_l1CallStruct(n, 0));
                newIdx = e.l2ToL1Calls.length - 1;
            } else {
                e.expectedL1ToL2Calls[frame].l2ToL1Calls.push(_l1CallStruct(n, 0));
                newIdx = e.expectedL1ToL2Calls[frame].l2ToL1Calls.length - 1;
            }
        } else {
            L2ExecutionEntry storage e2 = _unitEntries[c.hostUnit][c.hostEntry];
            if (frame == NO_FRAME) {
                e2.incomingCalls.push(_l2CallStruct(n, 0));
                newIdx = e2.incomingCalls.length - 1;
            } else {
                e2.expectedOutgoingCalls[frame].incomingCalls.push(_l2CallStruct(n, 0));
                newIdx = e2.expectedOutgoingCalls[frame].incomingCalls.length - 1;
            }
        }
        arrayKey = keccak256(abi.encodePacked(_regionNonce, y, c.hostIsL1, c.hostUnit, c.hostEntry, frame));

        if (_regionActive && y != _regionHost) {
            // In-region appends to one array are contiguous (a region is a contiguous
            // message range): the first one starts the span, later ones extend it.
            if (!_regionArraySeen[arrayKey]) {
                _regionArraySeen[arrayKey] = true;
                _regionSpanStart[arrayKey] = newIdx;
                _setMarker(y, frame, newIdx, 1);
            } else {
                uint256 start = _regionSpanStart[arrayKey];
                _bumpMarker(y, frame, start);
            }
        }
    }

    function _setMarker(uint64 y, uint256 frame, uint256 idx, uint16 v) internal {
        Ctx storage c = _ctx[y];
        if (c.hostIsL1) {
            ExecutionEntry storage e = _l1Entries[c.hostEntry];
            if (frame == NO_FRAME) e.l2ToL1Calls[idx].revertNextNCalls = v;
            else e.expectedL1ToL2Calls[frame].l2ToL1Calls[idx].revertNextNCalls = v;
        } else {
            L2ExecutionEntry storage e2 = _unitEntries[c.hostUnit][c.hostEntry];
            if (frame == NO_FRAME) e2.incomingCalls[idx].revertNextNCalls = v;
            else e2.expectedOutgoingCalls[frame].incomingCalls[idx].revertNextNCalls = v;
        }
    }

    function _bumpMarker(uint64 y, uint256 frame, uint256 idx) internal {
        Ctx storage c = _ctx[y];
        if (c.hostIsL1) {
            ExecutionEntry storage e = _l1Entries[c.hostEntry];
            if (frame == NO_FRAME) e.l2ToL1Calls[idx].revertNextNCalls++;
            else e.expectedL1ToL2Calls[frame].l2ToL1Calls[idx].revertNextNCalls++;
        } else {
            L2ExecutionEntry storage e2 = _unitEntries[c.hostUnit][c.hostEntry];
            if (frame == NO_FRAME) e2.incomingCalls[idx].revertNextNCalls++;
            else e2.expectedOutgoingCalls[frame].incomingCalls[idx].revertNextNCalls++;
        }
    }

    /// @notice Opens a reentrant-table row on `y`'s host entry with the given position key.
    function _pushRow(uint64 y, bytes32 key) internal returns (uint256 rowIdx) {
        Ctx storage c = _ctx[y];
        if (c.hostIsL1) {
            ExpectedL1ToL2Call storage row = _l1Entries[c.hostEntry].expectedL1ToL2Calls.push();
            row.expectedL1toL2Hash = key;
            rowIdx = _l1Entries[c.hostEntry].expectedL1ToL2Calls.length - 1;
        } else {
            ExpectedOutgoingCrossChainCall storage row2 =
                _unitEntries[c.hostUnit][c.hostEntry].expectedOutgoingCalls.push();
            row2.expectedOutgoingHash = key;
            rowIdx = _unitEntries[c.hostUnit][c.hostEntry].expectedOutgoingCalls.length - 1;
        }
    }

    function _sealRow(uint64 y, uint256 rowIdx, bytes32 subHash, bool success, bytes memory returnData) internal {
        Ctx storage c = _ctx[y];
        if (c.hostIsL1) {
            ExpectedL1ToL2Call storage row = _l1Entries[c.hostEntry].expectedL1ToL2Calls[rowIdx];
            row.revertedOrStaticRollingHash = subHash;
            row.success = success;
            row.returnData = returnData;
        } else {
            ExpectedOutgoingCrossChainCall storage row2 =
                _unitEntries[c.hostUnit][c.hostEntry].expectedOutgoingCalls[rowIdx];
            row2.revertedOrStaticRollingHash = subHash;
            row2.success = success;
            row2.returnData = returnData;
        }
    }

    function _foldCallBegin(uint64 y, bytes32 cch) internal {
        _ctx[y].liveHash = _hCallBegin(_ctx[y].liveHash, cch);
    }

    function _foldCallEnd(uint64 y, bool success, bytes memory retData) internal {
        _ctx[y].liveHash = _hCallEnd(_ctx[y].liveHash, success, retData);
    }

    // ──────────────────────────────────────────────
    //  Struct helpers
    // ──────────────────────────────────────────────

    function _nodeCch(CallNode memory n) internal pure returns (bytes32) {
        return _ccHash(n.isStatic, n.fromAddress, n.fromChain, n.toAddress, n.toChain, n.value, n.data);
    }

    /// @notice The hash the SOURCE chain keys this call with: gas-folding when the call leaves an
    ///         L2, the plain formula when it leaves L1.
    function _sourceCch(uint256 nodeId, CallNode memory n) internal view returns (bytes32) {
        if (n.fromChain == L1_CHAIN) return _nodeCch(n);
        return
            _ccHashGas(
                n.isStatic, n.fromAddress, n.fromChain, n.toAddress, n.toChain, n.value, _gasByNode[nodeId], n.data
            );
    }

    function _l1CallStruct(CallNode memory n, uint16 span) internal pure returns (L2ToL1Call memory) {
        return L2ToL1Call({
            revertNextNCalls: span,
            isStatic: n.isStatic,
            gas: n.gas,
            sourceAddress: n.fromAddress,
            sourceRollupId: n.fromChain,
            targetAddress: n.toAddress,
            value: n.value,
            data: n.data
        });
    }

    function _l2CallStruct(CallNode memory n, uint16 span) internal pure returns (CrossChainCall memory) {
        return CrossChainCall({
            revertNextNCalls: span,
            isStatic: n.isStatic,
            gas: n.gas,
            sourceAddress: n.fromAddress,
            sourceRollupId: n.fromChain,
            targetAddress: n.toAddress,
            value: n.value,
            data: n.data
        });
    }
}
