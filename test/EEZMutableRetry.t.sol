// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {BaseL2} from "./BaseL2.t.sol";
import {EEZ} from "../src/EEZ.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {EEZProxy} from "../src/proxy/EEZProxy.sol";
import {ExecutionEntry, L2ToL1Call, ExpectedL1ToL2Call} from "../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2Entry,
    CrossChainCall,
    StaticExecutionEntryL2,
    ExpectedOutgoingCrossChainCall
} from "../src/interfaces/IEEZL2.sol";
import {EEZExpressivenessL1Test} from "./EEZExpressiveness.t.sol";

contract RetryEffects {
    uint256 public calls;
    address public nestedProxy;

    function setNestedProxy(address proxy) external {
        nestedProxy = proxy;
    }

    function run() external payable returns (uint256) {
        ++calls;
        if (nestedProxy != address(0)) {
            (bool ok, bytes memory result) = nestedProxy.call("nested");
            require(ok && keccak256(result) == keccak256(abi.encode(uint256(7))), "nested result");
        }
        return calls;
    }
}

contract EEZMutableRetryL1Test is Base {
    RetryEffects internal effect;
    RollupHandle internal r;
    address internal proxy;
    bytes32 internal key;
    address internal metaProxy;
    bytes internal metaResult;

    function setUp() public {
        setUpBase();
        r = _makeRollup(bytes32(0));
        effect = new RetryEffects();
        proxy = rollups.createCrossChainProxy(L2_REMOTE, uint64(r.id));
        key = _ccHash(false, address(this), 0, L2_REMOTE, uint64(r.id), 0, "run");
    }

    function _rows(uint256 value) internal view returns (ExecutionEntry[] memory rows) {
        rows = new ExecutionEntry[](2);
        for (uint256 i; i < 2; i++) {
            rows[i] = _shellEntry(r.id, _oneDelta(r.id, bytes32(0), bytes32(i + 1), -int192(int256(value))));
            rows[i].proxyEntryHash = key;
            rows[i].l2ToL1Calls =
                _oneCall(_call(L2_SENDER, uint64(r.id), address(effect), value, abi.encodeCall(RetryEffects.run, ())));
            bytes32 callback = _ccHash(
                false, L2_SENDER, uint64(r.id), address(effect), 0, value, abi.encodeCall(RetryEffects.run, ())
            );
            rows[i].rollingHash = _hCallEnd(
                _hCallBegin(_hEntryBegin(rows[i].rollupUpdates, key), callback), true, abi.encode(uint256(1))
            );
            rows[i].returnData = abi.encode(i);
        }
        rows[0].rollingHash = bytes32(uint256(0xbad));
    }

    function test_RejectedCandidateRollsBackEffectsAndValue() public {
        _fundRollup(r.id, 3 ether);
        vm.deal(address(this), 1 ether);
        key = _ccHash(false, address(this), 0, L2_REMOTE, uint64(r.id), 1 ether, "run");
        ExecutionEntry[] memory rows = _rows(2 ether);
        // One inbound ETH offsets part of the two-ETH callback payout.
        for (uint256 i; i < rows.length; i++) {
            rows[i].rollupUpdates[0].etherDelta = -1 ether;
        }
        rows[1].rollingHash = _hCallEnd(
            _hCallBegin(
                _hEntryBegin(rows[1].rollupUpdates, key),
                _ccHash(
                    false, L2_SENDER, uint64(r.id), address(effect), 0, 2 ether, abi.encodeCall(RetryEffects.run, ())
                )
            ),
            true,
            abi.encode(uint256(1))
        );
        _postBatchOne(r, rows, _emptyStaticEntries(), 0, 0);
        (bool ok, bytes memory result) = proxy.call{value: 1 ether}("run");
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(1)));
        assertEq(effect.calls(), 1);
        assertEq(address(effect).balance, 2 ether);
        assertEq(address(rollups).balance, 2 ether);
        assertEq(_getRollupEtherBalance(r.id), 2 ether);
        assertEq(rollups.entryQueueIndex(uint64(r.id)), 2);
        assertEq(_getRollupState(r.id), bytes32(uint256(2)));
        // Consumption and transient cleanup must allow a subsequent call in this transaction.
        key = _ccHash(false, address(this), 0, L2_REMOTE, uint64(r.id), 0, "run");
        ExecutionEntry[] memory next = new ExecutionEntry[](1);
        next[0] = _shellEntry(r.id, _oneDelta(r.id, bytes32(uint256(2)), bytes32(uint256(3)), 0));
        next[0].proxyEntryHash = key;
        next[0].rollingHash = _hEntryBegin(next[0].rollupUpdates, key);
        _postBatchOne(r, next, _emptyStaticEntries(), 0, 0);
        (ok,) = proxy.call("run");
        assertTrue(ok);
        assertEq(_getRollupState(r.id), bytes32(uint256(3)));
    }

    function executeMetaCrossChainTransactions() external {
        require(msg.sender == address(rollups));
        (bool ok, bytes memory result) = metaProxy.call("run");
        require(ok);
        metaResult = result;
    }

    function test_TransientCandidatesRetry() public {
        metaProxy = proxy;
        _postBatchOne(r, _rows(0), _emptyStaticEntries(), 2, 0);
        assertEq(metaResult, abi.encode(uint256(1)));
        assertEq(effect.calls(), 1);
        assertEq(_getRollupState(r.id), bytes32(uint256(2)));
    }

    function test_AllMismatchesRestoreStateAndProxyCreation() public {
        _fundRollup(r.id, 3 ether);
        ExecutionEntry[] memory rows = _rows(2 ether);
        rows[1].rollingHash = rows[0].rollingHash;
        _postBatchOne(r, rows, _emptyStaticEntries(), 0, 0);
        address callbackProxy = rollups.computeCrossChainProxyAddress(L2_SENDER, uint64(r.id));
        (bool ok, bytes memory result) = proxy.call("run");
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector));
        assertEq(effect.calls(), 0);
        assertEq(address(effect).balance, 0);
        assertEq(_getRollupState(r.id), bytes32(0));
        assertEq(rollups.entryQueueIndex(uint64(r.id)), 0);
        assertEq(_getRollupEtherBalance(r.id), 3 ether);
        assertEq(callbackProxy.code.length, 0);
    }

    function _terminal(bytes memory payload) internal {
        ExecutionEntry[] memory rows = _rows(0);
        rows[0].rollingHash = _hCallEnd(
            _hCallBegin(
                _hEntryBegin(rows[0].rollupUpdates, key),
                _ccHash(false, L2_SENDER, uint64(r.id), address(effect), 0, 0, abi.encodeCall(RetryEffects.run, ()))
            ),
            true,
            abi.encode(uint256(1))
        );
        rows[0].success = false;
        rows[0].returnData = payload;
        _postBatchOne(r, rows, _emptyStaticEntries(), 0, 0);
        (bool ok, bytes memory result) = proxy.call("run");
        assertFalse(ok);
        assertEq(result, payload);
        assertEq(effect.calls(), 0);
        assertEq(rollups.entryQueueIndex(uint64(r.id)), 0);
        assertEq(_getRollupState(r.id), bytes32(0));
    }

    function test_ApplicationErrorsAreTerminal() public {
        _terminal(abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector));
        _terminal("");
        _terminal(abi.encodePacked(EEZBase.RollingHashMismatch.selector, uint256(1)));
    }

    function testFuzz_ApplicationRevertIsTerminal(bytes memory payload) public {
        _terminal(payload);
    }

    function test_OtherValidationErrorsAreTerminal() public {
        ExecutionEntry[] memory rows = _rows(0);
        rows[0].rollupUpdates[0].etherDelta = 1;
        rows[0].l2ToL1Calls = new L2ToL1Call[](0);
        rows[0].rollingHash = _hEntryBegin(rows[0].rollupUpdates, key);
        _postBatchOne(r, rows, _emptyStaticEntries(), 0, 0);
        (bool ok, bytes memory result) = proxy.call("run");
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZ.EtherDeltaMismatch.selector));
        assertEq(effect.calls(), 0);
    }

    function test_RejectedCandidateWithNestedCallRestoresContext() public {
        effect.setNestedProxy(proxy);
        ExecutionEntry[] memory rows = _rows(0);
        bytes32 callbackHash =
            _ccHash(false, L2_SENDER, uint64(r.id), address(effect), 0, 0, abi.encodeCall(RetryEffects.run, ()));
        bytes32 nestedHash = _ccHash(false, address(effect), 0, L2_REMOTE, uint64(r.id), 0, "nested");
        for (uint256 i; i < rows.length; i++) {
            bytes32 fireHash = _hCallBegin(_hEntryBegin(rows[i].rollupUpdates, key), callbackHash);
            rows[i].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](1);
            rows[i].expectedL1ToL2Calls[0].expectedL1toL2Hash = _expectedL1toL2Hash(nestedHash, fireHash);
            rows[i].expectedL1ToL2Calls[0].success = true;
            rows[i].expectedL1ToL2Calls[0].returnData = abi.encode(uint256(7));
            rows[i].rollingHash =
                _hCallEnd(_hNestedEnd(_hNestedBegin(fireHash, nestedHash)), true, abi.encode(uint256(1)));
        }
        rows[0].rollingHash = bytes32(uint256(0xbad));
        _postBatchOne(r, rows, _emptyStaticEntries(), 0, 0);
        (bool ok, bytes memory result) = proxy.call("run");
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(1)));
        assertEq(effect.calls(), 1);
        assertEq(rollups.entryQueueIndex(uint64(r.id)), 2);
    }

    function test_NoMatchKeepsExecutionNotFound() public {
        _postBatchOne(r, _rows(0), _emptyStaticEntries(), 0, 0);
        (bool ok, bytes memory result) = proxy.call("different");
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZBase.ExecutionNotFound.selector));
    }

    function test_ZeroHashEntriesRemainSequential() public {
        ExecutionEntry[] memory rows = new ExecutionEntry[](3);
        for (uint256 i; i < 3; i++) {
            rows[i] = _shellEntry(r.id, _oneDelta(r.id, bytes32(0), bytes32(i), 0));
            rows[i].rollingHash = _hEntryBegin(rows[i].rollupUpdates, bytes32(0));
        }
        // A nonzero first row keeps the zero-hash entries in the deferred queue.
        rows[0].proxyEntryHash = key;
        rows[0].rollingHash = _hEntryBegin(rows[0].rollupUpdates, key);
        rows[1].rollingHash = bytes32(uint256(0xbad));
        _postBatchOne(r, rows, _emptyStaticEntries(), 0, 0);
        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        rollups.executeL2Txs(uint64(r.id));
        assertEq(rollups.entryQueueIndex(uint64(r.id)), 0);
        assertEq(_getRollupState(r.id), bytes32(0));
    }

    function test_GasFirstMatchAndRetry() public {
        ExecutionEntry[] memory rows = _rows(0);
        _postBatchOne(r, rows, _emptyStaticEntries(), 0, 0);
        uint256 snapshot = vm.snapshotState();
        uint256 beforeGas = gasleft();
        (bool ok,) = proxy.call("run");
        uint256 retryGas = beforeGas - gasleft();
        assertTrue(ok);
        vm.revertToState(snapshot);
        // Make the first candidate valid with the same callback workload.
        rows[0].rollingHash = _hCallEnd(
            _hCallBegin(
                _hEntryBegin(rows[0].rollupUpdates, key),
                _ccHash(false, L2_SENDER, uint64(r.id), address(effect), 0, 0, abi.encodeCall(RetryEffects.run, ()))
            ),
            true,
            abi.encode(uint256(1))
        );
        _postBatchOne(r, rows, _emptyStaticEntries(), 0, 0);
        beforeGas = gasleft();
        (ok,) = proxy.call("run");
        uint256 firstGas = beforeGas - gasleft();
        assertTrue(ok);
        emit log_named_uint("first candidate gas", firstGas);
        emit log_named_uint("rejected then accepted gas", retryGas);
        assertGt(retryGas, firstGas);
    }

    function test_AttemptRequiresSelf() public {
        vm.expectRevert(EEZBase.NotSelf.selector);
        rollups._attemptExecuteEntry(uint64(r.id), 0);
    }
}

