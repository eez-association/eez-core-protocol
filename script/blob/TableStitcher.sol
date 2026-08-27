// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ExecutionEntry, L2ToL1Call, ExpectedL1ToL2Call, StaticExecutionEntry} from "../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    StaticExecutionEntry as L2StaticExecutionEntry
} from "../../src/interfaces/IEEZL2.sol";
import {TestHashes} from "../../test/TestHashes.sol";
import {ScenarioStore, CallParams} from "./ScenarioStore.sol";
import {SidecarTx, SidecarStatic, SidecarStaticResult, SidecarChainOp} from "./BlobSidecar.sol";
import {CallShapes} from "./CallShapes.sol";
import {UNIT_KIND_ORIGIN_GROUP, UNIT_KIND_INBOUND, ROOT_KIND_STATIC, NO_NODE, NO_CHAIN} from "./BlobConstants.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  TableStitcher — the Table → Blob direction.
//
//  Rebuilds the cross-chain call forest (a ScenarioStore, which then emits the
//  message stream) from the per-chain execution tables alone, plus a SIDECAR of
//  the data that provably never reaches any table:
//    - per-tx metadata (origin chain, tx_data, root slot kinds),
//    - ChainOperation payloads and the CloseBlobStream position,
//    - static call fields (both chains match static reads by hash only),
//    - region sizes (span markers can't distinguish adjacent regions).
//
//  Everything else is recovered from the tables and cross-checked by
//  re-simulating each chain's rolling hash:
//    - every non-root call's full fields come from its DESTINATION side (an
//      inbound entry's `incomingCalls[0]` or a host array item),
//    - every call's result comes from its CALLER side (origin entry /
//      reentrant-row `success` + `returnData`),
//    - nesting and order come from the content-addressed row keys: the next
//      row matches `keccak256(candidateCallHash ‖ liveHash)` only at the exact
//      execution point it was fired from,
//    - each rebuilt entry's simulated rolling hash must equal the stored
//      `rollingHash` (`RoundTripMismatch` otherwise).
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
    uint256 internal _staticSubCursor; // sidecar sub-read results
    uint256 internal _regionCursor; // sidecar region sizes

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

    // region reconstruction
    bool internal _regionOpen;
    uint256 internal _pendingRegionNode = NO_NODE;
    bool internal _regionJustOpened;
    // intra-entry regions branch the hosting chain's rolling hash in the generator
    // (the host's own EVM revert undoes the folds) — mirror the restore here
    bool internal _regionBranchActive;
    uint64 internal _regionSimChain;
    bytes32 internal _regionSavedSimHash;

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
    }

    function _stitchTx(uint256 t) internal {
        SidecarTx storage meta = _txMeta[t];
        uint64 origin = meta.originChain;
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
        uint256 regionRemaining = 0;
        for (uint256 k = 0; k < meta.rootKinds.length; k++) {
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
                }
            }
            // Root-level region bookkeeping (opened when the root's destination record
            // carried the first span marker). No hash branch at root level: each root
            // consumption seeds its own hash, so there is nothing to restore.
            regionRemaining = _siblingRegionStep(nodeId, regionRemaining);
            _regionJustOpened = false;
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

    /// @notice Root static read: fields from the sidecar, result from the caller-side
    ///         pool entry (L1 batch statics / the origin unit's statics). The pool
    ///         entry's sub-call array holds the read's own sub-reads (full fields —
    ///         only their results come from the sidecar), cross-checked against the
    ///         untagged accumulator. A read targeting an executing chain (the L2Tx
    ///         host when it targets L1) is also consumed from that chain's arrays
    ///         with its real folds, its sub-reads matched as STATIC rows.
    function _stitchRootStatic(uint256 txId, uint64 origin, uint256 originUnit) internal returns (uint256 nodeId) {
        CallParams memory params = CallShapes.toParams(_statics[_staticCursor++], origin);
        bytes32 callHash = _destCallHash(params);
        bool success;
        bytes memory ret;
        bytes32[] memory subCallHashes;
        if (origin == L1_CHAIN) {
            StaticExecutionEntry storage staticEntry = _l1Statics[_l1StaticCursor++];
            if (staticEntry.proxyEntryHash != callHash) {
                revert RoundTripMismatch(
                    "L1 static pool hash", L1_CHAIN, _l1StaticCursor - 1, callHash, staticEntry.proxyEntryHash
                );
            }
            (success, ret) = (staticEntry.success, staticEntry.returnData);
            nodeId = _out.newCall(txId, NO_NODE, params);
            _out.setResult(nodeId, success, ret);
            subCallHashes = _stitchStaticSubsL1(txId, nodeId, params, staticEntry);
        } else {
            L2StaticExecutionEntry storage l2StaticEntry = _unitStatics[originUnit][_unitStaticCursor[originUnit]++];
            if (l2StaticEntry.proxyEntryHash != callHash) {
                revert RoundTripMismatch(
                    "L2 static pool hash",
                    origin,
                    _unitStaticCursor[originUnit] - 1,
                    callHash,
                    l2StaticEntry.proxyEntryHash
                );
            }
            (success, ret) = (l2StaticEntry.success, l2StaticEntry.returnData);
            nodeId = _out.newCall(txId, NO_NODE, params);
            _out.setResult(nodeId, success, ret);
            subCallHashes = _stitchStaticSubsL2(txId, nodeId, params, l2StaticEntry);
        }

        if (params.toChain == L1_CHAIN || _ctx[params.toChain].active) {
            // Live leg on the executing destination: the isStatic array item + real
            // folds, with one STATIC row per sub-read at this exact point.
            uint16 marker = _consumeArrayItem(params.toChain, callHash);
            _noteMarker(nodeId, marker);
            _foldCallBegin(params.toChain, callHash);
            Ctx storage ctx = _ctx[params.toChain];
            for (uint256 i = 0; i < subCallHashes.length; i++) {
                if (
                    _rowKey(params.toChain, ctx.rowCursor)
                        != keccak256(abi.encodePacked(subCallHashes[i], ctx.liveHash))
                ) {
                    revert RoundTripMismatch(
                        "static sub-read row key",
                        params.toChain,
                        ctx.rowCursor,
                        keccak256(abi.encodePacked(subCallHashes[i], ctx.liveHash)),
                        _rowKey(params.toChain, ctx.rowCursor)
                    );
                }
                ctx.rowCursor++;
            }
            _foldCallEnd(params.toChain, success, ret);
        }
    }

    /// @dev Rebuilds an L1 pool entry's sub-reads: fields from the sub-call array,
    ///      results from the sidecar, the untagged accumulator cross-checked.
    function _stitchStaticSubsL1(
        uint256 txId,
        uint256 parentNode,
        CallParams memory params,
        StaticExecutionEntry storage staticEntry
    )
        internal
        returns (bytes32[] memory subCallHashes)
    {
        subCallHashes = new bytes32[](staticEntry.l2ToL1Calls.length);
        bytes32 acc = bytes32(0);
        for (uint256 i = 0; i < staticEntry.l2ToL1Calls.length; i++) {
            // sub-reads run on the resolving (reader) chain
            acc = _stitchOneStaticSub(
                txId,
                parentNode,
                params,
                CallShapes.toParams(staticEntry.l2ToL1Calls[i], params.fromChain),
                acc,
                subCallHashes,
                i
            );
        }
        if (acc != staticEntry.rollingHash) {
            revert RoundTripMismatch(
                "static sub-read accumulator", L1_CHAIN, _l1StaticCursor - 1, staticEntry.rollingHash, acc
            );
        }
    }

    /// @dev L2-pool twin of `_stitchStaticSubsL1`.
    function _stitchStaticSubsL2(
        uint256 txId,
        uint256 parentNode,
        CallParams memory params,
        L2StaticExecutionEntry storage l2StaticEntry
    )
        internal
        returns (bytes32[] memory subCallHashes)
    {
        subCallHashes = new bytes32[](l2StaticEntry.incomingCalls.length);
        bytes32 acc = bytes32(0);
        for (uint256 i = 0; i < l2StaticEntry.incomingCalls.length; i++) {
            acc = _stitchOneStaticSub(
                txId,
                parentNode,
                params,
                CallShapes.toParams(l2StaticEntry.incomingCalls[i], params.fromChain),
                acc,
                subCallHashes,
                i
            );
        }
        if (acc != l2StaticEntry.rollingHash) {
            revert RoundTripMismatch(
                "static sub-read accumulator", params.fromChain, _staticCursor - 1, l2StaticEntry.rollingHash, acc
            );
        }
    }

    /// @dev One sub-read: shape-checked (static, fired from the parent's destination),
    ///      appended to the rebuilt tree with its sidecar result, folded into `acc`.
    function _stitchOneStaticSub(
        uint256 txId,
        uint256 parentNode,
        CallParams memory params,
        CallParams memory sub,
        bytes32 acc,
        bytes32[] memory subCallHashes,
        uint256 i
    )
        internal
        returns (bytes32)
    {
        if (!sub.isStatic || sub.fromChain != params.toChain) {
            revert RoundTripMismatch("static sub-read shape", sub.fromChain, _staticSubCursor, 0, 0);
        }
        SidecarStaticResult storage result = _staticSubResults[_staticSubCursor++];
        uint256 subNode = _out.newCall(txId, parentNode, sub);
        _out.setResult(subNode, result.success, result.returnData);
        subCallHashes[i] = _destCallHash(sub);
        return _hStatic(acc, result.success, result.returnData);
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
            uint16 marker = _consumeArrayItem(dest, callHash);
            _noteMarker(nodeId, marker);
            _foldCallBegin(dest, callHash);
            _stitchChildren(txId, nodeId, dest);
            _foldCallEnd(dest, success, returnData);
        } else {
            uint256 unitIdx = _nextUnit(dest, UNIT_KIND_INBOUND);
            L2ExecutionEntry storage entry = _unitEntries[unitIdx][0];
            if (entry.proxyEntryHash != callHash) {
                revert RoundTripMismatch("inbound proxyEntryHash", dest, unitIdx, callHash, entry.proxyEntryHash);
            }
            _noteMarker(nodeId, entry.incomingCalls[0].revertNextNCalls);
            // incomingCalls[0] is the inbound call itself — start the top cursor past it.
            _openL2Ctx(dest, unitIdx, 0, _hEntryBeginL2(callHash), 1);
            _foldCallBegin(dest, callHash);
            _stitchChildren(txId, nodeId, dest);
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
        uint256 regionRemaining = 0;
        while (true) {
            Ctx storage ctx = _ctx[chain];
            if (ctx.rowCursor >= _rowCount(chain)) break;

            bytes32 preChildHash = ctx.liveHash;
            (bool found, bool isStatic, CallParams memory params) = _matchNextRow(chain);
            if (!found) break;
            ctx.rowCursor++;
            if (isStatic) _staticCursor++; // the matched candidate is claimed

            (bool rSuccess, bytes memory rRet, bytes32 rSubHash) = _rowResult(chain, ctx.rowCursor - 1);
            uint256 nodeId = _out.newCall(txId, parentNode, params);
            _out.setResult(nodeId, rSuccess, rRet);

            if (isStatic) {
                // STATIC row: host hash untouched; if the destination is executing,
                // its arrays carry the read at this exact point.
                if (params.toChain == L1_CHAIN || _ctx[params.toChain].active) {
                    bytes32 callHash = _destCallHash(params);
                    _consumeArrayItem(params.toChain, callHash);
                    _foldCallBegin(params.toChain, callHash);
                    _foldCallEnd(params.toChain, rSuccess, rRet);
                }
            } else {
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
            regionRemaining = _siblingRegionStep(nodeId, regionRemaining);
            if (_regionJustOpened) {
                // Intra-entry region: `chain` is the hosting chain — its folds inside the
                // region are undone by the host actor's own revert.
                _regionJustOpened = false;
                _regionBranchActive = true;
                _regionSimChain = chain;
                _regionSavedSimHash = preChildHash;
            }
            if (!_regionOpen && _regionBranchActive && _regionSimChain == chain) {
                ctx.liveHash = _regionSavedSimHash;
                _regionBranchActive = false;
            }
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

    /// @notice First span marker seen while no region is open ⇒ that node starts a
    ///         region; its size comes from the sidecar (markers alone are ambiguous).
    function _noteMarker(uint256 nodeId, uint16 marker) internal {
        if (marker > 0 && !_regionOpen) {
            _regionOpen = true;
            _pendingRegionNode = nodeId;
        }
    }

    /// @notice Sibling-loop step: opens the region bracket on the node that triggered
    ///         it and closes the bracket after `size` siblings.
    function _siblingRegionStep(uint256 nodeId, uint256 regionRemaining) internal returns (uint256) {
        if (_pendingRegionNode == nodeId) {
            _pendingRegionNode = NO_NODE;
            _regionJustOpened = true;
            uint16 size = _regionSizes[_regionCursor++];
            _out.setRevertSpan(nodeId, size);
            if (size <= 1) {
                _regionOpen = false;
                return 0;
            }
            return size - 1;
        }
        if (regionRemaining > 0) {
            regionRemaining--;
            if (regionRemaining == 0) _regionOpen = false;
        }
        return regionRemaining;
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
    ///         returns its span marker for region reconstruction.
    function _consumeArrayItem(uint64 chain, bytes32 callHash) internal returns (uint16 marker) {
        (bool ok, CallParams memory params) = _peekArrayItem(chain);
        Ctx storage ctx = _ctx[chain];
        if (!ok || _destCallHash(params) != callHash) {
            uint256 cur = ctx.frameRows.length == 0 ? ctx.topCursor : ctx.frameCursors[ctx.frameCursors.length - 1];
            revert RoundTripMismatch(
                "array item mismatch", chain, cur, callHash, ok ? _destCallHash(params) : bytes32(0)
            );
        }
        marker = _peekMarker(chain);
        if (ctx.frameRows.length == 0) {
            ctx.topCursor++;
        } else {
            ctx.frameCursors[ctx.frameCursors.length - 1]++;
        }
    }

    function _peekMarker(uint64 chain) internal view returns (uint16) {
        Ctx storage ctx = _ctx[chain];
        if (ctx.hostIsL1) {
            ExecutionEntry storage entry = _l1Entries[ctx.hostEntry];
            L2ToL1Call[] storage arr = ctx.frameRows.length == 0
                ? entry.l2ToL1Calls
                : entry.expectedL1ToL2Calls[ctx.frameRows[ctx.frameRows.length - 1]].l2ToL1Calls;
            uint256 cur = ctx.frameRows.length == 0 ? ctx.topCursor : ctx.frameCursors[ctx.frameCursors.length - 1];
            return arr[cur].revertNextNCalls;
        }
        L2ExecutionEntry storage l2Entry = _unitEntries[ctx.hostUnit][ctx.hostEntry];
        CrossChainCall[] storage arr2 = ctx.frameRows.length == 0
            ? l2Entry.incomingCalls
            : l2Entry.expectedOutgoingCalls[ctx.frameRows[ctx.frameRows.length - 1]].incomingCalls;
        uint256 cur2 = ctx.frameRows.length == 0 ? ctx.topCursor : ctx.frameCursors[ctx.frameCursors.length - 1];
        return arr2[cur2].revertNextNCalls;
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
