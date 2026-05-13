# Sync-Rollups Protocol Specification

**Source**: `src/`
**Purpose**: Formal reference for implementing the Rust rollup node. Supersedes informal comments in source code.

This document covers the **flat sequential execution model** layered with the **multi-prover / per-rollup-queue** model from the `feature/flatten` refactor. Every cross-chain entry is a flat list of `L2ToL1Call`s processed sequentially, with reentrant calls resolved via a parallel `ExpectedL1ToL2Call[]` table and integrity verified by a single `rollingHash` per entry. Entries are routed by `destinationRollupId` into per-rollup queues. `postAndVerifyBatch` carries a single `ProofSystemBatchPerVerificationEntries` whose proofs verify atomically.

For the multi-prover design (batch shape, per-PS public-inputs construction, threshold semantics, `crossProofSystemInteractions`), see `MULTI_PROVER_DESIGN.md`.

---

## Table of Contents

- [A. Data Model](#a-data-model)
- [B. Core Protocol Functions](#b-core-protocol-functions)
- [C. Action Hash Computation](#c-action-hash-computation)
- [D. Execution Model](#d-execution-model)
- [E. Rolling Hash](#e-rolling-hash)
- [F. Lookup Call Resolution](#f-lookup-call-resolution)
- [G. Execution Entry Lifecycle](#g-execution-entry-lifecycle)
- [H. Invariants](#h-invariants)
- [I. Security Considerations](#i-security-considerations)

---

## A. Data Model

### A.1 Core Structs

#### Action hash (off-chain helper)

Tooling computes `crossChainCallHash` from six fields (`targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId`). The on-chain interface (`IEEZ.sol`) does **not** declare an `Action` struct — contracts call the `public pure` helper `computeCrossChainCallHash(...)` directly with the six fields. A compatibility `Action` struct exists in `script/e2e/shared/E2EHelpers.sol` for tooling that prefers a single-arg `keccak256(abi.encode(action))` form; both routes produce the same preimage.

#### StateDelta

Describes one rollup's state transition caused by executing one entry. The pre-state binding lives on the entry: `currentState` is checked at consumption time against `rollups[delta.rollupId].stateRoot`; mismatch reverts `StateRootMismatch`. This makes entries content-addressed against the trajectory the proof committed to and is the soundness backstop that lets the per-rollup queue model interleave consumption across rollups safely.

```solidity
struct StateDelta {
    uint256 rollupId;       // which rollup's state changes
    bytes32 currentState;   // expected pre-state root on rollupId — checked against rollups[rid].stateRoot
    bytes32 newState;       // post-execution state root
    int256  etherDelta;     // signed change in rollup's ETH balance
}
```

#### L2ToL1Call

A single call in the entry's flat `L2ToL1Calls[]` array.

```solidity
struct L2ToL1Call {
    address targetAddress;
    uint256 value;
    bytes   data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;   // 0 = normal call; N>0 = force-revert state effects of next N calls (this one inclusive); see §D.4.1
}
```

#### ExpectedL1ToL2Call

Pre-computed result for a **successful** reentrant cross-chain call.

```solidity
struct ExpectedL1ToL2Call {
    bytes32 crossChainCallHash;   // hash of the reentrant call (must equal computeCrossChainCallHash at consumption)
    uint256 callCount;    // iterations from entry.L2ToL1Calls[] consumed inside this nested action
    bytes   returnData;   // the value returned to the destination contract
}
```

Reverting reentrant calls cannot be expressed as `ExpectedL1ToL2Call` — they must use `LookupCall` with `failed = true`.

#### ExecutionEntry

The central execution unit. Loaded by `postAndVerifyBatch` (L1) or `loadExecutionTable` (L2).

```solidity
struct ExecutionEntry {
    StateDelta[]           stateDeltas;          // L1 only — state root deltas; on L2 typically empty
    bytes32                proxyEntryHash;       // bytes32(0) = immediate, otherwise the trigger action hash
    uint256                destinationRollupId;  // rollup whose queue this entry routes to (per-rollup queue model)
    L2ToL1Call[]           L2ToL1Calls;          // flat array of all calls in execution order
    ExpectedL1ToL2Call[]   expectedL1ToL2Calls;  // sequentially consumed by reentrant calls
    uint256                callCount;            // number of entry-level iterations to process
    bytes                  returnData;           // pre-computed return data for the entry's top-level call
    bytes32                rollingHash;          // expected hash after all calls and nestings complete
}
```

Top-level entries always succeed: `executeCrossChainCall` returns `entry.returnData`. Reverting cross-chain results at the top level are expressed via `LookupCall { failed: true }`, consumed via `staticCallLookup` (static context) or via the failed-reentry fallback in `_consumeNestedAction`. There is no `entry.failed` flag.

#### LookupCall

Pre-computed result for a static (read-only) call or for a reverting reentrant / top-level call.

```solidity
struct LookupCall {
    bytes32      crossChainCallHash;
    uint256      destinationRollupId;       // rollup whose lookupQueue this entry routes to
    bytes        returnData;
    bool         failed;                     // true → lookup reverts with returnData
    uint64       callNumber;                 // _currentCallNumber at lookup time
    uint64       lastNestedActionConsumed;   // _lastNestedActionConsumed at lookup time
    L2ToL1Call[] calls;                      // optional sub-calls executed in static context
    bytes32      rollingHash;                // expected hash of those sub-calls (verified)
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
    address rollupContract;   // per-rollup IRollupContract-conforming manager (owner / vkey / threshold live there); immutable after registration
    bytes32 stateRoot;        // current committed state root
    uint256 etherBalance;     // ETH held on behalf of this rollup
}
```

The central registry no longer holds owner or vkey — those live on each rollup's `rollupContract` (reference impl: `src/rollupContract/Rollup.sol`). See `MULTI_PROVER_DESIGN.md` for the per-rollup-manager model.

#### RollupVerification (L1 only)

Per-rollup queue, lookup queue, cursor, and verified-this-block marker — replaces the legacy global `executions[]` / `executionIndex` / `lastStateUpdateBlock`.

```solidity
struct RollupVerification {
    uint256          lastVerifiedBlock;   // doubles as once-per-block invariant + read gate + lazy-reset signal
    ExecutionEntry[] queue;               // per-rollup deferred entries
    LookupCall[]     lookupQueue;         // per-rollup deferred lookup calls
    uint256          cursor;              // monotonic per-rollup consumption cursor
}
```

### A.2 Storage Layout

#### EEZ.sol (L1) — inherits `EEZBase`

| Variable | Type | Notes |
|----------|------|-------|
| `rollupCounter` | uint256 | Next rollup ID |
| `rollups` | mapping(uint256 ⇒ RollupConfig) | Per-rollup config (manager pointer + state root + ether) |
| `verificationByRollup` | internal mapping(uint256 ⇒ RollupVerification) | Per-rollup deferred queues + cursor (public views: `lastVerifiedBlock(rid)`, `queueLength(rid)`, `queueCursor(rid)`) |
| `_transientExecutions` | ExecutionEntry[] (public) | Transient-backed entries (cleared each `postAndVerifyBatch`); also doubles as the reentry guard via `length != 0` |
| `_transientLookupCalls` | LookupCall[] (public) | Transient-backed lookup calls |
| `_transientExecutionIndex` | `uint256 transient` | Global cursor into `_transientExecutions` (cross-rollup, intra-`postAndVerifyBatch`) |
| `_currentEntryRollupId` | `uint256 transient` | RollupId of the active entry (so `_consumeNestedAction` finds the right queue); `0` while running a transient entry |

Inherited from `EEZBase`:

| Variable | Type | Notes |
|----------|------|-------|
| `authorizedProxies` | mapping(address ⇒ ProxyInfo) | Registered proxies |
| `_rollingHash` | `bytes32 transient` | Rolling hash accumulator |
| `_currentEntryIndex` | `uint256 transient` | Active entry index for nested-action consumption |
| `_currentCallNumber` | `uint256 transient` | 1-indexed global call counter; doubles as `_insideExecution` flag (`!= 0`) |
| `_lastNestedActionConsumed` | `uint256 transient` | Sequential nested-action cursor |

`MAINNET_ROLLUP_ID = 0` is a constant. The four rolling-hash tag constants `CALL_BEGIN=1, CALL_END=2, NESTED_BEGIN=3, NESTED_END=4` are internal constants on `EEZBase`. There is no `_inPostBatch` flag — reentry is detected via `_transientExecutions.length != 0` instead.

`_transientExecutions` and `_transientLookupCalls` are declared as regular storage arrays (not Solidity `transient`) because the `transient` data location does not yet support reference types with nested dynamic arrays. They are cleared at the end of every `postAndVerifyBatch` via `delete`, recovering most of the gas cost via SSTORE-to-zero refunds.

#### EEZL2.sol (L2) — inherits `EEZBase`

L2-specific storage:

| Variable | Type | Notes |
|----------|------|-------|
| `executions` | ExecutionEntry[] | Persistent entries (single rollup — no per-rollup map needed) |
| `lookupCalls` | LookupCall[] | Persistent lookup calls |
| `lastLoadBlock` | uint256 | Block of last `loadExecutionTable` / `executeIncomingCrossChainCall` |
| `executionIndex` | uint256 | Cursor into `executions` |

The shared rolling-hash transient fields, proxy registry, and base-event/error set are inherited from `EEZBase`.

`ROLLUP_ID` and `SYSTEM_ADDRESS` are immutables.

### A.3 Transient Variables and `_insideExecution`

`_insideExecution()` is `_currentCallNumber != 0`. The first call processed inside an entry sets `_currentCallNumber` to 1 (and increments from there); the entry-completion path resets `_currentCallNumber = 0` so a subsequent top-level entry starts cleanly.

The transient variables are read by `executeCrossChainCall` (to route to `_consumeAndExecute` vs `_consumeNestedAction`) and by `staticCallLookup` (to compute the disambiguation key). They are reset implicitly between transactions by EIP-1153.

---

## B. Core Protocol Functions

### B.1 EEZ.sol (L1)

#### `registerRollup`

```solidity
function registerRollup(address rollupContract, bytes32 initialState)
    external returns (uint256 rollupId)
```

Permissionless. `rollupId = rollupCounter++`; `rollups[rollupId] = RollupConfig(rollupContract, initialState, 0)`. Fires `IRollupContract(rollupContract).rollupContractRegistered(rollupId)` so the manager learns its id (one-shot init callback). The caller is expected to deploy their `IRollupContract`-conforming manager (with desired proofSystems / vkeys / threshold / ownership baked in) before calling `registerRollup`.

Emits `RollupCreated(rollupId, rollupContract, initialState)`.

#### `postAndVerifyBatch`

```solidity
function postAndVerifyBatch(ProofSystemBatchPerVerificationEntries calldata batch) external
```

Permissionless. A single `ProofSystemBatchPerVerificationEntries` struct (NOT an array) carries `entries[]`, `l1ToL2lookupCalls[]`, `transientExecutionEntryCount`, `transientLookupCallCount`, `proofSystems[]` (sorted asc), `rollupIdsWithProofSystems[]` (strictly ascending by `rollupId`; each row pairs the rollupId with a strictly-ascending `proofSystemIndex[]` of indices into `proofSystems[]`), `crossProofSystemInteractions`, `blobIndices[]`, `callData`, and `proofs[]` (one per PS). See `MULTI_PROVER_DESIGN.md` for the multi-prover model — struct shape, per-PS public-inputs construction, and threshold enforcement.

**Preconditions** (enforced by `_validateStructure`):
- `_transientExecutions.length == 0` else `PostBatchReentry` (reentry guard).
- `proofSystems[]` sorted ascending, no duplicates, no zero address.
- `rollupIdsWithProofSystems[]` strictly ascending by `rollupId`, each `rollupId > MAINNET_ROLLUP_ID`, each registered.
- Each row's `proofSystemIndex[]` strictly ascending, all entries in range `[0, proofSystems.length)`.
- `transientExecutionEntryCount <= entries.length` else `TransientCountExceedsEntries`.
- `transientLookupCallCount <= l1ToL2lookupCalls.length` else `TransientLookupCallCountExceedsLookupCalls`.
- Each entry's `destinationRollupId` (and each lookup call's) is contained in the batch's rollup set else `RollupNotInBatch(rid)`.

**Per-PS public-inputs construction** (two-stage; see `MULTI_PROVER_DESIGN.md` for details):

```
sharedPublicInput = keccak256(abi.encodePacked(
    abi.encode(entryHashes),
    abi.encode(lookupCallHashes),
    abi.encode(blobHashes),
    keccak256(callData),
    crossProofSystemInteractions
))

for each PS k in proofSystems:
  acc_k = bytes32(0)
  for each rollup r where k ∈ rollupIdsWithProofSystems[r].proofSystemIndex:
    acc_k = keccak256(abi.encode(acc_k, rollupId_r, vkMatrix[r][j], blockHash_r, timestamp_r))
  publicInputsHash[k] = keccak256(abi.encodePacked(sharedPublicInput, acc_k))

entryHashes[i]      = keccak256(abi.encode(batch.entries[i]))
lookupCallHashes[i] = keccak256(abi.encode(batch.l1ToL2lookupCalls[i]))
```

`(blockHash_r, timestamp_r)` are fetched per-rollup via `IRollupContract(rollupContract).getTimestampAndBlockHash()`. `prevBlockhash` and `ts` are NOT in `sharedPublicInput` — each rollup folds its own values into the per-PS accumulator.

Each PS's `verify(proofs[k], publicInputsHash[k])` must return `true`. All proofs verify atomically — any failure reverts the whole call.

**State transitions** (in order, 8 steps; see `src/EEZ.sol:306-395`):

1. **Reentry check**: `if (_transientExecutions.length != 0) revert PostBatchReentry()`. There is no separate `_inPostBatch` flag.
2. **Structural validation** (`_validateStructure(batch)`, no external calls).
3. **Fetch + verify**: `_fetchVkMatrix(batch)` calls each rollup's manager via `IRollupContract.checkProofSystemsAndGetVkeys(subset)` (manager enforces threshold internally — reverts if not met) and returns one vkey per PS in the rollup's subset. Then `_verifyProofSystemBatch(batch, vkMatrix)` computes the public inputs and calls `IProofSystem.verify(...)` for each PS.
4. **Mark verified-this-block** (`_markVerifiedThisBlock(rid)` for each rollup): sets `verificationByRollup[rid].lastVerifiedBlock = block.number` AND **lazy-resets the queue on first touch this block** (subsequent same-block touches append). Done before any non-view external CALL so (a) `executeCrossChainCall` / `executeL2TX(rid)` work during the meta hook, and (b) `setStateRoot` is locked out until the next block.
5. **Load transient stream** (`_loadTransient(batch)`): copy `entries[0..transientExecutionEntryCount)` into `_transientExecutions` and `l1ToL2lookupCalls[0..transientLookupCallCount)` into `_transientLookupCalls`.
6. **Drain leading immediate entries inline**: while the next transient entry has `proxyEntryHash == 0`, self-call `try this.attemptApplyImmediate(idx) catch { emit ImmediateEntrySkipped(idx, revertData); }` and advance — not a hard error.
7. **Meta hook**: if `_transientExecutionIndex < _transientExecutions.length` AND `msg.sender.code.length > 0`, call `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()`. The hook may invoke `executeCrossChainCall` and `executeL2TX(rid)` to consume the rest of the transient stream.
8. **Cleanup transient tables**: `delete _transientExecutions; delete _transientLookupCalls; _transientExecutionIndex = 0`. Then `_publishRemainder(batch)` — pushes `entries[transientExecutionEntryCount..]` into `verificationByRollup[entry.destinationRollupId].queue` and `l1ToL2lookupCalls[transientLookupCallCount..]` into the matching `lookupQueue` **only if the transient prefix fully drained**. Finally, `emit BatchPosted(batch.rollupIdsWithProofSystems.length)`. Soundness backstop: each entry's `StateDelta.currentState` is checked at consumption time, so dropped transient leftover doesn't poison persistent consumers.

**Revert conditions**: `PostBatchReentry`, `TransientCountExceedsEntries`, `TransientLookupCallCountExceedsLookupCalls`, `RollupNotInBatch(rid)`, `InvalidProofSystemConfig`, `DuplicateProofSystem`, threshold/vkey reverts from the manager, `InvalidProof`, plus whatever the immediate entry / meta hook revert with (`RollingHashMismatch`, `EtherDeltaMismatch`, `InsufficientRollupBalance`, `UnconsumedCalls`, `UnconsumedNestedActions`, `ExecutionNotFound`, `StateRootMismatch(rid)`, …).

Note: same-block re-touch of a rollup is **permitted** — `_markVerifiedThisBlock` short-circuits silently on a same-block re-touch and entries from the second batch append to the existing queue. Orchestrators that need once-per-block-per-rollup exclusivity must coordinate at the social layer.

#### `executeCrossChainCall`

```solidity
function executeCrossChainCall(address sourceAddress, bytes calldata callData)
    external payable returns (bytes memory result)
```

**Access control**: caller must be a registered proxy (`authorizedProxies[msg.sender].originalAddress != address(0)`); else `UnauthorizedProxy`.

**Preconditions**: `verificationByRollup[proxyInfo.originalRollupId].lastVerifiedBlock == block.number` else `ExecutionNotInCurrentBlock(rollupId)`.

**Logic**:

```solidity
ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
uint256 rollupId = proxyInfo.originalRollupId;
bytes32 crossChainCallHash = computeCrossChainCallHash(
    rollupId,                     // targetRollupId
    proxyInfo.originalAddress,    // targetAddress
    msg.value,                    // value
    callData,                     // data
    sourceAddress,                // sourceAddress
    MAINNET_ROLLUP_ID             // sourceRollupId (L1 = 0)
);
emit CrossChainCallExecuted(crossChainCallHash, msg.sender, sourceAddress, callData, msg.value);

if (_insideExecution()) {
    return _consumeNestedAction(crossChainCallHash);
}
return _consumeAndExecute(rollupId, crossChainCallHash, int256(msg.value));
```

`_consumeAndExecute` routes to the rollup's queue (`verificationByRollup[rollupId]`) — transient stream first if inside `postAndVerifyBatch`, otherwise the persistent per-rollup queue. On a miss (cursor out-of-bounds or `proxyEntryHash` mismatch), it falls back to `_tryRevertedTopLevelLookup(crossChainCallHash, destRid)` (`src/EEZ.sol:1043`) which scans the transient lookup table then the per-rollup `lookupQueue` for a `failed && callNumber == 0 && lastNestedActionConsumed == 0` match and reverts with the cached `returnData`; only if that also misses does it revert `ExecutionNotFound`.

**Revert conditions**: `UnauthorizedProxy`, `ExecutionNotInCurrentBlock(rollupId)`, `ExecutionNotFound`, `RollingHashMismatch`, `UnconsumedCalls`, `UnconsumedNestedActions`, `EtherDeltaMismatch`, `InsufficientRollupBalance`, `StateRootMismatch(rollupId)`, plus any revert from the destination call (which is captured into `_rollingHash` via `CALL_END`).

#### `executeL2TX`

```solidity
function executeL2TX(uint256 rollupId) external returns (bytes memory result)
```

Permissionless. Consumes the next entry on `rollupId`'s queue, which **must** have `proxyEntryHash == bytes32(0)`. Cannot run during an active execution.

```solidity
if (verificationByRollup[rollupId].lastVerifiedBlock != block.number) revert ExecutionNotInCurrentBlock(rollupId);
if (_insideExecution()) revert L2TXNotAllowedDuringExecution();
emit L2TXExecuted(rollupId, verificationByRollup[rollupId].cursor);
return _consumeAndExecute(rollupId, bytes32(0), 0);
```

#### `staticCallLookup`

```solidity
function staticCallLookup(address sourceAddress, bytes calldata callData)
    external view returns (bytes memory)
```

Called via STATICCALL by `CrossChainProxy._fallback` when the proxy detects static context. Caller must be a registered proxy.

```solidity
uint256 rollupId = proxyInfo.originalRollupId;
bytes32 crossChainCallHash = computeCrossChainCallHash(
    rollupId,
    proxyInfo.originalAddress,
    0,                            // value = 0 in static context
    callData,
    sourceAddress,
    MAINNET_ROLLUP_ID
);
uint64 callNum = uint64(_currentCallNumber);
uint64 lastNA  = uint64(_lastNestedActionConsumed);

// Transient-first scan, then per-rollup lookupQueue. First match returns / reverts.
for lc in _transientLookupCalls:
    if lc.crossChainCallHash == crossChainCallHash && lc.destinationRollupId == rollupId
       && lc.callNumber == callNum && lc.lastNestedActionConsumed == lastNA:
        return _resolveLookupCall(lc);
for lc in verificationByRollup[rollupId].lookupQueue:
    if (same match): return _resolveLookupCall(lc);
revert ExecutionNotFound();
```

`_resolveLookupCall(lc)`:
- If `lc.calls.length > 0`: replay them via `_processNLookupCalls(lc.calls)` (each via `sourceProxy.staticcall(executeOnBehalf(...))`), accumulate the rolling hash, and check `computedHash == lc.rollingHash` else `RollingHashMismatch`.
- If `lc.failed`: revert with `lc.returnData` (bubbles back to the proxy and out to the caller).
- Else return `lc.returnData`.

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
                   address(this),    // deployer = the manager (Rollups on L1, EEZL2 on L2)
                   salt,
                   bytecodeHash
               )))))
```

The salt is exactly `(originalRollupId, originalAddress)` — no `domain` or `block.chainid` term is mixed in, so the same `(originalAddress, originalRollupId)` pair derives the same proxy address regardless of which manager / chain computes it. `createCrossChainProxy` and `computeCrossChainProxyAddress` are defined on `EEZBase` and inherited by both `EEZ` and `EEZL2`.

#### Per-rollup ownership / configuration

Per-rollup ownership lives on each rollup's `IRollupContract`-conforming manager (reference impl: `src/rollupContract/Rollup.sol`). The central `EEZ` registry exposes a single manager-callable mutator on the rollup config:

```solidity
function setStateRoot(uint256 rollupId, bytes32 newStateRoot) external  // msg.sender == rollups[rid].rollupContract
```

Subject to two reverts:
- `RollupBatchActiveThisBlock(rid)` if `verificationByRollup[rid].lastVerifiedBlock == block.number` (a batch hit `rid` earlier this block).
- `SetStateRootNotAllowedDuringExecution()` if `_insideExecution()` is true — the manager cannot rewrite state mid-execution via a reentrant proxy path.

`setStateRoot` does **not** update `lastVerifiedBlock` — it's an owner escape, not a batch post.

**No manager-handoff path**: there is no `setRollupContract` and no `RollupContractChanged` event. A rollup's manager binding is set at registration time and is immutable thereafter (see `src/rollupContract/Rollup.sol:144-149`). To "migrate" off a manager, the orchestrator must register a new rollupId pointing at a new manager and migrate state out-of-band.

Per-rollup operations like `addProofSystem` / `removeProofSystem`, `setVerificationKey`, `setThreshold`, `transferOwnership`, and any owner-driven `setStateRoot` initiation live on the manager itself. See `MULTI_PROVER_DESIGN.md` and `src/rollupContract/Rollup.sol`.

#### View accessors

`verificationByRollup` is `internal`. Public accessors:

```solidity
function lastVerifiedBlock(uint256 rid) external view returns (uint256);  // EEZ.sol:1109
function queueLength(uint256 rid) external view returns (uint256);        // EEZ.sol:1115
function queueCursor(uint256 rid) external view returns (uint256);        // EEZ.sol:1120
```

#### Internal helpers

##### `_consumeAndExecute(uint256 rollupId, bytes32 crossChainCallHash, int256 etherIn) → bytes`

```
if (_transientExecutions.length != 0):
    idx = _transientExecutionIndex++
    if (idx >= _transientExecutions.length): revert ExecutionNotFound
    entry = _transientExecutions[idx]
else:
    cursor = verificationByRollup[rollupId].cursor
    if (cursor >= verificationByRollup[rollupId].queue.length): revert ExecutionNotFound
    entry = verificationByRollup[rollupId].queue[cursor]
    verificationByRollup[rollupId].cursor = cursor + 1
    idx = cursor

if (entry.proxyEntryHash != crossChainCallHash): revert ExecutionNotFound
if (entry.destinationRollupId != rollupId): revert ExecutionNotFound
emit ExecutionConsumed(crossChainCallHash, rollupId, idx)

_currentEntryIndex = idx
_currentEntryRollupId = rollupId
_applyAndExecute(entry.stateDeltas, entry.callCount, entry.rollingHash, etherIn)

return entry.returnData
```

Inside an active `postAndVerifyBatch`, `_transientExecutions.length != 0` routes **all** consumption through the transient stream — running off the end falls back to `_tryRevertedTopLevelLookup` (top-level reverted-lookup scan), then `ExecutionNotFound`. Per-rollup queues are empty until step 8 of `postAndVerifyBatch`. Top-level execution always succeeds; reverting top-level results are expressed via `LookupCall { failed: true }`.

##### `_consumeNestedAction(bytes32 crossChainCallHash) → bytes`

```
entry = _currentEntryStorage()
idx   = _lastNestedActionConsumed++           // speculative bump (rolls back on revert)

// 1. ExpectedL1ToL2Call priority. The bump above is the commit; if we fall through,
//    every fallback path reverts and the EVM rolls the bump back.
if (idx < entry.expectedL1ToL2Calls.length
    && entry.expectedL1ToL2Calls[idx].crossChainCallHash == crossChainCallHash):
    nested        = entry.expectedL1ToL2Calls[idx]
    nestedNumber  = idx + 1
    _rollingHash  = keccak256(abi.encodePacked(_rollingHash, NESTED_BEGIN, nestedNumber))
    _processNCalls(nested.callCount)
    _rollingHash  = keccak256(abi.encodePacked(_rollingHash, NESTED_END, nestedNumber))
    return nested.returnData

// 2. Fallback: failed=true LookupCall keyed by the pre-bump cursor. This handles
//    the try/catch case (a reentrant call the caller expects to revert) — it
//    cannot be expressed as an ExpectedL1ToL2Call because the failure would roll
//    back the consumption-cursor bump and make consumption silent.
//    Lookup key uses `idx` (pre-bump) and the current `_currentCallNumber`.
//    Scan _transientLookupCalls first, then verificationByRollup[rid].lookupQueue.
//    A match calls _resolveLookupCall(lc), which always reverts when lc.failed.

// 3. No match anywhere.
revert ExecutionNotFound
```

The fallback's safety comes from the speculative-bump pattern: the cursor advance at line 2 is the only state change before the routing decision. `ExpectedL1ToL2Call` success persists the bump; every other path (LookupCall fallback hit, no-match) reverts and the EVM rolls the bump back, so the cursor only advances on a clean nested-call consumption.

##### `_tryRevertedTopLevelLookup(bytes32 crossChainCallHash, uint256 destRid)` (L1)

Called by `_consumeAndExecute` on a transient-table miss OR a persistent-queue miss. Scans `_transientLookupCalls` then `verificationByRollup[destRid].lookupQueue` for a match where:

```
lc.crossChainCallHash      == crossChainCallHash
lc.destinationRollupId     == destRid
lc.failed                  == true
lc.callNumber              == 0
lc.lastNestedActionConsumed == 0
```

On match, reverts with `lc.returnData` (no cursor advance). On no match, returns control to `_consumeAndExecute` which reverts `ExecutionNotFound`. The `(0, 0)` lookup key denotes a TOP-LEVEL natural revert — distinct from nested-call lookups whose `(callNumber, lastNestedActionConsumed)` are nonzero.

The L2 variant is `_tryRevertedTopLevelLookup(bytes32 crossChainCallHash)` (no `destRid` — single rollup) and scans only persistent `lookupCalls` (no transient table on L2). See `src/EEZ.sol:1043` and `src/L2/EEZL2.sol`.

`_currentEntryStorage()` returns `_transientExecutions[_currentEntryIndex]` if `_transientExecutions.length != 0`, else `verificationByRollup[_currentEntryRollupId].queue[_currentEntryIndex]`.

##### `_applyAndExecute(StateDelta[] memory deltas, uint256 callCount, bytes32 rollingHash, int256 etherIn)`

```
_rollingHash = bytes32(0)
_currentCallNumber = 0
_lastNestedActionConsumed = 0

etherOut          = _processNCalls(callCount)
totalEtherDelta   = _applyStateDeltas(deltas)

entry = _currentEntryStorage()
require(_rollingHash == rollingHash)                                         // RollingHashMismatch
require(_currentCallNumber == entry.L2ToL1Calls.length)                      // UnconsumedCalls
require(_lastNestedActionConsumed == entry.expectedL1ToL2Calls.length)       // UnconsumedNestedActions
require(totalEtherDelta == etherIn - etherOut)                               // EtherDeltaMismatch

emit EntryExecuted(_currentEntryIndex, _rollingHash, _currentCallNumber, _lastNestedActionConsumed)
_currentCallNumber = 0   // reset so _insideExecution() returns false again
```

##### `_processNCalls(uint256 count) → int256 etherOut`

Iterates `count` entry-level steps from `entry.L2ToL1Calls[_currentCallNumber]`. For each step:

- If `revertSpan == 0`: load the call, increment `_currentCallNumber`, hash `CALL_BEGIN`, derive `sourceProxy` (auto-create if missing), call `CrossChainProxy.executeOnBehalf` through it, hash `CALL_END(success, retData)`, emit `CallResult`. Add `cc.value` to `etherOut` only if `success && cc.value > 0`. Increment `processed` by 1.
- If `revertSpan > 0`: clear the field in storage, save `_currentCallNumber`, `try this.executeInContextAndRevert(revertSpan)`. Always reverts with `ContextResult`; decode and restore `_rollingHash`, `_lastNestedActionConsumed`, `_currentCallNumber` from the payload. Restore `entry.L2ToL1Calls[savedCallNumber].revertSpan = revertSpan`. Emit `RevertSpanExecuted`. Increment `processed` by `revertSpan`.

The same global cursor `_currentCallNumber` is advanced both by entry-level iterations and by nested-action iterations — `_processNCalls` is reused recursively from `_consumeNestedAction`.

##### `executeInContextAndRevert(uint256 callCount) external`

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
- `if (rollups[delta.rollupId].stateRoot != delta.currentState) revert StateRootMismatch(delta.rollupId)` — the per-rollup-queue soundness backstop.
- `rollups[delta.rollupId].stateRoot = delta.newState`.
- Accumulate `delta.etherDelta` into `totalEtherDelta`.
- If `delta.etherDelta < 0`: `etherBalance -= |delta|` (revert `InsufficientRollupBalance` on underflow).
- If `delta.etherDelta > 0`: `etherBalance += delta`.
- Emit `L2ExecutionPerformed(rollupId, newState)`.

##### `_processNLookupCalls(L2ToL1Call[] memory calls) → bytes32`

```
hash = bytes32(0)
for cc in calls:
    sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId)
    (success, retData) = sourceProxy.staticcall(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)))
    hash = keccak256(abi.encodePacked(hash, success, retData))
