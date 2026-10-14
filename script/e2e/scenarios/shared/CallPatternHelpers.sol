// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RollupUpdate, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry} from "../../../../src/interfaces/IEEZ.sol";
import {
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    ExecutionEntry as L2Entry,
    StaticExecutionEntryL2 as L2Static
} from "../../../../src/interfaces/IEEZL2.sol";
import {CallPatternActor as Actor} from "../../../../test/mocks/CallPatternContracts.sol";
import {RollingHashBuilder as RH, HashStep, crossChainCallHash, expectedL1toL2Hash} from "./E2EHelpers.sol";

/// @dev Both views use the SAME calldata, actors, outcomes and call hashes.
/// Scenario-specific tables and expectations live beside their Execute contracts.
abstract contract CallPatternHelpers {
    struct L2OriginTables {
        ExecutionEntry[] l1;
        L2Entry[] l2;
        L2Static[] statics;
        HashStep[][] steps;
    }

    struct L1EntryBuilder {
        address a1;
        address a2;
        RollupUpdate[] updates;
        L2ToL1Call[] calls;
        ExpectedL1ToL2Call[] rows;
        HashStep[] steps;
        bytes32 rh;
        uint256 callCount;
        uint256 nestedCount;
        uint256 stepCount;
    }

    function _bump(uint256 n) internal pure returns (bytes memory) {
        return abi.encodeCall(Actor.bump, (n));
    }

    function _read(uint8 n) internal pure returns (bytes memory) {
        return abi.encodeCall(Actor.readChain, (n));
    }

    function _fail() internal pure returns (bytes memory) {
        return abi.encodeCall(Actor.failAfterChild, ());
    }

    function _catch() internal pure returns (bytes memory) {
        return abi.encodeCall(Actor.catchNested, ());
    }

    function _under() internal pure returns (bytes memory) {
        return abi.encodeCall(Actor.readUnderMutable, ());
    }

    function _price() internal pure returns (bytes memory) {
        return abi.encodeCall(Actor.price, ());
    }

    function _valuation(bool caught) internal pure returns (bytes memory) {
        return abi.encodeCall(Actor.valuation, (caught));
    }

    function _purchase() internal pure returns (bytes memory) {
        return abi.encodeCall(Actor.purchase, ());
    }

    function _observe(uint256 n, uint256 delta) internal pure returns (bytes memory) {
        return abi.encodeCall(Actor.observeAndBump, (n, delta));
    }

    function _result(uint256 n) internal pure returns (bytes memory) {
        return abi.encode(n);
    }

    function _frameFailure(uint256 n) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Actor.FrameFailed.selector, n);
    }

    function _priceUnavailable() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Actor.PriceUnavailable.selector, uint256(0));
    }

    function _l2ToL1CallHash(address a1, address a2, bytes memory data, bool isStatic) internal pure returns (bytes32) {
        return crossChainCallHash(isStatic, a2, 1, a1, 0, 0, data);
    }

    function _l1ToL2CallHash(address a1, address a2, bytes memory data, bool isStatic) internal pure returns (bytes32) {
        return crossChainCallHash(isStatic, a1, 0, a2, 1, 0, data);
    }

    function _l1Call(
        address a1,
        address a2,
        bytes memory data,
        bool isStatic,
        uint16 span
    )
        internal
        pure
        returns (L2ToL1Call memory)
    {
        return L2ToL1Call(span, isStatic, 0, a2, 1, a1, 0, data);
    }

    function _l2Call(
        address a1,
        address a2,
        bytes memory data,
        bool isStatic
    )
        internal
        pure
        returns (CrossChainCall memory)
    {
        return CrossChainCall(0, isStatic, 0, a1, 0, a2, 0, data);
    }

    function _l1Callback(
        address a1,
        address a2,
        bytes memory data,
        bool isStatic
    )
        internal
        pure
        returns (L2ToL1Call[] memory calls)
    {
        calls = new L2ToL1Call[](1);
        calls[0] = _l1Call(a1, a2, data, isStatic, 0);
    }

    function _l2Callback(
        address a1,
        address a2,
        bytes memory data,
        bool isStatic
    )
        internal
        pure
        returns (CrossChainCall[] memory calls)
    {
        calls = new CrossChainCall[](1);
        calls[0] = _l2Call(a1, a2, data, isStatic);
    }

    function _newL1Entry(address a1, address a2) internal pure returns (L1EntryBuilder memory h) {
        h.a1 = a1;
        h.a2 = a2;
        h.updates = new RollupUpdate[](1);
        h.updates[0] = RollupUpdate(1, 0, keccak256("l2-initial-state"), keccak256("call-pattern-final"));
        h.calls = new L2ToL1Call[](12);
        h.rows = new ExpectedL1ToL2Call[](8);
        h.steps = new HashStep[](32);
        h.rh = RH.entryBegin(h.updates, bytes32(0));
    }

    function _appendL1HashStep(L1EntryBuilder memory h, HashStep memory step) internal pure {
        h.steps[h.stepCount++] = step;
        HashStep[] memory one = new HashStep[](1);
        one[0] = step;
        h.rh = RH.foldSteps(h.rh, one);
    }

    function _beginL1Call(
        L1EntryBuilder memory h,
        bytes memory data,
        bool isStatic,
        uint16 span
    )
        internal
        pure
        returns (bytes32)
    {
        h.calls[h.callCount++] = _l1Call(h.a1, h.a2, data, isStatic, span);
        _appendL1HashStep(h, RH.stepCallBegin(_l2ToL1CallHash(h.a1, h.a2, data, isStatic)));
        return h.rh;
    }

    function _endL1Call(L1EntryBuilder memory h, bool success, bytes memory result) internal pure {
        _appendL1HashStep(h, RH.stepCallEnd(success, result));
    }

    function _successfulL1Call(
        L1EntryBuilder memory h,
        bytes memory data,
        bool isStatic,
        uint16 span,
        uint256 result
    )
        internal
        pure
    {
        _beginL1Call(h, data, isStatic, span);
        _endL1Call(h, true, _result(result));
    }

    function _expectedL1ToL2Call(
        L1EntryBuilder memory h,
        bytes memory data,
        bool isStatic,
        bytes32 fire,
        L2ToL1Call[] memory callbacks,
        bytes32 subHash,
        bool success,
        bytes memory result
    )
        internal
        pure
    {
        h.rows[h.nestedCount++] = ExpectedL1ToL2Call(
            expectedL1toL2Hash(_l1ToL2CallHash(h.a1, h.a2, data, isStatic), fire), callbacks, subHash, success, result
        );
    }

    function _finishL1Entry(L1EntryBuilder memory h, L2OriginTables memory t) internal pure {
        L2ToL1Call[] memory calls = new L2ToL1Call[](h.callCount);
        ExpectedL1ToL2Call[] memory rows = new ExpectedL1ToL2Call[](h.nestedCount);
        HashStep[] memory steps = new HashStep[](h.stepCount);
        for (uint256 i; i < h.callCount; i++) {
            calls[i] = h.calls[i];
        }
        for (uint256 i; i < h.nestedCount; i++) {
            rows[i] = h.rows[i];
        }
        for (uint256 i; i < h.stepCount; i++) {
            steps[i] = h.steps[i];
        }
        t.l1 = new ExecutionEntry[](1);
        t.l1[0] = ExecutionEntry(h.updates, bytes32(0), calls, rows, h.rh, 1, true, "");
        t.steps = new HashStep[][](1);
        t.steps[0] = steps;
    }

    /// @dev One outgoing source entry; at most one direct callback in these fixtures.
    /// Its expected hash includes the callback's outcome even when the source entry later reverts.
    function _l2SourceEntry(
        address a1,
        address a2,
        bytes memory data,
        bool success,
        bytes memory result,
        bytes memory callbackData,
        bool callbackStatic,
        bool callbackSuccess,
        bytes memory callbackResult
    )
        internal
        pure
        returns (L2Entry memory e)
    {
        e.proxyEntryHash = _l2ToL1CallHash(a1, a2, data, false);
        e.incomingCalls = new CrossChainCall[](callbackData.length == 0 ? 0 : 1);
        e.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        e.rollingHash = RH.entryBeginL2(e.proxyEntryHash);
        if (callbackData.length != 0) {
            e.incomingCalls[0] = _l2Call(a1, a2, callbackData, callbackStatic);
            e.rollingHash = RH.appendCallBegin(e.rollingHash, _l1ToL2CallHash(a1, a2, callbackData, callbackStatic));
            e.rollingHash = RH.appendCallEnd(e.rollingHash, callbackSuccess, callbackResult);
        }
        e.success = success;
        e.returnData = result;
    }

    function _l2SourceEntryWithoutCallbacks(
        address a1,
        address a2,
        bytes memory data,
        uint256 result
    )
        internal
        pure
        returns (L2Entry memory)
    {
        return _l2SourceEntry(a1, a2, data, true, _result(result), "", false, true, "");
    }

    function _l2StaticEntry(
        address a1,
        address a2,
        bytes memory data,
        uint256 cursor,
        CrossChainCall[] memory callbacks,
        bytes32 callbackHash,
        bool success,
        bytes memory result
    )
        internal
        pure
        returns (L2Static memory)
    {
        return L2Static(cursor, _l2ToL1CallHash(a1, a2, data, true), callbacks, callbackHash, success, result);
    }
}
