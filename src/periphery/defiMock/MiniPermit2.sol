// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @notice Test-only illustration of Permit2's reusable, signed allowance flow.
/// @dev Simplified ABI and feature set; this is not the deployed Uniswap Permit2 contract.
contract MiniPermit2 is EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address token,address spender,uint160 amount,uint48 expiration,uint48 nonce,uint256 sigDeadline)"
    );

    struct Allowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        address token;
        address spender;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
        uint256 sigDeadline;
    }

    mapping(address owner => mapping(address token => mapping(address spender => Allowance))) public allowance;

    event Approval(
        address indexed owner, address indexed token, address indexed spender, uint160 amount, uint48 expiration
    );

    constructor() EIP712("MiniPermit2", "1") {}

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice A signed allowance can be submitted by anyone; only the owner's signature authorizes it.
    function permit(address owner, PermitSingle calldata p, bytes calldata signature) external {
        require(owner != address(0) && p.token != address(0) && p.spender != address(0), "Zero address");
        require(block.timestamp <= p.sigDeadline, "Signature expired");
        Allowance storage current = allowance[owner][p.token][p.spender];
        require(p.nonce == current.nonce, "Invalid nonce");
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, p.token, p.spender, p.amount, p.expiration, p.nonce, p.sigDeadline)
        );
        require(
            SignatureChecker.isValidSignatureNow(owner, _hashTypedDataV4(structHash), signature), "Invalid signature"
        );

        current.amount = p.amount;
        current.expiration = p.expiration;
        current.nonce += 1;
        emit Approval(owner, p.token, p.spender, p.amount, p.expiration);
    }

    /// @notice Onchain alternative to signing a permit, useful for repeat swaps in this mock.
    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        require(token != address(0) && spender != address(0), "Zero address");
        Allowance storage current = allowance[msg.sender][token][spender];
        current.amount = amount;
        current.expiration = expiration;
        current.nonce += 1;
        emit Approval(msg.sender, token, spender, amount, expiration);
    }

    /// @notice The approved spender calls this; ERC20 approval to this contract is still required.
    function transferFrom(address from, address to, uint160 amount, address token) external {
        require(to != address(0) && amount > 0, "Invalid transfer");
        Allowance storage current = allowance[from][token][msg.sender];
        require(block.timestamp <= current.expiration, "Allowance expired");
        require(current.amount >= amount, "Insufficient allowance");
        if (current.amount != type(uint160).max) current.amount -= amount;
        IERC20(token).safeTransferFrom(from, to, amount);
    }
}
