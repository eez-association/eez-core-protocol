// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {deployRollup} from "../../../../deployment/RollupDeployment.sol";

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../src/EEZ.sol";
import {Rollup} from "../../../../src/rollupContract/Rollup.sol";
import {IProofSystem} from "../../../../src/interfaces/IProofSystem.sol";
import {EEZL2} from "../../../../src/L2/EEZL2.sol";

/// @notice Mock proof system that accepts all proofs. Used in e2e flows where the test
///         orchestrator drives execution and we don't want real proof verification.
contract AcceptAllProofSystem is IProofSystem {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

/// @title DeployEEZL1
/// @notice Deploys AcceptAllProofSystem + EEZ, registers the L2 rollup and outputs its assigned ID.
/// @dev Id 0 is MAINNET_ROLLUP_ID and is never assigned by registerRollup.
/// Outputs: ROLLUPS, PROOF_SYSTEM, L2_MANAGER, L2_ROLLUP_ID
contract DeployEEZL1 is Script {
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function run() external {
        vm.startBroadcast();

        AcceptAllProofSystem ps = new AcceptAllProofSystem();
        EEZ rollups = new EEZ(msg.sender);

        // Create the L2 manager and use the ID assigned by the registry.
        address[] memory psList2 = new address[](1);
        psList2[0] = address(ps);
        bytes32[] memory vks2 = new bytes32[](1);
        vks2[0] = DEFAULT_VK;
        Rollup l2Manager = deployRollup(address(rollups), msg.sender, 1, psList2, vks2);
        uint256 rid = rollups.registerRollup(address(l2Manager), keccak256("l2-initial-state"));

        console.log("PROOF_SYSTEM=%s", address(ps));
        console.log("ROLLUPS=%s", address(rollups));
        console.log("L2_MANAGER=%s", address(l2Manager));
        console.log("L2_ROLLUP_ID=%s", rid);

        vm.stopBroadcast();
    }
}

/// @title DeployManagerL2
/// @notice Deploys EEZL2 for the given rollup ID, system address and recovery recipient.
/// Outputs: MANAGER_L2
contract DeployManagerL2 is Script {
    function run(uint64 rollupId, address systemAddress, address recoveryAddress) external {
        vm.startBroadcast();
        EEZL2 manager = new EEZL2(rollupId, systemAddress, false, recoveryAddress);
        console.log("MANAGER_L2=%s", address(manager));
        vm.stopBroadcast();
    }
}
