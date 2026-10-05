// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Bridge} from "./Bridge.sol";
import {EEZBridgedToken} from "./EEZBridgedToken.sol";

/// @notice Constructor-initialized bridge that natively creates EEZ-aware tokens.
/// @dev Reuses Bridge's authentication, lock/mint, burn/release and native paths.
/// This remains test-only periphery with Bridge's two-chain trust assumptions.
contract EEZBridge is Bridge {
    error InvalidManager();

    constructor(address manager_, uint64 rollupId_, address admin_) {
        if (manager_.code.length == 0) revert InvalidManager();
        _initialize(manager_, rollupId_, admin_);
        emit Initialized(manager_, rollupId_, admin_);
    }

    function _deployWrappedToken(
        bytes32 salt,
        string calldata name,
        string calldata symbol,
        uint8 tokenDecimals
    )
        internal
        override
        returns (address)
    {
        return address(new EEZBridgedToken{salt: salt}(address(manager), address(this), name, symbol, tokenDecimals));
    }
}
