// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {EEZ} from "../src/EEZ.sol";
import {
    ExecutionEntry,
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    StaticLookup,
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
///         exercising the reentrant `staticCallLookup` path + the proxy's static-context detection.
contract StaticReader {
    function readUint(address proxy, bytes calldata data) external view returns (uint256) {
        (bool ok, bytes memory ret) = proxy.staticcall(data);
        require(ok, "static read failed");
        return abi.decode(ret, (uint256));
    }
}

/// @notice Coverage for `EEZ.staticCallLookup` (top-level pool + reentrant in-execution),
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

    function _stdBatchPost(Base.RollupHandle memory r, StaticLookup[] memory lookups) internal {
        _postBatchOne(r, _emptyEntries(), lookups, 0, 0);
    }

    /// @notice Static cross-chain-call hash as `staticCallLookup` derives it for a proxy
    ///         routing `(src → tgt on rid)` (target rollup = `rid`, source rollup = MAINNET).
    function _staticHash(uint256 rid, address tgt, bytes memory cd, address src) internal pure returns (bytes32) {
        return _ccHash(IS_STATIC, src, uint64(MAINNET), tgt, uint64(rid), 0, cd);
    }

    /// @notice Minimal top-level static lookup pinned to `rid`'s live root.
    /// @dev Match key: `proxyEntryHash` (the static cch) + `destinationRollupId` + every
    ///      `expectedStateRoots` pin live. `success == false` resolves by reverting with `ret`.
    function _staticLookup(uint256 rid, bytes32 hash, bool success, bytes memory ret)
        internal
        view
        returns (StaticLookup memory lc)
    {
        lc.proxyEntryHash = hash;
        lc.destinationRollupId = uint64(rid);
        lc.returnData = ret;
        lc.success = success;
        lc.l2ToL1Calls = new L2ToL1Call[](0);
        lc.rollingHash = bytes32(0);
        ExpectedStateRootPerRollup[] memory pins = new ExpectedStateRootPerRollup[](1);
        pins[0] = ExpectedStateRootPerRollup({rollupId: uint64(rid), stateRoot: _getRollupState(rid)});
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
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes memory payload = abi.encode(uint256(123));
        bytes32 h = _staticHash(r.id, address(target), cd, sourceAddr);

        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0] = _staticLookup(r.id, h, true, payload);
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        bytes memory res = rollups.staticCallLookup(sourceAddr, cd);
        assertEq(res, payload);
    }

    function test_StaticLookup_TopLevelFailedReverts() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes memory payload = hex"deadbeef";
        bytes32 h = _staticHash(r.id, address(target), cd, sourceAddr);

        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0] = _staticLookup(r.id, h, false, payload); // !success → reverts with payload
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        vm.expectRevert(payload);
        rollups.staticCallLookup(sourceAddr, cd);
    }

    function test_StaticLookup_TopLevelHashMismatchReverts() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes32 h = _staticHash(r.id, address(target), cd, sourceAddr);

        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0] = _staticLookup(r.id, h, true, "");
        lookups[0].rollingHash = keccak256("wrong"); // no sub-calls → computed 0 != wrong
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        rollups.staticCallLookup(sourceAddr, cd);
    }

    function test_StaticLookup_TopLevelNoMatchReverts() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        _stdBatchPost(r, _emptyStaticLookups()); // verified, empty static-lookup queue

        vm.prank(proxyAddr);
        vm.expectRevert(EEZBase.ExecutionNotFound.selector);
        rollups.staticCallLookup(sourceAddr, abi.encodeCall(ViewTarget.getValue, ()));
    }

    /// @notice Top-level static lookup carrying a real static sub-call: `_processNStaticCalls` runs it
    ///         and folds its result into the verified rolling hash.
    function test_StaticLookup_TopLevelWithSubCall() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        target.setValue(55);

        // Sub-call reads target.getValue() through the already-deployed proxy (source = target).
        bytes memory subData = abi.encodeCall(ViewTarget.getValue, ());
        bytes memory subRet = abi.encode(uint256(55));
        bytes32 subHash = _hStatic(bytes32(0), true, subRet);

        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes memory payload = abi.encode(uint256(999));
        bytes32 h = _staticHash(r.id, address(target), cd, sourceAddr);

        StaticLookup[] memory lookups = new StaticLookup[](1);
        StaticLookup memory lc = _staticLookup(r.id, h, true, payload);
        L2ToL1Call[] memory subCalls = new L2ToL1Call[](1);
        subCalls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: address(target),
            sourceRollupId: uint64(r.id),
            targetAddress: address(target),
            value: 0,
            data: subData
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
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));

        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes32 h = _staticHash(r.id, address(target), cd, sourceAddr);
        address undeployedSource = address(0xDEAD);
        address undeployedProxy = rollups.computeCrossChainProxyAddress(undeployedSource, uint64(r.id));

        StaticLookup[] memory lookups = new StaticLookup[](1);
        StaticLookup memory lc = _staticLookup(r.id, h, true, "");
        L2ToL1Call[] memory subCalls = new L2ToL1Call[](1);
        subCalls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: undeployedSource, // proxy never created
            sourceRollupId: uint64(r.id),
            targetAddress: address(target),
            value: 0,
            data: cd
        });
        lc.l2ToL1Calls = subCalls;
        lookups[0] = lc;
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        vm.expectRevert(abi.encodeWithSelector(EEZBase.LookupCallProxyNotDeployed.selector, undeployedProxy));
        rollups.staticCallLookup(sourceAddr, cd);
    }

    // ──────────────────────────────────────────────
    //  Reentrant static read (inside execution)
    // ──────────────────────────────────────────────

    /// @notice An entry whose call performs a cross-chain STATICCALL resolves through the entry's
    ///         unified `expectedL1ToL2Calls` (a static read: `success == true`) via the proxy's
    ///         static detection. The read is position-pinned by `_rollingHash` at the firing instant.
    function test_StaticLookup_NestedInsideExecution() public {
        Base.RollupHandle memory r = _makeRollup(bytes32(0));
        StaticReader reader = new StaticReader();

        // Inner: a proxy on L1 for an L2 view target.
        address innerL2 = address(0xC0FFEE);
        address innerProxy = rollups.createCrossChainProxy(innerL2, uint64(r.id));
        bytes memory innerData = abi.encodeWithSignature("getValue()");
        uint256 innerResult = 77;
        bytes memory payload = abi.encode(innerResult);
        // Reentrant static-read key: source = reader (msg.sender to innerProxy), target = innerL2 on r.id.
        bytes32 innerHash = _ccHash(IS_STATIC, address(reader), uint64(MAINNET), innerL2, uint64(r.id), 0, innerData);

        // Outer call: reader.readUint(innerProxy, innerData) → returns the decoded uint.
        bytes memory outerData = abi.encodeCall(StaticReader.readUint, (innerProxy, innerData));
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(0xD00D),
            sourceRollupId: uint64(r.id),
            targetAddress: address(reader),
            value: 0,
            data: outerData
        });

        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: uint64(r.id), currentState: bytes32(0), newState: keccak256("s1"), etherDelta: 0});

        // Rolling hash: entry seed → CALL_BEGIN(outer call) → [static read pinned here, hash unchanged]
        //   → CALL_END(true, abi.encode(77)). `hAtFire` is `_rollingHash` when the static read fires.
        bytes32 outerHash =
            _ccHash(NOT_STATIC_CALL, address(0xD00D), uint64(r.id), address(reader), uint64(MAINNET), 0, outerData);
        bytes32 hAtFire = _hCallBegin(_hEntryBegin(deltas, bytes32(0)), outerHash);
        bytes32 h = _hCallEnd(hAtFire, true, payload);

        ExpectedL1ToL2Call[] memory reentrant = new ExpectedL1ToL2Call[](1);
        reentrant[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: _expectedL1toL2Hash(innerHash, hAtFire),
            l2ToL1Calls: new L2ToL1Call[](0),
            revertedOrStaticRollingHash: bytes32(0), // untagged static hash of an empty sub-array
            success: true,
            returnData: payload
        });

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].proxyEntryHash = bytes32(0);
        entries[0].destinationRollupId = uint64(r.id);
        entries[0].l2ToL1Calls = calls;
        entries[0].expectedL1ToL2Calls = reentrant;
        entries[0].rollingHash = h;
        entries[0].success = true;
        entries[0].returnData = "";

        _postBatchOne(r, entries, _emptyStaticLookups(), 1, 0);
        assertEq(_getRollupState(r.id), keccak256("s1"), "entry must commit through the nested static read");
    }
}
