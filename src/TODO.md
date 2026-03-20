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

**A. Self-call isolation: execute inside `executeInContext`, advance index outside**

Split `_consumeAndExecute` for failed entries: advance `executionIndex` and set `_currentEntryIndex` in the outer context, then process the entry's calls in a self-call that reverts. The outer context survives and the index is advanced. Then the outer function reverts with the entry's returnData.

Problem: the outer `executeCrossChainCall` still reverts (to propagate the failure to the proxy caller), which rolls back `executionIndex++` anyway. The revert boundary is the proxy's `.call`, which wraps the entire `executeCrossChainCall`.

**B. Don't revert for failed entries — return normally with failure encoding**

Change `_consumeAndExecute` to return `(bytes memory returnData, bool failed)` instead of reverting. `executeCrossChainCall` returns normally. The proxy decodes the result and decides whether to revert:

```solidity
// In _consumeAndExecute:
return (entry.returnData, entry.failed);  // no revert

// In executeCrossChainCall:
(bytes memory result, bool failed) = _consumeAndExecute(actionHash, int256(msg.value));
if (failed) {
    // encode failure into return so proxy can distinguish
    return abi.encode(result, true);  // or use a custom encoding
}
return result;
```

The proxy would need to understand this encoding and revert on the caller's behalf. This preserves `executionIndex` advancement (no revert in the manager) while still giving the proxy's caller a revert.

Downside: requires proxy changes and a new encoding convention.

**C. Two-step: separate `consumeEntry()` from execution**

Add a permissionless `consumeEntry()` that just advances `executionIndex` without executing. For failed entries, the flow would be:
1. Someone calls `consumeEntry()` — advances index, emits event
2. The proxy call to `executeCrossChainCall` sees the entry was already consumed

Problem: breaks the atomic consumption model. Race conditions. Complexity.

**D. Use an intermediate storage flag to mark entries as consumed**

Before processing, write `entry.consumed = true` (or a separate mapping). On revert, the storage write inside the `.call` is rolled back. This has the same problem as `executionIndex++`.

Unless the proxy is changed to make TWO calls: first a call to mark consumption (succeeds, state persists), then a call to execute (may revert). But this requires proxy changes.

**E. Move the revert boundary: proxy-level revert instead of manager-level**

The manager never reverts for failed entries. Instead, it returns `(returnData, failed)` as ABI-encoded bytes. The proxy detects `failed == true` and performs the revert. Since the manager's `.call` succeeded, `executionIndex++` persists.

```solidity
// Manager returns normally:
function executeCrossChainCall(...) external payable returns (bytes memory result) {
    ...
    (result, bool failed) = _consumeAndExecute(actionHash, int256(msg.value));
    if (failed) {
        // Return a sentinel that the proxy interprets as "revert with this data"
        // Could use a custom ABI encoding or error-like wrapper
    }
    return result;
}

// Proxy checks and reverts on behalf:
if (success) {
    // decode and check if manager signaled failure
    // if so, revert with the original returnData
}
```

This is the cleanest approach but requires a protocol between manager and proxy for signaling failures.

**F. Accept the constraint: failed entries must not exist in the deferred table**

The off-chain precomputation ensures that entries with `failed == true` are only used as the immediate entry in `postBatch` (index 0, `actionHash == bytes32(0)`). Since `postBatch` calls `_applyAndExecute` directly (not through `_consumeAndExecute`), the failed revert path is never hit for deferred entries. For proxy-triggered entries that fail, use `revertSpan` around the calls instead.

This is the simplest solution but restricts what can be expressed in the execution table.

---

## 1b. Failed nested action (reentrant call reverts) blocks entry verification

### Problem

If a reentrant call (one that triggers `_consumeNestedAction`) reverts, the EVM rolls back all state changes in that sub-context — including the `_lastNestedActionConsumed++` increment (transient storage follows revert rules). The nested action is never consumed, so the entry-level verification `_lastNestedActionConsumed == entry.nestedActions.length` fails with `UnconsumedNestedActions`.

The current workaround is documented: "All nested actions must succeed. Failed calls should use StaticCall instead." But this pushes complexity to the off-chain precomputation, which must predict failures and route them through the static call path.

### Scenario

```
_processNCalls: executes call c0 via proxy
  → destination calls back into proxy (reentrant)
  → executeCrossChainCall → _consumeNestedAction
    → _lastNestedActionConsumed++ (0 → 1)
    → _processNCalls(nested.callCount) — processes nested calls
    → one of the nested calls reverts, propagating up through _consumeNestedAction
  → revert rolls back _lastNestedActionConsumed to 0
proxy call returns (success=false, revertData)
CALL_END hashes the failure — but nested action was NOT consumed
→ verification fails: _lastNestedActionConsumed (0) != nestedActions.length (1)
```

The fundamental issue: `_lastNestedActionConsumed++` happens INSIDE the sub-call context (the proxy call → destination → reentrant call chain). A revert anywhere in that chain rolls back the transient storage increment. There's no way to "commit" the increment before the potential revert because it's triggered by the destination's callback, not by the manager.

### Possible solutions

**A. Wrap failing calls in revertSpan (current design, off-chain)**

If the off-chain precomputation knows a call will trigger a failed reentrant call, it wraps that call in a `revertSpan`. The entire call (including the reentrant callback) executes inside `executeInContext`. The `ContextResult` carries `_lastNestedActionConsumed` out of the revert context, preserving consumption state even though the inner call failed.

