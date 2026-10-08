// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {BalancerFlashLoanL2} from "../../src/periphery/balancer/BalancerFlashLoanL2.sol";
import {BalancerFlashLoanNFT} from "../../src/periphery/balancer/BalancerFlashLoanNFT.sol";
import {BalancerV3FlashBorrower} from "../../src/periphery/balancer/BalancerV3FlashBorrower.sol";
import {IBalancerV3Vault} from "../../src/periphery/balancer/interfaces/IBalancerV3Vault.sol";

/// @notice All Balancer mainnet deployment, configuration and read-only checks in one script.
/// @dev Only deployL1, deployL2 and configureL2 use broadcast; forge still requires --broadcast to send.
contract Mainnet is Script {
    address internal L1_BRIDGE = vm.envAddress("BALANCER_L1_BRIDGE");
    address internal L2_BRIDGE = vm.envAddress("BALANCER_L2_BRIDGE");
    address internal USDC = vm.envAddress("BALANCER_TOKEN");
    address internal VAULT = vm.envAddress("BALANCER_VAULT");
    uint256 internal constant MINIMUM = 10_000e6;
    uint256 internal L1_CHAIN_ID = 1;
    uint256 internal L2_CHAIN_ID = 696990;
    bytes32 internal constant FACTORY_CODE_HASH = 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;

    /// @notice Deterministic deployment recipe: the destination is L1 even though submission starts on L2.
    function prepareL1Create2(
        address owner,
        address executorL2
    )
        external
        view
        returns (address predicted, bytes memory payload)
    {
        require(owner != address(0) && executorL2 != address(0), "Zero owner/executor");
        bytes32 salt = keccak256("EEZ_BALANCER_USDC_V1");
        bytes memory initCode = abi.encodePacked(
            type(BalancerV3FlashBorrower).creationCode,
            abi.encode(IBalancerV3Vault(VAULT), IERC20(USDC), Bridge(L1_BRIDGE), executorL2, uint64(1), owner)
        );
        predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, keccak256(initCode)))))
        );
        // Arachnid's factory takes raw salt + initCode; there is no ABI function selector.
        payload = abi.encodePacked(salt, initCode);
    }

    function checkL1Factory() external view {
        checkBridge(true);
        require(CREATE2_FACTORY.codehash == FACTORY_CODE_HASH, "Unexpected CREATE2 factory code");
    }

    function ensureFactoryProxy(address owner) external returns (address proxy) {
        Bridge bridge = checkBridge(false);
        proxy = bridge.manager().computeCrossChainProxyAddress(CREATE2_FACTORY, 0);
        if (proxy.code.length == 0) {
            vm.startBroadcast(owner);
            require(bridge.manager().createCrossChainProxy(CREATE2_FACTORY, 0) == proxy, "Factory proxy mismatch");
            vm.stopBroadcast();
        }
    }

    function checkBridge(bool l1Chain) internal view returns (Bridge bridge) {
        require(block.chainid == (l1Chain ? L1_CHAIN_ID : L2_CHAIN_ID), "Wrong chain");
        bridge = Bridge(l1Chain ? L1_BRIDGE : L2_BRIDGE);
        require(address(bridge).code.length != 0, "Bridge missing");
        require(bridge.rollupId() == (l1Chain ? 0 : 1), "Wrong bridge rollup");
        require(bridge.canonicalBridgeAddress() == (l1Chain ? L2_BRIDGE : L1_BRIDGE), "Wrong counterpart bridge");
        require(address(bridge.manager()).code.length != 0, "Bridge manager missing");
    }

    function deployL1(address owner, address executorL2) external returns (BalancerV3FlashBorrower borrower) {
        checkBridge(true);
        require(owner != address(0) && executorL2 != address(0), "Zero owner/executor");
        vm.startBroadcast(owner);
        borrower =
            new BalancerV3FlashBorrower(IBalancerV3Vault(VAULT), IERC20(USDC), checkBridge(true), executorL2, 1, owner);
        vm.stopBroadcast();
    }

    function deployL2(address owner) external returns (BalancerFlashLoanL2 executor) {
        checkBridge(false);
        require(owner != address(0), "Zero owner");
        vm.startBroadcast(owner);
        executor = new BalancerFlashLoanL2(checkBridge(false), USDC, MINIMUM, owner);
        vm.stopBroadcast();
    }

    function configureL2(address executorAddress, address borrower, address owner) external {
        checkBridge(false);
        BalancerFlashLoanL2 executor = BalancerFlashLoanL2(executorAddress);
        require(executor.owner() == owner, "Wrong owner");
        require(address(executor.bridge()) == L2_BRIDGE && executor.tokenL1() == USDC, "Wrong executor");
        require(executor.borrowerL1() == address(0), "Already configured");
        require(borrower != address(0), "Zero borrower");
        vm.startBroadcast(owner);
        executor.configure(borrower);
        vm.stopBroadcast();
        require(executor.borrowerL1() == borrower, "Binding failed");
    }

    function preflightL1(address manager) external view returns (uint256 amount) {
        require(address(checkBridge(true).manager()) == manager, "Wrong L1 manager");
        uint256 balance = IERC20(USDC).balanceOf(VAULT);
        uint256 reserves = IBalancerV3Vault(VAULT).getReservesOf(IERC20(USDC));
        amount = Math.min(balance, reserves);
        console.log("Available USDC loan (base units):", amount);
    }

    function preflightL2(address manager) external view {
        require(address(checkBridge(false).manager()) == manager, "Wrong L2 manager");
    }

    function verifyL1(address borrowerAddress, address executorL2, address owner, bool completed) external view {
        Bridge bridge = checkBridge(true);
        BalancerV3FlashBorrower borrower = BalancerV3FlashBorrower(borrowerAddress);
        require(borrower.owner() == owner, "Wrong borrower owner");
        require(address(borrower.vault()) == VAULT && address(borrower.token()) == USDC, "Wrong Vault/token");
        require(address(borrower.bridge()) == address(bridge), "Wrong L1 bridge");
        require(borrower.executorL2() == executorL2 && borrower.l2RollupId() == 1, "Wrong L2 destination");
        address proxy = bridge.manager().computeCrossChainProxyAddress(executorL2, 1);
        require(borrower.executorL2Proxy() == proxy && proxy.code.length != 0, "Wrong/missing L2 proxy");
        if (completed) {
            require(IERC20(USDC).balanceOf(borrowerAddress) == 0, "USDC remains on borrower");
            require(IERC20(USDC).allowance(borrowerAddress, address(bridge)) == 0, "Bridge allowance remains");
        }
    }

    function verifyL2(
        address executorAddress,
        address borrower,
        address owner,
        bool configured,
        uint256 tokenId
    )
        external
        view
    {
        Bridge bridge = checkBridge(false);
        BalancerFlashLoanL2 executor = BalancerFlashLoanL2(executorAddress);
        require(executor.owner() == owner && address(executor.bridge()) == address(bridge), "Wrong L2 owner/bridge");
        require(executor.tokenL1() == USDC, "Wrong token");
        BalancerFlashLoanNFT nft = executor.nft();
        require(address(nft.bridge()) == address(bridge) && nft.originalToken() == USDC, "Wrong NFT token/bridge");
        require(nft.minBalance() == MINIMUM, "Wrong NFT minimum");
        if (configured) {
            require(executor.borrowerL1() == borrower, "Wrong borrower");
            address proxy = bridge.manager().computeCrossChainProxyAddress(borrower, 0);
            require(executor.borrowerL1Proxy() == proxy && proxy.code.length != 0, "Wrong/missing borrower proxy");
        }
        if (tokenId != 0) {
            require(nft.ownerOf(tokenId) == owner, "Wrong NFT owner");
            require(IERC20(bridge.getWrappedToken(USDC, 0)).balanceOf(executorAddress) == 0, "Wrapped funds remain");
        }
    }
}
