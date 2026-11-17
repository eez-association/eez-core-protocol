// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {ExecutionEntry, StaticExecutionEntryL2, CrossChainCall} from "../src/interfaces/IEEZL2.sol";
import {VerifyHelpers} from "../script/e2e/scenarios/shared/Verify.s.sol";

contract LinkVerificationHarness is VerifyHelpers {
    function select(
        Vm.EthGetLogs[] memory logs,
        bytes32[] memory hashes
    )
        external
        pure
        returns (Vm.EthGetLogs[] memory)
    {
        return _filterTransactionLogs(logs, hashes);
    }

    function statics(
        Vm.EthGetLogs[] memory logs,
        StaticExecutionEntryL2[] memory expected,
        bool exact
    )
        external
        pure
        returns (bool)
    {
        return _verifyL2StaticFields(logs, abi.encode(expected), exact);
    }

    function linked(
        Vm.EthGetLogs[] memory logs,
        ExecutionEntry[] memory expected,
        bytes32[] memory hashes,
        bytes[] memory inputs,
        bytes32[] memory loaders
    )
        external
        pure
    {
        _verifyLinkedTables(logs, abi.encode(expected), hashes, inputs, loaders);
    }

    function ordering(Vm.EthGetLogs[] memory logs, bytes32[] memory loaders, uint256[] memory positions) external pure {
        _checkLoaderOrdering(logs, loaders, positions);
    }
}

