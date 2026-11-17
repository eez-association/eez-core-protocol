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
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        _initializeBridge(manager_, address(0), rollupId_);
    }

    /// @dev Mutable linking is retained only for this direct test/demo fixture.
    function setCanonicalBridgeAddress(address counterpart) external onlyAdmin {
        canonicalBridgeAddress = counterpart;
        emit CanonicalBridgeAddressSet(counterpart);
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
        return
            address(new EEZBridgedToken{salt: salt}(address(EEZContract), address(this), name, symbol, tokenDecimals));
    }
}
