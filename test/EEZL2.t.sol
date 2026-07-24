// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {CrossChainProxy} from "../src/base/CrossChainProxy.sol";
import {
    ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    StaticExecutionEntry
} from "../src/interfaces/IEEZL2.sol";
import {Counter, SafeCounterAndProxy} from "./mocks/CounterContracts.sol";
import {BaseL2} from "./BaseL2.t.sol";

contract L2TestTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    function setAndReturn(uint256 _value) external returns (uint256) {
        value = _value;
        return _value;
    }

    function reverting() external pure {
        revert("boom");
    }

    receive() external payable {}
}

contract RevertingTarget {
    fallback() external payable {
        revert("always reverts");
    }
}

contract EEZL2Test is BaseL2 {
    L2TestTarget public target;

    function setUp() public override {
        super.setUp();
        target = new L2TestTarget();
    }

    // ── Constructor ──

    function test_Constructor_SetsRollupId() public view {
        assertEq(manager.ROLLUP_ID(), TEST_ROLLUP_ID);
    }

    function test_Constructor_SetsSystemAddress() public view {
        assertEq(manager.SYSTEM_ADDRESS(), SYSTEM_ADDRESS);
    }

    // ── loadExecutionTable ──

    function test_LoadExecutionTable_RevertsIfNotSystem() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](0);
        StaticExecutionEntry[] memory noStatic = new StaticExecutionEntry[](0);
        vm.expectRevert(EEZL2.Unauthorized.selector);
        manager.loadExecutionTable(entries, noStatic);
        vm.prank(address(0xBEEF));
        vm.expectRevert(EEZL2.Unauthorized.selector);
        manager.loadExecutionTable(entries, noStatic);
    }

    function test_LoadExecutionTable_SystemCanLoadEmpty() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](0);
        StaticExecutionEntry[] memory noStatic = new StaticExecutionEntry[](0);
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries, noStatic);
        assertEq(manager.entryIndex(), 0);
    }

    /// @notice Loading stores the entry in the table: the cursor starts at 0, the stored entry is
    ///         matchable by a proxy call, and consuming it advances the cursor.
    function test_LoadExecutionTable_StoresEntries() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);

        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        uint64 callGas = _probeOutgoing(address(this), proxy, 0, callData);
        bytes32 crossChainCallHash =
            _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, callData);

        CrossChainCall memory cc = _cc(address(target), 0, callData, address(this), REMOTE_ROLLUP_ID);

        bytes32 rollingHash = _rhSingle(crossChainCallHash, cc, true, "");

        ExecutionEntry memory entry = _buildSimpleEntry(crossChainCallHash, cc, "", rollingHash);
        _loadSingle(entry);
        assertEq(manager.entryIndex(), 0, "cursor starts before the stored entry");

        (bool success,) = proxy.call{gas: CALL_GAS}(callData);
        assertTrue(success);
        assertEq(target.value(), 42);
        assertEq(manager.entryIndex(), 1, "consuming the stored entry advances the cursor");
    }

    function test_LoadExecutionTable_MultipleEntries() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        uint64 callGas = _probeOutgoing(address(this), proxy, 0, callData);
        bytes32 crossChainCallHash =
            _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, callData);

        CrossChainCall memory cc = _cc(address(target), 0, callData, address(this), REMOTE_ROLLUP_ID);

        bytes32 rollingHash = _rhSingle(crossChainCallHash, cc, true, "");

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);
        for (uint256 i = 0; i < 3; i++) {
            entries[i] = _buildSimpleEntry(crossChainCallHash, cc, "", rollingHash);
        }
        _loadEntries(entries, new StaticExecutionEntry[](0));

        for (uint256 i = 0; i < 3; i++) {
            (bool success,) = proxy.call{gas: CALL_GAS}(callData);
            assertTrue(success);
        }
        vm.expectRevert(EEZL2.EntryNotFound.selector);
        (bool s,) = proxy.call{gas: CALL_GAS}(callData);
        s;
    }

    // ── createCrossChainProxy ──

    function test_CreateCrossChainProxy() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        (bool isProxy, address origAddr, uint64 origRollup) = manager.authorizedProxies(proxy);
        assertTrue(isProxy);
        assertEq(origAddr, address(target));
        assertEq(uint256(origRollup), REMOTE_ROLLUP_ID);
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(proxy)
        }
        assertTrue(codeSize > 0);
    }

    function test_CreateCrossChainProxy_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit EEZBase.CrossChainProxyCreated(
            manager.computeCrossChainProxyAddress(address(target), REMOTE_ROLLUP_ID), address(target), REMOTE_ROLLUP_ID
        );
        manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
    }

    function test_ComputeCrossChainProxyAddress_MatchesActual() public {
        address computed = manager.computeCrossChainProxyAddress(address(target), REMOTE_ROLLUP_ID);
        address actual = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        assertEq(computed, actual);
    }

    function test_MultipleProxies_DifferentEEZ() public {
        address proxy1 = manager.createCrossChainProxy(address(target), 1);
        address proxy2 = manager.createCrossChainProxy(address(target), 2);
        assertTrue(proxy1 != proxy2);
    }

    function test_MultipleProxies_DifferentAddresses() public {
        L2TestTarget target2 = new L2TestTarget();
        address proxy1 = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        address proxy2 = manager.createCrossChainProxy(address(target2), REMOTE_ROLLUP_ID);
        assertTrue(proxy1 != proxy2);
    }

    // ── executeCrossChainCall ──

    function test_ExecuteCrossChainCall_RevertsUnauthorizedProxy() public {
        vm.expectRevert(EEZBase.UnauthorizedProxy.selector);
        manager.executeCrossChainCall(address(this), "");
    }

    function test_ExecuteCrossChainCall_RevertsExecutionNotInCurrentBlock() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        vm.expectRevert(EEZL2.ExecutionNotInCurrentBlock.selector);
        (bool s,) = proxy.call(callData);
        s;
    }

    function test_ExecuteCrossChainCall_RevertsExecutionNotFound() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);

        _loadEntries(new ExecutionEntry[](0), new StaticExecutionEntry[](0));

        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));
        vm.expectRevert(EEZL2.EntryNotFound.selector);
        (bool s,) = proxy.call(callData);
        s;
    }

    // ──────────────────────────────────────────────
    //  Top-level reverting entry
    // ──────────────────────────────────────────────
    //
    // A top-level cross-chain call that must revert is a normal `ExecutionEntry` with `success == false`:
    // `_consumeAndExecute` matches it by `proxyEntryHash`, `_executeEntry` runs it, verifies the rolling
    // hash, then reverts with the cached `returnData`. The revert rolls back the `entryIndex` advance,
    // so the entry is never consumed and an identical second call reverts identically. The negative case
    // (no matching entry → ExecutionNotFound) is covered by
    // `test_ExecuteCrossChainCall_RevertsExecutionNotFound` above.
    function test_RevertedLookup_TopLevel_Reverts() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);

        bytes memory cd = abi.encodeCall(L2TestTarget.setValue, (7));
        bytes memory payload = hex"deadbeef";
        // Gas-folding key; sourceRollupId in the L2 proxy-entry hash is forced to ROLLUP_ID (== TEST_ROLLUP_ID).
        uint64 callGas = _probeOutgoing(address(this), proxy, 0, cd);
        bytes32 h = _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, cd);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].proxyEntryHash = h;
        entries[0].incomingCalls = new CrossChainCall[](0);
        entries[0].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entries[0].rollingHash = _hEntryBeginL2(h); // no calls ⇒ rolling hash is just the seed
        entries[0].success = false;
        entries[0].returnData = payload;

        _loadEntries(entries, new StaticExecutionEntry[](0));

        uint256 idxBefore = manager.entryIndex();

        (bool ok, bytes memory ret) = proxy.call{gas: CALL_GAS}(cd);
        assertFalse(ok);
        assertEq(ret, payload);
        assertEq(manager.entryIndex(), idxBefore, "reverting entry must not advance entryIndex");

        // Repeatable: a second identical call reverts identically, still no advance.
        (ok, ret) = proxy.call{gas: CALL_GAS}(cd);
        assertFalse(ok);
        assertEq(ret, payload);
        assertEq(manager.entryIndex(), idxBefore);
    }

    /// @notice REVERTED reentrant (outgoing) call (L2): a reentrant call fired during an entry resolves
    ///         against the entry's unified `expectedOutgoingCalls` table with `success == false`, reverts
    ///         with the cached returnData, and the caller's try/catch absorbs it.
    function test_NestedRevertedLookup_EntryScoped_RevertsAndCatches() public {
        // Inner target: proxy on L2 for a Counter living on MAINNET (rollup 0).
        address counterL1 = address(0xC0117E1);
        address counterProxy = manager.createCrossChainProxy(counterL1, MAINNET);
        SafeCounterAndProxy scap = new SafeCounterAndProxy(Counter(counterProxy));

        address outerProxy = manager.createCrossChainProxy(address(scap), REMOTE_ROLLUP_ID);
        bytes memory outerCd = abi.encodeCall(SafeCounterAndProxy.incrementProxy, ());
        bytes memory innerCd = abi.encodeCall(Counter.increment, ());

        // Gas-folding keys: the outer (host) call attaches OUTER_CALL_GAS so the nested site can
        // still forward its full explicit gas; the mock's inner call site attaches CALL_GAS.
        uint64 outerGas = _probeOutgoing(address(this), outerProxy, 0, outerCd, OUTER_CALL_GAS);
        uint64 innerGas = _probeOutgoing(address(scap), counterProxy, 0, innerCd);
        bytes32 outerHash = _outgoingCallHash(address(this), address(scap), REMOTE_ROLLUP_ID, 0, outerGas, outerCd);
        // L2 forces sourceRollupId = ROLLUP_ID for reentrant calls it issues.
        bytes32 innerHash = _outgoingCallHash(address(scap), counterL1, MAINNET, 0, innerGas, innerCd);

        CrossChainCall memory cc = _cc(address(scap), 0, outerCd, address(this), REMOTE_ROLLUP_ID);

        // Rolling-hash trace: the inner reentrant fires after the outer call's CALL_BEGIN, so the live
        // `_rollingHash` at that instant (`rhAtFire`) keys the outgoing entry. The reverted reentrant
        // resolution folds NESTED_BEGIN(innerHash) and then reverts — `revertedOrStaticRollingHash` is the
        // hash right after that fold. The catch rolls the fold + cursor back, so the outer call closes with
        // CALL_END(true, "").
        bytes32 rhAtFire = _hCallBegin(_hEntryBeginL2(outerHash), _incomingCallHash(cc));
        bytes32 outerRolling = _hCallEnd(rhAtFire, true, "");

        ExecutionEntry memory entry = _buildSimpleEntry(outerHash, cc, "", outerRolling);

        ExpectedOutgoingCrossChainCall[] memory outgoing = new ExpectedOutgoingCrossChainCall[](1);
        outgoing[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: _expectedOutgoingHash(innerHash, rhAtFire),
            incomingCalls: new CrossChainCall[](0),
            revertedOrStaticRollingHash: _hNestedBegin(rhAtFire, innerHash),
            success: false,
            returnData: bytes("inner reverts")
        });
        entry.expectedOutgoingCalls = outgoing;
        _loadSingle(entry);

        (bool ok,) = outerProxy.call{gas: OUTER_CALL_GAS}(outerCd);
        assertTrue(ok, "outer call must succeed");
        assertEq(scap.counter(), 1, "outer call must run");
        assertTrue(scap.lastCallFailed(), "inner call must revert via the outgoing reentrant table");
        assertEq(scap.targetCounter(), 0, "inner call must not have executed");
    }

    /// @notice A consumed entry surfaces its cached result to the caller: the proxy call returns the
    ///         entry's `returnData` (empty here — `setValue` has no return) alongside the state effect.
    function test_ExecuteCrossChainCall_SimpleResult() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        uint64 callGas = _probeOutgoing(address(this), proxy, 0, callData);
        bytes32 crossChainCallHash =
            _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, callData);

        CrossChainCall memory cc = _cc(address(target), 0, callData, address(this), REMOTE_ROLLUP_ID);

        bytes32 rollingHash = _rhSingle(crossChainCallHash, cc, true, "");

        ExecutionEntry memory entry = _buildSimpleEntry(crossChainCallHash, cc, "", rollingHash);
        _loadSingle(entry);

        (bool success, bytes memory ret) = proxy.call{gas: CALL_GAS}(callData);
        assertTrue(success);
        assertEq(ret, "", "caller receives the entry's (empty) returnData, not the target's");
        assertEq(target.value(), 42);
    }

    function test_ExecuteCrossChainCall_ResultWithReturnData() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.getValue, ());

        uint64 callGas = _probeOutgoing(address(this), proxy, 0, callData);
        bytes32 crossChainCallHash =
            _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, callData);

        CrossChainCall memory cc = _cc(address(target), 0, callData, address(this), REMOTE_ROLLUP_ID);

        bytes memory retData = abi.encode(uint256(0));
        bytes32 rollingHash = _rhSingle(crossChainCallHash, cc, true, retData);

        bytes memory entryReturnData = abi.encode(uint256(999));

        ExecutionEntry memory entry = _buildSimpleEntry(crossChainCallHash, cc, entryReturnData, rollingHash);
        _loadSingle(entry);

        (bool success, bytes memory ret) = proxy.call{gas: CALL_GAS}(callData);
        assertTrue(success);
        assertEq(ret, entryReturnData);
    }

    // NOTE: a reverting top-level cross-chain call is now a normal `ExecutionEntry { success: false }`
    // (run, verified, then reverted with `returnData` — see `test_RevertedLookup_TopLevel_Reverts`);
    // reverting REENTRANT calls are `success == false` `ExpectedOutgoingCrossChainCall`s, and a top-level
    // reverting READ is a `StaticExecutionEntry`. There is no separate `failed` flag any more.

    function test_ExecuteCrossChainCall_ConsumesInFifoOrder() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.getValue, ());

        uint64 callGas = _probeOutgoing(address(this), proxy, 0, callData);
        bytes32 crossChainCallHash =
            _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, callData);

        CrossChainCall memory cc = _cc(address(target), 0, callData, address(this), REMOTE_ROLLUP_ID);

        bytes memory retData = abi.encode(uint256(0));
        bytes32 rollingHash = _rhSingle(crossChainCallHash, cc, true, retData);

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _buildSimpleEntry(crossChainCallHash, cc, abi.encode(uint256(111)), rollingHash);
        entries[1] = _buildSimpleEntry(crossChainCallHash, cc, abi.encode(uint256(222)), rollingHash);
        _loadEntries(entries, new StaticExecutionEntry[](0));

        (bool s1, bytes memory r1) = proxy.call{gas: CALL_GAS}(callData);
        assertTrue(s1);
        assertEq(abi.decode(r1, (uint256)), 111);
        (bool s2, bytes memory r2) = proxy.call{gas: CALL_GAS}(callData);
        assertTrue(s2);
        assertEq(abi.decode(r2, (uint256)), 222);
        vm.expectRevert(EEZL2.EntryNotFound.selector);
        (bool s3,) = proxy.call{gas: CALL_GAS}(callData);
        s3;
    }

    // ── CrossChainProxy direct tests ──

    function test_Proxy_ExecuteOnBehalf_NonManagerFallsThrough() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        CrossChainProxy p = CrossChainProxy(payable(proxy));
        vm.prank(address(0xDEAD));
        vm.expectRevert(EEZL2.ExecutionNotInCurrentBlock.selector);
        p.executeOnBehalf(address(target), 0, abi.encodeCall(L2TestTarget.setValue, (42)));
    }

    // ── Rolling hash mismatch ──

    function test_RollingHashMismatch_Reverts() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        uint64 callGas = _probeOutgoing(address(this), proxy, 0, callData);
        bytes32 crossChainCallHash =
            _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, callData);

        CrossChainCall memory cc = _cc(address(target), 0, callData, address(this), REMOTE_ROLLUP_ID);

        ExecutionEntry memory entry = _buildSimpleEntry(crossChainCallHash, cc, "", bytes32(uint256(0xDEAD)));
        _loadSingle(entry);

        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        (bool s,) = proxy.call{gas: CALL_GAS}(callData);
        s;
    }

    // ── Unaccounted incoming calls ──
    //
    // The dedicated `UnconsumedIncomingCalls` error is gone: `_executeEntry` runs the WHOLE
    // `incomingCalls` array (no callCount partition, no cursor-vs-length check), so an entry declaring
    // more calls than its rolling hash accounts for diverges the hash and is caught by `RollingHashMismatch`.
    function test_UnconsumedIncomingCalls_Reverts() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        uint64 callGas = _probeOutgoing(address(this), proxy, 0, callData);
        bytes32 crossChainCallHash =
            _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, callData);

        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = _cc(address(target), 0, callData, address(this), REMOTE_ROLLUP_ID);
        calls[1] = _cc(address(target), 0, abi.encodeCall(L2TestTarget.setValue, (99)), address(this), REMOTE_ROLLUP_ID);

        // rollingHash accounts for only the FIRST call; processing both diverges it.
        bytes32 rollingHash = _rhSingle(crossChainCallHash, calls[0], true, "");

        ExecutionEntry memory entry;
        entry.proxyEntryHash = crossChainCallHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entry.rollingHash = rollingHash;
        entry.success = true;
        entry.returnData = "";

        _loadSingle(entry);

        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        (bool s,) = proxy.call{gas: CALL_GAS}(callData);
        s;
    }

    // ── Multiple calls in entry ──

    function test_ExecuteCrossChainCall_MultipleCalls() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        uint64 callGas = _probeOutgoing(address(this), proxy, 0, callData);
        bytes32 crossChainCallHash =
            _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, callData);

        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = _cc(address(target), 0, abi.encodeCall(L2TestTarget.setValue, (10)), address(this), REMOTE_ROLLUP_ID);
        calls[1] = _cc(address(target), 0, abi.encodeCall(L2TestTarget.setValue, (20)), address(this), REMOTE_ROLLUP_ID);

        bytes32 hash = _hEntryBeginL2(crossChainCallHash);
        hash = _hCallBegin(hash, _incomingCallHash(calls[0]));
        hash = _hCallEnd(hash, true, "");
        hash = _hCallBegin(hash, _incomingCallHash(calls[1]));
        hash = _hCallEnd(hash, true, "");

        ExecutionEntry memory entry;
        entry.proxyEntryHash = crossChainCallHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entry.rollingHash = hash;
        entry.success = true;
        entry.returnData = "";

        _loadSingle(entry);

        (bool success,) = proxy.call{gas: CALL_GAS}(callData);
        assertTrue(success);
        assertEq(target.value(), 20);
    }

    // ── executeInContextAndRevert: NotSelf ──

    function test_ExecuteInContext_NotSelf() public {
        vm.expectRevert(EEZBase.NotSelf.selector);
        manager.executeInContextAndRevert(new CrossChainCall[](0));
    }

    // ── revertNextNCalls (isolated context) ──

    function test_ExecuteCrossChainCall_WithRevertSpan() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        RevertingTarget revTarget = new RevertingTarget();
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        uint64 callGas = _probeOutgoing(address(this), proxy, 0, callData);
        bytes32 crossChainCallHash =
            _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, callData);

        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 1,
            isStatic: false,
            sourceAddress: address(this),
            sourceRollupId: REMOTE_ROLLUP_ID,
            targetAddress: address(revTarget),
            value: 0,
            data: hex"deadbeef"
        });

        bytes memory revertData = abi.encodeWithSignature("Error(string)", "always reverts");
        // The forced-revert span runs the call inside `executeInContextAndRevert`; its committed rolling
        // hash (CALL_BEGIN(cch) / CALL_END(false, revertData)) escapes via `ContextResult`.
        bytes32 hash = _rhSingle(crossChainCallHash, calls[0], false, revertData);

        ExecutionEntry memory entry;
        entry.proxyEntryHash = crossChainCallHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entry.rollingHash = hash;
        entry.success = true;
        entry.returnData = "";

        _loadSingle(entry);

        (bool success,) = proxy.call{gas: CALL_GAS}(callData);
        assertTrue(success);
    }

    // ══════════════════════════════════════════════
    //  Event tests
    // ══════════════════════════════════════════════

    // ── ExecutionTableLoaded ──

    function _findExecutionTableLoadedLog(Vm.Log[] memory logs) internal pure returns (bool found, uint256 idx) {
        bytes32 sel = EEZL2.ExecutionTableLoaded.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    function test_ExecutionTableLoaded_EmitsOnLoad() public {
        bytes32 hash1 = bytes32(uint256(1));
        bytes32 hash2 = bytes32(uint256(2));

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _buildNoCalls(hash1, "");
        entries[1] = _buildNoCalls(hash2, "");

        vm.recordLogs();
        _loadEntries(entries, new StaticExecutionEntry[](0));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found,) = _findExecutionTableLoadedLog(logs);
        assertTrue(found, "ExecutionTableLoaded event not found");
    }

    function test_ExecutionTableLoaded_EmptyBatch() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](0);

        vm.recordLogs();
        _loadEntries(entries, new StaticExecutionEntry[](0));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found,) = _findExecutionTableLoadedLog(logs);
        assertTrue(found, "ExecutionTableLoaded event not found for empty batch");
    }

    // ── ExecutionConsumed ──

    function test_ExecutionConsumed_EmitsOnConsume() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        uint64 callGas = _probeOutgoing(address(this), proxy, 0, callData);
        bytes32 crossChainCallHash =
            _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, callData);

        CrossChainCall memory cc = _cc(address(target), 0, callData, address(this), REMOTE_ROLLUP_ID);

        bytes32 rollingHash = _rhSingle(crossChainCallHash, cc, true, "");

        ExecutionEntry memory entry = _buildSimpleEntry(crossChainCallHash, cc, "", rollingHash);
        _loadSingle(entry);

        vm.recordLogs();
        (bool success,) = proxy.call{gas: CALL_GAS}(callData);
        assertTrue(success);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = EEZL2.ExecutionConsumed.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], crossChainCallHash);
                found = true;
                break;
            }
        }
        assertTrue(found, "ExecutionConsumed event not found");
    }

    function test_ExecutionConsumed_EmitsForEachConsumption() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        uint64 callGas = _probeOutgoing(address(this), proxy, 0, callData);
        bytes32 crossChainCallHash =
            _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, callData);

        CrossChainCall memory cc = _cc(address(target), 0, callData, address(this), REMOTE_ROLLUP_ID);

        bytes32 rollingHash = _rhSingle(crossChainCallHash, cc, true, "");

        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _buildSimpleEntry(crossChainCallHash, cc, "", rollingHash);
        entries[1] = _buildSimpleEntry(crossChainCallHash, cc, "", rollingHash);
        _loadEntries(entries, new StaticExecutionEntry[](0));

        vm.recordLogs();
        (bool s1,) = proxy.call{gas: CALL_GAS}(callData);
        assertTrue(s1);
        (bool s2,) = proxy.call{gas: CALL_GAS}(callData);
        assertTrue(s2);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = EEZL2.ExecutionConsumed.selector;
        uint256 consumedCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], crossChainCallHash);
                consumedCount++;
            }
        }
        assertEq(consumedCount, 2);
    }

    // ── CrossChainCallExecuted ──

    function test_CrossChainCallExecuted_EmitsOnProxyCall() public {
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes memory callData = abi.encodeCall(L2TestTarget.setValue, (42));

        uint64 callGas = _probeOutgoing(address(this), proxy, 0, callData);
        bytes32 crossChainCallHash =
            _outgoingCallHash(address(this), address(target), REMOTE_ROLLUP_ID, 0, callGas, callData);

        CrossChainCall memory cc = _cc(address(target), 0, callData, address(this), REMOTE_ROLLUP_ID);

        bytes32 rollingHash = _rhSingle(crossChainCallHash, cc, true, "");

        ExecutionEntry memory entry = _buildSimpleEntry(crossChainCallHash, cc, "", rollingHash);
        _loadSingle(entry);

        vm.recordLogs();
        (bool success,) = proxy.call{gas: CALL_GAS}(callData);
        assertTrue(success);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = EEZL2.CrossChainCallExecuted.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], crossChainCallHash);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), proxy);
                (address src, bytes memory cd, uint256 val, uint64 emittedGas) =
                    abi.decode(logs[i].data, (address, bytes, uint256, uint64));
                assertEq(src, address(this));
                assertEq(cd, callData);
                assertEq(val, 0);
                assertEq(emittedGas, 0, "callGas is fixed 0 (fixture runs useGasLeft = false)");
                assertEq(emittedGas, callGas, "emitted callGas equals the probed value");
                found = true;
                break;
            }
        }
        assertTrue(found, "CrossChainCallExecuted event not found");
    }
}
