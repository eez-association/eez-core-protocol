# Multi-Prover Refactor — Design Notes

Living document tracking the architecture and design decisions of the multi-prover /
per-rollup-manager refactor on `feature/flatten`. Updated as the design evolves.

---

## Architecture overview

```
┌──────────────────────────────────────────────┐
│ EEZ.sol  (central registry)                  │
│  - state roots, ether balances               │
│  - per-rollup deferred queues                │
│  - per-rollup `lastVerifiedBlock`            │
│  - cross-chain proxy registry                │
│  - postAndVerifyBatch / executeCrossChainCall│
│  - executeL2TX / staticCallLookup            │
│                                              │
│  Owner-escape entry point:                   │
│   - setStateRoot(rid, root)                  │
└──────────────────────────────────────────────┘
              ▲                    ▲
              │ checkProofSystems  │ rollupContractRegistered(rid)
              │ AndGetVkeys        │ (init callback)
              │ getTimestampAnd    │
              │ BlockHash          │
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
│  - transferOwnership / setStateRoot          │
│  - getTimestampAndBlockHash                  │
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
| `src/EEZ.sol` | Central registry: state roots, queues, `postAndVerifyBatch` flow |
| `src/base/EEZBase.sol` | Shared base for L1+L2: rolling-hash machinery, proxy registry, `computeCrossChainCallHash`, `_resolveLookupCall`, etc. |
| `src/L2/EEZL2.sol` | L2 manager — inherits `EEZBase`; gained `executeIncomingCrossChainCall` (system-only inbound delivery) and `_tryRevertedTopLevelLookup` |
| `src/rollupContract/Rollup.sol` | Reference per-rollup manager (PS membership, vkeys, threshold, owner) |
| `src/interfaces/IRollup.sol` | Declares `IRollupContract` — interface the registry calls back into |
| `src/interfaces/IProofSystem.sol` | Interface for proof-verifying contracts |
| `src/interfaces/IEEZ.sol` | Shared structs (`StateDelta`, `ExecutionEntry`, `LookupCall`, `L2ToL1Call`, `ExpectedL1ToL2Call`, …) |
| `src/interfaces/IMetaCrossChainReceiver.sol` | Callback fired on `postAndVerifyBatch`'s sender to drive the transient stream |
| `src/base/CrossChainProxy.sol` | CREATE2-deployed proxy per (originalAddress, originalRollupId); immutable `EEZ` points at the manager |

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
    ExecutionEntry[] entries;
    LookupCall[] l1ToL2lookupCalls;
    uint256 transientExecutionEntryCount;
    uint256 transientLookupCallCount;
    address[] proofSystems;                              // sorted asc, no duplicates, no zero
    RollupIdWithProofSystems[] rollupIdsWithProofSystems; // strictly ascending by rollupId
    bytes32 crossProofSystemInteractions;                 // hash binding cross-PS messages
    uint256[] blobIndices;                                // selects which tx-level 4844 blobs the batch consumes
    bytes callData;                                       // batch-scoped (each PS's circuit gets its own region)
    bytes[] proofs;                                       // parallel to proofSystems — one proof per PS
}

struct RollupIdWithProofSystems {
    uint256 rollupId;
    uint64[] proofSystemIndex;  // indices into proofSystems[], strictly ascending; len >= rollup's threshold
}
```

**Counting rule:** the batch verifies exactly `proofSystems.length` proofs — one per PS in
the global list — and all proofs must verify atomically (one revert reverts the whole call).

**Per-rollup PS subset (explicit):** each rollup `R` lists `proofSystemIndex[]` —
strictly-ascending indices into the batch's `proofSystems[]`. The rollup's manager is
handed the resolved subset via `IRollupContract.checkProofSystemsAndGetVkeys(subset)` and
enforces (a) every PS is known with a non-zero vkey for `R`, (b) `subset.length >= threshold`.
The registry never reads `threshold` separately — single external call per rollup.

### Threshold lives on the manager

`IRollupContract.checkProofSystemsAndGetVkeys(address[] subset)` does TWO things atomically:
1. Returns the vkey row (one vkey per PS in `subset`).
2. Reverts `ThresholdNotMet` if `subset.length < threshold`, or `ProofSystemNotAllowed` if
   any PS isn't allowed for this rollup (unknown / zero vkey). See
   `src/rollupContract/Rollup.sol`.

