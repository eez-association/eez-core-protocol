// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Manager forwarding ABI, dispatched by the proxy's payable fallback.
interface ICrossChainProxy {
    /// @notice Calls a destination from the proxy, forwarding msg.value and the supplied calldata.
    /// @dev The proxy dispatches this ABI only for its EEZ manager. It bubbles raw return or revert
    ///      data; callers that need return bytes must use a low-level call. Other callers enter
    ///      the cross-chain fallback path even when they use this selector.
    /// @param destination Address to call on the proxy's chain.
    /// @param callGas Gas cap at the destination; zero forwards the gas available under EVM call rules.
    /// @param data Calldata passed to the destination.
    function executeOnBehalf(address destination, uint64 callGas, bytes calldata data) external payable;
}
