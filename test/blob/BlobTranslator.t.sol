// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BlobTranslator} from "../../script/blob/BlobTranslator.sol";
import {BlobMessage, Msg, MsgList} from "../../script/blob/BlobMessages.sol";
import {BlobCodec} from "../../script/blob/BlobCodec.sol";
import {BlobPacking} from "../../script/blob/BlobPacking.sol";

/// @title BlobTranslatorTest
/// @notice Proves the facade's four conversions compose: blob → data → tables →
///         data → blob reproduces the input bytes exactly. Pure translation —
///         no managers, no actors, plain addresses (the actor rules are a
///         harness constraint, not a translation one).
contract BlobTranslatorTest is Test {
    uint64 constant L1 = 0;
    uint64 constant L2A = 1;
    uint64 constant L2B = 2;

    address constant DRIVER_L1 = address(0xD001);
    address constant DRIVER_A = address(0xD0A0);
    address constant ACTOR_A = address(0xA0A0);
    address constant ACTOR_B = address(0xB0B0);
    address constant ACTOR_C = address(0xC0C0); // lives on L1

    BlobTranslator tr;

    function setUp() public {
        tr = new BlobTranslator();
    }

    /// @dev Runs the full 4-leg chain on `msgs` and returns the derived tables:
    ///      encode → pack → unpack → dataToTables → tablesToData (byte-identical)
    ///      → pack (blob-identical).
    function _roundTrip(BlobMessage[] memory msgs) internal returns (BlobTranslator.Tables memory t) {
        (bytes memory blobData, bytes memory tail) = BlobCodec.encode(msgs);

        // data → blob → data: padded stream, same prefix.
        bytes32[][] memory blobs = tr.dataToBlobs(blobData);
        bytes memory unpacked = tr.blobsToData(blobs);
        assertEq(unpacked.length % BlobPacking.BYTES_PER_BLOB, 0, "unpacked stream is whole blobs");
        for (uint256 i = 0; i < blobData.length; i++) {
            assertEq(unpacked[i], blobData[i], "unpacked prefix mismatch");
        }

        // data (padded, straight from the blobs) → tables.
        t = tr.dataToTables(unpacked, tail);

        // tables → data: byte-identical to the original unpadded stream.
        (bytes memory blobData2, bytes memory tail2) = tr.tablesToData(t);
        assertEq(blobData2, blobData, "table round trip: blob bytes");
        assertEq(tail2, tail, "table round trip: callData bytes");

        // data → blob: identical blobs.
        (bytes32[][] memory blobs2, bytes memory tail3) = tr.tablesToBlobs(t);
        assertEq(tail3, tail, "tablesToBlobs tail");
        assertEq(keccak256(abi.encode(blobs2)), keccak256(abi.encode(blobs)), "repacked blobs mismatch");
    }

    function test_simpleL1Origin() public {
        MsgList memory l = Msg.list(8);
        Msg.push(l, Msg.initiate(L1, "tx-data"));
        Msg.push(l, Msg.call(L2A, DRIVER_L1, ACTOR_A, 0, abi.encodeWithSignature("doA()")));
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(42))));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());

        BlobTranslator.Tables memory t = _roundTrip(Msg.done(l));

        assertEq(t.l1Entries.length, 1, "one L1 entry (origin root call)");
        assertEq(t.l1Entries[0].destinationRollupId, L2A, "routed to L2A");
        assertEq(t.units.length, 1, "one L2 unit");
        assertEq(t.units[0].chainId, L2A);
        assertEq(t.units[0].kind, 2, "inbound delivery");
        assertTrue(t.sidecar.hasClose, "close recorded");
    }

    function test_l2OriginNestedCallback() public {
        MsgList memory l = Msg.list(8);
        Msg.push(l, Msg.initiate(L2A, "rlp-tx"));
        Msg.push(l, Msg.call(L1, DRIVER_A, ACTOR_C, 0, abi.encodeWithSignature("doC()")));
        Msg.push(l, Msg.call(L2B, ACTOR_C, ACTOR_B, 0, abi.encodeWithSignature("doB()"))); // nested: L1 → L2B
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(42))));
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(1))));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());

        BlobTranslator.Tables memory t = _roundTrip(Msg.done(l));

        assertEq(t.l1Entries.length, 1, "the L2Tx host");
        assertEq(t.l1Entries[0].proxyEntryHash, bytes32(0), "host is an L2Tx entry");
        assertEq(t.units.length, 2, "L2A origin group + L2B inbound");
        assertEq(t.units[0].chainId, L2A);
        assertEq(t.units[0].kind, 1, "origin group");
        assertEq(t.units[1].chainId, L2B);
        assertEq(t.units[1].kind, 2, "inbound delivery");
        assertEq(t.sidecar.callGasKeys.length, 1, "one L2-sourced mutable call");
        assertEq(t.sidecar.callGasValues[0], 0, "zero oracle under useGasLeft = false");
    }

    /// @notice Static read + Snapshot region + chain op + a second tx in the
    ///         callData tail — exercises every sidecar lane.
    function test_kitchenSink() public {
        MsgList memory l = Msg.list(20);
        Msg.push(l, Msg.initiate(L1, "tx-1"));
        Msg.push(l, Msg.staticCall(L2A, DRIVER_L1, ACTOR_A, abi.encodeWithSignature("readA()")));
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(7))));
        Msg.push(l, Msg.snapshot());
        Msg.push(l, Msg.call(L2A, DRIVER_L1, ACTOR_A, 0, abi.encodeWithSignature("poke()")));
        Msg.push(l, Msg.returnSuccess("ok"));
        Msg.push(l, Msg.revertMarker());
        Msg.push(l, Msg.call(L2B, DRIVER_L1, ACTOR_B, 0, abi.encodeWithSignature("commit()")));
        Msg.push(l, Msg.returnSuccess("done"));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.chainOperation(L2A, "op-bytes"));
        Msg.push(l, Msg.closeBlobStream());
        // Second transaction: rides the callData tail.
        Msg.push(l, Msg.initiate(L2A, "rlp-tx-2"));
        Msg.push(l, Msg.call(L1, DRIVER_A, ACTOR_C, 0, abi.encodeWithSignature("pay()")));
        Msg.push(l, Msg.returnSuccess("paid"));
        Msg.push(l, Msg.finish());

        BlobTranslator.Tables memory t = _roundTrip(Msg.done(l));

        assertEq(t.sidecar.txs.length, 2, "two transactions");
        assertEq(t.sidecar.statics.length, 1, "one hash-matched static call");
        assertEq(t.l1Statics.length, 1, "one L1 static pool entry");
        assertEq(t.sidecar.regionSizes.length, 1, "one Snapshot region");
        assertEq(t.sidecar.regionSizes[0], 1, "region spans one call");
        assertEq(t.sidecar.chainOps.length, 1, "one chain op");
        assertEq(t.sidecar.callGasKeys.length, 1, "tx2's L2A-sourced call");
    }
}
