# Multi-Prover Refactor — Design Notes

Living document tracking the architecture and design decisions of the multi-prover /
per-rollup-manager refactor on `feature/flatten`. Updated as the design evolves.

---

## Architecture overview

```
┌──────────────────────────────────────┐
│ Rollups.sol  (central registry)      │
│  - state roots, ether balances       │
│  - per-rollup deferred queues        │
│  - per-rollup `lastVerifiedBlock`    │
│  - cross-chain proxy registry        │
│  - postBatch / executeCrossChainCall │
│  - executeL2TX / staticCallLookup    │
│                                      │
│  Owner-escape entry points:          │
│   - setStateRoot(rid, root)          │
│   - setRollupContract(rid, newAddr)  │
└──────────────────────────────────────┘
              ▲                    ▲
              │ getVkeysFromPSes   │ rollupContractRegistered(rid)
              │ (returns vkeys     │ (one-shot init callback)
              │  iff threshold     │
              │  met internally)   │
              │                    ▼
┌──────────────────────────────────────┐
│ IRollup-conforming contracts (one    │
│ per rollup, deployed by user).       │
│ Reference impl: `Rollup.sol`         │
│  - owner                             │
│  - threshold                         │
│  - verificationKey[ps] map           │
│  - addProofSystem / removeProofSystem│
│  - setVerificationKey / setThreshold │
│  - transferOwnership / setStateRoot  │
└──────────────────────────────────────┘
              ▲ verify(proof, hash)
              │
┌──────────────────────────────────────┐
│ IProofSystem-conforming contracts    │
│ (any verifier — ZK, ECDSA, etc.)     │
│  No central registry — each rollup's │
│  manager defines its own allowed set │
└──────────────────────────────────────┘
```

### Files

| Path | Role |
|---|---|
| `src/Rollups.sol` | Central registry: state roots, queues, postBatch flow |
| `src/Rollup.sol` | Reference per-rollup manager (PS membership, vkeys, threshold, owner) |
| `src/IRollup.sol` | Interface registry calls back into per-rollup managers |
| `src/IProofSystem.sol` | Interface for proof-verifying contracts |
| `src/ICrossChainManager.sol` | Shared structs (`StateDelta`, `ExecutionEntry`, `LookupCall`, etc.) |
| `src/CrossChainProxy.sol` | CREATE2-deployed proxy per (originalAddress, originalRollupId) |
| `src/CrossChainManagerL2.sol` | L2 manager (unchanged by this refactor) |

### Deleted in this refactor

- `src/IZKVerifier.sol` — replaced by `IProofSystem.sol` (rename + generalization).
- `src/ProofSystemRegistry.sol` — no central PS registry. Each rollup's manager defines its
  own allowed set; vetting is the rollup owner's responsibility.

---

## Multi-prover model

### `ProofSystemBatch`

Each `postBatch` call carries one or more `ProofSystemBatch[]` sub-batches:

```solidity
struct ProofSystemBatch {
    address[] proofSystems;        // sorted asc, no duplicates, no zero
    uint256[] rollupIds;           // sorted asc, disjoint across sub-batches
    ExecutionEntry[] entries;
    LookupCall[] lookupCalls;
    uint256 transientCount;        // per-sub-batch transient prefix
    uint256 transientLookupCallCount;
    uint256[] blobIndices;         // selects which tx-level 4844 blobs this sub-batch consumes
    bytes callData;                // sub-batch-scoped (each PS's circuit gets its own region)
    bytes[] proof;                 // parallel to proofSystems — one proof per PS
    bytes32 crossProofSystemInteractions;  // hash binding cross-PS messages
}
```

**Counting rule:** total proofs to verify in a `postBatch` call =
Σ over sub-batches of `batch.proofSystems.length`.

**Per-rollup attestation:** each rollup `R` in `batch.rollupIds` must have its threshold met
by the count of group PSes with non-zero vkey for `R` — enforced inside the manager (see
"Threshold lives on the manager" below).

### Threshold lives on the manager

`IRollup.getVkeysFromProofSystems(addresses[])` does TWO things atomically:
1. Returns the vkey row (`bytes32(0)` for PSes not allowed for this rollup).
2. Counts non-zero entries in the row; reverts `ThresholdNotMet` if `count < threshold`.

The registry never reads `threshold` as a separate value — single external call per rollup,
no TOCTOU between two reads, no central threshold semantics. Custom managers can use any
threshold model they like (fixed M-of-N, governance-driven, time-weighted, etc.) — the
registry just consumes the returned vkeys.

