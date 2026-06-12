// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IProofSystem} from "../../src/interfaces/IProofSystem.sol";

/// @notice Mock proof system. Default: accepts any proof without checking the hash.
/// @dev With `shouldVerify` on, only the pinned `expectedPublicInputsHash` is accepted —
///      so tests can assert WHAT the registry feeds the prover. Enabling verification
///      without pinning a hash rejects everything (real hashes never equal 0).
contract MockProofSystem is IProofSystem {
    /// @notice When false (default), `verify` accepts without checking the hash.
    bool public shouldVerify;

    /// @notice The only publicInputsHash accepted while `shouldVerify` is on.
    bytes32 public expectedPublicInputsHash;

    function setShouldVerify(bool _shouldVerify) external {
        shouldVerify = _shouldVerify;
    }

    /// @notice Pins the exact hash `verify` must see, and enables verification.
    function setExpectedPublicInputsHash(bytes32 expected) external {
        expectedPublicInputsHash = expected;
        shouldVerify = true;
    }

    function verify(bytes calldata, bytes32 publicInputsHash) external view override returns (bool) {
        if (!shouldVerify) return true;
        return publicInputsHash == expectedPublicInputsHash;
    }
}
