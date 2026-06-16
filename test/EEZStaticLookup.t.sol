// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {EEZ} from "../src/EEZ.sol";
import {
    ExecutionEntry,
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExpectedLookup,
    LookupCall,
    ExpectedStateRootPerRollup
} from "../src/interfaces/IEEZ.sol";
import {EEZBase} from "../src/base/EEZBase.sol";

/// @notice Simple view target used as a static sub-call destination.
contract ViewTarget {
    uint256 public value;

    function setValue(uint256 v) external {
        value = v;
    }

    function getValue() external view returns (uint256) {
        return value;
    }
}

/// @notice Performs a cross-chain STATICCALL through a proxy from inside an entry's call,
///         exercising the nested `staticCallLookup` path + the proxy's static-context detection.
contract StaticReader {
    function readUint(address proxy, bytes calldata data) external view returns (uint256) {
        (bool ok, bytes memory ret) = proxy.staticcall(data);
        require(ok, "static read failed");
        return abi.decode(ret, (uint256));
    }
}

/// @notice Coverage for `EEZ.staticCallLookup` (top-level pool + nested entry-scoped),
///         `_resolveStaticLookup`, and `_processNStaticCalls`.
contract EEZStaticLookupTest is Base {
    ViewTarget internal target;
    address internal alice = makeAddr("alice");
    address internal sourceAddr = makeAddr("sourceAddr");

    uint256 internal constant MAINNET = 0;

    function setUp() public {
        setUpBase();
        target = new ViewTarget();
    }

    function _stdBatchPost(Base.RollupHandle memory r, LookupCall[] memory lookups) internal {
        _postBatchOne(r, _emptyEntries(), lookups, 0, 0);
    }

    /// @notice Minimal top-level lookup pinned to `rid`'s live root.
    function _lookup(uint256 rid, bytes32 hash, bool failed, bytes memory ret)
        internal
        view
        returns (LookupCall memory lc)
    {
        lc.crossChainCallHash = hash;
        lc.destinationRollupId = rid;
        lc.returnData = ret;
        lc.failed = failed;
        lc.l2ToL1Calls = new L2ToL1Call[](0);
        lc.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        lc.expectedLookups = new ExpectedLookup[](0);
        lc.callCount = 0;
        lc.rollingHash = bytes32(0);
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: rid, stateRoot: _getRollupState(rid)});
        lc.expectedStateRoots = pins;
    }

    // ──────────────────────────────────────────────
    //  Top-level static lookup (outside execution)
    // ──────────────────────────────────────────────

    function test_StaticLookup_Unauthorized() public {
        _makeRollup(bytes32(0));
        vm.expectRevert(EEZBase.UnauthorizedProxy.selector);
        rollups.staticCallLookup(sourceAddr, "");
    }

    function test_StaticLookup_TopLevelSuccess() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), r.id);
        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes memory payload = abi.encode(uint256(123));
        bytes32 h = _hashCall(r.id, address(target), 0, cd, sourceAddr, MAINNET);

        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = _lookup(r.id, h, false, payload);
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        bytes memory res = rollups.staticCallLookup(sourceAddr, cd);
        assertEq(res, payload);
    }

    function test_StaticLookup_TopLevelFailedReverts() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), r.id);
        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes memory payload = hex"deadbeef";
        bytes32 h = _hashCall(r.id, address(target), 0, cd, sourceAddr, MAINNET);

        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = _lookup(r.id, h, true, payload); // failed → reverts with payload
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        vm.expectRevert(payload);
        rollups.staticCallLookup(sourceAddr, cd);
    }

    function test_StaticLookup_TopLevelHashMismatchReverts() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), r.id);
        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes32 h = _hashCall(r.id, address(target), 0, cd, sourceAddr, MAINNET);

        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = _lookup(r.id, h, false, "");
        lookups[0].rollingHash = keccak256("wrong"); // no sub-calls → computed 0 != wrong
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        rollups.staticCallLookup(sourceAddr, cd);
    }

    function test_StaticLookup_TopLevelNoMatchReverts() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), r.id);
        _stdBatchPost(r, _emptyLookupCalls()); // verified, empty lookup queue

        vm.prank(proxyAddr);
        vm.expectRevert(EEZBase.ExecutionNotFound.selector);
        rollups.staticCallLookup(sourceAddr, abi.encodeCall(ViewTarget.getValue, ()));
    }

    /// @notice Top-level lookup carrying a real static sub-call: `_processNStaticCalls` runs it
    ///         and folds its result into the verified rolling hash.
    function test_StaticLookup_TopLevelWithSubCall() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), r.id);
        target.setValue(55);

        // Sub-call reads target.getValue() through the already-deployed proxy (source = target).
        bytes memory subData = abi.encodeCall(ViewTarget.getValue, ());
        bytes memory subRet = abi.encode(uint256(55));
        bytes32 subHash = _rollingHashStatic(subRet);

        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes memory payload = abi.encode(uint256(999));
        bytes32 h = _hashCall(r.id, address(target), 0, cd, sourceAddr, MAINNET);

        LookupCall[] memory lookups = new LookupCall[](1);
        LookupCall memory lc = _lookup(r.id, h, false, payload);
        L2ToL1Call[] memory subCalls = new L2ToL1Call[](1);
        subCalls[0] = L2ToL1Call({
            isStatic: true,
            targetAddress: address(target),
            value: 0,
            data: subData,
            sourceAddress: address(target),
            sourceRollupId: r.id,
            revertSpan: 0
        });
        lc.l2ToL1Calls = subCalls;
        lc.rollingHash = subHash;
        lookups[0] = lc;
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        bytes memory res = rollups.staticCallLookup(sourceAddr, cd);
        assertEq(res, payload);
    }

    /// @notice A static sub-call whose source proxy was never deployed reverts
    ///         `LookupCallProxyNotDeployed`.
    function test_StaticLookup_SubCallProxyNotDeployed() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), r.id);

        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes32 h = _hashCall(r.id, address(target), 0, cd, sourceAddr, MAINNET);
        address undeployedSource = address(0xDEAD);
        address undeployedProxy = rollups.computeCrossChainProxyAddress(undeployedSource, r.id);

        LookupCall[] memory lookups = new LookupCall[](1);
        LookupCall memory lc = _lookup(r.id, h, false, "");
        L2ToL1Call[] memory subCalls = new L2ToL1Call[](1);
        subCalls[0] = L2ToL1Call({
            isStatic: true,
            targetAddress: address(target),
            value: 0,
            data: cd,
            sourceAddress: undeployedSource, // proxy never created
            sourceRollupId: r.id,
            revertSpan: 0
        });
        lc.l2ToL1Calls = subCalls;
        lookups[0] = lc;
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        vm.expectRevert(abi.encodeWithSelector(EEZBase.LookupCallProxyNotDeployed.selector, undeployedProxy));
        rollups.staticCallLookup(sourceAddr, cd);
    }

    // ──────────────────────────────────────────────
    //  Nested static lookup (inside execution)
    // ──────────────────────────────────────────────

    /// @notice An entry whose call performs a cross-chain STATICCALL resolves through the
    ///         entry-scoped `expectedLookups` (failed=false) via the proxy's static detection.
    function test_StaticLookup_NestedInsideExecution() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StaticReader reader = new StaticReader();

        // Inner: a proxy on L1 for an L2 view target.
        address innerL2 = address(0xC0FFEE);
        address innerProxy = rollups.createCrossChainProxy(innerL2, r.id);
        bytes memory innerData = abi.encodeWithSignature("getValue()");
        uint256 innerResult = 77;
        bytes memory payload = abi.encode(innerResult);
        // Nested lookup key: source = reader (msg.sender to innerProxy), at call #1.
        bytes32 innerHash = _hashCall(r.id, innerL2, 0, innerData, address(reader), MAINNET);

        // Outer call: reader.readUint(innerProxy, innerData) → returns the decoded uint.
        bytes memory outerData = abi.encodeCall(StaticReader.readUint, (innerProxy, innerData));
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            isStatic: false,
            targetAddress: address(reader),
            value: 0,
            data: outerData,
            sourceAddress: address(0xD00D),
            sourceRollupId: r.id,
            revertSpan: 0
        });

        ExpectedLookup[] memory lookups = new ExpectedLookup[](1);
        lookups[0] = ExpectedLookup({
            crossChainCallHash: innerHash,
            destinationRollupId: r.id,
            returnData: payload,
            failed: false,
            l2ToL1CallNumber: 1,
            lastL1ToL2CallConsumed: 0,
            executingLookupIndex: 0,
            l2ToL1Calls: new L2ToL1Call[](0),
            expectedL1ToL2Calls: new ExpectedL1ToL2Call[](0),
            callCount: 0,
            rollingHash: bytes32(0)
        });

        // Outer call returns abi.encode(uint256(77)).
        bytes32 h = _rollingHashSingleCall(abi.encode(innerResult));

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: r.id, currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = r.id;
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].expectedLookups = lookups;
        entries[0].callCount = 1;
        entries[0].returnData = "";
        entries[0].rollingHash = h;

        _postBatchOne(r, entries, _emptyLookupCalls(), 1, 0);
        assertEq(_getRollupState(r.id), keccak256("s1"), "entry must commit through the nested static read");
    }

    // ──────────────────────────────────────────────
    //  Local helpers
    // ──────────────────────────────────────────────

    /// @notice Untagged static rolling hash of a single successful sub-call returning `ret`.
    function _rollingHashStatic(bytes memory ret) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(0), true, ret));
    }
}
