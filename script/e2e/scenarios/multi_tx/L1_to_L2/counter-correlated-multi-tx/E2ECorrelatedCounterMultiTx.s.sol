// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {IEEZ, RollupUpdate, ExecutionEntry} from "../../../../../../src/interfaces/IEEZ.sol";
import {EEZL2} from "../../../../../../src/L2/EEZL2.sol";
import {ExecutionEntry as L2ExecutionEntry, CrossChainCall} from "../../../../../../src/interfaces/IEEZL2.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    getOrCreateProxy,
    crossChainCallHash,
    noStaticEntries,
    noL2StaticEntries,
    noNestedActions,
    noL2OutgoingCalls,
    noCalls,
    RollingHashBuilder,
    immediateSingleRollupBatch,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// Three separate user transactions through the SAME L1 caller and L2 target:
// L1 tx i: EOA -> caller.execute()
//                  -> target.receiveCount(caller.counter) -> previous L2 count + input
//                  <- save result[i], increment caller.counter
// L2 delivery i: SYSTEM -> executeIncomingCrossChainCall([entry i])
//                          -> target.receiveCount(i)
//                          <- save input/result, increment target.counter
//
// i = 0, 1, 2: inputs = [0, 1, 2], results = [0, 2, 4], both final counters = 3.
// Each completed top-level call has one L1 entry and one L2 delivery. Its calldata
// (and therefore its call hash) depends on persisted L1 state from earlier txs;
// the real L2 return depends on persisted L2 state from earlier deliveries.
// Local mode uses one batch with chained placeholder roots and three triggers in
// the same block. Network mode repeats the parameterless trigger with consecutive
// nonces, as in counter-multi-tx; the composer supplies actual tables and roots.

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;
uint256 constant NUM_TXS = 3;

contract CorrelatedCounter {
    uint256 public counter;
    mapping(uint256 => uint256) public inputs;
    mapping(uint256 => uint256) public results;

    function receiveCount(uint256 input) external returns (uint256 result) {
        uint256 previousCount = counter;
        require(input == previousCount, "out-of-order L1 count");
        result = previousCount + input;
        inputs[previousCount] = input;
        results[previousCount] = result;
        counter = previousCount + 1;
    }
}

contract CorrelatedCounterCaller {
    CorrelatedCounter public immutable target;
    uint256 public counter;
    mapping(uint256 => uint256) public results;

    constructor(CorrelatedCounter target_) {
        target = target_;
    }

    function execute() external {
        uint256 input = counter;
        uint256 result = target.receiveCount(input);
        require(result == input + input, "wrong remote result");
        results[input] = result;
        counter = input + 1;
    }
}

abstract contract CorrelatedCounterMultiTxActions {
    function _callData(uint256 input) internal pure returns (bytes memory) {
        return abi.encodeCall(CorrelatedCounter.receiveCount, (input));
    }

    function _callHash(address target, address caller, uint256 input) internal pure returns (bytes32) {
        return crossChainCallHash(false, caller, MAINNET_ROLLUP_ID, target, L2_ROLLUP_ID, 0, _callData(input));
    }

    function _returnData(uint256 input) internal pure returns (bytes memory) {
        return abi.encode(input + input);
    }

    function _rootAfter(uint256 count) internal pure returns (bytes32) {
        if (count == 0) return keccak256("l2-initial-state");
        return keccak256(abi.encode("l2-correlated-counter-multi-tx", count));
    }

    function _l1Entries(address target, address caller) internal pure returns (ExecutionEntry[] memory entries) {
        entries = new ExecutionEntry[](NUM_TXS);
        for (uint256 i; i < NUM_TXS; ++i) {
            RollupUpdate[] memory updates = new RollupUpdate[](1);
            updates[0] = RollupUpdate({
                rollupId: L2_ROLLUP_ID, currentRoot: _rootAfter(i), newRoot: _rootAfter(i + 1), etherDelta: 0
            });
            bytes32 key = _callHash(target, caller, i);
            entries[i] = ExecutionEntry({
                rollupUpdates: updates,
                proxyEntryHash: key,
                destinationRollupId: L2_ROLLUP_ID,
                l2ToL1Calls: noCalls(),
                expectedL1ToL2Calls: noNestedActions(),
                rollingHash: RollingHashBuilder.entryBegin(updates, key),
                success: true,
                returnData: _returnData(i)
            });
        }
    }

    function _l2Entry(address target, address caller, uint256 input) internal pure returns (L2ExecutionEntry memory) {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: caller,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: target,
            value: 0,
            data: _callData(input)
        });
        bytes32 key = _callHash(target, caller, input);
        bytes32 rollingHash = RollingHashBuilder.entryBeginL2(key);
        rollingHash = RollingHashBuilder.appendCallBegin(rollingHash, key);
        rollingHash = RollingHashBuilder.appendCallEnd(rollingHash, true, _returnData(input));
        return L2ExecutionEntry({
            proxyEntryHash: key,
            incomingCalls: calls,
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: rollingHash,
            success: true,
            returnData: _returnData(input)
        });
    }

    function _checkCaller(address callerAddress, uint256 count) internal view {
        CorrelatedCounterCaller caller = CorrelatedCounterCaller(callerAddress);
        require(caller.counter() == count, "wrong L1 count");
        for (uint256 i; i < count; ++i) {
            require(caller.results(i) == i + i, "wrong saved L1 result");
        }
    }

    function _checkTarget(address targetAddress, uint256 count) internal view {
        CorrelatedCounter target = CorrelatedCounter(targetAddress);
        require(target.counter() == count, "wrong L2 count");
        for (uint256 i; i < count; ++i) {
            require(target.inputs(i) == i, "wrong saved L2 input");
            require(target.results(i) == i + i, "wrong saved L2 result");
        }
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        CorrelatedCounter target = new CorrelatedCounter();
        vm.stopBroadcast();
        output("COUNTER_L2", address(target));
    }
}

