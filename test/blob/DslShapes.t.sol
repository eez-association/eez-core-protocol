// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DslScenarioBase} from "./ScenarioDSL.sol";

/// @notice Exercise combinations of calls, static callbacks, value, failures and
/// rollback regions through the entire codec/table/execution pipeline.
contract DslShapes is DslScenarioBase {
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_CallTrees(uint256 seed) public {
        runDsl(_tree(uint64(seed % 3), 0, false, seed));
    }

    function _tree(
        uint64 source,
        uint256 depth,
        bool staticParent,
        uint256 seed
    )
        internal
        pure
        returns (string memory script)
    {
        uint64 target = uint64((source + 1 + ((seed >> 2) & 1)) % 3);
        bool readOnly = staticParent || ((seed >> 1) & 1) == 1;
        script = string.concat(_dslChainName(source), readOnly ? " staticCall " : " call ", _dslChainName(target));
        if (!readOnly && ((seed >> 7) & 1) == 1) script = string.concat(script, " value 1 wei");
        script = string.concat(script, "\n");
        uint256 children = depth < 3 ? (seed >> 3) % 3 : 0;
        bool region = !readOnly && children > 0 && ((seed >> 5) & 1) == 1;
        if (region) script = string.concat(script, "snapshot\n");
        for (uint256 i; i < children; i++) {
            bool innerRegion = region && ((seed >> 6) & 1) == 1;
            if (innerRegion) script = string.concat(script, "snapshot\n");
            script = string.concat(script, _tree(target, depth + 1, readOnly, uint256(keccak256(abi.encode(seed, i)))));
            if (innerRegion) script = string.concat(script, "revert\n");
        }
        if (region) script = string.concat(script, "revert\n");
        script = string.concat(script, (seed & 1) == 1 ? "returnFail\n" : "return\n");
    }

    function test_L1NestedRegionsRestoreRootsBeforeNextCall() public {
        runDsl(
            "L1 snapshot\nL1 call L2_A\nreturn\nsnapshot\nL1 call L2_B\nreturn\nrevert\nL1 call L2_A\nreturn\nrevert\nL1 call L2_B\nreturn\n"
        );
    }

    function test_FailedParentRollsBackSuccessfulValueTransfers() public {
        runDsl(
            "L2_A call L1 value 1 wei\nL1 call L2_B value 1 wei\nL2_B call L2_A value 1 wei\nreturn\nreturn\nreturnFail\n"
        );
    }

    function test_NestedRegionsWithStaticCallsAndValue() public {
        runDsl(
            "L1 call L2_A\nsnapshot\nL2_A call L1 value 1 wei\nreturn\nsnapshot\nL2_A staticCall L1\nL1 staticCall L2_B\nL2_B staticCall L2_A\nreturn\nreturn\nreturn\nrevert\nL2_A call L1 value 1 wei\nreturn\nrevert\nreturn\n"
        );
    }
}
