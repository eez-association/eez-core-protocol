// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MiniPermit2} from "../../../src/periphery/defiMock/MiniPermit2.sol";
import {MiniUniswapFactory} from "../../../src/periphery/defiMock/MiniUniswapFactory.sol";
import {MiniUniswapPair} from "../../../src/periphery/defiMock/MiniUniswapPair.sol";
import {MiniUniswapRouter} from "../../../src/periphery/defiMock/MiniUniswapRouter.sol";

contract MiniToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MiniUniswapTest is Test {
    MiniToken tokenA;
    MiniToken tokenB;
    MiniUniswapFactory factory;
    MiniUniswapRouter router;
    MiniPermit2 permit2;
    address alice = makeAddr("alice");
    address bob;
    uint256 bobKey;

    function setUp() public {
        (bob, bobKey) = makeAddrAndKey("bob");
        tokenA = new MiniToken("Token A", "A");
        tokenB = new MiniToken("Token B", "B");
        factory = new MiniUniswapFactory();
        permit2 = new MiniPermit2();
        router = new MiniUniswapRouter(address(factory), address(permit2));
        tokenA.mint(alice, 10_000e18);
        tokenB.mint(alice, 10_000e18);
        tokenA.mint(bob, 1_000e18);
        tokenB.mint(bob, 1_000e18);
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        tokenA.approve(address(permit2), type(uint256).max);
        tokenB.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    function test_createPoolAndFindItInEitherOrder() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        assertEq(factory.getPair(address(tokenA), address(tokenB)), pair);
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pair);
        assertEq(factory.allPairsLength(), 1);
        assertEq(MiniUniswapPair(pair).factory(), address(factory));
        vm.expectRevert("Pair exists");
        factory.createPair(address(tokenB), address(tokenA));
    }

    function test_addSwapBothWaysAndRemoveLiquidity() public {
        vm.startPrank(bob);
        permit2.approve(address(tokenA), address(router), 150e18, uint48(block.timestamp + 1 hours));
        permit2.approve(address(tokenB), address(router), 50e18, uint48(block.timestamp + 1 hours));
        vm.stopPrank();
        vm.prank(alice);
        (uint256 amountA, uint256 amountB, uint256 lp) = router.addLiquidity(
            address(tokenA), address(tokenB), 1_000e18, 1_000e18, 1_000e18, 1_000e18, alice, block.timestamp
        );
        assertEq(amountA, 1_000e18);
        assertEq(amountB, 1_000e18);
        assertEq(lp, 1_000e18);
        MiniUniswapPair pair = MiniUniswapPair(factory.getPair(address(tokenA), address(tokenB)));
        assertEq(pair.balanceOf(alice), lp);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        uint256 expected = router.getAmountOut(100e18, 1_000e18, 1_000e18);
        uint256 bobBBefore = tokenB.balanceOf(bob);
        vm.prank(bob);
        uint256 received = router.swapExactTokensForTokens(100e18, expected, path, bob, block.timestamp);
        assertEq(received, expected);
        assertEq(tokenB.balanceOf(bob) - bobBBefore, expected);
        assertEq(tokenA.balanceOf(address(pair)), 1_100e18);
        assertEq(tokenB.balanceOf(address(pair)), 1_000e18 - expected);

        path[0] = address(tokenB);
        path[1] = address(tokenA);
        uint256 reverseExpected = router.getAmountOut(50e18, 1_000e18 - expected, 1_100e18);
        vm.prank(bob);
        assertEq(router.swapExactTokensForTokens(50e18, reverseExpected, path, bob, block.timestamp), reverseExpected);

        vm.prank(alice);
        pair.approve(address(router), lp);
        uint256 aliceABefore = tokenA.balanceOf(alice);
        uint256 aliceBBefore = tokenB.balanceOf(alice);
        vm.prank(alice);
        (uint256 withdrawnA, uint256 withdrawnB) =
            router.removeLiquidity(address(tokenA), address(tokenB), lp, 1, 1, alice, block.timestamp);
        assertEq(tokenA.balanceOf(alice) - aliceABefore, withdrawnA);
        assertEq(tokenB.balanceOf(alice) - aliceBBefore, withdrawnB);
        assertEq(pair.totalSupply(), 0);
    }

    function test_swapChecksSlippageAndDeadline() public {
        vm.prank(alice);
        router.addLiquidity(address(tokenA), address(tokenB), 1_000e18, 1_000e18, 0, 0, alice, block.timestamp);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        vm.prank(bob);
        vm.expectRevert("Insufficient output");
        router.swapExactTokensForTokens(100e18, 1_000e18, path, bob, block.timestamp);
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        vm.expectRevert("Expired");
        router.swapExactTokensForTokens(100e18, 0, path, bob, block.timestamp - 1);
    }

    function test_directTransferThenPairSwap() public {
        vm.prank(alice);
        router.addLiquidity(address(tokenA), address(tokenB), 1_000e18, 1_000e18, 0, 0, alice, block.timestamp);
        MiniUniswapPair pair = MiniUniswapPair(factory.getPair(address(tokenA), address(tokenB)));
        uint256 output = router.getAmountOut(100e18, 1_000e18, 1_000e18);

        vm.prank(bob);
        tokenA.transfer(address(pair), 100e18);
        uint256 bobBefore = tokenB.balanceOf(bob);
        if (pair.token0() == address(tokenA)) pair.swap(0, output, bob);
        else pair.swap(output, 0, bob);
        assertEq(tokenB.balanceOf(bob) - bobBefore, output);
    }

    function test_swapWithMiniPermit2Signature() public {
        vm.prank(alice);
        router.addLiquidity(address(tokenA), address(tokenB), 1_000e18, 1_000e18, 0, 0, alice, block.timestamp);

        uint256 amountIn = 100e18;
        uint256 deadline = block.timestamp + 1 hours;
        MiniPermit2.PermitSingle memory p = MiniPermit2.PermitSingle({
            token: address(tokenA),
            spender: address(router),
            amount: uint160(amountIn),
            expiration: uint48(deadline),
            nonce: 0,
            sigDeadline: deadline
        });
        bytes32 structHash = keccak256(
            abi.encode(
                permit2.PERMIT_TYPEHASH(), bob, p.token, p.spender, p.amount, p.expiration, p.nonce, p.sigDeadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        uint256 expected = router.getAmountOut(amountIn, 1_000e18, 1_000e18);
        vm.prank(bob);
        assertEq(
            router.swapExactTokensForTokensWithPermit2(amountIn, expected, path, bob, deadline, p, signature), expected
        );
        assertEq(tokenA.allowance(bob, address(router)), 0);
        assertEq(tokenA.allowance(bob, address(permit2)), type(uint256).max);
        (uint160 remaining,, uint48 nonce) = permit2.allowance(bob, address(tokenA), address(router));
        assertEq(remaining, 0);
        assertEq(nonce, 1);
        vm.expectRevert("Invalid nonce");
        permit2.permit(bob, p, signature);
    }

    function test_permit2RequiresTokenApprovalAndExpires() public {
        vm.startPrank(bob);
        tokenA.approve(address(permit2), 0);
        permit2.approve(address(tokenA), address(router), 100e18, uint48(block.timestamp + 1));
        vm.stopPrank();

        vm.prank(address(router));
        vm.expectRevert();
        permit2.transferFrom(bob, alice, 1e18, address(tokenA));

        vm.prank(bob);
        tokenA.approve(address(permit2), 100e18);
        vm.warp(block.timestamp + 2);
        vm.prank(address(router));
        vm.expectRevert("Allowance expired");
        permit2.transferFrom(bob, alice, 1e18, address(tokenA));
    }
}
