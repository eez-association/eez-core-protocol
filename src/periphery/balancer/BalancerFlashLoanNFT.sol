// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Bridge} from "../Bridge.sol";

/// @notice Demonstration NFT: a temporary bridged balance is intentionally sufficient.
contract BalancerFlashLoanNFT is ERC721 {
    Bridge public immutable bridge;
    address public immutable originalToken;
    uint256 public immutable minBalance;
    uint256 public nextTokenId;
    mapping(address => bool) public hasClaimed;

    error InvalidConfiguration();
    error InvalidRecipient();
    error AlreadyClaimed();
    error TokenNotBridged();
    error InsufficientBalance();

    constructor(Bridge bridge_, address token_, uint256 minimum_) ERC721("EEZ Balancer Flash Loan", "EEZFLASH") {
        if (address(bridge_).code.length == 0 || token_ == address(0) || minimum_ == 0) {
            revert InvalidConfiguration();
        }
        bridge = bridge_;
        originalToken = token_;
        minBalance = minimum_;
    }

    /// @notice Anyone holding the minimum wrapped-token balance can mint to a recipient once.
    /// @dev Checks the caller's balance, never a third party's. Tokens are neither spent nor locked.
    /// The executor uses this same permissionless function during the flash loan.
    function claimFor(address recipient) external returns (uint256 id) {
        if (recipient == address(0)) revert InvalidRecipient();
        if (hasClaimed[recipient]) revert AlreadyClaimed();
        address wrapped = bridge.getWrappedToken(originalToken, 0);
        if (wrapped == address(0)) revert TokenNotBridged();
        if (IERC20(wrapped).balanceOf(msg.sender) < minBalance) revert InsufficientBalance();
        hasClaimed[recipient] = true;
        id = ++nextTokenId;
        // No receiver hook during the cross-chain flash-loan callback.
        _mint(recipient, id);
    }
}
