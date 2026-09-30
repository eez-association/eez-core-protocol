// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IProofSystem} from "../interfaces/IProofSystem.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ECDSAProofSystem
/// @notice Temporary proof system that uses ECDSA signature recovery instead of a ZK proof.
/// @dev The `proof` parameter is a 65-byte ECDSA signature encoded as `abi.encodePacked(r, s, v)`:
///   - r: bytes32 — the R component of the signature
///   - s: bytes32 — the S component of the signature
///   - v: uint8   — the recovery identifier. Must be 27 or 28.
///     Some signing tools/libraries produce v as 0 or 1 (EIP-2098 / legacy). OZ's ECDSA.recover
///     does NOT normalize these values — callers must ensure v is 27 or 28 before encoding the proof.
///
/// The `publicInputsHash` is signed directly as a raw bytes32 digest (no EIP-191 prefix).
contract ECDSAProofSystem is IProofSystem, Ownable {
    // ──────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────

    /// @notice Address whose signatures are accepted as proofs.
    address public signer;

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted on initialization (oldSigner is zero) and every signer update.
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    /// @notice Initializes ownership and the signer accepted by this proof system.
    /// @param initialOwner Address authorized to replace the signer.
    /// @param initialSigner Initial signing address; zero disables successful verification.
    constructor(address initialOwner, address initialSigner) Ownable(initialOwner) {
        signer = initialSigner;
        emit SignerUpdated(address(0), initialSigner);
    }

    // ──────────────────────────────────────────────
    //  Owner-only management
    // ──────────────────────────────────────────────

    /// @notice Replaces the accepted signer; callable only by the owner.
    /// @param newSigner Replacement signing address; zero disables successful verification.
    function setSigner(address newSigner) external onlyOwner {
        address oldSigner = signer;
        signer = newSigner;
        emit SignerUpdated(oldSigner, newSigner);
    }

    // ──────────────────────────────────────────────
    //  Proof verification
    // ──────────────────────────────────────────────

    /// @notice Checks whether a proof recovers to the configured signer.
    /// @dev Uses the raw digest without an Ethereum signed-message prefix. Malformed signatures
    ///      revert in ECDSA.recover; a valid signature from another signer returns false.
    /// @param proof A 65-byte signature encoded as abi.encodePacked(r, s, v), with v equal to 27 or 28.
    /// @param publicInputsHash Raw public-input digest signed by the prover.
    /// @return True if the recovered address equals signer, false otherwise.
    function verify(bytes calldata proof, bytes32 publicInputsHash) external view returns (bool) {
        address recovered = ECDSA.recover(publicInputsHash, proof);
        return recovered == signer;
    }
}
