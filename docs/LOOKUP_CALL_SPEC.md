# LookupCall Specification

`LookupCall` is the replay structure for a cross-chain call that is **looked up** rather than
executed as a normal `ExecutionEntry` — either because it is **read-only** (a STATICCALL) or
because it **reverts** (the caller made a reentrant call inside a `try/catch` and expects the
revert). This document specifies the data model and the two resolution modes, with particular
attention to the `callCount` partition — the field that is easy to get wrong.

It complements `EXECUTION_TABLE_SPEC.md` (how `ExecutionEntry`s are built) and
`SYNC_ROLLUPS_PROTOCOL_SPEC.md` §E/§F (rolling hash, lookup resolution).

Field names in the body are L1's (`src/interfaces/IEEZ.sol`); L2 (`src/interfaces/IEEZL2.sol`)
defines a leaner mirror struct with self-relative names — see §3 and §8.

---

## 1. Why LookupCall has the shape it has

The protocol has **two parallel replay structures**. Only one originally supported reentrant
L1→L2 ("nested") calls:

| Structure | flat calls | nested table | execution |
|---|---|---|---|
| `ExecutionEntry` | `l2ToL1Calls[]` | `expectedL1ToL2Calls[]` | real CALL, state applied |
| `LookupCall` (old) | `calls[]` | — | STATICCALL, read-only |

`LookupCall.calls[]` existed only for **read-only static reentry** (`staticCallLookup`), where
sub-calls can't change state — so a nested table was never needed.

Then `LookupCall` also became the backing for the **revert** path: a reverting reentrant call
consumed via the failed-reentry fallback in `_consumeNestedAction`. A call that *actually
executed and then reverted* may have triggered its own reentrant L1→L2 calls before reverting —
which the old `calls[]` could not represent. So `LookupCall` gained an `expectedL1ToL2Calls[]`
table and a `callCount`, making a **failed** lookup able to replay as a self-contained
mini-entry. That is the whole point of the new fields.

---

## 2. The two modes

A `LookupCall` is interpreted in one of two modes, selected by `failed`:

### (A) Static — `failed == false`
- Resolved by `staticCallLookup` (a `view` entry point) → `_resolveLookupCall`.
- Read-only. `l2ToL1Calls[]` (if any) are replayed in **STATICCALL** context via `_processNLookupCalls`
  and hashed with the **untagged** schema (`keccak256(prev, success, retData)` per sub-call),
  checked against `rollingHash`.
- **No nested table, no partition** — `expectedL1ToL2Calls` is empty and **`callCount == 0`**.
- Multiple reentrant reads "at the same moment" are encoded as **separate** `LookupCall`s that
  share the same `(l2ToL1CallNumber, lastL1ToL2CallConsumed)`.
- `expectedQueueIndices[]` pins each rollup's queue cursor at observation time (L1 only — the
  L2 struct has no such field).

### (B) Failed — `failed == true`
Resolved during execution — the reentrant fallback in `_consumeNestedAction` or the top-level
fallback `_tryRevertedTopLevelLookup` — **always** via `_replayFailedLookup`. Two shapes by
`callCount`:

| `l2ToL1Calls.length` | `callCount` | resolution | hash schema |
|---|---|---|---|
| `0` | `0` | plain cached revert: `_replayFailedLookup` runs a no-op sub-execution, then reverts | (none; `rollingHash` must be `0`) |
| `> 0` | `> 0` | **real state-mutating sub-execution** replayed as a mini-entry, then reverts | **tagged** |

There is **no `callCount`-based routing**: a plain failed lookup is just the `callCount == 0`
case of the same `_replayFailedLookup` path (a touch more gas, much clearer code). `l2ToL1Calls.length > 0`
with `callCount == 0` is **invalid** — the end check `_currentL2ToL1Call == l2ToL1Calls.length`
(`UnconsumedL2ToL1Calls`) would fail. A failed lookup never resolves via `_resolveLookupCall`; that's the static-context path
(`staticCallLookup` only), which still handles a *static read that happens to revert*.

In both shapes the call ultimately **reverts with `returnData`**, which the caller's `try/catch`
observes.

---

## 3. Field reference

