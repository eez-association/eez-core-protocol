// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FlashLoanersNFT is ERC721 {
    IERC20 public immutable token;
    uint256 public nextTokenId;
    uint256 public constant MIN_BALANCE = 10_000e18;

    mapping(address => bool) public hasClaimed;

    constructor(address _token) ERC721("FlashLoanersNFT", "FLNFT") {
        token = IERC20(_token);
    }

    /// @notice Claim NFT if you hold >= MIN_BALANCE tokens.
    function claim() external {
        require(!hasClaimed[msg.sender], "Already claimed");
        require(token.balanceOf(msg.sender) >= MIN_BALANCE, "Balance too low");

        hasClaimed[msg.sender] = true;
        _mint(msg.sender, ++nextTokenId);
    }
}
