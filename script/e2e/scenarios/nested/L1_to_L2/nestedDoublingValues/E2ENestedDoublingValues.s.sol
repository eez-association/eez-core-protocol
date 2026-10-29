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

// NestedDoublingValues: one L1 user transaction, all calls return successfully.
// Flow: user@L1 --1 wei--> hop0@L2 --2 wei--> hop1@L1 --4 wei--> hop2@L2 --8 wei--> hop3@L1 --16 wei--> hop4@L2 --32 wei--> hop5@L1
// Each hop returns the sum of its own value and every deeper value.
// Actors are funded at deployment with exactly their outgoing value; final balance = incoming value.
// L1 view: one proxy entry; deeper crossings stay in frame-owned calls.
// L2 view: one system delivery, nested outgoing rows contain the callbacks.
// L1 etherDelta = -21; local execution supplies 100 wei prior escrow.
// Network runs require existing registry liquidity/escrow and system funding; local mocks do not prove live settlement.

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
        if (i == 0) return crossChainCallHash(false, alice, 0, _hop(0), e2eRollupId(), 1, _data());
        if (i == 1) return crossChainCallHashL2Out(_hop(0), e2eRollupId(), _hop(1), 0, 2, _data());
        if (i == 2) return crossChainCallHash(false, _hop(1), 0, _hop(2), e2eRollupId(), 4, _data());
        if (i == 3) return crossChainCallHashL2Out(_hop(2), e2eRollupId(), _hop(3), 0, 8, _data());
        if (i == 4) return crossChainCallHash(false, _hop(3), 0, _hop(4), e2eRollupId(), 16, _data());
        if (i == 5) return crossChainCallHashL2Out(_hop(4), e2eRollupId(), _hop(5), 0, 32, _data());
        revert("invalid hop");
    }

    function _calls1(uint256 i, address) internal view returns (L2ToL1Call[] memory calls) {
        if (i >= 6) return new L2ToL1Call[](0);
        calls = new L2ToL1Call[](1);
        if (i == 1) {
            calls[0] = L2ToL1Call({
                revertNextNCalls: 0,
                isStatic: false,
                gas: 0,
                sourceAddress: _hop(0),
                sourceRollupId: e2eRollupId(),
                targetAddress: _hop(1),
                value: 2,
                data: _data()
            });
        }
        if (i == 3) {
            calls[0] = L2ToL1Call({
                revertNextNCalls: 0,
                isStatic: false,
                gas: 0,
                sourceAddress: _hop(2),
                sourceRollupId: e2eRollupId(),
                targetAddress: _hop(3),
                value: 8,
                data: _data()
            });
        }
        if (i == 5) {
            calls[0] = L2ToL1Call({
                revertNextNCalls: 0,
                isStatic: false,
                gas: 0,
                sourceAddress: _hop(4),
                sourceRollupId: e2eRollupId(),
                targetAddress: _hop(5),
                value: 32,
                data: _data()
            });
        }
    }

    function _calls2(uint256 i, address alice) internal view returns (CrossChainCall[] memory calls) {
        if (i >= 6) return new CrossChainCall[](0);
        calls = new CrossChainCall[](1);
        if (i == 0) {
            calls[0] = CrossChainCall({
                revertNextNCalls: 0,
                isStatic: false,
                gas: 0,
                sourceAddress: alice,
                sourceRollupId: 0,
                targetAddress: _hop(0),
                value: 1,
                data: _data()
            });
        }
        if (i == 2) {
            calls[0] = CrossChainCall({
                revertNextNCalls: 0,
                isStatic: false,
                gas: 0,
                sourceAddress: _hop(1),
                sourceRollupId: 0,
                targetAddress: _hop(2),
                value: 4,
                data: _data()
            });
        }
        if (i == 4) {
            calls[0] = CrossChainCall({
                revertNextNCalls: 0,
                isStatic: false,
                gas: 0,
                sourceAddress: _hop(3),
                sourceRollupId: 0,
                targetAddress: _hop(4),
                value: 16,
                data: _data()
            });
        }
    }

    function _entries1(address alice) internal view returns (ExecutionEntry[] memory entries) {
        RollupUpdate[] memory updates = new RollupUpdate[](1);
        updates[0] = RollupUpdate({
            rollupId: e2eRollupId(),
            currentRoot: keccak256("l2-initial-state"),
            newRoot: keccak256("nestedDoublingValues"),
            etherDelta: -21
        });
        bytes32 key = _hash(0, alice);
        bytes32 rh = RollingHashBuilder.entryBegin(updates, key);
        ExpectedL1ToL2Call[] memory nested = new ExpectedL1ToL2Call[](2);
        rh = RollingHashBuilder.appendCallBegin(rh, _hash(1, alice));
        nested[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(_hash(2, alice), rh),
            l2ToL1Calls: _calls1(3, alice),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(60))
        });
        rh = RollingHashBuilder.appendNestedBegin(rh, _hash(2, alice));
        rh = RollingHashBuilder.appendCallBegin(rh, _hash(3, alice));
        nested[1] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: expectedL1toL2Hash(_hash(4, alice), rh),
            l2ToL1Calls: _calls1(5, alice),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(48))
        });
        rh = RollingHashBuilder.appendNestedBegin(rh, _hash(4, alice));
        rh = RollingHashBuilder.appendCallBegin(rh, _hash(5, alice));
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(32)));
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(56)));
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(62)));
        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: updates,
            destinationRollupId: e2eRollupId(),
            l2ToL1Calls: _calls1(1, alice),
            expectedL1ToL2Calls: nested,
            proxyEntryHash: key,
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(63))
        });
    }

    function _entries2(address alice) internal view returns (L2Entry[] memory entries) {
        bytes32 key = _hash(0, alice);
        bytes32 rh = RollingHashBuilder.entryBeginL2(key);
        ExpectedOutgoingCrossChainCall[] memory nested = new ExpectedOutgoingCrossChainCall[](3);
        rh = RollingHashBuilder.appendCallBegin(rh, _hash(0, alice));
        nested[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(_hash(1, alice), rh),
            incomingCalls: _calls2(2, alice),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(62))
        });
        rh = RollingHashBuilder.appendNestedBegin(rh, _hash(1, alice));
        rh = RollingHashBuilder.appendCallBegin(rh, _hash(2, alice));
        nested[1] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(_hash(3, alice), rh),
            incomingCalls: _calls2(4, alice),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(56))
        });
        rh = RollingHashBuilder.appendNestedBegin(rh, _hash(3, alice));
        rh = RollingHashBuilder.appendCallBegin(rh, _hash(4, alice));
        nested[2] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(_hash(5, alice), rh),
            incomingCalls: _calls2(6, alice),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(32))
        });
        rh = RollingHashBuilder.appendNestedBegin(rh, _hash(5, alice));
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(48)));
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(60)));
        rh = RollingHashBuilder.appendNestedEnd(rh);
        rh = RollingHashBuilder.appendCallEnd(rh, true, abi.encode(uint256(63)));
        entries = new L2Entry[](1);
        entries[0] = L2Entry({
            incomingCalls: _calls2(0, alice),
            expectedOutgoingCalls: nested,
            proxyEntryHash: key,
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(63))
        });
    }

    function _steps(address alice) internal view returns (HashStep[][] memory steps) {
        steps = new HashStep[][](1);
        steps[0] = new HashStep[](10);
        steps[0][0] = RollingHashBuilder.stepCallBegin(_hash(1, alice));
        steps[0][1] = RollingHashBuilder.stepNestedBegin(_hash(2, alice));
        steps[0][2] = RollingHashBuilder.stepCallBegin(_hash(3, alice));
        steps[0][3] = RollingHashBuilder.stepNestedBegin(_hash(4, alice));
        steps[0][4] = RollingHashBuilder.stepCallBegin(_hash(5, alice));
        steps[0][5] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(32)));
        steps[0][6] = RollingHashBuilder.stepNestedEnd();
        steps[0][7] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(56)));
        steps[0][8] = RollingHashBuilder.stepNestedEnd();
        steps[0][9] = RollingHashBuilder.stepCallEnd(true, abi.encode(uint256(62)));
    }

    function _verify1() internal view {
        require(ValueHop(_hop(1)).calls() == 1, "hop 1: call count");
        require(ValueHop(_hop(1)).received() == 2, "hop 1: received value");
        require(ValueHop(_hop(1)).result() == 62, "hop 1: return result");
        require(_hop(1).balance == 2, "hop 1: balance");
        require(ValueHop(_hop(3)).calls() == 1, "hop 3: call count");
        require(ValueHop(_hop(3)).received() == 8, "hop 3: received value");
        require(ValueHop(_hop(3)).result() == 56, "hop 3: return result");
        require(_hop(3).balance == 8, "hop 3: balance");
        require(ValueHop(_hop(5)).calls() == 1, "hop 5: call count");
        require(ValueHop(_hop(5)).received() == 32, "hop 5: received value");
        require(ValueHop(_hop(5)).result() == 32, "hop 5: return result");
        require(_hop(5).balance == 32, "hop 5: balance");
    }

    function _verify2() internal view {
        require(ValueHop(_hop(0)).calls() == 1, "hop 0: call count");
        require(ValueHop(_hop(0)).received() == 1, "hop 0: received value");
        require(ValueHop(_hop(0)).result() == 63, "hop 0: return result");
        require(_hop(0).balance == 1, "hop 0: balance");
        require(ValueHop(_hop(2)).calls() == 1, "hop 2: call count");
        require(ValueHop(_hop(2)).received() == 4, "hop 2: received value");
        require(ValueHop(_hop(2)).result() == 60, "hop 2: return result");
        require(_hop(2).balance == 4, "hop 2: balance");
        require(ValueHop(_hop(4)).calls() == 1, "hop 4: call count");
        require(ValueHop(_hop(4)).received() == 16, "hop 4: received value");
        require(ValueHop(_hop(4)).result() == 48, "hop 4: return result");
        require(_hop(4).balance == 16, "hop 4: balance");
    }

    // Local-only prior escrow, following bridgeL2. No application execution is fabricated.
    function _fundEscrow(EEZ registry) internal {
        string memory addr = vm.toString(address(registry));
        string memory amount = vm.toString(bytes32(uint256(100)));
        vm.rpc("anvil_setBalance", string.concat('["', addr, '","', amount, '"]'));
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(uint256(e2eRollupId()), uint256(2)))) + 2);
        vm.rpc("anvil_setStorageAt", string.concat('["', addr, '","', vm.toString(slot), '","', amount, '"]'));
        (,, uint256 escrow) = registry.rollups(e2eRollupId());
        require(escrow == 100 && address(registry).balance == 100, "local escrow setup failed");
    }
}

