// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {WrappedToken} from "../../src/periphery/WrappedToken.sol";

/// @notice Minimal token that reverts on every metadata getter, exercising the
///         `_getSafeTokenMetadata` catch fallbacks.
contract NoMetadataToken is ERC20 {
    constructor() ERC20("", "") {
        _mint(msg.sender, 1_000_000e18);
    }

    function name() public pure override returns (string memory) {
        revert("no name");
    }

    function symbol() public pure override returns (string memory) {
        revert("no symbol");
    }

    function decimals() public pure override returns (uint8) {
        revert("no decimals");
    }
}

contract GoodToken is ERC20 {
    constructor() ERC20("Good Token", "GOOD") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @notice Accepts any call / ETH and returns empty success — stands in for a CrossChainProxy
///         on the destination so the Bridge's outbound `proxy.call(...)` succeeds.
contract AcceptingProxy {
    receive() external payable {}
    fallback() external payable {}
}

/// @notice Reverts on every call — drives the Bridge's `ProxyCallFailed` paths.
contract RevertingProxy {
    fallback() external payable {
        revert("nope");
    }
}

/// @notice Mock manager returning a fixed, pre-deployed proxy address for every lookup.
contract MockManager {
    address public proxy;

    constructor(address _proxy) {
        proxy = _proxy;
    }

    function computeCrossChainProxyAddress(address, uint64) external view returns (address) {
        return proxy;
    }

    function createCrossChainProxy(address, uint64) external returns (address) {
        return proxy;
    }
}

contract BridgeTest is Test {
    Bridge internal bridge;
    MockManager internal manager;
    AcceptingProxy internal proxy;
    GoodToken internal token;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal dest = makeAddr("dest");

    uint64 internal constant THIS_ROLLUP = 7;
    uint64 internal constant DEST_ROLLUP = 9;

    function setUp() public {
        proxy = new AcceptingProxy();
        manager = new MockManager(address(proxy));
        bridge = new Bridge();
        bridge.initialize(address(manager), THIS_ROLLUP, admin);
        token = new GoodToken();
        token.transfer(alice, 100_000e18);
    }

    // ── initialize ──────────────────────────────────────────────

    function test_initializeTwiceReverts() public {
        vm.expectRevert(Bridge.AlreadyInitialized.selector);
        bridge.initialize(address(manager), THIS_ROLLUP, admin);
    }

    function test_initializeZeroManagerReverts() public {
        Bridge fresh = new Bridge();
        vm.expectRevert(Bridge.ZeroAddress.selector);
        fresh.initialize(address(0), THIS_ROLLUP, admin);
    }

    function test_initializeZeroAdminReverts() public {
        Bridge fresh = new Bridge();
        vm.expectRevert(Bridge.ZeroAddress.selector);
        fresh.initialize(address(manager), THIS_ROLLUP, address(0));
    }

    // ── admin ───────────────────────────────────────────────────

    function test_setCanonicalBridgeAddressOnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(Bridge.OnlyAdmin.selector);
        bridge.setCanonicalBridgeAddress(address(0xBEEF));
    }

    function test_setCanonicalBridgeAddress() public {
        vm.prank(admin);
        bridge.setCanonicalBridgeAddress(address(0xBEEF));
        assertEq(bridge.canonicalBridgeAddress(), address(0xBEEF));
    }

    // ── bridgeEther ─────────────────────────────────────────────

    function test_bridgeEtherZeroAmountReverts() public {
        vm.expectRevert(Bridge.ZeroAmount.selector);
        bridge.bridgeEther{value: 0}(DEST_ROLLUP, dest);
    }

    function test_bridgeEtherSuccess() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        bridge.bridgeEther{value: 1 ether}(DEST_ROLLUP, dest);
        assertEq(address(proxy).balance, 1 ether);
    }

    function test_bridgeEtherProxyCallFailedReverts() public {
        // Point the manager at a reverting proxy.
        RevertingProxy bad = new RevertingProxy();
        MockManager badManager = new MockManager(address(bad));
        Bridge b = new Bridge();
        b.initialize(address(badManager), THIS_ROLLUP, admin);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        b.bridgeEther{value: 1 ether}(DEST_ROLLUP, dest);
    }

    // ── bridgeTokens (native) ───────────────────────────────────

    function test_bridgeTokensZeroAmountReverts() public {
        vm.expectRevert(Bridge.ZeroAmount.selector);
        bridge.bridgeTokens(address(token), 0, DEST_ROLLUP, dest);
    }

    function test_bridgeTokensZeroTokenReverts() public {
        vm.expectRevert(Bridge.ZeroAddress.selector);
        bridge.bridgeTokens(address(0), 1, DEST_ROLLUP, dest);
    }

    function test_bridgeTokensNativeSuccessLocks() public {
        vm.startPrank(alice);
        token.approve(address(bridge), 10_000e18);
        bridge.bridgeTokens(address(token), 10_000e18, DEST_ROLLUP, dest);
        vm.stopPrank();
        // Native tokens locked in the bridge.
        assertEq(token.balanceOf(address(bridge)), 10_000e18);
    }

    function test_bridgeTokensNoMetadataToken() public {
        NoMetadataToken bad = new NoMetadataToken();
        bad.transfer(alice, 10_000e18);
        vm.startPrank(alice);
        bad.approve(address(bridge), 10_000e18);
        // Exercises the name/symbol/decimals catch fallbacks.
        bridge.bridgeTokens(address(bad), 10_000e18, DEST_ROLLUP, dest);
        vm.stopPrank();
        assertEq(bad.balanceOf(address(bridge)), 10_000e18);
    }

    function test_bridgeTokensProxyCallFailedReverts() public {
        RevertingProxy bad = new RevertingProxy();
        MockManager badManager = new MockManager(address(bad));
        Bridge b = new Bridge();
        b.initialize(address(badManager), THIS_ROLLUP, admin);

        vm.startPrank(alice);
        token.approve(address(b), 10_000e18);
        vm.expectRevert();
        b.bridgeTokens(address(token), 10_000e18, DEST_ROLLUP, dest);
        vm.stopPrank();
    }

    // ── receiveTokens ───────────────────────────────────────────

    function test_receiveTokensUnauthorizedReverts() public {
        vm.prank(alice);
        vm.expectRevert(Bridge.UnauthorizedCaller.selector);
        bridge.receiveTokens(address(token), DEST_ROLLUP, dest, 1, "n", "s", 18, DEST_ROLLUP);
    }

    function test_receiveTokensForeignMintsWrapped() public {
        // originalRollupId != THIS_ROLLUP → mint wrapped.
        vm.prank(address(proxy));
        bridge.receiveTokens(address(token), DEST_ROLLUP, dest, 5_000e18, "Good Token", "GOOD", 18, DEST_ROLLUP);

        address wrapped = bridge.getWrappedToken(address(token), DEST_ROLLUP);
        assertTrue(wrapped != address(0));
        assertEq(WrappedToken(wrapped).balanceOf(dest), 5_000e18);
    }

    function test_receiveTokensForeignExistingWrapped() public {
        // First mint deploys the wrapped token; second reuses it (_getOrDeployWrapped early return).
        vm.startPrank(address(proxy));
        bridge.receiveTokens(address(token), DEST_ROLLUP, dest, 1_000e18, "Good Token", "GOOD", 18, DEST_ROLLUP);
        bridge.receiveTokens(address(token), DEST_ROLLUP, dest, 2_000e18, "Good Token", "GOOD", 18, DEST_ROLLUP);
        vm.stopPrank();

        address wrapped = bridge.getWrappedToken(address(token), DEST_ROLLUP);
        assertEq(WrappedToken(wrapped).balanceOf(dest), 3_000e18);
    }

    function test_receiveTokensNativeReleasesLocked() public {
        // Lock tokens first.
        vm.startPrank(alice);
        token.approve(address(bridge), 10_000e18);
        bridge.bridgeTokens(address(token), 10_000e18, DEST_ROLLUP, dest);
        vm.stopPrank();

        // Now receive with originalRollupId == THIS_ROLLUP → release path.
        vm.prank(address(proxy));
        bridge.receiveTokens(address(token), THIS_ROLLUP, dest, 4_000e18, "", "", 18, DEST_ROLLUP);
        assertEq(token.balanceOf(dest), 4_000e18);
    }

    // ── bridgeTokens (wrapped, burn path) ───────────────────────

    function test_bridgeTokensWrappedBurns() public {
        // Mint a wrapped token to alice first.
        vm.prank(address(proxy));
        bridge.receiveTokens(address(token), DEST_ROLLUP, alice, 6_000e18, "Good Token", "GOOD", 18, DEST_ROLLUP);
        address wrapped = bridge.getWrappedToken(address(token), DEST_ROLLUP);

        vm.prank(alice);
        bridge.bridgeTokens(wrapped, 6_000e18, DEST_ROLLUP, dest);
        // Wrapped tokens burned.
        assertEq(WrappedToken(wrapped).balanceOf(alice), 0);
    }

    // ── views & canonical address ───────────────────────────────

    function test_getWrappedTokenUnsetReturnsZero() public view {
        assertEq(bridge.getWrappedToken(address(token), DEST_ROLLUP), address(0));
    }

    function test_wrappedTokenOnlyBridgeMint() public {
        // Deploy a wrapped token via a foreign receive, then mint/burn directly → OnlyBridge.
        vm.prank(address(proxy));
        bridge.receiveTokens(address(token), DEST_ROLLUP, dest, 1, "Good Token", "GOOD", 18, DEST_ROLLUP);
        WrappedToken wrapped = WrappedToken(bridge.getWrappedToken(address(token), DEST_ROLLUP));

        vm.prank(alice);
        vm.expectRevert(WrappedToken.OnlyBridge.selector);
        wrapped.mint(alice, 1);

        vm.prank(alice);
        vm.expectRevert(WrappedToken.OnlyBridge.selector);
        wrapped.burn(dest, 1);
    }

    function test_canonicalBridgeAddressUsedForProxyLookup() public {
        // Setting a canonical address exercises the `_bridgeAddress` override branch on bridgeTokens.
        vm.prank(admin);
        bridge.setCanonicalBridgeAddress(address(0xCAFE));

        vm.startPrank(alice);
        token.approve(address(bridge), 1_000e18);
        bridge.bridgeTokens(address(token), 1_000e18, DEST_ROLLUP, dest);
        vm.stopPrank();
        assertEq(token.balanceOf(address(bridge)), 1_000e18);
    }
}
