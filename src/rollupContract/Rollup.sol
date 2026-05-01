// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IRollup} from "./IRollup.sol";

/// @notice Minimal interface against the central Rollups registry — only the calls this
///         per-rollup contract needs. Kept inline (rather than imported from `ICrossChainManager`)
///         to keep `Rollup.sol` decoupled from the cross-chain execution model.
interface IRollupsRegistry {
    function setStateRoot(uint256 rollupId, bytes32 newStateRoot) external;
}

/// @title Rollup
/// @notice Reference per-rollup management contract. Holds proof system membership, vkeys,
///         threshold, and ownership for a single rollup. Anyone can deploy this (or a custom
///         contract conforming to `IRollup`) and register it via `Rollups.createRollup` — the
///         central registry never deploys it on the user's behalf.
/// @dev The rollupId is provided by the registry via the `rollupContractRegistered` callback (only
///      callable by `ROLLUPS`). It's stored internally and passed back when this contract
///      calls into the registry (`setStateRoot(rid, root)` etc.), so the registry doesn't need
///      a reverse lookup from contract address to rollupId.
contract Rollup is IRollup {
    /// @notice The central Rollups registry this rollup is registered with
    address public immutable ROLLUPS;

    /// @notice Current owner — controls PS membership, threshold, and the state-root escape hatch.
    /// @dev Implementation detail of THIS reference manager. Not part of `IRollup`; the central
    ///      registry makes no assumption about ownership. Custom managers may use a multisig,
    ///      governance contract, or any other model.
    address public owner;

    /// @notice The rollupId this contract manages. Written by the `rollupContractRegistered` callback,
    ///         on registration (`Rollups.createRollup`) or handoff (`Rollups.setRollupContract`).
    uint256 public rollupId;

    /// @notice Minimum number of proof systems that must attest per batch (M of N). Owner is
    ///         free to set this to any value, including above the current PS count (which
    ///         effectively locks the rollup until more PSes are added).
    /// @dev Enforced internally by `getVkeysFromProofSystems`; not on the `IRollup` interface
    ///      (registry doesn't read it as a separate value).
    uint256 public threshold;

    /// @notice Per-proof-system verification key. `bytes32(0)` = not allowed.
    mapping(address proofSystem => bytes32 vkey) public verificationKey;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ProofSystemAdded(address indexed proofSystem, bytes32 verificationKey);
    event ProofSystemRemoved(address indexed proofSystem);
    event VerificationKeyUpdated(address indexed proofSystem, bytes32 newVerificationKey);
    event ThresholdChanged(uint256 newThreshold);
    event StateRootEscape(bytes32 newStateRoot);

    error NotOwner();
    error NotRollupsRegistry();
    error InvalidConfig();
    error ProofSystemAlreadyAllowed(address proofSystem);
    error ProofSystemNotAllowed(address proofSystem);

    /// @notice Reverts during `getVkeysFromProofSystems` when fewer non-zero vkeys would be
    ///         returned than this manager's threshold requires
    error ThresholdNotMet(uint256 submitted, uint256 required);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param rollupsRegistry The central Rollups contract
    /// @param _owner Initial owner
    /// @param _threshold Initial threshold — owner picks any value (no upper bound against
    ///        the initial PS list).
    /// @param proofSystems Initial proof system addresses — any contract conforming to
    ///        `IProofSystem`. There is no central registry; the rollup owner is responsible
    ///        for vetting each proof system before adding it.
    /// @param vkeys Initial verification keys (parallel to proofSystems; non-zero, no duplicates)
    constructor(
        address rollupsRegistry,
        address _owner,
        uint256 _threshold,
        address[] memory proofSystems,
        bytes32[] memory vkeys
    ) {
        if (rollupsRegistry == address(0)) revert InvalidConfig();
        if (_owner == address(0)) revert InvalidConfig();
        if (proofSystems.length != vkeys.length) revert InvalidConfig();

        ROLLUPS = rollupsRegistry;
        owner = _owner;
        threshold = _threshold;

        for (uint256 i = 0; i < proofSystems.length; i++) {
            address ps = proofSystems[i];
            if (vkeys[i] == bytes32(0)) revert InvalidConfig();
            if (verificationKey[ps] != bytes32(0)) revert ProofSystemAlreadyAllowed(ps);
            verificationKey[ps] = vkeys[i];
        }
    }

    // ──────────────────────────────────────────────
    //  IRollup
    // ──────────────────────────────────────────────

    /// @inheritdoc IRollup
    /// @dev Strict: every `proofSystem` in the input MUST be allowed for this rollup
    ///      (non-zero vkey). Reverts `ProofSystemNotAllowed` on the first unknown one. There
    ///      is no zero-padding semantic — the orchestrator must compose sub-batches whose
    ///      proofSystem set is a subset of EVERY participating rollup's allowed set, and
    ///      whose size is at least each rollup's threshold. Implication: the (rid × ps)
    ///      vkMatrix the registry sees is uniformly non-zero.
    function getVkeysFromProofSystems(address[] calldata proofSystems) external view returns (bytes32[] memory vkeys) {
        if (proofSystems.length < threshold) revert ThresholdNotMet(proofSystems.length, threshold);
        vkeys = new bytes32[](proofSystems.length);
        for (uint256 i = 0; i < proofSystems.length; i++) {
            bytes32 vk = verificationKey[proofSystems[i]];
            if (vk == bytes32(0)) revert ProofSystemNotAllowed(proofSystems[i]);
            vkeys[i] = vk;
        }
    }

    /// @inheritdoc IRollup
    /// @dev Auth: caller MUST be the central `ROLLUPS` registry, otherwise `NotRollupsRegistry`.
    ///      This impl does NOT enforce one-shot semantics — overwriting `rollupId` is allowed
    ///      so the same contract can be re-attached to a different rollup via
    ///      `Rollups.setRollupContract` handoff. A stricter manager could latch the first id.
    function rollupContractRegistered(uint256 _rollupId) external {
        if (msg.sender != ROLLUPS) revert NotRollupsRegistry();
        rollupId = _rollupId;
    }

    // ──────────────────────────────────────────────
    //  Owner-only management
    // ──────────────────────────────────────────────
    //
    // No mid-flow lockout modifier here. Two scenarios to consider:
    //   1. During a `postBatch` meta hook — the registry already snapshotted this rollup's
    //      vkMatrix in step 2 of postBatch (before the hook fires in step 6), so any
    //      mutation here doesn't affect the in-flight verification.
    //   2. The setStateRoot escape hatch — the only path that mutates central state — is
    //      itself gated by the registry's `RollupBatchActiveThisBlock` check.
    // So owner ops are free to run anytime; the registry handles its own lockout where it
    // matters.

    /// @notice Adds a proof system to this rollup's allowed set. The owner is responsible
    ///         for verifying that `proofSystem` is a contract conforming to `IProofSystem`.
    function addProofSystem(address proofSystem, bytes32 vkey) external onlyOwner {
        if (vkey == bytes32(0)) revert InvalidConfig();
        if (verificationKey[proofSystem] != bytes32(0)) revert ProofSystemAlreadyAllowed(proofSystem);
        verificationKey[proofSystem] = vkey;
        emit ProofSystemAdded(proofSystem, vkey);
    }

    /// @notice Removes a proof system. Owner is responsible for ensuring the remaining set
    ///         can still meet `threshold`; otherwise the rollup will be locked until more
    ///         PSes are added or `setThreshold` is lowered.
    function removeProofSystem(address proofSystem) external onlyOwner {
        if (verificationKey[proofSystem] == bytes32(0)) revert ProofSystemNotAllowed(proofSystem);
        delete verificationKey[proofSystem];
        emit ProofSystemRemoved(proofSystem);
    }

    /// @notice Rotates the verification key for an already-allowed proof system
    function setVerificationKey(address proofSystem, bytes32 newVkey) external onlyOwner {
        if (newVkey == bytes32(0)) revert InvalidConfig();
        if (verificationKey[proofSystem] == bytes32(0)) revert ProofSystemNotAllowed(proofSystem);
        verificationKey[proofSystem] = newVkey;
        emit VerificationKeyUpdated(proofSystem, newVkey);
    }

    /// @notice Updates the threshold. Any value is accepted, including values above the
    ///         current PS count (locks the rollup) or zero (any batch passes the threshold
    ///         check). Owner is responsible for picking a sane value.
    function setThreshold(uint256 newThreshold) external onlyOwner {
        threshold = newThreshold;
        emit ThresholdChanged(newThreshold);
    }

    /// @notice Transfers ownership of this rollup
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidConfig();
        address previous = owner;
        owner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
    }

    /// @notice Owner escape hatch — directly sets the rollup's state root via the central
    ///         registry. Single state-mutating call from this contract back into Rollups.
    /// @dev Passes `rollupId` explicitly so the registry doesn't need a reverse lookup. The
    ///      registry validates `msg.sender == rollups[rollupId].rollupContract` and reverts
    ///      `RollupBatchActiveThisBlock` if `lastVerifiedBlock(rid) == block.number` (i.e.,
    ///      a postBatch has touched this rollup in the current block) — the escape hatch
    ///      is locked out for the rest of the block once a verified state transition lands.
    function setStateRoot(bytes32 newStateRoot) external onlyOwner {
        IRollupsRegistry(ROLLUPS).setStateRoot(rollupId, newStateRoot);
        emit StateRootEscape(newStateRoot);
    }
}
