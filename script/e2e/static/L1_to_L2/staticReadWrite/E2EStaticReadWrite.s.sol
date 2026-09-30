// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    RollupUpdate,
    ExecutionEntry,
    StaticExecutionEntry,
    ExpectedRootPerRollup
} from "../../../../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2ExecutionEntry, CrossChainCall} from "../../../../../src/interfaces/IEEZL2.sol";
import {
    output,
    getOrCreateProxy,
    immediateSingleRollupBatch,
    noL2StaticEntries,
    crossChainCallHash,
    noCalls,
    noNestedActions,
    noL2OutgoingCalls,
    RollingHashBuilder,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// L1 -> L2, ONE source transaction:
//   reader.run() -> STATIC counter() = 0
//                -> CALL increment() = 1
//                -> STATIC counter() = 1
// L1: one mutable entry advances root R0 -> R1; two same-key static rows pin R0/R1.
// L2: ONE system delivery executes the real increment; no delivery for any read.
// Local mode checks the live producer before/after that delivery (0 -> 1).
// Final state: reader {beforeRead:0, incrementResult:1, afterRead:1, runs:1}; counter:1.

interface IStaticReadWriteTarget {
    function counter() external view returns (uint256);
}

contract StaticReadWriteTarget is IStaticReadWriteTarget {
    uint256 public counter;

    function increment() external returns (uint256) {
        counter++;
        return counter;
    }
}

/// @notice One transaction: one static read, one remote increment, one static read.
contract StaticReadWriteReader {
    uint256 private constant PROXY_CALL_GAS = 5_000_000;
    StaticReadWriteTarget public immutable target;
    uint256 public beforeRead;
    uint256 public incrementResult;
    uint256 public afterRead;
    uint256 public runs;

    constructor(StaticReadWriteTarget remoteProxy) {
        target = remoteProxy;
    }

    function run() external {
        beforeRead = target.counter();
        incrementResult = target.increment{gas: PROXY_CALL_GAS}();
        afterRead = target.counter();
        require(incrementResult == beforeRead + 1, "increment result differs");
        require(afterRead == incrementResult, "static read did not advance");
        runs++;
    }

    function assertFirstRun() external view {
        require(runs == 1, "expected one trigger");
        require(beforeRead == 0, "expected initial zero");
        require(incrementResult == 1, "expected increment to one");
        require(afterRead == 1, "expected final read of one");
    }
}

/// @dev Both sides of this L1-originating scenario, built from the same call identities.
abstract contract StaticReadWriteActions {
    uint64 internal constant L2_ID = 1;

    function _initialRoot() internal pure returns (bytes32) {
        return keccak256("l2-initial-state");
    }

    function _finalRoot() internal pure returns (bytes32) {
        return keccak256("l2-state-after-static-read-write");
    }

    function _data(bool isStatic) internal pure returns (bytes memory) {
        return isStatic
            ? abi.encodeCall(IStaticReadWriteTarget.counter, ())
            : abi.encodeCall(StaticReadWriteTarget.increment, ());
    }

    function _key(bool isStatic, address counter, address reader) internal pure returns (bytes32) {
        return crossChainCallHash(isStatic, reader, 0, counter, L2_ID, 0, _data(isStatic));
    }

    function _l1Entries(address counter, address reader) internal pure returns (ExecutionEntry[] memory entries) {
        RollupUpdate[] memory updates = new RollupUpdate[](1);
        updates[0] = RollupUpdate({rollupId: L2_ID, currentRoot: _initialRoot(), newRoot: _finalRoot(), etherDelta: 0});
        bytes32 key = _key(false, counter, reader);
        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: updates,
            proxyEntryHash: key,
            destinationRollupId: L2_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(updates, key),
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    function _l2Entries(address counter, address reader) internal pure returns (L2ExecutionEntry[] memory entries) {
        // Only the mutable frame is delivered; both static reads are lookups.
        bytes32 key = _key(false, counter, reader);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: reader,
            sourceRollupId: 0,
            targetAddress: counter,
            value: 0,
            data: _data(false)
        });
        bytes32 rh = RollingHashBuilder.entryBeginL2(key);
        rh = RollingHashBuilder.appendCallBegin(rh, key);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(1)));
        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: key,
            incomingCalls: calls,
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    function _l1Statics(address counter, address reader) internal pure returns (StaticExecutionEntry[] memory entries) {
        entries = new StaticExecutionEntry[](2);
        // Future snapshot FIRST: lookup must skip it before the increment, then select it after.
        for (uint256 i; i < 2; i++) {
            ExpectedRootPerRollup[] memory pins = new ExpectedRootPerRollup[](1);
            pins[0] = ExpectedRootPerRollup({rollupId: L2_ID, root: i == 0 ? _finalRoot() : _initialRoot()});
            entries[i] = StaticExecutionEntry({
                expectedRoots: pins,
                proxyEntryHash: _key(true, counter, reader),
                l2ToL1Calls: noCalls(),
                rollingHash: bytes32(0),
                destinationRollupId: L2_ID,
                success: true,
                returnData: abi.encode(uint256(i == 0 ? 1 : 0))
            });
        }
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        StaticReadWriteTarget counter = new StaticReadWriteTarget();
        require(counter.counter() == 0, "producer not initially zero");
        output("COUNTER_L2", address(counter));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), vm.envAddress("COUNTER_L2"), 1);
        StaticReadWriteReader reader = new StaticReadWriteReader(StaticReadWriteTarget(proxy));
        output("READER_L1", address(reader));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is Script, StaticReadWriteActions {
    function run() external {
        StaticReadWriteTarget counter = StaticReadWriteTarget(vm.envAddress("COUNTER_L2"));
        require(counter.counter() == 0, "before-read producer mismatch");
        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2"))
            .executeIncomingCrossChainCall(
                _l2Entries(address(counter), vm.envAddress("READER_L1")), noL2StaticEntries()
            );
        require(counter.counter() == 1, "after-read producer mismatch");
        vm.stopBroadcast();
        console.log("done: real L2 counter 0 -> 1; static reads have no delivery");
    }
}

