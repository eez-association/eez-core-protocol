// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Bridge} from "../src/periphery/Bridge.sol";

/// @notice The existing bridge with initialization performed in its creation transaction.
/// @dev Direct test fixture with mutable counterpart linking; no deployer/factory remains on-chain.
contract InitializedBridge is Bridge {
    constructor(address manager_, uint64 rollupId_, address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        _initializeBridge(manager_, address(0), rollupId_);
    }

    /// @dev Mutable linking is retained only for this direct test/demo fixture.
    function setCanonicalBridgeAddress(address counterpart) external onlyAdmin {
        canonicalBridgeAddress = counterpart;
        emit CanonicalBridgeAddressSet(counterpart);
    }
}

/// @notice Deploy one initialized bridge. Run once against each chain, then link
/// counterpart addresses through InitializedBridge.setCanonicalBridgeAddress as their admin.
contract DeployInitializedBridge is Script {
    function run(address manager, uint64 rollupId, address admin) external returns (Bridge bridge) {
        vm.startBroadcast();
        bridge = new InitializedBridge(manager, rollupId, admin);
        vm.stopBroadcast();
        console.log("BRIDGE=%s", address(bridge));
    }
}
