// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {RollupUpdate, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy} from "../../../../../test/mocks/CounterContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noStaticEntries,
    noNestedActions,
    noCalls,
    RollingHashBuilder,
    immediateSingleRollupBatch,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Counter-multi-tx scenario — L1-starting, same target called NUM_TXS times
//  in NUM_TXS SEPARATE user transactions. multi_call's sibling category:
//  multi-call-twice makes both calls inside ONE tx via a CallTwice contract;
//  here the EOA sends one top-level tx per call.
//
//  L1 side (Execute):
//    1. postAndVerifyBatch loads NUM_TXS deferred entries with the SAME
//       proxyEntryHash (CAP -> Counter@L2 increment), returnData 1..NUM_TXS,
//       roots chained initial -> after-1 -> ... -> after-NUM_TXS
//    2. The EOA sends CounterAndProxy.incrementProxy() NUM_TXS times, each
//       its own tx; the runner mines batch + all triggers in one block
//    3. Each tx consumes the next queue entry via the cursor forward-scan;
//       after all: CAP counter=NUM_TXS, targetCounter=NUM_TXS
//
//  L2 side (ExecuteL2):
//    SYSTEM delivers each inbound call as its OWN executeIncomingCrossChainCall
//    tx carrying a 1-entry table — each load wipes the previous (already
//    consumed) table. All system txs are mined in one block; the verifier
//    concatenates the ExecutionTableLoaded events.
//
//  Every entry on both sides keys on the same `_callHash(counterL2, cap)`
//  preimage; only returnData (1..NUM_TXS) distinguishes the entries.
//
//  Network mode: ExecuteNetwork prints the tx shape plus NUM_TXS; the runner
//  pre-signs NUM_TXS copies with consecutive nonces and FIRES them all before
//  any is mined (no receipt wait between sends) — probing how the composer
//  handles several held triggers at once. Every tx hash and mined block is
//  printed for later inspection.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;
uint256 constant NUM_TXS = 3;

/// @dev Centralized call + entry definitions — single source of truth for all contracts.
abstract contract CounterMultiTxActions {
    function _incrementCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Counter.increment.selector);
    }

    /// @dev The proxy-entry hash of the inbound cross-chain call (CAP L1 -> Counter L2). Same on
    ///      both sides and for EVERY transaction — the calls are byte-identical.
    function _callHash(address counterL2, address counterAndProxy) internal pure returns (bytes32) {
        return
            crossChainCallHash(
                false, counterAndProxy, MAINNET_ROLLUP_ID, counterL2, L2_ROLLUP_ID, 0, _incrementCallData()
            );
    }

    /// @dev Placeholder root after the n-th increment; n = 0 is the registered initial root.
    function _rootAfter(uint256 n) internal pure returns (bytes32) {
        if (n == 0) return keccak256("l2-initial-state");
        return keccak256(abi.encodePacked("l2-state-after-multi-tx-", n));
    }

    /// @dev NUM_TXS L1 entries sharing one proxyEntryHash — consumed sequentially, one per user
    ///      tx, by the queue cursor. Roots chain across the entries; returnData is the
    ///      counter value each increment yields on L2. No L1 top-level calls, so each rolling
    ///      hash is just the entry-begin seed.
    function _l1Entries(
        address counterL2,
        address counterAndProxy
    )
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        bytes32 ah = _callHash(counterL2, counterAndProxy);

        entries = new ExecutionEntry[](NUM_TXS);
        for (uint256 n = 1; n <= NUM_TXS; n++) {
            RollupUpdate[] memory deltas = new RollupUpdate[](1);
            deltas[0] = RollupUpdate({
                rollupId: L2_ROLLUP_ID, currentRoot: _rootAfter(n - 1), newRoot: _rootAfter(n), etherDelta: 0
            });

            entries[n - 1] = ExecutionEntry({
                rollupUpdates: deltas,
                proxyEntryHash: ah,
                destinationRollupId: L2_ROLLUP_ID,
                l2ToL1Calls: noCalls(),
                expectedL1ToL2Calls: noNestedActions(),
                rollingHash: RollingHashBuilder.entryBegin(deltas, ah),
                success: true,
                returnData: abi.encode(n)
            });
        }
    }

    /// @dev The L2-side mirror entry for the n-th inbound delivery (n = 1..NUM_TXS). Each is
    ///      loaded and consumed by its own executeIncomingCrossChainCall tx, so each table holds
    ///      exactly one entry and every rolling hash starts fresh from the entry-begin seed.
    function _l2Entry(
        address counterL2,
        address counterAndProxy,
        uint256 n
    )
        internal
        pure
        returns (L2ExecutionEntry memory)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: counterAndProxy,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: counterL2,
            value: 0,
            data: _incrementCallData()
        });

        bytes32 ah = _callHash(counterL2, counterAndProxy);
        bytes32 rh = RollingHashBuilder.entryBeginL2(ah);
        rh = RollingHashBuilder.appendCallBegin(rh, ah);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(n));

        return L2ExecutionEntry({
            proxyEntryHash: ah,
            incomingCalls: calls,
            expectedOutgoingCalls: new ExpectedOutgoingCrossChainCall[](0),
            rollingHash: rh,
            success: true,
            returnData: abi.encode(n)
        });
    }

    /// @dev 1-entry table for the n-th executeIncomingCrossChainCall tx.
    function _l2TableForTx(
        address counterL2,
        address counterAndProxy,
        uint256 n
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        entries = new L2ExecutionEntry[](1);
        entries[0] = _l2Entry(counterL2, counterAndProxy, n);
    }

    /// @dev All entries in delivery order — what the block's ExecutionTableLoaded events sum to.
    function _l2Entries(
        address counterL2,
        address counterAndProxy
    )
        internal
        pure
        returns (L2ExecutionEntry[] memory entries)
    {
        entries = new L2ExecutionEntry[](NUM_TXS);
        for (uint256 n = 1; n <= NUM_TXS; n++) {
            entries[n - 1] = _l2Entry(counterL2, counterAndProxy, n);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys
// ═══════════════════════════════════════════════════════════════════════

/// @title DeployL2 — deploy Counter on L2
/// Outputs: COUNTER_L2
contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        Counter counterL2 = new Counter();
        console.log("COUNTER_L2=%s", address(counterL2));
        vm.stopBroadcast();
    }
}