contract Execute is Script, StaticReadWriteActions {
    function run() external {
        address counter = vm.envAddress("COUNTER_L2");
        StaticReadWriteReader reader = StaticReadWriteReader(vm.envAddress("READER_L1"));
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        vm.startBroadcast();
        manager.postAndVerifyBatch(
            immediateSingleRollupBatch(
                vm.envAddress("PROOF_SYSTEM"),
                L2_ID,
                _l1Entries(counter, address(reader)),
                _l1Statics(counter, address(reader))
            )
        );
        reader.run(); // All three proxy calls are in this ONE trigger transaction.
        reader.assertFirstRun();
        require(manager.entryQueueIndex(L2_ID) == 1, "expected one mutable consumption");
        vm.stopBroadcast();
        console.log("done: L1 counter read 0, increment 1, read 1");
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("READER_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(StaticReadWriteReader.run, ())));
    }
}

contract VerifyNetwork is Script {
    function run() external view {
        StaticReadWriteReader(vm.envAddress("READER_L1")).assertFirstRun();
        console.log("VERIFY_PASS L1 read 0 -> increment 1 -> read 1, one trigger");
    }
}

contract VerifyNetworkL2 is Script {
    function run() external view {
        require(StaticReadWriteTarget(vm.envAddress("COUNTER_L2")).counter() == 1, "destination counter mismatch");
        console.log("VERIFY_PASS L2 counter=1");
    }
}

contract ComputeExpected is ComputeExpectedBase, StaticReadWriteActions {
    function run() external view {
        address counter = vm.envAddress("COUNTER_L2");
        address reader = vm.envAddress("READER_L1");
        _printL1Expectations(counter, reader);
        L2ExecutionEntry[] memory l2 = _l2Entries(counter, reader);
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        _printL2CallHashes(l2);
        _printL2Table(l2);
        _logL2Entry(0, l2[0]);
        _printL1StaticTable(_l1Statics(counter, reader));
        console.log("ABSENT_L2_HASHES=[%s]", vm.toString(_key(true, counter, reader)));
    }

    // Separate frame keeps the nested-table ABI encoder within the via-IR stack limit.
    function _printL1Expectations(address counter, address reader) private view {
        ExecutionEntry[] memory l1 = _l1Entries(counter, reader);
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        _printL1CallHashes(l1);
        _printL1Steps(l1, new HashStep[][](1));
        _printL1Table(l1);
        _logEntry(0, l1[0]);
    }
}
