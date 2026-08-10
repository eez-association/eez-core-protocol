// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DslScenarioBase} from "./ScenarioDSL.sol";

/// @title DslParser
/// @notice Negative tests for the DSL compiler (`DslScenarioBase` in
///         `ScenarioDSL.sol`): structural and lexical errors revert with an exact
///         `DSL line <n>: <reason>` message — except the two script-level checks
///         (empty script, one-runDsl-per-test), which have no line to point at
///         and revert with a plain `DSL: <reason>`.
contract DslParser is DslScenarioBase {
    /// @dev External wrapper so `vm.expectRevert` sees the compiler's revert.
    function compileExternal(string calldata script) external {
        dslCompile(script);
    }

    function runExternal(string calldata script) external {
        runDsl(script);
    }

    function _expectFail(uint256 lineNo, string memory reason, string memory script) internal {
        vm.expectRevert(bytes(string.concat("DSL line ", vm.toString(lineNo), ": ", reason)));
        this.compileExternal(script);
    }

    function test_reject_unknownVerb() public {
        _expectFail(1, "unknown verb 'jump'", "L1 jump L2_A\n");
    }

    function test_reject_badChainToken() public {
        _expectFail(1, "bad chain token 'l3' (want L1 or L2_a..L2_z)", "L3 call L2_A\n");
    }

    function test_reject_missingCallTarget() public {
        _expectFail(1, "expected: <chain> call <chain> [value <amount> [wei|gwei|ether]]", "L1 call\n");
    }

    function test_reject_valueOnStaticCall() public {
        _expectFail(1, "static calls cannot carry value", "L1 staticCall L2_A value 1 ether\n");
    }

    function test_reject_valueBadAmount() public {
        _expectFail(1, "bad value amount 'abc' (want a decimal integer)", "L1 call L2_A value abc\n");
    }

    function test_reject_valueBadUnit() public {
        _expectFail(1, "bad value unit 'szabo' (want wei, gwei, or ether)", "L1 call L2_A value 1 szabo\n");
    }

    function test_reject_valueMissingKeyword() public {
        _expectFail(1, "expected 'value', got 'with'", "L1 call L2_A with 1 ether\n");
    }

    function test_reject_missingVerb() public {
        _expectFail(1, "missing verb", "L1\n");
    }

    function test_reject_tokensAfterSeparator() public {
        _expectFail(3, "unexpected tokens after '--'", "L1 call L2_A\nL2_A return\n-- oops\n");
    }

    function test_reject_executorMismatch() public {
        _expectFail(2, "executor is l1 but l2_a is executing", "L1 call L2_A\nL1 return\n");
    }

    function test_reject_returnWithNoOpenCall() public {
        _expectFail(3, "return with no open call", "L1 call L2_A\nL2_A return\nL1 return\n");
    }

    function test_reject_selfChainTarget() public {
        _expectFail(1, "call target equals executing chain", "L1 call L1\n");
    }

    function test_reject_mutableNestingUnderStatic() public {
        _expectFail(2, "cannot nest a mutable call inside a static call", "L1 staticCall L2_A\nL2_A call L2_B\n");
    }

    function test_reject_staticSubReadNestingFurther() public {
        _expectFail(
            3, "static sub-reads cannot nest further", "L1 staticCall L2_A\nL2_A staticCall L1\nL1 staticCall L2_A\n"
        );
    }

    function test_reject_staticSubReadWrongTarget() public {
        _expectFail(2, "static sub-read must target the reader chain", "L1 staticCall L2_A\nL2_A staticCall L2_B\n");
    }

    function test_reject_staticNestingUnderReentrantStatic() public {
        // Only a TOP-LEVEL static frame may nest sub-reads; a reentrant one cannot.
        _expectFail(3, "static sub-reads cannot nest further", "L1 call L2_A\nL2_A staticCall L1\nL1 staticCall L2_A\n");
    }

    function test_reject_nestedSnapshot() public {
        _expectFail(
            4, "snapshot while a region is open (line 1)", "L2_A snapshot\nL2_A call L2_B\nL2_B return\nL2_A snapshot\n"
        );
    }

    function test_reject_revertWithoutSnapshot() public {
        _expectFail(3, "revert without matching snapshot", "L2_A call L2_B\nL2_B return\nL2_A revert\n");
    }

    function test_reject_emptySnapshotRegion() public {
        _expectFail(2, "empty snapshot region", "L2_A snapshot\nL2_A revert\n");
    }

    function test_reject_returnPastOpenRegion() public {
        _expectFail(
            5,
            "unclosed snapshot region (opened at line 2)",
            "L1 call L2_A\nL2_A snapshot\nL2_A call L2_B\nL2_B return\nL2_A return\n"
        );
    }

    function test_reject_unclosedFrameAtEof() public {
        // The trailing "\n" makes the (empty) line 2 the end-of-script position.
        _expectFail(2, "unclosed call frame (opened at line 1)", "L1 call L2_A\n");
    }

    function test_reject_separatorInsideOpenCall() public {
        _expectFail(2, "unclosed call frame (opened at line 1)", "L1 call L2_A\n--\n");
    }

    function test_reject_trailingSeparator() public {
        _expectFail(4, "empty transaction", "L1 call L2_A\nL2_A return\n--\n");
    }

    function test_reject_doubleSeparator() public {
        _expectFail(4, "empty transaction", "L1 call L2_A\nL2_A return\n--\n--\nL1 call L2_A\nL2_A return\n");
    }

    function test_reject_committedCallInsideFailFrame() public {
        _expectFail(
            4,
            "returnFail frame contains a committed call (unsupported shape)",
            "L1 call L2_A\nL2_A call L2_B\nL2_B return\nL2_A returnFail\n"
        );
    }

    function test_reject_txOpenerNotACall() public {
        _expectFail(1, "transaction must start with call, staticCall, or snapshot", "L1 return\n");
    }

    function test_reject_bareSnapshotAtTxStart() public {
        // A bare verb can't open a transaction: the first instruction fixes the origin.
        _expectFail(
            1,
            "first instruction of a transaction must name its executing chain",
            "snapshot\nL1 call L2_A\nL2_A return\nrevert\n"
        );
    }

    function test_reject_bareVerbWithArguments() public {
        _expectFail(3, "expected: [<chain>] return", "L1 call L2_A\nL2_A call L1\nreturn now\n");
    }

    function test_reject_bareVerbStillStructuralChecked() public {
        // Deduced executors relax nothing structural: a bare revert still needs a region.
        _expectFail(3, "revert without matching snapshot", "L1 call L2_A\nL2_A return\nrevert\n");
    }

    function test_reject_emptyScript() public {
        vm.expectRevert(bytes("DSL: empty script"));
        this.compileExternal("# only a comment\n\n");
    }

    function test_reject_secondRunDsl() public {
        this.runExternal("L1 call L2_A\nL2_A return\n");
        vm.expectRevert(bytes("DSL: one runDsl per test"));
        this.runExternal("L1 call L2_A\nL2_A return\n");
    }
}