### Per-PS publicInputsHash (two-stage)

```
sharedHash       = H(prevBlockhash, ts, rollupIds, entryHashes, lookupCallHashes,
                     blobHashes, H(callData), crossProofSystemInteractions)
publicInputsHash = H(sharedHash, rollupVks)   // per-PS
```

- `entryHashes[i] = keccak256(abi.encode(batch.entries[i]))` — binds the FULL `ExecutionEntry`
  struct (stateDeltas, actionHash, destinationRollupId, calls, nestedActions, callCount,
  returnData, failed, rollingHash). Prevents an orchestrator from swapping inputs at execution
  time without invalidating the proof.
- `lookupCallHashes[i] = keccak256(abi.encode(batch.lookupCalls[i]))` — same rationale.
- `rollupVks[r] = vkMatrix[r][k]` — the vkey of `proofSystems[k]` for `rollupIds[r]`.

The two-stage form was forced by EVM stack-too-deep when the publicInputsHash had too many
inputs; the single-call hash is structurally equivalent.

### Cross-PS interactions hash

`crossProofSystemInteractions` is a per-sub-batch hash committing to the set of cross-PS
boundary messages this sub-batch participates in (computed off-chain, mirrored in each PS's
circuit). All proofs in a `postBatch` must verify atomically — if PS_A claims to send msg_0
to PS_B and PS_B's commitment doesn't include msg_0, one of them won't verify and the whole
batch reverts. See `docs/hashedProofSystem.md` (port from source branch — TODO).

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

During `postBatch`, the leading `batch.transientCount` entries from each sub-batch are
concatenated (in sub-batch order) into a single global `_transientExecutions` array. Same
for lookup calls. The transient stream is consumed via `_transientExecutionIndex` cursor.

After the transient stream drains (or doesn't), the persistent remainder is published to
per-rollup queues unconditionally. Soundness backstop: each entry's `StateDelta.currentState`
is checked at consumption time; entries whose preconditions don't match the on-chain state
revert `StateRootMismatch`. So dropped transient leftover doesn't poison persistent
consumers — they just fail their own state-root check if they depended on it.

---

## `postBatch` flow (current)

1. **Structural validation** (no external calls). Per sub-batch: sorted/disjoint rollupIds,
   each registered (`rollupContract != 0`), proofSystems sorted (rejects zero/duplicates),
   entry/staticCall `destinationRollupId` ∈ `rollupIds`, transient bounds.
2. **Fetch + verify per sub-batch (single loop)**: for each sub-batch, fetch its vkMatrix
   via `IRollup.getVkeysFromProofSystems` (manager enforces threshold internally — reverts if
   not met) and immediately verify every proof in that sub-batch via
   `IProofSystem.verify(proof[k], publicInputsHash[k])`. Single loop means the vkMatrix is
   scoped to one iteration; no `bytes32[][][]` allocation for the whole batch. ALL proofs
   across ALL sub-batches must verify atomically (one revert reverts the whole call).
3. **Mark verified-this-block** for every rollup touched by any sub-batch. Sets the
   once-per-block-per-rollup invariant AND the read gate for `executeCrossChainCall` /
   `executeL2TX` (which require `lastVerifiedBlock(rid) == block.number`).
4. **Load transient stream**: concatenate each sub-batch's leading prefix.
5. **Drain leading immediate entries inline**: any leading run of transient entries with
   `actionHash == 0` runs inline (each gets its own `_applyAndExecute` cycle).
6. **Meta hook**: if `msg.sender` is a contract, fire `executeMetaCrossChainTransactions()`
   so the caller can drive remaining transient entries via cross-chain proxy calls.
7. **Cleanup transient tables** (whether the hook drained them or not).
8. **Publish remainder** unconditionally — push each sub-batch's remainder (entries past
   its `transientCount`) into per-rollup queues by `destinationRollupId`.

### Reentrancy reasoning

The two external calls during step 2 (`IRollup.getVkeysFromProofSystems`, `IProofSystem.verify`)
are both `view`. The Solidity compiler emits `STATICCALL` for view-marked interface calls.
Inside a STATICCALL frame, ALL state mutations revert at the EVM level — `SSTORE`, `TSTORE`,
`LOG`, `CREATE`, `CALL` with value, AND any nested `CALL` that tries to do those things. The
static context propagates down the call stack with no assembly bypass. So a malicious manager
or verifier cannot reenter `postBatch` (state-mutating) from inside step 2 — its first
`SSTORE` would revert.