return hash
```

No `revertSpan` handling — every call executes as-is. Static context cannot deploy proxies, so all referenced proxies must already exist.

This hashing scheme is **intentionally untagged** and is **distinct from** the entry-level rolling hash described in §E (no `CALL_BEGIN`/`CALL_END`/`NESTED_BEGIN`/`NESTED_END` tags, no `callNumber`). It is verified against `LookupCall.rollingHash`, a separate per-`LookupCall` accumulator whose context (entry, position, nesting depth) is already pinned by the lookup key `(crossChainCallHash, destinationRollupId, callNumber, lastNestedActionConsumed)`. See §E.2 for the full rationale.

##### `computeCrossChainCallHash` (`public pure`)

```solidity
function computeCrossChainCallHash(
    uint256 targetRollupId,
    address targetAddress,
    uint256 value,
    bytes calldata data,
    address sourceAddress,
    uint256 sourceRollupId
) public pure returns (bytes32) {
    return keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId));
}
```

Tooling can match this preimage by `keccak256(abi.encode(action))` over a six-field `Action` shim (kept in `script/e2e/shared/E2EHelpers.sol`).

##### `entryHashes` for the public-inputs preimage

Each entry's contribution is `keccak256(abi.encode(entry))` — the FULL `ExecutionEntry` struct, including `stateDeltas` (which carry the entry's `currentState` precondition), `proxyEntryHash`, `destinationRollupId`, `L2ToL1Calls`, `expectedL1ToL2Calls`, `callCount`, `returnData`, and `rollingHash`. Same for lookup calls (`keccak256(abi.encode(lookupCall))`). See `MULTI_PROVER_DESIGN.md` for the full per-PS public-inputs construction.

##### `_verifyProof(IProofSystem ps, bytes calldata proof, bytes32 publicInputsHash)`

```solidity
if (!ps.verify(proof, publicInputsHash)) revert InvalidProof();
```

Each `IProofSystem` is supplied per batch via `proofSystems[]`; there is no central `ZK_VERIFIER` immutable.

### B.2 EEZL2.sol (L2)

The L2 contract inherits `EEZBase` and mirrors the L1 contract's execution logic but with no rollup registry, no state deltas, no proofs, no per-rollup queue map (single rollup), and no transient/deferred split.

#### `loadExecutionTable`

```solidity
function loadExecutionTable(ExecutionEntry[] calldata entries, LookupCall[] calldata _lookupCalls)
    external onlySystemAddress
