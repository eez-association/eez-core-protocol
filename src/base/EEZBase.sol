// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEEZ, ProxyInfo} from "../interfaces/IEEZ.sol";
import {CrossChainProxy} from "./CrossChainProxy.sol";

/// @title EEZBase
/// @notice Direction-neutral shared base for the L1 (`EEZ`) and L2 (`EEZL2`) cross-chain managers.
/// @dev Holds ONLY the machinery that is identical on both sides AND never names a direction-
///      specific execution struct (those structs differ per side — `IEEZ.sol` vs `IEEZL2.sol`):
///        - Rolling-hash tag constants, the `_rollingHash` accumulator, and the fold helpers
///          (they operate on primitives, so they don't reference any execution struct).
///        - Neutral transient pointers: `_currentEntryIndex`, `_insideRevertedLookup`,
///          `_revertedLookupIndex`, `_revertedLookupTopLevel`, and `_topLevelLookupIndex` —
///          plus `_activeLookupContext()`, the match-key component derived from them.
///        - The `authorizedProxies` registry, the external `createCrossChainProxy` entry point,
///          and the internal CREATE2 deploy helper (`_createCrossChainProxyInternal`).
///        - Pure / view helpers (`computeCrossChainCallHash`, `computeCrossChainProxyAddress`).
///        - The `ContextResult` revert transport and its decoder (`_decodeContextResult`).
///        - The set of errors / events that mean the same thing on both contracts and carry no
///          direction in their name.
///
///      What lives in the children (`EEZ` / `EEZL2`) instead, because it names the per-side
///      execution structs or a per-side cursor:
///        - The call cursors — absolute-directional on L1 (`_currentL2ToL1Call` /
///          `_lastL1ToL2CallConsumed`), self-relative on L2 (`_currentIncomingCall` /
///          `_lastOutgoingCallConsumed`) — and `_insideExecution()`.
///        - `_processNCalls`, `_consumeNestedAction`, `_consumeAndExecute`.
///        - `_activeCalls` / `_activeNested` / `_getActiveLookups`, `_getCurrentEntryStoragePointer`,
///          `_currentTopLevelLookup`, `_resolveStaticLookup`, `_processNStaticCalls`,
///          `_executeRevertedNestedLookup` / `_executeRevertedTopLevelLookup`, `staticCallLookup`.
///        - The per-side events and errors (L1: `L1ToL2CallConsumed`, `UnconsumedL2ToL1Calls`, …;
///          L2: `OutgoingCallConsumed`, `UnconsumedIncomingCalls`, …).
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

    /// @notice True while executing a reverted NESTED lookup (`_executeRevertedNestedLookup`) — the
    ///         `ExpectedLookup` at `_revertedLookupIndex` within the active host table.
    /// @dev Scopes `_activeCalls()` / `_activeNested()` to that lookup instead of the host.
    ///      Always cleared by the terminal revert of the sub-execution — and, for deeper reverted-lookup executions,
    ///      restored to the parent's value by that same revert unwind (transient).
    bool transient _insideRevertedLookup;

    /// @notice Index of the nested `ExpectedLookup` being executed, within the active host
    ///         table (`_getActiveLookups()`). Storage refs can't be transient, so the child
    ///         reconstructs the pointer from this index.
    uint256 transient _revertedLookupIndex;

    /// @notice True while a reverted TOP-LEVEL `LookupCall` is the active host
    ///         (`_executeRevertedTopLevelLookup`) — the pool lookup at `_topLevelLookupIndex` supplies
    ///         the flat calls, reentrant table, and nested-lookup table instead of an entry.
    bool transient _revertedLookupTopLevel;

    /// @notice Pool index of the top-level `LookupCall` being executed. Kept separate from
    ///         `_revertedLookupIndex` so a nested reverted-lookup execution inside a top-level reverted-lookup execution doesn't
    ///         clobber the pool coordinate. L1 re-derives the pool (transient table vs
    ///         per-rollup queue keyed by `_revertedLookupRollupId`) from
    ///         `_transientExecutions.length`; L2 has a single table.
    uint256 transient _topLevelLookupIndex;

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

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    /// @notice Error when caller is not a registered CrossChainProxy
    error UnauthorizedProxy();

    /// @notice Error when a self-call-only entry point (`executeInContextAndRevert`,
    ///         L1's `attemptApplyImmediate`) is called by an external address
    error NotSelf();

    /// @notice Error when no matching execution entry exists for the action hash
    error ExecutionNotFound();

    /// @notice Error when the computed rolling hash doesn't match the entry's `rollingHash`
    error RollingHashMismatch();

    /// @notice Carries execution results out of a reverted context
    /// @dev Direction-neutral transport. `callNotFound` is the deferred-revert flag forwarded
    ///      from L1's `_consumeNestedAction` no-match path. The EVM rolls back the transient
    ///      write on revert, so it has to ride out in the payload. L2 has no such flag and
    ///      always sends `false`.
    error ContextResult(bytes32 rollingHash, uint256 reentrantConsumed, uint256 callsProcessed, bool callNotFound);

    /// @notice Error when `executeInContextAndRevert` reverts with an unexpected error
    error UnexpectedContextRevert(bytes revertData);

    /// @notice Error when a lookup-call sub-call targets an un-deployed proxy
    /// @dev STATICCALL to a codeless address returns `(true, "")`; prover could pre-hash that.
    error LookupCallProxyNotDeployed(address sourceProxy);

    /// @notice Error when a call marked `isStatic` was loaded carrying ETH value.
    /// @dev A STATICCALL cannot transfer value, so a non-zero `value` on a static call is a
    ///      malformed entry. We reject it explicitly rather than silently dropping the value.
    error StaticCallWithValue();

    /// @notice Error when a proxy is requested for an address on THIS manager's own network.
    /// @dev A CrossChainProxy stands in for a REMOTE address; a same-network proxy is meaningless
    ///      and unsafe. L1 (EEZ) forbids `MAINNET_ROLLUP_ID` (0); L2 (EEZL2) forbids its own
    ///      `ROLLUP_ID`. Enforced in `_createCrossChainProxyInternal`, so it also blocks the
    ///      auto-creation path during execution, not just the external entry point.
    error SameNetworkProxy(uint256 rollupId);

    // ──────────────────────────────────────────────
    //  Proxy creation
    // ──────────────────────────────────────────────

    /// @notice This manager's own network rollup id — a proxy may NOT be created for it.
    /// @dev L1 (EEZ) returns `MAINNET_ROLLUP_ID` (0); L2 (EEZL2) returns its own `ROLLUP_ID`.
    function _getRollupId() internal view virtual returns (uint256);

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
        // A proxy stands in for a REMOTE address — never one on this manager's own network.
        if (originalRollupId == _getRollupId()) revert SameNetworkProxy(originalRollupId);
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
    ///      sourceAddress, sourceRollupId))`. Field order MUST match the call struct field order
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
    //  Lookup-context helper
    // ──────────────────────────────────────────────

    /// @notice Fourth component of the nested-lookup match key (`executingLookupIndex`):
    ///         0 = host level; k = inside the sub-execution of the host's `expectedLookups[k-1]`.
    function _activeLookupContext() internal view returns (uint64) {
        return _insideRevertedLookup ? uint64(_revertedLookupIndex + 1) : 0;
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
        returns (bytes32 rollingHash, uint256 reentrantConsumed, uint256 callsProcessed, bool callNotFound)
    {
        if (bytes4(revertData) != ContextResult.selector) {
            revert UnexpectedContextRevert(revertData);
        }
        if (revertData.length < 132) revert UnexpectedContextRevert(revertData);
        assembly {
            let ptr := add(revertData, 36)
            rollingHash := mload(ptr)
            reentrantConsumed := mload(add(ptr, 32))
            callsProcessed := mload(add(ptr, 64))
            callNotFound := mload(add(ptr, 96))
        }
    }

    // ──────────────────────────────────────────────
    //  Rolling hash helpers
    // ──────────────────────────────────────────────
    //
    // The entry-level `_rollingHash` accumulator is updated at four event points during
    // entry execution: at the start and end of each top-level call, and at the start and
    // end of each reentrant frame. Each event is tagged with a domain byte
    // (CALL_BEGIN/CALL_END/NESTED_BEGIN/NESTED_END) so the same set of inputs can't collide
    // across event types. The final value is checked against `entry.rollingHash` at the end
    // of execution. See `docs/CORE_PROTOCOL_SPEC.md` §E for the full specification.
    //
    // Static-call sub-hashes (`_rollingHashStaticResult`) use a simpler, untagged formula
    // because they're verified against `LookupCall.rollingHash`, a separate accumulator
    // whose surrounding lookup key already pins the entry/call/nesting context. See spec §E.2.
    //
    // These tags are protocol constants — a call executed on either chain MUST hash the same
    // way for the proof, so the "nested" wording here is the neutral rolling-hash frame
    // concept, NOT a direction (the directional naming lives in the per-side children).

    /// @notice Folds a CALL_BEGIN event into `_rollingHash` for the given call number.
    function _rollingHashCallBegin(uint256 callNumber) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_BEGIN, callNumber));
    }

    /// @notice Folds a CALL_END event into `_rollingHash`, including the call's observed
    ///         outcome (success flag + raw return/revert data).
    function _rollingHashCallEnd(uint256 callNumber, bool success, bytes memory retData) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_END, callNumber, success, retData));
    }

    /// @notice Folds a NESTED_BEGIN event into `_rollingHash` for the given reentrant-frame
    ///         index (1-indexed).
    function _rollingHashNestedBegin(uint256 nestedNumber) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_BEGIN, nestedNumber));
    }

    /// @notice Folds a NESTED_END event into `_rollingHash` for the given reentrant-frame
    ///         index (1-indexed).
    function _rollingHashNestedEnd(uint256 nestedNumber) internal {
        _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_END, nestedNumber));
    }

    /// @notice Folds a static sub-call result into a local accumulator. Pure: doesn't touch
    ///         `_rollingHash` because lookup calls are verified against
    ///         `LookupCall.rollingHash`, a separate per-LookupCall accumulator.
    ///          Is much less constrained since static calls do not have state race conditions
    function _rollingHashStaticResult(bytes32 prev, bool success, bytes memory retData)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(prev, success, retData));
    }
}
