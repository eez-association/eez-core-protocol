// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlobScenarioBase} from "./BlobScenarioBase.sol";
import {BlobMessage, Msg, MsgList} from "../../script/blob/BlobMessages.sol";
import {ScenarioStore} from "../../script/blob/ScenarioStore.sol";
import {ScriptedActor} from "../../script/blob/ScriptedActor.sol";
import {ExecutionEntry} from "../../src/interfaces/IEEZ.sol";

/// @title BlobScenarios
/// @notice End-to-end scenarios: each test authors ONLY a blob message stream
///         (per BLOB_FORMAT_SPEC) and `runScenario` proves the whole chain —
///         codec round trip, Blob → Table, Table → Blob (byte-identical), and
///         real execution of the derived tables on EEZ / EEZL2.
///
///         To add a new test: deploy actors with `newActor(chainId)`, write the
///         message flow with the `Msg` builders, call `runScenario`, and assert
///         the actor effects you expect (`execCount` counts COMMITTED mutable
///         executions — rolled-back ones don't survive).
contract BlobScenarios is BlobScenarioBase {
    uint64 constant L2A = 1;
    uint64 constant L2B = 2;

    ScriptedActor driverL1; // origin driver on L1
    ScriptedActor driverA; // origin driver on L2A
    ScriptedActor actorA; // application contract on L2A
    ScriptedActor actorB; // application contract on L2B
    ScriptedActor actorC; // application contract on L1

    function setUp() public {
        _setUpChains(2);
        driverL1 = newActor(0);
        driverA = newActor(L2A);
        actorA = newActor(L2A);
        actorB = newActor(L2B);
        actorC = newActor(0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  1. The reference flow:
    //       L1 Call → L2A
    //       L2A → Call L2B
    //       L2B → Return
    //       L2A → Return
    // ═══════════════════════════════════════════════════════════════════════

    function test_L1CallsL2A_NestedCallL2B() public {
        MsgList memory l = Msg.list(8);
        Msg.push(l, Msg.initiate(0, "tx-data"));
        Msg.push(l, Msg.call(L2A, address(driverL1), address(actorA), 0, abi.encodeWithSignature("doA()")));
        Msg.push(l, Msg.call(L2B, address(actorA), address(actorB), 0, abi.encodeWithSignature("doB()")));
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(42)))); // L2B → L2A
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(7)))); // L2A → L1
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));

        assertEq(actorA.execCount(), 1, "A executed once");
        assertEq(actorB.execCount(), 1, "B executed once");
    }

    /// @notice Same flow, but asserting the derived L1 table SHAPE against the
    ///         EXECUTION_ENTRY_SPEC pattern (one deferred entry keyed by the L1→L2A
    ///         call, routed to L2A, seed-only rolling hash — nothing runs on L1).
    function test_L1CallsL2A_TableShape() public {
        MsgList memory l = Msg.list(8);
        bytes memory dataA = abi.encodeWithSignature("doA()");
        Msg.push(l, Msg.initiate(0, "tx-data"));
        Msg.push(l, Msg.call(L2A, address(driverL1), address(actorA), 0, dataA));
        Msg.push(l, Msg.call(L2B, address(actorA), address(actorB), 0, abi.encodeWithSignature("doB()")));
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(42))));
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(7))));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        BlobMessage[] memory msgs = Msg.done(l);

        (ExecutionEntry[] memory entries,,) = _generateOnly(msgs);
        assertEq(entries.length, 1, "one L1 entry (the origin root call)");
        assertEq(entries[0].destinationRollupId, L2A, "routed to L2A's queue");
        assertEq(entries[0].l2ToL1Calls.length, 0, "nothing executes on L1");
        assertEq(entries[0].expectedL1ToL2Calls.length, 0, "no reentrant frames on L1");
        assertEq(entries[0].returnData, abi.encode(uint256(7)), "pre-computed L2A return");
        // L2A + L2B both change state, so both must be in the entry's delta set.
        assertEq(entries[0].stateUpdates.length, 2, "deltas for L2A and L2B");
        assertEq(entries[0].stateUpdates[0].rollupId, L2A);
        assertEq(entries[0].stateUpdates[1].rollupId, L2B);

        runScenario(msgs);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  2. Directions: L2 → L1 and L2 → L2
    // ═══════════════════════════════════════════════════════════════════════

    function test_L2ACallsL1() public {
        MsgList memory l = Msg.list(8);
        Msg.push(l, Msg.initiate(L2A, "rlp-tx"));
        Msg.push(l, Msg.call(0, address(driverA), address(actorC), 0, abi.encodeWithSignature("doC()")));
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(1))));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));

        assertEq(actorC.execCount(), 1, "C really executed on L1");
        assertEq(driverA.execCount(), 1, "origin driver ran once");
    }

    function test_L2ACallsL2B() public {
        MsgList memory l = Msg.list(8);
        Msg.push(l, Msg.initiate(L2A, "rlp-tx"));
        Msg.push(l, Msg.call(L2B, address(driverA), address(actorB), 0, abi.encodeWithSignature("ping()")));
        Msg.push(l, Msg.returnSuccess("pong"));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));

        assertEq(actorB.execCount(), 1, "B executed once");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  3. Reentrancy: a call back into the chain that initiated the flow
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice L1 → L2A → L1: while A executes on L2A it calls back into L1 (actorC
    ///         really runs on L1 inside the origin entry's own call array).
    function test_L1ToL2A_CallbackIntoL1() public {
        MsgList memory l = Msg.list(10);
        Msg.push(l, Msg.initiate(0, "tx-data"));
        Msg.push(l, Msg.call(L2A, address(driverL1), address(actorA), 0, abi.encodeWithSignature("outer()")));
        Msg.push(l, Msg.call(0, address(actorA), address(actorC), 0, abi.encodeWithSignature("inner()")));
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(3)))); // L1 → L2A
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(9)))); // L2A → L1
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));

        assertEq(actorC.execCount(), 1, "callback really ran on L1");
        assertEq(actorA.execCount(), 1);
    }

    /// @notice Three levels + a sibling: L1 → L2A, A → B, B returns, A → B again
    ///         (the spec §1.2 context-stack example shape).
    function test_SiblingCallsAfterReturn() public {
        MsgList memory l = Msg.list(12);
        Msg.push(l, Msg.initiate(0, "tx-data"));
        Msg.push(l, Msg.call(L2A, address(driverL1), address(actorA), 0, abi.encodeWithSignature("root()")));
        Msg.push(l, Msg.call(L2B, address(actorA), address(actorB), 0, abi.encodeWithSignature("first()")));
        Msg.push(l, Msg.returnSuccess("r1"));
        Msg.push(l, Msg.call(L2B, address(actorA), address(actorB), 0, abi.encodeWithSignature("second()")));
        Msg.push(l, Msg.returnSuccess("r2"));
        Msg.push(l, Msg.returnSuccess("root-ret"));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));

        assertEq(actorB.execCount(), 2, "B delivered twice, in order");
    }

    /// @notice Callback into an L2 origin: L2A → L2B, and B calls back into A. The
    ///         callback executes on L2A inside the origin entry's own incomingCalls
    ///         while the driver's proxy call consumes it.
    function test_L2AToL2B_CallbackIntoOrigin() public {
        MsgList memory l = Msg.list(10);
        Msg.push(l, Msg.initiate(L2A, "rlp-tx"));
        Msg.push(l, Msg.call(L2B, address(driverA), address(actorB), 0, abi.encodeWithSignature("go()")));
        Msg.push(l, Msg.call(L2A, address(actorB), address(actorA), 0, abi.encodeWithSignature("callback()")));
        Msg.push(l, Msg.returnSuccess("cb-ret")); // L2A → L2B
        Msg.push(l, Msg.returnSuccess("b-ret")); // L2B → L2A
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));

        assertEq(actorA.execCount(), 1, "callback really ran on L2A");
        assertEq(actorB.execCount(), 1);
    }

    /// @notice Three chains in one flow: L2A → L2B, and B calls into L1 mid-execution
    ///         (the L1 leg rides the tx's L2Tx host entry, sourced from L2B).
    function test_L2AToL2B_NestedCallIntoL1() public {
        MsgList memory l = Msg.list(10);
        Msg.push(l, Msg.initiate(L2A, "rlp-tx"));
        Msg.push(l, Msg.call(L2B, address(driverA), address(actorB), 0, abi.encodeWithSignature("hop()")));
        Msg.push(l, Msg.call(0, address(actorB), address(actorC), 0, abi.encodeWithSignature("land()")));
        Msg.push(l, Msg.returnSuccess("c-ret")); // L1 → L2B
        Msg.push(l, Msg.returnSuccess("b-ret")); // L2B → L2A
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));

        assertEq(actorB.execCount(), 1);
        assertEq(actorC.execCount(), 1, "L1 leg really executed");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  4. Failure flavours
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Top-level ReturnFail: the L2A delivery reverts (entry runs, verifies,
    ///         then reverts) and the L1 origin entry reverts into the driver's
    ///         try/catch. Nothing commits on L2A.
    function test_TopLevelReturnFail() public {
        MsgList memory l = Msg.list(8);
        Msg.push(l, Msg.initiate(0, "tx-data"));
        Msg.push(l, Msg.call(L2A, address(driverL1), address(actorA), 0, abi.encodeWithSignature("failing()")));
        Msg.push(l, Msg.returnFail("nope"));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));

        assertEq(actorA.execCount(), 0, "failed delivery leaves no state on L2A");
    }

    /// @notice A ReturnFail frame with a COMMITTED sub-call has no faithful table
    ///         translation (the frame's terminal revert rolls back its own nested
    ///         consumptions on the executing chain) — the IR parser rejects it.
    function test_reject_ReturnFailFrameWithCommittedSubCall() public {
        MsgList memory l = Msg.list(8);
        Msg.push(l, Msg.initiate(0, "tx-data"));
        Msg.push(l, Msg.call(L2A, address(driverL1), address(actorA), 0, abi.encodeWithSignature("outer()")));
        Msg.push(l, Msg.call(L2B, address(actorA), address(actorB), 0, abi.encodeWithSignature("inner()")));
        Msg.push(l, Msg.returnSuccess("committed"));
        Msg.push(l, Msg.returnFail("outer-reverts"));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());

        ScenarioStore store = new ScenarioStore();
        vm.expectRevert(
            abi.encodeWithSelector(
                ScenarioStore.UnsupportedShape.selector, "ReturnFail frame with a committed sub-call"
            )
        );
        store.fromMessages(Msg.done(l));
    }

    /// @notice Reentrant ReturnFail: A's nested call to B fails; A catches it and
    ///         still succeeds (a success=false row in the unified reentrant table).
    function test_NestedReturnFail_Caught() public {
        MsgList memory l = Msg.list(10);
        Msg.push(l, Msg.initiate(0, "tx-data"));
        Msg.push(l, Msg.call(L2A, address(driverL1), address(actorA), 0, abi.encodeWithSignature("tryOuter()")));
        Msg.push(l, Msg.call(L2B, address(actorA), address(actorB), 0, abi.encodeWithSignature("willFail()")));
        Msg.push(l, Msg.returnFail("inner-revert"));
        Msg.push(l, Msg.returnSuccess("caught-and-continued"));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));

        assertEq(actorA.execCount(), 1, "A committed despite the caught inner failure");
        assertEq(actorB.execCount(), 0, "B's failed execution left no state");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  5. Static reads
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Reentrant static read: while A executes, it STATICCALLs a contract on
    ///         L2B — a STATIC-flavour row on L2A's side; L2B (idle) records nothing.
    function test_ReentrantStaticRead() public {
        MsgList memory l = Msg.list(10);
        Msg.push(l, Msg.initiate(0, "tx-data"));
        Msg.push(l, Msg.call(L2A, address(driverL1), address(actorA), 0, abi.encodeWithSignature("readAndAct()")));
        Msg.push(l, Msg.staticCall(L2B, address(actorA), address(actorB), abi.encodeWithSignature("peek()")));
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(1234))));
        Msg.push(l, Msg.returnSuccess("done"));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));

        assertEq(actorA.execCount(), 1);
        assertEq(actorB.execCount(), 0, "a static read commits nothing");
    }

    /// @notice Top-level static read fired from an idle L1: a pool
    ///         StaticExecutionEntry pinned to L2A's live state root.
    function test_TopLevelStaticReadFromL1() public {
        MsgList memory l = Msg.list(8);
        Msg.push(l, Msg.initiate(0, "tx-data"));
        Msg.push(l, Msg.staticCall(L2A, address(driverL1), address(actorA), abi.encodeWithSignature("peekA()")));
        Msg.push(l, Msg.returnSuccess(abi.encode(uint256(99))));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  6. Snapshot / Revert (forced-revert region — spec §3.2)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice A Snapshot…Revert bracket around an L2A→L2B call: B EXECUTES the call
    ///         (return data verified, rolling hash intact) but its state is rolled
    ///         back at the protocol layer (`revertNextNCalls` on B's inbound entry).
    function test_SnapshotRevertRegion() public {
        MsgList memory l = Msg.list(10);
        Msg.push(l, Msg.initiate(L2A, "rlp-tx"));
        Msg.push(l, Msg.snapshot());
        Msg.push(l, Msg.call(L2B, address(driverA), address(actorB), 0, abi.encodeWithSignature("rolledBack()")));
        Msg.push(l, Msg.returnSuccess("was-fine"));
        Msg.push(l, Msg.revertMarker());
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));

        assertEq(actorB.execCount(), 0, "B executed but the region rolled its state back");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  7. Value transfer
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice L1 → L2A with 1 ether: the L1 entry's etherDelta credits L2A's rollup
    ///         balance; the system mints the value on L2A by attaching it, and the
    ///         target actor really receives it.
    function test_CallWithValue() public {
        uint256 balBefore = address(actorA).balance;
        MsgList memory l = Msg.list(8);
        Msg.push(l, Msg.initiate(0, "tx-data"));
        Msg.push(l, Msg.call(L2A, address(driverL1), address(actorA), 1 ether, abi.encodeWithSignature("deposit()")));
        Msg.push(l, Msg.returnSuccess("deposited"));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));

        assertEq(address(actorA).balance - balBefore, 1 ether, "value minted and delivered on L2A");
        (,, uint256 rollupBalance) = rollups.rollups(L2A);
        assertEq(rollupBalance, 10_000 ether + 1 ether, "L2A rollup balance credited on L1");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  8. Full-slot stream: chain operations + two transactions + callData tail
    //     (the spec §3.1 canonical slot shape)
    // ═══════════════════════════════════════════════════════════════════════

    function test_FullSlot_ChainOpsAndTwoTransactions() public {
        MsgList memory l = Msg.list(24);
        // Each chain opens its cross-chain block.
        Msg.push(l, Msg.chainOperation(L2A, "open-block-a"));
        Msg.push(l, Msg.chainOperation(L2B, "open-block-b"));
        // Tx 1: L1 → L2A → L2B (the reference flow).
        Msg.push(l, Msg.initiate(0, "tx-1"));
        Msg.push(l, Msg.call(L2A, address(driverL1), address(actorA), 0, abi.encodeWithSignature("t1()")));
        Msg.push(l, Msg.call(L2B, address(actorA), address(actorB), 0, abi.encodeWithSignature("t1b()")));
        Msg.push(l, Msg.returnSuccess("b-ret"));
        Msg.push(l, Msg.returnSuccess("a-ret"));
        Msg.push(l, Msg.finish());
        // Tx 2: L2A → L1 (reverse direction, same slot).
        Msg.push(l, Msg.initiate(L2A, "tx-2"));
        Msg.push(l, Msg.call(0, address(driverA), address(actorC), 0, abi.encodeWithSignature("t2()")));
        Msg.push(l, Msg.returnSuccess("c-ret"));
        Msg.push(l, Msg.finish());
        // Both chains close their blocks; the closes ride the callData tail.
        Msg.push(l, Msg.closeBlobStream());
        Msg.push(l, Msg.chainOperation(L2A, "close-block-a"));
        Msg.push(l, Msg.chainOperation(L2B, "close-block-b"));
        runScenario(Msg.done(l));

        assertEq(actorA.execCount(), 1);
        assertEq(actorB.execCount(), 1);
        assertEq(actorC.execCount(), 1);
    }

    // ──────────────────────────────────────────────
    //  Helper: run only the Blob→Table direction (for table-shape assertions)
    // ──────────────────────────────────────────────

    function _generateOnly(BlobMessage[] memory msgs)
        internal
        returns (ExecutionEntry[] memory l1, uint256 units, address gen)
    {
        // Local imports avoided: mirror runScenario's first steps.
        return _generateTables(msgs);
    }
}
