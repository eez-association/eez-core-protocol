// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {RollupUpdate, L2ToL1Call, ExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2ExecutionEntry, StaticExecutionEntryL2} from "../../../../../src/interfaces/IEEZL2.sol";
import {
    output,
    getOrCreateProxy,
    immediateSingleRollupBatch,
    noStaticEntries,
    crossChainCallHash,
    noNestedActions,
    noL2Calls,
    noL2OutgoingCalls,
    RollingHashBuilder,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// L2 -> L1, ONE source transaction:
//   reader.run() -> STATIC counter() = 0
//                -> CALL increment() = 1
//                -> STATIC counter() = 1
// L2: one mutable source entry; same-key static rows pin cursors 0 and 1.
//     One load before the trigger, no reload between reads. Static reads consume nothing.
// L1: ONE immediate zero-hash L2Tx entry runs [read, increment, read]
//     against the real counter, folding every result into the rolling hash.
// Final state: reader {beforeRead:0, incrementResult:1, afterRead:1, runs:1}; counter:1.

interface IStaticReadWriteTargetL2 {
    function counter() external view returns (uint256);
}

contract StaticReadWriteTargetL2 is IStaticReadWriteTargetL2 {
    uint256 public counter;

    function increment() external returns (uint256) {
        counter++;
        return counter;
    }
}

/// @notice One transaction: one static read, one remote increment, one static read.
contract StaticReadWriteReaderL2 {
    uint256 private constant PROXY_CALL_GAS = 5_000_000;
    StaticReadWriteTargetL2 public immutable target;
    uint256 public beforeRead;
    uint256 public incrementResult;
    uint256 public afterRead;
    uint256 public runs;

    constructor(StaticReadWriteTargetL2 remoteProxy) {
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

/// @dev Both sides of this L2-originating scenario, built from the same call identities.
abstract contract StaticReadWriteL2Actions {
    uint64 internal constant L2_ID = 1;

    function _initialRoot() internal pure returns (bytes32) {
        return keccak256("l2-initial-state");
    }

    function _finalRoot() internal pure returns (bytes32) {
        return keccak256("l2-state-after-static-read-write");
    }

    function _data(bool isStatic) internal pure returns (bytes memory) {
        return isStatic
            ? abi.encodeCall(IStaticReadWriteTargetL2.counter, ())
            : abi.encodeCall(StaticReadWriteTargetL2.increment, ());
    }

    function _key(bool isStatic, address counter, address reader) internal pure returns (bytes32) {
        return crossChainCallHash(isStatic, reader, L2_ID, counter, 0, 0, _data(isStatic));
    }

    function _l1Calls(address counter, address reader) internal pure returns (L2ToL1Call[] memory calls) {
        // One L2 user transaction maps to ONE L1 entry, including both real reads.
        calls = new L2ToL1Call[](3);
        for (uint256 i; i < calls.length; i++) {
            calls[i] = L2ToL1Call({
                gas: 0,
                revertNextNCalls: 0,
                isStatic: i != 1,
                sourceAddress: reader,
                sourceRollupId: L2_ID,
                targetAddress: counter,
                value: 0,
                data: _data(i != 1)
            });
        }
    }

    function _l1Steps(address counter, address reader) internal pure returns (HashStep[][] memory steps) {
        steps = new HashStep[][](1);
        steps[0] = new HashStep[](6);
        for (uint256 i; i < 3; i++) {
            steps[0][2 * i] = RollingHashBuilder.stepCallBegin(_key(i != 1, counter, reader));
            steps[0][2 * i + 1] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(i < 1 ? 0 : 1)));
        }
    }

    function _l1Entries(address counter, address reader) internal pure returns (ExecutionEntry[] memory entries) {
        RollupUpdate[] memory updates = new RollupUpdate[](1);
        updates[0] = RollupUpdate({rollupId: L2_ID, currentRoot: _initialRoot(), newRoot: _finalRoot(), etherDelta: 0});
        bytes32 rh = RollingHashBuilder.foldSteps(
            RollingHashBuilder.entryBegin(updates, bytes32(0)), _l1Steps(counter, reader)[0]
        );
        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: updates,
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ID,
            l2ToL1Calls: _l1Calls(counter, reader),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }

    function _l2Entries(address counter, address reader) internal pure returns (L2ExecutionEntry[] memory entries) {
        bytes32 key = _key(false, counter, reader);
        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: key,
            incomingCalls: noL2Calls(),
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: RollingHashBuilder.entryBeginL2(key),
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    function _l2Statics(
        address counter,
        address reader
    )
        internal
        pure
        returns (StaticExecutionEntryL2[] memory entries)
    {
        entries = new StaticExecutionEntryL2[](2);
        // Same key, future cursor FIRST. The first read must not advance the cursor.
        for (uint256 i; i < 2; i++) {
            entries[i] = StaticExecutionEntryL2({
                expectedEntryIndex: i == 0 ? 1 : 0,
                proxyEntryHash: _key(true, counter, reader),
                incomingCalls: noL2Calls(),
                rollingHash: bytes32(0),
                success: true,
                returnData: abi.encode(uint256(i == 0 ? 1 : 0))
            });
        }
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        StaticReadWriteTargetL2 counter = new StaticReadWriteTargetL2();
        output("COUNTER_L1", address(counter));
        vm.stopBroadcast();
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("MANAGER_L2")), vm.envAddress("COUNTER_L1"), 0);
        StaticReadWriteReaderL2 reader = new StaticReadWriteReaderL2(StaticReadWriteTargetL2(proxy));
        output("READER_L2", address(reader));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is Script, StaticReadWriteL2Actions {
    function run() external {
        address counter = vm.envAddress("COUNTER_L1");
        StaticReadWriteReaderL2 reader = StaticReadWriteReaderL2(vm.envAddress("READER_L2"));
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        vm.startBroadcast();
        manager.loadExecutionTable(_l2Entries(counter, address(reader)), _l2Statics(counter, address(reader)));
        reader.run(); // All three proxy calls are in this ONE trigger transaction.
        reader.assertFirstRun();
        require(manager.entryIndex() == 1, "expected one mutable consumption");
        vm.stopBroadcast();
        console.log("done: L2 counter read 0, increment 1, read 1");
    }
}

contract Execute is Script, StaticReadWriteL2Actions {
    function run() external {
        StaticReadWriteTargetL2 counter = StaticReadWriteTargetL2(vm.envAddress("COUNTER_L1"));
        address reader = vm.envAddress("READER_L2");
        require(counter.counter() == 0, "producer not initially zero");
        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"), L2_ID, _l1Entries(address(counter), reader), noStaticEntries()
                )
            );
        require(counter.counter() == 1, "destination counter mismatch");
        vm.stopBroadcast();
        console.log("done: L1 executed real read 0, increment 1, read 1");
    }
}

