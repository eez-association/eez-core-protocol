# Smart Contract TODOs

Living list of in-code TODOs and open design issues.

For multi-prover / per-rollup-manager specific items, see also
[`docs/MULTI_PROVER_DESIGN.md`](../docs/MULTI_PROVER_DESIGN.md) — its
"Open / pending design decisions" section is the source of truth for that
refactor's open questions and is updated as the design evolves.

---

## 1. Failed entry (`entry.failed == true`) blocks the rollup queue

### Problem

When `_consumeAndExecute` processes a deferred entry with `failed == true`, it executes all calls (to verify the rolling hash), then reverts with `entry.returnData` via assembly. But the `cursor++` on `verificationByRollup[destRid].cursor` and the state-delta mutations applied just before the revert are **rolled back** — the revert propagates through `executeCrossChainCall`, which was called via `.call` from the proxy. The entire call frame is undone.

Result: the failed entry is never consumed, the per-rollup cursor stays the same, and **every subsequent call to that rollup hits the same failed entry forever** until a new `postBatch` lazy-resets the queue (next block, or different sub-batch group).

### Scenario

```
User calls proxy → proxy calls executeCrossChainCall via .call
  → _consumeAndExecute(destRid, ...):
    → verificationByRollup[destRid].cursor++ (0 → 1)
    → applies state deltas, processes calls, verifies rolling hash — all good
    → entry.failed == true
    → assembly { revert(returnData) }
  → revert propagates: cursor rolled back to 0, state deltas reverted
proxy catches revert, returns failure to user

Next call: cursor still 0, same failed entry, same revert → stuck for the rest of the block
```

### Possible solutions

1. **Drop `entry.failed` entirely.** Express top-level failures via `revertSpan = 0` and a naturally-reverting destination — `(success=false, retData)` is captured in `CALL_END`'s rolling-hash payload. The orchestrator never needs an explicit failed flag.
2. **Two-phase consume**: do `cursor++` AND emit `ExecutionConsumed` in a frame that survives the revert (e.g., a trusted-self-call wrapper that catches `entry.failed`'s revert and bubbles it up after committing the cursor advance).
3. **Cursor commit before content evaluation.** Restructure to bump the cursor + apply state deltas in an outer self-call, then evaluate `entry.failed` in an inner self-call whose revert is caught.

Option 1 is cleanest if no use case requires the explicit failed flag. Worth auditing the off-chain spec.

---

## 2. `LookupCall` lookup is O(n) linear scan

### Problem

`staticCallLookup` iterates the destination rollup's `lookupQueue` (and the transient `_transientLookupCalls`) to find an entry matching `(actionHash, callNumber, lastNestedActionConsumed)`. Same shape in `_consumeNestedAction`'s failed-reentry fallback. For sub-batches with many lookup calls this is O(n) per lookup; nested-call-heavy entries can hit it many times.

### Possible optimizations

- **Sort by lookup-key hash.** Have the orchestrator sort `lookupCalls[]` by `keccak256(actionHash, callNumber, lastNestedActionConsumed)` (cast to `uint256`). On-chain, replace the linear scan with a binary search → O(log n). The proof would enforce sort order via a single `keys[i+1] > keys[i]` check, and `lookupCallHashes` already binds the array contents into the publicInputsHash so the prover can't reorder maliciously.
- **Mapping from lookup-key hash to index.** O(1) but adds storage cost per entry (extra SSTORE on publish).
- **Require strict execution-order ordering**, so sequential cursor lookup works (no key match needed).

The TODO comment lives inline at `staticCallLookup` in `src/Rollups.sol`. Punted until profiling shows it matters.

---

## 3. `_publishRemainder` could skip persistent entries when the meta hook left transient unconsumed

### Problem

`_publishRemainder` unconditionally pushes every sub-batch's persistent remainder into per-rollup queues, even if the meta hook didn't drain the transient stream. Persistent entries whose preconditions depended on a dropped transient sibling will fail their `StateRootMismatch` check at consumption time — wasted SSTOREs.

### Optimization sketch

Track per-sub-batch transient consumption (or walk `_transientExecutionIndex` back to sub-batch boundaries) and skip publishing the persistent tail of any sub-batch whose transient prefix wasn't fully drained. Only a win if hooks frequently leave entries unconsumed; in normal operation hooks should drain. TODO comment lives inline at `_publishRemainder` in `src/Rollups.sol`.

---

## 4. `_processNLookupCalls` rolling-hash format diverges from main

### Issue

The main rolling hash uses tagged events (`CALL_BEGIN` / `CALL_END` / `NESTED_BEGIN` / `NESTED_END`) with call numbers. `_processNLookupCalls` (the sub-call replay inside `_resolveLookupCall`) uses an untagged `keccak256(prev, success, retData)` — different schema.

This is a pre-existing simplification (pre-multi-prover). It works because `LookupCall.rollingHash` is a separate per-LookupCall accumulator, not the entry-level `_rollingHash`. But the divergence is undocumented in the protocol spec.

### Action

Decide whether to:
1. Document the divergence (lookup-call sub-hashes use a simpler formula because the surrounding lookup-key already pins context).
2. Align with the tagged scheme for consistency.

---

## See also

- [`docs/MULTI_PROVER_DESIGN.md`](../docs/MULTI_PROVER_DESIGN.md) — multi-prover refactor notes, including:
  - `rollupContractRegistered` reentrancy in `setRollupContract` (callback fires after pointer update).
  - `createRollup` initial-state overwrite via callback → `setStateRoot`.
  - Double-registration of the same manager address for two rollupIds.
  - Handoff back to a previously-used reference manager (`rollupIdSet` permanent latch).
  - `rollupId == 0` (MAINNET) excluded from sub-batches by the strict-increasing check.
  - Possible "join" of `Action` and `CrossChainCall`.
  - Per-(destination rollup) call ID counter idea.
- [`docs/CAVEATS.md`](../docs/CAVEATS.md) — operator-facing edge cases.
- [`docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md`](../docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md) — formal protocol spec.
