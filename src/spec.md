# Contract Specification

## Architecture Overview

The system consists of four core contracts that enable cross-chain execution between L1 (Ethereum mainnet) and multiple L2 rollups.

### Contracts

| Contract | Layer | Purpose |
|---|---|---|
| **Rollups** | L1 | Manages rollup state roots, ZK-proven batch posting, cross-chain call execution, and ether accounting |
| **CrossChainManagerL2** | L2 | Manages cross-chain execution via system-loaded execution tables. No ZK proofs or state deltas |
| **CrossChainProxy** | Both | Deterministic proxy deployed per (address, rollupId) pair. Routes calls to the manager and forwards outbound calls to destinations |
| **IZKVerifier** | L1 | Interface for external ZK proof verification. A single method: `verify(proof, publicInputsHash) -> bool` |
| **IMetaCrossChainReceiver** | L1 | Callback interface (`src/interfaces/`). `postBatch` invokes `executeMetaCrossChainTransactions()` on `msg.sender` (when it has code) after the immediate entry, so the caller can consume transient entries via proxy calls |

### Shared Interface

Both Rollups and CrossChainManagerL2 implement `ICrossChainManager`, which exposes:

- `executeCrossChainCall(sourceAddress, callData)` -- entry point for proxies
- `staticCallLookup(sourceAddress, callData)` -- view function for static context lookups
- `createCrossChainProxy(originalAddress, originalRollupId)` -- deploys a proxy
- `computeCrossChainProxyAddress(originalAddress, originalRollupId)` -- computes deterministic address

---

## Struct Definitions

### Action

```solidity
struct Action {
    uint256 rollupId;
    address destination;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollup;
}
```

Used off-chain to compute `actionHash = keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup))`. Not stored on-chain in `ExecutionEntry`. The on-chain contracts reconstruct the hash from proxy identity and call parameters.

### StateDelta

```solidity
struct StateDelta {
    uint256 rollupId;
    bytes32 newState;
    int256 etherDelta;
}
```

Represents a state root transition for one rollup. `currentState` is not stored -- the ZK proof binds to the previous state root, which is read from on-chain storage at proof time and included in the entry hash.

### CrossChainCall

```solidity
struct CrossChainCall {
    address destination;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollup;
    uint256 revertSpan;
}
```

A single call in the flat execution array. When `revertSpan > 0`, the next `revertSpan` calls (including this one) execute inside an isolated revert context via `executeInContext`. The first call's `revertSpan` is cleared inside the context so it executes normally rather than recursively opening another context.

### NestedAction

```solidity
struct NestedAction {
    bytes32 actionHash;
    uint256 callCount;
    bytes returnData;
}
```

Pre-computed result for a **successful** reentrant cross-chain call triggered during execution. Consumed sequentially from the entry's flat `nestedActions[]` array. `callCount` specifies how many iterations from the entry-level flat `calls[]` array belong to this nested action.

All nested actions must succeed. A reverted nested call rolls back transient storage (including the consumption index), making it impossible to distinguish "call was made and reverted" from "call was never made." Failed/reverting calls must use `StaticCall` instead.

### ExecutionEntry

```solidity
struct ExecutionEntry {
    StateDelta[] stateDeltas;
    bytes32 actionHash;
    CrossChainCall[] calls;
    NestedAction[] nestedActions;
    uint256 callCount;
    bytes returnData;
    bool failed;
    bytes32 rollingHash;
}
```

The central execution unit. Fields:

- `stateDeltas` -- state root changes (L1 only; empty on L2)
- `actionHash` -- identifies what triggered this entry. `bytes32(0)` means immediate (L2TX or state commitment in postBatch)
- `calls` -- flat array of ALL cross-chain calls in execution order
- `nestedActions` -- flat array of reentrant call results, consumed sequentially by index
- `callCount` -- number of entry-level iterations to process from `calls[]`
- `returnData` -- pre-computed return data for the entry point
- `failed` -- if true, the entry point call reverts with `returnData`
- `rollingHash` -- expected hash after processing all calls (verified at completion)

### StaticCall

```solidity
struct StaticCall {
    bytes32 actionHash;
    bytes returnData;
    bool failed;
    bytes32 stateRoot;
    uint64 callNumber;
    uint64 lastNestedActionConsumed;
}
```