Single external call per rollup, no TOCTOU between two reads, no central threshold
semantics. Custom managers can use any threshold model they like (fixed M-of-N,
governance-driven, time-weighted, etc.) — the registry just consumes the returned vkeys.

### Per-PS publicInputsHash (two-stage)

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
```

- `entryHashes[i] = keccak256(abi.encode(batch.entries[i]))` — binds the FULL `ExecutionEntry`
  struct (stateDeltas, proxyEntryHash, destinationRollupId, L2ToL1Calls,
  expectedL1ToL2Calls, callCount, returnData, rollingHash). Prevents an orchestrator from
  swapping inputs at execution time without invalidating the proof.
- `lookupCallHashes[i] = keccak256(abi.encode(batch.l1ToL2lookupCalls[i]))` — same rationale.
- `(blockHash_r, timestamp_r)` are fetched per-rollup via
  `IRollupContract.getTimestampAndBlockHash()` and folded into per-PS `acc_k`. `prevBlockhash`
  and `ts` are NOT in `sharedPublicInput`; each rollup folds its own values into the
  per-PS accumulator.
- `vkMatrix[r][j]` is the vkey of `proofSystems[proofSystemIndex[r][j]]` for `rollupId_r`.

### Cross-PS interactions hash

`crossProofSystemInteractions` is a per-batch hash committing to the set of cross-PS
boundary messages this batch participates in (computed off-chain, mirrored in each PS's
circuit). All proofs in a `postAndVerifyBatch` must verify atomically — if PS_A claims to
send msg_0 to PS_B and PS_B's commitment doesn't include msg_0, one of them won't verify
and the whole batch reverts. See `docs/hashedProofSystem.md` (port from source branch — TODO).

---

## Per-rollup queue model

### Storage

```solidity
struct RollupVerification {
    uint256 lastVerifiedBlock;
    ExecutionEntry[] queue;
    LookupCall[] lookupQueue;
    uint256 cursor;
}
mapping(uint256 rollupId => RollupVerification record) internal verificationByRollup;
```

- `lastVerifiedBlock` doubles as: (a) once-per-block-per-rollup invariant, (b) reentrancy
  gate (read-after-write before any external call), (c) lazy-reset signal (stale values
  treated as empty queue).
- `queue` and `lookupQueue` are per-rollup deferred-consumption stores. Each entry's
  `destinationRollupId` selects which queue receives it during `_publishRemainder`.

### Lazy reset

When `_markVerifiedThisBlock(rid)` runs and finds `lastVerifiedBlock < block.number`, it
deletes the queue and resets the cursor — no explicit cleanup pass. Stale entries from
prior blocks are unreachable because consumers gate on `lastVerifiedBlock == block.number`.

### Routing

- `executeCrossChainCall(...)`: consumer's destination rollupId = `proxyInfo.originalRollupId`.
  Routes to `verificationByRollup[rid].queue[cursor]`.
- `executeL2TX(rid)`: explicit `rid` arg. Same routing.
- `staticCallLookup(...)`: consumer's destination rollupId = `proxyInfo.originalRollupId`.
  Routes to `verificationByRollup[rid].lookupQueue` (after scanning the global transient
  lookup-call table first).
- `_consumeNestedAction`: nested actions live within an entry, no per-rollup routing.

### Transient phase (intra-tx)

During `postAndVerifyBatch`, the leading `batch.transientExecutionEntryCount` entries from the
batch are copied into the global `_transientExecutions` array. Same for lookup calls (with
`transientLookupCallCount`). The transient stream is consumed via `_transientExecutionIndex`
cursor.

After the transient stream drains (or doesn't), the persistent remainder is published to
per-rollup queues unconditionally. Soundness backstop: each entry's `StateDelta.currentState`
is checked at consumption time; entries whose preconditions don't match the on-chain state
revert `StateRootMismatch`. So dropped transient leftover doesn't poison persistent
consumers — they just fail their own state-root check if they depended on it.

---

## `postAndVerifyBatch` flow (current)

1. **Reentry check** — `if (_transientExecutions.length != 0) revert PostBatchReentry();`.
   There is no separate `_inPostBatch` flag; the transient-stream length doubles as the guard.
2. **Structural validation** (no external calls) via `_validateStructure(batch)`: sorted
   `proofSystems[]`, strictly-ascending `rollupIdsWithProofSystems[].rollupId` (and
   `rollupId > MAINNET_ROLLUP_ID`), each rollup registered (`rollupContract != 0`), each row's
   `proofSystemIndex[]` strictly ascending and in range, entry/lookupCall
   `destinationRollupId` ∈ batch's rollup set, transient prefix bounds.
3. **Fetch vkMatrix + verify**: `_fetchVkMatrix(batch)` calls each rollup's manager via
   `IRollupContract.checkProofSystemsAndGetVkeys(subset)` — manager enforces threshold and
   returns one vkey per PS in the subset. Then `_verifyProofSystemBatch(batch, vkMatrix)`
   computes `sharedPublicInput`, builds per-PS `publicInputsHash[k]` (folding each rollup's
   `(blockHash, timestamp)` via `getTimestampAndBlockHash()`), and calls
   `IProofSystem.verify(proofs[k], publicInputsHash[k])` for each PS. ALL proofs must verify
   atomically (one revert reverts the whole call).
4. **Mark verified-this-block** (`_markVerifiedThisBlock(rid)` for each rollup): lazy-resets
   the queue on first touch in this block (subsequent touches in the same block append to
   the existing queue — same-block re-touch of a rollup is permitted; the orchestrator must
   coordinate exclusivity if it needs it). Sets the read gate for `executeCrossChainCall`
   / `executeL2TX`.
5. **Load transient stream** via `_loadTransient(batch)`: copy `entries[0..transientExecutionEntryCount)`
   into `_transientExecutions` and `l1ToL2lookupCalls[0..transientLookupCallCount)` into
   `_transientLookupCalls`.
6. **Drain leading immediate entries inline**: while `_transientExecutions[idx].proxyEntryHash == 0`,
   self-call `try this.attemptApplyImmediate(idx) catch { emit ImmediateEntrySkipped(idx, revertData); }`
   and advance.
7. **Meta hook**: if `_transientExecutionIndex < _transientExecutions.length`
   AND `msg.sender.code.length > 0`, fire `IMetaCrossChainReceiver.executeMetaCrossChainTransactions()`
   so the caller can drive remaining transient entries via cross-chain proxy calls.
8. **Cleanup transient tables**, then `_publishRemainder(batch)` (**unconditionally** — even
   if the meta hook left transient entries unconsumed), then
   `emit BatchPosted(batch.rollupIdsWithProofSystems.length)`.

### Reentrancy reasoning

The two external calls during step 3 (`IRollupContract.checkProofSystemsAndGetVkeys`,
`IProofSystem.verify`) are both `view`. The Solidity compiler emits `STATICCALL` for
view-marked interface calls. Inside a STATICCALL frame, ALL state mutations revert at the
EVM level — `SSTORE`, `TSTORE`, `LOG`, `CREATE`, `CALL` with value, AND any nested `CALL`
that tries to do those things. The static context propagates down the call stack with no
assembly bypass. So a malicious manager or verifier cannot reenter `postAndVerifyBatch`
(state-mutating) from inside step 3 — its first `SSTORE` would revert.

The other reentrancy windows are non-view callbacks:
`IRollupContract.rollupContractRegistered` (called once from `registerRollup`) and the
`IMetaCrossChainReceiver` hook (called in step 7). Those are normal `CALL` → can reenter. Lockouts:
- Re-entry into `postAndVerifyBatch` from any path → blocked by the
  `_transientExecutions.length != 0` check in step 1 (`PostBatchReentry`). This covers both
  the same-rollup and disjoint-rollup cases without needing a separate flag.
- `EEZ.setStateRoot` (called from the manager) → gated by `RollupBatchActiveThisBlock`
  (`lastVerifiedBlock == block.number`) AND `SetStateRootNotAllowedDuringExecution`
  (`_insideExecution() == true`). The latter prevents a malicious manager from rewriting
  state mid-execution via a reentrant proxy path.

---

## Manager registration (no handoff)

### Initial registration

```solidity
function registerRollup(address rollupContract, bytes32 initialState) external returns (uint256 rollupId);
```

- Caller deploys their `IRollupContract`-conforming contract (e.g. our reference
  `src/rollupContract/Rollup.sol`, or a custom multisig / governance contract) with desired
  (proofSystems, vkeys, threshold, ownership model) baked in, then registers it.
- Registry assigns next `rollupId`, stores `(rollupContract, initialState, etherBalance=0)`.
- Fires `IRollupContract(rollupContract).rollupContractRegistered(rollupId)` — one-shot
  callback so the manager learns its id. The reference impl stores the id and rejects a
  second call (`rollupId != 0` ⇒ `AlreadyRegistered`).

### No manager handoff

There is no `setRollupContract` and no `RollupContractChanged` event. The manager binding
is set at registration and is immutable thereafter. If a rollup needs to migrate to a new
manager, the off-chain orchestrator must register a new rollupId pointing at the new
manager and migrate state out-of-band.

### Owner escape (state root)

```solidity
function setStateRoot(uint256 rollupId, bytes32 newStateRoot) external;
```

- Callable only by the registered manager (`msg.sender == rollups[rid].rollupContract`).
- Reverts `RollupBatchActiveThisBlock` if any batch hit `rid` earlier this block.
- Reverts `SetStateRootNotAllowedDuringExecution` if `_insideExecution()` is true.
- The single state-mutating call from manager into registry.

---

## What's been removed (and why)

| Removed | Why |
|---|---|
| `IZKVerifier.sol` | Renamed/generalized to `IProofSystem.sol` — same interface. |
| `ProofSystemRegistry.sol` | Implicit in each rollup's vkey map. Each rollup owner vets their own PSes. |
| `_rollupIdByContract` reverse map | Manager passes `rollupId` explicitly via callbacks (`rollupContractRegistered`). |
| `RollupConfig.owner` / `threshold` / `proofSystemCount` | All on the per-rollup manager. Registry just stores `rollupContract` pointer + state root + ether. |
| `EEZ.setStateByOwner` / `setVerificationKey` / `addProofSystem` / `removeProofSystem` / `setThreshold` / `transferRollupOwnership` | All moved to the manager. |
| `IRollupContract.threshold()` (separate getter) | Manager enforces threshold internally inside `checkProofSystemsAndGetVkeys`; never read separately. |
| `IRollupContract.owner()` probe in `registerRollup` | Registry makes no assumption about ownership model. |
| `setRollupContract` / `RollupContractChanged` (manager handoff) | Removed. Manager binding is immutable after registration. |
| `_inPostBatch` flag | Replaced by `_transientExecutions.length != 0` reentry check. |
| `_validateRelevance` (anti-griefing PS-relevance check) | Manager's threshold check covers it; unrelated PSes are wasted gas the orchestrator pays. |
| "Drained cleanly" gate before `_publishRemainder` | Removed — `_publishRemainder` runs **unconditionally** (even if the transient prefix wasn't fully drained). `StateDelta.currentState` is the soundness backstop for the persistent path. |
| `EEZ.ThresholdNotMet` / `UnrelatedProofSystem` errors | No longer thrown by the registry. |
| Single-prover `postBatch(entries[], lookupCalls[], transientCount, transientLookupCallCount, blobCount, callData, proof)` | Replaced by `postAndVerifyBatch(ProofSystemBatchPerVerificationEntries batch)` — single struct, NOT an array. |
| Multi-sub-batch `postBatch(ProofSystemBatch[] batches)` (intermediate shape) | Collapsed to a single batch per call with explicit per-rollup `proofSystemIndex[]`. |
| Global `executions[]` / `executionIndex` / `lastStateUpdateBlock` | Replaced by per-rollup `verificationByRollup[rid].queue` / `cursor` / `lastVerifiedBlock`. |

---

## Trust model

- **Each rollup is its own security domain.** Compromise of a rollup's manager only affects
  that rollup's state root + queue. Cannot affect other rollups' state.
- **The rollup owner trusts their own proof system(s) and threshold.** Registry makes no
  judgment about whether a PS is "real"; just calls `verify(...)` and trusts the return.
- **Atomic verification across the batch.** All proofs in a `postAndVerifyBatch` call must
  verify; if any fails, the whole call reverts. This is what makes
  `crossProofSystemInteractions` load-bearing across PSes.
- **The orchestrator (`postAndVerifyBatch` caller) pays for any waste.** Unrelated PSes,
  unconsumed transient entries, etc. — registry doesn't grief-check.

---

## Open / pending design decisions

- **`registerRollup` initial state overwrite**: callback fires AFTER the pointer is set,
  so the new manager can call `setStateRoot` to overwrite `initialState`. Cosmetic (owner
  controls anyway) but the `RollupCreated` event's `initialState` field becomes unreliable.
- **Double-registration of same manager address**: a custom manager without the one-shot
  `rollupContractRegistered` guard (the reference impl's `rollupId != 0` ⇒ `AlreadyRegistered`)
  could be registered for two rollupIds, controlling both via shared `msg.sender`.
  Acceptable per the per-rollup trust model but worth documenting.
- **`rollupId == 0` (MAINNET) excluded from batches**: the strict-increasing check
  starting at `MAINNET_ROLLUP_ID = 0` makes `rollupId == 0` unpostable. Pre-existing pattern;
  document the deployer-passes `startingRollupId >= 1` invariant.
- **`_processNCalls` runs before `_applyStateDeltas`**: outer entry's state deltas applied
  at end. Reentrant entries from other rollups apply their own deltas during dispatch. By
  design, document.
- **`_processNLookupCalls` rolling hash format differs** from the main rolling hash (no
  CALL_BEGIN/CALL_END tags). Pre-existing simplification; document or align.
- **Possible "join" of `Action` and `L2ToL1Call`**: the two structs have overlapping
  shape (target, value, data, sourceAddress, sourceRollupId, plus a few extras each). The
  `Action` struct is off-chain-only (used by tooling to compute `crossChainCallHash`) while
  `L2ToL1Call` is the on-chain in-entry call type. Worth investigating whether they
  can be unified into a single struct with optional fields, or whether `L2ToL1Call`
  can subsume `Action` entirely. Trade-off: simpler mental model + one less struct vs. risk
  of conflating "the inputs that hash to crossChainCallHash" with "what executes during a call."
- **Per-(destination rollup) call ID counter**: introduce a monotonic `callId` per
  destination rollup (or maybe globally per `postAndVerifyBatch` / per cross-PS-interaction set) baked
  into each `L2ToL1Call` / `Action`. Useful for: deterministic cross-PS message
  ordering (replaces ad-hoc execution-order indexing in `crossProofSystemInteractions`),
  off-chain indexing / debugging, deduplication of identical-looking calls. Open questions:
  scope (per-rollup, per-tx, per-batch?), where the counter lives (registry storage vs.
  prover-supplied + bound by hash?), how it interacts with `revertSpan` when a call's
  state is rolled back. Worth investigating once the cross-PS interactions hash work
  starts.

---

## Audit history

Two parallel reviews were run after the latest round of changes:

- **Code-quality review**: flagged threshold-as-separate-call (now fixed by moving threshold
  inside `checkProofSystemsAndGetVkeys`), stale natspec referencing the removed reverse map,
  `StateDeltaRollupNotInBatch` error reused for lookup call destination (renamed to
  `RollupNotInBatch`), `_processNLookupCalls` rolling hash format divergence (pre-existing).
- **Security review**: HIGH on reentrancy via `_fetchVkMatrix` / `threshold()` BEFORE
  `_markVerifiedThisBlock` — fixed by hoisting the mark to step 4 (still before any external
  CALL, since steps 2/3 are static-only). MEDIUM on `rollupContractRegistered` reentrancy in
  `registerRollup` — open. MEDIUM on double-registration without unique-address check —
  open (acceptable per trust model). NEW: `setStateRoot` callable mid-execution via reentrant
  manager — fixed by `SetStateRootNotAllowedDuringExecution` guard (commit `c27c1bc`).

---

## Versioning

This document tracks the `feature/flatten` branch state. Updates are appended/edited inline
as the design evolves; commit hashes referenced in section headings where significant
changes land (TBD as we progress).
