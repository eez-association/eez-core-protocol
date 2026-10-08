// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bridge} from "../Bridge.sol";
import {BalancerFlashLoanNFT} from "./BalancerFlashLoanNFT.sol";
import {IBalancerV3FlashBorrower} from "./interfaces/IBalancerV3FlashBorrower.sol";
import {IBalancerFlashLoanL2} from "./interfaces/IBalancerFlashLoanL2.sol";

/// @notice L2 entry point for an EEZ synchronous L2 -> L1 -> L2 -> L1 flash loan.
/// @dev Demo periphery; inherits the deployed Bridge's trust and asset-backing assumptions.
contract BalancerFlashLoanL2 is Ownable, IBalancerFlashLoanL2 {
    Bridge public immutable bridge;
    address public immutable tokenL1;
    BalancerFlashLoanNFT public immutable nft;
    address public borrowerL1Proxy;
    address public borrowerL1;
    address private beneficiary;
    uint256 private minimum;
    uint256 private balanceBefore;
    uint256 private completedAmount;
    uint256 private completedTokenId;

    error InvalidConfiguration();
    error Unauthorized();
    error AlreadyConfigured();
    error NotConfigured();
    error LoanActive();
    error AlreadyClaimed();
    error NoPendingLoan();
    error BelowMinimum();
    error TokenNotBridged();
    error IncorrectDelivery();
    error IncorrectBurn(uint256 balanceAfter, uint256 balanceBefore);
    error IncompleteCallback();

    event Configured(address indexed borrowerL1);
    event FlashLoanCompleted(address indexed beneficiary, uint256 amount, uint256 indexed tokenId);

    constructor(Bridge bridge_, address token_, uint256 nftMinimum_, address owner_) Ownable(owner_) {
        if (address(bridge_).code.length == 0 || token_ == address(0)) {
            revert InvalidConfiguration();
        }
        if (bridge_.rollupId() == 0) revert InvalidConfiguration();
        bridge = bridge_;
        tokenL1 = token_;
        nft = new BalancerFlashLoanNFT(bridge_, token_, nftMinimum_);
    }

    /// @notice Bind once after deploying L1; no remote runtime code is expected on L2.
    function configure(address borrower_) external onlyOwner {
        if (borrowerL1 != address(0)) revert AlreadyConfigured();
        if (borrower_ == address(0)) revert InvalidConfiguration();
        borrowerL1 = borrower_;
        borrowerL1Proxy = bridge.manager().computeCrossChainProxyAddress(borrower_, 0);
        if (borrowerL1Proxy.code.length == 0) bridge.manager().createCrossChainProxy(borrower_, 0);
        emit Configured(borrower_);
    }

    /// @notice Start on L2 and borrow exactly max(minAmount, nft.minBalance()) to mint one NFT to msg.sender.
    /// @dev The NFT minimum also applies. A nested callback must finish before execute returns.
    function start(uint256 minAmount) external returns (uint256 amount, uint256 tokenId) {
        if (borrowerL1 == address(0)) revert NotConfigured();
        if (beneficiary != address(0)) revert LoanActive();
        if (nft.hasClaimed(msg.sender)) revert AlreadyClaimed();
        beneficiary = msg.sender;
        minimum = minAmount > nft.minBalance() ? minAmount : nft.minBalance();
        address wrapped = bridge.getWrappedToken(tokenL1, 0);
        balanceBefore = wrapped == address(0) ? 0 : IERC20(wrapped).balanceOf(address(this));
        completedAmount = 0;
        completedTokenId = 0;
        amount = IBalancerV3FlashBorrower(borrowerL1Proxy).execute(minimum);
        if (amount == 0 || completedAmount != amount) revert IncompleteCallback();
        tokenId = completedTokenId;
        delete beneficiary;
        delete minimum;
        delete balanceBefore;
        delete completedAmount;
        delete completedTokenId;
        emit FlashLoanCompleted(msg.sender, amount, tokenId);
    }

    /// @dev Must remain callable while start() is open: this is intentional cross-chain reentry.
    function claimAndBridgeBack(uint256 amount) external override {
        if (msg.sender != borrowerL1Proxy) revert Unauthorized();
        if (beneficiary == address(0) || completedAmount != 0) revert NoPendingLoan();
        if (amount < minimum) revert BelowMinimum();
        address wrapped = bridge.getWrappedToken(tokenL1, 0);
        if (wrapped == address(0)) revert TokenNotBridged();
        if (IERC20(wrapped).balanceOf(address(this)) != balanceBefore + amount) revert IncorrectDelivery();
        completedAmount = amount;
        completedTokenId = nft.claimFor(beneficiary);
        // The bridge burns its wrapped token directly; ERC20 approval is unnecessary.
        bridge.bridgeTokens(wrapped, amount, 0, borrowerL1);
        uint256 balanceAfter = IERC20(wrapped).balanceOf(address(this));
        uint256 expectedBalance = balanceBefore;
        if (balanceAfter != expectedBalance) revert IncorrectBurn(balanceAfter, expectedBalance);
    }
}
