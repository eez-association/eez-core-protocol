// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IntegrationBase} from "./IntegrationBase.t.sol";
import {ExecutionEntry, RollupUpdate, L2ToL1Call, ExpectedL1ToL2Call} from "../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../src/interfaces/IEEZL2.sol";
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
contract IntegrationTest is IntegrationBase {
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

    function setUp() public override {
        // ── Dual-manager infrastructure (EEZ + MockProofSystem + Rollup manager + EEZL2) ──
        super.setUp();

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

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 1: Alice -> A (-> B') -> resolved    [L1 deferred, simple]
    //
    //  Call chain:
    //    Alice calls A(CounterAndProxy) on L1
    //    -> A calls B'(proxy for B) on L1
    //    -> B' triggers EEZ.executeCrossChainCall
    //    -> execution table returns pre-computed result: abi.encode(1)
    //    -> A receives result, sets targetCounter=1, counter=1
    //
    //  The entry has no calls[] -- the proxy call triggers consumption and
    //  the pre-computed returnData is returned directly.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario1_L1CallsL2() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // proxyEntryHash: what executeCrossChainCall builds when A calls B'
        // B' proxy: originalAddress=counterL2, originalRollupId=L2_ROLLUP_ID
        // sourceAddress=counterAndProxy (A, msg.sender to B'), sourceRollup=MAINNET
        bytes32 crossChainCallHash = _ccHash(
            false, address(counterAndProxy), MAINNET_ROLLUP_ID, address(counterL2), L2_ROLLUP_ID, 0, incrementCallData
        );

        bytes32 newRoot = keccak256("l2-state-after-scenario1");

        // L1 deferred entry: no calls, just returnData
        {
            RollupUpdate[] memory rollupUpdates = new RollupUpdate[](1);
            rollupUpdates[0] =
                RollupUpdate({rollupId: L2_ROLLUP_ID, currentRoot: L2_GENESIS_STATE, newRoot: newRoot, etherDelta: 0});

            L2ToL1Call[] memory calls = new L2ToL1Call[](0);
            ExpectedL1ToL2Call[] memory nestedActions = new ExpectedL1ToL2Call[](0);

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0] = ExecutionEntry({
                rollupUpdates: rollupUpdates,
                proxyEntryHash: crossChainCallHash,
                destinationRollupId: L2_ROLLUP_ID,
                l2ToL1Calls: calls,
                expectedL1ToL2Calls: nestedActions,
                rollingHash: _hEntryBegin(rollupUpdates, crossChainCallHash),
                success: true,
                returnData: abi.encode(uint256(1))
            });

            _postBatchToL2(entries);
        }

        // Alice triggers the resolution
        vm.prank(alice);
        counterAndProxy.incrementProxy();

        // ── Final assertions ──
        assertEq(counterAndProxy.counter(), 1, "A.counter should be 1");
        assertEq(counterAndProxy.targetCounter(), 1, "A.targetCounter should be 1");
        assertEq(_getRollupState(L2_ROLLUP_ID), newRoot, "L2 rollup state should be updated");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 2: Alice -> D (-> C') -> resolved    [L2 deferred, simple]
    //
    //  Call chain (reverse of Scenario 1):
    //    Alice calls D(CounterAndProxy) on L2
    //    -> D calls C'(proxy for C) on L2
    //    -> C' triggers managerL2.executeCrossChainCall
    //    -> execution table returns pre-computed result: abi.encode(1)
    //    -> D receives result, sets targetCounter=1, counter=1
    //
    //  The entry has no calls[] -- same as Scenario 1 but on L2.
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario2_L2CallsL1() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // proxyEntryHash: what executeCrossChainCall builds when D calls C'
        // C' proxy: originalAddress=counterL1, originalRollupId=MAINNET_ROLLUP_ID
        // sourceAddress=counterAndProxyL2 (D, msg.sender to C'), sourceRollup=L2_ROLLUP_ID
        bytes32 crossChainCallHash =
            _ccHashL2Out(address(counterAndProxyL2), address(counterL1), MAINNET_ROLLUP_ID, 0, incrementCallData);

        // L2 execution table: one entry, no calls
        {
            CrossChainCall[] memory calls = new CrossChainCall[](0);
            ExpectedOutgoingCrossChainCall[] memory expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);

            L2ExecutionEntry[] memory entries = new L2ExecutionEntry[](1);
            entries[0] = L2ExecutionEntry({
                proxyEntryHash: crossChainCallHash,
                incomingCalls: calls,
                expectedOutgoingCalls: expectedOutgoingCalls,
                rollingHash: _hEntryBeginL2(crossChainCallHash),
                success: true,
                returnData: abi.encode(uint256(1))
            });

            _loadL2Table(entries, _emptyL2StaticEntries());
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
    //  into rollups.executeCrossChainCall. This consumes a separate L1 deferred
    //  entry (not an expectedOutgoingCall, because it is a different manager).
    //
    //  Flow:
    //    1. Alice calls A' on L2 -> managerL2.executeCrossChainCall
    //    2. L2 entry consumed -> _processNCalls(1)
    //    3. calls[0]: A'.executeOnBehalf(A, incrementProxy)
    //    4. A.incrementProxy() -> A calls B'
    //    5. B' -> rollups.executeCrossChainCall -> L1 entry consumed -> returns abi.encode(1)
    //    6. A: targetCounter=1, counter=1 (updated on-chain, shared single-EVM)
    //    7. L2 rolling hash verified, entry complete
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario3_NestedL2Entry() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);

        // ════════════════════════════════════════════
        //  Step 1: Prepare L1 deferred entry for B' call
        // ════════════════════════════════════════════

        bytes32 l1ActionHash = _ccHash(
            false, address(counterAndProxy), MAINNET_ROLLUP_ID, address(counterL2), L2_ROLLUP_ID, 0, incrementCallData
        );

        bytes32 newRoot = keccak256("l2-state-after-scenario3");

        {
            RollupUpdate[] memory rollupUpdates = new RollupUpdate[](1);
            rollupUpdates[0] =
                RollupUpdate({rollupId: L2_ROLLUP_ID, currentRoot: L2_GENESIS_STATE, newRoot: newRoot, etherDelta: 0});

            L2ToL1Call[] memory calls = new L2ToL1Call[](0);
            ExpectedL1ToL2Call[] memory nestedActions = new ExpectedL1ToL2Call[](0);

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0] = ExecutionEntry({
                rollupUpdates: rollupUpdates,
                proxyEntryHash: l1ActionHash,
                destinationRollupId: L2_ROLLUP_ID,
                l2ToL1Calls: calls,
                expectedL1ToL2Calls: nestedActions,
                rollingHash: _hEntryBegin(rollupUpdates, l1ActionHash),
                success: true,
                returnData: abi.encode(uint256(1))
            });

            _postBatchToL2(entries);
        }

        // ════════════════════════════════════════════
        //  Step 2: Prepare L2 entry for A' call (with sub-calls)
        // ════════════════════════════════════════════

        bytes32 l2ActionHash =
            _ccHashL2Out(alice, address(counterAndProxy), MAINNET_ROLLUP_ID, 0, incrementProxyCallData);

        // L2 rolling hash: seed (entry identity) + one top-level call (A.incrementProxy via A').
        // The call's identity folds source=(A, MAINNET) and target=this L2 (ROLLUP_ID).
        bytes32 callHash = _ccHash(
            false,
            address(counterAndProxy),
            MAINNET_ROLLUP_ID,
            address(counterAndProxy),
            L2_ROLLUP_ID,
            0,
            incrementProxyCallData
        );
        bytes32 rollingHash = _hCallBegin(_hEntryBeginL2(l2ActionHash), callHash);
        rollingHash = _hCallEnd(rollingHash, true, "");

        {
            ExpectedOutgoingCrossChainCall[] memory expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);

            CrossChainCall[] memory calls = new CrossChainCall[](1);
            calls[0] = CrossChainCall({
                gas: 0,
                revertNextNCalls: 0,
                isStatic: false,
                sourceAddress: address(counterAndProxy), // proxy identity = A'
                sourceRollupId: MAINNET_ROLLUP_ID,
                targetAddress: address(counterAndProxy), // A
                value: 0,
                data: incrementProxyCallData
            });

            L2ExecutionEntry[] memory entries = new L2ExecutionEntry[](1);
            entries[0] = L2ExecutionEntry({
                proxyEntryHash: l2ActionHash,
                incomingCalls: calls,
                expectedOutgoingCalls: expectedOutgoingCalls,
                rollingHash: rollingHash,
                success: true,
                returnData: ""
            });

            _loadL2Table(entries, _emptyL2StaticEntries());
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
        assertEq(_getRollupState(L2_ROLLUP_ID), newRoot, "L2 state should be updated via L1 entry");
        assertEq(rollups.entryQueueIndex(L2_ROLLUP_ID), 1, "L1 execution entry should be consumed");
        assertEq(managerL2.entryIndex(), 1, "L2 execution entry should be consumed");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Scenario 4: Alice -> D' (-> D -> C') -> resolved
    //              [L1 entry with calls, D' triggers on L1, cross-manager to L2]
    //
    //  Mirror of Scenario 3 but directions swapped:
    //
    //  The L1 entry has calls[] that execute D.incrementProxy() via a proxy.
    //  Inside D.incrementProxy(), D calls C' (L2 proxy for C), which crosses
    //  into managerL2.executeCrossChainCall. This consumes a separate L2 entry
    //  (not an expectedL1ToL2Call, because it is a different manager).
    //
    //  Flow:
    //    1. Alice calls D' on L1 -> rollups.executeCrossChainCall
    //    2. L1 entry consumed -> _processNCalls(1)
    //    3. calls[0]: proxy.executeOnBehalf(counterAndProxyL2, incrementProxy)
    //    4. D.incrementProxy() -> D calls C'
    //    5. C' -> managerL2.executeCrossChainCall -> L2 entry consumed -> returns abi.encode(1)
    //    6. D: targetCounter=1, counter=1 (updated on-chain, shared single-EVM)
    //    7. L1 rolling hash verified, entry complete
    // ═══════════════════════════════════════════════════════════════════════

    function test_Scenario4_NestedL1Entry() public {
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);
        bytes memory incrementProxyCallData = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);

        // ════════════════════════════════════════════
        //  Step 1: Prepare L2 entry for C' call
        // ════════════════════════════════════════════

        bytes32 l2ActionHash =
            _ccHashL2Out(address(counterAndProxyL2), address(counterL1), MAINNET_ROLLUP_ID, 0, incrementCallData);

        {
            CrossChainCall[] memory calls = new CrossChainCall[](0);
            ExpectedOutgoingCrossChainCall[] memory expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);

            L2ExecutionEntry[] memory entries = new L2ExecutionEntry[](1);
            entries[0] = L2ExecutionEntry({
                proxyEntryHash: l2ActionHash,
                incomingCalls: calls,
                expectedOutgoingCalls: expectedOutgoingCalls,
                rollingHash: _hEntryBeginL2(l2ActionHash),
                success: true,
                returnData: abi.encode(uint256(1))
            });

            _loadL2Table(entries, _emptyL2StaticEntries());
        }

        // ════════════════════════════════════════════
        //  Step 2: Prepare L1 entry for D' call (with sub-calls)
        // ════════════════════════════════════════════

        bytes32 l1ActionHash = _ccHash(
            false, alice, MAINNET_ROLLUP_ID, address(counterAndProxyL2), L2_ROLLUP_ID, 0, incrementProxyCallData
        );

        bytes32 s1 = keccak256("l2-state-s4-step1");

        {
            RollupUpdate[] memory rollupUpdates = new RollupUpdate[](1);
            rollupUpdates[0] =
                RollupUpdate({rollupId: L2_ROLLUP_ID, currentRoot: L2_GENESIS_STATE, newRoot: s1, etherDelta: 0});

            ExpectedL1ToL2Call[] memory nestedActions = new ExpectedL1ToL2Call[](0);

            L2ToL1Call[] memory calls = new L2ToL1Call[](1);
            calls[0] = L2ToL1Call({
                gas: 0,
                revertNextNCalls: 0,
                isStatic: false,
                sourceAddress: alice, // proxy identity: (alice, L2)
                sourceRollupId: L2_ROLLUP_ID,
                targetAddress: address(counterAndProxyL2), // D
                value: 0,
                data: incrementProxyCallData
            });

            // L1 rolling hash: entry seed (state + identity) + one top-level call (D.incrementProxy via D').
            // The call's identity folds source=(alice, L2) and target on L1 (MAINNET).
            bytes32 callHash = _ccHash(
                false, alice, L2_ROLLUP_ID, address(counterAndProxyL2), MAINNET_ROLLUP_ID, 0, incrementProxyCallData
            );
            bytes32 rollingHash = _hCallBegin(_hEntryBegin(rollupUpdates, l1ActionHash), callHash);
            rollingHash = _hCallEnd(rollingHash, true, "");

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0] = ExecutionEntry({
                rollupUpdates: rollupUpdates,
                proxyEntryHash: l1ActionHash,
                destinationRollupId: L2_ROLLUP_ID,
                l2ToL1Calls: calls,
                expectedL1ToL2Calls: nestedActions,
                rollingHash: rollingHash,
                success: true,
                returnData: ""
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
        assertEq(rollups.entryQueueIndex(L2_ROLLUP_ID), 1, "L1 execution entry should be consumed");
        assertEq(managerL2.entryIndex(), 1, "L2 execution entry should be consumed");
    }
}
