// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlobMessage, BlobMsgType, Msg, MsgList} from "./BlobMessages.sol";
import {NO_NODE, MAX_CALL_DEPTH} from "./BlobConstants.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  ScenarioStore — the framework's intermediate representation (IR).
//
//  A validated blob message stream and the per-chain execution tables are two
//  encodings of the same thing: a forest of cross-chain call trees. This
//  contract stores that forest and converts both ways to the MESSAGE side:
//
//      BlobMessage[]  ──fromMessages()──▶  IR  ──toMessages()──▶  BlobMessage[]
//
//  (TableGenerator converts IR → tables; TableStitcher rebuilds an IR from
//  tables. Round-tripping through both proves the two encodings agree.)
//
//  A storage contract (not a library) so the recursive tree can use dynamic
//  push — instantiate one per conversion; state is append-only.
//
//  Shape restrictions (parse reverts `UnsupportedShape`; the byte codec
//  still accepts these streams — the limits apply to table translation only):
//    - a static call nests only when it is a TOP-LEVEL read, and then only
//      leaf static sub-reads of the reader chain (the chain that fired the
//      read). That is exactly the shape the static entries verify: the pool
//      entry resolves on the reader chain and re-runs its sub-read array live
//      via STATICCALL against the untagged rolling hash — reads landing
//      anywhere else could not be re-run there,
//    - Snapshot/Revert regions don't nest and close between transactions is
//      the only supported CloseBlobStream position,
//    - a call's target is never the chain it executes on (the protocol rejects
//      same-network proxies),
//    - a ReturnFail frame carries no committed (successful mutable) sub-calls —
//      its terminal revert rolls back the frame's own nested consumptions on the
//      executing chain, so the generator's folded hash could never match live
//      (failing or static sub-calls are fine).
// ─────────────────────────────────────────────────────────────────────────────

/// @notice One call in the tree. `fromChain` is derived from the context stack
///         (spec §1.2) at parse time — it is not on the wire.
struct CallNode {
    bool isStatic;
    uint64 fromChain;
    address fromAddress;
    uint64 toChain;
    address toAddress;
    uint256 value;
    uint64 gas;
    bytes data;
    bool success; // ReturnSuccess vs ReturnFail
    bytes returnData;
    uint16 revertSpan; // >0 ⇒ a Snapshot opens right before this call and covers it + the next (revertSpan-1) siblings
    uint256[] children; // node ids of calls fired while this call executes
}

/// @notice Creation params for a node (results and revertSpan are set separately).
struct CallParams {
    bool isStatic;
    uint64 fromChain;
    address fromAddress;
    uint64 toChain;
    address toAddress;
    uint256 value;
    uint64 gas;
    bytes data;
}

struct TxSpec {
    uint64 originChain;
    bytes txData;
    uint256[] rootCalls; // node ids of the transaction's top-level calls
}

struct ChainOpSpec {
    uint64 chainId;
    bytes operations;
    uint256 txsBefore; // # transactions fully emitted before this op (position)
}

