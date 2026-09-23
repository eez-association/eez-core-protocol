// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {BaseL2} from "./BaseL2.t.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {
    ExecutionEntry,
    ExpectedL1ToL2Call,
    StaticExecutionEntry,
    ExpectedRootPerRollup
} from "../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2Entry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    StaticExecutionEntryL2
} from "../src/interfaces/IEEZL2.sol";

interface IRetryRate {
    function rate() external view returns (uint256);
}

/// @notice Ordinary contract execution can revert, then succeed after its caller changes state.
contract RemoteRateGate {
    error RateNotReady(uint256 rate);
    uint256 public successfulCalls;

    function read() external view returns (uint256) {
        uint256 currentRate = IRetryRate(msg.sender).rate();
        if (currentRate == 1) revert RateNotReady(currentRate);
        return currentRate;
    }

    function run() external returns (uint256) {
        uint256 currentRate = IRetryRate(msg.sender).rate();
        if (currentRate == 1) revert RateNotReady(currentRate);
        successfulCalls++;
        return currentRate;
    }
}

contract RemoteRateEcho {
    uint256 public successfulCalls;

    function run() external returns (uint256) {
        successfulCalls++;
        return IRetryRate(msg.sender).rate();
    }
}

interface IExpensiveRetryRate {
    function expensiveRate() external view returns (uint256);
}

contract ExpensiveCallbackQuote {
    function read() external view returns (uint256) {
        return IExpensiveRetryRate(msg.sender).expensiveRate();
    }
}

contract RetryRateCaller {
    address public immutable remote;
    uint256 public rate;
    bool public firstSucceeded;
    bool public retrySucceeded;
    bytes public firstResult;
    bytes public retryResult;

    constructor(address remote_) {
        remote = remote_;
    }

    function attemptTwice() external {
        rate = 1;
        (firstSucceeded, firstResult) = remote.call(abi.encodeCall(RemoteRateGate.run, ()));
        rate = 2;
        (retrySucceeded, retryResult) = remote.call(abi.encodeCall(RemoteRateGate.run, ()));
    }
}

contract GasSensitiveStaticRead {
    function read() external view returns (uint256) {
        return gasleft() < 400_000 ? 1 : 2;
    }
}

