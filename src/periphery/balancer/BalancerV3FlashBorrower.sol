// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Bridge} from "../Bridge.sol";
import {IBalancerV3Vault} from "./interfaces/IBalancerV3Vault.sol";
import {IBalancerV3FlashBorrower} from "./interfaces/IBalancerV3FlashBorrower.sol";
import {IBalancerFlashLoanL2} from "./interfaces/IBalancerFlashLoanL2.sol";

/// @notice Borrow on L1, bridge to L2, claim an NFT, bridge back, and repay Balancer V3.
/// @dev Experimental periphery using the existing Bridge's synchronous EEZ route.
/// Supports a standard ERC20 such as USDC, not fee-on-transfer or rebasing tokens.
contract BalancerV3FlashBorrower is Ownable, ReentrancyGuard, IBalancerV3FlashBorrower {
    using SafeERC20 for IERC20;

    IBalancerV3Vault public immutable vault;
    IERC20 public immutable token;
    Bridge public immutable bridge;
    address public immutable executorL2;
    address public immutable executorL2Proxy;
    uint64 public immutable l2RollupId;
    uint256 private pendingAmount;

    error Unauthorized();
    error InvalidConfiguration();
    error InsufficientLiquidity();
    error UnexpectedCallback();
    error CallbackNotReceived();
    error ExistingBalanceSpent();
    error IncorrectSettlement();

    event FlashLoanExecuted(address indexed token, uint256 amount);
    event TokenWithdrawn(address indexed token, address indexed recipient, uint256 amount);

    constructor(
        IBalancerV3Vault vault_,
        IERC20 token_,
        Bridge bridge_,
        address executorL2_,
        uint64 l2RollupId_,
        address owner_
    )
        Ownable(owner_)
    {
        if (address(vault_).code.length == 0 || address(token_).code.length == 0 || address(bridge_).code.length == 0) {
            revert InvalidConfiguration();
        }
        if (bridge_.rollupId() != 0 || executorL2_ == address(0) || l2RollupId_ == 0) revert InvalidConfiguration();
        vault = vault_;
        token = token_;
        bridge = bridge_;
        executorL2 = executorL2_;
        l2RollupId = l2RollupId_;
        // Remote addresses need no local bytecode. Only their EEZ proxies execute locally.
        executorL2Proxy = bridge_.manager().computeCrossChainProxyAddress(executorL2_, l2RollupId_);
        if (executorL2Proxy.code.length == 0) bridge_.manager().createCrossChainProxy(executorL2_, l2RollupId_);
    }

    /// @notice Full usable liquidity: the lesser of accounted Vault reserves and its actual token balance.
    function availableLoan() public view returns (uint256) {
        return Math.min(vault.getReservesOf(token), token.balanceOf(address(vault)));
    }

    /// @notice Borrow exactly minAmount through the authenticated L2 executor proxy.
    /// @dev Live liquidity is only a capacity check; it must not resize cross-chain calls or return data.
    function execute(uint256 minAmount) external override nonReentrant returns (uint256 amount) {
        if (msg.sender != executorL2Proxy) revert Unauthorized();
        amount = minAmount;
        if (amount == 0 || amount > availableLoan()) revert InsufficientLiquidity();
        uint256 balanceBefore = token.balanceOf(address(this));
        pendingAmount = amount;
        vault.unlock(abi.encodeCall(this.onFlashLoan, (amount)));
        if (pendingAmount != 0) revert CallbackNotReceived();
        // Existing funds must never subsidize an incomplete bridge return.
        if (token.balanceOf(address(this)) < balanceBefore) revert ExistingBalanceSpent();
        emit FlashLoanExecuted(address(token), amount);
    }

    /// @dev Deliberately callable during execute; only the Vault can consume the pending loan once.
    function onFlashLoan(uint256 amount) external {
        if (msg.sender != address(vault)) revert Unauthorized();
        if (!_reentrancyGuardEntered() || amount == 0 || pendingAmount != amount) revert UnexpectedCallback();
        delete pendingAmount;

        vault.sendTo(token, address(this), amount);

        // Same sequence as FlashLoanBridgeExecutor, with the existing bridges.
        token.forceApprove(address(bridge), amount);
        bridge.bridgeTokens(address(token), amount, l2RollupId, executorL2);
        token.forceApprove(address(bridge), 0);
        IBalancerFlashLoanL2(executorL2Proxy).claimAndBridgeBack(amount);

        token.safeTransfer(address(vault), amount);
        if (vault.settle(token, amount) != amount) revert IncorrectSettlement();
    }

    /// @notice Owner-only recovery of leftover tokens between loans, not a repayment step.
    function withdrawToken(IERC20 token_, address recipient, uint256 amount) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert InvalidConfiguration();
        token_.safeTransfer(recipient, amount);
        emit TokenWithdrawn(address(token_), recipient, amount);
    }
}
