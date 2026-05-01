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
    error ContextResult(bytes32 rollingHash, uint256 lastNestedActionConsumed, uint256 currentCallNumber);

    /// @notice Error when executeInContext is called by an external address
    error NotSelf();

    /// @notice Error when ETH transfer to system address fails
    error EtherTransferFailed();

    /// @notice Error when executeInContext reverts with an unexpected error
    error UnexpectedContextRevert(bytes revertData);

    /// @notice Error when not all nested actions were consumed after execution
    error UnconsumedNestedActions();

    /// @notice Error when not all calls were consumed after execution
    error UnconsumedCalls();

    /// @notice Emitted when a new CrossChainProxy is deployed and registered
    event CrossChainProxyCreated(address indexed proxy, address indexed originalAddress, uint256 indexed originalRollupId);

    /// @notice Emitted when execution entries are loaded into the execution table
    event ExecutionTableLoaded(ExecutionEntry[] entries);

    /// @notice Emitted when an execution entry is consumed
    event ExecutionConsumed(bytes32 indexed actionHash, uint256 indexed entryIndex);

    /// @notice Emitted when a cross-chain call is executed via proxy
    event CrossChainCallExecuted(bytes32 indexed actionHash, address indexed proxy, address sourceAddress, bytes callData, uint256 value);

    /// @notice Emitted after each call completes in _processNCalls
    /// @dev Not emitted for calls inside a revertSpan (those events are rolled back by the revert)
    event CallResult(uint256 indexed entryIndex, uint256 indexed callNumber, bool success, bytes returnData);

    /// @notice Emitted when a nested action is consumed during reentrant execution
    event NestedActionConsumed(uint256 indexed entryIndex, uint256 indexed nestedNumber, bytes32 actionHash, uint256 callCount);

    /// @notice Emitted after an entry's execution completes and all verifications pass
    event EntryExecuted(uint256 indexed entryIndex, bytes32 rollingHash, uint256 callsProcessed, uint256 nestedActionsConsumed);

    /// @notice Emitted after a revert span is processed via executeInContext
    event RevertSpanExecuted(uint256 indexed entryIndex, uint256 startCallNumber, uint256 span);

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

    /// @notice Returns true if currently inside a cross-chain call execution
    function _insideExecution() internal view returns (bool) {
        return _currentCallNumber != 0;
    }

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

        if (_insideExecution()) {
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

    /// @notice Consumes the next nested action, or replays a pre-computed reverting
    ///         static call when no NestedAction matches.
    /// @dev See L1 Rollups._consumeNestedAction for the full routing rules. L2 has no
    ///      transient static-call table, so the fallback only scans persistent `staticCalls`.
    function _consumeNestedAction(bytes32 actionHash) internal returns (bytes memory) {
        ExecutionEntry storage entry = executions[_currentEntryIndex];
        uint256 idx = _lastNestedActionConsumed++;

        // 1. NestedAction priority. The `++` above is the commit; if we fall through, every
        //    fallback path reverts and the EVM rolls the bump back.
        if (idx < entry.nestedActions.length && entry.nestedActions[idx].actionHash == actionHash) {
            NestedAction storage nested = entry.nestedActions[idx];
            uint256 nestedNumber = idx + 1; // 1-indexed
            emit NestedActionConsumed(_currentEntryIndex, nestedNumber, actionHash, nested.callCount);
            _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_BEGIN, nestedNumber));
            _processNCalls(nested.callCount);
            _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_END, nestedNumber));
            return nested.returnData;
        }

        // 2. Fallback. Lookup key uses `idx` (pre-bump) — that's what the prover observed.
        uint64 callNum = uint64(_currentCallNumber);
        uint64 lastNA = uint64(idx);
        for (uint256 i = 0; i < staticCalls.length; i++) {
            StaticCall storage sc = staticCalls[i];
            if (
                sc.failed && sc.actionHash == actionHash && sc.callNumber == callNum
                    && sc.lastNestedActionConsumed == lastNA
            ) {
                _resolveStaticCall(sc); // always reverts (sc.failed == true)
            }
        }

        // 3. No match anywhere.
        revert ExecutionNotFound();
    }

    /// @notice Verifies a matched static call entry and returns or reverts with cached data.
    /// @dev Shared between `staticCallLookup` and `_consumeNestedAction`'s fallback path.
    function _resolveStaticCall(StaticCall storage sc) internal view returns (bytes memory) {
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

    /// @notice Consumes the next execution entry, executes calls, and verifies rolling hash
    /// @param actionHash The expected action input hash for the next entry
    /// @return result The pre-computed return data from the action
    function _consumeAndExecute(bytes32 actionHash) internal returns (bytes memory result) {
        uint256 idx = executionIndex++;
        if (idx >= executions.length) revert ExecutionNotFound();

        ExecutionEntry storage entry = executions[idx];
        if (entry.actionHash != actionHash) revert ExecutionNotFound();

        emit ExecutionConsumed(actionHash, idx);

        _currentEntryIndex = idx;
        _rollingHash = bytes32(0);
        _currentCallNumber = 0;
        _lastNestedActionConsumed = 0;

        _processNCalls(entry.callCount);

        if (_rollingHash != entry.rollingHash) revert RollingHashMismatch();
        if (_currentCallNumber != entry.calls.length) revert UnconsumedCalls();
        if (_lastNestedActionConsumed != entry.nestedActions.length) revert UnconsumedNestedActions();

        emit EntryExecuted(idx, _rollingHash, _currentCallNumber, _lastNestedActionConsumed);
        _currentCallNumber = 0; // reset so _insideExecution() returns false

        bytes memory returnData = entry.returnData;

        if (entry.failed) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        return returnData;
    }

    /// @notice Executes calls in an isolated context that always reverts
    function executeInContext(uint256 callCount) external {
        if (msg.sender != address(this)) revert NotSelf();
        _processNCalls(callCount);
        revert ContextResult(_rollingHash, _lastNestedActionConsumed, _currentCallNumber);
    }

    /// @notice Processes N calls from the flat entry.calls[] array
    function _processNCalls(uint256 count) internal {
        ExecutionEntry storage entry = executions[_currentEntryIndex];
        uint256 processed = 0;
        while (processed < count) {
            uint256 revertSpan = entry.calls[_currentCallNumber].revertSpan;

            if (revertSpan == 0) {
                CrossChainCall memory cc = entry.calls[_currentCallNumber];
                _currentCallNumber++;

                _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_BEGIN, _currentCallNumber));

                address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
                if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
                    _createProxyInternal(cc.sourceAddress, cc.sourceRollupId);
                }

                (bool success, bytes memory retData) = sourceProxy.call{value: cc.value}(
                    abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data))
                );

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
            ROLLUP_ID
        );

        uint64 callNum = uint64(_currentCallNumber);
        uint64 lastNA = uint64(_lastNestedActionConsumed);

        for (uint256 i = 0; i < staticCalls.length; i++) {
            StaticCall storage sc = staticCalls[i];
            if (sc.actionHash == actionHash && sc.callNumber == callNum && sc.lastNestedActionConsumed == lastNA) {
                return _resolveStaticCall(sc);
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
            address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
            (bool success, bytes memory retData) = sourceProxy.staticcall(
                abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data))
            );
            computedHash = keccak256(abi.encodePacked(computedHash, success, retData));
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
