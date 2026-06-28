# Core Protocol Specification

**Source**: `src/`
**Purpose**: Formal reference for implementing the Rust rollup node. Supersedes informal comments in source code.

This document covers the **flat sequential execution model** layered with the **multi-prover / per-rollup-queue** model from the `feature/flatten` refactor. Every cross-chain entry is a flat list of calls processed sequentially, with reentrant calls resolved via a parallel expected-calls table and integrity verified by a single `rollingHash` per entry. The execution structs are split per side: L1 (`src/interfaces/IEEZ.sol`) uses absolute directional names (`L2ToL1Call` / `l2ToL1Calls`, `ExpectedL1ToL2Call` / `expectedL1ToL2Calls`); L2 (`src/interfaces/IEEZL2.sol`) uses **self-relative** directional names (`CrossChainCall` / `incomingCalls`, `ExpectedOutgoingCrossChainCall` / `expectedOutgoingCalls`) because an L2's counterparty can be L1 OR another L2 — see §A.1. Entries are routed by `destinationRollupId` into per-rollup queues on L1. `postAndVerifyBatch` carries a single `ProofSystemBatchPerVerificationEntries` whose proofs verify atomically.

For the multi-prover design (batch shape, per-PS public-inputs construction, threshold semantics), see `MULTI_PROVER_SPEC.md`.

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

The execution structs come in **two layout-similar but separately-declared families**:

- **L1 (`src/interfaces/IEEZ.sol`)** — absolute directional names: an `L2ToL1Call` is a cross-chain call executed on L1; an `ExpectedL1ToL2Call` is a reentrant L1→L2 call fired during execution.
- **L2 (`src/interfaces/IEEZL2.sol`)** — **self-relative** directional names: an `incomingCalls[]` entry is a call executed ON this L2 on behalf of a remote caller; an `expectedOutgoingCalls[]` entry is the pre-computed result of a reentrant call fired FROM this L2. The naming is relative to the chain itself because an L2's counterparty can be L1 (mainnet) OR another L2 — absolute names like `l1ToL2Calls` would frequently be wrong.

The L2 structs are deliberately **leaner**: L2 has a single rollup, no state deltas, and no per-rollup queue interleaving, so the L1-only fields (`StateDelta[] stateDeltas`, `destinationRollupId`, `ExpectedStateRootPerRollup[] expectedStateRoots`) do not exist on L2 at all. L2 never hashes a whole entry/lookup, so its layout is free to diverge from L1's.

#### Action hash (off-chain helper)

Tooling computes `crossChainCallHash` from six fields (`targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId`). The on-chain interface (`IEEZ.sol`) does **not** declare an `Action` struct — contracts call the `public pure` helper `computeCrossChainCallHash(...)` directly with the six fields. A compatibility `Action` struct exists in `script/e2e/shared/E2EHelpers.sol` for tooling that prefers a single-arg `keccak256(abi.encode(action))` form; both routes produce the same preimage.

#### StateDelta (L1 only)

Describes one rollup's state transition caused by executing one entry. The pre-state binding lives on the entry: `currentState` is checked at consumption time against `rollups[delta.rollupId].stateRoot`; mismatch reverts `StateRootMismatch`. This makes entries content-addressed against the trajectory the proof committed to and is the soundness backstop that lets the per-rollup queue model interleave consumption across rollups safely.

**Prover obligation**: an entry's `stateDeltas` must be its true state transition, and every entry must carry **at least one** `StateDelta` — the prover asserts `stateDeltas.length >= 1` for every entry it emits. This is not enforced on-chain; an empty `stateDeltas[]` would leave the entry unpinned from any rollup trajectory (nothing for the `StateRootMismatch` backstop to check).

```solidity
struct StateDelta {
    uint256 rollupId;       // which rollup's state changes
    bytes32 currentState;   // expected pre-state root on rollupId — checked against rollups[rid].stateRoot
    bytes32 newState;       // post-execution state root
    int256  etherDelta;     // signed change in rollup's ETH balance
}
```

#### L2ToL1Call (L1) / CrossChainCall (L2)

A single call in the entry's flat call array (`l2ToL1Calls[]` on L1, `incomingCalls[]` on L2). The two structs are field-identical; only the type name differs.

```solidity
// L1 (IEEZ.sol): L2ToL1Call — L2 (IEEZL2.sol): CrossChainCall, same fields
struct L2ToL1Call {
    address targetAddress;
    uint256 value;
    bytes   data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;   // 0 = normal call; N>0 = force-revert state effects of next N calls (this one inclusive); see §D.4.1
}
```

#### ExpectedL1ToL2Call (L1) / ExpectedOutgoingCrossChainCall (L2)

Pre-computed result for a **successful** reentrant cross-chain call.

```solidity
// L1 (IEEZ.sol): ExpectedL1ToL2Call — L2 (IEEZL2.sol): ExpectedOutgoingCrossChainCall, same fields
struct ExpectedL1ToL2Call {
    bytes32 crossChainCallHash;   // hash of the reentrant call (must equal computeCrossChainCallHash at consumption)
    uint256 callCount;    // iterations from the entry's flat call array consumed inside this reentrant frame
    bytes   returnData;   // the value returned to the destination contract
}
```

