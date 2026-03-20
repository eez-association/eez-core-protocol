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
///      sequentially. Each entry contains pre-computed calls and a rolling hash for verification.
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

    // ── Rolling hash tag constants ──
    uint8 internal constant CALL_BEGIN = 1;
    uint8 internal constant CALL_END = 2;
    uint8 internal constant NESTED_BEGIN = 3;
    uint8 internal constant NESTED_END = 4;

    // ── Transient execution state (4 variables) ──

    /// @notice The current execution entry being processed
    uint256 transient _currentEntryIndex;

    /// @notice Transient rolling hash accumulating tagged events across the entire entry
    bytes32 transient _rollingHash;

    /// @notice 1-indexed global call counter and cursor into entry.calls[]
    /// @dev Also replaces _insideExecution: _currentCallNumber != 0 means inside execution
    uint256 transient _currentCallNumber;

    /// @notice Sequential nested action consumption counter
    /// @dev Also used by staticCallLookup to disambiguate multiple static calls within the same call
    uint256 transient _lastNestedActionConsumed;

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

    /// @notice Emitted after each call completes in _processNCalls
    /// @dev Not emitted for calls inside a revertSpan (those events are rolled back by the revert)
    event CallResult(uint256 indexed entryIndex, uint256 indexed callNumber, bool success, bytes returnData);

    /// @notice Emitted when a nested action is consumed during reentrant execution
    event NestedActionConsumed(uint256 indexed entryIndex, uint256 indexed nestedNumber, bytes32 actionHash, uint256 callCount);

    /// @notice Emitted after an entry's execution completes and all verifications pass
    event EntryExecuted(uint256 indexed entryIndex, bytes32 rollingHash, uint256 callsProcessed, uint256 nestedActionsConsumed);

    /// @notice Emitted after a revert span is processed via executeInContext
    event RevertSpanExecuted(uint256 indexed entryIndex, uint256 startCallNumber, uint256 span);

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
    error ContextResult(bytes32 rollingHash, uint256 lastNestedActionConsumed, uint256 currentCallNumber);

    /// @notice Error when executeInContext reverts with an unexpected error
    error UnexpectedContextRevert(bytes revertData);

    /// @notice Error when not all nested actions were consumed after execution
    error UnconsumedNestedActions();

    /// @notice Error when not all calls were consumed after execution
    error UnconsumedCalls();

    /// @notice Error when executeCrossChainCall is called during execution with no matching nested action
    error NoNestedActionAvailable();

    /// @notice Error when executeL2TX is called while already inside a cross-chain execution
    error L2TXNotAllowedDuringExecution();

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
        // Push all entries first so _processNCalls can read entry.calls[] from storage
        for (uint256 i = 0; i < entries.length; i++) {
            executions.push(entries[i]);
        }
        for (uint256 i = 0; i < _staticCalls.length; i++) {
            staticCalls.push(_staticCalls[i]);
        }

        // If the first entry has actionHash == 0, apply it immediately
        if (entries.length > 0 && entries[0].actionHash == bytes32(0)) {
            _currentEntryIndex = 0;
            _applyAndExecute(entries[0].stateDeltas, entries[0].callCount, entries[0].rollingHash, 0);
            executionIndex = 1;
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

        if (_insideExecution()) {
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
        if (_insideExecution()) revert L2TXNotAllowedDuringExecution();

        return _consumeAndExecute(bytes32(0), 0);
    }

    // ──────────────────────────────────────────────
    //  Internal execution
    // ──────────────────────────────────────────────

    /// @notice Consumes the next nested action from the current entry
    function _consumeNestedAction(bytes32 actionHash) internal returns (bytes memory) {
        ExecutionEntry storage entry = executions[_currentEntryIndex];
        uint256 idx = _lastNestedActionConsumed++;
        if (idx >= entry.nestedActions.length) revert NoNestedActionAvailable();

        NestedAction storage nested = entry.nestedActions[idx];
        if (nested.actionHash != actionHash) revert ExecutionNotFound();

        uint256 nestedNumber = idx + 1; // 1-indexed
        emit NestedActionConsumed(_currentEntryIndex, nestedNumber, actionHash, nested.callCount);
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_BEGIN, nestedNumber));
        _processNCalls(nested.callCount);
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_END, nestedNumber));

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

        _currentEntryIndex = idx;
        _applyAndExecute(entry.stateDeltas, entry.callCount, entry.rollingHash, etherIn);

        bytes memory returnData = entry.returnData;

        if (entry.failed) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        return returnData;
    }

    /// @notice Applies state deltas, processes calls, verifies rolling hash, and checks ether balance
    function _applyAndExecute(
        StateDelta[] memory deltas,
        uint256 callCount,
        bytes32 rollingHash,
        int256 etherIn
    ) internal {
        _rollingHash = bytes32(0);
        _currentCallNumber = 0;
        _lastNestedActionConsumed = 0;

        int256 etherOut = _processNCalls(callCount);
        int256 totalEtherDelta = _applyStateDeltas(deltas);

        ExecutionEntry storage entry = executions[_currentEntryIndex];
        if (_rollingHash != rollingHash) revert RollingHashMismatch();
        if (_currentCallNumber != entry.calls.length) revert UnconsumedCalls();
        if (_lastNestedActionConsumed != entry.nestedActions.length) revert UnconsumedNestedActions();
        if (totalEtherDelta != etherIn - etherOut) revert EtherDeltaMismatch();

        emit EntryExecuted(_currentEntryIndex, _rollingHash, _currentCallNumber, _lastNestedActionConsumed);
        _currentCallNumber = 0; // reset so _insideExecution() returns false
    }

    /// @notice Processes N calls from the flat entry.calls[] array
    /// @param count Number of iterations to process
    /// @return etherOut Total ETH sent in successful (non-reverted) calls
    function _processNCalls(uint256 count) internal returns (int256 etherOut) {
        ExecutionEntry storage entry = executions[_currentEntryIndex];
        uint256 processed = 0;
        while (processed < count) {
            uint256 revertSpan = entry.calls[_currentCallNumber].revertSpan;

            if (revertSpan == 0) {
                CrossChainCall memory cc = entry.calls[_currentCallNumber];
                _currentCallNumber++;

                _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_BEGIN, _currentCallNumber));

                address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollup);
                if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
                    _createCrossChainProxyInternal(cc.sourceAddress, cc.sourceRollup);
                }

                (bool success, bytes memory retData) = sourceProxy.call{value: cc.value}(
                    abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.destination, cc.data))
                );

                if (cc.value > 0 && success) {
                    etherOut += int256(cc.value);
                }

                _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_END, _currentCallNumber, success, retData));
                emit CallResult(_currentEntryIndex, _currentCallNumber, success, retData);
                processed++;
            } else {
                uint256 savedCallNumber = _currentCallNumber;
                entry.calls[_currentCallNumber].revertSpan = 0;

                try this.executeInContext(revertSpan) {} catch (bytes memory revertData) {
                    (_rollingHash, _lastNestedActionConsumed, _currentCallNumber) = _decodeContextResult(revertData);
                }

                entry.calls[savedCallNumber].revertSpan = revertSpan;
                emit RevertSpanExecuted(_currentEntryIndex, savedCallNumber, revertSpan);
                processed += revertSpan;
            }
        }
    }

    /// @notice Executes calls in an isolated context that always reverts
    function executeInContext(uint256 callCount) external {
        if (msg.sender != address(this)) revert NotSelf();
        _processNCalls(callCount);
        revert ContextResult(_rollingHash, _lastNestedActionConsumed, _currentCallNumber);
    }

    /// @notice Decodes a ContextResult revert payload
    function _decodeContextResult(bytes memory revertData)
        internal pure
        returns (bytes32 rollingHash, uint256 naConsumed, uint256 callNumber)
    {
        if (bytes4(revertData) != ContextResult.selector) {
            revert UnexpectedContextRevert(revertData);
        }
        assembly {
            let ptr := add(revertData, 36)
            rollingHash := mload(ptr)
            naConsumed := mload(add(ptr, 32))
            callNumber := mload(add(ptr, 64))
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

    /// @notice Returns true if currently inside a cross-chain call execution
    function _insideExecution() internal view returns (bool) {
        return _currentCallNumber != 0;
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
    //  Static call lookup
    // ──────────────────────────────────────────────

    /// @notice Looks up a pre-computed static call result from the staticCalls table
    /// @dev Matches by actionHash + current call number + last nested action consumed.
    ///      tload works in static context, so transient tracking variables are readable.
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return The pre-computed return data
    function staticCallLookup(address sourceAddress, bytes calldata callData) external view returns (bytes memory) {
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
        if (proxyInfo.originalAddress == address(0)) revert UnauthorizedProxy();

        bytes32 actionHash = _computeActionInputHash(
            proxyInfo.originalRollupId,
            proxyInfo.originalAddress,
            0, // value is always 0 in static context
            callData,
            sourceAddress,
            MAINNET_ROLLUP_ID
        );

        uint64 callNum = uint64(_currentCallNumber);
        uint64 lastNA = uint64(_lastNestedActionConsumed);

        for (uint256 i = 0; i < staticCalls.length; i++) {
            StaticCall storage sc = staticCalls[i];
            if (sc.actionHash == actionHash && sc.callNumber == callNum && sc.lastNestedActionConsumed == lastNA) {
                if (sc.calls.length > 0) {
                    bytes32 computedHash = _processNStaticCalls(sc.calls);
                    if (computedHash != sc.rollingHash) revert RollingHashMismatch();
                }
                if (sc.failed) {
                    bytes memory returnData = sc.returnData;
                    assembly {
                        revert(add(returnData, 0x20), mload(returnData))
                    }
                }
                return sc.returnData;
            }
        }

        revert ExecutionNotFound();
    }

    /// @notice Executes calls in static context and computes a rolling hash of results
    /// @dev All proxies referenced by the calls must already be deployed — cannot CREATE2 in static context.
    ///      No revertSpan handling — all calls execute as-is (revertSpan correctness is verified by the proof).
    ///      Does not use storage or transient variables — only a local rolling hash.
    function _processNStaticCalls(CrossChainCall[] memory calls) internal view returns (bytes32 computedHash) {
        for (uint256 i = 0; i < calls.length; i++) {
            CrossChainCall memory cc = calls[i];
            address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollup);
            (bool success, bytes memory retData) = sourceProxy.staticcall(
                abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.destination, cc.data))
            );
            computedHash = keccak256(abi.encodePacked(computedHash, success, retData));
        }
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
