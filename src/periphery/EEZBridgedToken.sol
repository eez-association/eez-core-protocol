// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EEZToken} from "./defiMock/EEZToken.sol";

/// @notice Bridge-issued ERC20 with EEZ address translation. Test-only periphery.
/// @dev Mint/burn arguments are canonical destination-chain addresses supplied by
/// the bridge. ERC20 address arguments inherit EEZToken's caller-relative semantics.
contract EEZBridgedToken is EEZToken {
    address public immutable BRIDGE;
    uint8 private immutable _tokenDecimals;

    error OnlyBridge();
    error InvalidBridge();

    constructor(
        address manager_,
        address bridge_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    )
        EEZToken(manager_, name_, symbol_, address(0), 0)
    {
        if (bridge_ == address(0)) revert InvalidBridge();
        BRIDGE = bridge_;
        _tokenDecimals = decimals_;
    }

    modifier onlyBridge() {
        if (msg.sender != BRIDGE) revert OnlyBridge();
        _;
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
