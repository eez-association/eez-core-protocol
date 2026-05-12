// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IRollupContract
/// @notice Per-rollup contract interface — the canonical (or custom) handle that owns proof
///         system membership, vkeys, threshold, and ownership for ONE rollup. Held by the
///         central EEZ registry as `rollups[rid].rollupContract` and queried by the registry
///         during postAndVerifyBatch + state-root escape paths.
/// @dev The central EEZ contract holds the source of truth for state root, ether balance,
///      the deferred queue, and the proxy registry. Everything that mutates a rollup's PS
///      group / threshold / owner happens on this contract; the only call back into the
///      central registry is `setStateRoot` (the owner escape hatch), which `EEZ` allows
///      because `msg.sender` equals the registered `rollupContract`.
interface IRollupContract {
    /// @notice Bulk vkey lookup used by `EEZ.postAndVerifyBatch` for the
    ///         subset of proof systems this rollup chose for the batch.
    /// @dev Strict semantic: every `proofSystems[i]` MUST be allowed for this rollup. The
    ///      implementation MUST revert if any input is not allowed, and MUST revert if
    ///      `proofSystems.length` is below the manager's threshold. On success, every entry
    ///      of the returned `vkeys` is non-zero. The registry consumes the result verbatim;
    ///      successful return means both threshold and per-PS membership are satisfied.
    function checkProofSystemsAndGetVkeys(address[] calldata proofSystems)
        external
        view
        returns (bytes32[] memory vkeys);

    /// @notice Returns the (timestamp, blockHash) pair this rollup binds into its per-rollup
    ///         verification commit during proof verification. Folded one rollup at a time
    ///         into each PS's per-PS rolling accumulator inside `_verifyProofSystemBatch`.
    /// @dev A pure-L1 rollup with no L1→L2 messaging window can simply return
    ///      `(0, bytes32(0))`. A rollup that ingests L1 messages can return the L1 block
    ///      context it has finality for, so the proof commits to "I attest a transition
    ///      consistent with up to this L1 view."
    function getTimestampAndBlockHash() external view returns (uint256 timestamp, bytes32 blockHash);

    /// @notice Notification fired by `EEZ` when this contract becomes the registered manager
    ///         for a rollup via `EEZ.registerRollup`. The implementation MUST accept calls
    ///         only from the central `EEZ` registry.
    /// @dev The rollupId is stored so that subsequent calls from this contract back into the
    ///      registry (`EEZ.setStateRoot(rid, root)`) can pass the id explicitly — the
    ///      registry has no reverse-lookup mapping from contract address to rollupId.
    function rollupContractRegistered(uint256 rollupId) external;
}
