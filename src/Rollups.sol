// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IZKVerifier} from "./IZKVerifier.sol";
import {CrossChainProxy} from "./CrossChainProxy.sol";
import {ICrossChainManager, StateDelta, CrossChainCall, NestedAction, StaticCall, ExecutionEntry, ProxyInfo} from "./ICrossChainManager.sol";

/// @notice Rollup configuration
struct RollupConfig {
    address owner;
    bytes32 verificationKey;
    bytes32 stateRoot;
    uint256 etherBalance;
}

/// @title Rollups
/// @notice L1 contract managing rollup state roots, ZK-proven batch posting, and cross-chain call execution
/// @dev Execution entries are posted via `postBatch()` with a ZK proof. Immediate entries (actionHash == 0)
///      update state on the spot. Deferred entries are stored in a flat execution table and consumed
///      sequentially. Each entry contains pre-computed calls and a return hash for verification.
contract Rollups is ICrossChainManager {
    /// @notice The rollup ID representing L1 mainnet
    uint256 public constant MAINNET_ROLLUP_ID = 0;

    /// @notice The ZK verifier contract
    IZKVerifier public immutable ZK_VERIFIER;

    /// @notice Counter for generating rollup IDs
    uint256 public rollupCounter;

    /// @notice Mapping from rollup ID to rollup configuration
    mapping(uint256 rollupId => RollupConfig config) public rollups;

    /// @notice Array of pre-computed executions
    ExecutionEntry[] public executions;

    /// @notice Array of pre-computed static call results
    StaticCall[] public staticCalls;

    /// @notice Index of the next execution entry to consume
    uint256 public executionIndex;

    /// @notice Mapping of authorized CrossChainProxy contracts to their identity
    mapping(address proxy => ProxyInfo info) public authorizedProxies;

    /// @notice Last block number when state was modified
    uint256 public lastStateUpdateBlock;

    /// @notice Index of the next nested action to consume within the current entry
    uint256 transient _nestedActionIndex;

    /// @notice The current execution entry being processed (for nested action consumption)
    uint256 transient _currentEntryIndex;

    /// @notice Whether we're currently inside a cross-chain call execution
    bool transient _insideExecution;

    /// @notice Emitted when a new rollup is created
    event RollupCreated(uint256 indexed rollupId, address indexed owner, bytes32 verificationKey, bytes32 initialState);

    /// @notice Emitted when a rollup state is updated
    event StateUpdated(uint256 indexed rollupId, bytes32 newStateRoot);

    /// @notice Emitted when a rollup verification key is updated
    event VerificationKeyUpdated(uint256 indexed rollupId, bytes32 newVerificationKey);

    /// @notice Emitted when a rollup owner is transferred
    event OwnershipTransferred(uint256 indexed rollupId, address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when a new CrossChainProxy is created
    event CrossChainProxyCreated(address indexed proxy, address indexed originalAddress, uint256 indexed originalRollupId);

    /// @notice Emitted when an L2 execution is performed
    event L2ExecutionPerformed(uint256 indexed rollupId, bytes32 newState);

    /// @notice Emitted when an execution entry is consumed
    event ExecutionConsumed(bytes32 indexed actionHash, uint256 indexed entryIndex);

    /// @notice Emitted when a cross-chain call is executed via proxy
    event CrossChainCallExecuted(bytes32 indexed actionHash, address indexed proxy, address sourceAddress, bytes callData, uint256 value);

    /// @notice Emitted when a precomputed L2 transaction is executed
    event L2TXExecuted(uint256 indexed entryIndex);

    /// @notice Emitted when a batch is posted via postBatch
    event BatchPosted(ExecutionEntry[] entries, bytes32 publicInputsHash);

    /// @notice Error when proof verification fails
    error InvalidProof();

    /// @notice Error when caller is not an authorized proxy
    error UnauthorizedProxy();

    /// @notice Error when executeInContext is called by an external address
    error NotSelf();

    /// @notice Error when execution is not found or actionHash doesn't match next entry
    error ExecutionNotFound();

    /// @notice Error when caller is not the rollup owner
    error NotRollupOwner();

    /// @notice Error when state was already updated in this block
    error StateAlreadyUpdatedThisBlock();

    /// @notice Error when a rollup would have negative ether balance
    error InsufficientRollupBalance();

    /// @notice Error when the ether delta from state deltas doesn't match actual ETH flow
    error EtherDeltaMismatch();

    /// @notice Error when execution is attempted in a different block than the last state update
    error ExecutionNotInCurrentBlock();

    /// @notice Error when the computed rolling hash doesn't match the entry's rollingHash
    error RollingHashMismatch();

    /// @notice Carries execution results out of a reverted context
    error ContextResult(bytes32 computedHash);

    /// @notice Error when executeInContext reverts with an unexpected error
    error UnexpectedContextRevert(bytes revertData);

    /// @notice Error when not all nested actions were consumed after execution
    error UnconsumedNestedActions();

    /// @notice Error when executeCrossChainCall is called during execution with no matching nested action
    error NoNestedActionAvailable();

    /// @param _zkVerifier The ZK verifier contract address
    /// @param startingRollupId The starting ID for rollup numbering
    constructor(address _zkVerifier, uint256 startingRollupId) {
        ZK_VERIFIER = IZKVerifier(_zkVerifier);
        rollupCounter = startingRollupId;
    }

    // ──────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────
    modifier onlyRollupOwner(uint256 rollupId) {
        if (rollups[rollupId].owner != msg.sender) {
            revert NotRollupOwner();
        }
        _;
    }

    // ──────────────────────────────────────────────
    //  Rollup creation
    // ──────────────────────────────────────────────

    /// @notice Creates a new rollup
    /// @param initialState The initial state root for the rollup
    /// @param verificationKey The verification key for state transition proofs
    /// @param owner The owner who can update the verification key and state
    /// @return rollupId The ID of the newly created rollup
    function createRollup(
        bytes32 initialState,
        bytes32 verificationKey,
        address owner
    ) external returns (uint256 rollupId) {
        rollupId = rollupCounter++;
        rollups[rollupId] = RollupConfig({
            owner: owner,
            verificationKey: verificationKey,
            stateRoot: initialState,
            etherBalance: 0
        });
        emit RollupCreated(rollupId, owner, verificationKey, initialState);
    }

    // ──────────────────────────────────────────────
    //  Batch posting & execution table (ZK-proven)
    // ──────────────────────────────────────────────

    /// @notice Posts a batch of execution entries with a single ZK proof
    /// @dev Only the first entry may have actionHash == bytes32(0) (immediate state commitment + optional calls).
    ///      All remaining entries must have actionHash != bytes32(0) and are stored for deferred consumption.
    /// @param entries The execution entries to process
    /// @param _staticCalls The static call results to store
    /// @param blobCount Number of blobs containing shared data
    /// @param callData Shared data passed via calldata
    /// @param proof The ZK proof covering all entries
    function postBatch(
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata _staticCalls,
        uint256 blobCount,
        bytes calldata callData,
        bytes calldata proof
    ) external {
        if (lastStateUpdateBlock == block.number) {
            revert StateAlreadyUpdatedThisBlock();
        }

        // --- Build public inputs ---
        bytes32[] memory entryHashes = _computeEntryHashes(entries);

        bytes32[] memory blobHashes = new bytes32[](blobCount);
        for (uint256 i = 0; i < blobCount; i++) {
            blobHashes[i] = blobhash(i);
        }

        bytes32 publicInputsHash = keccak256(
            abi.encodePacked(
                blockhash(block.number - 1),
                block.timestamp,
                abi.encode(entryHashes),
                abi.encode(blobHashes),
                keccak256(callData)
            )
        );

        _verifyProof(proof, publicInputsHash);

        // Delete previous execution table and reset index
        delete executions;
        delete staticCalls;
        executionIndex = 0;

        // --- Process entries ---
        // First entry may have actionHash == 0 (immediate state commitment with optional calls).
        // All remaining entries must have actionHash != 0 (deferred, consumed via proxy calls).
        uint256 startIdx = 0;
        if (entries.length > 0 && entries[0].actionHash == bytes32(0)) {
            _applyAndExecute(entries[0].stateDeltas, entries[0].calls, entries[0].rollingHash, 0);
            startIdx = 1;
        }
        for (uint256 i = startIdx; i < entries.length; i++) {
            executions.push(entries[i]);
        }
        for (uint256 i = 0; i < _staticCalls.length; i++) {
            staticCalls.push(_staticCalls[i]);
        }

        emit BatchPosted(entries, publicInputsHash);
        lastStateUpdateBlock = block.number;
    }

    /// @notice Computes entry hashes for the public inputs, including verification keys and previous state roots
    function _computeEntryHashes(ExecutionEntry[] calldata entries) internal view returns (bytes32[] memory entryHashes) {
        entryHashes = new bytes32[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            // Gather verification keys and current state roots for each delta's rollup
            bytes32[] memory vks = new bytes32[](entries[i].stateDeltas.length);
            bytes32[] memory prevStates = new bytes32[](entries[i].stateDeltas.length);
            for (uint256 j = 0; j < entries[i].stateDeltas.length; j++) {
                RollupConfig storage cfg = rollups[entries[i].stateDeltas[j].rollupId];
                vks[j] = cfg.verificationKey;
                prevStates[j] = cfg.stateRoot;
            }
            entryHashes[i] = keccak256(
                abi.encodePacked(
                    abi.encode(entries[i].stateDeltas),
                    abi.encode(vks),
                    abi.encode(prevStates),
                    entries[i].actionHash,
                    entries[i].rollingHash
                )
            );
        }
    }

    /// @notice Verifies a ZK proof against the computed public inputs hash
    function _verifyProof(bytes calldata proof, bytes32 publicInputsHash) internal view {
        if (!ZK_VERIFIER.verify(proof, publicInputsHash)) {
            revert InvalidProof();
        }
    }

    // ──────────────────────────────────────────────
    //  L2 execution (proxy entry point)
    // ──────────────────────────────────────────────

    /// @notice Executes a cross-chain call initiated by an authorized proxy
    /// @dev Builds the CALL action from the proxy's identity and msg context, then executes
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return result The return data from the execution
    function executeCrossChainCall(address sourceAddress, bytes calldata callData) external payable returns (bytes memory result) {
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
        if (proxyInfo.originalAddress == address(0)) {
            revert UnauthorizedProxy();
        }

        // Executions can only be consumed in the same block they were posted
        if (lastStateUpdateBlock != block.number) {
            revert ExecutionNotInCurrentBlock();
        }

        // Build the action input hash for matching
        bytes32 actionHash = _computeActionInputHash(
            proxyInfo.originalRollupId,
            proxyInfo.originalAddress,
            msg.value,
            callData,
            sourceAddress,
            MAINNET_ROLLUP_ID
        );

        emit CrossChainCallExecuted(actionHash, msg.sender, sourceAddress, callData, msg.value);

        if (_insideExecution) {
            // Inside a cross-chain call: consume the next nested action
            return _consumeNestedAction(actionHash);
        }

        return _consumeAndExecute(actionHash, int256(msg.value));
    }

    // ──────────────────────────────────────────────
    //  Execute precomputed L2 transaction
    // ──────────────────────────────────────────────

    /// @notice Executes the next L2 transaction from the execution table (permissionless)
    /// @dev The next entry must have actionHash == bytes32(0) and we must not be inside a nested call.
    function executeL2TX() external returns (bytes memory result) {
        if (lastStateUpdateBlock != block.number) {
            revert ExecutionNotInCurrentBlock();
        }
        if (_insideExecution) revert ExecutionNotFound();

        return _consumeAndExecute(bytes32(0), 0);
    }

    // ──────────────────────────────────────────────
    //  Internal execution
    // ──────────────────────────────────────────────

    /// @notice Consumes the next nested action from the current entry
    function _consumeNestedAction(bytes32 actionHash) internal returns (bytes memory) {
        ExecutionEntry storage entry = executions[_currentEntryIndex];
        uint256 idx = _nestedActionIndex++;
        if (idx >= entry.nestedActions.length) revert NoNestedActionAvailable();

        NestedAction storage nested = entry.nestedActions[idx];
        if (nested.actionHash != actionHash) revert ExecutionNotFound();

        // Execute the nested action's cross-chain calls
        _processCrossChainCalls(bytes32(0), nested.calls);

        return nested.returnData;
    }

    /// @notice Consumes the next execution entry, applies state deltas, executes calls, and verifies rolling hash
    /// @param actionHash The expected action input hash for the next entry
    /// @param etherIn The ETH value received (msg.value) for ether accounting
    /// @return result The pre-computed return data from the action
    function _consumeAndExecute(bytes32 actionHash, int256 etherIn) internal returns (bytes memory result) {
        uint256 idx = executionIndex++;
        if (idx >= executions.length) revert ExecutionNotFound();

        ExecutionEntry storage entry = executions[idx];
        if (entry.actionHash != actionHash) revert ExecutionNotFound();

        emit ExecutionConsumed(actionHash, idx);

        // Set execution context for nested action consumption
        _currentEntryIndex = idx;
        _nestedActionIndex = 0;
        _insideExecution = true;

        _applyAndExecute(entry.stateDeltas, entry.calls, entry.rollingHash, etherIn);

        // Verify all nested actions were consumed
        if (_nestedActionIndex != entry.nestedActions.length) revert UnconsumedNestedActions();
        _insideExecution = false;

        bytes memory returnData = entry.returnData;

        // If the action failed, revert with the return data
        if (entry.failed) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        return returnData;
    }

    /// @notice Applies state deltas, processes cross-chain calls, verifies rolling hash, and checks ether balance
    function _applyAndExecute(
        StateDelta[] memory deltas,
        CrossChainCall[] memory calls,
        bytes32 rollingHash,
        int256 etherIn
    ) internal {
        (bytes32 computedHash, int256 etherOut) = _processCrossChainCalls(bytes32(0), calls);
        int256 totalEtherDelta = _applyStateDeltas(deltas);
        if (computedHash != rollingHash) revert RollingHashMismatch();
        if (totalEtherDelta != etherIn - etherOut) revert EtherDeltaMismatch();
    }

    /// @notice Processes cross-chain calls, opening new contexts for revertSpan calls
    /// @param runningHash The accumulated hash from prior calls
    /// @param calls The cross-chain calls to process
    /// @return computedHash The chained hash of all results
    /// @return etherOut Total ETH sent in successful (non-reverted) calls
    function _processCrossChainCalls(bytes32 runningHash, CrossChainCall[] memory calls) internal returns (
        bytes32 computedHash,
        int256 etherOut
    ) {
        computedHash = runningHash;
        uint256 i = 0;
        // Flat sequential iteration — no recursion. Each call is processed in order.
        // Reentrant calls triggered during execution are handled via NestedAction[] on the entry,
        // not by recursive invocations of this function.
        while (i < calls.length) {
            CrossChainCall memory cc = calls[i];

            if (cc.revertSpan > 0) {
                // revertSpan opens an isolated revert context spanning the next N calls (including this one).
                // All state changes within the context are rolled back regardless of success/failure,
                // but the rolling hash is preserved via ContextResult.
                CrossChainCall[] memory contextCalls = new CrossChainCall[](cc.revertSpan);
                for (uint256 j = 0; j < cc.revertSpan; j++) {
                    contextCalls[j] = calls[i + j];
                }
                // Clear revertSpan on the first call so it executes as a normal CALL inside the context,
                // otherwise it would recursively open another revert context.
                contextCalls[0].revertSpan = 0;

                // Self-call that always reverts: isolates state changes while preserving the
                // accumulated rolling hash via the ContextResult error. The hash is assigned
                // directly (not re-hashed) to maintain continuity across revert boundaries.
                try this.executeInContext(computedHash, contextCalls) {
                    // unreachable — executeInContext always reverts with ContextResult
                } catch (bytes memory revertData) {
                    computedHash = _decodeContextResult(revertData);
                }

                // Skip past all calls covered by this revert context
                i += cc.revertSpan;
            } else {
                // Normal call path: route through the source proxy so msg.sender on the
                // destination is the deterministic proxy address (not the manager).
                address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollup);
                if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
                    _createCrossChainProxyInternal(cc.sourceAddress, cc.sourceRollup);
                }

                (bool success, bytes memory retData) = sourceProxy.call{value: cc.value}(
                    abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.destination, cc.data))
                );

                // Track ETH leaving the manager — only on successful calls (reverted calls
                // return the ETH). Verified against state delta ether accounting in _applyAndExecute.
                if (cc.value > 0 && success) {
                    etherOut += int256(cc.value);
                }

                // Chain (success, retData) into the rolling hash for end-to-end verification
                // against entry.rollingHash after all calls are processed.
                computedHash = keccak256(abi.encodePacked(computedHash, success, retData));

                i++;
            }
        }
    }

    /// @notice Executes cross-chain calls in an isolated context that always reverts
    function executeInContext(bytes32 runningHash, CrossChainCall[] calldata calls) external {
        if (msg.sender != address(this)) revert NotSelf();
        (bytes32 computedHash,) = _processCrossChainCalls(runningHash, calls);
        revert ContextResult(computedHash);
    }

    /// @notice Decodes a ContextResult revert payload, reverting if selector doesn't match
    function _decodeContextResult(bytes memory revertData) internal pure returns (bytes32 computedHash) {
        if (bytes4(revertData) != ContextResult.selector) {
            revert UnexpectedContextRevert(revertData);
        }
        assembly {
            computedHash := mload(add(revertData, 36)) // skip length(32) + selector(4)
        }
    }

    /// @notice Applies state deltas and rollup balance changes
    /// @param deltas The state deltas to apply
    /// @return totalEtherDelta The sum of ether deltas across all rollups
    function _applyStateDeltas(StateDelta[] memory deltas) internal returns (int256 totalEtherDelta) {
        for (uint256 i = 0; i < deltas.length; i++) {
            StateDelta memory delta = deltas[i];
            RollupConfig storage config = rollups[delta.rollupId];
            config.stateRoot = delta.newState;
            totalEtherDelta += delta.etherDelta;

            if (delta.etherDelta < 0) {
                uint256 decrement = uint256(-delta.etherDelta);
                if (config.etherBalance < decrement) {
                    revert InsufficientRollupBalance();
                }
                config.etherBalance -= decrement;
            } else if (delta.etherDelta > 0) {
                config.etherBalance += uint256(delta.etherDelta);
            }

            emit L2ExecutionPerformed(delta.rollupId, delta.newState);
        }
    }

    // ──────────────────────────────────────────────
    //  CrossChainProxy creation
    // ──────────────────────────────────────────────

    /// @notice Creates a new CrossChainProxy contract for an original address
    /// @param originalAddress The original address this proxy represents
    /// @param originalRollupId The original rollup ID
    /// @return proxy The address of the deployed CrossChainProxy
    function createCrossChainProxy(address originalAddress, uint256 originalRollupId) external returns (address proxy) {
        return _createCrossChainProxyInternal(originalAddress, originalRollupId);
    }

    /// @notice Deploys a CrossChainProxy via CREATE2 and registers it as authorized
    function _createCrossChainProxyInternal(address originalAddress, uint256 originalRollupId) internal returns (address proxy) {
        bytes32 salt = keccak256(abi.encodePacked(originalRollupId, originalAddress));
        proxy = address(new CrossChainProxy{salt: salt}(address(this), originalAddress, originalRollupId));
        authorizedProxies[proxy] = ProxyInfo(originalAddress, uint64(originalRollupId));
        emit CrossChainProxyCreated(proxy, originalAddress, originalRollupId);
    }

    // ──────────────────────────────────────────────
    //  Rollup management (owner only)
    // ──────────────────────────────────────────────

    /// @notice Updates the state root for a rollup (owner only, no proof required)
    function setStateByOwner(uint256 rollupId, bytes32 newStateRoot) external onlyRollupOwner(rollupId) {
        rollups[rollupId].stateRoot = newStateRoot;
        emit StateUpdated(rollupId, newStateRoot);
    }

    /// @notice Updates the verification key for a rollup (owner only)
    function setVerificationKey(uint256 rollupId, bytes32 newVerificationKey) external onlyRollupOwner(rollupId) {
        rollups[rollupId].verificationKey = newVerificationKey;
        emit VerificationKeyUpdated(rollupId, newVerificationKey);
    }

    /// @notice Transfers ownership of a rollup to a new owner
    function transferRollupOwnership(uint256 rollupId, address newOwner) external onlyRollupOwner(rollupId) {
        address previousOwner = rollups[rollupId].owner;
        rollups[rollupId].owner = newOwner;
        emit OwnershipTransferred(rollupId, previousOwner, newOwner);
    }

    // ──────────────────────────────────────────────
    //  Action hash helpers
    // ──────────────────────────────────────────────

    /// @notice Computes the action input hash from individual fields
    function _computeActionInputHash(
        uint256 rollupId,
        address destination,
        uint256 value,
        bytes memory data,
        address sourceAddress,
        uint256 sourceRollup
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup));
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice Computes the deterministic CREATE2 address for a CrossChainProxy
    /// @param originalAddress The original address this proxy represents
    /// @param originalRollupId The original rollup ID
    /// @return The computed proxy address
    function computeCrossChainProxyAddress(address originalAddress, uint256 originalRollupId) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(originalRollupId, originalAddress));
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(CrossChainProxy).creationCode,
                abi.encode(address(this), originalAddress, originalRollupId)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
