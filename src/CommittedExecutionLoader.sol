// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Rollups, Execution} from "./Rollups.sol";

/// @title CommittedExecutionLoader
/// @notice Commit-reveal wrapper for loadL2Executions to prevent builder front-running
/// @dev Prevents block builders from inspecting execution table contents before inclusion,
///      mitigating cross-domain MEV extraction via execution table reordering.
///
///      The pattern is adapted from ENS commit-reveal — the same cryptographic
///      primitive used to prevent domain name front-running. Here, it prevents builders
///      from front-running or restructuring user execution tables for MEV extraction.
///
///      Flow:
///        1. User computes commitment = keccak256(executionsHash, proofHash, secret)
///        2. User submits commitment on-chain (opaque bytes32, content hidden)
///        3. After MIN_COMMITMENT_AGE blocks, user reveals executions + proof + secret
///        4. Contract verifies commitment matches, then forwards to Rollups.loadL2Executions()
///
///      The builder sees the commitment in block N but cannot extract the execution table
///      contents until the reveal in block N+1 (or later), by which time the commitment
///      is already included and the builder cannot reorder against it.
///
/// @dev Adapted from ENS/Veil commit-reveal pattern.
///
/// NOTE: In the current sync-rollups architecture, the block builder is typically
/// the entity constructing execution tables (since loadL2Executions requires knowing
/// pending L1 state). This means commit-reveal protects a submitter from the builder,
/// but in practice the submitter and builder are often the same entity. This contract
/// becomes fully effective under a decentralized prover market where independent
/// parties can construct and submit proven execution tables.
contract CommittedExecutionLoader {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Rollups contract to forward executions to
    Rollups public immutable rollups;

    /// @notice Minimum blocks between commit and reveal
    /// @dev 1 block ensures the commitment is included before the builder sees the content.
    ///      This is the minimum to prevent same-block extraction.
    uint256 public constant MIN_COMMITMENT_AGE = 1;

    /// @notice Maximum blocks between commit and reveal
    /// @dev 256 blocks (~51 min at 12s/slot) stays within the BLOCKHASH opcode window.
    ///      Commitments older than this are considered expired and can be re-used.
    uint256 public constant MAX_COMMITMENT_AGE = 256;

    /// @notice Mapping from commitment hash to the block number it was submitted
    mapping(bytes32 => uint256) public commitments;

    /// @notice Mapping from commitment hash to the address that submitted it
    /// @dev Only the original committer can reveal, preventing leaked-secret exploitation
    mapping(bytes32 => address) public commitmentOwner;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a commitment already exists and hasn't expired
    error AlreadyCommitted();

    /// @notice Thrown when reveal is attempted too soon after commit
    error CommitmentTooNew();

    /// @notice Thrown when reveal is attempted too late after commit
    error CommitmentTooOld();

    /// @notice Thrown when no matching commitment is found
    error CommitmentNotFound();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new execution table commitment is submitted
    /// @param commitment The commitment hash
    /// @param committer The address that submitted the commitment
    event ExecutionCommitted(
        bytes32 indexed commitment,
        address indexed committer
    );

    /// @notice Emitted when a commitment is revealed and executions are loaded
    /// @param commitment The commitment hash that was revealed
    /// @param executionCount The number of executions loaded
    event ExecutionRevealed(bytes32 indexed commitment, uint256 executionCount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _rollups The Rollups contract address
    constructor(address _rollups) {
        rollups = Rollups(_rollups);
    }

    /*//////////////////////////////////////////////////////////////
                           COMMIT-REVEAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Compute a commitment hash for an execution table
    /// @dev Pure function — can be called off-chain to prepare the commitment
    /// @param executions The executions to commit to
    /// @param proof The ZK proof to commit to
    /// @param secret A random 256-bit secret known only to the committer
    /// @return The commitment hash
    function makeCommitment(
        Execution[] calldata executions,
        bytes calldata proof,
        bytes32 secret
    ) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(abi.encode(executions)),
                    keccak256(proof),
                    secret
                )
            );
    }

    /// @notice Submit an opaque commitment to an execution table
    /// @dev The commitment is a hash that hides the execution table contents.
    ///      The builder includes this in block N but cannot extract the content
    ///      until the reveal in block N+1 or later.
    /// @param commitment The commitment hash (from makeCommitment)
    function commit(bytes32 commitment) external {
        if (
            commitments[commitment] != 0 &&
            block.number <= commitments[commitment] + MAX_COMMITMENT_AGE
        ) {
            revert AlreadyCommitted();
        }
        commitments[commitment] = block.number;
        commitmentOwner[commitment] = msg.sender;
        emit ExecutionCommitted(commitment, msg.sender);
    }

    /// @notice Reveal an execution table and load it into the Rollups contract
    /// @dev Verifies the commitment matches, enforces timing constraints,
    ///      then forwards to Rollups.loadL2Executions()
    /// @param executions The executions (must match the committed hash)
    /// @param proof The ZK proof (must match the committed hash)
    /// @param secret The secret used in the original commitment
    function revealAndLoad(
        Execution[] calldata executions,
        bytes calldata proof,
        bytes32 secret
    ) external {
        bytes32 commitment = keccak256(
            abi.encode(
                keccak256(abi.encode(executions)),
                keccak256(proof),
                secret
            )
        );

        uint256 committedAt = commitments[commitment];

        if (committedAt == 0) revert CommitmentNotFound();
        if (msg.sender != commitmentOwner[commitment])
            revert CommitmentNotFound();
        if (block.number < committedAt + MIN_COMMITMENT_AGE)
            revert CommitmentTooNew();
        if (block.number > committedAt + MAX_COMMITMENT_AGE)
            revert CommitmentTooOld();

        delete commitments[commitment];
        delete commitmentOwner[commitment];

        // Forward to Rollups contract — ZK proof verification happens there
        rollups.loadL2Executions(executions, proof);

        emit ExecutionRevealed(commitment, executions.length);
    }
}
