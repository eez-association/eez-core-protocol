// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFlashLoanReceiver, FlashLoan} from "./FlashLoan.sol";
import {FlashLoanersNFT} from "./FlashLoanersNFT.sol";
import {Bridge} from "../Bridge.sol";

contract FlashLoanBridgeExecutor is IFlashLoanReceiver {
    using SafeERC20 for IERC20;

    FlashLoan public immutable flashLoanPool;
    Bridge public immutable bridge;
    address public immutable executorL2Proxy;
    address public immutable executorL2;
    address public immutable wrappedTokenL2;
    address public immutable nftL2;
    address public immutable bridgeL2;
    uint64 public immutable l2RollupId;
    address public immutable token;

    constructor(
        address _flashLoanPool,
        address _bridge,
        address _executorL2Proxy,
        address _executorL2,
        address _wrappedTokenL2,
        address _nftL2,
        address _bridgeL2,
        uint64 _l2RollupId,
        address _token
    ) {
        flashLoanPool = FlashLoan(_flashLoanPool);
        bridge = Bridge(_bridge);
        executorL2Proxy = _executorL2Proxy;
        executorL2 = _executorL2;
        wrappedTokenL2 = _wrappedTokenL2;
        nftL2 = _nftL2;
        bridgeL2 = _bridgeL2;
        l2RollupId = _l2RollupId;
        token = _token;
    }

    function execute() external {
        flashLoanPool.flashLoan(token, 10_000e18);
    }

    function onFlashLoan(address _token, uint256 amount) external override {
        require(msg.sender == address(flashLoanPool), "Unauthorized");

        // 1. Bridge tokens to executor on L2
        IERC20(_token).approve(address(bridge), amount);
        bridge.bridgeTokens(_token, amount, l2RollupId, executorL2);

        // 2. Trigger executor(L2) to claim NFT and bridge tokens back
        (bool success,) = executorL2Proxy.call(
            abi.encodeCall(this.claimAndBridgeBack, (wrappedTokenL2, nftL2, bridgeL2, 0, address(this)))
        );
        require(success, "Cross-chain call failed");

        // 3. Repay (tokens are back from bridge release)
        IERC20(_token).safeTransfer(msg.sender, amount);
    }

    function claimAndBridgeBack(
        address wrappedToken,
        address nftContract,
        address _bridge,
        uint64 destRollupId,
        address returnTo
    )
        external
    {
        FlashLoanersNFT(nftContract).claim();
        uint256 balance = IERC20(wrappedToken).balanceOf(address(this));
        Bridge(_bridge).bridgeTokens(wrappedToken, balance, destRollupId, returnTo);
    }
}
