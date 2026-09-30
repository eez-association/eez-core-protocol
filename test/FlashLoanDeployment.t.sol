// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Bridge} from "../src/periphery/Bridge.sol";
import {CREATE2_FACTORY, _computeBridgeAddress, _deployBridge} from "../script/DeployBridge.s.sol";
import {_ensureFlashLoanBridge} from "../script/e2e/nested/L1_to_L2/flash-loan/E2EFlashLoan.s.sol";

// Same salt + init-code calldata layout as the keyless CREATE2 factory.
contract FlashLoanTestFactory {
    fallback() external payable {
        assembly {
            let salt := calldataload(0)
            let size := sub(calldatasize(), 32)
            calldatacopy(0, 32, size)
            let deployed := create2(callvalue(), 0, size, salt)
            if iszero(deployed) { revert(0, 0) }
            mstore(0, deployed)
            return(12, 20)
        }
    }
}

contract FlashLoanDeploymentHarness {
    function ensure(bytes32 salt, address manager, uint64 rollupId, address admin) external returns (address) {
        return _ensureFlashLoanBridge(salt, manager, rollupId, admin);
    }
}

contract FlashLoanDeploymentTest is Test {
    FlashLoanDeploymentHarness internal harness;
    bytes32 internal constant SALT = keccak256("flash-loan-deployment-regression");
    address internal constant MANAGER = address(0x1234);
    address internal constant ADMIN = address(0x5678);

    function setUp() public {
        vm.etch(CREATE2_FACTORY, type(FlashLoanTestFactory).runtimeCode);
        harness = new FlashLoanDeploymentHarness();
    }

    function test_deploysMissingBridgeAndInitializes() public {
        address deployed = harness.ensure(SALT, MANAGER, 1, ADMIN);
        assertEq(deployed, _computeBridgeAddress(SALT));
        assertGt(deployed.code.length, 0);
        assertEq(address(Bridge(deployed).manager()), MANAGER);
        assertEq(Bridge(deployed).rollupId(), 1);
        assertEq(Bridge(deployed).admin(), ADMIN);
    }

    function test_reusesInitializedBridgeWithoutRedeployingOrChangingAdmin() public {
        address deployed = harness.ensure(SALT, MANAGER, 1, ADMIN);
        uint64 factoryNonce = vm.getNonce(CREATE2_FACTORY);
        vm.deal(deployed, 1 ether);
        assertEq(harness.ensure(SALT, MANAGER, 1, address(0x9999)), deployed);
        assertEq(vm.getNonce(CREATE2_FACTORY), factoryNonce);
        assertEq(Bridge(deployed).admin(), ADMIN);
        assertEq(deployed.balance, 1 ether);
    }

    function test_initializesPreviouslyDeployedBridge() public {
        address deployed = _deployBridge(SALT);
        uint64 factoryNonce = vm.getNonce(CREATE2_FACTORY);
        assertEq(harness.ensure(SALT, MANAGER, 0, ADMIN), deployed);
        assertEq(vm.getNonce(CREATE2_FACTORY), factoryNonce);
        assertEq(address(Bridge(deployed).manager()), MANAGER);
        assertEq(Bridge(deployed).rollupId(), 0);
        assertEq(Bridge(deployed).admin(), ADMIN);
    }

    function test_rejectsDifferentManager() public {
        harness.ensure(SALT, MANAGER, 1, ADMIN);
        vm.expectRevert(bytes("flash-loan bridge manager mismatch"));
        harness.ensure(SALT, address(0x9999), 1, ADMIN);
    }

    function test_rejectsDifferentRollup() public {
        harness.ensure(SALT, MANAGER, 1, ADMIN);
        vm.expectRevert(bytes("flash-loan bridge rollup mismatch"));
        harness.ensure(SALT, MANAGER, 0, ADMIN);
    }

    function test_rejectsDifferentCanonicalBridge() public {
        address deployed = harness.ensure(SALT, MANAGER, 1, ADMIN);
        vm.prank(ADMIN);
        Bridge(deployed).setCanonicalBridgeAddress(address(0x9999));
        vm.expectRevert(bytes("flash-loan bridge canonical address mismatch"));
        harness.ensure(SALT, MANAGER, 1, ADMIN);
    }

    function test_acceptsSelfAsCanonicalBridge() public {
        address deployed = harness.ensure(SALT, MANAGER, 1, ADMIN);
        vm.prank(ADMIN);
        Bridge(deployed).setCanonicalBridgeAddress(deployed);
        assertEq(harness.ensure(SALT, MANAGER, 1, ADMIN), deployed);
    }
}