Downside: requires off-chain prediction of which calls will fail. Also, the call with the reentrant callback must be the one with `revertSpan` — not just any call in the span.

**B. Pre-consume nested actions before the proxy call**

Move nested action consumption from the reentrant callback into the outer `_processNCalls` loop. The manager would know (from execution entry metadata) that call N triggers nested action M, and pre-consume it before making the proxy call:

```
for each call:
  if this call triggers a nested action:
    advance _lastNestedActionConsumed (in outer context — survives inner revert)
    hash NESTED_BEGIN
    _processNCalls(nested.callCount)  // process nested calls
    hash NESTED_END
  execute the call via proxy
  hash CALL_END
```

This requires a new field on `CrossChainCall` (e.g., `uint256 nestedActionCount` — how many nested actions this call triggers, typically 0 or 1). The reentrant `executeCrossChainCall` would just return `nested.returnData` without consuming (already consumed).

Upside: completely solves the problem — consumption index advances in the outer context, immune to inner reverts.

Downside: changes the execution model. The destination contract's callback no longer drives consumption. The manager must know in advance which calls are reentrant.

**C. Treat reentrant-call-that-reverts as a special revertSpan automatically**

When a proxy call fails AND the next nested action hasn't been consumed (indicating a failed reentrant call), the manager could retry the call inside a revert context to capture the consumption:

Problem: the manager can't know at CALL_END time whether the failed call was supposed to trigger a nested action. The failure could be a normal call failure (no nesting) or a nested action failure.

**D. Accept current design — document the constraint**

The current design works correctly under its stated constraints: the off-chain precomputation routes all potentially-failing reentrant calls through `StaticCall` lookup or wraps them in `revertSpan`. The constraint "nested actions must succeed" is a valid design choice that trades off-chain flexibility for on-chain simplicity.

This is well-documented in `ICrossChainManager.sol`:
> All nested actions must succeed. Failed calls should use StaticCall instead.

---

## 2. `L2TXExecuted` event declared but never emitted

`Rollups.sol` declares `event L2TXExecuted(uint256 indexed entryIndex)` but `executeL2TX()` never emits it. Either emit it in `executeL2TX` or remove the declaration.

---

## 3. `staticCalls` lookup is O(n) linear scan

`staticCallLookup` iterates over the entire `staticCalls[]` array to find a match. For entries with many static calls this could be gas-expensive. Consider:
- A mapping from `keccak256(actionHash, callNumber, lastNestedActionConsumed)` to index
- Keeping the array sorted and using binary search
- Requiring static calls to be ordered so sequential lookup works

---

## 4. No `depositEther` function

The ether accounting system tracks `rollups[rollupId].etherBalance` and enforces non-negative balances, but there's no way to deposit ETH into a rollup's balance outside of state deltas in `postBatch`. Consider adding:

```solidity
function depositEther(uint256 rollupId) external payable {
    rollups[rollupId].etherBalance += msg.value;
}
```

---

## 5. No mechanism to clear a stuck execution table

If entries are posted via `postBatch` but cannot be consumed in the same block (e.g., a bug in off-chain construction), the execution table is stuck until the next `postBatch` overwrites it. Consider whether a cleanup mechanism is needed, or if the one-block lifecycle is sufficient.

---

## 6. Action struct unused on-chain

The `Action` struct in `ICrossChainManager.sol` is declared but never used by any contract function. It exists only for off-chain tooling to compute `actionHash`. Consider moving it to a separate file or adding a comment clarifying its off-chain-only purpose.

---

## 7. Rewrite stubbed scripts

The following scripts were stubbed out during the flatten refactor because they used removed types (`Action`, `ActionType`, `ExecutionEntry.nextAction`, `StateDelta.currentState`). They need full rewrites for the new model:

- `script/DecodeExecutions.s.sol` — execution entry decoder/visualizer
- `script/e2e-decode/E2EDecode.s.sol` — e2e test decoder
- `script/e2e-decode/E2EBridgeDecode.s.sol` — e2e bridge test decoder
- `script/flash-loan-test/ExecuteFlashLoan.s.sol` — flash loan e2e executor

---

## 8. Update visualizator dashboard

`visualizator/dashboard/index.html` and the Remotion video source (`visualizator/video/src/`) reference the old execution model (scope-based navigation, Action/ActionType structs, nextAction flow). Update to reflect:
- Flat `calls[]` array with `callCount`
- `NestedAction` with `callCount` instead of `calls[]`
- Rolling hash with 4 tagged events (CALL_BEGIN, CALL_END, NESTED_BEGIN, NESTED_END)
- `revertSpan` instead of scope-based revert handling

---

## 9. Update integration test plan documentation

`test/INTEGRATION_TEST_PLAN.md` describes the old scope-based scenarios and is now deprecated. Rewrite to document the current test scenarios:
- Scenario 1: L1 calls L2 (simple deferred entry)
- Scenario 2: L2 calls L1 (simple deferred entry)
- Scenario 3: Nested L2 entry (cross-manager)
- Scenario 4: Nested L1 entry (cross-manager)
- Bridge tests: ether bridge, token bridge, roundtrip
- Flash loan: cross-chain atomic flash loan

---

## 10. Add events for data only in rolling hash (see `src/events.md`)
