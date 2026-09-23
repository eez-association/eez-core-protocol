// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ExecutionEntry, L2ToL1Call, ExpectedL1ToL2Call, StaticExecutionEntry} from "../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    StaticExecutionEntryL2 as L2StaticExecutionEntry
} from "../../src/interfaces/IEEZL2.sol";
import {TableGenerator} from "./TableGenerator.sol";
import {TestHashes} from "../../test/TestHashes.sol";
import {ScenarioStore, CallParams, RevertRegion} from "./ScenarioStore.sol";
import {SidecarTx, SidecarStatic, SidecarStaticResult, SidecarChainOp} from "./BlobSidecar.sol";
import {CallShapes} from "./CallShapes.sol";
import {UNIT_KIND_ORIGIN_GROUP, UNIT_KIND_INBOUND, ROOT_KIND_STATIC, NO_NODE, NO_CHAIN} from "./BlobConstants.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  TableStitcher — the Table → Blob direction.
//
//  Rebuilds the call forest from tables and sidecar metadata. The sidecar
//  supplies transaction boundaries, static tree shape/outcomes, exact rollback
//  regions, chain operations and source gas observations. Mutable fields and
//  results are recovered from table rows using content-addressed keys.
//
//  Static outcomes duplicated in rows are compared; callbacks are checked
//  against their arrays and untagged accumulators. Executing destinations use
//  tagged rolling hashes. Reconstructed rollback regions must reproduce all
//  table span markers. See README.md for the sidecar ABI and model limits.
// ─────────────────────────────────────────────────────────────────────────────