/// @notice Characterization tests: these assert current representational limitations,
///         not desired support or acceptance by a production prover.
contract EEZExpressivenessL2Test is BaseL2 {
    uint256 public rate;

    error ParentRevertedAfterSuccess(uint256 returnedRate);

    function callThenRevert(address proxy) external {
        uint256 returnedRate = RemoteRateEcho(proxy).run();
        revert ParentRevertedAfterSuccess(returnedRate);
    }

    function test_OrdinaryCallCanRevertThenSucceedAfterLocalWrite() public {
        RemoteRateGate gate = new RemoteRateGate();
        RetryRateCaller caller = new RetryRateCaller(address(gate));
        caller.attemptTwice();
        assertFalse(caller.firstSucceeded());
        assertEq(caller.firstResult(), abi.encodeWithSelector(RemoteRateGate.RateNotReady.selector, uint256(1)));
        assertTrue(caller.retrySucceeded());
        assertEq(caller.retryResult(), abi.encode(uint256(2)));
        assertEq(gate.successfulCalls(), 1);
    }

    function test_StaticRevertCanRetryAfterLocalWrite() public {
        address gate = address(new RemoteRateGate());
        bytes memory data = abi.encodeCall(RemoteRateGate.read, ());
        bytes memory expectedRevert = abi.encodeWithSelector(RemoteRateGate.RateNotReady.selector, uint256(1));
        rate = 1;
        (bool ok, bytes memory result) = gate.staticcall(data);
        assertFalse(ok);
        assertEq(result, expectedRevert);
        rate = 2;
        (ok, result) = gate.staticcall(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(2)));

        address proxy = manager.createCrossChainProxy(gate, REMOTE_ROLLUP_ID);
        bytes32 key = _ccHash(true, address(this), TEST_ROLLUP_ID, gate, REMOTE_ROLLUP_ID, 0, data);
        StaticExecutionEntryL2[] memory rows = new StaticExecutionEntryL2[](2);
        for (uint256 i; i < 2; i++) {
            rows[i].proxyEntryHash = key;
            rows[i].incomingCalls = new CrossChainCall[](1);
            rows[i].incomingCalls[0] =
                _cc(address(this), 0, abi.encodeCall(IRetryRate.rate, ()), gate, REMOTE_ROLLUP_ID);
            rows[i].incomingCalls[0].isStatic = true;
            rows[i].rollingHash = _hStatic(bytes32(0), true, abi.encode(i + 1));
            rows[i].success = i == 1;
            rows[i].returnData = i == 0 ? expectedRevert : abi.encode(uint256(2));
        }
        _loadEntries(new L2Entry[](0), rows);
        rate = 1;
        (ok, result) = proxy.staticcall(data);
        assertFalse(ok);
        assertEq(result, expectedRevert);
        rate = 2;
        (ok, result) = proxy.staticcall(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(2)));
        assertEq(manager.entryIndex(), 0);
    }

    function test_TopLevelRevertedCallCannotReachSuccessCandidateAfterLocalWrite() public {
        address gate = address(new RemoteRateGate());
        address proxy = manager.createCrossChainProxy(gate, REMOTE_ROLLUP_ID);
        bytes memory data = abi.encodeCall(RemoteRateGate.run, ());
        bytes32 key = _ccHash(false, address(this), TEST_ROLLUP_ID, gate, REMOTE_ROLLUP_ID, 0, data);
        CrossChainCall memory callback =
            _cc(address(this), 0, abi.encodeCall(IRetryRate.rate, ()), gate, REMOTE_ROLLUP_ID);
        callback.isStatic = true;
        L2Entry[] memory entries = new L2Entry[](2);
        for (uint256 i; i < 2; i++) {
            entries[i] =
                _buildSimpleEntry(key, callback, abi.encode(i + 1), _rhSingle(key, callback, true, abi.encode(i + 1)));
        }
        entries[0].success = false;
        entries[0].returnData = abi.encodeWithSelector(RemoteRateGate.RateNotReady.selector, uint256(1));
        _loadEntries(entries, new StaticExecutionEntryL2[](0));

        rate = 1;
        (bool ok, bytes memory result) = proxy.call(data);
        assertFalse(ok);
        assertEq(result, entries[0].returnData);
        assertEq(manager.entryIndex(), 0);

        rate = 2;
        (ok, result) = proxy.call(data);
        assertFalse(ok, "matching reverted row blocks the success candidate");
        assertEq(result, abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector));
        assertEq(manager.entryIndex(), 0);

        // The success candidate itself is valid for rate 2. Removing the earlier row
        // makes it reachable, but a table reload cannot happen inside the original flow.
        _loadSingle(entries[1]);
        (ok, result) = proxy.call(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(2)));
    }

    function test_NestedRevertedCallCannotReachSuccessCandidateAfterLocalWrite() public {
        address gate = address(new RemoteRateGate());
        address proxy = manager.createCrossChainProxy(gate, REMOTE_ROLLUP_ID);
        RetryRateCaller caller = new RetryRateCaller(proxy);
        CrossChainCall memory outer = _cc(
            address(caller), 0, abi.encodeCall(RetryRateCaller.attemptTwice, ()), address(0xA11CE), REMOTE_ROLLUP_ID
        );
        bytes32 key = _incomingCallHash(outer);
        bytes32 fireHash = _hCallBegin(_hEntryBeginL2(key), key);
        bytes32 innerHash = _ccHash(
            false, address(caller), TEST_ROLLUP_ID, gate, REMOTE_ROLLUP_ID, 0, abi.encodeCall(RemoteRateGate.run, ())
        );
        CrossChainCall[] memory callbacks = new CrossChainCall[](1);
        callbacks[0] = _cc(address(caller), 0, abi.encodeCall(IRetryRate.rate, ()), gate, REMOTE_ROLLUP_ID);
        callbacks[0].isStatic = true;
        L2Entry memory entry = _buildSimpleEntry(key, outer, "", _hCallEnd(fireHash, true, ""));
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](2);
        for (uint256 i; i < 2; i++) {
            entry.expectedOutgoingCalls[i].expectedOutgoingHash = _expectedOutgoingHash(innerHash, fireHash);
            entry.expectedOutgoingCalls[i].incomingCalls = callbacks;
            entry.expectedOutgoingCalls[i].success = i == 1;
        }
        entry.expectedOutgoingCalls[0].revertedOrStaticRollingHash = _hCallEnd(
            _hCallBegin(_hNestedBegin(fireHash, innerHash), _incomingCallHash(callbacks[0])),
            true,
            abi.encode(uint256(1))
        );
        entry.expectedOutgoingCalls[0].returnData =
            abi.encodeWithSelector(RemoteRateGate.RateNotReady.selector, uint256(1));
        entry.expectedOutgoingCalls[1].returnData = abi.encode(uint256(2));
        L2Entry[] memory entries = new L2Entry[](1);
        entries[0] = entry;
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall(entries, new StaticExecutionEntryL2[](0));

        assertFalse(caller.firstSucceeded());
        assertEq(caller.firstResult(), entry.expectedOutgoingCalls[0].returnData);
        assertFalse(caller.retrySucceeded());
        assertEq(caller.retryResult(), abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector));
        assertEq(caller.rate(), 2);
    }

    function test_ParentRevertMakesSuccessfulCallRetryReuseOldRow() public {
        address remote = address(new RemoteRateEcho());
        bytes memory data = abi.encodeCall(RemoteRateEcho.run, ());
        rate = 1;
        (bool ok, bytes memory result) = address(this).call(abi.encodeCall(this.callThenRevert, (remote)));
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(ParentRevertedAfterSuccess.selector, uint256(1)));
        assertEq(RemoteRateEcho(remote).successfulCalls(), 0);
        rate = 2;
        assertEq(RemoteRateEcho(remote).run(), 2);

        address proxy = manager.createCrossChainProxy(remote, REMOTE_ROLLUP_ID);
        bytes32 key = _ccHash(false, address(this), TEST_ROLLUP_ID, remote, REMOTE_ROLLUP_ID, 0, data);
        CrossChainCall memory callback =
            _cc(address(this), 0, abi.encodeCall(IRetryRate.rate, ()), remote, REMOTE_ROLLUP_ID);
        callback.isStatic = true;
        L2Entry[] memory entries = new L2Entry[](2);
        for (uint256 i; i < 2; i++) {
            entries[i] =
                _buildSimpleEntry(key, callback, abi.encode(i + 1), _rhSingle(key, callback, true, abi.encode(i + 1)));
        }
        _loadEntries(entries, new StaticExecutionEntryL2[](0));
        rate = 1;
        (ok, result) = address(this).call(abi.encodeCall(this.callThenRevert, (proxy)));
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(ParentRevertedAfterSuccess.selector, uint256(1)));
        assertEq(manager.entryIndex(), 0, "parent revert undoes a successful consumption");
        rate = 2;
        (ok, result) = proxy.call(data);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector));
        _loadSingle(entries[1]);
        (ok, result) = proxy.call(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(2)));
    }

    function expensiveRate() external view returns (uint256) {
        bytes32 accumulator;
        for (uint256 i; i < 2_000; i++) {
            accumulator = keccak256(abi.encode(accumulator, i));
        }
        require(accumulator != bytes32(0), "unexpected digest");
        return rate;
    }

    function test_StaticRetryCanExhaustBudgetThatFitsEitherCandidateAlone() public {
        rate = 1;
        uint256 beforeGas = gasleft();
        (bool ok, bytes memory result) = address(this).staticcall(abi.encodeCall(this.expensiveRate, ()));
        uint64 callbackGas = uint64(beforeGas - gasleft() + 20_000);
        uint64 quoteGas = callbackGas + 60_000;
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(1)));

        address remote = address(new ExpensiveCallbackQuote());
        bytes memory data = abi.encodeCall(ExpensiveCallbackQuote.read, ());
        (ok, result) = remote.staticcall{gas: quoteGas}(data);
        assertTrue(ok, "native quote fits this budget");
        assertEq(result, abi.encode(uint256(1)));
        rate = 2;
        (ok, result) = remote.staticcall{gas: quoteGas}(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(2)));

        address proxy = manager.createCrossChainProxy(remote, REMOTE_ROLLUP_ID);
        bytes32 key = _ccHash(true, address(this), TEST_ROLLUP_ID, remote, REMOTE_ROLLUP_ID, 0, data);
        StaticExecutionEntryL2[] memory rows = new StaticExecutionEntryL2[](2);
        for (uint256 i; i < 2; i++) {
            rows[i].proxyEntryHash = key;
            rows[i].incomingCalls = new CrossChainCall[](1);
            rows[i].incomingCalls[0] =
                _cc(address(this), 0, abi.encodeCall(this.expensiveRate, ()), remote, REMOTE_ROLLUP_ID);
            rows[i].incomingCalls[0].isStatic = true;
            rows[i].incomingCalls[0].gas = callbackGas;
            rows[i].rollingHash = _hStatic(bytes32(0), true, abi.encode(i + 1));
            rows[i].success = true;
            rows[i].returnData = abi.encode(i + 1);
        }
        _loadEntries(new L2Entry[](0), rows);
        rate = 1;
        (ok, result) = proxy.staticcall{gas: quoteGas}(data);
        assertTrue(ok, "one candidate fits including EEZ overhead");
        assertEq(result, abi.encode(uint256(1)));
        rate = 2;
        (ok, result) = proxy.staticcall{gas: quoteGas}(data);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZBase.InsufficientCallGas.selector, callbackGas));

        // Reordering does not fix the sequence: whichever candidate is second
        // cannot be reached within the caller's cap after the expensive first try.
        StaticExecutionEntryL2 memory first = rows[0];
        rows[0] = rows[1];
        rows[1] = first;
        _loadEntries(new L2Entry[](0), rows);
        (ok, result) = proxy.staticcall{gas: quoteGas}(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(2)));
        rate = 1;
        (ok, result) = proxy.staticcall{gas: quoteGas}(data);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZBase.InsufficientCallGas.selector, callbackGas));
    }

    function test_GasSensitiveStaticResultsCannotBeDistinguishedWithoutCallbacks() public {
        GasSensitiveStaticRead target = new GasSensitiveStaticRead();
        bytes memory data = abi.encodeCall(GasSensitiveStaticRead.read, ());
        (bool ok, bytes memory result) = address(target).staticcall{gas: 200_000}(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(1)));
        (ok, result) = address(target).staticcall{gas: 600_000}(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(2)));

        // Both are legitimate read outcomes, but gas-independent lookup gives them
        // one key. With no callbacks, both candidates have the same zero sub-hash.
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        bytes32 key = _ccHash(true, address(this), TEST_ROLLUP_ID, address(target), REMOTE_ROLLUP_ID, 0, data);
        StaticExecutionEntryL2[] memory rows = new StaticExecutionEntryL2[](2);
        for (uint256 i; i < 2; i++) {
            rows[i].proxyEntryHash = key;
            rows[i].incomingCalls = new CrossChainCall[](0);
            rows[i].success = true;
            rows[i].returnData = abi.encode(i + 1);
        }
        _loadEntries(new L2Entry[](0), rows);
        (ok, result) = proxy.staticcall{gas: 200_000}(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(1)));
        (ok, result) = proxy.staticcall{gas: 600_000}(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(1)), "first row wins at both gas budgets");
    }
}

