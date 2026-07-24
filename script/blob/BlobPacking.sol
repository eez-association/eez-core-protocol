// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
//  BlobPacking — spec §4: the logical byte stream ⇄ EIP-4844 blob field elements.
//
//  Each 32-byte field element carries 31 bytes of stream data read least-
//  significant-byte first; the 32nd (most significant) byte is unused and MUST
//  be zero, keeping every element below the BLS12-381 modulus. A blob is 4096
//  elements (126,976 useful bytes); the stream spans blobs in order and the
//  unused capacity after `CloseBlobStream` stays zero (the codec verifies the
//  padding bytes).
// ─────────────────────────────────────────────────────────────────────────────

library BlobPacking {
    uint256 internal constant FIELD_ELEMENTS_PER_BLOB = 4096;
    uint256 internal constant BYTES_PER_ELEMENT = 31;
    uint256 internal constant BYTES_PER_BLOB = FIELD_ELEMENTS_PER_BLOB * BYTES_PER_ELEMENT; // 126,976

    error InvalidFieldElement(uint256 blobIndex, uint256 elementIndex);
    error EmptyBlobStream();

    /// @notice Packs the blob portion of the logical stream into full-size blobs
    ///         (zero elements pad the unused tail — the decoder treats post-close
    ///         zero bytes as padding).
    function pack(bytes memory stream) internal pure returns (bytes32[][] memory blobs) {
        if (stream.length == 0) revert EmptyBlobStream();
        uint256 nBlobs = (stream.length + BYTES_PER_BLOB - 1) / BYTES_PER_BLOB;
        blobs = new bytes32[][](nBlobs);
        uint256 pos = 0;
        for (uint256 b = 0; b < nBlobs; b++) {
            bytes32[] memory elements = new bytes32[](FIELD_ELEMENTS_PER_BLOB);
            for (uint256 e = 0; e < FIELD_ELEMENTS_PER_BLOB && pos < stream.length; e++) {
                uint256 v = 0;
                for (uint256 k = 0; k < BYTES_PER_ELEMENT && pos < stream.length; (k++, pos++)) {
                    // Stream byte k sits at byte significance k (LSB-first physical order).
                    v |= uint256(uint8(stream[pos])) << (8 * k);
                }
                elements[e] = bytes32(v);
            }
            blobs[b] = elements;
        }
    }

    /// @notice Recovers the logical byte stream: 31 data bytes per element, LSB first,
    ///         dropping the (required-zero) most significant byte; blobs concatenate in
    ///         order. The result includes any zero padding — the codec skips it.
    function unpack(bytes32[][] memory blobs) internal pure returns (bytes memory stream) {
        stream = new bytes(blobs.length * BYTES_PER_BLOB);
        uint256 pos = 0;
        for (uint256 b = 0; b < blobs.length; b++) {
            require(blobs[b].length == FIELD_ELEMENTS_PER_BLOB, "BlobPacking: blob must have 4096 elements");
            for (uint256 e = 0; e < FIELD_ELEMENTS_PER_BLOB; e++) {
                uint256 v = uint256(blobs[b][e]);
                // Encoding-layer validity (§5 condition 1): last byte must be zero.
                if (v >> (8 * BYTES_PER_ELEMENT) != 0) revert InvalidFieldElement(b, e);
                for (uint256 k = 0; k < BYTES_PER_ELEMENT; (k++, pos++)) {
                    stream[pos] = bytes1(uint8(v >> (8 * k)));
                }
            }
        }
    }
}
