// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
    address public signer;

    constructor(address initialOwner, address initialSigner) Ownable(initialOwner) {
        signer = initialSigner;
    }

    function setSigner(address newSigner) external onlyOwner {
        signer = newSigner;
    }

    function verify(bytes calldata proof, bytes32 publicInputsHash) external view returns (bool) {
        address recovered = ECDSA.recover(publicInputsHash, proof);
        return recovered == signer;
    }
}