```solidity
// L1 — src/interfaces/IEEZ.sol
struct ExpectedQueueIndexPerRollup { uint256 rollupId; uint256 executionQueueIndex; }

struct LookupCall {
    bytes32 crossChainCallHash;        // identity of the looked-up call
    uint256 destinationRollupId;       // routes to verificationByRollup[rid].lookupQueue
    bytes   returnData;                // returned on success / reverted-with on failure
    bool    failed;                    // mode selector (see §2)
    uint64  l2ToL1CallNumber;          // _currentL2ToL1Call at observation (content-addressing)
    uint64  lastL1ToL2CallConsumed;    // _lastL1ToL2CallConsumed at observation
    L2ToL1Call[]         l2ToL1Calls;        // sub-calls replayed during resolution
    ExpectedL1ToL2Call[] expectedL1ToL2Calls; // failed-mode nested table (reused from entries)
    uint256              callCount;    // failed-mode top-level iteration count — see §4
    bytes32 rollingHash;               // expected hash of the replayed sub-calls
    ExpectedQueueIndexPerRollup[] expectedQueueIndices; // per-rollup execution-queue-index pins
}

// L2 — src/interfaces/IEEZL2.sol (no destinationRollupId, no expectedQueueIndices)
struct LookupCall {
    bytes32 crossChainCallHash;
    bytes   returnData;
    bool    failed;
    uint64  callNumber;                // _currentIncomingCall at observation
    uint64  lastOutgoingCallConsumed;  // _lastOutgoingCallConsumed at observation
    CrossChainCall[]                 incomingCalls;         // sub-calls replayed during resolution
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls; // failed-mode nested table
    uint256                          callCount;
    bytes32 rollingHash;
}
```

- **`l2ToL1Calls`** (L2: `incomingCalls`) — the flat list of sub-calls. Static mode: STATICCALL,
  read-only, `revertSpan` not allowed. Failed real-execution mode: **real** calls (may host
  nested reentry and `revertSpan`), partitioned against `expectedL1ToL2Calls` exactly like
  `ExecutionEntry.l2ToL1Calls`.
- **`expectedL1ToL2Calls`** (L2: `expectedOutgoingCalls`) — the failed-mode nested table:
  pre-computed results for reentrant L1→L2 (L2: outgoing) calls fired *during* the
  sub-execution, consumed sequentially by `_consumeNestedAction` while `_insideFailedLookup`
  is set. Empty in static mode. Reuses the entry struct (`ExpectedL1ToL2Call` /
  `ExpectedOutgoingCrossChainCall`) so the same `_processNCalls` / `_consumeNestedAction`
  machinery drives it.
- **`callCount`** — the partition parameter; see §4. **Zero for static mode** and for plain
  failed reverts.
- **`rollingHash`** — checked against the replayed sub-calls. Untagged schema in static mode,
  tagged `CALL_*/NESTED_*` schema in failed real-execution mode (because nesting boundaries
  must be captured).
- **`l2ToL1CallNumber` / `lastL1ToL2CallConsumed`** (L2: `callNumber` / `lastOutgoingCallConsumed`)
  — content-addressing coordinates: the cursor values the prover observed when the looked-up
  call fired. For a static read observed *inside* a failed lookup's sub-execution, these are the
  failed lookup's **fresh sub-cursor** values. NOTE: the lookup key does **not** encode which
  context is active — the prover must keep keys collision-free across the entry and any
  failed-lookup sub-executions (see §7).
- **`destinationRollupId` / `expectedQueueIndices`** — L1-only; see §7 and §8.

---

## 4. The `callCount` partition (read this carefully)

`callCount` exists **only for a failed-mode real sub-execution** and means exactly what
`ExecutionEntry.callCount` means: it is the number of **top-level** iterations the
sub-execution's `_processNCalls` runs over `l2ToL1Calls[]`.

A real sub-execution's `l2ToL1Calls[]` is the **full flat list** of every call it makes, in execution
order, partitioned between the top-level frame and any reentrant (nested) frames:

```
callCount                         = iterations the TOP-LEVEL frame runs
expectedL1ToL2Calls[i].callCount  = iterations the i-th nested frame runs
```

with the **partition invariant**, checked on-chain at the end of the replay:

```
callCount + Σ expectedL1ToL2Calls[i].callCount == l2ToL1Calls.length
```

A single global cursor (`_currentL2ToL1Call`; L2: `_currentIncomingCall`) advances
**monotonically** over `l2ToL1Calls[]` — there
is only one cursor across the whole sub-tree. When a top-level call triggers a reentrant L1→L2
proxy call, control re-enters via `executeCrossChainCall` → `_consumeNestedAction`, which runs
`_processNCalls(expectedL1ToL2Calls[i].callCount)` over the **same** `l2ToL1Calls[]`, advancing the
same cursor; the top-level frame resumes where the cursor left off.

