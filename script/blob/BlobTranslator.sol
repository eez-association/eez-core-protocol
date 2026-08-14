// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ExecutionEntry, StaticExecutionEntry} from "../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry
} from "../../src/interfaces/IEEZL2.sol";
import {TestHashes} from "../../test/TestHashes.sol";
import {BlobMessage} from "./BlobMessages.sol";
import {BlobCodec} from "./BlobCodec.sol";
import {BlobPacking} from "./BlobPacking.sol";
import {ScenarioStore, CallNode, TxSpec, ChainOpSpec} from "./ScenarioStore.sol";
import {SidecarTx, SidecarStatic, SidecarStaticResult, SidecarChainOp} from "./BlobSidecar.sol";
import {ROOT_KIND_CALL, ROOT_KIND_STATIC} from "./BlobConstants.sol";
import {TableGenerator} from "./TableGenerator.sol";
import {TableStitcher} from "./TableStitcher.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  BlobTranslator — one-call facade over the blob ⇄ table pipeline.
//
//  The four conversions, each a single call (no store/generator/stitcher
//  orchestration at the call site):
//
//      blobsToData    bytes32[][] blobs        → bytes stream        (§4 unpack)
//      dataToBlobs    bytes stream             → bytes32[][] blobs   (§4 pack)
//      dataToTables   bytes stream (+ tail)    → Tables              (decode → parse → generate)
//      tablesToData   Tables                   → bytes stream + tail (stitch → emit → encode)
//
//  `Tables` bundles everything the Table → Blob direction needs: the L1 batch
//  artifacts, each L2 chain's units in execution order, and the SIDECAR of data
//  that provably never reaches any table (tx boundaries, static call fields,
//  chain ops, region sizes, per-call callGas — see TableStitcher). Because
//  `dataToTables` emits the sidecar alongside the tables, its output feeds
//  `tablesToData` directly and round-trips to the exact input bytes.
//
//  callGas: tables are derived with a zero callGas oracle — correct for every
//  current deployment (`useGasLeft = false`, all keys fold 0). Under a future
//  observed-gas mode the oracle must come from probing live managers
//  (`BlobScenarioBase._probeAllCallGas`), not from this facade.
// ─────────────────────────────────────────────────────────────────────────────