```

```
delete executions
delete lookupCalls
executionIndex = 0
for e in entries: executions.push(e)
for l in _lookupCalls: lookupCalls.push(l)
lastLoadBlock = block.number
emit ExecutionTableLoaded(entries)
```

`onlySystemAddress` reverts `Unauthorized` for any other caller. `entry.destinationRollupId` is set by tooling for parity with L1 but is not read by on-chain execution paths (L2 has a single rollup).

#### `executeIncomingCrossChainCall` (L2 inbound delivery, NEW)

```solidity
function executeIncomingCrossChainCall(
    address destination,
    uint256 value,
    bytes calldata data,
    address sourceAddress,
    uint256 sourceRollup,
    ExecutionEntry[] calldata entries,
    LookupCall[] calldata _lookupCalls
) external payable onlySystemAddress returns (bytes memory)
```

System-only top-level delivery path for an inbound cross-chain call from another rollup (`src/L2/EEZL2.sol:161-211`). Behavior:

1. Revert `EmptyEntries` if `entries.length == 0`.
2. Revert `ValueMismatch` if `msg.value != value` (strict equality — the system mints exactly the call's `value`).
3. `_loadExecutionTable(entries, _lookupCalls)` — atomically replaces the execution table.
4. `crossChainCallHash = computeCrossChainCallHash(ROLLUP_ID, destination, value, data, sourceAddress, sourceRollup)`.
5. Drive `executions[0]` through `_processNCalls(executions[0].callCount)` (entries[0] is the inbound call). The system's `msg.value` lives in the manager and is drained as `_processNCalls` forwards through the source proxy.
6. Standard post-checks: rolling-hash, unconsumed calls, unconsumed nested actions (same invariants as `_consumeAndExecute`).
7. Emit `IncomingCrossChainCallExecuted(crossChainCallHash, destination, value, data, sourceAddress, sourceRollup)`.
8. Return `executions[0].returnData`.

#### `executeCrossChainCall` (L2 variant)

Same as L1, with two differences:

1. **`sourceRollupId`** in the action hash is `ROLLUP_ID` (this L2's ID), not `MAINNET_ROLLUP_ID`.
2. **ETH burn**: if `msg.value > 0`, the L2 manager forwards it to `SYSTEM_ADDRESS` immediately. Failure of the transfer reverts `EtherTransferFailed`.

L2's `_consumeAndExecute` reads from `executions` only — there is no transient table and no per-rollup queue map. On a miss (cursor out-of-bounds or `proxyEntryHash` mismatch), it falls back to `_tryRevertedTopLevelLookup(crossChainCallHash)` (no `destRid` arg — single rollup), which scans `lookupCalls` for `failed && callNumber == 0 && lastNestedActionConsumed == 0` and reverts with the cached `returnData`. Only if that also misses does it revert `ExecutionNotFound`.

#### Top-level call delivery on L2

Top-level calls on L2 arrive via two paths:

1. **User txs hitting proxies** → `executeCrossChainCall`.
2. **`SYSTEM_ADDRESS` → `executeIncomingCrossChainCall`** for inbound cross-chain calls from another rollup.

There is no `executeL2TX` on L2 — that mechanism lives on L1 and handles the L1-side commit of L2 user actions.

#### `staticCallLookup` (L2)

Same as L1, but only scans `lookupCalls` (no transient table). `sourceRollupId` in the action hash is `ROLLUP_ID`. The lookup match key drops `destinationRollupId` (single rollup) — match is keyed on `(crossChainCallHash, callNumber, lastNestedActionConsumed)` only. The same applies to the failed-reentry fallback in `_consumeNestedAction` and to `_tryRevertedTopLevelLookup`.

#### `createCrossChainProxy` / `computeCrossChainProxyAddress`

Inherited from `EEZBase`. Identical formula on both L1 and L2.

### B.3 CrossChainProxy.sol

```solidity
constructor(address _eez, address _originalAddress, uint256 _originalRollupId)
```

Three immutables: `EEZ`, `ORIGINAL_ADDRESS`, `ORIGINAL_ROLLUP_ID` (`src/base/CrossChainProxy.sol:14-33`). The `EEZ` immutable holds the manager address (L1 `EEZ` or L2 `EEZL2`); the proxy is constructed by `EEZBase.createCrossChainProxy`.

#### `executeOnBehalf(address destination, bytes calldata data) external payable`

If `msg.sender == EEZ`: call `destination.call{value: msg.value}(data)` and return/revert raw bytes via assembly.

Else: route through `_fallback()` — the transparent-proxy pattern: the manager admin (when the manager itself calls `executeOnBehalf`) gets direct forwarding; any other caller hitting `executeOnBehalf` enters the cross-chain path.

#### `staticCheck() external`

Self-only function used to detect STATICCALL context. If `msg.sender == address(this)`: attempt `_staticDetector = 0` (a `tstore`). In static context this reverts; in normal context it succeeds. Else: route through `_fallback()`.

#### `fallback() external payable` and `_fallback()` internal

```
(detectSuccess, _) = address(this).call(abi.encodeCall(staticCheck, ()))
if (!detectSuccess):
    // STATICCALL context — look up cached result
    (success, result) = MANAGER.staticcall(abi.encodeCall(IEEZ.staticCallLookup, (msg.sender, msg.data)))