### Worked example
`l2ToL1Calls.length = 4`:
- call 0: top-level, no reentry.
- call 1: top-level, triggers a reentrant L1→L2 call → matched against `expectedL1ToL2Calls[0]`,
  whose `callCount = 2` consumes calls 2 and 3 inside the nested frame.

⇒ `callCount = 2` (calls 0 and 1 at the top-level frame), `expectedL1ToL2Calls[0].callCount = 2`
(calls 2, 3 nested), and `2 + 2 == 4 == l2ToL1Calls.length`. `_currentL2ToL1Call == 4` at the end.

### Why `callCount == 0` for static (and plain) lookups
Static lookups (and plain failed reverts) **do not run a partitioned execution**. Their `l2ToL1Calls[]`
are replayed *flatly* by `_processNLookupCalls` — a simple loop that STATICCALLs every element
and folds an untagged hash. There is no top-level/nested frame split, no `_currentL2ToL1Call`
cursor, and no nested table — so there is nothing to partition. `callCount` is therefore unused
and **must be 0** (a prover convention — `_resolveLookupCall` never reads it). On-chain, the
path split is by **context**, not by `callCount`: a `failed` lookup matched during execution
always resolves via `_replayFailedLookup` (with `callCount == 0` the sub-execution is a no-op),
and `staticCallLookup` always resolves via `_resolveLookupCall`.

> Pitfall: setting `callCount = 0` while providing a non-empty `expectedL1ToL2Calls` is
> malformed — a nested frame can only be entered from a top-level call, so a real sub-execution
> always has `callCount >= 1`. Conversely, `callCount > 0` on a static lookup is dead weight:
> `_resolveLookupCall` ignores it, and a `failed == false` lookup is never matched by the
> execution-context fallbacks (they require `failed == true`).

---

## 5. Resolution mechanics

### Static context (`staticCallLookup`, `view`) — `_resolveLookupCall`
Handles a static read, whether it returns or reverts:
1. `_checkExpectedRollupExecutionQueueIndex(sc)` — verify `expectedQueueIndices[]` against the
   live per-rollup `executionQueueIndex` (L1 only; L2 has neither the field nor the function).
2. **Always** `_processNLookupCalls(sc.l2ToL1Calls)` (STATICCALL each, untagged hash) and require it
   equals `rollingHash`. Empty `l2ToL1Calls[]` hashes to 0, which must equal a sub-call-less lookup's
   `rollingHash` (0).
3. If `failed` → `revert(returnData)`, else return `returnData`.

### Execution context (failed lookups) — `_replayFailedLookup`
Every failed lookup consumed during execution (reentrant or top-level), **whatever its
`callCount`**, runs inline in the consuming `executeCrossChainCall` frame:
```
_checkExpectedRollupExecutionQueueIndex(sc)        // same pin as the static path (L1 only)
set _insideFailedLookup + pointer (_failedLookupIndex; L1 also _failedLookupRollupId = sc.destinationRollupId)
reset sub-cursors (_rollingHash, _currentL2ToL1Call, _lastL1ToL2CallConsumed = 0)
_processNCalls(sc.callCount)                         // 0 ⇒ no-op; nested reentry → _consumeNestedAction over sc.expectedL1ToL2Calls
require _rollingHash == sc.rollingHash
require _currentL2ToL1Call == sc.l2ToL1Calls.length  // partition invariant
require _lastL1ToL2CallConsumed == sc.expectedL1ToL2Calls.length
revert(sc.returnData)
```
The terminal `revert` discards the sub-call **state changes** *and* restores the outer cursors
(the EVM rolls back every tstore write in this frame); the pre-revert hash/count checks need no
`ContextResult` escape. Nested failed lookups compose for free via that same revert unwind.

---

## 6. Rolling-hash schemas

- **Static / flat replay** (`_processNLookupCalls`): untagged
  `keccak256(prev, success, retData)` per sub-call. Safe because the surrounding `LookupCall` is
  already content-addressed by `(crossChainCallHash, l2ToL1CallNumber, lastL1ToL2CallConsumed)`,
  which pins the call/nesting context the entry-level tags would otherwise disambiguate.
