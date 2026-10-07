// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EEZ} from "../EEZ.sol";
import {ProofSystemBatchPerVerificationEntries, RollupUpdate} from "../interfaces/IEEZ.sol";
import {IMetaCrossChainReceiver} from "../interfaces/IMetaCrossChainReceiver.sol";

/// @notice Posts EEZ batches with an optional assertion on the last immediate entry's final roots.
contract EEZPostBatcher is IMetaCrossChainReceiver {
    EEZ public immutable eez;

    error OnlyEEZ();
    error LastImmediateRootMismatch(uint64 rollupId, bytes32 expectedRoot, bytes32 actualRoot);

    constructor(EEZ eez_) {
        eez = eez_;
    }

    /// @notice Matches EEZ's batch-posting interface and checks the last immediate entry's final roots.
    function postAndVerifyBatch(ProofSystemBatchPerVerificationEntries calldata batch) external {
        _postBatch(batch, true);
    }

    /// @notice Posts a batch and optionally requires the last immediate entry's final roots.
    /// @dev With no immediate entries, there is nothing to check. This is a final-state assertion:
    ///      it implies earlier execution only when the batch's root dependencies enforce it.
    ///      Sender-bound proofs must bind to this contract, which is EEZ's msg.sender.
    /// @param batch The batch forwarded to EEZ.
    /// @param lastImmediateExecuted Whether to revert unless all roots in the last immediate entry match.
    function postBatch(ProofSystemBatchPerVerificationEntries calldata batch, bool lastImmediateExecuted) external {
        _postBatch(batch, lastImmediateExecuted);
    }

    function _postBatch(ProofSystemBatchPerVerificationEntries calldata batch, bool lastImmediateExecuted) internal {
        eez.postAndVerifyBatch(batch);

        if (!lastImmediateExecuted || batch.immediateEntryCount == 0) return;

        RollupUpdate[] calldata updates = batch.entries[batch.immediateEntryCount - 1].rollupUpdates;
        for (uint256 i = 0; i < updates.length; i++) {
            RollupUpdate calldata update = updates[i];
            (, bytes32 actualRoot,) = eez.rollups(update.rollupId);
            if (actualRoot != update.newRoot) {
                revert LastImmediateRootMismatch(update.rollupId, update.newRoot, actualRoot);
            }
        }
    }

    /// @notice Placeholder for driving immediate cross-chain entries during batch posting.
    function executeMetaCrossChainTransactions() external virtual override {
        if (msg.sender != address(eez)) revert OnlyEEZ();
        // TODO: Implement the batch-posting callback.
    }
}
