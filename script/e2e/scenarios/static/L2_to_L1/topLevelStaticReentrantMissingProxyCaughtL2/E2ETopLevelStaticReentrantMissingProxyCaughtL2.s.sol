// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../../src/L2/EEZL2.sol";
import {IEEZ, RollupUpdate, ExecutionEntry, ExpectedL1ToL2Call} from "../../../../../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2ExecutionEntry, StaticExecutionEntryL2} from "../../../../../../src/interfaces/IEEZL2.sol";
import {EEZBase} from "../../../../../../src/base/EEZBase.sol";
import {Counter} from "../../../../../../test/mocks/CounterContracts.sol";
import {StaticRoundTripFailureReader} from "../../../../../../test/mocks/StaticRoundTripContracts.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    e2eRollupId,
    output,
    getOrCreateProxy,
    immediateSingleRollupBatch,
    noCalls,
    noStaticEntries,
    RollingHashBuilder,
    HashStep
} from "../../../shared/E2EHelpers.sol";
import {
    DeployProducerL2 as DeployProducer,
    Deploy as DeployRemote,
    TopLevelStaticReentrantCounterL2Actions
} from "../topLevelStaticReentrantMissingProxyL2/E2ETopLevelStaticReentrantMissingProxyL2.s.sol";

// One L2 user transaction: reader -> STATIC L1 forwarder -> STATIC L2 producer.
// Callback dispatch fails at the missing source proxy; the reader records the exact
// error without recovery. No remote read completes, so its single L1 L2Tx entry
// has no calls or nested rows. The L2 static row remains visible for content checks;
// it is not a mutable consumption or an incoming delivery.
abstract contract TopLevelStaticReentrantMissingProxyCaughtL2Actions is
    Script,
    TopLevelStaticReentrantCounterL2Actions
{
    function _rows() internal view returns (StaticExecutionEntryL2[] memory) {
        return _staticEntries(
            vm.envAddress("PRODUCER_L2"),
            vm.envAddress("CALLBACK_L1"),
            vm.envAddress("COUNTER_L1"),
            vm.envAddress("READER_L2")
        );
    }

    function _failedL1Entries() internal view returns (ExecutionEntry[] memory entries) {
        RollupUpdate[] memory updates = new RollupUpdate[](1);
        updates[0] = RollupUpdate({
            rollupId: e2eRollupId(),
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("l2-state-after-caught-static-failure"),
            etherDelta: 0
        });
        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: updates,
            proxyEntryHash: bytes32(0),
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: new ExpectedL1ToL2Call[](0),
            rollingHash: RollingHashBuilder.entryBegin(updates, bytes32(0)),
            destinationRollupId: e2eRollupId(),
            success: true,
            returnData: ""
        });
    }

    function _verifyFailure() internal view {
        StaticRoundTripFailureReader reader = StaticRoundTripFailureReader(vm.envAddress("READER_L2"));
        address proxy = IEEZ(vm.envAddress("MANAGER_L2")).computeCrossChainProxyAddress(vm.envAddress("CALLBACK_L1"), 0);
        require(reader.failedReads() == 1, "expected exactly one failed read");
        require(proxy.code.length == 0, "callback proxy must remain undeployed");
        require(
            keccak256(reader.missingProxyError())
                == keccak256(abi.encodeWithSelector(EEZBase.StaticCallProxyNotDeployed.selector, proxy)),
            "missing-proxy evidence mismatch"
        );
        require(Counter(vm.envAddress("PRODUCER_L2")).counter() == 1, "producer changed");
    }
}

contract DeployProducerL2 is DeployProducer {}

contract Deploy is DeployRemote {}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("MANAGER_L2")), vm.envAddress("COUNTER_L1"), 0);
        address callbackProxy =
            IEEZ(vm.envAddress("MANAGER_L2")).computeCrossChainProxyAddress(vm.envAddress("CALLBACK_L1"), 0);
        require(callbackProxy.code.length == 0, "callback source proxy must start undeployed");
        output("CALLBACK_PROXY", callbackProxy);
        output("COUNTER_PROXY_L2", proxy);
        output(
            "READER_L2",
            address(
                new StaticRoundTripFailureReader(proxy, vm.envAddress("MANAGER_L2"), vm.envAddress("CALLBACK_L1"), 0)
            )
        );
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is TopLevelStaticReentrantMissingProxyCaughtL2Actions {
    function run() external {
        vm.startBroadcast();
        EEZL2(vm.envAddress("MANAGER_L2")).loadExecutionTable(new L2ExecutionEntry[](0), _rows());
        StaticRoundTripFailureReader(vm.envAddress("READER_L2")).recordFailure();
        _verifyFailure();
        require(EEZL2(vm.envAddress("MANAGER_L2")).entryIndex() == 0, "failed read consumed mutable entry");
        vm.stopBroadcast();
        console.log("done: exact missing-proxy failure recorded; no recovery");
    }
}

contract Execute is TopLevelStaticReentrantMissingProxyCaughtL2Actions {
    function run() external {
        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"), e2eRollupId(), _failedL1Entries(), noStaticEntries()
                )
            );
        vm.stopBroadcast();
        console.log("done: L2Tx entry contains no completed remote calls");
    }
}

contract ExecuteNetworkL2 is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("READER_L2"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(StaticRoundTripFailureReader.recordFailure, ())));
    }
}

contract VerifyNetworkL2 is TopLevelStaticReentrantMissingProxyCaughtL2Actions {
    function run() external view {
        _verifyFailure();
        console.log("VERIFY_PASS one failed read; callback proxy still absent");
    }
}

contract ComputeExpected is ComputeExpectedBase, TopLevelStaticReentrantMissingProxyCaughtL2Actions {
    function run() external view {
        ExecutionEntry[] memory entries = _failedL1Entries();
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(entries[0])));
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("EXPECTED_L2_CALL_HASHES=[]");
        HashStep[][] memory steps = new HashStep[][](1);
        steps[0] = new HashStep[](0);
        _printL1Steps(entries, steps);
        _printL1Table(entries);
        _printL2StaticTable(_rows());
    }
}
