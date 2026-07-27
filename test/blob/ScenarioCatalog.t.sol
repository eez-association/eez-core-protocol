// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DslScenarioBase} from "./ScenarioDSL.sol";
import {Msg, MsgList} from "../../script/blob/BlobMessages.sol";

/// @title ScenarioCatalog
/// @notice The canonical direction catalog: one test per basic cross-chain shape,
///         each authored in the pseudo-code DSL (or raw messages where the DSL
///         cannot express the shape) and run through the full pipeline — codec
///         round trip, Blob → Table, Table → Blob, live execution on EEZ/EEZL2.
///
///         The L1 batch (`ProofSystemBatchPerVerificationEntries`) each scenario
///         produces is documented case by case in `SCENARIO_CATALOG.md`.
contract ScenarioCatalog is DslScenarioBase {
    uint64 constant L2A = 1;
    uint64 constant L2B = 2;

    // ═══════════════════════════════════════════════════════════════════════
    //  1. L2-only transaction — no cross-chain calls at all.
    //     The DSL rejects call-free txs, so this one is authored as raw
    //     messages: Initiate on L2A, Finish, Close. On L1 it is just the
    //     immediate L2Tx host entry advancing L2A's state root.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Catalog01_L2OnlyTransaction() public {
        _setUpChains(1);
        MsgList memory l = Msg.list(3);
        Msg.push(l, Msg.initiate(L2A, "l2-only-rlp-tx"));
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  2–5. Single hop, all four kinds
    // ═══════════════════════════════════════════════════════════════════════

    function test_Catalog02_L1CallL2() public {
        runDsl(string.concat("L1 call L2_A\n", "L2_A return\n"));
        assertEq(dslTarget[L2A].execCount(), 1, "delivered on L2A");
    }

    function test_Catalog03_L2CallL1() public {
        runDsl(string.concat("L2_A call L1\n", "L1 return\n"));
        assertEq(dslTarget[0].execCount(), 1, "executed on L1");
        assertEq(dslDriver[L2A].execCount(), 1, "origin driver ran once");
    }

    function test_Catalog04_L1StaticCallL2() public {
        runDsl(string.concat("L1 staticCall L2_A\n", "L2_A return\n"));
        assertEq(dslTarget[L2A].execCount(), 0, "a static read commits nothing");
    }

    function test_Catalog05_L2StaticCallL1() public {
        runDsl(string.concat("L2_A staticCall L1\n", "L1 return\n"));
        assertEq(dslTarget[0].execCount(), 0, "a static read commits nothing");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  6–7. Two hops: a callback into the origin
    // ═══════════════════════════════════════════════════════════════════════

    function test_Catalog06_L1CallL2CallL1() public {
        runDsl(string.concat("L1 call L2_A\n", "L2_A call L1\n", "L1 return\n", "L2_A return\n"));
        assertEq(dslTarget[L2A].execCount(), 1);
        assertEq(dslTarget[0].execCount(), 1, "callback really ran on L1");
    }

    function test_Catalog07_L2CallL1CallL2() public {
        runDsl(string.concat("L2_A call L1\n", "L1 call L2_A\n", "L2_A return\n", "L1 return\n"));
        assertEq(dslTarget[0].execCount(), 1);
        assertEq(dslTarget[L2A].execCount(), 1, "callback really ran on L2A");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  8–9. A static read nested inside a mutable frame
    // ═══════════════════════════════════════════════════════════════════════

    function test_Catalog08_L1CallL2StaticCallL1() public {
        runDsl(string.concat("L1 call L2_A\n", "L2_A staticCall L1\n", "L1 return\n", "L2_A return\n"));
        assertEq(dslTarget[L2A].execCount(), 1);
        assertEq(dslTarget[0].execCount(), 0, "the read commits nothing on L1");
    }

    function test_Catalog09_L2CallL1StaticCallL2() public {
        runDsl(string.concat("L2_A call L1\n", "L1 staticCall L2_A\n", "L2_A return\n", "L1 return\n"));
        assertEq(dslTarget[0].execCount(), 1);
        assertEq(dslTarget[L2A].execCount(), 0, "the read commits nothing on L2A");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  10–11. Static inside static — the read enters through the static entry:
    //     the pool StaticExecutionEntry carries the sub-read in its sub-call
    //     array, re-run live on the reader chain during resolution and verified
    //     by the untagged static rolling hash. When the outer read targets L1
    //     (case 11) it is ALSO evaluated live on the L1 host, its sub-read
    //     matched as a STATIC row.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Catalog10_L1StaticL2StaticL1() public {
        runDsl(string.concat("L1 staticCall L2_A\n", "L2_A staticCall L1\n", "L1 return\n", "L2_A return\n"));
        assertEq(dslTarget[L2A].execCount(), 0, "reads commit nothing");
        assertEq(dslTarget[0].execCount(), 0, "reads commit nothing");
    }

    function test_Catalog11_L2StaticL1StaticL2() public {
        runDsl(string.concat("L2_A staticCall L1\n", "L1 staticCall L2_A\n", "L2_A return\n", "L1 return\n"));
        assertEq(dslTarget[0].execCount(), 0, "reads commit nothing");
        assertEq(dslTarget[L2A].execCount(), 0, "reads commit nothing");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  12. L2A → L1 → L2B where the inner delivery REVERTS and L1 catches it
    // ═══════════════════════════════════════════════════════════════════════

    function test_Catalog12_L2aCallL1_CallRevertL2b() public {
        runDsl(string.concat("L2_A call L1\n", "L1 call L2_B\n", "L2_B returnFail\n", "L1 return\n"));
        assertEq(dslTarget[0].execCount(), 1, "L1 caught the failure and committed");
        assertEq(dslTarget[L2B].execCount(), 0, "B's failed delivery left no state");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  13. Three root calls from L2A into L1; the last two are wrapped in a
    //      Snapshot…Revert region (revertNextNCalls = 2 on the L1 side): they
    //      execute — including the nested L1 → L2B hop — then roll back.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Catalog13_ThreeRootCalls_RevertLastTwo() public {
        runDsl(
            string.concat(
                "L2_A call L1\n",
                "L1 return\n",
                "L2_A snapshot\n",
                "L2_A call L1\n",
                "L1 call L2_B\n",
                "L2_B return\n",
                "L1 return\n",
                "L2_A call L1\n",
                "L1 return\n",
                "L2_A revert\n"
            )
        );
        assertEq(dslTarget[0].execCount(), 1, "only the first L1 call survives the region");
        assertEq(dslTarget[L2B].execCount(), 0, "the nested B hop rolled back with the region");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  14. Deep nesting across three chains: L1 → L2A → L1 → L2B → L1
    // ═══════════════════════════════════════════════════════════════════════

    function test_Catalog14_Nested_L1_L2a_L1_L2b_L1() public {
        runDsl(
            string.concat(
                "L1 call L2_A\n",
                "L2_A call L1\n",
                "L1 call L2_B\n",
                "L2_B call L1\n",
                "L1 return\n",
                "L2_B return\n",
                "L1 return\n",
                "L2_A return\n"
            )
        );
        assertEq(dslTarget[L2A].execCount(), 1);
        assertEq(dslTarget[L2B].execCount(), 1);
        assertEq(dslTarget[0].execCount(), 2, "both L1 landings committed");
    }
}