This is why step 3 (`_markVerifiedThisBlock`, the persistent-state side effect) can sit
AFTER step 2 instead of before: the only paths that mutate state in step 2 are forbidden by
STATICCALL.

The OTHER reentrancy windows are non-view callbacks: `IRollup.rollupContractRegistered` (called from
`createRollup` and `setRollupContract`) and the `IMetaCrossChainReceiver` hook (called in
step 6). Those are normal CALL → can reenter. Lockouts:
- Same-rollup re-entry into `postBatch` → blocked by `lastVerifiedBlock == block.number`
  (`RollupAlreadyVerifiedThisBlock`).
- Disjoint-rollup re-entry into `postBatch` (e.g., the hook calls `postBatch` for a different
  rollup set) → blocked by an explicit transient flag `_inPostBatch` (`PostBatchReentry`).
  Without this flag, the nested call would corrupt the SHARED `_transientExecutions` /
  `_transientLookupCalls` / `_transientExecutionIndex` storage (different rollupIds but the
  same physical slots). Flag is set on entry, cleared on exit.
- `Rollups.setStateRoot` and `Rollups.setRollupContract` (called from the manager) → gated
  by `RollupBatchActiveThisBlock` (`lastVerifiedBlock == block.number`).

---

## Manager substitution / handoff

### Initial registration

```solidity
function createRollup(address rollupContract, bytes32 initialState) external returns (uint256 rollupId);
```

- Caller deploys their `IRollup`-conforming contract (e.g. our reference `Rollup.sol`,
  or a custom multisig / governance contract) with desired (proofSystems, vkeys, threshold,
  ownership model) baked in, then registers it.
- Registry assigns next `rollupId`, stores `(rollupContract, initialState, etherBalance=0)`.
- Fires `IRollup(rollupContract).rollupContractRegistered(rollupId)` — one-shot callback so the
  manager learns its id. The reference impl latches `rollupIdSet=true`.

### Handoff

```solidity
function setRollupContract(uint256 rollupId, address newContract) external;
```

- Callable only by the current manager (`msg.sender == rollups[rid].rollupContract`).
- Locked out for the rest of the block once any postBatch has touched this rollup
  (`RollupBatchActiveThisBlock`).
- Updates the pointer, fires `rollupContractRegistered(rollupId)` on `newContract`.
- Old manager is dropped; new manager learns its id.

### Owner escape (state root)

```solidity
function setStateRoot(uint256 rollupId, bytes32 newStateRoot) external;
```

- Callable only by the current manager. Manager passes `rollupId` explicitly (no reverse
  lookup needed).
- Same block-active lockout as `setRollupContract`.
- The single state-mutating call from manager into registry.

---

## What's been removed (and why)

| Removed | Why |
|---|---|
| `IZKVerifier.sol` | Renamed/generalized to `IProofSystem.sol` — same interface. |
| `ProofSystemRegistry.sol` | Implicit in each rollup's vkey map. Each rollup owner vets their own PSes. |
| `_rollupIdByContract` reverse map | Manager passes `rollupId` explicitly via callbacks (`rollupContractRegistered`). |
| `RollupConfig.owner` / `threshold` / `proofSystemCount` | All on the per-rollup manager. Registry just stores `rollupContract` pointer + state root + ether. |
| `Rollups.setStateByOwner` / `setVerificationKey` / `addProofSystem` / `removeProofSystem` / `setThreshold` / `transferRollupOwnership` | All moved to the manager. |
| `IRollup.threshold()` | Manager enforces threshold internally inside `getVkeysFromProofSystems`; never read separately. |
| `IRollup.owner()` probe in `createRollup`/`setRollupContract` | Registry makes no assumption about ownership model. |
| `_validateRelevance` (anti-griefing PS-relevance check) | Manager's threshold check covers it; unrelated PSes are wasted gas the orchestrator pays. |
| "Drained cleanly" gate before `_publishRemainder` | Always publish — `StateDelta.currentState` is the soundness backstop. |
| `Rollups.ThresholdNotMet` / `UnrelatedProofSystem` errors | No longer thrown by the registry. |
| Single-prover `postBatch(entries[], lookupCalls[], transientCount, transientLookupCallCount, blobCount, callData, proof)` | Replaced by `postBatch(ProofSystemBatch[] batches)` with sub-batch shape. |
| Global `executions[]` / `executionIndex` / `lastStateUpdateBlock` | Replaced by per-rollup `verificationByRollup[rid].queue` / `cursor` / `lastVerifiedBlock`. |