- **Failed real sub-execution** (`_replayFailedLookup` via `_processNCalls`): the **tagged**
  entry schema (`CALL_BEGIN`/`CALL_END`/`NESTED_BEGIN`/`NESTED_END`), because the nesting
  boundaries inside the sub-execution must be captured — identical to how an `ExecutionEntry`'s
  rolling hash is built.

---

## 7. Scope, content addressing, and cursors

- **`_insideFailedLookup`** (transient) re-points `_activeCalls()` / `_activeNested()` inside a
  failed sub-execution: reentrant state-changing calls consume the **lookup's** `expectedL1ToL2Calls`
  (not the entry's), and a mid-replay STATIC read is keyed by the failed lookup's **fresh
  sub-cursor** `(l2ToL1CallNumber, lastL1ToL2CallConsumed)`. The lookup key itself does **not**
  encode whether a failed-lookup sub-execution is active — `staticCallLookup` matches only on
  `(crossChainCallHash, l2ToL1CallNumber, lastL1ToL2CallConsumed)`, so the prover must keep keys
  collision-free across the entry and any failed-lookup sub-executions.
- **`expectedQueueIndices`** (L1 only) pins a lookup to a specific point in the **per-rollup
  execution-queue interleaving**: at resolve time the contract requires
  `verificationByRollup[rollupId].executionQueueIndex == executionQueueIndex` for each entry, else
  `ExecutionQueueIndexMismatch`. Checked by `_checkExpectedRollupExecutionQueueIndex` on **both**
  resolution paths — static (`_resolveLookupCall`) and failed (`_replayFailedLookup`). It's the
  content-addressing key that keeps a cached result valid only against the consumption
  interleaving it was proven for. (Replaces the earlier state-root idea.)

---

## 8. L1 / L2 differences

The two sides intentionally diverge:
- They define **different `LookupCall` structs** (see §3). `destinationRollupId` and
  `expectedQueueIndices` are **L1-only** — the L2 struct drops them entirely (no parity
  placeholders): L2 has a single rollup and a single sequential table, so there is nothing to
  route or pin. `_checkExpectedRollupExecutionQueueIndex` exists only in `EEZ.sol`; L2's
  `_resolveLookupCall` / `_replayFailedLookup` have no pin step.
- Field naming differs: L1 is absolute-directional (`l2ToL1CallNumber`, `lastL1ToL2CallConsumed`,
  `l2ToL1Calls`, `expectedL1ToL2Calls` of type `ExpectedL1ToL2Call`); L2 is self-relative
  (`callNumber`, `lastOutgoingCallConsumed`, `incomingCalls`, `expectedOutgoingCalls` of type
  `ExpectedOutgoingCrossChainCall`), because an L2's counterparty can be L1 **or** another L2.
- L1 scans a **transient** lookup table (`_transientLookupCalls`, the meta-hook window) then the
  persistent per-rollup `lookupQueue`; L2 scans only the persistent `lookupCalls` loaded via
  `loadExecutionTable`.
- The failed-lookup pointer: L1 stores `(_failedLookupIndex, _failedLookupRollupId)` and
  re-derives the source table from `_transientExecutions.length`; L2 needs only
  `_failedLookupIndex` (single table).

---

## 9. Invariants (summary)

- `failed == false` ⇒ `callCount == 0`, `expectedL1ToL2Calls.length == 0`.
- `callCount > 0` ⇒ `failed == true`, real sub-execution, tagged hash, and
  `callCount + Σ expectedL1ToL2Calls[i].callCount == l2ToL1Calls.length`.
- A failed lookup with `l2ToL1Calls.length > 0` requires `callCount > 0` — no read-only static
  sub-calls in a failed lookup (the `_currentL2ToL1Call == l2ToL1Calls.length` check —
  `UnconsumedL2ToL1Calls` — would fail).
- `expectedL1ToL2Calls.length > 0` ⇒ `callCount >= 1` (nesting requires a top-level caller).
- Static `l2ToL1Calls[]` use the untagged hash; failed real-execution `l2ToL1Calls[]` use the tagged hash.
- Failed lookups always resolve via `_replayFailedLookup` (reentrant *and* top-level); static
  reads via `_resolveLookupCall`.
- `destinationRollupId` (L1 only) MUST equal the queue the lookup is published under —
  load-bearing for `_replayFailedLookup` / `_currentFailedLookup` to recover the queue
  mid-replay.
- A failed lookup always reverts with `returnData`; a static lookup returns it (or reverts with
  it if that static read is itself `failed`).
