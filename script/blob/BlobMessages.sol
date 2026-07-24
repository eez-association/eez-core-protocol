// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
//  BlobMessages — in-memory model of the standardized message format
//  (docs/blobs/BLOB_FORMAT_SPEC.md of eez-core-protocol, version byte 00).
//
//  One flat struct covers every message type; fields not used by a type MUST be
//  zero so two message lists can be compared with plain field equality. The
//  `Msg` library builders below always produce zeroed unused fields — build
//  messages through them.
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Wire message types. Enum order matches the spec's type bytes exactly
///         (`uint8(msgType)` IS the wire byte); type 0 is reserved-invalid so zero
///         padding never parses as a message.
enum BlobMsgType {
    Invalid, // 0  — reserved, never begins a message
    CloseBlobStream, // 1  — marker: end of the blob portion; stream resumes in callData
    ChainOperation, // 2  — chain-local ops (opaque payload)
    InitiateCrossChainTransaction, // 3  — opens a cross-chain tx bracket
    Call, // 4  — value-bearing cross-chain call
    StaticCall, // 5  — read-only cross-chain call (no value on the wire)
    ReturnSuccess, // 6  — result of the last outstanding Call/StaticCall
    ReturnFail, // 7  — the call finished by reverting on the callee
    Snapshot, // 8  — marker: opens a forced-revert region
    Revert, // 9  — marker: closes the innermost open Snapshot
    FinishCrossChainTransaction // 10 — marker: closes the tx bracket
}

/// @notice One decoded message. Per-type field usage (everything else zero):
///         - ChainOperation:                 chainId, data (= operations)
///         - InitiateCrossChainTransaction:  chainId, data (= tx_data)
///         - Call:                           chainId (= to_chain), fromAddress, toAddress, value, gas, data
///         - StaticCall:                     chainId (= to_chain), fromAddress, toAddress, gas, data
///         - ReturnSuccess / ReturnFail:     data (= return_data)
///         - markers (Close/Snapshot/Revert/Finish): none
struct BlobMessage {
    BlobMsgType msgType;
    uint64 chainId;
    address fromAddress;
    address toAddress;
    uint256 value;
    uint64 gas;
    bytes data;
}

/// @notice Growable message list for scenario authoring (memory arrays can't push).
struct MsgList {
    BlobMessage[] items;
    uint256 len;
}

/// @notice Builders for every message type + the `MsgList` push helpers.
library Msg {
    function _blank(BlobMsgType t) private pure returns (BlobMessage memory m) {
        m.msgType = t;
    }

    function chainOperation(uint64 chainId, bytes memory operations) internal pure returns (BlobMessage memory m) {
        m = _blank(BlobMsgType.ChainOperation);
        m.chainId = chainId;
        m.data = operations;
    }

    function initiate(uint64 chainId, bytes memory txData) internal pure returns (BlobMessage memory m) {
        m = _blank(BlobMsgType.InitiateCrossChainTransaction);
        m.chainId = chainId;
        m.data = txData;
    }

    /// @notice Call with all remaining gas forwarded (`gas = 0`).
    function call(uint64 toChain, address fromAddress, address toAddress, uint256 value, bytes memory data)
        internal
        pure
        returns (BlobMessage memory m)
    {
        return call(toChain, fromAddress, toAddress, value, 0, data);
    }

    function call(
        uint64 toChain,
        address fromAddress,
        address toAddress,
        uint256 value,
        uint64 callGas,
        bytes memory data
    )
        internal
        pure
        returns (BlobMessage memory m)
    {
        m = _blank(BlobMsgType.Call);
        m.chainId = toChain;
        m.fromAddress = fromAddress;
        m.toAddress = toAddress;
        m.value = value;
        m.gas = callGas;
        m.data = data;
    }

    /// @notice Static call with all remaining gas forwarded (`gas = 0`).
    function staticCall(uint64 toChain, address fromAddress, address toAddress, bytes memory data)
        internal
        pure
        returns (BlobMessage memory m)
    {
        return staticCall(toChain, fromAddress, toAddress, 0, data);
    }

    function staticCall(uint64 toChain, address fromAddress, address toAddress, uint64 callGas, bytes memory data)
        internal
        pure
        returns (BlobMessage memory m)
    {
        m = _blank(BlobMsgType.StaticCall);
        m.chainId = toChain;
        m.fromAddress = fromAddress;
        m.toAddress = toAddress;
        m.gas = callGas;
        m.data = data;
    }

    function returnSuccess(bytes memory returnData) internal pure returns (BlobMessage memory m) {
        m = _blank(BlobMsgType.ReturnSuccess);
        m.data = returnData;
    }

    function returnFail(bytes memory returnData) internal pure returns (BlobMessage memory m) {
        m = _blank(BlobMsgType.ReturnFail);
        m.data = returnData;
    }

    function snapshot() internal pure returns (BlobMessage memory m) {
        m = _blank(BlobMsgType.Snapshot);
    }

    function revertMarker() internal pure returns (BlobMessage memory m) {
        m = _blank(BlobMsgType.Revert);
    }

    function finish() internal pure returns (BlobMessage memory m) {
        m = _blank(BlobMsgType.FinishCrossChainTransaction);
    }

    function closeBlobStream() internal pure returns (BlobMessage memory m) {
        m = _blank(BlobMsgType.CloseBlobStream);
    }

    // ── MsgList helpers ──

    function list(uint256 capacity) internal pure returns (MsgList memory l) {
        l.items = new BlobMessage[](capacity);
    }

    function push(MsgList memory l, BlobMessage memory m) internal pure {
        require(l.len < l.items.length, "MsgList: capacity exceeded");
        l.items[l.len++] = m;
    }

    /// @notice Finalizes the list into a right-sized array.
    function done(MsgList memory l) internal pure returns (BlobMessage[] memory out) {
        out = new BlobMessage[](l.len);
        for (uint256 i = 0; i < l.len; i++) {
            out[i] = l.items[i];
        }
    }

    // ── Equality ──

    function eq(BlobMessage memory a, BlobMessage memory b) internal pure returns (bool) {
        return a.msgType == b.msgType && a.chainId == b.chainId && a.fromAddress == b.fromAddress
            && a.toAddress == b.toAddress && a.value == b.value && a.gas == b.gas
            && keccak256(a.data) == keccak256(b.data);
    }
}
