// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEEZ, L2ToL1Call, LookupCall, ProxyInfo, ExecutionEntry, ExpectedL1ToL2Call} from "../interfaces/IEEZ.sol";
import {CrossChainProxy} from "./CrossChainProxy.sol";

/// @title EEZBase
/// @notice Shared base for the L1 (`EEZ`) and L2 (`EEZL2`) cross-chain managers.
/// @dev Holds every concern that is currently identical between L1 and L2:
///        - Rolling-hash machinery (tag constants, `_rollingHash`, fold helpers).
///        - The three transient execution cursors (`_currentEntryIndex`, `_currentCallNumber`,
///          `_lastNestedActionConsumed`) and the `_insideExecution()` predicate that reads them.
///        - The `authorizedProxies` registry, the external `createCrossChainProxy` entry point,
///          and the internal CREATE2 deploy helper (`_createCrossChainProxyInternal`).
///        - Pure / view helpers (`computeCrossChainCallHash`, `computeCrossChainProxyAddress`,
///          `_decodeContextResult`).
///        - Lookup-call resolution helpers (`_resolveLookupCall`, `_processNLookupCalls`).
///        - The set of errors and events that mean the same thing on both contracts.
///
///      What is intentionally NOT extracted yet:
///        - `_processNCalls` (L1 also accounts ether, L2 forwards msg.value as burn).
///        - `_consumeNestedAction` and `staticCallLookup` (L1 also scans a transient
///          lookup-call table that L2 doesn't have).
///        - `executeInContextAndRevert` (only because it calls into the diverging
///          `_processNCalls`).
///        - `_consumeAndExecute` / `_applyAndExecute` (L1's transient-table routing,
///          per-rollup queue, and state-delta application have no L2 counterpart).
abstract contract EEZBase is IEEZ {
    // ──────────────────────────────────────────────
    //  Rolling-hash tag constants
    // ──────────────────────────────────────────────
    uint8 internal constant CALL_BEGIN = 1;
    uint8 internal constant CALL_END = 2;
    uint8 internal constant NESTED_BEGIN = 3;
    uint8 internal constant NESTED_END = 4;


    // ──────────────────────────────────────────────
    //  Storage shared with children
    // ──────────────────────────────────────────────

    /// @notice Mapping of authorized CrossChainProxy contracts to their identity
    mapping(address proxy => ProxyInfo info) public authorizedProxies;

    // ──────────────────────────────────────────────
    //  Transient execution state shared with children
    // ──────────────────────────────────────────────

    /// @notice Transient rolling hash accumulating tagged events across the entire entry
    bytes32 transient _rollingHash;

    /// @notice The current execution entry being processed.
    /// @dev L1 uses this to index `_transientExecutions` while a batch is mid-flight, otherwise
    ///      `verificationByRollup[_currentEntryRollupId].executionQueue`. L2 always indexes `executions`.
    ///      Both meanings are consistent — the child decides where the cursor points.
    uint256 transient _currentEntryIndex;

    /// @notice 1-indexed global call counter and cursor into `entry.L2ToL1Calls[]`.
    /// @dev `_currentCallNumber != 0` also doubles as the `_insideExecution()` predicate.
    uint256 transient _currentCallNumber;

    /// @notice Sequential nested action consumption counter.
    /// @dev Also used by `staticCallLookup` to disambiguate multiple lookup calls within the
    ///      same call.
    uint256 transient _lastNestedActionConsumed;

    /// @notice True while replaying a `failed` LookupCall's sub-execution (`_replayFailedLookup`).
    /// @dev Scopes `_activeCalls()` / `_activeNested()` and the inner-static branch of
    ///      `staticCallLookup` to the failed lookup instead of the containing entry. Always
    ///      cleared by the terminal revert of the replay — and, for nested failed lookups,
    ///      restored to the parent's value by that same revert unwind (transient).
    /// @dev Could be derived instead of stored (saves this slot): if `_replayFailedLookup`
    ///      always wrote the lookup's `destinationRollupId` into the pointer, this would be
    ///      `_failedLookupRollupId != 0`. That's L1-safe (a lookup's `destinationRollupId >= 1`)
    ///      but FRAGILE on L2, where `destinationRollupId` is a parity-only field not guaranteed
    ///      nonzero — a 0 there would make `_insideFailedLookup` read `false` mid-replay and
    ///      silently corrupt the sub-execution. A robust derivation would use an index sentinel
    ///      (`_failedLookupIndex = index + 1`, "inside" = `!= 0`). Kept explicit on purpose for
    ///      clarity; revisit if the transient slot ever matters.
    bool transient _insideFailedLookup;

    /// @notice Locates the failed LookupCall currently being replayed. Storage refs can't be
    ///         transient, so the child encodes (index, rollupId) here and reconstructs the
    ///         storage pointer in `_currentFailedLookup()`. The source table is NOT stored:
    ///         L1 re-derives it from `_transientExecutions.length` (transient prefix vs
    ///         persistent queue); L2 has a single table. `rollupId` is only used for the L1
    ///         persistent `lookupQueue` (0 for a transient-table match and on L2).
    uint256 transient _failedLookupIndex;
    uint256 transient _failedLookupRollupId;

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when a new CrossChainProxy is deployed and registered
    event CrossChainProxyCreated(
        address indexed proxy, address indexed originalAddress, uint256 indexed originalRollupId
    );

    /// @notice Emitted when a cross-chain call is executed via proxy
    event CrossChainCallExecuted(
        bytes32 indexed crossChainCallHash, address indexed proxy, address sourceAddress, bytes callData, uint256 value
    );

    /// @notice Emitted after each call completes in `_processNCalls`.
    /// @dev Not emitted for calls inside a revertSpan (those events are rolled back by the revert).
    event CallResult(uint256 indexed entryIndex, uint256 indexed callNumber, bool success, bytes returnData);

    /// @notice Emitted when a nested action is consumed during reentrant execution
    event NestedActionConsumed(
        uint256 indexed entryIndex, uint256 indexed nestedNumber, bytes32 crossChainCallHash, uint256 callCount
    );

    /// @notice Emitted after an entry's execution completes and all verifications pass
    event EntryExecuted(
        uint256 indexed entryIndex, bytes32 rollingHash, uint256 callsProcessed, uint256 nestedActionsConsumed
    );

    /// @notice Emitted after a revert span is processed via `executeInContextAndRevert`
    event RevertSpanExecuted(uint256 indexed entryIndex, uint256 startCallNumber, uint256 span);

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    /// @notice Error when caller is not a registered CrossChainProxy
    error UnauthorizedProxy();

    /// @notice Error when `executeInContextAndRevert` is called by an external address
    error NotSelf();

    /// @notice Error when no matching execution entry exists for the action hash
    error ExecutionNotFound();

    /// @notice Error when the computed rolling hash doesn't match the entry's `rollingHash`
    error RollingHashMismatch();

    /// @notice Carries execution results out of a reverted context
    /// @dev `nestedActionNotFound` is the deferred-revert flag forwarded from L1's
    ///      `_consumeNestedAction` no-match path. The EVM rolls back the transient write on
    ///      revert, so it has to ride out in the payload. L2 has no such flag and always
    ///      sends `false`.
    error ContextResult(
        bytes32 rollingHash, uint256 lastNestedActionConsumed, uint256 currentCallNumber, bool nestedActionNotFound
    );

    /// @notice Error when `executeInContextAndRevert` reverts with an unexpected error
    error UnexpectedContextRevert(bytes revertData);

    /// @notice Error when not all nested actions were consumed after execution
    error UnconsumedNestedActions();

    /// @notice Error when a lookup-call sub-call targets an un-deployed proxy
    /// @dev STATICCALL to a codeless address returns `(true, "")`; prover could pre-hash that.
    error LookupCallProxyNotDeployed(address sourceProxy);

    /// @notice Error when not all calls were consumed after execution
    error UnconsumedCalls();

    // ──────────────────────────────────────────────
    //  Predicates
    // ──────────────────────────────────────────────

    /// @notice Returns true if currently inside a cross-chain call execution
    function _insideExecution() internal view returns (bool) {
        return _currentCallNumber != 0;
    }

    // ──────────────────────────────────────────────
    //  Virtual calls (implemented by L1 / L2)
    // ──────────────────────────────────────────────

    /// @notice The execution entry currently being processed (child-routed).
    function _currentEntryStorage() internal view virtual returns (ExecutionEntry storage);

    /// @notice The failed LookupCall currently being replayed (child-routed from the
    ///         `_failedLookup*` transient pointer). Only valid while `_insideFailedLookup`.
    function _currentFailedLookup() internal view virtual returns (LookupCall storage);

    /// @notice Processes `count` calls from `_activeCalls()`, advancing the cursors and folding
    ///         the rolling hash. Implemented per child (L1 also accounts ether and returns it as
    ///         `etherOut`; L2 has no ether accounting and returns 0). Declared here so shared
    ///         code (`_replayFailedLookup`) can drive it; callers that don't need the ether sum
    ///         ignore the return.
    function _processNCalls(uint256 count) internal virtual returns (int256 etherOut);

    /// @notice Hook: verify a static lookup's `expectedQueueIndices[]` against live per-rollup queue
    ///         cursors. No-op on base (and on L2, single rollup); L1 overrides.
    function _checkExpectedRollupExecutionQueueIndex(LookupCall storage sc) internal view virtual {}

    // ──────────────────────────────────────────────
    //  Active-execution accessors
    // ──────────────────────────────────────────────
    //
    // `_processNCalls` and `_consumeNestedAction` operate on whichever flat-call / nested
    // table is currently active: the containing `ExecutionEntry` normally, or the `LookupCall`
    // being replayed while `_insideFailedLookup`. The element types (`L2ToL1Call`,
    // `ExpectedL1ToL2Call`) are identical across both parents, so a single storage-pointer
    // accessor serves both. Solidity evaluates only the taken ternary branch, so
    // `_currentFailedLookup()` is never read outside a failed-lookup replay.

    /// @notice The flat call array driving the current execution.
    function _activeCalls() internal view returns (L2ToL1Call[] storage) {
        return _insideFailedLookup ? _currentFailedLookup().calls : _currentEntryStorage().L2ToL1Calls;
    }

    /// @notice The nested (reentrant L1→L2) table for the current execution.
    function _activeNested() internal view returns (ExpectedL1ToL2Call[] storage) {
        return _insideFailedLookup ? _currentFailedLookup().expectedL1ToL2Calls : _currentEntryStorage().expectedL1ToL2Calls;
    }

    // ──────────────────────────────────────────────
    //  Proxy creation
    // ──────────────────────────────────────────────

    /// @notice Creates a new CrossChainProxy for an address on another rollup
    /// @param originalAddress The address this proxy represents on the source rollup
    /// @param originalRollupId The source rollup ID
    /// @return proxy The deployed proxy address
    function createCrossChainProxy(address originalAddress, uint256 originalRollupId) external returns (address proxy) {
        return _createCrossChainProxyInternal(originalAddress, originalRollupId);
    }

    /// @notice Deploys a CrossChainProxy via CREATE2 and registers it as authorized
    function _createCrossChainProxyInternal(address originalAddress, uint256 originalRollupId)
        internal
        returns (address proxy)
    {
        bytes32 salt = keccak256(abi.encodePacked(originalRollupId, originalAddress));
        proxy = address(new CrossChainProxy{salt: salt}(address(this), originalAddress, originalRollupId));
        authorizedProxies[proxy] = ProxyInfo(originalAddress, uint64(originalRollupId));
        emit CrossChainProxyCreated(proxy, originalAddress, originalRollupId);
    }

    /// @notice Computes the deterministic CREATE2 address for a CrossChainProxy
    /// @param originalAddress The address this proxy represents on the source rollup
    /// @param originalRollupId The source rollup ID
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

    // ──────────────────────────────────────────────
    //  Cross-chain call hash helper
    // ──────────────────────────────────────────────

    /// @notice Computes the cross-chain call hash from individual fields. Public so off-chain
    ///         tooling can derive the hash for a planned cross-chain call. Identical formula on
    ///         L1 and L2 so a single off-chain helper can target either chain.
    /// @dev Formula: `keccak256(abi.encode(targetRollupId, targetAddress, value, data,
    ///      sourceAddress, sourceRollupId))`. Field order MUST match `L2ToL1Call` field order
    ///      plus the source pair appended; reordering would break every on-chain hash check
    ///      and every off-chain tool that pre-computes the hash.
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
    //  Revert-context decode helper
    // ──────────────────────────────────────────────

    /// @notice Decodes a `ContextResult` revert payload returned by `executeInContextAndRevert`.
    /// @dev Validates selector AND length (4 + 4*32 = 132) before the raw mloads — defense
    ///      against a truncated revert that happens to share the selector.
    function _decodeContextResult(bytes memory revertData)
        internal
        pure
        returns (bytes32 rollingHash, uint256 naConsumed, uint256 callNumber, bool nestedActionNotFound)
    {
        if (bytes4(revertData) != ContextResult.selector) {
            revert UnexpectedContextRevert(revertData);
        }
        if (revertData.length < 132) revert UnexpectedContextRevert(revertData);
        assembly {
            let ptr := add(revertData, 36)
            rollingHash := mload(ptr)
            naConsumed := mload(add(ptr, 32))
            callNumber := mload(add(ptr, 64))
            nestedActionNotFound := mload(add(ptr, 96))
        }
    }

    // ──────────────────────────────────────────────
    //  Lookup-call resolution
    // ──────────────────────────────────────────────

    /// @notice Resolves a static-context `LookupCall`: returns its cached data, or reverts with
    ///         it when `failed`. Checks the queue-index pins and the sub-calls' rolling hash.
    /// @dev Static path only (`staticCallLookup`). Failed lookups consumed *during execution*
    ///      go through `_replayFailedLookup` (real, tagged sub-execution).
    function _resolveLookupCall(LookupCall storage sc) internal view returns (bytes memory) {
        // Check that all rollups are on their expected queue index
        _checkExpectedRollupExecutionQueueIndex(sc);
        // Always compare: empty `calls[]` hashes to 0, which must match a sub-call-less lookup's
        // `rollingHash` (0) — so malformed lookups are caught uniformly.
        if (_processNLookupCalls(sc.calls) != sc.rollingHash) revert RollingHashMismatch();
        if (sc.failed) {
            bytes memory returnData = sc.returnData;
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return sc.returnData;
    }

    /// @notice Replays a `failed` LookupCall as a self-contained mini-entry, then reverts with
    ///         its cached `returnData`. The single resolution path for failed lookups consumed
    ///         during execution (reentrant or top-level); a plain failed lookup is just the
    ///         `callCount == 0` case (no-op sub-execution).
    /// @dev Runs INLINE in the consuming `executeCrossChainCall` frame; the terminal revert
    ///      discards the sub-call state AND restores the outer cursors (the EVM rolls back every
    ///      tstore write here), so the pre-revert hash/count checks need no `ContextResult`
    ///      escape. Nested failed lookups compose for free via that same revert unwind.
    function _replayFailedLookup(LookupCall storage sc, uint256 index) internal {
        _checkExpectedRollupExecutionQueueIndex(sc); // content-addressing pin, same as the static path

        // Pointer for deeper frames to re-derive this lookup (`_currentFailedLookup()`); storage
        // refs can't be transient. The lookup's own `destinationRollupId` is the L1 persistent
        // `lookupQueue` it lives in (ignored for a transient match, and on L2's single table).
        _failedLookupIndex = index;
        _failedLookupRollupId = sc.destinationRollupId;
        _insideFailedLookup = true;

        // Fresh sub-execution context (rolled back by the terminal revert).
        _rollingHash = bytes32(0);
        _currentCallNumber = 0;
        _lastNestedActionConsumed = 0;

        _processNCalls(sc.callCount);

        // Entry-style end checks against the lookup's own expected values.
        if (_rollingHash != sc.rollingHash) revert RollingHashMismatch();
        if (_currentCallNumber != sc.calls.length) revert UnconsumedCalls();
        if (_lastNestedActionConsumed != sc.expectedL1ToL2Calls.length) revert UnconsumedNestedActions();

        bytes memory returnData = sc.returnData;
        assembly {
            revert(add(returnData, 0x20), mload(returnData))
        }
    }

    /// @notice Executes the lookup call's optional `calls[]` in static context and computes
    ///         a rolling hash of the results. No `revertSpan` handling — every call is
    ///         executed as-is.
    /// @dev All proxies referenced by `calls` must already be deployed; CREATE2 is not
    ///      available inside a STATICCALL frame. The accumulator is a local variable, not
    ///      `_rollingHash`, so this call is verified against `LookupCall.rollingHash` — a
    ///      separate accumulator.
    /// @dev SCHEMA NOTE: this rolling hash uses a deliberately simpler, **untagged**
    ///      schema — `keccak256(prev, success, retData)` per sub-call — and **diverges**
    ///      from the entry-level rolling hash (which uses tagged events
    ///      `CALL_BEGIN`/`CALL_END`/`NESTED_BEGIN`/`NESTED_END` with `callNumber`).
    ///      This is safe because the surrounding `LookupCall` is content-addressed by
    ///      `(crossChainCallHash, destinationRollupId, callNumber, lastNestedActionConsumed)`,
    ///      which already pins the entry/call/nesting context that the entry-level tags
    ///      disambiguate. See `docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md` §E.2 for the rationale.
    function _processNLookupCalls(L2ToL1Call[] memory calls) internal view returns (bytes32 computedHash) {
        for (uint256 i = 0; i < calls.length; i++) {
            L2ToL1Call memory cc = calls[i];
            address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
            // STATICCALL to a codeless address silently succeeds — reject so the prover can't pre-hash a no-op.
            if (sourceProxy.code.length == 0) revert LookupCallProxyNotDeployed(sourceProxy);
            (bool success, bytes memory retData) =
                sourceProxy.staticcall(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)));
            computedHash = _rollingHashStaticResult(computedHash, success, retData);
        }
    }

    // ──────────────────────────────────────────────
    //  Rolling hash helpers
    // ──────────────────────────────────────────────
    //
    // The entry-level `_rollingHash` accumulator is updated at four event points during
    // entry execution: at the start and end of each top-level call, and at the start and
    // end of each nested-action frame. Each event is tagged with a domain byte
    // (CALL_BEGIN/CALL_END/NESTED_BEGIN/NESTED_END) so the same set of inputs can't collide
    // across event types. The final value is checked against `entry.rollingHash` at the end
    // of execution. See `docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md` §E for the full specification.
    //
    // Static-call sub-hashes (`_rollingHashStaticResult`) use a simpler, untagged formula
    // because they're verified against `LookupCall.rollingHash`, a separate accumulator
    // whose surrounding lookup key already pins the entry/call/nesting context. See the
    // schema-divergence note on `_processNLookupCalls` above and spec §E.2.

    /// @notice Folds a CALL_BEGIN event into `_rollingHash` for the given call number.
    function _rollingHashCallBegin(uint256 callNumber) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_BEGIN, callNumber));
    }

    /// @notice Folds a CALL_END event into `_rollingHash`, including the call's observed
    ///         outcome (success flag + raw return/revert data).
    function _rollingHashCallEnd(uint256 callNumber, bool success, bytes memory retData) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_END, callNumber, success, retData));
    }

    /// @notice Folds a NESTED_BEGIN event into `_rollingHash` for the given nested-action
    ///         index (1-indexed).
    function _rollingHashNestedBegin(uint256 nestedNumber) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_BEGIN, nestedNumber));
    }

    /// @notice Folds a NESTED_END event into `_rollingHash` for the given nested-action
    ///         index (1-indexed).
    function _rollingHashNestedEnd(uint256 nestedNumber) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_END, nestedNumber));
    }

    /// @notice Folds a static sub-call result into a local accumulator. Pure: doesn't touch
    ///         `_rollingHash` because lookup calls are verified against
    ///         `LookupCall.rollingHash`, a separate per-LookupCall accumulator.
    ///          Is much less constrained since static calls does not have state race conditions
    function _rollingHashStaticResult(bytes32 prev, bool success, bytes memory retData)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(prev, success, retData));
    }
}
