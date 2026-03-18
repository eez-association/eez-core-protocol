// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CrossChainProxy} from "./CrossChainProxy.sol";
import {ICrossChainManager, CrossChainCall, NestedAction, StaticCall, ExecutionEntry, ProxyInfo} from "./ICrossChainManager.sol";

/// @title CrossChainManagerL2
/// @notice L2-side contract for cross-chain execution via pre-computed execution tables
/// @dev No rollups, no state deltas, no ZK proofs. System address loads execution tables,
///      which are consumed sequentially via proxy calls (executeCrossChainCall).
contract CrossChainManagerL2 is ICrossChainManager {
    /// @notice The rollup ID this L2 belongs to
    uint256 public immutable ROLLUP_ID;

    /// @notice The system address authorized for admin operations
    address public immutable SYSTEM_ADDRESS;

    /// @notice Array of pre-computed executions
    ExecutionEntry[] public executions;

    /// @notice Array of pre-computed static call results
    StaticCall[] public staticCalls;

    /// @notice Mapping of authorized CrossChainProxy contracts to their identity
    mapping(address proxy => ProxyInfo info) public authorizedProxies;

    /// @notice Last block number when execution table was loaded
    uint256 public lastLoadBlock;

    /// @notice Index of the next execution entry to consume
    uint256 public executionIndex;

    /// @notice Index of the next nested action to consume within the current entry
    uint256 transient _nestedActionIndex;

    /// @notice The current execution entry being processed (for nested action consumption)
    uint256 transient _currentEntryIndex;

    /// @notice Whether we're currently inside a cross-chain call execution
    bool transient _insideExecution;

    /// @notice Error when caller is not the system address
    error Unauthorized();

    /// @notice Error when caller is not a registered CrossChainProxy
    error UnauthorizedProxy();

    /// @notice Error when no matching execution entry exists for the action hash
    error ExecutionNotFound();

    /// @notice Error when execution is attempted in a different block than the last load
    error ExecutionNotInCurrentBlock();

    /// @notice Error when the computed rolling hash doesn't match the entry's rollingHash
    error RollingHashMismatch();

    /// @notice Carries execution results out of a reverted context
    error ContextResult(bytes32 computedHash);

    /// @notice Error when executeInContext is called by an external address
    error NotSelf();

    /// @notice Error when ETH transfer to system address fails
    error EtherTransferFailed();

    /// @notice Error when executeInContext reverts with an unexpected error
    error UnexpectedContextRevert(bytes revertData);

    /// @notice Error when not all nested actions were consumed after execution
    error UnconsumedNestedActions();

    /// @notice Error when executeCrossChainCall is called during execution with no matching nested action
    error NoNestedActionAvailable();

    /// @notice Emitted when a new CrossChainProxy is deployed and registered
    event CrossChainProxyCreated(address indexed proxy, address indexed originalAddress, uint256 indexed originalRollupId);

    /// @notice Emitted when execution entries are loaded into the execution table
    event ExecutionTableLoaded(ExecutionEntry[] entries);

    /// @notice Emitted when an execution entry is consumed
    event ExecutionConsumed(bytes32 indexed actionHash, uint256 indexed entryIndex);

    /// @notice Emitted when a cross-chain call is executed via proxy
    event CrossChainCallExecuted(bytes32 indexed actionHash, address indexed proxy, address sourceAddress, bytes callData, uint256 value);

    /// @param _rollupId The rollup ID this L2 instance belongs to
    /// @param _systemAddress The privileged address allowed to load execution tables
    constructor(uint256 _rollupId, address _systemAddress) {
        ROLLUP_ID = _rollupId;
        SYSTEM_ADDRESS = _systemAddress;
    }

    modifier onlySystemAddress() {
        if (msg.sender != SYSTEM_ADDRESS) revert Unauthorized();
        _;
    }

    // ──────────────────────────────────────────────
    //  Admin: load execution table
    // ──────────────────────────────────────────────

    /// @notice Loads execution entries and static calls into the execution table (system only)
    /// @dev Clears previous entries and stores new ones. Entries must be consumed in the same block.
    /// @param entries The execution entries to load
    /// @param _staticCalls The static call results to load
    function loadExecutionTable(
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata _staticCalls
    ) external onlySystemAddress {
        // Delete previous execution table and reset index
        delete executions;
        delete staticCalls;
        executionIndex = 0;

        for (uint256 i = 0; i < entries.length; i++) {
            executions.push(entries[i]);
        }
        for (uint256 i = 0; i < _staticCalls.length; i++) {
            staticCalls.push(_staticCalls[i]);
        }
        lastLoadBlock = block.number;
        emit ExecutionTableLoaded(entries);
    }

    // ──────────────────────────────────────────────
    //  Execution entry points
    // ──────────────────────────────────────────────

    /// @notice Executes a cross-chain call initiated by an authorized proxy
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return result The return data from the execution
    function executeCrossChainCall(address sourceAddress, bytes calldata callData) external payable returns (bytes memory result) {
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
        if (proxyInfo.originalAddress == address(0)) revert UnauthorizedProxy();

        // Executions can only be consumed in the same block they were loaded
        if (lastLoadBlock != block.number) revert ExecutionNotInCurrentBlock();

        // burn ether — return to system address
        if (msg.value > 0) {
            (bool success,) = SYSTEM_ADDRESS.call{value: msg.value}("");
            if (!success) revert EtherTransferFailed();
        }

        bytes32 actionHash = _computeActionInputHash(
            proxyInfo.originalRollupId,
            proxyInfo.originalAddress,
            msg.value,
            callData,
            sourceAddress,
            ROLLUP_ID
        );
        emit CrossChainCallExecuted(actionHash, msg.sender, sourceAddress, callData, msg.value);

        if (_insideExecution) {
            // Inside a cross-chain call: consume the next nested action
            return _consumeNestedAction(actionHash);
        }

        return _consumeAndExecute(actionHash);
    }

    // ──────────────────────────────────────────────
    //  Proxy creation
    // ──────────────────────────────────────────────

    /// @notice Creates a new CrossChainProxy for an address on another rollup
    /// @param originalAddress The address this proxy represents on the source rollup
    /// @param originalRollupId The source rollup ID
    /// @return proxy The deployed proxy address
    function createCrossChainProxy(address originalAddress, uint256 originalRollupId) external returns (address proxy) {
        return _createProxyInternal(originalAddress, originalRollupId);
    }

    // ──────────────────────────────────────────────
    //  Internal helpers
    // ──────────────────────────────────────────────

    /// @notice Deploys a CrossChainProxy via CREATE2 and registers it as authorized
    function _createProxyInternal(address originalAddress, uint256 originalRollupId) internal returns (address proxy) {
        bytes32 salt = keccak256(abi.encodePacked(originalRollupId, originalAddress));
        proxy = address(new CrossChainProxy{salt: salt}(address(this), originalAddress, originalRollupId));
        authorizedProxies[proxy] = ProxyInfo(originalAddress, uint64(originalRollupId));
        emit CrossChainProxyCreated(proxy, originalAddress, originalRollupId);
    }

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

    /// @notice Consumes the next execution entry, executes calls, and verifies rolling hash
    /// @param actionHash The expected action input hash for the next entry
    /// @return result The pre-computed return data from the action
    function _consumeAndExecute(bytes32 actionHash) internal returns (bytes memory result) {
        uint256 idx = executionIndex++;
        if (idx >= executions.length) revert ExecutionNotFound();

        ExecutionEntry storage entry = executions[idx];
        if (entry.actionHash != actionHash) revert ExecutionNotFound();

        emit ExecutionConsumed(actionHash, idx);

        // Set execution context for nested action consumption
        _currentEntryIndex = idx;
        _nestedActionIndex = 0;
        _insideExecution = true;

        // Execute all calls and verify rolling hash
        (bytes32 computedHash) = _processCrossChainCalls(bytes32(0), entry.calls);
        if (computedHash != entry.rollingHash) revert RollingHashMismatch();

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

    /// @notice Executes cross-chain calls in an isolated context that always reverts
    /// @dev Can only be called by this contract. Results are encoded in the ContextResult revert.
    function executeInContext(bytes32 runningHash, CrossChainCall[] calldata calls) external {
        if (msg.sender != address(this)) revert NotSelf();
        (bytes32 computedHash) = _processCrossChainCalls(runningHash, calls);
        revert ContextResult(computedHash);
    }

    /// @notice Processes cross-chain calls, opening new contexts for revertSpan calls
    function _processCrossChainCalls(bytes32 runningHash, CrossChainCall[] memory calls) internal returns (
        bytes32 computedHash
    ) {
        computedHash = runningHash;
        uint256 i = 0;
        // Flat sequential iteration — same model as L1 but without ether accounting.
        // Reentrant calls triggered during execution are handled via NestedAction[] on the entry.
        while (i < calls.length) {
            CrossChainCall memory cc = calls[i];

            if (cc.revertSpan > 0) {
                // revertSpan opens an isolated revert context spanning the next N calls (including this one).
                // All state changes are rolled back, but the rolling hash is preserved via ContextResult.
                CrossChainCall[] memory contextCalls = new CrossChainCall[](cc.revertSpan);
                for (uint256 j = 0; j < cc.revertSpan; j++) {
                    contextCalls[j] = calls[i + j];
                }
                // Clear revertSpan on the first call so it executes as a normal CALL inside the context.
                contextCalls[0].revertSpan = 0;

                // Self-call that always reverts: isolates state changes while preserving the
                // accumulated rolling hash via ContextResult. Hash is assigned directly (not re-hashed).
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
                    _createProxyInternal(cc.sourceAddress, cc.sourceRollup);
                }

                (bool success, bytes memory retData) = sourceProxy.call{value: cc.value}(
                    abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.destination, cc.data))
                );

                // Chain (success, retData) into the rolling hash for end-to-end verification
                // against entry.rollingHash after all calls are processed.
                computedHash = keccak256(abi.encodePacked(computedHash, success, retData));

                i++;
            }
        }
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
    /// @param originalAddress The address this proxy represents on the source rollup
    /// @param originalRollupId The source rollup ID
    /// @return The computed proxy address
    function computeCrossChainProxyAddress(
        address originalAddress,
        uint256 originalRollupId
    ) public view returns (address) {
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