Reverting reentrant calls cannot be expressed as `ExpectedL1ToL2Call` / `ExpectedOutgoingCrossChainCall` — they must use a reverted NESTED lookup (`ExpectedLookup { failed: true }` inside the entry's `expectedLookups[]`).

#### ExecutionEntry

The central execution unit. Loaded by `postAndVerifyBatch` (L1) or `loadExecutionTable` / `executeIncomingCrossChainCall` (L2). The two sides declare separate structs:

```solidity
// L1 (IEEZ.sol)
struct ExecutionEntry {
    StateDelta[]           stateDeltas;          // state root deltas (initial state → final state)
    bytes32                proxyEntryHash;       // bytes32(0) = immediate, otherwise the trigger action hash
    uint256                destinationRollupId;  // rollup whose queue this entry routes to (per-rollup queue model)
    L2ToL1Call[]           l2ToL1Calls;          // flat array of ALL calls in execution order
    ExpectedL1ToL2Call[]   expectedL1ToL2Calls;  // sequentially consumed by reentrant calls
    ExpectedLookup[]       expectedLookups;      // entry-scoped nested lookups (static reads + try/catch'd reverts)
    uint256                callCount;            // number of entry-level (top-level frame) iterations to process
    bytes                  returnData;           // pre-computed return data for the entry's top-level call
    bytes32                rollingHash;          // expected hash after all calls and nestings complete
}
```

```solidity
// L2 (IEEZL2.sol) — no stateDeltas, no destinationRollupId
struct ExecutionEntry {
    bytes32                              proxyEntryHash;        // hash of the inbound call — never bytes32(0) on L2 (no zero-hash consumption path; executeL2TX is L1-only)
    CrossChainCall[]                     incomingCalls;         // flat array of ALL calls in execution order
    ExpectedOutgoingCrossChainCall[]     expectedOutgoingCalls; // sequentially consumed by reentrant calls
    ExpectedLookup[]                     expectedLookups;       // entry-scoped nested lookups
    uint256                              callCount;
    bytes                                returnData;
    bytes32                              rollingHash;
}
```

A top-level entry carries a `success` flag. When `success == true`, `executeCrossChainCall` runs the entry and returns `entry.returnData`. When `success == false`, the entry is run and verified (rolling hash + ether invariant) exactly as a successful one, then **reverted with `entry.returnData`** so all of its state effects roll back — the top-level call fails and the caller may try/catch it. (Read-only reverting top-level results are still expressed via a top-level `StaticLookup` resolved by `staticCallLookup` outside an execution.)

Partition invariant: `entry.callCount + Σ expectedL1ToL2Calls[i].callCount == l2ToL1Calls.length` (L2: `expectedOutgoingCalls` / `incomingCalls`) — see §D.2.

#### ExpectedLookup (NESTED lookups — entry-scoped)

The pre-computed result of a reentrant cross-chain call that is looked up rather than executed: a reentrant STATICCALL (static mode, `failed == false` — may also revert with `returnData` when `failed`), or a try/catch'd reverting reentrant call (reverted mode, executed as a mini-entry). Lives INSIDE the entry (`ExecutionEntry.expectedLookups[]`), and inside a top-level `LookupCall.expectedLookups[]` for its sub-execution — entry-scoped by construction, no queue routing. Matched by the 4-tuple:

```
(crossChainCallHash, l2ToL1CallNumber, lastL1ToL2CallConsumed, executingLookupIndex)   // L1
(crossChainCallHash, callNumber, lastOutgoingCallConsumed, executingLookupIndex)       // L2
```

```solidity
// L1 (IEEZ.sol) — L2 mirrors with self-relative names
struct ExpectedLookup {
    bytes32      crossChainCallHash;
    bytes        returnData;                 // returned (static) / reverted-with (failed)
    bool         failed;
    uint64       l2ToL1CallNumber;           // _currentL2ToL1Call at observation
    uint64       lastL1ToL2CallConsumed;     // _lastL1ToL2CallConsumed at observation
    uint64       executingLookupIndex;       // execution context: 0 = host level, k = inside the sub-execution of expectedLookups[k-1]
    L2ToL1Call[] l2ToL1Calls;                // sub-calls: STATICCALL (static) or real calls (reverted)
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;// reverted-mode reentrant table; empty for static mode
    uint256      callCount;                  // reverted-mode top-level iterations; 0 for static mode
    bytes32      rollingHash;                // untagged schema (static), tagged (reverted)
}
```

`executingLookupIndex` makes the flat host table context-unambiguous across the entry and its execution contexts — compared against the live `_insideRevertedLookup ? _revertedLookupIndex + 1 : 0` (an enforced check, no longer a prover convention). `ExpectedLookup` cannot nest itself (Solidity forbids recursive structs): deeper lookups inside any sub-execution resolve from the same host table. See `LOOKUP_SPEC.md`.

#### ExpectedStateRootPerRollup (L1 only)

Content-addresses a TOP-LEVEL lookup to a point on each pinned rollup's trajectory: a candidate only MATCHES when every pin equals the live `rollups[rollupId].stateRoot` (full-scan semantics — a mismatching candidate is skipped, not reverted on). Split-independent, valid in the transient phase, and robust under same-block re-verify — unlike the queue-cursor pins it replaced.

```solidity
struct ExpectedStateRootPerRollup {
    uint256 rollupId;
    bytes32 stateRoot;
}
```

#### LookupCall (TOP-LEVEL lookups — storage pool)

Pre-computed result for a top-level call that is looked up rather than executed — a top-level static read (`staticCallLookup` outside an execution) or a top-level reverting call (`_tryRevertedTopLevelLookup`). Lives in the storage pool (`_transientLookupCalls` / per-rollup `lookupQueue` on L1; `lookupCalls` on L2) and is consumable ONLY when `!_insideExecution()`. Match key: `crossChainCallHash` + all state-root pins live (L1; L2 matches by hash alone). Reverted mode runs as a mini-entry (with nested lookups from its own `expectedLookups` table), then reverts with `returnData`.

```solidity
// L1 (IEEZ.sol)
struct LookupCall {
    bytes32      crossChainCallHash;
    uint256      destinationRollupId;        // lookupQueue this is published under (== the target rollup bound into crossChainCallHash)
    bytes        returnData;
    bool         failed;                     // true → lookup reverts with returnData
    L2ToL1Call[] l2ToL1Calls;                // sub-calls: STATICCALL in static mode or real calls (reverted mode)
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;// reverted-mode reentrant table; empty for static mode
    ExpectedLookup[]     expectedLookups;    // reverted-mode nested lookups for the sub-execution; empty for static mode
    uint256      callCount;                  // reverted-mode top-level iterations; 0 for static mode
    bytes32      rollingHash;                // expected hash of the sub-calls (untagged schema in static mode, tagged in reverted mode)
    ExpectedStateRootPerRollup[] expectedStateRoots; // state-root pins — part of the MATCH (L1 only)
}
```

```solidity
// L2 (IEEZL2.sol) — no destinationRollupId, no expectedStateRoots
struct LookupCall {
    bytes32          crossChainCallHash;
    bytes            returnData;
    bool             failed;
    CrossChainCall[] incomingCalls;
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls;
    ExpectedLookup[] expectedLookups;
    uint256          callCount;
    bytes32          rollingHash;
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

The central registry no longer holds owner or vkey — those live on each rollup's `rollupContract` (reference impl: `src/rollupContract/Rollup.sol`). See `MULTI_PROVER_SPEC.md` for the per-rollup-manager model.

#### RollupVerification (L1 only)

Per-rollup queue, lookup queue, cursor, and verified-this-block marker — replaces the legacy global `executions[]` / `executionIndex` / `lastStateUpdateBlock`.

```solidity
struct RollupVerification {
    uint256          lastVerifiedBlock;   // per-block reset marker + read gate + setStateRoot lockout signal
    ExecutionEntry[] executionQueue;      // per-rollup deferred entries
    LookupCall[]     lookupQueue;         // per-rollup deferred lookup calls
    uint256          executionQueueIndex; // per-rollup consumption cursor
}
```

### A.2 Storage Layout

#### EEZ.sol (L1) — inherits `EEZBase`

| Variable | Type | Notes |
|----------|------|-------|
| `rollupCounter` | uint256 | Last assigned rollup ID (`registerRollup` assigns `++rollupCounter`) |
| `rollups` | mapping(uint256 ⇒ RollupConfig) | Per-rollup config (manager pointer + state root + ether) |
| `verificationByRollup` | internal mapping(uint256 ⇒ RollupVerification) | Per-rollup deferred queues + cursor (public views: `lastVerifiedBlock(rid)`, `queueLength(rid)`, `executionQueueIndex(rid)`) |
| `_transientExecutions` | ExecutionEntry[] (public) | Transient-backed entries (cleared each `postAndVerifyBatch`); also doubles as the reentry guard via `length != 0` |
| `_transientLookupCalls` | LookupCall[] (public) | Transient-backed TOP-LEVEL lookups (nested lookups live inside their entries) |
| `_transientExecutionIndex` | `uint256 transient` | Global cursor into `_transientExecutions` (cross-rollup, intra-`postAndVerifyBatch`) |
| `_currentEntryRollupId` | `uint256 transient` | RollupId of the active entry (so `_consumeNestedAction` finds the right queue); `0` while running a transient entry |
| `_l1ToL2CallNotFound` | `bool transient` | Deferred no-match flag set by `_consumeNestedAction` when nothing matches; checked at the end of `_applyAndExecute` to revert `ExecutionNotFound`, and OR-merged out of a `revertSpan` via the 4th `ContextResult` field. **L1 only** (L2 reverts in place). |
| `_currentL2ToL1Call` | `uint256 transient` | 1-indexed global L2→L1 call counter and cursor into `entry.l2ToL1Calls[]`; doubles as the `_insideExecution()` flag (`!= 0`) |
| `_lastL1ToL2CallConsumed` | `uint256 transient` | Sequential reentrant (L1→L2) call consumption cursor |
| `_entryEtherIn` | `uint256 transient` | All ether received via `executeCrossChainCall` during the current entry (top-level + reentrant `msg.value`); the single in-side of the ether-delta invariant (§H.2). Top-level discipline: `executeCrossChainCall` SETS it to msg.value; `executeL2TX` and `attemptApplyImmediate` revert `ResidualEntryEtherIn` unless it is already 0; reentrant calls ADD; cleared again at the END of `_applyAndExecute`. **L1 only** |
| `_revertedLookupRollupId` | `uint256 transient` | Rollup whose persistent `lookupQueue` holds the TOP-LEVEL LookupCall being executed (pairs with `_topLevelLookupIndex`; unused for a transient-table match). **L1 only** |

Inherited from `EEZBase`:

| Variable | Type | Notes |
|----------|------|-------|
| `authorizedProxies` | mapping(address ⇒ ProxyInfo) | Registered proxies |
| `_rollingHash` | `bytes32 transient` | Rolling hash accumulator |
| `_currentEntryIndex` | `uint256 transient` | Active entry index for nested-action consumption |
| `_insideRevertedLookup` | `bool transient` | True while executing a reverted NESTED lookup (`_executeRevertedNestedLookup`); scopes `_activeCalls()` / `_activeNested()` to the `ExpectedLookup` at `_revertedLookupIndex` within the active host table |
| `_revertedLookupIndex` | `uint256 transient` | Index of the nested `ExpectedLookup` being executed, within the active host table (`_getActiveLookups()`) |
| `_revertedLookupTopLevel` | `bool transient` | True while a reverted TOP-LEVEL `LookupCall` is the active HOST (`_executeRevertedTopLevelLookup`) — its tables drive the sub-execution instead of an entry's |
| `_topLevelLookupIndex` | `uint256 transient` | Pool index of the top-level LookupCall being executed (kept separate from `_revertedLookupIndex` so a nested reverted-lookup execution inside a top-level reverted-lookup execution doesn't clobber the pool coordinate) |

The per-side call cursors live in the children, not the base: L1 declares `_currentL2ToL1Call` / `_lastL1ToL2CallConsumed`, L2 declares `_currentIncomingCall` / `_lastOutgoingCallConsumed` — same mechanics, per-side directional names.

`MAINNET_ROLLUP_ID = 0` is a constant. The five rolling-hash tag constants `CALL_BEGIN=1, CALL_END=2, NESTED_BEGIN=3, NESTED_END=4, CALL_NOT_FOUND=5` are internal constants on `EEZBase`. There is no `_inPostBatch` flag — reentry is detected via `_transientExecutions.length != 0` instead.

`_transientExecutions` and `_transientLookupCalls` are declared as regular storage arrays (not Solidity `transient`) because the `transient` data location does not yet support reference types with nested dynamic arrays. They are cleared at the end of every `postAndVerifyBatch` via `delete`, recovering most of the gas cost via SSTORE-to-zero refunds.

#### EEZL2.sol (L2) — inherits `EEZBase`

L2-specific storage:

| Variable | Type | Notes |
|----------|------|-------|
| `executions` | ExecutionEntry[] | Persistent entries (single rollup — no per-rollup map needed) |
| `lookupCalls` | LookupCall[] | Persistent lookup calls |
| `lastLoadBlock` | uint256 | Block of last `loadExecutionTable` / `executeIncomingCrossChainCall` |
| `executionIndex` | uint256 | Cursor into `executions` |
| `_currentIncomingCall` | `uint256 transient` | 1-indexed global call counter and cursor into `entry.incomingCalls[]`; doubles as the `_insideExecution()` flag (`!= 0`) |
| `_lastOutgoingCallConsumed` | `uint256 transient` | Sequential reentrant (outgoing) call consumption cursor |

The shared rolling-hash transient fields, proxy registry, and base-event/error set are inherited from `EEZBase`.

`ROLLUP_ID` and `SYSTEM_ADDRESS` are immutables.

### A.3 Transient Variables and `_insideExecution`

`_insideExecution()` is `_currentL2ToL1Call != 0` on L1 and `_currentIncomingCall != 0` on L2. The first call processed inside an entry sets the cursor to 1 (and increments from there); the entry-completion path resets it to 0 so a subsequent top-level entry starts cleanly.

The transient variables are read by `executeCrossChainCall` (to route to `_consumeAndExecute` vs `_consumeNestedAction`) and by `staticCallLookup` (to compute the disambiguation key). They are reset implicitly between transactions by EIP-1153.

---

## B. Core Protocol Functions

### B.1 EEZ.sol (L1)

#### `registerRollup`

```solidity
function registerRollup(address rollupContract, bytes32 initialState)
    external returns (uint256 rollupId)
```

Permissionless. `rollupId = ++rollupCounter` (first assigned id is 1; 0 is `MAINNET_ROLLUP_ID`); `rollups[rollupId] = RollupConfig(rollupContract, initialState, 0)`. Reverts `InvalidRollupContract` if `rollupContract` is `address(0)` or the registry itself. Fires `IRollupContract(rollupContract).rollupContractRegistered(rollupId)` so the manager learns its id (one-shot init callback). The caller is expected to deploy their `IRollupContract`-conforming manager (with desired proofSystems / vkeys / threshold / ownership baked in) before calling `registerRollup`.

Emits `RollupCreated(rollupId, rollupContract, initialState)`.

#### `postAndVerifyBatch`

```solidity
function postAndVerifyBatch(ProofSystemBatchPerVerificationEntries calldata batch) external
```

Permissionless. A single `ProofSystemBatchPerVerificationEntries` struct (NOT an array) carries `entries[]`, `l1ToL2lookupCalls[]` (TOP-LEVEL lookups only — nested lookups travel inside their entries), `transientExecutionEntryCount`, `transientLookupCallCount`, `proofSystems[]` (sorted asc), `rollupIdsWithProofSystems[]` (strictly ascending by `rollupId`; each `RollupIdWithProofSystems` row pairs the rollupId with a strictly-ascending `proofSystemIndex[]` of indices into `proofSystems[]`), `blobIndices[]`, `callData`, `proofs[]` (one per PS), and `blockNumber` (uint64 — the single L1 block the whole batch binds to, forwarded to every rollup's `getCustomData(blockNumber)`; 0 = no block context). See `MULTI_PROVER_SPEC.md` for the multi-prover model — struct shape, per-PS public-inputs construction, and threshold enforcement.

**Preconditions** (enforced by `_validateStructure`):
- `_transientExecutions.length == 0` else `PostBatchReentry` (reentry guard).
- `proofSystems[]` sorted ascending, no duplicates, no zero address.
- `rollupIdsWithProofSystems[]` strictly ascending by `rollupId`, each `rollupId > MAINNET_ROLLUP_ID`, each registered.
- Each row's `proofSystemIndex[]` strictly ascending, all entries in range `[0, proofSystems.length)`.
- `transientExecutionEntryCount <= entries.length` else `TransientCountExceedsEntries`.
- `transientLookupCallCount <= l1ToL2lookupCalls.length` else `TransientLookupCallCountExceedsLookupCalls`.
- Each entry's `destinationRollupId` (and each lookup call's) is contained in the batch's rollup set else `RollupNotInBatch(rid)`.

**Per-PS public-inputs construction** (two-stage; see `MULTI_PROVER_SPEC.md` for details):

```
customDataAcc = bytes32(0)
for each rollup r in rollupIdsWithProofSystems (rollupId-ascending):
  customDataAcc = keccak256(abi.encode(customDataAcc, rollupId_r, customData_r))

sharedPublicInput = keccak256(abi.encodePacked(
    abi.encode(entryHashes),
    abi.encode(lookupCallHashes),
    abi.encode(blobHashes),
    keccak256(callData),
    customDataAcc
))

for each PS k in proofSystems:
  acc_k = bytes32(0)
  for each rollup r where k ∈ rollupIdsWithProofSystems[r].proofSystemIndex:
    acc_k = keccak256(abi.encode(acc_k, rollupId_r, vkMatrix[r][j]))
  publicInputsHash[k] = keccak256(abi.encodePacked(sharedPublicInput, acc_k))

entryHashes[i]      = keccak256(abi.encode(batch.entries[i]))
lookupCallHashes[i] = keccak256(abi.encode(batch.l1ToL2lookupCalls[i]))
```

`customData_r` is the opaque per-rollup blob fetched via `IRollupContract(rollupContract).getCustomData(batch.blockNumber)` (rollup-defined L1-view commitment; the reference `Rollup` returns ABI-encoded `(timestamp, blockHash)`). Each blob folds — keyed by `rollupId_r`, rollupId-ascending — into `customDataAcc`, which binds into `sharedPublicInput`. It does NOT vary per PS, so it is folded ONCE into the shared input rather than into each per-PS `acc_k`.

Each PS's `verify(proofs[k], publicInputsHash[k])` must return `true`. All proofs verify atomically — any failure reverts the whole call.

**State transitions** (in order, 8 steps; see `src/EEZ.sol:379-468`):

1. **Reentry check**: `if (_transientExecutions.length != 0) revert PostBatchReentry()`. There is no separate `_inPostBatch` flag.
2. **Structural validation** (`_validateStructure(batch)`, no external calls).
3. **Fetch + verify**: `_fetchVkMatrix(batch)` calls each rollup's manager via `IRollupContract.checkProofSystemsAndGetVkeys(subset)` (manager enforces threshold internally — reverts if not met) and returns one vkey per PS in the rollup's subset (length must equal the subset length, else `InvalidProofSystemConfig`). Then `_verifyProofSystemBatch(batch, vkMatrix)` computes the public inputs and calls `IProofSystem.verify(...)` for each PS.
4. **Mark verified-this-block** (`_markVerifiedBlockPerRollup(rid)` for each rollup): sets `verificationByRollup[rid].lastVerifiedBlock = block.number` AND **wipes the rollup's `executionQueue` / `lookupQueue` / `executionQueueIndex` on EVERY verify** — a same-block re-verify REPLACES (does not append to) the prior batch's entries for that rollup. Done before any non-view external CALL so (a) `executeCrossChainCall` / `executeL2TX(rid)` work during the meta hook, and (b) `setStateRoot` is locked out until the next block.
5. **Load transient stream** (`_loadTransientExecutions(batch)`): copy `entries[0..transientExecutionEntryCount)` into `_transientExecutions` and `l1ToL2lookupCalls[0..transientLookupCallCount)` into `_transientLookupCalls`.
6. **Drain leading immediate entries inline**: while the next transient entry has `proxyEntryHash == 0`, self-call `try this.attemptApplyImmediate(idx) catch { emit ImmediateEntrySkipped(idx, revertData); }` and advance — not a hard error.
7. **Meta hook**: if `_transientExecutionIndex < _transientExecutions.length` AND `msg.sender.code.length > 0`, call `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()`. The hook may invoke `executeCrossChainCall` and `executeL2TX(rid)` to consume the rest of the transient stream.
8. **Cleanup transient tables**: `delete _transientExecutions; delete _transientLookupCalls; _transientExecutionIndex = 0`. Then `_publishRemainderExecutions(batch)` — pushes `entries[transientExecutionEntryCount..]` into `verificationByRollup[entry.destinationRollupId].executionQueue` and `l1ToL2lookupCalls[transientLookupCallCount..]` into the matching `lookupQueue` **unconditionally** (even if the meta hook left transient entries unconsumed — there is no drain-cleanly gate). Finally, `emit BatchPosted(batch.rollupIdsWithProofSystems.length)`. Soundness backstop: each entry's `StateDelta.currentState` is checked at consumption time, so dropped transient leftover doesn't poison persistent consumers.

**Revert conditions**: `PostBatchReentry`, `TransientCountExceedsEntries`, `TransientLookupCallCountExceedsLookupCalls`, `RollupNotInBatch(rid)`, `InvalidProofSystemConfig`, `DuplicateProofSystem`, threshold/vkey reverts from the manager, `InvalidProof`, plus whatever the meta hook reverts with (`RollingHashMismatch`, `EtherDeltaMismatch`, `InsufficientRollupBalance`, `UnconsumedL2ToL1Calls`, `UnconsumedL1ToL2Calls`, `ExecutionNotFound`, `StateRootMismatch(rid)`, …; an *immediate* entry's revert is caught by `attemptApplyImmediate`'s try/catch and only skips that entry).

Note: same-block re-touch of a rollup is **permitted** — but `_markVerifiedBlockPerRollup` wipes the queue on every verify, so the second batch's entries REPLACE (not append to) the first batch's for that rollup. Safe because state only mutates at consumption and every entry is gated by `StateDelta.currentState`.

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
    _entryEtherIn += msg.value;   // reentrant: ADD to the entry's inbound-ether accumulator — §H.2
    return _consumeNestedAction(crossChainCallHash);
}
_entryEtherIn = msg.value;        // top-level: SET — a fresh entry can never inherit residue
return _consumeAndExecute(rollupId, crossChainCallHash);
```

`_consumeAndExecute` routes to the rollup's queue (`verificationByRollup[rollupId]`) — transient stream first if inside `postAndVerifyBatch`, otherwise the persistent per-rollup queue. On a miss (cursor out-of-bounds or `proxyEntryHash` mismatch), it falls back to `_tryRevertedTopLevelLookup(crossChainCallHash, destRid)`, which scans the transient lookup table then the per-rollup `lookupQueue` for a `failed` lookup matching `crossChainCallHash` with live state-root pins and resolves it via `_executeRevertedTopLevelLookup` (runs any sub-execution, then reverts with the cached `returnData`); only if that also misses does it revert `ExecutionNotFound`.

**Revert conditions**: `UnauthorizedProxy`, `ExecutionNotInCurrentBlock(rollupId)`, `ExecutionNotFound`, `RollingHashMismatch`, `UnconsumedL2ToL1Calls`, `UnconsumedL1ToL2Calls`, `EtherDeltaMismatch`, `InsufficientRollupBalance`, `StateRootMismatch(rollupId)`, `StaticCallWithValue` (a flat call flagged `isStatic` but carrying non-zero `value` — a STATICCALL cannot transfer ETH, so it is rejected rather than silently dropping the value), plus any revert from the destination call (which is captured into `_rollingHash` via `CALL_END`).

#### `executeL2TX`

```solidity
function executeL2TX(uint256 rollupId) external returns (bytes memory result)
```

Permissionless. Consumes the next entry on `rollupId`'s queue, which **must** have `proxyEntryHash == bytes32(0)`. Cannot run during an active execution.

```solidity
if (verificationByRollup[rollupId].lastVerifiedBlock != block.number) revert ExecutionNotInCurrentBlock(rollupId);
if (_insideExecution()) revert L2TXNotAllowedDuringExecution();
if (_entryEtherIn != 0) revert ResidualEntryEtherIn();   // non-payable + never mid-entry — dirty accumulator = bug
idx = _transientExecutions.length != 0 ? _transientExecutionIndex
                                       : verificationByRollup[rollupId].executionQueueIndex;
emit L2TXExecuted(rollupId, idx);   // transient phase emits the transient cursor
return _consumeAndExecute(rollupId, bytes32(0));
```

#### `staticCallLookup`

```solidity
function staticCallLookup(address sourceAddress, bytes calldata callData)
    external view returns (bytes memory)
```

Called via STATICCALL by `CrossChainProxy._fallback` when the proxy detects static context. Caller must be a registered proxy. Branches on `_insideExecution()`:

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

// NESTED (inside an execution): scan the active host's entry-scoped table by the live cursors.
if (_insideExecution()):
    callNum = uint64(_currentL2ToL1Call); lastNA = uint64(_lastL1ToL2CallConsumed);
    execIdx = _insideRevertedLookup ? uint64(_revertedLookupIndex + 1) : 0;
    for el in _getActiveLookups():        // entry.expectedLookups, or the executed top-level lookup's
        if 4-tuple (hash, callNum, lastNA, execIdx) matches:
            return _resolveStaticLookup(el.l2ToL1Calls, el.rollingHash, el.failed, el.returnData);
    revert ExecutionNotFound();

// TOP-LEVEL: transient pool first, then the routed rollup's persistent lookupQueue.
// Match = crossChainCallHash + every state-root pin equal to the live root (full scan —
// a non-matching candidate is skipped). `destinationRollupId` is enforced structurally
// (the scan targets verificationByRollup[rollupId].lookupQueue); the transient pool is
// not filtered by destination rollup.
for lc in _transientLookupCalls:
    if lc.crossChainCallHash == crossChainCallHash && _stateRootsMatch(lc):
        return _resolveStaticLookup(lc.l2ToL1Calls, lc.rollingHash, lc.failed, lc.returnData);
for lc in verificationByRollup[rollupId].lookupQueue:
    if (same match): return _resolveStaticLookup(...);
revert ExecutionNotFound();
```

`_resolveStaticLookup(calls, rollingHash, failed, returnData)` (shared by both branches):
- **Always** run the sub-calls via `_processNStaticCalls(calls)` (each via `sourceProxy.staticcall(executeOnBehalf(...))`) and check `computedHash == rollingHash` else `RollingHashMismatch` — an empty array hashes to `bytes32(0)`, which must match a sub-call-less lookup's `rollingHash`.
- If `failed`: revert with `returnData` (bubbles back to the proxy and out to the caller).
- Else return `returnData`.

`_stateRootsMatch(lc)` returns true iff every `lc.expectedStateRoots[i]` equals the live `rollups[rollupId].stateRoot` — part of the MATCH predicate, not a post-match check.

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
                   address(this),    // deployer = the manager (EEZ on L1, EEZL2 on L2)
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

**No manager-handoff path**: there is no `setRollupContract` and no `RollupContractChanged` event. A rollup's manager binding is set at registration time and is immutable thereafter (the one-shot `rollupContractRegistered` latch, `src/rollupContract/Rollup.sol:156`). To "migrate" off a manager, the orchestrator must register a new rollupId pointing at a new manager and migrate state out-of-band.

Per-rollup operations like `addProofSystem` / `removeProofSystem`, `updateVerificationKey`, `setThreshold`, `transferOwnership`, and any owner-driven `setStateRoot` initiation live on the manager itself. See `MULTI_PROVER_SPEC.md` and `src/rollupContract/Rollup.sol`.

#### View accessors

`verificationByRollup` is `internal`. Public accessors:

```solidity
function lastVerifiedBlock(uint256 _rollupId) external view returns (uint256);     // EEZ.sol:1329
function queueLength(uint256 _rollupId) external view returns (uint256);           // EEZ.sol:1335
function executionQueueIndex(uint256 _rollupId) external view returns (uint256);   // EEZ.sol:1340
```

#### Internal helpers

##### `_consumeAndExecute(uint256 rollupId, bytes32 crossChainCallHash) → bytes`

```
if (_transientExecutions.length != 0):
    idx = _transientExecutionIndex
    if (idx >= _transientExecutions.length
        || _transientExecutions[idx].proxyEntryHash != crossChainCallHash):
        _tryRevertedTopLevelLookup(crossChainCallHash, rollupId)   // reverts on a failed-lookup hit
        revert ExecutionNotFound
    _transientExecutionIndex = idx + 1                             // advance ONLY after the match
    entry = _transientExecutions[idx]
    _currentEntryRollupId = 0                                      // transient-phase marker
else:
    rec = verificationByRollup[rollupId]
    idx = rec.executionQueueIndex
    if (idx >= rec.executionQueue.length
        || rec.executionQueue[idx].proxyEntryHash != crossChainCallHash):
        _tryRevertedTopLevelLookup(crossChainCallHash, rollupId)
        revert ExecutionNotFound
    rec.executionQueueIndex = idx + 1                              // advance ONLY after the match
    entry = rec.executionQueue[idx]
    _currentEntryRollupId = rollupId

// NOTE: there is NO separate `entry.destinationRollupId == rollupId` check — the match on
// `proxyEntryHash` already binds the target rollup (it is in the hash preimage), and the
// proof bound `destinationRollupId` into the entry hash. See the `_consumeAndExecute`
// natspec in src/EEZ.sol.
emit ExecutionConsumed(crossChainCallHash, rollupId, idx)

_currentEntryIndex = idx
_applyAndExecute(entry.stateDeltas, entry.callCount, entry.rollingHash)

return entry.returnData
```

Inside an active `postAndVerifyBatch`, `_transientExecutions.length != 0` routes **all** consumption through the transient stream — running off the end falls back to `_tryRevertedTopLevelLookup` (top-level reverted-lookup scan), then `ExecutionNotFound`. Per-rollup queues are empty until step 8 of `postAndVerifyBatch`. Consumption forward-scans the stream to the first matching entry; a matched entry with `success == false` runs, verifies, then reverts with its `returnData` (rolling back the cursor advance), so it is re-callable and only drops out once a later successful consumption advances past it.

##### `_consumeNestedAction(bytes32 crossChainCallHash) → bytes`

**L1 (`EEZ`)** — pre-commit read; the cursor advances **only on a match**, and a no-match is a *deferred* revert (a transient flag, not an in-place `revert`):

```
expectedCalls = _activeNested()                // the entry's expectedL1ToL2Calls, or — while
                                               // executing a reverted lookup — that lookup's own table
idx           = _lastL1ToL2CallConsumed        // pre-commit read — NO bump here

// 1. ExpectedL1ToL2Call priority — the ONLY path that advances the cursor.
if (idx < expectedCalls.length
    && expectedCalls[idx].crossChainCallHash == crossChainCallHash):
    nested                  = expectedCalls[idx]
    _lastL1ToL2CallConsumed = idx + 1          // advance committed here, on match only
    nestedNumber            = idx + 1
    emit L1ToL2CallConsumed(_currentEntryIndex, nestedNumber, crossChainCallHash, nested.callCount)
    _rollingHash  = keccak256(abi.encodePacked(_rollingHash, NESTED_BEGIN, nestedNumber))
    _processNCalls(nested.callCount)
    _rollingHash  = keccak256(abi.encodePacked(_rollingHash, NESTED_END, nestedNumber))
    return nested.returnData

// 2. Fallback: failed=true NESTED lookup in the active host's `expectedLookups` table
//    (_getActiveLookups() — entry-scoped, no queue routing). Handles the try/catch case
//    (a reentrant call the caller expects to revert). Keyed by the un-advanced cursor
//    `idx`, the current `_currentL2ToL1Call`, and the execution context:
//      execIdx = _insideRevertedLookup ? _revertedLookupIndex + 1 : 0
//    A 4-tuple match calls _executeRevertedNestedLookup(i), which always reverts (it runs the
//    lookup's sub-execution as a mini-entry, then reverts with its returnData).

// 3. No match anywhere — DEFERRED revert (NOT an in-place revert):
emit L1ToL2CallNotFound(_currentEntryIndex, crossChainCallHash, _currentL2ToL1Call, idx)
_l1ToL2CallNotFound = true                     // bool transient, src/EEZ.sol
return ""                                       // entry reverts ExecutionNotFound at the boundary
```

L1 never advances the cursor before the routing decision, so there is no speculative bump to roll back. The no-match path returns empty bytes and sets `_l1ToL2CallNotFound`; the flag is checked at end-of-entry in `_applyAndExecute` (`if (_l1ToL2CallNotFound) revert ExecutionNotFound`) and is OR-merged out of a `revertSpan` self-call via the 4th `ContextResult` field, so a no-match observed inside a span still surfaces (`src/EEZ.sol:1018-1026`). Returning empty bytes may also revert the *caller's* frame sooner if it ABI-decodes a non-empty payload — the flag only guarantees the entry eventually reverts.

**L2 (`EEZL2`)** — the system-loaded table is trusted, so L2 uses the simpler **speculative-bump** form and reverts in place on a no-match (`src/L2/EEZL2.sol:322-358`):

```
idx = _lastOutgoingCallConsumed++              // speculative bump (rolls back on revert)
// 1. ExpectedOutgoingCrossChainCall priority (same as L1, but the ++ above is the commit).
// 2. Fallback: failed=true NESTED lookup in the active host's `expectedLookups`
//    (_getActiveLookups()), keyed by (crossChainCallHash, callNumber == _currentIncomingCall,
//    lastOutgoingCallConsumed == idx, executingLookupIndex == live execution context)
//    → _executeRevertedNestedLookup(i), which always reverts.
// 3. No match → revert ExecutionNotFound      (the ++ rolls back with the revert)
```

There is no deferred no-match flag on L2 — every fall-through path reverts, so the bump rolls back automatically.

##### `_tryRevertedTopLevelLookup(bytes32 crossChainCallHash, uint256 destRid)` (L1)

Called by `_consumeAndExecute` on a transient-table miss OR a persistent-queue miss — only reachable outside an execution (nested lookups live on the entry). Scans `_transientLookupCalls` then `verificationByRollup[destRid].lookupQueue` for a match where:

```
lc.failed             == true
lc.crossChainCallHash == crossChainCallHash
_stateRootsMatch(lc)                          // every state-root pin equals the live root
```

(`destinationRollupId` is enforced structurally — the scan targets `destRid`'s `lookupQueue`; a non-matching pin SKIPS the candidate, full-scan semantics.) On match, `_executeRevertedTopLevelLookup(lc, i)` runs any reverted-mode sub-execution and reverts with `lc.returnData` (no cursor advance). On no match, returns control to `_consumeAndExecute` which reverts `ExecutionNotFound`.

The L2 variant is `_tryRevertedTopLevelLookup(bytes32 crossChainCallHash)` (no `destRid` — single rollup) and scans only persistent `lookupCalls` (no transient table on L2), matched by `crossChainCallHash` alone.

`_getCurrentEntryStoragePointer()` returns `_transientExecutions[_currentEntryIndex]` if `_transientExecutions.length != 0`, else `verificationByRollup[_currentEntryRollupId].executionQueue[_currentEntryIndex]`.

##### `_applyAndExecute(StateDelta[] memory deltas, uint256 callCount, bytes32 rollingHash)`

`_entryEtherIn` already holds the entry-point call's `msg.value` here (SET by the top-level entry point — `executeCrossChainCall` / `executeL2TX` / `attemptApplyImmediate` — before consumption), so it is NOT reset in the preamble — only at the end, after the invariant check.

```
_rollingHash = bytes32(0)
_currentL2ToL1Call = 0
_lastL1ToL2CallConsumed = 0

etherOut          = _processNCalls(callCount)
totalEtherDelta   = _applyStateDeltas(deltas)

entry = _getCurrentEntryStoragePointer()
require(!_l1ToL2CallNotFound)                                                // ExecutionNotFound (deferred no-match)
require(_rollingHash == rollingHash)                                         // RollingHashMismatch
require(_currentL2ToL1Call == entry.l2ToL1Calls.length)                      // UnconsumedL2ToL1Calls
require(_lastL1ToL2CallConsumed == entry.expectedL1ToL2Calls.length)         // UnconsumedL1ToL2Calls
require(totalEtherDelta == _entryEtherIn - etherOut)                         // EtherDeltaMismatch

emit EntryExecuted(_currentEntryIndex, _rollingHash, _currentL2ToL1Call, _lastL1ToL2CallConsumed)
_currentL2ToL1Call = 0   // reset so _insideExecution() returns false again
_entryEtherIn = 0        // reset for the next top-level entry in this tx
```

##### `_processNCalls(uint256 count) → int256 etherOut`

Iterates `count` steps over the active flat-call array `_activeCalls()` — the entry's `l2ToL1Calls[]`, or the reverted lookup's while one is executing — starting at `_currentL2ToL1Call`. For each step:

- If `revertSpan == 0`: load the call, increment `_currentL2ToL1Call`, hash `CALL_BEGIN`, derive `sourceProxy` (auto-create if missing), call `CrossChainProxy.executeOnBehalf` through it, hash `CALL_END(success, retData)`, emit `CallResult`. Add `cc.value` to `etherOut` only if `success && cc.value > 0`. Increment `processed` by 1.
- If `revertSpan > 0`: clear the field in storage, save `_currentL2ToL1Call`, `try this.executeInContextAndRevert(revertSpan)`. Always reverts with `ContextResult`; decode and restore `_rollingHash`, `_lastL1ToL2CallConsumed`, `_currentL2ToL1Call` from the payload (and OR-merge the no-match flag). Restore `calls[savedCallNumber].revertSpan = revertSpan`. Emit `RevertSpanExecuted`. Increment `processed` by `revertSpan`.

The same global cursor `_currentL2ToL1Call` is advanced both by entry-level iterations and by nested-action iterations — `_processNCalls` is reused recursively from `_consumeNestedAction`. (L2's variant is identical but returns nothing — no ether accounting — and uses `_currentIncomingCall` over `incomingCalls[]`.)

##### `executeInContextAndRevert(uint256 callCount) external`

```
require(msg.sender == address(this))       // NotSelf
_processNCalls(callCount)
revert ContextResult(_rollingHash, _lastL1ToL2CallConsumed, _currentL2ToL1Call, _l1ToL2CallNotFound)
```

(L2's variant passes `false` for the 4th field — it has no deferred no-match flag, `src/L2/EEZL2.sol:415-420`.)

The unconditional revert rolls back all transient writes inside the self-call, but the `ContextResult` payload escapes via the revert data — `_processNCalls`'s caller decodes it and restores the rolling hash, the two counters, and (L1) OR-merges the no-match flag. Storage changes inside the span (e.g., destination state on L1) are also rolled back by the EVM revert; the rolling hash, counters, and flag survive only because the payload re-applies them after the catch.

##### `_decodeContextResult(bytes memory revertData) → (bytes32, uint256, uint256, bool)`

Defined on `EEZBase` with direction-neutral names. Verifies `bytes4(revertData) == ContextResult.selector` AND `revertData.length >= 132` (4 + 4×32) else `UnexpectedContextRevert(revertData)`; then assembly-loads four words at offsets 36, 68, 100, 132 (`rollingHash`, `reentrantConsumed`, `callsProcessed`, `callNotFound`).

##### `_applyStateDeltas(StateDelta[] memory deltas) → int256 totalEtherDelta`

For each delta:
- `if (rollups[delta.rollupId].stateRoot != delta.currentState) revert StateRootMismatch(delta.rollupId)` — the per-rollup-queue soundness backstop.
- `rollups[delta.rollupId].stateRoot = delta.newState`.
- Accumulate `delta.etherDelta` into `totalEtherDelta`.
- If `delta.etherDelta < 0`: `etherBalance -= |delta|` (revert `InsufficientRollupBalance` on underflow).
- If `delta.etherDelta > 0`: `etherBalance += delta`.
- Emit `L2ExecutionPerformed(rollupId, newState)`.

##### `_processNStaticCalls(L2ToL1Call[] memory calls) → bytes32`

```
hash = bytes32(0)
for cc in calls:
    sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId)
    if (sourceProxy.code.length == 0) revert LookupCallProxyNotDeployed(sourceProxy)
    (success, retData) = sourceProxy.staticcall(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)))
    hash = keccak256(abi.encodePacked(hash, success, retData))
