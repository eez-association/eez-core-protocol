// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Valueless test token with an unrestricted faucet. Never use for real assets.
contract MockBalancerToken is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