Pre-computed result for static (read-only) calls and calls whose revert needs to be replayed. Loaded via `postBatch` (L1) or `loadExecutionTable` (L2). The `callNumber` and `lastNestedActionConsumed` fields disambiguate which phase of execution the static call belongs to, since the same `actionHash` may appear at different points in the execution tree.

### ProxyInfo

```solidity
struct ProxyInfo {
    address originalAddress;
    uint64 originalRollupId;
}
```

Stored in the `authorizedProxies` mapping. Identifies which cross-chain identity a proxy represents.

### RollupConfig (L1 only)

```solidity
struct RollupConfig {
    address owner;
    bytes32 verificationKey;
    bytes32 stateRoot;
    uint256 etherBalance;
}
```

---

## Execution Model

### Flat Calls Array

All cross-chain calls for an entry live in a single flat `entry.calls[]` array, processed sequentially. There is no recursion in the call processing loop. Reentrant calls triggered during execution (when a destination contract calls back into a proxy) are handled through the `nestedActions[]` array, not by recursive invocation of the call processor.

### Entry-Level and Nested-Action callCount

- `entry.callCount` specifies how many calls from `entry.calls[]` are processed at the entry level.
- `nestedAction.callCount` specifies how many calls from `entry.calls[]` are consumed by that nested action.
- Calls are read from storage sequentially; the sum of all `callCount` values (entry-level plus all nested actions) equals `entry.calls.length`.

### Sequential Consumption

Entries are consumed in order via `executionIndex`. Within an entry, nested actions are consumed in order via `_lastNestedActionConsumed`. There is no hash-based lookup or swap-and-pop -- pure sequential indexing.

### Execution Flow

1. **Entry consumption**: `_consumeAndExecute(actionHash, etherIn)` increments `executionIndex`, verifies the next entry's `actionHash` matches, and sets up transient execution context.
2. **Call processing**: `_processNCalls(count)` reads calls from `entry.calls[_currentCallNumber]` in storage. For each call:
   - If `revertSpan == 0`: increment `_currentCallNumber`, hash `CALL_BEGIN`, route through the source proxy via `executeOnBehalf`, hash `CALL_END` with result.
   - If `revertSpan > 0`: clear `revertSpan` in storage, execute via `executeInContext(revertSpan)` (self-call that always reverts with `ContextResult` carrying 3 values), restore transient state from the revert payload, then restore `revertSpan`.
3. **Nested action consumption**: If a destination contract calls back into a proxy during step 2, `executeCrossChainCall` detects `_insideExecution()` is true and calls `_consumeNestedAction`. This verifies the actionHash, hashes `NESTED_BEGIN`/`NESTED_END` tags, calls `_processNCalls(nested.callCount)` for the nested calls, and returns `returnData`.
4. **Verification**: After all calls complete, the contract checks `_rollingHash == entry.rollingHash` and (on L1) verifies ether accounting.
5. **Result**: Returns `entry.returnData`, or reverts with it if `entry.failed` is true.

---

## Entry Points

### postBatch (L1)

```solidity
function postBatch(
    ExecutionEntry[] calldata entries,
    StaticCall[] calldata _staticCalls,
    uint256 transientCount,
    uint256 transientStaticCallCount,
    uint256 blobCount,
    bytes calldata callData,
    bytes calldata proof
) external
```

Posts a batch of execution entries with a single ZK proof. Only one `postBatch` per block (`lastStateUpdateBlock` check). `lastStateUpdateBlock = block.number` is written immediately after proof verification — before any external calls — to (1) enable `executeCrossChainCall`/`executeL2TX` during the meta hook, and (2) block re-entrant `postBatch` from an untrusted hook.

The first `transientCount` entries are pushed to `_transientExecutions` (regular storage cleared at end of call). The first `transientStaticCallCount` static calls go to `_transientStaticCalls`. The flow:

1. Previous persistent `executions` and `staticCalls` are deleted.
2. Transient tables are populated from the leading entries/static calls.
3. **Immediate entry**: if `transientCount >= 1` and `entries[0].actionHash == bytes32(0)`, entry 0 is executed immediately (state deltas applied, calls processed via `_applyAndExecute`). The transient cursor (`_transientExecutionIndex`) advances to 1.
4. **Meta hook**: if `msg.sender` has code, `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` is called. The hook can consume remaining transient entries via cross-chain proxy calls within the same transaction.
5. **Deferred remainder**: if the hook fully drained the transient table (`_transientExecutionIndex == _transientExecutions.length`), `entries[transientCount..]` and `_staticCalls[transientStaticCallCount..]` are pushed to persistent `executions`/`staticCalls`. Otherwise the remainder is dropped (partial consumption = unknown batch state).
6. Transient tables are deleted (SSTORE-to-zero refund). `_transientExecutionIndex` (a `transient` value-type) is also explicitly reset.