else:
    // Normal context — execute cross-chain call
    (success, result) = MANAGER.call{value: msg.value}(abi.encodeCall(IEEZ.executeCrossChainCall, (msg.sender, msg.data)))

if (success):
    result = abi.decode(result, (bytes))    // unwrap the inner bytes returned by IEEZ.*
// assembly return/revert raw result
```

The `abi.decode(result, (bytes))` unwrap is required because `executeCrossChainCall` and `staticCallLookup` both return `bytes memory`, and the low-level `.call() / .staticcall()` ABI-encodes that return value. The proxy strips one layer so the caller sees the destination's raw return data (matching the behavior the destination saw via `executeOnBehalf`'s assembly return).

---

## C. Action Hash Computation

Every action hash is:

```solidity
crossChainCallHash = keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId))
```

There is exactly one formula for all entry points and all reentrant calls. On-chain code calls the `public pure` helper `computeCrossChainCallHash(...)` directly with six fields. Off-chain tooling can use the compatibility `Action` shim in `script/e2e/shared/E2EHelpers.sol` to compute the same preimage from a single struct.

### C.1 Hash from `executeCrossChainCall` (L1)

| Field | Value |
|---|---|
| `targetRollupId` | `proxyInfo.originalRollupId` |
| `targetAddress` | `proxyInfo.originalAddress` |
| `value` | `msg.value` |
| `data` | `callData` (forwarded by the proxy as `msg.data`) |
| `sourceAddress` | `sourceAddress` (msg.sender of the original proxy call) |
| `sourceRollupId` | `MAINNET_ROLLUP_ID = 0` |

### C.2 Hash from `executeCrossChainCall` (L2)

Same as L1, with `sourceRollupId = ROLLUP_ID` (this L2's chain ID).

### C.3 Hash from `staticCallLookup`

Same as the corresponding `executeCrossChainCall`, with `value = 0` (STATICCALL cannot carry ETH). The two values that disambiguate phases — `callNumber` and `lastNestedActionConsumed` — are part of the `LookupCall` struct, not part of the action hash.

### C.4 Hash for nested actions

Identical to the proxy that triggered the reentrant call. The protocol does not distinguish "top-level" vs "reentrant" in the hash itself; the routing decision (`_consumeAndExecute` vs `_consumeNestedAction`) is made at runtime via `_insideExecution()`.

### C.5 No `crossChainCallHash` for L2TX entries

`executeL2TX(rollupId)` requires `entry.proxyEntryHash == bytes32(0)`. There is no separate L2TX hash — the entry is identified by being the next entry on the rollup's queue.

---

## D. Execution Model

### D.1 Sequential Entry Consumption

Entries in `verificationByRollup[rid].queue` (or `_transientExecutions` during `postAndVerifyBatch`) are consumed in posted order via the rollup's `cursor` (or the global `_transientExecutionIndex` during the transient phase). Each call to `executeCrossChainCall` (top-level), `executeL2TX(rollupId)`, or — during `postAndVerifyBatch`'s meta hook — both, increments the per-rollup cursor by exactly one. There is no hash-based search and no swap-and-pop.

`_consumeAndExecute` checks `entry.proxyEntryHash == expectedHash` AND `entry.destinationRollupId == rollupId` and reverts `ExecutionNotFound` on mismatch. This catches out-of-order calls from a buggy hook, a wrong builder, or a routing mismatch.

Cross-rollup independence: a stuck cursor on one rollup does not block consumption on another — each rollup's queue advances on its own.

### D.2 Flat Call Processing

Within an entry, calls live in a single flat array `calls[]` and are processed by a non-recursive `while` loop in `_processNCalls`. Each iteration reads `entry.L2ToL1Calls[_currentCallNumber]`, increments the cursor (or self-calls `executeInContextAndRevert` for revert spans), and continues until `processed == count`.

Reentrant calls share the same `entry.L2ToL1Calls[]` and the same `_currentCallNumber` cursor — they recurse into `_processNCalls(nested.callCount)` from inside `_consumeNestedAction`, but the loop itself does not branch through the action data.

The total call accounting at the end of the entry:

```
_currentCallNumber       == entry.L2ToL1Calls.length          // UnconsumedCalls
_lastNestedActionConsumed == entry.expectedL1ToL2Calls.length // UnconsumedNestedActions
```

The sum of `entry.callCount` plus all `nestedAction.callCount`s **must** equal `entry.L2ToL1Calls.length`. This is not enforced as a separate check; it falls out of the two equalities above plus the sequential cursor advance.

### D.3 Reentrant Calls (ExpectedL1ToL2Call or failed LookupCall)

When the destination contract called by `_processNCalls` calls back into a proxy, the proxy forwards to `executeCrossChainCall`. Inside that call, `_insideExecution() == true` (the global counter is non-zero), so the path branches to `_consumeNestedAction`. The function speculatively bumps the cursor up front (`idx = _lastNestedActionConsumed++`) and then routes:

**1. ExpectedL1ToL2Call priority.** If `expectedL1ToL2Calls[idx].crossChainCallHash == crossChainCallHash`:
   1. The speculative `++` is the commit — no further cursor write.
   2. Hash `NESTED_BEGIN` into `_rollingHash`.
   3. Recurse into `_processNCalls(nested.callCount)`. Inside that call, `entry.L2ToL1Calls[]` is read at positions starting from the current `_currentCallNumber`.
   4. Hash `NESTED_END` into `_rollingHash`.
   5. Return `nested.returnData` to the destination.

**2. Otherwise — fall back to a failed LookupCall.** Scan `_transientLookupCalls` then `verificationByRollup[rid].lookupQueue` for an entry with `failed == true` and matching key `(crossChainCallHash, _currentCallNumber, idx)` — note the lookup uses `idx` (the pre-bump cursor), which is what the prover observed; `_lastNestedActionConsumed` itself currently holds `idx + 1`:
   - Hit → `_resolveLookupCall(lc)` replays any `lc.calls` via STATICCALL for integrity, then reverts with `lc.returnData`. The destination's `try/catch` absorbs the revert.
   - No hit → revert `ExecutionNotFound`.

**Why this works for reverts.** Every fallback path reverts, so the speculative `++` rolls back automatically (transient storage follows EVM revert rules). The cursors and `_rollingHash` outside the destination's `try/catch` reflect exactly what the prover simulated. A reverting reentrant call therefore needs **only** a `LookupCall` with `failed=true` — no companion `ExpectedL1ToL2Call`, no `revertSpan` wrapper.

**Why a `failed=false` lookup call here is invalid.** A successful reentrant call in a normal CALL frame is expressed as an `ExpectedL1ToL2Call`; a successful read-only call is in a STATICCALL frame and routed to `staticCallLookup` (§F) instead. A `failed=false` lookup entry matching this fallback path is a prover bug — the loop simply doesn't match it, so it falls through to `ExecutionNotFound`.

### D.4 Revert Span

`revertSpan > 0` opens an isolated EVM context for the next `revertSpan` calls. Mechanism:

1. Caller saves `_currentCallNumber` and `entry.L2ToL1Calls[saved].revertSpan`, then sets `entry.L2ToL1Calls[saved].revertSpan = 0` in storage so the inner self-call sees the call as normal at the same index.
2. `try this.executeInContextAndRevert(revertSpan)`. The inner call:
   - Runs `_processNCalls(revertSpan)`, which advances `_currentCallNumber`, `_lastNestedActionConsumed`, and `_rollingHash` based on the calls inside the span.
   - **Always** reverts with `ContextResult(_rollingHash, _lastNestedActionConsumed, _currentCallNumber)`.
3. The EVM revert rolls back all storage and transient state inside the self-call. The three values escape via the revert data.
4. Caller decodes `ContextResult` and writes the three values back into transient storage. The rolling hash and cursors now reflect what happened inside the span, even though the EVM rolled the state back.
5. Caller restores `entry.L2ToL1Calls[saved].revertSpan = revertSpan` and emits `RevertSpanExecuted`. `processed += revertSpan`.

A single mechanism handles atomic rollback: there are no continuation entries, no per-rollup state-root restoration, no scope tree to navigate. The "what happened" is encoded by the calls in the span; the "what state survives" is whatever the EVM rolled back.

#### D.4.1 When to use `revertSpan` (and when not to)

**Use `revertSpan > 0` only for forced reverts** — calls (or sequences of calls) that *would* succeed against the destination but whose state effects must not survive. The canonical scenario is a cross-chain call from rollup A to rollup B where the destination on B succeeds, but the prover output for the replaying side records that the call must be rolled back (for example, because the higher-level transaction that contained the call was reverted on A). The rolling hash still commits to a `CALL_END(success=true, retData=…)` outcome — what was promised — while the EVM rolls the state back.

**Do not use `revertSpan` to model a destination that naturally reverts.** With `revertSpan = 0`, `_processNCalls` already invokes the destination via the proxy's `.call`, captures `(success=false, retData=revertReason)`, and hashes that into `CALL_END`. The destination's own revert rolls back its own state. Wrapping a single naturally-reverting call in `revertSpan = 1` produces the same observable rolling hash and the same on-chain state as `revertSpan = 0` — it adds a self-call frame for no benefit. The mechanism only earns its keep when state would otherwise survive.

The three revert paths in the protocol are distinct — pick the one that matches the situation:

| Situation | Path |
|---|---|
| Top-level cross-chain call that naturally reverts | `LookupCall` with `failed = true`, consumed via `staticCallLookup`, the failed-reentry fallback in `_consumeNestedAction`, or the top-level fallback `_tryRevertedTopLevelLookup`. (Or, when the call lives inside `L2ToL1Calls[]`, place it with `revertSpan = 0` and let `CALL_END(false, retData)` capture it.) |
| **Reentrant** cross-chain call that reverts (caller wraps it in `try/catch`) | `LookupCall` with `failed = true` — *not* `revertSpan`, *not* `ExpectedL1ToL2Call`. See §D.3 / §F.4 |
| Successful call(s) whose state must be force-reverted | `revertSpan > 0` on the first call of the span |

The reentrant-revert case **must not** use `revertSpan`: the destination's `try/catch` already provides the isolation boundary, the `LookupCall` fallback in `_consumeNestedAction` replays the cached revert without advancing the consumption cursor, and the EVM revert from the caught failure has nothing to roll back. Wrapping it in `revertSpan` would consume an entry-level call slot the prover did not allocate.

### D.5 Flat Call Model

The off-chain prover emits a flat `L2ToL1Calls[]` array plus a parallel `ExpectedL1ToL2Call[]` table — it does not thread scope arrays through nested calls. Return data from a call is captured directly into the rolling hash via `CALL_END`; reverts of natural failures are captured via `success=false` in the same `CALL_END` tag. `revertSpan` is reserved for forced-revert spans where state must be rolled back even though the call(s) succeeded.

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
- `tstore` writes are part of the EVM journal and are **rolled back** when the call frame reverts. So when `executeInContextAndRevert` reverts with `ContextResult`, every transient write performed inside the span (including the rolling-hash updates and counter increments) is undone — except for the three values that escape via the revert payload, which the caller manually re-applies after decoding.

### E.2 LookupCall Sub-Hash (`LookupCall.rollingHash`)

`LookupCall.rollingHash` is **a separate accumulator**, scoped to a single `LookupCall` and computed only over its optional `calls[]` array (the static sub-calls replayed during lookup resolution). It is **not** the entry-level `_rollingHash`, and it uses a deliberately simpler, **untagged** hashing scheme:

```
hash = bytes32(0)
for cc in lookupCall.calls:
    sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId)
    (success, retData) = sourceProxy.staticcall(executeOnBehalf(cc.targetAddress, cc.data))
    hash = keccak256(abi.encodePacked(hash, success, retData))
