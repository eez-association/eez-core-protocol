// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {WrappedToken} from "../../src/periphery/WrappedToken.sol";
import {FlashLoan} from "../../src/periphery/defiMock/FlashLoan.sol";
import {FlashLoanBridgeExecutor} from "../../src/periphery/defiMock/FlashLoanBridgeExecutor.sol";
import {FlashLoanersNFT} from "../../src/periphery/defiMock/FlashLoanersNFT.sol";
import {EEZ} from "../../src/EEZ.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {_deployBridge, _computeBridgeAddress} from "../DeployBridge.s.sol";

/// @dev Simple test token deployed on L1
contract TestToken is ERC20 {
    constructor() ERC20("Test Token", "TT") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @title DeployTokenAndBridgeL1 — Deploy ERC20 token + Bridge on L1
/// @dev Usage:
///   forge script script/flash-loan-test/DeployFlashLoan.s.sol:DeployTokenAndBridgeL1 \
///     --rpc-url $L1_RPC --broadcast --private-key $PK \
///     --sig "run(address,bytes32)" $ROLLUPS $SALT
contract DeployTokenAndBridgeL1 is Script {
    function run(address rollups, bytes32 salt) external {
        vm.startBroadcast();

        // Deploy test ERC20 token (1M tokens minted to deployer)
        TestToken token = new TestToken();
        console.log("TOKEN=%s", address(token));

        // Deploy Bridge via CREATE2
        address bridge = _deployBridge(salt);
        Bridge(bridge).initialize(rollups, 0, msg.sender);
        console.log("BRIDGE_L1=%s", bridge);

        vm.stopBroadcast();
    }
}

/// @title DeployBridgeL2 — Deploy Bridge on L2
/// @dev Usage:
///   forge script script/flash-loan-test/DeployFlashLoan.s.sol:DeployBridgeL2 \
///     --rpc-url $L2_RPC --broadcast --private-key $PK \
///     --sig "run(address,uint256,bytes32)" $MANAGER_L2 $L2_ROLLUP_ID $SALT
contract DeployBridgeL2 is Script {
    function run(address managerL2, uint64 rollupId, bytes32 salt) external {
        vm.startBroadcast();

        address bridge = _deployBridge(salt);
        Bridge(bridge).initialize(managerL2, rollupId, msg.sender);
        console.log("BRIDGE_L2=%s", bridge);

        vm.stopBroadcast();
    }
}

/// @title ComputeWrappedTokenAddress — Pre-compute WrappedToken CREATE2 address
/// @dev Run against L1 RPC (where the token lives) to read name/symbol/decimals.
///   forge script script/flash-loan-test/DeployFlashLoan.s.sol:ComputeWrappedTokenAddress \
///     --rpc-url $L1_RPC \
///     --sig "run(address,address,uint256)" $BRIDGE_L2 $TOKEN $TOKEN_ORIGIN_ROLLUP_ID
contract ComputeWrappedTokenAddress is Script {
    function run(address bridgeL2, address token, uint64 tokenOriginRollupId) external view {
        string memory name = ERC20(token).name();
        string memory symbol = ERC20(token).symbol();
        uint8 tokenDecimals = ERC20(token).decimals();

        bytes32 wrappedSalt = keccak256(abi.encodePacked(token, tokenOriginRollupId));
        bytes32 wrappedBytecodeHash = keccak256(
            abi.encodePacked(type(WrappedToken).creationCode, abi.encode(name, symbol, tokenDecimals, bridgeL2))
        );
        address wrappedTokenL2 = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), bridgeL2, wrappedSalt, wrappedBytecodeHash))))
        );
        console.log("WRAPPED_TOKEN_L2=%s", wrappedTokenL2);
    }
}

/// @title DeployFlashLoanL2 — Deploy L2-side contracts (executorL2, FlashLoanersNFT)
/// @dev Usage:
///   forge script script/flash-loan-test/DeployFlashLoan.s.sol:DeployFlashLoanL2 \
///     --rpc-url $L2_RPC --broadcast --private-key $PK \
///     --sig "run(address)" $WRAPPED_TOKEN_L2
contract DeployFlashLoanL2 is Script {
    function run(address wrappedTokenL2) external {
        vm.startBroadcast();

        // ExecutorL2: constructor args unused — claimAndBridgeBack takes all params as function args
        FlashLoanBridgeExecutor executorL2 = new FlashLoanBridgeExecutor(
            address(0), address(0), address(0), address(0), address(0), address(0), address(0), 0, address(0)
        );
        console.log("EXECUTOR_L2=%s", address(executorL2));

        // FlashLoanersNFT: token-gated NFT using the pre-computed wrapped token address
        FlashLoanersNFT nft = new FlashLoanersNFT(wrappedTokenL2);
        console.log("FLASH_LOANERS_NFT=%s", address(nft));

        vm.stopBroadcast();
    }
}

/// @title DeployFlashLoanL1 — Deploy L1-side contracts (FlashLoan pool, executor, fund pool)
/// @dev Usage:
///   forge script script/flash-loan-test/DeployFlashLoan.s.sol:DeployFlashLoanL1 \
///     --rpc-url $L1_RPC --broadcast --private-key $PK \
///     --sig "run(address,address,address,address,address,address,uint256,address)" \
///     $ROLLUPS $BRIDGE_L1 $EXECUTOR_L2 $WRAPPED_TOKEN_L2 $FLASH_LOANERS_NFT $BRIDGE_L2 $L2_ROLLUP_ID $TOKEN
contract DeployFlashLoanL1 is Script {
    function run(
        address rollups,
        address bridgeL1,
        address executorL2,
        address wrappedTokenL2,
        address flashLoanersNFT,
        address bridgeL2,
        uint64 l2RollupId,
        address token
    )
        external
    {
        vm.startBroadcast();

        // FlashLoan pool
        FlashLoan flashLoanPool = new FlashLoan();
        console.log("FLASH_LOAN_POOL=%s", address(flashLoanPool));

        // Fund the flash loan pool with 10k tokens
        IERC20(token).transfer(address(flashLoanPool), 10_000e18);
        console.log("Funded flash loan pool with 10k tokens");

        // Create proxy for executorL2 on L1
        address executorL2Proxy = EEZ(rollups).createCrossChainProxy(executorL2, l2RollupId);
        console.log("EXECUTOR_L2_PROXY=%s", executorL2Proxy);

        // Executor on L1 (orchestrates the full flash loan + cross-chain flow)
        FlashLoanBridgeExecutor executor = new FlashLoanBridgeExecutor(
            address(flashLoanPool),
            bridgeL1,
            executorL2Proxy,
            executorL2,
            wrappedTokenL2,
            flashLoanersNFT,
            bridgeL2,
            l2RollupId,
            token
        );
        console.log("EXECUTOR_L1=%s", address(executor));

        vm.stopBroadcast();
    }
}
