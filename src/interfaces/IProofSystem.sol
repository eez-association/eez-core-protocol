// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IProofSystem
/// @notice Interface for proof-verifying systems referenced from a per-rollup `IRollupContract`
///         contract's vkey map.
/// @dev A proof system is any contract that can check `(proof, publicInputsHash)` — ZK, ECDSA,
///      etc. There is no central registry; each rollup owner is responsible for vetting which
///      proof system addresses are added to their rollup's allowed set.
interface IProofSystem {
    /// @notice Verifies a proof against a single public input hash
    /// @param proof The proof bytes (interpretation is proof-system-specific)
    /// @param publicInputsHash Hash of all public inputs for the proof
    /// @return valid True if the proof is valid, false otherwise
    function verify(bytes calldata proof, bytes32 publicInputsHash) external view returns (bool valid);
}
