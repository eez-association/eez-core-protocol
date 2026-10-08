// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {MockBalancerToken} from "../../src/periphery/balancer/mock/MockBalancerToken.sol";
import {MockBalancerV3Vault} from "../../src/periphery/balancer/mock/MockBalancerV3Vault.sol";

/// @notice Deploy the test token and flash-loan Vault exclusively on Chiado.
contract ChiadoMock is Script {
    function run() external returns (MockBalancerToken token, MockBalancerV3Vault vault) {
        require(block.chainid == 10200, "Chiado only");
        uint256 liquidity = vm.envOr("MOCK_BALANCER_LIQUIDITY", uint256(1_000_000e6));
        vm.startBroadcast();
        token = new MockBalancerToken();
        // Foundry's broadcast sender owns the Vault, not the script contract.
        (, address sender,) = vm.readCallers();
        vault = new MockBalancerV3Vault(token, sender);
        vault.setLiquidity(liquidity);
        vm.stopBroadcast();
        require(token.balanceOf(address(vault)) == liquidity, "Wrong balance");
        require(vault.getReservesOf(token) == liquidity, "Wrong reserves");
        console.log("MOCK_TOKEN", address(token));
        console.log("MOCK_VAULT", address(vault));
        console.log("MOCK_OWNER", vault.owner());
        console.log("MOCK_LIQUIDITY_BASE_UNITS", liquidity);
    }
}
