// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IRollup
/// @notice Per-rollup contract interface — the canonical (or custom) handle that owns proof
///         system membership, vkeys, threshold, and ownership for ONE rollup. Held by the
///         central Rollups registry as `rollups[rid].rollupContract` and queried by the
///         registry during postBatch + state-root escape paths.
/// @dev The central Rollups contract holds the source of truth for state root, ether
///      balance, the deferred queue, and the proxy registry. Everything that mutates a
///      rollup's PS group / threshold / owner happens on this contract; the only call
///      back into the central registry is `setStateRoot` (the owner escape hatch), which
///      `Rollups` allows because `msg.sender` equals the registered `rollupContract`.
interface IRollup {
    /// @notice Bulk vkey lookup used by `Rollups.postBatch` per sub-batch
    /// @dev Strict semantic: every `proofSystems[i]` MUST be allowed for this rollup. The
    ///      implementation MUST revert if any input is not allowed, and MUST revert if
    ///      `proofSystems.length` is below the manager's threshold. On success, every entry
    ///      of the returned `vkeys` is non-zero. The registry consumes the result verbatim;
    ///      successful return means both threshold and per-PS membership are satisfied. This
    ///      pushes both checks into the manager, so the registry never needs to count
    ///      non-zero entries or read threshold as a separate value (no TOCTOU between two
    ///      reads, no external call surface).
    function getVkeysFromProofSystems(address[] calldata proofSystems) external view returns (bytes32[] memory vkeys);

    /// @notice Notification fired by `Rollups` when this contract becomes the registered
    ///         manager for a rollup — either via `createRollup` (first registration) or via
    ///         `Rollups.setRollupContract` (handoff to a new manager). The implementation MUST
    ///         accept calls only from the central `Rollups` registry. Whether to enforce
    ///         one-shot init (reject overwrites) is implementation-defined: the reference
    ///         `Rollup.sol` allows overwrite (so a single contract can be re-attached on
    ///         handoff), while a stricter manager could latch the first id and reject re-init.
    /// @dev The rollupId is stored so that subsequent calls from this contract back into the
    ///      registry (`Rollups.setStateRoot(rid, root)`) can pass the id explicitly — the
    ///      registry has no reverse-lookup mapping from contract address to rollupId.
    function rollupContractRegistered(uint256 rollupId) external;
}
