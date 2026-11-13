// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../../src/L2/EEZL2.sol";
import {
    IEEZ,
    RollupUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry
} from "../../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2Entry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../../src/interfaces/IEEZL2.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    e2eRollupId,
    output,
    getOrCreateProxy,
    crossChainCallHash,
    crossChainCallHashL2Out,
    expectedL1toL2Hash,
    noStaticEntries,
    noL2StaticEntries,
    immediateSingleRollupBatch,
    RollingHashBuilder,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// NestedCallbackValueL2: one L2 user transaction, all calls return successfully.
// Flow: user@L2 --0 wei--> hop0@L1 --10 wei--> hop1@L2
// Each hop returns the sum of its own value and every deeper value.
// Actors are funded at deployment with exactly their outgoing value; final balance = incoming value.
// L1 view: one zero-hash immediate L2Tx entry; deeper crossings stay in frame-owned calls.
// L2 view: one source consumption, callbacks in that entry; no separate delivery.
// L1 etherDelta = 10; L1 pays nothing out, so no prior escrow is needed.
// Network runs require system funding; local mocks do not prove live settlement.

contract ValueHop {
    address public immutable next;
    uint256 public immutable incomingValue;
    uint256 public immutable outgoingValue;
    uint256 public immutable expectedInnerResult;
    uint256 public calls;
    uint256 public received;
    uint256 public result;

    constructor(address next_, uint256 incoming_, uint256 outgoing_, uint256 inner_) payable {
        require(msg.value == outgoing_, "setup funding");
        next = next_;
        incomingValue = incoming_;
        outgoingValue = outgoing_;
        expectedInnerResult = inner_;
    }

    function forward() external payable returns (uint256) {
        require(msg.value == incomingValue, "wrong incoming value");
        calls++;
        received += msg.value;
        uint256 inner;
        if (next != address(0)) {
            (bool ok, bytes memory data) = next.call{value: outgoingValue}(abi.encodeCall(ValueHop.forward, ()));
            require(ok, "nested call failed");
            require(keccak256(data) == keccak256(abi.encode(expectedInnerResult)), "wrong inner return bytes");
            inner = abi.decode(data, (uint256));
        }
        result = msg.value + inner;
        return result;
    }
}

abstract contract ValueActions is Script {
    function _hop(uint256 i) internal view returns (address) {
        return vm.envAddress(string.concat("HOP_", vm.toString(i)));
    }

    function _data() internal pure returns (bytes memory) {
        return abi.encodeCall(ValueHop.forward, ());
    }

    function _hash(uint256 i, address alice) internal view returns (bytes32) {
        if (i == 0) return crossChainCallHashL2Out(alice, e2eRollupId(), _hop(0), 0, 0, _data());
        if (i == 1) return crossChainCallHash(false, _hop(0), 0, _hop(1), e2eRollupId(), 10, _data());
        revert("invalid hop");
    }

    function _calls1(uint256 i, address alice) internal view returns (L2ToL1Call[] memory calls) {
        if (i >= 2) return new L2ToL1Call[](0);
        calls = new L2ToL1Call[](1);
        if (i == 0) {
            calls[0] = L2ToL1Call({
                revertNextNCalls: 0,
                isStatic: false,
                gas: 0,
                sourceAddress: alice,
                sourceRollupId: e2eRollupId(),
                targetAddress: _hop(0),
                value: 0,
                data: _data()
            });
        }
    }

    function _calls2(uint256 i, address) internal view returns (CrossChainCall[] memory calls) {
        if (i >= 2) return new CrossChainCall[](0);
        calls = new CrossChainCall[](1);
        if (i == 1) {
            calls[0] = CrossChainCall({
                revertNextNCalls: 0,
                isStatic: false,
                gas: 0,
                sourceAddress: _hop(0),
                sourceRollupId: 0,
                targetAddress: _hop(1),
                value: 10,
                data: _data()
            });
        }
    }

    function _entries1(address alice) internal view returns (ExecutionEntry[] memory entries) {
        RollupUpdate[] memory updates = new RollupUpdate[](1);
        updates[0] = RollupUpdate({
            rollupId: e2eRollupId(),
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("nestedCallbackValueL2"),
            etherDelta: 10
        });
        bytes32 key = bytes32(0);
        bytes32 rh = RollingHashBuilder.entryBegin(updates, key);
        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](1);
        rh = RollingHashBuilder.appendCallBegin(rh, _hash(0, alice));
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(_hash(1, alice), rh),
            l2ToL1Calls: _calls1(2, alice),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(10))
        });
        rh = RollingHashBuilder.appendNestedBegin(rh, _hash(1, alice));
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(10)));
        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: updates,
            destinationRollupId: e2eRollupId(),
            l2ToL1Calls: _calls1(0, alice),
            expectedL1ToL2Calls: nested,
            proxyEntryHash: key,
            rollingHash: rh,
            success: true,
            returnData: ""
        });
    }

    function _entries2(address alice) internal view returns (L2Entry[] memory entries) {
        bytes32 key = _hash(0, alice);
        bytes32 rh = RollingHashBuilder.entryBeginL2(key);
        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](0);
        rh = RollingHashBuilder.appendCallBegin(rh, _hash(1, alice));
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(10)));
        entries = new L2Entry[](1);
        entries[0] = L2Entry({
            incomingCalls: _calls2(1, alice),
            expectedOutgoingCalls: nested,
            proxyEntryHash: key,
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(10))
        });
    }

    function _steps(address alice) internal view returns (HashStep[][] memory steps) {
        steps = new HashStep[][](1);
        steps[0] = new HashStep[](4);
        steps[0][0] = RollingHashBuilder.stepCallBegin(_hash(0, alice));
        steps[0][1] = RollingHashBuilder.stepNestedBegin(_hash(1, alice));
        steps[0][2] = RollingHashBuilder.stepNestedEnd();
        steps[0][3] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(10)));
    }

    function _verify1() internal view {
        require(ValueHop(_hop(0)).calls() == 1, "hop 0: call count");
        require(ValueHop(_hop(0)).received() == 0, "hop 0: received value");
        require(ValueHop(_hop(0)).result() == 10, "hop 0: return result");
        require(_hop(0).balance == 0, "hop 0: balance");
    }

    function _verify2() internal view {
        require(ValueHop(_hop(1)).calls() == 1, "hop 1: call count");
        require(ValueHop(_hop(1)).received() == 10, "hop 1: received value");
        require(ValueHop(_hop(1)).result() == 10, "hop 1: return result");
        require(_hop(1).balance == 10, "hop 1: balance");
    }
}

