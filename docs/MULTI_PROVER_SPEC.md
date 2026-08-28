# Multi-Prover Specification

Living document tracking the architecture and design decisions of the multi-prover /
per-rollup-manager refactor on `feature/flatten`. Updated as the design evolves.

---

## Architecture overview

```
┌──────────────────────────────────────────────┐
│ EEZ.sol  (central registry)                  │
│  - roots, ether balances               │
│  - per-rollup deferred queues                │
│  - per-rollup `lastVerifiedBlock`            │
│  - cross-chain proxy registry                │
│  - postAndVerifyBatch / executeCrossChainCall│
│  - executeL2Txs / staticCrossChainCall       │
│                                              │
│  Owner-escape entry point:                   │
│   - setRoot(rid, root)                  │
└──────────────────────────────────────────────┘
              ▲                    ▲
              │ checkProofSystems  │ rollupContractRegistered(rid)
              │ AndGetVkeys        │ (init callback)
              │ getCustomData      │
              │                    ▼
┌──────────────────────────────────────────────┐
│ IRollupContract-conforming contracts (one    │
│ per rollup, deployed by user).               │
│ Reference impl: `rollupContract/Rollup.sol`  │
│  - owner                                     │
│  - threshold                                 │
│  - verificationKey[ps] map                   │
│  - addProofSystem / removeProofSystem        │
│  - updateVerificationKey / setThreshold      │
│  - transferOwnership / setRoot          │
│  - getCustomData                             │
└──────────────────────────────────────────────┘
              ▲ verify(proof, hash)
              │
┌──────────────────────────────────────────────┐
│ IProofSystem-conforming contracts            │
│ (any verifier — ZK, ECDSA, etc.)             │
│  No central registry — each rollup's         │
│  manager defines its own allowed set         │
└──────────────────────────────────────────────┘
```

### Files

| Path | Role |
|---|---|
| `src/EEZ.sol` | Central registry: roots, queues, `postAndVerifyBatch` flow |
| `src/base/EEZBase.sol` | Shared base for L1+L2: rolling-hash machinery, proxy registry, `computeCrossChainCallHash`, the `ContextResult` transport, etc. |
| `src/L2/EEZL2.sol` | L2 manager — inherits `EEZBase`; system-driven table loading (`loadExecutionTable`) and inbound delivery (`executeIncomingCrossChainCall`) |
| `src/rollupContract/Rollup.sol` | Reference per-rollup manager (PS membership, vkeys, threshold, owner, `getCustomData`) |
| `src/interfaces/IRollup.sol` | Declares `IRollupContract` — interface the registry calls back into |
| `src/interfaces/IProofSystem.sol` | Interface for proof-verifying contracts |
| `src/interfaces/IEEZ.sol` | Shared `ProxyInfo` + `IEEZ` interface, plus the L1 execution structs (`RollupUpdate`, `ExecutionEntry`, `StaticExecutionEntry`, `L2ToL1Call`, `ExpectedL1ToL2Call`, the batch structs, …) |
| `src/interfaces/IEEZL2.sol` | L2 execution structs with self-relative directional names (`CrossChainCall`, `ExpectedOutgoingCrossChainCall`, `ExecutionEntry`, `StaticExecutionEntry`) — leaner than L1's (no `RollupUpdate` / `destinationRollupId` / `ExpectedRootPerRollup`) |
| `src/interfaces/IMetaCrossChainReceiver.sol` | Callback fired on `postAndVerifyBatch`'s sender to drive the transient stream |
| `src/base/CrossChainProxy.sol` | CREATE2-deployed proxy per (originalAddress, originalRollupId); immutable `EEZ` points at the manager |
| `src/base/ExpectedL1ToL2CallTransient.sol` | EIP-1153 transient-storage implementation for the immediate L1→L2 reentrant table; inherited by `EEZ` and used while immediate entries execute |

### Deleted in this refactor

