// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IProofSystem} from "../../src/interfaces/IProofSystem.sol";

/// @notice Mock proof system that returns a configurable verify result. Default: always succeeds.
contract MockProofSystem is IProofSystem {
    bool public shouldVerify = true;

    function setVerifyResult(bool _shouldVerify) external {
        shouldVerify = _shouldVerify;
    }

    function verify(bytes calldata, bytes32) external view override returns (bool) {
        return shouldVerify;
    }
}
