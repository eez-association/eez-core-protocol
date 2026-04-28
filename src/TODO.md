# Smart Contract TODOs

## 1a. Failed entry (`entry.failed == true`) blocks the execution table

### Problem

When `_consumeAndExecute` processes an entry with `failed == true`, it executes all calls (to verify the rolling hash), then reverts with `entry.returnData` via assembly. But the `executionIndex++` that happened at the start of `_consumeAndExecute` is **rolled back** by the revert — because the revert propagates through `executeCrossChainCall`, which was called via `.call` from the proxy. The entire call context is undone.

Result: the failed entry is never consumed, `executionIndex` stays the same, and **every subsequent call hits the same failed entry forever**. The execution table is stuck.

### Scenario

```
User calls proxy → proxy calls executeCrossChainCall via .call
  → _consumeAndExecute:
    → executionIndex++ (0 → 1)
    → processes calls, verifies rolling hash — all good
    → entry.failed == true
    → assembly { revert(returnData) }
  → revert propagates: executionIndex rolled back to 0
proxy catches revert, returns failure to user

Next call: executionIndex is still 0, same failed entry, same revert → stuck forever
```

### Possible solutions

See `src/DISCUSS.md` for 3 approaches.

---

## 1b. Failed nested action (reentrant call reverts) — RESOLVED

### Resolution

`_consumeNestedAction` now falls back to a `StaticCall` lookup when no `NestedAction` matches at the current cursor. The fallback only matches `failed=true` static calls keyed by `(actionHash, _currentCallNumber, _lastNestedActionConsumed)`, replays any sub-calls via STATICCALL for integrity, and reverts with the cached `returnData`. The destination's `try/catch` absorbs the revert, the outer `_processNCalls` continues, and `_lastNestedActionConsumed` is never bumped on this path — so the EVM revert has nothing to roll back.

Routing summary:

| Frame type | Routes to | Handles |
|---|---|---|
| Real STATICCALL (proxy `tstore` reverts) | `staticCallLookup` (external view) | Both `failed=true` and `failed=false` static entries |
| Normal CALL, reentrant (`_insideExecution() == true`) | `_consumeNestedAction` | NestedAction first; on miss, only `failed=true` static entries (revert replay) |

Implementation: `src/Rollups.sol` `_consumeNestedAction` (L1, scans `_transientStaticCalls` then `staticCalls`); `src/CrossChainManagerL2.sol` `_consumeNestedAction` (L2, persistent `staticCalls` only). Both share a `_resolveStaticCall` helper.

---

## 3. `staticCalls` lookup is O(n) linear scan

`staticCallLookup` iterates over the entire `staticCalls[]` array to find a match. For entries with many static calls this could be gas-expensive. Consider:
- A mapping from `keccak256(actionHash, callNumber, lastNestedActionConsumed)` to index
- Keeping the array sorted and using binary search
- Requiring static calls to be ordered so sequential lookup works

---

## 5. No mechanism to clear a stuck execution table

If entries are posted via `postBatch` but cannot be consumed in the same block (e.g., a bug in off-chain construction), the execution table is stuck until the next `postBatch` overwrites it. Non-issue in practice: tables are one-block-lived and `postBatch` deletes previous data on each call.
