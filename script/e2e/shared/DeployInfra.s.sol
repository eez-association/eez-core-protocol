// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../src/EEZ.sol";
import {Rollup} from "../../../src/rollupContract/Rollup.sol";
import {IProofSystem} from "../../../src/interfaces/IProofSystem.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";

/// @notice Mock proof system that accepts all proofs. Used in e2e flows where the test
///         orchestrator drives execution and we don't want real proof verification.
contract AcceptAllProofSystem is IProofSystem {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

/// @title DeployEEZL1
/// @notice Deploys AcceptAllProofSystem + EEZ + creates L2 rollup (id=1).
/// @dev The first registered rollup gets id 0 = MAINNET_ROLLUP_ID, which is unpostable
///      because the strict-increasing rollupIds check in postAndVerifyBatch rejects 0. So we burn
///      id 0 with a throwaway rollup, then register the L2 rollup at id 1.
/// Outputs: ROLLUPS, PROOF_SYSTEM, L2_MANAGER, L2_ROLLUP_ID
contract DeployEEZL1 is Script {
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function run() external {
        vm.startBroadcast();

        AcceptAllProofSystem ps = new AcceptAllProofSystem();
        EEZ rollups = new EEZ();

        // registerRollup skips id 0 (MAINNET_ROLLUP_ID), so the first registered rollup
        // lands at id 1.
        // Create L2 manager + register at id 1.
        address[] memory psList2 = new address[](1);
        psList2[0] = address(ps);
        bytes32[] memory vks2 = new bytes32[](1);
        vks2[0] = DEFAULT_VK;
        Rollup l2Manager = new Rollup(address(rollups), msg.sender, 1, psList2, vks2);
        uint256 rid = rollups.registerRollup(address(l2Manager), keccak256("l2-initial-state"));
        require(rid == 1, "expected L2 rollupId = 1");

        console.log("PROOF_SYSTEM=%s", address(ps));
        console.log("ROLLUPS=%s", address(rollups));
        console.log("L2_MANAGER=%s", address(l2Manager));
        console.log("L2_ROLLUP_ID=1");

        vm.stopBroadcast();
    }
}

/// @title DeployManagerL2
/// @notice Deploys EEZL2 for the given rollup ID / system address.
/// Outputs: MANAGER_L2
contract DeployManagerL2 is Script {
    function run(uint256 rollupId, address systemAddress) external {
        vm.startBroadcast();
        EEZL2 manager = new EEZL2(rollupId, systemAddress);
        console.log("MANAGER_L2=%s", address(manager));
        vm.stopBroadcast();
    }
}