When `transientCount == 0`, no immediate execution occurs, no transient tables are populated, and all entries go directly to persistent storage (assuming the empty-transient drain check passes trivially).

### executeCrossChainCall (L1 and L2)

```solidity
function executeCrossChainCall(
    address sourceAddress,
    bytes calldata callData
) external payable returns (bytes memory result)
```

Called by authorized proxies. Computes `actionHash` from the proxy's identity and call parameters.

- If `_insideExecution()` returns true (reentrant call): consumes the next nested action.
- If `_insideExecution()` returns false (top-level call): consumes the next execution entry.

Must be called in the same block as `postBatch` (L1) or `loadExecutionTable` (L2).

### executeL2TX (L1)

```solidity
function executeL2TX() external returns (bytes memory result)
```

Permissionless. Consumes the next execution entry, which must have `actionHash == bytes32(0)`. Cannot be called during an active execution (`_insideExecution()` must return false).

### loadExecutionTable (L2)

```solidity
function loadExecutionTable(
    ExecutionEntry[] calldata entries,
    StaticCall[] calldata _staticCalls
) external onlySystemAddress
```

L2 equivalent of `postBatch`, without ZK proofs or state deltas. The system address loads entries, which must be consumed in the same block (`lastLoadBlock == block.number`).

---

## State Management

### Transient Variables

Five transient variables manage execution context within a single transaction. They are automatically cleared at transaction end.

| Variable | Type | Purpose |
|---|---|---|
| `_currentEntryIndex` | uint256 | Index of the currently executing entry in the active table (`_transientExecutions` if non-empty, otherwise `executions`) |
| `_rollingHash` | bytes32 | Accumulates tagged call/nesting events across the entire entry |
| `_currentCallNumber` | uint256 | 1-indexed global call counter and cursor into `entry.calls[]`. Also serves as `_insideExecution` check: `_currentCallNumber != 0` means inside execution |
| `_lastNestedActionConsumed` | uint256 | Sequential nested action consumption counter. Also used by `staticCallLookup` to disambiguate phases within the same call |
| `_transientExecutionIndex` | uint256 | Tracks how many transient entries have been consumed. Not advanced on consumption — set explicitly by `postBatch` (immediate entry) and `_consumeAndExecute` (hook-driven entries). Used to gate whether deferred entries are published |

The `_insideExecution()` internal view function returns `_currentCallNumber != 0`.

### Transient-Backed Storage

Two regular storage arrays act as semantically transient tables — populated at the start of `postBatch` and deleted at the end:

| Variable | Type | Purpose |
|---|---|---|
| `_transientExecutions` | ExecutionEntry[] | Leading `transientCount` entries, consumed during the immediate entry and meta hook |
| `_transientStaticCalls` | StaticCall[] | Leading `transientStaticCallCount` static calls, scanned before persistent `staticCalls` in `staticCallLookup` |

These use regular storage (not Solidity `transient` data location) because `transient` does not yet support reference types with nested dynamic arrays. The SSTORE-to-zero refund on the trailing `delete` recovers most of the gas cost.

The discriminator `_transientExecutions.length != 0` routes all entry consumption (`_currentEntryStorage()`, `_consumeAndExecute`) to the transient table. Running off the end of the transient table during execution reverts with `ExecutionNotFound` — there is no silent fall-through to persistent storage.

### Execution Table Lifecycle

1. **Load**: `postBatch` (L1) or `loadExecutionTable` (L2) clears previous persistent data. On L1, the first `transientCount` entries go to `_transientExecutions` and the first `transientStaticCallCount` static calls go to `_transientStaticCalls`.
2. **Immediate + hook consumption (L1 transient path)**: The immediate entry (if any) and the `IMetaCrossChainReceiver` hook consume transient entries in-order. The transient cursor `_transientExecutionIndex` tracks progress. If the hook fully drains the transient table, the deferred remainder is published to persistent storage.
3. **Deferred consumption**: Entries in persistent `executions` are consumed sequentially via `executionIndex`. Each `executeCrossChainCall` or `executeL2TX` increments the index.
4. **Block constraint**: All entries must be consumed in the same block they were loaded. Enforced by `lastStateUpdateBlock` (L1) or `lastLoadBlock` (L2).
5. **Nested actions**: Within an entry, nested actions are consumed sequentially. After execution completes, the contract verifies `_lastNestedActionConsumed == entry.nestedActions.length` (all consumed) and `_currentCallNumber == entry.calls.length` (all calls consumed).
6. **Cleanup (L1)**: `_transientExecutions`, `_transientStaticCalls`, and `_transientExecutionIndex` are cleared at the end of `postBatch`.

