// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DslScenarioBase} from "./ScenarioDSL.sol";
import {BlobMessage, BlobMsgType} from "../../script/blob/BlobMessages.sol";

/// @title DslExamples
/// @notice Worked examples of the pseudo-code DSL, ordered by complexity. Each
///         test is a self-contained scenario: `runDsl` compiles the script into
///         the standardized blob message list, derives every chain's execution
///         tables, round-trips them back to a byte-identical blob, executes the
///         tables on the real EEZ / EEZL2 managers, and asserts every actor's
///         committed `execCount`. The explicit asserts restate what `runDsl`
///         already checked, as documentation.
contract DslExamples is DslScenarioBase {
    uint64 constant L2A = 1;
    uint64 constant L2B = 2;

    // ═══════════════════════════════════════════════════════════════════════
    //  1. The smallest possible scenario: one cross-chain call.
    //
    //  What gets built from these two lines:
    //   - blob:  Initiate(L1) · Call(→L2A) · ReturnSuccess · Finish · Close
    //   - L1:    one ExecutionEntry keyed by the call hash, routed to L2A's
    //            queue, consumed by the driver actor's proxy call
    //   - L2A:   one inbound-delivery unit, driven by the system address via
    //            executeIncomingCrossChainCall
    // ═══════════════════════════════════════════════════════════════════════
    function test_Example1_SingleCall() public {
        runDsl(
            string.concat(
                "L1 call L2_A\n", //  L1's driver calls the target actor on L2A
                "L2_A return\n" //    ... which succeeds
            )
        );
        assertEq(dslTarget[L2A].execCount(), 1, "the delivery committed on L2A");
        assertEq(dslDriver[0].execCount(), 1, "the L1 driver drove the tx");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  2. Nesting + a callback into the origin. Indentation is free-form —
    //     nesting comes from POSITION: a call before the previous call's
    //     `return` is its child; returns close innermost-first (LIFO).
    //
    //  While B executes on L2B it calls back into L2A — that call lands in the
    //  reentrant (expectedOutgoing) table of L2A's origin entry, keyed by the
    //  live rolling hash at the exact point it fires.
    // ═══════════════════════════════════════════════════════════════════════
    function test_Example2_NestedCallback() public {
        runDsl(
            string.concat(
                "L2_A call L2_B\n", //      tx originates on L2A
                "  L2_B call L2_A\n", //      B calls back into the origin
                "  L2_A return\n", //         the callback commits on L2A
                "L2_B return\n" //          B finishes
            )
        );
        assertEq(dslTarget[L2B].execCount(), 1);
        assertEq(dslTarget[L2A].execCount(), 1, "callback really ran on L2A mid-flight");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  3. Reads and failures. A staticCall commits nothing anywhere; a nested
    //     returnFail is a caught revert — the parent continues and commits, the
    //     failed leg leaves no state (a success=false row in the reentrant
    //     table, verified against its own mini rolling hash, then reverted).
    // ═══════════════════════════════════════════════════════════════════════
    function test_Example3_ReadThenCaughtFailure() public {
        runDsl(
            string.concat(
                "L1 call L2_A\n",
                "  L2_A staticCall L2_B\n", //  read-only peek at L2B
                "  L2_B return\n",
                "  L2_A call L2_B\n", //        state-changing attempt...
                "  L2_B returnFail\n", //       ... which reverts; A catches it
                "L2_A return\n" //              A still succeeds
            )
        );
        assertEq(dslTarget[L2A].execCount(), 1, "A committed despite the caught failure");
        assertEq(dslTarget[L2B].execCount(), 0, "static read + failed call leave no state on B");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  4. Forced revert + a second transaction. The snapshot…revert region
    //     makes B EXECUTE the call (return data verified, rolling hash intact)
    //     and then rolls its state back at the protocol layer
    //     (revertNextNCalls on B's inbound entry). `--` starts a new
    //     transaction — here with a different origin chain.
    // ═══════════════════════════════════════════════════════════════════════
    function test_Example4_RegionAndSecondTx() public {
        runDsl(
            string.concat(
                "L2_A snapshot\n", //       open the forced-revert region
                "L2_A call L2_B\n", //      runs on B...
                "L2_B return\n",
                "L2_A revert\n", //         ...but its state is rolled back
                "L2_A call L2_B\n", //      a fresh attempt outside the region
                "L2_B return\n",
                "--\n", //                  second transaction, new origin
                "L1 call L2_B\n",
                "L2_B return\n"
            )
        );
        assertEq(dslTarget[L2B].execCount(), 2, "region call rolled back; the other two committed");
        assertEq(dslDriver[L2A].execCount(), 1, "tx1 driver on L2A");
        assertEq(dslDriver[0].execCount(), 1, "tx2 driver on L1");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  5. What the compiler actually emits: `dslCompile` returns the message
    //     list without executing, so the wire encoding is inspectable. Payloads
    //     are auto-generated and globally unique per call site.
    // ═══════════════════════════════════════════════════════════════════════
    function test_Example5_InspectCompiledMessages() public {
        BlobMessage[] memory msgs = dslCompile(string.concat("L1 call L2_A\n", "L2_A return\n"));

        assertEq(msgs.length, 5);
        assertEq(uint8(msgs[0].msgType), uint8(BlobMsgType.InitiateCrossChainTransaction));
        assertEq(msgs[0].chainId, 0, "origin = L1 (fixed by the first instruction)");
        assertEq(msgs[0].data, "dsl.tx#0");

        assertEq(uint8(msgs[1].msgType), uint8(BlobMsgType.Call));
        assertEq(msgs[1].chainId, L2A, "to_chain");
        assertEq(msgs[1].fromAddress, address(dslDriver[0]), "root calls come from the origin driver");
        assertEq(msgs[1].toAddress, address(dslTarget[L2A]), "targets are per-chain actors");
        assertEq(msgs[1].data, "dsl.call#0");

        assertEq(uint8(msgs[2].msgType), uint8(BlobMsgType.ReturnSuccess));
        assertEq(msgs[2].data, "dsl.ret#0", "return payload keyed to the call it closes");

        assertEq(uint8(msgs[3].msgType), uint8(BlobMsgType.FinishCrossChainTransaction));
        assertEq(uint8(msgs[4].msgType), uint8(BlobMsgType.CloseBlobStream));
    }
}
