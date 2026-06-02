// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title WrappedToken
/// @notice ERC20 representation of a token bridged from another rollup
/// @dev Deployed by the Bridge via CREATE2. Only the Bridge can mint and burn.
///      ILLUSTRATIVE EXAMPLE (periphery) — not production-hardened.
contract WrappedToken is ERC20, ERC20Permit {
    address public immutable BRIDGE;
    uint8 private immutable _tokenDecimals;

    error OnlyBridge();

    modifier onlyBridge() {
        if (msg.sender != BRIDGE) revert OnlyBridge();
        _;
    }

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address bridge_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        BRIDGE = bridge_;
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external onlyBridge {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyBridge {
        _burn(from, amount);
    }
}