contract EEZMutableRetryL2Test is BaseL2 {
    RetryEffects internal effect;
    address internal proxy;
    bytes32 internal key;

    function setUp() public override {
        super.setUp();
        effect = new RetryEffects();
        proxy = manager.createCrossChainProxy(address(0xBEEF), REMOTE_ROLLUP_ID);
        key = _ccHash(false, address(this), TEST_ROLLUP_ID, address(0xBEEF), REMOTE_ROLLUP_ID, 0, "run");
    }

    function _rows(uint256 value) internal view returns (L2Entry[] memory rows) {
        CrossChainCall memory callback =
            _cc(address(effect), value, abi.encodeCall(RetryEffects.run, ()), address(0xD00D), REMOTE_ROLLUP_ID);
        rows = new L2Entry[](2);
        for (uint256 i; i < 2; i++) {
            rows[i] =
                _buildSimpleEntry(key, callback, abi.encode(i), _rhSingle(key, callback, true, abi.encode(uint256(1))));
        }
        rows[0].rollingHash = bytes32(uint256(0xbad));
    }

    function test_RejectedCandidateRollsBackEffectsAndValue() public {
        vm.deal(address(manager), 3 ether);
        vm.deal(address(this), 1 ether);
        uint256 systemBalance = SYSTEM_ADDRESS.balance;
        key = _ccHash(false, address(this), TEST_ROLLUP_ID, address(0xBEEF), REMOTE_ROLLUP_ID, 1 ether, "run");
        _loadEntries(_rows(2 ether), new StaticExecutionEntryL2[](0));
        (bool ok, bytes memory result) = proxy.call{value: 1 ether}("run");
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(1)));
        assertEq(effect.calls(), 1);
        assertEq(address(effect).balance, 2 ether);
        assertEq(address(manager).balance, 1 ether);
        assertEq(SYSTEM_ADDRESS.balance, systemBalance + 1 ether);
        assertEq(manager.entryIndex(), 2);
        // A second same-transaction call must see a clean execution context.
        _loadSingle(_buildNoCalls(key, "next"));
        vm.deal(address(this), 1 ether);
        (ok, result) = proxy.call{value: 1 ether}("run");
        assertTrue(ok);
        assertEq(result, bytes("next"));
    }

    function test_AllMismatchesRestoreStateAndValue() public {
        vm.deal(address(manager), 3 ether);
        L2Entry[] memory rows = _rows(2 ether);
        rows[1].rollingHash = rows[0].rollingHash;
        _loadEntries(rows, new StaticExecutionEntryL2[](0));
        (bool ok, bytes memory result) = proxy.call("run");
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector));
        assertEq(effect.calls(), 0);
        assertEq(address(effect).balance, 0);
        assertEq(address(manager).balance, 3 ether);
        assertEq(manager.entryIndex(), 0);
    }

    function _terminal(bytes memory payload) internal {
        L2Entry[] memory rows = _rows(0);
        rows[0].rollingHash = rows[1].rollingHash;
        rows[0].success = false;
        rows[0].returnData = payload;
        _loadEntries(rows, new StaticExecutionEntryL2[](0));
        (bool ok, bytes memory result) = proxy.call("run");
        assertFalse(ok);
        assertEq(result, payload);
        assertEq(effect.calls(), 0);
        assertEq(manager.entryIndex(), 0);
    }

    function test_ApplicationErrorsAreTerminal() public {
        _terminal(abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector));
        _terminal("");
        _terminal(abi.encodePacked(EEZBase.RollingHashMismatch.selector, uint256(1)));
    }

    function testFuzz_ApplicationRevertIsTerminal(bytes memory payload) public {
        _terminal(payload);
    }

    function test_OtherValidationErrorsAreTerminal() public {
        vm.deal(address(manager), 1 ether);
        L2Entry[] memory rows = _rows(0);
        rows[0].incomingCalls[0].isStatic = true;
        rows[0].incomingCalls[0].value = 1;
        _loadEntries(rows, new StaticExecutionEntryL2[](0));
        (bool ok, bytes memory result) = proxy.call("run");
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZBase.StaticCallWithValue.selector));
        assertEq(effect.calls(), 0);
    }

    function test_RetryCannotReachRetainedInactiveRows() public {
        L2Entry[] memory rows = _rows(0);
        _loadEntries(rows, new StaticExecutionEntryL2[](0));
        _loadSingle(rows[0]);
        (bool ok, bytes memory result) = proxy.call("run");
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector));
        assertEq(effect.calls(), 0);
        assertEq(manager.entryIndex(), 0);
    }

    function test_RejectedCandidateWithNestedCallRestoresContext() public {
        effect.setNestedProxy(proxy);
        L2Entry[] memory rows = _rows(0);
        bytes32 fireHash = _hCallBegin(_hEntryBeginL2(key), _incomingCallHash(rows[0].incomingCalls[0]));
        bytes32 nestedHash =
            _ccHash(false, address(effect), TEST_ROLLUP_ID, address(0xBEEF), REMOTE_ROLLUP_ID, 0, "nested");
        for (uint256 i; i < rows.length; i++) {
            rows[i].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](1);
            rows[i].expectedOutgoingCalls[0].expectedOutgoingHash = _expectedOutgoingHash(nestedHash, fireHash);
            rows[i].expectedOutgoingCalls[0].success = true;
            rows[i].expectedOutgoingCalls[0].returnData = abi.encode(uint256(7));
            rows[i].rollingHash =
                _hCallEnd(_hNestedEnd(_hNestedBegin(fireHash, nestedHash)), true, abi.encode(uint256(1)));
        }
        rows[0].rollingHash = bytes32(uint256(0xbad));
        _loadEntries(rows, new StaticExecutionEntryL2[](0));
        (bool ok, bytes memory result) = proxy.call("run");
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(1)));
        assertEq(effect.calls(), 1);
        assertEq(manager.entryIndex(), 2);
    }

    function test_NoMatchKeepsEntryNotFound() public {
        _loadEntries(_rows(0), new StaticExecutionEntryL2[](0));
        (bool ok, bytes memory result) = proxy.call("different");
        assertFalse(ok);
        bytes32 missing =
            _ccHash(false, address(this), TEST_ROLLUP_ID, address(0xBEEF), REMOTE_ROLLUP_ID, 0, "different");
        assertEq(result, abi.encodeWithSelector(EEZL2.EntryNotFound.selector, missing, uint64(0)));
    }

    function test_IncomingApplicationRevertRestoresTableAndFunding() public {
        _loadSingle(_buildNoCalls(key, "previous"));
        vm.deal(address(manager), 3 ether);
        vm.deal(SYSTEM_ADDRESS, 1 ether);
        CrossChainCall memory callback =
            _cc(address(effect), 2 ether, abi.encodeCall(RetryEffects.run, ()), address(0xD00D), REMOTE_ROLLUP_ID);
        bytes32 inboundKey = manager.computeCrossChainCallHash(
            false,
            callback.sourceAddress,
            callback.sourceRollupId,
            callback.targetAddress,
            TEST_ROLLUP_ID,
            callback.value,
            callback.gas,
            callback.data
        );
        L2Entry[] memory rows = new L2Entry[](2);
        for (uint256 i; i < 2; i++) {
            rows[i] = _buildSimpleEntry(
                inboundKey, callback, "", _rhSingle(inboundKey, callback, true, abi.encode(uint256(1)))
            );
        }
        rows[0].success = false;
        rows[0].returnData = abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector);
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        manager.executeIncomingCrossChainCall{value: 1 ether}(rows, new StaticExecutionEntryL2[](0));
        assertEq(effect.calls(), 0);
        assertEq(address(effect).balance, 0);
        assertEq(address(manager).balance, 3 ether);
        assertEq(SYSTEM_ADDRESS.balance, 1 ether);
        assertEq(manager.entriesLength(), 1);
        assertEq(manager.entryIndex(), 0);
        (bool ok, bytes memory result) = proxy.call("run");
        assertTrue(ok);
        assertEq(result, bytes("previous"));
    }

    function test_GasFirstMatchAndRetry() public {
        L2Entry[] memory rows = _rows(0);
        _loadEntries(rows, new StaticExecutionEntryL2[](0));
        uint256 snapshot = vm.snapshotState();
        uint256 beforeGas = gasleft();
        (bool ok,) = proxy.call("run");
        uint256 retryGas = beforeGas - gasleft();
        assertTrue(ok);
        vm.revertToState(snapshot);
        rows[0].rollingHash = rows[1].rollingHash;
        _loadEntries(rows, new StaticExecutionEntryL2[](0));
        beforeGas = gasleft();
        (ok,) = proxy.call("run");
        uint256 firstGas = beforeGas - gasleft();
        assertTrue(ok);
        emit log_named_uint("first candidate gas", firstGas);
        emit log_named_uint("rejected then accepted gas", retryGas);
        assertGt(retryGas, firstGas);
    }

    function test_AttemptRequiresSelf() public {
        vm.expectRevert(EEZBase.NotSelf.selector);
        manager._attemptExecuteEntry(0);
    }
}

contract EEZProxyMutableRetryTest is EEZMutableRetryL1Test {
    function _deployEEZ(address recovery) internal override returns (EEZ) {
        return EEZ(address(new EEZProxy(address(new EEZ(recovery)), makeAddr("EEZ upgrade owner"))));
    }
}

contract EEZProxyRetryExpressivenessTest is EEZExpressivenessL1Test {
    function _deployEEZ(address recovery) internal override returns (EEZ) {
        return EEZ(address(new EEZProxy(address(new EEZ(recovery)), makeAddr("EEZ upgrade owner"))));
    }
}
