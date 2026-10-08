// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBalancerV3Vault} from "../interfaces/IBalancerV3Vault.sol";
import {MockBalancerToken} from "./MockBalancerToken.sol";

/// @notice Single-token test double for the Balancer V3 flash-loan ABI used by this repository.
/// @dev Not a full Vault: no pools, swaps, nested unlocks or multi-caller accounting.
/// Loans are fee-free and must be transferred back AND settled before unlock returns.
contract MockBalancerV3Vault is IBalancerV3Vault, Ownable {
    using SafeERC20 for IERC20;

    MockBalancerToken public immutable token;
    address public unlockedBy;
    uint256 public debt;
    uint256 private reserves;

    error VaultLocked();
    error AlreadyUnlocked();
    error WrongCaller();
    error UnsupportedToken();
    error InsufficientLiquidity();
    error UnsettledDebt();
    error InvalidBorrower();

    event LiquiditySet(uint256 amount);

    constructor(MockBalancerToken token_, address owner_) Ownable(owner_) {
        require(address(token_).code.length != 0, "Token missing");
        token = token_;
    }

    /// @notice Set exact available liquidity in token base units, minting/burning test tokens.
    function setLiquidity(uint256 amount) external onlyOwner {
        if (unlockedBy != address(0)) revert AlreadyUnlocked();
        uint256 balance = token.balanceOf(address(this));
        if (amount > balance) token.mint(address(this), amount - balance);
        else if (balance > amount) token.burn(balance - amount);
        reserves = amount;
        emit LiquiditySet(amount);
    }

    function getReservesOf(IERC20 token_) external view override returns (uint256) {
        return address(token_) == address(token) ? reserves : 0;
    }

    function unlock(bytes calldata data) external override returns (bytes memory result) {
        if (unlockedBy != address(0)) revert AlreadyUnlocked();
        if (msg.sender.code.length == 0) revert InvalidBorrower();
        unlockedBy = msg.sender;
        bool success;
        (success, result) = msg.sender.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        if (debt != 0) revert UnsettledDebt();
        delete unlockedBy;
    }

    function sendTo(IERC20 token_, address to, uint256 amount) external override {
        _checkSession(token_);
        if (amount > reserves) revert InsufficientLiquidity();
        reserves -= amount;
        debt += amount;
        token_.safeTransfer(to, amount);
    }

    function settle(IERC20 token_, uint256 amountHint) external override returns (uint256 credit) {
        _checkSession(token_);
        uint256 balance = token.balanceOf(address(this));
        uint256 received = balance > reserves ? balance - reserves : 0;
        credit = received < amountHint ? received : amountHint;
        // This test double supports debt repayment only, not prepaid credits.
        if (credit > debt) credit = debt;
        reserves += credit;
        debt -= credit;
    }

    function _checkSession(IERC20 token_) private view {
        if (unlockedBy == address(0)) revert VaultLocked();
        if (msg.sender != unlockedBy) revert WrongCaller();
        if (address(token_) != address(token)) revert UnsupportedToken();
    }
}
