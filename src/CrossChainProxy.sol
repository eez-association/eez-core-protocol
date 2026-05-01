// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICrossChainManager} from "./ICrossChainManager.sol";

/// @title CrossChainProxy
/// @notice Proxy contract for cross-chain addresses, deployed via CREATE2
/// @dev Stores manager address, original address, and original rollup ID as immutables.
///      Uses the OZ TransparentProxy pattern: the manager (admin) calling executeOnBehalf
///      gets the direct forwarding behavior; any other caller hitting executeOnBehalf
///      is routed through the cross-chain execution path via _fallback().
contract CrossChainProxy {
    /// @notice The manager contract address
    address internal immutable MANAGER;

    /// @notice The original address this proxy represents
    address internal immutable ORIGINAL_ADDRESS;

    /// @notice The original rollup ID
    uint256 internal immutable ORIGINAL_ROLLUP_ID;

    /// @dev Dummy transient variable used to detect STATICCALL context.
    ///      Writing to it reverts in a static context; the self-call in _fallback catches this.
    uint256 transient _staticDetector;

    /// @param _manager The manager contract address (Rollups on L1, CrossChainManagerL2 on L2)
    /// @param _originalAddress The original address this proxy represents
    /// @param _originalRollupId The original rollup ID
    constructor(address _manager, address _originalAddress, uint256 _originalRollupId) {
        MANAGER = _manager;
        ORIGINAL_ADDRESS = _originalAddress;
        ORIGINAL_ROLLUP_ID = _originalRollupId;
    }

    /// @notice Fallback function that forwards all calls to the manager contract
    /// @dev Uses abi.encodeCall for type-safe encoding, low-level call to preserve raw return/revert data
    fallback() external payable {
        _fallback();
    }

    /// @notice Executes a call on behalf of this proxy identity
    /// @dev When called by the manager, forwards the call to the destination.
    ///      When called by anyone else, routes through _fallback() (cross-chain path),
    ///      similar to OZ's TransparentProxy admin pattern.
    /// @param destination The address to call
    /// @param data The calldata
    function executeOnBehalf(address destination, bytes calldata data) external payable {
        if (msg.sender == MANAGER) {
            (bool success, bytes memory result) = destination.call{value: msg.value}(data);

            assembly {
                switch success
                case 0 { revert(add(result, 0x20), mload(result)) }
                default { return(add(result, 0x20), mload(result)) }
            }
        } else {
            _fallback();
        }
    }

    /// @notice Attempts a tstore to detect STATICCALL context
    /// @dev In a static context, tstore reverts. Called via self-call so the revert is caught.
    ///      When called by anyone other than self, routes through _fallback() (same transparent proxy pattern).
    function staticCheck() external {
        if (msg.sender == address(this)) {
            _staticDetector = 0;
        } else {
            _fallback();
        }
    }

    /// @dev Internal fallback that forwards the call to the manager as a cross-chain execution.
    ///      Uses assembly return/revert which terminates the entire call context.
    ///
    ///      Static context detection: a self-call to staticCheck() attempts a transient store.
    ///      If it reverts we're in a STATICCALL — route to staticCallLookup (view) instead.
    ///
    ///      Result decoding:
    ///      The low-level `.call()` returns ABI-encoded return data. Since `executeCrossChainCall`
    ///      returns `bytes memory`, the raw `result` is double-encoded: the outer ABI encoding
    ///      wraps the inner `bytes` return value. We must `abi.decode(result, (bytes))` to unwrap
    ///      the inner bytes before returning them to the caller.
    ///      On revert, the raw revert data is not ABI-wrapped, so we forward it directly.
    function _fallback() internal {
        // Detect STATICCALL context: tstore reverts in static context, tload does not.
        // A self-call to staticCheck() isolates the tstore so we can catch the revert.
        (bool success,) = address(this).call(abi.encodeCall(this.staticCheck, ()));
        bytes memory result;

        if (!success) {
            // Static context — look up pre-computed result via view function
            (success, result) =
                MANAGER.staticcall(abi.encodeCall(ICrossChainManager.staticCallLookup, (msg.sender, msg.data)));
        } else {
            // Normal context — execute cross-chain call
            (success, result) = MANAGER.call{
                value: msg.value
            }(abi.encodeCall(ICrossChainManager.executeCrossChainCall, (msg.sender, msg.data)));
        }

        if (success) {
            // Decode the inner `bytes` from the ABI-encoded return value
            result = abi.decode(result, (bytes));
        }

        assembly {
            switch success
            case 0 { revert(add(result, 0x20), mload(result)) }
            default { return(add(result, 0x20), mload(result)) }
        }
    }
}