contract E2ELinkVerificationTest is Test {
    LinkVerificationHarness internal verifier;
    bytes32 internal constant LOADER = keccak256("correct loader");
    bytes32 internal constant OTHER = keccak256("other job");

    function setUp() public {
        verifier = new LinkVerificationHarness();
    }

    function _rows() internal pure returns (StaticExecutionEntryL2[] memory rows) {
        rows = new StaticExecutionEntryL2[](1);
        rows[0].expectedEntryIndex = 2;
        rows[0].proxyEntryHash = keccak256("static call");
        rows[0].success = true;
        rows[0].returnData = hex"1234";
        rows[0].incomingCalls = new CrossChainCall[](1);
        rows[0].incomingCalls[0].data = hex"cafe";
    }

    function _table(
        bytes32 txHash,
        uint64 index,
        ExecutionEntry[] memory entries,
        StaticExecutionEntryL2[] memory rows
    )
        internal
        pure
        returns (Vm.EthGetLogs memory log)
    {
        log.transactionHash = txHash;
        log.transactionIndex = index;
        log.blockNumber = 10;
        log.topics = new bytes32[](1);
        log.topics[0] = EEZL2.ExecutionTableLoaded.selector;
        log.data = abi.encode(entries, rows);
    }

    function test_SharedBlockFiltersOutFirstForeignLoader() public view {
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](2);
        logs[0] = _table(OTHER, 0, new ExecutionEntry[](0), _rows());
        logs[1] = _table(LOADER, 2, new ExecutionEntry[](0), _rows());
        bytes32[] memory allowed = new bytes32[](1);
        allowed[0] = LOADER;
        Vm.EthGetLogs[] memory selected = verifier.select(logs, allowed);
        assertEq(selected.length, 1);
        assertEq(selected[0].transactionHash, LOADER);
        assertTrue(verifier.statics(selected, _rows(), true));
    }

    function test_StaticOnlyPoolRejectsMissingExtraOrAlteredRows() public view {
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](1);
        logs[0] = _table(LOADER, 2, new ExecutionEntry[](0), _rows());
        assertTrue(verifier.statics(logs, _rows(), true));
        assertFalse(verifier.statics(new Vm.EthGetLogs[](0), _rows(), true));
        assertFalse(verifier.statics(logs, new StaticExecutionEntryL2[](0), true));
        StaticExecutionEntryL2[] memory expected = _rows();
        expected[0].expectedEntryIndex++;
        assertFalse(verifier.statics(logs, expected, true));
        expected = _rows();
        expected[0].returnData = hex"ffff";
        assertFalse(verifier.statics(logs, expected, true));
        expected = _rows();
        expected[0].incomingCalls[0].data = hex"0000";
        assertFalse(verifier.statics(logs, expected, true));
        expected = _rows();
        expected[0].success = false;
        assertFalse(verifier.statics(logs, expected, true));
        expected = _rows();
        expected[0].rollingHash = keccak256("wrong callback result");
        assertFalse(verifier.statics(logs, expected, true));
    }

    function test_IdenticalStaticRowsAreReusableButDistinctAlternativesAreRequired() public view {
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](1);
        logs[0] = _table(LOADER, 2, new ExecutionEntry[](0), _rows());
        StaticExecutionEntryL2[] memory expected = new StaticExecutionEntryL2[](2);
        expected[0] = _rows()[0];
        expected[1] = expected[0];
        assertTrue(verifier.statics(logs, expected, true));
        logs[0] = _table(LOADER, 2, new ExecutionEntry[](0), expected);
        assertTrue(verifier.statics(logs, _rows(), true));
        expected[1] = _rows()[0];
        expected[1].expectedEntryIndex++;
        assertFalse(verifier.statics(logs, expected, true));
        logs[0] = _table(LOADER, 2, new ExecutionEntry[](0), expected);
        assertFalse(verifier.statics(logs, _rows(), true));
    }

    function test_LoaderOrderingRejectsInterveningReplacementWithoutDemandingAdjacency() public {
        bytes32[] memory loaders = new bytes32[](1);
        loaders[0] = LOADER;
        uint256[] memory positions = new uint256[](2);
        positions[0] = 10;
        positions[1] = 5;
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](2);
        logs[0] = _table(LOADER, 2, new ExecutionEntry[](0), _rows());
        logs[1] = _table(OTHER, 0, new ExecutionEntry[](0), _rows());
        verifier.ordering(logs, loaders, positions);
        logs[1].transactionIndex = 4;
        vm.expectRevert("Intervening table replacement");
        verifier.ordering(logs, loaders, positions);
    }

    function test_LinkedCalldataMustMatchTableEvent() public {
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](1);
        logs[0] = _table(LOADER, 2, new ExecutionEntry[](0), _rows());
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = LOADER;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encodePacked(EEZL2.loadExecutionTable.selector, logs[0].data);
        verifier.linked(logs, new ExecutionEntry[](0), hashes, inputs, hashes);
        logs[0].data = abi.encode(new ExecutionEntry[](0), new StaticExecutionEntryL2[](0));
        vm.expectRevert("Table event/calldata mismatch");
        verifier.linked(logs, new ExecutionEntry[](0), hashes, inputs, hashes);
    }

    function test_SwappedSimilarSourceLinksCannotBorrowAggregateCoverage() public {
        ExecutionEntry[] memory expected = new ExecutionEntry[](2);
        expected[0].proxyEntryHash = keccak256("same call");
        expected[1].proxyEntryHash = expected[0].proxyEntryHash;
        expected[0].returnData = hex"01";
        expected[1].returnData = hex"02";
        ExecutionEntry[] memory one = new ExecutionEntry[](1);
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](2);
        one[0] = expected[0];
        logs[0] = _table(LOADER, 2, one, new StaticExecutionEntryL2[](0));
        one[0] = expected[1];
        logs[1] = _table(OTHER, 4, one, new StaticExecutionEntryL2[](0));
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = LOADER;
        hashes[1] = OTHER;
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encodePacked(EEZL2.executeIncomingCrossChainCall.selector, logs[0].data);
        inputs[1] = abi.encodePacked(EEZL2.executeIncomingCrossChainCall.selector, logs[1].data);
        verifier.linked(logs, expected, hashes, inputs, new bytes32[](0));
        (hashes[0], hashes[1]) = (hashes[1], hashes[0]);
        (inputs[0], inputs[1]) = (inputs[1], inputs[0]);
        vm.expectRevert("Linked table differs from source expectation");
        verifier.linked(logs, expected, hashes, inputs, new bytes32[](0));
    }
}