/// @title Deploy — on L1, create proxy for counterL2 + deploy CounterAndProxy
/// Env: ROLLUPS, COUNTER_L2
/// Outputs: COUNTER_PROXY, COUNTER_AND_PROXY
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();
        EEZ rollups = EEZ(rollupsAddr);

        address counterProxy;
        try rollups.createCrossChainProxy(counterL2Addr, L2_ROLLUP_ID) returns (address p) {
            counterProxy = p;
        } catch {
            counterProxy = rollups.computeCrossChainProxyAddress(counterL2Addr, L2_ROLLUP_ID);
        }

        CounterAndProxy cap = new CounterAndProxy(Counter(counterProxy));

        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(cap));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// @title ExecuteL2 — local mode: NUM_TXS system-driven deliveries of the inbound call, one tx
///        each.
/// @dev Runs on L2. The local deployer (anvil account 0) is the SYSTEM_ADDRESS. Each
///      executeIncomingCrossChainCall replaces the table with its own single entry and consumes
///      it; the runner mines all txs in one block.
/// Env: MANAGER_L2, COUNTER_L2, COUNTER_AND_PROXY
contract ExecuteL2 is Script, CounterMultiTxActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");

        vm.startBroadcast();
        for (uint256 n = 1; n <= NUM_TXS; n++) {
            EEZL2(managerAddr)
                .executeIncomingCrossChainCall(
                    _l2TableForTx(counterL2Addr, capAddr, n), new L2StaticExecutionEntry[](0)
                );
        }

        console.log("done");
        console.log("L2 counter=%s", Counter(counterL2Addr).counter());
        vm.stopBroadcast();
    }
}

/// @title Execute — local mode: postAndVerifyBatch tx + NUM_TXS separate incrementProxy txs
///        from the EOA. The runner mines all of them in one block (execute_l1_same_block),
///        satisfying the same-block consumption gate; each trigger tx consumes the next queue
///        entry.
/// Env: ROLLUPS, PROOF_SYSTEM, COUNTER_L2, COUNTER_AND_PROXY
contract Execute is Script, CounterMultiTxActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    proofSystemAddr, L2_ROLLUP_ID, _l1Entries(counterL2Addr, capAddr), noStaticEntries()
                )
            );
        for (uint256 n = 1; n <= NUM_TXS; n++) {
            CounterAndProxy(capAddr).incrementProxy();
        }

        console.log("done");
        console.log("counter=%s", CounterAndProxy(capAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(capAddr).targetCounter());
        vm.stopBroadcast();
    }
}

/// @title ExecuteNetwork — network mode: one trigger tx shape, fired NUM_TXS times.
///        The runner pre-signs NUM_TXS copies with consecutive nonces and publishes
///        them all without waiting for receipts.
/// Env: COUNTER_AND_PROXY
contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("COUNTER_AND_PROXY");
        bytes memory data = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(data));
        console.log("NUM_TXS=%s", NUM_TXS);
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected — print expected tables for verification
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, CounterMultiTxActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "Counter";
        if (a == vm.envAddress("COUNTER_AND_PROXY")) return "CounterAndProxy";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Counter.increment.selector) return "increment";
        return ComputeExpectedBase._funcName(sel);
    }

    /// @dev Comma-joined `_entryHash` list for the EXPECTED_*_HASHES protocol lines.
    function _entryHashList(ExecutionEntry[] memory entries) private pure returns (string memory acc) {
        for (uint256 i = 0; i < entries.length; i++) {
            acc = i == 0
                ? vm.toString(_entryHash(entries[i]))
                : string.concat(acc, ",", vm.toString(_entryHash(entries[i])));
        }
    }

    function _entryHashList(L2ExecutionEntry[] memory entries) private pure returns (string memory acc) {
        for (uint256 i = 0; i < entries.length; i++) {
            acc = i == 0
                ? vm.toString(_entryHash(entries[i]))
                : string.concat(acc, ",", vm.toString(_entryHash(entries[i])));
        }
    }

    function run() external view {
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address capAddr = vm.envAddress("COUNTER_AND_PROXY");

        ExecutionEntry[] memory l1 = _l1Entries(counterL2Addr, capAddr);
        L2ExecutionEntry[] memory l2 = _l2Entries(counterL2Addr, capAddr);

        console.log("EXPECTED_L1_HASHES=[%s]", _entryHashList(l1));
        console.log("EXPECTED_L2_HASHES=[%s]", _entryHashList(l2));
        _printL1CallHashes(l1);
        _printL2CallHashes(l2);
        _printL1Table(l1);
        _printL1Steps(l1, new HashStep[][](NUM_TXS)); // every entry: seed only, no folds
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L1 EXECUTION TABLE (%s entries, same proxyEntryHash) ===", NUM_TXS);
        for (uint256 i = 0; i < l1.length; i++) {
            _logEntry(i, l1[i]);
        }

        console.log("");
        console.log("=== EXPECTED L2 EXECUTION TABLE (%s entries, one tx each) ===", NUM_TXS);
        for (uint256 i = 0; i < l2.length; i++) {
            _logL2Entry(i, l2[i]);
        }
    }
}
