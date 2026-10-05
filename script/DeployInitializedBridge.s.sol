// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Bridge} from "../src/periphery/Bridge.sol";

/// @notice The existing bridge with initialization performed in its creation transaction.
/// @dev This adds constructor logic only. No deployer/factory contract remains on-chain.
contract InitializedBridge is Bridge {
    constructor(address manager_, uint64 rollupId_, address admin_) {
        _initialize(manager_, rollupId_, admin_);
    }
}

/// @notice Deploy one initialized bridge. Run once against each chain, then link
/// counterpart addresses through Bridge.setCanonicalBridgeAddress as their admin.
contract DeployInitializedBridge is Script {
    function run(address manager, uint64 rollupId, address admin) external returns (Bridge bridge) {
        vm.startBroadcast();
        bridge = new InitializedBridge(manager, rollupId, admin);
        vm.stopBroadcast();
        console.log("BRIDGE=%s", address(bridge));
    }
}
