# Lookup Specification (nested `ExpectedLookup` + top-level `LookupCall`)

A lookup is the sub-execution structure for a cross-chain call that is **looked up** rather than
executed as a normal `ExecutionEntry` — either because it is **read-only** (a STATICCALL) or
because it **reverts** (the caller made the call inside a `try/catch` and expects the revert).

Since the entry-scoping redesign there are **two lookup structs in two homes**:

| Struct | Lives in | Serves | Match key |
|---|---|---|---|
| `ExpectedLookup` (**nested**) | `ExecutionEntry.expectedLookups[]` (and a top-level lookup's own `expectedLookups[]` during its sub-execution) | reentrant static reads + try/catch'd reverting reentrant calls, fired `_insideExecution()` | `(crossChainCallHash, l2ToL1CallNumber, lastL1ToL2CallConsumed, executingLookupIndex)` |
| `LookupCall` (**top-level**) | the storage pool: `_transientLookupCalls` / per-rollup `lookupQueue` (L1), `lookupCalls` (L2) | top-level static reads + top-level reverting calls, consumable ONLY when `!_insideExecution()` | `crossChainCallHash` + every `expectedStateRoots` pin live (L1; L2: hash alone) |

This split is what makes lookups **entry-scoped by construction**: a nested lookup can only
resolve from the entry (or executed top-level lookup) that carries it — no queue routing, no
cross-entry collisions, no cross-rollup routing concerns. Field names below are L1's
(`src/interfaces/IEEZ.sol`); L2 (`src/interfaces/IEEZL2.sol`) mirrors with self-relative names
(`callNumber`, `lastOutgoingCallConsumed`, `incomingCalls`, `expectedOutgoingCalls`) and drops
the L1-only fields (`destinationRollupId`, `expectedStateRoots`).

This document complements `EXECUTION_ENTRY_SPEC.md` (how `ExecutionEntry`s are built) and
`CORE_PROTOCOL_SPEC.md` §E/§F (rolling hash, lookup resolution).

---

## 1. The two modes (shared by both structs)

A lookup is interpreted in one of two modes, selected by `failed`:

### (A) Static — `failed == false`
- Nested: resolved by `staticCallLookup`'s in-execution branch;
  top-level: by its pool branch. Both resolve through the shared
  `_resolveStaticLookup`.
- Read-only. The sub-call array (if any) is executed in **STATICCALL** context via
  `_processNStaticCalls` and hashed with the **untagged** schema
  (`keccak256(prev, success, retData)` per sub-call), checked against `rollingHash`.
- **No nested table, no partition** — `expectedL1ToL2Calls` is empty and **`callCount == 0`**.
- Multiple reentrant reads "at the same moment" are encoded as **separate** nested lookups
  sharing the same `(l2ToL1CallNumber, lastL1ToL2CallConsumed, executingLookupIndex)`.

### (B) Failed — `failed == true`
Resolved during execution, **always via a sub-execution** (`_executeRevertedNestedLookup` for nested,
`_executeRevertedTopLevelLookup` for top-level — both end in `_executeRevertedLookup`). Two shapes by
`callCount`:

| `l2ToL1Calls.length` | `callCount` | resolution | hash schema |
|---|---|---|---|
| `0` | `0` | plain cached revert: the sub-execution runs a no-op sub-execution, then reverts | (none; `rollingHash` must be `0`) |
| `> 0` | `> 0` | **real state-mutating sub-execution** executed as a mini-entry, then reverts | **tagged** |

There is **no `callCount`-based routing**: a plain reverted lookup is just the `callCount == 0`
case of the same execution path. `l2ToL1Calls.length > 0` with `callCount == 0` is **invalid** —
the end check `_currentL2ToL1Call == l2ToL1Calls.length` (`UnconsumedL2ToL1Calls`) would fail.
A reverted lookup never resolves via the static resolvers' return path; `staticCallLookup` still
handles a *static read that happens to revert* (it reverts with `returnData`).

In both shapes the call ultimately **reverts with `returnData`**, which the caller's
`try/catch` observes.

---

## 2. Field reference

```solidity
// L1 — src/interfaces/IEEZ.sol

/// NESTED lookup — lives inside the entry (or a top-level lookup's sub-execution table).
struct ExpectedLookup {
    bytes32 crossChainCallHash;        // identity of the looked-up call
    bytes   returnData;                // returned on success / reverted-with on failure
    bool    failed;                    // mode selector (see §1)
    uint64  l2ToL1CallNumber;          // _currentL2ToL1Call at observation
    uint64  lastL1ToL2CallConsumed;    // _lastL1ToL2CallConsumed at observation
    uint64  executingLookupIndex;      // execution context at observation — see §5
    L2ToL1Call[]         l2ToL1Calls;        // sub-calls executed at resolution
    ExpectedL1ToL2Call[] expectedL1ToL2Calls; // reverted-mode reentrant table
    uint256              callCount;    // reverted-mode top-level iteration count — see §3
    bytes32 rollingHash;               // expected hash of the executed sub-calls
}

/// TOP-LEVEL lookup — lives in the storage pool; consumable only outside an execution.
struct ExpectedStateRootPerRollup { uint256 rollupId; bytes32 stateRoot; }

struct LookupCall {
    bytes32 crossChainCallHash;
    uint256 destinationRollupId;       // which lookupQueue this is published under (L1)
    bytes   returnData;
    bool    failed;
    L2ToL1Call[]         l2ToL1Calls;
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;
    ExpectedLookup[]     expectedLookups;   // nested lookups consumed while a reverted lookup executes
    uint256              callCount;
    bytes32 rollingHash;
    ExpectedStateRootPerRollup[] expectedStateRoots; // part of the MATCH — see §6
}
```

Notes:

- **No cursor coordinates on the top-level struct.** The old `(0, 0)` key encoded "top-level"
  implicitly; the explicit `!_insideExecution()` gate replaces it.
- **`expectedLookups` on `LookupCall`** exists so a top-level reverted lookup can host nested
  lookups of its own. `ExpectedLookup` cannot nest itself (Solidity forbids recursive structs):
  deeper lookups inside ANY lookup sub-execution resolve from the **same host table** — the entry's
  `expectedLookups`, or the executed top-level lookup's. `executingLookupIndex` (§5) makes
  those flat-table keys context-unambiguous.
- **`destinationRollupId`** (top-level, L1) routes publishing into
  `verificationByRollup[rid].lookupQueue`. It is coherent by construction: the consumption
  scan targets the proxy's `originalRollupId`, which is the target rollup bound into
  `crossChainCallHash`.

---

## 3. The `callCount` partition (read this carefully)

`callCount` exists **only for a reverted-mode real sub-execution** and means exactly what
`ExecutionEntry.callCount` means: the number of **top-level** iterations the sub-execution's
`_processNCalls` runs over `l2ToL1Calls[]`, with the partition invariant checked on-chain at
the end of the sub-execution:

```
callCount + Σ expectedL1ToL2Calls[i].callCount == l2ToL1Calls.length
```

A single global cursor (`_currentL2ToL1Call`; L2: `_currentIncomingCall`) advances
monotonically over the sub-execution's `l2ToL1Calls[]` — one cursor across the whole sub-tree,
exactly like an entry.

### Worked example
`l2ToL1Calls.length = 4`:
- call 0: top-level, no reentry.
- call 1: top-level, triggers a reentrant call → matched against `expectedL1ToL2Calls[0]`,
  whose `callCount = 2` consumes calls 2 and 3 inside the nested frame.

⇒ `callCount = 2`, `expectedL1ToL2Calls[0].callCount = 2`, and `2 + 2 == 4`.

### Why `callCount == 0` for static (and plain failed) lookups
Static lookups run their `l2ToL1Calls[]` *flatly* via `_processNStaticCalls` — a simple
STATICCALL loop with an untagged hash. No frame split, no cursor, no nested table — nothing to
partition. `callCount` is unused and **must be 0** (a prover convention — the static resolvers
never read it). The mode split is by **context**, not by `callCount`: a `failed` lookup
matched during execution always runs; `staticCallLookup` always resolves statically.

> Pitfall: `callCount = 0` with a non-empty `expectedL1ToL2Calls` is malformed — a nested
> frame can only be entered from a top-level call, so a real sub-execution always has
> `callCount >= 1`. Conversely, a `failed == false` lookup is never matched by the
> execution-context fallbacks (they require `failed == true`).

---

## 4. Resolution mechanics

### Static context (`staticCallLookup`, `view`)
Branches on `_insideExecution()`:

- **Inside an execution** → scan the active host's `expectedLookups`
  (`_getActiveLookups()` — the entry's table, or the executed top-level lookup's) for the 4-tuple
  key.
- **Outside** → scan `_transientLookupCalls` then the routed rollup's `lookupQueue`
  (L2: the single `lookupCalls` pool) for `crossChainCallHash` with **all state-root pins
  live** (§6).

Both branches resolve through `_resolveStaticLookup`: run the sub-calls statically, require the
untagged hash to equal `rollingHash` (an empty array must carry `rollingHash == 0`), then
return `returnData` — or revert with it when `failed`.

### Execution context (reverted lookups) — `_executeRevertedNestedLookup` / `_executeRevertedTopLevelLookup`
Both run inline in the consuming `executeCrossChainCall` frame and share `_executeRevertedLookup`:

```
set the sub-execution pointers:
  nested:    _revertedLookupIndex = index; _insideRevertedLookup = true
  top-level: _topLevelLookupIndex = index; _revertedLookupTopLevel = true
             (+ _revertedLookupRollupId = destinationRollupId on L1, to re-derive the pool)
reset sub-cursors (_rollingHash, _currentL2ToL1Call, _lastL1ToL2CallConsumed = 0)
_processNCalls(callCount)                  // 0 ⇒ no-op; reentry → _consumeNestedAction
require _rollingHash == rollingHash
require _currentL2ToL1Call == l2ToL1Calls.length          // partition invariant
require _lastL1ToL2CallConsumed == expectedL1ToL2Calls.length
revert(returnData)
```

The terminal `revert` discards the sub-call **state changes** *and* restores the outer cursors
(the EVM rolls back every tstore write in this frame); the pre-revert checks need no
`ContextResult` escape. Deeper reverted-lookup executions compose for free via that same revert unwind.

A top-level reverted lookup is reachable from `_tryRevertedTopLevelLookup` (the
`_consumeAndExecute` miss path); a nested one from the fallback inside `_consumeNestedAction`.

---

## 5. Context binding: `executingLookupIndex` (enforced, not convention)

Every nested lookup records the execution context it fires in:

- `0` — fired at entry/host level (no nested reverted-lookup execution active);
- `k` — fired inside the sub-execution of `expectedLookups[k-1]` of the same host.

At match time the scan compares it against the live context
(`_insideRevertedLookup ? _revertedLookupIndex + 1 : 0`). Together with the two cursor
coordinates this makes the flat host table unambiguous across the entry and all of its
execution contexts — the old "prover must keep keys collision-free across contexts" note is now
an **on-chain check**. (Only identical keys at the SAME depth chain — e.g. the same lookup sub-execution
entered from two different colliding paths — remain a prover-care item, and those already
require fully colliding keys elsewhere.)

---

## 6. State-root pins (top-level, L1 only)

`expectedStateRoots[]` content-addresses a top-level lookup to a point on each pinned
rollup's trajectory: a candidate only **matches** when every pin equals the live
`rollups[rollupId].stateRoot` (full-scan semantics — a mismatching candidate is skipped, the
scan continues; no dedicated error). Replaces the old `expectedQueueIndices` cursor pins,
with three concrete wins:

- **Split-independent** — roots don't depend on the transient/persistent split
  (`immediateEntryCount` stays an unproven dispatch parameter, as documented).
- **Transient-phase capable** — roots advance entry-by-entry during the batch; the old
  cursor pins were blind there (all per-rollup cursors are 0).
- **Re-verify robust** — a same-block re-verify resets cursors but the root trajectory
  continues coherently.

Use them to pin a cached read to the cross-rollup interleaving it was proven against. The
prover decides which rollups to pin; an empty array matches unconditionally.

---

## 7. L1 / L2 differences

- L2's structs drop `destinationRollupId` and `expectedStateRoots` entirely (single rollup,
  no state roots) and use self-relative names. The L2 top-level pool (`lookupCalls`) is
  matched by `crossChainCallHash` alone.
