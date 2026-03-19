# Discussion: How to handle failed execution entries

## Background

`ExecutionEntry.failed == true` means "the original cross-chain call reverted." Currently `_consumeAndExecute` processes the entry's calls (to verify the rolling hash), then reverts with `entry.returnData`. This rolls back `executionIndex++`, permanently blocking the execution table (see TODO.md #1a).

Three approaches:

---

## Approach 1: Remove `failed` entirely

Delete `ExecutionEntry.failed`. Entries always succeed. Failed cross-chain calls are represented using `revertSpan` around the calls that fail — the revert is isolated internally while the entry-level execution succeeds.

**Pros:**
- Simplest model. No revert path in `_consumeAndExecute`, no footgun
- `revertSpan` already handles reverts correctly (ContextResult preserves state)

**Cons:**
- The proxy caller always sees success, even if the original L2 call reverted. The destination contract can't distinguish "call succeeded" from "call was replayed but originally failed"
- Loses the ability to faithfully replay a failed top-level call — the outer call always returns normally

---

## Approach 2: Keep `failed`, bypass non-matching failed entries

Relax the strict sequential consumption order. When `_consumeAndExecute` searches for the next entry, if the entry at `executionIndex` has `failed == true` and its `actionHash` doesn't match the current call, skip it and check the next one. Failed entries don't block unrelated calls.

### Mechanism

```
_consumeAndExecute(targetHash):
  idx = executionIndex
  while idx < executions.length:
    entry = executions[idx]
    if entry.failed && entry.actionHash != targetHash:
      idx++          // bypass — this failed entry isn't ours
      continue
    break

  if idx >= executions.length: revert ExecutionNotFound
  if entry.actionHash != targetHash: revert ExecutionNotFound

  executionIndex = idx + 1   // consume up to and including this entry
  ... process entry normally ...

  if entry.failed:
    revert(entry.returnData)  // correct behavior — caller sees a revert
```

### What happens with the revert

When the matching entry has `failed == true`, the function reverts. This rolls back `executionIndex = idx + 1`. But that's **fine** — the failed entry stays at its position and other calls can bypass it:

```
Table: [E0(failed, hashA), E1(ok, hashB), E2(ok, hashC)]

Call with hashB:
  idx=0: E0.failed && hashA != hashB → skip
  idx=1: E1.actionHash == hashB → match
  executionIndex = 2, process E1 normally → succeeds
  executionIndex persists at 2

Call with hashA:
  idx=2: nothing at 2 that matches... but E0 is behind executionIndex now
```

Wait — once `executionIndex` advances past E0 (because E1 was consumed), E0 is behind the cursor. So the scan starts at idx=2, not idx=0. E0 is gone.

This means the scan must look backwards too? No — simpler: **don't advance `executionIndex` past skipped failed entries**. Only advance it when consuming a non-failed entry:

```
_consumeAndExecute(targetHash):
  idx = executionIndex
  while idx < executions.length:
    entry = executions[idx]
    if entry.failed && entry.actionHash != targetHash:
      idx++
      continue
    break

  if entry.actionHash != targetHash: revert ExecutionNotFound

  if entry.failed:
    // don't advance executionIndex — the revert would roll it back anyway
    // just revert with the entry's returnData
    revert(entry.returnData)

  // non-failed entry: advance executionIndex past all skipped + this one
  executionIndex = idx + 1
  ... process normally ...
```

Now the flow:
```
Table: [E0(failed, hashA), E1(ok, hashB), E2(ok, hashC)]

Call with hashB:
  idx=0: E0.failed && hashA != hashB → skip
  idx=1: E1 matches hashB, not failed → consume
  executionIndex = 2 (advances past E0 and E1)

Call with hashC:
  idx=2: E2 matches hashC → consume normally

Call with hashA (if it came first instead):
  idx=0: E0 matches hashA, failed → revert with E0.returnData
  executionIndex stays at 0 (revert rolled it back, but we never changed it)
  Other calls can still bypass E0 on their next attempt
```

The failed entry acts as a "soft barrier" — it blocks its own actionHash (correct revert semantics) but doesn't block other calls. It stays in the array until the table is cleared by the next `postBatch`.