contract ExecuteNetworkL2 is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("READER_L2"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(StaticReadWriteReaderL2.run, ())));
    }
}

contract VerifyNetwork is Script {
    function run() external view {
        require(StaticReadWriteTargetL2(vm.envAddress("COUNTER_L1")).counter() == 1, "destination counter mismatch");
        console.log("VERIFY_PASS L1 counter=1");
    }
}

contract VerifyNetworkL2 is Script {
    function run() external view {
        StaticReadWriteReaderL2(vm.envAddress("READER_L2")).assertFirstRun();
        console.log("VERIFY_PASS L2 read 0 -> increment 1 -> read 1, one trigger");
    }
}

contract ComputeExpected is ComputeExpectedBase, StaticReadWriteL2Actions {
    function run() external view {
        address counter = vm.envAddress("COUNTER_L1");
        address reader = vm.envAddress("READER_L2");
        _printL1Expectations(counter, reader);
        L2ExecutionEntry[] memory l2 = _l2Entries(counter, reader);
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        _printL2CallHashes(l2);
        _printL2Table(l2);
        _logL2Entry(0, l2[0]);
        StaticExecutionEntryL2[] memory statics = _l2Statics(counter, reader);
        for (uint256 i; i < statics.length; i++) {
            _logStaticLookup(i, statics[i]);
        }
    }

    // Separate frame keeps the nested-table ABI encoder within the via-IR stack limit.
    function _printL1Expectations(address counter, address reader) private view {
        ExecutionEntry[] memory l1 = _l1Entries(counter, reader);
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        _printL1Steps(l1, _l1Steps(counter, reader));
        _printL1Table(l1);
        _logEntry(0, l1[0]);
    }
}