- `src/IZKVerifier.sol` — replaced by `IProofSystem.sol` (rename + generalization).
- `src/ProofSystemRegistry.sol` — no central PS registry. Each rollup's manager defines its
  own allowed set; vetting is the rollup owner's responsibility.

---

## Multi-prover model

### `ProofSystemBatchPerVerificationEntries`

Each `postAndVerifyBatch` call carries a single batch struct (NOT an array):

```solidity
struct ProofSystemBatchPerVerificationEntries {
    ExpectedRootPerRollup[] expectedRootPerRollup; // optional composer assertions — checked first
    ExecutionEntry[] entries;
    StaticExecutionEntry[] staticEntries;                    // top-level static (read-only) entries
    uint256 immediateEntryCount;                             // leading prefix executed this tx (not queued)
    uint256 immediateStaticEntryCount;                       // leading static entries resolvable this tx via the meta hook
    address[] proofSystems;                                  // strictly increasing, no address(0), no duplicates
    RollupIdWithProofSystems[] rollupIdsWithProofSystems;    // strictly ascending by rollupId
    uint256[] blobIndices;                                   // selects which tx-level 4844 blobs the batch consumes
    bytes callData;                                          // batch-scoped (each PS's circuit gets its own region)
    bytes[] proofs;                                          // parallel to proofSystems — one proof per PS
    uint64 blockNumber;                                      // single L1 block the batch binds to (0 = no context, uint64.max = latest)
    bool bindMsgSenderInPublicInput;                         // true = fold msg.sender into the public input (front-run protection)
}

struct RollupIdWithProofSystems {
    uint64 rollupId;
    uint64[] proofSystemIndexes;  // indices into proofSystems[], strictly ascending; len >= rollup's threshold
}

struct ExpectedRootPerRollup {
    uint64 rollupId;
    bytes32 root;
}
```

**Counting rule:** the batch verifies exactly `proofSystems.length` proofs — one per PS in
the global list — and all proofs must verify atomically (one revert reverts the whole call).

**Per-rollup PS subset (explicit):** each rollup `R` lists `proofSystemIndexes[]` —
strictly-ascending indices into the batch's `proofSystems[]`. The rollup's manager is
handed the resolved subset via `IRollupContract.checkProofSystemsAndGetVkeys(subset)` and
enforces (a) every PS is known with a non-zero vkey for `R`, (b) `subset.length >= threshold`.
The registry never reads `threshold` separately — single external call per rollup. The registry
additionally requires the manager to return exactly one vkey per subset entry
(`InvalidProofSystemConfig` otherwise).

**Composer root pins:** `expectedRootPerRollup` is an optional set of assertions
checked before anything else — each pin must equal the live `rollups[rid].root` or the
whole call reverts `ExpectedRootMismatch(rid)`. Lets a batch composer refuse to land on
an unexpected state.

**Unproven dispatch params:** `immediateEntryCount` / `immediateStaticEntryCount` are NOT
folded into the public input, so the immediate/persistent split can be re-tuned without
re-proving.

### Threshold lives on the manager

`IRollupContract.checkProofSystemsAndGetVkeys(address[] subset)` does TWO things atomically:
1. Returns the vkey row (one vkey per PS in `subset`).
2. Reverts `ThresholdNotMet` if `subset.length < threshold`, or `ProofSystemNotAllowed` if
   any PS isn't allowed for this rollup (unknown / zero vkey, non-strictly-increasing input). See
   `src/rollupContract/Rollup.sol`.

Single external call per rollup, no TOCTOU between two reads, no central threshold
semantics. Custom managers can use any threshold model they like (fixed M-of-N,
governance-driven, time-weighted, etc.) — the registry just consumes the returned vkeys.

### Per-PS publicInputsHash (two-stage)

