# Multi-Prover Specification

EEZ verifies batches with multiple proof systems. Each rollup's manager defines its
accepted verifiers, verification keys and threshold.

## Architecture

- **EEZ** stores roots, ETH balances and per-rollup queues. It queries each manager's
  policy, calls proof verifiers, and executes the accepted entries.
- **Rollup managers** authorize registration and provide verification keys and block
  context. The reference Rollup also exposes owner-controlled policy and root updates.
- **Proof systems** implement `verify(proof, publicInputsHash)`. Every proof listed in
  a batch must pass before the registry changes state.

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
| `src/interfaces/IEEZL2.sol` | L2 execution structs with self-relative directional names (`CrossChainCall`, `ExpectedOutgoingCrossChainCall`, `ExecutionEntry`, `StaticExecutionEntryL2`) — leaner than L1's (no `RollupUpdate` / `destinationRollupId` / `ExpectedRootPerRollup`) |
| `src/interfaces/IMetaCrossChainReceiver.sol` | Callback fired on `postAndVerifyBatch`'s sender to drive the transient stream |
| `src/base/CrossChainProxy.sol` | CREATE2-deployed proxy per (originalAddress, originalRollupId); immutable `EEZ` points at the manager |
| `src/base/ExpectedL1ToL2CallTransient.sol` | EIP-1153 transient-storage implementation for the immediate L1→L2 reentrant table; inherited by `EEZ` and used while immediate entries execute |

## Multi-prover model

### `ProofSystemBatchPerVerificationEntries`

