// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpgradeBase} from "../deployment/Upgrade.s.sol";

/// @notice Upgrade a bridge as its ProxyAdmin owner, optionally executing a migration.
/// @dev Review storage layout and token creation policy before running; these checks do not prove compatibility.
contract UpgradeBridge is UpgradeBase {
    function run(address proxy, address implementation, bytes calldata data) external {
        _upgrade(proxy, implementation, data);
    }
}