contract DeployHop1L2 is ValueActions {
    function run() external {
        vm.startBroadcast();
        require(!EEZL2(vm.envAddress("MANAGER_L2")).USE_GAS_LEFT(), "requires gas-independent hashes");
        ValueHop hop = new ValueHop{value: 0}(address(0), 10, 0, 0);
        output("HOP_1", address(hop));
        vm.stopBroadcast();
    }
}

contract DeployHop0 is ValueActions {
    function run() external {
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), _hop(1), e2eRollupId());
        ValueHop hop = new ValueHop{value: 10}(proxy, 0, 10, 10);
        output("HOP_0", address(hop));
        vm.stopBroadcast();
    }
}

contract DeployTriggerL2 is ValueActions {
    function run() external {
        vm.startBroadcast();
        output("TRIGGER_PROXY", getOrCreateProxy(IEEZ(vm.envAddress("MANAGER_L2")), _hop(0), 0));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is ValueActions {
    function run() external {
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        vm.startBroadcast();
        manager.loadExecutionTable{value: 10}(_entries2(msg.sender), noL2StaticEntries());
        (bool ok, bytes memory ret) = vm.envAddress("TRIGGER_PROXY").call{value: 0}(_data());
        require(ok, "trigger failed");
        require(keccak256(ret) == keccak256(abi.encode(uint256(10))), "wrong outer return bytes");
        _verify2();
        vm.stopBroadcast();
        console.log("done");
    }
}

contract Execute is ValueActions {
    function run() external {
        EEZ registry = EEZ(vm.envAddress("ROLLUPS"));
        vm.startBroadcast();
        registry.postAndVerifyBatch(
            immediateSingleRollupBatch(
                vm.envAddress("PROOF_SYSTEM"), e2eRollupId(), _entries1(msg.sender), noStaticEntries()
            )
        );
        _verify1();
        (,, uint256 escrow) = registry.rollups(e2eRollupId());
        require(escrow == 10 && address(registry).balance == 10, "net escrow mismatch");
        vm.stopBroadcast();
        console.log("done");
    }
}

contract ExecuteNetworkL2 is ValueActions {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("TRIGGER_PROXY"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(_data()));
    }
}

contract VerifyNetwork is ValueActions {
    function run() external view {
        _verify1();
    }
}

contract VerifyNetworkL2 is ValueActions {
    function run() external view {
        _verify2();
    }
}

contract ComputeExpected is ComputeExpectedBase, ValueActions {
    function run() external view {
        ExecutionEntry[] memory l1 = _entries1(msg.sender);
        L2Entry[] memory l2 = _entries2(msg.sender);
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        _printL1CallHashes(l1);
        console.log("EXPECTED_L2_CALL_HASHES=[%s]", vm.toString(l2[0].proxyEntryHash));
        _printL1Steps(l1, _steps(msg.sender));
        _printL1Table(l1);
        _printL2Table(l2);
    }
}
