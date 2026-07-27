// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ExecutionEntry,
    StateUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    StaticExecutionEntry
} from "../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    StaticExecutionEntry as L2StaticExecutionEntry
} from "../../src/interfaces/IEEZL2.sol";
import {TestHashes} from "../../test/TestHashes.sol";
import {ScenarioStore, CallParams} from "./ScenarioStore.sol";

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
    uint256 internal constant NONE = type(uint256).max;

    error RoundTripMismatch(string what);

    // ── inputs: tables ──
    ExecutionEntry[] internal _l1Entries;
    StaticExecutionEntry[] internal _l1Statics;

    uint64[] internal _unitChain;
    uint8[] internal _unitKind; // 1 = origin group, 2 = inbound delivery
    mapping(uint256 => L2ExecutionEntry[]) internal _unitEntries;
    mapping(uint256 => L2StaticExecutionEntry[]) internal _unitStatics;

    uint64[] internal _chains; // distinct L2 chain ids seen in units
    mapping(uint64 => bool) internal _chainSeen;

    // ── inputs: sidecar ──
    struct SidecarTx {
        uint64 originChain;
        bytes txData;
        uint8[] rootKinds; // 0 = mutable call, 1 = static call
    }

    struct SidecarStatic {
        address fromAddress;
        uint64 toChain;
        address toAddress;
        uint64 gas;
        bytes data;
    }

    /// @dev Result of one static sub-read, in parent-DFS order. A sub-read's FIELDS
    ///      live in its static entry's sub-call array (a table), but its result is
    ///      only ever hashed into the untagged accumulator — so the result alone
    ///      rides the sidecar.
    struct SidecarStaticResult {
        bool success;
        bytes returnData;
    }

    SidecarTx[] internal _txMeta;
    SidecarStatic[] internal _statics;
    SidecarStaticResult[] internal _staticSubResults;
    uint16[] internal _regionSizes;
    // Observed callGas per L2-sourced mutable call, queued per destination-kind hash in
    // execution order (callGas reaches no table — it lives only inside the source-side keys).
    mapping(bytes32 => uint64[]) internal _callGasQueue;
    mapping(bytes32 => uint256) internal _callGasCursor;

    // ── stitch state ──
    ScenarioStore internal _out;
    uint256 internal _l1Cursor; // next L1 entry
    uint256 internal _l1StaticCursor;
    mapping(uint64 => uint256) internal _unitScan; // per-chain scan position over units
    mapping(uint256 => uint256) internal _unitEntryCursor; // per (origin) unit: next entry
    mapping(uint256 => uint256) internal _unitStaticCursor;
    uint256 internal _staticCursor; // sidecar statics
    uint256 internal _staticSubCursor; // sidecar sub-read results
    uint256 internal _regionCursor; // sidecar region sizes

    struct Sim {
        bool active;
        bool isL1;
        uint256 unitIdx; // L2 only
        uint256 entryPos; // L2 only (position within the unit)
        uint256 l1Entry; // L1 only
        bytes32 liveHash;
        uint256 rowCursor; // next reentrant-table row
        uint256 topCursor; // cursor into the entry's top-level call array
        uint256[] frameRows; // open reentrant frames (row indices)
        uint256[] frameCursors; // per open frame: cursor into its sub-array
    }

    mapping(uint64 => Sim) internal _sim;

    // region reconstruction
    bool internal _regionOpen;
    uint256 internal _pendingRegionNode = NONE;
    bool internal _regionJustOpened;
    // intra-entry regions branch the hosting chain's rolling hash in the generator
    // (the host's own EVM revert undoes the folds) — mirror the restore here
    bool internal _regionBranchActive;
    uint64 internal _regionSimChain;
    bytes32 internal _regionSavedSimHash;

    // ──────────────────────────────────────────────
    //  Loading (harness feeds the generator's outputs + the sidecar)
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
        SidecarTx storage t = _txMeta.push();
        t.originChain = originChain;
        t.txData = txData;
        t.rootKinds = rootKinds;
    }

    function loadSidecarStatic(SidecarStatic calldata s) external {
        _statics.push(s);
    }

    function loadSidecarStaticSubResult(bool success, bytes calldata returnData) external {
        SidecarStaticResult storage r = _staticSubResults.push();
        r.success = success;
        r.returnData = returnData;
    }

    function loadSidecarCallGas(bytes32 destCch, uint64 callGas) external {
        _callGasQueue[destCch].push(callGas);
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

    struct SidecarChainOp {
        uint64 chainId;
        bytes operations;
        uint256 txsBefore;
    }

    SidecarChainOp[] internal _outChainOps;
    bool internal _hasClose;
    uint256 internal _closeTxsBefore;
    uint256 internal _closeOpsBefore;

    function loadSidecarClose(uint256 txsBefore, uint256 opsBefore) external {
        _hasClose = true;
        _closeTxsBefore = txsBefore;
        _closeOpsBefore = opsBefore;
    }

    // ──────────────────────────────────────────────
    //  Stitch
    // ──────────────────────────────────────────────

    function stitch(ScenarioStore out) external {
        _out = out;
        for (uint256 i = 0; i < _outChainOps.length; i++) {
            out.addChainOp(_outChainOps[i].chainId, _outChainOps[i].operations, _outChainOps[i].txsBefore);
        }
        if (_hasClose) out.setClose(_closeTxsBefore, _closeOpsBefore);

        for (uint256 t = 0; t < _txMeta.length; t++) {
            _stitchTx(t);
        }
        if (_l1Cursor != _l1Entries.length) revert RoundTripMismatch("unconsumed L1 entries");
    }

    function _stitchTx(uint256 t) internal {
        SidecarTx storage meta = _txMeta[t];
        uint64 origin = meta.originChain;
        uint256 txId = _out.newTx(origin, meta.txData);

        uint256 l1HostIdx = NONE;
        if (origin != L1_CHAIN) {
            // The tx's L2Tx host commitment on L1.
            l1HostIdx = _l1Cursor++;
            if (_l1Entries[l1HostIdx].proxyEntryHash != bytes32(0)) {
                revert RoundTripMismatch("expected L2Tx host entry");
            }
            _openL1Sim(l1HostIdx);
        }

        uint256 originUnit = NONE;
        uint256 regionRemaining = 0;
        for (uint256 k = 0; k < meta.rootKinds.length; k++) {
            uint256 nodeId;
            if (meta.rootKinds[k] == 1) {
                if (origin != L1_CHAIN && originUnit == NONE) originUnit = _nextUnit(origin, 1);
                nodeId = _stitchRootStatic(txId, origin, originUnit);
            } else {
                if (origin == L1_CHAIN) {
                    uint256 idx = _l1Cursor++;
                    ExecutionEntry storage e = _l1Entries[idx];
                    if (e.proxyEntryHash == bytes32(0)) revert RoundTripMismatch("unexpected L2Tx entry");
                    _openL1Sim(idx);
                    nodeId = _stitchRootCall(txId, origin, e.proxyEntryHash, e.success, e.returnData);
                    if (_sim[L1_CHAIN].liveHash != e.rollingHash) revert RoundTripMismatch("L1 root rollingHash");
                    _sim[L1_CHAIN].active = false;
                } else {
                    if (originUnit == NONE) originUnit = _nextUnit(origin, 1);
                    uint256 pos = _unitEntryCursor[originUnit]++;
                    L2ExecutionEntry storage e2 = _unitEntries[originUnit][pos];
                    _openL2Sim(origin, originUnit, pos, _hEntryBeginL2(e2.proxyEntryHash), 0);
                    nodeId = _stitchRootCall(txId, origin, e2.proxyEntryHash, e2.success, e2.returnData);
                    if (_sim[origin].liveHash != e2.rollingHash) revert RoundTripMismatch("origin rollingHash");
                    _sim[origin].active = false;
                }
            }
            // Root-level region bookkeeping (opened when the root's destination record
            // carried the first span marker). No hash branch at root level: each root
            // consumption seeds its own hash, so there is nothing to restore.
            regionRemaining = _siblingRegionStep(nodeId, regionRemaining);
            _regionJustOpened = false;
        }

        if (origin != L1_CHAIN) {
            if (_sim[L1_CHAIN].liveHash != _l1Entries[l1HostIdx].rollingHash) {
                revert RoundTripMismatch("L2Tx host rollingHash");
            }
            _sim[L1_CHAIN].active = false;
        }
    }

    /// @notice Root mutable call: fields resolved from the destination side by the
    ///         origin entry's proxyEntryHash; result from the origin entry.
    function _stitchRootCall(uint256 txId, uint64 origin, bytes32 cch, bool success, bytes memory returnData)
        internal
        returns (uint256 nodeId)
    {
        CallParams memory p = _resolveByCch(origin, cch);
        _consumeCallGas(p);
        nodeId = _out.newCall(txId, NONE, p);
        _out.setResult(nodeId, success, returnData);
        _stitchDestination(txId, nodeId, p, success, returnData);
    }

    /// @notice Root static read: fields from the sidecar, result from the caller-side
    ///         pool entry (L1 batch statics / the origin unit's statics). The pool
    ///         entry's sub-call array holds the read's own sub-reads (full fields —
    ///         only their results come from the sidecar), cross-checked against the
    ///         untagged accumulator. A read targeting an executing chain (the L2Tx
    ///         host when it targets L1) is also consumed from that chain's arrays
    ///         with its real folds, its sub-reads matched as STATIC rows.
    function _stitchRootStatic(uint256 txId, uint64 origin, uint256 originUnit) internal returns (uint256 nodeId) {
        SidecarStatic storage sc = _statics[_staticCursor++];
        CallParams memory p = CallParams({
            isStatic: true,
            fromChain: origin,
            fromAddress: sc.fromAddress,
            toChain: sc.toChain,
            toAddress: sc.toAddress,
            value: 0,
            gas: sc.gas,
            data: sc.data
        });
        bytes32 cch = _cchOf(p);
        bool success;
        bytes memory ret;
        bytes32[] memory subCchs;
        if (origin == L1_CHAIN) {
            StaticExecutionEntry storage se = _l1Statics[_l1StaticCursor++];
            if (se.proxyEntryHash != cch) revert RoundTripMismatch("L1 static pool hash");
            (success, ret) = (se.success, se.returnData);
            nodeId = _out.newCall(txId, NONE, p);
            _out.setResult(nodeId, success, ret);
            subCchs = _stitchStaticSubsL1(txId, nodeId, p, se);
        } else {
            L2StaticExecutionEntry storage se2 = _unitStatics[originUnit][_unitStaticCursor[originUnit]++];
            if (se2.proxyEntryHash != cch) revert RoundTripMismatch("L2 static pool hash");
            (success, ret) = (se2.success, se2.returnData);
            nodeId = _out.newCall(txId, NONE, p);
            _out.setResult(nodeId, success, ret);
            subCchs = _stitchStaticSubsL2(txId, nodeId, p, se2);
        }

        if (p.toChain == L1_CHAIN || _sim[p.toChain].active) {
            // Live leg on the executing destination: the isStatic array item + real
            // folds, with one STATIC row per sub-read at this exact point.
            uint16 marker = _consumeArrayItem(p.toChain, cch);
            _noteMarker(nodeId, marker);
            _fold(p.toChain, cch, true);
            Sim storage s = _sim[p.toChain];
            for (uint256 i = 0; i < subCchs.length; i++) {
                if (_rowKey(p.toChain, s.rowCursor) != keccak256(abi.encodePacked(subCchs[i], s.liveHash))) {
                    revert RoundTripMismatch("static sub-read row key");
                }
                s.rowCursor++;
            }
            _foldEnd(p.toChain, success, ret);
        }
    }

    /// @dev Rebuilds an L1 pool entry's sub-reads: fields from the sub-call array,
    ///      results from the sidecar, the untagged accumulator cross-checked.
    function _stitchStaticSubsL1(uint256 txId, uint256 parentNode, CallParams memory p, StaticExecutionEntry storage se)
        internal
        returns (bytes32[] memory subCchs)
    {
        subCchs = new bytes32[](se.l2ToL1Calls.length);
        bytes32 acc = bytes32(0);
        for (uint256 i = 0; i < se.l2ToL1Calls.length; i++) {
            L2ToL1Call storage c = se.l2ToL1Calls[i];
            acc = _stitchOneStaticSub(
                txId,
                parentNode,
                p,
                CallParams({
                    isStatic: c.isStatic,
                    fromChain: c.sourceRollupId,
                    fromAddress: c.sourceAddress,
                    toChain: p.fromChain, // sub-reads run on the resolving (reader) chain
                    toAddress: c.targetAddress,
                    value: c.value,
                    gas: c.gas,
                    data: c.data
                }),
                acc,
                subCchs,
                i
            );
        }
        if (acc != se.rollingHash) revert RoundTripMismatch("static sub-read accumulator");
    }

    /// @dev L2-pool twin of `_stitchStaticSubsL1`.
    function _stitchStaticSubsL2(
        uint256 txId,
        uint256 parentNode,
        CallParams memory p,
        L2StaticExecutionEntry storage se
    )
        internal
        returns (bytes32[] memory subCchs)
    {
        subCchs = new bytes32[](se.incomingCalls.length);
        bytes32 acc = bytes32(0);
        for (uint256 i = 0; i < se.incomingCalls.length; i++) {
            CrossChainCall storage c = se.incomingCalls[i];
            acc = _stitchOneStaticSub(
                txId,
                parentNode,
                p,
                CallParams({
                    isStatic: c.isStatic,
                    fromChain: c.sourceRollupId,
                    fromAddress: c.sourceAddress,
                    toChain: p.fromChain,
                    toAddress: c.targetAddress,
                    value: c.value,
                    gas: c.gas,
                    data: c.data
                }),
                acc,
                subCchs,
                i
            );
        }
        if (acc != se.rollingHash) revert RoundTripMismatch("static sub-read accumulator");
    }

    /// @dev One sub-read: shape-checked (static, fired from the parent's destination),
    ///      appended to the rebuilt tree with its sidecar result, folded into `acc`.
    function _stitchOneStaticSub(
        uint256 txId,
        uint256 parentNode,
        CallParams memory p,
        CallParams memory sub,
        bytes32 acc,
        bytes32[] memory subCchs,
        uint256 i
    )
        internal
        returns (bytes32)
    {
        if (!sub.isStatic || sub.fromChain != p.toChain) {
            revert RoundTripMismatch("static sub-read shape");
        }
        SidecarStaticResult storage r = _staticSubResults[_staticSubCursor++];
        uint256 subNode = _out.newCall(txId, parentNode, sub);
        _out.setResult(subNode, r.success, r.returnData);
        subCchs[i] = _cchOf(sub);
        return _hStatic(acc, r.success, r.returnData);
    }

    // ──────────────────────────────────────────────
    //  Destination side + children
    // ──────────────────────────────────────────────

    /// @notice Consumes the destination-side record of a mutable call and recurses
    ///         into the calls its execution fired (mirrors TableGenerator._execCall).
    function _stitchDestination(
        uint256 txId,
        uint256 nodeId,
        CallParams memory p,
        bool success,
        bytes memory returnData
    )
        internal
    {
        uint64 dest = p.toChain;
        bytes32 cch = _cchOf(p);

        if (dest == L1_CHAIN || _sim[dest].active) {
            uint16 marker = _consumeArrayItem(dest, cch);
            _noteMarker(nodeId, marker);
            _fold(dest, cch, true);
            _stitchChildren(txId, nodeId, dest);
            _foldEnd(dest, success, returnData);
        } else {
            uint256 unitIdx = _nextUnit(dest, 2);
            L2ExecutionEntry storage e = _unitEntries[unitIdx][0];
            if (e.proxyEntryHash != cch) revert RoundTripMismatch("inbound proxyEntryHash");
            _noteMarker(nodeId, e.incomingCalls[0].revertNextNCalls);
            // incomingCalls[0] is the inbound call itself — start the top cursor past it.
            _openL2Sim(dest, unitIdx, 0, _hEntryBeginL2(cch), 1);
            _fold(dest, cch, true);
            _stitchChildren(txId, nodeId, dest);
            _foldEnd(dest, e.success, e.returnData);
            if (_sim[dest].liveHash != e.rollingHash) revert RoundTripMismatch("inbound rollingHash");
            _sim[dest].active = false;
        }
    }

    /// @notice Rebuilds the calls fired FROM `x` while `parent` executes there: reads
    ///         the host's reentrant rows in cursor order; the row whose key matches
    ///         `keccak(candidateHash ‖ liveHash)` is the next child — no match means
    ///         this nesting level is complete.
    function _stitchChildren(uint256 txId, uint256 parentNode, uint64 x) internal {
        uint256 regionRemaining = 0;
        while (true) {
            Sim storage s = _sim[x];
            if (s.rowCursor >= _rowCount(x)) break;

            bytes32 preChildHash = s.liveHash;
            (bool found, bool isStatic, CallParams memory p) = _matchNextRow(x);
            if (!found) break;
            s.rowCursor++;
            if (isStatic) _staticCursor++; // the matched candidate is claimed

            (bool rSuccess, bytes memory rRet, bytes32 rSubHash) = _rowResult(x, s.rowCursor - 1);
            uint256 nodeId = _out.newCall(txId, parentNode, p);
            _out.setResult(nodeId, rSuccess, rRet);

            if (isStatic) {
                // STATIC row: host hash untouched; if the destination is executing,
                // its arrays carry the read at this exact point.
                if (p.toChain == L1_CHAIN || _sim[p.toChain].active) {
                    bytes32 cch = _cchOf(p);
                    _consumeArrayItem(p.toChain, cch);
                    _fold(p.toChain, cch, true);
                    _foldEnd(p.toChain, rSuccess, rRet);
                }
            } else {
                bytes32 cch = _srcCchOf(p);
                _consumeCallGas(p);
                bytes32 fireHash = s.liveHash;
                s.liveHash = _hNestedBegin(s.liveHash, cch);
                s.frameRows.push(s.rowCursor - 1);
                s.frameCursors.push(0);

                _stitchDestination(txId, nodeId, p, rSuccess, rRet);

                s.frameRows.pop();
                s.frameCursors.pop();
                if (rSuccess) {
                    s.liveHash = _hNestedEnd(s.liveHash);
                } else {
                    if (s.liveHash != rSubHash) revert RoundTripMismatch("reverted frame sub-hash");
                    s.liveHash = fireHash;
                }
            }
            regionRemaining = _siblingRegionStep(nodeId, regionRemaining);
            if (_regionJustOpened) {
                // Intra-entry region: `x` is the hosting chain — its folds inside the
                // region are undone by the host actor's own revert.
                _regionJustOpened = false;
                _regionBranchActive = true;
                _regionSimChain = x;
                _regionSavedSimHash = preChildHash;
            }
            if (!_regionOpen && _regionBranchActive && _regionSimChain == x) {
                s.liveHash = _regionSavedSimHash;
                _regionBranchActive = false;
            }
        }
    }

    /// @notice Tries to identify the next row of `x`'s host: a sidecar static or, for
    ///         mutable calls, the next pending destination record on any other chain.
    function _matchNextRow(uint64 x) internal view returns (bool, bool, CallParams memory p) {
        bytes32 key = _rowKey(x, _sim[x].rowCursor);
        bytes32 live = _sim[x].liveHash;

        // Static candidate (next unclaimed sidecar static, fired from x).
        if (_staticCursor < _statics.length) {
            SidecarStatic storage sc = _statics[_staticCursor];
            CallParams memory sp = CallParams({
                isStatic: true,
                fromChain: x,
                fromAddress: sc.fromAddress,
                toChain: sc.toChain,
                toAddress: sc.toAddress,
                value: 0,
                gas: sc.gas,
                data: sc.data
            });
            if (keccak256(abi.encodePacked(_cchOf(sp), live)) == key) {
                return (true, true, sp);
            }
        }

        // Mutable candidates: L1's host arrays, other hosted chains' arrays, or the
        // next pending inbound unit per chain.
        if (x != L1_CHAIN && _sim[L1_CHAIN].active) {
            (bool ok, CallParams memory cp) = _peekArrayItem(L1_CHAIN);
            if (ok && keccak256(abi.encodePacked(_srcCchOf(cp), live)) == key) return (true, false, cp);
        }
        for (uint256 i = 0; i < _chains.length; i++) {
            uint64 w = _chains[i];
            if (w == x) continue;
            if (_sim[w].active) {
                (bool ok, CallParams memory cp) = _peekArrayItem(w);
                if (ok && keccak256(abi.encodePacked(_srcCchOf(cp), live)) == key) return (true, false, cp);
            } else {
                (bool ok, CallParams memory cp) = _peekUnitInbound(w);
                if (ok && keccak256(abi.encodePacked(_srcCchOf(cp), live)) == key) return (true, false, cp);
            }
        }
        return (false, false, p);
    }

    /// @notice The hash the SOURCE chain keys `p` with: gas-folding (next queued callGas for this
    ///         shape, peeked) when the call leaves an L2, the plain formula when it leaves L1.
    function _srcCchOf(CallParams memory p) internal view returns (bytes32) {
        if (p.fromChain == L1_CHAIN) return _cchOf(p);
        bytes32 destCch = _cchOf(p);
        uint64[] storage q = _callGasQueue[destCch];
        uint256 cur = _callGasCursor[destCch];
        uint64 g = cur < q.length ? q[cur] : 0; // exhausted ⇒ hash can't match ⇒ candidate rejected
        return _ccHashGas(p.isStatic, p.fromAddress, p.fromChain, p.toAddress, p.toChain, p.value, g, p.data);
    }

    /// @dev Claims the peeked callGas once a candidate is confirmed as the next node.
    function _consumeCallGas(CallParams memory p) internal {
        if (p.fromChain != L1_CHAIN && !p.isStatic) _callGasCursor[_cchOf(p)]++;
    }

    /// @notice Resolves a root call's fields by its source-side crossChainCallHash (origin
    ///         entries key by cch directly, not by position).
    function _resolveByCch(uint64 origin, bytes32 cch) internal view returns (CallParams memory) {
        if (origin != L1_CHAIN && _sim[L1_CHAIN].active) {
            (bool ok, CallParams memory cp) = _peekArrayItem(L1_CHAIN);
            if (ok && _srcCchOf(cp) == cch) return cp;
        }
        for (uint256 i = 0; i < _chains.length; i++) {
            uint64 w = _chains[i];
            if (w == origin) continue;
            (bool ok, CallParams memory cp) = _peekUnitInbound(w);
            if (ok && _srcCchOf(cp) == cch) return cp;
        }
        revert RoundTripMismatch("root call destination not found");
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
            _pendingRegionNode = NONE;
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
    //  Sim plumbing
    // ──────────────────────────────────────────────

    function _openL1Sim(uint256 entryIdx) internal {
        Sim storage s = _sim[L1_CHAIN];
        s.active = true;
        s.isL1 = true;
        s.l1Entry = entryIdx;
        s.liveHash = _hEntryBegin(_l1Entries[entryIdx].stateUpdates, _l1Entries[entryIdx].proxyEntryHash);
        s.rowCursor = 0;
        s.topCursor = 0;
        _clearStacks(s);
    }

    function _openL2Sim(uint64 chain, uint256 unitIdx, uint256 entryPos, bytes32 seed, uint256 topCursor) internal {
        Sim storage s = _sim[chain];
        s.active = true;
        s.isL1 = false;
        s.unitIdx = unitIdx;
        s.entryPos = entryPos;
        s.liveHash = seed;
        s.rowCursor = 0;
        s.topCursor = topCursor;
        _clearStacks(s);
    }

    function _clearStacks(Sim storage s) internal {
        while (s.frameRows.length > 0) {
            s.frameRows.pop();
        }
        while (s.frameCursors.length > 0) {
            s.frameCursors.pop();
        }
    }

    /// @notice Next unconsumed unit of `chain` with the expected kind.
    function _nextUnit(uint64 chain, uint8 kind) internal returns (uint256 idx) {
        uint256 i = _unitScan[chain];
        while (i < _unitChain.length && _unitChain[i] != chain) {
            i++;
        }
        if (i >= _unitChain.length) revert RoundTripMismatch("missing unit");
        if (_unitKind[i] != kind) revert RoundTripMismatch("unit kind");
        _unitScan[chain] = i + 1;
        return i;
    }

    // ── host-array access (top array or open frame's sub-array) ──

    function _rowCount(uint64 x) internal view returns (uint256) {
        Sim storage s = _sim[x];
        return s.isL1
            ? _l1Entries[s.l1Entry].expectedL1ToL2Calls.length
            : _unitEntries[s.unitIdx][s.entryPos].expectedOutgoingCalls.length;
    }

    function _rowKey(uint64 x, uint256 rowIdx) internal view returns (bytes32) {
        Sim storage s = _sim[x];
        return s.isL1
            ? _l1Entries[s.l1Entry].expectedL1ToL2Calls[rowIdx].expectedL1toL2Hash
            : _unitEntries[s.unitIdx][s.entryPos].expectedOutgoingCalls[rowIdx].expectedOutgoingHash;
    }

    function _rowResult(uint64 x, uint256 rowIdx) internal view returns (bool, bytes memory, bytes32) {
        Sim storage s = _sim[x];
        if (s.isL1) {
            ExpectedL1ToL2Call storage r = _l1Entries[s.l1Entry].expectedL1ToL2Calls[rowIdx];
            return (r.success, r.returnData, r.revertedOrStaticRollingHash);
        }
        ExpectedOutgoingCrossChainCall storage r2 = _unitEntries[s.unitIdx][s.entryPos].expectedOutgoingCalls[rowIdx];
        return (r2.success, r2.returnData, r2.revertedOrStaticRollingHash);
    }

    /// @notice Peeks the next unconsumed item of `x`'s current insertion array.
    function _peekArrayItem(uint64 x) internal view returns (bool ok, CallParams memory p) {
        Sim storage s = _sim[x];
        if (s.isL1) {
            ExecutionEntry storage e = _l1Entries[s.l1Entry];
            L2ToL1Call[] storage arr = s.frameRows.length == 0
                ? e.l2ToL1Calls
                : e.expectedL1ToL2Calls[s.frameRows[s.frameRows.length - 1]].l2ToL1Calls;
            uint256 cur = s.frameRows.length == 0 ? s.topCursor : s.frameCursors[s.frameCursors.length - 1];
            if (cur >= arr.length) return (false, p);
            L2ToL1Call storage c = arr[cur];
            return (
                true,
                CallParams({
                    isStatic: c.isStatic,
                    fromChain: c.sourceRollupId,
                    fromAddress: c.sourceAddress,
                    toChain: L1_CHAIN,
                    toAddress: c.targetAddress,
                    value: c.value,
                    gas: c.gas,
                    data: c.data
                })
            );
        }
        L2ExecutionEntry storage e2 = _unitEntries[s.unitIdx][s.entryPos];
        CrossChainCall[] storage arr2 = s.frameRows.length == 0
            ? e2.incomingCalls
            : e2.expectedOutgoingCalls[s.frameRows[s.frameRows.length - 1]].incomingCalls;
        uint256 cur2 = s.frameRows.length == 0 ? s.topCursor : s.frameCursors[s.frameCursors.length - 1];
        if (cur2 >= arr2.length) return (false, p);
        CrossChainCall storage c2 = arr2[cur2];
        return (
            true,
            CallParams({
                isStatic: c2.isStatic,
                fromChain: c2.sourceRollupId,
                fromAddress: c2.sourceAddress,
                toChain: x,
                toAddress: c2.targetAddress,
                value: c2.value,
                gas: c2.gas,
                data: c2.data
            })
        );
    }

    /// @notice Consumes the next item of `x`'s insertion array (must hash to `cch`);
    ///         returns its span marker for region reconstruction.
    function _consumeArrayItem(uint64 x, bytes32 cch) internal returns (uint16 marker) {
        (bool ok, CallParams memory p) = _peekArrayItem(x);
        if (!ok || _cchOf(p) != cch) revert RoundTripMismatch("array item mismatch");
        Sim storage s = _sim[x];
        marker = _peekMarker(x);
        if (s.frameRows.length == 0) {
            s.topCursor++;
        } else {
            s.frameCursors[s.frameCursors.length - 1]++;
        }
    }

    function _peekMarker(uint64 x) internal view returns (uint16) {
        Sim storage s = _sim[x];
        if (s.isL1) {
            ExecutionEntry storage e = _l1Entries[s.l1Entry];
            L2ToL1Call[] storage arr = s.frameRows.length == 0
                ? e.l2ToL1Calls
                : e.expectedL1ToL2Calls[s.frameRows[s.frameRows.length - 1]].l2ToL1Calls;
            uint256 cur = s.frameRows.length == 0 ? s.topCursor : s.frameCursors[s.frameCursors.length - 1];
            return arr[cur].revertNextNCalls;
        }
        L2ExecutionEntry storage e2 = _unitEntries[s.unitIdx][s.entryPos];
        CrossChainCall[] storage arr2 = s.frameRows.length == 0
            ? e2.incomingCalls
            : e2.expectedOutgoingCalls[s.frameRows[s.frameRows.length - 1]].incomingCalls;
        uint256 cur2 = s.frameRows.length == 0 ? s.topCursor : s.frameCursors[s.frameCursors.length - 1];
        return arr2[cur2].revertNextNCalls;
    }

    /// @notice Peeks the next pending inbound (kind 2) unit of chain `w`.
    function _peekUnitInbound(uint64 w) internal view returns (bool ok, CallParams memory p) {
        uint256 i = _unitScan[w];
        while (i < _unitChain.length && _unitChain[i] != w) {
            i++;
        }
        if (i >= _unitChain.length || _unitKind[i] != 2) return (false, p);
        CrossChainCall storage c = _unitEntries[i][0].incomingCalls[0];
        return (
            true,
            CallParams({
                isStatic: c.isStatic,
                fromChain: c.sourceRollupId,
                fromAddress: c.sourceAddress,
                toChain: w,
                toAddress: c.targetAddress,
                value: c.value,
                gas: c.gas,
                data: c.data
            })
        );
    }

    function _fold(uint64 x, bytes32 cch, bool /*begin*/) internal {
        _sim[x].liveHash = _hCallBegin(_sim[x].liveHash, cch);
    }

    function _foldEnd(uint64 x, bool success, bytes memory ret) internal {
        _sim[x].liveHash = _hCallEnd(_sim[x].liveHash, success, ret);
    }

    function _cchOf(CallParams memory p) internal pure returns (bytes32) {
        return _ccHash(p.isStatic, p.fromAddress, p.fromChain, p.toAddress, p.toChain, p.value, p.data);
    }
}
