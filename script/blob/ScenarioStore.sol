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
//  Static calls may nest across chains, including under reentrant static reads.
//  Successful children of failed frames and nested rollback regions are preserved.
//  Static descendants must remain static; calls must cross chains; rollback regions
//  are nonempty and stay within their frame. CloseBlobStream sits between transactions.
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

/// @notice Explicit rollback boundaries; multiple regions may start at one call.
struct RevertRegion {
    uint256 firstNode;
    uint256 lastNode;
    uint16 span;
}

contract ScenarioStore {
    CallNode[] internal _nodes;
    RevertRegion[] internal _regions;
    mapping(uint256 => uint256) internal _parent;
    mapping(uint256 => uint256) internal _nodeTx;
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

    /// @notice Every static node in DFS order, including descendants. The sidecar
    ///         records the static tree, including portions with no executing destination.
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
        sizes = new uint16[](_regions.length);
        for (uint256 i; i < sizes.length; i++) {
            sizes[i] = _regions[i].span;
        }
    }

    function getRegions() external view returns (RevertRegion[] memory) {
        return _regions;
    }

    function addRevertRegion(uint256 firstNode, uint256 lastNode, uint16 span) public {
        if (
            span == 0 || firstNode >= _nodes.length || lastNode >= _nodes.length
                || _nodeTx[firstNode] != _nodeTx[lastNode] || _parent[firstNode] != _parent[lastNode]
        ) {
            revert ParseInvariant("invalid rollback region");
        }
        uint256 frame = _parent[firstNode];
        uint256 txId = _nodeTx[firstNode];
        uint256 count = _frameChildCount(txId, frame);
        bool found;
        for (uint256 i; i < count; i++) {
            if (_frameChild(txId, frame, i) == firstNode) {
                if (i + span > count || _frameChild(txId, frame, i + span - 1) != lastNode) {
                    revert ParseInvariant("rollback region span mismatch");
                }
                found = true;
                break;
            }
        }
        if (!found) revert ParseInvariant("rollback region start missing");
        _regions.push(RevertRegion(firstNode, lastNode, span));
        if (span > _nodes[firstNode].revertSpan) _nodes[firstNode].revertSpan = span;
    }

    /// @dev DFS over every static node, including its children.
    function _collectStatics(
        uint256[] storage siblings,
        uint256[] memory buf,
        uint256 n
    )
        internal
        view
        returns (uint256)
    {
        for (uint256 i = 0; i < siblings.length; i++) {
            CallNode storage node = _nodes[siblings[i]];
            if (node.isStatic) {
                buf[n++] = siblings[i];
            }
            n = _collectStatics(node.children, buf, n);
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
        _parent[nodeId] = parentId;
        _nodeTx[nodeId] = txId;
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
            _txs[txId].rootCalls.push(nodeId);
        } else {
            CallNode storage parent = _nodes[parentId];
            if (parent.isStatic) {
                if (!p.isStatic) revert UnsupportedShape("mutable call inside a static call");
            }
            parent.children.push(nodeId);
        }
    }

    function setResult(uint256 nodeId, bool success, bytes memory returnData) public {
        _nodes[nodeId].success = success;
        _nodes[nodeId].returnData = returnData;
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
    ///         cross-chain/static constraints on top).
    function fromMessages(BlobMessage[] calldata msgs) external {
        if (_nodes.length != 0 || _txs.length != 0) revert ParseInvariant("store already populated");

        // Frame stack: ROOT_FRAME sentinel at the bottom of each tx, node ids above.
        // Capacity matches the codec's context stack — decode enforces the depth.
        uint256[] memory frames = new uint256[](MAX_CALL_DEPTH);
        uint64[] memory chains = new uint64[](MAX_CALL_DEPTH); // executing chain per frame level
        uint256 sp = 0;
        bool inTx = false;
        uint256 curTx = 0;

        uint256[] memory regionFrames = new uint256[](msgs.length);
        uint256[] memory regionStarts = new uint256[](msgs.length);
        uint256[] memory regionIds = new uint256[](msgs.length);
        uint256 regionDepth;

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
                setResult(frames[sp], t == BlobMsgType.ReturnSuccess, m.data);
            } else if (t == BlobMsgType.Snapshot) {
                regionFrames[regionDepth] = frames[sp - 1];
                regionStarts[regionDepth] = _frameChildCount(curTx, frames[sp - 1]);
                regionIds[regionDepth++] = _regions.length;
                _regions.push();
            } else if (t == BlobMsgType.Revert) {
                uint256 depth = --regionDepth;
                uint256 frame = regionFrames[depth];
                uint256 start = regionStarts[depth];
                uint256 count = _frameChildCount(curTx, frame);
                if (count == start) revert UnsupportedShape("empty Snapshot region");
                if (count - start > type(uint16).max) revert UnsupportedShape("Snapshot region too large");
                uint256 first = _frameChild(curTx, frame, start);
                uint16 span = uint16(count - start);
                _regions[regionIds[depth]] = RevertRegion(first, _frameChild(curTx, frame, count - 1), span);
                if (span > _nodes[first].revertSpan) _nodes[first].revertSpan = span;
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
        uint256 regions = _regions.length;
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
        uint256[] memory ends = new uint256[](_regions.length);
        uint256 depth;
        for (uint256 i; i < siblings.length; i++) {
            for (uint256 r; r < _regions.length; r++) {
                if (_regions[r].firstNode == siblings[i]) {
                    Msg.push(l, Msg.snapshot());
                    ends[depth++] = _regions[r].lastNode;
                }
            }
            _emitSubtree(l, siblings[i]);
            while (depth > 0 && ends[depth - 1] == siblings[i]) {
                Msg.push(l, Msg.revertMarker());
                depth--;
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
