// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockBalancerToken} from "../../src/periphery/balancer/mock/MockBalancerToken.sol";
import {MockBalancerV3Vault} from "../../src/periphery/balancer/mock/MockBalancerV3Vault.sol";
import {ChiadoMock} from "../../script/balancer/ChiadoMock.s.sol";

contract MockBalancerV3VaultTest is Test {
    MockBalancerToken token;
    MockBalancerV3Vault vault;
    uint256 constant CAPACITY = 1_000_000e6;

    function setUp() public {
        token = new MockBalancerToken();
        vault = new MockBalancerV3Vault(token, address(this));
        vault.setLiquidity(CAPACITY);
    }

    function testFuzzExactLoanAndRepeatedUse(uint256 amount) public {
        amount = bound(amount, 1, CAPACITY);
        for (uint256 i; i < 2; ++i) {
            bytes memory result = vault.unlock(abi.encodeCall(this.repay, (amount, amount, amount)));
            assertEq(abi.decode(result, (uint256)), amount);
            assertEq(token.balanceOf(address(this)), 0);
            assertEq(token.balanceOf(address(vault)), CAPACITY);
            assertEq(vault.getReservesOf(token), CAPACITY);
            assertEq(vault.debt(), 0);
            assertEq(vault.unlockedBy(), address(0));
        }
    }

    function repay(uint256 amount, uint256 repayment, uint256 hint) external returns (uint256) {
        require(msg.sender == address(vault), "Vault only");
        vault.sendTo(token, address(this), amount);
        assertEq(token.balanceOf(address(this)), amount);
        token.transfer(address(vault), repayment);
        return vault.settle(token, hint);
    }

    function testUnderpaymentRevertsAndRollsBack() public {
        vm.expectRevert(MockBalancerV3Vault.UnsettledDebt.selector);
        vault.unlock(abi.encodeCall(this.repay, (100e6, 99e6, 100e6)));
        assertEq(token.balanceOf(address(vault)), CAPACITY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(vault.getReservesOf(token), CAPACITY);
        assertEq(vault.unlockedBy(), address(0));
    }

    function testHintCannotFakeRepayment() public {
        vm.expectRevert(MockBalancerV3Vault.UnsettledDebt.selector);
        vault.unlock(abi.encodeCall(this.repay, (100e6, 0, type(uint256).max)));
    }

    function testFullTransferWithSmallHintStillReverts() public {
        vm.expectRevert(MockBalancerV3Vault.UnsettledDebt.selector);
        vault.unlock(abi.encodeCall(this.repay, (100e6, 100e6, 99e6)));
    }

    function testInsufficientLiquidity() public {
        vm.expectRevert(MockBalancerV3Vault.InsufficientLiquidity.selector);
        vault.unlock(abi.encodeCall(this.repay, (CAPACITY + 1, CAPACITY + 1, CAPACITY + 1)));
    }

    function testCallsOutsideUnlockRevert() public {
        vm.expectRevert(MockBalancerV3Vault.VaultLocked.selector);
        vault.sendTo(token, address(this), 1);
        vm.expectRevert(MockBalancerV3Vault.VaultLocked.selector);
        vault.settle(token, 1);
    }

    function restrictions() external {
        vm.expectRevert(MockBalancerV3Vault.AlreadyUnlocked.selector);
        vault.unlock("");
        vm.expectRevert(MockBalancerV3Vault.AlreadyUnlocked.selector);
        vault.setLiquidity(0);
        vm.expectRevert(MockBalancerV3Vault.UnsupportedToken.selector);
        vault.sendTo(IERC20(address(123)), address(this), 1);
        vm.prank(address(456));
        vm.expectRevert(MockBalancerV3Vault.WrongCaller.selector);
        vault.sendTo(token, address(456), 1);
    }

    function testSessionRestrictions() public {
        vault.unlock(abi.encodeCall(this.restrictions, ()));
    }

    function testAdjustLiquidityAndFaucet() public {
        vault.setLiquidity(2 * CAPACITY);
        assertEq(token.balanceOf(address(vault)), 2 * CAPACITY);
        vault.setLiquidity(123e6);
        assertEq(vault.getReservesOf(token), 123e6);
        assertEq(token.balanceOf(address(vault)), 123e6);
        token.mint(address(123), 42e6);
        assertEq(token.balanceOf(address(123)), 42e6);
        assertEq(token.decimals(), 6);
        vm.prank(address(123));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(123)));
        vault.setLiquidity(1);
    }

    function testDeploymentOnChiado() public {
        vm.chainId(10200);
        ChiadoMock deployment = new ChiadoMock();
        (MockBalancerToken deployedToken, MockBalancerV3Vault deployedVault) = deployment.run();
        assertEq(deployedToken.balanceOf(address(deployedVault)), CAPACITY);
        assertEq(deployedVault.getReservesOf(deployedToken), CAPACITY);
        assertTrue(deployedVault.owner() != address(deployment));
    }

    function testDeploymentRejectsOtherChains() public {
        vm.chainId(1);
        ChiadoMock deployment = new ChiadoMock();
        vm.expectRevert("Chiado only");
        deployment.run();
    }
}