---

## Proxy System

### CREATE2 Deployment

Proxies are deployed deterministically via CREATE2:

- **Salt**: `keccak256(abi.encodePacked(originalRollupId, originalAddress))`
- **Bytecode**: `CrossChainProxy` creation code with constructor args `(manager, originalAddress, originalRollupId)`
- **Address**: Standard CREATE2 formula: `keccak256(0xff, deployer, salt, bytecodeHash)`

The `domain`/`block.chainid` parameter was removed from the salt. `computeCrossChainProxyAddress(originalAddress, originalRollupId)` takes 2 parameters.

### Transparent Proxy Pattern

CrossChainProxy uses a pattern inspired by OpenZeppelin's TransparentProxy:

- **Manager calling `executeOnBehalf`**: Forwards the call directly to the destination. This is the outbound path -- the manager routes calls through proxies so that `msg.sender` on the destination is the deterministic proxy address.
- **Anyone else calling `executeOnBehalf`**: Routes through `_fallback()` into the cross-chain execution path.
- **`staticCheck`**: When called by self, attempts `tstore` to detect STATICCALL context. When called by anyone else, routes through `_fallback()`.

### Static Call Detection

The proxy detects whether it is inside a STATICCALL context:

1. Self-call to `staticCheck()`, which attempts `_staticDetector = 0` (a transient store).
2. If the self-call reverts, we are in a static context. Route to `staticCallLookup` (view function) on the manager.
3. If it succeeds, we are in a normal context. Route to `executeCrossChainCall` on the manager.

This works because `tstore` reverts in a STATICCALL context, while `tload` does not.

---

## ZK Verification (L1)

### Entry Hash Construction

For each entry, the entry hash includes:

```
entryHash = keccak256(abi.encodePacked(
    abi.encode(entry.stateDeltas),
    abi.encode(verificationKeys[]),
    abi.encode(previousStateRoots[]),
    entry.actionHash,
    entry.rollingHash
))
```

Where `verificationKeys[]` and `previousStateRoots[]` are gathered from on-chain `rollups[rollupId]` storage for each delta's rollup ID.

### Public Inputs Hash

```
publicInputsHash = keccak256(abi.encodePacked(
    blockhash(block.number - 1),
    block.timestamp,
    abi.encode(entryHashes[]),
    abi.encode(blobHashes[]),
    keccak256(callData)
))
```

Where `blobHashes` are obtained via the `blobhash()` opcode for each blob index.

### Verification

The ZK verifier is called with: `ZK_VERIFIER.verify(proof, publicInputsHash)`. If verification fails, `postBatch` reverts with `InvalidProof()`.

---

## Ether Accounting (L1 Only)

L1 tracks ETH flow through rollup balances:

1. **Inflow**: `msg.value` from `executeCrossChainCall`.
2. **Outflow**: ETH sent in successful cross-chain calls (tracked per-call in `_processNCalls`).
3. **State deltas**: Each `StateDelta` has `etherDelta` (positive = rollup gains ETH, negative = rollup loses ETH).
4. **Verification**: After all calls and state deltas are processed: `totalEtherDelta == etherIn - etherOut`. If not, reverts with `EtherDeltaMismatch`.
5. **Balance enforcement**: If a rollup's `etherBalance` would go negative, reverts with `InsufficientRollupBalance`.

L2 does not track ether accounting. Instead, `executeCrossChainCall` forwards any `msg.value` to `SYSTEM_ADDRESS` (burn).

---

## Rollup Management (L1)

Owner-only functions for managing rollup configuration:

| Function | Purpose |
|---|---|
| `createRollup(initialState, verificationKey, owner)` | Creates a new rollup with sequential ID |
| `setStateByOwner(rollupId, newStateRoot)` | Updates state root without proof |
| `setVerificationKey(rollupId, newVerificationKey)` | Updates the ZK verification key |
| `transferRollupOwnership(rollupId, newOwner)` | Transfers rollup ownership |