contract EEZExpressivenessL1Test is Base {
    uint256 public rate;

    error ParentRevertedAfterSuccess(uint256 returnedRate);

    function callThenRevert(address proxy) external {
        uint256 returnedRate = RemoteRateEcho(proxy).run();
        revert ParentRevertedAfterSuccess(returnedRate);
    }

    function setUp() public {
        setUpBase();
    }

    function test_StaticRevertCanRetryAfterLocalWrite() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address gate = address(new RemoteRateGate());
        address proxy = rollups.createCrossChainProxy(gate, uint64(r.id));
        bytes memory data = abi.encodeCall(RemoteRateGate.read, ());
        bytes memory expectedRevert = abi.encodeWithSelector(RemoteRateGate.RateNotReady.selector, uint256(1));
        bytes32 key = _ccHash(true, address(this), 0, gate, uint64(r.id), 0, data);
        StaticExecutionEntry[] memory rows = new StaticExecutionEntry[](2);
        for (uint256 i; i < 2; i++) {
            rows[i].proxyEntryHash = key;
            rows[i].destinationRollupId = uint64(r.id);
            rows[i].expectedRoots = new ExpectedRootPerRollup[](1);
            rows[i].expectedRoots[0] = ExpectedRootPerRollup(uint64(r.id), bytes32(0));
            rows[i].l2ToL1Calls =
                _oneCall(_staticCall(gate, uint64(r.id), address(this), abi.encodeCall(IRetryRate.rate, ())));
            rows[i].rollingHash = _hStatic(bytes32(0), true, abi.encode(i + 1));
            rows[i].success = i == 1;
            rows[i].returnData = i == 0 ? expectedRevert : abi.encode(uint256(2));
        }
        _postBatchOne(r, _emptyEntries(), rows, 0, 0);
        rate = 1;
        (bool ok, bytes memory result) = proxy.staticcall(data);
        assertFalse(ok);
        assertEq(result, expectedRevert);
        rate = 2;
        (ok, result) = proxy.staticcall(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(2)));
        assertEq(_getRollupState(r.id), bytes32(0));
    }

    function test_TopLevelRevertedCallCannotReachSuccessCandidateAfterLocalWrite() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address gate = address(new RemoteRateGate());
        address proxy = rollups.createCrossChainProxy(gate, uint64(r.id));
        bytes memory data = abi.encodeCall(RemoteRateGate.run, ());
        bytes32 key = _ccHash(false, address(this), 0, gate, uint64(r.id), 0, data);
        bytes32 callbackHash =
            _ccHash(true, gate, uint64(r.id), address(this), 0, 0, abi.encodeCall(IRetryRate.rate, ()));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        for (uint256 i; i < 2; i++) {
            entries[i] = _shellEntry(r.id, _oneDelta(r.id, bytes32(0), i == 0 ? bytes32(0) : keccak256("committed"), 0));
            entries[i].proxyEntryHash = key;
            entries[i].l2ToL1Calls =
                _oneCall(_staticCall(gate, uint64(r.id), address(this), abi.encodeCall(IRetryRate.rate, ())));
            entries[i].rollingHash = _hCallEnd(
                _hCallBegin(_hEntryBegin(entries[i].rollupUpdates, key), callbackHash), true, abi.encode(i + 1)
            );
            entries[i].returnData = abi.encode(i + 1);
        }
        entries[0].success = false;
        entries[0].returnData = abi.encodeWithSelector(RemoteRateGate.RateNotReady.selector, uint256(1));
        _postBatchOne(r, entries, _emptyStaticEntries(), 0, 0);

        rate = 1;
        (bool ok, bytes memory result) = proxy.call(data);
        assertFalse(ok);
        assertEq(result, entries[0].returnData);
        assertEq(_getRollupState(r.id), bytes32(0));
        rate = 2;
        (ok, result) = proxy.call(data);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector));
        assertEq(_getRollupState(r.id), bytes32(0));

        ExecutionEntry[] memory replacement = new ExecutionEntry[](1);
        replacement[0] = entries[1];
        _postBatchOne(r, replacement, _emptyStaticEntries(), 0, 0);
        (ok, result) = proxy.call(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(2)));
    }

    function test_NestedRevertedCallCannotReachSuccessCandidateAfterLocalWrite() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address gate = address(new RemoteRateGate());
        address proxy = rollups.createCrossChainProxy(gate, uint64(r.id));
        RetryRateCaller caller = new RetryRateCaller(proxy);
        bytes memory outerData = abi.encodeCall(RetryRateCaller.attemptTwice, ());
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(r.id, _oneDelta(r.id, bytes32(0), keccak256("committed"), 0));
        entries[0].l2ToL1Calls = _oneCall(_call(address(0xA11CE), uint64(r.id), address(caller), 0, outerData));
        bytes32 outerHash = _ccHash(false, address(0xA11CE), uint64(r.id), address(caller), 0, 0, outerData);
        bytes32 fireHash = _hCallBegin(_hEntryBegin(entries[0].rollupUpdates, bytes32(0)), outerHash);
        bytes32 innerHash =
            _ccHash(false, address(caller), 0, gate, uint64(r.id), 0, abi.encodeCall(RemoteRateGate.run, ()));
        bytes32 callbackHash =
            _ccHash(true, gate, uint64(r.id), address(caller), 0, 0, abi.encodeCall(IRetryRate.rate, ()));
        entries[0].rollingHash = _hCallEnd(fireHash, true, "");
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](2);
        for (uint256 i; i < 2; i++) {
            entries[0].expectedL1ToL2Calls[i].expectedL1toL2Hash = _expectedL1toL2Hash(innerHash, fireHash);
            entries[0].expectedL1ToL2Calls[i].l2ToL1Calls =
                _oneCall(_staticCall(gate, uint64(r.id), address(caller), abi.encodeCall(IRetryRate.rate, ())));
            entries[0].expectedL1ToL2Calls[i].success = i == 1;
        }
        bytes memory expectedRevert = abi.encodeWithSelector(RemoteRateGate.RateNotReady.selector, uint256(1));
        entries[0].expectedL1ToL2Calls[0].returnData = expectedRevert;
        entries[0].expectedL1ToL2Calls[0].revertedOrStaticRollingHash =
            _hCallEnd(_hCallBegin(_hNestedBegin(fireHash, innerHash), callbackHash), true, abi.encode(uint256(1)));
        entries[0].expectedL1ToL2Calls[1].returnData = abi.encode(uint256(2));
        _postBatchOne(r, entries, _emptyStaticEntries(), 1, 0);
        assertFalse(caller.firstSucceeded());
        assertEq(caller.firstResult(), expectedRevert);
        assertFalse(caller.retrySucceeded());
        assertEq(caller.retryResult(), abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector));
        assertEq(caller.rate(), 2);
    }

    function test_ParentRevertMakesSuccessfulCallRetryReuseOldRow() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        address remote = address(new RemoteRateEcho());
        address proxy = rollups.createCrossChainProxy(remote, uint64(r.id));
        bytes memory data = abi.encodeCall(RemoteRateEcho.run, ());
        bytes32 key = _ccHash(false, address(this), 0, remote, uint64(r.id), 0, data);
        bytes32 callbackHash =
            _ccHash(true, remote, uint64(r.id), address(this), 0, 0, abi.encodeCall(IRetryRate.rate, ()));
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        for (uint256 i; i < 2; i++) {
            entries[i] = _shellEntry(r.id, _oneDelta(r.id, bytes32(0), keccak256(abi.encode(i)), 0));
            entries[i].proxyEntryHash = key;
            entries[i].l2ToL1Calls =
                _oneCall(_staticCall(remote, uint64(r.id), address(this), abi.encodeCall(IRetryRate.rate, ())));
            entries[i].rollingHash = _hCallEnd(
                _hCallBegin(_hEntryBegin(entries[i].rollupUpdates, key), callbackHash), true, abi.encode(i + 1)
            );
            entries[i].returnData = abi.encode(i + 1);
        }
        _postBatchOne(r, entries, _emptyStaticEntries(), 0, 0);
        rate = 1;
        (bool ok, bytes memory result) = address(this).call(abi.encodeCall(this.callThenRevert, (proxy)));
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(ParentRevertedAfterSuccess.selector, uint256(1)));
        assertEq(_getRollupState(r.id), bytes32(0), "parent revert restores the original root");
        rate = 2;
        (ok, result) = proxy.call(data);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZBase.RollingHashMismatch.selector));
        ExecutionEntry[] memory replacement = new ExecutionEntry[](1);
        replacement[0] = entries[1];
        _postBatchOne(r, replacement, _emptyStaticEntries(), 0, 0);
        (ok, result) = proxy.call(data);
        assertTrue(ok);
        assertEq(result, abi.encode(uint256(2)));
    }
}
