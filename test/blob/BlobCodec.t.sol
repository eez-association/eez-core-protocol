// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BlobMessage, BlobMsgType, Msg, MsgList} from "../../script/blob/BlobMessages.sol";
import {BlobCodec} from "../../script/blob/BlobCodec.sol";
import {BlobPacking} from "../../script/blob/BlobPacking.sol";

/// @notice Byte-layer tests of the message codec (wire encoding, §5 validity) and the
///         §4 field-element packing — independent of the table translation.
contract BlobCodecTest is Test {
    uint64 constant L1 = 0;
    uint64 constant L2A = 1;
    uint64 constant L2B = 2;

    address constant USER = address(0xA11CE);
    address constant TARGET_A = address(0xAAAA);
    address constant TARGET_B = address(0xBBBB);

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    /// @notice The user's reference flow: L1 → L2A, L2A → L2B, both return.
    function _exampleFlow() internal pure returns (BlobMessage[] memory) {
        MsgList memory l = Msg.list(16);
        Msg.push(l, Msg.initiate(L1, "tx-data"));
        Msg.push(l, Msg.call(L2A, USER, TARGET_A, 0, "call-a")); // from L1 (implicit)
        Msg.push(l, Msg.call(L2B, TARGET_A, TARGET_B, 0, "call-b")); // from L2A (implicit)
        Msg.push(l, Msg.returnSuccess("ret-b"));
        Msg.push(l, Msg.returnSuccess("ret-a"));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        return Msg.done(l);
    }

    function _assertMsgsEq(BlobMessage[] memory got, BlobMessage[] memory want) internal pure {
        assertEq(got.length, want.length, "message count mismatch");
        for (uint256 i = 0; i < want.length; i++) {
            assertTrue(Msg.eq(got[i], want[i]), string.concat("message mismatch at index ", vm.toString(i)));
        }
    }

    function _roundTrip(BlobMessage[] memory msgs) internal pure {
        (bytes memory blobPortion, bytes memory tail) = BlobCodec.encode(msgs);
        BlobMessage[] memory decoded = BlobCodec.decode(blobPortion, tail);
        _assertMsgsEq(decoded, msgs);
    }

    // ──────────────────────────────────────────────
    //  Round trips
    // ──────────────────────────────────────────────

    function test_roundTrip_exampleFlow() public pure {
        _roundTrip(_exampleFlow());
    }

    /// @notice Non-zero gas limits survive the wire for both call flavours.
    function test_roundTrip_callWithGasLimit() public pure {
        MsgList memory l = Msg.list(8);
        Msg.push(l, Msg.initiate(L2A, "rlp-tx"));
        Msg.push(l, Msg.call(L2B, USER, TARGET_B, 1 ether, 250_000, "bounded"));
        Msg.push(l, Msg.staticCall(L1, TARGET_B, TARGET_A, 30_000, "bounded-read"));
        Msg.push(l, Msg.returnSuccess("read-result"));
        Msg.push(l, Msg.returnSuccess("call-result"));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        _roundTrip(Msg.done(l));
    }

    function test_roundTrip_allMessageTypes() public pure {
        MsgList memory l = Msg.list(24);
        Msg.push(l, Msg.chainOperation(L2A, hex"deadbeef"));
        Msg.push(l, Msg.chainOperation(L2B, ""));
        Msg.push(l, Msg.initiate(L2A, "rlp-tx"));
        Msg.push(l, Msg.call(L1, USER, TARGET_A, 1 ether, "with-value"));
        Msg.push(l, Msg.staticCall(L2B, TARGET_A, TARGET_B, "read"));
        Msg.push(l, Msg.returnSuccess("read-result"));
        Msg.push(l, Msg.returnFail("revert-payload"));
        Msg.push(l, Msg.snapshot());
        Msg.push(l, Msg.call(L2B, USER, TARGET_B, 0, "reverted-later"));
        Msg.push(l, Msg.returnSuccess(""));
        Msg.push(l, Msg.revertMarker());
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        // Stream resumes in the callData tail after the close marker.
        Msg.push(l, Msg.chainOperation(L2A, "in-calldata-tail"));
        _roundTrip(Msg.done(l));
    }

    function test_roundTrip_largePayloadUsesMultiByteVarint() public pure {
        bytes memory big = new bytes(300); // varint(300) = 2 bytes (spec §1.1 example)
        for (uint256 i = 0; i < big.length; i++) {
            big[i] = bytes1(uint8(i));
        }
        MsgList memory l = Msg.list(4);
        Msg.push(l, Msg.chainOperation(7, big));
        Msg.push(l, Msg.closeBlobStream());
        _roundTrip(Msg.done(l));
    }

    function test_roundTrip_throughBlobPacking() public pure {
        BlobMessage[] memory msgs = _exampleFlow();
        (bytes memory blobPortion, bytes memory tail) = BlobCodec.encode(msgs);

        bytes32[][] memory blobs = BlobPacking.pack(blobPortion);
        assertEq(blobs.length, 1, "flow should fit one blob");
        assertEq(blobs[0].length, BlobPacking.FIELD_ELEMENTS_PER_BLOB, "full-size blob");

        bytes memory recovered = BlobPacking.unpack(blobs);
        assertEq(recovered.length, BlobPacking.BYTES_PER_BLOB, "padded stream length");

        BlobMessage[] memory decoded = BlobCodec.decode(recovered, tail);
        _assertMsgsEq(decoded, msgs);
    }

    function test_packing_streamSpansBlobBoundary() public pure {
        // A ChainOperation payload larger than one blob's capacity forces the
        // message to continue in the second blob (§1.1: messages may span blobs).
        bytes memory big = new bytes(BlobPacking.BYTES_PER_BLOB + 100);
        MsgList memory l = Msg.list(4);
        Msg.push(l, Msg.chainOperation(L2A, big));
        Msg.push(l, Msg.closeBlobStream());
        BlobMessage[] memory msgs = Msg.done(l);

        (bytes memory blobPortion, bytes memory tail) = BlobCodec.encode(msgs);
        bytes32[][] memory blobs = BlobPacking.pack(blobPortion);
        assertEq(blobs.length, 2, "stream should need two blobs");
        _assertMsgsEq(BlobCodec.decode(BlobPacking.unpack(blobs), tail), msgs);
    }

    function test_packing_fieldElementsAreValidScalars() public pure {
        (bytes memory blobPortion,) = BlobCodec.encode(_exampleFlow());
        bytes32[][] memory blobs = BlobPacking.pack(blobPortion);
        for (uint256 e = 0; e < blobs[0].length; e++) {
            assertEq(uint256(blobs[0][e]) >> 248, 0, "MSB of every field element must be zero");
        }
    }

    // ──────────────────────────────────────────────
    //  Wire-format details
    // ──────────────────────────────────────────────

    function test_encoding_versionByteAndLittleEndian() public pure {
        MsgList memory l = Msg.list(2);
        Msg.push(l, Msg.chainOperation(0x0102030405060708, hex"aa"));
        Msg.push(l, Msg.closeBlobStream());
        (bytes memory blobPortion,) = BlobCodec.encode(Msg.done(l));

        assertEq(uint8(blobPortion[0]), 0x00, "version byte");
        assertEq(uint8(blobPortion[1]), 2, "ChainOperation type byte");
        // u64 chain_id little-endian: least significant byte (0x08) first.
        assertEq(uint8(blobPortion[2]), 0x08, "chain_id LSB first");
        assertEq(uint8(blobPortion[9]), 0x01, "chain_id MSB last");
        assertEq(uint8(blobPortion[10]), 1, "varint length");
        assertEq(uint8(blobPortion[11]), 0xaa, "payload");
        assertEq(uint8(blobPortion[12]), 1, "CloseBlobStream marker");
        assertEq(blobPortion.length, 13, "no trailing bytes");
    }

    function test_encoding_varint300() public pure {
        bytes memory v = BlobCodec.varint(300);
        // Spec §1.1 example: varint(300) = ac 02.
        assertEq(v.length, 2);
        assertEq(uint8(v[0]), 0xac);
        assertEq(uint8(v[1]), 0x02);
    }

    function test_decoding_acceptsNonMinimalVarint() public pure {
        // Condition 8: non-minimal encodings still decode. varint(1) as 0x81 0x00.
        bytes memory stream = abi.encodePacked(
            uint8(0), // version
            uint8(2), // ChainOperation
            BlobCodec._le64(7),
            hex"8100", // non-minimal varint(1)
            hex"aa", // payload
            uint8(1) // CloseBlobStream
        );
        BlobMessage[] memory msgs = BlobCodec.decodeStream(stream);
        assertEq(msgs.length, 2);
        assertEq(msgs[0].data.length, 1);
    }

    // ──────────────────────────────────────────────
    //  Validity rejections (§5)
    // ──────────────────────────────────────────────

    function _encodeNoClose(BlobMessage[] memory msgs) internal pure returns (bytes memory blobPortion) {
        (blobPortion,) = BlobCodec.encode(msgs);
    }

    function test_reject_unknownVersion() public {
        bytes memory stream = hex"0101"; // version 01, then CloseBlobStream
        vm.expectRevert(abi.encodeWithSelector(BlobCodec.UnknownProtocolVersion.selector, 1));
        this.decodeExternal(stream, "");
    }

    function test_reject_missingCloseBlobStream() public {
        MsgList memory l = Msg.list(4);
        Msg.push(l, Msg.chainOperation(L2A, "ops"));
        bytes memory blobPortion = _encodeNoClose(Msg.done(l));
        vm.expectRevert(BlobCodec.CloseBlobStreamMissing.selector);
        this.decodeExternal(blobPortion, "");
    }

    function test_reject_typeZeroPaddingWithoutClose() public {
        // Zero bytes where a message is expected ⇒ InvalidMessageType(0), the spec's
        // reason for reserving type 0 (§2).
        bytes memory stream = abi.encodePacked(uint8(0), uint8(0));
        vm.expectRevert(abi.encodeWithSelector(BlobCodec.InvalidMessageType.selector, 0));
        this.decodeExternal(stream, "");
    }

    function test_reject_unknownType() public {
        bytes memory stream = abi.encodePacked(uint8(0), uint8(11));
        vm.expectRevert(abi.encodeWithSelector(BlobCodec.InvalidMessageType.selector, 11));
        this.decodeExternal(stream, "");
    }

    function test_reject_nonZeroPaddingAfterClose() public {
        bytes memory stream = abi.encodePacked(uint8(0), uint8(1), uint8(0), uint8(0xFF));
        vm.expectRevert(abi.encodeWithSelector(BlobCodec.NonZeroPadding.selector, 3));
        this.decodeExternal(stream, "");
    }

    function test_reject_closeInCallDataTail() public {
        bytes memory blobPortion = abi.encodePacked(uint8(0), uint8(1));
        bytes memory tail = abi.encodePacked(uint8(1));
        vm.expectRevert(BlobCodec.CloseBlobStreamInCallData.selector);
        this.decodeExternal(blobPortion, tail);
    }

    function test_reject_truncatedCall() public {
        // A Call type byte with nothing behind it.
        bytes memory blobPortion = abi.encodePacked(uint8(0), uint8(4), uint8(0x01));
        vm.expectRevert(BlobCodec.TruncatedStream.selector);
        this.decodeExternal(blobPortion, "");
    }

    function test_reject_nestedTransaction() public {
        MsgList memory l = Msg.list(4);
        Msg.push(l, Msg.initiate(L1, ""));
        Msg.push(l, Msg.initiate(L2A, ""));
        (bytes memory p, bytes memory t) = BlobCodec.encode(Msg.done(l));
        vm.expectRevert(BlobCodec.NestedTransaction.selector);
        this.decodeExternal(p, t);
    }

    function test_reject_callOutsideTransaction() public {
        MsgList memory l = Msg.list(4);
        Msg.push(l, Msg.call(L2A, USER, TARGET_A, 0, ""));
        (bytes memory p, bytes memory t) = BlobCodec.encode(Msg.done(l));
        vm.expectRevert(abi.encodeWithSelector(BlobCodec.MessageOutsideTransaction.selector, BlobMsgType.Call));
        this.decodeExternal(p, t);
    }

    function test_reject_chainOperationInsideTransaction() public {
        MsgList memory l = Msg.list(4);
        Msg.push(l, Msg.initiate(L1, ""));
        Msg.push(l, Msg.chainOperation(L2A, "ops"));
        (bytes memory p, bytes memory t) = BlobCodec.encode(Msg.done(l));
        vm.expectRevert(BlobCodec.ChainOperationInsideTransaction.selector);
        this.decodeExternal(p, t);
    }

    function test_reject_returnWithoutOpenCall() public {
        MsgList memory l = Msg.list(4);
        Msg.push(l, Msg.initiate(L1, ""));
        Msg.push(l, Msg.returnSuccess(""));
        (bytes memory p, bytes memory t) = BlobCodec.encode(Msg.done(l));
        vm.expectRevert(BlobCodec.ReturnWithoutOpenCall.selector);
        this.decodeExternal(p, t);
    }

    function test_reject_revertWithUnreturnedCall() public {
        // §5 condition 6: a Revert while a Call opened after the Snapshot is still
        // unreturned is invalid.
        MsgList memory l = Msg.list(8);
        Msg.push(l, Msg.initiate(L1, ""));
        Msg.push(l, Msg.snapshot());
        Msg.push(l, Msg.call(L2A, USER, TARGET_A, 0, ""));
        Msg.push(l, Msg.revertMarker());
        (bytes memory p, bytes memory t) = BlobCodec.encode(Msg.done(l));
        vm.expectRevert(BlobCodec.RevertWithOpenCall.selector);
        this.decodeExternal(p, t);
    }

    function test_reject_bareRevert() public {
        MsgList memory l = Msg.list(4);
        Msg.push(l, Msg.initiate(L1, ""));
        Msg.push(l, Msg.revertMarker());
        (bytes memory p, bytes memory t) = BlobCodec.encode(Msg.done(l));
        vm.expectRevert(BlobCodec.RevertWithoutSnapshot.selector);
        this.decodeExternal(p, t);
    }

    function test_reject_finishWithOpenCall() public {
        MsgList memory l = Msg.list(4);
        Msg.push(l, Msg.initiate(L1, ""));
        Msg.push(l, Msg.call(L2A, USER, TARGET_A, 0, ""));
        Msg.push(l, Msg.finish());
        (bytes memory p, bytes memory t) = BlobCodec.encode(Msg.done(l));
        vm.expectRevert(BlobCodec.FinishWithOpenCall.selector);
        this.decodeExternal(p, t);
    }

    function test_reject_finishWithOpenSnapshot() public {
        MsgList memory l = Msg.list(4);
        Msg.push(l, Msg.initiate(L1, ""));
        Msg.push(l, Msg.snapshot());
        Msg.push(l, Msg.finish());
        (bytes memory p, bytes memory t) = BlobCodec.encode(Msg.done(l));
        vm.expectRevert(BlobCodec.FinishWithOpenSnapshot.selector);
        this.decodeExternal(p, t);
    }

    function test_reject_unclosedTransactionAtStreamEnd() public {
        MsgList memory l = Msg.list(4);
        Msg.push(l, Msg.closeBlobStream());
        Msg.push(l, Msg.initiate(L1, "")); // opened in the callData tail, never finished
        (bytes memory p, bytes memory t) = BlobCodec.encode(Msg.done(l));
        vm.expectRevert(BlobCodec.UnclosedBracket.selector);
        this.decodeExternal(p, t);
    }

    function test_reject_invalidFieldElement() public {
        bytes32[][] memory blobs = new bytes32[][](1);
        blobs[0] = new bytes32[](BlobPacking.FIELD_ELEMENTS_PER_BLOB);
        blobs[0][5] = bytes32(uint256(1) << 248); // non-zero MSB — not a valid scalar
        vm.expectRevert(abi.encodeWithSelector(BlobPacking.InvalidFieldElement.selector, 0, 5));
        this.unpackExternal(blobs);
    }

    /// @dev External wrappers so `vm.expectRevert` can catch library reverts.
    function decodeExternal(bytes memory blobPortion, bytes memory tail) external pure returns (uint256) {
        return BlobCodec.decode(blobPortion, tail).length;
    }

    function unpackExternal(bytes32[][] memory blobs) external pure returns (uint256) {
        return BlobPacking.unpack(blobs).length;
    }
}
