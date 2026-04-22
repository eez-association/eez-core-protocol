// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMetaCrossChainReceiver
/// @notice Callback invoked on postBatch's msg.sender (when it has code) after transient
///         entries are loaded and the immediate L2 entry is applied. Gives the caller a
///         chance to consume the transient execution table via cross-chain proxy calls
///         within the same transaction.
interface IMetaCrossChainReceiver {
    function executeMetaCrossChainTransactions() external;
}
