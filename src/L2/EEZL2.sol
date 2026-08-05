// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {CrossChainProxy} from "../base/CrossChainProxy.sol";
import {
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    ExecutionEntry,
    StaticExecutionEntry
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
/// @dev Mirrors `EEZ` (L1) structurally minus the L1-only machinery — no state deltas / ether
///      accounting, no rollup registry, no proofs, no per-rollup queues, no proxy-protection set.
///      Each frame carries its OWN flat call array (`_processNCalls` walks it by a local index, no
///      global cursor); the reentrant (outgoing) table is a single unified `expectedOutgoingCalls`,
///      content-addressed by `expectedOutgoingHash` and forward-scanned by `_lastOutgoingCallConsumed`.
contract EEZL2 is EEZBase {
    /// @notice The rollup ID this L2 belongs to
    uint64 public immutable ROLLUP_ID;

    /// @notice The system address authorized for admin operations (load/replace execution table).
    /// @dev TRUST ASSUMPTION: node-controlled system address with no private key — never adversarial
    ///      and not reentry-reachable, so table loads/replacements are trusted (no attacker can wipe
    ///      or swap the table mid-execution).
    address public immutable SYSTEM_ADDRESS;

    /// @notice Whether the `callGas` folded into outgoing call hashes is the observed `gasleft()`.
    /// @dev When false, `callGas` is fixed at 0 — outgoing hashes are then gas-independent and can
    ///      be pre-computed without observing the forwarded gas. Gas-observed keying (`true`) is the
    ///      intended production mode once the node supplies observed gas.
    bool public immutable USE_GAS_LEFT;

    /// @notice Recipient of ether swept from proxies (ether sent to a proxy address before deployment).
    /// @dev On L2 this is `SYSTEM_ADDRESS` — same as the burn path in `executeCrossChainCall`.
    function RECOVERY_ADDRESS() external view returns (address) {
        return SYSTEM_ADDRESS;
    }

    /// @notice Array of pre-computed entries
    ExecutionEntry[] public entries;

    /// @notice Array of pre-computed top-level static entries; resolvable only in the load block
    StaticExecutionEntry[] public staticEntries;

    /// @notice Last block number when execution table was loaded
    uint256 public lastLoadBlock;

    /// @notice Index of the next execution entry to consume
    uint256 public entryIndex;

    // ──────────────────────────────────────────────
    //  Transient execution state
    // ──────────────────────────────────────────────

    /// @notice True while inside a cross-chain call execution. Set at `_executeEntry` start, cleared
    ///         at its end; a revert rolls it back. Backs `_insideExecution()` (L1 derives the same
    ///         predicate from its proxy-protection array, which L2 doesn't have).
    bool transient _executing;

    /// @notice Forward-scan position into the entry's unified `expectedOutgoingCalls`. MUST be
    ///         transient — `_consumeNestedCall` / `staticCrossChainCall` read it from fresh reentrant
    ///         frames; it rides the `ContextResult` payload across a revert-span boundary.
    uint256 transient _lastOutgoingCallConsumed;

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

    /// @notice Entry 0 has no incoming calls — `incomingCalls[0]` must be the inbound call
    error EmptyIncomingCalls();

    /// @notice Entry 0's `proxyEntryHash` doesn't match the hash of its own `incomingCalls[0]`
    error EntryHashMismatch();

    /// @notice No entry matched a top-level outgoing call. Carries the computed L2-outgoing hash and
    ///         the observed `callGas` so the entry-builder can reproduce the key.
    error EntryNotFound(bytes32 crossChainCallHash, uint64 callGas);

    /// @notice A `revertNextNCalls` span declares more calls than remain in its array (malformed entry).
    error RevertSpanOutOfBounds(uint256 start, uint256 span, uint256 length);

    /// @notice Emitted when execution entries are loaded into the execution table
    event ExecutionTableLoaded(ExecutionEntry[] entries);

    /// @notice Emitted when an execution entry is consumed
    event ExecutionConsumed(bytes32 indexed crossChainCallHash, uint256 indexed entryIndex);

    /// @notice Emitted when the system address initiates an incoming cross-chain call from another
    ///         rollup. Field order mirrors `computeCrossChainCallHash`; all fields are the inbound
    ///         call's own (`incomingCalls[0]`), folded into its hash.
    event IncomingCrossChainCallExecuted(
        bytes32 indexed crossChainCallHash,
        bool isStatic,
        address sourceAddress,
        uint64 sourceRollup,
        address destination,
        uint256 value,
        uint64 callGas,
        bytes data
    );

    /// @notice Emitted when a cross-chain call LEAVING this L2 is executed via proxy. `callGas` is
    ///         the value folded into the hash: the gas observed at manager entry (what the caller
    ///         forwarded) when `USE_GAS_LEFT`, else 0.
    /// @dev Overloads `EEZBase.CrossChainCallExecuted` (L1's five-field form) with an extra
    ///      trailing `callGas`; the two signatures have different topic0s.
    event CrossChainCallExecuted(
        bytes32 indexed crossChainCallHash,
        address indexed proxy,
        address sourceAddress,
        bytes callData,
        uint256 value,
        uint64 callGas
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
    /// @param _useGasLeft Whether outgoing call hashes fold the observed `gasleft()` (true) or a
    ///        fixed 0 (false — gas-independent keying)
    constructor(uint64 _rollupId, address _systemAddress, bool _useGasLeft) {
        if (_rollupId == 0) revert InvalidRollupId();
        ROLLUP_ID = _rollupId;
        SYSTEM_ADDRESS = _systemAddress;
        USE_GAS_LEFT = _useGasLeft;
    }

    modifier onlySystemAddress() {
        if (msg.sender != SYSTEM_ADDRESS) revert Unauthorized();
        _;
    }

    // ──────────────────────────────────────────────
    //  Admin: load execution table
    // ──────────────────────────────────────────────

    /// @notice Loads execution entries and static entries into the execution table (system only)
    /// @dev Clears previous entries and stores new ones. Entries must be consumed in the same block.
    ///      Payable: `msg.value` mints the inbound ETH the loaded entries commit. No on-chain check —
    ///      consumption is user-driven and possibly partial; `msg.value` matching the sum of
    ///      committed incoming values is a prover constraint.
    /// @param _entries The execution entries to load
    /// @param _staticEntries The top-level static entries to load
    function loadExecutionTable(ExecutionEntry[] calldata _entries, StaticExecutionEntry[] calldata _staticEntries)
        external
        payable
        onlySystemAddress
    {
        _loadExecutionTable(_entries, _staticEntries);
    }

    /// @notice Internal: replaces the execution table and resets the consumption cursor
    /// @dev Shared between `loadExecutionTable` and `executeIncomingCrossChainCall`
    function _loadExecutionTable(ExecutionEntry[] calldata _entries, StaticExecutionEntry[] calldata _staticEntries)
        internal
    {
        delete entries;
        delete staticEntries;
        entryIndex = 0;

        for (uint256 i = 0; i < _entries.length; i++) {
            entries.push(_entries[i]);
        }
        for (uint256 i = 0; i < _staticEntries.length; i++) {
            staticEntries.push(_staticEntries[i]);
        }
        lastLoadBlock = block.number;
        emit ExecutionTableLoaded(_entries);
    }

    // ──────────────────────────────────────────────
    //  Predicates
    // ──────────────────────────────────────────────

    /// @notice Returns true if currently inside a cross-chain call execution
    function _insideExecution() internal view returns (bool) {
        return _executing;
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

        uint64 callGas = USE_GAS_LEFT ? uint64(gasleft()) : 0;
        bytes32 crossChainCallHash = computeCrossChainCallHash(
            NOT_STATIC_CALL,
            sourceAddress,
            ROLLUP_ID,
            destAddress,
            proxyInfo.originalRollupId,
            msg.value,
            callGas,
            callData
        );
        emit CrossChainCallExecuted(crossChainCallHash, msg.sender, sourceAddress, callData, msg.value, callGas);

        if (_insideExecution()) {
            // Reentrant — resolve against the active entry's unified outgoing table
            return _consumeNestedCall(crossChainCallHash);
        }

        return _consumeAndExecute(crossChainCallHash, callGas);
    }

    /// @notice System-initiated execution of an incoming cross-chain call from another rollup
    /// @dev Atomically replaces the execution table and drives `entries[0]`; reentrant calls
    ///      consume from its `expectedOutgoingCalls`. `incomingCalls[0]` IS the inbound call —
    ///      its hash must equal `entries[0].proxyEntryHash` (checked on-chain); that it matches
    ///      what actually arrived is a prover constraint — as is `msg.value` equalling the total
    ///      inbound ether the committed calls consume (later entries may draw on it too, so no
    ///      on-chain check; same model as `loadExecutionTable`). `entries[0]` stays fully general:
    ///      `success == false` reverts the whole delivery, and `revertNextNCalls` on the inbound
    ///      call rolls back its destination effects while the delivery commits.
    /// @param _entries The execution entries to load (entries[0] is consumed by this call)
    /// @param _staticEntries The static entries to load (used for STATICCALL reads)
    /// @return result The pre-computed return data from `entries[0]`
    function executeIncomingCrossChainCall(
        ExecutionEntry[] calldata _entries,
        StaticExecutionEntry[] calldata _staticEntries
    )
        external
        payable
        onlySystemAddress
        returns (bytes memory result)
    {
        if (_entries.length == 0) revert EmptyEntries();
        if (_entries[0].incomingCalls.length == 0) revert EmptyIncomingCalls();

        // 1. Replace the execution table (same logic as loadExecutionTable)
        _loadExecutionTable(_entries, _staticEntries);

        // 2. Bind the entry's identity to its own inbound call: `proxyEntryHash` must be the
        //    hash of `incomingCalls[0]` (mirrors L1 `_consumeAndExecuteEntry`'s hash match).
        CrossChainCall calldata inbound = _entries[0].incomingCalls[0];
        bytes32 crossChainCallHash = computeCrossChainCallHash(
            inbound.isStatic,
            inbound.sourceAddress,
            inbound.sourceRollupId,
            inbound.targetAddress,
            ROLLUP_ID,
            inbound.value,
            inbound.gas,
            inbound.data
        );
        ExecutionEntry storage entry = entries[0];
        if (entry.proxyEntryHash != crossChainCallHash) revert EntryHashMismatch();

        emit IncomingCrossChainCallExecuted(
            crossChainCallHash,
            inbound.isStatic,
            inbound.sourceAddress,
            inbound.sourceRollupId,
            inbound.targetAddress,
            inbound.value,
            inbound.gas,
            inbound.data
        );

        // Same consumption signal the proxy-driven path emits, so a log reader sees every entry
        // that ran regardless of which entry point drove it.
        emit ExecutionConsumed(crossChainCallHash, 0);

        // 3. Execute. `_currentEntryIndex`, `_rollingHash`, `_lastOutgoingCallConsumed`,
        //    `_executing` are all `transient` and default to zero/false at the start of every tx;
        //    SYSTEM_ADDRESS invokes this as a top-level call, once per tx, so they're already what
        //    `_executeEntry` expects (entry index 0, fresh rolling hash, cursor at 0, not executing).
        _currentEntryIndex = 0;
        _executeEntry(entry);

        // 4. Advance past entries[0] so follow-up `executeCrossChainCall`s don't re-consume it.
        //    SYSTEM_ADDRESS is not reentry-reachable so no `_insideExecution()` guard is needed.
        entryIndex = 1;

        return entry.returnData;
    }

    // ──────────────────────────────────────────────
    //  Internal execution
    // ──────────────────────────────────────────────

    /// @notice The unified reentrant (outgoing) table a proxy re-entry resolves against — always the
    ///         entry currently in `_executeEntry`. L2 has a single `entries` table, so the
    ///         transient `_currentEntryIndex` indexes it directly. A reverted sub-execution shares the
    ///         same table for its own reentrant calls, disambiguated by the `_rollingHash` folded into
    ///         each `expectedOutgoingHash`.
    function _getExpectedOutgoingCalls() internal view returns (ExpectedOutgoingCrossChainCall[] storage) {
        return entries[_currentEntryIndex].expectedOutgoingCalls;
    }

    /// @notice Resolves a reentrant (outgoing) CALL: a plain-success entry consumed from
    ///         `expectedOutgoingCalls`, or a reverted entry run as a sub-execution.
    /// @dev Entries are content-addressed by `expectedOutgoingHash == keccak256(crossChainCallHash, _rollingHash)`,
    ///      where `_rollingHash` folds every prior call and nesting boundary, so it uniquely pins the
    ///      execution point. The scan walks STRICT FORWARD from `_lastOutgoingCallConsumed`; the first
    ///      match IS the entry, and its `success` flag selects the path in `_resolveNestedReentrant`
    ///      (commit vs run-and-revert). Static entries can't match here — their `crossChainCallHash`
    ///      folds `isStatic = true`, while this match is keyed with `isStatic = false`; the proxy
    ///      routes reentrant STATICCALLs to `staticCrossChainCall`. On no match, `_rollingHashCallNotFound`
    ///      folds CALL_NOT_FOUND so the entry reverts at its rolling-hash check (`RollingHashMismatch`).
    function _consumeNestedCall(bytes32 crossChainCallHash) internal returns (bytes memory) {
        ExpectedOutgoingCrossChainCall[] storage expectedCalls = _getExpectedOutgoingCalls();
        bytes32 expectedOutgoingHash = _computeExpectedL1toL2Hash(crossChainCallHash, _rollingHash);

        for (uint256 i = _lastOutgoingCallConsumed; i < expectedCalls.length; i++) {
            if (expectedCalls[i].expectedOutgoingHash == expectedOutgoingHash) {
                // Advance the cursor PAST this match before resolving it
                _lastOutgoingCallConsumed = i + 1;
                return _resolveNestedReentrant(expectedCalls[i], crossChainCallHash);
            }
        }

        // No match: CALL_NOT_FOUND is a distinct tag from the CALL_END(true, "") folded for a normal
        // empty return, so it can't be forged as one. The hash divergence is what the entry boundary
        // checks and it rides the `ContextResult` payload across a revert-span boundary, so it survives
        // any intermediate try/catch.
        _rollingHashCallNotFound(crossChainCallHash);
        return "";
    }

    /// @notice Resolves a matched reentrant (outgoing) CALL by running its OWN `incomingCalls[]` sub-array.
    /// @dev Takes the matched entry by `storage` pointer (the caller already resolved + indexed it, and
    ///      advanced `_lastOutgoingCallConsumed` past it). SUCCESS commits the sub-execution into the
    ///      host's continuous `_rollingHash` (NESTED_END) and returns `returnData`. REVERTED checks the
    ///      sub-hash against `revertedOrStaticRollingHash` and reverts with `returnData`; the terminal
    ///      revert rolls back the frame's state, hash, and cursor (no save needed).
    function _resolveNestedReentrant(
        ExpectedOutgoingCrossChainCall storage expectedOutgoing,
        bytes32 crossChainCallHash
    )
        internal
        returns (bytes memory)
    {
        CrossChainCall[] memory incomingCalls = expectedOutgoing.incomingCalls;

        // Open the frame and run the sub-array (cursor already advanced by the caller, so the sub-frame's
        // own reentrant calls scan strictly forward).
        _rollingHashNestedBegin(crossChainCallHash);
        _processNCalls(incomingCalls);

        if (expectedOutgoing.success) {
            // Defensive check of the prover constraint: the field is unused when success.
            if (expectedOutgoing.revertedOrStaticRollingHash != bytes32(0)) {
                revert SuccessRowWithRevertedOrStaticHash();
            }
            // Updates the rolling hash closing the nested call
            _rollingHashNestedEnd();
            return expectedOutgoing.returnData;
        } else {
            // It reverts with the expected saved revert data only if the expected rolling hash matches
            if (_rollingHash != expectedOutgoing.revertedOrStaticRollingHash) revert RollingHashMismatch();
            bytes memory returnData = expectedOutgoing.returnData;
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    /// @notice Consumes the next execution entry (forward-scanning for the matching `proxyEntryHash`),
    ///         runs it, and verifies the rolling hash.
    /// @dev Forward-scan from the cursor skips intervening non-matches so a top-level call can reach
    ///      past already-attempted entries (a `success == false` entry reverts, leaving the cursor where
    ///      it was). No reverted fallback: top-level reverting calls are normal entries
    ///      (`success == false`), and the static pool (`StaticExecutionEntry`) is read-only (`staticCrossChainCall`).
    /// @param crossChainCallHash The expected action input hash for the next entry
    /// @return result The pre-computed return data from the action
    function _consumeAndExecute(bytes32 crossChainCallHash, uint64 callGas) internal returns (bytes memory result) {
        uint256 idx = _findMatchingEntry(entryIndex, crossChainCallHash, callGas);
        entryIndex = idx + 1;
        ExecutionEntry storage entry = entries[idx];

        emit ExecutionConsumed(crossChainCallHash, idx);

        _currentEntryIndex = idx;
        _executeEntry(entry);

        // Reset the entry pointer now the entry is done (hygiene/symmetry — it's only read
        // mid-`_executeEntry` and always re-set before the next read). On a revert it rolls back to 0.
        _currentEntryIndex = 0;

        return entry.returnData;
    }

    /// @notice Forward-scans `entries` from `startIndex` for the FIRST entry whose `proxyEntryHash`
    ///         matches `crossChainCallHash`, returning its index. Reverts `EntryNotFound` if the
    ///         scan reaches the end with no match.
    function _findMatchingEntry(uint256 startIndex, bytes32 crossChainCallHash, uint64 callGas)
        internal
        view
        returns (uint256)
    {
        uint256 queueLen = entries.length;
        for (uint256 i = startIndex; i < queueLen; i++) {
            if (entries[i].proxyEntryHash == crossChainCallHash) return i;
        }
        revert EntryNotFound(crossChainCallHash, callGas);
    }

    /// @notice Seeds the rolling hash, processes the entry's top-level calls, verifies the rolling
    ///         hash, and (when `!success`) reverts with the entry's `returnData`.
    /// @dev `entry.incomingCalls` is its TOP-LEVEL calls only (each reentrant frame carries its own
    ///      sub-calls); `_processNCalls` runs the whole array, so completeness is structural (no
    ///      cursor-vs-length check). `_executing` is set true for the whole span (backs
    ///      `_insideExecution()`) so a reentrant call routes through `_consumeNestedCall`. Proxy
    ///      re-entries resolve the reentrant table from storage via `_getExpectedOutgoingCalls()`.
    function _executeEntry(ExecutionEntry storage entry) internal {
        // Flips `_insideExecution()` true; cleared on the success path, rolled back on a revert.
        _executing = true;

        _seedRollingHash(entry.proxyEntryHash); // initial hash: binds the entry identity
        _lastOutgoingCallConsumed = 0;

        // Storage→memory copy of the top-level calls (mirrors L1's by-`memory` processing).
        _processNCalls(entry.incomingCalls);

        // A reentrant no-match folded CALL_NOT_FOUND into the rolling hash, so it surfaces here as a
        // `RollingHashMismatch` — no separate no-match check needed. No reentrant table-length check:
        // the unified `expectedOutgoingCalls` mixes plain-success entries with static / reverted ones
        // (content-addressed, may be unused); completeness of the success entries is enforced by the
        // rolling hash, and an unused entry is inert.
        if (_rollingHash != entry.rollingHash) revert RollingHashMismatch();

        emit EntryExecuted(_currentEntryIndex, _rollingHash, entry.incomingCalls.length, _lastOutgoingCallConsumed);

        // Top-level reverting entry: the trace is now verified, so unwind everything — the inbound
        // value, the cursor advance, and these cleanups all roll back with the revert, surfacing
        // `returnData` to the caller. Mirrors `_resolveNestedReentrant`'s `!success` branch.
        if (!entry.success) {
            bytes memory returnData = entry.returnData;
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        _executing = false; // resets _insideExecution() to false
        _rollingHash = bytes32(0); // reset so the next entry's `_seedRollingHash` zero-guard passes
    }

    /// @notice Initializes `_rollingHash` to the entry's BEGIN seed — binds the entry's identity
    ///         (`proxyEntryHash` == its crossChainCallHash) so nested frames inherit it transitively.
    /// @dev Mirrors L1's `_rollingHashEntryBegin` with an empty state-delta prefix (L2 has no state
    ///      deltas), keeping the cross-chain hashing scheme identical modulo the dropped deltas:
    ///        _rollingHash = keccak(bytes32(0), proxyEntryHash)
    function _seedRollingHash(bytes32 proxyEntryHash) internal {
        if (_rollingHash != bytes32(0)) revert RollingHashNotCleared();
        _rollingHash = keccak256(abi.encodePacked(bytes32(0), proxyEntryHash));
    }

    /// @notice Runs `calls` in an isolated context that always reverts (force-revert span executor).
    ///         Receives the span slice by `memory` (ABI-encoded across the self-call) since a
    ///         `storage` ref can't cross an external boundary; processes the whole slice.
    function executeInContextAndRevert(CrossChainCall[] memory calls) external {
        if (msg.sender != address(this)) revert NotSelf();
        _processNCalls(calls);
        // 3rd field is always 0 on L2 (no flat-call transient cursor); it exists for the shared
        // L1/L2 ContextResult decoder.
        revert ContextResult(_rollingHash, _lastOutgoingCallConsumed, 0);
    }

    /// @notice Processes the WHOLE `calls` array (the entry's top-level calls, a reentrant sub-frame's
    ///         own calls, or a force-revert span slice), walked by a plain LOCAL index, folding the
    ///         rolling hash.
    /// @dev The index is a local, not transient: it auto-survives a reentrant proxy call (the outer
    ///      stack is preserved across the return), so there's nothing to save/restore for the
    ///      incoming-call position. L2 has no ether accounting (unlike L1), so this returns nothing.
    function _processNCalls(CrossChainCall[] memory calls) internal {
        for (uint256 i = 0; i < calls.length;) {
            uint256 revertNextNCalls = calls[i].revertNextNCalls;

            if (revertNextNCalls == 0) {
                CrossChainCall memory cc = calls[i];

                // Fold the call's identity (target on this L2 = ROLLUP_ID, source = its rollup) into CALL_BEGIN.
                _rollingHashCallBegin(
                    computeCrossChainCallHash(
                        cc.isStatic,
                        cc.sourceAddress,
                        cc.sourceRollupId,
                        cc.targetAddress,
                        ROLLUP_ID,
                        cc.value,
                        ZERO_CALL_GAS,
                        cc.data
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
                        abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.gas, cc.data))
                    );
                } else {
                    (success, retData) = sourceProxy.call{
                        value: cc.value
                    }(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.gas, cc.data)));
                }

                _rollingHashCallEnd(success, retData);
                emit CallResult(_currentEntryIndex, i, success, retData);
                i++;
            } else {
                // Force-revert span: the next `n` calls (this one included) run, succeed, then have
                // their state rolled back. Run them in an isolated self-call that always reverts; its
                // committed-to-`_rollingHash` and reentrant-consumption escape via `ContextResult` and
                // are restored here, while the EVM discards the state. A no-match inside the span is
                // already folded into that `_rollingHash`, so it rides out with no separate flag.
                if (i + revertNextNCalls > calls.length) {
                    revert RevertSpanOutOfBounds(i, revertNextNCalls, calls.length);
                }
                // Zero the trigger's span marker in our throwaway memory copy (the slice copies it),
                // so the isolated re-run reads it as a normal call instead of recursing into the span.
                calls[i].revertNextNCalls = 0;

                CrossChainCall[] memory revertedSpan = _sliceCrossChainCalls(calls, i, revertNextNCalls);
                try this.executeInContextAndRevert(revertedSpan) {}
                catch (bytes memory revertData) {
                    (_rollingHash, _lastOutgoingCallConsumed,) = _decodeContextResult(revertData);
                }
                emit CallsReverted(_currentEntryIndex, i, revertNextNCalls);
                i += revertNextNCalls; // skip past the span — its calls ran inside the self-call
            }
        }
    }

    // ──────────────────────────────────────────────
    //  Static entries
    // ──────────────────────────────────────────────

    /// @notice Resolves a pre-computed static entry.
    /// @dev Inside an execution: scans the active entry's unified `expectedOutgoingCalls` for an entry
    ///      whose `expectedOutgoingHash` matches `keccak256(crossChainCallHash, _rollingHash)` — the
    ///      same content-addressed key the reentrant CALLs use. The `crossChainCallHash` here folds
    ///      `isStatic = true`, so only static entries can match. Outside: scans the `staticEntries`
    ///      pool for a matching `crossChainCallHash`, gated on `lastLoadBlock == block.number`
    ///      (no pins on L2 — the block gate bounds staleness). tload works in static context, so
    ///      the transient tracking variables are readable.
    /// @param sourceAddress The original caller address (msg.sender as seen by the proxy)
    /// @param callData The original calldata sent to the proxy
    /// @return The pre-computed return data
    function staticCrossChainCall(address sourceAddress, bytes calldata callData) external view returns (bytes memory) {
        ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
        if (!proxyInfo.isProxy) revert UnauthorizedProxy();
        address destAddress = proxyInfo.originalAddress;

        bytes32 crossChainCallHash = computeCrossChainCallHash(
            IS_STATIC,
            sourceAddress,
            ROLLUP_ID,
            destAddress,
            proxyInfo.originalRollupId,
            0, // value is always 0 in static context
            ZERO_CALL_GAS,
            callData
        );

        // Nested: the active entry's unified reentrant table, content-addressed by `expectedOutgoingHash`.
        // `crossChainCallHash` was computed with `isStatic = true`, so it can only match a static entry.
        // A STATICCALL cannot mutate the cursor, so a static read is position-pinned by the rolling hash
        // rather than consumed.
        if (_insideExecution()) {
            bytes32 expectedOutgoingHash = _computeExpectedL1toL2Hash(crossChainCallHash, _rollingHash);
            // Forward scan from the cursor — same strict-forward window as `_consumeNestedCall`
            // (a static read cannot advance the cursor, but it still only matches at/after it).
            ExpectedOutgoingCrossChainCall[] storage expectedCalls = _getExpectedOutgoingCalls();
            for (uint256 i = _lastOutgoingCallConsumed; i < expectedCalls.length; i++) {
                ExpectedOutgoingCrossChainCall storage expectedCall = expectedCalls[i];
                if (expectedCall.expectedOutgoingHash == expectedOutgoingHash) {
                    return _resolveStaticEntry(
                        expectedCall.incomingCalls,
                        expectedCall.revertedOrStaticRollingHash,
                        expectedCall.success,
                        expectedCall.returnData
                    );
                }
            }
            revert ExecutionNotFound();
        }

        // Top-level: same-block pool, matched by hash alone (no pins on L2 — the block gate bounds staleness).
        if (lastLoadBlock != block.number) revert ExecutionNotInCurrentBlock();
        for (uint256 i = 0; i < staticEntries.length; i++) {
            StaticExecutionEntry storage staticEntry = staticEntries[i];
            if (staticEntry.proxyEntryHash == crossChainCallHash) {
                return _resolveStaticEntry(
                    staticEntry.incomingCalls, staticEntry.rollingHash, staticEntry.success, staticEntry.returnData
                );
            }
        }

        revert ExecutionNotFound();
    }

    /// @notice Shared static-resolution body: run the sub-calls (untagged schema, always
    ///         compared — an empty `calls[]` hashes to 0, which must match a sub-call-less
    ///         static entry's `rollingHash`), then return the cached data, or revert with it when
    ///         `!success`.
    function _resolveStaticEntry(
        CrossChainCall[] storage calls,
        bytes32 revertedOrStaticRollingHash,
        bool success,
        bytes memory returnData
    )
        internal
        view
        returns (bytes memory)
    {
        if (_processNStaticCalls(calls) != revertedOrStaticRollingHash) revert RollingHashMismatch();
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return returnData;
    }

    /// @notice Runs the static entry's `calls[]` in static context, folding an untagged rolling hash verified
    ///         against `StaticExecutionEntry.rollingHash` / `ExpectedOutgoingCrossChainCall.revertedOrStaticRollingHash`.
    /// @dev No `revertNextNCalls` handling — there is no state to roll back (== 0 is a prover
    ///      constraint); referenced proxies must already be deployed (CREATE2 is unavailable
    ///      inside a STATICCALL frame). See `docs/CORE_PROTOCOL_SPEC.md` §E.2.
    function _processNStaticCalls(CrossChainCall[] memory calls) internal view returns (bytes32 computedHash) {
        for (uint256 i = 0; i < calls.length; i++) {
            CrossChainCall memory cc = calls[i];

            // Dispatch is read-only unconditionally, so the declared flag and value must agree,
            // and a revert span is meaningless (nothing to roll back).
            if (!cc.isStatic) revert NonStaticSubCall();
            if (cc.value != 0) revert StaticCallWithValue();
            if (cc.revertNextNCalls != 0) revert StaticCallWithRevertSpan();

            address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
            // STATICCALL to a codeless address silently succeeds — reject so the prover can't pre-hash a no-op.
            if (sourceProxy.code.length == 0) revert StaticCallProxyNotDeployed(sourceProxy);
            (bool success, bytes memory retData) = sourceProxy.staticcall(
                abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.gas, cc.data))
            );
            computedHash = _rollingHashStaticResult(computedHash, success, retData);
        }
    }

    // ──────────────────────────────────────────────
    //  Internal helpers
    // ──────────────────────────────────────────────

    /// @notice Copies the `n`-call span at `start` into a fresh memory array. Explicit field copy
    ///         (not element assignment) so the fresh structs don't alias the caller's array. The
    ///         caller zeroes the trigger's `revertNextNCalls` before slicing (so `span[0]` copies 0
    ///         and the isolated re-run won't recurse into the same span).
    function _sliceCrossChainCalls(CrossChainCall[] memory calls, uint256 start, uint256 n)
        internal
        pure
        returns (CrossChainCall[] memory span)
    {
        span = new CrossChainCall[](n);
        for (uint256 k = 0; k < n; k++) {
            CrossChainCall memory source = calls[start + k];
            span[k] = CrossChainCall({
                revertNextNCalls: source.revertNextNCalls,
                isStatic: source.isStatic,
                gas: source.gas,
                sourceAddress: source.sourceAddress,
                sourceRollupId: source.sourceRollupId,
                targetAddress: source.targetAddress,
                value: source.value,
                data: source.data
            });
        }
    }
}