```
for each rollup r in rollupIdsWithProofSystems (rollupId-ascending):
  customDataHashes[r] = keccak256(abi.encode(rollupId_r, customData_r))

boundSender = batch.bindMsgSenderInPublicInput ? msg.sender : address(0)

sharedPublicInput = keccak256(abi.encodePacked(
    abi.encode(entryHashes),
    abi.encode(staticEntryHashes),
    abi.encode(blobHashes),
    keccak256(callData),
    abi.encode(customDataHashes),
    boundSender
))

for each PS k in proofSystems:
  acc_k = bytes32(0)
  for each rollup r (rollupId-ascending) where k ∈ rollupIdsWithProofSystems[r].proofSystemIndexes:
    acc_k = keccak256(abi.encode(acc_k, rollupId_r, verificationKeysPerRollup[r][j]))
  publicInputsHash[k] = keccak256(abi.encodePacked(sharedPublicInput, acc_k))
```

- `entryHashes[i] = keccak256(abi.encode(batch.entries[i]))` — binds the FULL `ExecutionEntry`
  struct (rollupUpdates, proxyEntryHash, l2ToL1Calls, expectedL1ToL2Calls, rollingHash,
  destinationRollupId, success, returnData). Prevents an orchestrator from swapping inputs
  at execution time without invalidating the proof.
