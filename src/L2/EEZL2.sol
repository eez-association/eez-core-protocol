// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CrossChainProxy} from "../base/CrossChainProxy.sol";
import {
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    ExpectedLookup,
    LookupCall,
    ExecutionEntry
} from "../interfaces/IEEZL2.sol";
import {ProxyInfo} from "../interfaces/IEEZ.sol";
import {EEZBase} from "../base/EEZBase.sol";

/// @title EEZL2
/// @notice L2-side contract for cross-chain execution via pre-computed execution tables
/// @dev No rollups, no state deltas, no ZK proofs. System address loads execution tables,
///      which are consumed sequentially via proxy calls (`executeCrossChainCall`).
/// @dev SELF-RELATIVE directional vocabulary, mirroring L1's directional style: `incomingCalls`
///      holds the cross-chain calls executed ON this L2 on behalf of remote callers (the
///      counterparty may be L1 OR another L2), and `expectedOutgoingCalls` holds the pre-computed
///      results of reentrant calls fired FROM this L2 during execution. See `IEEZL2.sol`.
contract EEZL2 is EEZBase {
    /// @notice The rollup ID this L2 belongs to
    uint64 public immutable ROLLUP_ID;

    /// @notice The system address authorized for admin operations (load/replace execution table).
    /// @dev TRUST ASSUMPTION: node-controlled system address with no private key — never adversarial
    ///      and not reentry-reachable, so table loads/replacements are trusted (no attacker can wipe
    ///      or swap the table mid-execution).
    address public immutable SYSTEM_ADDRESS;

    /// @notice Array of pre-computed executions
    ExecutionEntry[] public executions;

    /// @notice Array of pre-computed lookup call results
    LookupCall[] public lookupCalls;

    /// @notice Last block number when execution table was loaded
    uint256 public lastLoadBlock;

    /// @notice Index of the next execution entry to consume
    uint256 public executionIndex;

    // ──────────────────────────────────────────────
    //  Transient execution cursors
    // ──────────────────────────────────────────────

    /// @notice 1-indexed global call counter and cursor into `entry.incomingCalls[]`.
    /// @dev `_currentIncomingCall != 0` also doubles as the `_insideExecution()` predicate.
    uint256 transient _currentIncomingCall;

    /// @notice Sequential reentrant (outgoing) call consumption counter.
    /// @dev Also used by `staticCallLookup` to disambiguate multiple lookup calls within the same call.
    uint256 transient _lastOutgoingCallConsumed;

    // ── Sub-frame / reverted-lookup pointers (L2-only) ──
    // These scope `_activeCalls()` / `_getActiveLookups()` to a sub-execution's tables. They used to
    // live in the shared `EEZBase`, but L1 no longer needs them (it passes the active call array by
    // `memory`), so they're declared here.

    /// @notice True while executing a reverted NESTED lookup — the `ExpectedLookup` at
    ///         `_reentrantSubFrameIndex` within the active host table scopes `_activeCalls()`.
    bool transient _inReentrantSubFrame;

    /// @notice Index of the nested `ExpectedLookup` being executed, within the active host table.
    uint256 transient _reentrantSubFrameIndex;

    /// @notice True while a reverted TOP-LEVEL `LookupCall` is the active host — the pool lookup at
    ///         `_topLevelLookupIndex` supplies the flat calls / reentrant / nested tables.
    bool transient _revertedLookupTopLevel;

    /// @notice Pool index of the top-level `LookupCall` being executed.
    uint256 transient _topLevelLookupIndex;

    /// @notice Error when caller is not the system address
    error Unauthorized();

    /// @notice Error when constructor is given the reserved mainnet rollup id (0)
    error InvalidRollupId();

    /// @notice Error when execution is attempted in a different block than the last load
    error ExecutionNotInCurrentBlock();

    /// @notice Error when ETH transfer to system address fails
    error EtherTransferFailed();

    /// @notice Error when `executeIncomingCrossChainCall` is called with no entries
    error EmptyEntries();

    /// @notice Error when `msg.value` attached to `executeIncomingCrossChainCall` doesn't match `value`
    error ValueMismatch();

    /// @notice Entry 0's `proxyEntryHash` doesn't match the hash computed from the explicit params
    error EntryHashMismatch();

    /// @notice Error when not all calls (`entry.incomingCalls`) were consumed after execution
    error UnconsumedIncomingCalls();

    /// @notice Error when not all reentrant (outgoing) calls (`entry.expectedOutgoingCalls`) were
    ///         consumed after execution
    error UnconsumedOutgoingCalls();

    /// @notice Emitted when execution entries are loaded into the execution table
    event ExecutionTableLoaded(ExecutionEntry[] entries);

    /// @notice Emitted when an execution entry is consumed
    event ExecutionConsumed(bytes32 indexed crossChainCallHash, uint256 indexed executionIndex);

    /// @notice Emitted when the system address initiates an incoming cross-chain call from another rollup
    event IncomingCrossChainCallExecuted(
        bytes32 indexed crossChainCallHash,
        address destination,
        uint256 value,
        bytes data,
        address sourceAddress,
        uint64 sourceRollup
    );

    /// @notice Emitted after each call completes in `_processNCalls`.
    /// @dev Not emitted for calls inside a revertNextNCalls (those events are rolled back by the revert).
    event CallResult(uint256 indexed entryIndex, uint256 indexed callNumber, bool success, bytes returnData);

    /// @notice Emitted after an entry's execution completes and all verifications pass
    event EntryExecuted(
        uint256 indexed entryIndex, bytes32 rollingHash, uint256 callsProcessed, uint256 outgoingCallsConsumed
    );

    /// @notice Emitted after a rollback window (`revertNextNCalls`) is processed via
    ///         `executeInContextAndRevert` — `nCalls` calls ran, succeeded, then had their state rolled back.
    event CallsReverted(uint256 indexed entryIndex, uint256 startCallNumber, uint256 nCalls);

    /// @param _rollupId Non-zero; 0 is reserved as the mainnet sentinel in call hashes.
    /// @param _systemAddress The privileged address allowed to load execution tables
    constructor(uint64 _rollupId, address _systemAddress) {
        if (_rollupId == 0) revert InvalidRollupId();
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
    //  Predicates
    // ──────────────────────────────────────────────

    /// @notice Returns true if currently inside a cross-chain call execution
    function _insideExecution() internal view returns (bool) {
        return _currentIncomingCall != 0;
    }

    /// @notice This L2's own network — `createCrossChainProxy` may not proxy a local address.
    function _getRollupId() internal view override returns (uint64) {
        return ROLLUP_ID;
    }

    // ──────────────────────────────────────────────
    //  Execution entry points
    // ──────────────────────────────────────────────

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
        if (!proxyInfo.isProxy) revert UnauthorizedProxy();
        address destAddress = proxyInfo.originalAddress;

        // Executions can only be consumed in the same block they were loaded
        if (lastLoadBlock != block.number) revert ExecutionNotInCurrentBlock();

        // burn ether — return to system address
        if (msg.value > 0) {
            (bool success,) = SYSTEM_ADDRESS.call{value: msg.value}("");
            if (!success) revert EtherTransferFailed();
        }

        bytes32 crossChainCallHash = computeCrossChainCallHash(
            NOT_STATIC_CALL, sourceAddress, ROLLUP_ID, destAddress, proxyInfo.originalRollupId, msg.value, callData
        );
        emit CrossChainCallExecuted(crossChainCallHash, msg.sender, sourceAddress, callData, msg.value);

        if (_insideExecution()) {
            // Inside a cross-chain call: consume the next reentrant action
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
    ///      folds tagged events into the rolling hash, and handles `revertNextNCalls`. Reentrant
    ///      cross-chain calls during execution see `_insideExecution() == true` and consume
    ///      from `executions[0].expectedOutgoingCalls`.
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
        uint64 sourceRollup,
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
            computeCrossChainCallHash(NOT_STATIC_CALL, sourceAddress, sourceRollup, destination, ROLLUP_ID, value, data);
        emit IncomingCrossChainCallExecuted(crossChainCallHash, destination, value, data, sourceAddress, sourceRollup);

        // 3. No entry-context preamble needed: `_currentEntryIndex`, `_rollingHash`,
        //    `_currentIncomingCall`, `_lastOutgoingCallConsumed` are all `transient` and
        //    default to zero at the start of every tx. SYSTEM_ADDRESS invokes this as a
        //    top-level call, once per tx — so they're already what `_processNCalls`
        //    expects (entry index 0, fresh rolling hash, call cursor at 0, reentrant cursor at 0).
        ExecutionEntry storage entry = executions[0];

        // 4. Bind the emitted call hash to the entry (mirrors L1 `_consumeAndExecute`).
        if (entry.proxyEntryHash != crossChainCallHash) revert EntryHashMismatch();

        // 5. Drive the flat call processor — `entry.incomingCalls[0]` is the inbound call,
        //    delivered via the source proxy by `_processNCalls`
        _processNCalls(entry.callCount);

        // 6. Verify invariants (mirrors `_consumeAndExecute`'s post-checks)
        if (_rollingHash != entry.rollingHash) revert RollingHashMismatch();
        if (_currentIncomingCall != entry.incomingCalls.length) revert UnconsumedIncomingCalls();
        if (_lastOutgoingCallConsumed != entry.expectedOutgoingCalls.length) revert UnconsumedOutgoingCalls();

        // 7. Advance past entries[0] so follow-up `executeCrossChainCall`s don't re-consume it.
        //    SYSTEM_ADDRESS is not reentry-reachable so no `_insideExecution()` guard is needed.
        executionIndex = 1;

        emit EntryExecuted(0, _rollingHash, _currentIncomingCall, _lastOutgoingCallConsumed);
        _currentIncomingCall = 0; // reset so _insideExecution() returns false

        return entry.returnData;
    }

    // ──────────────────────────────────────────────
    //  Internal execution
    // ──────────────────────────────────────────────

    /// @notice The execution entry currently being processed. L2 has a single table, so the
    ///         transient `_currentEntryIndex` indexes `executions` directly.
    function _getCurrentEntry() internal view returns (ExecutionEntry storage) {
        return executions[_currentEntryIndex];
    }

    /// @notice The TOP-LEVEL LookupCall currently being executed. L2 has a single `lookupCalls`
    ///         table, indexed directly by the transient pointer.
    function _currentTopLevelLookup() internal view returns (LookupCall storage) {
        return lookupCalls[_topLevelLookupIndex];
    }

    // ──────────────────────────────────────────────
    //  Active-execution accessors
    // ──────────────────────────────────────────────
    //
    // `_processNCalls` and `_consumeNestedAction` operate on whichever flat-call / reentrant /
    // nested-lookup tables are active. Three contexts:
    //   - normal entry execution → the entry's tables;
    //   - top-level reverted lookup executing (`_revertedLookupTopLevel`) → the pool lookup's tables;
    //   - nested reverted lookup executing (`_inReentrantSubFrame`) → the `ExpectedLookup` at
    //     `_reentrantSubFrameIndex` within the active host table (`_getActiveLookups()`).

    /// @notice Fourth component of the nested-lookup match key (`executingLookupIndex`):
    ///         0 = host level; k = inside the sub-execution of the host's `expectedLookups[k-1]`.
    function _activeLookupContext() internal view returns (uint64) {
        return _inReentrantSubFrame ? uint64(_reentrantSubFrameIndex + 1) : 0;
    }

    /// @notice The flat call array driving the current execution.
    function _activeCalls() internal view returns (CrossChainCall[] storage) {
        if (_inReentrantSubFrame) return _getActiveLookups()[_reentrantSubFrameIndex].incomingCalls;
        if (_revertedLookupTopLevel) return _currentTopLevelLookup().incomingCalls;
        return _getCurrentEntry().incomingCalls;
    }

    /// @notice The reentrant (outgoing) table for the current execution.
    function _activeNested() internal view returns (ExpectedOutgoingCrossChainCall[] storage) {
        if (_inReentrantSubFrame) return _getActiveLookups()[_reentrantSubFrameIndex].expectedOutgoingCalls;
        if (_revertedLookupTopLevel) return _currentTopLevelLookup().expectedOutgoingCalls;
        return _getCurrentEntry().expectedOutgoingCalls;
    }

    /// @notice The nested-lookup table of the active HOST — the entry's `expectedLookups`, or
    ///         the top-level lookup's own table while one is being executed. Deeper reverted-lookup executions
    ///         within a host resolve from this same flat table.
    function _getActiveLookups() internal view returns (ExpectedLookup[] storage) {
        return _revertedLookupTopLevel ? _currentTopLevelLookup().expectedLookups : _getCurrentEntry().expectedLookups;
    }

    /// @notice Consumes the next reentrant action, or runs a pre-computed reverting
    ///         lookup call when no ExpectedOutgoingCrossChainCall matches.
    /// @dev L2 reverts immediately on no-match (no deferred-revert flag like L1). The
    ///      system-loaded table is trusted, so a no-match is unrecoverable. The post-increment
    ///      below is safe because every fall-through path reverts and rolls the bump back.
    function _consumeNestedAction(bytes32 crossChainCallHash) internal returns (bytes memory) {
        // Active reentrant table: the containing entry's, or — while executing a reverted lookup —
        // that lookup's own `expectedOutgoingCalls`.
        ExpectedOutgoingCrossChainCall[] storage expectedCalls = _activeNested();
        uint256 idx = _lastOutgoingCallConsumed++;

        // 1. ExpectedOutgoingCrossChainCall priority. The `++` above is the commit; if we fall through, every
        //    fallback path reverts and the EVM rolls the bump back.
        if (idx < expectedCalls.length && expectedCalls[idx].crossChainCallHash == crossChainCallHash) {
            ExpectedOutgoingCrossChainCall storage nested = expectedCalls[idx];
            _rollingHashNestedBegin(crossChainCallHash); // bind the reentrant call's identity
            _processNCalls(nested.callCount);
            _rollingHashNestedEnd();
            return nested.returnData;
        }

        // 2. Fallback. Lookup key uses `idx` (pre-bump) — that's what the prover observed. A
        //    reverted (`!success`) match in the active host's `expectedLookups` (entry-scoped) runs as a
        //    mini-entry via `_executeRevertedNestedLookup` (sub-calls, if any, run for real), then
        //    reverts with the cached `returnData`.
        uint64 callNum = uint64(_currentIncomingCall);
        uint64 lastNA = uint64(idx);
        uint64 execIdx = _activeLookupContext();
        ExpectedLookup[] storage lookups = _getActiveLookups();
        for (uint256 i = 0; i < lookups.length; i++) {
            ExpectedLookup storage el = lookups[i];
            if (
                !el.success && el.crossChainCallHash == crossChainCallHash && el.callNumber == callNum
                    && el.lastOutgoingCallConsumed == lastNA && el.executingLookupIndex == execIdx
            ) {
                _executeRevertedNestedLookup(i); // always reverts
            }
        }

        // 3. No match anywhere.
        revert ExecutionNotFound();
    }

    /// @notice Top-level fallback: scan persistent `lookupCalls` for a reverted (`!success`) `LookupCall`
    ///         matching `crossChainCallHash`. Only reachable outside an execution — nested
    ///         lookups live on the entry. A match is resolved by `_executeRevertedTopLevelLookup`
    ///         (always reverts); no match returns so the caller reverts `ExecutionNotFound`.
    function _tryRevertedTopLevelLookup(bytes32 crossChainCallHash) internal {
        for (uint256 i = 0; i < lookupCalls.length; i++) {
            LookupCall storage sc = lookupCalls[i];
            if (!sc.success && sc.crossChainCallHash == crossChainCallHash) {
                _executeRevertedTopLevelLookup(sc, i); // always reverts
            }
        }
    }

    /// @notice Consumes the next execution entry, executes calls, and verifies rolling hash
    /// @dev Miss path: when the cursor is out of bounds or the next entry's `proxyEntryHash` doesn't
    ///      match, `_tryRevertedTopLevelLookup` scans persistent `lookupCalls` for a `success=false`
    ///      `LookupCall` matching `crossChainCallHash` (top-level lookups carry no cursor key).
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
        _currentIncomingCall = 0;
        _lastOutgoingCallConsumed = 0;

        _processNCalls(entry.callCount);

        if (_rollingHash != entry.rollingHash) revert RollingHashMismatch();
        if (_currentIncomingCall != entry.incomingCalls.length) revert UnconsumedIncomingCalls();
        if (_lastOutgoingCallConsumed != entry.expectedOutgoingCalls.length) revert UnconsumedOutgoingCalls();

        emit EntryExecuted(idx, _rollingHash, _currentIncomingCall, _lastOutgoingCallConsumed);
        _currentIncomingCall = 0; // reset so _insideExecution() returns false

        return entry.returnData;
    }

    /// @notice Executes calls in an isolated context that always reverts
    function executeInContextAndRevert(uint256 callCount) external {
        if (msg.sender != address(this)) revert NotSelf();
        _processNCalls(callCount);
        revert ContextResult(_rollingHash, _lastOutgoingCallConsumed, _currentIncomingCall);
    }

    /// @notice Processes N calls from the flat entry.incomingCalls[] array
    /// @dev L2 has no ether accounting (unlike L1), so this returns nothing.
    function _processNCalls(uint256 count) internal {
        // Active flat-call array: the entry's, or the reverted lookup's while one is executing.
        CrossChainCall[] storage calls = _activeCalls();
        uint256 processed = 0;
        while (processed < count) {
            uint256 revertNextNCalls = calls[_currentIncomingCall].revertNextNCalls;

            if (revertNextNCalls == 0) {
                CrossChainCall memory cc = calls[_currentIncomingCall];
                _currentIncomingCall++;

                // L2 mechanical update (full L2 pass deferred): bind the call's identity into CALL_BEGIN.
                _rollingHashCallBegin(
                    computeCrossChainCallHash(
                        cc.isStatic, cc.sourceAddress, cc.sourceRollupId, cc.targetAddress, ROLLUP_ID, cc.value, cc.data
                    )
                );

                address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
                if (!authorizedProxies[sourceProxy].isProxy) {
                    _createCrossChainProxyInternal(cc.sourceAddress, cc.sourceRollupId);
                }

                bool success;
                bytes memory retData;
                if (cc.isStatic) {
                    // Read-only dispatch: STATICCALL carries no value and reverts on any state write.
                    // A static call loaded with value is malformed — reject it rather than drop the value.
                    if (cc.value != 0) revert StaticCallWithValue();
                    (success, retData) = sourceProxy.staticcall(
                        abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data))
                    );
                } else {
                    (success, retData) = sourceProxy.call{
                        value: cc.value
                    }(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)));
                }

                _rollingHashCallEnd(success, retData);
                emit CallResult(_currentEntryIndex, _currentIncomingCall, success, retData);
                processed++;
            } else {
                uint256 savedCallNumber = _currentIncomingCall;
                calls[_currentIncomingCall].revertNextNCalls = 0;

                try this.executeInContextAndRevert(revertNextNCalls) {}
                catch (bytes memory revertData) {
                    (_rollingHash, _lastOutgoingCallConsumed, _currentIncomingCall) = _decodeContextResult(revertData);
                }

                calls[savedCallNumber].revertNextNCalls = revertNextNCalls;
                emit CallsReverted(_currentEntryIndex, savedCallNumber, revertNextNCalls);
                processed += revertNextNCalls;
            }
        }
    }

    // ──────────────────────────────────────────────
    //  Lookup-call resolution
    // ──────────────────────────────────────────────

    /// @notice Shared static-resolution body: run the sub-calls (untagged schema, always
    ///         compared — an empty `calls[]` hashes to 0, which must match a sub-call-less
    ///         lookup's `rollingHash`), then return the cached data, or revert with it when
    ///         `!success`.
    function _resolveStaticLookup(
        CrossChainCall[] storage calls,
        bytes32 rollingHash,
        bool success,
        bytes memory returnData
    )
        internal
        view
        returns (bytes memory)
    {
        if (_processNStaticCalls(calls) != rollingHash) revert RollingHashMismatch();
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return returnData;
    }

    /// @notice Runs a reverted NESTED lookup (`_getActiveLookups()[index]`) as a self-contained
    ///         mini-entry, then reverts with its cached `returnData`.
    function _executeRevertedNestedLookup(uint256 index) internal {
        ExpectedLookup storage el = _getActiveLookups()[index];

        // Pointer for deeper frames (`_activeCalls()` / `_activeNested()`); storage refs
        // can't be transient.
        _reentrantSubFrameIndex = index;
        _inReentrantSubFrame = true;

        _executeRevertedLookup(
            el.callCount, el.rollingHash, el.incomingCalls.length, el.expectedOutgoingCalls.length, el.returnData
        );
    }

    /// @notice Runs a reverted TOP-LEVEL `LookupCall` as a self-contained mini-entry, then
    ///         reverts with its cached `returnData`. The pool lookup becomes the active HOST:
    ///         its tables drive the sub-execution, including its own `expectedLookups` for nested
    ///         lookups observed inside it.
    function _executeRevertedTopLevelLookup(LookupCall storage sc, uint256 index) internal {
        // Host pointer for deeper frames; L2 has a single table, so only the index is needed.
        _topLevelLookupIndex = index;
        _revertedLookupTopLevel = true;

        _executeRevertedLookup(
            sc.callCount, sc.rollingHash, sc.incomingCalls.length, sc.expectedOutgoingCalls.length, sc.returnData
        );
    }

    /// @notice Shared execution tail for reverted lookups: fresh sub-execution context, run the
    ///         sub-calls, entry-style end checks, then the terminal revert with the cached
    ///         `returnData`. Runs INLINE in the consuming `executeCrossChainCall` frame; the
    ///         revert discards the sub-call state AND restores the outer cursors (the EVM
    ///         rolls back every tstore here). Deeper reverted-lookup executions compose via the same unwind.
    function _executeRevertedLookup(
        uint256 callCount,
        bytes32 rollingHash,
        uint256 callsLength,
        uint256 reentrantLength,
        bytes memory returnData
    )
        internal
    {
        _rollingHash = bytes32(0);
        _currentIncomingCall = 0;
        _lastOutgoingCallConsumed = 0;

        _processNCalls(callCount);

        if (_rollingHash != rollingHash) revert RollingHashMismatch();
        if (_currentIncomingCall != callsLength) revert UnconsumedIncomingCalls();
        if (_lastOutgoingCallConsumed != reentrantLength) revert UnconsumedOutgoingCalls();

        assembly {
            revert(add(returnData, 0x20), mload(returnData))
        }
    }

    /// @notice Executes the lookup call's optional `calls[]` in static context and computes a
    ///         rolling hash of the results (untagged static schema). No `revertNextNCalls` handling.
    /// @dev All proxies referenced must already be deployed; CREATE2 is unavailable inside a
    ///      STATICCALL frame. The accumulator is a local, not `_rollingHash`, so this is verified
    ///      against `LookupCall.rollingHash`. See `docs/CORE_PROTOCOL_SPEC.md` §E.2.
    function _processNStaticCalls(CrossChainCall[] memory calls) internal view returns (bytes32 computedHash) {
        for (uint256 i = 0; i < calls.length; i++) {
            CrossChainCall memory cc = calls[i];
            address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
            // STATICCALL to a codeless address silently succeeds — reject so the prover can't pre-hash a no-op.
            if (sourceProxy.code.length == 0) revert LookupCallProxyNotDeployed(sourceProxy);
            (bool success, bytes memory retData) =
                sourceProxy.staticcall(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)));
            computedHash = _rollingHashStaticResult(computedHash, success, retData);
        }
    }

    // ──────────────────────────────────────────────
    //  Lookup call lookup
    // ──────────────────────────────────────────────

    /// @notice Looks up a pre-computed lookup result.
    /// @dev Inside an execution: scans the active host's entry-scoped `expectedLookups` by
    ///      `(crossChainCallHash, callNumber, lastOutgoingCallConsumed)`. Outside: scans the
    ///      persistent `lookupCalls` pool for a top-level `LookupCall` matching
    ///      `crossChainCallHash`. tload works in static context, so the transient tracking
    ///      variables are readable.
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return The pre-computed return data
    function staticCallLookup(address sourceAddress, bytes calldata callData) external view returns (bytes memory) {
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
        if (!proxyInfo.isProxy) revert UnauthorizedProxy();
        address destAddress = proxyInfo.originalAddress;

        bytes32 crossChainCallHash = computeCrossChainCallHash(
            true,
            sourceAddress,
            ROLLUP_ID,
            destAddress,
            proxyInfo.originalRollupId,
            0, // value is always 0 in static context
            callData
        );

        // Nested: entry-scoped table of the active host, keyed by the live cursors.
        if (_insideExecution()) {
            uint64 callNum = uint64(_currentIncomingCall);
            uint64 lastNA = uint64(_lastOutgoingCallConsumed);
            uint64 execIdx = _activeLookupContext();
            ExpectedLookup[] storage lookups = _getActiveLookups();
            for (uint256 i = 0; i < lookups.length; i++) {
                ExpectedLookup storage el = lookups[i];
                if (
                    el.crossChainCallHash == crossChainCallHash && el.callNumber == callNum
                        && el.lastOutgoingCallConsumed == lastNA && el.executingLookupIndex == execIdx
                ) {
                    return _resolveStaticLookup(el.incomingCalls, el.rollingHash, el.success, el.returnData);
                }
            }
            revert ExecutionNotFound();
        }

        // Top-level: persistent pool, matched by hash alone (L2 has no state roots to pin).
        for (uint256 i = 0; i < lookupCalls.length; i++) {
            LookupCall storage sc = lookupCalls[i];
            if (sc.crossChainCallHash == crossChainCallHash) {
                return _resolveStaticLookup(sc.incomingCalls, sc.rollingHash, sc.success, sc.returnData);
            }
        }

        revert ExecutionNotFound();
    }
}
