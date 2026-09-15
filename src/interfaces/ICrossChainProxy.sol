// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Manager forwarding ABI, dispatched by the proxy's payable fallback.
interface ICrossChainProxy {
    function executeOnBehalf(address destination, uint64 callGas, bytes calldata data) external payable;
}