Each `postAndVerifyBatch` call carries a single batch struct:

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
    bytes callData;                                          // batch-scoped application data
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
- `blobHashes[i] = blobhash(batch.blobIndices[i])` — the selected tx-level 4844 blob hashes; an index the tx carries no blob at (`blobhash == 0`) reverts `BlobNotFound(index)`.
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
    uint64 entryQueueIndex; // consumption cursor
    uint64 entryQueueLength; // active execution entries / next append index
    uint64 staticEntryQueueIndex; // active static entries / next append index
    // All four uint64 counters share one storage slot.
    mapping(uint256 => ExecutionEntry) entryQueue;
    mapping(uint256 => StaticExecutionEntry) staticEntryQueue;
}
mapping(uint64 rollupId => RollupVerification record) internal verificationByRollup;
```

- `lastVerifiedBlock` serves as: (a) per-block reset marker (every verify that touches `rid`
  resets the queue bounds and cursor without deleting entries), (b) read gate for consumers (`lastVerifiedBlock == block.number`),
  (c) lockout signal for the `setRoot` owner-escape path.
- `entryQueue` and `staticEntryQueue` are per-rollup deferred-consumption stores. Each
  entry's / static entry's `destinationRollupId` selects which queue receives it during
  `_saveRemainderEntries`.

### Reset on every verify

`_markVerifiedBlockAndResetQueues(rid)` zeros `entryQueueLength`, `staticEntryQueueIndex`, and the consumption cursor without deleting mapping entries on
**every** verify — including a same-block re-verify, which therefore REPLACES (does not append
to) the prior batch's entries. Stale entries from prior blocks are unreachable anyway because
consumers gate on `lastVerifiedBlock == block.number`. Appends overwrite retained slots from index zero, and scans stop at the active bounds. Static reads do not advance `staticEntryQueueIndex`; it is the active count, not a consumption cursor.

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
  A mutable reentrant no-match folds `CALL_NOT_FOUND` into the rolling hash so the entry
  fails its final `RollingHashMismatch` check. Static lookup retries candidates whose
  callback-result hashes mismatch, without advancing a cursor; exhaustion instead
  reverts `ExecutionNotFound`. Same-key alternatives support local writes between reads
  ([STATIC_ENTRY §4.4](STATIC_ENTRY.md#44-local-writes-between-identical-static-reads)).
  This also applies to top-level static pools; the active table scope never changes
  during retry.

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

1. **Reentry check** — `if (_insideExecution() || _transientEntriesLength != 0) revert PostBatchReentry();`.
   There is no separate `_inPostBatch` flag; the conditions cover executing-entry and
   meta-hook windows. Ordinary registration callbacks outside them are not blocked.
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
   each PS. A false return reverts with `InvalidProof`; a verifier revert propagates its
   original error (including reference ECDSA malformed-signature errors). Either path
   unwinds the whole batch atomically.
5. **Mark verified-this-block** (`_markVerifiedBlockAndResetQueues(rid)` for each
   rollup): resets the rollup's queue bounds and cursor without deleting entries on every verify — a same-block
   re-verify REPLACES (does not append to) the prior batch's entries for that rollup. Sets the
   read gate for `executeCrossChainCall` / `executeL2Txs`.
6. **Drain the leading immediate L2Tx run straight from calldata**: while
   `batch.entries[i].proxyEntryHash == 0` (within the immediate prefix), self-call
   `_attemptExecuteImmediateL2Txs(batch.entries[i])`. A nonempty caught revert emits
   `L2TxSkipped(i, revertData)` and advances; empty data aborts with `ImmediateL2TxOutOfGas(i)`
   before emission (it does not prove OOG). If the nonempty run has no successes,
   `AllImmediateL2TxsFailed` unwinds the post. Every outer revert discards earlier skip logs.
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
   `emit BatchPosted(sharedPublicInput, rollupIds)`.

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
- Re-entry into `postAndVerifyBatch` during execution or the meta hook is blocked by the
  `_insideExecution() || _transientEntriesLength != 0` check in step 1 (`PostBatchReentry`).
  `_insideExecution()` covers the immediate L2Tx run and any executing entry;
  `_transientEntriesLength != 0` covers the meta-hook window. This covers both the
  same-rollup and disjoint-rollup cases without needing a separate flag. A registration
  callback outside those windows may post an otherwise valid batch; it is not itself an
  active posting window. Static verification callbacks cannot complete state writes, but
  need not fail specifically with `PostBatchReentry`.
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

- Deploy and initialize an `IRollupContract`-conforming manager before registration.
  The reference Rollup proxy initializes its owner, proof systems, vkeys and threshold
  atomically during deployment; see [the deployment guide](../deployment/README.md).
- Registry assigns next `rollupId` (a `uint64`; sequential ids stay well below 2^64), stores
  `(rollupContract, initialRoot, etherBalance=0)`.
- Fires `IRollupContract(rollupContract).rollupContractRegistered(rollupId, registrant)` — one-shot
  callback so the manager learns its id; `registrant` is the registry's own `msg.sender`. The
  reference impl requires `registrant == owner()` (else `UnauthorizedRegistrantAccount`), stores
  the id and rejects a second call (`rollupId != 0` ⇒ `AlreadyRegistered`).
- Emits `RollupCreated(rollupId, rollupContract, rollups[rollupId].root)` using the stored root after the registration callback.

### No manager handoff

The registry binds each rollup ID to its manager address at registration. A registered proxy manager can be upgraded through its own administration without changing that address.

### Owner escape (root)

```solidity
function setRoot(uint64 rollupId, bytes32 newRoot) external;
```

- Callable only by the registered manager (`msg.sender == rollups[rid].rollupContract`).
- Reverts `RollupBatchActiveThisBlock` if any batch hit `rid` earlier this block.
- Reverts `SetRootNotAllowedDuringExecution` if `_insideExecution()` is true.
- The single state-mutating call from manager into registry. Emits `RootUpdated`.

---

## Trust boundaries

- **Rollup policy:** the owner chooses trusted proof systems and their threshold.
  EEZ checks the manager's returned keys and each verifier's result; it does not
  establish circuit soundness.
- **Cross-rollup execution:** each entry must cover its destination and call sources
  in its proven rollup set. Nested targets must also belong to that set.
- **Posting and delivery:** all listed proofs must pass atomically. The poster controls
  the unproven immediate/deferred split, and unconsumed immediate work can be discarded.
  Proof acceptance does not guarantee delivery of every entry.
- **Registration callbacks:** EEZ forwards the registrant to the manager. The reference
  Rollup requires its owner and rejects repeated registration. Custom managers define
  their own registration policy and can permit multiple rollup IDs for one address.
- **Callback guards:** key lookup, custom-data lookup and proof verification are static
  calls. `postAndVerifyBatch` rejects reentry during execution and the meta hook.
  Registration callbacks outside those windows can perform otherwise permitted operations.
- **Root updates:** nested rows share the outer entry's pre-state. Only the outer entry
  applies root and ETH deltas, subject to validation and EVM rollback. Direct `setRoot`
  calls are restricted to the registered manager and the registry's execution/block guards.
- **Reserved rollup ID:** ID zero identifies L1. Registration starts at one, and batch
  validation rejects zero as a participating rollup ID.

See [Caveats](CAVEATS.md) for proof domains, freshness, funding and supported call patterns.