require(hash == lookupCall.rollingHash);   // RollingHashMismatch
```

Note the differences from the entry-level scheme:

- **No event tags** (no `CALL_BEGIN` / `CALL_END` / `NESTED_BEGIN` / `NESTED_END` domain bytes).
- **No `callNumber`** mixed into each fold.
- **No nesting** at all — `_processNLookupCalls` does not handle reentrancy; STATICCALL forbids state writes, so the proxies' `executeOnBehalf` paths cannot reenter the manager's mutating entrypoints and consume nested actions or further lookup calls.

This simpler schema is safe because the surrounding lookup key already pins the call context that tagged events disambiguate at entry level. The match against the cached `LookupCall` is content-addressed by:

```
(crossChainCallHash, destinationRollupId, callNumber, lastNestedActionConsumed)
```

so the entry/call/nesting position is already locked in by the key. The only thing left for `LookupCall.rollingHash` to commit to is the **outcome of the static sub-calls**, in order, which is exactly what the untagged `keccak256(prev, success, retData)` chain captures. There is also no cross-contamination risk with the entry-level accumulator: `_processNLookupCalls` returns the local `computedHash` and never reads or writes `_rollingHash`.

The two accumulators serve different verification scopes and intentionally do not share a schema. If the lookup sub-call list ever needs to commit to richer structure (e.g., nesting), the schema would have to gain tags too — but as of this spec, lookup sub-calls are flat by construction.

### E.3 Worked Hash Chain Example

Setup:

```
entry.L2ToL1Calls    = [c0, c1, c2, c3, c4]
entry.callCount      = 3
entry.expectedL1ToL2Calls  = [ { crossChainCallHash = H_nested, callCount = 2, returnData = 0xaa } ]
entry.rollingHash    = <expected final hash>
```

The entry has 5 calls in the flat array. Entry-level processes 3 iterations: c0, c3, c4. While c0 is executing, the destination contract calls back into a proxy, which consumes `expectedL1ToL2Calls[0]`; that nested action processes c1 and c2.

Step-by-step:

```
Initial transient state:
  _rollingHash               = 0x0
  _currentCallNumber         = 0
  _lastNestedActionConsumed  = 0

