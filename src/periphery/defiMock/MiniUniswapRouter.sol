// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MiniUniswapFactory} from "./MiniUniswapFactory.sol";
import {MiniUniswapPair} from "./MiniUniswapPair.sol";
import {MiniPermit2} from "./MiniPermit2.sol";

/// @notice Test-only router for direct ERC20/ERC20 swaps. No ETH or multihop support.
contract MiniUniswapRouter {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    MiniUniswapFactory public immutable factory;
    MiniPermit2 public immutable permit2;

    constructor(address factory_, address permit2_) {
        require(factory_ != address(0) && permit2_ != address(0), "Zero dependency");
        factory = MiniUniswapFactory(factory_);
        permit2 = MiniPermit2(permit2_);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        _check(deadline, to);
        address pairAddress = factory.getPair(tokenA, tokenB);
        if (pairAddress == address(0)) pairAddress = factory.createPair(tokenA, tokenB);
        MiniUniswapPair pair = MiniUniswapPair(pairAddress);
        (uint256 reserveA, uint256 reserveB) = _reserves(pair, tokenA);

        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = amountADesired * reserveB / reserveA;
            if (amountBOptimal <= amountBDesired) {
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                (amountA, amountB) = (amountBDesired * reserveA / reserveB, amountBDesired);
            }
        }
        require(amountA > 0 && amountB > 0 && amountA >= amountAMin && amountB >= amountBMin, "Liquidity bounds");
        IERC20(tokenA).safeTransferFrom(msg.sender, pairAddress, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pairAddress, amountB);
        liquidity = pair.mint(to);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (uint256 amountA, uint256 amountB)
    {
        _check(deadline, to);
        address pairAddress = factory.getPair(tokenA, tokenB);
        require(pairAddress != address(0), "Pair missing");
        MiniUniswapPair pair = MiniUniswapPair(pairAddress);
        IERC20(pairAddress).safeTransferFrom(msg.sender, pairAddress, liquidity);
        (uint256 amount0, uint256 amount1) = pair.burn(to);
        (amountA, amountB) = tokenA == pair.token0() ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin && amountB >= amountBMin, "Liquidity bounds");
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        returns (uint256 amountOut)
    {
        return _swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);
    }

    /// @notice Submit a MiniPermit2 signature and swap in one transaction.
    /// @dev Simplified teaching equivalent of a Permit2 permit command followed by a swap command.
    function swapExactTokensForTokensWithPermit2(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline,
        MiniPermit2.PermitSingle calldata permitData,
        bytes calldata signature
    )
        external
        returns (uint256 amountOut)
    {
        require(
            path.length == 2 && permitData.token == path[0] && permitData.spender == address(this), "Permit mismatch"
        );
        permit2.permit(msg.sender, permitData, signature);
        return _swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);
    }

    function _swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        private
        returns (uint256 amountOut)
    {
        _check(deadline, to);
        require(path.length == 2 && path[0] != path[1], "Direct path only");
        address pairAddress = factory.getPair(path[0], path[1]);
        require(pairAddress != address(0), "Pair missing");
        MiniUniswapPair pair = MiniUniswapPair(pairAddress);
        (uint256 reserveIn, uint256 reserveOut) = _reserves(pair, path[0]);
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        require(amountOut >= amountOutMin, "Insufficient output");

        permit2.transferFrom(msg.sender, pairAddress, amountIn.toUint160(), path[0]);
        if (path[0] == pair.token0()) pair.swap(0, amountOut, to);
        else pair.swap(amountOut, 0, to);
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    )
        public
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0 && reserveIn > 0 && reserveOut > 0, "Invalid quote");
        uint256 amountInWithFee = amountIn * 997;
        amountOut = amountInWithFee * reserveOut / (reserveIn * 1000 + amountInWithFee);
        require(amountOut > 0, "Output rounds to zero");
    }

    function _reserves(MiniUniswapPair pair, address tokenA) private view returns (uint256 reserveA, uint256 reserveB) {
        require(tokenA == pair.token0() || tokenA == pair.token1(), "Token not in pair");
        (reserveA, reserveB) =
            tokenA == pair.token0() ? (pair.reserve0(), pair.reserve1()) : (pair.reserve1(), pair.reserve0());
    }

    function _check(uint256 deadline, address to) private view {
        require(block.timestamp <= deadline, "Expired");
        require(to != address(0), "Zero recipient");
    }
}
