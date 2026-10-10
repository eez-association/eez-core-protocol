// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Rollups, Action, ActionType, Execution, StateDelta, StateCommitment} from "../src/Rollups.sol";
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

/// @title GasBenchmarkTest
/// @notice Gas benchmarks for key Rollups operations
/// @dev Run with `forge test --match-contract GasBenchmarkTest --gas-report -vv`
///      Results provide baseline gas costs for optimization work.
contract GasBenchmarkTest is Test {
    Rollups public rollups;
    MockZKVerifier public verifier;

    address public alice = makeAddr("alice");
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function setUp() public {
        verifier = new MockZKVerifier();
        rollups = new Rollups(address(verifier), 1);
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _buildSingleExecution(
        uint256 rollupId,
        address target,
        bytes memory callData,
        bytes32 currentState,
        bytes32 newState
    ) internal view returns (Execution[] memory) {
        address proxyAddr = rollups.computeL2ProxyAddress(
            target,
            rollupId,
            block.chainid
        );

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: target,
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: proxyAddr,
            sourceRollup: rollupId,
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

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: rollupId,
            currentState: currentState,
            newState: newState,
            etherDelta: 0
        });

        Execution[] memory executions = new Execution[](1);
        executions[0].stateDeltas = stateDeltas;
        executions[0].actionHash = keccak256(abi.encode(action));
        executions[0].nextAction = resultAction;
        return executions;
    }

    function _buildMultiRollupExecution(
        uint256[] memory rollupIds,
        address target,
        bytes memory callData,
        bytes32[] memory currentStates,
        bytes32[] memory newStates
    ) internal view returns (Execution[] memory) {
        address proxyAddr = rollups.computeL2ProxyAddress(
            target,
            rollupIds[0],
            block.chainid
        );

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupIds[0],
            destination: target,
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: proxyAddr,
            sourceRollup: rollupIds[0],
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

        StateDelta[] memory stateDeltas = new StateDelta[](rollupIds.length);
        for (uint256 i = 0; i < rollupIds.length; i++) {
            stateDeltas[i] = StateDelta({
                rollupId: rollupIds[i],
                currentState: currentStates[i],
                newState: newStates[i],
                etherDelta: 0
            });
        }

        Execution[] memory executions = new Execution[](1);
        executions[0].stateDeltas = stateDeltas;
        executions[0].actionHash = keccak256(abi.encode(action));
        executions[0].nextAction = resultAction;
        return executions;
    }

    /*//////////////////////////////////////////////////////////////
                    ROLLUP CREATION BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas cost of creating a single rollup
    function test_Benchmark_CreateRollup() public {
        uint256 gasBefore = gasleft();
        rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("createRollup gas", gasUsed);
    }

    /// @notice Gas cost of creating rollup #100 (storage growth)
    function test_Benchmark_CreateRollup_100th() public {
        for (uint256 i = 0; i < 99; i++) {
            rollups.createRollup(bytes32(uint256(i)), DEFAULT_VK, alice);
        }
        uint256 gasBefore = gasleft();
        rollups.createRollup(bytes32(uint256(99)), DEFAULT_VK, alice);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("createRollup #100 gas", gasUsed);
    }

    /*//////////////////////////////////////////////////////////////
                  PROXY DEPLOYMENT BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas cost of deploying an L2 proxy contract
    function test_Benchmark_CreateL2ProxyContract() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        uint256 gasBefore = gasleft();
        rollups.createL2ProxyContract(address(this), rollupId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("createL2ProxyContract gas", gasUsed);
    }

    /// @notice Gas cost of computing a proxy address (view function)
    function test_Benchmark_ComputeL2ProxyAddress() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        uint256 gasBefore = gasleft();
        rollups.computeL2ProxyAddress(address(this), rollupId, block.chainid);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("computeL2ProxyAddress gas", gasUsed);
    }

    /*//////////////////////////////////////////////////////////////
                EXECUTION LOADING BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas cost of loading 1 execution with 1 state delta
    function test_Benchmark_LoadL2Executions_1x1() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        Execution[] memory executions = _buildSingleExecution(
            rollupId,
            address(this),
            abi.encode(0),
            bytes32(0),
            keccak256("s1")
        );

        uint256 gasBefore = gasleft();
        rollups.loadL2Executions(executions, "proof");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("loadL2Executions (1 exec, 1 delta) gas", gasUsed);
    }

    /// @notice Gas cost of loading 1 execution with 3 state deltas (3 rollups)
    function test_Benchmark_LoadL2Executions_1x3() public {
        uint256[] memory ids = new uint256[](3);
        bytes32[] memory currentStates = new bytes32[](3);
        bytes32[] memory newStates = new bytes32[](3);

        for (uint256 i = 0; i < 3; i++) {
            ids[i] = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
            currentStates[i] = bytes32(0);
            newStates[i] = keccak256(abi.encode("state", i));
        }

        Execution[] memory executions = _buildMultiRollupExecution(
            ids,
            address(this),
            abi.encode(0),
            currentStates,
            newStates
        );

        uint256 gasBefore = gasleft();
        rollups.loadL2Executions(executions, "proof");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("loadL2Executions (1 exec, 3 deltas) gas", gasUsed);
    }

    /// @notice Gas cost of loading 1 execution with 5 state deltas (5 rollups)
    function test_Benchmark_LoadL2Executions_1x5() public {
        uint256[] memory ids = new uint256[](5);
        bytes32[] memory currentStates = new bytes32[](5);
        bytes32[] memory newStates = new bytes32[](5);

        for (uint256 i = 0; i < 5; i++) {
            ids[i] = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
            currentStates[i] = bytes32(0);
            newStates[i] = keccak256(abi.encode("state", i));
        }

        Execution[] memory executions = _buildMultiRollupExecution(
            ids,
            address(this),
            abi.encode(0),
            currentStates,
            newStates
        );

        uint256 gasBefore = gasleft();
        rollups.loadL2Executions(executions, "proof");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("loadL2Executions (1 exec, 5 deltas) gas", gasUsed);
    }

    /// @notice Gas cost of loading 10 executions with 1 state delta each
    function test_Benchmark_LoadL2Executions_10x1() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        Execution[] memory executions = new Execution[](10);
        for (uint256 i = 0; i < 10; i++) {
            address proxyAddr = rollups.computeL2ProxyAddress(
                address(this),
                rollupId,
                block.chainid
            );

            Action memory action = Action({
                actionType: ActionType.CALL,
                rollupId: rollupId,
                destination: address(this),
                value: 0,
                data: abi.encode(i),
                failed: false,
                sourceAddress: proxyAddr,
                sourceRollup: rollupId,
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

            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: rollupId,
                currentState: bytes32(0),
                newState: keccak256(abi.encode("state", i)),
                etherDelta: 0
            });

            executions[i].stateDeltas = stateDeltas;
            executions[i].actionHash = keccak256(abi.encode(action));
            executions[i].nextAction = resultAction;
        }

        uint256 gasBefore = gasleft();
        rollups.loadL2Executions(executions, "proof");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint(
            "loadL2Executions (10 execs, 1 delta each) gas",
            gasUsed
        );
    }

    /*//////////////////////////////////////////////////////////////
                   POSTBATCH BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas cost of postBatch for 1 rollup
    function test_Benchmark_PostBatch_1Rollup() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        StateCommitment[] memory commitments = new StateCommitment[](1);
        commitments[0] = StateCommitment({
            rollupId: rollupId,
            newState: keccak256("new_state"),
            etherIncrement: 0
        });

        uint256 gasBefore = gasleft();
        rollups.postBatch(commitments, 0, "", "proof");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("postBatch (1 rollup) gas", gasUsed);
    }

    /// @notice Gas cost of postBatch for 5 rollups with ETH rebalance
    function test_Benchmark_PostBatch_5Rollups() public {
        uint256[] memory ids = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            ids[i] = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        }

        // Fund first rollup so it can transfer out
        rollups.depositEther{value: 100 ether}(ids[0]);

        StateCommitment[] memory commitments = new StateCommitment[](5);
        int256 totalIncrement = 0;
        for (uint256 i = 0; i < 5; i++) {
            int256 increment;
            if (i == 0) {
                increment = -40 ether;
            } else {
                increment = 10 ether;
            }
            totalIncrement += increment;
            commitments[i] = StateCommitment({
                rollupId: ids[i],
                newState: keccak256(abi.encode("state", i)),
                etherIncrement: increment
            });
        }
        require(
            totalIncrement == 0,
            "Test invariant: ether increments must sum to zero"
        );

        uint256 gasBefore = gasleft();
        rollups.postBatch(commitments, 0, "", "proof");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint(
            "postBatch (5 rollups, ETH rebalance) gas",
            gasUsed
        );
    }

    /*//////////////////////////////////////////////////////////////
                     ETH OPERATIONS BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas cost of depositing ETH to a rollup
    function test_Benchmark_DepositEther() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        uint256 gasBefore = gasleft();
        rollups.depositEther{value: 1 ether}(rollupId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("depositEther gas", gasUsed);
    }

    /*//////////////////////////////////////////////////////////////
             EXECUTION TABLE GROWTH STRESS TEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Measures how gas cost grows when loading many executions
    ///         under the same actionHash (related to the O(n) lookup issue)
    function test_Benchmark_ExecutionLookupScaling() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address proxyAddr = rollups.computeL2ProxyAddress(
            address(this),
            rollupId,
            block.chainid
        );

        // Same action but different state snapshots — simulates speculative loading
        bytes memory commonCallData = abi.encode(uint256(42));
        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(this),
            value: 0,
            data: commonCallData,
            failed: false,
            sourceAddress: proxyAddr,
            sourceRollup: rollupId,
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

        keccak256(abi.encode(action)); // action hash computed but not needed for loading

        // Load N executions with the same actionHash but different state roots
        uint256[] memory gasCosts = new uint256[](5);
        uint256[] memory batchSizes = new uint256[](5);
        batchSizes[0] = 1;
        batchSizes[1] = 5;
        batchSizes[2] = 10;
        batchSizes[3] = 20;
        batchSizes[4] = 50;

        for (uint256 batch = 0; batch < batchSizes.length; batch++) {
            // Reset rollup state for each batch
            uint256 rid = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
            address pAddr = rollups.computeL2ProxyAddress(
                address(this),
                rid,
                block.chainid
            );

            Action memory batchAction = Action({
                actionType: ActionType.CALL,
                rollupId: rid,
                destination: address(this),
                value: 0,
                data: commonCallData,
                failed: false,
                sourceAddress: pAddr,
                sourceRollup: rid,
                scope: new uint256[](0)
            });

            bytes32 batchActionHash = keccak256(abi.encode(batchAction));

            Execution[] memory execs = new Execution[](batchSizes[batch]);
            for (uint256 i = 0; i < batchSizes[batch]; i++) {
                StateDelta[] memory deltas = new StateDelta[](1);
                deltas[0] = StateDelta({
                    rollupId: rid,
                    currentState: keccak256(abi.encode("snapshot", i)),
                    newState: keccak256(abi.encode("result", i)),
                    etherDelta: 0
                });

                execs[i].stateDeltas = deltas;
                execs[i].actionHash = batchActionHash;
                execs[i].nextAction = resultAction;
            }

            uint256 gasBefore = gasleft();
            rollups.loadL2Executions(execs, "proof");
            gasCosts[batch] = gasBefore - gasleft();

            emit log_named_uint(
                string(
                    abi.encodePacked(
                        "loadL2Executions (",
                        vm.toString(batchSizes[batch]),
                        " execs, same actionHash) gas"
                    )
                ),
                gasCosts[batch]
            );
        }

        // Log per-execution cost to show scaling
        for (uint256 i = 0; i < batchSizes.length; i++) {
            uint256 perExecCost = gasCosts[i] / batchSizes[i];
            emit log_named_uint(
                string(
                    abi.encodePacked(
                        "per-execution cost at ",
                        vm.toString(batchSizes[i]),
                        " execs"
                    )
                ),
                perExecCost
            );
        }
    }
}
