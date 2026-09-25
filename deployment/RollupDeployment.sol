// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Rollup} from "../src/rollupContract/Rollup.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Shared proxy deployment used by fixtures and devnet scripts.
/// @dev The operational owner also owns this proxy's ProxyAdmin. Use DeployRollup
///      when these roles need distinct owners.
function deployRollup(
    address EEZContract,
    address owner,
    uint256 threshold,
    address[] memory proofSystems,
    bytes32[] memory vkeys
)
    returns (Rollup)
{
    Rollup implementation = new Rollup(EEZContract);
    return Rollup(
        address(
            new TransparentUpgradeableProxy(
                address(implementation),
                owner,
                abi.encodeCall(Rollup.initialize, (owner, threshold, proofSystems, vkeys))
            )
        )
    );
}