contract DeployHop5 is ValueActions {
    function run() external {
        vm.startBroadcast();
        ValueHop hop = new ValueHop{value: 0}(address(0), 32, 0, 0);
        output("HOP_5", address(hop));
        vm.stopBroadcast();
    }
}

contract DeployHop4L2 is ValueActions {
    function run() external {
        vm.startBroadcast();
        require(!EEZL2(vm.envAddress("MANAGER_L2")).USE_GAS_LEFT(), "requires gas-independent hashes");
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("MANAGER_L2")), _hop(5), 0);
        ValueHop hop = new ValueHop{value: 32}(proxy, 16, 32, 32);
        output("HOP_4", address(hop));
        vm.stopBroadcast();
    }
}

contract DeployHop3 is ValueActions {
    function run() external {
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), _hop(4), e2eRollupId());
        ValueHop hop = new ValueHop{value: 16}(proxy, 8, 16, 48);
        output("HOP_3", address(hop));
        vm.stopBroadcast();
    }
}

contract DeployHop2L2 is ValueActions {
    function run() external {
        vm.startBroadcast();
        require(!EEZL2(vm.envAddress("MANAGER_L2")).USE_GAS_LEFT(), "requires gas-independent hashes");
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("MANAGER_L2")), _hop(3), 0);
        ValueHop hop = new ValueHop{value: 8}(proxy, 4, 8, 56);
        output("HOP_2", address(hop));
        vm.stopBroadcast();
    }
}

