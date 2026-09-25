// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IMetaCrossChainReceiver
/// @notice Callback invoked on postAndVerifyBatch's msg.sender (when it has code) after the leading
///         immediate L2Tx entries have run. Gives the caller — e.g. an account-abstraction entrypoint — a
///         chance to consume the remaining immediate entries (the transient execution table) via
///         cross-chain proxy calls within the same transaction.
interface IMetaCrossChainReceiver {
    /// @notice Drives immediate cross-chain entries during the batch-posting callback.
    /// @dev EEZ invokes this on the batch caller after attempting the leading immediate L2 transactions
    ///      and loading the remaining immediate entries. Implementations define their own caller checks.
    function executeMetaCrossChainTransactions() external;
}
