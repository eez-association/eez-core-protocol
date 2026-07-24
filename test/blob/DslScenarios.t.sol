// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DslScenarioBase} from "./ScenarioDSL.sol";
import {BlobMessage, Msg, MsgList} from "../../script/blob/BlobMessages.sol";

/// @title DslScenarios
/// @notice End-to-end scenarios authored in the pseudo-code DSL. `runDsl` compiles
///         the script, runs the full pipeline (codec ⇄ IR ⇄ tables ⇄ live
///         execution), and auto-asserts every actor's committed `execCount`; the
///         explicit asserts below restate the interesting expectations as
///         documentation. Chains and actors deploy automatically — no setUp.
contract DslScenarios is DslScenarioBase {
    uint64 constant L2A = 1;
    uint64 constant L2B = 2;

    /// @notice The motivating example: two root calls, a reentrant static read, and
    ///         a three-deep callback chain (L1 → L2A → L1 → L2A).
    function test_Dsl_UserExample() public {
        runDsl(
            string.concat(
                "L1 call L2_A\n",
                "L2_A return\n",
                "L1 call L2_A\n",
                "L2_A staticCall L1\n",
                "L1 return\n",
                "L2_A call L1\n",
                "L1 call L2_A        # nested callback\n",
                "L2_A return\n",
                "L1 return\n",
                "L2_A return\n"
            )
        );
        assertEq(dslTarget[L2A].execCount(), 3, "both roots + the deep callback");
        assertEq(dslTarget[0].execCount(), 1, "the L2A->L1 call (static read commits nothing)");
    }

    /// @notice Reference nested flow (mirrors test_L1CallsL2A_NestedCallL2B).
    function test_Dsl_ReferenceFlow() public {
        runDsl(string.concat("L1 call L2_A\n", "L2_A call L2_B\n", "L2_B return\n", "L2_A return\n"));
        assertEq(dslTarget[L2A].execCount(), 1);
        assertEq(dslTarget[L2B].execCount(), 1);
    }

    /// @notice Sibling repeats: same shape delivered twice, unique auto calldata.
    function test_Dsl_SiblingCallsAfterReturn() public {
        runDsl(
            string.concat(
                "L1 call L2_A\n",
                "L2_A call L2_B\n",
                "L2_B return\n",
                "L2_A call L2_B\n",
                "L2_B return\n",
                "L2_A return\n"
            )
        );
        assertEq(dslTarget[L2B].execCount(), 2, "B delivered twice, in order");
    }

    /// @notice Two transactions with different origins in one slot.
    function test_Dsl_MultiTx() public {
        runDsl(string.concat("L1 call L2_A\n", "L2_A return\n", "--\n", "L2_A call L2_B\n", "L2_B return\n"));
        assertEq(dslTarget[L2A].execCount(), 1);
        assertEq(dslTarget[L2B].execCount(), 1);
        assertEq(dslDriver[0].execCount(), 1, "tx1 driven from L1");
        assertEq(dslDriver[L2A].execCount(), 1, "tx2 driven from L2A");
    }

    /// @notice Top-level ReturnFail: the delivery runs, verifies, then reverts —
    ///         nothing commits on the target (mirrors test_TopLevelReturnFail).
    function test_Dsl_TopLevelReturnFail() public {
        runDsl(string.concat("L1 call L2_A\n", "L2_A returnFail\n"));
        assertEq(dslTarget[L2A].execCount(), 0, "failed delivery leaves no state");
    }

    /// @notice Nested ReturnFail caught by the parent, which still commits
    ///         (mirrors test_NestedReturnFail_Caught).
    function test_Dsl_NestedReturnFail_Caught() public {
        runDsl(string.concat("L1 call L2_A\n", "L2_A call L2_B\n", "L2_B returnFail\n", "L2_A return\n"));
        assertEq(dslTarget[L2A].execCount(), 1, "A committed despite the caught inner failure");
        assertEq(dslTarget[L2B].execCount(), 0, "B's failed execution left no state");
    }

    /// @notice A failing frame whose sub-call ALSO fails: both roll back, and the
    ///         frame's terminal revert leaves the host hash consistent.
    ///         (A committed sub-call inside a returnFail frame is an unsupported v1
    ///         shape — see ScenarioStore — and is rejected at parse time.)
    function test_Dsl_FailedFrameWithFailedChild() public {
        runDsl(string.concat("L1 call L2_A\n", "L2_A call L2_B\n", "L2_B returnFail\n", "L2_A returnFail\n"));
        assertEq(dslTarget[L2A].execCount(), 0);
        assertEq(dslTarget[L2B].execCount(), 0);
    }

    /// @notice A failing frame that performed a static read first: reads fold nothing
    ///         on the host, so the failure translates cleanly.
    function test_Dsl_FailedFrameWithStaticChild() public {
        runDsl(string.concat("L1 call L2_A\n", "L2_A staticCall L2_B\n", "L2_B return\n", "L2_A returnFail\n"));
        assertEq(dslTarget[L2A].execCount(), 0);
        assertEq(dslTarget[L2B].execCount(), 0);
    }

    /// @notice Snapshot…Revert around a root call: the target executes but the region
    ///         rolls its state back (mirrors test_SnapshotRevertRegion).
    function test_Dsl_SnapshotRevert() public {
        runDsl(string.concat("L2_A snapshot\n", "L2_A call L2_B\n", "L2_B return\n", "L2_A revert\n"));
        assertEq(dslTarget[L2B].execCount(), 0, "region rolled B's state back");
    }

    /// @notice A region inside a nested frame (not at the tx root).
    function test_Dsl_SnapshotInsideFrame() public {
        runDsl(
            string.concat(
                "L1 call L2_A\n",
                "L2_A snapshot\n",
                "L2_A call L2_B\n",
                "L2_B return\n",
                "L2_A revert\n",
                "L2_A return\n"
            )
        );
        assertEq(dslTarget[L2A].execCount(), 1, "host frame commits");
        assertEq(dslTarget[L2B].execCount(), 0, "covered call rolls back");
    }

    /// @notice The same shape repeated right after a reverted region — unique auto
    ///         calldata guarantees the fresh call never re-matches the rolled-back entry.
    function test_Dsl_RepeatedShapeAfterRevert() public {
        runDsl(
            string.concat(
                "L2_A snapshot\n",
                "L2_A call L2_B\n",
                "L2_B return\n",
                "L2_A revert\n",
                "L2_A call L2_B\n",
                "L2_B return\n"
            )
        );
        assertEq(dslTarget[L2B].execCount(), 1, "only the post-region call commits");
    }

    /// @notice Top-level static read (mirrors test_TopLevelStaticReadFromL1).
    function test_Dsl_StaticTopLevel() public {
        runDsl(string.concat("L1 staticCall L2_A\n", "L2_A return\n"));
        assertEq(dslTarget[L2A].execCount(), 0, "a static read commits nothing");
    }

    /// @notice Reentrant static read (mirrors test_ReentrantStaticRead).
    function test_Dsl_ReentrantStaticRead() public {
        runDsl(string.concat("L1 call L2_A\n", "L2_A staticCall L2_B\n", "L2_B return\n", "L2_A return\n"));
        assertEq(dslTarget[L2A].execCount(), 1);
        assertEq(dslTarget[L2B].execCount(), 0);
    }

    /// @notice Top-level static read that REVERTS (a pool StaticExecutionEntry with
    ///         success = false).
    function test_Dsl_StaticReturnFail() public {
        runDsl(string.concat("L1 staticCall L2_A\n", "L2_A returnFail\n"));
        assertEq(dslTarget[L2A].execCount(), 0);
    }

    /// @notice Lexer torture: mixed case, CRLF endings, tabs, run-on spaces,
    ///         comment-only and blank lines.
    function test_Dsl_Normalization() public {
        runDsl(
            string.concat(
                "\n", "# leading comment line\n", "  l1   CALL   l2_a  # inline comment\r\n", "\tL2_a\tReturn\r\n", "\n"
            )
        );
        assertEq(dslTarget[L2A].execCount(), 1);
    }

    /// @notice Locks the compiled message stream: exact order, actor wiring, and
    ///         auto-generated payloads.
    function test_Dsl_CompiledMessages() public {
        BlobMessage[] memory got = dslCompile(string.concat("L2_A call L2_B\n", "L2_B return\n"));

        MsgList memory l = Msg.list(5);
        Msg.push(l, Msg.initiate(L2A, "dsl.tx#0"));
        Msg.push(l, Msg.call(L2B, address(dslDriver[L2A]), address(dslTarget[L2B]), 0, "dsl.call#0"));
        Msg.push(l, Msg.returnSuccess("dsl.ret#0"));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        BlobMessage[] memory want = Msg.done(l);

        assertEq(got.length, want.length, "message count");
        for (uint256 i = 0; i < want.length; i++) {
            assertTrue(Msg.eq(got[i], want[i]), string.concat("message mismatch at index ", vm.toString(i)));
        }
    }
}
