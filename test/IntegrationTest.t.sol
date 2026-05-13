// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {EEZ, RollupConfig, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../src/EEZ.sol";
import {Rollup} from "../src/rollupContract/Rollup.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {CrossChainProxy} from "../src/base/CrossChainProxy.sol";
import {
    ExecutionEntry,
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    LookupCall,
    ProxyInfo
} from "../src/interfaces/IEEZ.sol";
import {MockProofSystem} from "./mocks/MockProofSystem.sol";
import {Counter, CounterAndProxy} from "./mocks/CounterContracts.sol";

/// @title IntegrationTest
/// @notice End-to-end tests of L1 <-> L2 cross-chain call flows using Counter contracts
///
/// ┌──────────────────────────────────────────────────────────────────────────┐
/// │  Legend                                                                  │
/// │    A  = CounterAndProxy on L1   (calls a proxy, updates local counter)  │
/// │    B  = Counter on L2           (simple increment, returns new value)   │
/// │    C  = Counter on L1           (simple increment, returns new value)   │
/// │    D  = CounterAndProxy on L2   (calls a proxy, updates local counter)  │
/// │    X' = CrossChainProxy for X   (deployed on the OTHER chain)           │
/// └──────────────────────────────────────────────────────────────────────────┘
///
/// ┌────┬──────────────────────────────────────────────────────────────────────┐
/// │  # │ Flow                              │ Direction      │ Type           │
/// ├────┼───────────────────────────────────┼────────────────┼────────────────┤
/// │  1 │ Alice -> A  (-> B') -> resolved   │ L1 deferred    │ Simple         │
/// │  2 │ Alice -> D  (-> C') -> resolved   │ L2 deferred    │ Simple         │
/// │  3 │ Alice -> A' (-> A -> B') resolved │ L2 entry+calls │ Nested (L2->L1)│
/// │  4 │ Alice -> D' (-> D -> C') resolved │ L1 entry+calls │ Nested (L1->L2)│
/// └────┴───────────────────────────────────┴────────────────┴────────────────┘
contract IntegrationTest is Test {
    // ── Rolling hash tag constants (must match contracts) ──
    uint8 constant CALL_BEGIN = 1;
    uint8 constant CALL_END = 2;
    uint8 constant NESTED_BEGIN = 3;
    uint8 constant NESTED_END = 4;

    // ── L1 contracts ──
    EEZ public rollups;
    MockProofSystem public ps;
    Rollup public l2Manager; // per-rollup IRollupContract manager for L2_ROLLUP_ID

    // ── L2 contracts ──
    EEZL2 public managerL2;

    // ── Application contracts (see legend) ──
    CounterAndProxy public counterAndProxy; // A  -- CounterAndProxy on L1, target = B'
    Counter public counterL2; // B  -- Counter on L2
    Counter public counterL1; // C  -- Counter on L1
    CounterAndProxy public counterAndProxyL2; // D -- CounterAndProxy on L2, target = C'

    // ── Proxies (see legend) ──
    address public counterProxy; // B' -- proxy for B, deployed on L1
    address public counterProxyL2; // C' -- proxy for C, deployed on L2
    address public counterAndProxyProxyL2; // A' -- proxy for A, deployed on L2
    address public counterAndProxyL2ProxyL1; // D' -- proxy for D, deployed on L1

    // ── Constants ──
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    address public alice = makeAddr("alice");

    function setUp() public {
        // ── L1 infrastructure ──
        rollups = new EEZ();
        ps = new MockProofSystem();

        // The contract has no `startingRollupId` constructor arg, so `rollupCounter`
        // starts at 0 and the FIRST registered rollup would receive id 0 = MAINNET.
        // postAndVerifyBatch validation rejects id 0 (strict-increasing from MAINNET_ROLLUP_ID),
        // so we burn id 0 with a throwaway rollup, then register L2 at id 1.
        {
            address[] memory psList = new address[](1);
            psList[0] = address(ps);
            bytes32[] memory vks = new bytes32[](1);
            vks[0] = DEFAULT_VK;
            Rollup burnRollup = new Rollup(address(rollups), address(this), 1, psList, vks);
            rollups.registerRollup(address(burnRollup), bytes32(0));
        }

        // Create L2 rollup at id = 1 = L2_ROLLUP_ID
        {
            address[] memory psList = new address[](1);
            psList[0] = address(ps);
            bytes32[] memory vks = new bytes32[](1);
            vks[0] = DEFAULT_VK;
            l2Manager = new Rollup(address(rollups), address(this), 1, psList, vks);
            uint256 rid = rollups.registerRollup(address(l2Manager), keccak256("l2-initial-state"));
            require(rid == L2_ROLLUP_ID, "expected L2_ROLLUP_ID = 1");
        }

        // ── L2 infrastructure ──
        managerL2 = new EEZL2(L2_ROLLUP_ID, SYSTEM_ADDRESS);

        // ── Deploy application contracts ──
        counterL2 = new Counter(); // B
        counterL1 = new Counter(); // C

        // ── Deploy proxies ──
        // B': proxy for B(Counter on L2), lives on L1 -- so A can call B cross-chain
        counterProxy = rollups.createCrossChainProxy(address(counterL2), L2_ROLLUP_ID);

        // A: CounterAndProxy on L1, its target = B'
        counterAndProxy = new CounterAndProxy(Counter(counterProxy));

        // C': proxy for C(Counter on L1), lives on L2 -- so D can call C cross-chain
        counterProxyL2 = managerL2.createCrossChainProxy(address(counterL1), MAINNET_ROLLUP_ID);

        // D: CounterAndProxy on L2, its target = C'
        counterAndProxyL2 = new CounterAndProxy(Counter(counterProxyL2));

        // A': proxy for A(CounterAndProxy on L1), lives on L2 -- for Scenario 3
        counterAndProxyProxyL2 = managerL2.createCrossChainProxy(address(counterAndProxy), MAINNET_ROLLUP_ID);

        // D': proxy for D(CounterAndProxy on L2), lives on L1 -- for Scenario 4
        counterAndProxyL2ProxyL1 = rollups.createCrossChainProxy(address(counterAndProxyL2), L2_ROLLUP_ID);
    }

    function _getRollupState(uint256 rollupId) internal view returns (bytes32) {
        (, bytes32 stateRoot,) = rollups.rollups(rollupId);
        return stateRoot;
    }

    /// @notice Wraps a single sub-batch (one PS attesting one rollup) and posts it.
    function _postBatchToL2(ExecutionEntry[] memory entries) internal {
        _postBatchToL2(entries, _noLookupCalls(), 0, 0);
    }

    function _postBatchToL2(
        ExecutionEntry[] memory entries,
        LookupCall[] memory lookupCalls,
        uint256 transientCount,
        uint256 transientLookupCallCount
    )
        internal
    {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        uint256[] memory rids = new uint256[](1);
        rids[0] = L2_ROLLUP_ID;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](psList.length);
        for (uint256 _i = 0; _i < psList.length; _i++) {
            psIdx[_i] = uint64(_i);
        }
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](rids.length);
        for (uint256 _i = 0; _i < rids.length; _i++) {
            rps[_i] = RollupIdWithProofSystems({rollupId: rids[_i], proofSystemIndex: psIdx});
        }

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            entries: entries,
            l1ToL2lookupCalls: lookupCalls,
            transientExecutionEntryCount: transientCount,
            transientLookupCallCount: transientLookupCallCount,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
    }

    /// @notice Computes the action hash the same way executeL1ToL2Call does
    function _crossChainCallHash(
        uint256 rollupId,
        address destination,
        uint256 value,
        bytes memory data,
        address sourceAddress,
        uint256 sourceRollup
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup));
    }

    /// @notice Creates an empty LookupCall array (used by postAndVerifyBatch and loadExecutionTable)
    function _noLookupCalls() internal pure returns (LookupCall[] memory) {
        return new LookupCall[](0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 1: Alice -> A (-> B') -> resolved    [L1 deferred, simple]
    //
    //  Call chain:
    //    Alice calls A(CounterAndProxy) on L1
    //    -> A calls B'(proxy for B) on L1
    //    -> B' triggers EEZ.executeL1ToL2Call
    //    -> execution table returns pre-computed result: abi.encode(1)
    //    -> A receives result, sets targetCounter=1, counter=1
    //
    //  The entry has no calls[] -- the proxy call triggers consumption and
    //  the pre-computed returnData is returned directly.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario1_L1CallsL2() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // proxyEntryHash: what executeL1ToL2Call builds when A calls B'
        // B' proxy: originalAddress=counterL2, originalRollupId=L2_ROLLUP_ID
        // sourceAddress=counterAndProxy (A, msg.sender to B'), sourceRollup=MAINNET
        bytes32 crossChainCallHash = _crossChainCallHash(
            L2_ROLLUP_ID, address(counterL2), 0, incrementCallData, address(counterAndProxy), MAINNET_ROLLUP_ID
        );

        bytes32 newState = keccak256("l2-state-after-scenario1");

        // L1 deferred entry: no calls, just returnData
        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: L2_ROLLUP_ID, currentState: keccak256("l2-initial-state"), newState: newState, etherDelta: 0
            });

            L2ToL1Call[] memory calls = new L2ToL1Call[](0);
            ExpectedL1ToL2Call[] memory nestedActions = new ExpectedL1ToL2Call[](0);

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0] = ExecutionEntry({
                stateDeltas: stateDeltas,
                proxyEntryHash: crossChainCallHash,
                destinationRollupId: L2_ROLLUP_ID,
                L2ToL1Calls: calls,
                expectedL1ToL2Calls: nestedActions,
                callCount: 0,
                returnData: abi.encode(uint256(1)),
                rollingHash: bytes32(0)
            });

            _postBatchToL2(entries);
        }

        // Alice triggers the resolution
        vm.prank(alice);
        counterAndProxy.incrementProxy();

        // ── Final assertions ──
        assertEq(counterAndProxy.counter(), 1, "A.counter should be 1");
        assertEq(counterAndProxy.targetCounter(), 1, "A.targetCounter should be 1");
        assertEq(_getRollupState(L2_ROLLUP_ID), newState, "L2 rollup state should be updated");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 2: Alice -> D (-> C') -> resolved    [L2 deferred, simple]
    //
    //  Call chain (reverse of Scenario 1):
    //    Alice calls D(CounterAndProxy) on L2
    //    -> D calls C'(proxy for C) on L2
    //    -> C' triggers managerL2.executeL1ToL2Call
    //    -> execution table returns pre-computed result: abi.encode(1)
    //    -> D receives result, sets targetCounter=1, counter=1
    //
    //  The entry has no calls[] -- same as Scenario 1 but on L2.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario2_L2CallsL1() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // proxyEntryHash: what executeL1ToL2Call builds when D calls C'
        // C' proxy: originalAddress=counterL1, originalRollupId=MAINNET_ROLLUP_ID
        // sourceAddress=counterAndProxyL2 (D, msg.sender to C'), sourceRollup=L2_ROLLUP_ID
        bytes32 crossChainCallHash = _crossChainCallHash(
            MAINNET_ROLLUP_ID, address(counterL1), 0, incrementCallData, address(counterAndProxyL2), L2_ROLLUP_ID
        );

        // L2 execution table: one entry, no calls
        {
            StateDelta[] memory emptyDeltas = new StateDelta[](0);
            L2ToL1Call[] memory calls = new L2ToL1Call[](0);
            ExpectedL1ToL2Call[] memory nestedActions = new ExpectedL1ToL2Call[](0);

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0] = ExecutionEntry({
                stateDeltas: emptyDeltas,
                proxyEntryHash: crossChainCallHash,
                destinationRollupId: L2_ROLLUP_ID,
                L2ToL1Calls: calls,
                expectedL1ToL2Calls: nestedActions,
                callCount: 0,
                returnData: abi.encode(uint256(1)),
                rollingHash: bytes32(0)
            });

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries, _noLookupCalls());
        }

        // Alice triggers the resolution on L2
        vm.prank(alice);
        counterAndProxyL2.incrementProxy();

        // ── Final assertions ──
        assertEq(counterAndProxyL2.counter(), 1, "D.counter should be 1");
        assertEq(counterAndProxyL2.targetCounter(), 1, "D.targetCounter should be 1");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 3: Alice -> A' (-> A -> B') -> resolved
    //              [L2 entry with calls, A' triggers on L2, cross-manager to L1]
    //
    //  Full cross-chain flow with execution on BOTH chains:
    //
    //  The L2 entry has calls[] that execute A.incrementProxy() via A' proxy.
    //  Inside A.incrementProxy(), A calls B' (L1 proxy for B), which crosses
    //  into rollups.executeL1ToL2Call. This consumes a separate L1 deferred
    //  entry (not a nestedAction, because it is a different manager).
    //
    //  Flow:
    //    1. Alice calls A' on L2 -> managerL2.executeL1ToL2Call
    //    2. L2 entry consumed -> _processNCalls(1)
    //    3. calls[0]: A'.executeOnBehalf(A, incrementProxy)
    //    4. A.incrementProxy() -> A calls B'
    //    5. B' -> rollups.executeL1ToL2Call -> L1 entry consumed -> returns abi.encode(1)
    //    6. A: targetCounter=1, counter=1 (updated on-chain, shared single-EVM)
    //    7. L2 rolling hash verified, entry complete
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario3_NestedL2Entry() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);

        // ════════════════════════════════════════════
        //  Step 1: Prepare L1 deferred entry for B' call
        // ════════════════════════════════════════════

        bytes32 l1ActionHash = _crossChainCallHash(
            L2_ROLLUP_ID, address(counterL2), 0, incrementCallData, address(counterAndProxy), MAINNET_ROLLUP_ID
        );

        bytes32 newState = keccak256("l2-state-after-scenario3");

        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: L2_ROLLUP_ID, currentState: keccak256("l2-initial-state"), newState: newState, etherDelta: 0
            });

            L2ToL1Call[] memory calls = new L2ToL1Call[](0);
            ExpectedL1ToL2Call[] memory nestedActions = new ExpectedL1ToL2Call[](0);

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0] = ExecutionEntry({
                stateDeltas: stateDeltas,
                proxyEntryHash: l1ActionHash,
                destinationRollupId: L2_ROLLUP_ID,
                L2ToL1Calls: calls,
                expectedL1ToL2Calls: nestedActions,
                callCount: 0,
                returnData: abi.encode(uint256(1)),
                rollingHash: bytes32(0)
            });

            _postBatchToL2(entries);
        }

        // ════════════════════════════════════════════
        //  Step 2: Prepare L2 entry for A' call (with sub-calls)
        // ════════════════════════════════════════════

        bytes32 l2ActionHash = _crossChainCallHash(
            MAINNET_ROLLUP_ID, address(counterAndProxy), 0, incrementProxyCallData, alice, L2_ROLLUP_ID
        );

        // Compute rolling hash for L2 entry: 1 call, no nested actions
        bytes32 rollingHash = keccak256(abi.encodePacked(bytes32(0), CALL_BEGIN, uint256(1)));
        bytes memory voidRetData = "";
        rollingHash = keccak256(abi.encodePacked(rollingHash, CALL_END, uint256(1), true, voidRetData));

        {
            StateDelta[] memory emptyDeltas = new StateDelta[](0);
            ExpectedL1ToL2Call[] memory nestedActions = new ExpectedL1ToL2Call[](0);

            L2ToL1Call[] memory calls = new L2ToL1Call[](1);
            calls[0] = L2ToL1Call({
                targetAddress: address(counterAndProxy), // A
                value: 0,
                data: incrementProxyCallData,
                sourceAddress: address(counterAndProxy), // proxy identity = A'
                sourceRollupId: MAINNET_ROLLUP_ID,
                revertSpan: 0
            });

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0] = ExecutionEntry({
                stateDeltas: emptyDeltas,
                proxyEntryHash: l2ActionHash,
                destinationRollupId: L2_ROLLUP_ID,
                L2ToL1Calls: calls,
                expectedL1ToL2Calls: nestedActions,
                callCount: 1,
                returnData: "",
                rollingHash: rollingHash
            });

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries, _noLookupCalls());
        }

        // ════════════════════════════════════════════
        //  Step 3: Alice calls A' on L2
        // ════════════════════════════════════════════

        vm.prank(alice);
        (bool success,) = counterAndProxyProxyL2.call(incrementProxyCallData);
        assertTrue(success, "A' call should succeed");

        // ── Final assertions ──
        assertEq(counterAndProxy.counter(), 1, "A.counter should be 1");
        assertEq(counterAndProxy.targetCounter(), 1, "A.targetCounter should be 1");
        assertEq(_getRollupState(L2_ROLLUP_ID), newState, "L2 state should be updated via L1 entry");
        assertEq(rollups.queueCursor(L2_ROLLUP_ID), 1, "L1 execution entry should be consumed");
        assertEq(managerL2.executionIndex(), 1, "L2 execution entry should be consumed");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 4: Alice -> D' (-> D -> C') -> resolved
    //              [L1 entry with calls, D' triggers on L1, cross-manager to L2]
    //
    //  Mirror of Scenario 3 but directions swapped:
    //
    //  The L1 entry has calls[] that execute D.incrementProxy() via a proxy.
    //  Inside D.incrementProxy(), D calls C' (L2 proxy for C), which crosses
    //  into managerL2.executeL1ToL2Call. This consumes a separate L2 entry
    //  (not a nestedAction, because it is a different manager).
    //
    //  Flow:
    //    1. Alice calls D' on L1 -> rollups.executeL1ToL2Call
    //    2. L1 entry consumed -> _processNCalls(1)
    //    3. calls[0]: proxy.executeOnBehalf(counterAndProxyL2, incrementProxy)
    //    4. D.incrementProxy() -> D calls C'
    //    5. C' -> managerL2.executeL1ToL2Call -> L2 entry consumed -> returns abi.encode(1)
    //    6. D: targetCounter=1, counter=1 (updated on-chain, shared single-EVM)
    //    7. L1 rolling hash verified, entry complete
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario4_NestedL1Entry() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);

        // ════════════════════════════════════════════
        //  Step 1: Prepare L2 entry for C' call
        // ════════════════════════════════════════════

        bytes32 l2ActionHash = _crossChainCallHash(
            MAINNET_ROLLUP_ID, address(counterL1), 0, incrementCallData, address(counterAndProxyL2), L2_ROLLUP_ID
        );

        {
            StateDelta[] memory emptyDeltas = new StateDelta[](0);
            L2ToL1Call[] memory calls = new L2ToL1Call[](0);
            ExpectedL1ToL2Call[] memory nestedActions = new ExpectedL1ToL2Call[](0);

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0] = ExecutionEntry({
                stateDeltas: emptyDeltas,
                proxyEntryHash: l2ActionHash,
                destinationRollupId: L2_ROLLUP_ID,
                L2ToL1Calls: calls,
                expectedL1ToL2Calls: nestedActions,
                callCount: 0,
                returnData: abi.encode(uint256(1)),
                rollingHash: bytes32(0)
            });

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries, _noLookupCalls());
        }

        // ════════════════════════════════════════════
        //  Step 2: Prepare L1 entry for D' call (with sub-calls)
        // ════════════════════════════════════════════

        bytes32 l1ActionHash = _crossChainCallHash(
            L2_ROLLUP_ID, address(counterAndProxyL2), 0, incrementProxyCallData, alice, MAINNET_ROLLUP_ID
        );

        bytes32 s1 = keccak256("l2-state-s4-step1");

        // Compute rolling hash for L1 entry: 1 call, no nested actions
        bytes32 rollingHash = keccak256(abi.encodePacked(bytes32(0), CALL_BEGIN, uint256(1)));
        bytes memory voidRetData = "";
        rollingHash = keccak256(abi.encodePacked(rollingHash, CALL_END, uint256(1), true, voidRetData));

        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: L2_ROLLUP_ID, currentState: keccak256("l2-initial-state"), newState: s1, etherDelta: 0
            });

            ExpectedL1ToL2Call[] memory nestedActions = new ExpectedL1ToL2Call[](0);

            L2ToL1Call[] memory calls = new L2ToL1Call[](1);
            calls[0] = L2ToL1Call({
                targetAddress: address(counterAndProxyL2), // D
                value: 0,
                data: incrementProxyCallData,
                sourceAddress: alice, // proxy identity: (alice, L2)
                sourceRollupId: L2_ROLLUP_ID,
                revertSpan: 0
            });

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0] = ExecutionEntry({
                stateDeltas: stateDeltas,
                proxyEntryHash: l1ActionHash,
                destinationRollupId: L2_ROLLUP_ID,
                L2ToL1Calls: calls,
                expectedL1ToL2Calls: nestedActions,
                callCount: 1,
                returnData: "",
                rollingHash: rollingHash
            });

            _postBatchToL2(entries);
        }

        // ════════════════════════════════════════════
        //  Step 3: Alice calls D' on L1
        // ════════════════════════════════════════════

        vm.prank(alice);
        (bool success,) = counterAndProxyL2ProxyL1.call(incrementProxyCallData);
        assertTrue(success, "D' call should succeed");

        // ── Final assertions ──
        assertEq(counterAndProxyL2.counter(), 1, "D.counter should be 1");
        assertEq(counterAndProxyL2.targetCounter(), 1, "D.targetCounter should be 1");
        assertEq(_getRollupState(L2_ROLLUP_ID), s1, "L2 state should be updated");
        assertEq(rollups.queueCursor(L2_ROLLUP_ID), 1, "L1 execution entry should be consumed");
        assertEq(managerL2.executionIndex(), 1, "L2 execution entry should be consumed");
    }
}
