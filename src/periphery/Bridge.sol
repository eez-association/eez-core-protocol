// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IEEZ} from "../interfaces/IEEZ.sol";
import {WrappedToken} from "./WrappedToken.sol";

/// @title Bridge
/// @notice Periphery contract for bridging ETH and ERC20 tokens between rollups
/// @dev No constructor args — deployed via CREATE2 at the same address on every chain.
///      Chain-specific config (manager, rollupId, admin) is set via initialize().
///      Uses a lock-and-mint model: native tokens are locked on the source chain,
///      and a WrappedToken is minted on the destination. Burning wrapped tokens
///      releases the native tokens on the origin chain.
///
///      Security model: the inbound function (receiveTokens) validates that
///      msg.sender is the expected CrossChainProxy for this bridge. The execution table
///      (ZK-proven entries) provides the primary security guarantee.
///
///      ILLUSTRATIVE EXAMPLE — not production-hardened. Known, intentional simplifications:
///      no fee-on-transfer token accounting, single initialize() with no chain/deployment-context
///      binding, and no re-deployment authorization. Harden before any production use.
contract Bridge {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────
    struct TokenInfo {
        address originalToken;
        uint64 originalRollupId;
    }

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    /// @notice The cross-chain manager contract (EEZ on L1, EEZL2 on L2)
    IEEZ public manager;

    /// @notice This chain's rollup ID (0 for L1 mainnet)
    uint256 public rollupId;

    /// @notice Admin address that can set the canonical bridge address
    /// @dev Currently used for testing. Decentralized deployment strategy TBD.
    address public admin;

    /// @notice Override for the bridge's canonical address (used for cross-chain proxy lookups)
    /// @dev Currently used for testing. Decentralized deployment strategy TBD.
    address public canonicalBridgeAddress;

    /// @notice Mapping: wrappedSalt => wrappedToken address
    mapping(bytes32 wrappedSalt => address wrappedToken) public wrappedTokens;

    /// @notice Reverse lookup: wrappedToken address => original token info
    mapping(address wrappedToken => TokenInfo tokenInfo) public wrappedTokenInfo;

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error ProxyCallFailed(bytes reason);
    error UnauthorizedCaller();
    error OnlyAdmin();
    error AlreadyInitialized();

    // ──────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────

    /// @dev Validates that msg.sender is the CrossChainProxy representing this bridge from `sourceRollupId`.
    modifier onlyBridgeProxy(uint256 sourceRollupId) {
        address expectedProxy = manager.computeCrossChainProxyAddress(_bridgeAddress(), sourceRollupId);
        if (msg.sender != expectedProxy) revert UnauthorizedCaller();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event Initialized(address indexed manager, uint256 rollupId, address indexed admin);
    event CanonicalBridgeAddressSet(address indexed addr);
    event EtherBridged(address indexed sender, uint256 indexed rollupId, uint256 amount);
    event TokensBridged(address indexed token, address indexed sender, uint256 indexed rollupId, uint256 amount);
    event TokensReleased(address indexed token, address indexed to, uint256 amount);
    event WrappedTokensMinted(address indexed wrappedToken, address indexed to, uint256 amount);
    event WrappedTokenDeployed(
        address indexed wrappedToken, address indexed originalToken, uint256 indexed originalRollupId
    );

    // ──────────────────────────────────────────────
    //  Initialization
    // ──────────────────────────────────────────────

    /// @notice Initialize the bridge with chain-specific config (called once after CREATE2 deployment)
    /// @param _manager The cross-chain manager address
    /// @param _rollupId This chain's rollup ID (0 = L1 mainnet)
    /// @param _admin The admin address that can set the canonical bridge address
    function initialize(address _manager, uint256 _rollupId, address _admin) external {
        if (address(manager) != address(0)) revert AlreadyInitialized();
        if (_manager == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        manager = IEEZ(_manager);
        rollupId = _rollupId;
        admin = _admin;
    }

    // ──────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────

    /// @notice Set the canonical bridge address used for cross-chain proxy lookups
    /// @dev Use this when the Bridge is deployed at a different address on this chain
    ///      than on the counterpart chains. Decentralized deployment strategy TBD.
    function setCanonicalBridgeAddress(address bridgeAddress) external onlyAdmin {
        canonicalBridgeAddress = bridgeAddress;
        emit CanonicalBridgeAddressSet(bridgeAddress);
    }

    // ══════════════════════════════════════════════
    //  OUTBOUND — user-facing bridge operations
    // ══════════════════════════════════════════════

    /// @notice Bridge ETH to destinationAddress on the destination rollup
    /// @param _rollupId The destination rollup ID
    function bridgeEther(uint256 _rollupId, address destinationAddress) external payable {
        if (msg.value == 0) revert ZeroAmount();

        address proxy = _getOrDeployProxy(destinationAddress, _rollupId);
        (bool success, bytes memory reason) = proxy.call{value: msg.value}("");
        if (!success) revert ProxyCallFailed(reason);

        emit EtherBridged(destinationAddress, _rollupId, msg.value);
    }

    /// @notice Bridge an ERC20 token (native or wrapped) to the destination rollup
    /// @dev Native tokens are locked in this contract; wrapped tokens are burned.
    ///      On the destination, receiveTokens either releases native tokens or mints wrapped.
    /// @param token The ERC20 token to bridge (native or wrapped)
    /// @param amount The amount to bridge
    /// @param _rollupId The destination rollup ID
    /// @param destinationAddress The recipient address on the destination rollup
    function bridgeTokens(address token, uint256 amount, uint256 _rollupId, address destinationAddress) external {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert ZeroAddress();

        address bridgeProxy = _getOrDeployProxy(_bridgeAddress(), _rollupId);
        TokenInfo memory info = wrappedTokenInfo[token];

        string memory name;
        string memory symbol;
        uint8 tokenDecimals;
        address originalToken;
        uint256 originalRollupId;

        if (info.originalToken != address(0)) {
            // Wrapped token: burn and trace back to original
            WrappedToken(token).burn(msg.sender, amount);
            originalToken = info.originalToken;
            originalRollupId = info.originalRollupId;
            (name, symbol, tokenDecimals) =
                (IERC20Metadata(token).name(), IERC20Metadata(token).symbol(), IERC20Metadata(token).decimals());
        } else {
            // Native token: lock in this contract
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            originalToken = token;
            originalRollupId = rollupId;
            (name, symbol, tokenDecimals) = _getSafeTokenMetadata(token);
        }

        (bool success, bytes memory reason) = bridgeProxy.call(
            abi.encodeCall(
                this.receiveTokens,
                (originalToken, originalRollupId, destinationAddress, amount, name, symbol, tokenDecimals, rollupId)
            )
        );
        if (!success) revert ProxyCallFailed(reason);

        emit TokensBridged(token, msg.sender, _rollupId, amount);
    }

    // ══════════════════════════════════════════════
    //  INBOUND — called via cross-chain execution
    // ══════════════════════════════════════════════

    /// @notice Receive bridged tokens from another chain
    /// @dev If the token is native to this chain (originalRollupId == rollupId), releases locked tokens.
    ///      Otherwise, deploys/mints a WrappedToken.
    /// @param originalToken The token address on the origin chain
    /// @param originalRollupId The rollup ID where the native token lives
    /// @param to The recipient address
    /// @param amount The amount to receive
    /// @param name The token name (used only on first WrappedToken deployment)
    /// @param symbol The token symbol (used only on first WrappedToken deployment)
    /// @param tokenDecimals The token decimals (used only on first WrappedToken deployment)
    /// @param sourceRollupId The rollup ID the call originates from
    function receiveTokens(
        address originalToken,
        uint256 originalRollupId,
        address to,
        uint256 amount,
        string calldata name,
        string calldata symbol,
        uint8 tokenDecimals,
        uint256 sourceRollupId
    )
        external
        onlyBridgeProxy(sourceRollupId)
    {
        if (originalRollupId == rollupId) {
            // Token is native to this chain → release locked tokens
            IERC20(originalToken).safeTransfer(to, amount);
            emit TokensReleased(originalToken, to, amount);
        } else {
            // Token is foreign → mint wrapped tokens
            address wrapped = _getOrDeployWrapped(originalToken, originalRollupId, name, symbol, tokenDecimals);
            WrappedToken(wrapped).mint(to, amount);
            emit WrappedTokensMinted(wrapped, to, amount);
        }
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice Get the WrappedToken address for a given (originalToken, originalRollupId) pair
    /// @dev Returns address(0) if the token has not been bridged yet.
    function getWrappedToken(address originalToken, uint256 originalRollupId) external view returns (address) {
        return wrappedTokens[_wrappedSalt(originalToken, originalRollupId)];
    }

    // ──────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────

    /// @dev Returns the canonical bridge address: the override if set, otherwise address(this).
    ///      Currently used for testing. Decentralized deployment strategy TBD.
    function _bridgeAddress() internal view returns (address) {
        address canonical = canonicalBridgeAddress;
        return canonical != address(0) ? canonical : address(this);
    }

    /// @dev Computes the deterministic salt for a WrappedToken.
    function _wrappedSalt(address originalToken, uint256 originalRollupId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(originalToken, originalRollupId));
    }

    /// @dev Returns an existing WrappedToken or deploys a new one via CREATE2.
    function _getOrDeployWrapped(
        address originalToken,
        uint256 originalRollupId,
        string calldata name,
        string calldata symbol,
        uint8 tokenDecimals
    )
        internal
        returns (address wrappedAddr)
    {
        // Check if a WrappedToken already exists for this (token, rollup) pair
        bytes32 salt = _wrappedSalt(originalToken, originalRollupId);
        wrappedAddr = wrappedTokens[salt];
        if (wrappedAddr != address(0)) return wrappedAddr;

        // First bridge for this token — deploy a new WrappedToken via CREATE2
        WrappedToken wrapped = new WrappedToken{salt: salt}(name, symbol, tokenDecimals, address(this));

        // Register in both lookup directions: salt → address and address → origin info
        wrappedAddr = address(wrapped);
        wrappedTokens[salt] = wrappedAddr;
        wrappedTokenInfo[wrappedAddr] = TokenInfo(originalToken, uint64(originalRollupId));

        emit WrappedTokenDeployed(wrappedAddr, originalToken, originalRollupId);
    }

    /// @dev Ensures a CrossChainProxy exists for (addr, rollupId), creating it if needed.
    function _getOrDeployProxy(address originalAddress, uint256 _rollupId) internal returns (address proxy) {
        proxy = manager.computeCrossChainProxyAddress(originalAddress, _rollupId);
        if (proxy.code.length == 0) {
            manager.createCrossChainProxy(originalAddress, _rollupId);
        }
    }

    /// @dev Reads token metadata (name, symbol, decimals) with safe fallbacks.
    function _getSafeTokenMetadata(address token)
        internal
        view
        returns (string memory name, string memory symbol, uint8 tokenDecimals)
    {
        try IERC20Metadata(token).name() returns (string memory n) {
            name = n;
        } catch {
            name = "Unknown Token";
        }
        try IERC20Metadata(token).symbol() returns (string memory s) {
            symbol = s;
        } catch {
            symbol = "UNKTKN";
        }
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            tokenDecimals = d;
        } catch {
            tokenDecimals = 18;
        }
    }
}