─── Entry-level _processNCalls(3), iteration 0 ─────────────

  Read entry.L2ToL1Calls[0] = c0
  _currentCallNumber++ → 1
  hash CALL_BEGIN(callNum=1):
    _rollingHash = keccak256(0x0, uint8(1), uint256(1))                                    → H1

  Execute c0 via the source proxy. During c0, the destination contract calls back
  into a proxy on this chain → executeCrossChainCall → _insideExecution() == true
  → _consumeNestedAction(H_nested):

      idx = _lastNestedActionConsumed++ → idx=0, counter becomes 1
      require(expectedL1ToL2Calls[0].crossChainCallHash == H_nested)
      nestedNumber = idx + 1 = 1

      hash NESTED_BEGIN(nestedNum=1):
        _rollingHash = keccak256(H1, uint8(3), uint256(1))                                 → H2

      _processNCalls(2):  // nested action's callCount

        Read entry.L2ToL1Calls[1] = c1
        _currentCallNumber++ → 2
        hash CALL_BEGIN(callNum=2):
          _rollingHash = keccak256(H2, uint8(1), uint256(2))                               → H3
        Execute c1 via the source proxy. Succeeds with retData_1.
        hash CALL_END(callNum=2, success=true, retData_1):
          _rollingHash = keccak256(H3, uint8(2), uint256(2), true, retData_1)              → H4

        Read entry.L2ToL1Calls[2] = c2
        _currentCallNumber++ → 3
        hash CALL_BEGIN(callNum=3):
          _rollingHash = keccak256(H4, uint8(1), uint256(3))                               → H5
        Execute c2 via the source proxy. Succeeds with retData_2.
        hash CALL_END(callNum=3, success=true, retData_2):
          _rollingHash = keccak256(H5, uint8(2), uint256(3), true, retData_2)              → H6

      hash NESTED_END(nestedNum=1):
        _rollingHash = keccak256(H6, uint8(4), uint256(1))                                 → H7

      return expectedL1ToL2Calls[0].returnData (0xaa) to the destination contract

  c0's proxy call returns. Proxy reports success and retData_0.
  hash CALL_END(callNum=1, success=true, retData_0):
    _rollingHash = keccak256(H7, uint8(2), uint256(1), true, retData_0)                    → H8

─── Entry-level _processNCalls(3), iteration 1 ─────────────

  Read entry.L2ToL1Calls[3] = c3
  _currentCallNumber++ → 4
  hash CALL_BEGIN(callNum=4):
    _rollingHash = keccak256(H8, uint8(1), uint256(4))                                     → H9
  Execute c3. Succeeds with retData_3.
  hash CALL_END(callNum=4, success=true, retData_3):
    _rollingHash = keccak256(H9, uint8(2), uint256(4), true, retData_3)                    → H10

─── Entry-level _processNCalls(3), iteration 2 ─────────────

  Read entry.L2ToL1Calls[4] = c4
  _currentCallNumber++ → 5
  hash CALL_BEGIN(callNum=5):
    _rollingHash = keccak256(H10, uint8(1), uint256(5))                                    → H11
  Execute c4. Succeeds with retData_4.
  hash CALL_END(callNum=5, success=true, retData_4):
    _rollingHash = keccak256(H11, uint8(2), uint256(5), true, retData_4)                   → H12

─── Verification ─────────────

  _rollingHash (H12)              == entry.rollingHash             → RollingHashMismatch?       no
  _currentCallNumber (5)          == entry.L2ToL1Calls.length (5)        → UnconsumedCalls?           no
  _lastNestedActionConsumed (1)   == entry.expectedL1ToL2Calls.length(1) → UnconsumedNestedActions?   no
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

