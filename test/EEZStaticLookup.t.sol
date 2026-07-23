// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {
    ExecutionEntry,
    StateUpdate,
    ExpectedL1ToL2Call,
    StaticExecutionEntry,
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
///         exercising the reentrant `staticCrossChainCall` path + the proxy's static-context detection.
contract StaticReader {
    function readUint(address proxy, bytes calldata data) external view returns (uint256) {
        (bool ok, bytes memory ret) = proxy.staticcall(data);
        require(ok, "static read failed");
        return abi.decode(ret, (uint256));
    }
}

/// @notice Coverage for `EEZ.staticCrossChainCall` (top-level pool + reentrant in-execution),
///         `_resolveStaticEntry`, and `_processNStaticCalls`.
contract EEZStaticLookupTest is Base {
    ViewTarget internal target;
    address internal alice = makeAddr("alice");
    address internal sourceAddr = makeAddr("sourceAddr");

    uint64 internal constant MAINNET_ROLLUP_ID = 0;

    function setUp() public {
        setUpBase();
        target = new ViewTarget();
    }

    function _stdBatchPost(RollupHandle memory r, StaticExecutionEntry[] memory lookups) internal {
        _postBatchOne(r, _emptyEntries(), lookups, 0, 0);
    }

    /// @notice Static cross-chain-call hash as `staticCrossChainCall` derives it for a proxy
    ///         routing `(src → tgt on rid)` (target rollup = `rid`, source rollup = MAINNET).
    function _staticHash(uint256 rid, address tgt, bytes memory cd, address src) internal pure returns (bytes32) {
        return _ccHash(IS_STATIC, src, MAINNET_ROLLUP_ID, tgt, uint64(rid), 0, cd);
    }

    /// @notice Minimal top-level static lookup pinned to `rid`'s live root.
    /// @dev Match key: `proxyEntryHash` (the static cch) + `destinationRollupId` + every
    ///      `expectedStateRoots` pin live. `success == false` resolves by reverting with `ret`.
    function _staticEntry(uint256 rid, bytes32 hash, bool success, bytes memory ret)
        internal
        view
        returns (StaticExecutionEntry memory lc)
    {
        lc.proxyEntryHash = hash;
        lc.destinationRollupId = uint64(rid);
        lc.returnData = ret;
        lc.success = success;
        lc.l2ToL1Calls = _emptyCalls();
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
        rollups.staticCrossChainCall(sourceAddr, "");
    }

    function test_StaticLookup_TopLevelSuccess() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes memory payload = abi.encode(uint256(123));
        bytes32 h = _staticHash(r.id, address(target), cd, sourceAddr);

        StaticExecutionEntry[] memory lookups = new StaticExecutionEntry[](1);
        lookups[0] = _staticEntry(r.id, h, true, payload);
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        bytes memory res = rollups.staticCrossChainCall(sourceAddr, cd);
        assertEq(res, payload);
    }

    function test_StaticLookup_TopLevelFailedReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes memory payload = hex"deadbeef";
        bytes32 h = _staticHash(r.id, address(target), cd, sourceAddr);

        StaticExecutionEntry[] memory lookups = new StaticExecutionEntry[](1);
        lookups[0] = _staticEntry(r.id, h, false, payload); // !success → reverts with payload
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        vm.expectRevert(payload);
        rollups.staticCrossChainCall(sourceAddr, cd);
    }

    function test_StaticLookup_TopLevelHashMismatchReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes32 h = _staticHash(r.id, address(target), cd, sourceAddr);

        StaticExecutionEntry[] memory lookups = new StaticExecutionEntry[](1);
        lookups[0] = _staticEntry(r.id, h, true, "");
        lookups[0].rollingHash = keccak256("wrong"); // no sub-calls → computed 0 != wrong
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        rollups.staticCrossChainCall(sourceAddr, cd);
    }

    function test_StaticLookup_TopLevelNoMatchReverts() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        _stdBatchPost(r, _emptyStaticEntries()); // verified, empty static-lookup queue

        vm.prank(proxyAddr);
        vm.expectRevert(EEZBase.ExecutionNotFound.selector);
        rollups.staticCrossChainCall(sourceAddr, abi.encodeCall(ViewTarget.getValue, ()));
    }

    /// @notice Top-level static lookup carrying a real static sub-call: `_processNStaticCalls` runs it
    ///         and folds its result into the verified rolling hash.
    function test_StaticLookup_TopLevelWithSubCall() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));
        target.setValue(55);

        // Sub-call reads target.getValue() through the already-deployed proxy (source = target).
        bytes memory subData = abi.encodeCall(ViewTarget.getValue, ());
        bytes memory subRet = abi.encode(uint256(55));
        bytes32 subHash = _hStatic(bytes32(0), true, subRet);

        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes memory payload = abi.encode(uint256(999));
        bytes32 h = _staticHash(r.id, address(target), cd, sourceAddr);

        StaticExecutionEntry[] memory lookups = new StaticExecutionEntry[](1);
        StaticExecutionEntry memory lc = _staticEntry(r.id, h, true, payload);
        lc.l2ToL1Calls = _oneCall(_staticCall(address(target), uint64(r.id), address(target), subData));
        lc.rollingHash = subHash;
        lookups[0] = lc;
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        bytes memory res = rollups.staticCrossChainCall(sourceAddr, cd);
        assertEq(res, payload);
    }

    /// @notice A static sub-call whose source proxy was never deployed reverts
    ///         `StaticCallProxyNotDeployed`.
    function test_StaticLookup_SubCallProxyNotDeployed() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address proxyAddr = rollups.createCrossChainProxy(address(target), uint64(r.id));

        bytes memory cd = abi.encodeCall(ViewTarget.getValue, ());
        bytes32 h = _staticHash(r.id, address(target), cd, sourceAddr);
        address undeployedSource = address(0xDEAD);
        address undeployedProxy = rollups.computeCrossChainProxyAddress(undeployedSource, uint64(r.id));

        StaticExecutionEntry[] memory lookups = new StaticExecutionEntry[](1);
        StaticExecutionEntry memory lc = _staticEntry(r.id, h, true, "");
        // Sub-call source proxy is never created.
        lc.l2ToL1Calls = _oneCall(_staticCall(undeployedSource, uint64(r.id), address(target), cd));
        lookups[0] = lc;
        _stdBatchPost(r, lookups);

        vm.prank(proxyAddr);
        vm.expectRevert(abi.encodeWithSelector(EEZBase.StaticCallProxyNotDeployed.selector, undeployedProxy));
        rollups.staticCrossChainCall(sourceAddr, cd);
    }

    // ──────────────────────────────────────────────
    //  Reentrant static read (inside execution)
    // ──────────────────────────────────────────────

    /// @notice An entry whose call performs a cross-chain STATICCALL resolves through the entry's
    ///         unified `expectedL1ToL2Calls` (a static read: `success == true`) via the proxy's
    ///         static detection. The read is position-pinned by `_rollingHash` at the firing instant.
    function test_StaticLookup_NestedInsideExecution() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        StaticReader reader = new StaticReader();

        // Inner: a proxy on L1 for an L2 view target.
        address innerL2 = address(0xC0FFEE);
        address innerProxy = rollups.createCrossChainProxy(innerL2, uint64(r.id));
        bytes memory innerData = abi.encodeWithSignature("getValue()");
        uint256 innerResult = 77;
        bytes memory payload = abi.encode(innerResult);
        // Reentrant static-read key: source = reader (msg.sender to innerProxy), target = innerL2 on r.id.
        bytes32 innerHash = _ccHash(IS_STATIC, address(reader), MAINNET_ROLLUP_ID, innerL2, uint64(r.id), 0, innerData);

        // Outer call: reader.readUint(innerProxy, innerData) → returns the decoded uint.
        bytes memory outerData = abi.encodeCall(StaticReader.readUint, (innerProxy, innerData));

        StateUpdate[] memory deltas = _oneDelta(r.id, bytes32(0), keccak256("s1"), 0);

        // Rolling hash: entry seed → CALL_BEGIN(outer call) → [static read pinned here, hash unchanged]
        //   → CALL_END(true, abi.encode(77)). `hAtFire` is `_rollingHash` when the static read fires.
        bytes32 outerHash =
            _ccHash(NOT_STATIC_CALL, L2_SENDER, uint64(r.id), address(reader), MAINNET_ROLLUP_ID, 0, outerData);
        bytes32 hAtFire = _hCallBegin(_hEntryBegin(deltas, bytes32(0)), outerHash);
        bytes32 h = _hCallEnd(hAtFire, true, payload);

        ExpectedL1ToL2Call[] memory reentrant = new ExpectedL1ToL2Call[](1);
        reentrant[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: _expectedL1toL2Hash(innerHash, hAtFire),
            l2ToL1Calls: _emptyCalls(),
            revertedOrStaticRollingHash: bytes32(0), // untagged static hash of an empty sub-array
            success: true,
            returnData: payload
        });

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, deltas);
        entries[0].l2ToL1Calls = _oneCall(_call(L2_SENDER, uint64(r.id), address(reader), 0, outerData));
        entries[0].expectedL1ToL2Calls = reentrant;
        entries[0].rollingHash = h;

        _postBatchOne(r, entries, _emptyStaticEntries(), 1, 0);
        assertEq(_getRollupState(r.id), keccak256("s1"), "entry must commit through the nested static read");
    }
}
