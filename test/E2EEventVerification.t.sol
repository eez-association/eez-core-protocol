// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {EEZ} from "../src/EEZ.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {ExecutionEntry, RollupUpdate, L2ToL1Call, ExpectedL1ToL2Call} from "../src/interfaces/IEEZ.sol";
import {VerifyHelpers, VerifyL1BatchCalldata} from "../script/e2e/scenarios/shared/Verify.s.sol";
import {ExecutionEntry as L2Entry, ExpectedOutgoingCrossChainCall} from "../src/interfaces/IEEZL2.sol";
import {DecodeExecutions} from "../script/tools/DecodeExecutions.s.sol";

contract EventSummaryHarness is DecodeExecutions {
    function summary(Vm.EthGetLogs[] memory logs) external pure returns (string memory) {
        return _buildSummary(logs);
    }
}

contract E2EEventVerificationHarness is VerifyHelpers {
    function l2Fields(
        L2Entry[] memory actual,
        Vm.EthGetLogs[] memory logs,
        L2Entry[] memory expected
    )
        external
        pure
        returns (bool)
    {
        return _verifyL2TableFields(actual, logs, abi.encode(expected), new bytes32[](0));
    }

    function completions(Vm.EthGetLogs[] memory logs, ExecutionEntry[] memory entries) external pure returns (bool) {
        return _verifyL1Completions(logs, entries);
    }

    function fields(Vm.EthGetLogs[] memory logs, ExecutionEntry[] memory entries) external pure returns (bool) {
        return _verifyL1EntryFields(logs, abi.encode(entries));
    }

    function eventless(
        Vm.EthGetLogs[] memory logs,
        ExecutionEntry[] memory entries,
        bytes32[] memory keys
    )
        external
        pure
        returns (bool, ExecutionEntry[] memory)
    {
        _validateEventlessL1(entries, keys);
        return _filterEventlessL1(logs, entries, keys);
    }

    function eventlessPartial(
        Vm.EthGetLogs[] memory logs,
        ExecutionEntry[] memory matched,
        ExecutionEntry[] memory expected,
        bytes32[] memory keys
    )
        external
        pure
        returns (bool, ExecutionEntry[] memory)
    {
        _validateEventlessL1(expected, keys);
        return _filterEventlessL1(logs, matched, keys);
    }

    function updateChain(ExecutionEntry[] memory entries, bytes32[] memory keys) external pure returns (bool) {
        return _checkPostedUpdateChain(entries, true, keys);
    }

    function roots(
        address registry,
        ExecutionEntry[] memory entries,
        bytes32[] memory keys
    )
        external
        view
        returns (bool)
    {
        return _checkLiveRoots(registry, entries, entries, keys);
    }

    function content(ExecutionEntry memory posted, ExecutionEntry memory expected) external pure returns (bool) {
        return _comparePostedEntry(posted, expected, 0);
    }

    function l2Completion(
        Vm.EthGetLogs[] memory logs,
        bytes32 hash,
        uint256 calls,
        uint256 cursor
    )
        external
        pure
        returns (bool)
    {
        return _hasTriple(_collectExecutedTriples(logs), hash, calls, cursor);
    }
}