A single call iteration can issue several STATICCALLs at distinct points of its execution, possibly with the same `crossChainCallHash`. The `(callNumber, lastNestedActionConsumed)` pair forms a coordinate that advances monotonically and never repeats — it is what the lookup queue is keyed on (see §F.1).

Example: while `entry.L2ToL1Calls[0]` (call #1 at the entry level) executes, the destination contract:

```
Call #1 begins:
  _currentCallNumber = 1
  _lastNestedActionConsumed = 0

  STATICCALL to proxy → staticCallLookup
    → matched by (crossChainCallHash, callNumber=1, lastNestedActionConsumed=0)

  Trigger nested action #1 (a successful reentrant call)
    → _consumeNestedAction post-increments _lastNestedActionConsumed to 1
    → NESTED_BEGIN/END are hashed; nested calls (if any) advance _currentCallNumber

  STATICCALL to proxy → staticCallLookup
    → matched by (crossChainCallHash, callNumber=K, lastNestedActionConsumed=1)
       where K is _currentCallNumber after any nested calls
```

Both STATICCALLs may carry the **same** `crossChainCallHash` — the builder differentiates them by recording the live values of `_currentCallNumber` and `_lastNestedActionConsumed` at the exact point of each STATICCALL during simulation, and stamping them into the corresponding `LookupCall` entries.

If `_currentCallNumber` advanced inside the nested action (the nested action consumed some of `entry.L2ToL1Calls[]`), the second STATICCALL's `callNumber` will be larger than the first's. If the nested action was empty (`callCount == 0`), `_currentCallNumber` stays at 1 and the two STATICCALLs differ only in `lastNestedActionConsumed` (0 vs 1).

---

## F. Lookup Call Resolution

Lookup calls (read-only or reverting reentrant / top-level calls) are looked up — never executed via the normal call path. There are two entry points into the lookup:

1. **`staticCallLookup`** (external view) — used when the proxy's `_fallback` detects a real STATICCALL context (a self-call to `staticCheck` whose `tstore` reverts). Handles both `failed=true` and `failed=false` entries.
2. **Fallback inside `_consumeNestedAction`** — used when a normal-CALL reentrant call has no matching `ExpectedL1ToL2Call`. Only matches `failed=true` entries (the destination's `try/catch` consumes the revert). See §D.3.

Both entry points share the same match key and `_resolveLookupCall` helper.

### F.1 Match Key

```
(crossChainCallHash, destinationRollupId, callNumber, lastNestedActionConsumed)
```

- `crossChainCallHash` — same formula as `computeCrossChainCallHash` (with `value = 0`).
- `destinationRollupId` — the rollup whose `lookupQueue` is being scanned (the consumer's routing rollupId).
- `callNumber` — `uint64(_currentCallNumber)` at lookup time.
- `lastNestedActionConsumed` — `uint64(_lastNestedActionConsumed)` at lookup time.

The counters together identify a unique phase of execution. They both advance monotonically and never repeat within a single entry's execution.

### F.2 Lookup Algorithm

L1:

```
for lc in _transientLookupCalls:
    if all four fields match: return _resolveLookupCall(lc)
for lc in verificationByRollup[rollupId].lookupQueue:
    if all four fields match: return _resolveLookupCall(lc)
revert ExecutionNotFound
```

L2: same, but only scans `lookupCalls` (single-rollup, no transient table, no per-rollup map).

`_resolveLookupCall(lc)`:
- If `lc.calls.length > 0`: replay them in static context (`_processNLookupCalls`) and check `computedHash == lc.rollingHash` (else `RollingHashMismatch`).
- If `lc.failed`: revert with `lc.returnData`.
- Else return `lc.returnData`.

### F.3 Lookup Sub-Calls

A `LookupCall` may include its own `calls[]` array — these are STATICCALLs that the cached call itself would issue. They are replayed at lookup time in static context (no `revertSpan` handling, no proxy creation), and their composite hash is checked against `lc.rollingHash`.

This lets a lookup model a contract that performs read-only sub-calls: the lookup verifies the sub-call results match what the proof committed to, and only then returns the cached top-level result.

### F.4 When to use `LookupCall` vs `ExpectedL1ToL2Call`

| Situation | Use | Routed via |
|---|---|---|
| Reentrant call that **succeeds** | `ExpectedL1ToL2Call` | `_consumeNestedAction` (priority branch) |
| Reentrant call that **reverts** (caller catches with try/catch) | `LookupCall` with `failed = true` | `_consumeNestedAction` fallback |
| Reentrant cross-chain `STATICCALL` (read-only, success or revert) | `LookupCall` with `failed` set as appropriate | `staticCallLookup` (real STATICCALL frame) |
| Top-level call that should fail (natural revert) | `LookupCall` with `failed = true`, consumed via `staticCallLookup`, the failed-reentry fallback in `_consumeNestedAction`, or `_tryRevertedTopLevelLookup` | — |
| Successful call(s) whose state must be force-reverted | `revertSpan > 0` on the first call of the span (see §D.4.1) | `executeInContextAndRevert` self-call |

---

## G. Execution Entry Lifecycle

### G.1 L1 Posting

`postAndVerifyBatch` lazy-resets each touched rollup's `verificationByRollup[rid]`, populates `_transientExecutions` and `_transientLookupCalls` from each batch's leading prefixes, drains the leading immediate entries inline (if any), runs the meta hook, wipes the transient tables, and unconditionally publishes each batch's remainder into the per-rollup queues.

Within a single `postAndVerifyBatch`:
1. Reentry guard: `_transientExecutions.length == 0` (revert `PostBatchReentry` otherwise). Validate. Verify proofs (`checkProofSystemsAndGetVkeys` per rollup, then `IProofSystem.verify` per PS).
2. Mark `verificationByRollup[rid].lastVerifiedBlock = block.number` for every touched rollup; lazy-reset per-rollup queues / cursors on first touch this block.
3. Load the batch's transient prefix into `_transientExecutions` / `_transientLookupCalls`.
4. Drain leading immediate entries (skip-on-revert via `ImmediateEntrySkipped`).
5. Meta hook runs if transient stream not yet drained AND `msg.sender` has code (per-rollup cursors advance per consumption).
6. Wipe transient tables; reset `_transientExecutionIndex`.
7. Publish the batch's remainder to per-rollup queues by `destinationRollupId` (only if transient prefix fully drained). Soundness backstop is `StateDelta.currentState`.
8. Emit `BatchPosted(batch.rollupIdsWithProofSystems.length)`.

### G.2 L2 Loading

`loadExecutionTable` clears `executions` and `lookupCalls`, copies the new entries / lookup calls in, and sets `lastLoadBlock = block.number`. There is no transient table and no per-rollup queue map on L2.

### G.3 Consumption

Sequential — per-rollup `verificationByRollup[rid].cursor++` (or `_transientExecutionIndex++` during the transient phase) per consumption. Each entry is consumed exactly once. There is no swap-and-pop and no hash-based search.

### G.4 Same-Block Restriction

On L1, all execution attempts revert `ExecutionNotInCurrentBlock(rollupId)` if `verificationByRollup[rollupId].lastVerifiedBlock != block.number`. On L2, same with `lastLoadBlock`. Entries that aren't consumed in the loading block are unreachable on the next load (per-rollup queues are lazy-reset on the next batch that touches the rollup).

### G.5 Table Clearing

Each new `postAndVerifyBatch` lazy-resets the touched rollups' queues; `loadExecutionTable` wipes the entire L2 table. Builders must produce self-contained batches.

---

## H. Invariants

### H.1 State Root Consistency (L1)

`rollups[id].stateRoot` is updated only:
- By `_applyStateDeltas` (during `_applyAndExecute`, called from `postAndVerifyBatch`, `executeCrossChainCall`, or `executeL2TX`).
- By `setStateRoot(rid, newRoot)` from the rollup's manager (subject to the same-block lockout).

The previous-state binding lives on the entry: `StateDelta.currentState` is checked at consumption time against `rollups[id].stateRoot`; mismatch reverts `StateRootMismatch(id)`. The proof itself binds to the FULL `ExecutionEntry` struct (including `stateDeltas`), so a stale builder either fails proof verification or fails the on-chain `currentState` match. This dual binding is the per-rollup-queue model's soundness backstop.

### H.2 Ether Accounting (L1)

For each entry: `totalEtherDelta == etherIn - etherOut`, where `etherIn` is the `msg.value` received by the entry-point call (or 0 for `executeL2TX` and immediate entries) and `etherOut` is the sum of `value` fields on every **successful** call inside the entry.

Each entry independently balances — ether accounting is localized to a single entry rather than aggregated across the transaction — which simplifies the prover's job.

The sum of `etherBalance` across all rollups plus `address(rollups).balance` is conserved modulo direct deposits/withdrawals outside the protocol.

### H.3 Sequential Consumption

Each entry is consumed exactly once, in posted order **on its destination rollup**. Each rollup has its own monotonically-increasing `cursor` that is reset to 0 when the queue is lazy-reset (next batch that touches the rollup). Cross-rollup state is independent.

### H.4 Rolling Hash Integrity

After each entry completes:

```
_rollingHash               == entry.rollingHash             // RollingHashMismatch
_currentCallNumber         == entry.L2ToL1Calls.length            // UnconsumedCalls
_lastNestedActionConsumed  == entry.expectedL1ToL2Calls.length    // UnconsumedNestedActions
```

Together, these three checks attest that every call described in the entry was processed in the correct order, with the correct return data, with the correct nesting structure, and that nothing extra happened.

### H.5 Proxy Determinism

Address of `CrossChainProxy(originalAddress, originalRollupId)` is fully determined by:
- The manager contract (`address(this)` at deployment time)
- Salt: `keccak256(abi.encodePacked(originalRollupId, originalAddress))`
- `CrossChainProxy` creation code + constructor args

The same pair always maps to the same proxy address on the same manager. Two proxies for the same pair cannot exist (CREATE2 collision would revert).

### H.6 Same-Block Execution

All entries posted in a given block must be consumed in that block — `verificationByRollup[rid].lastVerifiedBlock == block.number` (L1, per-rollup) or `lastLoadBlock == block.number` (L2).

### H.7 Lazy Reset Per Block

`postAndVerifyBatch` lazy-resets each touched rollup's queue / lookupQueue / cursor when its `lastVerifiedBlock` is stale. `loadExecutionTable` (L2) `delete`s the entire existing table before loading new entries. Unconsumed entries from a prior block are unreachable.

### H.8 Per-Rollup Queue Soundness

The deferred remainder of a `postAndVerifyBatch` is published unconditionally to per-rollup queues. Partial transient drain does not drop persistent entries; the soundness backstop is `StateDelta.currentState`, checked at consumption. Entries whose recorded pre-state doesn't match the on-chain state at consumption revert `StateRootMismatch`.

### H.9 Reentry Guard for `postAndVerifyBatch`

`postAndVerifyBatch` re-entered from any path (e.g., by the meta hook) reverts `PostBatchReentry` — the guard is `_transientExecutions.length != 0` at the top of the function (there is no separate `_inPostBatch` flag). This prevents corruption of the shared `_transientExecutions` / `_transientLookupCalls` storage by a nested call.

Same-block re-touch of a rollup across separate (non-nested) `postAndVerifyBatch` calls is **permitted**: `_markVerifiedThisBlock` short-circuits silently on a same-block re-touch and entries from the second batch append to the existing per-rollup queue. Orchestrators that need once-per-block-per-rollup exclusivity must enforce it at the social layer.

---

## I. Security Considerations

### I.1 Multi-Prover Verification

`postAndVerifyBatch` verifies one proof per `(batch, proofSystem)` pair. Each proof's public-inputs hash covers (see `MULTI_PROVER_DESIGN.md` for the exact construction):

- Every entry hash — `keccak256(abi.encode(entry))` over the FULL `ExecutionEntry` struct (including `stateDeltas` with `currentState`, `proxyEntryHash`, `destinationRollupId`, `L2ToL1Calls`, `expectedL1ToL2Calls`, `callCount`, `returnData`, `rollingHash`).
- Every lookup-call hash — `keccak256(abi.encode(lookupCall))`.
- Every blob hash (for data availability).
- Per-rollup `(blockHash, timestamp)` fetched via `IRollupContract.getTimestampAndBlockHash()` and folded into the per-PS accumulator `acc_k` (one quadruple per attesting rollup).
- `keccak256(callData)`.
- `crossProofSystemInteractions` (binds cross-PS messages within the batch).
- The per-rollup vkey row (`vkMatrix[r][j]`) for the rollup's `proofSystemIndex[]` subset.

All proofs in the batch verify atomically — a single failure reverts. Per-rollup attestation is enforced inside each manager's `checkProofSystemsAndGetVkeys`, which reverts (threshold-not-met / unknown-PS / zero-vkey) if the resolved subset for `rid` is insufficient.

A malicious caller producing a forged batch would have to forge proofs from every required PS for every touched rollup at the current rollup states.

### I.2 Reentrancy

The protocol is intentionally reentrant. `_processNCalls` calls into proxies, which forward to destination contracts, which may call back into proxies. Reentrant calls are routed to `_consumeNestedAction` via the `_insideExecution()` check. The transient `_currentCallNumber` cursor naturally serializes everything within one entry.

`postAndVerifyBatch` re-entry from the meta hook is blocked by a single guard: `if (_transientExecutions.length != 0) revert PostBatchReentry()` at the top of the function. The transient-stream length doubles as the reentry flag — it is non-zero whenever a `postAndVerifyBatch` call is mid-flight and zero in between calls. Same-block re-touch across separate (non-nested) calls is permitted — see H.9.

The two view-only external calls during proof verification (`IRollupContract.checkProofSystemsAndGetVkeys` and `IProofSystem.verify`) are made inside `STATICCALL` frames, so a malicious manager / verifier cannot mutate state during step 3 of `postAndVerifyBatch`.

### I.3 Untrusted Meta Hook

`postAndVerifyBatch` invokes `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` if `msg.sender` has code. The hook is untrusted — it may revert, consume some entries, ignore the call, or attempt to re-enter `postAndVerifyBatch`. The protocol's defense:

- **Re-entry**: blocked by `PostBatchReentry` (the `_transientExecutions.length != 0` guard) — see I.2.
- **Partial consumption**: the persistent remainder is published anyway; `StateDelta.currentState` is the soundness backstop at consumption time.
- **Hook revert**: the entire `postAndVerifyBatch` reverts (atomicity), which rolls back every write — `lastVerifiedBlock`, the transient stream, the immediate entries, the published remainder. The next caller can re-attempt cleanly.

### I.4 Access Control Summary

| Function | Who can call |
|---|---|
| `registerRollup` | Anyone |
| `postAndVerifyBatch` | Anyone (proofs verify authorization) |
| `executeCrossChainCall` (L1 / L2) | Registered proxies only |
| `executeL2TX(rollupId)` (L1) | Anyone (must not be inside execution) |
| `staticCallLookup` (L1 / L2) | Registered proxies only (called via STATICCALL by the proxy) |
| `executeInContextAndRevert` (L1 / L2) | Self-call only (`address(this)`) |
| `createCrossChainProxy` (L1 / L2) | Anyone |
| `setStateRoot(rid, newRoot)` (L1) | Current `rollups[rid].rollupContract` (subject to same-block lockout AND `SetStateRootNotAllowedDuringExecution` guard) |
| `loadExecutionTable` (L2) | `SYSTEM_ADDRESS` |
| `executeIncomingCrossChainCall(...)` (L2) | `SYSTEM_ADDRESS` |
| `attemptApplyImmediate(transientIdx)` (L1) | Self-call only (`address(this)`) |

Per-rollup ownership operations (`addProofSystem`, `removeProofSystem`, `setVerificationKey`, `setThreshold`, `transferOwnership`) live on the rollup's manager (`src/rollupContract/Rollup.sol` reference impl).

### I.5 Reentry Guard and Same-Block Touch Semantics

`postAndVerifyBatch` reentry from anywhere (meta hook, manager callback, etc.) is blocked by `PostBatchReentry` via the `_transientExecutions.length != 0` check at the top of the function.

Multiple top-level `postAndVerifyBatch` calls hitting the same rollup in the same block are permitted by design: `_markVerifiedThisBlock` short-circuits silently on a same-block re-touch and entries from the second batch append to the existing queue. Builders cannot rely on once-per-block-per-rollup exclusivity; if exclusivity is required, the orchestrator must enforce it at the social layer.

### I.6 Cross-Chain Proxy Identity

A `CrossChainProxy` represents exactly one `(originalAddress, originalRollupId)` pair. When the manager calls a destination via `CrossChainProxy.executeOnBehalf`, the destination sees `msg.sender = proxy address` (deterministic from the pair). The cross-chain identity is encoded by the pair, not by `msg.sender` alone — two proxies on different managers for the same pair have the same address only if the managers themselves match.

### I.7 Static Context Detection

The `tstore` / `tload` asymmetry is the basis for STATICCALL detection: `tstore` reverts in static context, `tload` does not. The proxy's `_fallback` self-calls `staticCheck()` (which attempts `tstore`); if the self-call reverts, the proxy is in static context and routes to `staticCallLookup`. This works because:
- A self-call to `staticCheck` from within a STATICCALL is itself a STATICCALL (the proxy can't escalate privileges).
- The `tstore` inside `staticCheck` is the only thing that can fail; everything else (the call itself, the `_fallback` machinery) is read-only.

A misbehaving destination contract that suppresses the static context would still hit `staticCallLookup` via this detector — there is no way to fake a non-static context from inside a STATICCALL.

### I.8 Sequential Index — No Out-of-Order Consumption

Because `_consumeAndExecute` increments the cursor by exactly one and verifies `entry.proxyEntryHash == expectedHash`, a builder error or a hook error that triggers an unexpected call reverts immediately and cleanly. The cursor only advances on a hash-matching consumption — never on a mismatch — so the table state remains coherent across reverts within a single `postAndVerifyBatch`.

### I.9 Rolling Hash as Integrity Backbone

The single `_rollingHash == entry.rollingHash` check is the primary integrity guarantee. Because the hash chains every `(success, retData)` pair plus every `NESTED_BEGIN` / `NESTED_END` boundary with unique tags, a single mismatch anywhere — wrong return data, wrong nesting, missing call, extra call, reordered operations — produces a different final hash and is caught at the entry boundary.

No path exists where execution diverges from the proof and still completes successfully — every divergence (return data, nesting, ordering, count) lands in the rolling hash and is rejected at the entry boundary.

---

*End of specification. This document covers the flat sequential execution model. For migration notes from the legacy scope-tree / `ActionType` model, see `CHANGES_FROM_PREVIOUS.md`.*