contract TableStitcher is TestHashes {
    uint64 internal constant L1_CHAIN = 0;

    /// @dev Every mismatch carries a locator: the chain being walked (NO_CHAIN
    ///      when none applies), the relevant entry/unit/cursor index, and the
    ///      expected vs got words (hashes, or scalars widened to bytes32; zero
    ///      when the check has no meaningful pair).
    error RoundTripMismatch(string what, uint64 chain, uint256 index, bytes32 expected, bytes32 got);

    // ── inputs: tables ──
    ExecutionEntry[] internal _l1Entries;
    StaticExecutionEntry[] internal _l1Statics;

    uint64[] internal _unitChain;
    uint8[] internal _unitKind; // UNIT_KIND_ORIGIN_GROUP / UNIT_KIND_INBOUND
    mapping(uint256 => L2ExecutionEntry[]) internal _unitEntries;
    mapping(uint256 => L2StaticExecutionEntry[]) internal _unitStatics;

    uint64[] internal _chains; // distinct L2 chain ids seen in units
    mapping(uint64 => bool) internal _chainSeen;

    // ── inputs: sidecar (struct definitions in BlobSidecar.sol) ──
    SidecarTx[] internal _txMeta;
    SidecarStatic[] internal _statics;
    SidecarStaticResult[] internal _staticSubResults;
    uint16[] internal _regionSizes;
    SidecarChainOp[] internal _outChainOps;
    bool internal _hasClose;
    uint256 internal _closeTxsBefore;
    uint256 internal _closeOpsBefore;
    // Observed callGas per L2-sourced mutable call, queued per destination-kind hash in
    // execution order (callGas reaches no table — it lives only inside the source-side keys).
    mapping(bytes32 => uint64[]) internal _callGasQueue;
    mapping(bytes32 => uint256) internal _callGasCursor;

    // ── stitch state ──
    ScenarioStore internal _out;
    bool internal _stitched; // stitch() is single-shot, like TableGenerator.generate
    uint256 internal _l1Cursor; // next L1 entry
    uint256 internal _l1StaticCursor;
    mapping(uint64 => uint256) internal _unitScan; // per-chain scan position over units
    mapping(uint256 => uint256) internal _unitEntryCursor; // per (origin) unit: next entry
    mapping(uint256 => uint256) internal _unitStaticCursor;
    uint256 internal _staticCursor; // sidecar statics
    uint256 internal _staticSubCursor; // sidecar static outcomes

    /// @dev Per-chain walk context — same vocabulary as TableGenerator.Ctx, plus
    ///      the rebuild-side cursors (the generator appends where this scans).
    struct Ctx {
        bool active; // an open host entry is being walked on this chain
        bool hostIsL1; // selects which of hostEntry/hostUnit are meaningful
        uint256 hostUnit; // meaningless when hostIsL1
        uint256 hostEntry; // hostIsL1: index into _l1Entries; else: entry position within _unitEntries[hostUnit]
        bytes32 liveHash;
        uint256 rowCursor; // next reentrant-table row
        uint256 topCursor; // cursor into the entry's top-level call array
        uint256[] frameRows; // open reentrant frames (row indices)
        uint256[] frameCursors; // per open frame: cursor into its sub-array
    }

    mapping(uint64 => Ctx) internal _ctx;

    struct StaticFrame {
        bool pool;
        uint256 index;
        uint256 unit;
        uint256 cursor;
        uint256 count;
        bytes32 expectedHash;
        bytes32 hash;
    }
    mapping(uint64 => StaticFrame[]) internal _staticFrames;
    uint64 internal _origin;
    uint256 internal _staticOriginUnit;

    struct RegionState {
        uint64 host;
        uint256 endNode;
        bool branched;
        bytes32 savedHash;
        bool rootLevel;
        uint256 savedCursor;
    }
    RevertRegion[] internal _regions;
    RegionState[] internal _regionStack;
    uint256 internal _originUnitForTx;
    mapping(uint256 => uint256) internal _unitLiveCursor;

    // ──────────────────────────────────────────────
    //  Loading (harness feeds the generator's outputs + the sidecar)
    //
    //  ORDER MATTERS on every loader below: tables and sidecar rows are consumed
    //  by cursor during the stitch, so each stream must be fed in the order the
    //  generator produced it — units in execution order, sidecar txs in message
    //  order, statics in `staticNodesInOrder` order (their sub-read results in
    //  parent-DFS order), callGas rows in execution (DFS) order per key.
    // ──────────────────────────────────────────────

    function loadL1(ExecutionEntry[] calldata entries, StaticExecutionEntry[] calldata statics) external {
        for (uint256 i = 0; i < entries.length; i++) {
            _l1Entries.push(entries[i]);
        }
        for (uint256 i = 0; i < statics.length; i++) {
            _l1Statics.push(statics[i]);
        }
    }

    /// @notice Units must be loaded in execution order.
    function loadUnit(
        uint64 chainId,
        uint8 kind,
        L2ExecutionEntry[] calldata entries,
        L2StaticExecutionEntry[] calldata statics
    )
        external
    {
        uint256 idx = _unitChain.length;
        _unitChain.push(chainId);
        _unitKind.push(kind);
        for (uint256 i = 0; i < entries.length; i++) {
            _unitEntries[idx].push(entries[i]);
        }
        for (uint256 i = 0; i < statics.length; i++) {
            _unitStatics[idx].push(statics[i]);
        }
        if (!_chainSeen[chainId]) {
            _chainSeen[chainId] = true;
            _chains.push(chainId);
        }
    }

    function loadSidecarTx(uint64 originChain, bytes calldata txData, uint8[] calldata rootKinds) external {
        SidecarTx storage sidecarTx = _txMeta.push();
        sidecarTx.originChain = originChain;
        sidecarTx.txData = txData;
        sidecarTx.rootKinds = rootKinds;
    }

    function loadSidecarStatic(SidecarStatic calldata staticCall) external {
        _statics.push(staticCall);
    }

    function loadSidecarStaticSubResult(bool success, bytes calldata returnData) external {
        SidecarStaticResult storage result = _staticSubResults.push();
        result.success = success;
        result.returnData = returnData;
    }

    function loadSidecarCallGas(bytes32 destCallHash, uint64 callGas) external {
        _callGasQueue[destCallHash].push(callGas);
    }

    function loadSidecarRegionSizes(uint16[] calldata sizes) external {
        for (uint256 i = 0; i < sizes.length; i++) {
            _regionSizes.push(sizes[i]);
        }
    }

    function loadSidecarRegions(RevertRegion[] calldata regions) external {
        for (uint256 i; i < regions.length; i++) {
            _regions.push(regions[i]);
        }
    }

    function loadSidecarChainOp(uint64 chainId, bytes calldata operations, uint256 txsBefore) external {
        _outChainOps.push();
        SidecarChainOp storage op = _outChainOps[_outChainOps.length - 1];
        op.chainId = chainId;
        op.operations = operations;
        op.txsBefore = txsBefore;
    }

    function loadSidecarClose(uint256 txsBefore, uint256 opsBefore) external {
        _hasClose = true;
        _closeTxsBefore = txsBefore;
        _closeOpsBefore = opsBefore;
    }

    // ──────────────────────────────────────────────
    //  Stitch
    // ──────────────────────────────────────────────

    function stitch(ScenarioStore out) external {
        if (_stitched) revert RoundTripMismatch("already stitched", NO_CHAIN, 0, 0, 0);
        _stitched = true;
        _out = out;
        for (uint256 i = 0; i < _outChainOps.length; i++) {
            out.addChainOp(_outChainOps[i].chainId, _outChainOps[i].operations, _outChainOps[i].txsBefore);
        }
        if (_hasClose) out.setClose(_closeTxsBefore, _closeOpsBefore);

        for (uint256 t = 0; t < _txMeta.length; t++) {
            _stitchTx(t);
        }
        if (_l1Cursor != _l1Entries.length) {
            revert RoundTripMismatch(
                "unconsumed L1 entries", L1_CHAIN, _l1Cursor, bytes32(_l1Entries.length), bytes32(_l1Cursor)
            );
        }
        if (
            _staticCursor != _statics.length || _staticSubCursor != _staticSubResults.length
                || _l1StaticCursor != _l1Statics.length
        ) {
            revert RoundTripMismatch(
                "unconsumed static data", NO_CHAIN, _staticCursor, bytes32(_statics.length), bytes32(_staticCursor)
            );
        }
        if (_regionStack.length != 0) revert RoundTripMismatch("unclosed rollback region", NO_CHAIN, 0, 0, 0);
        for (uint256 i; i < _unitChain.length; i++) {
            if (_unitStaticCursor[i] != _unitStatics[i].length) {
                revert RoundTripMismatch("unconsumed L2 statics", _unitChain[i], i, 0, 0);
            }
        }
        if (_regions.length != _regionSizes.length) {
            revert RoundTripMismatch("region metadata count", NO_CHAIN, 0, 0, 0);
        }
        for (uint256 i; i < _regions.length; i++) {
            if (_regions[i].span != _regionSizes[i]) {
                revert RoundTripMismatch("region metadata span", NO_CHAIN, i, 0, 0);
            }
            _out.addRevertRegion(_regions[i].firstNode, _regions[i].lastNode, _regions[i].span);
        }
        _checkRollbackMarkers();
    }

    function _stitchTx(uint256 t) internal {
        SidecarTx storage meta = _txMeta[t];
        uint64 origin = meta.originChain;
        _origin = origin;
        uint256 txId = _out.newTx(origin, meta.txData);

        uint256 l1HostIdx = NO_NODE;
        if (origin != L1_CHAIN) {
            // The tx's L2Tx host commitment on L1.
            l1HostIdx = _l1Cursor++;
            if (_l1Entries[l1HostIdx].proxyEntryHash != bytes32(0)) {
                revert RoundTripMismatch(
                    "expected L2Tx host entry", L1_CHAIN, l1HostIdx, bytes32(0), _l1Entries[l1HostIdx].proxyEntryHash
                );
            }
            _openL1Ctx(l1HostIdx);
        }

        uint256 originUnit = NO_NODE;
        for (uint256 k = 0; k < meta.rootKinds.length; k++) {
            if (origin != L1_CHAIN && originUnit == NO_NODE) originUnit = _nextUnit(origin, UNIT_KIND_ORIGIN_GROUP);
            _originUnitForTx = originUnit;
            _beginRegions(_out.nodeCount(), origin, true);
            uint256 nodeId;
            if (meta.rootKinds[k] == ROOT_KIND_STATIC) {
                if (origin != L1_CHAIN && originUnit == NO_NODE) {
                    originUnit = _nextUnit(origin, UNIT_KIND_ORIGIN_GROUP);
                }
                nodeId = _stitchRootStatic(txId, origin, originUnit);
            } else {
                if (origin == L1_CHAIN) {
                    uint256 idx = _l1Cursor++;
                    ExecutionEntry storage entry = _l1Entries[idx];
                    if (entry.proxyEntryHash == bytes32(0)) {
                        revert RoundTripMismatch("unexpected L2Tx entry", L1_CHAIN, idx, 0, 0);
                    }
                    _openL1Ctx(idx);
                    nodeId = _stitchRootCall(txId, origin, entry.proxyEntryHash, entry.success, entry.returnData);
                    if (_ctx[L1_CHAIN].liveHash != entry.rollingHash) {
                        revert RoundTripMismatch(
                            "L1 root rollingHash", L1_CHAIN, idx, entry.rollingHash, _ctx[L1_CHAIN].liveHash
                        );
                    }
                    _ctx[L1_CHAIN].active = false;
                } else {
                    if (originUnit == NO_NODE) originUnit = _nextUnit(origin, UNIT_KIND_ORIGIN_GROUP);
                    uint256 pos = _unitEntryCursor[originUnit]++;
                    L2ExecutionEntry storage l2Entry = _unitEntries[originUnit][pos];
                    _openL2Ctx(origin, originUnit, pos, _hEntryBeginL2(l2Entry.proxyEntryHash), 0);
                    nodeId = _stitchRootCall(txId, origin, l2Entry.proxyEntryHash, l2Entry.success, l2Entry.returnData);
                    if (_ctx[origin].liveHash != l2Entry.rollingHash) {
                        revert RoundTripMismatch(
                            "origin rollingHash", origin, pos, l2Entry.rollingHash, _ctx[origin].liveHash
                        );
                    }
                    _ctx[origin].active = false;
                    if (l2Entry.success) _unitLiveCursor[originUnit] = pos + 1;
                }
            }
            _endRegions(nodeId);
        }

        if (origin != L1_CHAIN) {
            if (_ctx[L1_CHAIN].liveHash != _l1Entries[l1HostIdx].rollingHash) {
                revert RoundTripMismatch(
                    "L2Tx host rollingHash",
                    L1_CHAIN,
                    l1HostIdx,
                    _l1Entries[l1HostIdx].rollingHash,
                    _ctx[L1_CHAIN].liveHash
                );
            }
            _ctx[L1_CHAIN].active = false;
        }
    }

    /// @notice Root mutable call: fields resolved from the destination side by the
    ///         origin entry's proxyEntryHash; result from the origin entry.
    function _stitchRootCall(
        uint256 txId,
        uint64 origin,
        bytes32 callHash,
        bool success,
        bytes memory returnData
    )
        internal
        returns (uint256 nodeId)
    {
        CallParams memory params = _resolveByCallHash(origin, callHash);
        _consumeCallGas(params);
        nodeId = _out.newCall(txId, NO_NODE, params);
        _out.setResult(nodeId, success, returnData);
        _stitchDestination(txId, nodeId, params, success, returnData);
    }

    /// @notice Rebuild a static tree from its sidecar shape, checking lookup results,
    /// callback identities and accumulators, and any executing destination's hash.
    function _stitchRootStatic(uint256 txId, uint64 origin, uint256 originUnit) internal returns (uint256) {
        _staticOriginUnit = originUnit;
        return _stitchStatic(txId, NO_NODE, origin);
    }

    function _stitchStatic(uint256 txId, uint256 parent, uint64 source) internal returns (uint256 nodeId) {
        SidecarStatic memory shape = _statics[_staticCursor++];
        SidecarStaticResult memory outcome = _staticSubResults[_staticSubCursor++];
        CallParams memory params = CallShapes.toParams(shape, source);
        bytes32 callHash = _destCallHash(params);
        nodeId = _out.newCall(txId, parent, params);
        _out.setResult(nodeId, outcome.success, outcome.returnData);
        bool hasLookup = _ctx[source].active || source == _origin;
        if (hasLookup) {
            StaticFrame memory frame;
            bool success;
            bytes memory ret;
            if (_ctx[source].active) {
                frame.index = _ctx[source].rowCursor++;
                bytes32 key = keccak256(abi.encodePacked(callHash, _ctx[source].liveHash));
                if (_rowKey(source, frame.index) != key) {
                    revert RoundTripMismatch("static row key", source, frame.index, key, _rowKey(source, frame.index));
                }
                (success, ret, frame.expectedHash) = _rowResult(source, frame.index);
                Ctx storage ctx = _ctx[source];
                frame.count = source == L1_CHAIN
                    ? _l1Entries[ctx.hostEntry].expectedL1ToL2Calls[frame.index].l2ToL1Calls.length
                    : _unitEntries[ctx.hostUnit][ctx.hostEntry].expectedOutgoingCalls[frame.index].incomingCalls.length;
            } else {
                frame.pool = true;
                if (source == L1_CHAIN) {
                    frame.index = _l1StaticCursor++;
                    StaticExecutionEntry storage row = _l1Statics[frame.index];
                    if (row.proxyEntryHash != callHash || row.destinationRollupId != params.toChain) {
                        revert RoundTripMismatch("static pool key", source, frame.index, callHash, row.proxyEntryHash);
                    }
                    (success, ret, frame.expectedHash, frame.count) =
                    (row.success, row.returnData, row.rollingHash, row.l2ToL1Calls.length);
                } else {
                    frame.unit = _staticOriginUnit;
                    frame.index = _unitStaticCursor[frame.unit]++;
                    L2StaticExecutionEntry storage row = _unitStatics[frame.unit][frame.index];
                    if (row.proxyEntryHash != callHash) {
                        revert RoundTripMismatch("static pool key", source, frame.index, callHash, row.proxyEntryHash);
                    }
                    uint256 expectedCursor = _unitLiveCursor[frame.unit];
                    if (row.expectedEntryIndex != expectedCursor) {
                        revert RoundTripMismatch(
                            "L2 static entry cursor",
                            source,
                            frame.index,
                            bytes32(expectedCursor),
                            bytes32(row.expectedEntryIndex)
                        );
                    }
                    (success, ret, frame.expectedHash, frame.count) =
                    (row.success, row.returnData, row.rollingHash, row.incomingCalls.length);
                }
            }
            if (success != outcome.success || keccak256(ret) != keccak256(outcome.returnData)) {
                revert RoundTripMismatch(
                    "static result", source, frame.index, keccak256(ret), keccak256(outcome.returnData)
                );
            }
            _staticFrames[source].push(frame);
        }
        uint64 dest = params.toChain;
        bool callback = _staticFrames[dest].length > 0;
        bool executing = _ctx[dest].active;
        if (callback) {
            _consumeStaticCallback(dest, params, outcome);
        } else if (executing) {
            _consumeArrayItem(dest, callHash);
            _foldCallBegin(dest, callHash);
        }
        for (uint256 i; i < shape.childCount; i++) {
            _stitchStatic(txId, nodeId, dest);
        }
        if (!callback && executing) _foldCallEnd(dest, outcome.success, outcome.returnData);
        if (hasLookup) {
            StaticFrame memory frame = _staticFrames[source][_staticFrames[source].length - 1];
            _staticFrames[source].pop();
            if (frame.cursor != frame.count || frame.hash != frame.expectedHash) {
                revert RoundTripMismatch(
                    "static callback accumulator", source, frame.index, frame.expectedHash, frame.hash
                );
            }
        }
    }

    function _consumeStaticCallback(
        uint64 chain,
        CallParams memory wanted,
        SidecarStaticResult memory outcome
    )
        internal
    {
        bytes32 callHash = _destCallHash(wanted);
        StaticFrame storage frame = _staticFrames[chain][_staticFrames[chain].length - 1];
        Ctx storage ctx = _ctx[chain];
        if (frame.cursor >= frame.count) {
            revert RoundTripMismatch("missing static callback", chain, frame.cursor, callHash, 0);
        }
        CallParams memory params;
        if (chain == L1_CHAIN) {
            L2ToL1Call memory c = frame.pool
                ? _l1Statics[frame.index].l2ToL1Calls[frame.cursor]
                : _l1Entries[ctx.hostEntry].expectedL1ToL2Calls[frame.index].l2ToL1Calls[frame.cursor];
            if (c.revertNextNCalls != 0) {
                revert RoundTripMismatch(
                    "static callback revert span", chain, frame.cursor, 0, bytes32(uint256(c.revertNextNCalls))
                );
            }
            params = CallShapes.toParams(c, chain);
        } else {
            CrossChainCall memory c = frame.pool
                ? _unitStatics[frame.unit][frame.index].incomingCalls[frame.cursor]
                : _unitEntries[ctx.hostUnit][ctx.hostEntry].expectedOutgoingCalls[frame.index].incomingCalls[
                    frame.cursor
                ];
            if (c.revertNextNCalls != 0) {
                revert RoundTripMismatch(
                    "static callback revert span", chain, frame.cursor, 0, bytes32(uint256(c.revertNextNCalls))
                );
            }
            params = CallShapes.toParams(c, chain);
        }
        if (!params.isStatic || params.value != 0 || keccak256(abi.encode(params)) != keccak256(abi.encode(wanted))) {
            revert RoundTripMismatch("static callback identity", chain, frame.cursor, callHash, _destCallHash(params));
        }
        frame.cursor++;
        frame.hash = _hStatic(frame.hash, outcome.success, outcome.returnData);
    }

    // ──────────────────────────────────────────────
    //  Destination side + children
    // ──────────────────────────────────────────────

    /// @notice Consumes the destination-side record of a mutable call and recurses
    ///         into the calls its execution fired (mirrors TableGenerator._execCall).
    function _stitchDestination(
        uint256 txId,
        uint256 nodeId,
        CallParams memory params,
        bool success,
        bytes memory returnData
    )
        internal
    {
        uint64 dest = params.toChain;
        bytes32 callHash = _destCallHash(params);

        if (dest == L1_CHAIN || _ctx[dest].active) {
            _consumeArrayItem(dest, callHash);
            _foldCallBegin(dest, callHash);
            bytes32 beforeChildren = _ctx[dest].liveHash;
            _stitchChildren(txId, nodeId, dest);
            if (!success) _ctx[dest].liveHash = beforeChildren;
            _foldCallEnd(dest, success, returnData);
        } else {
            uint256 unitIdx = _nextUnit(dest, UNIT_KIND_INBOUND);
            L2ExecutionEntry storage entry = _unitEntries[unitIdx][0];
            if (entry.proxyEntryHash != callHash) {
                revert RoundTripMismatch("inbound proxyEntryHash", dest, unitIdx, callHash, entry.proxyEntryHash);
            }
            // incomingCalls[0] is the inbound call itself — start the top cursor past it.
            _openL2Ctx(dest, unitIdx, 0, _hEntryBeginL2(callHash), 1);
            _foldCallBegin(dest, callHash);
            bytes32 beforeChildren = _ctx[dest].liveHash;
            _stitchChildren(txId, nodeId, dest);
            if (!success) _ctx[dest].liveHash = beforeChildren;
            if (success != entry.success || keccak256(returnData) != keccak256(entry.returnData)) {
                revert RoundTripMismatch(
                    "inbound result", dest, unitIdx, keccak256(returnData), keccak256(entry.returnData)
                );
            }
            _foldCallEnd(dest, entry.success, entry.returnData);
            if (_ctx[dest].liveHash != entry.rollingHash) {
                revert RoundTripMismatch("inbound rollingHash", dest, unitIdx, entry.rollingHash, _ctx[dest].liveHash);
            }
            _ctx[dest].active = false;
        }
    }

    /// @notice Rebuilds the calls fired FROM `chain` while `parent` executes there: reads
    ///         the host's reentrant rows in cursor order; the row whose key matches
    ///         `keccak(candidateHash ‖ liveHash)` is the next child — no match means
    ///         this nesting level is complete.
    function _stitchChildren(uint256 txId, uint256 parentNode, uint64 chain) internal {
        while (true) {
            Ctx storage ctx = _ctx[chain];
            if (ctx.rowCursor >= _rowCount(chain)) break;

            (bool found, bool isStatic, CallParams memory params) = _matchNextRow(chain);
            if (!found) break;
            _beginRegions(_out.nodeCount(), chain, false);
            uint256 nodeId;
            if (isStatic) {
                nodeId = _stitchStatic(txId, parentNode, chain);
            } else {
                ctx.rowCursor++;
                (bool rSuccess, bytes memory rRet, bytes32 rSubHash) = _rowResult(chain, ctx.rowCursor - 1);
                nodeId = _out.newCall(txId, parentNode, params);
                _out.setResult(nodeId, rSuccess, rRet);
                bytes32 callHash = _sourceCallHash(params);
                _consumeCallGas(params);
                bytes32 fireHash = ctx.liveHash;
                ctx.liveHash = _hNestedBegin(ctx.liveHash, callHash);
                ctx.frameRows.push(ctx.rowCursor - 1);
                ctx.frameCursors.push(0);

                _stitchDestination(txId, nodeId, params, rSuccess, rRet);

                ctx.frameRows.pop();
                ctx.frameCursors.pop();
                if (rSuccess) {
                    ctx.liveHash = _hNestedEnd(ctx.liveHash);
                } else {
                    if (ctx.liveHash != rSubHash) {
                        revert RoundTripMismatch(
                            "reverted frame sub-hash", chain, ctx.rowCursor - 1, rSubHash, ctx.liveHash
                        );
                    }
                    ctx.liveHash = fireHash;
                }
            }
            _endRegions(nodeId);
        }
    }

    /// @notice Tries to identify the next row of `chain`'s host: a sidecar static or, for
    ///         mutable calls, the next pending destination record on any other chain.
    function _matchNextRow(uint64 chain) internal view returns (bool, bool, CallParams memory params) {
        bytes32 key = _rowKey(chain, _ctx[chain].rowCursor);
        bytes32 live = _ctx[chain].liveHash;

        // Static candidate (next unclaimed sidecar static, fired from chain).
        if (_staticCursor < _statics.length) {
            CallParams memory staticParams = CallShapes.toParams(_statics[_staticCursor], chain);
            if (keccak256(abi.encodePacked(_destCallHash(staticParams), live)) == key) {
                return (true, true, staticParams);
            }
        }

        // Mutable candidates: L1's host arrays, other hosted chains' arrays, or the
        // next pending inbound unit per chain.
        if (chain != L1_CHAIN && _ctx[L1_CHAIN].active) {
            (bool ok, CallParams memory candidate) = _peekArrayItem(L1_CHAIN);
            if (ok && keccak256(abi.encodePacked(_sourceCallHash(candidate), live)) == key) {
                return (true, false, candidate);
            }
        }
        for (uint256 i = 0; i < _chains.length; i++) {
            uint64 other = _chains[i];
            if (other == chain) continue;
            if (_ctx[other].active) {
                (bool ok, CallParams memory candidate) = _peekArrayItem(other);
                if (ok && keccak256(abi.encodePacked(_sourceCallHash(candidate), live)) == key) {
                    return (true, false, candidate);
                }
            } else {
                (bool ok, CallParams memory candidate) = _peekUnitInbound(other);
                if (ok && keccak256(abi.encodePacked(_sourceCallHash(candidate), live)) == key) {
                    return (true, false, candidate);
                }
            }
        }
        return (false, false, params);
    }

    /// @notice The hash the SOURCE chain keys `params` with: folds the next queued callGas for this
    ///         shape (peeked) when the call leaves an L2, 0 when it leaves L1.
    function _sourceCallHash(CallParams memory params) internal view returns (bytes32) {
        if (params.fromChain == L1_CHAIN) return _destCallHash(params);
        bytes32 destCallHash = _destCallHash(params);
        uint64[] storage queue = _callGasQueue[destCallHash];
        uint256 cur = _callGasCursor[destCallHash];
        uint64 callGas = cur < queue.length ? queue[cur] : 0; // exhausted ⇒ hash can't match ⇒ candidate rejected
        return _ccHashGas(
            params.isStatic,
            params.fromAddress,
            params.fromChain,
            params.toAddress,
            params.toChain,
            params.value,
            callGas,
            params.data
        );
    }

    /// @dev Claims the peeked callGas once a candidate is confirmed as the next node.
    function _consumeCallGas(CallParams memory params) internal {
        if (params.fromChain != L1_CHAIN && !params.isStatic) _callGasCursor[_destCallHash(params)]++;
    }

    /// @notice Resolves a root call's fields by its source-side crossChainCallHash (origin
    ///         entries key by callHash directly, not by position).
    function _resolveByCallHash(uint64 origin, bytes32 callHash) internal view returns (CallParams memory) {
        if (origin != L1_CHAIN && _ctx[L1_CHAIN].active) {
            (bool ok, CallParams memory candidate) = _peekArrayItem(L1_CHAIN);
            if (ok && _sourceCallHash(candidate) == callHash) return candidate;
        }
        for (uint256 i = 0; i < _chains.length; i++) {
            uint64 other = _chains[i];
            if (other == origin) continue;
            (bool ok, CallParams memory candidate) = _peekUnitInbound(other);
            if (ok && _sourceCallHash(candidate) == callHash) return candidate;
        }
        revert RoundTripMismatch("root call destination not found", origin, 0, callHash, 0);
    }

    // ──────────────────────────────────────────────
    //  Region reconstruction
    // ──────────────────────────────────────────────

    // Exact source-region boundaries are sidecar metadata; destination rollback
    // markers are independently checked after reconstructing fields and outcomes.
    function _beginRegions(uint256 nodeId, uint64 host, bool rootLevel) internal {
        for (uint256 i; i < _regions.length; i++) {
            if (_regions[i].firstNode == nodeId) {
                _regionStack.push(
                    RegionState(
                        host,
                        _regions[i].lastNode,
                        _ctx[host].active,
                        _ctx[host].liveHash,
                        rootLevel,
                        _unitLiveCursor[_originUnitForTx]
                    )
                );
            }
        }
    }

    function _endRegions(uint256 nodeId) internal {
        while (_regionStack.length > 0 && _regionStack[_regionStack.length - 1].endNode == nodeId) {
            RegionState memory region = _regionStack[_regionStack.length - 1];
            if (region.branched) _ctx[region.host].liveHash = region.savedHash;
            if (region.rootLevel && region.host != L1_CHAIN) _unitLiveCursor[_originUnitForTx] = region.savedCursor;
            _regionStack.pop();
        }
    }

    /// @dev Fields/results were recovered and their hashes checked independently above.
    /// Re-derive only the rollback layout to validate metadata against every table marker.
    function _checkRollbackMarkers() internal {
        TableGenerator generator = new TableGenerator();
        generator.generate(_out, new uint64[](_out.nodeCount()));
        ExecutionEntry[] memory l1 = generator.l1Entries();
        if (l1.length != _l1Entries.length || generator.unitCount() != _unitChain.length) {
            revert RoundTripMismatch("rollback table count", NO_CHAIN, 0, 0, 0);
        }
        for (uint256 i; i < l1.length; i++) {
            _checkL1Markers(l1[i].l2ToL1Calls, _l1Entries[i].l2ToL1Calls);
            if (l1[i].expectedL1ToL2Calls.length != _l1Entries[i].expectedL1ToL2Calls.length) {
                revert RoundTripMismatch("rollback row count", L1_CHAIN, i, 0, 0);
            }
            for (uint256 j; j < l1[i].expectedL1ToL2Calls.length; j++) {
                _checkL1Markers(
                    l1[i].expectedL1ToL2Calls[j].l2ToL1Calls, _l1Entries[i].expectedL1ToL2Calls[j].l2ToL1Calls
                );
            }
        }
        for (uint256 u; u < _unitChain.length; u++) {
            L2ExecutionEntry[] memory entries = generator.unitEntries(u);
            if (entries.length != _unitEntries[u].length) {
                revert RoundTripMismatch("rollback entry count", _unitChain[u], u, 0, 0);
            }
            for (uint256 i; i < entries.length; i++) {
                _checkL2Markers(entries[i].incomingCalls, _unitEntries[u][i].incomingCalls);
                if (entries[i].expectedOutgoingCalls.length != _unitEntries[u][i].expectedOutgoingCalls.length) {
                    revert RoundTripMismatch("rollback row count", _unitChain[u], i, 0, 0);
                }
                for (uint256 j; j < entries[i].expectedOutgoingCalls.length; j++) {
                    _checkL2Markers(
                        entries[i].expectedOutgoingCalls[j].incomingCalls,
                        _unitEntries[u][i].expectedOutgoingCalls[j].incomingCalls
                    );
                }
            }
        }
    }

    function _checkL1Markers(L2ToL1Call[] memory expected, L2ToL1Call[] storage actual) internal view {
        if (expected.length != actual.length) revert RoundTripMismatch("rollback call count", L1_CHAIN, 0, 0, 0);
        for (uint256 i; i < expected.length; i++) {
            if (expected[i].revertNextNCalls != actual[i].revertNextNCalls) {
                revert RoundTripMismatch(
                    "rollback marker",
                    L1_CHAIN,
                    i,
                    bytes32(uint256(expected[i].revertNextNCalls)),
                    bytes32(uint256(actual[i].revertNextNCalls))
                );
            }
        }
    }

    function _checkL2Markers(CrossChainCall[] memory expected, CrossChainCall[] storage actual) internal view {
        if (expected.length != actual.length) revert RoundTripMismatch("rollback call count", NO_CHAIN, 0, 0, 0);
        for (uint256 i; i < expected.length; i++) {
            if (expected[i].revertNextNCalls != actual[i].revertNextNCalls) {
                revert RoundTripMismatch(
                    "rollback marker",
                    NO_CHAIN,
                    i,
                    bytes32(uint256(expected[i].revertNextNCalls)),
                    bytes32(uint256(actual[i].revertNextNCalls))
                );
            }
        }
    }

    // ──────────────────────────────────────────────
    //  Ctx plumbing
    // ──────────────────────────────────────────────

    function _openL1Ctx(uint256 entryIdx) internal {
        Ctx storage ctx = _ctx[L1_CHAIN];
        ctx.active = true;
        ctx.hostIsL1 = true;
        ctx.hostEntry = entryIdx;
        ctx.liveHash = _hEntryBegin(_l1Entries[entryIdx].rollupUpdates, _l1Entries[entryIdx].proxyEntryHash);
        ctx.rowCursor = 0;
        ctx.topCursor = 0;
        _clearFrames(ctx);
    }

    function _openL2Ctx(uint64 chain, uint256 unitIdx, uint256 entryPos, bytes32 seed, uint256 topCursor) internal {
        Ctx storage ctx = _ctx[chain];
        ctx.active = true;
        ctx.hostIsL1 = false;
        ctx.hostUnit = unitIdx;
        ctx.hostEntry = entryPos;
        ctx.liveHash = seed;
        ctx.rowCursor = 0;
        ctx.topCursor = topCursor;
        _clearFrames(ctx);
    }

    function _clearFrames(Ctx storage ctx) internal {
        while (ctx.frameRows.length > 0) {
            ctx.frameRows.pop();
        }
        while (ctx.frameCursors.length > 0) {
            ctx.frameCursors.pop();
        }
    }

    /// @notice Next unconsumed unit of `chain` with the expected kind.
    function _nextUnit(uint64 chain, uint8 kind) internal returns (uint256 idx) {
        uint256 i = _unitScan[chain];
        while (i < _unitChain.length && _unitChain[i] != chain) {
            i++;
        }
        if (i >= _unitChain.length) revert RoundTripMismatch("missing unit", chain, i, bytes32(uint256(kind)), 0);
        if (_unitKind[i] != kind) {
            revert RoundTripMismatch("unit kind", chain, i, bytes32(uint256(kind)), bytes32(uint256(_unitKind[i])));
        }
        _unitScan[chain] = i + 1;
        return i;
    }

    // ── host-array access (top array or open frame's sub-array) ──

    function _rowCount(uint64 chain) internal view returns (uint256) {
        Ctx storage ctx = _ctx[chain];
        return ctx.hostIsL1
            ? _l1Entries[ctx.hostEntry].expectedL1ToL2Calls.length
            : _unitEntries[ctx.hostUnit][ctx.hostEntry].expectedOutgoingCalls.length;
    }

    function _rowKey(uint64 chain, uint256 rowIdx) internal view returns (bytes32) {
        Ctx storage ctx = _ctx[chain];
        return ctx.hostIsL1
            ? _l1Entries[ctx.hostEntry].expectedL1ToL2Calls[rowIdx].expectedL1toL2Hash
            : _unitEntries[ctx.hostUnit][ctx.hostEntry].expectedOutgoingCalls[rowIdx].expectedOutgoingHash;
    }

    function _rowResult(uint64 chain, uint256 rowIdx) internal view returns (bool, bytes memory, bytes32) {
        Ctx storage ctx = _ctx[chain];
        if (ctx.hostIsL1) {
            ExpectedL1ToL2Call storage row = _l1Entries[ctx.hostEntry].expectedL1ToL2Calls[rowIdx];
            return (row.success, row.returnData, row.revertedOrStaticRollingHash);
        }
        ExpectedOutgoingCrossChainCall storage l2Row =
            _unitEntries[ctx.hostUnit][ctx.hostEntry].expectedOutgoingCalls[rowIdx];
        return (l2Row.success, l2Row.returnData, l2Row.revertedOrStaticRollingHash);
    }

    /// @notice Peeks the next unconsumed item of `chain`'s current insertion array.
    function _peekArrayItem(uint64 chain) internal view returns (bool ok, CallParams memory params) {
        Ctx storage ctx = _ctx[chain];
        if (ctx.hostIsL1) {
            ExecutionEntry storage entry = _l1Entries[ctx.hostEntry];
            L2ToL1Call[] storage arr = ctx.frameRows.length == 0
                ? entry.l2ToL1Calls
                : entry.expectedL1ToL2Calls[ctx.frameRows[ctx.frameRows.length - 1]].l2ToL1Calls;
            uint256 cur = ctx.frameRows.length == 0 ? ctx.topCursor : ctx.frameCursors[ctx.frameCursors.length - 1];
            if (cur >= arr.length) return (false, params);
            return (true, CallShapes.toParams(arr[cur], L1_CHAIN));
        }
        L2ExecutionEntry storage l2Entry = _unitEntries[ctx.hostUnit][ctx.hostEntry];
        CrossChainCall[] storage arr2 = ctx.frameRows.length == 0
            ? l2Entry.incomingCalls
            : l2Entry.expectedOutgoingCalls[ctx.frameRows[ctx.frameRows.length - 1]].incomingCalls;
        uint256 cur2 = ctx.frameRows.length == 0 ? ctx.topCursor : ctx.frameCursors[ctx.frameCursors.length - 1];
        if (cur2 >= arr2.length) return (false, params);
        return (true, CallShapes.toParams(arr2[cur2], chain));
    }

    /// @notice Consumes the next item of `chain`'s insertion array (must hash to `callHash`);
    ///         rollback markers are checked against the reconstructed tree afterward.
    function _consumeArrayItem(uint64 chain, bytes32 callHash) internal {
        (bool ok, CallParams memory params) = _peekArrayItem(chain);
        Ctx storage ctx = _ctx[chain];
        if (!ok || _destCallHash(params) != callHash) {
            uint256 cur = ctx.frameRows.length == 0 ? ctx.topCursor : ctx.frameCursors[ctx.frameCursors.length - 1];
            revert RoundTripMismatch(
                "array item mismatch", chain, cur, callHash, ok ? _destCallHash(params) : bytes32(0)
            );
        }
        if (ctx.frameRows.length == 0) {
            ctx.topCursor++;
        } else {
            ctx.frameCursors[ctx.frameCursors.length - 1]++;
        }
    }

    /// @notice Peeks the next pending inbound unit of `chain`.
    function _peekUnitInbound(uint64 chain) internal view returns (bool ok, CallParams memory params) {
        uint256 i = _unitScan[chain];
        while (i < _unitChain.length && _unitChain[i] != chain) {
            i++;
        }
        if (i >= _unitChain.length || _unitKind[i] != UNIT_KIND_INBOUND) return (false, params);
        return (true, CallShapes.toParams(_unitEntries[i][0].incomingCalls[0], chain));
    }

    function _foldCallBegin(uint64 chain, bytes32 callHash) internal {
        _ctx[chain].liveHash = _hCallBegin(_ctx[chain].liveHash, callHash);
    }

    function _foldCallEnd(uint64 chain, bool success, bytes memory ret) internal {
        _ctx[chain].liveHash = _hCallEnd(_ctx[chain].liveHash, success, ret);
    }

    function _destCallHash(CallParams memory params) internal pure returns (bytes32) {
        return _ccHash(
            params.isStatic,
            params.fromAddress,
            params.fromChain,
            params.toAddress,
            params.toChain,
            params.value,
            params.data
        );
    }
}
