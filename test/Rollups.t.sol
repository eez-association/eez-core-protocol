// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {Rollups, RollupConfig} from "../src/Rollups.sol";
import {
    ExecutionEntry,
    StateDelta,
    CrossChainCall,
    NestedAction,
    StaticCall,
    ProxyInfo
} from "../src/ICrossChainManager.sol";
import {CrossChainProxy} from "../src/CrossChainProxy.sol";
import {MockZKVerifier} from "./helpers/TestBase.sol";

/// @notice Simple target contract for testing
contract TestTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    receive() external payable {}
}

/// @notice Target contract that always reverts
contract RevertingTarget {
    error TargetReverted();

    fallback() external payable {
        revert TargetReverted();
    }
}

contract RollupsTest is Test {
    Rollups public rollups;
    MockZKVerifier public verifier;
    TestTarget public target;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    uint8 constant CALL_BEGIN = 1;
    uint8 constant CALL_END = 2;
    uint8 constant NESTED_BEGIN = 3;
    uint8 constant NESTED_END = 4;

    function setUp() public {
        verifier = new MockZKVerifier();
        rollups = new Rollups(address(verifier), 1);
        target = new TestTarget();
    }

    function _getRollupState(uint256 rollupId) internal view returns (bytes32) {
        (,, bytes32 stateRoot,) = rollups.rollups(rollupId);
        return stateRoot;
    }

    function _getRollupOwner(uint256 rollupId) internal view returns (address) {
        (address owner,,,) = rollups.rollups(rollupId);
        return owner;
    }

    function _getRollupVK(uint256 rollupId) internal view returns (bytes32) {
        (, bytes32 vk,,) = rollups.rollups(rollupId);
        return vk;
    }

    function _getRollupEtherBalance(uint256 rollupId) internal view returns (uint256) {
        (,,, uint256 etherBalance) = rollups.rollups(rollupId);
        return etherBalance;
    }

    function _fundRollup(uint256 rollupId, uint256 amount) internal {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(rollupId, uint256(1)))) + 3);
        vm.store(address(rollups), slot, bytes32(amount));
        vm.deal(address(rollups), address(rollups).balance + amount);
    }

    function _computeActionHash(
        uint256 rollupId, address destination, uint256 value_, bytes memory data,
        address sourceAddress, uint256 sourceRollup
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(rollupId, destination, value_, data, sourceAddress, sourceRollup));
    }

    function _rollingHashSingleCall(bytes memory retData) internal pure returns (bytes32) {
        bytes32 hash = bytes32(0);
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(1)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(1), true, retData));
        return hash;
    }

    function _immediateEntry(uint256 rollupId, bytes32 newState) internal pure returns (ExecutionEntry memory entry) {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: newState, etherDelta: 0});
        entry.stateDeltas = deltas;
        entry.actionHash = bytes32(0);
        entry.calls = new CrossChainCall[](0);
        entry.nestedActions = new NestedAction[](0);
        entry.callCount = 0;
        entry.returnData = "";
        entry.failed = false;
        entry.rollingHash = bytes32(0);
    }

    function _postBatch(ExecutionEntry[] memory entries) internal {
        StaticCall[] memory noStatic = new StaticCall[](0);
        rollups.postBatch(entries, noStatic, 0, "", "proof");
    }

    // ══════════════════════════════════════════════
    //  Rollup creation tests
    // ══════════════════════════════════════════════

    function test_CreateRollup() public {
        bytes32 initialState = keccak256("initial");
        uint256 rollupId = rollups.createRollup(initialState, DEFAULT_VK, alice);
        assertEq(rollupId, 1);
        uint256 rollupId2 = rollups.createRollup(bytes32(0), DEFAULT_VK, bob);
        assertEq(rollupId2, 2);
        assertEq(_getRollupState(rollupId), initialState);
        assertEq(_getRollupOwner(rollupId), alice);
        assertEq(_getRollupVK(rollupId), DEFAULT_VK);
        assertEq(_getRollupState(rollupId2), bytes32(0));
        assertEq(_getRollupOwner(rollupId2), bob);
    }

    function test_CreateCrossChainProxy() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address targetAddr = address(0x1234);
        address proxy = rollups.createCrossChainProxy(targetAddr, rollupId);
        (address origAddr,) = rollups.authorizedProxies(proxy);
        assertTrue(origAddr != address(0));
        uint256 codeSize;
        assembly { codeSize := extcodesize(proxy) }
        assertTrue(codeSize > 0);
    }

    function test_ComputeCrossChainProxyAddress() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address targetAddr = address(0x5678);
        address computedAddr = rollups.computeCrossChainProxyAddress(targetAddr, rollupId);
        address actualAddr = rollups.createCrossChainProxy(targetAddr, rollupId);
        assertEq(computedAddr, actualAddr);
    }

    // ══════════════════════════════════════════════
    //  PostBatch tests
    // ══════════════════════════════════════════════

    function test_PostBatch_ImmediateStateUpdate() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("new state");
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, newState);
        _postBatch(entries);
        assertEq(_getRollupState(rollupId), newState);
    }

    function test_PostBatch_MultipleRollups() public {
        uint256 rollupId1 = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupId2 = rollups.createRollup(bytes32(0), DEFAULT_VK, bob);
        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({rollupId: rollupId1, newState: keccak256("new state 1"), etherDelta: 0});
        deltas[1] = StateDelta({rollupId: rollupId2, newState: keccak256("new state 2"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].calls = new CrossChainCall[](0);
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].rollingHash = bytes32(0);
        _postBatch(entries);
        assertEq(_getRollupState(rollupId1), keccak256("new state 1"));
        assertEq(_getRollupState(rollupId2), keccak256("new state 2"));
    }

    function test_PostBatch_InvalidProof() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, keccak256("new state"));
        verifier.setVerifyResult(false);
        StaticCall[] memory noStatic = new StaticCall[](0);
        vm.expectRevert(Rollups.InvalidProof.selector);
        rollups.postBatch(entries, noStatic, 0, "", "bad proof");
    }

    function test_PostBatch_AfterBatchSameBlockReverts() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("state1");
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, newState);
        _postBatch(entries);
        assertEq(_getRollupState(rollupId), newState);
        ExecutionEntry[] memory entries2 = new ExecutionEntry[](1);
        entries2[0] = _immediateEntry(rollupId, keccak256("another state"));
        StaticCall[] memory noStatic = new StaticCall[](0);
        vm.expectRevert(Rollups.StateAlreadyUpdatedThisBlock.selector);
        rollups.postBatch(entries2, noStatic, 0, "", "proof");
        assertEq(_getRollupState(rollupId), newState);
    }

    function test_PostBatch_EmptyEntries() public {
        ExecutionEntry[] memory entries = new ExecutionEntry[](0);
        _postBatch(entries);
    }

    function test_PostBatch_DifferentBlocks() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        ExecutionEntry[] memory entries1 = new ExecutionEntry[](1);
        entries1[0] = _immediateEntry(rollupId, keccak256("s1"));
        _postBatch(entries1);
        vm.roll(block.number + 1);
        ExecutionEntry[] memory entries2 = new ExecutionEntry[](1);
        entries2[0] = _immediateEntry(rollupId, keccak256("s2"));
        _postBatch(entries2);
        assertEq(_getRollupState(rollupId), keccak256("s2"));
    }

    function test_PostBatch_SetsLastStateUpdateBlock() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, keccak256("s"));
        _postBatch(entries);
        assertEq(rollups.lastStateUpdateBlock(), block.number);
    }

    function test_PostBatch_WithBlobCount() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32[] memory blobs = new bytes32[](2);
        blobs[0] = keccak256("blob0");
        blobs[1] = keccak256("blob1");
        vm.blobhashes(blobs);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, keccak256("blobState"));
        StaticCall[] memory noStatic = new StaticCall[](0);
        rollups.postBatch(entries, noStatic, 2, "", "proof");
        assertEq(_getRollupState(rollupId), keccak256("blobState"));
    }

    function test_PostBatch_OnlyDeferredEntries() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("d1"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = keccak256("some action");
        entries[0].calls = new CrossChainCall[](0);
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].rollingHash = bytes32(0);
        _postBatch(entries);
        assertEq(_getRollupState(rollupId), bytes32(0));
    }

    function test_PostBatch_MixedImmediateAndDeferred() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        bytes32 state1 = keccak256("state1");
        bytes32 state2 = keccak256("state2");
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 0, callData, address(this), 0);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.setValue, (42)),
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 0
        });
        bytes32 rollingHash = _rollingHashSingleCall("");
        ExecutionEntry[] memory entries = new ExecutionEntry[](2);
        entries[0] = _immediateEntry(rollupId, state1);
        StateDelta[] memory deferredDeltas = new StateDelta[](1);
        deferredDeltas[0] = StateDelta({rollupId: rollupId, newState: state2, etherDelta: 0});
        entries[1].stateDeltas = deferredDeltas;
        entries[1].actionHash = actionHash;
        entries[1].calls = calls;
        entries[1].nestedActions = new NestedAction[](0);
        entries[1].callCount = 1;
        entries[1].rollingHash = rollingHash;
        _postBatch(entries);
        assertEq(_getRollupState(rollupId), state1);
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        assertEq(_getRollupState(rollupId), state2);
        assertEq(target.value(), 42);
    }

    function test_PostBatch_MultipleDeltasPerEntry() public {
        uint256 r1 = rollups.createRollup(keccak256("a"), DEFAULT_VK, alice);
        uint256 r2 = rollups.createRollup(keccak256("b"), DEFAULT_VK, bob);
        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({rollupId: r1, newState: keccak256("a2"), etherDelta: 0});
        deltas[1] = StateDelta({rollupId: r2, newState: keccak256("b2"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].calls = new CrossChainCall[](0);
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].rollingHash = bytes32(0);
        _postBatch(entries);
        assertEq(_getRollupState(r1), keccak256("a2"));
        assertEq(_getRollupState(r2), keccak256("b2"));
    }

    // ══════════════════════════════════════════════
    //  Owner management tests
    // ══════════════════════════════════════════════

    function test_SetStateByOwner() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        vm.prank(alice);
        rollups.setStateByOwner(rollupId, keccak256("owner set state"));
        assertEq(_getRollupState(rollupId), keccak256("owner set state"));
    }

    function test_SetStateByOwner_NotOwner() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        vm.prank(bob);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.setStateByOwner(rollupId, keccak256("owner set state"));
    }

    function test_SetVerificationKey() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newVK = keccak256("new verification key");
        vm.prank(alice);
        rollups.setVerificationKey(rollupId, newVK);
        assertEq(_getRollupVK(rollupId), newVK);
    }

    function test_SetVerificationKey_NotOwner() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newVK = keccak256("new verification key");
        vm.prank(bob);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.setVerificationKey(rollupId, newVK);
    }

    function test_TransferRollupOwnership() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        vm.prank(alice);
        rollups.transferRollupOwnership(rollupId, bob);
        assertEq(_getRollupOwner(rollupId), bob);
        vm.prank(bob);
        rollups.setStateByOwner(rollupId, keccak256("bob's state"));
        vm.prank(alice);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.setStateByOwner(rollupId, keccak256("alice's state"));
    }

    function test_TransferRollupOwnership_NotOwner() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        vm.prank(bob);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.transferRollupOwnership(rollupId, bob);
    }

    function test_StartingRollupId() public {
        Rollups rollups2 = new Rollups(address(verifier), 1000);
        uint256 rollupId = rollups2.createRollup(bytes32(0), DEFAULT_VK, alice);
        assertEq(rollupId, 1000);
        uint256 rollupId2 = rollups2.createRollup(bytes32(0), DEFAULT_VK, alice);
        assertEq(rollupId2, 1001);
    }

    function test_MultipleProxiesSameTarget() public {
        uint256 rollup1 = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollup2 = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxy1 = rollups.createCrossChainProxy(address(0x9999), rollup1);
        address proxy2 = rollups.createCrossChainProxy(address(0x9999), rollup2);
        assertTrue(proxy1 != proxy2);
        (address origAddr1,) = rollups.authorizedProxies(proxy1);
        (address origAddr2,) = rollups.authorizedProxies(proxy2);
        assertTrue(origAddr1 != address(0));
        assertTrue(origAddr2 != address(0));
    }

    function test_RollupWithCustomInitialState() public {
        bytes32 customState = keccak256("custom initial state");
        bytes32 customVK = keccak256("custom vk");
        uint256 rollupId = rollups.createRollup(customState, customVK, bob);
        assertEq(_getRollupState(rollupId), customState);
        assertEq(_getRollupVK(rollupId), customVK);
        assertEq(_getRollupOwner(rollupId), bob);
    }

    // ══════════════════════════════════════════════
    //  Ether tracking tests
    // ══════════════════════════════════════════════

    function test_PostBatch_EtherDeltasMustSumToZero() public {
        uint256 rollupId1 = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupId2 = rollups.createRollup(bytes32(0), DEFAULT_VK, bob);
        _fundRollup(rollupId1, 5 ether);
        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({rollupId: rollupId1, newState: keccak256("s1"), etherDelta: -2 ether});
        deltas[1] = StateDelta({rollupId: rollupId2, newState: keccak256("s2"), etherDelta: 2 ether});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].calls = new CrossChainCall[](0);
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].rollingHash = bytes32(0);
        _postBatch(entries);
        assertEq(_getRollupEtherBalance(rollupId1), 3 ether);
        assertEq(_getRollupEtherBalance(rollupId2), 2 ether);
    }

    function test_PostBatch_EtherDeltasNonZeroSumReverts() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        _fundRollup(rollupId, 5 ether);
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("s1"), etherDelta: 1 ether});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].calls = new CrossChainCall[](0);
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].rollingHash = bytes32(0);
        vm.expectRevert(Rollups.EtherDeltaMismatch.selector);
        _postBatch(entries);
    }

    function test_PostBatch_InsufficientRollupBalanceReverts() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("s1"), etherDelta: -1 ether});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].calls = new CrossChainCall[](0);
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].rollingHash = bytes32(0);
        vm.expectRevert(Rollups.InsufficientRollupBalance.selector);
        _postBatch(entries);
    }

    function test_PostBatch_EtherDeltaPositiveIncrement() public {
        uint256 rollupId1 = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupId2 = rollups.createRollup(bytes32(0), DEFAULT_VK, bob);
        _fundRollup(rollupId1, 10 ether);
        StateDelta[] memory deltas = new StateDelta[](2);
        deltas[0] = StateDelta({rollupId: rollupId1, newState: keccak256("s1"), etherDelta: -3 ether});
        deltas[1] = StateDelta({rollupId: rollupId2, newState: keccak256("s2"), etherDelta: 3 ether});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].calls = new CrossChainCall[](0);
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].rollingHash = bytes32(0);
        _postBatch(entries);
        assertEq(_getRollupEtherBalance(rollupId1), 7 ether);
        assertEq(_getRollupEtherBalance(rollupId2), 3 ether);
    }

    function test_ApplyStateDeltas_ZeroEtherDelta() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        _fundRollup(rollupId, 5 ether);
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("zd"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = bytes32(0);
        entries[0].calls = new CrossChainCall[](0);
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].rollingHash = bytes32(0);
        _postBatch(entries);
        assertEq(_getRollupEtherBalance(rollupId), 5 ether);
        assertEq(_getRollupState(rollupId), keccak256("zd"));
    }

    // ══════════════════════════════════════════════
    //  ExecuteCrossChainCall tests
    // ══════════════════════════════════════════════

    function test_ExecuteCrossChainCall_Simple() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 0, callData, address(this), 0);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.setValue, (42)),
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 0
        });
        bytes32 rollingHash = _rollingHashSingleCall("");
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("state1"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].calls = calls;
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].callCount = 1;
        entries[0].rollingHash = rollingHash;
        _postBatch(entries);
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        assertEq(_getRollupState(rollupId), keccak256("state1"));
        assertEq(target.value(), 42);
    }

    function test_ExecuteCrossChainCall_UnauthorizedProxy() public {
        rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        vm.expectRevert(Rollups.UnauthorizedProxy.selector);
        rollups.executeCrossChainCall(alice, "");
    }

    function test_ExecuteCrossChainCall_ExecutionNotFound() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        ExecutionEntry[] memory emptyEntries = new ExecutionEntry[](0);
        _postBatch(emptyEntries);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (999));
        vm.expectRevert(Rollups.ExecutionNotFound.selector);
        (bool success,) = proxyAddr.call(callData);
        success;
    }

    function test_ExecuteCrossChainCall_WithETHValue() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (55));
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 1 ether, callData, address(this), 0);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.setValue, (55)),
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 0
        });
        bytes32 rollingHash = _rollingHashSingleCall("");
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("ethv1"), etherDelta: 1 ether});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].calls = calls;
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].callCount = 1;
        entries[0].rollingHash = rollingHash;
        _postBatch(entries);
        (bool success,) = proxyAddr.call{value: 1 ether}(callData);
        assertTrue(success);
        assertEq(_getRollupState(rollupId), keccak256("ethv1"));
    }

    function test_ExecuteCrossChainCall_EtherDeltaMismatch() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (66));
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 0, callData, address(this), 0);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.setValue, (66)),
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 0
        });
        bytes32 rollingHash = _rollingHashSingleCall("");
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("edm1"), etherDelta: 1 ether});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].calls = calls;
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].callCount = 1;
        entries[0].rollingHash = rollingHash;
        _postBatch(entries);
        vm.expectRevert(Rollups.EtherDeltaMismatch.selector);
        (bool success,) = proxyAddr.call(callData);
        success;
    }

    function test_ExecuteCrossChainCall_MultipleCalls() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 0, callData, address(this), 0);
        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.setValue, (10)),
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 0
        });
        calls[1] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.setValue, (20)),
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 0
        });
        bytes32 hash = bytes32(0);
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(1)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(1), true, bytes("")));
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(2)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(2), true, bytes("")));
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("state_multi"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].calls = calls;
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].callCount = 2;
        entries[0].rollingHash = hash;
        _postBatch(entries);
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        assertEq(target.value(), 20);
    }

    function test_ExecuteCrossChainCall_FailedEntry() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 0, callData, address(this), 0);
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("state_fail"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].calls = new CrossChainCall[](0);
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].returnData = abi.encodeWithSignature("Error(string)", "test fail");
        entries[0].failed = true;
        entries[0].rollingHash = bytes32(0);
        _postBatch(entries);
        (bool success,) = proxyAddr.call(callData);
        assertFalse(success);
    }

    function test_ExecuteCrossChainCall_ReturnData() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        bytes memory callData = abi.encodeCall(TestTarget.getValue, ());
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 0, callData, address(this), 0);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.getValue, ()),
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 0
        });
        bytes32 rollingHash = _rollingHashSingleCall(abi.encode(uint256(0)));
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("state_ret"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].calls = calls;
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].callCount = 1;
        entries[0].returnData = abi.encode(uint256(0));
        entries[0].rollingHash = rollingHash;
        _postBatch(entries);
        (bool success, bytes memory ret) = proxyAddr.call(callData);
        assertTrue(success);
        assertEq(abi.decode(ret, (uint256)), 0);
    }

    function test_ExecuteCrossChainCall_WithRevertSpan() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        RevertingTarget revTarget = new RevertingTarget();
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 0, callData, address(this), 0);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: address(revTarget), value: 0, data: hex"deadbeef",
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 1
        });
        bytes memory revertData = abi.encodeWithSelector(RevertingTarget.TargetReverted.selector);
        bytes32 hash = bytes32(0);
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(1)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(1), false, revertData));
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("state_revert"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].calls = calls;
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].callCount = 1;
        entries[0].rollingHash = hash;
        _postBatch(entries);
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
    }

    function test_RollingHashMismatch_Reverts() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 0, callData, address(this), 0);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.setValue, (42)),
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 0
        });
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("state1"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].calls = calls;
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].callCount = 1;
        entries[0].rollingHash = bytes32(uint256(0xDEAD));
        _postBatch(entries);
        vm.expectRevert(Rollups.RollingHashMismatch.selector);
        (bool success,) = proxyAddr.call(callData);
        success;
    }

    function test_UnconsumedCalls_Reverts() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 0, callData, address(this), 0);
        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.setValue, (42)),
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 0
        });
        calls[1] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.setValue, (99)),
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 0
        });
        bytes32 rollingHash = _rollingHashSingleCall("");
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("state1"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].calls = calls;
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].callCount = 1;
        entries[0].rollingHash = rollingHash;
        _postBatch(entries);
        vm.expectRevert(Rollups.UnconsumedCalls.selector);
        (bool success,) = proxyAddr.call(callData);
        success;
    }

    function test_ProcessNCalls_AutoProxyCreation() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        address expectedProxy = rollups.computeCrossChainProxyAddress(alice, 0);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (77));
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 0, callData, address(this), 0);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.setValue, (77)),
            sourceAddress: alice, sourceRollup: 0, revertSpan: 0
        });
        bytes32 rollingHash = _rollingHashSingleCall("");
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("ap1"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].calls = calls;
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].callCount = 1;
        entries[0].rollingHash = rollingHash;
        _postBatch(entries);
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        (address origAddr,) = rollups.authorizedProxies(expectedProxy);
        assertEq(origAddr, alice);
        assertEq(target.value(), 77);
    }

    // ══════════════════════════════════════════════
    //  executeL2TX tests
    // ══════════════════════════════════════════════

    function test_ExecuteL2TX() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        ExecutionEntry[] memory allEntries = new ExecutionEntry[](2);
        allEntries[0] = _immediateEntry(rollupId, keccak256("temp"));
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("state1"), etherDelta: 0});
        allEntries[1].stateDeltas = deltas;
        allEntries[1].actionHash = bytes32(0);
        allEntries[1].calls = new CrossChainCall[](0);
        allEntries[1].nestedActions = new NestedAction[](0);
        allEntries[1].rollingHash = bytes32(0);
        _postBatch(allEntries);
        rollups.executeL2TX();
        assertEq(_getRollupState(rollupId), keccak256("state1"));
    }

    function test_ExecuteInContext_NotSelf() public {
        vm.expectRevert(Rollups.NotSelf.selector);
        rollups.executeInContext(1);
    }

    // ══════════════════════════════════════════════
    //  Proxy tests
    // ══════════════════════════════════════════════

    function test_Proxy_Fallback_BubblesRevert() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (1));
        (bool success, bytes memory retData) = proxyAddr.call(callData);
        assertFalse(success);
        bytes4 selector;
        assembly { selector := mload(add(retData, 32)) }
        assertEq(selector, Rollups.ExecutionNotInCurrentBlock.selector);
    }

    function test_Proxy_ExecuteOnBehalf_NonManagerFallsThrough() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        CrossChainProxy proxy = CrossChainProxy(payable(proxyAddr));
        vm.prank(alice);
        vm.expectRevert(Rollups.ExecutionNotInCurrentBlock.selector);
        proxy.executeOnBehalf(address(target), abi.encodeCall(TestTarget.setValue, (42)));
    }

    // ══════════════════════════════════════════════
    //  Event tests
    // ══════════════════════════════════════════════

    function test_CreateRollup_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit Rollups.RollupCreated(1, alice, DEFAULT_VK, keccak256("init"));
        rollups.createRollup(keccak256("init"), DEFAULT_VK, alice);
    }

    function test_SetStateByOwner_EmitsEvent() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Rollups.StateUpdated(rollupId, keccak256("emitState"));
        rollups.setStateByOwner(rollupId, keccak256("emitState"));
    }

    function test_SetVerificationKey_EmitsEvent() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Rollups.VerificationKeyUpdated(rollupId, keccak256("newVK"));
        rollups.setVerificationKey(rollupId, keccak256("newVK"));
    }

    function test_TransferOwnership_EmitsEvent() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Rollups.OwnershipTransferred(rollupId, alice, bob);
        rollups.transferRollupOwnership(rollupId, bob);
    }

    function test_CreateCrossChainProxy_EmitsEvent() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address expectedProxy = rollups.computeCrossChainProxyAddress(address(target), rollupId);
        vm.expectEmit(true, true, true, true);
        emit Rollups.CrossChainProxyCreated(expectedProxy, address(target), rollupId);
        rollups.createCrossChainProxy(address(target), rollupId);
    }

    function test_BatchPosted_EmitsOnImmediateEntry() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rollupId, keccak256("bp1"));
        vm.recordLogs();
        _postBatch(entries);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        bytes32 sel = Rollups.BatchPosted.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) { found = true; break; }
        }
        assertTrue(found, "BatchPosted event not found");
    }

    function test_ExecutionConsumed_EmitsOnConsume() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 0, callData, address(this), 0);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.setValue, (42)),
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 0
        });
        bytes32 rollingHash = _rollingHashSingleCall("");
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("state_ec"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].calls = calls;
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].callCount = 1;
        entries[0].rollingHash = rollingHash;
        _postBatch(entries);
        vm.recordLogs();
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = Rollups.ExecutionConsumed.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) { assertEq(logs[i].topics[1], actionHash); found = true; break; }
        }
        assertTrue(found, "ExecutionConsumed event not found");
    }

    function test_CrossChainCallExecuted_L1_EmitsOnProxyCall() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createCrossChainProxy(address(target), rollupId);
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));
        bytes32 actionHash = _computeActionHash(rollupId, address(target), 0, callData, address(this), 0);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            destination: address(target), value: 0,
            data: abi.encodeCall(TestTarget.setValue, (42)),
            sourceAddress: address(this), sourceRollup: 0, revertSpan: 0
        });
        bytes32 rollingHash = _rollingHashSingleCall("");
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({rollupId: rollupId, newState: keccak256("state1"), etherDelta: 0});
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].stateDeltas = deltas;
        entries[0].actionHash = actionHash;
        entries[0].calls = calls;
        entries[0].nestedActions = new NestedAction[](0);
        entries[0].callCount = 1;
        entries[0].rollingHash = rollingHash;
        _postBatch(entries);
        vm.recordLogs();
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sel = Rollups.CrossChainCallExecuted.selector;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sel) {
                assertEq(logs[i].topics[1], actionHash);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), proxyAddr);
                found = true; break;
            }
        }
        assertTrue(found, "CrossChainCallExecuted event not found");
    }

    // See problems/questions.md for list of old tests that were fundamentally
    // incompatible with the new API (scopes, Action/ActionType, etc.)
}
