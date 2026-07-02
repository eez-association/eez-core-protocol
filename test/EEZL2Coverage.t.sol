// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {CrossChainProxy} from "../src/base/CrossChainProxy.sol";
import {
    ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    StaticLookup
} from "../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy} from "./mocks/CounterContracts.sol";

/// @notice View target used as a static sub-call destination.
contract ViewTargetL2 {
    uint256 public value;

    function setValue(uint256 v) external {
        value = v;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    receive() external payable {}
}

/// @notice Performs a cross-chain STATICCALL through a proxy from inside an entry's call,
///         exercising the nested `staticCallLookup` path + the proxy's static-context detection.
contract StaticReaderL2 {
    function readUint(address proxy, bytes calldata data) external view returns (uint256) {
        (bool ok, bytes memory ret) = proxy.staticcall(data);
        require(ok, "static read failed");
        return abi.decode(ret, (uint256));
    }
}

/// @notice Fires one reentrant (outgoing) cross-chain call through a proxy, requires success,
///         returns a constant — drives an outgoing reentrant frame from inside an entry.
contract OutgoingForwarderL2 {
    function fire(address proxy, bytes calldata data) external returns (uint256) {
        (bool ok,) = proxy.call(data);
        require(ok, "outgoing call failed");
        return 9;
    }
}

/// @notice Coverage tests for `src/L2/EEZL2.sol` — value forwarding, executeIncomingCrossChainCall,
///         reentrant ExpectedOutgoing success path, and nested + top-level staticCallLookup.
contract EEZL2CoverageTest is Test {
    EEZL2 public manager;
    ViewTargetL2 public target;

    uint64 constant TEST_ROLLUP_ID = 42;
    uint64 constant REMOTE_ROLLUP_ID = 1;
    uint64 constant MAINNET = 0;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);

    uint8 constant CALL_BEGIN = 1;
    uint8 constant CALL_END = 2;
    uint8 constant NESTED_BEGIN = 3;
    uint8 constant NESTED_END = 4;
    uint8 constant CALL_NOT_FOUND = 5;

    function setUp() public {
        manager = new EEZL2(TEST_ROLLUP_ID, SYSTEM_ADDRESS);
        target = new ViewTargetL2();
    }

    // ── helpers ──

    /// Cross-chain call hash, mirroring `EEZBase.computeCrossChainCallHash`.
    function _ccHash(
        bool isStatic,
        address src,
        uint64 srcRollup,
        address tgt,
        uint64 tgtRollup,
        uint256 value_,
        bytes memory data
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(isStatic, src, srcRollup, tgt, tgtRollup, value_, data));
    }

    /// Position key for a unified `expectedOutgoingCalls` element: `keccak(crossChainCallHash, rollingHashAtFire)`.
    function _expectedOutgoingHash(bytes32 cch, bytes32 rollingHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(cch, rollingHash));
    }

    /// Entry seed: `keccak(bytes32(0), proxyEntryHash)` (L2 has no state deltas).
    function _seed(bytes32 proxyEntryHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(0), proxyEntryHash));
    }

    function _hCallBegin(bytes32 h, bytes32 cch) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(h, CALL_BEGIN, cch));
    }

    function _hCallEnd(bytes32 h, bool success, bytes memory retData) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(h, CALL_END, success, retData));
    }

    function _hNestedBegin(bytes32 h, bytes32 cch) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(h, NESTED_BEGIN, cch));
    }

    function _hNestedEnd(bytes32 h) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(h, NESTED_END));
    }

    function _hCallNotFound(bytes32 h, bytes32 cch) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(h, CALL_NOT_FOUND, cch));
    }

    /// Rolling hash for an entry with a single top-level call: seed → CALL_BEGIN(cch) → CALL_END(success, retData).
    function _rhSingle(bytes32 proxyEntryHash, bytes32 cch, bool success, bytes memory retData)
        internal
        pure
        returns (bytes32)
    {
        return _hCallEnd(_hCallBegin(_seed(proxyEntryHash), cch), success, retData);
    }

    /// Untagged static rolling hash of a single successful sub-call returning `ret`.
    function _rollingHashStatic(bytes memory ret) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(0), true, ret));
    }

    function _cc(address tgt, uint256 value_, bytes memory data, address src, uint64 srcRollup)
        internal
        pure
        returns (CrossChainCall memory)
    {
        return CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: src,
            sourceRollupId: srcRollup,
            targetAddress: tgt,
            value: value_,
            data: data
        });
    }

    function _loadEntries(ExecutionEntry[] memory entries, StaticLookup[] memory lookups) internal {
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries, lookups);
    }

    function _loadSingle(ExecutionEntry memory entry, StaticLookup[] memory lookups) internal {
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = entry;
        _loadEntries(entries, lookups);
    }

    // ──────────────────────────────────────────────
    //  msg.value forwarding to SYSTEM_ADDRESS
    // ──────────────────────────────────────────────

    function test_ExecuteCrossChainCall_ForwardsValueToSystem() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(ViewTargetL2.setValue, (42));

        // The proxy forwards msg.value to the manager; the manager forwards it to SYSTEM_ADDRESS.
        // The cross-chain call hash is computed with msg.value = 5 (it's part of the hash).
        uint256 sentValue = 5;
        // Inbound call: source = (this caller, this L2), target = (target, remote proxy rollup).
        bytes32 crossChainCallHash =
            _ccHash(false, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, sentValue, callData);

        // Inner forwarded call still carries cc.value (independent of the inbound msg.value).
        CrossChainCall memory cc = _cc(address(target), 0, callData, address(this), REMOTE_ROLLUP_ID);
        // The top-level call executes on this L2: target rollup = ROLLUP_ID, source = the call's own pair.
        bytes32 callHash = _ccHash(false, address(this), REMOTE_ROLLUP_ID, address(target), TEST_ROLLUP_ID, 0, callData);

        ExecutionEntry memory entry;
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = cc;
        entry.proxyEntryHash = crossChainCallHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entry.success = true;
        entry.returnData = "";
        entry.rollingHash = _rhSingle(crossChainCallHash, callHash, true, "");
        _loadSingle(entry, new StaticLookup[](0));

        uint256 sysBefore = SYSTEM_ADDRESS.balance;
        (bool success,) = proxy.call{value: sentValue}(callData);
        assertTrue(success);
        assertEq(SYSTEM_ADDRESS.balance, sysBefore + sentValue, "value must be forwarded to SYSTEM_ADDRESS");
        assertEq(target.value(), 42);
    }

    function test_ExecuteCrossChainCall_EtherTransferFailed() public {
        // System address is a contract with no payable receive → transfer fails.
        RejectEther rejecter = new RejectEther();
        EEZL2 mgr2 = new EEZL2(TEST_ROLLUP_ID, address(rejecter));
        address proxy = mgr2.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(ViewTargetL2.setValue, (1));

        bytes32 h = _ccHash(false, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, 3, callData);
        bytes32 callHash = _ccHash(false, address(this), REMOTE_ROLLUP_ID, address(target), TEST_ROLLUP_ID, 0, callData);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = _cc(address(target), 0, callData, address(this), REMOTE_ROLLUP_ID);
        ExecutionEntry memory entry;
        entry.proxyEntryHash = h;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entry.success = true;
        entry.rollingHash = _rhSingle(h, callHash, true, "");
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = entry;
        vm.prank(address(rejecter));
        mgr2.loadExecutionTable(entries, new StaticLookup[](0));

        // The EtherTransferFailed error bubbles up through the proxy as a revert.
        (bool ok,) = proxy.call{value: 3}(callData);
        assertFalse(ok, "transfer to non-payable system address must fail");
    }

    // ──────────────────────────────────────────────
    //  executeIncomingCrossChainCall
    // ──────────────────────────────────────────────

    function test_IncomingCrossChainCall_EmptyEntries() public {
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert(EEZL2.EmptyEntries.selector);
        manager.executeIncomingCrossChainCall(
            address(target), 0, "", address(this), REMOTE_ROLLUP_ID, new ExecutionEntry[](0), new StaticLookup[](0)
        );
    }

    function test_IncomingCrossChainCall_ValueMismatch() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].proxyEntryHash = bytes32(uint256(1));
        vm.deal(SYSTEM_ADDRESS, 10);
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert(EEZL2.ValueMismatch.selector);
        manager.executeIncomingCrossChainCall{
            value: 1
        }(address(target), 5, "", address(this), REMOTE_ROLLUP_ID, entries, new StaticLookup[](0));
    }

    function test_IncomingCrossChainCall_NotSystem() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        vm.expectRevert(EEZL2.Unauthorized.selector);
        manager.executeIncomingCrossChainCall(
            address(target), 0, "", address(this), REMOTE_ROLLUP_ID, entries, new StaticLookup[](0)
        );
    }

    function test_IncomingCrossChainCall_EntryHashMismatch() public {
        // destination/value/data hash won't equal entries[0].proxyEntryHash.
        bytes memory data = abi.encodeCall(ViewTargetL2.setValue, (7));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].proxyEntryHash = bytes32(uint256(0xBAD));
        entries[0].incomingCalls = new CrossChainCall[](0);
        entries[0].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);

        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert(EEZL2.EntryHashMismatch.selector);
        manager.executeIncomingCrossChainCall(
            address(target), 0, data, address(0xABCD), REMOTE_ROLLUP_ID, entries, new StaticLookup[](0)
        );
    }

    function test_IncomingCrossChainCall_Success() public {
        address sourceAddr = address(0xABCD);
        uint64 sourceRollup = REMOTE_ROLLUP_ID;
        bytes memory data = abi.encodeCall(ViewTargetL2.setValue, (123));
        uint256 value = 0; // setValue is non-payable; keep the forwarded value at 0

        // entries[0].incomingCalls[0] is the inbound call delivered via the source proxy.
        // The inbound call's hash binds source = (sourceAddr, sourceRollup), target = (destination, ROLLUP_ID).
        bytes32 inboundHash = _ccHash(false, sourceAddr, sourceRollup, address(target), TEST_ROLLUP_ID, value, data);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: sourceAddr,
            sourceRollupId: sourceRollup,
            targetAddress: address(target),
            value: value,
            data: data
        });

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].proxyEntryHash = inboundHash;
        entries[0].incomingCalls = calls;
        entries[0].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entries[0].success = true;
        entries[0].returnData = abi.encode(uint256(777));
        // The inbound call executes on this L2 with the same identity as the entry's proxyEntryHash.
        entries[0].rollingHash = _rhSingle(inboundHash, inboundHash, true, "");

        vm.prank(SYSTEM_ADDRESS);
        bytes memory ret = manager.executeIncomingCrossChainCall{
            value: value
        }(address(target), value, data, sourceAddr, sourceRollup, entries, new StaticLookup[](0));

        assertEq(ret, abi.encode(uint256(777)));
        assertEq(target.value(), 123);
        assertEq(manager.executionIndex(), 1, "executionIndex advances past entries[0]");
    }

    // ──────────────────────────────────────────────
    //  Reentrant ExpectedOutgoing success path
    // ──────────────────────────────────────────────

    /// An entry whose call reenters the manager via a proxy, matched against
    /// `expectedOutgoingCalls[0]` (NESTED_BEGIN/END folded into the rolling hash).
    function test_ExpectedOutgoingCall_SuccessPath() public {
        // Inner target: a proxy on this L2 for a Counter living on MAINNET (rollup 0).
        address counterL1 = address(0xC0117E1);
        address counterProxy = manager.createCrossChainProxy(counterL1, MAINNET);
        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        address outerProxy = manager.createCrossChainProxy(address(cap), REMOTE_ROLLUP_ID);
        bytes memory outerCd = abi.encodeCall(CounterAndProxy.incrementProxy, ());
        bytes memory innerCd = abi.encodeCall(Counter.increment, ());

        // Outer call: invoked via outerProxy by address(this) → source = (this, this L2), target = (cap, remote).
        bytes32 outerHash = _ccHash(false, address(this), TEST_ROLLUP_ID, address(cap), REMOTE_ROLLUP_ID, 0, outerCd);
        // Top-level outer call executed on this L2 carries its own source pair, target rollup = ROLLUP_ID.
        bytes32 outerCallHash =
            _ccHash(false, address(this), REMOTE_ROLLUP_ID, address(cap), TEST_ROLLUP_ID, 0, outerCd);
        // Reentrant call leaving this L2: L2 forces sourceRollupId = ROLLUP_ID, target = (counterL1, MAINNET).
        bytes32 innerHash = _ccHash(false, address(cap), TEST_ROLLUP_ID, counterL1, MAINNET, 0, innerCd);
        // The sub-call run inside the reentrant frame executes on this L2 (target rollup = ROLLUP_ID).
        bytes32 subHash = _ccHash(false, address(cap), MAINNET, counterL1, TEST_ROLLUP_ID, 0, innerCd);

        // The reentrant frame's own sub-call targets the codeless `counterL1` address; a call to a
        // codeless address succeeds returning "". The reentrant caller (`cap`) gets
        // `expectedOutgoingCalls[0].returnData` = abi.encode(1).
        bytes memory outgoingRet = abi.encode(uint256(1));

        // entry.incomingCalls holds ONLY the top-level outer call; the reentrant frame carries its own.
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = _cc(address(cap), 0, outerCd, address(this), REMOTE_ROLLUP_ID);

        // The reentrant frame's sub-array (run by `_resolveNestedReentrant`).
        CrossChainCall[] memory frameCalls = new CrossChainCall[](1);
        frameCalls[0] = _cc(counterL1, 0, innerCd, address(cap), MAINNET);

        // Rolling hash: seed, CALL_BEGIN(outer), [NESTED_BEGIN(inner), CALL_BEGIN(sub),
        // CALL_END(true,""), NESTED_END], CALL_END(true,"").
        bytes32 h = _seed(outerHash);
        h = _hCallBegin(h, outerCallHash);
        bytes32 rhAtFire = h; // `_rollingHash` at the instant the reentrant call fires
        h = _hNestedBegin(h, innerHash);
        h = _hCallBegin(h, subHash);
        h = _hCallEnd(h, true, "");
        h = _hNestedEnd(h);
        h = _hCallEnd(h, true, "");

        ExpectedOutgoingCrossChainCall[] memory outgoing = new ExpectedOutgoingCrossChainCall[](1);
        outgoing[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: _expectedOutgoingHash(innerHash, rhAtFire),
            incomingCalls: frameCalls,
            revertedOrStaticRollingHash: bytes32(0), // unused on the success path
            success: true,
            returnData: outgoingRet
        });

        ExecutionEntry memory entry;
        entry.proxyEntryHash = outerHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = outgoing;
        entry.success = true;
        entry.returnData = "";
        entry.rollingHash = h;
        _loadSingle(entry, new StaticLookup[](0));

        (bool ok,) = outerProxy.call(outerCd);
        assertTrue(ok, "outer reentrant call must succeed");
        assertEq(cap.counter(), 1);
        assertEq(cap.targetCounter(), 1, "reentrant frame returned the pre-computed outgoing returnData");
    }

    // ──────────────────────────────────────────────
    //  staticCallLookup — top-level pool
    // ──────────────────────────────────────────────

    function test_StaticLookup_Unauthorized() public {
        vm.expectRevert(EEZBase.UnauthorizedProxy.selector);
        manager.staticCallLookup(address(this), "");
    }

    function test_StaticLookup_TopLevelSuccess() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory cd = abi.encodeCall(ViewTargetL2.getValue, ());
        bytes memory payload = abi.encode(uint256(123));
        // Static lookup key: isStatic = true, source = (this caller, this L2), target = (target, remote).
        bytes32 h = _ccHash(true, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, 0, cd);

        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0].proxyEntryHash = h;
        lookups[0].returnData = payload;
        lookups[0].success = true;
        lookups[0].incomingCalls = new CrossChainCall[](0);
        lookups[0].rollingHash = bytes32(0);
        _loadEntries(new ExecutionEntry[](0), lookups);

        vm.prank(proxy);
        bytes memory res = manager.staticCallLookup(address(this), cd);
        assertEq(res, payload);
    }

    function test_StaticLookup_TopLevelFailedReverts() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory cd = abi.encodeCall(ViewTargetL2.getValue, ());
        bytes memory payload = hex"deadbeef";
        bytes32 h = _ccHash(true, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, 0, cd);

        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0].proxyEntryHash = h;
        lookups[0].returnData = payload;
        lookups[0].success = false;
        lookups[0].incomingCalls = new CrossChainCall[](0);
        lookups[0].rollingHash = bytes32(0);
        _loadEntries(new ExecutionEntry[](0), lookups);

        vm.prank(proxy);
        vm.expectRevert(payload);
        manager.staticCallLookup(address(this), cd);
    }

    function test_StaticLookup_TopLevelHashMismatch() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory cd = abi.encodeCall(ViewTargetL2.getValue, ());
        bytes32 h = _ccHash(true, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, 0, cd);

        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0].proxyEntryHash = h;
        lookups[0].returnData = "";
        lookups[0].success = true;
        lookups[0].incomingCalls = new CrossChainCall[](0);
        lookups[0].rollingHash = keccak256("wrong"); // no sub-calls → computed 0 != wrong
        _loadEntries(new ExecutionEntry[](0), lookups);

        vm.prank(proxy);
        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        manager.staticCallLookup(address(this), cd);
    }

    function test_StaticLookup_TopLevelNoMatch() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        _loadEntries(new ExecutionEntry[](0), new StaticLookup[](0));

        vm.prank(proxy);
        vm.expectRevert(EEZBase.ExecutionNotFound.selector);
        manager.staticCallLookup(address(this), abi.encodeCall(ViewTargetL2.getValue, ()));
    }

    /// Top-level lookup carrying a real static sub-call: `_processNStaticCalls` runs it
    /// and folds its result into the verified rolling hash.
    function test_StaticLookup_TopLevelWithSubCall() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        target.setValue(55);

        bytes memory subData = abi.encodeCall(ViewTargetL2.getValue, ());
        bytes memory subRet = abi.encode(uint256(55));
        bytes32 subHash = _rollingHashStatic(subRet);

        bytes memory cd = abi.encodeCall(ViewTargetL2.getValue, ());
        bytes memory payload = abi.encode(uint256(999));
        bytes32 h = _ccHash(true, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, 0, cd);

        CrossChainCall[] memory subCalls = new CrossChainCall[](1);
        subCalls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: address(target),
            sourceRollupId: REMOTE_ROLLUP_ID,
            targetAddress: address(target),
            value: 0,
            data: subData
        });

        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0].proxyEntryHash = h;
        lookups[0].returnData = payload;
        lookups[0].success = true;
        lookups[0].incomingCalls = subCalls;
        lookups[0].rollingHash = subHash;
        _loadEntries(new ExecutionEntry[](0), lookups);

        vm.prank(proxy);
        bytes memory res = manager.staticCallLookup(address(this), cd);
        assertEq(res, payload);
    }

    /// Static sub-call whose source proxy was never deployed reverts LookupCallProxyNotDeployed.
    function test_StaticLookup_SubCallProxyNotDeployed() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory cd = abi.encodeCall(ViewTargetL2.getValue, ());
        bytes32 h = _ccHash(true, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, 0, cd);
        address undeployedSource = address(0xDEAD);
        address undeployedProxy = manager.computeCrossChainProxyAddress(undeployedSource, REMOTE_ROLLUP_ID);

        CrossChainCall[] memory subCalls = new CrossChainCall[](1);
        subCalls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: undeployedSource,
            sourceRollupId: REMOTE_ROLLUP_ID,
            targetAddress: address(target),
            value: 0,
            data: cd
        });

        StaticLookup[] memory lookups = new StaticLookup[](1);
        lookups[0].proxyEntryHash = h;
        lookups[0].returnData = "";
        lookups[0].success = true;
        lookups[0].incomingCalls = subCalls;
        lookups[0].rollingHash = bytes32(0);
        _loadEntries(new ExecutionEntry[](0), lookups);

        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(EEZBase.LookupCallProxyNotDeployed.selector, undeployedProxy));
        manager.staticCallLookup(address(this), cd);
    }

    // ──────────────────────────────────────────────
    //  staticCallLookup — nested inside execution
    // ──────────────────────────────────────────────

    /// An entry whose call performs a cross-chain STATICCALL resolves through the active entry's
    /// unified `expectedOutgoingCalls` (a static-keyed `success == true` element) via the proxy's
    /// static-context detection.
    function test_StaticLookup_NestedInsideExecution() public {
        StaticReaderL2 reader = new StaticReaderL2();

        // Inner: a proxy on this L2 for a remote view target.
        address innerRemote = address(0xC0FFEE);
        address innerProxy = manager.createCrossChainProxy(innerRemote, MAINNET);
        bytes memory innerData = abi.encodeWithSignature("getValue()");
        uint256 innerResult = 77;
        bytes memory payload = abi.encode(innerResult);
        // Nested static read key: isStatic = true, source = (reader, this L2), target = (innerRemote, MAINNET).
        bytes32 innerHash = _ccHash(true, address(reader), TEST_ROLLUP_ID, innerRemote, MAINNET, 0, innerData);

        // Outer call: reader.readUint(innerProxy, innerData) → returns the decoded uint.
        bytes memory outerData = abi.encodeCall(StaticReaderL2.readUint, (innerProxy, innerData));
        bytes32 outerHash =
            _ccHash(false, address(0xD00D), TEST_ROLLUP_ID, address(reader), REMOTE_ROLLUP_ID, 0, outerData);
        // Top-level outer call executed on this L2 (target rollup = ROLLUP_ID).
        bytes32 outerCallHash =
            _ccHash(false, address(0xD00D), REMOTE_ROLLUP_ID, address(reader), TEST_ROLLUP_ID, 0, outerData);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = _cc(address(reader), 0, outerData, address(0xD00D), REMOTE_ROLLUP_ID);

        // The static read fires while inside the outer call: `_rollingHash` = seed → CALL_BEGIN(outer).
        bytes32 rhAtRead = _hCallBegin(_seed(outerHash), outerCallHash);

        ExpectedOutgoingCrossChainCall[] memory outgoing = new ExpectedOutgoingCrossChainCall[](1);
        outgoing[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: _expectedOutgoingHash(innerHash, rhAtRead),
            incomingCalls: new CrossChainCall[](0), // no sub-calls; the read returns the pre-computed payload
            revertedOrStaticRollingHash: bytes32(0), // untagged static hash of an empty sub-array
            success: true,
            returnData: payload
        });

        // Outer call returns abi.encode(uint256(77)).
        bytes32 h = _rhSingle(outerHash, outerCallHash, true, abi.encode(innerResult));

        ExecutionEntry memory entry;
        entry.proxyEntryHash = outerHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = outgoing;
        entry.success = true;
        entry.returnData = "";
        entry.rollingHash = h;
        _loadSingle(entry, new StaticLookup[](0));

        address outerProxy = manager.createCrossChainProxy(address(reader), REMOTE_ROLLUP_ID);
        // Invoke from 0xD00D so the consumed hash matches the entry's proxyEntryHash, whose
        // bound sourceAddress is 0xD00D.
        vm.prank(address(0xD00D));
        (bool ok,) = outerProxy.call(outerData);
        assertTrue(ok, "entry with nested static read must commit");
    }

    /// Nested staticCallLookup with no matching outgoing entry reverts ExecutionNotFound,
    /// surfacing as the outer call failing.
    function test_StaticLookup_NestedNoMatch() public {
        StaticReaderL2 reader = new StaticReaderL2();
        address innerRemote = address(0xC0FFEE);
        address innerProxy = manager.createCrossChainProxy(innerRemote, MAINNET);
        bytes memory innerData = abi.encodeWithSignature("getValue()");

        // Outer call performs the static read but NO expectedOutgoing entry is provided → revert inside.
        bytes memory outerData = abi.encodeCall(StaticReaderL2.readUint, (innerProxy, innerData));
        bytes32 outerHash =
            _ccHash(false, address(0xD00D), TEST_ROLLUP_ID, address(reader), REMOTE_ROLLUP_ID, 0, outerData);
        bytes32 outerCallHash =
            _ccHash(false, address(0xD00D), REMOTE_ROLLUP_ID, address(reader), TEST_ROLLUP_ID, 0, outerData);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = _cc(address(reader), 0, outerData, address(0xD00D), REMOTE_ROLLUP_ID);

        ExecutionEntry memory entry;
        entry.proxyEntryHash = outerHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entry.success = true;
        entry.returnData = "";
        // The outer call's static read reverts (ExecutionNotFound), so reader's require fails →
        // the outer call returns (false, ...). We set an incomplete rolling hash (seed + CALL_BEGIN
        // only) so the entry fails its rolling-hash check and the whole call reverts.
        entry.rollingHash = _hCallBegin(_seed(outerHash), outerCallHash);
        _loadSingle(entry, new StaticLookup[](0));

        address outerProxy = manager.createCrossChainProxy(address(reader), REMOTE_ROLLUP_ID);
        vm.prank(address(0xD00D));
        (bool ok,) = outerProxy.call(outerData);
        assertFalse(ok, "nested static read with no lookup match must surface as failure");
    }

    // ──────────────────────────────────────────────
    //  Reentrant (outgoing) no-match → CALL_NOT_FOUND
    // ──────────────────────────────────────────────

    /// A reentrant call with no matching `expectedOutgoingCalls` element folds CALL_NOT_FOUND into the
    /// rolling hash (and returns "" to the caller). Pinning the entry's hash to the CALL_NOT_FOUND fold
    /// proves the path: the entry verifies and commits.
    function test_NestedReentrant_NoMatch_CallNotFound() public {
        OutgoingForwarderL2 fwd = new OutgoingForwarderL2();
        address innerRemote = address(0xC0FFEE);
        address innerProxy = manager.createCrossChainProxy(innerRemote, MAINNET);
        bytes memory innerData = "";

        address outerProxy = manager.createCrossChainProxy(address(fwd), REMOTE_ROLLUP_ID);
        bytes memory outerData = abi.encodeCall(OutgoingForwarderL2.fire, (innerProxy, innerData));

        bytes32 outerHash = _ccHash(false, address(this), TEST_ROLLUP_ID, address(fwd), REMOTE_ROLLUP_ID, 0, outerData);
        bytes32 outerCallHash =
            _ccHash(false, address(this), REMOTE_ROLLUP_ID, address(fwd), TEST_ROLLUP_ID, 0, outerData);
        // Reentrant call leaving this L2: source forced to ROLLUP_ID, target (innerRemote, MAINNET).
        bytes32 innerHash = _ccHash(false, address(fwd), TEST_ROLLUP_ID, innerRemote, MAINNET, 0, innerData);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = _cc(address(fwd), 0, outerData, address(this), REMOTE_ROLLUP_ID);

        bytes32 h = _seed(outerHash);
        h = _hCallBegin(h, outerCallHash);
        h = _hCallNotFound(h, innerHash);
        h = _hCallEnd(h, true, abi.encode(uint256(9)));

        ExecutionEntry memory entry;
        entry.proxyEntryHash = outerHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0); // no match
        entry.success = true;
        entry.returnData = "";
        entry.rollingHash = h;
        _loadSingle(entry, new StaticLookup[](0));

        (bool ok,) = outerProxy.call(outerData);
        assertTrue(ok, "no-match reentrant folds CALL_NOT_FOUND; entry hash matches and commits");
    }

    // ──────────────────────────────────────────────
    //  Incoming static call inside an entry
    // ──────────────────────────────────────────────

    /// An entry whose top-level incoming call is `isStatic` dispatches via STATICCALL (read-only),
    /// reading `target.getValue()`. Covers the static branch of `_processNCalls`.
    function test_IncomingStaticCall_InsideEntry() public {
        target.setValue(55);
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory cd = abi.encodeCall(ViewTargetL2.getValue, ());
        bytes32 proxyEntryHash = _ccHash(false, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, 0, cd);
        bytes32 staticCallHash = _ccHash(true, address(this), REMOTE_ROLLUP_ID, address(target), TEST_ROLLUP_ID, 0, cd);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: address(this),
            sourceRollupId: REMOTE_ROLLUP_ID,
            targetAddress: address(target),
            value: 0,
            data: cd
        });
        bytes32 h = _hCallEnd(_hCallBegin(_seed(proxyEntryHash), staticCallHash), true, abi.encode(uint256(55)));

        ExecutionEntry memory entry;
        entry.proxyEntryHash = proxyEntryHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entry.success = true;
        entry.returnData = "";
        entry.rollingHash = h;
        _loadSingle(entry, new StaticLookup[](0));

        (bool ok,) = proxy.call(cd);
        assertTrue(ok, "static incoming call dispatches via STATICCALL and reads getValue()");
        assertEq(target.value(), 55);
    }

    /// A static incoming call carrying non-zero value is malformed → `StaticCallWithValue`.
    function test_IncomingStaticCall_WithValueReverts() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory cd = abi.encodeCall(ViewTargetL2.getValue, ());
        bytes32 proxyEntryHash = _ccHash(false, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, 0, cd);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: true,
            sourceAddress: address(this),
            sourceRollupId: REMOTE_ROLLUP_ID,
            targetAddress: address(target),
            value: 1, // static + value → reject
            data: cd
        });
        ExecutionEntry memory entry;
        entry.proxyEntryHash = proxyEntryHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entry.success = true;
        entry.returnData = "";
        entry.rollingHash = bytes32(0); // unreached
        _loadSingle(entry, new StaticLookup[](0));

        (bool ok, bytes memory ret) = proxy.call(cd);
        assertFalse(ok);
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        assertEq(sel, EEZBase.StaticCallWithValue.selector);
    }

    // ──────────────────────────────────────────────
    //  RevertSpanOutOfBounds
    // ──────────────────────────────────────────────

    /// A `revertNextNCalls` span overrunning its call array reverts `RevertSpanOutOfBounds`.
    function test_RevertSpanOutOfBounds() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory cd = abi.encodeCall(ViewTargetL2.setValue, (1));
        bytes32 proxyEntryHash = _ccHash(false, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, 0, cd);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            revertNextNCalls: 2, // span of 2 overruns the single-element array
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: REMOTE_ROLLUP_ID,
            targetAddress: address(target),
            value: 0,
            data: cd
        });
        ExecutionEntry memory entry;
        entry.proxyEntryHash = proxyEntryHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entry.success = true;
        entry.returnData = "";
        entry.rollingHash = bytes32(0); // unreached
        _loadSingle(entry, new StaticLookup[](0));

        (bool ok, bytes memory ret) = proxy.call(cd);
        assertFalse(ok);
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        assertEq(sel, EEZL2.RevertSpanOutOfBounds.selector);
    }
}

contract RejectEther {
    // No payable receive/fallback → any value transfer reverts.

    }
