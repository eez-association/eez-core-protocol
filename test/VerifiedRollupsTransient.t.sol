// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VerifiedRollupsTransient} from "../src/base/VerifiedRollupsTransient.sol";
import {ExpectedL1ToL2CallTransient} from "../src/base/ExpectedL1ToL2CallTransient.sol";
import {ExpectedL1ToL2Call, L2ToL1Call} from "../src/interfaces/IEEZ.sol";

/// @notice Exposes the internal region operations, and inherits `ExpectedL1ToL2CallTransient`
///         alongside it (like `EEZ` does) so the no-collision test runs against the real layout.
contract VerifiedRollupsHarness is VerifiedRollupsTransient, ExpectedL1ToL2CallTransient {
    error Boom();

    function push(uint64 rid) external {
        _pushVerifiedRollup(rid);
    }

    function clear() external {
        _clearVerifiedRollups();
    }

    function count() external view returns (uint256) {
        return _verifiedRollupCount();
    }

    function contains(uint64 rid) external view returns (bool) {
        return _containsVerifiedRollup(rid);
    }

    function pushThenRevert(uint64 rid) external {
        _pushVerifiedRollup(rid);
        revert Boom();
    }

    function setTable(ExpectedL1ToL2Call[] calldata calls) external {
        _setTransientExpectedL1toL2Calls(calls);
    }

    function heldTableLength() external view returns (uint256) {
        return _transientExpectedL1toL2CallsLength();
    }

    function heldTableRow0Hash() external view returns (bytes32) {
        return _transientExpectedL1toL2Calls()[0].expectedL1toL2Hash;
    }
}

contract VerifiedRollupsTransientTest is Test {
    VerifiedRollupsHarness harness;

    function setUp() public {
        harness = new VerifiedRollupsHarness();
    }

    function test_EmptyByDefault() public view {
        assertEq(harness.count(), 0);
        assertFalse(harness.contains(0));
        assertFalse(harness.contains(1));
        assertFalse(harness.contains(type(uint64).max));
    }

    function test_PushAndContains() public {
        harness.push(7);
        harness.push(42);
        assertEq(harness.count(), 2);
        assertTrue(harness.contains(7));
        assertTrue(harness.contains(42));
        assertFalse(harness.contains(8));
        // Unset slots tload 0 — a zero probe must not match past the count-bounded scan.
        assertFalse(harness.contains(0));
    }

    function test_ZeroIdIsAValidMember() public {
        harness.push(0);
        assertEq(harness.count(), 1);
        assertTrue(harness.contains(0));
    }

    function test_DuplicatePushesKept() public {
        harness.push(5);
        harness.push(5);
        assertEq(harness.count(), 2);
        assertTrue(harness.contains(5));
    }

    function test_ClearResetsSet() public {
        harness.push(1);
        harness.push(2);
        harness.clear();
        assertEq(harness.count(), 0);
        assertFalse(harness.contains(1));
        assertFalse(harness.contains(2));
    }

    function test_ClearIsIdempotent() public {
        harness.clear(); // clearing an empty set is a no-op
        assertEq(harness.count(), 0);
        harness.push(3);
        harness.clear();
        harness.clear();
        assertEq(harness.count(), 0);
        assertFalse(harness.contains(3));
    }

    /// @notice The count word is authoritative: ids stranded past the count by a clear must
    ///         never be visible to a later, shorter set.
    function test_StaleTailInvisibleAfterClearAndRepush() public {
        harness.push(1);
        harness.push(2);
        harness.push(3);
        harness.clear();
        harness.push(9); // overwrites the slot that held 1; slots holding 2 and 3 are stranded
        assertEq(harness.count(), 1);
        assertTrue(harness.contains(9));
        assertFalse(harness.contains(1));
        assertFalse(harness.contains(2));
        assertFalse(harness.contains(3));
    }

    /// @notice Transient writes roll back on revert exactly like storage — a reverted push
    ///         leaves no trace (what `_executeEntry`'s revert paths rely on).
    function test_RevertRollsBackPush() public {
        harness.push(1);
        vm.expectRevert(VerifiedRollupsHarness.Boom.selector);
        harness.pushThenRevert(2);
        assertEq(harness.count(), 1);
        assertTrue(harness.contains(1));
        assertFalse(harness.contains(2));
    }

    /// @notice The namespaced region must not collide with `ExpectedL1ToL2CallTransient`'s —
    ///         both live side by side in EEZ.
    function test_NoCollisionWithExpectedTableRegion() public {
        ExpectedL1ToL2Call[] memory calls = new ExpectedL1ToL2Call[](1);
        calls[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: keccak256("row0"),
            l2ToL1Calls: new L2ToL1Call[](0),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: ""
        });
        harness.setTable(calls);
        harness.push(11);
        harness.push(22);

        assertEq(harness.heldTableLength(), 1);
        assertEq(harness.heldTableRow0Hash(), keccak256("row0"));
        assertEq(harness.count(), 2);
        assertTrue(harness.contains(11));
        assertTrue(harness.contains(22));

        // And clearing one region leaves the other intact, both ways.
        harness.clear();
        assertEq(harness.heldTableLength(), 1);
        assertEq(harness.count(), 0);
    }

    function testFuzz_PushedIdsAreMembers(uint64[] calldata ids, uint64 probe) public {
        bool probeIsMember;
        for (uint256 i = 0; i < ids.length; i++) {
            harness.push(ids[i]);
            if (ids[i] == probe) probeIsMember = true;
        }
        assertEq(harness.count(), ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            assertTrue(harness.contains(ids[i]));
        }
        assertEq(harness.contains(probe), probeIsMember);
    }
}
