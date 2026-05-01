// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IZKVerifier} from "./IZKVerifier.sol";
import {CrossChainProxy} from "./CrossChainProxy.sol";
import {
    ICrossChainManager,
    StateDelta,
    CrossChainCall,
    NestedAction,
    StaticCall,
    ExecutionEntry,
    ProxyInfo
} from "./ICrossChainManager.sol";
import {IMetaCrossChainReceiver} from "./interfaces/IMetaCrossChainReceiver.sol";

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
///      update state on the spot. Deferred entries live either in a transient-backed table
///      (`_transientExecutions`, first `transientCount` entries of a batch — consumed within the
///      same transaction via the IMetaCrossChainReceiver hook) or in the persistent `executions`
///      table. Consumers always consult the transient table first.
///      Each entry contains pre-computed calls and a rolling hash for verification.
///
/// TODO(callers): `postBatch` now takes TWO transient-count parameters between `_staticCalls`
///                and `blobCount`: `transientCount` (entries) and `transientStaticCallCount`
///                (static calls). Update tests/scripts/README/visualizator/E2E helpers to the
///                new 7-arg signature. There is no longer a legacy path: to get immediate
///                execution of entries[0] (actionHash == 0), `transientCount` must be >= 1.
///                Callers that want purely-deferred batches pass 0 and entries[0] will land
///                in `executions` for a later executeL2TX().
/// TODO(docs):    Update CLAUDE.md `postBatch` description to document the two transient
///                counts, the IMetaCrossChainReceiver hook, and the "immediate entry covers
///                pure L2 transactions + L2 transactions that touch L1" framing.
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

    // ── Transient-backed execution entries & static calls ──
    //
    // First N entries / M static calls of a batch live here instead of the persistent
    // `executions` / `staticCalls` arrays to save storage gas. Semantically transient
    // (populated and cleared within a single postBatch call) but declared as regular
    // storage since Solidity 0.8.34 does not yet support `transient` data location for
    // reference types with nested dynamic arrays. Both are cleared at the end of every
    // postBatch, regardless of success.
    // TODO: promote to real `transient` once Solidity supports transient reference types
    //       with nested dynamic arrays — until then, we rely on manual `delete` at the
    //       end of every postBatch plus SSTORE refunds from zeroing the slots.
    ExecutionEntry[] public _transientExecutions;
    StaticCall[] public _transientStaticCalls;

    /// @notice Cursor into `_transientExecutions` for the next entry to consume.
    /// @dev Only meaningful while `_transientExecutions.length != 0`. The table's length
    ///      itself is what flags "inside a transient batch" for `_currentEntryStorage()`
    ///      and `_consumeAndExecute`; this variable just tracks progress. Transient so it
    ///      resets between transactions automatically, and explicitly reset at the end
    ///      of every postBatch.
    uint256 transient _transientExecutionIndex;

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

    /// @notice Error when executeL2TX is called while already inside a cross-chain execution
    error L2TXNotAllowedDuringExecution();

    /// @notice Error when `transientCount` passed to postBatch exceeds the number of entries
    error TransientCountExceedsEntries();

    /// @notice Error when `transientStaticCallCount` exceeds the number of static calls
    error TransientStaticCallCountExceedsStaticCalls();

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
    /// @dev Flow:
    ///      1. Proof is verified against hashes of all entries.
    ///      2. The first `transientCount` entries are loaded into `_transientExecutions`
    ///         (semantically transient — cleared before the call returns).
    ///      3. If entries[0].actionHash == 0, that entry is the batch's immediate
    ///         execution (pure L2 transactions + L2 transactions that touch L1) and is
    ///         applied on the spot from the transient table so the cursor advances past it.
    ///      4. If msg.sender has code, its IMetaCrossChainReceiver hook is invoked so it
    ///         can drive the rest of the transient-backed entries via cross-chain proxy
    ///         calls within the same transaction.
    ///      5. If the hook drained every transient entry, the remainder
    ///         (index >= transientCount) is pushed to persistent `executions` for
    ///         deferred consumption via executeL2TX / proxy calls later in the same block.
    ///         If it did not, the remainder is discarded — the ZK proof blessed the batch
    ///         as an ordered group, and partial transient consumption means we can't
    ///         soundly promise the rest.
    ///      `transientCount == 0` is allowed but skips immediate execution: all entries
    ///      (including entries[0] with actionHash == 0) are deferred to persistent
    ///      `executions` after the hook returns, to be consumed later via executeL2TX()
    ///      or proxy calls. The hook is still fired unconditionally when msg.sender has code.
    /// @param entries The execution entries to process, expected to be consumed sequentially
    /// @param _staticCalls The static call results to store
    /// @param transientCount Number of leading entries routed through `_transientExecutions`;
    ///                       the rest are deferred to persistent storage only if transient is
    ///                       fully consumed by the immediate entry and the meta hook
    /// @param transientStaticCallCount Number of leading static calls routed through
    ///                       `_transientStaticCalls`; the rest are deferred to persistent
    ///                       `staticCalls` under the same "transient executions drained" gate
    /// @param blobCount Number of blobs containing shared data
    /// @param callData Shared data passed via calldata
    /// @param proof The ZK proof covering all entries
    function postBatch(
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata _staticCalls,
        uint256 transientCount,
        uint256 transientStaticCallCount,
        uint256 blobCount,
        bytes calldata callData,
        bytes calldata proof
    ) external {
        if (lastStateUpdateBlock == block.number) {
            revert StateAlreadyUpdatedThisBlock();
        }
        if (transientCount > entries.length) {
            revert TransientCountExceedsEntries();
        }
        if (transientStaticCallCount > _staticCalls.length) {
            revert TransientStaticCallCountExceedsStaticCalls();
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

        // Mark this block as state-updated BEFORE any external calls (the immediate
        // entry's `_processNCalls` and the meta hook). Two reasons:
        //   1. `executeCrossChainCall` / `executeL2TX` guard on
        //      `lastStateUpdateBlock == block.number`. Without this early write the
        //      meta hook couldn't call either — it would revert ExecutionNotInCurrentBlock.
        //   2. Doubles as re-entrancy protection against a nested `postBatch`: the
        //      outer guard (`lastStateUpdateBlock == block.number` reverts
        //      `StateAlreadyUpdatedThisBlock`) now triggers on any recursive entry,
        //      keeping `executions` / `staticCalls` / `_transientExecutions` from
        //      being wiped mid-flight by an untrusted hook.
        lastStateUpdateBlock = block.number;

        // Reset persistent tables. `_transientExecutions` is only cleared at the end
        // of this call — every path below reaches that cleanup, so doing it here too
        // would just be redundant SSTOREs.
        delete executions;
        delete staticCalls;
        executionIndex = 0;

        // Load transient-backed tables. Static calls don't have a consumption cursor
        // (they're content-addressed by actionHash + callNumber + lastNestedActionConsumed),
        // so the transient-first split is purely about where `staticCallLookup` reads from.
        for (uint256 i = 0; i < transientStaticCallCount; i++) {
            _transientStaticCalls.push(_staticCalls[i]);
        }

        for (uint256 i = 0; i < transientCount; i++) {
            _transientExecutions.push(entries[i]);
        }

        // Immediate entry (pure L2 transactions + L2 transactions that touch L1) runs
        // from the transient table so the cursor advances past it before the hook fires.
        // Requires `transientCount >= 1` — callers that want an immediate entry must put
        // at least entries[0] in the transient region. `_currentEntryStorage()` routes
        // into `_transientExecutions` because its length is non-zero.
        if (transientCount > 0 && entries[0].actionHash == bytes32(0)) {
            _currentEntryIndex = 0;
            // Eecute first N ( para salvaguardar en caso que la del meido pete)
            _applyAndExecute(entries[0].stateDeltas, entries[0].callCount, entries[0].rollingHash, 0);
            _transientExecutionIndex = 1;
        }

        // Give the caller (if it is a contract) a chance to drive the remaining
        // transient entries via cross-chain proxy calls in this same transaction.
        // Only invoke when unconsumed transient entries remain — if the immediate
        // entry drained the table (or transientCount == 0), there is nothing to drive.
        if (_transientExecutionIndex < _transientExecutions.length && msg.sender.code.length > 0) {
            IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions();
        }

        // Only publish the deferred remainder if the hook honored the proven ordering
        // and drained the transient execution table. Partial consumption means we're in
        // an unknown state wrt the batch ordering — drop the residual entries AND their
        // associated static calls instead of committing them as if the prefix had
        // executed cleanly.
        if (_transientExecutionIndex == _transientExecutions.length) {
            for (uint256 i = transientCount; i < entries.length; i++) {
                executions.push(entries[i]);
            }
            for (uint256 i = transientStaticCallCount; i < _staticCalls.length; i++) {
                staticCalls.push(_staticCalls[i]);
            }
        }

        // Clear the semantically-transient tables so their slots go back to zero
        // (SSTORE refund) and nothing leaks into the next transaction.
        delete _transientExecutions;
        delete _transientStaticCalls;
        _transientExecutionIndex = 0;

        emit BatchPosted(entries, publicInputsHash);
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

        emit L2TXExecuted(executionIndex);
        return _consumeAndExecute(bytes32(0), 0);
    }

    // ──────────────────────────────────────────────
    //  Internal execution
    // ──────────────────────────────────────────────

    /// @notice Resolves the entry currently being processed.
    /// @dev `_transientExecutions.length != 0` is the single discriminator: a non-empty
    ///      transient table means we're inside a transient batch and `_currentEntryIndex`
    ///      indexes `_transientExecutions`; empty means it indexes persistent `executions`.
    ///      Both arrays are regular storage, so the pointer type is the same.
    function _currentEntryStorage() internal view returns (ExecutionEntry storage entry) {
        if (_transientExecutions.length != 0) {
            entry = _transientExecutions[_currentEntryIndex];
        } else {
            entry = executions[_currentEntryIndex];
        }
    }

    /// @notice Consumes the next nested action, or replays a pre-computed reverting
    ///         static call when no NestedAction matches.
    /// @dev Routing rules:
    ///      1. NestedAction at `_lastNestedActionConsumed` matches `actionHash` → consume
    ///         (the speculative `++` bump is what commits, hash NESTED_BEGIN/END, return
    ///         cached returnData).
    ///      2. Otherwise scan `_transientStaticCalls` then `staticCalls` for a `failed=true`
    ///         entry keyed by (actionHash, _currentCallNumber, idx) where `idx` is the
    ///         pre-bump cursor value → revert with cached returnData. Every fallback path
    ///         reverts, so the speculative bump is rolled back by the EVM automatically.
    ///      3. No match → revert `ExecutionNotFound`.
    ///
    ///      Why fall back only on `failed=true`: a successful reentrant call in a normal CALL
    ///      frame is expressed as a NestedAction; a successful read-only call is in a STATICCALL
    ///      frame and routed to `staticCallLookup` instead. A static-call hit on this path only
    ///      makes sense when the caller has try/catch and expects a revert. The fallback
    ///      sidesteps the transient-rollback issue (TODO 1b): a successful match's bump
    ///      persists; every other path reverts and the bump rolls back with it.
    function _consumeNestedAction(bytes32 actionHash) internal returns (bytes memory) {
        ExecutionEntry storage entry = _currentEntryStorage();
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

        // 2. Fallback. The lookup key uses `idx` (the pre-bump cursor) — that's what the
        //    prover observed. Reading `_lastNestedActionConsumed` directly would give idx+1.
        uint64 callNum = uint64(_currentCallNumber);
        uint64 lastNA = uint64(idx);
        for (uint256 i = 0; i < _transientStaticCalls.length; i++) {
            StaticCall storage sc = _transientStaticCalls[i];
            if (
                sc.failed && sc.actionHash == actionHash && sc.callNumber == callNum
                    && sc.lastNestedActionConsumed == lastNA
            ) {
                _resolveStaticCall(sc); // always reverts (sc.failed == true)
            }
        }
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

    /// @notice Consumes the next execution entry, applies state deltas, executes calls, and verifies rolling hash
    /// @dev Consults the transient table first ("always look for transient calls before storage calls").
    ///      While a postBatch call is running, `_transientExecutions` is non-empty and ALL consumption
    ///      is routed through it — the entries are NOT popped, only `_transientExecutionIndex` advances.
    ///      Running past the end inside a transient batch is treated as a hard `ExecutionNotFound`
    ///      (not a fall-through): the ZK proof sized the batch, and the hook trying to consume more
    ///      than that is a protocol bug. Outside a transient batch (`_transientExecutions.length == 0`),
    ///      consumption goes straight to persistent `executions`.
    /// @param actionHash The expected action input hash for the next entry
    /// @param etherIn The ETH value received (msg.value) for ether accounting
    /// @return result The pre-computed return data from the action
    function _consumeAndExecute(bytes32 actionHash, int256 etherIn) internal returns (bytes memory result) {
        uint256 idx;
        ExecutionEntry storage entry;

        // Inside a transient batch, all consumption comes from `_transientExecutions`.
        // Running past the end is a protocol bug (the batch is shorter than the hook
        // tried to consume), not a fall-through to persistent `executions` — those
        // haven't been written yet.
        if (_transientExecutions.length != 0) {
            idx = _transientExecutionIndex++;
            if (idx >= _transientExecutions.length) revert ExecutionNotFound();
            entry = _transientExecutions[idx];
        } else {
            idx = executionIndex++;
            if (idx >= executions.length) revert ExecutionNotFound();
            entry = executions[idx];
        }

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

        ExecutionEntry storage entry = _currentEntryStorage();
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
        ExecutionEntry storage entry = _currentEntryStorage();
        uint256 processed = 0;
        while (processed < count) {
            uint256 revertSpan = entry.calls[_currentCallNumber].revertSpan;

            if (revertSpan == 0) {
                CrossChainCall memory cc = entry.calls[_currentCallNumber];
                _currentCallNumber++;

                _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_BEGIN, _currentCallNumber));

                address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
                if (authorizedProxies[sourceProxy].originalAddress == address(0)) {
                    _createCrossChainProxyInternal(cc.sourceAddress, cc.sourceRollupId);
                }

                (bool success, bytes memory retData) = sourceProxy.call{value: cc.value}(
                    abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data))
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
    ///      Consults `_transientStaticCalls` first (populated only while a postBatch is
    ///      executing its transient prefix) and falls through to the persistent
    ///      `staticCalls` array. tload works in static context, so the transient tracking
    ///      variables used to compute the match keys are readable.
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

        // Transient-first, then persistent. Each hit is terminal (returns or reverts
        // from within `_resolveStaticCall`).
        for (uint256 i = 0; i < _transientStaticCalls.length; i++) {
            StaticCall storage sc = _transientStaticCalls[i];
            if (sc.actionHash == actionHash && sc.callNumber == callNum && sc.lastNestedActionConsumed == lastNA) {
                return _resolveStaticCall(sc);
            }
        }
        for (uint256 i = 0; i < staticCalls.length; i++) {
            StaticCall storage sc = staticCalls[i];
            if (sc.actionHash == actionHash && sc.callNumber == callNum && sc.lastNestedActionConsumed == lastNA) {
                return _resolveStaticCall(sc);
            }
        }

        revert ExecutionNotFound();
    }

    /// @notice Verifies and unpacks a matched static call entry — replaying the static
    ///         call subcalls (if any), checking the rolling hash, and either returning
    ///         the cached return data or bubbling up the cached revert.
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