contract DeployHop1 is ValueActions {
    function run() external {
        vm.startBroadcast();
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), _hop(2), e2eRollupId());
        ValueHop hop = new ValueHop{value: 4}(proxy, 2, 4, 60);
        output("HOP_1", address(hop));
        vm.stopBroadcast();
    }
}

contract DeployHop0L2 is ValueActions {
    function run() external {
        vm.startBroadcast();
        require(!EEZL2(vm.envAddress("MANAGER_L2")).USE_GAS_LEFT(), "requires gas-independent hashes");
        address proxy = getOrCreateProxy(IEEZ(vm.envAddress("MANAGER_L2")), _hop(1), 0);
        ValueHop hop = new ValueHop{value: 2}(proxy, 1, 2, 62);
        output("HOP_0", address(hop));
        vm.stopBroadcast();
    }
}

contract DeployTrigger is ValueActions {
    function run() external {
        vm.startBroadcast();
        output("TRIGGER_PROXY", getOrCreateProxy(IEEZ(vm.envAddress("ROLLUPS")), _hop(0), e2eRollupId()));
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is ValueActions {
    function run() external {
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        vm.startBroadcast();
        manager.executeIncomingCrossChainCall{value: 21}(_entries2(msg.sender), noL2StaticEntries());
        _verify2();
        vm.stopBroadcast();
        console.log("done");
    }
}

contract Execute is ValueActions {
    function run() external {
        EEZ registry = EEZ(vm.envAddress("ROLLUPS"));
        _fundEscrow(registry);
        vm.startBroadcast();
        registry.postAndVerifyBatch(
            immediateSingleRollupBatch(
                vm.envAddress("PROOF_SYSTEM"), e2eRollupId(), _entries1(msg.sender), noStaticEntries()
            )
        );
        (bool ok, bytes memory ret) = vm.envAddress("TRIGGER_PROXY").call{value: 1}(_data());
        require(ok, "trigger failed");
        require(keccak256(ret) == keccak256(abi.encode(uint256(63))), "wrong outer return bytes");
        _verify1();
        (,, uint256 escrow) = registry.rollups(e2eRollupId());
        require(escrow == 79 && address(registry).balance == 79, "net escrow mismatch");
        vm.stopBroadcast();
        console.log("done");
    }
}

contract ExecuteNetwork is ValueActions {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("TRIGGER_PROXY"));
        console.log("VALUE=1");
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