- L1 scans the **transient** pool (`_transientLookupCalls`, the meta-hook window) before the
  persistent per-rollup `lookupQueue`; L2 scans only `lookupCalls`.
- Sub-execution pointers: both sides use `_revertedLookupIndex` / `_insideRevertedLookup` (nested) and
  `_topLevelLookupIndex` / `_revertedLookupTopLevel` (top-level host); L1 additionally keeps
  `_revertedLookupRollupId` to re-derive the persistent pool, with the transient-vs-persistent
  source re-derived from `_transientExecutions.length`.

---

## 8. Invariants (summary)

- `failed == false` ⇒ `callCount == 0`, `expectedL1ToL2Calls.length == 0` (and for top-level:
  `expectedLookups.length == 0`).
- `callCount > 0` ⇒ `failed == true`, real sub-execution, tagged hash, and
  `callCount + Σ expectedL1ToL2Calls[i].callCount == l2ToL1Calls.length`.
- A reverted lookup with `l2ToL1Calls.length > 0` requires `callCount > 0`.
- `expectedL1ToL2Calls.length > 0` ⇒ `callCount >= 1` (nesting requires a top-level caller).
- Static sub-calls use the untagged hash; failed sub-executions use the tagged hash.
- Nested lookups resolve ONLY from the active host's `expectedLookups`; top-level lookups
  ONLY from the pool and ONLY when `!_insideExecution()`.
- A reverted lookup always reverts with `returnData`; a static lookup returns it (or reverts
  with it if that static read is itself `failed`).
- PROVER OBLIGATION: cross-rollup consistency of a *sub-call-less* nested static read is
  attested at the proof layer — the entry's deltas pin only the rollups they touch (top-level
  lookups can use state-root pins instead).