return hash
```

No `revertSpan` handling — every call executes as-is. Static context cannot deploy proxies, so all referenced proxies must already exist; a codeless proxy reverts `LookupCallProxyNotDeployed` (a STATICCALL to a codeless address silently succeeds, which the prover could otherwise pre-hash as a no-op).

This hashing scheme is **intentionally untagged** and is **distinct from** the entry-level rolling hash described in §E (no `CALL_BEGIN`/`CALL_END`/`NESTED_BEGIN`/`NESTED_END` tags, no call number). It is verified against the lookup's own `rollingHash`, a separate per-lookup accumulator whose context is already pinned: nested lookups by their 4-tuple key within the entry, top-level lookups by the structural queue routing plus the state-root pins. See §E.2 for the full rationale.

##### `_executeRevertedNestedLookup(uint256 index)` / `_executeRevertedTopLevelLookup(LookupCall storage sc, uint256 index)` — always revert

Execute a reverted (`failed = true`) lookup as a self-contained mini-entry, then revert with its cached `returnData`. Setup differs per kind, the shared tail is `_executeRevertedLookup`:

- **Nested** (`_getActiveLookups()[index]`): set `_revertedLookupIndex = index` and `_insideRevertedLookup = true` — the `ExpectedLookup` at that index supplies the sub-execution's flat calls and reentrant table.
- **Top-level** (pool lookup): set `_topLevelLookupIndex = index`, `_revertedLookupRollupId = sc.destinationRollupId` (L1), and `_revertedLookupTopLevel = true` — the pool lookup becomes the active HOST, supplying flat calls, reentrant table, AND its own `expectedLookups` for nested lookups observed inside the sub-execution (`_currentTopLevelLookup` re-derives the pool from `_transientExecutions.length`).

`_executeRevertedLookup` then resets `_rollingHash` and both cursors to a fresh sub-execution context, runs `_processNCalls(callCount)` (reentrant calls consume the sub-execution's reentrant table via `_consumeNestedAction`; deeper lookups resolve from the active host table), applies entry-style end checks (`RollingHashMismatch` / `UnconsumedL2ToL1Calls` / `UnconsumedL1ToL2Calls`), then reverts with `returnData`. The terminal revert discards the sub-call state AND restores the outer cursors (every `tstore` rolls back), so no `ContextResult` escape is needed. A plain reverted lookup with no sub-execution is just the `callCount == 0` case. The L2 variants are identical minus the rollup routing.

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

Each entry's contribution is `keccak256(abi.encode(entry))` — the FULL `ExecutionEntry` struct, including `stateDeltas` (which carry the entry's `currentState` precondition), `proxyEntryHash`, `destinationRollupId`, `l2ToL1Calls`, `expectedL1ToL2Calls`, `expectedLookups`, `callCount`, `returnData`, and `rollingHash`. Same for top-level lookups (`keccak256(abi.encode(lookupCall))`). See `MULTI_PROVER_SPEC.md` for the full per-PS public-inputs construction.

##### Per-PS verify (inlined in `_verifyProofSystemBatch`)

There is no standalone `_verifyProof` function — each PS is verified inline at the end of the per-PS loop in `_verifyProofSystemBatch`:

```solidity
if (!IProofSystem(batch.proofSystems[k]).verify(batch.proofs[k], publicInputsHash)) revert InvalidProof();
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