- `staticEntryHashes[i] = keccak256(abi.encode(batch.staticEntries[i]))` — same rationale.
- `blobHashes[i] = blobhash(batch.blobIndices[i])` — the selected tx-level 4844 blob hashes.
- `customData_r` is the opaque blob fetched per-rollup via
  `IRollupContract.getCustomData(batch.blockNumber)` (rollup-defined L1-view commitment — the
  reference `Rollup` returns ABI-encoded `(timestamp, blockHash)`, an empty blob for
  `blockNumber == 0`, and reverts `BlockHashUnavailable` when the hash can't be resolved).
  Each blob is hashed keyed by `rollupId_r`, and the per-rollup hash ARRAY binds into
  `sharedPublicInput`. It does NOT vary per PS, so it is shared across all `acc_k` rather than
  re-folded into each one.
- `verificationKeysPerRollup[r][j]` is the vkey of `proofSystems[proofSystemIndexes[r][j]]`
  for `rollupId_r` (the jagged matrix returned by `_getVerificationKeysPerRollup`).
- `boundSender` binds the submitter: with `bindMsgSenderInPublicInput = true` the proof commits to
  the exact `msg.sender` allowed to land the batch (front-run protection for the meta-hook / AA
  bundle); with `false` it commits to `address(0)` and anyone may submit.

---

## Per-rollup queue model

### Storage

```solidity
struct RollupVerification {
    uint64 lastVerifiedBlock;
    uint64 entryQueueIndex;             // packed with lastVerifiedBlock
    ExecutionEntry[] entryQueue;
    StaticExecutionEntry[] staticEntryQueue;
}
mapping(uint64 rollupId => RollupVerification record) internal verificationByRollup;
```

- `lastVerifiedBlock` doubles as: (a) per-block reset marker (every verify that touches `rid`
  wipes the queues), (b) read gate for consumers (`lastVerifiedBlock == block.number`),
  (c) lockout signal for the `setRoot` owner-escape path.
- `entryQueue` and `staticEntryQueue` are per-rollup deferred-consumption stores. Each
  entry's / static entry's `destinationRollupId` selects which queue receives it during
  `_saveRemainderEntries`.

### Reset on every verify

`_markVerifiedBlockAndDeletePreviousEntries(rid)` deletes the queues and resets the cursor on
**every** verify — including a same-block re-verify, which therefore REPLACES (does not append
to) the prior batch's entries. Stale entries from prior blocks are unreachable anyway because
consumers gate on `lastVerifiedBlock == block.number`.

### Routing

- `executeCrossChainCall(...)`: consumer's destination rollupId = `proxyInfo.originalRollupId`.
  Forward-scans `verificationByRollup[rid].entryQueue` from `entryQueueIndex` for the first
  entry matching identity (`proxyEntryHash`), routing (`destinationRollupId`), and state
  preconditions (every `RollupUpdate.currentRoot` == the live root); non-matches are skipped,
  no match ⇒ `ExecutionNotFound`.
- `executeL2Txs(rid)`: explicit `rid` arg; the matched entry must have
  `proxyEntryHash == bytes32(0)`. Same routing.
- `staticCrossChainCall(...)`: consumer's destination rollupId = `proxyInfo.originalRollupId`.
  Outside an execution it scans ONE table: the batch's transient static pool while a batch is
  mid-flight, otherwise `verificationByRollup[rid].staticEntryQueue` (match by
  `proxyEntryHash` + `destinationRollupId` + all `expectedRoots` pins live, full scan).
- `_consumeNestedCall` / reentrant static reads: resolved from the executing entry's own
  unified `expectedL1ToL2Calls[]` table (entry-scoped — no queue routing at all), each entry
  content-addressed by `expectedL1toL2Hash == keccak256(crossChainCallHash, _rollingHash)`.
  A reentrant no-match folds `CALL_NOT_FOUND` into the rolling hash so the entry fails its
  final `RollingHashMismatch` check.

### Transient phase (intra-tx)

During `postAndVerifyBatch`, the leading `batch.immediateEntryCount` entries form the
IMMEDIATE prefix. Its leading run of L2Tx entries (`proxyEntryHash == 0`) executes straight
from calldata — never SSTOREd. Only the prefix REMAINDER (the entries past the L2Tx run) is
copied into `_transientEntries`, together with the leading `immediateStaticEntryCount` static
entries into `_transientStaticEntries`; `msg.sender` must have code to drive them
(`MetaEntriesWithoutReceiver` otherwise).
The transient stream is consumed via the global `_transientEntryIndex` cursor (with the same
forward-scan matching as the persistent path).

After the transient stream drains (or doesn't), the persistent remainder is published to
per-rollup queues unconditionally. Soundness backstop: each entry's `RollupUpdate.currentRoot`
is part of the match predicate at consumption time; entries whose preconditions don't match
the on-chain state are simply never matched (`ExecutionNotFound` if nothing else matches).
So dropped transient leftover doesn't poison persistent consumers — they just fail their own
root match if they depended on it.

---

## `postAndVerifyBatch` flow (current)

1. **Reentry check** — `if (_insideExecution() || _transientEntries.length != 0) revert PostBatchReentry();`.
   There is no separate `_inPostBatch` flag; the two conditions cover every window in which a
   state-mutating external call is in flight (an executing entry, and the meta hook respectively).
2. **Composer pins** — every `expectedRootPerRollup` pin must equal the live root, else
   `ExpectedRootMismatch(rid)`.
3. **Structural validation** (no external calls) via `_validateBatchStructure(batch)`: sorted
   `proofSystems[]`, strictly-ascending `rollupIdsWithProofSystems[].rollupId` (and
   `rollupId > MAINNET_ROLLUP_ID`), each rollup registered (`rollupContract != 0`), each row's
   `proofSystemIndexes[]` strictly ascending and in range; per entry: ≥1 `rollupUpdates`
   (strictly increasing, all ∈ batch), `destinationRollupId` ∈ its own deltas, every call
   SOURCE ∈ its deltas (top-level + reentrant sub-calls); per static entry: `expectedRoots`
   pins strictly increasing and ∈ batch, `destinationRollupId` pinned, sub-call sources pinned;
   immediate prefix bounds, and `ImmediateCountStrandsLeadingL2Tx` (the poster may not truncate
   `immediateEntryCount` below the leading L2Tx run).
4. **Fetch vkeys + verify**: `_getVerificationKeysPerRollup(batch)` calls each rollup's manager
   via `IRollupContract.checkProofSystemsAndGetVkeys(subset)` — manager enforces threshold and
   returns one vkey per PS in the subset (length-checked by the registry). Then
   `_verifyProofSystemBatch(batch, verificationKeysPerRollup)` computes `sharedPublicInput`
   (folding each rollup's `customData` via `getCustomData(batch.blockNumber)`), builds per-PS
   `publicInputsHash[k]`, and calls `IProofSystem.verify(proofs[k], publicInputsHash[k])` for
   each PS. ALL proofs must verify atomically (one failure reverts the whole call with
   `InvalidProof`).
5. **Mark verified-this-block** (`_markVerifiedBlockAndDeletePreviousEntries(rid)` for each
   rollup): wipes the rollup's queues and resets its cursor on every verify — a same-block
   re-verify REPLACES (does not append to) the prior batch's entries for that rollup. Sets the
   read gate for `executeCrossChainCall` / `executeL2Txs`.
6. **Drain the leading immediate L2Tx run straight from calldata**: while
   `batch.entries[i].proxyEntryHash == 0` (within the immediate prefix), self-call
   `try this._attemptExecuteImmediateL2Txs(batch.entries[i]) catch { emit L2TxSkipped(i, revertData); }`
   and advance. If the run was non-empty and EVERY entry reverted, the whole post is unwound
   with `AllImmediateL2TxsFailed`.
7. **Meta hook**: if immediate-prefix entries remain past the L2Tx run, `msg.sender` must have
   code to receive the hook (`MetaEntriesWithoutReceiver` otherwise); push them into
   `_transientEntries` (and the leading
   `immediateStaticEntryCount` static entries into `_transientStaticEntries`), then fire
   `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` so the caller can
   drive them via cross-chain proxy calls.
8. **Publish the remainder** via `_saveRemainderEntries(batch)` (**unconditionally** — even if
   the meta hook left transient entries unconsumed): entries past `immediateEntryCount` into
   `entryQueue[destinationRollupId]`, static entries past `immediateStaticEntryCount` into
   `staticEntryQueue[destinationRollupId]`.
9. **Cleanup transient tables** (which also closes the re-entry window), then
   `emit BatchPosted(batch.rollupIdsWithProofSystems.length)`.

### Reentrancy reasoning

The three external calls during step 4 (`IRollupContract.checkProofSystemsAndGetVkeys`,
`IRollupContract.getCustomData`, `IProofSystem.verify`) are all `view`. The Solidity compiler
emits `STATICCALL` for view-marked interface calls. Inside a STATICCALL frame, ALL state
mutations revert at the EVM level — `SSTORE`, `TSTORE`, `LOG`, `CREATE`, `CALL` with value,
AND any nested `CALL` that tries to do those things. The static context propagates down the
call stack with no assembly bypass. So a malicious manager or verifier cannot reenter
`postAndVerifyBatch` (state-mutating) from inside step 4 — its first `SSTORE` would revert.

The other reentrancy windows are non-view callbacks:
`IRollupContract.rollupContractRegistered` (called once from `registerRollup`), the immediate
L2Tx run's proxy targets (step 6), and the `IMetaCrossChainReceiver` hook (step 7). Those are
normal `CALL` → can reenter. Lockouts:
- Re-entry into `postAndVerifyBatch` from any path → blocked by the
  `_insideExecution() || _transientEntries.length != 0` check in step 1 (`PostBatchReentry`).
  `_insideExecution()` covers the immediate L2Tx run and any executing entry;
  `_transientEntries.length != 0` covers the meta-hook window. This covers both the
  same-rollup and disjoint-rollup cases without needing a separate flag.
- `EEZ.setRoot` (called from the manager) → gated by `RollupBatchActiveThisBlock`
  (`lastVerifiedBlock == block.number`) AND `SetRootNotAllowedDuringExecution`
  (`_insideExecution() == true`). The latter prevents a malicious manager from rewriting
  state mid-execution via a reentrant proxy path.

---

## Manager registration (no handoff)

### Initial registration

```solidity
function registerRollup(address rollupContract, bytes32 initialRoot) external returns (uint64 rollupId);
```

- Caller deploys their `IRollupContract`-conforming contract (e.g. our reference
  `src/rollupContract/Rollup.sol`, or a custom multisig / governance contract) with desired
  (proofSystems, vkeys, threshold, ownership model) baked in, then registers it.
- Registry assigns next `rollupId` (a `uint64`; sequential ids stay well below 2^64), stores
  `(rollupContract, initialRoot, etherBalance=0)`.
- Fires `IRollupContract(rollupContract).rollupContractRegistered(rollupId)` — one-shot
  callback so the manager learns its id. The reference impl stores the id and rejects a
  second call (`rollupId != 0` ⇒ `AlreadyRegistered`).
- Emits `RollupCreated(rollupId, rollupContract, initialRoot)`.

### No manager handoff

There is no `setRollupContract` and no `RollupContractChanged` event. The manager binding
is set at registration and is immutable thereafter. If a rollup needs to migrate to a new
manager, the off-chain orchestrator must register a new rollupId pointing at the new
manager and migrate state out-of-band.

### Owner escape (root)

```solidity
function setRoot(uint64 rollupId, bytes32 newRoot) external;
```

- Callable only by the registered manager (`msg.sender == rollups[rid].rollupContract`).
- Reverts `RollupBatchActiveThisBlock` if any batch hit `rid` earlier this block.
- Reverts `SetRootNotAllowedDuringExecution` if `_insideExecution()` is true.
- The single state-mutating call from manager into registry. Emits `RootUpdated`.

---

## What's been removed (and why)

| Removed | Why |
|---|---|
| `IZKVerifier.sol` | Renamed/generalized to `IProofSystem.sol` — same interface. |
| `ProofSystemRegistry.sol` | Implicit in each rollup's vkey map. Each rollup owner vets their own PSes. |
| `_rollupIdByContract` reverse map | Manager passes `rollupId` explicitly via callbacks (`rollupContractRegistered`). |
| `RollupConfig.owner` / `threshold` / `proofSystemCount` | All on the per-rollup manager. Registry just stores `rollupContract` pointer + root + ether. |
| `EEZ.setStateByOwner` / `setVerificationKey` / `addProofSystem` / `removeProofSystem` / `setThreshold` / `transferRollupOwnership` | All moved to the manager. |
| `IRollupContract.threshold()` (separate getter) | Manager enforces threshold internally inside `checkProofSystemsAndGetVkeys`; never read separately. |
| `IRollupContract.owner()` probe in `registerRollup` | Registry makes no assumption about ownership model. |
| `setRollupContract` / `RollupContractChanged` (manager handoff) | Removed. Manager binding is immutable after registration. |
| `_inPostBatch` flag | Replaced by the `_insideExecution() || _transientEntries.length != 0` reentry check. |
| `_validateRelevance` (anti-griefing PS-relevance check) | Manager's threshold check covers it; unrelated PSes are wasted gas the orchestrator pays. |
| "Drained cleanly" gate before publishing the remainder | Removed — `_saveRemainderEntries` runs **unconditionally** (even if the transient prefix wasn't fully drained). `RollupUpdate.currentRoot` is the soundness backstop for the persistent path. |
| `EEZ.ThresholdNotMet` / `UnrelatedProofSystem` errors | No longer thrown by the registry. |
| Single-prover `postBatch(entries[], lookupCalls[], transientCount, transientLookupCallCount, blobCount, callData, proof)` | Replaced by `postAndVerifyBatch(ProofSystemBatchPerVerificationEntries batch)` — single struct, NOT an array. |
| Multi-sub-batch `postBatch(ProofSystemBatch[] batches)` (intermediate shape) | Collapsed to a single batch per call with explicit per-rollup `proofSystemIndexes[]`. |
| Global `executions[]` / `executionIndex` / `lastStateUpdateBlock` | Replaced by per-rollup `verificationByRollup[rid].entryQueue` / `entryQueueIndex` / `lastVerifiedBlock`. |

---

## Trust model

- **Each rollup is its own security domain.** Compromise of a rollup's manager only affects
  that rollup's root + queue. Cannot affect other rollups' state.
- **The rollup owner trusts their own proof system(s) and threshold.** Registry makes no
  judgment about whether a PS is "real"; just calls `verify(...)` and trusts the return.
- **Atomic verification across the batch.** All proofs in a `postAndVerifyBatch` call must
  verify; if any fails, the whole call reverts.
- **The orchestrator (`postAndVerifyBatch` caller) pays for any waste.** Unrelated PSes,
  unconsumed transient entries, etc. — registry doesn't grief-check.

---

## Open / pending design decisions

- **`registerRollup` initial state overwrite**: callback fires AFTER the pointer is set,
  so the new manager can call `setRoot` to overwrite `initialRoot`. Cosmetic (owner
  controls anyway) but the `RollupCreated` event's `initialRoot` field becomes unreliable.
- **Double-registration of same manager address**: a custom manager without the one-shot
  `rollupContractRegistered` guard (the reference impl's `rollupId != 0` ⇒ `AlreadyRegistered`)
  could be registered for two rollupIds, controlling both via shared `msg.sender`.
  Acceptable per the per-rollup trust model but worth documenting.
- **`rollupId == 0` (MAINNET) excluded from batches**: the strict-increasing check
  starting at `MAINNET_ROLLUP_ID = 0` makes `rollupId == 0` unpostable. Pre-existing pattern;
  the registry's `++rollupCounter` assigns ids starting at 1, so id 0 is never registered.
- **`_processNCalls` runs before `_applyRollupUpdates`**: outer entry's state deltas applied
  at end. Reentrant entries from other rollups apply their own deltas during dispatch. By
  design, document.
- **`_processNStaticCalls` rolling hash format differs** from the main rolling hash (no
  CALL_BEGIN/CALL_END tags — untagged `keccak(prev, success, retData)`, verified against
  `StaticExecutionEntry.rollingHash`). Pre-existing simplification; document or align.
- **Per-(destination rollup) call ID counter**: introduce a monotonic `callId` per
  destination rollup (or maybe globally per `postAndVerifyBatch` / per cross-PS-interaction set) baked
  into each `L2ToL1Call`. Useful for: deterministic cross-PS message
  ordering, off-chain indexing / debugging, deduplication of identical-looking calls. Open
  questions: scope (per-rollup, per-tx, per-batch?), where the counter lives (registry storage
  vs. prover-supplied + bound by hash?), how it interacts with `revertNextNCalls` when a call's
  state is rolled back. Worth investigating later.

---

## Audit history

Two parallel reviews were run after the latest round of changes:

- **Code-quality review**: flagged threshold-as-separate-call (now fixed by moving threshold
  inside `checkProofSystemsAndGetVkeys`), stale natspec referencing the removed reverse map,
  `StateUpdateRollupNotInBatch` error reused for static-entry destinations (renamed to
  `RollupNotInBatch`), `_processNStaticCalls` rolling hash format divergence (pre-existing).
- **Security review**: HIGH on reentrancy via the vkey fetch (now
  `_getVerificationKeysPerRollup`) / `threshold()` BEFORE the verified-block mark — fixed by
  keeping the mark (`_markVerifiedBlockAndDeletePreviousEntries`) before any external
  non-static CALL (the vkey/verify steps are static-only). MEDIUM on
  `rollupContractRegistered` reentrancy in `registerRollup` — open. MEDIUM on
  double-registration without unique-address check — open (acceptable per trust model).
  NEW: `setRoot` callable mid-execution via reentrant manager — fixed by
  `SetRootNotAllowedDuringExecution` guard (commit `c27c1bc`).

---

## Versioning

This document originated on `feature/flatten` and now tracks the current branch state
(`feature/simplify` as of the unified reentrant table / static-entry model). Updates are
appended/edited inline as the design evolves.