contract ScenarioStore {
    CallNode[] internal _nodes;
    mapping(uint256 => bool) internal _isRoot; // node id → is a transaction root call
    TxSpec[] internal _txs;
    ChainOpSpec[] internal _chainOps;
    uint256 public closeTxsBefore;
    uint256 public closeOpsBefore;
    bool public hasClose;

    error UnsupportedShape(string reason);
    error ParseInvariant(string reason);

    /// @dev Root-frame parent sentinel — the shared NO_NODE value, because callers
    ///      (TableStitcher) pass it into `newCall` from across the contract boundary.
    uint256 internal constant ROOT_FRAME = NO_NODE;

    // ──────────────────────────────────────────────
    //  Getters
    // ──────────────────────────────────────────────

    function nodeCount() external view returns (uint256) {
        return _nodes.length;
    }

    function getNode(uint256 id) external view returns (CallNode memory) {
        return _nodes[id];
    }

    /// @notice Lightweight accessor (avoids copying the full node struct in loops).
    function nodeRevertSpan(uint256 id) external view returns (uint16) {
        return _nodes[id].revertSpan;
    }

    function txCount() external view returns (uint256) {
        return _txs.length;
    }

    function getTx(uint256 id) external view returns (TxSpec memory) {
        return _txs[id];
    }

    function chainOpCount() external view returns (uint256) {
        return _chainOps.length;
    }

    function getChainOp(uint256 id) external view returns (ChainOpSpec memory) {
        return _chainOps[id];
    }

    /// @notice Node ids of every top-level-or-nested static call in message (DFS)
    ///         order, EXCLUDING sub-reads of a static read — sidecar input for
    ///         TableStitcher: these calls' fields never appear in any table (both
    ///         sides match them by hash only), so they ride the blob, not the
    ///         tables. A static read's own sub-reads are different: their full
    ///         fields live in the static entry's sub-call array, so the stitcher
    ///         recovers them from the tables (only their RESULTS ride the sidecar —
    ///         see `TableStitcher.loadSidecarStaticSubResult`).
    function staticNodesInOrder() external view returns (uint256[] memory ids) {
        uint256[] memory buf = new uint256[](_nodes.length);
        uint256 n = 0;
        for (uint256 t = 0; t < _txs.length; t++) {
            n = _collectStatics(_txs[t].rootCalls, buf, n);
        }
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = buf[i];
        }
    }

    /// @notice Region sizes (revertSpan of each region's first call) in message order —
    ///         sidecar input: destination-side markers alone can't distinguish one
    ///         region over two sibling calls from two adjacent single-call regions.
    function regionSizesInOrder() external view returns (uint16[] memory sizes) {
        uint256[] memory buf = new uint256[](_nodes.length);
        uint256 n = 0;
        for (uint256 t = 0; t < _txs.length; t++) {
            n = _collectRegionStarts(_txs[t].rootCalls, buf, n);
        }
        sizes = new uint16[](n);
        for (uint256 i = 0; i < n; i++) {
            sizes[i] = _nodes[buf[i]].revertSpan;
        }
    }

    /// @dev DFS over `siblings` collecting static nodes. A static node's children
    ///      (its own sub-reads, always static) are NOT collected — their fields
    ///      live in the static entry's sub-call array, not the sidecar.
    function _collectStatics(uint256[] storage siblings, uint256[] memory buf, uint256 n)
        internal
        view
        returns (uint256)
    {
        for (uint256 i = 0; i < siblings.length; i++) {
            CallNode storage node = _nodes[siblings[i]];
            if (node.isStatic) {
                buf[n++] = siblings[i];
            } else {
                n = _collectStatics(node.children, buf, n);
            }
        }
        return n;
    }

    /// @dev DFS over `siblings` collecting each region's first node (revertSpan > 0).
    function _collectRegionStarts(uint256[] storage siblings, uint256[] memory buf, uint256 n)
        internal
        view
        returns (uint256)
    {
        for (uint256 i = 0; i < siblings.length; i++) {
            CallNode storage node = _nodes[siblings[i]];
            if (node.revertSpan > 0) {
                buf[n++] = siblings[i];
            }
            n = _collectRegionStarts(node.children, buf, n);
        }
        return n;
    }

    // ──────────────────────────────────────────────
    //  Builder API (used by the parser below and by TableStitcher)
    // ──────────────────────────────────────────────

    function newTx(uint64 originChain, bytes memory txData) public returns (uint256 txId) {
        txId = _txs.length;
        TxSpec storage t = _txs.push();
        t.originChain = originChain;
        t.txData = txData;
    }

    function newCall(uint256 txId, uint256 parentId, CallParams memory p) public returns (uint256 nodeId) {
        if (p.toChain == p.fromChain) revert UnsupportedShape("call target == executing chain");
        nodeId = _nodes.length;
        CallNode storage n = _nodes.push();
        n.isStatic = p.isStatic;
        n.fromChain = p.fromChain;
        n.fromAddress = p.fromAddress;
        n.toChain = p.toChain;
        n.toAddress = p.toAddress;
        n.value = p.value;
        n.gas = p.gas;
        n.data = p.data;
        if (parentId == ROOT_FRAME) {
            _isRoot[nodeId] = true;
            _txs[txId].rootCalls.push(nodeId);
        } else {
            CallNode storage parent = _nodes[parentId];
            if (parent.isStatic) {
                // A static entry re-runs its sub-read array live on the chain resolving
                // it (the reader chain) — only leaf reads landing there translate.
                if (!p.isStatic) revert UnsupportedShape("mutable call inside a static call");
                if (!_isRoot[parentId]) revert UnsupportedShape("static sub-reads cannot nest further");
                if (p.toChain != parent.fromChain) {
                    revert UnsupportedShape("static sub-read must target the reader chain");
                }
            }
            parent.children.push(nodeId);
        }
    }

    function setResult(uint256 nodeId, bool success, bytes memory returnData) public {
        _nodes[nodeId].success = success;
        _nodes[nodeId].returnData = returnData;
    }

    function setRevertSpan(uint256 nodeId, uint16 span) public {
        _nodes[nodeId].revertSpan = span;
    }

    function addChainOp(uint64 chainId, bytes memory operations, uint256 txsBefore) public {
        ChainOpSpec storage op = _chainOps.push();
        op.chainId = chainId;
        op.operations = operations;
        op.txsBefore = txsBefore;
    }

    function setClose(uint256 txsBefore, uint256 opsBefore) public {
        hasClose = true;
        closeTxsBefore = txsBefore;
        closeOpsBefore = opsBefore;
    }

    // ──────────────────────────────────────────────
    //  Messages → IR (parser)
    // ──────────────────────────────────────────────

    /// @notice Parses a validated message list (run it through `BlobCodec.decode`
    ///         first — this parser assumes bracket discipline holds and only checks
    ///         the v1 shape restrictions on top).
    function fromMessages(BlobMessage[] calldata msgs) external {
        if (_nodes.length != 0 || _txs.length != 0) revert ParseInvariant("store already populated");

        // Frame stack: ROOT_FRAME sentinel at the bottom of each tx, node ids above.
        // Capacity matches the codec's context stack — decode enforces the depth.
        uint256[] memory frames = new uint256[](MAX_CALL_DEPTH);
        uint64[] memory chains = new uint64[](MAX_CALL_DEPTH); // executing chain per frame level
        uint256 sp = 0;
        bool inTx = false;
        uint256 curTx = 0;

        bool regionOpen = false;
        uint256 regionFrame = 0;
        uint256 regionStart = 0;

        for (uint256 i = 0; i < msgs.length; i++) {
            BlobMessage calldata m = msgs[i];
            BlobMsgType t = m.msgType;

            if (t == BlobMsgType.ChainOperation) {
                addChainOp(m.chainId, m.data, _txs.length);
            } else if (t == BlobMsgType.InitiateCrossChainTransaction) {
                curTx = newTx(m.chainId, m.data);
                inTx = true;
                frames[0] = ROOT_FRAME;
                chains[0] = m.chainId;
                sp = 1;
            } else if (t == BlobMsgType.Call || t == BlobMsgType.StaticCall) {
                uint256 nodeId = newCall(
                    curTx,
                    frames[sp - 1],
                    CallParams({
                        isStatic: t == BlobMsgType.StaticCall,
                        fromChain: chains[sp - 1],
                        fromAddress: m.fromAddress,
                        toChain: m.chainId,
                        toAddress: m.toAddress,
                        value: m.value,
                        gas: m.gas,
                        data: m.data
                    })
                );
                frames[sp] = nodeId;
                chains[sp] = m.chainId;
                sp++;
            } else if (t == BlobMsgType.ReturnSuccess || t == BlobMsgType.ReturnFail) {
                sp--;
                if (t == BlobMsgType.ReturnFail) {
                    // A failing frame's terminal revert rolls back its own nested
                    // consumptions on the executing chain, so a committed (successful
                    // mutable) sub-call has no faithful table translation.
                    uint256[] storage kids = _nodes[frames[sp]].children;
                    for (uint256 k = 0; k < kids.length; k++) {
                        if (!_nodes[kids[k]].isStatic && _nodes[kids[k]].success) {
                            revert UnsupportedShape("ReturnFail frame with a committed sub-call");
                        }
                    }
                }
                setResult(frames[sp], t == BlobMsgType.ReturnSuccess, m.data);
            } else if (t == BlobMsgType.Snapshot) {
                if (regionOpen) revert UnsupportedShape("nested Snapshot regions");
                regionOpen = true;
                regionFrame = frames[sp - 1];
                regionStart = _frameChildCount(curTx, regionFrame);
            } else if (t == BlobMsgType.Revert) {
                // Codec guarantees the Revert arrives at the Snapshot's stack depth,
                // which in a linear walk means the same frame.
                uint256 count = _frameChildCount(curTx, regionFrame);
                if (count == regionStart) revert UnsupportedShape("empty Snapshot region");
                uint256 firstChild = _frameChild(curTx, regionFrame, regionStart);
                setRevertSpan(firstChild, uint16(count - regionStart));
                regionOpen = false;
            } else if (t == BlobMsgType.FinishCrossChainTransaction) {
                inTx = false;
                sp = 0;
            } else if (t == BlobMsgType.CloseBlobStream) {
                if (inTx) revert UnsupportedShape("CloseBlobStream inside a transaction");
                setClose(_txs.length, _chainOps.length);
            }
        }
    }

    function _frameChildCount(uint256 txId, uint256 frame) internal view returns (uint256) {
        return frame == ROOT_FRAME ? _txs[txId].rootCalls.length : _nodes[frame].children.length;
    }

    function _frameChild(uint256 txId, uint256 frame, uint256 idx) internal view returns (uint256) {
        return frame == ROOT_FRAME ? _txs[txId].rootCalls[idx] : _nodes[frame].children[idx];
    }

    // ──────────────────────────────────────────────
    //  IR → Messages (emitter)
    // ──────────────────────────────────────────────

    /// @notice Emits the canonical message list for the stored forest. For an IR
    ///         built by `fromMessages` this reproduces the input exactly; for an IR
    ///         built by TableStitcher it IS the Table→Blob direction.
    function toMessages() external view returns (BlobMessage[] memory) {
        uint256 regions = 0;
        for (uint256 i = 0; i < _nodes.length; i++) {
            if (_nodes[i].revertSpan > 0) regions++;
        }
        MsgList memory l =
            Msg.list(2 * _nodes.length + 2 * regions + 2 * _txs.length + _chainOps.length + (hasClose ? 1 : 0));

        uint256 opIdx = 0;
        bool closeEmitted = false;
        for (uint256 txIdx = 0; txIdx <= _txs.length; txIdx++) {
            // Emit everything positioned before transaction `txIdx`, in original
            // order: ops with txsBefore == txIdx interleaved with the close marker
            // at its recorded op offset.
            while (true) {
                if (hasClose && !closeEmitted && closeTxsBefore == txIdx && closeOpsBefore == opIdx) {
                    Msg.push(l, Msg.closeBlobStream());
                    closeEmitted = true;
                } else if (opIdx < _chainOps.length && _chainOps[opIdx].txsBefore == txIdx) {
                    Msg.push(l, Msg.chainOperation(_chainOps[opIdx].chainId, _chainOps[opIdx].operations));
                    opIdx++;
                } else {
                    break;
                }
            }
            if (txIdx < _txs.length) {
                _emitTx(l, txIdx);
            }
        }
        return Msg.done(l);
    }

    function _emitTx(MsgList memory l, uint256 txIdx) internal view {
        TxSpec storage t = _txs[txIdx];
        Msg.push(l, Msg.initiate(t.originChain, t.txData));
        _emitSiblings(l, t.rootCalls);
        Msg.push(l, Msg.finish());
    }

    /// @notice Emits a run of sibling calls, wrapping `revertSpan` groups in
    ///         Snapshot … Revert brackets.
    function _emitSiblings(MsgList memory l, uint256[] storage siblings) internal view {
        uint256 regionEnd = type(uint256).max; // sibling index the active region closes after
        for (uint256 i = 0; i < siblings.length; i++) {
            CallNode storage n = _nodes[siblings[i]];
            if (n.revertSpan > 0) {
                Msg.push(l, Msg.snapshot());
                regionEnd = i + n.revertSpan - 1;
            }
            _emitSubtree(l, siblings[i]);
            if (regionEnd == i) {
                Msg.push(l, Msg.revertMarker());
                regionEnd = type(uint256).max;
            }
        }
    }

    function _emitSubtree(MsgList memory l, uint256 nodeId) internal view {
        CallNode storage n = _nodes[nodeId];
        if (n.isStatic) {
            Msg.push(l, Msg.staticCall(n.toChain, n.fromAddress, n.toAddress, n.gas, n.data));
        } else {
            Msg.push(l, Msg.call(n.toChain, n.fromAddress, n.toAddress, n.value, n.gas, n.data));
        }
        _emitSiblings(l, n.children);
        Msg.push(l, n.success ? Msg.returnSuccess(n.returnData) : Msg.returnFail(n.returnData));
    }
}