contract E2EEventVerificationTest is Test {
    E2EEventVerificationHarness internal verifier;
    bytes32 internal constant HASH = keccak256("expected execution");

    function setUp() public {
        verifier = new E2EEventVerificationHarness();
    }

    function _entries(uint256 count) internal pure returns (ExecutionEntry[] memory entries) {
        entries = new ExecutionEntry[](count);
        for (uint256 i; i < count; i++) {
            entries[i].success = true;
            entries[i].rollingHash = HASH;
            entries[i].destinationRollupId = 1;
            entries[i].rollupUpdates = new RollupUpdate[](1);
            entries[i].rollupUpdates[0].rollupId = 1;
        }
    }

    function _log(bytes32 signature, bytes memory data) internal pure returns (Vm.EthGetLogs memory log) {
        log.topics = new bytes32[](2);
        log.topics[0] = signature;
        log.data = data;
    }

    function test_UnrelatedCompletionsCannotSatisfyExpectedEntry() public view {
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](2);
        logs[0] = _log(EEZ.EntryExecuted.selector, abi.encode(keccak256("other execution")));
        logs[1] = logs[0];
        assertFalse(verifier.completions(logs, _entries(1)));
    }

    function test_RepeatedExpectedHashRequiresDistinctLogs() public view {
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](2);
        logs[0] = _log(EEZ.EntryExecuted.selector, abi.encode(HASH));
        logs[1] = _log(EEZ.EntryExecuted.selector, abi.encode(keccak256("other execution")));
        assertFalse(verifier.completions(logs, _entries(2)));
        logs[1] = _log(EEZ.EntryExecuted.selector, abi.encode(HASH));
        assertTrue(verifier.completions(logs, _entries(2)));
    }

    function test_L1AndL2CompletionLayoutsAreSeparate() public view {
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](1);
        logs[0] = _log(EEZL2.EntryExecuted.selector, abi.encode(HASH, uint256(2), uint256(3)));
        assertFalse(verifier.completions(logs, _entries(1)));
        assertTrue(verifier.l2Completion(logs, HASH, 2, 3));
        assertFalse(verifier.l2Completion(logs, HASH, 2, 2));
        logs[0] = _log(EEZ.EntryExecuted.selector, abi.encode(HASH));
        assertTrue(verifier.completions(logs, _entries(1)));
        assertFalse(verifier.l2Completion(logs, HASH, 0, 0));
    }

    function test_MalformedL1PayloadDoesNotCountAsCompletion() public view {
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](2);
        logs[0] = _log(EEZ.EntryExecuted.selector, abi.encode(HASH, uint256(1), uint256(1)));
        assertFalse(verifier.completions(logs, _entries(1)));
    }

    function test_RevertingEntryDoesNotRequireCompletion() public view {
        ExecutionEntry[] memory entries = _entries(1);
        entries[0].success = false;
        assertTrue(verifier.fields(new Vm.EthGetLogs[](0), entries));
    }

    function test_ProxyEntryNeedsConsumptionOnItsDestinationRollup() public view {
        ExecutionEntry[] memory entries = _entries(1);
        entries[0].proxyEntryHash = keccak256("proxy call");
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](2);
        logs[0] = _log(EEZ.EntryExecuted.selector, abi.encode(HASH));
        assertFalse(verifier.fields(logs, entries));
        logs[1].topics = new bytes32[](4);
        logs[1].topics[0] = EEZ.ExecutionConsumed.selector;
        logs[1].topics[1] = entries[0].proxyEntryHash;
        logs[1].topics[2] = bytes32(uint256(2));
        assertFalse(verifier.fields(logs, entries));
        logs[1].topics[2] = bytes32(uint256(1));
        assertTrue(verifier.fields(logs, entries));
    }

    function test_ExplicitParentRollbackDoesNotRequireCompletion() public view {
        ExecutionEntry[] memory entries = _entries(1);
        entries[0].proxyEntryHash = keccak256("erased call");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = entries[0].proxyEntryHash;
        (bool ok, ExecutionEntry[] memory committed) = verifier.eventless(new Vm.EthGetLogs[](0), entries, keys);
        assertTrue(ok);
        assertEq(committed.length, 0);
        assertFalse(verifier.fields(new Vm.EthGetLogs[](0), entries), "absence alone must not imply rollback");
    }

    function test_ParentRollbackDeclarationRejectsSurvivingEvents() public view {
        ExecutionEntry[] memory entries = _entries(1);
        entries[0].proxyEntryHash = keccak256("erased call");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = entries[0].proxyEntryHash;
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](1);
        logs[0] = _log(EEZ.EntryExecuted.selector, abi.encode(HASH));
        (bool ok,) = verifier.eventless(logs, entries, keys);
        assertFalse(ok);
        logs[0].topics = new bytes32[](4);
        logs[0].topics[0] = EEZ.ExecutionConsumed.selector;
        logs[0].topics[1] = keys[0];
        logs[0].data = "";
        (ok,) = verifier.eventless(logs, entries, keys);
        assertFalse(ok);
    }

    function test_ParentRollbackCannotExemptUnrelatedEntry() public view {
        ExecutionEntry[] memory entries = _entries(2);
        entries[0].proxyEntryHash = keccak256("erased call");
        entries[1].proxyEntryHash = keccak256("committing call");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = entries[0].proxyEntryHash;
        (bool ok, ExecutionEntry[] memory committed) = verifier.eventless(new Vm.EthGetLogs[](0), entries, keys);
        assertTrue(ok);
        assertEq(committed.length, 1);
        assertEq(committed[0].proxyEntryHash, entries[1].proxyEntryHash);
        assertFalse(verifier.fields(new Vm.EthGetLogs[](0), committed));
    }

    function test_ParentRollbackDeclarationCanBelongToAnotherBatch() public {
        ExecutionEntry[] memory expected = _entries(2);
        expected[0].proxyEntryHash = keccak256("erased call in first batch");
        expected[1].proxyEntryHash = keccak256("committing call in second batch");
        expected[1].rollingHash = keccak256("second batch hash");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = expected[0].proxyEntryHash;
        ExecutionEntry[] memory matched = new ExecutionEntry[](1);
        matched[0] = expected[1];

        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](2);
        logs[0] = _log(EEZ.EntryExecuted.selector, abi.encode(expected[1].rollingHash));
        logs[1].topics = new bytes32[](4);
        logs[1].topics[0] = EEZ.ExecutionConsumed.selector;
        logs[1].topics[1] = expected[1].proxyEntryHash;
        logs[1].topics[2] = bytes32(uint256(1));
        (bool ok, ExecutionEntry[] memory committed) = verifier.eventlessPartial(logs, matched, expected, keys);
        assertTrue(ok);
        assertEq(committed.length, 1);
        assertTrue(verifier.fields(logs, committed));
        assertFalse(verifier.fields(new Vm.EthGetLogs[](0), committed), "other batch still needs completion");

        matched[0] = expected[0];
        (ok, committed) = verifier.eventlessPartial(new Vm.EthGetLogs[](0), matched, expected, keys);
        assertTrue(ok);
        assertEq(committed.length, 0);

        keys[0] = keccak256("unknown in every batch");
        vm.expectRevert("eventless L1 key is not a successful expected entry");
        verifier.eventlessPartial(new Vm.EthGetLogs[](0), matched, expected, keys);
    }

    function test_ParentRollbackStillChecksLiveRootWithoutCommittingEntries() public {
        ExecutionEntry[] memory entries = _entries(1);
        entries[0].proxyEntryHash = keccak256("erased call");
        entries[0].rollupUpdates[0].currentRoot = bytes32(uint256(1));
        entries[0].rollupUpdates[0].newRoot = bytes32(uint256(2));
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = entries[0].proxyEntryHash;
        address registry = address(0x1234);
        bytes memory callData = abi.encodeWithSignature("rollups(uint64)", uint64(1));
        vm.mockCall(registry, callData, abi.encode(address(0), bytes32(uint256(1)), uint256(0)));
        assertTrue(verifier.roots(registry, entries, keys));
        vm.mockCall(registry, callData, abi.encode(address(0), bytes32(uint256(2)), uint256(0)));
        assertFalse(verifier.roots(registry, entries, keys), "erased entry must not advance live root");
    }

    function test_ParentRollbackDoesNotWeakenRootChecksForTheRestOfItsBatch() public {
        ExecutionEntry[] memory entries = _entries(2);
        entries[0].proxyEntryHash = keccak256("erased call");
        entries[0].rollupUpdates[0].currentRoot = bytes32(uint256(1));
        entries[0].rollupUpdates[0].newRoot = bytes32(uint256(2));
        entries[1].proxyEntryHash = keccak256("committing call");
        entries[1].rollupUpdates[0].currentRoot = bytes32(uint256(1));
        entries[1].rollupUpdates[0].newRoot = bytes32(uint256(3));
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = entries[0].proxyEntryHash;
        assertTrue(verifier.updateChain(entries, keys));
        entries[1].rollupUpdates[0].currentRoot = bytes32(uint256(2));
        assertFalse(verifier.updateChain(entries, keys), "next entry must start at the restored root");
        entries[1].rollupUpdates[0].currentRoot = bytes32(uint256(1));

        address registry = address(0x1234);
        bytes memory callData = abi.encodeWithSignature("rollups(uint64)", uint64(1));
        vm.mockCall(registry, callData, abi.encode(address(0), bytes32(uint256(3)), uint256(0)));
        assertTrue(verifier.roots(registry, entries, keys));
        vm.mockCall(registry, callData, abi.encode(address(0), bytes32(uint256(2)), uint256(0)));
        assertFalse(verifier.roots(registry, entries, keys), "whole matched batch still needs exact final root");
    }

    function test_ParentRollbackRejectsAmbiguousRepeatedCalls() public {
        ExecutionEntry[] memory entries = _entries(2);
        bytes32 key = keccak256("repeated call");
        entries[0].proxyEntryHash = key;
        entries[1].proxyEntryHash = key;
        // Different results do not distinguish occurrences in a call-hash declaration.
        entries[0].returnData = abi.encode(uint256(1));
        entries[1].returnData = abi.encode(uint256(2));
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.expectRevert("ambiguous eventless L1 key");
        verifier.eventless(new Vm.EthGetLogs[](0), entries, keys);

        // Splitting the repeated occurrences across batches cannot hide the ambiguity.
        ExecutionEntry[] memory matched = new ExecutionEntry[](1);
        matched[0] = entries[0];
        vm.expectRevert("ambiguous eventless L1 key");
        verifier.eventlessPartial(new Vm.EthGetLogs[](0), matched, entries, keys);

        // A failed twin must not inherit the successful entry's exemption either.
        entries[1].success = false;
        vm.expectRevert("ambiguous eventless L1 key");
        verifier.eventless(new Vm.EthGetLogs[](0), entries, keys);
    }

    function test_EventlessPreflightValidatesWithoutCandidateOrRpc() public {
        VerifyL1BatchCalldata preflight = new VerifyL1BatchCalldata();
        ExecutionEntry[] memory entries = _entries(1);
        entries[0].proxyEntryHash = keccak256("erased call");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = entries[0].proxyEntryHash;
        preflight.validateExpectations(abi.encode(entries), keys);
        preflight.validateExpectations("", new bytes32[](0));
        vm.expectRevert("eventless L1 keys require EXPECTED_L1_TABLE");
        preflight.validateExpectations("", keys);
        keys[0] = keccak256("unknown");
        vm.expectRevert("eventless L1 key is not a successful expected entry");
        preflight.validateExpectations(abi.encode(entries), keys);
        keys[0] = entries[0].proxyEntryHash;
        entries[0].success = false;
        vm.expectRevert("eventless L1 key is not a successful expected entry");
        preflight.validateExpectations(abi.encode(entries), keys);
    }

    function test_InvalidParentRollbackDeclarationsRevert() public {
        ExecutionEntry[] memory entries = _entries(1);
        entries[0].proxyEntryHash = keccak256("erased call");
        bytes32[] memory keys = new bytes32[](1);
        vm.expectRevert("eventless L1 key cannot be zero");
        verifier.eventless(new Vm.EthGetLogs[](0), entries, keys);
        keys[0] = keccak256("unknown call");
        vm.expectRevert("eventless L1 key is not a successful expected entry");
        verifier.eventless(new Vm.EthGetLogs[](0), entries, keys);
        keys = new bytes32[](2);
        keys[0] = entries[0].proxyEntryHash;
        keys[1] = keys[0];
        vm.expectRevert("duplicate eventless L1 key");
        verifier.eventless(new Vm.EthGetLogs[](0), entries, keys);
    }

    function test_PostedCallArrayIsCheckedWithoutEmittedCount() public view {
        ExecutionEntry memory expected = _entries(1)[0];
        ExecutionEntry memory posted = _entries(1)[0];
        assertTrue(verifier.content(posted, expected));
        posted.l2ToL1Calls = new L2ToL1Call[](1);
        assertFalse(verifier.content(posted, expected));
    }

    function test_PostedNestedArrayIsCheckedWithoutEmittedCursor() public view {
        ExecutionEntry memory expected = _entries(1)[0];
        ExecutionEntry memory posted = _entries(1)[0];
        posted.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](1);
        assertFalse(verifier.content(posted, expected));
    }

    function _l2Entries(uint256 count) internal pure returns (L2Entry[] memory entries) {
        entries = new L2Entry[](count);
        for (uint256 i; i < count; i++) {
            entries[i].proxyEntryHash = keccak256("L2 proxy call");
            entries[i].rollingHash = HASH;
            entries[i].success = true;
            entries[i].returnData = hex"01";
        }
    }

    function _l2Logs(uint256 count) internal pure returns (Vm.EthGetLogs[] memory logs) {
        logs = new Vm.EthGetLogs[](count);
        for (uint256 i; i < count; i++) {
            logs[i] = _log(EEZL2.EntryExecuted.selector, abi.encode(HASH, uint256(0), uint256(0)));
            logs[i].topics[1] = bytes32(i);
        }
    }

    function test_L2CannotReuseExactLoadedTwinWithDifferentReturnData() public view {
        L2Entry[] memory expected = _l2Entries(2);
        L2Entry[] memory actual = _l2Entries(2);
        actual[1].returnData = hex"02"; // Same entry identity, different full contents.
        assertFalse(verifier.l2Fields(actual, _l2Logs(2), expected));
    }

    function test_L2RequiresDistinctCompletionsForRepeatedEntries() public view {
        assertFalse(verifier.l2Fields(_l2Entries(2), _l2Logs(1), _l2Entries(2)));
        assertTrue(verifier.l2Fields(_l2Entries(2), _l2Logs(2), _l2Entries(2)));
    }

    function test_L2PreservesSmallCursorForTighterExpectation() public view {
        L2Entry[] memory expected = _l2Entries(2);
        expected[0].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](3);
        expected[1].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](1);
        Vm.EthGetLogs[] memory logs = _l2Logs(2);
        logs[0].data = abi.encode(HASH, uint256(0), uint256(1));
        logs[1].data = abi.encode(HASH, uint256(0), uint256(3));
        assertTrue(verifier.l2Fields(expected, logs, expected));
    }

    function test_DecoderCountsExecutionRootUpdatesAndOmitsUnknownNestedCount() public {
        Vm.EthGetLogs[] memory logs = new Vm.EthGetLogs[](2);
        logs[0] = _log(EEZ.RootUpdated.selector, abi.encode(HASH));
        logs[1] = _log(EEZ.L2ExecutionPerformed.selector, abi.encode(HASH, uint256(0)));
        assertEq(
            new EventSummaryHarness().summary(logs),
            "batches=0 entries=0 calls=0(failed=0) revertSpans=0 l2tx=0 skipped=0 rollupUpdates=2 proxies=0"
        );
    }
}
