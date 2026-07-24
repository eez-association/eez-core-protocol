// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlobMessage, BlobMsgType} from "./BlobMessages.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  BlobCodec — wire codec for the standardized message format (version 00).
//
//  The logical stream is `blobPortion ‖ callDataTail`: the blob portion starts
//  with the reserved version byte, ends at its `CloseBlobStream` marker (any
//  bytes after it are zero padding), and the stream resumes in the callData
//  tail, where `CloseBlobStream` is invalid.
//
//  Wire conventions (spec §1.1): scalars little-endian fixed-width, `address`
//  raw 20 bytes, `bytes` fields protobuf-style (varint length + payload).
//
//  `decode` enforces the §5 validity conditions it can see at the byte layer:
//  version byte, known types, no truncation, exactly-one CloseBlobStream,
//  zeroed padding, bracket discipline over the context stack (condition 6) and
//  message placement (condition 7). Minimal varint encodings are NOT enforced
//  (condition 8). A violation reverts with a typed error — a malformed stream
//  is rejected whole.
// ─────────────────────────────────────────────────────────────────────────────

library BlobCodec {
    uint8 internal constant PROTOCOL_VERSION = 0x00;
    uint256 internal constant MAX_DEPTH = 64; // context-stack / snapshot-stack capacity

    error EmptyStream();
    error UnknownProtocolVersion(uint8 version);
    error InvalidMessageType(uint8 typeByte);
    error TruncatedStream();
    error VarintTooLong();
    error CloseBlobStreamMissing();
    error DuplicateCloseBlobStream();
    error CloseBlobStreamInCallData();
    error NonZeroPadding(uint256 offset);
    error NestedTransaction();
    error MessageOutsideTransaction(BlobMsgType msgType);
    error ChainOperationInsideTransaction();
    error ReturnWithoutOpenCall();
    error ReturnCrossesSnapshot();
    error RevertWithoutSnapshot();
    error RevertWithOpenCall();
    error FinishWithOpenCall();
    error FinishWithOpenSnapshot();
    error UnclosedBracket();
    error DepthLimitExceeded();

    // ──────────────────────────────────────────────
    //  Encoding
    // ──────────────────────────────────────────────

    /// @notice Encodes `msgs` into the two physical segments of the logical stream.
    ///         Messages up to and including the (single) `CloseBlobStream` land in
    ///         `blobPortion` (prefixed with the version byte); messages after it land
    ///         in `callDataTail`. Structural validity is NOT checked here — feed the
    ///         result to `decode` for that (encode→decode is the round-trip check).
    function encode(BlobMessage[] memory msgs)
        internal
        pure
        returns (bytes memory blobPortion, bytes memory callDataTail)
    {
        blobPortion = abi.encodePacked(PROTOCOL_VERSION);
        bool closed = false;
        for (uint256 i = 0; i < msgs.length; i++) {
            bytes memory enc = encodeOne(msgs[i]);
            if (closed) {
                callDataTail = bytes.concat(callDataTail, enc);
            } else {
                blobPortion = bytes.concat(blobPortion, enc);
            }
            if (msgs[i].msgType == BlobMsgType.CloseBlobStream) {
                closed = true;
            }
        }
    }

    /// @notice Wire encoding of a single message (type byte + fields in wire order).
    function encodeOne(BlobMessage memory m) internal pure returns (bytes memory) {
        BlobMsgType t = m.msgType;
        if (t == BlobMsgType.ChainOperation || t == BlobMsgType.InitiateCrossChainTransaction) {
            return abi.encodePacked(uint8(t), _le64(m.chainId), _lenPrefixed(m.data));
        }
        if (t == BlobMsgType.Call) {
            return abi.encodePacked(
                uint8(t), _le64(m.chainId), m.fromAddress, m.toAddress, _le256(m.value), _lenPrefixed(m.data)
            );
        }
        if (t == BlobMsgType.StaticCall) {
            return abi.encodePacked(uint8(t), _le64(m.chainId), m.fromAddress, m.toAddress, _lenPrefixed(m.data));
        }
        if (t == BlobMsgType.ReturnSuccess || t == BlobMsgType.ReturnFail) {
            return abi.encodePacked(uint8(t), _lenPrefixed(m.data));
        }
        // Bare markers: CloseBlobStream, Snapshot, Revert, FinishCrossChainTransaction.
        require(t != BlobMsgType.Invalid, "BlobCodec: cannot encode Invalid");
        return abi.encodePacked(uint8(t));
    }

    // ──────────────────────────────────────────────
    //  Decoding + validation
    // ──────────────────────────────────────────────

    struct DecodeState {
        BlobMessage[] msgs;
        uint256 count;
        uint64[] ctxStack; // chain-id context stack (§1.2)
        uint256 sp;
        uint256[] snapDepth; // context-stack depth each open Snapshot was taken at
        uint256 snapSp;
        bool closeSeen;
    }

    /// @notice Decodes and validates the full logical stream. Reverts (typed) on any
    ///         §5 violation visible at this layer; returns the message list otherwise.
    function decode(bytes memory blobPortion, bytes memory callDataTail)
        internal
        pure
        returns (BlobMessage[] memory msgs)
    {
        if (blobPortion.length == 0) revert EmptyStream();
        if (uint8(blobPortion[0]) != PROTOCOL_VERSION) revert UnknownProtocolVersion(uint8(blobPortion[0]));

        DecodeState memory s;
        s.msgs = new BlobMessage[](16);
        s.ctxStack = new uint64[](MAX_DEPTH);
        s.snapDepth = new uint256[](MAX_DEPTH);

        _decodeSegment(s, blobPortion, 1, true);
        if (!s.closeSeen) revert CloseBlobStreamMissing();
        _decodeSegment(s, callDataTail, 0, false);

        if (s.sp != 0 || s.snapSp != 0) revert UnclosedBracket();

        msgs = new BlobMessage[](s.count);
        for (uint256 i = 0; i < s.count; i++) {
            msgs[i] = s.msgs[i];
        }
    }

    /// @notice Convenience for tests operating on a single unsplit byte stream
    ///         (no callData tail).
    function decodeStream(bytes memory stream) internal pure returns (BlobMessage[] memory) {
        return decode(stream, "");
    }

    function _decodeSegment(DecodeState memory s, bytes memory seg, uint256 pos, bool isBlobPortion) private pure {
        while (pos < seg.length) {
            uint8 typeByte = uint8(seg[pos]);
            if (typeByte == 0 || typeByte > uint8(BlobMsgType.FinishCrossChainTransaction)) {
                revert InvalidMessageType(typeByte);
            }
            BlobMsgType t = BlobMsgType(typeByte);
            pos++;

            if (t == BlobMsgType.CloseBlobStream) {
                if (!isBlobPortion) revert CloseBlobStreamInCallData();
                if (s.closeSeen) revert DuplicateCloseBlobStream();
                s.closeSeen = true;
                _push(s, _marker(t));
                // Everything after the marker up to the end of the blob portion is
                // padding and MUST be zeroed (§2.1).
                for (uint256 i = pos; i < seg.length; i++) {
                    if (seg[i] != 0) revert NonZeroPadding(i);
                }
                return;
            }

            BlobMessage memory m;
            m.msgType = t;
            if (t == BlobMsgType.ChainOperation || t == BlobMsgType.InitiateCrossChainTransaction) {
                (m.chainId, pos) = _readU64le(seg, pos);
                (m.data, pos) = _readBytes(seg, pos);
            } else if (t == BlobMsgType.Call) {
                (m.chainId, pos) = _readU64le(seg, pos);
                (m.fromAddress, pos) = _readAddress(seg, pos);
                (m.toAddress, pos) = _readAddress(seg, pos);
                (m.value, pos) = _readU256le(seg, pos);
                (m.data, pos) = _readBytes(seg, pos);
            } else if (t == BlobMsgType.StaticCall) {
                (m.chainId, pos) = _readU64le(seg, pos);
                (m.fromAddress, pos) = _readAddress(seg, pos);
                (m.toAddress, pos) = _readAddress(seg, pos);
                (m.data, pos) = _readBytes(seg, pos);
            } else if (t == BlobMsgType.ReturnSuccess || t == BlobMsgType.ReturnFail) {
                (m.data, pos) = _readBytes(seg, pos);
            }
            // Snapshot / Revert / Finish are bare markers — no fields.

            _validate(s, m);
            _push(s, m);
        }
    }

    /// @notice Bracket discipline (condition 6) + placement (condition 7), driven by
    ///         the context stack of §1.2.
    function _validate(DecodeState memory s, BlobMessage memory m) private pure {
        BlobMsgType t = m.msgType;
        if (t == BlobMsgType.ChainOperation) {
            if (s.sp != 0) revert ChainOperationInsideTransaction();
        } else if (t == BlobMsgType.InitiateCrossChainTransaction) {
            if (s.sp != 0) revert NestedTransaction();
            _ctxPush(s, m.chainId);
        } else if (t == BlobMsgType.Call || t == BlobMsgType.StaticCall) {
            if (s.sp == 0) revert MessageOutsideTransaction(t);
            _ctxPush(s, m.chainId);
        } else if (t == BlobMsgType.ReturnSuccess || t == BlobMsgType.ReturnFail) {
            if (s.sp < 2) revert ReturnWithoutOpenCall(); // sp == 1 means only the root context is open
            // The stack may not drop below the innermost open Snapshot's depth (§2.7).
            if (s.snapSp > 0 && s.sp - 1 < s.snapDepth[s.snapSp - 1]) revert ReturnCrossesSnapshot();
            s.sp--;
        } else if (t == BlobMsgType.Snapshot) {
            if (s.sp == 0) revert MessageOutsideTransaction(t);
            if (s.snapSp == MAX_DEPTH) revert DepthLimitExceeded();
            s.snapDepth[s.snapSp++] = s.sp;
        } else if (t == BlobMsgType.Revert) {
            if (s.snapSp == 0) revert RevertWithoutSnapshot();
            if (s.sp != s.snapDepth[s.snapSp - 1]) revert RevertWithOpenCall();
            s.snapSp--;
        } else if (t == BlobMsgType.FinishCrossChainTransaction) {
            if (s.sp == 0) revert MessageOutsideTransaction(t);
            if (s.sp > 1) revert FinishWithOpenCall();
            if (s.snapSp != 0) revert FinishWithOpenSnapshot();
            s.sp--;
        }
    }

    function _ctxPush(DecodeState memory s, uint64 chainId) private pure {
        if (s.sp == MAX_DEPTH) revert DepthLimitExceeded();
        s.ctxStack[s.sp++] = chainId;
    }

    function _marker(BlobMsgType t) private pure returns (BlobMessage memory m) {
        m.msgType = t;
    }

    function _push(DecodeState memory s, BlobMessage memory m) private pure {
        if (s.count == s.msgs.length) {
            BlobMessage[] memory grown = new BlobMessage[](s.msgs.length * 2);
            for (uint256 i = 0; i < s.count; i++) {
                grown[i] = s.msgs[i];
            }
            s.msgs = grown;
        }
        s.msgs[s.count++] = m;
    }

    // ──────────────────────────────────────────────
    //  Wire primitives
    // ──────────────────────────────────────────────

    /// @notice Little-endian fixed-width u64.
    function _le64(uint64 v) internal pure returns (bytes memory out) {
        out = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    /// @notice Little-endian fixed-width u256.
    function _le256(uint256 v) internal pure returns (bytes memory out) {
        out = new bytes(32);
        for (uint256 i = 0; i < 32; i++) {
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    /// @notice Protobuf varint (LSB group first, high bit = continuation).
    function varint(uint256 v) internal pure returns (bytes memory out) {
        require(v <= type(uint32).max, "BlobCodec: length exceeds u32");
        // Longest u32 varint is 5 bytes.
        bytes memory buf = new bytes(5);
        uint256 n = 0;
        while (v >= 0x80) {
            buf[n++] = bytes1(uint8(v & 0x7f) | 0x80);
            v >>= 7;
        }
        buf[n++] = bytes1(uint8(v));
        out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = buf[i];
        }
    }

    /// @notice `bytes` field: varint length + payload (§1.1).
    function _lenPrefixed(bytes memory payload) internal pure returns (bytes memory) {
        return bytes.concat(varint(payload.length), payload);
    }

    function _readU64le(bytes memory b, uint256 pos) private pure returns (uint64 v, uint256 newPos) {
        if (pos + 8 > b.length) revert TruncatedStream();
        for (uint256 i = 0; i < 8; i++) {
            v |= uint64(uint8(b[pos + i])) << uint64(8 * i);
        }
        newPos = pos + 8;
    }

    function _readU256le(bytes memory b, uint256 pos) private pure returns (uint256 v, uint256 newPos) {
        if (pos + 32 > b.length) revert TruncatedStream();
        for (uint256 i = 0; i < 32; i++) {
            v |= uint256(uint8(b[pos + i])) << (8 * i);
        }
        newPos = pos + 32;
    }

    function _readAddress(bytes memory b, uint256 pos) private pure returns (address a, uint256 newPos) {
        if (pos + 20 > b.length) revert TruncatedStream();
        uint160 v;
        for (uint256 i = 0; i < 20; i++) {
            v = (v << 8) | uint160(uint8(b[pos + i]));
        }
        a = address(v);
        newPos = pos + 20;
    }

    function _readVarint(bytes memory b, uint256 pos) private pure returns (uint256 v, uint256 newPos) {
        uint256 shift = 0;
        while (true) {
            if (pos >= b.length) revert TruncatedStream();
            // Lengths fit a u32: prefix is 1–5 bytes (§1.1). Non-minimal encodings
            // still decode (condition 8), but a 6th continuation byte cannot.
            if (shift > 4 * 7) revert VarintTooLong();
            uint8 c = uint8(b[pos++]);
            v |= uint256(c & 0x7f) << shift;
            if (c < 0x80) break;
            shift += 7;
        }
        newPos = pos;
    }

    function _readBytes(bytes memory b, uint256 pos) private pure returns (bytes memory out, uint256 newPos) {
        uint256 len;
        (len, pos) = _readVarint(b, pos);
        if (pos + len > b.length) revert TruncatedStream();
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = b[pos + i];
        }
        newPos = pos + len;
    }
}
