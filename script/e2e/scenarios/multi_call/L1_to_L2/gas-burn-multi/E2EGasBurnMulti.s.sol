// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {e2eRollupId} from "../../../shared/E2EHelpers.sol";

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {IEEZ, ExecutionEntry, RollupUpdate} from "../../../../../../src/interfaces/IEEZ.sol";
import {EEZL2} from "../../../../../../src/L2/EEZL2.sol";
import {
    ExecutionEntry as L2Entry,
    StaticExecutionEntryL2,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../../src/interfaces/IEEZL2.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    getOrCreateProxy,
    crossChainCallHash,
    noCalls,
    noNestedActions,
    noStaticEntries,
    RollingHashBuilder,
    HashStep,
    immediateSingleRollupBatch
} from "../../../shared/E2EHelpers.sol";

// E2E_EXCLUDE_FROM_ALL: deliberate block-capacity experiment; run explicitly.
// E2E_LOCAL_L2_BLOCK_GAS_LIMIT: 60000000
// Local replay reserves room for Forge's padded transaction gas limits.
// This fixture does not establish packing into a live network's block limit.
// L1: GasBurnTrigger.run() -> burn(14M) returns 1 -> burn(14M) returns 2.
// L2: two system deliveries -> GasBurner.burn(14M), one per completed frame.
// Final state: trigger.completed == burner.completed == 2; each burn records 14M gas.

library GasBurnPlan {
    uint256 internal constant COUNT = 2;
    uint256 internal constant BUDGET = 14_000_000;
}

/// @notice Burns the requested gas, then persists evidence. Delivery overhead is additional.
contract GasBurner {
    uint256 public completed;
    mapping(uint256 => uint256) public burnedGas;
    event Burned(uint256 indexed ordinal, uint256 requested, uint256 measured);

    function burn(uint256 requested) external returns (uint256 ordinal) {
        require(requested == GasBurnPlan.BUDGET, "unsupported budget");
        require(gasleft() > requested + 100_000, "insufficient burn gas");
        uint256 start = gasleft();
        assembly ("memory-safe") {
            for {} lt(sub(start, gas()), requested) {} {}
        }
        uint256 measured = start - gasleft();
        ordinal = ++completed;
        burnedGas[ordinal] = measured;
        emit Burned(ordinal, requested, measured);
    }
}

contract GasBurnTrigger {
    address public immutable remote;
    uint256 public completed;

    constructor(address remote_) {
        remote = remote_;
    }

    function run() external {
        require(completed == 0, "already run");
        uint256 n = GasBurnPlan.COUNT;
        for (uint256 i; i < n; ++i) {
            require(GasBurner(remote).burn(GasBurnPlan.BUDGET) == i + 1, "wrong remote result");
        }
        completed = n;
    }
}

abstract contract GasBurnActions {
    function _burnData() internal pure returns (bytes memory) {
        return abi.encodeCall(GasBurner.burn, (GasBurnPlan.BUDGET));
    }

    function _burnHash(address target, address caller) internal view returns (bytes32) {
        return crossChainCallHash(false, caller, 0, target, e2eRollupId(), 0, _burnData());
    }

    function _burnL1Entries(address target, address caller) internal view returns (ExecutionEntry[] memory entries) {
        entries = new ExecutionEntry[](GasBurnPlan.COUNT);
        bytes32 root = keccak256("l2-initial-state");
        for (uint256 i; i < entries.length; ++i) {
            bytes32 nextRoot = keccak256(abi.encode("gas-burn-state", i + 1));
            RollupUpdate[] memory updates = new RollupUpdate[](1);
            updates[0] = RollupUpdate({rollupId: e2eRollupId(), currentRoot: root, newRoot: nextRoot, etherDelta: 0});
            bytes32 h = _burnHash(target, caller);
            entries[i] = ExecutionEntry({
                rollupUpdates: updates,
                proxyEntryHash: h,
                l2ToL1Calls: noCalls(),
                expectedL1ToL2Calls: noNestedActions(),
                rollingHash: RollingHashBuilder.entryBegin(updates, h),
                destinationRollupId: e2eRollupId(),
                success: true,
                returnData: abi.encode(i + 1)
            });
            root = nextRoot;
        }
    }

    function _burnL2Entry(address target, address caller, uint256 index) internal view returns (L2Entry memory entry) {
        bytes32 h = _burnHash(target, caller);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            gas: 0,
            sourceAddress: caller,
            sourceRollupId: 0,
            targetAddress: target,
            value: 0,
            data: _burnData()
        });
        bytes memory result = abi.encode(index + 1);
        bytes32 rh = RollingHashBuilder.entryBeginL2(h);
        rh = RollingHashBuilder.appendCallBegin(rh, h);
        rh = RollingHashBuilder.appendCallEnd(rh, true, result);
        entry = L2Entry({
            proxyEntryHash: h,
            incomingCalls: calls,
            expectedOutgoingCalls: new ExpectedOutgoingCrossChainCall[](0),
            rollingHash: rh,
            success: true,
            returnData: result
        });
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        output("BURNER_L2", address(new GasBurner()));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), vm.envAddress("BURNER_L2"), e2eRollupId());
        output("BURN_PROXY", proxy);
        output("BURN_TRIGGER", address(new GasBurnTrigger(proxy)));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is Script, GasBurnActions {
    function run() external {
        vm.startBroadcast();
        for (uint256 i; i < GasBurnPlan.COUNT; ++i) {
            L2Entry[] memory table = new L2Entry[](1);
            table[0] = _burnL2Entry(vm.envAddress("BURNER_L2"), vm.envAddress("BURN_TRIGGER"), i);
            EEZL2(vm.envAddress("MANAGER_L2")).executeIncomingCrossChainCall(table, new StaticExecutionEntryL2[](0));
        }
        vm.stopBroadcast();
        require(GasBurner(vm.envAddress("BURNER_L2")).completed() == GasBurnPlan.COUNT, "missing burn");
    }
}