contract Deploy is Script {
    function run() external {
        IEEZ manager = IEEZ(vm.envAddress("ROLLUPS"));
        vm.startBroadcast();
        address proxy = getOrCreateProxy(manager, vm.envAddress("COUNTER_L2"), L2_ROLLUP_ID);
        CorrelatedCounterCaller caller = new CorrelatedCounterCaller(CorrelatedCounter(proxy));
        vm.stopBroadcast();
        output("COUNTER_PROXY", proxy);
        output("CALLER_L1", address(caller));
    }
}

contract ExecuteL2 is Script, CorrelatedCounterMultiTxActions {
    function run() external {
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        address target = vm.envAddress("COUNTER_L2");
        address caller = vm.envAddress("CALLER_L1");
        for (uint256 i; i < NUM_TXS; ++i) {
            L2ExecutionEntry[] memory table = new L2ExecutionEntry[](1);
            table[0] = _l2Entry(target, caller, i);
            vm.broadcast();
            manager.executeIncomingCrossChainCall(table, noL2StaticEntries());
            _checkTarget(target, i + 1);
            require(manager.entryIndex() == 1, "delivery not consumed");
        }
        console.log("done: L2 counter=3; results=0,2,4");
    }
}

contract Execute is Script, CorrelatedCounterMultiTxActions {
    function run() external {
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        address caller = vm.envAddress("CALLER_L1");
        ExecutionEntry[] memory entries = _l1Entries(vm.envAddress("COUNTER_L2"), caller);
        vm.broadcast();
        manager.postAndVerifyBatch(
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), L2_ROLLUP_ID, entries, noStaticEntries())
        );
        for (uint256 i; i < NUM_TXS; ++i) {
            vm.broadcast();
            CorrelatedCounterCaller(caller).execute();
            _checkCaller(caller, i + 1);
            require(manager.entryQueueIndex(L2_ROLLUP_ID) == i + 1, "wrong L1 consumption count");
            (, bytes32 root,) = manager.rollups(L2_ROLLUP_ID);
            require(root == _rootAfter(i + 1), "wrong L1 root");
        }
        console.log("done: L1 counter=3; results=0,2,4");
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("CALLER_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(CorrelatedCounterCaller.execute, ())));
        console.log("NUM_TXS=%s", NUM_TXS);
    }
}

contract VerifyNetwork is Script, CorrelatedCounterMultiTxActions {
    function run() external view {
        _checkCaller(vm.envAddress("CALLER_L1"), NUM_TXS);
        console.log("VERIFY_PASS L1 count=3; all saved results match");
    }
}

contract VerifyNetworkL2 is Script, CorrelatedCounterMultiTxActions {
    function run() external view {
        _checkTarget(vm.envAddress("COUNTER_L2"), NUM_TXS);
        console.log("VERIFY_PASS L2 count=3; all saved inputs and results match");
    }
}

contract ComputeExpected is ComputeExpectedBase, CorrelatedCounterMultiTxActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("COUNTER_L2")) return "CorrelatedCounter";
        if (a == vm.envAddress("CALLER_L1")) return "CorrelatedCounterCaller";
        return _shortAddr(a);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == CorrelatedCounter.receiveCount.selector) return "receiveCount";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        address target = vm.envAddress("COUNTER_L2");
        address caller = vm.envAddress("CALLER_L1");
        ExecutionEntry[] memory l1 = _l1Entries(target, caller);
        L2ExecutionEntry[] memory l2 = new L2ExecutionEntry[](NUM_TXS);
        HashStep[][] memory steps = new HashStep[][](NUM_TXS);
        string memory l1Hashes;
        string memory l2Hashes;
        for (uint256 i; i < NUM_TXS; ++i) {
            l2[i] = _l2Entry(target, caller, i);
            steps[i] = new HashStep[](0); // L1 entries contain only the entry-begin seed.
            l1Hashes = string.concat(l1Hashes, i == 0 ? "" : ",", vm.toString(_entryHash(l1[i])));
            l2Hashes = string.concat(l2Hashes, i == 0 ? "" : ",", vm.toString(_entryHash(l2[i])));
        }
        console.log("EXPECTED_L1_HASHES=[%s]", l1Hashes);
        console.log("EXPECTED_L2_HASHES=[%s]", l2Hashes);
        _printL1CallHashes(l1);
        _printL2CallHashes(l2);
        _printL1Steps(l1, steps);
        _printL1Table(l1);
        _printL2Table(l2);
        for (uint256 i; i < NUM_TXS; ++i) {
            _logEntry(i, l1[i]);
            _logL2Entry(i, l2[i]);
        }
    }
}
