// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {ExecutionEntry, ExpectedL1ToL2Call, L2ToL1Call} from "../src/interfaces/IEEZ.sol";

contract IntermediateRevertTarget {
    uint256 public value;

    function setValue(uint256 next) external {
        value = next;
    }
}

contract IntermediateRevertCatcher {
    uint256 public beforeCall;
    uint256 public afterCall;
    bool public nestedSuccess;
    bytes public nestedResult;

    function run(address proxy, bytes calldata data) external {
        beforeCall++;
        (nestedSuccess, nestedResult) = proxy.call(data);
        afterCall++;
    }
}

/// @notice Characterizes EEZ's execution boundary with accepted tables.
/// @dev Uses Base's accepting mock verifier. These tests do NOT demonstrate that a
/// production prover accepts malformed tables or that an invalid proof can verify.
contract EEZIntermediateRevertTest is Base {
    RollupHandle internal rollup;
    IntermediateRevertTarget internal prefix;
    IntermediateRevertTarget internal suffix;
    IntermediateRevertTarget internal outerTail;
    IntermediateRevertCatcher internal catcher;
    address internal remoteProxy;

    bytes32 internal constant NEXT_ROOT = keccak256("intermediate-revert-next");
    bytes internal constant REMOTE_DATA = hex"11223344";
    bytes internal constant EXPECTED_REVERT = hex"aabbccdd";

    enum Failure {
        None,
        StaticValue,
        SpanBounds,
        WrongNestedHash
    }

    function setUp() public {
        setUpBase();
        rollup = _makeRollup(bytes32(0));
        prefix = new IntermediateRevertTarget();
        suffix = new IntermediateRevertTarget();
        outerTail = new IntermediateRevertTarget();
        catcher = new IntermediateRevertCatcher();
        remoteProxy = rollups.createCrossChainProxy(L2_REMOTE, uint64(rollup.id));
    }

    function _callbacks(Failure failure, bool wrap) internal view returns (L2ToL1Call[] memory calls) {
        uint64 rid = uint64(rollup.id);
        calls = new L2ToL1Call[](3);
        calls[0] = _call(L2_SENDER, rid, address(prefix), 0,
            abi.encodeCall(IntermediateRevertTarget.setValue, (11)));
        calls[1] = _staticCall(L2_SENDER, rid, address(prefix),
            abi.encodeWithSignature("value()"));
        calls[2] = _call(L2_SENDER, rid, address(suffix), 0,
            abi.encodeCall(IntermediateRevertTarget.setValue, (22)));
        if (failure == Failure.StaticValue) calls[1].value = 1;
        if (failure == Failure.SpanBounds) calls[1].revertNextNCalls = 3;
        if (wrap) calls[0].revertNextNCalls = 3;
    }

    function _callHash(L2ToL1Call memory c) internal pure returns (bytes32) {
        return _ccHash(c.isStatic, c.sourceAddress, c.sourceRollupId,
            c.targetAddress, 0, c.value, c.data);
    }

    function _expectedError(Failure failure, bool wrap) internal pure returns (bytes memory data) {
        if (failure == Failure.None) return EXPECTED_REVERT;
        if (failure == Failure.StaticValue) {
            data = abi.encodeWithSelector(EEZBase.StaticCallWithValue.selector);
        } else if (failure == Failure.SpanBounds) {
            data = abi.encodeWithSignature("RevertSpanOutOfBounds(uint256,uint256,uint256)",
                uint256(1), uint256(3), uint256(3));
        } else {
            return abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector);
        }
        if (wrap) data = abi.encodeWithSelector(EEZBase.UnexpectedContextRevert.selector, data);
    }

    function _expectCallbacks(Failure failure) internal {
        // Foundry call expectations also observe calls in subsequently reverted frames.
        vm.expectCall(address(prefix), abi.encodeCall(IntermediateRevertTarget.setValue, (11)), uint64(1));
        uint64 tailCount = failure == Failure.StaticValue || failure == Failure.SpanBounds ? 0 : 1;
        vm.expectCall(address(suffix), abi.encodeCall(IntermediateRevertTarget.setValue, (22)), tailCount);
    }

    function _runNested(Failure failure, bool wrap) internal {
        uint64 rid = uint64(rollup.id);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rid, bytes32(0), NEXT_ROOT);
        entries[0].l2ToL1Calls = new L2ToL1Call[](2);
        entries[0].l2ToL1Calls[0] = _call(L2_SENDER, rid, address(catcher), 0,
            abi.encodeCall(IntermediateRevertCatcher.run, (remoteProxy, REMOTE_DATA)));
        entries[0].l2ToL1Calls[1] = _call(L2_SENDER, rid, address(outerTail), 0,
            abi.encodeCall(IntermediateRevertTarget.setValue, (99)));

        bytes32 fireHash = _hCallBegin(entries[0].rollingHash, _callHash(entries[0].l2ToL1Calls[0]));
        bytes32 nestedIdentity = _ccHash(false, address(catcher), 0, L2_REMOTE, rid, 0, REMOTE_DATA);
        L2ToL1Call[] memory calls = _callbacks(failure, wrap);
        bytes32 nestedHash = _hNestedBegin(fireHash, nestedIdentity);
        for (uint256 i; i < calls.length; i++) {
            nestedHash = _hCallEnd(_hCallBegin(nestedHash, _callHash(calls[i])),
                true, i == 1 ? abi.encode(uint256(11)) : bytes(""));
        }
        if (failure == Failure.WrongNestedHash) nestedHash = bytes32(0);

        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](1);
        entries[0].expectedL1ToL2Calls[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: _expectedL1toL2Hash(nestedIdentity, fireHash),
            l2ToL1Calls: calls,
            revertedOrStaticRollingHash: nestedHash,
            success: false,
            returnData: EXPECTED_REVERT
        });

        // Same surviving outer transcript whether nested failure is the intended
        // terminal revert or an intermediate validation error swallowed by the app.
        bytes32 outerHash = _hCallEnd(fireHash, true, "");
        entries[0].rollingHash =
            _hCallEnd(_hCallBegin(outerHash, _callHash(entries[0].l2ToL1Calls[1])), true, "");
        _expectCallbacks(failure);
        _postBatchOne(rollup, entries, _emptyStaticEntries(), 1, 0);

        assertEq(_getRollupState(rid), NEXT_ROOT, "outer entry commits");
        assertEq(catcher.beforeCall(), 1, "outer prefix persists");
        assertEq(catcher.afterCall(), 1, "application continues after catch");
        assertFalse(catcher.nestedSuccess());
        assertEq(catcher.nestedResult(), _expectedError(failure, wrap));
        assertEq(prefix.value(), 0, "executed nested prefix rolls back");
        assertEq(suffix.value(), 0, "nested effects never persist");
        assertEq(outerTail.value(), 99, "later outer sibling executes");
    }

    function test_Control_ExpectedNestedTerminalRevertCommitsOuterEntry() public {
        _runNested(Failure.None, false);
    }

    function test_StaticCallWithValue_NestedErrorCaughtAndOuterCommits() public {
        _runNested(Failure.StaticValue, false);
    }

    function test_RevertSpanOutOfBounds_NestedErrorCaughtAndOuterCommits() public {
        _runNested(Failure.SpanBounds, false);
    }

    function test_StaticCallWithValue_InNestedSpanCaughtAndOuterCommits() public {
        _runNested(Failure.StaticValue, true);
    }

    function test_RevertSpanOutOfBounds_InNestedSpanCaughtAndOuterCommits() public {
        _runNested(Failure.SpanBounds, true);
    }

    function test_WrongNestedHash_CaughtAndOuterCommits() public {
        _runNested(Failure.WrongNestedHash, false);
    }

    function _runDirect(Failure failure, bool wrap) internal {
        uint64 rid = uint64(rollup.id);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rid, bytes32(0), NEXT_ROOT);
        entries[0].proxyEntryHash = _ccHash(false, address(this), 0, L2_REMOTE, rid, 0, REMOTE_DATA);
        entries[0].l2ToL1Calls = _callbacks(failure, wrap);
        entries[0].rollingHash = bytes32(0); // not reached
        _postBatchOne(rollup, entries, _emptyStaticEntries(), 0, 0);

        _expectCallbacks(failure);
        (bool ok, bytes memory data) = remoteProxy.call(REMOTE_DATA);
        assertFalse(ok, "direct incomplete execution must fail");
        assertEq(data, _expectedError(failure, wrap));
        assertEq(_getRollupState(rid), bytes32(0));
        assertEq(rollups.entryQueueIndex(rid), 0, "consumption rolls back");
        assertEq(prefix.value(), 0);
        assertEq(suffix.value(), 0);
    }

    function test_Control_DirectStaticCallWithValueRejectsEntry() public {
        _runDirect(Failure.StaticValue, false);
    }

    function test_Control_DirectRevertSpanOutOfBoundsRejectsEntry() public {
        _runDirect(Failure.SpanBounds, false);
    }

    function test_Control_DirectSpanEarlyRevertRejectsEntry() public {
        _runDirect(Failure.StaticValue, true);
    }
}
