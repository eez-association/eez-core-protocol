// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Devnet funding helper: sends the same amount of ether to many
///         accounts in one transaction, so the parallel e2e runner submits one
///         funding tx per chain instead of one per worker (devnet txpools cap
///         pending txs per account at ~20).
contract MultiSend {
    error ValueMismatch(uint256 provided, uint256 required);
    error SendFailed(address to);

    /// Sends `amount` wei to every address in `to`; msg.value must match exactly.
    function fund(address[] calldata to, uint256 amount) external payable {
        uint256 required = to.length * amount;
        if (msg.value != required) revert ValueMismatch(msg.value, required);
        for (uint256 i = 0; i < to.length; i++) {
            (bool ok,) = to[i].call{value: amount}("");
            if (!ok) revert SendFailed(to[i]);
        }
    }
}
