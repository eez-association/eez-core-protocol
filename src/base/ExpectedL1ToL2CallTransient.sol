// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEEZ, ExpectedL1ToL2Call, L2ToL1Call} from "../interfaces/IEEZ.sol";

/// @title ExpectedL1ToL2CallTransient
/// @notice Focused playground for round-tripping a single `ExpectedL1ToL2Call` through
///         transient storage with hand-rolled `tstore` / `tload` assembly.
/// @dev Implements `IEEZ` only to satisfy the interface — every interface method reverts
///      `NotSupported`. The real subject of this contract is `store` / `load`.
///
///      Transient layout is a flat, sequential slot walk from `BASE_SLOT`; a single cursor
///      advances and dynamic regions are length-prefixed so `load` replays the same walk.
///      Optimised for slot count and `tstore`/`tload` op count:
///
///        slot+0  expectedL1toL2Hash
///        slot+1  revertedOrStaticRollingHash
///        slot+2  success (0/1)
///        slot+3  returnData.length L          ── then ceil(L/32) data words
///        slot+x  l2ToL1Calls.length N         ── then N encoded calls
///        per call (4 fixed slots + data):
///          header = revertNextNCalls | isStatic | sourceRollupId | sourceAddress  (packed at bit offsets 0/16/17/81)
///          targetAddress
///          value
///          data.length M                      ── then ceil(M/32) data words
///
///      Packing the four small scalars into one `header` word (248 bits used) turns each
///      call's fixed cost from 6 transient words down to 3 + the length word.
contract ExpectedL1ToL2CallTransient is IEEZ {
    error NotSupported();
    error IndexOutOfBounds();

    /// @dev Namespaced base so the walk never collides with other transient regions.
    uint256 private constant BASE_SLOT = uint256(keccak256("eez.transient.ExpectedL1ToL2Call.v1"));

    // Bit offsets for the packed `L2ToL1Call` header word.
    uint256 private constant ISTATIC_OFFSET = 16;
    uint256 private constant ROLLUP_OFFSET = 17;
    uint256 private constant SOURCE_ADDR_OFFSET = 81;

    // ─────────────────────────────────────────────────────────────────────────
    //  The function in focus: struct → transient storage, and back.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Serialize one `c` into transient storage starting at `BASE_SLOT`.
    /// @dev `calldata` input so the bytes blobs are copied straight out via `calldataload`.
    function store(ExpectedL1ToL2Call calldata c) external {
        _store(BASE_SLOT, c);
    }

    /// @notice Reconstruct the `ExpectedL1ToL2Call` previously written by `store`.
    function load() external view returns (ExpectedL1ToL2Call memory c) {
        (c,) = _load(BASE_SLOT);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Array variant: length at `BASE_SLOT`, element i at its own hashed base
    //  `keccak256(BASE_SLOT, i)`. Each element keeps its own self-contained
    //  sequential region, so variable-length elements never need to be walked
    //  past to address element i — and keccak spacing makes regions non-overlapping.
    //  (Shares the `BASE_SLOT` length slot with `store`; the two APIs aren't mixed.)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Serialize an array of calls, one per hashed base slot.
    function storeArray(ExpectedL1ToL2Call[] calldata cs) external {
        uint256 n = cs.length;
        _tstore(BASE_SLOT, n);
        for (uint256 i; i < n;) {
            _store(_elementBase(i), cs[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Reconstruct the array previously written by `storeArray`.
    function loadArray() external view returns (ExpectedL1ToL2Call[] memory cs) {
        uint256 n = _tload(BASE_SLOT);
        cs = new ExpectedL1ToL2Call[](n);
        for (uint256 i; i < n;) {
            (cs[i],) = _load(_elementBase(i));
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Number of elements written by the most recent `storeArray`.
    /// @dev Single `tload` of the length slot — no deserialization.
    function arrayLength() external view returns (uint256) {
        return _tload(BASE_SLOT);
    }

    /// @notice Load a single array element by index, without touching the others.
    /// @dev O(1) addressing: the element lives at its own hashed base, so this deserializes
    ///      exactly one entry. This is the access shape EEZ's reentrant consumption wants —
    ///      length first, then one element at a time as each proxy re-entry matches.
    function loadAt(uint256 index) external view returns (ExpectedL1ToL2Call memory c) {
        if (index >= _tload(BASE_SLOT)) revert IndexOutOfBounds();
        (c,) = _load(_elementBase(index));
    }

    /// @dev Per-index namespaced base, identical spacing to Solidity's storage arrays.
    function _elementBase(uint256 index) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(BASE_SLOT, index)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Single-struct (de)serialization over a cursor — reused by both APIs.
    // ─────────────────────────────────────────────────────────────────────────

    function _store(uint256 slot, ExpectedL1ToL2Call calldata c) private returns (uint256) {
        _tstore(slot, uint256(c.expectedL1toL2Hash));
        _tstore(slot + 1, uint256(c.revertedOrStaticRollingHash));
        _tstore(slot + 2, c.success ? 1 : 0);
        slot += 3;

        slot = _storeBytes(slot, c.returnData);

        uint256 n = c.l2ToL1Calls.length;
        _tstore(slot++, n);
        for (uint256 i; i < n;) {
            slot = _storeCall(slot, c.l2ToL1Calls[i]);
            unchecked {
                ++i;
            }
        }
        return slot;
    }

    function _load(uint256 slot) private view returns (ExpectedL1ToL2Call memory c, uint256) {
        c.expectedL1toL2Hash = bytes32(_tload(slot));
        c.revertedOrStaticRollingHash = bytes32(_tload(slot + 1));
        c.success = _tload(slot + 2) != 0;
        slot += 3;

        (c.returnData, slot) = _loadBytes(slot);

        uint256 n = _tload(slot++);
        L2ToL1Call[] memory calls = new L2ToL1Call[](n);
        for (uint256 i; i < n;) {
            (calls[i], slot) = _loadCall(slot);
            unchecked {
                ++i;
            }
        }
        c.l2ToL1Calls = calls;
        return (c, slot);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Per-`L2ToL1Call` (de)serialization — four scalars packed into one word.
    // ─────────────────────────────────────────────────────────────────────────

    function _storeCall(uint256 slot, L2ToL1Call calldata call) private returns (uint256) {
        uint256 header =
            uint256(call.revertNextNCalls) | (call.isStatic ? uint256(1) << ISTATIC_OFFSET : 0)
            | (uint256(call.sourceRollupId) << ROLLUP_OFFSET)
            | (uint256(uint160(call.sourceAddress)) << SOURCE_ADDR_OFFSET);

        _tstore(slot, header);
        _tstore(slot + 1, uint256(uint160(call.targetAddress)));
        _tstore(slot + 2, call.value);
        return _storeBytes(slot + 3, call.data);
    }

    function _loadCall(uint256 slot) private view returns (L2ToL1Call memory call, uint256) {
        uint256 header = _tload(slot);
        call.revertNextNCalls = uint16(header);
        call.isStatic = (header >> ISTATIC_OFFSET) & 1 != 0;
        call.sourceRollupId = uint64(header >> ROLLUP_OFFSET);
        call.sourceAddress = address(uint160(header >> SOURCE_ADDR_OFFSET));
        call.targetAddress = address(uint160(_tload(slot + 1)));
        call.value = _tload(slot + 2);
        (call.data, slot) = _loadBytes(slot + 3);
        return (call, slot);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Length-prefixed bytes: length word, then ceil(len/32) full words.
    //  Both directions loop entirely in assembly — no per-word function calls.
    // ─────────────────────────────────────────────────────────────────────────

    function _storeBytes(uint256 slot, bytes calldata b) private returns (uint256 next) {
        assembly {
            let len := b.length
            tstore(slot, len)
            slot := add(slot, 1)
            // Copy ceil(len/32) words; a trailing partial word pulls in adjacent
            // calldata, harmless because `_loadBytes` truncates to `len`.
            for { let off := b.offset } lt(off, add(b.offset, len)) { off := add(off, 32) } {
                tstore(slot, calldataload(off))
                slot := add(slot, 1)
            }
            next := slot
        }
    }

    function _loadBytes(uint256 slot) private view returns (bytes memory b, uint256 next) {
        assembly {
            let len := tload(slot)
            slot := add(slot, 1)

            b := mload(0x40) // allocate manually from the free pointer
            mstore(b, len)
            let dataPtr := add(b, 32)

            let words := shr(5, add(len, 31)) // ceil(len / 32)
            for { let i := 0 } lt(i, words) { i := add(i, 1) } {
                mstore(add(dataPtr, shl(5, i)), tload(slot))
                slot := add(slot, 1)
            }
            mstore(0x40, add(dataPtr, shl(5, words))) // bump free pointer past the buffer
            next := slot
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Raw transient word access.
    // ─────────────────────────────────────────────────────────────────────────

    function _tstore(uint256 slot, uint256 value) private {
        assembly {
            tstore(slot, value)
        }
    }

    function _tload(uint256 slot) private view returns (uint256 value) {
        assembly {
            value := tload(slot)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  IEEZ — required surface, intentionally unsupported here.
    // ─────────────────────────────────────────────────────────────────────────

    function executeCrossChainCall(address, bytes calldata) external payable returns (bytes memory) {
        revert NotSupported();
    }

    function staticCallLookup(address, bytes calldata) external view returns (bytes memory) {
        revert NotSupported();
    }

    function createCrossChainProxy(address, uint64) external returns (address) {
        revert NotSupported();
    }

    function computeCrossChainProxyAddress(address, uint64) external view returns (address) {
        revert NotSupported();
    }
}
