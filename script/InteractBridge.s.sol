// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Bridge} from "../src/periphery/Bridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BridgeEtherScript — Bridge ETH to a destination rollup
/// @dev Usage:
///   forge script script/InteractBridge.s.sol:BridgeEtherScript \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address,uint64,address,uint256)" $BRIDGE $ROLLUP_ID $DESTINATION $AMOUNT_WEI
contract BridgeEtherScript is Script {
    function run(address bridge, uint64 rollupId, address destination, uint256 amount) external {
        vm.startBroadcast();

        Bridge(bridge).bridgeEther{value: amount}(rollupId, destination);
        console.log("Bridged %s wei to rollup %s for %s", amount, rollupId, destination);

        vm.stopBroadcast();
    }
}

/// @title BridgeTokensScript — Bridge ERC20 tokens to a destination rollup
/// @dev Usage:
///   forge script script/InteractBridge.s.sol:BridgeTokensScript \
///     --rpc-url $RPC --broadcast --private-key $PK \
///     --sig "run(address,address,uint256,uint64)" $BRIDGE $TOKEN $AMOUNT $ROLLUP_ID
contract BridgeTokensScript is Script {
    function run(address bridge, address token, uint256 amount, uint64 rollupId) external {
        vm.startBroadcast();

        IERC20(token).approve(bridge, amount);
        Bridge(bridge).bridgeTokens(token, amount, rollupId, msg.sender);
        console.log("Bridged %s tokens to rollup %s", amount, rollupId);

        vm.stopBroadcast();
    }
}
