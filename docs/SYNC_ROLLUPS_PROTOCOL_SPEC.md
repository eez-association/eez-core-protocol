# Sync-Rollups Protocol Specification

**Source**: `src/`
**Purpose**: Formal reference for implementing the Rust rollup node. Supersedes informal comments in source code.

This document covers the **flat sequential execution model**. Every cross-chain entry is a flat list of `CrossChainCall`s processed sequentially, with reentrant calls resolved via a parallel `NestedAction[]` table and integrity verified by a single `rollingHash` per entry.

---

## Table of Contents

- [A. Data Model](#a-data-model)
- [B. Core Protocol Functions](#b-core-protocol-functions)
- [C. Action Hash Computation](#c-action-hash-computation)
- [D. Execution Model](#d-execution-model)
- [E. Rolling Hash](#e-rolling-hash)
- [F. Static Call Lookup](#f-static-call-lookup)
- [G. Execution Entry Lifecycle](#g-execution-entry-lifecycle)
- [H. Invariants](#h-invariants)
- [I. Security Considerations](#i-security-considerations)

---

## A. Data Model

### A.1 Core Structs

#### Action (off-chain only)

Used by tooling / the prover to compute `actionHash`. Not stored on-chain — the contracts reconstruct the hash from individual fields (`_computeActionInputHash`).

```solidity
struct Action {
    uint256 targetRollupId;  // target rollup (where this call executes)
    address targetAddress;   // contract being called on the target rollup
    uint256 value;           // ETH sent with the call
    bytes   data;            // calldata
    address sourceAddress;   // caller identity on the source rollup
    uint256 sourceRollupId;  // source rollup ID
}
```

The struct carries only the six fields above. Field declaration order matches the `abi.encode` preimage — do not reorder.

#### StateDelta

Describes one rollup's state transition caused by executing one entry. The previous state root is **not** stored in the delta — the proof binds to the live `rollups[id].stateRoot` via the entry-hash construction in `_computeEntryHashes`.

```solidity
struct StateDelta {
    uint256 rollupId;     // which rollup's state changes
    bytes32 newState;     // post-execution state root
    int256  etherDelta;   // signed change in rollup's ETH balance
}
```

#### CrossChainCall

A single call in the entry's flat `calls[]` array.

```solidity
struct CrossChainCall {
    address targetAddress;
    uint256 value;
    bytes   data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;   // 0 = normal call; N>0 = open isolated revert context for next N calls (this one inclusive)
}
```

#### NestedAction

Pre-computed result for a **successful** reentrant cross-chain call.

```solidity
struct NestedAction {
    bytes32 actionHash;   // hash of the reentrant call (must equal _computeActionInputHash at consumption)
    uint256 callCount;    // iterations from entry.calls[] consumed inside this nested action
    bytes   returnData;   // the value returned to the destination contract
}
```

Reverting reentrant calls cannot be expressed as `NestedAction` — they must use `StaticCall` with `failed = true`.

#### ExecutionEntry

The central execution unit. Loaded by `postBatch` (L1) or `loadExecutionTable` (L2).

```solidity
struct ExecutionEntry {
    StateDelta[]      stateDeltas;   // L1 only — state root deltas; on L2 typically empty
    bytes32           actionHash;    // bytes32(0) = immediate, otherwise the trigger action hash
    CrossChainCall[]  calls;         // flat array of all calls in execution order
    NestedAction[]    nestedActions; // sequentially consumed by reentrant calls
    uint256           callCount;     // number of entry-level iterations to process
    bytes             returnData;    // pre-computed return data for the entry's top-level call
    bool              failed;        // if true, top-level call reverts with returnData
    bytes32           rollingHash;   // expected hash after all calls and nestings complete
}
```

#### StaticCall

Pre-computed result for a static (read-only) call or for a reverting reentrant call.

```solidity
struct StaticCall {
    bytes32          actionHash;
    bytes            returnData;
    bool             failed;                     // true → lookup reverts with returnData
    bytes32          stateRoot;                  // expected state root for the target rollup (informational)
    uint64           callNumber;                 // _currentCallNumber at lookup time
    uint64           lastNestedActionConsumed;   // _lastNestedActionConsumed at lookup time
    CrossChainCall[] calls;                      // optional sub-calls executed in static context
    bytes32          rollingHash;                // expected hash of those sub-calls (verified)
}
```

#### ProxyInfo

```solidity
struct ProxyInfo {
    address originalAddress;
    uint64  originalRollupId;
}
```

#### RollupConfig (L1 only)

```solidity
struct RollupConfig {
    address owner;            // can call setStateByOwner / setVerificationKey / transferRollupOwnership
    bytes32 verificationKey;  // used to derive proof public inputs
    bytes32 stateRoot;        // current committed state root
    uint256 etherBalance;     // ETH held on behalf of this rollup
}
```

### A.2 Storage Layout

#### Rollups.sol (L1)

| Slot | Variable | Type | Notes |
|------|----------|------|-------|
| 0 | `rollupCounter` | uint256 | Next rollup ID |
| 1 | `rollups` | mapping(uint256 ⇒ RollupConfig) | Per-rollup config |
| 2 | `executions` | ExecutionEntry[] | Persistent deferred entries |
| 3 | `staticCalls` | StaticCall[] | Persistent static calls |
| 4 | `executionIndex` | uint256 | Cursor into `executions` |
| 5 | `authorizedProxies` | mapping(address ⇒ ProxyInfo) | Registered proxies |
| 6 | `lastStateUpdateBlock` | uint256 | Block of last `postBatch` |
| 7 | `_transientExecutions` | ExecutionEntry[] | Transient-backed entries (cleared each `postBatch`) |
| 8 | `_transientStaticCalls` | StaticCall[] | Transient-backed static calls |
| transient | `_transientExecutionIndex` | uint256 | Cursor into `_transientExecutions` |
| transient | `_currentEntryIndex` | uint256 | Active entry index for nested-action consumption |
| transient | `_rollingHash` | bytes32 | Rolling hash accumulator |
| transient | `_currentCallNumber` | uint256 | 1-indexed global call counter; doubles as `_insideExecution` flag (`!= 0`) |
| transient | `_lastNestedActionConsumed` | uint256 | Sequential nested-action cursor |

`MAINNET_ROLLUP_ID = 0` is a constant. `ZK_VERIFIER` is immutable. The four rolling-hash tag constants `CALL_BEGIN=1, CALL_END=2, NESTED_BEGIN=3, NESTED_END=4` are internal constants.

`_transientExecutions` and `_transientStaticCalls` are declared as regular storage arrays (not Solidity `transient`) because the `transient` data location does not yet support reference types with nested dynamic arrays. They are cleared at the end of every `postBatch` via `delete`, recovering most of the gas cost via SSTORE-to-zero refunds.

#### CrossChainManagerL2.sol (L2)

| Slot | Variable | Type | Notes |
|------|----------|------|-------|
| 0 | `executions` | ExecutionEntry[] | Persistent entries |
| 1 | `staticCalls` | StaticCall[] | Persistent static calls |
| 2 | `authorizedProxies` | mapping(address ⇒ ProxyInfo) | Registered proxies |
| 3 | `lastLoadBlock` | uint256 | Block of last `loadExecutionTable` |
| 4 | `executionIndex` | uint256 | Cursor into `executions` |
| transient | `_currentEntryIndex` | uint256 | Active entry index |
| transient | `_rollingHash` | bytes32 | Rolling hash accumulator |
| transient | `_currentCallNumber` | uint256 | 1-indexed global call counter |
| transient | `_lastNestedActionConsumed` | uint256 | Nested-action cursor |

`ROLLUP_ID` and `SYSTEM_ADDRESS` are immutables.

### A.3 Transient Variables and `_insideExecution`

`_insideExecution()` is `_currentCallNumber != 0`. The first call processed inside an entry sets `_currentCallNumber` to 1 (and increments from there); the entry-completion path resets `_currentCallNumber = 0` so a subsequent top-level entry starts cleanly.

The transient variables are read by `executeCrossChainCall` (to route to `_consumeAndExecute` vs `_consumeNestedAction`) and by `staticCallLookup` (to compute the disambiguation key). They are reset implicitly between transactions by EIP-1153.

---

## B. Core Protocol Functions

### B.1 Rollups.sol (L1)

#### `createRollup`

```solidity
function createRollup(bytes32 initialState, bytes32 verificationKey, address owner)
    external returns (uint256 rollupId)
```

Permissionless. `rollupId = rollupCounter++`; `rollups[rollupId] = RollupConfig(owner, verificationKey, initialState, 0)`.

Emits `RollupCreated(rollupId, owner, verificationKey, initialState)`.

#### `postBatch`

```solidity
function postBatch(
    ExecutionEntry[] calldata entries,
    StaticCall[]     calldata _staticCalls,
    uint256                   transientCount,
    uint256                   transientStaticCallCount,
    uint256                   blobCount,
    bytes            calldata callData,
    bytes            calldata proof
) external
```

Permissionless.

**Preconditions**:
- `lastStateUpdateBlock != block.number` (one batch per block).
- `transientCount <= entries.length` else `TransientCountExceedsEntries`.
- `transientStaticCallCount <= _staticCalls.length` else `TransientStaticCallCountExceedsStaticCalls`.
- Proof verifies for the constructed `publicInputsHash`.

**Public-inputs construction** (exact encoding):

```solidity
// Per-entry hash:
for each entry i in entries:
    vks[j]        = rollups[entry[i].stateDeltas[j].rollupId].verificationKey   for each delta j
    prevStates[j] = rollups[entry[i].stateDeltas[j].rollupId].stateRoot         for each delta j

    entryHashes[i] = keccak256(abi.encodePacked(
        abi.encode(entry[i].stateDeltas),
        abi.encode(vks),
        abi.encode(prevStates),
        entry[i].actionHash,
        entry[i].rollingHash
    ))

// Per-blob hash:
for i in 0 .. blobCount:
    blobHashes[i] = blobhash(i)

publicInputsHash = keccak256(abi.encodePacked(
    blockhash(block.number - 1),
    block.timestamp,
    abi.encode(entryHashes),
    abi.encode(blobHashes),
    keccak256(callData)
))
```

The verifier is invoked as `ZK_VERIFIER.verify(proof, publicInputsHash)` and must return `true`.

**State transitions** (in order):

1. **Verify proof**. Revert `InvalidProof` on failure.
2. **Mark block**: `lastStateUpdateBlock = block.number`. This happens **before** any external call so (a) `executeCrossChainCall` / `executeL2TX` work during the meta hook, and (b) re-entrant `postBatch` is blocked by the same-block guard.
3. **Wipe persistent**: `delete executions; delete staticCalls; executionIndex = 0`.
4. **Populate transient tables**: push leading entries into `_transientExecutions` and leading static calls into `_transientStaticCalls`.
5. **Immediate entry**: if `transientCount > 0 && entries[0].actionHash == bytes32(0)`, set `_currentEntryIndex = 0` and call `_applyAndExecute(entries[0].stateDeltas, entries[0].callCount, entries[0].rollingHash, 0)`. Then set `_transientExecutionIndex = 1`.
6. **Meta hook**: if `msg.sender.code.length > 0`, call `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()`. The hook may invoke `executeCrossChainCall` and `executeL2TX` to consume the rest of `_transientExecutions`.
7. **Deferred publish**: if `_transientExecutionIndex == _transientExecutions.length` (transient table fully drained), push `entries[transientCount..]` to `executions` and `_staticCalls[transientStaticCallCount..]` to `staticCalls`. Otherwise drop the remainder.
8. **Cleanup**: `delete _transientExecutions; delete _transientStaticCalls; _transientExecutionIndex = 0`.
9. Emit `BatchPosted(entries, publicInputsHash)`.

**Revert conditions**: `StateAlreadyUpdatedThisBlock`, `TransientCountExceedsEntries`, `TransientStaticCallCountExceedsStaticCalls`, `InvalidProof`, plus whatever the immediate entry / meta hook revert with (`RollingHashMismatch`, `EtherDeltaMismatch`, `InsufficientRollupBalance`, `UnconsumedCalls`, `UnconsumedNestedActions`, `ExecutionNotFound`, …).

#### `executeCrossChainCall`

```solidity
function executeCrossChainCall(address sourceAddress, bytes calldata callData)
    external payable returns (bytes memory result)
```

**Access control**: caller must be a registered proxy (`authorizedProxies[msg.sender].originalAddress != address(0)`); else `UnauthorizedProxy`.

**Preconditions**: `lastStateUpdateBlock == block.number` else `ExecutionNotInCurrentBlock`.

**Logic**:

```solidity
ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
bytes32 actionHash = _computeActionInputHash(
    proxyInfo.originalRollupId,   // targetRollupId
    proxyInfo.originalAddress,    // targetAddress
    msg.value,                    // value
    callData,                     // data
    sourceAddress,                // sourceAddress
    MAINNET_ROLLUP_ID             // sourceRollupId (L1 = 0)
);
emit CrossChainCallExecuted(actionHash, msg.sender, sourceAddress, callData, msg.value);

if (_insideExecution()) {
    return _consumeNestedAction(actionHash);
}
return _consumeAndExecute(actionHash, int256(msg.value));
```

**Revert conditions**: `UnauthorizedProxy`, `ExecutionNotInCurrentBlock`, `ExecutionNotFound`, `RollingHashMismatch`, `UnconsumedCalls`, `UnconsumedNestedActions`, `EtherDeltaMismatch`, `InsufficientRollupBalance`, `NoNestedActionAvailable`, plus any revert from the destination call (which is captured into `_rollingHash` via `CALL_END`).

#### `executeL2TX`

```solidity
function executeL2TX() external returns (bytes memory result)
```

Permissionless. Consumes the next entry, which **must** have `actionHash == bytes32(0)`. Cannot run during an active execution.

```solidity
if (lastStateUpdateBlock != block.number) revert ExecutionNotInCurrentBlock();
if (_insideExecution()) revert L2TXNotAllowedDuringExecution();
emit L2TXExecuted(executionIndex);
return _consumeAndExecute(bytes32(0), 0);
```

#### `staticCallLookup`

```solidity
function staticCallLookup(address sourceAddress, bytes calldata callData)
    external view returns (bytes memory)
```

Called via STATICCALL by `CrossChainProxy._fallback` when the proxy detects static context. Caller must be a registered proxy.

```solidity
bytes32 actionHash = _computeActionInputHash(
    proxyInfo.originalRollupId,
    proxyInfo.originalAddress,
    0,                            // value = 0 in static context
    callData,
    sourceAddress,
    MAINNET_ROLLUP_ID
);
uint64 callNum = uint64(_currentCallNumber);
uint64 lastNA  = uint64(_lastNestedActionConsumed);

// Transient-first scan, then persistent. First match returns / reverts.
for sc in _transientStaticCalls:
    if sc.actionHash == actionHash && sc.callNumber == callNum && sc.lastNestedActionConsumed == lastNA:
        return _resolveStaticCall(sc);
for sc in staticCalls:
    if (same match): return _resolveStaticCall(sc);
revert ExecutionNotFound();
```

`_resolveStaticCall(sc)`:
- If `sc.calls.length > 0`: replay them via `_processNStaticCalls(sc.calls)` (each via `sourceProxy.staticcall(executeOnBehalf(...))`), accumulate the rolling hash, and check `computedHash == sc.rollingHash` else `RollingHashMismatch`.
- If `sc.failed`: revert with `sc.returnData` (bubbles back to the proxy and out to the caller).
- Else return `sc.returnData`.

#### `createCrossChainProxy` / `computeCrossChainProxyAddress`

```solidity
function createCrossChainProxy(address originalAddress, uint256 originalRollupId)
    external returns (address proxy);

function computeCrossChainProxyAddress(address originalAddress, uint256 originalRollupId)
    public view returns (address);
```

Both permissionless.

```solidity
salt         = keccak256(abi.encodePacked(originalRollupId, originalAddress))
bytecodeHash = keccak256(abi.encodePacked(
    type(CrossChainProxy).creationCode,
    abi.encode(address(this), originalAddress, originalRollupId)
))
address      = address(uint160(uint256(keccak256(abi.encodePacked(
                   bytes1(0xff),
                   address(this),    // deployer = the manager (Rollups on L1, CrossChainManagerL2 on L2)
                   salt,
                   bytecodeHash
               )))))
```

The salt is exactly `(originalRollupId, originalAddress)` — no `domain` or `block.chainid` term is mixed in, so the same `(originalAddress, originalRollupId)` pair derives the same proxy address regardless of which manager / chain computes it.

#### Owner functions

```solidity
function setStateByOwner(uint256 rollupId, bytes32 newStateRoot)            external onlyRollupOwner(rollupId)
function setVerificationKey(uint256 rollupId, bytes32 newVerificationKey)   external onlyRollupOwner(rollupId)
function transferRollupOwnership(uint256 rollupId, address newOwner)        external onlyRollupOwner(rollupId)
```

`setStateByOwner` does **not** update `lastStateUpdateBlock` — it is an escape hatch, not a batch post.

#### Internal helpers

##### `_consumeAndExecute(bytes32 actionHash, int256 etherIn) → bytes`

```
if (_transientExecutions.length != 0):
    idx = _transientExecutionIndex++
    if (idx >= _transientExecutions.length): revert ExecutionNotFound
    entry = _transientExecutions[idx]
else:
    idx = executionIndex++
    if (idx >= executions.length): revert ExecutionNotFound
    entry = executions[idx]

if (entry.actionHash != actionHash): revert ExecutionNotFound
emit ExecutionConsumed(actionHash, idx)

_currentEntryIndex = idx
_applyAndExecute(entry.stateDeltas, entry.callCount, entry.rollingHash, etherIn)

returnData = entry.returnData
if (entry.failed): revert with returnData
return returnData
```

Inside an active `postBatch`, `_transientExecutions.length != 0` routes **all** consumption through the transient table — running off the end is a hard `ExecutionNotFound`, never a fall-through to `executions` (which is still empty at that point).

##### `_consumeNestedAction(bytes32 actionHash) → bytes`

```
entry = _currentEntryStorage()
idx   = _lastNestedActionConsumed++
if (idx >= entry.nestedActions.length): revert NoNestedActionAvailable
nested = entry.nestedActions[idx]
if (nested.actionHash != actionHash): revert ExecutionNotFound

nestedNumber = idx + 1
_rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_BEGIN, nestedNumber))
_processNCalls(nested.callCount)
_rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_END, nestedNumber))

return nested.returnData
```

`_currentEntryStorage()` returns `_transientExecutions[_currentEntryIndex]` if `_transientExecutions.length != 0`, else `executions[_currentEntryIndex]`.

##### `_applyAndExecute(StateDelta[] memory deltas, uint256 callCount, bytes32 rollingHash, int256 etherIn)`

```
_rollingHash = bytes32(0)
_currentCallNumber = 0
_lastNestedActionConsumed = 0

etherOut          = _processNCalls(callCount)
totalEtherDelta   = _applyStateDeltas(deltas)

entry = _currentEntryStorage()
require(_rollingHash == rollingHash)                                       // RollingHashMismatch
require(_currentCallNumber == entry.calls.length)                          // UnconsumedCalls
require(_lastNestedActionConsumed == entry.nestedActions.length)           // UnconsumedNestedActions
require(totalEtherDelta == etherIn - etherOut)                             // EtherDeltaMismatch

emit EntryExecuted(_currentEntryIndex, _rollingHash, _currentCallNumber, _lastNestedActionConsumed)
_currentCallNumber = 0   // reset so _insideExecution() returns false again
```

##### `_processNCalls(uint256 count) → int256 etherOut`

Iterates `count` entry-level steps from `entry.calls[_currentCallNumber]`. For each step:

- If `revertSpan == 0`: load the call, increment `_currentCallNumber`, hash `CALL_BEGIN`, derive `sourceProxy` (auto-create if missing), call `CrossChainProxy.executeOnBehalf` through it, hash `CALL_END(success, retData)`, emit `CallResult`. Add `cc.value` to `etherOut` only if `success && cc.value > 0`. Increment `processed` by 1.
- If `revertSpan > 0`: clear the field in storage, save `_currentCallNumber`, `try this.executeInContext(revertSpan)`. Always reverts with `ContextResult`; decode and restore `_rollingHash`, `_lastNestedActionConsumed`, `_currentCallNumber` from the payload. Restore `entry.calls[savedCallNumber].revertSpan = revertSpan`. Emit `RevertSpanExecuted`. Increment `processed` by `revertSpan`.

The same global cursor `_currentCallNumber` is advanced both by entry-level iterations and by nested-action iterations — `_processNCalls` is reused recursively from `_consumeNestedAction`.

##### `executeInContext(uint256 callCount) external`

```
require(msg.sender == address(this))       // NotSelf
_processNCalls(callCount)
revert ContextResult(_rollingHash, _lastNestedActionConsumed, _currentCallNumber)
```

The unconditional revert rolls back all transient writes inside the self-call, but the `ContextResult` payload escapes via the revert data — `_processNCalls`'s caller decodes it and restores the three values. Storage changes inside the span (e.g., destination state on L1) are also rolled back by the EVM revert; the rolling hash and counters survive only because the payload re-applies them after the catch.

##### `_decodeContextResult(bytes memory revertData) → (bytes32, uint256, uint256)`

Verifies `bytes4(revertData) == ContextResult.selector` else `UnexpectedContextRevert(revertData)`; then assembly-loads three uint-sized words at offsets 36, 68, 100.

##### `_applyStateDeltas(StateDelta[] memory deltas) → int256 totalEtherDelta`

For each delta:
- `rollups[delta.rollupId].stateRoot = delta.newState`.
- Accumulate `delta.etherDelta` into `totalEtherDelta`.
- If `delta.etherDelta < 0`: `etherBalance -= |delta|` (revert `InsufficientRollupBalance` on underflow).
- If `delta.etherDelta > 0`: `etherBalance += delta`.
- Emit `L2ExecutionPerformed(rollupId, newState)`.

##### `_processNStaticCalls(CrossChainCall[] memory calls) → bytes32`

```
hash = bytes32(0)
for cc in calls:
    sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId)
    (success, retData) = sourceProxy.staticcall(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)))
    hash = keccak256(abi.encodePacked(hash, success, retData))
return hash
```

No `revertSpan` handling — every call executes as-is. Static context cannot deploy proxies, so all referenced proxies must already exist.

##### `_computeActionInputHash`

```solidity
keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId))
```

##### `_computeEntryHashes(ExecutionEntry[] calldata entries)`

For each entry, gathers `vks[]` and `prevStates[]` from `rollups[delta.rollupId]` and computes:

```solidity
entryHashes[i] = keccak256(abi.encodePacked(
    abi.encode(entry.stateDeltas),
    abi.encode(vks),
    abi.encode(prevStates),
    entry.actionHash,
    entry.rollingHash
))
```

##### `_verifyProof(bytes calldata proof, bytes32 publicInputsHash)`

```solidity
if (!ZK_VERIFIER.verify(proof, publicInputsHash)) revert InvalidProof();
```

### B.2 CrossChainManagerL2.sol (L2)

The L2 contract mirrors the L1 contract's execution logic but with no rollup registry, no state deltas, no ZK proofs, and no transient/deferred split.

#### `loadExecutionTable`

```solidity
function loadExecutionTable(ExecutionEntry[] calldata entries, StaticCall[] calldata _staticCalls)
    external onlySystemAddress
```

```
delete executions
delete staticCalls
executionIndex = 0
for e in entries: executions.push(e)
for s in _staticCalls: staticCalls.push(s)
lastLoadBlock = block.number
emit ExecutionTableLoaded(entries)
```

`onlySystemAddress` reverts `Unauthorized` for any other caller.

#### `executeCrossChainCall` (L2 variant)

Same as L1, with two differences:

1. **`sourceRollup`** in the action hash is `ROLLUP_ID` (this L2's ID), not `MAINNET_ROLLUP_ID`.
2. **ETH burn**: if `msg.value > 0`, the L2 manager forwards it to `SYSTEM_ADDRESS` immediately. Failure of the transfer reverts `EtherTransferFailed`.

L2's `_consumeAndExecute` reads from `executions` only — there is no transient table.

#### Top-level call delivery on L2

Top-level calls on L2 are driven entirely by user transactions hitting proxies (which forward to `executeCrossChainCall`). There is no system-only delivery path on L2; the `executeL2TX` mechanism lives on L1 and handles the L1-side commit of L2 user actions.

#### `staticCallLookup` (L2)

Same as L1, but only scans `staticCalls` (no transient table). `sourceRollup` in the action hash is `ROLLUP_ID`.

#### `createCrossChainProxy` / `computeCrossChainProxyAddress`

Identical to L1 — same salt / bytecode / address formula, deployed by the L2 manager.

### B.3 CrossChainProxy.sol

```solidity
constructor(address _manager, address _originalAddress, uint256 _originalRollupId)
```

Three immutables: `MANAGER`, `ORIGINAL_ADDRESS`, `ORIGINAL_ROLLUP_ID`.

#### `executeOnBehalf(address destination, bytes calldata data) external payable`

If `msg.sender == MANAGER`: call `destination.call{value: msg.value}(data)` and return/revert raw bytes via assembly.

Else: route through `_fallback()` — the transparent-proxy pattern: the manager admin (when the manager itself calls `executeOnBehalf`) gets direct forwarding; any other caller hitting `executeOnBehalf` enters the cross-chain path.

#### `staticCheck() external`

Self-only function used to detect STATICCALL context. If `msg.sender == address(this)`: attempt `_staticDetector = 0` (a `tstore`). In static context this reverts; in normal context it succeeds. Else: route through `_fallback()`.

#### `fallback() external payable` and `_fallback()` internal

```
(detectSuccess, _) = address(this).call(abi.encodeCall(staticCheck, ()))
if (!detectSuccess):
    // STATICCALL context — look up cached result
    (success, result) = MANAGER.staticcall(abi.encodeCall(ICrossChainManager.staticCallLookup, (msg.sender, msg.data)))
else:
    // Normal context — execute cross-chain call
    (success, result) = MANAGER.call{value: msg.value}(abi.encodeCall(ICrossChainManager.executeCrossChainCall, (msg.sender, msg.data)))

if (success):
    result = abi.decode(result, (bytes))    // unwrap the inner bytes returned by ICrossChainManager.*
// assembly return/revert raw result
```

The `abi.decode(result, (bytes))` unwrap is required because `executeCrossChainCall` and `staticCallLookup` both return `bytes memory`, and the low-level `.call() / .staticcall()` ABI-encodes that return value. The proxy strips one layer so the caller sees the destination's raw return data (matching the behavior the destination saw via `executeOnBehalf`'s assembly return).

---

## C. Action Hash Computation

Every action hash is:

```solidity
actionHash = keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId))
```

There is exactly one formula for all entry points and all reentrant calls. The off-chain `Action` struct in `ICrossChainManager.sol` exists purely so tooling can construct the same ABI-encoded preimage as `_computeActionInputHash`.

### C.1 Hash from `executeCrossChainCall` (L1)

| Field | Value |
|---|---|
| `rollupId` | `proxyInfo.originalRollupId` |
| `destination` | `proxyInfo.originalAddress` |
| `value` | `msg.value` |
| `data` | `callData` (forwarded by the proxy as `msg.data`) |
| `sourceAddress` | `sourceAddress` (msg.sender of the original proxy call) |
| `sourceRollup` | `MAINNET_ROLLUP_ID = 0` |

### C.2 Hash from `executeCrossChainCall` (L2)

Same as L1, with `sourceRollup = ROLLUP_ID` (this L2's chain ID).

### C.3 Hash from `staticCallLookup`

Same as the corresponding `executeCrossChainCall`, with `value = 0` (STATICCALL cannot carry ETH). The two values that disambiguate phases — `callNumber` and `lastNestedActionConsumed` — are part of the `StaticCall` struct, not part of the action hash.

### C.4 Hash for nested actions

Identical to the proxy that triggered the reentrant call. The protocol does not distinguish "top-level" vs "reentrant" in the hash itself; the routing decision (`_consumeAndExecute` vs `_consumeNestedAction`) is made at runtime via `_insideExecution()`.

### C.5 No `actionHash` for L2TX entries

`executeL2TX` requires `entry.actionHash == bytes32(0)`. There is no separate L2TX hash — the entry is identified by being the next entry in the table.

---

## D. Execution Model

### D.1 Sequential Entry Consumption

Entries in `executions` (or `_transientExecutions` during `postBatch`) are consumed in posted order via `executionIndex` (or `_transientExecutionIndex`). Each call to `executeCrossChainCall` (top-level), `executeL2TX`, or — during `postBatch`'s meta hook — both, increments the cursor by exactly one. There is no hash-based search and no swap-and-pop.

`_consumeAndExecute` checks `entry.actionHash == expectedHash` and reverts `ExecutionNotFound` on mismatch. This catches out-of-order calls from a buggy hook or a wrong builder.

### D.2 Flat Call Processing

Within an entry, calls live in a single flat array `calls[]` and are processed by a non-recursive `while` loop in `_processNCalls`. Each iteration reads `entry.calls[_currentCallNumber]`, increments the cursor (or self-calls `executeInContext` for revert spans), and continues until `processed == count`.

Reentrant calls share the same `entry.calls[]` and the same `_currentCallNumber` cursor — they recurse into `_processNCalls(nested.callCount)` from inside `_consumeNestedAction`, but the loop itself does not branch through the action data.

The total call accounting at the end of the entry:

```
_currentCallNumber       == entry.calls.length          // UnconsumedCalls
_lastNestedActionConsumed == entry.nestedActions.length // UnconsumedNestedActions
```

The sum of `entry.callCount` plus all `nestedAction.callCount`s **must** equal `entry.calls.length`. This is not enforced as a separate check; it falls out of the two equalities above plus the sequential cursor advance.

### D.3 Reentrant Calls (NestedAction or failed StaticCall)

When the destination contract called by `_processNCalls` calls back into a proxy, the proxy forwards to `executeCrossChainCall`. Inside that call, `_insideExecution() == true` (the global counter is non-zero), so the path branches to `_consumeNestedAction`. The function speculatively bumps the cursor up front (`idx = _lastNestedActionConsumed++`) and then routes:

**1. NestedAction priority.** If `nestedActions[idx].actionHash == actionHash`:
   1. The speculative `++` is the commit — no further cursor write.
   2. Hash `NESTED_BEGIN` into `_rollingHash`.
   3. Recurse into `_processNCalls(nested.callCount)`. Inside that call, `entry.calls[]` is read at positions starting from the current `_currentCallNumber`.
   4. Hash `NESTED_END` into `_rollingHash`.
   5. Return `nested.returnData` to the destination.

**2. Otherwise — fall back to a failed StaticCall.** Scan `_transientStaticCalls` then `staticCalls` for an entry with `failed == true` and matching key `(actionHash, _currentCallNumber, idx)` — note the lookup uses `idx` (the pre-bump cursor), which is what the prover observed; `_lastNestedActionConsumed` itself currently holds `idx + 1`:
   - Hit → `_resolveStaticCall(sc)` replays any `sc.calls` via STATICCALL for integrity, then reverts with `sc.returnData`. The destination's `try/catch` absorbs the revert.
   - No hit → revert `ExecutionNotFound`.

**Why this works for reverts.** Every fallback path reverts, so the speculative `++` rolls back automatically (transient storage follows EVM revert rules). The cursors and `_rollingHash` outside the destination's `try/catch` reflect exactly what the prover simulated. A reverting reentrant call therefore needs **only** a `StaticCall` with `failed=true` — no companion `NestedAction`, no `revertSpan` wrapper.

**Why a `failed=false` static call here is invalid.** A successful reentrant call in a normal CALL frame is expressed as a NestedAction; a successful read-only call is in a STATICCALL frame and routed to `staticCallLookup` (§F) instead. A `failed=false` static entry matching this fallback path is a prover bug — the loop simply doesn't match it, so it falls through to `ExecutionNotFound`.

### D.4 Revert Span

`revertSpan > 0` opens an isolated EVM context for the next `revertSpan` calls. Mechanism:

1. Caller saves `_currentCallNumber` and `entry.calls[saved].revertSpan`, then sets `entry.calls[saved].revertSpan = 0` in storage so the inner self-call sees the call as normal at the same index.
2. `try this.executeInContext(revertSpan)`. The inner call:
   - Runs `_processNCalls(revertSpan)`, which advances `_currentCallNumber`, `_lastNestedActionConsumed`, and `_rollingHash` based on the calls inside the span.
   - **Always** reverts with `ContextResult(_rollingHash, _lastNestedActionConsumed, _currentCallNumber)`.
3. The EVM revert rolls back all storage and transient state inside the self-call. The three values escape via the revert data.
4. Caller decodes `ContextResult` and writes the three values back into transient storage. The rolling hash and cursors now reflect what happened inside the span, even though the EVM rolled the state back.
5. Caller restores `entry.calls[saved].revertSpan = revertSpan` and emits `RevertSpanExecuted`. `processed += revertSpan`.

A single mechanism handles atomic rollback: there are no continuation entries, no per-rollup state-root restoration, no scope tree to navigate. The "what happened" is encoded by the calls in the span; the "what state survives" is whatever the EVM rolled back.

### D.5 Flat Call Model

The off-chain prover emits a flat `calls[]` array plus a parallel `NestedAction[]` table — it does not thread scope arrays through nested calls. Return data from a call is captured directly into the rolling hash via `CALL_END`; reverts are captured via `success=false` in the same `CALL_END` tag (or via `revertSpan` when an entire span must be replayed).

---

## E. Rolling Hash

A single `bytes32 rollingHash` per entry covers every call result and every nesting boundary. The accumulator starts at `bytes32(0)` and is updated at four tagged events:

```
CALL_BEGIN   = uint8(1)   _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_BEGIN,   _currentCallNumber))
CALL_END     = uint8(2)   _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_END,     _currentCallNumber, success, retData))
NESTED_BEGIN = uint8(3)   _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_BEGIN, nestedNumber))
NESTED_END   = uint8(4)   _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_END,   nestedNumber))
```

`_currentCallNumber` is 1-indexed and incremented before `CALL_BEGIN` is hashed. `nestedNumber` is `_lastNestedActionConsumed` after the post-increment that consumed the nested action — also 1-indexed.

After all calls and nestings complete:

```solidity
require(_rollingHash == entry.rollingHash);   // RollingHashMismatch
```

A single mismatch anywhere in the execution tree changes the final hash — this catches:
- Wrong return data for any call
- Wrong success/failure flag
- Missing or extra calls
- Incorrect nesting structure (nested action declared at the wrong depth)
- Reordered operations

### E.1 Rolling Hash and `revertSpan`

Inside a `revertSpan`, the inner self-call updates `_rollingHash` exactly as if the calls were normal (CALL_BEGIN/CALL_END for each, including failed ones). The `ContextResult` revert payload carries the post-span hash value back out, so the outer flow's rolling hash reflects that the span happened — even though the EVM rolled back the state changes the calls produced. This is essential: the proof's `rollingHash` must commit to the calls regardless of whether their state effects survived.

The mechanism relies on EIP-1153 `tload` / `tstore` semantics:

- `tload` is **read-only**, so it works inside a STATICCALL context **and** inside a self-call that is about to revert. The inner self-call therefore observes the outer `_rollingHash`, `_currentCallNumber`, and `_lastNestedActionConsumed` values when it starts.
- `tstore` writes are part of the EVM journal and are **rolled back** when the call frame reverts. So when `executeInContext` reverts with `ContextResult`, every transient write performed inside the span (including the rolling-hash updates and counter increments) is undone — except for the three values that escape via the revert payload, which the caller manually re-applies after decoding.

### E.2 Worked Hash Chain Example

Setup:

```
entry.calls          = [c0, c1, c2, c3, c4]
entry.callCount      = 3
entry.nestedActions  = [ { actionHash = H_nested, callCount = 2, returnData = 0xaa } ]
entry.rollingHash    = <expected final hash>
```

The entry has 5 calls in the flat array. Entry-level processes 3 iterations: c0, c3, c4. While c0 is executing, the destination contract calls back into a proxy, which consumes `nestedActions[0]`; that nested action processes c1 and c2.

Step-by-step:

```
Initial transient state:
  _rollingHash               = 0x0
  _currentCallNumber         = 0
  _lastNestedActionConsumed  = 0

─── Entry-level _processNCalls(3), iteration 0 ─────────────

  Read entry.calls[0] = c0
  _currentCallNumber++ → 1
  hash CALL_BEGIN(callNum=1):
    _rollingHash = keccak256(0x0, uint8(1), uint256(1))                                    → H1

  Execute c0 via the source proxy. During c0, the destination contract calls back
  into a proxy on this chain → executeCrossChainCall → _insideExecution() == true
  → _consumeNestedAction(H_nested):

      idx = _lastNestedActionConsumed++ → idx=0, counter becomes 1
      require(nestedActions[0].actionHash == H_nested)
      nestedNumber = idx + 1 = 1

      hash NESTED_BEGIN(nestedNum=1):
        _rollingHash = keccak256(H1, uint8(3), uint256(1))                                 → H2

      _processNCalls(2):  // nested action's callCount

        Read entry.calls[1] = c1
        _currentCallNumber++ → 2
        hash CALL_BEGIN(callNum=2):
          _rollingHash = keccak256(H2, uint8(1), uint256(2))                               → H3
        Execute c1 via the source proxy. Succeeds with retData_1.
        hash CALL_END(callNum=2, success=true, retData_1):
          _rollingHash = keccak256(H3, uint8(2), uint256(2), true, retData_1)              → H4

        Read entry.calls[2] = c2
        _currentCallNumber++ → 3
        hash CALL_BEGIN(callNum=3):
          _rollingHash = keccak256(H4, uint8(1), uint256(3))                               → H5
        Execute c2 via the source proxy. Succeeds with retData_2.
        hash CALL_END(callNum=3, success=true, retData_2):
          _rollingHash = keccak256(H5, uint8(2), uint256(3), true, retData_2)              → H6

      hash NESTED_END(nestedNum=1):
        _rollingHash = keccak256(H6, uint8(4), uint256(1))                                 → H7

      return nestedActions[0].returnData (0xaa) to the destination contract

  c0's proxy call returns. Proxy reports success and retData_0.
  hash CALL_END(callNum=1, success=true, retData_0):
    _rollingHash = keccak256(H7, uint8(2), uint256(1), true, retData_0)                    → H8

─── Entry-level _processNCalls(3), iteration 1 ─────────────

  Read entry.calls[3] = c3
  _currentCallNumber++ → 4
  hash CALL_BEGIN(callNum=4):
    _rollingHash = keccak256(H8, uint8(1), uint256(4))                                     → H9
  Execute c3. Succeeds with retData_3.
  hash CALL_END(callNum=4, success=true, retData_3):
    _rollingHash = keccak256(H9, uint8(2), uint256(4), true, retData_3)                    → H10

─── Entry-level _processNCalls(3), iteration 2 ─────────────

  Read entry.calls[4] = c4
  _currentCallNumber++ → 5
  hash CALL_BEGIN(callNum=5):
    _rollingHash = keccak256(H10, uint8(1), uint256(5))                                    → H11
  Execute c4. Succeeds with retData_4.
  hash CALL_END(callNum=5, success=true, retData_4):
    _rollingHash = keccak256(H11, uint8(2), uint256(5), true, retData_4)                   → H12

─── Verification ─────────────

  _rollingHash (H12)              == entry.rollingHash             → RollingHashMismatch?       no
  _currentCallNumber (5)          == entry.calls.length (5)        → UnconsumedCalls?           no
  _lastNestedActionConsumed (1)   == entry.nestedActions.length(1) → UnconsumedNestedActions?   no
  _currentCallNumber = 0    // reset so _insideExecution() returns false
```

Hash chain summary:

```
H0  = 0x0
H1  = hash(H0,  CALL_BEGIN,   callNum=1)
H2  = hash(H1,  NESTED_BEGIN, nestedNum=1)
H3  = hash(H2,  CALL_BEGIN,   callNum=2)
H4  = hash(H3,  CALL_END,     callNum=2, true, retData_1)
H5  = hash(H4,  CALL_BEGIN,   callNum=3)
H6  = hash(H5,  CALL_END,     callNum=3, true, retData_2)
H7  = hash(H6,  NESTED_END,   nestedNum=1)
H8  = hash(H7,  CALL_END,     callNum=1, true, retData_0)
H9  = hash(H8,  CALL_BEGIN,   callNum=4)
H10 = hash(H9,  CALL_END,     callNum=4, true, retData_3)
H11 = hash(H10, CALL_BEGIN,   callNum=5)
H12 = hash(H11, CALL_END,     callNum=5, true, retData_4)

require(H12 == entry.rollingHash)
```

### E.3 Multiple Phases Within One Call (Static Call Disambiguation)

A single call iteration can issue several STATICCALLs at distinct points of its execution, possibly with the same `actionHash`. The `(callNumber, lastNestedActionConsumed)` pair forms a coordinate that advances monotonically and never repeats — it is what `staticCalls[]` is keyed on (see §F.1).

Example: while `entry.calls[0]` (call #1 at the entry level) executes, the destination contract:

```
Call #1 begins:
  _currentCallNumber = 1
  _lastNestedActionConsumed = 0

  STATICCALL to proxy → staticCallLookup
    → matched by (actionHash, callNumber=1, lastNestedActionConsumed=0)

  Trigger nested action #1 (a successful reentrant call)
    → _consumeNestedAction post-increments _lastNestedActionConsumed to 1
    → NESTED_BEGIN/END are hashed; nested calls (if any) advance _currentCallNumber

  STATICCALL to proxy → staticCallLookup
    → matched by (actionHash, callNumber=K, lastNestedActionConsumed=1)
       where K is _currentCallNumber after any nested calls
```

Both STATICCALLs may carry the **same** `actionHash` — the builder differentiates them by recording the live values of `_currentCallNumber` and `_lastNestedActionConsumed` at the exact point of each STATICCALL during simulation, and stamping them into the corresponding `StaticCall` entries.

If `_currentCallNumber` advanced inside the nested action (the nested action consumed some of `entry.calls[]`), the second STATICCALL's `callNumber` will be larger than the first's. If the nested action was empty (`callCount == 0`), `_currentCallNumber` stays at 1 and the two STATICCALLs differ only in `lastNestedActionConsumed` (0 vs 1).

---

## F. Static Call Lookup

Static calls (read-only or reverting reentrant calls) are looked up — never executed via the normal call path. There are two entry points into the lookup:

1. **`staticCallLookup`** (external view) — used when the proxy's `_fallback` detects a real STATICCALL context (a self-call to `staticCheck` whose `tstore` reverts). Handles both `failed=true` and `failed=false` entries.
2. **Fallback inside `_consumeNestedAction`** — used when a normal-CALL reentrant call has no matching `NestedAction`. Only matches `failed=true` entries (the destination's `try/catch` consumes the revert). See §D.3.

Both entry points share the same match key and `_resolveStaticCall` helper.

### F.1 Match Key

```
(actionHash, callNumber, lastNestedActionConsumed)
```

- `actionHash` — same formula as `_computeActionInputHash` (with `value = 0`).
- `callNumber` — `uint64(_currentCallNumber)` at lookup time.
- `lastNestedActionConsumed` — `uint64(_lastNestedActionConsumed)` at lookup time.

The two counters together identify a unique phase of execution. They both advance monotonically and never repeat within a single entry's execution.

### F.2 Lookup Algorithm

L1:

```
for sc in _transientStaticCalls:
    if all three fields match: return _resolveStaticCall(sc)
for sc in staticCalls:
    if all three fields match: return _resolveStaticCall(sc)
revert ExecutionNotFound
```

L2: same, but only scans `staticCalls`.

`_resolveStaticCall(sc)`:
- If `sc.calls.length > 0`: replay them in static context (`_processNStaticCalls`) and check `computedHash == sc.rollingHash` (else `RollingHashMismatch`).
- If `sc.failed`: revert with `sc.returnData`.
- Else return `sc.returnData`.

### F.3 Static Sub-Calls

A `StaticCall` may include its own `calls[]` array — these are STATICCALLs that the cached call itself would issue. They are replayed at lookup time in static context (no `revertSpan` handling, no proxy creation), and their composite hash is checked against `sc.rollingHash`.

This lets a static lookup model a contract that performs read-only sub-calls: the lookup verifies the sub-call results match what the proof committed to, and only then returns the cached top-level result.

### F.4 When to use `StaticCall` vs `NestedAction`

| Situation | Use | Routed via |
|---|---|---|
| Reentrant call that **succeeds** | `NestedAction` | `_consumeNestedAction` (priority branch) |
| Reentrant call that **reverts** (caller catches with try/catch) | `StaticCall` with `failed = true` | `_consumeNestedAction` fallback |
| Reentrant cross-chain `STATICCALL` (read-only, success or revert) | `StaticCall` with `failed` set as appropriate | `staticCallLookup` (real STATICCALL frame) |
| Top-level call that should fail | Set `entry.failed = true` (immediate entry only) — or wrap in `revertSpan` | — |

---

## G. Execution Entry Lifecycle

### G.1 L1 Posting

`postBatch` clears persistent `executions` and `staticCalls`, populates `_transientExecutions` and `_transientStaticCalls` from the leading slices, runs the immediate entry (if `entries[0].actionHash == 0`) and the meta hook, then publishes the deferred remainder if the transient table was fully drained, then wipes both transient tables.

Within a single `postBatch`:
1. Persistent tables wiped.
2. Transient tables populated.
3. Immediate entry runs (transient cursor → 1).
4. Meta hook runs (cursor advances per consumption).
5. If `cursor == _transientExecutions.length`: publish deferred remainder to persistent tables.
6. Wipe transient tables; reset cursor.

### G.2 L2 Loading

`loadExecutionTable` clears `executions` and `staticCalls`, copies the new entries / static calls in, and sets `lastLoadBlock = block.number`. There is no transient table on L2.

### G.3 Consumption

Sequential — `executionIndex++` (or `_transientExecutionIndex++`) per consumption. Each entry is consumed exactly once. There is no swap-and-pop and no hash-based search.

### G.4 Same-Block Restriction

On L1, all execution attempts revert `ExecutionNotInCurrentBlock` if `lastStateUpdateBlock != block.number`. On L2, same with `lastLoadBlock`. Entries that aren't consumed in the loading block are silently dropped on the next load.

### G.5 Table Clearing

Each new `postBatch` / `loadExecutionTable` wipes the entire existing table. Builders must produce self-contained batches.

---

## H. Invariants

### H.1 State Root Consistency (L1)

`rollups[id].stateRoot` is updated only:
- By `_applyStateDeltas` (during `_applyAndExecute`, called from `postBatch`, `executeCrossChainCall`, or `executeL2TX`).
- By `setStateByOwner` (owner escape hatch).

The previous-state binding lives in the proof: `_computeEntryHashes` reads `rollups[id].stateRoot` at proof time and folds it into the entry hash via `prevStates[]`. A stale builder produces an entry hash that doesn't match what the verifier expects.

### H.2 Ether Accounting (L1)

For each entry: `totalEtherDelta == etherIn - etherOut`, where `etherIn` is the `msg.value` received by the entry-point call (or 0 for `executeL2TX` and immediate entries) and `etherOut` is the sum of `value` fields on every **successful** call inside the entry.

Each entry independently balances — ether accounting is localized to a single entry rather than aggregated across the transaction — which simplifies the prover's job.

The sum of `etherBalance` across all rollups plus `address(rollups).balance` is conserved modulo direct deposits/withdrawals outside the protocol.

### H.3 Sequential Consumption

Each entry is consumed exactly once, in posted order. The cursor is monotonically increasing within a table and reset to 0 when the table is wiped.

### H.4 Rolling Hash Integrity

After each entry completes:

```
_rollingHash               == entry.rollingHash             // RollingHashMismatch
_currentCallNumber         == entry.calls.length            // UnconsumedCalls
_lastNestedActionConsumed  == entry.nestedActions.length    // UnconsumedNestedActions
```

Together, these three checks attest that every call described in the entry was processed in the correct order, with the correct return data, with the correct nesting structure, and that nothing extra happened.

### H.5 Proxy Determinism

Address of `CrossChainProxy(originalAddress, originalRollupId)` is fully determined by:
- The manager contract (`address(this)` at deployment time)
- Salt: `keccak256(abi.encodePacked(originalRollupId, originalAddress))`
- `CrossChainProxy` creation code + constructor args

The same pair always maps to the same proxy address on the same manager. Two proxies for the same pair cannot exist (CREATE2 collision would revert).

### H.6 Same-Block Execution

All entries posted in a given block must be consumed in that block — `lastStateUpdateBlock == block.number` (L1) or `lastLoadBlock == block.number` (L2).

### H.7 Table Cleared Per Block

`postBatch` and `loadExecutionTable` each `delete` the entire existing table before loading new entries. Unconsumed entries from a prior block are silently dropped.

### H.8 Transient Table Drain Gating

The deferred remainder of a `postBatch` is published to persistent storage **only** if the immediate entry plus the meta hook drained the transient execution table completely. Partial consumption drops both deferred entries and deferred static calls — the ZK proof committed to the batch as an ordered group, and a partial prefix can't be soundly extended.

---

## I. Security Considerations

### I.1 ZK Proof Verification

`postBatch` verifies a ZK proof covering:
- Every entry hash (which embeds `stateDeltas`, `vks`, `prevStates`, `actionHash`, `rollingHash`).
- Every blob hash (for data availability).
- The previous block's `blockhash`.
- `block.timestamp`.
- `keccak256(callData)`.

A malicious caller producing a forged batch would have to forge the proof for the current rollup state — impossible without breaking the underlying ZK system.

The `prevStates[]` field inside the entry hash binds each entry to the rollup state at the time the proof was generated. If the chain advances between proof generation and `postBatch`, the public-inputs hash differs and verification fails.

### I.2 Reentrancy

The protocol is intentionally reentrant. `_processNCalls` calls into proxies, which forward to destination contracts, which may call back into proxies. Reentrant calls are routed to `_consumeNestedAction` via the `_insideExecution()` check. The transient `_currentCallNumber` cursor naturally serializes everything within one entry.

The same-block guard (`lastStateUpdateBlock == block.number`) plus the immediate `lastStateUpdateBlock = block.number` write inside `postBatch` prevents recursive `postBatch` calls — the outer guard would catch a nested call from an untrusted hook.

### I.3 Untrusted Meta Hook

`postBatch` invokes `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` if `msg.sender` has code. The hook is untrusted — it may revert, consume some entries, ignore the call, or attempt to re-enter `postBatch`. The protocol's defense:

- **Re-entry**: blocked by the `lastStateUpdateBlock == block.number` guard, which is set before the hook runs.
- **Partial consumption**: the deferred remainder is dropped (no publish to persistent storage).
- **Hook revert**: the entire `postBatch` reverts (atomicity), which rolls back the block-marker write, the transient writes, and the immediate entry. The next caller can re-attempt cleanly.

### I.4 Access Control Summary

| Function | Who can call |
|---|---|
| `createRollup` | Anyone |
| `postBatch` | Anyone (proof verifies authorization) |
| `executeCrossChainCall` (L1 / L2) | Registered proxies only |
| `executeL2TX` (L1) | Anyone (must not be inside execution) |
| `staticCallLookup` (L1 / L2) | Registered proxies only (called via STATICCALL by the proxy) |
| `executeInContext` (L1 / L2) | Self-call only (`address(this)`) |
| `createCrossChainProxy` (L1 / L2) | Anyone |
| `setStateByOwner` (L1) | Rollup owner |
| `setVerificationKey` (L1) | Rollup owner |
| `transferRollupOwnership` (L1) | Rollup owner |
| `loadExecutionTable` (L2) | `SYSTEM_ADDRESS` |

### I.5 `StateAlreadyUpdatedThisBlock` Guard

Only one `postBatch` can succeed per block on L1. The guard is the single point of synchronization: builders must coordinate to ensure exactly one batch per block.

### I.6 Cross-Chain Proxy Identity

A `CrossChainProxy` represents exactly one `(originalAddress, originalRollupId)` pair. When the manager calls a destination via `CrossChainProxy.executeOnBehalf`, the destination sees `msg.sender = proxy address` (deterministic from the pair). The cross-chain identity is encoded by the pair, not by `msg.sender` alone — two proxies on different managers for the same pair have the same address only if the managers themselves match.

### I.7 Static Context Detection

The `tstore` / `tload` asymmetry is the basis for STATICCALL detection: `tstore` reverts in static context, `tload` does not. The proxy's `_fallback` self-calls `staticCheck()` (which attempts `tstore`); if the self-call reverts, the proxy is in static context and routes to `staticCallLookup`. This works because:
- A self-call to `staticCheck` from within a STATICCALL is itself a STATICCALL (the proxy can't escalate privileges).
- The `tstore` inside `staticCheck` is the only thing that can fail; everything else (the call itself, the `_fallback` machinery) is read-only.

A misbehaving destination contract that suppresses the static context would still hit `staticCallLookup` via this detector — there is no way to fake a non-static context from inside a STATICCALL.

### I.8 Sequential Index — No Out-of-Order Consumption

Because `_consumeAndExecute` increments the cursor by exactly one and verifies `entry.actionHash == expectedHash`, a builder error or a hook error that triggers an unexpected call reverts immediately and cleanly. The cursor only advances on a hash-matching consumption — never on a mismatch — so the table state remains coherent across reverts within a single `postBatch`.

### I.9 Rolling Hash as Integrity Backbone

The single `_rollingHash == entry.rollingHash` check is the primary integrity guarantee. Because the hash chains every `(success, retData)` pair plus every `NESTED_BEGIN` / `NESTED_END` boundary with unique tags, a single mismatch anywhere — wrong return data, wrong nesting, missing call, extra call, reordered operations — produces a different final hash and is caught at the entry boundary.

No path exists where execution diverges from the proof and still completes successfully — every divergence (return data, nesting, ordering, count) lands in the rolling hash and is rejected at the entry boundary.

---

*End of specification. This document covers the flat sequential execution model. For migration notes from the legacy scope-tree / `ActionType` model, see `CHANGES_FROM_PREVIOUS.md`.*