**Pros:**
- No proxy changes needed — the revert propagates naturally
- No self-call complexity — just a scan loop
- Failed entries don't block unrelated calls
- Correct revert semantics: caller of the failed action sees a revert
- Minimal code change: replace `executionIndex++` at the start with a scan loop

**Cons:**
- O(k) scan per call where k = number of consecutive failed entries at the front
- Failed entries are never "consumed" — they linger until `postBatch` clears the table (fine since tables are one-block-lived)
- Breaks strict sequential ordering — entries can be consumed out of order when failed entries are present
- A matching failed entry permanently reverts for that actionHash (can never advance past it). If the same actionHash appears again later in the table, it's unreachable

---

## Approach 3: Handle failed entries through `StaticCall`

Don't use `ExecutionEntry` for failed calls at all. Instead, store failed call results in the `staticCalls[]` array. The proxy already has static call detection — extend it to also handle "calls that should revert."

### Mechanism

A failed cross-chain call is stored as a `StaticCall` with `failed == true`. When the proxy makes the call:

1. The destination calls the proxy (reentrant)
2. The proxy tries `executeCrossChainCall` on the manager
3. The manager doesn't find a matching entry (the failed call was never in `executions[]`)
4. Instead of reverting with `ExecutionNotFound`, the manager checks `staticCalls[]`
5. Finds the matching `StaticCall` with `failed == true`
6. Returns the pre-computed revert data

Or simpler: the off-chain system wraps the failing call in a `revertSpan`, so the call executes inside `executeInContext`. The static call path is used only for read-only calls that also happen to fail.

### Variant: merge static and failed lookups

Extend `staticCallLookup` (or add a `failedCallLookup`) that the proxy calls when `executeCrossChainCall` reverts with `ExecutionNotFound`. If a matching `StaticCall` exists with `failed == true`, the proxy reverts with its `returnData`.

```solidity
// In proxy _fallback:
(success, result) = MANAGER.call{value: msg.value}(
    abi.encodeCall(ICrossChainManager.executeCrossChainCall, (msg.sender, msg.data))
);
if (!success) {
    // executeCrossChainCall failed — check if there's a pre-computed revert
    (bool found, result) = MANAGER.staticcall(
        abi.encodeCall(ICrossChainManager.staticCallLookup, (msg.sender, msg.data))
    );
    // staticCallLookup reverts with the pre-computed data if failed==true
    // or returns the data if it's a read-only result
}
```

**Pros:**
- No changes to `ExecutionEntry` or `_consumeAndExecute` — they stay simple
- Reuses existing `StaticCall` infrastructure and proxy detection
- Failed calls don't occupy slots in the execution table, so no blocking possible
- Clean separation: `executions[]` = successful calls, `staticCalls[]` = lookups + failures

**Cons:**
- `StaticCall` was designed for read-only calls. Overloading it with "calls that revert" may be confusing
- The proxy needs a fallback path: try `executeCrossChainCall`, if it fails check `staticCallLookup`
- The `staticCallLookup` matching must work for failed calls too (needs correct `callNumber` + `lastNestedActionConsumed` at the time of the call)
- Doesn't help with entry-level failures (top-level call that reverts), only nested/reentrant failures

---

## Recommendation

**Approach 3** is the cleanest for nested/reentrant failures — it reuses existing infrastructure and keeps the execution table unblocked. It aligns with the existing constraint "nested actions must succeed; failed calls use StaticCall."

**Approach 2** is needed if we want to support entry-level failures (the top-level `executeCrossChainCall` or `executeL2TX` returning a revert). This requires the proxy-level revert signaling but gives the most faithful replay.

**Approach 1** is the fallback if the complexity isn't worth it — just remove `failed` and accept that all replayed calls succeed from the caller's perspective.

These approaches aren't mutually exclusive. A combined path could be:
- Approach 3 for nested/reentrant failures (StaticCall)
- Approach 2 for entry-level failures (skip-and-consume + proxy revert signaling)
- Or just Approach 1 if neither is needed yet
