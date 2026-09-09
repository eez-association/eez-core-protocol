// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEEZ} from "../interfaces/IEEZ.sol";
import {ICrossChainProxy} from "../interfaces/ICrossChainProxy.sol";

/// @title CrossChainProxy
/// @notice Proxy contract for cross-chain addresses, deployed via CREATE2
/// @dev Stores the EEZ manager address as an immutable. Dispatch follows the OZ TransparentProxy
///      pattern, keyed on caller AND selector: `executeOnBehalf` from the EEZ manager forwards
///      directly to the destination, and the `staticCheck()` selector from the proxy itself runs
///      the static-context detector. Every other call, whatever its selector, is routed through
///      the cross-chain execution path via _fallback(). A destination that makes the proxy call
///      itself with the `staticCheck()` selector (via executeOnBehalf) reaches the detector rather
///      than a cross-chain call; this is acceptable.
contract CrossChainProxy {
    /// @notice The EEZ manager contract address (`EEZ` on L1, `EEZL2` on L2)
    address internal immutable EEZ;

    /// @dev Dummy transient variable used to detect STATICCALL context.
    ///      Writing to it reverts in a static context; the self-call in _fallback catches this.
    uint256 transient _staticDetector;

    /// @dev Gas for the `staticCheck` probe self-call. In a static context the tstore is an
    ///      exceptional halt that consumes everything forwarded, so the probe must be capped;
    ///      1,000 safely covers the current mutable path (~300 gas).
    ///      Major EVM gas repricing could make proxies unusable.
    uint256 private constant STATIC_CHECK_GAS = 1_000;
    bytes4 private constant STATIC_CHECK_SELECTOR = bytes4(keccak256("staticCheck()"));

    /// @dev Gas cap for the constructor's ether recovery. Bounds what a gas-burning recovery address
    ///      can cost, so deployment still completes after a failed sweep; ample for any plain receiver.
    uint256 private constant RECOVERY_ETHER_GAS = 100_000;

    /// @param _eez The EEZ manager contract address (`EEZ` on L1, `EEZL2` on L2)
    constructor(address _eez) {
        EEZ = _eez;

        // Best-effort sweep of ether sent here before deployment (otherwise stuck —
        // the proxy only forwards msg.value). Ignore transfer failure; ETH then stays here.
        uint256 predeployedEther = address(this).balance;
        if (predeployedEther != 0) {
            // EVM forwards min(RECOVERY_ETHER_GAS, gas available).
            IEEZ(_eez).RECOVERY_ADDRESS().call{value: predeployedEther, gas: RECOVERY_ETHER_GAS}("");
        }
    }

    /// @notice Serves `executeOnBehalf` from the EEZ manager and the `staticCheck()` self-probe; every
    ///         other call goes to `_fallback()`, which executes it as a cross-chain call on EEZ.
    /// @dev Check the caller before ABI decoding so selector collisions with malformed arguments
    ///      still reach the remote fallback. Use ICrossChainProxy for the manager forwarding ABI.
    fallback() external payable {
        if (msg.sender == EEZ && msg.sig == ICrossChainProxy.executeOnBehalf.selector) {
            (address destination, uint64 callGas, bytes memory data) =
                abi.decode(msg.data[4:], (address, uint64, bytes));
            (bool success, bytes memory result) = callGas == 0
                ? destination.call{value: msg.value}(data)
                : destination.call{value: msg.value, gas: callGas}(data);
            assembly {
                switch success
                case 0 { revert(add(result, 0x20), mload(result)) }
                default { return(add(result, 0x20), mload(result)) }
            }
        }
        if (msg.sender == address(this) && msg.sig == STATIC_CHECK_SELECTOR) {
            // Self-calls, run the static detector.
            // TSTORE halts in static context.
            _staticDetector = 0;
            return;
        }
        _fallback();
    }

    /// @dev Internal fallback that forwards the call to the EEZ manager as a cross-chain execution.
    ///      Uses assembly return/revert which terminates the entire call context.
    ///
    ///      Static context detection: a self-call to staticCheck() attempts a transient store.
    ///      If it reverts we're in a STATICCALL — route to staticCrossChainCall (view) instead.
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
        (bool success,) = address(this).call{gas: STATIC_CHECK_GAS}(abi.encodeWithSelector(STATIC_CHECK_SELECTOR));
        bytes memory result;

        if (!success) {
            // Static context — look up pre-computed result via view function
            (success, result) = EEZ.staticcall(abi.encodeCall(IEEZ.staticCrossChainCall, (msg.sender, msg.data)));
        } else {
            // Normal context — execute cross-chain call
            (success, result) =
                EEZ.call{value: msg.value}(abi.encodeCall(IEEZ.executeCrossChainCall, (msg.sender, msg.data)));
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
