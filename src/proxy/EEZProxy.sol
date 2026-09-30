// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Transparent proxy for EEZ, whose initial persistent state is entirely zero.
/// @dev EEZ has no initializer: its recovery address and proxy bytecode hash are implementation
///      immutables. Explicitly allow empty initialization data under OpenZeppelin v5.6.1.
contract EEZProxy is TransparentUpgradeableProxy {
    constructor(
        address implementation,
        address upgradeOwner
    )
        TransparentUpgradeableProxy(implementation, upgradeOwner, "")
    {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}
