# Core Protocol Specification

**Source**: `src/`
**Purpose**: Formal reference for implementing the Rust rollup node. Supersedes informal comments in source code.

This document covers the **flat sequential execution model** layered with the **multi-prover / per-rollup-queue** model. Every cross-chain entry carries a flat list of top-level calls processed sequentially; each reentrant frame carries its **own** flat sub-array; reentrant calls resolve against a single unified expected-calls table content-addressed by the live rolling hash; and integrity is verified by a single `rollingHash` per entry. The execution structs are split per side: L1 (`src/interfaces/IEEZ.sol`) uses absolute directional names (`L2ToL1Call` / `l2ToL1Calls`, `ExpectedL1ToL2Call` / `expectedL1ToL2Calls`); L2 (`src/interfaces/IEEZL2.sol`) uses **self-relative** directional names (`CrossChainCall` / `incomingCalls`, `ExpectedOutgoingCrossChainCall` / `expectedOutgoingCalls`) because an L2's counterparty can be L1 OR another L2 — see §A.1. Entries are routed by `destinationRollupId` into per-rollup queues on L1. `postAndVerifyBatch` carries a single `ProofSystemBatchPerVerificationEntries` whose proofs verify atomically.

For the multi-prover design (batch shape, per-PS public-inputs construction, threshold semantics), see `MULTI_PROVER_SPEC.md`.

---

## Table of Contents

