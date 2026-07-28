// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ExpectedL1ToL2Call, L2ToL1Call} from "../interfaces/IEEZ.sol";

/// @title ExpectedL1ToL2CallTransient
/// @notice Holds one `ExpectedL1ToL2Call[]` in transient storage, so a table can outlive an external
///         boundary without ever being SSTOREd. Reverts roll it back exactly like storage.
/// @dev Layout: a length word at `_EXPECTED_L1_TO_L2_CALLS_SLOT`, then one row per derived base. Each row is a flat slot
///      walk with length-prefixed dynamic regions, so a load replays what the store wrote:
///
///        slot+0  expectedL1toL2Hash
///        slot+1  revertedOrStaticRollingHash
///        slot+2  success (0/1)
///        slot+3  returnData.length L          ── then ceil(L/32) data words
///        slot+x  l2ToL1Calls.length N         ── then N encoded calls
///        per call (3 fixed slots + data):
///          header = revertNextNCalls | isStatic | sourceRollupId | sourceAddress  (bit offsets 0/16/17/81)
///          target = targetAddress | gas                                          (bit offsets 0/160)
///          value
///          data.length M                      ── then ceil(M/32) data words
///
///      Packing the six small scalars into two words (241 and 224 bits used) costs 3 words per call
///      plus its length word, against 7 unpacked.
abstract contract ExpectedL1ToL2CallTransient {
    /// @dev ERC-7201 namespaced, so the walk never collides with other transient regions.
    uint256 private constant _EXPECTED_L1_TO_L2_CALLS_SLOT = uint256(
        keccak256(abi.encode(uint256(keccak256("eez.transient.ExpectedL1ToL2Call")) - 1)) & ~bytes32(uint256(0xff))
    );

    // Bit offsets within the two packed `L2ToL1Call` words.
    uint256 private constant IS_STATIC_OFFSET = 16; // header
    uint256 private constant SOURCE_ROLLUP_OFFSET = 17; // header
    uint256 private constant SOURCE_ADDR_OFFSET = 81; // header
    uint256 private constant GAS_OFFSET = 160; // target

    // Row i lives at its own base, spaced like a `mapping(uint256 => ...)` slot, so a
    // variable-length row never has to be walked past to address row i.

    /// @notice Replace the table with `calls`.
    /// @dev The length word is authoritative, so a shorter table strands the previous one's tail rows.
    function _setTransientExpectedL1toL2Calls(ExpectedL1ToL2Call[] calldata calls) internal {
        uint256 n = calls.length;
        _tstore(_EXPECTED_L1_TO_L2_CALLS_SLOT, n);
        for (uint256 i = 0; i < n; i++) {
            _store(_elementBase(_EXPECTED_L1_TO_L2_CALLS_SLOT, i), calls[i]);
        }
    }

    /// @notice Empty the table — one `tstore` of the length word.
    function _clearTransientExpectedL1toL2Calls() internal {
        _tstore(_EXPECTED_L1_TO_L2_CALLS_SLOT, 0);
    }

    /// @notice Row count; 0 means nothing is held. One `tload`.
    function _transientExpectedL1toL2CallsLength() internal view returns (uint256) {
        return _tload(_EXPECTED_L1_TO_L2_CALLS_SLOT);
    }

    /// @notice Deserialize every row.
    function _transientExpectedL1toL2Calls() internal view returns (ExpectedL1ToL2Call[] memory calls) {
        uint256 n = _tload(_EXPECTED_L1_TO_L2_CALLS_SLOT);
        calls = new ExpectedL1ToL2Call[](n);
        for (uint256 i = 0; i < n; i++) {
            (calls[i],) = _load(_elementBase(_EXPECTED_L1_TO_L2_CALLS_SLOT, i));
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Per-row (de)serialization over a cursor.
    // ─────────────────────────────────────────────────────────────────────────

    function _store(uint256 slot, ExpectedL1ToL2Call calldata c) private returns (uint256) {
        _tstore(slot, uint256(c.expectedL1toL2Hash));
        _tstore(slot + 1, uint256(c.revertedOrStaticRollingHash));
        _tstore(slot + 2, c.success ? 1 : 0);

        slot = _storeBytes(slot + 3, c.returnData);

        uint256 n = c.l2ToL1Calls.length;
        _tstore(slot++, n);
        for (uint256 i = 0; i < n; i++) {
            slot = _storeCall(slot, c.l2ToL1Calls[i]);
        }
        return slot;
    }

    function _load(uint256 slot) private view returns (ExpectedL1ToL2Call memory c, uint256) {
        c.expectedL1toL2Hash = bytes32(_tload(slot));
        c.revertedOrStaticRollingHash = bytes32(_tload(slot + 1));
        c.success = _tload(slot + 2) != 0;

        (c.returnData, slot) = _loadBytes(slot + 3);

        uint256 n = _tload(slot++);
        c.l2ToL1Calls = new L2ToL1Call[](n);
        for (uint256 i = 0; i < n; i++) {
            (c.l2ToL1Calls[i], slot) = _loadCall(slot);
        }
        return (c, slot);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Per-`L2ToL1Call` (de)serialization — six scalars packed into two words.
    // ─────────────────────────────────────────────────────────────────────────

    function _storeCall(uint256 slot, L2ToL1Call calldata call) private returns (uint256) {
        _tstore(
            slot,
            uint256(call.revertNextNCalls) | (call.isStatic ? uint256(1) << IS_STATIC_OFFSET : 0)
                | (uint256(call.sourceRollupId) << SOURCE_ROLLUP_OFFSET)
                | (uint256(uint160(call.sourceAddress)) << SOURCE_ADDR_OFFSET)
        );
        _tstore(slot + 1, uint256(uint160(call.targetAddress)) | (uint256(call.gas) << GAS_OFFSET));
        _tstore(slot + 2, call.value);
        return _storeBytes(slot + 3, call.data);
    }

    function _loadCall(uint256 slot) private view returns (L2ToL1Call memory call, uint256) {
        uint256 header = _tload(slot);
        call.revertNextNCalls = uint16(header);
        call.isStatic = (header >> IS_STATIC_OFFSET) & 1 != 0;
        call.sourceRollupId = uint64(header >> SOURCE_ROLLUP_OFFSET);
        call.sourceAddress = address(uint160(header >> SOURCE_ADDR_OFFSET));

        uint256 target = _tload(slot + 1);
        call.targetAddress = address(uint160(target));
        call.gas = uint64(target >> GAS_OFFSET);

        call.value = _tload(slot + 2);
        (call.data, slot) = _loadBytes(slot + 3);
        return (call, slot);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Length-prefixed bytes: length word, then ceil(len/32) full words.
    // ─────────────────────────────────────────────────────────────────────────

    function _storeBytes(uint256 slot, bytes calldata b) private returns (uint256) {
        _tstore(slot++, b.length);
        assembly ("memory-safe") {
            // A trailing partial word pulls in adjacent calldata; harmless, since every reader
            // of the reconstructed blob goes by its `len`.
            for { let off := b.offset } lt(off, add(b.offset, b.length)) { off := add(off, 32) } {
                tstore(slot, calldataload(off))
                slot := add(slot, 1)
            }
        }
        return slot;
    }

    function _loadBytes(uint256 slot) private view returns (bytes memory b, uint256) {
        uint256 len = _tload(slot++);
        assembly ("memory-safe") {
            b := mload(0x40) // allocate by hand: every word gets overwritten, so skip the zero-fill
            mstore(b, len)
            let ptr := add(b, 32)
            let end := add(ptr, and(add(len, 31), not(31)))
            for {} lt(ptr, end) { ptr := add(ptr, 32) } {
                mstore(ptr, tload(slot))
                slot := add(slot, 1)
            }
            mstore(0x40, end) // bump the free pointer past the buffer
        }
        return (b, slot);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Slot primitives.
    // ─────────────────────────────────────────────────────────────────────────

    function _tstore(uint256 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(uint256 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /// @dev Per-index base, spaced exactly like a `mapping(uint256 => ...)` slot. Hashes out of the
    ///      0x00-0x40 scratch space, so nothing is allocated.
    function _elementBase(uint256 base, uint256 index) private pure returns (uint256 slot) {
        assembly ("memory-safe") {
            mstore(0x00, index)
            mstore(0x20, base)
            slot := keccak256(0x00, 0x40)
        }
    }
}