contract BlobTranslator is TestHashes {
    uint64 internal constant L1_CHAIN = 0;

    /// @notice One L2 unit in execution order (mirrors TableGenerator's unit stream).
    struct L2Unit {
        uint64 chainId; // rollup id of the chain this unit loads on
        uint8 kind; // UNIT_KIND_ORIGIN_GROUP (loadExecutionTable + own tx) / UNIT_KIND_INBOUND (executeIncomingCrossChainCall)
        L2ExecutionEntry[] entries; // the unit's execution table
        L2StaticExecutionEntry[] statics; // the unit's static pool
    }

    /// @notice The non-table data required to rebuild the blob (see TableStitcher's
    ///         sidecar rationale). `callGasKeys`/`callGasValues` are parallel arrays:
    ///         one row per L2-sourced mutable call in execution (DFS) order, keyed by
    ///         the destination-kind call hash (callGas = 0).
    struct Sidecar {
        SidecarTx[] txs; // per-tx: origin chain, tx_data, root slot kinds
        SidecarStatic[] statics; // fields of every hash-matched static call
        SidecarStaticResult[] staticSubResults; // sub-read results, parent-DFS order
        uint16[] regionSizes; // Snapshot region sizes, message order
        bytes32[] callGasKeys;
        uint64[] callGasValues;
        SidecarChainOp[] chainOps;
        bool hasClose; // CloseBlobStream present (position below)
        uint256 closeTxsBefore;
        uint256 closeOpsBefore;
    }

    /// @notice Every chain's execution artifacts for one blob stream, plus the sidecar.
    struct Tables {
        ExecutionEntry[] l1Entries; // L1 batch entries, message order
        StaticExecutionEntry[] l1Statics; // L1 static pool entries
        L2Unit[] units; // all chains' L2 units, execution order
        Sidecar sidecar;
    }

    // ──────────────────────────────────────────────
    //  1. blob ⇄ bytes data (§4 packing)
    // ──────────────────────────────────────────────

    /// @notice EIP-4844 blobs → the logical byte stream (includes the trailing zero
    ///         padding; the codec skips it).
    function blobsToData(bytes32[][] memory blobs) public pure returns (bytes memory stream) {
        return BlobPacking.unpack(blobs);
    }

    /// @notice Logical byte stream (the blob portion only — the callData tail rides
    ///         tx calldata, never a blob) → full-size EIP-4844 blobs.
    function dataToBlobs(bytes memory blobData) public pure returns (bytes32[][] memory blobs) {
        return BlobPacking.pack(blobData);
    }

    // ──────────────────────────────────────────────
    //  2. bytes data → tables
    // ──────────────────────────────────────────────

    /// @notice Decodes + validates the stream (§5), then derives every chain's tables
    ///         and the sidecar. `callDataTail` is the post-close segment ("" if none).
    function dataToTables(bytes memory blobData, bytes memory callDataTail) public returns (Tables memory t) {
        return messagesToTables(BlobCodec.decode(blobData, callDataTail));
    }

    /// @notice Message-level entry point of the same direction.
    function messagesToTables(BlobMessage[] memory msgs) public returns (Tables memory t) {
        ScenarioStore store = new ScenarioStore();
        store.fromMessages(msgs);
        uint64[] memory gasByNode = new uint64[](store.nodeCount()); // zero oracle: useGasLeft = false
        TableGenerator gen = new TableGenerator();
        gen.generate(store, gasByNode);

        t.l1Entries = gen.l1Entries();
        t.l1Statics = gen.l1StaticEntries();
        uint256 n = gen.unitCount();
        t.units = new L2Unit[](n);
        for (uint256 i = 0; i < n; i++) {
            TableGenerator.UnitTag memory tag = gen.unitTag(i);
            t.units[i] = L2Unit({
                chainId: tag.chainId, kind: tag.kind, entries: gen.unitEntries(i), statics: gen.unitStatics(i)
            });
        }
        t.sidecar = _buildSidecar(store, gasByNode);
    }

    // ──────────────────────────────────────────────
    //  3. tables → bytes data
    // ──────────────────────────────────────────────

    /// @notice Rebuilds the exact stream the tables came from (stitch → emit → encode).
    ///         Every stored rollingHash is cross-checked during the stitch — a
    ///         tampered table reverts `RoundTripMismatch`.
    function tablesToData(Tables memory t) public returns (bytes memory blobData, bytes memory callDataTail) {
        return BlobCodec.encode(tablesToMessages(t));
    }

    /// @notice Message-level exit point of the same direction.
    function tablesToMessages(Tables memory t) public returns (BlobMessage[] memory msgs) {
        TableStitcher stitcher = new TableStitcher();
        stitcher.loadL1(t.l1Entries, t.l1Statics);
        for (uint256 i = 0; i < t.units.length; i++) {
            stitcher.loadUnit(t.units[i].chainId, t.units[i].kind, t.units[i].entries, t.units[i].statics);
        }

        Sidecar memory s = t.sidecar;
        for (uint256 i = 0; i < s.txs.length; i++) {
            stitcher.loadSidecarTx(s.txs[i].originChain, s.txs[i].txData, s.txs[i].rootKinds);
        }
        for (uint256 i = 0; i < s.statics.length; i++) {
            stitcher.loadSidecarStatic(s.statics[i]);
        }
        for (uint256 i = 0; i < s.staticSubResults.length; i++) {
            stitcher.loadSidecarStaticSubResult(s.staticSubResults[i].success, s.staticSubResults[i].returnData);
        }
        stitcher.loadSidecarRegionSizes(s.regionSizes);
        for (uint256 i = 0; i < s.callGasKeys.length; i++) {
            stitcher.loadSidecarCallGas(s.callGasKeys[i], s.callGasValues[i]);
        }
        for (uint256 i = 0; i < s.chainOps.length; i++) {
            stitcher.loadSidecarChainOp(s.chainOps[i].chainId, s.chainOps[i].operations, s.chainOps[i].txsBefore);
        }
        if (s.hasClose) stitcher.loadSidecarClose(s.closeTxsBefore, s.closeOpsBefore);

        ScenarioStore rebuilt = new ScenarioStore();
        stitcher.stitch(rebuilt);
        return rebuilt.toMessages();
    }

    // ──────────────────────────────────────────────
    //  Composites: blob ⇄ tables in one hop
    // ──────────────────────────────────────────────

    function blobsToTables(bytes32[][] memory blobs, bytes memory callDataTail) public returns (Tables memory t) {
        return dataToTables(BlobPacking.unpack(blobs), callDataTail);
    }

    function tablesToBlobs(Tables memory t) public returns (bytes32[][] memory blobs, bytes memory callDataTail) {
        bytes memory blobData;
        (blobData, callDataTail) = tablesToData(t);
        blobs = BlobPacking.pack(blobData);
    }

    // ──────────────────────────────────────────────
    //  Sidecar derivation (mirrors the harness's stitcher feeding)
    // ──────────────────────────────────────────────

    function _buildSidecar(ScenarioStore store, uint64[] memory gasByNode) internal view returns (Sidecar memory s) {
        uint256 txN = store.txCount();
        s.txs = new SidecarTx[](txN);
        for (uint256 t = 0; t < txN; t++) {
            TxSpec memory txSpec = store.getTx(t);
            uint8[] memory kinds = new uint8[](txSpec.rootCalls.length);
            for (uint256 k = 0; k < txSpec.rootCalls.length; k++) {
                kinds[k] = store.getNode(txSpec.rootCalls[k]).isStatic ? ROOT_KIND_STATIC : ROOT_KIND_CALL;
            }
            s.txs[t] = SidecarTx({originChain: txSpec.originChain, txData: txSpec.txData, rootKinds: kinds});
        }

        // Static call fields + sub-read results (fields of a sub-read live in the
        // static entry's sub-call array — only its result rides the sidecar).
        uint256[] memory staticIds = store.staticNodesInOrder();
        uint256 subN = 0;
        for (uint256 i = 0; i < staticIds.length; i++) {
            subN += store.getNode(staticIds[i]).children.length;
        }
        s.statics = new SidecarStatic[](staticIds.length);
        s.staticSubResults = new SidecarStaticResult[](subN);
        uint256 w = 0;
        for (uint256 i = 0; i < staticIds.length; i++) {
            CallNode memory nd = store.getNode(staticIds[i]);
            s.statics[i] = SidecarStatic({
                fromAddress: nd.fromAddress, toChain: nd.toChain, toAddress: nd.toAddress, gas: nd.gas, data: nd.data
            });
            for (uint256 c = 0; c < nd.children.length; c++) {
                CallNode memory sub = store.getNode(nd.children[c]);
                s.staticSubResults[w++] = SidecarStaticResult({success: sub.success, returnData: sub.returnData});
            }
        }

        s.regionSizes = store.regionSizesInOrder();

        bytes32[] memory keys = new bytes32[](store.nodeCount());
        uint64[] memory vals = new uint64[](store.nodeCount());
        uint256 cg = 0;
        for (uint256 t = 0; t < txN; t++) {
            cg = _collectCallGas(store, store.getTx(t).rootCalls, gasByNode, keys, vals, cg);
        }
        s.callGasKeys = new bytes32[](cg);
        s.callGasValues = new uint64[](cg);
        for (uint256 i = 0; i < cg; i++) {
            s.callGasKeys[i] = keys[i];
            s.callGasValues[i] = vals[i];
        }

        uint256 opN = store.chainOpCount();
        s.chainOps = new SidecarChainOp[](opN);
        for (uint256 i = 0; i < opN; i++) {
            ChainOpSpec memory op = store.getChainOp(i);
            s.chainOps[i] = SidecarChainOp({chainId: op.chainId, operations: op.operations, txsBefore: op.txsBefore});
        }

        s.hasClose = store.hasClose();
        if (s.hasClose) {
            s.closeTxsBefore = store.closeTxsBefore();
            s.closeOpsBefore = store.closeOpsBefore();
        }
    }

    /// @dev One callGas row per L2-sourced mutable call, DFS (execution) order,
    ///      keyed by the destination-kind hash — same feeding order the stitcher
    ///      consumes per key.
    function _collectCallGas(
        ScenarioStore store,
        uint256[] memory siblings,
        uint64[] memory gasByNode,
        bytes32[] memory keys,
        uint64[] memory vals,
        uint256 w
    )
        internal
        view
        returns (uint256)
    {
        for (uint256 i = 0; i < siblings.length; i++) {
            CallNode memory nd = store.getNode(siblings[i]);
            if (!nd.isStatic && nd.fromChain != L1_CHAIN) {
                keys[w] =
                    _ccHash(nd.isStatic, nd.fromAddress, nd.fromChain, nd.toAddress, nd.toChain, nd.value, nd.data);
                vals[w] = gasByNode[siblings[i]];
                w++;
            }
            w = _collectCallGas(store, nd.children, gasByNode, keys, vals, w);
        }
        return w;
    }
}