---

## Trust model

- **Each rollup is its own security domain.** Compromise of a rollup's manager only affects
  that rollup's state root + queue. Cannot affect other rollups' state.
- **The rollup owner trusts their own proof system(s) and threshold.** Registry makes no
  judgment about whether a PS is "real"; just calls `verify(...)` and trusts the return.
- **Atomic verification across sub-batches.** All proofs in a `postBatch` call must verify;
  if any fails, the whole call reverts. This is what makes `crossProofSystemInteractions`
  load-bearing across PSes.
- **The orchestrator (postBatch caller) pays for any waste.** Unrelated PSes, unconsumed
  transient entries, etc. — registry doesn't grief-check.

---

## Open / pending design decisions

- **`rollupContractRegistered` reentrancy in `setRollupContract`**: callback fires AFTER the pointer
  update. A malicious new manager's `rollupContractRegistered` impl could call `setRollupContract`
  again during the callback (since `msg.sender == rollupContract` is true). Mitigation
  candidates: invoke callback BEFORE pointer update, or add a transient reentrancy flag.
- **`createRollup` initial state overwrite**: same window — callback fires AFTER pointer is
  set, can call `setStateRoot` to overwrite `initialState`. Cosmetic (owner controls anyway)
  but the `RollupCreated` event's `initialState` field becomes unreliable.
- **Double-registration of same manager address**: a custom manager without `rollupIdSet`
  guard could be registered for two rollupIds, controlling both via shared `msg.sender`.
  Acceptable per the per-rollup trust model but worth documenting.
- **Handoff back to a previously-used reference manager**: `Rollup.rollupContractRegistered`'s
  `rollupIdSet` permanent latch means an A→B→A handoff is impossible. Could relax to allow
  re-init when `_rollupId == rollupId`.
- **`rollupId == 0` (MAINNET) excluded from sub-batches**: the strict-increasing check
  starting at `MAINNET_ROLLUP_ID = 0` makes `rollupId == 0` unpostable. Pre-existing pattern;
  document the deployer-passes `startingRollupId >= 1` invariant.
- **`_processNCalls` runs before `_applyStateDeltas`**: outer entry's state deltas applied
  at end. Reentrant entries from other rollups apply their own deltas during dispatch. By
  design, document.
- **`_processNLookupCalls` rolling hash format differs** from the main rolling hash (no
  CALL_BEGIN/CALL_END tags). Pre-existing simplification; document or align.
- **Possible "join" of `Action` and `CrossChainCall`**: the two structs have overlapping
  shape (target, value, data, sourceAddress, sourceRollupId, plus a few extras each). The
  `Action` struct is off-chain-only (used by tooling to compute `actionHash`) while
  `CrossChainCall` is the on-chain in-entry call type. Worth investigating whether they
  can be unified into a single struct with optional fields, or whether `CrossChainCall`
  can subsume `Action` entirely. Trade-off: simpler mental model + one less struct vs. risk
  of conflating "the inputs that hash to actionHash" with "what executes during a call."
- **Per-(destination rollup) call ID counter**: introduce a monotonic `callId` per
  destination rollup (or maybe globally per postBatch / per cross-PS-interaction set) baked
  into each `CrossChainCall` / `Action`. Useful for: deterministic cross-PS message
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
  inside `getVkeysFromProofSystems`), stale natspec referencing the removed reverse map,
  `StateDeltaRollupNotInBatch` error reused for lookup call destination (renamed to
  `RollupNotInBatch`), `_processNLookupCalls` rolling hash format divergence (pre-existing).
- **Security review**: HIGH on reentrancy via `_fetchVkMatrix` / `threshold()` BEFORE
  `_markVerifiedThisBlock` — fixed by hoisting the mark to step 2 before any external call.
  MEDIUM on `rollupContractRegistered` reentrancy in `createRollup` / `setRollupContract` — open.
  MEDIUM on double-registration without unique-address check — open (acceptable per trust
  model).

---

## Versioning

This document tracks the `feature/flatten` branch state. Updates are appended/edited inline
as the design evolves; commit hashes referenced in section headings where significant
changes land (TBD as we progress).
