// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEEZRegistry} from "../interfaces/IEEZRegistry.sol";
import {IRollupContract} from "../interfaces/IRollup.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title Rollup
/// @notice Reference per-rollup management contract. Holds proof system membership, vkeys,
///         threshold, and ownership for a single rollup. Anyone can deploy a proxy; its current
///         owner registers it via `EEZ.registerRollup` — the registry never deploys it on the user's
///         behalf.
/// @dev The rollupId is provided by the registry via the `rollupContractRegistered` callback
///      (only callable by `EEZContract`). Stored internally and passed back when this contract
///      calls into the registry (`setRoot(rollupId, root)`), so the registry doesn't need a
///      reverse lookup from contract address to rollupId.
contract Rollup is IRollupContract, OwnableUpgradeable {
    // ──────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────

    /// @notice The central EEZ registry this rollup is registered with
    address public immutable EEZContract;

    // ──────────────────────────────────────────────
    //  Storage
    // ──────────────────────────────────────────────

    /// @notice The rollupId this contract manages. Written once on registration.
    uint64 public rollupId;

    /// @notice Minimum number of proof systems that must attest per batch (M of N). Owner is
    ///         free to set this to any value, including above the current PS count (which
    ///         effectively locks the rollup until more PSes are added).
    /// @dev Enforced internally by `checkProofSystemsAndGetVkeys`; not on the `IRollupContract`
    ///      interface (registry doesn't read it as a separate value).
    uint256 public threshold;

    /// @notice Per-proof-system verification key. `bytes32(0)` = not allowed.
    mapping(address proofSystem => bytes32 vkey) public verificationKey;

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when a proof system is added with its initial verification key.
    event ProofSystemAdded(address indexed proofSystem, bytes32 verificationKey);

    /// @notice Emitted when a proof system is removed from the allowed set.
    event ProofSystemRemoved(address indexed proofSystem);

    /// @notice Emitted when an allowed proof system receives a replacement verification key.
    event VerificationKeyUpdated(address indexed proofSystem, bytes32 newVerificationKey);

    /// @notice Emitted when the threshold is initialized or updated.
    event ThresholdChanged(uint256 newThreshold);

    /// @notice Emitted after the registry accepts an owner-requested root replacement.
    event RootEscape(bytes32 newRoot);

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    /// @notice The registration callback was called by an address other than EEZContract.
    error NotEEZRegistry();

    /// @notice The EEZ contract address is zero.
    error InvalidEEZContract();

    /// @notice A verification key is zero, or initial array lengths differ.
    error InvalidConfig();

    /// @notice A registration callback was received after a rollup ID was already assigned.
    error AlreadyRegistered();

    /// @notice The account registering this manager is not its current owner.
    error UnauthorizedRegistrantAccount(address registrant);

    /// @notice An attempt was made to add a proof system that already has a nonzero key.
    error ProofSystemAlreadyAllowed(address proofSystem);

    /// @notice A submitted proof system has no key, is zero, or breaks strictly increasing address order.
    error ProofSystemNotAllowed(address proofSystem);

    /// @notice A management op (`removeProofSystem` / `updateVerificationKey`) targeted a
    ///         proof system that isn't currently added (zero vkey).
    error ProofSystemNotAdded(address proofSystem);

    /// @notice Reverts during `checkProofSystemsAndGetVkeys` when fewer non-zero vkeys would
    ///         be returned than this manager's threshold requires
    error ThresholdNotMet(uint256 submitted, uint256 required);

    /// @notice `getCustomData` was asked to bind a blockNumber whose `blockhash`
    ///         is unavailable (≥ current block or older than the last 256 blocks → 0).
    error BlockHashUnavailable(uint64 blockNumber);

    // ──────────────────────────────────────────────
    //  Constructor and initialization
    // ──────────────────────────────────────────────

    /// @notice Binds the implementation to EEZ and disables implementation initialization.
    /// @param _EEZContract The central EEZ proxy; preserve this address on upgrades.
    constructor(address _EEZContract) {
        if (_EEZContract == address(0)) revert InvalidEEZContract();
        EEZContract = _EEZContract;
        _disableInitializers();
    }

    /// @notice Initializes proxy storage once; pass this call to the proxy constructor.
    /// @param initialOwner Nonzero owner authorized to manage the rollup.
    /// @param initialThreshold Initial minimum proof-system count, with no upper bound.
    /// @param proofSystems Initial proof-system addresses; duplicates are rejected.
    /// @param vkeys Nonzero verification keys parallel to proofSystems.
    function initialize(
        address initialOwner,
        uint256 initialThreshold,
        address[] memory proofSystems,
        bytes32[] memory vkeys
    )
        external
        initializer
    {
        __Ownable_init(initialOwner);
        if (proofSystems.length != vkeys.length) revert InvalidConfig();
        _setThreshold(initialThreshold);

        for (uint256 i = 0; i < proofSystems.length; i++) {
            _addProofSystem(proofSystems[i], vkeys[i]);
        }
    }

    // ──────────────────────────────────────────────
    //  Registry-facing surface
    // ──────────────────────────────────────────────

    /// @notice Bulk vkey lookup for the chosen PS subset of a posting batch.
    /// @dev Strict: every `proofSystem` in the input MUST be allowed for this rollup
    ///      (non-zero vkey). Reverts `ProofSystemNotAllowed` on the first unknown one. There
    ///      is no zero-padding semantic — the orchestrator must compose batches whose
    ///      proofSystem subset for THIS rollup is a subset of this manager's allowed set,
    ///      and whose size is at least the manager's threshold. Implication: the (rid × ps)
    ///      verificationKeysPerRollup the registry sees is uniformly non-zero.
    /// @param proofSystems Allowed proof-system addresses in strictly increasing order, meeting the threshold.
    /// @return vkeys Nonzero verification keys in the same order as proofSystems.
    function checkProofSystemsAndGetVkeys(address[] calldata proofSystems)
        external
        view
        returns (bytes32[] memory vkeys)
    {
        if (proofSystems.length < threshold) revert ThresholdNotMet(proofSystems.length, threshold);
        vkeys = new bytes32[](proofSystems.length);
        // Strictly-increasing check: rejects address(0) AND duplicates in one pass. The registry
        // already enforces the same invariant on the batch's global PS list and on each
        // rollup's `proofSystemIndexes[]` (so the resolved subset reaches us already sorted),
        // but checking here keeps this manager safe for callers that don't pre-sort.
        address prev = address(0);
        for (uint256 i = 0; i < proofSystems.length; i++) {
            address ps = proofSystems[i];
            if (uint160(ps) <= uint160(prev)) revert ProofSystemNotAllowed(ps);
            bytes32 vk = verificationKey[ps];
            if (vk == bytes32(0)) revert ProofSystemNotAllowed(ps);
            vkeys[i] = vk;
            prev = ps;
        }
    }

    /// @notice Opaque `customData` blob this rollup binds into its per-rollup verification
    ///         commit for the L1 `blockNumber` the batch is bound to. The registry folds the
    ///         result into the batch's shared public input, so the proof attests against this
    ///         exact L1 view.
    /// @dev Reference impl returns ABI-encoded `(timestamp, blockHash)` with timestamp 0: a
    ///      past block's timestamp can't be recovered on-chain (only `block.timestamp` of the
    ///      current block is available), so it's read off-chain from the header instead.
    /// @param blockNumber L1 block to bind. 0 = no block context (empty blob);
    ///        type(uint64).max = latest context (current timestamp + last block header).
    /// @return customData Empty bytes for zero; otherwise ABI-encoded (timestamp, blockHash).
    function getCustomData(uint64 blockNumber) external view returns (bytes memory customData) {
        // 0 is the "no L1 context" sentinel — bind an empty blob.
        if (blockNumber == 0) return "";

        // type(uint64).max is the "latest context" sentinel — bind the current block's
        // timestamp and the most recent available block hash (the previous block).
        if (blockNumber == type(uint64).max) return abi.encode(block.timestamp, blockhash(block.number - 1));

        // `blockhash` only resolves the most recent 256 blocks; the current/future block and
        // anything older than 256 return 0. Reject that: a stale or out-of-range blockNumber
        // must not silently bind a zero hash, which would let a proof built for a different
        // (or absent) L1 view pass verification.
        // If we think is necessary we can use the EIP-2935 for checking last 8k~ block headers
        bytes32 blockHash = blockhash(blockNumber);
        if (blockHash == bytes32(0)) revert BlockHashUnavailable(blockNumber);

        return abi.encode(uint256(0), blockHash);
    }

    /// @notice One-shot registration callback fired by the central registry.
    /// @dev `rollupId == 0` is the unset sentinel (registry assigns ids starting at 1).
    /// @param _rollupId Id the registry assigned to this rollup; stored for later `setRoot` calls.
    /// @param registrant Original caller of `EEZ.registerRollup`, forwarded by the registry.
    function rollupContractRegistered(uint64 _rollupId, address registrant) external {
        if (msg.sender != EEZContract) revert NotEEZRegistry();
        if (rollupId != 0) revert AlreadyRegistered();
        if (registrant != owner()) revert UnauthorizedRegistrantAccount(registrant);
        rollupId = _rollupId;
    }

    // ──────────────────────────────────────────────
    //  Owner-only management
    // ──────────────────────────────────────────────
    //
    // No mid-flow lockout modifier here. Two scenarios to consider:
    //   1. During a `postAndVerifyBatch` meta hook — the registry already snapshotted this rollup's
    //      verificationKeysPerRollup in step 2 of postAndVerifyBatch (before the hook fires in step 6), so any
    //      mutation here doesn't affect the in-flight verification.
    //   2. The setRoot escape hatch — the only path that mutates central state — is
    //      itself gated by the registry's `RollupBatchActiveThisBlock` check.
    // So owner ops are free to run anytime; the registry handles its own lockout where it
    // matters.

    /// @notice Adds a proof system to this rollup's allowed set. The owner is responsible
    ///         for verifying that `proofSystem` is a contract conforming to `IProofSystem`.
    /// @param proofSystem Address to add; it must not already have a verification key.
    /// @param vkey Nonzero verification key for the proof system.
    function addProofSystem(address proofSystem, bytes32 vkey) external onlyOwner {
        _addProofSystem(proofSystem, vkey);
    }

    /// @notice Removes a proof system. Owner is responsible for ensuring the remaining set
    ///         can still meet `threshold`; otherwise the rollup will be locked until more
    ///         PSes are added or `setThreshold` is lowered.
    /// @param proofSystem Currently allowed proof system to remove.
    function removeProofSystem(address proofSystem) external onlyOwner {
        if (verificationKey[proofSystem] == bytes32(0)) revert ProofSystemNotAdded(proofSystem);
        delete verificationKey[proofSystem];
        emit ProofSystemRemoved(proofSystem);
    }

    /// @notice Rotates the verification key for an already-allowed proof system
    /// @param proofSystem Currently allowed proof system whose key is replaced.
    /// @param newVkey Nonzero replacement verification key.
    function updateVerificationKey(address proofSystem, bytes32 newVkey) external onlyOwner {
        if (newVkey == bytes32(0)) revert InvalidConfig();
        if (verificationKey[proofSystem] == bytes32(0)) revert ProofSystemNotAdded(proofSystem);
        verificationKey[proofSystem] = newVkey;
        emit VerificationKeyUpdated(proofSystem, newVkey);
    }

    /// @notice Updates the threshold. Any value is accepted, including values above the
    ///         current PS count (locks the rollup) or zero (any batch passes the threshold
    ///         check). Owner is responsible for picking a sane value.
    /// @param newThreshold Minimum number of distinct allowed proof systems required per batch.
    function setThreshold(uint256 newThreshold) external onlyOwner {
        _setThreshold(newThreshold);
    }

    /// @notice Owner escape hatch — directly sets the rollup's root via the central
    ///         registry. Single state-mutating call from this contract back into EEZ.
    /// @dev Passes `rollupId` explicitly so the registry doesn't need a reverse lookup. The
    ///      registry validates `msg.sender == rollups[rollupId].rollupContract` and reverts
    ///      `RollupBatchActiveThisBlock` if `lastVerifiedBlock(rollupId) == block.number` (i.e.,
    ///      a postAndVerifyBatch has touched this rollup in the current block) — the escape hatch
    ///      is locked out for the rest of the block once a verified state transition lands.
    /// @param newRoot Replacement state root for this rollup.
    function setRoot(bytes32 newRoot) external onlyOwner {
        IEEZRegistry(EEZContract).setRoot(rollupId, newRoot);
        emit RootEscape(newRoot);
    }

    // ──────────────────────────────────────────────
    //  Shared configuration helpers
    // ──────────────────────────────────────────────

    /// @dev Stores a nonzero key for a previously unconfigured proof system and emits ProofSystemAdded.
    /// @param proofSystem Address to add; address validity and interface conformance are not checked here.
    /// @param vkey Nonzero verification key for the proof system.
    function _addProofSystem(address proofSystem, bytes32 vkey) internal {
        if (vkey == bytes32(0)) revert InvalidConfig();
        if (verificationKey[proofSystem] != bytes32(0)) revert ProofSystemAlreadyAllowed(proofSystem);
        verificationKey[proofSystem] = vkey;
        emit ProofSystemAdded(proofSystem, vkey);
    }

    /// @dev Stores the threshold without range checks and emits ThresholdChanged.
    /// @param newThreshold Minimum proof-system count; zero and values above the allowed set size are accepted.
    function _setThreshold(uint256 newThreshold) internal {
        threshold = newThreshold;
        emit ThresholdChanged(newThreshold);
    }
}
