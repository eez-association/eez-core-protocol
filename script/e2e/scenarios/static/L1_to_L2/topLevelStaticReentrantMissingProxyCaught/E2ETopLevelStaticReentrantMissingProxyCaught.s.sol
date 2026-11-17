// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {IEEZ, ExecutionEntry, StaticExecutionEntry} from "../../../../../../src/interfaces/IEEZ.sol";
import {EEZBase} from "../../../../../../src/base/EEZBase.sol";
import {Counter} from "../../../../../../test/mocks/CounterContracts.sol";
import {StaticRoundTripFailureReader} from "../../../../../../test/mocks/StaticRoundTripContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {e2eRollupId, output, getOrCreateProxy, immediateSingleRollupBatch} from "../../../shared/E2EHelpers.sol";
import {
    Deploy as DeployProducer,
    DeployL2 as DeployRemote,
    DeployPredictionL2 as PredictRemote,
    TopLevelStaticReentrantCounterActions
} from "../topLevelStaticReentrantMissingProxy/E2ETopLevelStaticReentrantMissingProxy.s.sol";

// One L1 user transaction: reader -> STATIC L2 forwarder -> STATIC L1 producer.
// Callback dispatch fails before the producer runs because its source proxy is absent.
// The reader records the exact error and stops: no proxy creation, retry, or L2 delivery.
// Reuse the recovery scenario's real producer, forwarder, prediction and static row.
abstract contract TopLevelStaticReentrantMissingProxyCaughtActions is Script, TopLevelStaticReentrantCounterActions {
    function _rows() internal view returns (StaticExecutionEntry[] memory) {
        return _staticEntries(
            vm.envAddress("COUNTER_L1"),
            vm.envAddress("CALLBACK_L2"),
            vm.envAddress("COUNTER_L2"),
            vm.envAddress("READER_L1"),
            vm.envBytes("PREDICTED_STATIC_RESULT")
        );
    }

    function _verifyFailure() internal view {
        StaticRoundTripFailureReader reader = StaticRoundTripFailureReader(vm.envAddress("READER_L1"));
        address proxy =
            IEEZ(vm.envAddress("ROLLUPS")).computeCrossChainProxyAddress(vm.envAddress("CALLBACK_L2"), e2eRollupId());
        require(reader.failedReads() == 1, "expected exactly one failed read");
        require(proxy.code.length == 0, "callback proxy must remain undeployed");
        require(
            keccak256(reader.missingProxyError())
                == keccak256(abi.encodeWithSelector(EEZBase.StaticCallProxyNotDeployed.selector, proxy)),
            "missing-proxy evidence mismatch"
        );
        require(Counter(vm.envAddress("COUNTER_L1")).counter() == 1, "producer changed");
    }
}

contract Deploy is DeployProducer {}

contract DeployL2 is DeployRemote {}

contract Deploy2 is Script {
    function run() external {
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), vm.envAddress("COUNTER_L2"), e2eRollupId());
        address callbackProxy =
            IEEZ(vm.envAddress("ROLLUPS")).computeCrossChainProxyAddress(vm.envAddress("CALLBACK_L2"), e2eRollupId());
        require(callbackProxy.code.length == 0, "callback source proxy must start undeployed");
        output("CALLBACK_PROXY", callbackProxy);
        output("COUNTER_PROXY", proxy);
        output(
            "READER_L1",
            address(
                new StaticRoundTripFailureReader(
                    proxy, vm.envAddress("ROLLUPS"), vm.envAddress("CALLBACK_L2"), e2eRollupId()
                )
            )
        );
        vm.stopBroadcast();
    }
}

contract DeployPredictionL2 is PredictRemote {}

contract Execute is TopLevelStaticReentrantMissingProxyCaughtActions {
    function run() external {
        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"), e2eRollupId(), new ExecutionEntry[](0), _rows()
                )
            );
        StaticRoundTripFailureReader(vm.envAddress("READER_L1")).recordFailure();
        _verifyFailure();
        (, bytes32 root,) = EEZ(vm.envAddress("ROLLUPS")).rollups(e2eRollupId());
        require(root == keccak256("l2-initial-state"), "failed lookup moved L2 root");
        vm.stopBroadcast();
        console.log("done: exact missing-proxy failure recorded; no recovery");
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("READER_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(StaticRoundTripFailureReader.recordFailure, ())));
    }
}

contract VerifyNetwork is TopLevelStaticReentrantMissingProxyCaughtActions {
    function run() external view {
        _verifyFailure();
        console.log("VERIFY_PASS one failed read; callback proxy still absent");
    }
}

contract ComputeExpected is ComputeExpectedBase, TopLevelStaticReentrantMissingProxyCaughtActions {
    function run() external view {
        StaticExecutionEntry[] memory rows = _rows();
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        console.log("EXPECTED_L1_HASHES=[]");
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("EXPECTED_L2_CALL_HASHES=[]");
        console.log("ABSENT_L2_HASHES=[%s]", vm.toString(rows[0].proxyEntryHash));
        _printL1StaticTable(rows);
    }
}
