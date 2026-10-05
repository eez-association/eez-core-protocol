// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EEZToken} from "./EEZToken.sol";

/// @title EEZWrappedNative
/// @notice Experimental native-value wrapper with EEZ ERC20 address translation.
/// @dev Only deposits mint tokens. Withdrawal burns the caller's tokens before
/// transferring native value; a failed transfer reverts the burn. Native value
/// is paid to msg.sender, which may itself be a proxy for a remote caller.
contract EEZWrappedNative is EEZToken {
    error NativeTransferFailed();

    event Deposit(address indexed account, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);

    constructor(address eezContract_) EEZToken(eezContract_, "Wrapped Native", "WNATIVE", address(0), 0) {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert NativeTransferFailed();
        emit Withdrawal(msg.sender, amount);
    }
}