`onlySystemAddress` reverts `Unauthorized` for any other caller. The L2 `ExecutionEntry` struct has no `destinationRollupId` and no `stateDeltas` (see §A.1 — `IEEZL2.sol`).

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

System-only top-level delivery path for an inbound cross-chain call from another rollup (`src/L2/EEZL2.sol:221-278`). Behavior:

1. Revert `EmptyEntries` if `entries.length == 0`.
2. Revert `ValueMismatch` if `msg.value != value` (strict equality — the system mints exactly the call's `value`).
3. `_loadExecutionTable(entries, _lookupCalls)` — atomically replaces the execution table.
4. `crossChainCallHash = computeCrossChainCallHash(ROLLUP_ID, destination, value, data, sourceAddress, sourceRollup)`; emit `IncomingCrossChainCallExecuted(crossChainCallHash, destination, value, data, sourceAddress, sourceRollup)`.
5. Revert `EntryHashMismatch` if `executions[0].proxyEntryHash != crossChainCallHash` (binds the emitted call hash to the entry, mirroring L1's `_consumeAndExecute` match).
6. Drive `executions[0]` through `_processNCalls(executions[0].callCount)` (entries[0]'s `incomingCalls[0]` is the inbound call itself). The system's `msg.value` lives in the manager and is drained as `_processNCalls` forwards through the source proxy.
7. Standard post-checks: `RollingHashMismatch`, `UnconsumedIncomingCalls`, `UnconsumedOutgoingCalls` (same invariants as `_consumeAndExecute`).
8. `executionIndex = 1` — advance past `entries[0]` so follow-up `executeCrossChainCall`s don't re-consume it. Emit `EntryExecuted(0, ...)`, reset `_currentIncomingCall = 0`, and return `executions[0].returnData`.

#### `executeCrossChainCall` (L2 variant)

Same as L1, with two differences:

1. **`sourceRollupId`** in the action hash is `ROLLUP_ID` (this L2's ID), not `MAINNET_ROLLUP_ID`.
2. **ETH burn**: if `msg.value > 0`, the L2 manager forwards it to `SYSTEM_ADDRESS` immediately. Failure of the transfer reverts `EtherTransferFailed`.

L2's `_consumeAndExecute` reads from `executions` only — there is no transient table and no per-rollup queue map. On a miss (cursor out-of-bounds or `proxyEntryHash` mismatch), it falls back to `_tryRevertedTopLevelLookup(crossChainCallHash)` (no `destRid` arg — single rollup), which scans `lookupCalls` for a `failed` lookup matching `crossChainCallHash` and resolves a match via `_executeRevertedTopLevelLookup` (reverts with the cached `returnData`). Only if that also misses does it revert `ExecutionNotFound`.

#### Top-level call delivery on L2

Top-level calls on L2 arrive via two paths:

1. **User txs hitting proxies** → `executeCrossChainCall`.
2. **`SYSTEM_ADDRESS` → `executeIncomingCrossChainCall`** for inbound cross-chain calls from another rollup.

There is no `executeL2TX` on L2 — that mechanism lives on L1 and handles the L1-side commit of L2 user actions.

#### `staticCallLookup` (L2)

Same shape as L1: inside an execution it scans the active host's `expectedLookups` by `(crossChainCallHash, callNumber, lastOutgoingCallConsumed, executingLookupIndex)`; outside it scans the persistent `lookupCalls` pool (no transient table) matched by `crossChainCallHash` alone — the L2 top-level `LookupCall` has no `destinationRollupId` and no `expectedStateRoots` (single rollup, no state roots). `sourceRollupId` in the action hash is `ROLLUP_ID`.

#### `createCrossChainProxy` / `computeCrossChainProxyAddress`

Inherited from `EEZBase`. Identical formula on both L1 and L2.

### B.3 CrossChainProxy.sol

```solidity
constructor(address _eez, address _originalAddress, uint256 _originalRollupId)
```

Three immutables: `EEZ`, `ORIGINAL_ADDRESS`, `ORIGINAL_ROLLUP_ID` (`src/base/CrossChainProxy.sol:13-32`). The `EEZ` immutable holds the manager address (L1 `EEZ` or L2 `EEZL2`); the proxy is constructed by `EEZBase._createCrossChainProxyInternal` (reached via the external `createCrossChainProxy` or auto-creation in `_processNCalls`).

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
    (success, result) = EEZ.staticcall(abi.encodeCall(IEEZ.staticCallLookup, (msg.sender, msg.data)))
else:
    // Normal context — execute cross-chain call
    (success, result) = EEZ.call{value: msg.value}(abi.encodeCall(IEEZ.executeCrossChainCall, (msg.sender, msg.data)))

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

Same as L1, with `sourceRollupId = ROLLUP_ID` (this L2's rollup ID) and `targetRollupId = proxyInfo.originalRollupId` (the proxied counterparty's rollup — L1 or another L2).

### C.3 Hash from `staticCallLookup`

Same as the corresponding `executeCrossChainCall`, with `value = 0` (STATICCALL cannot carry ETH). The values that disambiguate phases — `l2ToL1CallNumber` / `lastL1ToL2CallConsumed` / `executingLookupIndex` on L1, `callNumber` / `lastOutgoingCallConsumed` / `executingLookupIndex` on L2 — are part of the nested `ExpectedLookup` struct, not part of the action hash (top-level `LookupCall`s carry no cursor key).

### C.4 Hash for nested actions

Identical to the proxy that triggered the reentrant call. The protocol does not distinguish "top-level" vs "reentrant" in the hash itself; the routing decision (`_consumeAndExecute` vs `_consumeNestedAction`) is made at runtime via `_insideExecution()`.

### C.5 No `crossChainCallHash` for L2TX entries

`executeL2TX(rollupId)` requires `entry.proxyEntryHash == bytes32(0)`. There is no separate L2TX hash — the entry is identified by being the next entry on the rollup's queue.

---

## D. Execution Model

### D.1 Sequential Entry Consumption

Entries in `verificationByRollup[rid].executionQueue` (or `_transientExecutions` during `postAndVerifyBatch`) are consumed in posted order via the rollup's `executionQueueIndex` (or the global `_transientExecutionIndex` during the transient phase). Each call to `executeCrossChainCall` (top-level), `executeL2TX(rollupId)`, or — during `postAndVerifyBatch`'s meta hook — both, increments the active cursor by exactly one (the rollup's `executionQueueIndex`, or the global `_transientExecutionIndex` while the transient table is non-empty — per-rollup cursors stay untouched during the transient phase). There is no hash-based search and no swap-and-pop.

`_consumeAndExecute` checks `entry.proxyEntryHash == expectedHash` and reverts `ExecutionNotFound` on mismatch (there is no separate `entry.destinationRollupId == rollupId` check — the target rollup is already bound into the hash preimage and into the proof's entry hash). This catches out-of-order calls from a buggy hook, a wrong builder, or a routing mismatch.

Cross-rollup independence: a stuck cursor on one rollup does not block consumption on another — each rollup's queue advances on its own.

### D.2 Flat Call Processing

Within an entry, calls live in a single flat array (`l2ToL1Calls[]` on L1, `incomingCalls[]` on L2) and are processed by a non-recursive `while` loop in `_processNCalls`. Each iteration reads `entry.l2ToL1Calls[_currentL2ToL1Call]`, increments the cursor (or self-calls `executeInContextAndRevert` for revert spans), and continues until `processed == count`.

Reentrant calls share the same `entry.l2ToL1Calls[]` and the same `_currentL2ToL1Call` cursor — they recurse into `_processNCalls(nested.callCount)` from inside `_consumeNestedAction`, but the loop itself does not branch through the action data.

The total call accounting at the end of the entry (L1 names; L2 mirrors with `incomingCalls` / `expectedOutgoingCalls` / `UnconsumedIncomingCalls` / `UnconsumedOutgoingCalls`):

```
_currentL2ToL1Call      == entry.l2ToL1Calls.length          // UnconsumedL2ToL1Calls
_lastL1ToL2CallConsumed == entry.expectedL1ToL2Calls.length  // UnconsumedL1ToL2Calls
```

The sum of `entry.callCount` plus all `expectedL1ToL2Calls[i].callCount`s **must** equal `entry.l2ToL1Calls.length`. This is not enforced as a separate check; it falls out of the two equalities above plus the sequential cursor advance.

### D.3 Reentrant Calls (ExpectedL1ToL2Call or failed nested ExpectedLookup)

When the destination contract called by `_processNCalls` calls back into a proxy, the proxy forwards to `executeCrossChainCall`. Inside that call, `_insideExecution() == true` (the global counter is non-zero), so the path branches to `_consumeNestedAction`. The cursor-advance discipline differs by chain — **L1 reads the cursor without bumping and advances only on a match; L2 speculatively bumps up front (`idx = _lastOutgoingCallConsumed++`)** — but both route the same way (let `idx` be the pre-advance cursor; L1 names below, L2 mirrors with `expectedOutgoingCalls` etc.):

**1. ExpectedL1ToL2Call priority.** If `expectedL1ToL2Calls[idx].crossChainCallHash == crossChainCallHash` (against `_activeNested()` — the entry's table, or the reverted lookup's while one is executing):
   1. Commit the advance: L1 writes `_lastL1ToL2CallConsumed = idx + 1`; L2's earlier `++` already did it.
   2. Emit `L1ToL2CallConsumed` (L2: `OutgoingCallConsumed`) and hash `NESTED_BEGIN` into `_rollingHash`.
   3. Recurse into `_processNCalls(nested.callCount)`. Inside that call, `entry.l2ToL1Calls[]` is read at positions starting from the current `_currentL2ToL1Call`.
   4. Hash `NESTED_END` into `_rollingHash`.
   5. Return `nested.returnData` to the destination.

**2. Otherwise — fall back to a reverted NESTED lookup.** Scan the active host's entry-scoped table (`_getActiveLookups()` — the entry's `expectedLookups[]`, or the executed top-level lookup's) for an `ExpectedLookup` with `failed == true` and matching 4-tuple key `(crossChainCallHash, _currentL2ToL1Call, idx, executingLookupIndex)` — the lookup uses `idx`, the cursor value the prover observed, and `executingLookupIndex` must equal the live execution context (`_insideRevertedLookup ? _revertedLookupIndex + 1 : 0`):
   - Hit → `_executeRevertedNestedLookup(i)` runs the lookup's own sub-execution as a mini-entry (real calls over `el.l2ToL1Calls[]`, reentry from `el.expectedL1ToL2Calls[]`, tagged rolling-hash schema, entry-style end checks via `_executeRevertedLookup`), then reverts with `el.returnData`. The destination's `try/catch` absorbs the revert. A sub-execution-less lookup is just the `callCount == 0` case.
   - No hit → **L1**: set `_l1ToL2CallNotFound`, emit `L1ToL2CallNotFound`, return `""` (the entry reverts `ExecutionNotFound` later, at the `_applyAndExecute` boundary). **L2**: `revert ExecutionNotFound` in place.

**Why this works for reverts.** On L1 the cursor never advances before the routing decision, so a no-match leaves it untouched and the deferred `_l1ToL2CallNotFound` flag forces the entry to revert at its boundary; on L2 every fall-through path reverts, so the speculative `++` rolls back automatically (transient storage follows EVM revert rules). Either way the cursors and `_rollingHash` outside the destination's `try/catch` reflect exactly what the prover simulated. A reverting reentrant call therefore needs **only** an `ExpectedLookup` with `failed=true` inside the entry — no companion `ExpectedL1ToL2Call`, no `revertSpan` wrapper.

**Why a `failed=false` nested lookup here is invalid.** A successful reentrant call in a normal CALL frame is expressed as an `ExpectedL1ToL2Call`; a successful read-only call is in a STATICCALL frame and routed to `staticCallLookup` (§F) instead. A `failed=false` nested lookup matching this fallback path is a prover bug — the loop simply doesn't match it, so it falls through to `ExecutionNotFound`.

#### D.3.1 Nested children must be laid out after their parent (forward-cursor layout)

Reentrant entries in `expectedL1ToL2Calls[]` are content-addressed by `(crossChainCallHash, expectedRollingHash)` and located by a **strict forward scan** from `_lastL1ToL2CallConsumed`: a call only ever matches an entry at or after the cursor, never one before it. The match is the rolling hash, not the array position — but the cursor governs *which slice of the table is still visible*.

When a reentrant entry at index `i` is resolved (`_resolveNestedReentrant`), the cursor is advanced to `i + 1` **before** the entry's own sub-calls run, not after. This keeps the cursor monotonic: any reentrant call the sub-frame fires scans strictly forward from `i + 1`, and a successful frame leaves the cursor at its high-water mark with no restore step. (On revert the whole frame's writes — including this advance — roll back with the EVM, so the cursor returns to the parent's value automatically.)

**Layout rule for provers/builders.** A nested frame's own reentrant children must be placed in `expectedL1ToL2Calls[]` at indices **strictly greater than their parent entry's index** — i.e. the table must be in depth-first / execution order. A child placed at an index `≤` its parent is below the cursor when the sub-frame scans, so it is never found: the reentrant call folds `CALL_NOT_FOUND` into the rolling hash and the entry reverts at its boundary (`RollingHashMismatch` / `ExecutionNotFound`). This is purely a *findability* constraint; it never produces a wrong match, because the rolling-hash key is unique per call position. Sibling entries at the same nesting level are already forward-ordered by the same cursor discipline.

### D.4 Revert Span

`revertSpan > 0` opens an isolated EVM context for the next `revertSpan` calls. Mechanism:

1. Caller saves `_currentL2ToL1Call` and `entry.l2ToL1Calls[saved].revertSpan`, then sets `entry.l2ToL1Calls[saved].revertSpan = 0` in storage so the inner self-call sees the call as normal at the same index.
2. `try this.executeInContextAndRevert(revertSpan)`. The inner call:
   - Runs `_processNCalls(revertSpan)`, which advances `_currentL2ToL1Call`, `_lastL1ToL2CallConsumed`, and `_rollingHash` based on the calls inside the span.
   - **Always** reverts with `ContextResult(_rollingHash, _lastL1ToL2CallConsumed, _currentL2ToL1Call, _l1ToL2CallNotFound)` (L2 passes `false` for the 4th field).
3. The EVM revert rolls back all storage and transient state inside the self-call. The four values escape via the revert data.
4. Caller decodes `ContextResult` and writes the rolling hash and the two counters back into transient storage, and (L1) OR-merges the no-match flag so a no-match observed inside the span still reverts the entry. The rolling hash and cursors now reflect what happened inside the span, even though the EVM rolled the state back.
5. Caller restores `entry.l2ToL1Calls[saved].revertSpan = revertSpan` and emits `RevertSpanExecuted`. `processed += revertSpan`.

A single mechanism handles atomic rollback: there are no continuation entries, no per-rollup state-root restoration, no scope tree to navigate. The "what happened" is encoded by the calls in the span; the "what state survives" is whatever the EVM rolled back.

#### D.4.1 When to use `revertSpan` (and when not to)

**Use `revertSpan > 0` only for forced reverts** — calls (or sequences of calls) that *would* succeed against the destination but whose state effects must not survive. The canonical scenario is a cross-chain call from rollup A to rollup B where the destination on B succeeds, but the prover output for the sub-executioning side records that the call must be rolled back (for example, because the higher-level transaction that contained the call was reverted on A). The rolling hash still commits to a `CALL_END(success=true, retData=…)` outcome — what was promised — while the EVM rolls the state back.

**Do not use `revertSpan` to model a destination that naturally reverts.** With `revertSpan = 0`, `_processNCalls` already invokes the destination via the proxy's `.call`, captures `(success=false, retData=revertReason)`, and hashes that into `CALL_END`. The destination's own revert rolls back its own state. Wrapping a single naturally-reverting call in `revertSpan = 1` produces the same observable rolling hash and the same on-chain state as `revertSpan = 0` — it adds a self-call frame for no benefit. The mechanism only earns its keep when state would otherwise survive.

The three revert paths in the protocol are distinct — pick the one that matches the situation:

| Situation | Path |
|---|---|
| Top-level cross-chain call that naturally reverts | Top-level `LookupCall` with `failed = true` in the storage pool, executed via `_tryRevertedTopLevelLookup` (or resolved via `staticCallLookup` outside an execution). (Or, when the call lives inside `l2ToL1Calls[]`, place it with `revertSpan = 0` and let `CALL_END(false, retData)` capture it.) |
| **Reentrant** cross-chain call that reverts (caller wraps it in `try/catch`) | Nested `ExpectedLookup` with `failed = true` inside the entry — *not* `revertSpan`, *not* `ExpectedL1ToL2Call`. See §D.3 / §F.4 |
| Successful call(s) whose state must be force-reverted | `revertSpan > 0` on the first call of the span |

The reentrant-revert case **must not** use `revertSpan`: the destination's `try/catch` already provides the isolation boundary, the nested-lookup fallback in `_consumeNestedAction` runs the cached revert without advancing the consumption cursor, and the EVM revert from the caught failure has nothing to roll back. Wrapping it in `revertSpan` would consume an entry-level call slot the prover did not allocate.

### D.5 Flat Call Model

The off-chain prover emits a flat `l2ToL1Calls[]` array plus a parallel `ExpectedL1ToL2Call[]` table (L2: `incomingCalls[]` / `ExpectedOutgoingCrossChainCall[]`) — it does not thread scope arrays through nested calls. Return data from a call is captured directly into the rolling hash via `CALL_END`; reverts of natural failures are captured via `success=false` in the same `CALL_END` tag. `revertSpan` is reserved for forced-revert spans where state must be rolled back even though the call(s) succeeded.

---

## E. Rolling Hash

A single `bytes32 rollingHash` per entry covers every call result and every nesting boundary. The four tag constants and the fold helpers (`_rollingHashCallBegin` / `_rollingHashCallEnd` / `_rollingHashNestedBegin` / `_rollingHashNestedEnd`) live on `EEZBase` and are **protocol constants shared by both chains** — the `CALL_*` / `NESTED_*` tags are the neutral rolling-hash frame vocabulary, not a direction. The accumulator starts at `bytes32(0)` and is updated at four tagged events:

```
CALL_BEGIN     = uint8(1)   _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_BEGIN,     callNumber))
CALL_END       = uint8(2)   _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_END,       callNumber, success, retData))
NESTED_BEGIN   = uint8(3)   _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_BEGIN,   nestedNumber))
NESTED_END     = uint8(4)   _rollingHash = keccak256(abi.encodePacked(_rollingHash, NESTED_END,     nestedNumber))
CALL_NOT_FOUND = uint8(5)   _rollingHash = keccak256(abi.encodePacked(_rollingHash, CALL_NOT_FOUND, crossChainCallHash))
```

`callNumber` is the per-side global call cursor (`_currentL2ToL1Call` on L1, `_currentIncomingCall` on L2) — 1-indexed and incremented before `CALL_BEGIN` is hashed. `nestedNumber` is the reentrant cursor (`_lastL1ToL2CallConsumed` / `_lastOutgoingCallConsumed`) after the advance that consumed the reentrant call — also 1-indexed.

`CALL_NOT_FOUND` is folded (L1) when a reentrant call finds no matching expected entry in `expectedL1ToL2Calls`. The dedicated tag is distinct from `CALL_END(true, "")` (what the caller folds for a normal empty return), so a no-match can never be forged as one. The divergence is caught at the entry's rolling-hash check (surviving any intermediate try/catch and riding the `ContextResult` payload across a revert-span boundary), so no side flag is needed; a prover that deliberately pre-hashes the tag commits to a not-found at that exact position — a faithful outcome, not an attack.

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

- `tload` is **read-only**, so it works inside a STATICCALL context **and** inside a self-call that is about to revert. The inner self-call therefore observes the outer `_rollingHash` and call-cursor values when it starts.
- `tstore` writes are part of the EVM journal and are **rolled back** when the call frame reverts. So when `executeInContextAndRevert` reverts with `ContextResult`, every transient write performed inside the span (including the rolling-hash updates and counter increments) is undone — except for the values that escape via the revert payload (the rolling hash, the two counters, and L1's `_l1ToL2CallNotFound` flag), which the caller manually re-applies after decoding.

### E.2 Lookup Sub-Hash (`rollingHash` on `ExpectedLookup` / `LookupCall`)

Every lookup carries its own `rollingHash` — **a separate accumulator**, scoped to that lookup and computed over its optional sub-call array (`l2ToL1Calls[]` on L1, `incomingCalls[]` on L2). It is **not** the entry-level `_rollingHash`. Which schema applies depends on the lookup's mode:

- **Static mode (`staticCallLookup` → `_resolveStaticLookup`)** — a deliberately simpler, **untagged** scheme computed by `_processNStaticCalls`:

```
hash = bytes32(0)
for cc in lookupCall.l2ToL1Calls:
    sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId)
    (success, retData) = sourceProxy.staticcall(executeOnBehalf(cc.targetAddress, cc.data))
    hash = keccak256(abi.encodePacked(hash, success, retData))
require(hash == lookupCall.rollingHash);   // RollingHashMismatch
```

- **Reverted mode (`_executeRevertedNestedLookup` / `_executeRevertedTopLevelLookup`)** — the sub-execution runs as real calls and is folded with the **tagged entry schema** (`CALL_*` / `NESTED_*`, same as §E), then checked against the lookup's `rollingHash` with entry-style end checks. Reverted-mode sub-calls may host reentry (`expectedL1ToL2Calls`) and `revertSpan`.

The static-mode differences from the entry-level scheme:

- **No event tags** (no `CALL_BEGIN` / `CALL_END` / `NESTED_BEGIN` / `NESTED_END` domain bytes).
- **No call number** mixed into each fold.
- **No nesting** at all — `_processNStaticCalls` does not handle reentrancy; STATICCALL forbids state writes, so the proxies' `executeOnBehalf` paths cannot reenter the manager's mutating entrypoints and consume nested actions or further lookup calls.

This simpler schema is safe because the surrounding lookup key already pins the call context that tagged events disambiguate at entry level. A NESTED lookup is content-addressed within its entry by the compared 4-tuple:

```
(crossChainCallHash, l2ToL1CallNumber, lastL1ToL2CallConsumed, executingLookupIndex)   // L1
(crossChainCallHash, callNumber, lastOutgoingCallConsumed, executingLookupIndex)       // L2
```

and a TOP-LEVEL lookup by `crossChainCallHash` + the structural queue routing + (L1) the `expectedStateRoots[]` pins — so the entry/call/nesting position is already locked in. The only thing left for a static lookup's `rollingHash` to commit to is the **outcome of the static sub-calls**, in order, which is exactly what the untagged `keccak256(prev, success, retData)` chain captures. There is also no cross-contamination risk with the entry-level accumulator: `_processNStaticCalls` returns a local `computedHash` and never reads or writes `_rollingHash`.

The two accumulators serve different verification scopes and intentionally do not share a schema. Static-mode lookup sub-calls are flat by construction; only reverted-mode runs carry richer structure, and those use the tagged schema for exactly that reason.

### E.3 Worked Hash Chain Example

Setup (L1 names; the L2 chain is identical with `incomingCalls` / `expectedOutgoingCalls` / `_currentIncomingCall` / `_lastOutgoingCallConsumed`):

```
entry.l2ToL1Calls    = [c0, c1, c2, c3, c4]
entry.callCount      = 3
entry.expectedL1ToL2Calls  = [ { crossChainCallHash = H_nested, callCount = 2, returnData = 0xaa } ]
entry.rollingHash    = <expected final hash>
```

The entry has 5 calls in the flat array. Entry-level processes 3 iterations: c0, c3, c4. While c0 is executing, the destination contract calls back into a proxy, which consumes `expectedL1ToL2Calls[0]`; that reentrant frame processes c1 and c2.

Step-by-step:

```
Initial transient state:
  _rollingHash             = 0x0
  _currentL2ToL1Call       = 0
  _lastL1ToL2CallConsumed  = 0

─── Entry-level _processNCalls(3), iteration 0 ─────────────

  Read entry.l2ToL1Calls[0] = c0
  _currentL2ToL1Call++ → 1
  hash CALL_BEGIN(callNum=1):
    _rollingHash = keccak256(0x0, uint8(1), uint256(1))                                    → H1

  Execute c0 via the source proxy. During c0, the destination contract calls back
  into a proxy on this chain → executeCrossChainCall → _insideExecution() == true
  → _consumeNestedAction(H_nested):

      idx = _lastL1ToL2CallConsumed → idx=0     (L1 pre-commit read, no bump yet)
      require(expectedL1ToL2Calls[0].crossChainCallHash == H_nested)
      _lastL1ToL2CallConsumed = idx + 1 → 1     (advance committed on match)
      nestedNumber = idx + 1 = 1

      hash NESTED_BEGIN(nestedNum=1):
        _rollingHash = keccak256(H1, uint8(3), uint256(1))                                 → H2

      _processNCalls(2):  // reentrant frame's callCount

        Read entry.l2ToL1Calls[1] = c1
        _currentL2ToL1Call++ → 2
        hash CALL_BEGIN(callNum=2):
          _rollingHash = keccak256(H2, uint8(1), uint256(2))                               → H3
        Execute c1 via the source proxy. Succeeds with retData_1.
        hash CALL_END(callNum=2, success=true, retData_1):
          _rollingHash = keccak256(H3, uint8(2), uint256(2), true, retData_1)              → H4

        Read entry.l2ToL1Calls[2] = c2
        _currentL2ToL1Call++ → 3
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

  Read entry.l2ToL1Calls[3] = c3
  _currentL2ToL1Call++ → 4
  hash CALL_BEGIN(callNum=4):
    _rollingHash = keccak256(H8, uint8(1), uint256(4))                                     → H9
  Execute c3. Succeeds with retData_3.
  hash CALL_END(callNum=4, success=true, retData_3):
    _rollingHash = keccak256(H9, uint8(2), uint256(4), true, retData_3)                    → H10

─── Entry-level _processNCalls(3), iteration 2 ─────────────

  Read entry.l2ToL1Calls[4] = c4
  _currentL2ToL1Call++ → 5
  hash CALL_BEGIN(callNum=5):
    _rollingHash = keccak256(H10, uint8(1), uint256(5))                                    → H11
  Execute c4. Succeeds with retData_4.
  hash CALL_END(callNum=5, success=true, retData_4):
    _rollingHash = keccak256(H11, uint8(2), uint256(5), true, retData_4)                   → H12

─── Verification ─────────────

  _rollingHash (H12)            == entry.rollingHash                     → RollingHashMismatch?     no
  _currentL2ToL1Call (5)        == entry.l2ToL1Calls.length (5)          → UnconsumedL2ToL1Calls?   no
  _lastL1ToL2CallConsumed (1)   == entry.expectedL1ToL2Calls.length (1)  → UnconsumedL1ToL2Calls?   no
  _currentL2ToL1Call = 0    // reset so _insideExecution() returns false
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

### E.4 Multiple Phases Within One Call (Static Call Disambiguation)

A single call iteration can issue several STATICCALLs at distinct points of its execution, possibly with the same `crossChainCallHash`. The `(l2ToL1CallNumber, lastL1ToL2CallConsumed)` pair (L2: `(callNumber, lastOutgoingCallConsumed)`) forms a coordinate that advances monotonically and never repeats within a context — it is what the entry's `expectedLookups` table is keyed on, together with `executingLookupIndex` for the execution context (see §F.1).

Example: while `entry.l2ToL1Calls[0]` (call #1 at the entry level) executes, the destination contract:

```
Call #1 begins:
  _currentL2ToL1Call = 1
  _lastL1ToL2CallConsumed = 0

  STATICCALL to proxy → staticCallLookup
    → matched by (crossChainCallHash, l2ToL1CallNumber=1, lastL1ToL2CallConsumed=0)

  Trigger reentrant call #1 (a successful reentrant call)
    → _consumeNestedAction advances _lastL1ToL2CallConsumed to 1 (on match)
    → NESTED_BEGIN/END are hashed; the reentrant frame's calls (if any) advance _currentL2ToL1Call

  STATICCALL to proxy → staticCallLookup
    → matched by (crossChainCallHash, l2ToL1CallNumber=K, lastL1ToL2CallConsumed=1)
       where K is _currentL2ToL1Call after any reentrant-frame calls
```

Both STATICCALLs may carry the **same** `crossChainCallHash` — the builder differentiates them by recording the live values of `_currentL2ToL1Call` and `_lastL1ToL2CallConsumed` at the exact point of each STATICCALL during simulation, and stamping them into the corresponding `ExpectedLookup` entries of the entry's `expectedLookups` table.

If `_currentL2ToL1Call` advanced inside the reentrant frame (it consumed some of `entry.l2ToL1Calls[]`), the second STATICCALL's `l2ToL1CallNumber` will be larger than the first's. If the reentrant frame was empty (`callCount == 0`), `_currentL2ToL1Call` stays at 1 and the two STATICCALLs differ only in `lastL1ToL2CallConsumed` (0 vs 1).

---

## F. Lookup Resolution

Lookups (read-only or reverting reentrant / top-level calls) are looked up — never executed via the normal call path. There are three entry points:

1. **`staticCallLookup`** (external view) — used when the proxy's `_fallback` detects a real STATICCALL context (a self-call to `staticCheck` whose `tstore` reverts). Inside an execution it scans the active host's entry-scoped `expectedLookups`; outside, the top-level pool. Handles both `failed=true` and `failed=false` via the shared `_resolveStaticLookup`.
2. **Fallback inside `_consumeNestedAction`** — used when a normal-CALL reentrant call has no matching `ExpectedL1ToL2Call`. Only matches `failed=true` nested lookups (the destination's `try/catch` consumes the revert) and resolves them via `_executeRevertedNestedLookup`, which runs any reverted-mode sub-execution and always reverts. See §D.3.
3. **`_tryRevertedTopLevelLookup`** — the top-level twin (the `_consumeAndExecute` miss path), matching `failed=true` pool lookups via `_executeRevertedTopLevelLookup`.

### F.1 Match Keys

**Nested (`ExpectedLookup`, entry-scoped)** — the compared 4-tuple:

```
(crossChainCallHash, l2ToL1CallNumber, lastL1ToL2CallConsumed, executingLookupIndex)   // L1
(crossChainCallHash, callNumber, lastOutgoingCallConsumed, executingLookupIndex)       // L2
```

- `crossChainCallHash` — same formula as `computeCrossChainCallHash` (with `value = 0` for static reads).
- `l2ToL1CallNumber` — `uint64(_currentL2ToL1Call)` at lookup time (L2: `callNumber` / `_currentIncomingCall`).
- `lastL1ToL2CallConsumed` — `uint64(_lastL1ToL2CallConsumed)` at lookup time (L2: `lastOutgoingCallConsumed`).
- `executingLookupIndex` — the live execution context, `_insideRevertedLookup ? _revertedLookupIndex + 1 : 0`. Makes the flat host table unambiguous across the entry and its execution contexts (enforced, not a prover convention).

The scan targets only the active host's table (`_getActiveLookups()`) — entry-scoping is structural, so there is no cross-entry or cross-rollup collision surface and no queue routing.

**Top-level (`LookupCall`, storage pool; `!_insideExecution()` only)** — the match is `crossChainCallHash` plus, on L1, every `expectedStateRoots[i]` pin equal to the live `rollups[rollupId].stateRoot` (`_stateRootsMatch`, full-scan semantics — a non-matching candidate is skipped). `destinationRollupId` is enforced structurally for the persistent queue (the scan targets `verificationByRollup[rollupId].lookupQueue`); the transient pool is not filtered by destination rollup, so the prover must not collide transient top-level keys across rollups within one batch. L2 matches by hash alone.

### F.2 Lookup Algorithm

See the `staticCallLookup` pseudocode in §B.1 (nested branch + top-level branch) and `_tryRevertedTopLevelLookup` for the failed top-level path. Resolution helpers:

`_resolveStaticLookup(calls, rollingHash, failed, returnData)` (static mode, both kinds):
- **Always** run the sub-calls in static context (`_processNStaticCalls(calls)`) and check `computedHash == rollingHash` (else `RollingHashMismatch`); an empty array hashes to `bytes32(0)`.
- If `failed`: revert with `returnData`. Else return `returnData`.

`_executeRevertedNestedLookup(i)` / `_executeRevertedTopLevelLookup(lc, i)` (reverted mode): run as a mini-entry and revert with `returnData` — see §B.1.

### F.3 Lookup Sub-Calls

A lookup may include its own sub-call array (`l2ToL1Calls[]` on L1, `incomingCalls[]` on L2). In static mode these are STATICCALLs that the cached call itself would issue. They are executed at lookup time in static context (no `revertSpan` handling, no proxy creation — an un-deployed proxy reverts `LookupCallProxyNotDeployed`), and their composite hash is checked against the lookup's `rollingHash`.

This lets a lookup model a contract that performs read-only sub-calls: the lookup verifies the sub-call results match what the proof committed to, and only then returns the cached top-level result.

In reverted mode (`callCount > 0`) the same array instead runs as **real calls** inside the sub-execution — with reentry supplied by the lookup's own `expectedL1ToL2Calls[]` table, deeper lookups from the active host table, and the tagged rolling-hash schema — before the terminal revert with `returnData` (see §A.1 / §E.2).

### F.4 When to use which structure

(L1 names; on L2 the success table is `ExpectedOutgoingCrossChainCall`.)

| Situation | Use | Routed via |
|---|---|---|
| Reentrant call that **succeeds** | `ExpectedL1ToL2Call` | `_consumeNestedAction` (priority branch) |
| Reentrant call that **reverts** (caller catches with try/catch) | Nested `ExpectedLookup` with `failed = true` (inside the entry) | `_consumeNestedAction` fallback |
| Reentrant cross-chain `STATICCALL` (read-only, success or revert) | Nested `ExpectedLookup` with `failed` set as appropriate (inside the entry) | `staticCallLookup` (real STATICCALL frame, in-execution branch) |
| Top-level static read | Top-level `LookupCall` in the pool | `staticCallLookup` (top-level branch) |
| Top-level call that should fail (natural revert) | Top-level `LookupCall` with `failed = true` in the pool | `_tryRevertedTopLevelLookup` |
| Successful call(s) whose state must be force-reverted | `revertSpan > 0` on the first call of the span (see §D.4.1) | `executeInContextAndRevert` self-call |

---

## G. Execution Entry Lifecycle

### G.1 L1 Posting

`postAndVerifyBatch` resets each touched rollup's `verificationByRollup[rid]` (wipe on every verify), populates `_transientExecutions` and `_transientLookupCalls` from the batch's leading prefixes, drains the leading immediate entries inline (if any), runs the meta hook, wipes the transient tables, and unconditionally publishes the batch's remainder into the per-rollup queues.

Within a single `postAndVerifyBatch`:
1. Reentry guard: `_transientExecutions.length == 0` (revert `PostBatchReentry` otherwise). Validate. Verify proofs (`checkProofSystemsAndGetVkeys` per rollup, then `IProofSystem.verify` per PS).
2. Mark `verificationByRollup[rid].lastVerifiedBlock = block.number` for every touched rollup; wipe each touched rollup's queues / cursor on every verify (`_markVerifiedBlockPerRollup`).
3. Load the batch's transient prefix into `_transientExecutions` / `_transientLookupCalls`.
4. Drain leading immediate entries (skip-on-revert via `ImmediateEntrySkipped`).
5. Meta hook runs if transient stream not yet drained AND `msg.sender` has code (consumption advances the global `_transientExecutionIndex`; per-rollup cursors stay untouched until persistent consumption).
6. Wipe transient tables; reset `_transientExecutionIndex`.
7. Publish the batch's remainder to per-rollup queues by `destinationRollupId` (unconditionally — even if the transient prefix wasn't fully drained; there is no drain-cleanly gate). Soundness backstop is `StateDelta.currentState`.
8. Emit `BatchPosted(batch.rollupIdsWithProofSystems.length)`.

### G.2 L2 Loading

`loadExecutionTable` clears `executions` and `lookupCalls`, copies the new entries / lookup calls in, and sets `lastLoadBlock = block.number`. There is no transient table and no per-rollup queue map on L2.

### G.3 Consumption

Sequential — per-rollup `verificationByRollup[rid].executionQueueIndex++` (or `_transientExecutionIndex++` during the transient phase) per consumption. Each entry is consumed exactly once. There is no swap-and-pop and no hash-based search.

### G.4 Same-Block Restriction

On L1, all execution attempts revert `ExecutionNotInCurrentBlock(rollupId)` if `verificationByRollup[rollupId].lastVerifiedBlock != block.number`. On L2, same with `lastLoadBlock`. Entries that aren't consumed in the posting block are never read again (the read gate), and the queue is wiped by the next batch that verifies the rollup.

### G.5 Table Clearing

Each `postAndVerifyBatch` wipes the touched rollups' queues (on every verify, including same-block re-verifies); `loadExecutionTable` wipes the entire L2 table. Builders must produce self-contained batches.

---

## H. Invariants

### H.1 State Root Consistency (L1)

`rollups[id].stateRoot` is updated only:
- By `_applyStateDeltas` (during `_applyAndExecute`, called from `postAndVerifyBatch`, `executeCrossChainCall`, or `executeL2TX`).
- By `setStateRoot(rid, newRoot)` from the rollup's manager (subject to the same-block lockout).

The previous-state binding lives on the entry: `StateDelta.currentState` is checked at consumption time against `rollups[id].stateRoot`; mismatch reverts `StateRootMismatch(id)`. The proof itself binds to the FULL `ExecutionEntry` struct (including `stateDeltas`), so a stale builder either fails proof verification or fails the on-chain `currentState` match. This dual binding is the per-rollup-queue model's soundness backstop.

### H.2 Ether Accounting (L1)

For each entry: `totalEtherDelta == entryEtherIn - etherOut`, where `entryEtherIn` (the transient `_entryEtherIn` accumulator) is ALL `msg.value` received via `executeCrossChainCall` during the entry — the entry-point call's value plus every reentrant call's (0 for `executeL2TX` and immediate entries unless reentrant receipts occur) — and `etherOut` is the sum of `value` fields on every **successful** call inside the entry. Calls inside a `revertSpan` count toward neither side — their ETH transfers are rolled back by the span's revert and the span-local accumulators are discarded with the frame, even though the rolling hash still records them as successful.

Each entry independently balances — ether accounting is localized to a single entry rather than aggregated across the transaction — which simplifies the prover's job.

The sum of `etherBalance` across all rollups plus the `EEZ` contract's own balance is conserved modulo direct deposits/withdrawals outside the protocol.

### H.3 Sequential Consumption

Each entry is consumed exactly once, in posted order **on its destination rollup**. Each rollup has its own monotonically-increasing `executionQueueIndex` that is reset to 0 by every batch that verifies the rollup (wipe-on-verify). Cross-rollup state is independent.

### H.4 Rolling Hash Integrity

After each entry completes:

```
_rollingHash             == entry.rollingHash                   // RollingHashMismatch
_currentL2ToL1Call       == entry.l2ToL1Calls.length            // UnconsumedL2ToL1Calls
_lastL1ToL2CallConsumed  == entry.expectedL1ToL2Calls.length    // UnconsumedL1ToL2Calls
```

(L2: `_currentIncomingCall` / `incomingCalls` / `UnconsumedIncomingCalls` and `_lastOutgoingCallConsumed` / `expectedOutgoingCalls` / `UnconsumedOutgoingCalls`.)

Together, these three checks attest that every call described in the entry was processed in the correct order, with the correct return data, with the correct nesting structure, and that nothing extra happened.

### H.5 Proxy Determinism

Address of `CrossChainProxy(originalAddress, originalRollupId)` is fully determined by:
- The manager contract (`address(this)` at deployment time)
- Salt: `keccak256(abi.encodePacked(originalRollupId, originalAddress))`
- `CrossChainProxy` creation code + constructor args

The same pair always maps to the same proxy address on the same manager. Two proxies for the same pair cannot exist (CREATE2 collision would revert).

### H.6 Same-Block Execution

All entries posted in a given block must be consumed in that block — `verificationByRollup[rid].lastVerifiedBlock == block.number` (L1, per-rollup) or `lastLoadBlock == block.number` (L2).

### H.7 Wipe On Every Verify

`postAndVerifyBatch` wipes each touched rollup's `executionQueue` / `lookupQueue` / `executionQueueIndex` on **every** verify — including same-block re-verifies, where the new batch REPLACES the prior one for that rollup. `loadExecutionTable` (L2) `delete`s the entire existing table before loading new entries. Unconsumed entries from a prior block are unreachable (the `lastVerifiedBlock` read gate stops them even before the wipe).

### H.8 Per-Rollup Queue Soundness

The deferred remainder of a `postAndVerifyBatch` is published unconditionally to per-rollup queues. Partial transient drain does not drop persistent entries; the soundness backstop is `StateDelta.currentState`, checked at consumption. Entries whose recorded pre-state doesn't match the on-chain state at consumption revert `StateRootMismatch`.

### H.9 Reentry Guard for `postAndVerifyBatch`

`postAndVerifyBatch` re-entered from any path (e.g., by the meta hook) reverts `PostBatchReentry` — the guard is `_transientExecutions.length != 0` at the top of the function (there is no separate `_inPostBatch` flag). This prevents corruption of the shared `_transientExecutions` / `_transientLookupCalls` storage by a nested call.

Same-block re-touch of a rollup across separate (non-nested) `postAndVerifyBatch` calls is **permitted**: `_markVerifiedBlockPerRollup` wipes the rollup's queue and cursor on every verify, so the second batch's entries REPLACE the first batch's. Safe because state only mutates at consumption and every entry is gated by `StateDelta.currentState` — discarding unconsumed-but-proven entries is a liveness choice, not a safety one.

---

## I. Security Considerations

### I.1 Multi-Prover Verification

`postAndVerifyBatch` verifies one proof per `(batch, proofSystem)` pair. Each proof's public-inputs hash covers (see `MULTI_PROVER_SPEC.md` for the exact construction):

- Every entry hash — `keccak256(abi.encode(entry))` over the FULL `ExecutionEntry` struct (including `stateDeltas` with `currentState`, `proxyEntryHash`, `destinationRollupId`, `l2ToL1Calls`, `expectedL1ToL2Calls`, `callCount`, `returnData`, `rollingHash`).
- Every lookup-call hash — `keccak256(abi.encode(lookupCall))`.
- Every blob hash (for data availability).
- Per-rollup `customData` blob fetched via `IRollupContract.getCustomData(batch.blockNumber)` (rollup-defined L1-view commitment) and folded — keyed by rollupId — into `customDataAcc`, which binds into `sharedPublicInput` (shared across all PS, not per-PS).
- `keccak256(callData)`.
- The per-rollup vkey row (`vkMatrix[r][j]`) for the rollup's `proofSystemIndex[]` subset.

All proofs in the batch verify atomically — a single failure reverts. Per-rollup attestation is enforced inside each manager's `checkProofSystemsAndGetVkeys`, which reverts (threshold-not-met / unknown-PS / zero-vkey) if the resolved subset for `rid` is insufficient.

A malicious caller producing a forged batch would have to forge proofs from every required PS for every touched rollup at the current rollup states.

### I.2 Reentrancy

The protocol is intentionally reentrant. `_processNCalls` calls into proxies, which forward to destination contracts, which may call back into proxies. Reentrant calls are routed to `_consumeNestedAction` via the `_insideExecution()` check. The transient call cursor (`_currentL2ToL1Call` / `_currentIncomingCall`) naturally serializes everything within one entry.

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

Per-rollup ownership operations (`addProofSystem`, `removeProofSystem`, `updateVerificationKey`, `setThreshold`, `transferOwnership`) live on the rollup's manager (`src/rollupContract/Rollup.sol` reference impl).

### I.5 Reentry Guard and Same-Block Touch Semantics

`postAndVerifyBatch` reentry from anywhere (meta hook, manager callback, etc.) is blocked by `PostBatchReentry` via the `_transientExecutions.length != 0` check at the top of the function.

Multiple top-level `postAndVerifyBatch` calls hitting the same rollup in the same block are permitted by design: `_markVerifiedBlockPerRollup` wipes the rollup's queue and cursor on every verify, so the second batch fully SUPERSEDES the first for that rollup (no append). Builders cannot rely on once-per-block-per-rollup exclusivity; if exclusivity is required, the orchestrator must enforce it at the social layer.

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
