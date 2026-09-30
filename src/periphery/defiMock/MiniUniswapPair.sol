// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Test-only, v2-style constant-product pool. Not for production use.
contract MiniUniswapPair is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint256 public reserve0;
    uint256 public reserve1;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint256 reserve0, uint256 reserve1);

    constructor(address token0_, address token1_) ERC20("Mini Uniswap LP", "MINI-LP") {
        require(token0_ != address(0) && token1_ != address(0) && token0_ < token1_, "Invalid tokens");
        factory = msg.sender;
        token0 = token0_;
        token1 = token1_;
    }

    /// @dev Caller must transfer both tokens into the pair before minting.
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        require(to != address(0), "Zero recipient");
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;
        uint256 supply = totalSupply();

        if (supply == 0) {
            liquidity = Math.sqrt(amount0 * amount1);
        } else {
            liquidity = Math.min(amount0 * supply / reserve0, amount1 * supply / reserve1);
        }
        require(liquidity > 0, "Insufficient liquidity minted");
        _mint(to, liquidity);
        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @dev Caller must transfer LP tokens into the pair before burning.
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(to != address(0) && to != token0 && to != token1, "Invalid recipient");
        uint256 liquidity = balanceOf(address(this));
        uint256 supply = totalSupply();
        require(liquidity > 0, "No LP tokens");
        amount0 = liquidity * IERC20(token0).balanceOf(address(this)) / supply;
        amount1 = liquidity * IERC20(token1).balanceOf(address(this)) / supply;
        require(amount0 > 0 && amount1 > 0, "Insufficient liquidity burned");
        _burn(address(this), liquidity);
        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @dev Input must be transferred into the pair before calling swap. Fee is 0.3%.
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external nonReentrant {
        require((amount0Out == 0) != (amount1Out == 0), "One output required");
        require(amount0Out < reserve0 && amount1Out < reserve1, "Insufficient reserves");
        require(to != address(0) && to != token0 && to != token1, "Invalid recipient");

        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "No input");
        require(
            (balance0 * 1000 - amount0In * 3) * (balance1 * 1000 - amount1In * 3) >= reserve0 * reserve1 * 1_000_000,
            "Invariant violated"
        );

        _update(balance0, balance1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function _update(uint256 balance0, uint256 balance1) private {
        reserve0 = balance0;
        reserve1 = balance1;
        emit Sync(balance0, balance1);
    }
}
