// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Rollups, Action, ActionType, Execution, StateDelta, StateCommitment} from "../src/Rollups.sol";
import {L2Proxy} from "../src/L2Proxy.sol";
import {IZKVerifier} from "../src/IZKVerifier.sol";

/// @notice Mock ZK verifier that always returns true
contract MockZKVerifier is IZKVerifier {
    function verify(
        bytes calldata,
        bytes32
    ) external pure override returns (bool) {
        return true;
    }
}

/// @notice L1 contract that calls a Rollup B proxy during execution
/// @dev Simulates a cross-domain interaction: L1 receives a call from Rollup A proxy,
///      then calls a Rollup B proxy, creating a multi-rollup execution chain
contract L1Bridge {
    uint256 public lastValueFromRollupB;
    address public rollupBProxy;

    function setRollupBProxy(address _proxy) external {
        rollupBProxy = _proxy;
    }

    /// @notice Called by Rollup A's proxy — reads value from Rollup B's proxy
    function bridgeCall(uint256 inputValue) external returns (uint256) {
        // In a real scenario, this would call rollupBProxy to read L2 state
        // For testing, we store the input and return a derived value
        lastValueFromRollupB = inputValue;
        return inputValue * 2;
    }
}

/// @notice Registry contract that accumulates state across rollups
/// @dev Used to verify that multi-rollup state transitions are atomic
contract StateRegistry {
    mapping(uint256 => bytes32) public rollupStates;
    uint256 public updateCount;

    function recordState(uint256 rollupId, bytes32 stateHash) external {
        rollupStates[rollupId] = stateHash;
        updateCount++;
    }

    function getState(uint256 rollupId) external view returns (bytes32) {
        return rollupStates[rollupId];
    }
}

