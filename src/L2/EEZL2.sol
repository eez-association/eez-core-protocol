// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CrossChainProxy} from "../base/CrossChainProxy.sol";
import {L2ToL1Call, ExpectedL1ToL2Call, LookupCall, ExecutionEntry, ProxyInfo} from "../interfaces/IEEZ.sol";
import {EEZBase} from "../base/EEZBase.sol";

/// @title EEZL2
/// @notice L2-side contract for cross-chain execution via pre-computed execution tables
/// @dev No rollups, no state deltas, no ZK proofs. System address loads execution tables,
///      which are consumed sequentially via proxy calls (executeCrossChainCall).
contract EEZL2 is EEZBase {
    /// @notice The rollup ID this L2 belongs to
    uint256 public immutable ROLLUP_ID;

    /// @notice The system address authorized for admin operations
    address public immutable SYSTEM_ADDRESS;

    /// @notice Array of pre-computed executions
    ExecutionEntry[] public executions;

    /// @notice Array of pre-computed lookup call results
    LookupCall[] public lookupCalls;

    /// @notice Mapping of authorized CrossChainProxy contracts to their identity
    mapping(address proxy => ProxyInfo info) public authorizedProxies;

    /// @notice Last block number when execution table was loaded
    uint256 public lastLoadBlock;

    /// @notice Index of the next execution entry to consume
    uint256 public executionIndex;

    // Rolling-hash tag constants and the `_rollingHash` transient accumulator live on
    // `EEZBase` (shared with the L1 `EEZ` contract).

    // ── Transient execution state (3 variables) ──

    /// @notice The current execution entry being processed
    uint256 transient _currentEntryIndex;

    /// @notice 1-indexed global call counter and cursor into entry.L2ToL1Calls[]
    /// @dev Also replaces _insideExecution: _currentCallNumber != 0 means inside execution
    uint256 transient _currentCallNumber;

    /// @notice Sequential nested action consumption counter
    /// @dev Also used by staticCallLookup to disambiguate multiple lookup calls within the same call
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

    /// @notice Error when executeInContextAndRevert is called by an external address
    error NotSelf();

    /// @notice Error when ETH transfer to system address fails
    error EtherTransferFailed();

    /// @notice Error when executeInContextAndRevert reverts with an unexpected error
    error UnexpectedContextRevert(bytes revertData);

    /// @notice Error when not all nested actions were consumed after execution
    error UnconsumedNestedActions();

    /// @notice Error when not all calls were consumed after execution
    error UnconsumedCalls();

    /// @notice Error when executeIncomingCrossChainCall is called with no entries
    error EmptyEntries();

    /// @notice Error when msg.value attached to executeIncomingCrossChainCall doesn't match `value`
    error ValueMismatch();

    /// @notice Emitted when a new CrossChainProxy is deployed and registered
    event CrossChainProxyCreated(
        address indexed proxy, address indexed originalAddress, uint256 indexed originalRollupId
    );

    /// @notice Emitted when execution entries are loaded into the execution table
    event ExecutionTableLoaded(ExecutionEntry[] entries);

    /// @notice Emitted when an execution entry is consumed
    event ExecutionConsumed(bytes32 indexed crossChainCallHash, uint256 indexed entryIndex);

    /// @notice Emitted when a cross-chain call is executed via proxy
    event CrossChainCallExecuted(
        bytes32 indexed crossChainCallHash, address indexed proxy, address sourceAddress, bytes callData, uint256 value
    );

    /// @notice Emitted when the system address initiates an incoming cross-chain call from another rollup
    event IncomingCrossChainCallExecuted(
        bytes32 indexed crossChainCallHash,
        address destination,
        uint256 value,
        bytes data,
        address sourceAddress,
        uint256 sourceRollup
    );

    /// @notice Emitted after each call completes in _processNCalls
    /// @dev Not emitted for calls inside a revertSpan (those events are rolled back by the revert)
    event CallResult(uint256 indexed entryIndex, uint256 indexed callNumber, bool success, bytes returnData);

    /// @notice Emitted when a nested action is consumed during reentrant execution
    event NestedActionConsumed(
        uint256 indexed entryIndex, uint256 indexed nestedNumber, bytes32 crossChainCallHash, uint256 callCount
    );

    /// @notice Emitted after an entry's execution completes and all verifications pass
    event EntryExecuted(
        uint256 indexed entryIndex, bytes32 rollingHash, uint256 callsProcessed, uint256 nestedActionsConsumed
    );

    /// @notice Emitted after a revert span is processed via executeInContextAndRevert
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

    /// @notice Loads execution entries and lookup calls into the execution table (system only)
    /// @dev Clears previous entries and stores new ones. Entries must be consumed in the same block.
    /// @param entries The execution entries to load
    /// @param _lookupCalls The lookup call results to load
    function loadExecutionTable(ExecutionEntry[] calldata entries, LookupCall[] calldata _lookupCalls)
        external
        onlySystemAddress
    {
        _loadExecutionTable(entries, _lookupCalls);
    }

    /// @notice Internal: replaces the execution table and resets the consumption cursor
    /// @dev Shared between `loadExecutionTable` and `executeIncomingCrossChainCall`
    function _loadExecutionTable(ExecutionEntry[] calldata entries, LookupCall[] calldata _lookupCalls) internal {
        delete executions;
        delete lookupCalls;
        executionIndex = 0;

        for (uint256 i = 0; i < entries.length; i++) {
            executions.push(entries[i]);
        }
        for (uint256 i = 0; i < _lookupCalls.length; i++) {
            lookupCalls.push(_lookupCalls[i]);
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
    function executeCrossChainCall(address sourceAddress, bytes calldata callData)
        external
        payable
        returns (bytes memory result)
    {
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
        if (proxyInfo.originalAddress == address(0)) revert UnauthorizedProxy();

        // Executions can only be consumed in the same block they were loaded
        if (lastLoadBlock != block.number) revert ExecutionNotInCurrentBlock();

        // burn ether — return to system address
        if (msg.value > 0) {
            (bool success,) = SYSTEM_ADDRESS.call{value: msg.value}("");
            if (!success) revert EtherTransferFailed();
        }

        bytes32 crossChainCallHash = computeCrossChainCallHash(
            proxyInfo.originalRollupId, proxyInfo.originalAddress, msg.value, callData, sourceAddress, ROLLUP_ID
        );
        emit CrossChainCallExecuted(crossChainCallHash, msg.sender, sourceAddress, callData, msg.value);

        if (_insideExecution()) {
            // Inside a cross-chain call: consume the next nested action
            return _consumeNestedAction(crossChainCallHash);
        }

        return _consumeAndExecute(crossChainCallHash);
    }

    /// @notice System-initiated execution of an incoming cross-chain call from another rollup
    /// @dev Atomically replaces the execution table and drives `executions[0]` through the
    ///      flat call processor. The first entry's `calls[0]` is the inbound call itself
    ///      (its `sourceAddress` / `sourceRollupId` / `targetAddress` / `value` / `data` must
    ///      match the explicit params passed here — the prover builds them consistently).
    ///      `_processNCalls` makes the actual proxy invocation, advances the call counter,
    ///      folds tagged events into the rolling hash, and handles `revertSpan`. Reentrant
    ///      cross-chain calls during execution see `_insideExecution() == true` and consume
    ///      from `executions[0].nestedActions`.
    /// @param destination The L2 destination address (target of the inbound call)
    /// @param value The ETH value forwarded to the destination
    /// @param data The calldata for the destination
    /// @param sourceAddress The original caller address on the source rollup
    /// @param sourceRollup The source rollup ID
    /// @param entries The execution entries to load (entries[0] is consumed by this call)
    /// @param _lookupCalls The lookup call results to load (used for STATICCALL / failed reentrants)
    /// @return result The pre-computed return data from `executions[0]`
    function executeIncomingCrossChainCall(
        address destination,
        uint256 value,
        bytes calldata data,
        address sourceAddress,
        uint256 sourceRollup,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata _lookupCalls
    )
        external
        payable
        onlySystemAddress
        returns (bytes memory result)
    {
        if (entries.length == 0) revert EmptyEntries();
        // ETH model: the system mints `value` on L2 by attaching it to msg.value. That ETH
        // lives in the manager balance and is drawn down by `_processNCalls` when it forwards
        // through the source proxy (`sourceProxy.call{value: cc.value}(...)`). Strict equality
        // — not >= — so any drift between the system's intent and the prover-bound `value`
        // surfaces here instead of as a rolling-hash mismatch deep inside `_processNCalls`.
        if (msg.value != value) revert ValueMismatch();

        // 1. Replace the execution table (same logic as loadExecutionTable)
        _loadExecutionTable(entries, _lookupCalls);

        // 2. Compute and emit the action hash binding this top-level call
        bytes32 crossChainCallHash =
            computeCrossChainCallHash(ROLLUP_ID, destination, value, data, sourceAddress, sourceRollup);
        emit IncomingCrossChainCallExecuted(crossChainCallHash, destination, value, data, sourceAddress, sourceRollup);

        // 3. No entry-context preamble needed: `_currentEntryIndex`, `_rollingHash`,
        //    `_currentCallNumber`, `_lastNestedActionConsumed` are all `transient` and
        //    default to zero at the start of every tx. SYSTEM_ADDRESS invokes this as a
        //    top-level call, once per tx — so they're already what `_processNCalls`
        //    expects (entry index 0, fresh rolling hash, call cursor at 0, nested cursor at 0).
        ExecutionEntry storage entry = executions[0];

        // 4. Drive the flat call processor — `entry.L2ToL1Calls[0]` is the inbound call,
        //    delivered via the source proxy by `_processNCalls`
        _processNCalls(entry.callCount);

        // 5. Verify invariants (mirrors `_consumeAndExecute`'s post-checks)
        if (_rollingHash != entry.rollingHash) revert RollingHashMismatch();
        if (_currentCallNumber != entry.L2ToL1Calls.length) revert UnconsumedCalls();
        if (_lastNestedActionConsumed != entry.expectedL1ToL2Calls.length) revert UnconsumedNestedActions();

        emit EntryExecuted(0, _rollingHash, _currentCallNumber, _lastNestedActionConsumed);
        _currentCallNumber = 0; // reset so _insideExecution() returns false

        return entry.returnData;
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
    ///         lookup call when no ExpectedL1ToL2Call matches.
    /// @dev See L1 EEZ._consumeNestedAction for the full routing rules. L2 has no
    ///      transient lookup-call table, so the fallback only scans persistent `lookupCalls`.
    function _consumeNestedAction(bytes32 crossChainCallHash) internal returns (bytes memory) {
        ExecutionEntry storage entry = executions[_currentEntryIndex];
        uint256 idx = _lastNestedActionConsumed++;

        // 1. ExpectedL1ToL2Call priority. The `++` above is the commit; if we fall through, every
        //    fallback path reverts and the EVM rolls the bump back.
        if (
            idx < entry.expectedL1ToL2Calls.length
                && entry.expectedL1ToL2Calls[idx].crossChainCallHash == crossChainCallHash
        ) {
            ExpectedL1ToL2Call storage nested = entry.expectedL1ToL2Calls[idx];
            uint256 nestedNumber = idx + 1; // 1-indexed
            emit NestedActionConsumed(_currentEntryIndex, nestedNumber, crossChainCallHash, nested.callCount);
            _rollingHashNestedBegin(nestedNumber);
            _processNCalls(nested.callCount);
            _rollingHashNestedEnd(nestedNumber);
            return nested.returnData;
        }

        // 2. Fallback. Lookup key uses `idx` (pre-bump) — that's what the prover observed.
        uint64 callNum = uint64(_currentCallNumber);
        uint64 lastNA = uint64(idx);
        for (uint256 i = 0; i < lookupCalls.length; i++) {
            LookupCall storage sc = lookupCalls[i];
            if (
                sc.failed && sc.crossChainCallHash == crossChainCallHash && sc.callNumber == callNum
                    && sc.lastNestedActionConsumed == lastNA
            ) {
                _resolveLookupCall(sc); // always reverts (sc.failed == true)
            }
        }

        // 3. No match anywhere.
        revert ExecutionNotFound();
    }

    /// @notice Verifies a matched lookup call entry and returns or reverts with cached data.
    /// @dev Shared between `staticCallLookup` and `_consumeNestedAction`'s fallback path.
    function _resolveLookupCall(LookupCall storage sc) internal view returns (bytes memory) {
        if (sc.calls.length > 0) {
            bytes32 computedHash = _processNLookupCalls(sc.calls);
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

    /// @notice Top-level fallback: scan persistent `lookupCalls` for a `LookupCall` with
    ///         `failed=true` matching `(crossChainCallHash, callNumber=0, lastNestedActionConsumed=0)`.
    ///         The (0,0) lookup key denotes top-level context — disjoint from the nested
    ///         fallback path which always observes `callNumber > 0`. On match,
    ///         `_resolveLookupCall` reverts with the cached `returnData`; on no match,
    ///         returns so the caller reverts `ExecutionNotFound`.
    function _tryRevertedTopLevelLookup(bytes32 crossChainCallHash) internal view {
        for (uint256 i = 0; i < lookupCalls.length; i++) {
            LookupCall storage sc = lookupCalls[i];
            if (
                sc.failed && sc.crossChainCallHash == crossChainCallHash && sc.callNumber == 0
                    && sc.lastNestedActionConsumed == 0
            ) {
                _resolveLookupCall(sc); // always reverts (sc.failed == true)
            }
        }
    }

    /// @notice Consumes the next execution entry, executes calls, and verifies rolling hash
    /// @dev Miss path: when the cursor is out of bounds or the next entry's `proxyEntryHash` doesn't
    ///      match, `_tryRevertedTopLevelLookup` scans persistent `lookupCalls` for a `failed=true`
    ///      `LookupCall` keyed by `(crossChainCallHash, callNumber=0, lastNestedActionConsumed=0)`.
    ///      On match, that helper reverts with the cached `returnData` (so the caller's `try/catch`
    ///      observes the prover-specified revert). On no match the helper returns and we revert
    ///      `ExecutionNotFound`. The cursor is NOT advanced on the miss path.
    /// @param crossChainCallHash The expected action input hash for the next entry
    /// @return result The pre-computed return data from the action
    function _consumeAndExecute(bytes32 crossChainCallHash) internal returns (bytes memory result) {
        uint256 idx = executionIndex;
        if (idx >= executions.length || executions[idx].proxyEntryHash != crossChainCallHash) {
            // Try reverted-lookup fallback (always reverts on match); otherwise ExecutionNotFound
            _tryRevertedTopLevelLookup(crossChainCallHash);
            revert ExecutionNotFound();
        }
        executionIndex = idx + 1;
        ExecutionEntry storage entry = executions[idx];

        emit ExecutionConsumed(crossChainCallHash, idx);

        _currentEntryIndex = idx;
        _rollingHash = bytes32(0);
        _currentCallNumber = 0;
        _lastNestedActionConsumed = 0;

        _processNCalls(entry.callCount);

        if (_rollingHash != entry.rollingHash) revert RollingHashMismatch();
        if (_currentCallNumber != entry.L2ToL1Calls.length) revert UnconsumedCalls();
        if (_lastNestedActionConsumed != entry.expectedL1ToL2Calls.length) revert UnconsumedNestedActions();

        emit EntryExecuted(idx, _rollingHash, _currentCallNumber, _lastNestedActionConsumed);
        _currentCallNumber = 0; // reset so _insideExecution() returns false

        return entry.returnData;
    }

    /// @notice Executes calls in an isolated context that always reverts
    function executeInContextAndRevert(uint256 callCount) external {
        if (msg.sender != address(this)) revert NotSelf();
        _processNCalls(callCount);
        revert ContextResult(_rollingHash, _lastNestedActionConsumed, _currentCallNumber);
    }

    /// @notice Processes N calls from the flat entry.L2ToL1Calls[] array
    function _processNCalls(uint256 count) internal {
        ExecutionEntry storage entry = executions[_currentEntryIndex];
        uint256 processed = 0;
        while (processed < count) {
            uint256 revertSpan = entry.L2ToL1Calls[_currentCallNumber].revertSpan;

            if (revertSpan == 0) {
                L2ToL1Call memory cc = entry.L2ToL1Calls[_currentCallNumber];
                _currentCallNumber++;

                _rollingHashCallBegin(_currentCallNumber);

                address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
                if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
                    _createProxyInternal(cc.sourceAddress, cc.sourceRollupId);
                }

                (bool success, bytes memory retData) = sourceProxy.call{
                    value: cc.value
                }(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)));

                _rollingHashCallEnd(_currentCallNumber, success, retData);
                emit CallResult(_currentEntryIndex, _currentCallNumber, success, retData);
                processed++;
            } else {
                uint256 savedCallNumber = _currentCallNumber;
                entry.L2ToL1Calls[_currentCallNumber].revertSpan = 0;

                try this.executeInContextAndRevert(revertSpan) {}
                catch (bytes memory revertData) {
                    (_rollingHash, _lastNestedActionConsumed, _currentCallNumber) = _decodeContextResult(revertData);
                }

                entry.L2ToL1Calls[savedCallNumber].revertSpan = revertSpan;
                emit RevertSpanExecuted(_currentEntryIndex, savedCallNumber, revertSpan);
                processed += revertSpan;
            }
        }
    }

    /// @notice Decodes a ContextResult revert payload
    function _decodeContextResult(bytes memory revertData)
        internal
        pure
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
    //  Lookup call lookup
    // ──────────────────────────────────────────────

    /// @notice Looks up a pre-computed lookup call result from the lookupCalls table
    /// @dev Matches by crossChainCallHash + current call number + last nested action consumed.
    ///      tload works in static context, so transient tracking variables are readable.
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return The pre-computed return data
    function staticCallLookup(address sourceAddress, bytes calldata callData) external view returns (bytes memory) {
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
        if (proxyInfo.originalAddress == address(0)) revert UnauthorizedProxy();

        bytes32 crossChainCallHash = computeCrossChainCallHash(
            proxyInfo.originalRollupId,
            proxyInfo.originalAddress,
            0, // value is always 0 in static context
            callData,
            sourceAddress,
            ROLLUP_ID
        );

        uint64 callNum = uint64(_currentCallNumber);
        uint64 lastNA = uint64(_lastNestedActionConsumed);

        for (uint256 i = 0; i < lookupCalls.length; i++) {
            LookupCall storage sc = lookupCalls[i];
            if (
                sc.crossChainCallHash == crossChainCallHash && sc.callNumber == callNum
                    && sc.lastNestedActionConsumed == lastNA
            ) {
                return _resolveLookupCall(sc);
            }
        }

        revert ExecutionNotFound();
    }

    /// @notice Executes calls in static context and computes a rolling hash of results
    /// @dev All proxies referenced by the calls must already be deployed — cannot CREATE2 in static context.
    ///      No revertSpan handling — all calls execute as-is (revertSpan correctness is verified by the proof).
    ///      Does not use storage or transient variables — only a local rolling hash.
    function _processNLookupCalls(L2ToL1Call[] memory calls) internal view returns (bytes32 computedHash) {
        for (uint256 i = 0; i < calls.length; i++) {
            L2ToL1Call memory cc = calls[i];
            address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
            (bool success, bytes memory retData) =
                sourceProxy.staticcall(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)));
            computedHash = _rollingHashStaticResult(computedHash, success, retData);
        }
    }

    // ──────────────────────────────────────────────
    //  Cross-chain call hash helper
    // ──────────────────────────────────────────────

    /// @notice Computes the cross-chain call hash from individual fields. Public so off-chain
    ///         tooling can derive the hash for a planned cross-chain call. Same formula as
    ///         the L1 `EEZ.computeCrossChainCallHash` so a tool that calls one can use
    ///         the result against either chain.
    function computeCrossChainCallHash(
        uint256 targetRollupId,
        address targetAddress,
        uint256 value,
        bytes memory data,
        address sourceAddress,
        uint256 sourceRollupId
    )
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId));
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    /// @notice Computes the deterministic CREATE2 address for a CrossChainProxy
    /// @param originalAddress The address this proxy represents on the source rollup
    /// @param originalRollupId The source rollup ID
    /// @return The computed proxy address
    function computeCrossChainProxyAddress(address originalAddress, uint256 originalRollupId)
        public
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(originalRollupId, originalAddress));
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(CrossChainProxy).creationCode, abi.encode(address(this), originalAddress, originalRollupId)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