- [A. Data Model](#a-data-model)
- [B. Core Protocol Functions](#b-core-protocol-functions)
- [C. Action Hash Computation](#c-action-hash-computation)
- [D. Execution Model](#d-execution-model)
- [E. Rolling Hash](#e-rolling-hash)
- [F. Static Entry Resolution](#f-static-entry-resolution)
- [G. Execution Entry Lifecycle](#g-execution-entry-lifecycle)
- [H. Invariants](#h-invariants)
- [I. Security Considerations](#i-security-considerations)

---

## A. Data Model

### A.1 Core Structs

The execution structs come in **two layout-similar but separately-declared families**:

- **L1 (`src/interfaces/IEEZ.sol`)** — absolute directional names: an `L2ToL1Call` is a cross-chain call executed on L1; an `ExpectedL1ToL2Call` is a reentrant L1→L2 call fired during execution.
- **L2 (`src/interfaces/IEEZL2.sol`)** — **self-relative** directional names: an `incomingCalls[]` entry is a call executed ON this L2 on behalf of a remote caller; an `expectedOutgoingCalls[]` entry is the pre-computed result of a reentrant call fired FROM this L2. The naming is relative to the chain itself because an L2's counterparty can be L1 (mainnet) OR another L2 — absolute names like `l1ToL2Calls` would frequently be wrong.

The L2 structs are deliberately **leaner**: L2 has a single rollup, no state deltas, and no per-rollup queue interleaving, so the L1-only fields (`RollupUpdate[] rollupUpdates`, `destinationRollupId`, `ExpectedRootPerRollup[] expectedRoots`) do not exist on L2 at all. L2 never hashes a whole entry/static entry, so its layout is free to diverge from L1's.

#### Cross-chain call hash (off-chain helper)

`computeCrossChainCallHash(...)` — `public pure` on `EEZBase`, inherited by both managers. Formula, matching-site table, and off-chain helpers in §C.

#### RollupUpdate (L1 only)

Describes one rollup's state transition caused by executing one entry. The pre-state binding lives on the entry: `currentRoot` is checked at consumption time against `rollups[delta.rollupId].root`; a mismatch skips a queued candidate (`ExecutionNotFound` if none matches), while direct immediate execution reverts `RootMismatch`. This makes entries content-addressed against the trajectory the proof committed to and is the soundness backstop that lets the per-rollup queue model interleave consumption across rollups safely.

Every entry must carry **at least one** `RollupUpdate`, and the deltas must be **strictly increasing by `rollupId`** — both enforced **on-chain** at batch validation (`EntryHasNoRollupUpdates`, `RollupUpdatesNotStrictlyIncreasing`; the ≥1 check is re-asserted in `_executeEntry`). An empty `rollupUpdates[]` would leave the entry unpinned from any rollup trajectory (nothing for the `RootMismatch` backstop to check); strict ordering rejects duplicate rollups and (starting above `MAINNET_ROLLUP_ID`) a mainnet delta. The prover remains responsible for `rollupUpdates` being the entry's *true* state transition.

```solidity
struct RollupUpdate {
    uint64  rollupId;       // which rollup's state changes
    int192  etherDelta;     // signed change in rollup's ETH balance; packs with rollupId into one slot
    bytes32 currentRoot;   // expected pre-root on rollupId — checked against rollups[rid].root
    bytes32 newRoot;       // post-execution root
}
```

#### L2ToL1Call (L1) / CrossChainCall (L2)

A single call in a flat call array — the entry's top-level `l2ToL1Calls[]` / `incomingCalls[]`, or a reentrant frame's own sub-array, or a static entry's read-only sub-calls. The two structs are field-identical; only the type name differs.

```solidity
// L1 (IEEZ.sol): L2ToL1Call — L2 (IEEZL2.sol): CrossChainCall, same fields
struct L2ToL1Call {
    uint16  revertNextNCalls; // >0 force-reverts the next N calls (this one included); see §D.4
    bool    isStatic;         // dispatch via STATICCALL (read-only, no value); see §D.2
    uint64  gas;              // gas limit for the target call; 0 = forward all remaining gas
    address sourceAddress;    // originating address on the source rollup
    uint64  sourceRollupId;   // originating rollup
    address targetAddress;    // call target on this chain
    uint256 value;            // ether to send (must be 0 when isStatic)
    bytes   data;             // calldata
}
```

#### ExpectedL1ToL2Call (L1) / ExpectedOutgoingCrossChainCall (L2)

One **unified reentrant table** per entry holds every kind of reentrant cross-chain call fired during execution — plain SUCCESS, read-only STATIC, and try/catch'd REVERTED (`success == false`). Each row is content-addressed by a single position key:

```
expectedL1toL2Hash == keccak256(abi.encodePacked(crossChainCallHash, expectedRollingHash))
// L2 field name: expectedOutgoingHash — same formula (_computeExpectedL1toL2Hash on EEZBase)
```

`crossChainCallHash` folds `isStatic` (a static read keys distinctly from a state-changing call) plus the routed rollup, so neither needs its own field; `expectedRollingHash` is the live `_rollingHash` at the instant the call fires, which binds the recorded execution context. Local writes and reverted frames can leave the same key available for another call.

```solidity
// L1 (IEEZ.sol): ExpectedL1ToL2Call — L2 (IEEZL2.sol): ExpectedOutgoingCrossChainCall
struct ExpectedL1ToL2Call {
    bytes32      expectedL1toL2Hash;          // position key: keccak256(crossChainCallHash, expectedRollingHash)
    L2ToL1Call[] l2ToL1Calls;                 // the reentrant frame's OWN sub-calls, processed in order (subject to gas checks)
    bytes32      revertedOrStaticRollingHash; // expected sub-call rolling hash: checked for STATIC / REVERTED; must be 0 on SUCCESS rows (prover constraint, §A.1)
    bool         success;                     // whether the reentrant call returns or reverts
    bytes        returnData;                  // pre-computed return value (revert payload when !success)
}
```

Every kind carries its **own** `l2ToL1Calls[]` sub-array, processed in order (subject to gas checks) — there is no shared flat-array partition and no `callCount` field. Resolution:

- **SUCCESS** (`success == true`, matched via `_consumeNestedCall` with an `isStatic == false` key): `_resolveNestedReentrant` runs the sub-array as a COMMITTING sub-execution, folding into the host's continuous `_rollingHash` between `NESTED_BEGIN` / `NESTED_END`, then returns `returnData`. `revertedOrStaticRollingHash` is required to be zero on this path (`SuccessRowWithRevertedOrStaticHash` otherwise).
- **REVERTED** (`success == false`, same key shape): `_resolveNestedReentrant` runs the sub-array as a mini-entry, checks the resulting `_rollingHash` against `revertedOrStaticRollingHash`, then reverts with `returnData` — the terminal revert rolls back the frame's state, hash, and cursor.
- **STATIC** (key computed with `isStatic == true`, matched via `staticCrossChainCall`): `_resolveStaticEntry` runs the sub-array via STATICCALL (untagged hash, §E.2) against `revertedOrStaticRollingHash` and returns `returnData` (reverts with it when `!success`).

A reverted sub-execution reuses the host table for its own reentrant calls (Solidity forbids recursive structs); the live `_rollingHash` folded into each key keeps the contexts distinct.

#### ExecutionEntry

The central execution unit. Loaded by `postAndVerifyBatch` (L1) or `loadExecutionTable` / `executeIncomingCrossChainCall` (L2). The two sides declare separate structs:

```solidity
// L1 (IEEZ.sol)
struct ExecutionEntry {
    RollupUpdate[]         rollupUpdates;          // the entry's true state transition (≥1, enforced on-chain)
    bytes32              proxyEntryHash;       // inbound proxy-entry call hash; bytes32(0) = L2Tx entry
    L2ToL1Call[]         l2ToL1Calls;          // the entry's TOP-LEVEL calls (reentrant frames carry their own)
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;  // unified reentrant table; see above
    bytes32              rollingHash;          // expected rolling hash over all calls + nestings
    uint64               destinationRollupId;  // routes to a per-rollup queue; must be ∈ rollupUpdates
    bool                 success;              // whether the entry returns or reverts
    bytes                returnData;           // pre-computed top-level return value (revert payload when !success)
}
```

```solidity
// L2 (IEEZL2.sol) — no rollupUpdates, no destinationRollupId
struct ExecutionEntry {
    bytes32                          proxyEntryHash;        // hash of the inbound call — never bytes32(0) on L2 (no zero-hash consumption path; executeL2Txs is L1-only)
    CrossChainCall[]                 incomingCalls;         // the entry's TOP-LEVEL calls
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls; // unified reentrant table
    bytes32                          rollingHash;
    bool                             success;
    bytes                            returnData;
}
```

A top-level entry carries a `success` flag. When `success == true`, the entry runs, verifies, and the top-level call returns `entry.returnData`. When `success == false`, the entry is run and verified (rolling hash + ether invariant) exactly as a successful one, then **reverted with `entry.returnData`** so all of its state effects roll back — the top-level call fails and the caller may try/catch it. Because the revert also rolls back the cursor advance, a `success == false` entry is re-callable; the forward-scan consumption (§D.1) reaches past it once a later successful consumption advances beyond it. A top-level reverting *read* is a `StaticExecutionEntry` instead.

#### Prover constraints

These obligations include remote truth, canonical encoding and funding policy. Local structural checks cannot establish circuit soundness or remote execution truth. Where a cheap local check exists the contracts check defensively (error in parentheses); other guarantees depend on the actual circuit/system implementation.

L1:
- `rollupUpdates` are the entry's TRUE state transition. On a `success == false` entry, `newRoot` is written then unwound and never compared — supplied for completeness. *Circuit-only.*
- L2Tx entries (`proxyEntryHash == bytes32(0)`): `success == true`, empty `returnData` — no proxy consumer. *(Defensive check at batch validation: `L2TxEntryNotCanonical` — an unchecked queued violator would be a poison entry, its revert keeping its pins live so every later `executeL2Txs(rid)` re-matches it that block.)*

L2:
- `executeIncomingCrossChainCall`: `entries[0].incomingCalls[0]` equals the call that actually arrived from the source rollup — a cross-chain fact, *circuit-only*. Its `gas` is bound on-chain (folded into `proxyEntryHash`); the rest of `entries[0]` stays fully general — `success == false` reverts the whole delivery, and `revertNextNCalls` on the inbound call rolls back its destination effects while the delivery commits.
- System funding must back the executed incoming transfers. The contract pools `msg.value`, permits partial consumption, and retains balance when tables are replaced; it does not enforce a per-load equality to committed or consumed values. The node/circuit must define aggregate inventory, funding and residual handling across loads/reverts before claiming conservation. See [L2 funding and inventory](#l2-funding-and-inventory).
- **Lookups are never delivered.** L2 state and the L2 root change only for cross-chain work L1 can prove it executed. A top-level static read, an L1→L2 call that reverts on L2, and an L1→L2 call whose L1 frame is reverted afterwards are all *lookups*: the composer simulates the call, the prover signs its return or revert data (the L1 entry's `returnData`, and the blob so the user can read it), nothing is applied on L2, the root does not move, and no `executeIncomingCrossChainCall` tx exists for it in the sync block. The rule is uniform — there is no root-only checkpoint or synthetic entry that catches a root up after a failed delivery. On L1 the matching `success == false` entry unwinds its root update with its revert (above), so both sides agree the root did not move. The rule is direction-specific: an L2→L1 call that reverts on L1 IS delivered — the L2Tx entry runs it on L1 and `CALL_END(false, revertData)` records the revert — because L1 executes it itself. *Composer / circuit rule.*

Both sides:
- SUCCESS rows of the unified reentrant table carry `revertedOrStaticRollingHash == bytes32(0)` — the field is only read on the STATIC / REVERTED paths. *(Defensive check at resolution: `SuccessRowWithRevertedOrStaticHash`.)*
- **Static alternatives per key.** Static reads change neither `_rollingHash` nor the cursor. Multiple rows may share a key: lookup tries each candidate until its callback-result hash matches. Builders must provide/prove the required alternatives and reject incompatible outcomes when multiple candidates can validate; the first hash-valid row wins. *Circuit / builder rule.* See [STATIC_ENTRY §4.4](STATIC_ENTRY.md#44-local-writes-between-identical-static-reads) for all four local-write cases, candidate construction, retry outcomes and E2E evidence. Do not deduplicate static rows by key alone; skipped candidates execute local callback validation but do not create additional logical remote frames.
- Static sub-calls carry `revertNextNCalls == 0` — static resolution has no state to roll back. *(Defensive check in `_processStaticL2ToL1Calls`: `StaticCallWithRevertSpan`.)*
- Tables contain exactly the rows/entries the simulated trace resolves; anything beyond is inert padding. *Circuit-only.*

There is no `callCount` field and no flat-array partition: `_processL2ToL1Calls` (L1) / `_processIncomingCalls` (L2) runs each frame's whole array, so call ordering is structural; gas shortage can terminate the current local array (§D.2/§H.4).

#### ExpectedRootPerRollup (L1 only)

A root pin. Two uses:

1. On a `StaticExecutionEntry`: content-addresses the static entry to a point on each pinned rollup's trajectory — a candidate only MATCHES when every pin equals the live `rollups[rollupId].root` (full-scan semantics: a mismatching candidate is skipped, not reverted on).
2. On the batch (`batch.expectedRootPerRollup`): optional composer-supplied assertions checked at the very top of `postAndVerifyBatch`; any mismatch reverts `ExpectedRootMismatch(rid)`.

```solidity
struct ExpectedRootPerRollup {
    uint64  rollupId;
    bytes32 root;
}
```

#### StaticExecutionEntry (TOP-LEVEL static entries — storage pool)

Pre-computed result for a **top-level read-only** cross-chain call, resolved via `staticCrossChainCall` OUTSIDE any execution, from the pool (`_transientStaticEntries` / per-rollup `staticEntryQueue` on L1; the persistent `staticEntries` array on L2). Reverting top-level reads land here (`success == false` ⇒ resolution reverts with `returnData`); state-changing top-level calls are `ExecutionEntry`s. There is no reentrant table — a reentrant read during resolution re-enters the pool as ANOTHER `StaticExecutionEntry`. Referenced proxies must already be deployed (CREATE2 is unavailable inside a STATICCALL frame).

```solidity
// L1 (IEEZ.sol)
struct StaticExecutionEntry {
    ExpectedRootPerRollup[] expectedRoots;  // root pins — part of the MATCH predicate
    bytes32                      proxyEntryHash;      // inbound proxy-entry call hash (isStatic = true in the preimage)
    L2ToL1Call[]                 l2ToL1Calls;         // read-only sub-calls run via STATICCALL during resolution
    bytes32                      rollingHash;         // untagged static schema: keccak256(prev, success, retData)
    uint64                       destinationRollupId; // routes the pool entry; must be ∈ expectedRoots
    bool                         success;             // false ⇒ resolution reverts with returnData
    bytes                        returnData;
}
```

```solidity
// L2 (IEEZL2.sol) — no expectedRoots, no destinationRollupId
struct StaticExecutionEntryL2 {
    uint256          expectedEntryIndex; // must equal the live next-entry cursor
    bytes32          proxyEntryHash;
    CrossChainCall[] incomingCalls;
    bytes32          rollingHash;
    bool             success;
    bytes            returnData;
}
```

Match: `proxyEntryHash` + `destinationRollupId` + all root pins live on L1 (full scan); `proxyEntryHash` + `expectedEntryIndex == entryIndex` on L2.

#### ProxyInfo

```solidity
struct ProxyInfo {
    bool    isProxy;          // existence flag, set on registration
    address originalAddress;
    uint64  originalRollupId;
}
```

#### RollupConfig (L1 only)

```solidity
struct RollupConfig {
    address rollupContract;   // per-rollup IRollupContract-conforming manager (owner / vkeys / threshold live there); immutable after registration
    bytes32 root;        // current committed root
    uint256 etherBalance;     // ETH held on behalf of this rollup
}
```

The central registry holds no owner or vkey — those live on each rollup's `rollupContract` (reference impl: `src/rollupContract/Rollup.sol`). See `MULTI_PROVER_SPEC.md` for the per-rollup-manager model.

#### RollupVerification (L1 only)

Per-rollup entry queue, static-entry queue, cursor, and verified-this-block marker.

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
```

Queue resets zero the active bounds and consumption cursor without deleting mapping entries. Appends reuse slots from index zero; lookups stop at the active bounds, so retained entries cannot be consumed. Replacing an entry copies all its fields; Solidity may still clear truncated nested arrays or bytes during that assignment.

### A.2 Storage Layout

#### EEZ.sol (L1) — inherits `EEZBase`

| Variable | Type | Notes |
|----------|------|-------|
| `rollupCounter` | uint64 | Last assigned rollup ID (`registerRollup` assigns `++rollupCounter`) |
| `rollups` | mapping(uint64 ⇒ RollupConfig) | Per-rollup config (manager pointer + root + ether) |
| `verificationByRollup` | internal mapping(uint64 ⇒ RollupVerification) | Per-rollup deferred queues + cursor (public views: `lastVerifiedBlock(rid)`, `queueLength(rid)`, `entryQueueIndex(rid)`) |
| `_transientEntries` | mapping(uint256 ⇒ ExecutionEntry) (internal) | Ordinary storage meta-hook entries; each used slot is deleted after the batch |
| `_transientStaticEntries` | mapping(uint256 ⇒ StaticExecutionEntry) (internal) | Ordinary storage TOP-LEVEL static entries for the meta-hook phase; each used slot is deleted after the batch |
| immediate-L2Tx reentrant table | EIP-1153 transient region (`ExpectedL1ToL2CallTransient`) | Reentrant table of the ONE immediate L2Tx entry currently executing — hand-serialized into transient slots (`src/base/ExpectedL1ToL2CallTransient.sol`) because the immediate run executes entries straight from calldata (never SSTOREd whole) and a proxy re-entry crosses an external boundary; written before `_executeEntry`, cleared right after (a revert rolls it back) |
| verified-rollup set | EIP-1153 namespaced count and ID slots (`VerifiedRollupsTransient`) | `_pushVerifiedRollup` appends the entry's allowed rollup IDs; `_clearVerifiedRollups` zeroes the count, hiding stale tail slots. `_verifiedRollupCount() != 0` means executing; `_containsVerifiedRollup` checks membership |
| `_transientEntriesLength` / `_transientStaticEntriesLength` | `uint256 transient` | Active batch-scoped mapping bounds; the execution length flags the meta-hook reentry window; both reset after each batch |
| `_transientEntryIndex` | `uint256 transient` | Global cursor into `_transientEntries` (cross-rollup, intra-`postAndVerifyBatch`) |
| `_currentEntryRollupId` | `uint64 transient` | Rollup whose persistent queue supplies the executing entry (so `_getExpectedL1toL2Calls()` finds the right queue); set only by `_consumeAndExecuteEntry`'s persistent branch, `0` everywhere else |
| `_lastL1ToL2CallConsumed` | `uint256 transient` | Forward-scan position into the entry's unified `expectedL1ToL2Calls[]` |
| `_entryEtherDelta` | `int256 transient` | Net ether flow for the current entry (`Σ inbound msg.value − Σ successful outbound call value`); the accounting side of the ether-delta invariant (§H.2). Top-level entry points SET it (`executeCrossChainCall`) or require it zero (`executeL2Txs` / `_attemptExecuteImmediateL2Txs` revert `ResidualEntryEtherIn`); reentrant calls ADD; successful value calls SUBTRACT; reset at the end of `_executeEntry`. **L1 only** |

Inherited from `EEZBase`:

| Variable | Type | Notes |
|----------|------|-------|
| `authorizedProxies` | mapping(address ⇒ ProxyInfo) | Registered proxies |
| `_rollingHash` | `bytes32 transient` | Rolling hash accumulator |
| `_currentEntryIndex` | `uint256 transient` | Index of the entry being executed (into `_transientEntries`, the persistent queue, or L2's `entries`) |

There is **no transient flat-call cursor**: the position inside a flat call array is a plain local index in `_processL2ToL1Calls` (L1) / `_processIncomingCalls` (L2) (it survives reentrant proxy calls on the call stack), and each frame carries its own array.

`MAINNET_ROLLUP_ID = 0` is a constant (uint64). The six rolling-hash tag constants `CALL_BEGIN=1, CALL_END=2, NESTED_BEGIN=3, NESTED_END=4, CALL_NOT_FOUND=5, CALL_INSUFFICIENT_GAS=6` plus the readability constants `NOT_STATIC_CALL = false` / `IS_STATIC = true` are internal constants on `EEZBase`. There is no `_inPostBatch` flag — `postAndVerifyBatch` reentry is detected via `_insideExecution() || _transientEntriesLength != 0`.

`_transientEntries` / `_transientStaticEntries` are declared as regular storage mappings (not Solidity `transient`) because the `transient` data location does not yet support reference types with nested dynamic arrays; each used mapping entry is deleted at the end of every `postAndVerifyBatch`. Those storage clears can earn refunds, capped at 20% of transaction gas and applied after execution. Both transient length counters and the cursor are explicitly reset after the batch so another batch can run in the same transaction. The verified-rollup set and immediate-L2Tx reentrant table instead use EIP-1153 transient storage. The latter lives in a hand-serialized EIP-1153 transient region (`src/base/ExpectedL1ToL2CallTransient.sol`), so it never touches storage and rolls back with reverts automatically.

#### EEZL2.sol (L2) — inherits `EEZBase`

L2-specific storage:

| Variable | Type | Notes |
|----------|------|-------|
| `entries` | mapping(uint256 ⇒ ExecutionEntry) (public) | Reusable execution slots; only indices below `entriesLength` are active |
| `staticEntries` | mapping(uint256 ⇒ StaticExecutionEntryL2) (public) | Reusable static slots; only indices below `staticEntriesLength` are active |
| `lastLoadBlock` | uint256 | Block of last `loadExecutionTable` / `executeIncomingCrossChainCall` |
| `entryIndex` | uint256 | Cursor into the active execution prefix |
| `entriesLength` / `staticEntriesLength` | uint256 | Active table bounds, reset on every load; retained slots beyond them cannot be consumed |
| `_executing` | `bool transient` | Set at `_executeEntry` start, cleared at its end; backs `_insideExecution()` (L1 derives the same predicate from its proxy-protection array, which L2 doesn't have) |
| `_lastOutgoingCallConsumed` | `uint256 transient` | Forward-scan position into the entry's unified `expectedOutgoingCalls[]` |

The shared rolling-hash transient fields, proxy registry, and base-event/error set are inherited from `EEZBase`.

Immutables: `ROLLUP_ID` (non-zero; 0 reverts `InvalidRollupId` — it is the mainnet sentinel in call hashes), `SYSTEM_ADDRESS` (not validated; `address(0)` is accepted for chains whose system caller is the zero address), and `USE_GAS_LEFT` (`callGas` in outgoing hashes: `gasleft()` when true, `0` when false). `RECOVERY_ADDRESS` is a separate nonzero immutable, configured by the fourth constructor argument; zero reverts `InvalidRecoveryAddress`, as on L1. Proxy construction sweeps prefunded ETH to this address. Outgoing call value still goes to `SYSTEM_ADDRESS`.

The constructor is `EEZL2(uint64 rollupId, address systemAddress, bool useGasLeft, address recoveryAddress)`. Indexed mapping getters may expose retained inactive rows; callers must use the active lengths.

### A.3 Transient Variables and `_insideExecution`

`_insideExecution()` is `_verifiedRollupCount() != 0` on L1 (every entry has ≥1 delta; namespaced transient ID slots are populated at `_executeEntry` start and their count is cleared at its end) and the transient `_executing` flag on L2. A revert anywhere rolls the marker back automatically.

The transient variables are read by `executeCrossChainCall` (to route to `_consumeAndExecuteEntry` vs `_consumeNestedCall`) and by `staticCrossChainCall` (to compute the position key `keccak256(crossChainCallHash, _rollingHash)`). `tload` works in static context, so `staticCrossChainCall` can read them. They are reset implicitly between transactions by EIP-1153.

---

## B. Core Protocol Functions

### B.1 EEZ.sol (L1)

#### `registerRollup`

```solidity
function registerRollup(address rollupContract, bytes32 initialRoot)
    external returns (uint64 rollupId)
```

No registry-wide admission allowlist; each manager authorizes its own registrant. EEZ forwards its original `msg.sender` as `registrant`, and the reference Rollup requires that address to equal its current owner (otherwise `UnauthorizedRegistrantAccount(registrant)`). A rejected callback rolls back the counter and initial state. `rollupId = ++rollupCounter` (a `uint64` counter; first assigned id is 1; 0 is `MAINNET_ROLLUP_ID`); `rollups[rollupId] = RollupConfig(rollupContract, initialRoot, 0)`. Reverts `InvalidRollupContract` if `rollupContract` is `address(0)` or the registry itself. Fires `IRollupContract(rollupContract).rollupContractRegistered(rollupId, registrant)` so the manager learns its id (one-shot init callback; the reference manager latches and reverts `AlreadyRegistered` on reuse). The caller is expected to deploy their `IRollupContract`-conforming manager with its verification policy and ownership initialized before calling `registerRollup`.

Emits `RollupCreated(rollupId, rollupContract, rollups[rollupId].root)` using the stored root after the registration callback.

#### `postAndVerifyBatch`

```solidity
function postAndVerifyBatch(ProofSystemBatchPerVerificationEntries calldata batch) external
```

Permissionless. A single struct (NOT an array) carries:

```solidity
struct ProofSystemBatchPerVerificationEntries {
    ExpectedRootPerRollup[] expectedRootPerRollup; // optional composer assertions; mismatch reverts
    ExecutionEntry[]             entries;                    // execution entries
    StaticExecutionEntry[]       staticEntries;              // top-level static entries
    uint256                      immediateEntryCount;        // leading prefix executed this tx (immediate L2Txs + meta-hook entries), not queued
    uint256                      immediateStaticEntryCount;  // leading static entries resolvable this tx via the meta hook, not queued
    address[]                    proofSystems;               // strictly increasing, no address(0)
    RollupIdWithProofSystems[]   rollupIdsWithProofSystems;  // strictly increasing by rollupId
    uint256[]                    blobIndices;                // tx-level EIP-4844 blobs this batch consumes
    bytes                        callData;                   // batch-scoped calldata
    bytes[]                      proofs;                     // one proof per proofSystems entry
    uint64                       blockNumber;                // block binding: 0 = none, type(uint64).max = latest
    bool                         bindMsgSenderInPublicInput; // true = fold msg.sender into the public input (front-run protection); false = fold address(0)
}

struct RollupIdWithProofSystems {
    uint64   rollupId;
    uint64[] proofSystemIndexes;  // strictly-increasing indices into the batch's proofSystems[]
}
```

`immediateEntryCount` / `immediateStaticEntryCount` are **unproven dispatch params** — not folded into the public input, so the immediate/persistent split can be re-tuned without re-proving. `blockNumber` is forwarded to every rollup's `getCustomData(blockNumber)`. See `MULTI_PROVER_SPEC.md` for the multi-prover model.

**Preconditions** (composer pins + `_validateBatchStructure`, no external calls):
- Reentry guard: `_insideExecution() || _transientEntriesLength != 0` reverts `PostBatchReentry`.
- Every `batch.expectedRootPerRollup` pin equals the live root, else `ExpectedRootMismatch(rid)`.
- `proofSystems.length != 0`, `proofSystems.length == proofs.length`, `rollupIdsWithProofSystems.length != 0`, else `InvalidProofSystemConfig`.
- `proofSystems[]` strictly increasing by address (rejects duplicates + `address(0)`), else `DuplicateProofSystem(ps)`.
- `rollupIdsWithProofSystems[]` strictly ascending by `rollupId`, each `> MAINNET_ROLLUP_ID`, each registered; each row's `proofSystemIndexes[]` non-empty, strictly ascending, all in `[0, proofSystems.length)` — else `InvalidProofSystemConfig`.
- **Per entry (proxy protection)**: `rollupUpdates.length >= 1` (`EntryHasNoRollupUpdates`); deltas strictly increasing by rollupId (`RollupUpdatesNotStrictlyIncreasing`); every delta rollup in the batch's rollup set (`RollupNotInBatch`); `destinationRollupId` ∈ the entry's own deltas (`EntryDestinationNotInRollupUpdates`); every call SOURCE — top-level calls plus each reentrant frame's sub-calls — ∈ the entry's deltas (`CallSourceNotVerified`). Reentrant TARGETS carry no clear-text rollup field, so they stay a runtime check (§B.1 `_consumeNestedCall`).
- **Per static entry**: `expectedRoots` pins strictly increasing (`ExpectedRootsNotStrictlyIncreasing`), each ∈ batch (`RollupNotInBatch`); `destinationRollupId` ∈ its own pins (`StaticEntryDestinationNotPinned`); every sub-call source ∈ the pins (`CallSourceNotVerified`).
- `immediateEntryCount <= entries.length` else `ImmediateCountExceedsEntries`; `immediateStaticEntryCount <= staticEntries.length` else `ImmediateStaticEntryCountExceedsStaticEntries`. (A non-zero `immediateStaticEntryCount` additionally requires the meta hook to fire — checked after the immediate L2Tx run in step 6, `ImmediateStaticEntriesWithoutImmediateEntries`.)
- If `entries[immediateEntryCount]` exists and has `proxyEntryHash == 0`, revert `ImmediateCountStrandsLeadingL2Tx` — protects honest composers against a poster under-counting the unproven `immediateEntryCount` and stranding a proven leading L2Tx into the queue.

**Per-PS public-inputs construction** (two-stage; see `MULTI_PROVER_SPEC.md` for details):

```
entryHashes[i]       = keccak256(abi.encode(batch.entries[i]))
staticEntryHashes[i] = keccak256(abi.encode(batch.staticEntries[i]))
blobHashes[i]        = blobhash(batch.blobIndices[i])
customDataHashes[r]  = keccak256(abi.encode(rollupId_r, customData_r))
boundSender          = batch.bindMsgSenderInPublicInput ? msg.sender : address(0)

sharedPublicInput = keccak256(abi.encodePacked(
    abi.encode(entryHashes),
    abi.encode(staticEntryHashes),
    abi.encode(blobHashes),
    keccak256(batch.callData),
    abi.encode(customDataHashes),
    boundSender
))

for each PS k in proofSystems:
  acc_k = bytes32(0)
  for each rollup r (rollupId-ascending) where k ∈ rollupIdsWithProofSystems[r].proofSystemIndexes:
    acc_k = keccak256(abi.encode(acc_k, rollupId_r, verificationKeysPerRollup[r][j]))
  publicInputsHash[k] = keccak256(abi.encodePacked(sharedPublicInput, acc_k))
```

`customData_r` is the opaque per-rollup blob fetched ONCE via `IRollupContract(rollupContract).getCustomData(batch.blockNumber)` (rollup-defined L1-view commitment; the reference `Rollup` returns ABI-encoded `(timestamp, blockHash)` — an empty blob for `blockNumber == 0`, `(block.timestamp, blockhash(block.number - 1))` for `type(uint64).max`, `(0, blockhash(blockNumber))` for a specific block, reverting `BlockHashUnavailable` when the hash cannot be resolved). Each blob is hashed keyed by its `rollupId` and the array binds into `sharedPublicInput`. It does NOT vary per PS, so it is folded ONCE into the shared input rather than into each per-PS `acc_k`.

`boundSender` binds the submitter: with `batch.bindMsgSenderInPublicInput = true` the proof commits to the exact `msg.sender` allowed to land the batch (front-run protection for the meta-hook / AA bundle); with `false` it commits to `address(0)` and anyone may submit.

Each PS's `verify(proofs[k], publicInputsHash[k])` must return `true`. A `false` return reverts with `InvalidProof`; a verifier revert propagates its original error. For example, malformed reference ECDSA signatures can raise length/high-s errors, whereas a well-formed wrong-signer signature returns false. Both rejection paths unwind the whole batch atomically.

**State transitions** (in order; see `postAndVerifyBatch` in `src/EEZ.sol`):

1. **Reentry check**: `if (_insideExecution() || _transientEntriesLength != 0) revert PostBatchReentry()`.
2. **Composer pins + structural validation** (`_validateBatchStructure(batch)`, no external calls).
3. **Fetch + verify**: `_getVerificationKeysPerRollup(batch)` calls each rollup's manager via `IRollupContract.checkProofSystemsAndGetVkeys(subset)` (a `view` call; the manager enforces threshold + per-PS membership internally and must return exactly one vkey per subset entry, else `InvalidProofSystemConfig`). Then `_verifyProofSystemBatch(batch, vkMatrix)` computes the public inputs and calls `IProofSystem.verify(...)` for each PS.
4. **Mark verified-this-block** (`_markVerifiedBlockAndResetQueues(rid)` for each rollup): sets `verificationByRollup[rid].lastVerifiedBlock = block.number` AND **resets the rollup's `entryQueueLength` / `staticEntryQueueIndex` / `entryQueueIndex` on EVERY verify without deleting entries** — a same-block re-verify REPLACES (does not append to) the prior batch's entries for that rollup. Done before any non-view external CALL so (a) `executeCrossChainCall` / `executeL2Txs(rid)` work during the meta hook, and (b) `setRoot` is locked out until the next block.
5. **Drain the leading run of immediate L2Txs straight from calldata**: while `i < immediateEntryCount` and `batch.entries[i].proxyEntryHash == bytes32(0)`, self-call `try this._attemptExecuteImmediateL2Txs(batch.entries[i]) catch { emit L2TxSkipped(i, revertData); }` and advance — a skip is not a hard error, but if at least one L2Tx was attempted and NONE succeeded, revert `AllImmediateL2TxsFailed` (a fully-failed immediate prefix unwinds the whole post). Empty revert data from the self-call aborts the post with `ImmediateL2TxOutOfGas(i)` before emitting a skip; empty data alone does not prove out-of-gas. Any outer revert, including `AllImmediateL2TxsFailed`, discards earlier skip logs. These entries are never SSTOREd whole; only each entry's reentrant table is parked in the `ExpectedL1ToL2CallTransient` transient region for the duration of that entry.
6. **Meta hook**: if entries remain in the immediate prefix past the leading L2Tx run (`i < immediateEntryCount`), `msg.sender` must have code to receive the hook (revert `MetaEntriesWithoutReceiver` otherwise — the never-persisted prefix would be silently dropped): copy `entries[i..immediateEntryCount)` into `_transientEntries` and `staticEntries[0..immediateStaticEntryCount)` into `_transientStaticEntries`, incrementing their transient lengths from zero, then call `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()`. The hook may invoke `executeCrossChainCall` and `executeL2Txs(rid)` to consume the transient stream. The static prefix is a companion of the META-HOOK entries, not of the immediate prefix as a whole: it loads only when the hook fires. If no hook fires (empty immediate prefix, or one that is pure L2Txs) a non-zero `immediateStaticEntryCount` would drop the leading static entries (never loaded transiently, never queued), so the post reverts `ImmediateStaticEntriesWithoutImmediateEntries` — composers set it to 0 in that shape (see `STATIC_ENTRY.md` §6).
7. **Publish the remainder** (`_saveRemainderEntries(batch)`): push `entries[immediateEntryCount..]` into `verificationByRollup[entry.destinationRollupId].entryQueue` and `staticEntries[immediateStaticEntryCount..]` into the matching `staticEntryQueue`, **unconditionally** (even if the meta hook left transient entries unconsumed — there is no drain-cleanly gate). Soundness backstop: each entry's `RollupUpdate.currentRoot` is checked at consumption time, so dropped transient leftover doesn't poison persistent consumers.
8. **Cleanup transient tables**: delete every `_transientEntries[i]` below `_transientEntriesLength` and every `_transientStaticEntries[i]` below `_transientStaticEntriesLength`, including unconsumed entries; then zero both transient lengths and `_transientEntryIndex` (zeroing the execution length also closes the reentry window). Finally, `emit BatchPosted(sharedPublicInput, rollupIds)`.

**Revert conditions**: `PostBatchReentry`, `ExpectedRootMismatch(rid)`, `InvalidProofSystemConfig`, `DuplicateProofSystem(ps)`, `EntryHasNoRollupUpdates`, `RollupUpdatesNotStrictlyIncreasing(rid)`, `RollupNotInBatch(rid)`, `EntryDestinationNotInRollupUpdates(rid)`, `CallSourceNotVerified(rid)`, `ExpectedRootsNotStrictlyIncreasing(rid)`, `StaticEntryDestinationNotPinned(rid)`, `ImmediateCountExceedsEntries`, `ImmediateStaticEntryCountExceedsStaticEntries`, `ImmediateStaticEntriesWithoutImmediateEntries`, `ImmediateCountStrandsLeadingL2Tx`, threshold/vkey reverts from the manager (e.g. `ThresholdNotMet`, `ProofSystemNotAllowed`), `InvalidProof`, propagated verifier errors, `ImmediateL2TxOutOfGas(i)`, `AllImmediateL2TxsFailed`, plus whatever the meta hook reverts with (`RollingHashMismatch`, `EtherDeltaMismatch`, `InsufficientRollupBalance`, `ExecutionNotFound`, `RootMismatch(rid)`, …; only a nonempty *immediate L2Tx* revert can be skipped; empty data aborts, and any outer revert removes skip logs).

Note: same-block re-touch of a rollup is **permitted** — but `_markVerifiedBlockAndResetQueues` resets the queue bounds on every verify without deleting stored entries, so the second batch's entries REPLACE (not append to) the first batch's for that rollup. Safe because state only mutates at consumption and every entry is gated by `RollupUpdate.currentRoot`.

#### `executeCrossChainCall`

```solidity
function executeCrossChainCall(address sourceAddress, bytes calldata callData)
    external payable returns (bytes memory result)
```

**Access control**: caller must be a registered proxy (`authorizedProxies[msg.sender].isProxy`); else `UnauthorizedProxy`.

**Preconditions**: `verificationByRollup[proxyInfo.originalRollupId].lastVerifiedBlock == block.number` else `ExecutionNotInCurrentBlock(rollupId)`.

**Logic**:

```solidity
ProxyInfo storage proxyInfo = authorizedProxies[msg.sender];
address destAddress = proxyInfo.originalAddress;
uint64  destRid     = proxyInfo.originalRollupId;

bytes32 crossChainCallHash = computeCrossChainCallHash(
    NOT_STATIC_CALL,      // isStatic = false
    sourceAddress,        // sourceAddress (msg.sender of the original proxy call)
    MAINNET_ROLLUP_ID,    // sourceRollupId (L1 = 0)
    destAddress,          // targetAddress
    destRid,              // targetRollupId
    msg.value,            // value
    ZERO_CALL_GAS,        // callGas (0 — L1 never keys on gas)
    callData              // data
);
emit CrossChainCallExecuted(crossChainCallHash, msg.sender, sourceAddress, callData, msg.value);

if (_insideExecution()) {
    _entryEtherDelta += int256(msg.value);   // reentrant: ADD to the entry's net-ether accumulator — §H.2
    return _consumeNestedCall(destRid, crossChainCallHash);
}
_entryEtherDelta = int256(msg.value);        // top-level: SET — a fresh entry can never inherit residue
return _consumeAndExecuteEntry(destRid, crossChainCallHash);
```

`_consumeAndExecuteEntry` routes to the rollup's queue — the transient stream (global cursor) while a batch is mid-flight, otherwise the persistent per-rollup queue. Consumption is a **forward scan** for the first fully-matching entry (§D.1); if the scan reaches the end with no match, it reverts `ExecutionNotFound`. There is no reverted-top-level fallback structure: a top-level reverting call is a normal `ExecutionEntry` with `success == false`.

**Revert conditions**: `UnauthorizedProxy`, `ExecutionNotInCurrentBlock(rollupId)`, `ExecutionNotFound`, `RollingHashMismatch`, `EtherDeltaMismatch`, `InsufficientRollupBalance`, `RootMismatch(rollupId)`, `ReentrantDestinationNotVerified(rollupId)` (reentrant path only), `StaticCallWithValue` (a flat call flagged `isStatic` but carrying non-zero `value` — a STATICCALL cannot transfer ETH, so it is rejected rather than silently dropping the value), `RevertSpanOutOfBounds`, plus a `success == false` entry's own `returnData` revert. A destination's natural revert does NOT propagate — the proxy `.call` captures `(false, retData)` into the rolling hash via `CALL_END`.

#### `executeL2Txs`

```solidity
function executeL2Txs(uint64 rollupId) external returns (bytes memory result)
```

Permissionless. Consumes the next entry on `rollupId`'s queue whose `proxyEntryHash == bytes32(0)`. Cannot run during an active execution. L2Tx entries are canonically `success == true` with empty `returnData` — a prover constraint (§A.1).

```solidity
if (verificationByRollup[rollupId].lastVerifiedBlock != uint64(block.number)) revert ExecutionNotInCurrentBlock(rollupId);
if (_insideExecution()) revert L2TxNotAllowedDuringExecution();
if (_entryEtherDelta != 0) revert ResidualEntryEtherIn();   // non-payable + never mid-entry — dirty accumulator = bug
emit L2TxExecuted(rollupId);
return _consumeAndExecuteEntry(rollupId, bytes32(0));
```

#### `staticCrossChainCall`

```solidity
function staticCrossChainCall(address sourceAddress, bytes calldata callData)
    external view returns (bytes memory)
```

Called via STATICCALL by `CrossChainProxy._fallback` when the proxy detects static context. Caller must be a registered proxy. The standard same-block restriction applies (§G.4). Branches on `_insideExecution()`:

```solidity
uint64 destRid = proxyInfo.originalRollupId;
bytes32 crossChainCallHash = computeCrossChainCallHash(
    IS_STATIC,                    // isStatic = true — keys distinctly from a state-changing call
    sourceAddress,
    MAINNET_ROLLUP_ID,
    proxyInfo.originalAddress,
    destRid,
    0,                            // value = 0 in static context
    ZERO_CALL_GAS,                // callGas — L1 static reads never key on gas
    callData
);

// NESTED (inside an execution): scan the active host's unified reentrant table by the
// content-addressed position key. The isStatic=true hash means only STATIC rows can match.
if (_insideExecution()):
    if (!_containsVerifiedRollup(destRid)) revert ReentrantDestinationNotVerified(destRid);
    key = keccak256(abi.encodePacked(crossChainCallHash, _rollingHash));
    expectedCalls = _getExpectedL1toL2Calls();
    for i in [_lastL1ToL2CallConsumed, expectedCalls.length):   // strict-forward window; a read cannot advance the cursor
        if expectedCalls[i].expectedL1toL2Hash == key:
            if _resolveStaticEntry(expectedCalls[i].l2ToL1Calls,
                                   expectedCalls[i].revertedOrStaticRollingHash,
                                   expectedCalls[i].success,
                                   expectedCalls[i].returnData):
                return expectedCalls[i].returnData;
    revert ExecutionNotFound();

// TOP-LEVEL: the batch's transient pool while one is mid-flight (the transient phase is
// self-contained — see docs/CAVEATS.md), otherwise destRid's persistent staticEntryQueue.
// Match = proxyEntryHash + destinationRollupId + every root pin live (full scan —
// a non-matching candidate is skipped). The destinationRollupId term matters for the
// transient pool, which is a single global table not routed by rollup.
isTransient = _transientEntriesLength != 0;
rec = verificationByRollup[destRid];
poolLength = isTransient ? _transientStaticEntriesLength : rec.staticEntryQueueIndex;
for i in [0, poolLength):
    se = isTransient ? _transientStaticEntries[i] : rec.staticEntryQueue[i];
    if se.proxyEntryHash == crossChainCallHash && se.destinationRollupId == destRid && _rootsMatch(se):
        if _resolveStaticEntry(se.l2ToL1Calls, se.rollingHash, se.success, se.returnData):
            return se.returnData;
revert ExecutionNotFound();
```

`_resolveStaticEntry(calls, revertedOrStaticRollingHash, success, returnData)` (shared by both branches — the param is the pool entry's `rollingHash` or the table row's `revertedOrStaticRollingHash`):
- **Always** run the sub-calls via `_processStaticL2ToL1Calls(calls)` (each via `sourceProxy.staticcall(executeOnBehalf(target, cc.gas, data))`) and return `false` on `computedHash != revertedOrStaticRollingHash` so lookup tries the next candidate — an empty array hashes to `bytes32(0)`, which must match a sub-call-less entry's `rollingHash`.
- If `!success`: revert with `returnData` (bubbles back to the proxy and out to the caller).
- Else return `true`; the caller returns the row's `returnData`. Exhausting candidates reports `ExecutionNotFound`.

`_rootsMatch(se)` returns true iff every `se.expectedRoots[i]` equals the live `rollups[rollupId].root` — part of the MATCH predicate, not a post-match check.

#### `createCrossChainProxy` / `computeCrossChainProxyAddress`

```solidity
function createCrossChainProxy(address originalAddress, uint64 originalRollupId)
    external returns (address proxy);

function computeCrossChainProxyAddress(address originalAddress, uint64 originalRollupId)
    public view returns (address);
```

Both permissionless. `createCrossChainProxy` reverts if the proxy already exists. The separate public `getOrCreateCrossChainProxy` returns an existing authorized proxy or creates it; internal mutable execution uses this idempotent helper. Returning an existing proxy emits no creation event.

```solidity
salt         = keccak256(abi.encodePacked(originalRollupId, originalAddress))
bytecodeHash = keccak256(type(CrossChainProxy).creationCode)  // constructor has no arguments
address      = address(uint160(uint256(keccak256(abi.encodePacked(
                   bytes1(0xff),
                   address(this),    // deployer = the manager (EEZ on L1, EEZL2 on L2)
                   salt,
                   bytecodeHash
               )))))
```

The constructor captures its manager from `msg.sender`. Under delegatecall the CREATE2 deployer is the manager proxy (`address(this)` in the execution context), not its implementation. The init-code hash is compiler/settings dependent. Deployments must pin the actual creation bytecode and compiler settings; reproducible deployment and hash reference vectors remain outstanding.

The salt is exactly `(originalRollupId, originalAddress)` — no `domain` or `block.chainid` term is mixed in. `createCrossChainProxy` and `computeCrossChainProxyAddress` are defined on `EEZBase` and inherited by both `EEZ` and `EEZL2`. A proxy stands in for a REMOTE address, never one on the manager's own network: `_createCrossChainProxyInternal` reverts `SameNetworkProxy(rollupId)` when `originalRollupId` equals the manager's own network id (`MAINNET_ROLLUP_ID` on L1, `ROLLUP_ID` on L2), so `createCrossChainProxy`, `getOrCreateCrossChainProxy` and the auto-creation path during execution are all covered by the one check.

Nothing verifies that `originalAddress` actually holds a contract on rollup `originalRollupId` — proxy creation is permissionless and the manager cannot see other chains. A proxy minted over an address with no code at the destination forwards calls that "succeed" against an empty account (flat entries, empty return data). Always mint proxies over the real remote contract, never over a local twin's address.

#### Per-rollup ownership / configuration

Per-rollup ownership lives on each rollup's `IRollupContract`-conforming manager (reference impl: `src/rollupContract/Rollup.sol`). The central `EEZ` registry exposes a single manager-callable mutator on the rollup config:

```solidity
function setRoot(uint64 rollupId, bytes32 newRoot) external  // msg.sender == rollups[rid].rollupContract
```

Subject to three reverts:
- `NotRollupContract` if `msg.sender != rollups[rid].rollupContract`.
- `SetRootNotAllowedDuringExecution()` if `_insideExecution()` — the manager cannot rewrite state mid-execution via a reentrant proxy path.
- `RollupBatchActiveThisBlock(rid)` if `verificationByRollup[rid].lastVerifiedBlock == block.number` (a batch hit `rid` earlier this block).

Emits `RootUpdated(rollupId, newRoot)`. `setRoot` does **not** update `lastVerifiedBlock` — it's an owner escape, not a batch post.

The registry's manager address is fixed at registration. Proxy-based managers retain that address when upgraded through their own administration.

Per-rollup operations like `addProofSystem` / `removeProofSystem`, `updateVerificationKey`, `setThreshold`, `transferOwnership`, and any owner-driven `setRoot` initiation live on the manager itself. See `MULTI_PROVER_SPEC.md` and `src/rollupContract/Rollup.sol`.

#### View accessors

`verificationByRollup` is `internal`. Public accessors:

```solidity
function lastVerifiedBlock(uint64 _rollupId) external view returns (uint256);
function queueLength(uint64 _rollupId) external view returns (uint256);      // entryQueueLength
function entryQueueIndex(uint64 _rollupId) external view returns (uint256);
```

#### Internal helpers

##### `_consumeAndExecuteEntry(uint64 destRid, bytes32 crossChainCallHash) → bytes`

```
if (_transientEntriesLength != 0):
    idx = _findMatchingEntry(_transientEntries, _transientEntryIndex, _transientEntriesLength, crossChainCallHash, destRid)
    _transientEntryIndex = idx + 1
    entry = _transientEntries[idx]
else:
    rec = verificationByRollup[destRid]
    idx = _findMatchingEntry(rec.entryQueue, rec.entryQueueIndex, rec.entryQueueLength, crossChainCallHash, destRid)
    rec.entryQueueIndex = uint64(idx + 1)
    entry = rec.entryQueue[idx]
    _currentEntryRollupId = destRid       // the queue _getExpectedL1toL2Calls() reads

emit ExecutionConsumed(crossChainCallHash, destRid, idx)

_currentEntryIndex = idx
_executeEntry(entry)

_currentEntryRollupId = 0                 // load-bearing: the immediate L2Tx path relies on 0
_currentEntryIndex = 0                    // hygiene/symmetry
return entry.returnData
```

`_findMatchingEntry(queue, startIndex, hash, destRid)` forward-scans from the cursor for the **first** entry where `_entryMatches` holds, reverting `ExecutionNotFound` at the end of the queue. `_entryMatches(entry, hash, destRid)` requires all of:

- `entry.proxyEntryHash == crossChainCallHash` (identity),
- `entry.destinationRollupId == destRid` (routing — load-bearing in the transient branch, whose cursor is global across rollups; holds by construction in the persistent branch),
- every `entry.rollupUpdates[i].currentRoot` equals the live `rollups[rid].root` (state preconditions — a stale entry is a *non-match*, skipped rather than reverted on).

Skipping intervening non-matches lets a top-level call pass stale-state entries or failed entries whose hashes no longer match. A failed entry that still matches is retried, because its revert restored the cursor. A skipped entry simply never executes — anything depending on it later fails its own `currentRoot` check.

Inside an active `postAndVerifyBatch`, `_transientEntriesLength != 0` routes **all** consumption through the transient stream with the global `_transientEntryIndex`. Per-rollup queues are populated only at step 7 of `postAndVerifyBatch`.

##### `_getExpectedL1toL2Calls() → ExpectedL1ToL2Call[] memory`

The reentrant table of the entry currently being processed — the live source a proxy re-entry resolves against (it crosses an external boundary and can't see the executing `_executeEntry`'s memory entry). Returned by `memory` (one of the sources is a transient region, which cannot produce a `storage` pointer). Three sources, in priority order:

1. **Immediate L2Tx run** — the `ExpectedL1ToL2CallTransient` transient region when non-empty (the entry never lands in storage; only its table is parked there).
2. **Meta-hook** — `_transientEntries[_currentEntryIndex].expectedL1ToL2Calls` while a batch is mid-flight.
3. **Normal proxy consumption** — `verificationByRollup[_currentEntryRollupId].entryQueue[_currentEntryIndex].expectedL1ToL2Calls`. An immediate L2Tx whose parked table is empty yet still makes a reentrant call reaches here with `_currentEntryRollupId == 0`; the accessor returns an empty table instead of indexing the nonexistent queue. CALL then records `CALL_NOT_FOUND` and returns empty bytes; STATICCALL reverts `ExecutionNotFound`, matching the empty-table behavior of queued and meta-hook entries.

##### `_consumeNestedCall(uint64 destRid, bytes32 crossChainCallHash) → bytes`

The reentrant resolution path. The cursor advances **only on a match**; a no-match folds a `CALL_NOT_FOUND` tag into the rolling hash instead of reverting in place:

```
// Proxy protection: the reentrant call's target rollup must be in the entry's proven set.
if (!_containsVerifiedRollup(destRid)) revert ReentrantDestinationNotVerified(destRid)

expectedCalls      = _getExpectedL1toL2Calls()
expectedL1toL2Hash = keccak256(abi.encodePacked(crossChainCallHash, _rollingHash))

// Strict forward scan from the cursor — the first key match IS the row.
for i in [_lastL1ToL2CallConsumed, expectedCalls.length):
    if expectedCalls[i].expectedL1toL2Hash == expectedL1toL2Hash:
        _lastL1ToL2CallConsumed = i + 1          // advance PAST the match before resolving
        return _resolveNestedReentrant(expectedCalls[i], crossChainCallHash)

// No match: fold a dedicated tag. Distinct from CALL_END(true, ""), so a no-match can never be
// forged as a normal empty return; the divergence surfaces at the entry's rolling-hash check
// (RollingHashMismatch), riding the ContextResult payload across any revert-span boundary.
_rollingHashCallNotFound(crossChainCallHash)
return ""
```

The same logic on L2 is `_consumeNestedCall(crossChainCallHash)` — no `destRid` / proxy-protection check (single rollup, trusted system-loaded table), scanning `expectedOutgoingCalls` by `expectedOutgoingHash` with cursor `_lastOutgoingCallConsumed`.

##### `_resolveNestedReentrant(ExpectedL1ToL2Call storage row, bytes32 crossChainCallHash) → bytes`

```
_rollingHashNestedBegin(crossChainCallHash)     // open the frame, binding the call's identity
_processL2ToL1Calls(row.l2ToL1Calls)                 // process this frame's sub-array; a failed _hasEnoughCallGas check stops it and marks the hash

if (row.success):
    _rollingHashNestedEnd()                     // close the frame into the host's continuous hash
    return row.returnData
else:
    if (_rollingHash != row.revertedOrStaticRollingHash) revert RollingHashMismatch()
    revert-with row.returnData                  // terminal revert rolls back state, hash, and cursor
```

A SUCCESS frame commits: its sub-calls fold into the host's continuous `_rollingHash` between `NESTED_BEGIN` / `NESTED_END`. A REVERTED frame is a mini-entry: its sub-hash (seeded from the host hash at `NESTED_BEGIN`) is checked against the row's `revertedOrStaticRollingHash`, then the frame reverts with `returnData` — the destination's `try/catch` absorbs the revert, and the EVM rolls back every write inside the frame, including the cursor advance and the hash folds (no save/restore step is needed).

##### `_executeEntry(ExecutionEntry memory entry)`

`_entryEtherDelta` already holds the entry-point call's `msg.value` here (SET by the top-level entry point before consumption), so it is NOT reset in the preamble — only at the end, after the invariant check. The entry is taken by `memory` so an immediate L2Tx can run straight from calldata.

```
if (entry.rollupUpdates.length == 0) revert EntryHasNoRollupUpdates   // redundant guard; backs _insideExecution()

for delta in entry.rollupUpdates:
    if (rollups[delta.rollupId].root != delta.currentRoot) revert RootMismatch(delta.rollupId)
    _pushVerifiedRollup(delta.rollupId)    // allowed set; flips _insideExecution() true

_rollingHashEntryBegin(entry.rollupUpdates, entry.proxyEntryHash)    // seed: starting state + identity (§E)
_lastL1ToL2CallConsumed = 0

_processL2ToL1Calls(entry.l2ToL1Calls)                                  // the entry's TOP-LEVEL calls, whole array
totalEtherDelta = _applyRollupUpdates(entry.rollupUpdates)             // newRoot applies AFTER the calls

if (_rollingHash != entry.rollingHash) revert RollingHashMismatch  // a CALL_NOT_FOUND fold surfaces here too
if (totalEtherDelta != _entryEtherDelta) revert EtherDeltaMismatch

emit EntryExecuted(_currentEntryIndex, _rollingHash)

if (!entry.success):
    revert-with entry.returnData     // trace verified; unwind state deltas, value, cursor advance, cleanups

_clearVerifiedRollups()   // resets _insideExecution() to false
_entryEtherDelta = 0
_rollingHash = bytes32(0)                       // next entry's zero-guard (RollingHashNotCleared) passes
```

There is **no flat-call cursor check** (arrays are walked in order, with the gas-shortage early return described below) and **no reentrant table-length check**: the unified `expectedL1ToL2Calls` mixes plain-success rows with static / reverted ones (content-addressed, may legitimately go unused). Completeness of the success rows is enforced by the rolling hash — a skipped success row omits its `NESTED` frame, diverging the hash; an unconsumed row is inert.

##### `_processL2ToL1Calls(L2ToL1Call[] memory calls)`

Walks the `calls` array until its end or a gas-shortage return — the entry's top-level calls, a reentrant frame's own sub-array, or a force-revert span slice — walked by a plain **local** index (it auto-survives reentrant proxy calls on the call stack; no transient cursor). For each element:

- If `revertNextNCalls == 0`:
  1. Fold `CALL_BEGIN` with the call's identity: `computeCrossChainCallHash(cc.isStatic, cc.sourceAddress, cc.sourceRollupId, cc.targetAddress, MAINNET_ROLLUP_ID, cc.value, ZERO_CALL_GAS, cc.data)` (L2 substitutes `ROLLUP_ID` for the target).
  2. Derive `sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId)`; auto-create it if not registered. (No source check here — every executed call's `sourceRollupId` was validated ∈ `rollupUpdates` at batch validation.)
  3. Encode the forwarding payload and check `_hasEnoughCallGas(cc.gas, payload.length, cc.value)`. On shortage, fold `CALL_INSUFFICIENT_GAS` (tag 6) and return from this local array: this call and later siblings are not dispatched; `CALL_BEGIN` is already folded. A parent can continue after `ContextResult` transports a stopped span. Otherwise dispatch: if `cc.isStatic`, revert `StaticCallWithValue` when `cc.value != 0`, then `sourceProxy.staticcall(executeOnBehalf(target, cc.gas, data))`; else `sourceProxy.call{value: cc.value}(executeOnBehalf(target, cc.gas, data))`, and on success with `cc.value > 0`, `_entryEtherDelta -= int256(cc.value)`.
  4. Fold `CALL_END(success, retData)`; emit `CallResult(_currentEntryIndex, i, success, retData)`; `i++`.
- If `revertNextNCalls > 0` (force-revert span):
  1. `if (i + n > calls.length) revert RevertSpanOutOfBounds(i, n, calls.length)`.
  2. Zero `calls[i].revertNextNCalls` in the throwaway memory copy (so the isolated re-run reads it as a normal call), slice `calls[i .. i+n)` into a fresh memory array (`_sliceL2ToL1Calls`).
  3. `try this.executeInContextAndRevert(span)` — always reverts; decode `ContextResult` and restore `_rollingHash` and `_lastL1ToL2CallConsumed` from the payload.
  4. Emit `CallsReverted(_currentEntryIndex, i, n)`; `i += n`.

(L2's variant is identical over `CrossChainCall[]`, minus the ether accounting.)

The preflight is an estimate for nonzero caps: payload memory/copy costs, fixed overhead, value transfers and a two-hop forwarding margin. A zero cap bypasses it. New-account costs, returndata handling and the remaining entry/batch are excluded; posters still need enough gas for the whole execution. Valid proofs exclude tag 6; runtime equality alone cannot enforce that proof policy. `CallsReverted` reports the requested span length, not an independently measured dispatch count.

##### `executeInContextAndRevert(L2ToL1Call[] memory calls) external`

```
require(msg.sender == address(this))       // NotSelf
_processL2ToL1Calls(calls)
revert ContextResult(_rollingHash, _lastL1ToL2CallConsumed)
```

The span slice crosses the self-call boundary by `memory` (ABI-encoded), since a `storage` ref cannot. (L2 passes `_lastOutgoingCallConsumed` as the second field.)

The unconditional revert rolls back all storage and transient writes inside the self-call, but the `ContextResult` payload escapes via the revert data — the caller decodes it and re-applies the rolling hash and reentrant cursor. A reentrant no-match inside the span is already folded into that rolling hash (`CALL_NOT_FOUND`), so it rides out with no separate flag.

##### `_decodeContextResult(bytes memory revertData) → (bytes32, uint256)`

Defined on `EEZBase` with direction-neutral names. Verifies `bytes4(revertData) == ContextResult.selector` AND `revertData.length >= 68` (4 + 2×32) else `UnexpectedContextRevert(revertData)`; then assembly-loads two words at offsets 36 and 68 (`rollingHash`, `reentrantConsumed`).

##### `_applyRollupUpdates(RollupUpdate[] memory deltas) → int256 totalEtherDelta`

For each delta (the `currentRoot` precondition was already checked upfront in `_executeEntry`; roots are immutable mid-execution):
- `rollups[delta.rollupId].root = delta.newRoot`.
- Accumulate `delta.etherDelta` into `totalEtherDelta`.
- If `delta.etherDelta < 0`: `etherBalance -= |delta|` (revert `InsufficientRollupBalance` on underflow).
- If `delta.etherDelta > 0`: `etherBalance += delta`.
- Emit `L2ExecutionPerformed(rollupId, newRoot, etherBalance)`.

##### `_processStaticL2ToL1Calls(L2ToL1Call[] memory calls) → bytes32`

```
hash = bytes32(0)
for cc in calls:
    if (!cc.isStatic) revert NonStaticSubCall()
    if (cc.value != 0) revert StaticCallWithValue()
    if (cc.revertNextNCalls != 0) revert StaticCallWithRevertSpan()
    sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId)
    if (sourceProxy.code.length == 0) revert StaticCallProxyNotDeployed(sourceProxy)
    payload = abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.gas, cc.data))
    if (!_hasEnoughCallGas(cc.gas, payload.length, 0)) revert InsufficientCallGas(cc.gas)
    (success, retData) = sourceProxy.staticcall(payload)
    hash = keccak256(abi.encodePacked(hash, success, retData))
return hash
```

Static callbacks require `revertNextNCalls == 0` both as a prover constraint and at runtime (`StaticCallWithRevertSpan`). A nonzero gas cap also receives the preflight estimate; shortage reverts `InsufficientCallGas(cc.gas)` without folding tag 6. Static context cannot deploy proxies, so all referenced proxies must already exist; a codeless proxy reverts `StaticCallProxyNotDeployed` (a STATICCALL to a codeless address silently succeeds, which the prover could otherwise pre-hash as a no-op).

Dispatch here is read-only unconditionally, so the declared fields must agree with it: `isStatic == false` reverts `NonStaticSubCall` and a non-zero `value` reverts `StaticCallWithValue`. Neither field is folded into the untagged hash, so without these checks a proven state-changing call would silently execute as a STATICCALL, and a declared value would be silently dropped.

This hashing scheme is **intentionally untagged** and is **distinct from** the entry-level rolling hash described in §E (no `CALL_BEGIN`/`CALL_END`/`NESTED_BEGIN`/`NESTED_END` tags). It is verified against the static entry's own accumulator (`StaticExecutionEntry.rollingHash`, or `ExpectedL1ToL2Call.revertedOrStaticRollingHash` for a nested static row), whose surrounding key already pins the context. See §E.2.

##### `_attemptExecuteImmediateL2Txs(ExecutionEntry calldata entry) public` — self-call only

Runs ONE leading immediate L2Tx entry, straight from the batch calldata, in an isolated frame — so `postAndVerifyBatch`'s surrounding `try/catch` can skip a reverting entry (`L2TxSkipped`) instead of aborting the batch. Guards: `NotSelf`, `ResidualEntryEtherIn` (L2Tx entries receive no inbound value). Parks the entry's reentrant table in the `ExpectedL1ToL2CallTransient` transient region, calls `_executeEntry(entry)`, then clears the parked table (a skip's writes roll back with the frame). Neither `_currentEntryIndex` nor `_currentEntryRollupId` is set here (both are already 0), so this entry's events log `entryIndex == 0`.

##### `computeCrossChainCallHash` (`public pure`, on `EEZBase`)

```solidity
function computeCrossChainCallHash(
    bool isStatic,
    address sourceAddress,
    uint64 sourceRollupId,
    address targetAddress,
    uint64 targetRollupId,
    uint256 value,
    uint64 callGas,
    bytes memory data
) public pure returns (bytes32) {
    return keccak256(
        abi.encode(isStatic, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, callGas, data)
    );
}
```

Field order is `isStatic` → FROM (source pair) → TO (target pair) → `value` → `callGas` → `data`. `isStatic` makes a read-only call hash distinctly from an otherwise-identical state-changing one. Off-chain tooling mirrors this via `crossChainCallHash` in `script/e2e/shared/E2EHelpers.sol` (`abi.encode` left-pads integers to 32 bytes, so uint256 rollupIds produce identical bytes to the contract's uint64 fields).

Apart from L2 inbound binding, which uses `incomingCalls[0].gas`, `callGas` is `0` (`ZERO_CALL_GAS`) except calls **leaving an L2** (`EEZL2.executeCrossChainCall` and `staticCrossChainCall` — top-level and nested matching), where the folded value depends on the constructor flag `useGasLeft` (immutable `USE_GAS_LEFT`):

- `useGasLeft = true` (requires observed-gas support in the node/prover): `uint64(gasleft())` read when the manager computes the hash, i.e. after proxy authorization and storage reads, plus the block check and ETH transfer for mutable calls. Because it keys both top-level entry matching (`proxyEntryHash`) and the nested `expectedOutgoingHash`, the prover must commit to that exact gas value (deterministic when replaying the block).
- `useGasLeft = false` (the shared test fixtures): `callGas` is fixed at `0`, so outgoing hashes are gas-independent and can be pre-computed without observing the forwarded gas. L2 inbound binding still uses the incoming call's own `gas` field.

For mutable calls, the folded value is emitted in L2's `CrossChainCallExecuted` event (the six-field overload — different topic0 from L1's five-field form). Any L2 miss — a top-level mutable call, or a static read in either branch — reverts `EntryNotFound(crossChainCallHash, callGas)`, returning the folded value.

Which `callGas` value keys what:

| Matching site | `callGas` folded |
|---|---|
| Everything on L1 | `0` |
| L2 inbound binding (`executeIncomingCrossChainCall` vs `entries[0].proxyEntryHash`) | `incomingCalls[0].gas` (the inbound call's own field) |
| L2 static matching (`staticCrossChainCall`) | `gasleft()` when `USE_GAS_LEFT`, else `0` |
| Calls LEAVING an L2 (`executeCrossChainCall`, top-level + nested) | `gasleft()` when `USE_GAS_LEFT`, else `0` |

Distinguish the **gas value hashed at the source** from the **gas cap requested at the destination**. The `gas` field on `L2ToL1Call` / `CrossChainCall` supplies the proxy's destination-call cap (`0` forwards available gas subject to EVM limits). The contracts do not enforce equality between that cap and an outgoing source hash's `callGas`.

- **L1-sourced** call: the source identity always folds `callGas = 0`. The builder supplies the destination `CrossChainCall.gas`, which may be nonzero; L2's inbound identity binds that supplied cap.
- **L2-sourced** call: outgoing identity folds observed `gasleft()` when `USE_GAS_LEFT`, otherwise `0`. Copying that observation into the destination call's `gas` field is a builder/node forwarding policy, not an automatic runtime transfer or contract invariant. The integration must specify and validate the policy, including any use of a zero cap.

A supplied cap also does not by itself guarantee delivery of that much gas; the preflight estimate and EVM forwarding limits still apply.

##### `entryHashes` for the public-inputs preimage

Each entry's contribution is `keccak256(abi.encode(entry))` — the FULL `ExecutionEntry` struct, including `rollupUpdates` (which carry the entry's `currentRoot` precondition), `proxyEntryHash`, `l2ToL1Calls`, the unified `expectedL1ToL2Calls`, `rollingHash`, `destinationRollupId`, `success`, and `returnData`. Same for static entries (`keccak256(abi.encode(staticEntry))`). See `MULTI_PROVER_SPEC.md` for the full per-PS public-inputs construction.

##### Per-PS verify (inlined in `_verifyProofSystemBatch`)

There is no standalone `_verifyProof` function — each PS is verified inline at the end of the per-PS loop in `_verifyProofSystemBatch`:

```solidity
if (!IProofSystem(batch.proofSystems[k]).verify(batch.proofs[k], publicInputsHash)) revert InvalidProof();
```

The per-PS rollup walk resolves each rollup's position in its `proofSystemIndexes[]` via binary search (`_findIndexPosition`; the strictly-increasing invariant was enforced at validation). Each `IProofSystem` is supplied per batch via `proofSystems[]`; there is no central `ZK_VERIFIER` immutable.

### B.2 EEZL2.sol (L2)

The L2 contract inherits `EEZBase` and mirrors the L1 contract's execution logic but with no rollup registry, no state deltas, no ether accounting, no proofs, no per-rollup queue map (single rollup), no proxy-protection set, and no transient/deferred split.

#### `loadExecutionTable`

```solidity
function loadExecutionTable(ExecutionEntry[] calldata _entries, StaticExecutionEntryL2[] calldata _staticEntries)
    external payable onlySystemAddress
```

```
entryIndex = 0
entriesLength = _entries.length
staticEntriesLength = _staticEntries.length
for i in [0, entriesLength): entries[i] = _entries[i]
for i in [0, staticEntriesLength): staticEntries[i] = _staticEntries[i]
lastLoadBlock = block.number
emit ExecutionTableLoaded(_entries, _staticEntries)
```

`onlySystemAddress` reverts `Unauthorized` for any other caller. The L2 `ExecutionEntry` struct has no `destinationRollupId` and no `rollupUpdates` (see §A.1 — `IEEZL2.sol`).

Payable: system-supplied `msg.value` adds pooled ETH drawn down by successful incoming transfers. Replacing tables does not reset held ETH. Partial consumption and residual inventory require aggregate node/circuit accounting ([L2 funding and inventory](#l2-funding-and-inventory)); no per-load conservation check is implemented.

#### `executeIncomingCrossChainCall` (L2 inbound delivery)

```solidity
function executeIncomingCrossChainCall(
    ExecutionEntry[] calldata _entries,
    StaticExecutionEntryL2[] calldata _staticEntries
) external payable onlySystemAddress returns (bytes memory)
```

System-only top-level delivery path for an inbound cross-chain call from another rollup. `entries[0].incomingCalls[0]` IS the inbound call. One such tx per committed top-level inbound call: a source-chain tx that makes N such calls to this L2 is delivered as N separate `executeIncomingCrossChainCall` txs, each atomically replacing the table (see [delivery units](EXECUTION_ENTRY_SPEC.md#delivery-units-and-execution-transactions)). Behavior:

1. Revert `EmptyEntries` if `_entries.length == 0`; revert `EmptyIncomingCalls` if `_entries[0].incomingCalls.length == 0`.
2. `msg.value` adds system funding to the manager's pooled balance, drained by successful incoming transfers through source proxies. Later entries may draw on it; replacement retains unused ETH. Issuance/burn and residual inventory are external node/circuit obligations (§A.1 and §H.2), not a checked per-load equality.
3. `_loadExecutionTable(_entries, _staticEntries)` — atomically replaces the execution table.
4. With `inbound = _entries[0].incomingCalls[0]`: `crossChainCallHash = computeCrossChainCallHash(inbound.isStatic, inbound.sourceAddress, inbound.sourceRollupId, inbound.targetAddress, ROLLUP_ID, inbound.value, inbound.gas, inbound.data)` — the identity binds the inbound call's own `gas`. Revert `EntryHashMismatch` if `entries[0].proxyEntryHash != crossChainCallHash` — the entry's identity must be the hash of its own inbound call, mirroring L1's `_consumeAndExecuteEntry` match. Prover constraints on `entries[0]` and its `incomingCalls[0]`: §A.1.
5. Emit `IncomingCrossChainCallExecuted(crossChainCallHash, inbound.isStatic, inbound.sourceAddress, inbound.sourceRollupId, inbound.targetAddress, inbound.value, inbound.gas, inbound.data)` (hash-formula field order) and `ExecutionConsumed(crossChainCallHash, 0)` — the same consumption signal the proxy-driven path emits, so a log reader sees every entry that ran regardless of which entry point drove it.
6. `_currentEntryIndex = 0; _executeEntry(entries[0])` — the standard entry cycle (seed, flat calls, rolling-hash check, `!success` revert-with-returnData).
7. `entryIndex = 1` — advance past `entries[0]` so follow-up `executeCrossChainCall`s don't re-consume it.
8. Return `entries[0].returnData`.

#### `executeCrossChainCall` (L2 variant)

Same shape as L1, with these differences:

1. **Hash formula**: outgoing mutable and static L2 calls can fold a non-zero `callGas` — observed `gasleft()` when `USE_GAS_LEFT`, else `0`. It keys both the top-level `proxyEntryHash` match and the nested `expectedOutgoingHash`. See §C.2.
2. **`sourceRollupId`** in the call hash is `ROLLUP_ID` (this L2's ID), not `MAINNET_ROLLUP_ID`; `targetRollupId` is `proxyInfo.originalRollupId` (the proxied counterparty — L1 or another L2).
3. **ETH burn**: if `msg.value > 0`, the manager forwards it to `SYSTEM_ADDRESS` immediately (before hashing). Failure reverts `EtherTransferFailed`. There is no `_entryEtherDelta` accounting on L2.
4. Block gate is the single `lastLoadBlock != block.number → ExecutionNotInCurrentBlock` check (no per-rollup routing).
5. **Miss error**: a top-level scan that reaches the end of `entries` reverts `EntryNotFound(crossChainCallHash, callGas)` — NOT L1's `ExecutionNotFound`. A static miss (`staticCrossChainCall`, nested or top-level) reverts the same error with the static-kind hash. The two-field payload is deliberate: it hands the builder both the key that was searched for and the `callGas` that went into it, which is what makes observed-gas keying debuggable (see `test/GasProbe.t.sol`).

Top-level consumption is `_consumeAndExecute(crossChainCallHash, callGas)`: forward-scan `entries` from `entryIndex` for the first `proxyEntryHash` match (`_findMatchingEntry` — hash alone, no state pins on L2), advance `entryIndex = idx + 1`, emit `ExecutionConsumed(crossChainCallHash, idx)`, run `_executeEntry`, return `entry.returnData`. Reentrant calls route to `_consumeNestedCall(crossChainCallHash)` (§B.1 — same algorithm, no proxy-protection check). There is no reverted-top-level fallback structure — a top-level reverting call is an `ExecutionEntry` with `success == false`.

The proxy-driven call emits `CrossChainCallExecuted` — the six-field L2 overload carrying the extra `callGas` field, with a different topic0 from L1's five-field form.

L2's `_executeEntry` seeds the hash with `_seedRollingHash(proxyEntryHash)` — `keccak256(abi.encodePacked(bytes32(0), proxyEntryHash))`, i.e. L1's `_rollingHashEntryBegin` with an empty state-delta prefix — keeping the cross-chain hashing scheme identical modulo the dropped deltas. End checks: rolling hash only (no ether invariant, no table-length checks).

#### Top-level call delivery on L2

Top-level calls on L2 arrive via two paths:

1. **User txs hitting proxies** → `executeCrossChainCall`.
2. **`SYSTEM_ADDRESS` → `executeIncomingCrossChainCall`** for inbound cross-chain calls from another rollup.

There is no `executeL2Txs` on L2 — that mechanism lives on L1 and handles the L1-side commit of L2 user actions. A `bytes32(0)` `proxyEntryHash` is unreachable on L2.

#### `staticCrossChainCall` (L2)

Same shape as L1: inside an execution it scans the active entry's unified `expectedOutgoingCalls` for a row whose `expectedOutgoingHash` matches `keccak256(crossChainCallHash, _rollingHash)` (forward window from `_lastOutgoingCallConsumed`); outside it scans the `staticEntries` pool matched by `proxyEntryHash` + `expectedEntryIndex == entryIndex`, gated on `lastLoadBlock == block.number` — the L2 `StaticExecutionEntryL2` has no `destinationRollupId` and no `expectedRoots` (single rollup, no roots), so the block gate bounds staleness. `sourceRollupId` in the call hash is `ROLLUP_ID`; `isStatic = true`; `value = 0`; `callGas` follows the outgoing policy (§C.3). A miss in either branch reverts `EntryNotFound(crossChainCallHash, callGas)`, not L1's bare `ExecutionNotFound`, so the builder can recover the static key under `USE_GAS_LEFT` with the same probe recipe as mutable calls.

#### `createCrossChainProxy` / `computeCrossChainProxyAddress`

Inherited from `EEZBase`. Identical formula on both L1 and L2 (§B.1); L2's `SameNetworkProxy` guard forbids `originalRollupId == ROLLUP_ID`.

### B.3 CrossChainProxy.sol

```solidity
constructor()
```

One immutable: `EEZ` (`src/base/CrossChainProxy.sol`), holding the deploying EEZ contract address from `msg.sender` (L1 `EEZ` or L2 `EEZL2`). The `(originalAddress, originalRollupId)` pair lives in the CREATE2 salt and the manager's `authorizedProxies` mapping. The proxy is constructed by `EEZBase._createCrossChainProxyInternal` (reached via the external `createCrossChainProxy` or auto-creation in `_processL2ToL1Calls` (L1) / `_processIncomingCalls` (L2)).

The constructor sweeps any ether predeployed at the proxy address (otherwise stuck) to `IEEZ(msg.sender).RECOVERY_ADDRESS()`, best-effort: the transfer result is ignored and failed recovery leaves ETH in the proxy. The sweep is capped at `RECOVERY_ETHER_GAS = 100_000` (the EVM forwards min(cap, available)), so a gas-burning recipient cannot starve the rest of the constructor. `RECOVERY_ADDRESS()` is on the shared `IEEZ` interface and is a separately configured nonzero immutable on both L1 and L2 (`InvalidRecoveryAddress` rejects zero). L2 outgoing value still goes to `SYSTEM_ADDRESS`.

#### `executeOnBehalf(address destination, uint64 callGas, bytes calldata data)` (payable ABI through `ICrossChainProxy`)

The payable fallback checks the selector and manager identity before decoding arguments. Non-manager calldata is forwarded unchanged, even when it collides with this selector but is invalid for its ABI.

If `msg.sender == EEZ`: call `destination.call{value: msg.value}(data)` when `callGas == 0` (forward all remaining gas), else `destination.call{value: msg.value, gas: callGas}(data)`. Return/revert raw bytes via assembly. `callGas` is the executing call's `L2ToL1Call.gas` / `CrossChainCall.gas` field, passed straight through by `_processL2ToL1Calls` (L1) / `_processIncomingCalls` (L2); it caps the destination call. Flat-call `CALL_BEGIN` hashes use zero gas (§C.5); L2 inbound entry identity separately binds the incoming cap (§C).

Else: route through `_fallback()` — the transparent-proxy pattern: the manager admin (when the manager itself calls `executeOnBehalf`) gets direct forwarding; any other caller hitting `executeOnBehalf` enters the cross-chain path.

#### `staticCheck()` (private selector used by the payable fallback)

The payable fallback handles this selector locally only if `msg.sender == address(this)`: attempt `_staticDetector = 0` (a `tstore`), then return. In static context this halts; in normal context it succeeds with empty return data. Other callers route through `_fallback()` with their original calldata and value. `STATIC_CHECK_SELECTOR` is a private constant; `staticCheck` is not declared in the public ABI. `src/interfaces/ICrossChainProxy.sol` exposes only `executeOnBehalf`.

Because the check is on `msg.sender`, a destination that makes the proxy call itself with this selector via `executeOnBehalf` also reaches the detector rather than a forwarded cross-chain call. The prover must reproduce that outcome.

#### `fallback() external payable` and `_fallback()` internal

```
staticCheckGas = IEEZ(EEZ).STATIC_CHECK_GAS() // manager-owned cap, read on every fallback
(detectSuccess, _) = address(this).call{gas: staticCheckGas}(abi.encodeWithSelector(STATIC_CHECK_SELECTOR))
if (!detectSuccess):
    // STATICCALL context — look up cached result
    (success, result) = EEZ.staticcall(abi.encodeCall(IEEZ.staticCrossChainCall, (msg.sender, msg.data)))
else:
    // Normal context — execute cross-chain call
    (success, result) = EEZ.call{value: msg.value}(abi.encodeCall(IEEZ.executeCrossChainCall, (msg.sender, msg.data)))

if (success):
    result = abi.decode(result, (bytes))    // unwrap the inner bytes returned by IEEZ.*
// assembly return/revert raw result
```

The `abi.decode(result, (bytes))` unwrap is required because `executeCrossChainCall` and `staticCrossChainCall` both return `bytes memory`, and the low-level `.call() / .staticcall()` ABI-encodes that return value. The proxy strips one layer so the caller sees the destination's raw return data (matching the behavior the destination saw via `executeOnBehalf`'s assembly return). On revert, the raw revert data is not ABI-wrapped, so it is forwarded directly.

---

## C. Action Hash Computation

The formula:

```solidity
// EEZBase.computeCrossChainCallHash, inherited by both managers
crossChainCallHash = keccak256(abi.encode(
    isStatic, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, callGas, data
))
```

The sites differ only in the `callGas` value they fold:

| Matching site | `callGas` folded |
|---|---|
| Everything on L1 (entry points, flat calls, reentrant rows, static) | `0` (`ZERO_CALL_GAS`) |
| L2 inbound binding (`executeIncomingCrossChainCall` vs `entries[0].proxyEntryHash`) | `incomingCalls[0].gas` |
| L2 flat-call `CALL_BEGIN` folds (§C.5) | `0` (`ZERO_CALL_GAS`) |
| L2 static matching (`staticCrossChainCall`, both branches) | `uint64(gasleft())` when the hash is computed if `USE_GAS_LEFT`, else `0` |
| Calls LEAVING an L2 (`EEZL2.executeCrossChainCall` — top-level `proxyEntryHash` match AND the nested `expectedOutgoingHash` key) | **`uint64(gasleft())` when `USE_GAS_LEFT`, else `0`** |

Under `useGasLeft = false`, outgoing hashes fold `0`; inbound binding still uses `incomingCalls[0].gas`. See §B.1 for the rationale and the `callGas` ⇄ `CrossChainCall.gas` relationship.

Off-chain tooling (`script/e2e/shared/E2EHelpers.sol`): `crossChainCallHash` / `crossChainCallHashStatic` fold `callGas = 0`; `crossChainCallHashL2Out` keys L2-outgoing calls.

### C.1 Hash from `executeCrossChainCall` (L1)

| Field | Value |
|---|---|
| `isStatic` | `false` (`NOT_STATIC_CALL`) |
| `sourceAddress` | `sourceAddress` (msg.sender of the original proxy call) |
| `sourceRollupId` | `MAINNET_ROLLUP_ID = 0` |
| `targetAddress` | `proxyInfo.originalAddress` |
| `targetRollupId` | `proxyInfo.originalRollupId` |
| `value` | `msg.value` |
| `callGas` | `0` (`ZERO_CALL_GAS`) — L1 never keys on gas |
| `data` | `callData` (forwarded by the proxy as `msg.data`) |

### C.2 Hash from `executeCrossChainCall` (L2)

**Outgoing mutable and static L2 calls share this gas-keying policy.** Fields as in C.1, except:

| Field | Value |
|---|---|
| `sourceRollupId` | this L2's `ROLLUP_ID` |
| `targetRollupId` | `proxyInfo.originalRollupId` (the proxied counterparty — L1 or another L2) |
| `callGas` | `uint64(gasleft())` when the hash is computed if `USE_GAS_LEFT`, else `0` |

The folded value is echoed in L2's `CrossChainCallExecuted` event, and on a top-level miss in `EntryNotFound(crossChainCallHash, callGas)`, so a builder can recover the exact key.

### C.3 Hash from `staticCrossChainCall`

`isStatic = true` (`IS_STATIC`), `value = 0` (STATICCALL cannot carry ETH), and `callGas = 0` on L1; on L2, `uint64(gasleft())` sampled after proxy authorization/storage reads when `USE_GAS_LEFT`, otherwise `0`; source/target pairs as in the corresponding `executeCrossChainCall`. Because `isStatic` is folded into the hash, a static read keys distinctly from an otherwise-identical state-changing call — this is what routes static rows vs call rows inside the unified reentrant table without a mode field.

### C.4 Hash for reentrant calls

Identical to the proxy hash that triggered the reentrant call — so a reentrant call leaving an L2 folds `callGas` exactly like a top-level one (C.2), and every reentrant call on L1 folds `0`. The protocol does not distinguish "top-level" vs "reentrant" in the call hash itself; the routing decision (`_consumeAndExecuteEntry` vs `_consumeNestedCall`) is made at runtime via `_insideExecution()`. Inside the reentrant table, the call hash is bound to its execution point by the position key `keccak256(abi.encodePacked(crossChainCallHash, expectedRollingHash))` (§A.1), computed by `EEZBase._computeExpectedL1toL2Hash`.

### C.5 Hash for flat-call `CALL_BEGIN` folds

Each executed flat call folds its own identity hash into `CALL_BEGIN` (§E): `computeCrossChainCallHash(cc.isStatic, cc.sourceAddress, cc.sourceRollupId, cc.targetAddress, MAINNET_ROLLUP_ID, cc.value, ZERO_CALL_GAS, cc.data)` on L1, with `ROLLUP_ID` as the target on L2 — the executing chain is always the target. **`callGas = 0` on both chains**: a flat call is a call being DELIVERED on the executing chain, not one leaving it, so `cc.gas` is passed to the proxy but never folded into the identity hash.

### C.6 No `crossChainCallHash` for L2Tx entries

`executeL2Txs(rollupId)` requires `entry.proxyEntryHash == bytes32(0)`. There is no separate L2Tx hash — the entry is identified by being the next zero-hash entry the forward scan reaches on the rollup's queue.

---

## D. Execution Model

### D.1 Forward-Scan Entry Consumption

Entries in `verificationByRollup[rid].entryQueue` (or `_transientEntries` during `postAndVerifyBatch`) are consumed via the rollup's `entryQueueIndex` (or the global `_transientEntryIndex` during the transient phase — per-rollup cursors stay untouched then). Consumption is a **forward scan** from the cursor to the first entry satisfying the full match predicate (`_entryMatches`):

```
entry.proxyEntryHash      == crossChainCallHash        // identity
entry.destinationRollupId == destRid                   // routing
every rollupUpdates[i].currentRoot == live root         // state preconditions
```

The cursor is then set to `matchIndex + 1`. A non-matching entry (wrong hash, wrong routing, stale state) is **skipped**, not reverted on; the scan reverts `ExecutionNotFound` only at the end of the queue. A consumed entry with `success == false` runs, verifies, then reverts with its `returnData` — rolling back the cursor advance — so it is re-callable and only drops out of reach once a later successful consumption advances past it. There is no swap-and-pop.

Cross-rollup independence: a stuck cursor on one rollup does not block consumption on another — each rollup's queue advances on its own. (During the transient phase the cursor is global, which is why `destinationRollupId == destRid` is load-bearing there.)

### D.2 Flat Call Processing

Within an entry, the **top-level** calls live in the entry's own flat array (`l2ToL1Calls[]` on L1, `incomingCalls[]` on L2), and every reentrant frame carries its **own** flat sub-array. `_processL2ToL1Calls` (L1) / `_processIncomingCalls` (L2) walks whichever array it is given with a plain local index until completion or a gas-shortage early return — there is no shared global cursor, no `callCount`, and no partition invariant. Proofs must exclude surviving failure markers; the loop alone does not guarantee dispatch of the entire array.

A flat call dispatches via `CALL` normally, or via `STATICCALL` when `isStatic == true` (read-only; `value` must be 0 or the entry reverts `StaticCallWithValue`). Each call's identity hash folds into `CALL_BEGIN` and its `(success, retData)` outcome into `CALL_END` (§E) — a naturally-reverting destination is captured as `CALL_END(false, revertData)` without failing the entry.

The end-of-entry accounting is carried entirely by the rolling hash (§H.4): wrong results, missing/extra calls, and skipped reentrant frames all diverge the final hash.

### D.3 Reentrant Calls (unified `ExpectedL1ToL2Call` table)

When the destination contract called by `_processL2ToL1Calls` (L1) / `_processIncomingCalls` (L2) calls back into a proxy, the proxy forwards to `executeCrossChainCall`. Inside that call, `_insideExecution() == true`, so the path branches to `_consumeNestedCall` (L1 additionally checks the target rollup against the entry's proven set — `ReentrantDestinationNotVerified`). Resolution (L1 names; L2 mirrors with `expectedOutgoingCalls` / `expectedOutgoingHash` / `_lastOutgoingCallConsumed`):

**1. Compute the position key** `expectedL1toL2Hash = keccak256(abi.encodePacked(crossChainCallHash, _rollingHash))` — the call's identity bound to the live rolling hash, which folds the recorded calls and nesting boundaries. An ordinary revert restores that hash, so an identical retry can reuse the key.

**2. Strict forward scan** of the active entry's `expectedL1ToL2Calls[]` from `_lastL1ToL2CallConsumed`. The first key match IS the row; advance `_lastL1ToL2CallConsumed = i + 1` **before** resolving, then `_resolveNestedReentrant`:
   - `success == true`: fold `NESTED_BEGIN(crossChainCallHash)`, process the row's own `l2ToL1Calls[]` subject to gas checks (folding into the host's continuous hash), fold `NESTED_END`, return `row.returnData` to the destination.
   - `success == false`: fold `NESTED_BEGIN(crossChainCallHash)`, run the row's own sub-array, check `_rollingHash == row.revertedOrStaticRollingHash` (else `RollingHashMismatch`), then revert with `row.returnData`. The destination's `try/catch` absorbs the revert; the EVM rolls back the frame's state, hash folds, and cursor advance automatically.

**3. No match** → fold `CALL_NOT_FOUND(crossChainCallHash)` into `_rollingHash` and return `""`. The entry later fails its rolling-hash check (`RollingHashMismatch`) at the `_executeEntry` boundary — `ContextResult` carries the divergence across deliberate revert spans; an ordinary enclosing revert rolls back the marker with the frame. (Returning empty bytes may also revert the *caller's* frame sooner if it ABI-decodes a non-empty payload.)

**Why this works for reverts.** A reverting reentrant call needs **only** a `success == false` row — no `revertNextNCalls` wrapper: the destination's `try/catch` is the isolation boundary, the terminal revert restores the cursor and hash to the pre-call values, and the row's `revertedOrStaticRollingHash` pins exactly what the reverted frame executed.

**Why static reads don't match here.** The key is computed with `isStatic = false`; a static row's `crossChainCallHash` folds `isStatic = true`, so the keys can never collide. The proxy routes real STATICCALL frames to `staticCrossChainCall` (§F), which scans the same unified table with the `isStatic = true` key and resolves via `_resolveStaticEntry` — without advancing the cursor (a read is position-pinned, not consumed).

A reverted sub-execution reuses the host entry's table for its own reentrant calls (Solidity forbids recursive structs); the live `_rollingHash` folded into each key keeps the contexts distinct.

#### D.3.1 Nested children must be laid out after their parent (forward-cursor layout)

Reentrant rows in `expectedL1ToL2Calls[]` are content-addressed by `(crossChainCallHash, expectedRollingHash)` and located by a **strict forward scan** from `_lastL1ToL2CallConsumed`: a call only ever matches a row at or after the cursor, never one before it. The match is the rolling hash, not the array position — but the cursor governs *which slice of the table is still visible*.

When a reentrant row at index `i` is resolved (`_resolveNestedReentrant`), the cursor is advanced to `i + 1` **before** the row's own sub-calls run, not after. This keeps the cursor monotonic: any reentrant call the sub-frame fires scans strictly forward from `i + 1`, and a successful frame leaves the cursor at its high-water mark with no restore step. (On revert the whole frame's writes — including this advance — roll back with the EVM, so the cursor returns to the parent's value automatically.)

**Layout rule for provers/builders.** A nested frame's own reentrant children must be placed in `expectedL1ToL2Calls[]` at indices **strictly greater than their parent row's index** — i.e. the table must be in depth-first / execution order. A child placed at an index `≤` its parent is below the cursor when the sub-frame scans, so it is never found: the reentrant call folds `CALL_NOT_FOUND` into the rolling hash and the entry reverts at its boundary (`RollingHashMismatch`). This is purely a *findability* constraint; it never produces a wrong match, because lookup still requires the expected call identity and recorded hash context. Sibling rows at the same nesting level are already forward-ordered by the same cursor discipline.

### D.4 Revert Span (`revertNextNCalls`)

`revertNextNCalls > 0` on a flat call opens an isolated EVM context for the next `revertNextNCalls` calls (that call included). Mechanism:

1. `_processL2ToL1Calls` (L1) / `_processIncomingCalls` (L2) checks the span fits (`RevertSpanOutOfBounds` otherwise), zeroes the trigger's `revertNextNCalls` in its throwaway memory copy, and slices the span (`_sliceL2ToL1Calls` / `_sliceCrossChainCalls`) into a fresh memory array — so the isolated re-run reads the trigger as a normal call instead of recursing into the span.
2. `try this.executeInContextAndRevert(span)`. The inner self-call runs `_processL2ToL1Calls(span)` — advancing `_rollingHash` and `_lastL1ToL2CallConsumed` based on the calls inside the span — then **always** reverts with `ContextResult(_rollingHash, _lastL1ToL2CallConsumed)` (L2: `_processIncomingCalls(span)` and `_lastOutgoingCallConsumed`).
3. The EVM revert rolls back all storage and transient state inside the self-call, including any ETH transfers and their `_entryEtherDelta` subtractions. The values escape via the revert data.
4. The caller decodes `ContextResult` and writes the rolling hash and reentrant cursor back into transient storage. A reentrant no-match observed inside the span was folded into that rolling hash (`CALL_NOT_FOUND`), so it still surfaces at the entry boundary. The restored hash records the span's execution outcomes while its state effects remain rolled back.
5. The caller emits `CallsReverted(entryIndex, start, n)` and skips its local index past the span.

A single mechanism handles atomic rollback: there are no continuation entries, no per-rollup root restoration, no scope tree to navigate. The "what happened" is encoded by the calls in the span; the "what state survives" is whatever the EVM rolled back.

#### D.4.1 When to use `revertNextNCalls` (and when not to)

**Use `revertNextNCalls > 0` only for forced rollback of a span** — its state effects must not survive, while individual calls may succeed or fail. The canonical scenario is a cross-chain call from rollup A to rollup B where the destination on B succeeds, but the prover output records that the call must be rolled back (for example, because the higher-level transaction that contained the call was reverted on A). In that example the rolling hash commits to `CALL_END(success=true, retData=…)` while the EVM rolls the state back; failed calls elsewhere in a span retain their actual failure outcomes.

**Do not use it to model a destination that naturally reverts.** With `revertNextNCalls = 0`, `_processL2ToL1Calls` (L1) / `_processIncomingCalls` (L2) already invokes the destination via the proxy's `.call`, captures `(success=false, retData=revertReason)`, and hashes that into `CALL_END`. The destination's own revert rolls back its own state. Wrapping a single naturally-reverting call in a span of 1 produces the same observable state for no benefit — the mechanism only earns its keep when state would otherwise survive.

The protocol's revert paths are distinct — the full situation → structure decision table is `EXECUTION_ENTRY_SPEC.md` § "When to use which structure". In particular, a **reentrant** call that reverts (caller wraps it in `try/catch`) is a `success == false` row in the unified reentrant table (§D.3) and **must not** use `revertNextNCalls`: the destination's `try/catch` already provides the isolation boundary, and the row runs the reverted frame with its own sub-hash check. Wrapping it in a span would consume flat-call slots the prover did not allocate.

### D.5 Flat Call Model

The off-chain prover emits, per entry, a flat top-level `l2ToL1Calls[]` array plus the unified `ExpectedL1ToL2Call[]` table (L2: `incomingCalls[]` / `ExpectedOutgoingCrossChainCall[]`) in which each reentrant frame carries its own flat sub-array — it does not thread scope arrays through nested calls and does not partition one shared array. Return data from a call is captured directly into the rolling hash via `CALL_END`; natural failures are captured via `success=false` in the same tag. `revertNextNCalls` is reserved for forced-revert spans where state must be rolled back regardless of individual success/failure outcomes.

---

## E. Rolling Hash

A single `bytes32 rollingHash` per entry covers the entry's identity, its starting state context, every call result, and every nesting boundary. The six tag constants and the fold helpers (`_rollingHashEntryBegin` / `_rollingHashCallBegin` / `_rollingHashCallEnd` / `_rollingHashNestedBegin` / `_rollingHashNestedEnd` / `_rollingHashCallNotFound` / `_rollingHashCallInsufficientGas`) live on `EEZBase` and are **protocol constants shared by both chains** — the `CALL_*` / `NESTED_*` tags are the neutral rolling-hash frame vocabulary, not a direction.

The accumulator is **seeded** at entry start (it must be `bytes32(0)` beforehand, else `RollingHashNotCleared`):

```
// L1 (_rollingHashEntryBegin): ordered (rollupId, currentRoot) state context, closed with identity
seed         = keccak256(…keccak256(bytes32(0) ‖ rollupId_1 ‖ currentRoot_1)… ‖ rollupId_n ‖ currentRoot_n)
_rollingHash = keccak256(abi.encodePacked(seed, proxyEntryHash))

// L2 (_seedRollingHash): same formula with an empty state-delta prefix
_rollingHash = keccak256(abi.encodePacked(bytes32(0), proxyEntryHash))
```

so the hash binds the entry's STARTING STATE + identity, not just call results (nested frames inherit it transitively). It is then updated at six tagged hash transitions (these are not Solidity log events) (all `abi.encodePacked`):

```
CALL_BEGIN     = uint8(1)   _rollingHash = keccak256(_rollingHash ‖ CALL_BEGIN ‖ crossChainCallHash)
CALL_END       = uint8(2)   _rollingHash = keccak256(_rollingHash ‖ CALL_END ‖ success ‖ retData)
NESTED_BEGIN   = uint8(3)   _rollingHash = keccak256(_rollingHash ‖ NESTED_BEGIN ‖ crossChainCallHash)
NESTED_END     = uint8(4)   _rollingHash = keccak256(_rollingHash ‖ NESTED_END)
CALL_NOT_FOUND = uint8(5)   _rollingHash = keccak256(_rollingHash ‖ CALL_NOT_FOUND ‖ crossChainCallHash)
CALL_INSUFFICIENT_GAS = uint8(6) _rollingHash = keccak256(_rollingHash ‖ CALL_INSUFFICIENT_GAS)
```

`CALL_BEGIN` binds the executed call's full identity (its eight-field `crossChainCallHash`, §C.5) so the hash commits to *which* call ran, not just its result. `NESTED_BEGIN` binds the reentrant call's identity the same way. **No call/frame index is folded in**: `_rollingHash` is a chain (each fold depends on the prior value), so order, count, and nesting are already bound by the chain + the tags; omitting an explicit index is also what lets a `revertNextNCalls` span be processed as a 0-based sub-slice without diverging the hash from a continuous run.

`CALL_NOT_FOUND` is folded when a reentrant call finds no matching row in the unified table. The dedicated tag is distinct from `CALL_END(true, "")` (what the caller folds for a normal empty return), so a no-match can never be forged as one. The divergence is caught at the entry's rolling-hash check if the marker remains in the committed trace (`ContextResult` carries it across deliberate revert spans; ordinary enclosing reverts undo it), so no side flag is needed. Valid proofs MUST exclude both `CALL_NOT_FOUND` and `CALL_INSUFFICIENT_GAS` from expected entry and sub-hashes (§H.4). An accepting mock or trusted loader can supply a marker-containing expected hash; matching it is not evidence of a valid production proof. Ordinary enclosing reverts erase marker writes, even if an intervening catch continued execution.

After all calls and nestings complete:

```solidity
require(_rollingHash == entry.rollingHash);   // RollingHashMismatch
```

A single mismatch anywhere in the execution tree changes the final hash — this catches:
- Wrong return data for any call
- Wrong success/failure flag
- Missing or extra calls
- A skipped or extra reentrant frame (missing/extra `NESTED_BEGIN`/`NESTED_END`)
- Reordered operations
- A surviving reentrant miss (`CALL_NOT_FOUND`) or dispatch shortage (`CALL_INSUFFICIENT_GAS`), against a valid marker-free expected hash

### E.1 Rolling Hash and `revertNextNCalls`

Inside a force-revert span, the inner self-call updates `_rollingHash` exactly as if the calls were normal (`CALL_BEGIN`/`CALL_END` for each, including failed ones). The `ContextResult` revert payload carries the post-span hash value back out, so the outer flow's rolling hash reflects that the span happened — even though the EVM rolled back the state changes the calls produced. This is essential: the proof's `rollingHash` must commit to the calls regardless of whether their state effects survived.

The mechanism relies on EIP-1153 `tload` / `tstore` semantics:

- `tload` is **read-only**, so it works inside a STATICCALL context **and** inside a self-call that is about to revert. The inner self-call therefore observes the outer `_rollingHash` and cursor values when it starts.
- `tstore` writes are part of the EVM journal and are **rolled back** when the call frame reverts. So when `executeInContextAndRevert` reverts with `ContextResult`, every transient write performed inside the span (including the rolling-hash updates, the reentrant-cursor advances, and the `_entryEtherDelta` subtractions) is undone — except for the values that escape via the revert payload (the rolling hash and the reentrant cursor), which the caller manually re-applies after decoding.

### E.2 Static Sub-Hash (`rollingHash` / `revertedOrStaticRollingHash`)

Every static resolution carries its own expected hash — **a separate accumulator**, scoped to that static entry/row and computed over its read-only sub-call array. It is **not** the entry-level `_rollingHash`. The scheme is deliberately simpler and **untagged**, computed by `_processStaticL2ToL1Calls` on L1 and `_processStaticIncomingCalls` on L2:

```
hash = bytes32(0)
for cc in calls:
    sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId)
    (success, retData) = sourceProxy.staticcall(executeOnBehalf(cc.targetAddress, cc.gas, cc.data))
    hash = keccak256(abi.encodePacked(hash, success, retData))
if (hash != expected) return false;   // try the next static candidate
```

The `expected` value is `StaticExecutionEntry.rollingHash` for a top-level static entry, or `ExpectedL1ToL2Call.revertedOrStaticRollingHash` for a static row inside the unified reentrant table.

The differences from the entry-level scheme:

- **No event tags** (no `CALL_BEGIN` / `CALL_END` / `NESTED_BEGIN` / `NESTED_END` domain bytes) and no call-identity folds.
- **No nesting** at all — `_processStaticL2ToL1Calls` does not handle reentrancy; STATICCALL forbids state writes, so the proxies' `executeOnBehalf` paths cannot reenter the manager's mutating entrypoints. A reentrant read during resolution re-enters `staticCrossChainCall` and resolves independently.
- **No proxy creation and no `revertNextNCalls`** — nothing mutates.

This simpler schema is safe because the surrounding key already pins the context that tagged events disambiguate at entry level: a nested static row is content-addressed by `keccak256(crossChainCallHash, _rollingHash-at-fire-point)` within its entry, and a top-level static entry by `proxyEntryHash` + queue routing + (L1) the `expectedRoots[]` pins. The only thing left for the static hash to commit to is the **outcome of the read-only sub-calls, in order**, which is exactly what the untagged `keccak256(prev, success, retData)` chain captures. There is also no cross-contamination with the entry-level accumulator: `_processStaticL2ToL1Calls` returns a local hash and never reads or writes `_rollingHash`.

Note the distinction inside the unified table: a **static** row's sub-array runs via STATICCALL under the untagged schema, while a **reverted call** row's sub-array runs as real calls under the tagged entry schema (its `revertedOrStaticRollingHash` is compared against the live `_rollingHash` at the end of the frame, which was seeded from the host hash at `NESTED_BEGIN`). The `isStatic` bit folded into `crossChainCallHash` decides which resolution path can reach the row.

### E.3 Worked Hash Chain Example

Setup (L1 names; the L2 chain is identical with `incomingCalls` / `expectedOutgoingCalls` / `_lastOutgoingCallConsumed` and the delta-less seed):

```
entry.rollupUpdates         = [ d0 ]
entry.proxyEntryHash      = P
entry.l2ToL1Calls         = [c0, c1]           // top-level calls
entry.expectedL1ToL2Calls = [ R0 ]
R0 = { expectedL1toL2Hash = keccak256(H_nested ‖ S1),   // computed by the prover in simulation
       l2ToL1Calls        = [n0],                        // the frame's own sub-call
       success            = true,
       returnData         = 0xaa }
entry.rollingHash         = <expected final hash>
```

While c0 executes, the destination contract re-enters a proxy with reentrant call hash `H_nested`; the frame runs `n0`, then returns `0xaa`.

Step-by-step:

```
Seed:
  seed = keccak256(bytes32(0) ‖ d0.rollupId ‖ d0.currentRoot)
  S0   = keccak256(seed ‖ P)                                 // _rollingHashEntryBegin
  _lastL1ToL2CallConsumed = 0

─── _processL2ToL1Calls([c0, c1]), i = 0 ─────────────

  hash CALL_BEGIN with c0's identity hash ccHash(c0):
    S1 = keccak256(S0 ‖ uint8(1) ‖ ccHash(c0))

  Execute c0 via the source proxy. During c0, the destination re-enters a proxy
  → executeCrossChainCall → _insideExecution() == true → _consumeNestedCall(H_nested):

      key = keccak256(H_nested ‖ S1)                          // live _rollingHash is S1
      forward scan from cursor 0 → matches R0.expectedL1toL2Hash
      _lastL1ToL2CallConsumed = 1                             // advanced BEFORE the frame runs

      hash NESTED_BEGIN(H_nested):
        S2 = keccak256(S1 ‖ uint8(3) ‖ H_nested)

      _processL2ToL1Calls([n0]):                                   // the frame's OWN sub-array
        hash CALL_BEGIN(ccHash(n0)):
          S3 = keccak256(S2 ‖ uint8(1) ‖ ccHash(n0))
        Execute n0. Succeeds with retData_n0.
        hash CALL_END(true, retData_n0):
          S4 = keccak256(S3 ‖ uint8(2) ‖ true ‖ retData_n0)

      hash NESTED_END:
        S5 = keccak256(S4 ‖ uint8(4))

      return R0.returnData (0xaa) to the destination

  c0's proxy call returns. Proxy reports success and retData_0.
  hash CALL_END(true, retData_0):
    S6 = keccak256(S5 ‖ uint8(2) ‖ true ‖ retData_0)

─── _processL2ToL1Calls([c0, c1]), i = 1 ─────────────

  hash CALL_BEGIN(ccHash(c1)):
    S7 = keccak256(S6 ‖ uint8(1) ‖ ccHash(c1))
  Execute c1. Succeeds with retData_1.
  hash CALL_END(true, retData_1):
    S8 = keccak256(S7 ‖ uint8(2) ‖ true ‖ retData_1)

─── Verification ─────────────

  _rollingHash (S8) == entry.rollingHash    → RollingHashMismatch?   no
  ether invariant: totalEtherDelta == _entryEtherDelta               (L1)
  _rollingHash reset to 0; allowed-rollups set deleted
```

Hash chain summary:

```
S0 = keccak(keccak(0 ‖ rid ‖ currentRoot) ‖ P)
S1 = keccak(S0 ‖ CALL_BEGIN   ‖ ccHash(c0))
S2 = keccak(S1 ‖ NESTED_BEGIN ‖ H_nested)
S3 = keccak(S2 ‖ CALL_BEGIN   ‖ ccHash(n0))
S4 = keccak(S3 ‖ CALL_END     ‖ true ‖ retData_n0)
S5 = keccak(S4 ‖ NESTED_END)
S6 = keccak(S5 ‖ CALL_END     ‖ true ‖ retData_0)
S7 = keccak(S6 ‖ CALL_BEGIN   ‖ ccHash(c1))
S8 = keccak(S7 ‖ CALL_END     ‖ true ‖ retData_1)

require(S8 == entry.rollingHash)
```

### E.4 Multiple Reads Within One Call (Static Disambiguation)

A single call iteration can issue several STATICCALLs at distinct points of its execution, possibly with the same `crossChainCallHash`. The disambiguating coordinate is the live `_rollingHash` folded into each row's position key: an intervening recorded fold (`CALL_BEGIN`, `CALL_END` or a nested frame) changes `_rollingHash`, so the two reads compute different keys and match different rows.

Example: while `entry.l2ToL1Calls[0]` executes (live hash `S1` after its `CALL_BEGIN`), the destination contract:

```
STATICCALL to proxy → staticCrossChainCall
  → key = keccak256(H_read ‖ S1) → matches the row the prover stamped for this point

Trigger reentrant call (a successful reentrant frame)
  → _consumeNestedCall matches at key keccak256(H_nested ‖ S1); the frame's folds move the hash to S5

STATICCALL to proxy → staticCrossChainCall
  → key = keccak256(H_read ‖ S5) → a DIFFERENT row, even for the same H_read
```

Two reads with the same `crossChainCallHash` and **no** intervening fold compute the same key. Lookup tries sibling rows until the callback-result hash matches, allowing local writes to distinguish reads without a host-hash fold. If incompatible candidates both validate, the first wins; builders must reject or restructure that ambiguity. L2 top-level selection also pins `expectedEntryIndex == entryIndex`. The builder records the live `_rollingHash` at each STATICCALL and stamps `keccak256(crossChainCallHash, thatHash)` into each corresponding row. The forward window still applies: every candidate must be at an index `>= _lastL1ToL2CallConsumed` at read time (§D.3.1); static reads do not advance that cursor.

---

## F. Static Entry Resolution

Read-only cross-chain calls (and pre-verified reverting reentrant calls) are resolved from prover-supplied data — never executed via the normal call path. Two entry points:

1. **`staticCrossChainCall`** (external view) — used when the proxy's `_fallback` detects a real STATICCALL context (a self-call to `staticCheck` whose `tstore` reverts). Inside an execution it scans the active entry's unified reentrant table with an `isStatic = true` key; outside, the top-level static-entry pool (L1: `proxyEntryHash` + `destinationRollupId` + live root pins; L2: `proxyEntryHash` + `expectedEntryIndex == entryIndex`).
2. **Reverted-frame resolution inside `_consumeNestedCall`** — not a read, but the revert twin: a normal-CALL reentrant call matching a `success == false` row runs the frame and reverts with the cached payload (§D.3). It shares the unified table, keyed with `isStatic = false`.

The full specification — match keys, resolution mechanics, static sub-calls, root pins, L1/L2 differences, invariants — lives in **`docs/STATIC_ENTRY.md`**. Within this document: the `staticCrossChainCall` pseudocode is in §B.1, the untagged static accumulator in §E.2, and static key disambiguation in §E.4. For which structure models which situation, see `EXECUTION_ENTRY_SPEC.md` § "When to use which structure".

---

## G. Execution Entry Lifecycle

### G.1 L1 Posting

`postAndVerifyBatch` resets each touched rollup's `verificationByRollup[rid]` (reset queue bounds and cursor on every verify), drains the leading immediate L2Txs straight from calldata, loads the meta-hook remainder of the immediate prefix into `_transientEntries` / `_transientStaticEntries` and runs the meta hook, publishes the batch's remainder into the per-rollup queues unconditionally, then wipes the transient tables.

Within a single `postAndVerifyBatch`:
1. Reentry guard: `_insideExecution() || _transientEntriesLength != 0` (revert `PostBatchReentry` when either is true). Check composer root pins. Validate structure (including per-entry proxy-protection). Verify proofs (`checkProofSystemsAndGetVkeys` + `getCustomData` per rollup — both `view` — then `IProofSystem.verify` per PS).
2. Mark `verificationByRollup[rid].lastVerifiedBlock = block.number` for every touched rollup; reset each touched rollup's queue bounds / cursor on every verify (`_markVerifiedBlockAndResetQueues`).
3. Drain the leading run of immediate L2Txs (`proxyEntryHash == 0`) via try/catch self-calls (skip-on-revert with `L2TxSkipped`; `AllImmediateL2TxsFailed` if a non-empty run had zero successes).
4. Meta hook runs if immediate-prefix entries remain past the L2Tx run (`msg.sender` must have code — `MetaEntriesWithoutReceiver` otherwise) — the remainder is pushed to the transient tables first (consumption advances the global `_transientEntryIndex`; per-rollup cursors stay untouched until persistent consumption).
5. Publish the batch's remainder to per-rollup queues by `destinationRollupId` (unconditionally — even if the transient prefix wasn't fully drained; there is no drain-cleanly gate). Soundness backstop is `RollupUpdate.currentRoot`.
6. Wipe transient tables; reset `_transientEntryIndex`. Emit `BatchPosted(sharedPublicInput, rollupIds)`.

### G.2 L2 Loading

`loadExecutionTable` clears `entries` and `staticEntries`, copies the new entries / static entries in, resets `entryIndex`, and sets `lastLoadBlock = block.number`. `executeIncomingCrossChainCall` performs the same load atomically before driving `entries[0]`. There is no transient table and no per-rollup queue map on L2.

### G.3 Consumption

Forward-scan — per consumption, the cursor jumps to `matchIndex + 1` (per-rollup `entryQueueIndex`, the global `_transientEntryIndex` during the transient phase, or L2's `entryIndex`). Each entry is consumed at most once; entries skipped by the scan (stale state, non-matching hash) are permanently passed over. A `success == false` entry's revert rolls the cursor advance back, so it stays reachable until a later successful consumption advances past it. There is no swap-and-pop.

### G.4 Same-Block Restriction

Execution and static lookup tables are valid only in the block they were posted or loaded. L1 requires `verificationByRollup[rollupId].lastVerifiedBlock == block.number`; L2 uses `lastLoadBlock == block.number`. Expired tables are inaccessible, and posting/loading a new table replaces the previous one.

### G.5 Table Replacement

Each `postAndVerifyBatch` resets the touched rollups' queue bounds and cursors (on every verify, including same-block re-verifies); `loadExecutionTable` resets the L2 active lengths and cursor, then overwrites slots from zero without deleting inactive rows. Builders must produce self-contained batches.

---

## H. Invariants

### H.1 Root Consistency (L1)

`rollups[id].root` is updated only:
- By `_applyRollupUpdates` (during `_executeEntry`, reached from `postAndVerifyBatch`'s immediate run, the meta hook, `executeCrossChainCall`, or `executeL2Txs`).
- By `setRoot(rid, newRoot)` from the rollup's manager (subject to the same-block lockout and the mid-execution guard).

The previous-state binding lives on the entry: `RollupUpdate.currentRoot` is checked both as part of the consumption match (`_entryMatches`) and as a hard gate at `_executeEntry` start (`RootMismatch(id)` — the gate that covers the immediate L2Tx path, which doesn't pass through `_entryMatches`). `newRoot` applies only **after** the entry's calls, so mid-execution reads see the pre-state. The proof itself binds to the FULL `ExecutionEntry` struct (including `rollupUpdates`), so a stale builder either fails proof verification or fails the on-chain `currentRoot` match. This dual binding is the per-rollup-queue model's soundness backstop.

### H.2 Ether Accounting (L1)

For each entry: `totalEtherDelta == _entryEtherDelta`, where `totalEtherDelta` is the sum of the entry's `rollupUpdates[].etherDelta` and `_entryEtherDelta` is the entry's net physical flow — ALL `msg.value` received via `executeCrossChainCall` during the entry (the entry-point call's value plus every reentrant call's; 0 for `executeL2Txs` and immediate entries unless reentrant receipts occur) MINUS the `value` of every **successful** non-static outbound call. Calls inside a `revertNextNCalls` span contribute to neither side — their ETH transfers and their `_entryEtherDelta` subtractions are rolled back by the span's revert, while the rolling hash still records their actual success/failure outcomes.

Each entry independently balances — ether accounting is localized to a single entry rather than aggregated across the transaction — which simplifies the prover's job.

At successful L1 entry boundaries, protocol-accounted flows satisfy
`Δ held ETH = Σ etherDelta` and preserve
`surplus = address(EEZ).balance − Σ rollups[rid].etherBalance`.
Deposits increase both held ETH and liabilities. Direct or forced ETH can increase
surplus. Temporary transfers inside an entry need not satisfy this boundary relation.

#### L2 funding and inventory

L2 holds pooled system funding without a per-table ledger. Loads add `msg.value`,
incoming calls spend the pool, and outgoing calls transfer their value to
`SYSTEM_ADDRESS`. Replacing tables retains unused ETH; reverted transfers unwind
with their enclosing frame. Proxy recovery sends prefunded ETH to `RECOVERY_ADDRESS`.

The node/circuit must account for opening inventory, funding or issuance, actual
payouts, system transfers, external balance changes and closing inventory. It must
also define how unused funds are retained or reused. No per-load equality or
issuance/burning rule is enforced by the Solidity manager.

### H.3 Forward-Scan Consumption

Within one queue generation, successful consumption advances the destination rollup's cursor beyond the selected entry. A reverted consumption restores the cursor and can be retried. Each new verification resets that rollup's active bounds and cursor. Skipped entries are not executed, and later entries must still match their live root pins.

### H.4 Rolling Hash Integrity

At entry validation, before clearing transient state:

```
_rollingHash == entry.rollingHash        // RollingHashMismatch
```

Against a valid expected hash, this check attests the surviving tagged execution observations, including explicit rollback spans transported by `ContextResult`. It does not attest observations erased by ordinary enclosing reverts. There is no flat-call cursor check (local arrays may stop on gas shortage; valid expected hashes exclude failure markers) and no reentrant table-length check (the unified table mixes call rows with static rows; completeness of the success rows is enforced by the hash — a skipped frame omits its `NESTED` folds — and an unused row is inert).

**Prover requirement:** valid entries and expected sub-hashes must never include
`CALL_INSUFFICIENT_GAS` or `CALL_NOT_FOUND`. Certifying either is malicious prover
behavior. These are failure markers, not permitted successful proof outcomes.

The markers deliberately diverge from an honest expected hash, causing validation
to revert the enclosing execution and its effects from the start. This is best-effort
protection: an ordinary enclosing revert erases the marker, while `ContextResult`
carries it through deliberate rollback spans. The hash mechanism does not independently
enforce an honest prover; the proof system must reject expected hashes containing these paths.

### H.5 Proxy Determinism

The proxy address for a `(originalAddress, originalRollupId)` pair is fully determined by:
- The deploying EEZ contract (the proxy captures it from `msg.sender`; there are no constructor arguments)
- Salt: `keccak256(abi.encodePacked(originalRollupId, originalAddress))` — the ONLY place the pair enters the derivation; all proxies on a manager share identical init code
- `CrossChainProxy` creation code

For a fixed manager and proxy init-code hash, the same pair maps to the same proxy address. Two proxies for the same pair cannot exist (CREATE2 collision would revert). A proxy for the manager's own network is unrepresentable (`SameNetworkProxy`).

### H.6 Same-Block Execution

Execution and static lookups follow the same-block restriction (§G.4).

### H.7 Queue Replacement

`postAndVerifyBatch` resets each touched rollup's `entryQueueLength` / `staticEntryQueueIndex` / `entryQueueIndex` without deleting stored entries on **every** verify — including same-block re-verifies, where the new batch REPLACES the prior one for that rollup. `loadExecutionTable` (L2) similarly resets `entriesLength`, `staticEntriesLength` and `entryIndex`, then overwrites active slots. Both lookup paths stop at their active bound. Reset cost is independent of the old table size; overwriting shorter nested arrays/bytes can still clear their old tails. Reverted incoming delivery restores the previous rows, bounds, cursor, load block and balances. Unconsumed entries from a prior block are unreachable (the `lastVerifiedBlock` read gate stops them even before the reset).

### H.8 Per-Rollup Queue Soundness

The deferred remainder of a `postAndVerifyBatch` is published unconditionally to per-rollup queues. Partial transient drain does not drop persistent entries; the soundness backstop is `RollupUpdate.currentRoot`, checked at consumption. Entries whose recorded pre-state doesn't match the on-chain state at consumption are skipped by the match scan and, if reached directly (immediate path), revert `RootMismatch`.

### H.9 Reentry Guard for `postAndVerifyBatch`

`postAndVerifyBatch` called during an active entry or meta-hook window reverts `PostBatchReentry` — the guard is `_insideExecution() || _transientEntriesLength != 0` at the top of the function (there is no separate `_inPostBatch` flag). Within posting, the two terms cover the execution/hook windows: `_insideExecution()` during the immediate L2Tx run and any executing entry, `_transientEntriesLength != 0` during the meta hook. The remaining external calls before the immediate run (`checkProofSystemsAndGetVkeys`, `getCustomData`, `verify`) are all `view`/STATICCALL, so a reentrant batch cannot complete state writes there; its error need not be `PostBatchReentry`. An ordinary registration callback outside execution/hook context is not covered by this guard and may post an otherwise valid batch. Posting remains permissionless and all normal checks still apply.

Same-block re-touch of a rollup across separate (non-nested) `postAndVerifyBatch` calls is **permitted**: `_markVerifiedBlockAndResetQueues` resets the rollup's queue bounds and cursor on every verify, so the second batch's entries REPLACE the first batch's. Safe because state only mutates at consumption and every entry is gated by `RollupUpdate.currentRoot` — discarding unconsumed-but-proven entries is a liveness choice, not a safety one.

---

## I. Security Considerations

### I.1 Multi-Prover Verification

`postAndVerifyBatch` verifies one proof per `(batch, proofSystem)` pair. Each proof's public-inputs hash covers (see `MULTI_PROVER_SPEC.md` for the exact construction):

- Every entry hash — `keccak256(abi.encode(entry))` over the FULL `ExecutionEntry` struct (including `rollupUpdates` with `currentRoot`, `proxyEntryHash`, `l2ToL1Calls`, the unified `expectedL1ToL2Calls`, `rollingHash`, `destinationRollupId`, `success`, `returnData`).
- Every static-entry hash — `keccak256(abi.encode(staticEntry))`.
- Every selected blob hash (for data availability).
- Per-rollup `customData` blob fetched via `IRollupContract.getCustomData(batch.blockNumber)` (rollup-defined L1-view commitment), hashed keyed by rollupId and bound into `sharedPublicInput` (shared across all PS, not per-PS).
- `keccak256(callData)`.
- `boundSender` — `msg.sender` when `bindMsgSenderInPublicInput`, else `address(0)`.
- Per PS: the rolling `(rollupId, vkey)` accumulator over the rollups that selected that PS.

All proofs in the batch verify atomically — a single failure reverts. Per-rollup attestation is enforced inside each manager's `checkProofSystemsAndGetVkeys`, which reverts (threshold-not-met / unknown-PS / zero-vkey) if the resolved subset for `rid` is insufficient.

A malicious caller producing a forged batch would have to forge proofs from every required PS for every touched rollup at the current rollup states.

### I.2 Reentrancy

The protocol is intentionally reentrant. `_processL2ToL1Calls` (L1) / `_processIncomingCalls` (L2) calls into proxies, which forward to destination contracts, which may call back into proxies. Reentrant calls are routed to `_consumeNestedCall` via the `_insideExecution()` check, and resolve against the executing entry's unified table with rolling-hash-pinned keys — the forward-scan cursor plus the chained hash serialize everything within one entry.

`postAndVerifyBatch` re-entry is blocked by the compound guard described in §H.9. The three view-only external calls during proof verification (`IRollupContract.checkProofSystemsAndGetVkeys`, `IRollupContract.getCustomData`, and `IProofSystem.verify`) are made inside `STATICCALL` frames, so a malicious manager / verifier cannot mutate state during verification.

### I.3 Untrusted Meta Hook

`postAndVerifyBatch` invokes `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` when non-L2Tx immediate entries remain (a codeless sender reverts `MetaEntriesWithoutReceiver` — the never-persisted prefix would be silently dropped). The hook is untrusted — it may revert, consume some entries, ignore the call, or attempt to re-enter `postAndVerifyBatch`. The protocol's defense:

- **Re-entry**: execution/hook windows are guarded by `PostBatchReentry`; static verification and registration callbacks have different rules — see §H.9 / I.2.
- **Partial consumption**: the persistent remainder is published anyway; `RollupUpdate.currentRoot` is the soundness backstop at consumption time.
- **Hook revert**: the entire `postAndVerifyBatch` reverts (atomicity), which rolls back every write — `lastVerifiedBlock`, the queue resets, the immediate entries, the transient stream. The next caller can re-attempt cleanly.

### I.4 Access Control Summary

| Function | Who can call |
|---|---|
| `registerRollup` | Anyone |
| `postAndVerifyBatch` | Anyone (proofs verify authorization; `bindMsgSenderInPublicInput` can pin the submitter) |
| `executeCrossChainCall` (L1 / L2) | Registered proxies only |
| `executeL2Txs(rollupId)` (L1) | Anyone (must not be inside execution) |
| `staticCrossChainCall` (L1 / L2) | Registered proxies only (called via STATICCALL by the proxy) |
| `executeInContextAndRevert` (L1 / L2) | Self-call only (`address(this)`) |
| `_attemptExecuteImmediateL2Txs(entry)` (L1, `public`) | Self-call only (`address(this)`) |
| `createCrossChainProxy` (L1 / L2) | Anyone (subject to `SameNetworkProxy`) |
| `setRoot(rid, newRoot)` (L1) | Current `rollups[rid].rollupContract` (subject to same-block lockout AND `SetRootNotAllowedDuringExecution`) |
| `loadExecutionTable` (L2) | `SYSTEM_ADDRESS` |
| `executeIncomingCrossChainCall(...)` (L2) | `SYSTEM_ADDRESS` |

Per-rollup ownership operations (`addProofSystem`, `removeProofSystem`, `updateVerificationKey`, `setThreshold`, `transferOwnership`) live on the rollup's manager (`src/rollupContract/Rollup.sol` reference impl).

### I.5 Reentry Guard and Same-Block Touch Semantics

`postAndVerifyBatch` reentry during the meta hook or an active entry is blocked by `PostBatchReentry`. Verification callbacks are static and cannot complete state-mutating posting, without guaranteeing this exact error. A registration callback outside those guarded windows can post a valid batch (§H.9).

Multiple top-level `postAndVerifyBatch` calls hitting the same rollup in the same block are permitted by design: `_markVerifiedBlockAndResetQueues` resets the rollup's queue bounds and cursor on every verify, so the second batch fully SUPERSEDES the first for that rollup (no append). Builders cannot rely on once-per-block-per-rollup exclusivity; if exclusivity is required, the orchestrator must enforce it at the social layer.

### I.6 Cross-Chain Proxy Identity

A `CrossChainProxy` represents exactly one `(originalAddress, originalRollupId)` pair. When the manager calls a destination via `CrossChainProxy.executeOnBehalf`, the destination sees `msg.sender = proxy address` (deterministic from the pair). The cross-chain identity is encoded by the pair, not by `msg.sender` alone — two proxies on different managers for the same pair have the same address only if the managers themselves match.

### I.7 Static Context Detection

The `tstore` / `tload` asymmetry is the basis for STATICCALL detection: `tstore` reverts in static context, `tload` does not. The proxy's `_fallback` self-calls `staticCheck()` (which attempts `tstore`); if the self-call reverts, the proxy is in static context and routes to `staticCrossChainCall`. This works because:
- A self-call to `staticCheck` from within a STATICCALL is itself a STATICCALL (the proxy can't escalate privileges).
- The `tstore` inside `staticCheck` is the only thing that can fail; everything else (the call itself, the `_fallback` machinery) is read-only.

A misbehaving destination contract that suppresses the static context would still hit `staticCrossChainCall` via this detector — there is no way to fake a non-static context from inside a STATICCALL.

### I.8 Forward Scan — No Wrong-Entry Consumption

`_consumeAndExecuteEntry` advances the cursor only past an entry that fully matches — identity (`proxyEntryHash`), routing (`destinationRollupId`), and live state preconditions. A builder error or a hook error that triggers an unexpected call either skips forward to a genuine match or reverts `ExecutionNotFound` cleanly at the end of the queue. A `success == false` entry's post-verification revert rolls its cursor advance back, so the table state remains coherent across reverts within a single `postAndVerifyBatch`.

### I.9 Rolling Hash as Integrity Backbone

The single `_rollingHash == entry.rollingHash` check is the primary integrity guarantee. Because the hash is seeded with the entry's starting state context + identity and chains every call's identity (`CALL_BEGIN`), every `(success, retData)` outcome (`CALL_END`), every `NESTED_BEGIN(crossChainCallHash)` / `NESTED_END` boundary, and every reentrant no-match (`CALL_NOT_FOUND`), a single divergence anywhere — wrong call, wrong return data, wrong nesting, missing call, extra call, reordered operations — produces a different final hash and is rejected at the entry boundary.

No path exists where execution diverges from the proof and still completes successfully — every divergence lands in the rolling hash and is rejected at the entry boundary.

### I.10 Proxy Protection (L1)

Every proxy an entry can drive must be backed by a rollup the entry actually proved:

- **Validation-time (batch)**: every entry's `destinationRollupId` and every flat call's `sourceRollupId` (top-level + each reentrant frame's sub-calls) must be ∈ the entry's `rollupUpdates` rollups (`EntryDestinationNotInRollupUpdates` / `CallSourceNotVerified`); every static entry's `destinationRollupId` and sub-call sources must be ∈ its `expectedRoots` pins (`StaticEntryDestinationNotPinned` / `CallSourceNotVerified`).
- **Runtime**: reentrant / static-read TARGETS carry no clear-text rollup field at post time, so `_consumeNestedCall` and `staticCrossChainCall` check the calling proxy's rollup against the executing entry's allowed transient set (`VerifiedRollupsTransient`) (its `rollupUpdates` rollupIds) — `ReentrantDestinationNotVerified` on failure.

Together these ensure a batch cannot use a proxy of a rollup it did not verify, in any position of the execution tree. L2 has no equivalent (single rollup, trusted system-loaded tables).

---

*End of specification. This document covers the flat sequential execution model with the unified reentrant table and static-entry pools.*