/// @title CrossRollupTest
/// @notice Integration tests for multi-rollup cross-domain execution
/// @dev Tests the core value proposition: atomic state transitions across rollups
contract CrossRollupTest is Test {
    Rollups public rollups;
    MockZKVerifier public verifier;
    L1Bridge public bridge;
    StateRegistry public registry;

    address public alice = makeAddr("alice");
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function setUp() public {
        verifier = new MockZKVerifier();
        rollups = new Rollups(address(verifier), 1);
        bridge = new L1Bridge();
        registry = new StateRegistry();
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getRollupState(uint256 rollupId) internal view returns (bytes32) {
        (, , bytes32 stateRoot, ) = rollups.rollups(rollupId);
        return stateRoot;
    }

    function _getRollupEtherBalance(
        uint256 rollupId
    ) internal view returns (uint256) {
        (, , , uint256 etherBalance) = rollups.rollups(rollupId);
        return etherBalance;
    }

    /*//////////////////////////////////////////////////////////////
               MULTI-ROLLUP STATE TRANSITION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Tests that two rollups can have their states updated atomically
    ///         via a single L2 execution that touches both
    function test_TwoRollupAtomicStateTransition() public {
        // Setup: create two rollups
        uint256 rollupA = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupB = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        // Create proxy for a target contract on rollup A
        address proxyAddrA = rollups.createL2ProxyContract(
            address(registry),
            rollupA
        );

        bytes32 stateA1 = keccak256("rollupA_state1");
        bytes32 stateB1 = keccak256("rollupB_state1");

        // Build calldata: record state for rollup A
        bytes memory callData = abi.encodeCall(
            StateRegistry.recordState,
            (rollupA, stateA1)
        );

        // Build the initial CALL action from rollup A
        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupA,
            destination: address(registry),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: proxyAddrA,
            sourceRollup: rollupA,
            scope: new uint256[](0)
        });

        // Final RESULT action
        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // State deltas: BOTH rollups transition atomically
        StateDelta[] memory stateDeltas = new StateDelta[](2);
        stateDeltas[0] = StateDelta({
            rollupId: rollupA,
            currentState: bytes32(0),
            newState: stateA1,
            etherDelta: 0
        });
        stateDeltas[1] = StateDelta({
            rollupId: rollupB,
            currentState: bytes32(0),
            newState: stateB1,
            etherDelta: 0
        });

        // Load execution
        Execution[] memory executions = new Execution[](1);
        executions[0].stateDeltas = stateDeltas;
        executions[0].actionHash = keccak256(abi.encode(action));
        executions[0].nextAction = resultAction;
        rollups.loadL2Executions(executions, "proof");

        // Execute via proxy fallback
        (bool success, ) = proxyAddrA.call(callData);
        assertTrue(success, "Cross-rollup execution should succeed");

        // Verify BOTH rollup states were updated atomically
        assertEq(
            _getRollupState(rollupA),
            stateA1,
            "Rollup A state should have transitioned"
        );
        assertEq(
            _getRollupState(rollupB),
            stateB1,
            "Rollup B state should have transitioned atomically"
        );
    }

    /// @notice Tests three rollups transitioning atomically in a single execution
    function test_ThreeRollupAtomicStateTransition() public {
        uint256 rollupA = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupB = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupC = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        address proxyAddrA = rollups.createL2ProxyContract(
            address(registry),
            rollupA
        );

        bytes32 stateA1 = keccak256("A_state1");
        bytes32 stateB1 = keccak256("B_state1");
        bytes32 stateC1 = keccak256("C_state1");

        bytes memory callData = abi.encodeCall(
            StateRegistry.recordState,
            (rollupA, stateA1)
        );

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupA,
            destination: address(registry),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: proxyAddrA,
            sourceRollup: rollupA,
            scope: new uint256[](0)
        });

        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // State deltas: ALL THREE rollups transition
        StateDelta[] memory stateDeltas = new StateDelta[](3);
        stateDeltas[0] = StateDelta({
            rollupId: rollupA,
            currentState: bytes32(0),
            newState: stateA1,
            etherDelta: 0
        });
        stateDeltas[1] = StateDelta({
            rollupId: rollupB,
            currentState: bytes32(0),
            newState: stateB1,
            etherDelta: 0
        });
        stateDeltas[2] = StateDelta({
            rollupId: rollupC,
            currentState: bytes32(0),
            newState: stateC1,
            etherDelta: 0
        });

        Execution[] memory executions = new Execution[](1);
        executions[0].stateDeltas = stateDeltas;
        executions[0].actionHash = keccak256(abi.encode(action));
        executions[0].nextAction = resultAction;
        rollups.loadL2Executions(executions, "proof");

        (bool success, ) = proxyAddrA.call(callData);
        assertTrue(success, "Three-rollup execution should succeed");

        assertEq(_getRollupState(rollupA), stateA1);
        assertEq(_getRollupState(rollupB), stateB1);
        assertEq(_getRollupState(rollupC), stateC1);
    }

    /// @notice Tests that a cross-rollup execution fails atomically if state doesn't match
    function test_CrossRollup_FailsIfStateStale() public {
        uint256 rollupA = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupB = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        address proxyAddrA = rollups.createL2ProxyContract(
            address(registry),
            rollupA
        );

        bytes memory callData = abi.encodeCall(
            StateRegistry.recordState,
            (rollupA, keccak256("new"))
        );

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupA,
            destination: address(registry),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: proxyAddrA,
            sourceRollup: rollupA,
            scope: new uint256[](0)
        });

        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // State deltas: Rollup B expects state bytes32(0), but we'll advance it first
        StateDelta[] memory stateDeltas = new StateDelta[](2);
        stateDeltas[0] = StateDelta({
            rollupId: rollupA,
            currentState: bytes32(0),
            newState: keccak256("A_new"),
            etherDelta: 0
        });
        stateDeltas[1] = StateDelta({
            rollupId: rollupB,
            currentState: bytes32(0), // Expects initial state
            newState: keccak256("B_new"),
            etherDelta: 0
        });

        Execution[] memory executions = new Execution[](1);
        executions[0].stateDeltas = stateDeltas;
        executions[0].actionHash = keccak256(abi.encode(action));
        executions[0].nextAction = resultAction;
        rollups.loadL2Executions(executions, "proof");

        // Advance rollup B's state so the execution table becomes stale
        vm.prank(alice);
        rollups.setStateByOwner(rollupB, keccak256("advanced_state"));

        // Execution should fail because rollup B's state no longer matches
        vm.expectRevert(Rollups.ExecutionNotFound.selector);
        (bool success, ) = proxyAddrA.call(callData);
        success; // silence unused variable warning
    }

    /*//////////////////////////////////////////////////////////////
              CROSS-ROLLUP ETH VALUE TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Tests ETH balance transfers between rollups via execution table
    function test_CrossRollup_EtherTransfer() public {
        uint256 rollupA = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupB = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        // Fund rollup A with 10 ETH
        rollups.depositEther{value: 10 ether}(rollupA);
        assertEq(_getRollupEtherBalance(rollupA), 10 ether);
        assertEq(_getRollupEtherBalance(rollupB), 0);

        address proxyAddrA = rollups.createL2ProxyContract(
            address(registry),
            rollupA
        );

        bytes memory callData = abi.encodeCall(
            StateRegistry.recordState,
            (rollupA, keccak256("transfer"))
        );

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupA,
            destination: address(registry),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: proxyAddrA,
            sourceRollup: rollupA,
            scope: new uint256[](0)
        });

        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // State deltas with ETH transfer: 3 ETH from rollup A to rollup B
        StateDelta[] memory stateDeltas = new StateDelta[](2);
        stateDeltas[0] = StateDelta({
            rollupId: rollupA,
            currentState: bytes32(0),
            newState: keccak256("A_after_transfer"),
            etherDelta: -3 ether // Rollup A loses 3 ETH
        });
        stateDeltas[1] = StateDelta({
            rollupId: rollupB,
            currentState: bytes32(0),
            newState: keccak256("B_after_transfer"),
            etherDelta: 3 ether // Rollup B gains 3 ETH
        });

        Execution[] memory executions = new Execution[](1);
        executions[0].stateDeltas = stateDeltas;
        executions[0].actionHash = keccak256(abi.encode(action));
        executions[0].nextAction = resultAction;
        rollups.loadL2Executions(executions, "proof");

        (bool success, ) = proxyAddrA.call(callData);
        assertTrue(success, "ETH transfer execution should succeed");

        // Verify ETH balances were updated
        assertEq(
            _getRollupEtherBalance(rollupA),
            7 ether,
            "Rollup A should have 7 ETH after sending 3"
        );
        assertEq(
            _getRollupEtherBalance(rollupB),
            3 ether,
            "Rollup B should have 3 ETH after receiving 3"
        );
    }

    /// @notice Tests that cross-rollup ETH transfer fails if sender has insufficient balance
    function test_CrossRollup_EtherTransfer_InsufficientBalance() public {
        uint256 rollupA = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupB = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        // Fund rollup A with only 1 ETH
        rollups.depositEther{value: 1 ether}(rollupA);

        address proxyAddrA = rollups.createL2ProxyContract(
            address(registry),
            rollupA
        );

        bytes memory callData = abi.encodeCall(
            StateRegistry.recordState,
            (rollupA, keccak256("overdraft"))
        );

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupA,
            destination: address(registry),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: proxyAddrA,
            sourceRollup: rollupA,
            scope: new uint256[](0)
        });

        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // Try to transfer 5 ETH from rollup A (which only has 1 ETH)
        StateDelta[] memory stateDeltas = new StateDelta[](2);
        stateDeltas[0] = StateDelta({
            rollupId: rollupA,
            currentState: bytes32(0),
            newState: keccak256("A_overdraft"),
            etherDelta: -5 ether
        });
        stateDeltas[1] = StateDelta({
            rollupId: rollupB,
            currentState: bytes32(0),
            newState: keccak256("B_overdraft"),
            etherDelta: 5 ether
        });

        Execution[] memory executions = new Execution[](1);
        executions[0].stateDeltas = stateDeltas;
        executions[0].actionHash = keccak256(abi.encode(action));
        executions[0].nextAction = resultAction;
        rollups.loadL2Executions(executions, "proof");

        // Should revert with InsufficientRollupBalance
        vm.expectRevert(Rollups.InsufficientRollupBalance.selector);
        (bool success, ) = proxyAddrA.call(callData);
        success;
    }

    /*//////////////////////////////////////////////////////////////
              CROSS-ROLLUP CHAINED EXECUTION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Tests a chained execution: Rollup A → L1 call → state update,
    ///         then a second execution continues from the new state
    function test_ChainedCrossRollupExecutions() public {
        uint256 rollupA = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupB = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        address proxyAddrA = rollups.createL2ProxyContract(
            address(bridge),
            rollupA
        );

        bytes32 stateA1 = keccak256("A_step1");
        bytes32 stateA2 = keccak256("A_step2");
        bytes32 stateB1 = keccak256("B_step1");
        bytes32 stateB2 = keccak256("B_step2");

        // First call: bridgeCall(42)
        bytes memory callData1 = abi.encodeCall(L1Bridge.bridgeCall, (42));

        Action memory action1 = Action({
            actionType: ActionType.CALL,
            rollupId: rollupA,
            destination: address(bridge),
            value: 0,
            data: callData1,
            failed: false,
            sourceAddress: proxyAddrA,
            sourceRollup: rollupA,
            scope: new uint256[](0)
        });

        // Second call: bridgeCall(84) — continues after first resolves
        Action memory action2 = Action({
            actionType: ActionType.CALL,
            rollupId: rollupA,
            destination: address(bridge),
            value: 0,
            data: abi.encodeCall(L1Bridge.bridgeCall, (84)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // Result from second call
        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: rollupA,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(168)), // 84 * 2
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // Final result
        Action memory finalResult = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: abi.encode(uint256(168)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0,
            scope: new uint256[](0)
        });

        // First execution: both rollups transition, next action is second CALL
        StateDelta[] memory deltas1 = new StateDelta[](2);
        deltas1[0] = StateDelta({
            rollupId: rollupA,
            currentState: bytes32(0),
            newState: stateA1,
            etherDelta: 0
        });
        deltas1[1] = StateDelta({
            rollupId: rollupB,
            currentState: bytes32(0),
            newState: stateB1,
            etherDelta: 0
        });

        // Second execution: both rollups transition again from step 1 to step 2
        StateDelta[] memory deltas2 = new StateDelta[](2);
        deltas2[0] = StateDelta({
            rollupId: rollupA,
            currentState: stateA1,
            newState: stateA2,
            etherDelta: 0
        });
        deltas2[1] = StateDelta({
            rollupId: rollupB,
            currentState: stateB1,
            newState: stateB2,
            etherDelta: 0
        });

        // Load both executions
        Execution[] memory executions = new Execution[](2);
        executions[0].stateDeltas = deltas1;
        executions[0].actionHash = keccak256(abi.encode(action1));
        executions[0].nextAction = action2;

        executions[1].stateDeltas = deltas2;
        executions[1].actionHash = keccak256(abi.encode(resultAction));
        executions[1].nextAction = finalResult;

        rollups.loadL2Executions(executions, "proof");

        // Execute the chain via proxy fallback
        (bool success, ) = proxyAddrA.call(callData1);
        assertTrue(success, "Chained cross-rollup execution should succeed");

        // Verify both rollups reached their final states
        assertEq(
            _getRollupState(rollupA),
            stateA2,
            "Rollup A should be at step 2"
        );
        assertEq(
            _getRollupState(rollupB),
            stateB2,
            "Rollup B should be at step 2"
        );

        // Verify L1 contract was called with the second value
        assertEq(
            bridge.lastValueFromRollupB(),
            84,
            "Bridge should have received value 84"
        );
    }

    /*//////////////////////////////////////////////////////////////
                     POSTBATCH WITH ETHER TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Tests postBatch with ether increments that must sum to zero
    function test_PostBatch_CrossRollupEtherRebalance() public {
        uint256 rollupA = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupB = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupC = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        // Fund rollups
        rollups.depositEther{value: 10 ether}(rollupA);
        rollups.depositEther{value: 5 ether}(rollupB);

        StateCommitment[] memory commitments = new StateCommitment[](3);
        commitments[0] = StateCommitment({
            rollupId: rollupA,
            newState: keccak256("A_rebalanced"),
            etherIncrement: -4 ether // A loses 4
        });
        commitments[1] = StateCommitment({
            rollupId: rollupB,
            newState: keccak256("B_rebalanced"),
            etherIncrement: -1 ether // B loses 1
        });
        commitments[2] = StateCommitment({
            rollupId: rollupC,
            newState: keccak256("C_rebalanced"),
            etherIncrement: 5 ether // C gains 5 (sum = 0)
        });

        rollups.postBatch(commitments, 0, "", "proof");

        assertEq(_getRollupEtherBalance(rollupA), 6 ether);
        assertEq(_getRollupEtherBalance(rollupB), 4 ether);
        assertEq(_getRollupEtherBalance(rollupC), 5 ether);
    }

    /// @notice Tests that postBatch reverts if ether increments don't sum to zero
    function test_PostBatch_EtherIncrementsNotZero() public {
        uint256 rollupA = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupB = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        rollups.depositEther{value: 10 ether}(rollupA);

        StateCommitment[] memory commitments = new StateCommitment[](2);
        commitments[0] = StateCommitment({
            rollupId: rollupA,
            newState: keccak256("A"),
            etherIncrement: -5 ether
        });
        commitments[1] = StateCommitment({
            rollupId: rollupB,
            newState: keccak256("B"),
            etherIncrement: 3 ether // Sum = -2, not zero
        });

        vm.expectRevert(Rollups.EtherIncrementsSumNotZero.selector);
        rollups.postBatch(commitments, 0, "", "proof");
    }
}
