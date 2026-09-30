// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MiniUniswapPair} from "./MiniUniswapPair.sol";

/// @notice Test-only factory: one pool for each unordered ERC20 pair.
contract MiniUniswapFactory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair);

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "Identical tokens");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Zero token");
        require(getPair[token0][token1] == address(0), "Pair exists");

        pair = address(new MiniUniswapPair(token0, token1));
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair);
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }
}
