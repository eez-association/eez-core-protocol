// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Rollups, Action, ActionType, Execution, StateDelta} from "../src/Rollups.sol";
import {CommittedExecutionLoader} from "../src/CommittedExecutionLoader.sol";
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

/// @notice Simple target contract for testing cross-rollup calls
contract Target {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }
}

contract CommittedExecutionLoaderTest is Test {
    Rollups public rollups;
    CommittedExecutionLoader public loader;
    MockZKVerifier public verifier;
    Target public target;

    address public alice = makeAddr("alice");
    address public builder = makeAddr("builder");

    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function setUp() public {
        verifier = new MockZKVerifier();
        rollups = new Rollups(address(verifier), 1);
        loader = new CommittedExecutionLoader(address(rollups));
        target = new Target();
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Creates a simple single-rollup execution for testing
    function _createSimpleExecution(
        uint256 rollupId
    )
        internal
        view
        returns (Execution[] memory executions, bytes memory proof)
    {
        address proxyAddr = rollups.computeL2ProxyAddress(
            address(target),
            rollupId,
            block.chainid
        );

        bytes memory callData = abi.encodeCall(Target.setValue, (42));

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: proxyAddr,
            sourceRollup: rollupId,
            scope: new uint256[](0)
        });

        Action memory nextAction = Action({
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

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: rollupId,
            currentState: bytes32(0),
            newState: keccak256("state1"),
            etherDelta: 0
        });

        executions = new Execution[](1);
        executions[0].stateDeltas = stateDeltas;
        executions[0].actionHash = keccak256(abi.encode(action));
        executions[0].nextAction = nextAction;

        proof = "valid_proof";
    }

    /*//////////////////////////////////////////////////////////////
                        COMMITMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MakeCommitment_IsDeterministic() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        (
            Execution[] memory executions,
            bytes memory proof
        ) = _createSimpleExecution(rollupId);
        bytes32 secret = keccak256("my_secret");

        bytes32 commitment1 = loader.makeCommitment(executions, proof, secret);
        bytes32 commitment2 = loader.makeCommitment(executions, proof, secret);

        assertEq(
            commitment1,
            commitment2,
            "Same inputs should produce same commitment"
        );
    }

    function test_MakeCommitment_DifferentSecrets() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        (
            Execution[] memory executions,
            bytes memory proof
        ) = _createSimpleExecution(rollupId);

        bytes32 commitment1 = loader.makeCommitment(
            executions,
            proof,
            keccak256("secret1")
        );
        bytes32 commitment2 = loader.makeCommitment(
            executions,
            proof,
            keccak256("secret2")
        );

        assertTrue(
            commitment1 != commitment2,
            "Different secrets should produce different commitments"
        );
    }

    function test_Commit_Success() public {
        bytes32 commitment = keccak256("test_commitment");

        vm.prank(alice);
        loader.commit(commitment);

        assertEq(loader.commitments(commitment), block.number);
    }

    function test_Commit_EmitsEvent() public {
        bytes32 commitment = keccak256("test_commitment");

        vm.expectEmit(true, true, false, false);
        emit CommittedExecutionLoader.ExecutionCommitted(commitment, alice);

        vm.prank(alice);
        loader.commit(commitment);
    }

    function test_Commit_RevertIfAlreadyCommitted() public {
        bytes32 commitment = keccak256("test_commitment");

        loader.commit(commitment);

        vm.expectRevert(CommittedExecutionLoader.AlreadyCommitted.selector);
        loader.commit(commitment);
    }

    function test_Commit_AllowsRecommitAfterExpiry() public {
        bytes32 commitment = keccak256("test_commitment");

        loader.commit(commitment);

        // Roll past MAX_COMMITMENT_AGE
        vm.roll(block.number + loader.MAX_COMMITMENT_AGE() + 1);

        // Should succeed — old commitment expired
        loader.commit(commitment);
        assertEq(loader.commitments(commitment), block.number);
    }

    /*//////////////////////////////////////////////////////////////
                        REVEAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevealAndLoad_Success() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        (
            Execution[] memory executions,
            bytes memory proof
        ) = _createSimpleExecution(rollupId);
        bytes32 secret = keccak256("my_secret");

        // Step 1: Commit
        bytes32 commitment = loader.makeCommitment(executions, proof, secret);
        vm.prank(alice);
        loader.commit(commitment);

        // Step 2: Advance past MIN_COMMITMENT_AGE
        vm.roll(block.number + loader.MIN_COMMITMENT_AGE());

        // Step 3: Reveal
        vm.prank(alice);
        loader.revealAndLoad(executions, proof, secret);

        // Verify commitment was consumed
        assertEq(loader.commitments(commitment), 0);
    }

    function test_RevealAndLoad_TooEarly() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        (
            Execution[] memory executions,
            bytes memory proof
        ) = _createSimpleExecution(rollupId);
        bytes32 secret = keccak256("my_secret");

        bytes32 commitment = loader.makeCommitment(executions, proof, secret);
        loader.commit(commitment);

        // Try to reveal in the same block — should fail
        vm.expectRevert(CommittedExecutionLoader.CommitmentTooNew.selector);
        loader.revealAndLoad(executions, proof, secret);
    }

    function test_RevealAndLoad_TooLate() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        (
            Execution[] memory executions,
            bytes memory proof
        ) = _createSimpleExecution(rollupId);
        bytes32 secret = keccak256("my_secret");

        bytes32 commitment = loader.makeCommitment(executions, proof, secret);
        loader.commit(commitment);

        // Roll past MAX_COMMITMENT_AGE
        vm.roll(block.number + loader.MAX_COMMITMENT_AGE() + 1);

        vm.expectRevert(CommittedExecutionLoader.CommitmentTooOld.selector);
        loader.revealAndLoad(executions, proof, secret);
    }

    function test_RevealAndLoad_WrongSecret() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        (
            Execution[] memory executions,
            bytes memory proof
        ) = _createSimpleExecution(rollupId);

        bytes32 correctSecret = keccak256("correct");
        bytes32 wrongSecret = keccak256("wrong");

        bytes32 commitment = loader.makeCommitment(
            executions,
            proof,
            correctSecret
        );
        loader.commit(commitment);

        vm.roll(block.number + loader.MIN_COMMITMENT_AGE());

        // Reveal with wrong secret — should fail because commitment doesn't match
        vm.expectRevert(CommittedExecutionLoader.CommitmentNotFound.selector);
        loader.revealAndLoad(executions, proof, wrongSecret);
    }

    function test_RevealAndLoad_NoCommitment() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        (
            Execution[] memory executions,
            bytes memory proof
        ) = _createSimpleExecution(rollupId);
        bytes32 secret = keccak256("my_secret");

        // Try to reveal without committing first
        vm.expectRevert(CommittedExecutionLoader.CommitmentNotFound.selector);
        loader.revealAndLoad(executions, proof, secret);
    }

    function test_RevealAndLoad_CannotReplayCommitment() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        (
            Execution[] memory executions,
            bytes memory proof
        ) = _createSimpleExecution(rollupId);
        bytes32 secret = keccak256("my_secret");

        bytes32 commitment = loader.makeCommitment(executions, proof, secret);
        loader.commit(commitment);

        vm.roll(block.number + loader.MIN_COMMITMENT_AGE());

        // First reveal succeeds
        loader.revealAndLoad(executions, proof, secret);

        // Second reveal with same parameters fails — commitment was deleted
        vm.expectRevert(CommittedExecutionLoader.CommitmentNotFound.selector);
        loader.revealAndLoad(executions, proof, secret);
    }

    /*//////////////////////////////////////////////////////////////
                  BUILDER FRONT-RUNNING RESISTANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Demonstrates that a builder cannot extract execution table content
    ///         from the commitment alone
    function test_BuilderCannotExtractContentFromCommitment() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        (
            Execution[] memory executions,
            bytes memory proof
        ) = _createSimpleExecution(rollupId);
        bytes32 secret = keccak256("alice_secret");

        // Alice commits — builder sees only the opaque commitment hash
        bytes32 commitment = loader.makeCommitment(executions, proof, secret);

        vm.prank(alice);
        loader.commit(commitment);

        // Builder tries to reveal with a guessed secret — fails
        vm.roll(block.number + loader.MIN_COMMITMENT_AGE());

        vm.prank(builder);
        vm.expectRevert(CommittedExecutionLoader.CommitmentNotFound.selector);
        loader.revealAndLoad(executions, proof, keccak256("guessed_secret"));

        // Alice's reveal still works
        vm.prank(alice);
        loader.revealAndLoad(executions, proof, secret);
    }

    /// @notice Demonstrates that commitments from different users don't collide
    function test_MultipleUsersCanCommitIndependently() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        (
            Execution[] memory executions,
            bytes memory proof
        ) = _createSimpleExecution(rollupId);

        bytes32 aliceSecret = keccak256("alice_secret");
        bytes32 builderSecret = keccak256("builder_secret");

        bytes32 aliceCommitment = loader.makeCommitment(
            executions,
            proof,
            aliceSecret
        );
        bytes32 builderCommitment = loader.makeCommitment(
            executions,
            proof,
            builderSecret
        );

        // Different secrets produce different commitments
        assertTrue(aliceCommitment != builderCommitment);

        // Both can commit independently
        vm.prank(alice);
        loader.commit(aliceCommitment);

        vm.prank(builder);
        loader.commit(builderCommitment);

        // Both commitments are stored
        assertTrue(loader.commitments(aliceCommitment) != 0);
        assertTrue(loader.commitments(builderCommitment) != 0);
    }

    /*//////////////////////////////////////////////////////////////
                    CROSS-ROLLUP EXECUTION TEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Tests the full flow: commit → reveal → execute across rollups
    /// @dev This is the canonical integration test that the original repo was missing
    function test_FullFlow_CommitRevealExecute() public {
        // Setup: create a rollup and deploy proxy
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.createL2ProxyContract(
            address(target),
            rollupId
        );

        (
            Execution[] memory executions,
            bytes memory proof
        ) = _createSimpleExecution(rollupId);
        bytes32 secret = keccak256("full_flow_secret");

        // Phase 1: Commit (block N)
        bytes32 commitment = loader.makeCommitment(executions, proof, secret);
        vm.prank(alice);
        loader.commit(commitment);

        // Phase 2: Wait (block N+1)
        vm.roll(block.number + 1);

        // Phase 3: Reveal and load (block N+1)
        vm.prank(alice);
        loader.revealAndLoad(executions, proof, secret);

        // Phase 4: Execute via proxy — the execution was loaded, so this should work
        bytes memory callData = abi.encodeCall(Target.setValue, (42));
        (bool success, ) = proxyAddr.call(callData);
        assertTrue(
            success,
            "Execution via proxy should succeed after commit-reveal load"
        );

        // Verify state transition happened
        (, , bytes32 stateRoot, ) = rollups.rollups(rollupId);
        assertEq(
            stateRoot,
            keccak256("state1"),
            "Rollup state should have transitioned"
        );
    }
}