contract Execute is Script, GasBurnActions {
    function run() external {
        vm.startBroadcast();
        EEZ(vm.envAddress("ROLLUPS"))
            .postAndVerifyBatch(
                immediateSingleRollupBatch(
                    vm.envAddress("PROOF_SYSTEM"),
                    e2eRollupId(),
                    _burnL1Entries(vm.envAddress("BURNER_L2"), vm.envAddress("BURN_TRIGGER")),
                    noStaticEntries()
                )
            );
        GasBurnTrigger(vm.envAddress("BURN_TRIGGER")).run();
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("BURN_TRIGGER"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(GasBurnTrigger.run, ())));
    }
}

contract ComputeExpected is ComputeExpectedBase, GasBurnActions {
    function run() external view {
        address target = vm.envAddress("BURNER_L2");
        address caller = vm.envAddress("BURN_TRIGGER");
        ExecutionEntry[] memory l1 = _burnL1Entries(target, caller);
        L2Entry[] memory l2 = new L2Entry[](l1.length);
        HashStep[][] memory steps = new HashStep[][](l1.length);
        string memory h1;
        string memory h2;
        for (uint256 i; i < l1.length; ++i) {
            l2[i] = _burnL2Entry(target, caller, i);
            steps[i] = new HashStep[](0);
            h1 = string.concat(h1, i == 0 ? "" : ",", vm.toString(_entryHash(l1[i])));
            h2 = string.concat(h2, i == 0 ? "" : ",", vm.toString(_entryHash(l2[i])));
        }
        console.log("EXPECTED_L1_HASHES=[%s]", h1);
        console.log("EXPECTED_L2_HASHES=[%s]", h2);
        _printL1CallHashes(l1);
        _printL2CallHashes(l2);
        _printL1Steps(l1, steps);
        _printL1Table(l1);
        _printL2Table(l2);
        _printL1StaticTable(noStaticEntries());
        _printL2StaticTable(new StaticExecutionEntryL2[](0));
    }
}

contract VerifyNetwork is Script {
    function run() external view {
        GasBurnTrigger trigger = GasBurnTrigger(vm.envAddress("BURN_TRIGGER"));
        require(trigger.completed() == GasBurnPlan.COUNT, "source incomplete");
    }
}

contract VerifyNetworkL2 is Script {
    function run() external view {
        GasBurner burner = GasBurner(vm.envAddress("BURNER_L2"));
        require(burner.completed() == GasBurnPlan.COUNT, "delivery count mismatch");
        for (uint256 i; i < GasBurnPlan.COUNT; ++i) {
            uint256 measured = burner.burnedGas(i + 1);
            uint256 requested = GasBurnPlan.BUDGET;
            require(measured >= requested && measured < requested + 1_000, "burn outside tolerance");
            console.log("burn %s used %s gas inside loop", i + 1, measured);
        }
    }
}
