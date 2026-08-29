// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Devnet funding helper: tops many accounts up to a target balance in
///         one transaction, so the parallel e2e runner submits one funding tx
///         per chain instead of one per worker (devnet txpools cap pending txs
///         per account at ~20).
contract MultiSend {
    error SendFailed(address to);
    error RefundFailed();

    /// Tops every account in `to` below `floor` wei up to `target` wei (accounts
    /// at or above the floor are left as-is, skipping dust transfers) and refunds
    /// the unspent msg.value to the caller — so the caller attaches the worst
    /// case (to.length * target) without overpaying for reused, still-funded
    /// accounts. A `floor` above `target` degrades to a plain top-up-to-target.
    function fundUpTo(address[] calldata to, uint256 target, uint256 floor) external payable {
        for (uint256 i = 0; i < to.length; i++) {
            uint256 bal = to[i].balance;
            if (bal >= floor || bal >= target) continue;
            (bool ok,) = to[i].call{value: target - bal}("");
            if (!ok) revert SendFailed(to[i]);
        }
        if (address(this).balance > 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            if (!ok) revert RefundFailed();
        }
    }
}
