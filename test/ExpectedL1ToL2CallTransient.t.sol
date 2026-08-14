// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {ExpectedL1ToL2CallTransient} from "../src/base/ExpectedL1ToL2CallTransient.sol";
import {ExpectedL1ToL2Call, L2ToL1Call} from "../src/interfaces/IEEZ.sol";

/// @notice External surface over the base contract — the `calldata` inputs need a call boundary, and
///         the transient region belongs to the contract the base is mixed into.
contract TransientHarness is ExpectedL1ToL2CallTransient {
    function storeArray(ExpectedL1ToL2Call[] calldata cs) external {
        _setTransientExpectedL1toL2Calls(cs);
    }

    function loadArray() external view returns (ExpectedL1ToL2Call[] memory) {
        return _transientExpectedL1toL2Calls();
    }

    function arrayLength() external view returns (uint256) {
        return _transientExpectedL1toL2CallsLength();
    }

    function loadAt(uint256 index) external view returns (ExpectedL1ToL2Call memory) {
        return _transientExpectedL1toL2Calls()[index];
    }

    function clearArray() external {
        _clearTransientExpectedL1toL2Calls();
    }
}

/// @notice Round-trip tests for the transient (de)serializer.
/// @dev `store` and `load` are separate external calls; transient storage survives across them
///      because Foundry runs each test body as one transaction (no `--isolate`).
contract ExpectedL1ToL2CallTransientTest is Test {
    TransientHarness internal t;

    function setUp() public {
        t = new TransientHarness();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Single-row round trips
    // ─────────────────────────────────────────────────────────────────────────

    function test_RoundTrip_Empty() public {
        ExpectedL1ToL2Call memory c;
        c.expectedL1toL2Hash = keccak256("hash");
        c.revertedOrStaticRollingHash = keccak256("rolling");
        c.success = true;
        c.returnData = "";
        c.l2ToL1Calls = new L2ToL1Call[](0);

        t.storeArray(_one(c));
        _assertEntryEq(t.loadAt(0), c);
    }

    function test_RoundTrip_WithCallsAndData() public {
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = L2ToL1Call({
            gas: 100_000,
            revertNextNCalls: 3,
            isStatic: true,
            sourceAddress: address(0xABCD),
            sourceRollupId: 7,
            targetAddress: address(0x1234),
            value: 0, // static ⇒ no value
            data: hex"deadbeef"
        });
        calls[1] = L2ToL1Call({
            gas: 0, // 0 = forward all remaining gas
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(0xBEEF),
            sourceRollupId: 99,
            targetAddress: address(0x5678),
            value: 1 ether,
            // 37 bytes — exercises the non-32-multiple tail path
            data: hex"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2021222324"
        });

        ExpectedL1ToL2Call memory c;
        c.expectedL1toL2Hash = keccak256("k");
        c.revertedOrStaticRollingHash = keccak256("r");
        c.success = false;
        c.returnData = hex"cafe";
        c.l2ToL1Calls = calls;

        t.storeArray(_one(c));
        _assertEntryEq(t.loadAt(0), c);
    }

    /// @dev Pins the packing maths: max-width scalars must survive the two packed words intact.
    function test_RoundTrip_HeaderPackingExtremes() public {
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: type(uint64).max,
            revertNextNCalls: type(uint16).max,
            isStatic: true,
            sourceAddress: address(type(uint160).max),
            sourceRollupId: type(uint64).max,
            targetAddress: address(type(uint160).max),
            value: type(uint256).max,
            data: ""
        });

        ExpectedL1ToL2Call memory c;
        c.l2ToL1Calls = calls;
        c.returnData = "";

        t.storeArray(_one(c));
        _assertEntryEq(t.loadAt(0), c);
    }

    /// @dev Storing twice must fully overwrite — a larger first write must not leak into the second.
    function test_RoundTrip_OverwriteShrinks() public {
        ExpectedL1ToL2Call memory big;
        big.l2ToL1Calls = new L2ToL1Call[](2);
        big.l2ToL1Calls[0].data = hex"aabbccdd";
        big.l2ToL1Calls[1].data = hex"eeff";
        big.returnData = hex"11223344556677889900";
        t.storeArray(_one(big));

        ExpectedL1ToL2Call memory small;
        small.expectedL1toL2Hash = keccak256("small");
        small.l2ToL1Calls = new L2ToL1Call[](0);
        small.returnData = "";
        t.storeArray(_one(small));

        _assertEntryEq(t.loadAt(0), small);
    }

    /// @dev Two blobs that both end mid-word, each followed by more calldata for the trailing
    ///      partial word to over-read — the reconstructed blobs must still stop at their length.
    function test_RoundTrip_PartialTrailingWords() public {
        ExpectedL1ToL2Call memory c;
        c.l2ToL1Calls = new L2ToL1Call[](1);
        c.returnData = hex"aabbcc";
        c.l2ToL1Calls[0].data = hex"ddeeff";

        t.storeArray(_one(c));
        _assertEntryEq(t.loadAt(0), c);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Array round trips (per-index derived bases)
    // ─────────────────────────────────────────────────────────────────────────

    function test_RoundTrip_Array() public {
        ExpectedL1ToL2Call[] memory cs = new ExpectedL1ToL2Call[](3);

        // element 0: empty
        cs[0].expectedL1toL2Hash = keccak256("a");
        cs[0].l2ToL1Calls = new L2ToL1Call[](0);
        cs[0].returnData = "";

        // element 1: one call, some data
        cs[1].expectedL1toL2Hash = keccak256("b");
        cs[1].success = true;
        cs[1].returnData = hex"1234";
        cs[1].l2ToL1Calls = new L2ToL1Call[](1);
        cs[1].l2ToL1Calls[0] = L2ToL1Call(0, false, 21_000, address(0x11), 1, address(0x22), 5, hex"99");

        // element 2: two calls, larger data
        cs[2].expectedL1toL2Hash = keccak256("c");
        cs[2].returnData = hex"00112233445566778899aabbccddeeff00112233"; // 20 bytes
        cs[2].l2ToL1Calls = new L2ToL1Call[](2);
        cs[2].l2ToL1Calls[0] = L2ToL1Call(1, true, 50_000, address(0x33), 2, address(0x44), 0, "");
        cs[2].l2ToL1Calls[1] = L2ToL1Call(0, false, 0, address(0x55), 3, address(0x66), 7, hex"abcd");

        t.storeArray(cs);

        ExpectedL1ToL2Call[] memory got = t.loadArray();
        assertEq(got.length, cs.length, "array length");
        for (uint256 i; i < cs.length; ++i) {
            _assertEntryEq(got[i], cs[i]);
        }
    }

    function test_RoundTrip_ArrayEmpty() public {
        t.storeArray(new ExpectedL1ToL2Call[](0));
        assertEq(t.loadArray().length, 0);
    }

    /// @dev Indexed access: read length, then fetch each element individually — the shape EEZ wants.
    function test_Array_LengthAndLoadAt() public {
        ExpectedL1ToL2Call[] memory cs = new ExpectedL1ToL2Call[](3);
        for (uint256 i; i < 3; ++i) {
            cs[i].expectedL1toL2Hash = keccak256(abi.encode("elem", i));
            cs[i].returnData = abi.encodePacked(uint8(i));
            cs[i].l2ToL1Calls = new L2ToL1Call[](i); // 0, 1, 2 calls — variable length per element
            for (uint256 j; j < i; ++j) {
                cs[i].l2ToL1Calls[j] =
                    L2ToL1Call(uint16(j), false, uint64(j * 1000), address(0x10), uint64(j), address(0x20), j, hex"ab");
            }
        }
        t.storeArray(cs);

        assertEq(t.arrayLength(), 3, "arrayLength");
        // Fetch out of order to prove each element is independently addressable.
        _assertEntryEq(t.loadAt(2), cs[2]);
        _assertEntryEq(t.loadAt(0), cs[0]);
        _assertEntryEq(t.loadAt(1), cs[1]);
    }

    function test_LoadAt_OutOfBoundsReverts() public {
        ExpectedL1ToL2Call[] memory cs = new ExpectedL1ToL2Call[](2);
        cs[0].l2ToL1Calls = new L2ToL1Call[](0);
        cs[1].l2ToL1Calls = new L2ToL1Call[](0);
        t.storeArray(cs);

        vm.expectRevert(stdError.indexOOBError);
        t.loadAt(2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Stale-slot tolerance. Clearing only zeroes the length word and transient
    //  storage outlives a call, so every later read must be bounded by the CURRENT
    //  length — never by what an earlier, larger table left lying in those slots.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Clear leaves all row data behind; nothing may still be reachable through it.
    function test_Stale_ClearHidesEveryRow() public {
        t.storeArray(_fatRows(3));
        assertEq(t.arrayLength(), 3, "seeded");

        t.clearArray();

        assertEq(t.arrayLength(), 0, "length");
        assertEq(t.loadArray().length, 0, "loadArray");
        vm.expectRevert(stdError.indexOOBError);
        t.loadAt(0);
    }

    /// @dev A shorter table written over a longer one: the stale tail must stay unreachable, and the
    ///      surviving row must be the NEW one, not a blend with the fat row that occupied its slots.
    function test_Stale_ShorterTableAfterClear() public {
        t.storeArray(_fatRows(3));
        t.clearArray();

        ExpectedL1ToL2Call[] memory lean = new ExpectedL1ToL2Call[](1);
        lean[0].expectedL1toL2Hash = keccak256("lean");
        lean[0].returnData = ""; // fat row 0 had 40 bytes here
        lean[0].l2ToL1Calls = new L2ToL1Call[](0); // fat row 0 had 2 calls here
        t.storeArray(lean);

        assertEq(t.arrayLength(), 1, "length");
        _assertEntryEq(t.loadAt(0), lean[0]);
        vm.expectRevert(stdError.indexOOBError);
        t.loadAt(1);
    }

    /// @dev Same, without an intervening clear — a plain overwrite must be equally bounded.
    function test_Stale_ShorterTableWithoutClear() public {
        t.storeArray(_fatRows(3));

        ExpectedL1ToL2Call[] memory lean = new ExpectedL1ToL2Call[](2);
        for (uint256 i = 0; i < 2; i++) {
            lean[i].expectedL1toL2Hash = keccak256(abi.encode("lean", i));
            lean[i].returnData = "";
            lean[i].l2ToL1Calls = new L2ToL1Call[](0);
        }
        t.storeArray(lean);

        assertEq(t.arrayLength(), 2, "length");
        ExpectedL1ToL2Call[] memory got = t.loadArray();
        assertEq(got.length, 2, "loadArray length");
        for (uint256 i = 0; i < 2; i++) {
            _assertEntryEq(got[i], lean[i]);
        }
        vm.expectRevert(stdError.indexOOBError);
        t.loadAt(2);
    }

    /// @dev Rows carrying calls and blobs, so a stale row leaves plenty behind to bleed through.
    function _fatRows(uint256 n) internal pure returns (ExpectedL1ToL2Call[] memory cs) {
        cs = new ExpectedL1ToL2Call[](n);
        for (uint256 i = 0; i < n; i++) {
            cs[i].expectedL1toL2Hash = keccak256(abi.encode("fat", i));
            cs[i].revertedOrStaticRollingHash = keccak256(abi.encode("fatRolling", i));
            cs[i].success = true;
            cs[i].returnData = hex"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff0011223344556677";
            cs[i].l2ToL1Calls = new L2ToL1Call[](2);
            cs[i].l2ToL1Calls[0] =
                L2ToL1Call(7, true, 99_999, address(0xF00D), 42, address(0xBEEF), 0, hex"aabbccddeeff");
            cs[i].l2ToL1Calls[1] = L2ToL1Call(0, false, 1234, address(0xCAFE), 43, address(0xD00D), 5 ether, hex"1122");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Wrap one entry as a single-row table.
    function _one(ExpectedL1ToL2Call memory c) internal pure returns (ExpectedL1ToL2Call[] memory cs) {
        cs = new ExpectedL1ToL2Call[](1);
        cs[0] = c;
    }

    function _assertEntryEq(ExpectedL1ToL2Call memory got, ExpectedL1ToL2Call memory want) internal pure {
        assertEq(got.expectedL1toL2Hash, want.expectedL1toL2Hash, "expectedL1toL2Hash");
        assertEq(got.revertedOrStaticRollingHash, want.revertedOrStaticRollingHash, "revertedOrStaticRollingHash");
        assertEq(got.success, want.success, "success");
        assertEq(got.returnData, want.returnData, "returnData");
        assertEq(got.l2ToL1Calls.length, want.l2ToL1Calls.length, "calls length");
        for (uint256 i; i < want.l2ToL1Calls.length; ++i) {
            _assertCallEq(got.l2ToL1Calls[i], want.l2ToL1Calls[i]);
        }
    }

    function _assertCallEq(L2ToL1Call memory got, L2ToL1Call memory want) internal pure {
        assertEq(got.revertNextNCalls, want.revertNextNCalls, "revertNextNCalls");
        assertEq(got.isStatic, want.isStatic, "isStatic");
        assertEq(got.gas, want.gas, "gas");
        assertEq(got.sourceAddress, want.sourceAddress, "sourceAddress");
        assertEq(got.sourceRollupId, want.sourceRollupId, "sourceRollupId");
        assertEq(got.targetAddress, want.targetAddress, "targetAddress");
        assertEq(got.value, want.value, "value");
        assertEq(got.data, want.data, "data");
    }
}
