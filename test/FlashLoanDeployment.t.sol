// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Bridge} from "../src/periphery/Bridge.sol";
import {FlashLoanBridgeExecutor} from "../src/periphery/defiMock/FlashLoanBridgeExecutor.sol";
import {WrappedToken} from "../src/periphery/WrappedToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy, DeployL2, Deploy2} from "../script/e2e/scenarios/nested/L1_to_L2/flash-loan/E2EFlashLoan.s.sol";

// Deployment only needs an existing proxy address; execution is covered by the E2E.
contract FlashLoanDeploymentManager {
    function computeCrossChainProxyAddress(address, uint64) external view returns (address) {
        return address(this);
    }
}

contract FlashLoanDeploymentTest is Test {
    address internal constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function test_deploysAndWiresDistinctBridgesWithoutFactory() public {
        // Calling scripts through this test reproduces PrepareJob's nested caller.
        // The Bridge admin must be the broadcast wallet, not this caller.
        vm.etch(FACTORY, hex"");
        address managerL1 = address(new FlashLoanDeploymentManager());
        address managerL2 = address(new FlashLoanDeploymentManager());
        vm.setEnv("ROLLUPS", vm.toString(managerL1));
        vm.setEnv("MANAGER_L2", vm.toString(managerL2));

        new Deploy().run();
        new DeployL2().run();
        new Deploy2().run();

        Bridge l1 = Bridge(vm.envAddress("BRIDGE_L1"));
        Bridge l2 = Bridge(vm.envAddress("BRIDGE_L2"));
        assertNotEq(address(l1), address(l2));
        assertEq(address(l1.manager()), managerL1);
        assertEq(address(l2.manager()), managerL2);
        assertEq(l1.rollupId(), 0);
        assertEq(l2.rollupId(), 1);
        assertEq(l1.canonicalBridgeAddress(), address(l2));
        assertEq(l2.canonicalBridgeAddress(), address(l1));
        assertEq(l1.admin(), l2.admin());
        assertNotEq(l1.admin(), address(this));
        assertEq(FACTORY.code.length, 0);

        FlashLoanBridgeExecutor executor = FlashLoanBridgeExecutor(vm.envAddress("EXECUTOR_L1"));
        assertEq(address(executor.bridge()), address(l1));
        assertEq(executor.bridgeL2(), address(l2));
        assertEq(executor.executorL2(), vm.envAddress("EXECUTOR_L2"));
        assertEq(IERC20(vm.envAddress("TOKEN")).balanceOf(vm.envAddress("FLASH_LOAN_POOL")), 10_000e18);

        bytes32 salt = keccak256(abi.encodePacked(vm.envAddress("TOKEN"), uint64(0)));
        bytes32 initHash = keccak256(
            abi.encodePacked(type(WrappedToken).creationCode, abi.encode("Test Token", "TT", uint8(18), address(l2)))
        );
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(l2), salt, initHash)))));
        assertEq(vm.envAddress("PREDICTED_WRAPPED_TOKEN_L2"), predicted);
        assertEq(executor.wrappedTokenL2(), predicted);
    }
}
