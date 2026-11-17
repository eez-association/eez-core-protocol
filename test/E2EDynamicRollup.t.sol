// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {ExecutionEntry, StaticExecutionEntryL2} from "../src/interfaces/IEEZL2.sol";
import {ExecutionEntry as L1Entry, StaticExecutionEntry} from "../src/interfaces/IEEZ.sol";
import {Counter} from "./mocks/CounterContracts.sol";
import {CounterActions} from "../script/e2e/scenarios/one_way/L1_to_L2/counter/E2ECounter.s.sol";
import {CounterL2Actions} from "../script/e2e/scenarios/one_way/L2_to_L1/counterL2/E2ECounterL2.s.sol";
import {
    StaticReadCallsBackAndReadsAgainActions
} from "../script/e2e/scenarios/static/L1_to_L2/staticReadCallsBackAndReadsAgain/E2EStaticReadCallsBackAndReadsAgain.s.sol";

contract IncomingScenarioHarness is CounterActions {
    uint64 private immutable rollupId;

    constructor(uint64 id) {
        rollupId = id;
    }

    function _e2eRollupId() internal view override returns (uint64) {
        return rollupId;
    }

    function buildTables(
        address target,
        address source
    )
        external
        view
        returns (L1Entry[] memory, ExecutionEntry[] memory)
    {
        return (_l1Entries(target, source), _l2Entries(target, source));
    }
}

contract OutgoingScenarioHarness is CounterL2Actions {
    uint64 private immutable rollupId;

    constructor(uint64 id) {
        rollupId = id;
    }

    function _e2eRollupId() internal view override returns (uint64) {
        return rollupId;
    }

    function buildTables(
        address target,
        address source
    )
        external
        view
        returns (L1Entry[] memory, ExecutionEntry[] memory)
    {
        return (_l1Entries(target, source), _l2Entries(target, source));
    }
}

contract StaticScenarioHarness is StaticReadCallsBackAndReadsAgainActions {
    uint64 private immutable rollupId;

    constructor(uint64 id) {
        rollupId = id;
    }

    function _e2eRollupId() internal view override returns (uint64) {
        return rollupId;
    }

    function buildTables(address a1, address a2) external view returns (StaticExecutionEntry[] memory) {
        return _tables(a1, a2).statics;
    }
}

contract E2EDynamicRollupTest is Test {
    function test_rollupTwoExecutesBothDirectionsAndBuildsStaticCallbacks() public {
        _checkRollup(2);
    }

    function test_rollupThreeExecutesBothDirectionsAndBuildsStaticCallbacks() public {
        _checkRollup(3);
    }

    function _checkRollup(uint64 id) internal {
        _incomingTablesExecute(id);
        _outgoingTablesExecute(id);
        _staticRowsAndCallbacks(id);
    }

    function _incomingTablesExecute(uint64 id) internal {
        Counter target = new Counter();
        EEZL2 manager = new EEZL2(id, address(this), false, address(this));
        (L1Entry[] memory l1, ExecutionEntry[] memory l2) =
            new IncomingScenarioHarness(id).buildTables(address(target), address(0x123));
        assertEq(l1[0].destinationRollupId, id);
        assertEq(l1[0].rollupUpdates[0].rollupId, id);
        assertEq(l1[0].proxyEntryHash, l2[0].proxyEntryHash);
        manager.executeIncomingCrossChainCall(l2, new StaticExecutionEntryL2[](0));
        assertEq(target.counter(), 1);
    }

    function _outgoingTablesExecute(uint64 id) internal {
        address source = address(0x123);
        address remote = address(0x456);
        EEZL2 manager = new EEZL2(id, address(this), false, address(this));
        (L1Entry[] memory l1, ExecutionEntry[] memory l2) = new OutgoingScenarioHarness(id).buildTables(remote, source);
        assertEq(l1[0].destinationRollupId, id);
        assertEq(l1[0].rollupUpdates[0].rollupId, id);
        assertEq(l1[0].l2ToL1Calls[0].sourceRollupId, id);
        address proxy = manager.getOrCreateCrossChainProxy(remote, 0);
        manager.loadExecutionTable(l2, new StaticExecutionEntryL2[](0));
        vm.prank(source);
        assertEq(Counter(proxy).increment(), 1);
        assertEq(manager.entryIndex(), 1);
    }

    function _staticRowsAndCallbacks(uint64 id) internal {
        StaticExecutionEntry[] memory rows = new StaticScenarioHarness(id).buildTables(address(0x123), address(0x456));
        for (uint256 i; i < rows.length; ++i) {
            assertEq(rows[i].destinationRollupId, id);
            assertEq(rows[i].expectedRoots[0].rollupId, id);
            for (uint256 j; j < rows[i].l2ToL1Calls.length; ++j) {
                assertEq(rows[i].l2ToL1Calls[j].sourceRollupId, id);
            }
        }
    }
}
