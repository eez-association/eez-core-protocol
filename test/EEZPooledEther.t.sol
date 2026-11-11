// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "./Base.t.sol";
import {EEZ} from "../src/EEZ.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {ExecutionEntry, ExpectedL1ToL2Call, L2ToL1Call, RollupUpdate} from "../src/interfaces/IEEZ.sol";

contract PooledEtherBorrower {
    EEZ public immutable manager;
    address public immutable repaymentProxy;
    uint256 public received;
    uint256 public poolDuringCall;

    error BorrowedThenReverted(uint256 received, uint256 poolBalance);

    constructor(EEZ manager_, address repaymentProxy_) {
        manager = manager_;
        repaymentProxy = repaymentProxy_;
    }

    function borrow(uint256 repay, bool revertAfter) external payable {
        received = msg.value;
        poolDuringCall = address(manager).balance;
        if (revertAfter) revert BorrowedThenReverted(msg.value, poolDuringCall);
        (bool ok, bytes memory reason) = repaymentProxy.call{value: repay}(abi.encodeWithSignature("deposit()"));
        if (!ok) {
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}

/// @notice Contract-level spending-limit regressions: MockProofSystem accepts the supplied entries.
///         This does not establish that a production prover permits these transitions.
contract EEZPooledEtherTest is Base {
    uint64 internal constant MAINNET_ROLLUP_ID = 0;
    RollupHandle internal lender;
    RollupHandle internal borrowerRollup;
    PooledEtherBorrower internal borrower;
    bytes32 internal constant NEW_ROOT = keccak256("borrower-after-execution");

    function setUp() public {
        setUpBase();
        lender = _makeRollup(bytes32(0));
        borrowerRollup = _makeRollup(bytes32(0));
        // The only physical ETH belongs to a rollup absent from the execution and batch.
        _fundRollup(lender.id, 10 ether);
        address proxy = rollups.createCrossChainProxy(L2_REMOTE, uint64(borrowerRollup.id));
        borrower = new PooledEtherBorrower(rollups, proxy);
    }

    function _entry(
        uint256 amount,
        uint256 repay,
        int192 delta,
        bool revertAfter
    )
        internal
        view
        returns (ExecutionEntry[] memory entries)
    {
        uint64 rid = uint64(borrowerRollup.id);
        bytes memory data = abi.encodeCall(PooledEtherBorrower.borrow, (repay, revertAfter));
        entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(rid, _oneDelta(rid, bytes32(0), NEW_ROOT, delta));
        entries[0].l2ToL1Calls = _oneCall(_call(L2_SENDER, rid, address(borrower), amount, data));
        bytes32 callHash = _ccHash(NOT_STATIC_CALL, L2_SENDER, rid, address(borrower), MAINNET_ROLLUP_ID, amount, data);
        bytes32 h = _hCallBegin(_hEntryBegin(entries[0].rollupUpdates, bytes32(0)), callHash);
        if (revertAfter) {
            entries[0].rollingHash = _hCallEnd(
                h,
                false,
                abi.encodeWithSelector(
                    PooledEtherBorrower.BorrowedThenReverted.selector, amount, address(rollups).balance - amount
                )
            );
        } else {
            bytes32 nestedHash = _ccHash(
                NOT_STATIC_CALL,
                address(borrower),
                MAINNET_ROLLUP_ID,
                L2_REMOTE,
                rid,
                repay,
                abi.encodeWithSignature("deposit()")
            );
            entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](1);
            entries[0].expectedL1ToL2Calls[0] = ExpectedL1ToL2Call({
                expectedL1toL2Hash: _expectedL1toL2Hash(nestedHash, h),
                l2ToL1Calls: _emptyCalls(),
                revertedOrStaticRollingHash: bytes32(0),
                success: true,
                returnData: ""
            });
            h = _hNestedEnd(_hNestedBegin(h, nestedHash));
            entries[0].rollingHash = _hCallEnd(h, true, "");
        }
    }

    function _postDeferred(ExecutionEntry[] memory entries) internal {
        // Match the existing queued-L2Tx fixture: a non-L2Tx boundary entry
        // permits the following L2Tx to remain deferred. It is never executed.
        ExecutionEntry[] memory queued = new ExecutionEntry[](2);
        queued[0] = _immediateEntry(borrowerRollup.id, bytes32(0), bytes32(0));
        queued[0].proxyEntryHash = keccak256("boundary");
        queued[0].rollingHash = _hEntryBegin(queued[0].rollupUpdates, queued[0].proxyEntryHash);
        queued[1] = entries[0];
        _postBatchOne(borrowerRollup, queued, _emptyStaticEntries(), 0, 0);
    }

    function _assertBalancesIntact() internal view {
        assertEq(_getRollupEtherBalance(lender.id), 10 ether);
        assertEq(_getRollupEtherBalance(borrowerRollup.id), 0);
        assertEq(address(rollups).balance, 10 ether);
        assertEq(address(borrower).balance, 0);
        assertEq(_getRollupState(lender.id), bytes32(0));
    }

    function test_ZeroBalanceRollupCannotBorrowOtherRollupsFunds() public {
        _postDeferred(_entry(10 ether, 10 ether, 0, false));
        vm.expectRevert(EEZ.InsufficientEntryBalance.selector);
        vm.prank(makeAddr("executor"));
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        assertEq(borrower.received(), 0);
        assertEq(_getRollupState(borrowerRollup.id), bytes32(0));
        _assertBalancesIntact();
    }

    function test_RevertingCallCannotTemporarilyBorrowOtherRollupsFunds() public {
        _postDeferred(_entry(10 ether, 0, 0, true));
        vm.expectRevert(EEZ.InsufficientEntryBalance.selector);
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        _assertBalancesIntact();
    }

    function test_SingleRollupCannotBorrowEntireEEZPoolFromOtherRollups() public {
        RollupHandle memory secondLender = _makeRollup(bytes32(0));
        _fundRollup(secondLender.id, 7 ether);
        uint256 entirePool = address(rollups).balance;
        assertEq(entirePool, 17 ether);
        ExecutionEntry[] memory entries = _entry(entirePool, entirePool, 0, false);
        assertEq(entries[0].rollupUpdates.length, 1);
        _postDeferred(entries);
        vm.expectRevert(EEZ.InsufficientEntryBalance.selector);
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        assertEq(borrower.received(), 0);
        assertEq(address(rollups).balance, entirePool);
        assertEq(_getRollupEtherBalance(lender.id), 10 ether);
        assertEq(_getRollupEtherBalance(secondLender.id), 7 ether);
        assertEq(_getRollupState(borrowerRollup.id), bytes32(0));
    }

    function test_UnaccountedSurplusCannotFundBorrower() public {
        vm.deal(address(rollups), 20 ether); // 10 ETH of surplus, not a protocol deposit
        _postDeferred(_entry(10 ether, 10 ether, 0, false));
        vm.expectRevert(EEZ.InsufficientEntryBalance.selector);
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        assertEq(address(rollups).balance, 20 ether);
        assertEq(borrower.received(), 0);
    }

    function test_OwnFundsCanBeSentAndRepaid() public {
        _fundRollup(borrowerRollup.id, 10 ether);
        _postDeferred(_entry(10 ether, 10 ether, 0, false));
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        assertEq(borrower.received(), 10 ether);
        assertEq(borrower.poolDuringCall(), 10 ether);
        assertEq(address(rollups).balance, 20 ether);
        assertEq(_getRollupEtherBalance(borrowerRollup.id), 10 ether);
        assertEq(_getRollupState(borrowerRollup.id), NEW_ROOT);
    }

    function test_ClaimingZeroDeltaWithoutFullRepaymentStillReverts() public {
        _fundRollup(borrowerRollup.id, 10 ether);
        _postDeferred(_entry(10 ether, 9 ether, 0, false));
        vm.expectRevert(EEZ.EtherDeltaMismatch.selector);
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        assertEq(address(rollups).balance, 20 ether);
        assertEq(_getRollupEtherBalance(borrowerRollup.id), 10 ether);
        assertEq(borrower.received(), 0);
    }

    function _plainCallsEntry(
        L2ToL1Call[] memory calls,
        int192 delta
    )
        internal
        view
        returns (ExecutionEntry[] memory entries)
    {
        entries = new ExecutionEntry[](1);
        entries[0] = _shellEntry(borrowerRollup.id, _oneDelta(borrowerRollup.id, bytes32(0), NEW_ROOT, delta));
        entries[0].l2ToL1Calls = calls;
        bytes32 h = _hEntryBegin(entries[0].rollupUpdates, bytes32(0));
        for (uint256 i; i < calls.length; ++i) {
            h = _hCallBegin(h, _callHash(calls[i]));
            h = _hCallEnd(h, true, "");
        }
        entries[0].rollingHash = h;
    }

    function _callHash(L2ToL1Call memory c) internal pure returns (bytes32) {
        return
            _ccHash(c.isStatic, c.sourceAddress, c.sourceRollupId, c.targetAddress, MAINNET_ROLLUP_ID, c.value, c.data);
    }

    function test_FailedCallRestoresAllowanceForNextCall() public {
        _fundRollup(borrowerRollup.id, 10 ether);
        ExecutionEntry[] memory entries = _entry(10 ether, 0, 0, true);
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = entries[0].l2ToL1Calls[0];
        address sink = makeAddr("sink");
        calls[1] = _call(L2_SENDER, uint64(borrowerRollup.id), sink, 10 ether, "");
        entries[0].l2ToL1Calls = calls;
        entries[0].rollupUpdates[0].etherDelta = -10 ether;
        entries[0].rollingHash = _hCallEnd(_hCallBegin(entries[0].rollingHash, _callHash(calls[1])), true, "");
        _postDeferred(entries);
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        assertEq(sink.balance, 10 ether);
        assertEq(address(rollups).balance, 10 ether);
        assertEq(_getRollupEtherBalance(borrowerRollup.id), 0);
        assertEq(borrower.received(), 0);
    }

    function test_ForcedRevertSpanRestoresAllowance() public {
        _fundRollup(borrowerRollup.id, 10 ether);
        address sink = makeAddr("sink");
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = _call(L2_SENDER, uint64(borrowerRollup.id), sink, 10 ether, "");
        calls[0].revertNextNCalls = 1;
        calls[1] = _call(L2_SENDER, uint64(borrowerRollup.id), sink, 10 ether, "");
        _postDeferred(_plainCallsEntry(calls, -10 ether));
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        assertEq(sink.balance, 10 ether);
        assertEq(address(rollups).balance, 10 ether);
    }

    function test_ForcedRevertSpanCannotBorrowOtherRollupsFunds() public {
        L2ToL1Call[] memory calls =
            _oneCall(_call(L2_SENDER, uint64(borrowerRollup.id), makeAddr("sink"), 10 ether, ""));
        calls[0].revertNextNCalls = 1;
        _postDeferred(_plainCallsEntry(calls, 0));
        vm.expectRevert(
            abi.encodeWithSelector(
                EEZBase.UnexpectedContextRevert.selector, abi.encodeWithSelector(EEZ.InsufficientEntryBalance.selector)
            )
        );
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        _assertBalancesIntact();
    }

    function test_SiblingCallsShareOneRemainingAllowance() public {
        _fundRollup(borrowerRollup.id, 10 ether);
        address sink = makeAddr("sink");
        L2ToL1Call[] memory calls = new L2ToL1Call[](2);
        calls[0] = _call(L2_SENDER, uint64(borrowerRollup.id), sink, 6 ether, "");
        calls[1] = _call(L2_SENDER, uint64(borrowerRollup.id), sink, 5 ether, "");
        _postDeferred(_plainCallsEntry(calls, -11 ether));
        vm.expectRevert(EEZ.InsufficientEntryBalance.selector);
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        assertEq(sink.balance, 0);
        assertEq(address(rollups).balance, 20 ether);
    }

    function test_AllowanceDoesNotLeakBetweenImmediateEntries() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(lender.id, bytes32(0), NEW_ROOT);
        entries[1] = _entry(10 ether, 10 ether, 0, false)[0];
        vm.expectEmit(true, false, false, true, address(rollups));
        emit EEZ.L2TxSkipped(1, abi.encodeWithSelector(EEZ.InsufficientEntryBalance.selector));
        rollups.postAndVerifyBatch(_twoRollupBatch(lender.id, borrowerRollup.id, entries, _emptyStaticEntries(), 2, 0));
        assertEq(_getRollupState(lender.id), NEW_ROOT);
        assertEq(_getRollupState(borrowerRollup.id), bytes32(0));
        assertEq(borrower.received(), 0);
        assertEq(address(rollups).balance, 10 ether);
    }

    function _nestedSpendEntry(
        uint256 repay,
        uint256 spend,
        bool expectFailure
    )
        internal
        returns (ExecutionEntry[] memory entries, address sink)
    {
        entries = _entry(10 ether, repay, expectFailure ? int192(0) : -int192(int256(10 ether + spend - repay)), false);
        sink = makeAddr("nestedSink");
        L2ToL1Call memory nestedCall = _call(L2_SENDER, uint64(borrowerRollup.id), sink, spend, "");
        entries[0].expectedL1ToL2Calls[0].l2ToL1Calls = _oneCall(nestedCall);
        bytes32 h =
            _hCallBegin(_hEntryBegin(entries[0].rollupUpdates, bytes32(0)), _callHash(entries[0].l2ToL1Calls[0]));
        if (expectFailure) {
            h = _hCallEnd(h, false, abi.encodeWithSelector(EEZ.InsufficientEntryBalance.selector));
        } else {
            bytes32 nestedHash = _ccHash(
                NOT_STATIC_CALL,
                address(borrower),
                MAINNET_ROLLUP_ID,
                L2_REMOTE,
                uint64(borrowerRollup.id),
                repay,
                abi.encodeWithSignature("deposit()")
            );
            h = _hNestedBegin(h, nestedHash);
            h = _hCallEnd(_hCallBegin(h, _callHash(nestedCall)), true, "");
            h = _hCallEnd(_hNestedEnd(h), true, "");
        }
        entries[0].rollingHash = h;
    }

    function test_NestedCallCannotReuseValueAlreadyInFlight() public {
        _fundRollup(borrowerRollup.id, 10 ether);
        (ExecutionEntry[] memory entries, address sink) = _nestedSpendEntry(0, 1 ether, true);
        _postDeferred(entries);
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        assertEq(sink.balance, 0);
        assertEq(borrower.received(), 0);
        assertEq(_getRollupState(borrowerRollup.id), NEW_ROOT);
        assertEq(address(rollups).balance, 20 ether);
    }

    function test_NestedDepositFundsNestedOutgoingCall() public {
        _fundRollup(borrowerRollup.id, 10 ether);
        (ExecutionEntry[] memory entries, address sink) = _nestedSpendEntry(5 ether, 5 ether, false);
        _postDeferred(entries);
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        assertEq(sink.balance, 5 ether);
        assertEq(address(borrower).balance, 5 ether);
        assertEq(address(rollups).balance, 10 ether);
        assertEq(_getRollupEtherBalance(borrowerRollup.id), 0);
    }

    function test_TopLevelDepositFundsOutgoingCall() public {
        address sink = makeAddr("sink");
        L2ToL1Call[] memory calls = _oneCall(_call(L2_SENDER, uint64(borrowerRollup.id), sink, 10 ether, ""));
        ExecutionEntry[] memory entries = _plainCallsEntry(calls, 0);
        bytes32 entryHash = _ccHash(
            NOT_STATIC_CALL, address(this), MAINNET_ROLLUP_ID, L2_REMOTE, uint64(borrowerRollup.id), 10 ether, ""
        );
        entries[0].proxyEntryHash = entryHash;
        entries[0].rollingHash = _oneCallHash(entries[0].rollupUpdates, entryHash, _callHash(calls[0]), true, "");
        _postBatchOne(borrowerRollup, entries, _emptyStaticEntries(), 0, 0);
        vm.deal(address(this), 10 ether);
        (bool ok,) = borrower.repaymentProxy().call{value: 10 ether}("");
        assertTrue(ok);
        assertEq(sink.balance, 10 ether);
        assertEq(address(rollups).balance, 10 ether);
        assertEq(_getRollupEtherBalance(borrowerRollup.id), 0);
    }

    function test_ParticipatingRollupsCanShareTheirCombinedBalance() public {
        // This is an entry-wide cap, not a separate balance limit for each participant.
        address sink = makeAddr("sink");
        L2ToL1Call[] memory calls = _oneCall(_call(L2_SENDER, uint64(borrowerRollup.id), sink, 10 ether, ""));
        ExecutionEntry[] memory entries = _plainCallsEntry(calls, 0);
        RollupUpdate[] memory updates = new RollupUpdate[](2);
        updates[0] = RollupUpdate(uint64(lender.id), -10 ether, bytes32(0), NEW_ROOT);
        updates[1] = RollupUpdate(uint64(borrowerRollup.id), 0, bytes32(0), NEW_ROOT);
        entries[0].rollupUpdates = updates;
        entries[0].rollingHash = _oneCallHash(updates, bytes32(0), _callHash(calls[0]), true, "");
        rollups.postAndVerifyBatch(_twoRollupBatch(lender.id, borrowerRollup.id, entries, _emptyStaticEntries(), 1, 0));
        assertEq(sink.balance, 10 ether);
        assertEq(address(rollups).balance, 0);
        assertEq(_getRollupEtherBalance(lender.id), 0);
    }

    function test_VerifiedButNonparticipatingRollupDoesNotFundEntry() public {
        ExecutionEntry[] memory entries = _entry(10 ether, 10 ether, 0, false);
        ExecutionEntry[] memory queued = new ExecutionEntry[](2);
        queued[0] = _immediateEntry(borrowerRollup.id, bytes32(0), bytes32(0));
        queued[0].proxyEntryHash = keccak256("boundary");
        queued[0].rollingHash = _hEntryBegin(queued[0].rollupUpdates, queued[0].proxyEntryHash);
        queued[1] = entries[0];
        rollups.postAndVerifyBatch(_twoRollupBatch(lender.id, borrowerRollup.id, queued, _emptyStaticEntries(), 0, 0));
        vm.expectRevert(EEZ.InsufficientEntryBalance.selector);
        rollups.executeL2Txs(uint64(borrowerRollup.id));
        _assertBalancesIntact();
    }
}
