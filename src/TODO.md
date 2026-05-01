# Smart Contract TODOs

Living list of in-code TODOs and open design issues.

For multi-prover / per-rollup-manager specific items, see also
[`docs/MULTI_PROVER_DESIGN.md`](../docs/MULTI_PROVER_DESIGN.md) — its
"Open / pending design decisions" section is the source of truth for that
refactor's open questions and is updated as the design evolves.

---

## 1. DISCUSSION — execution vs lookup: `entry.failed` removed

### Resolution applied

Dropped `bool failed` from `ExecutionEntry`. Deferred entries always succeed at the top
level — `executeCrossChainCall` returns `entry.returnData` as success.

### Rationale

A reverting top-level call **isn't an execution** — it's a *lookup*. Executions are
"this happened and produced state changes." Reverts are "this happened and the cached
result is a revert payload." The protocol already has a clean abstraction for the second
case: `LookupCall { failed: true }`, consumed via `staticCallLookup` (static-context
entry point) or via the failed-reentry fallback in `_consumeNestedAction`.

Splitting along this seam:
- **`ExecutionEntry`** = state-mutating execution. Always succeeds at the top level.
  Inner calls may revert naturally; their `(success=false, retData)` is captured in the
  rolling-hash `CALL_END` payload. The entry's outer `executeCrossChainCall` still
  returns `entry.returnData` as success.
- **`LookupCall`** with `failed: true` = revert replay. Content-addressed by
  `(actionHash, callNumber, lastNestedActionConsumed)`, replays cached sub-calls if any,
  and reverts with the cached payload. Survives EVM revert rollback because it's a
  read-side lookup, not a queue advance.

### What we gave up

The orchestrator can no longer express "this top-level cross-chain call reverted on the
source side, propagate the revert to the destination caller" as an `ExecutionEntry`.
Instead, the orchestrator must:
- (a) Not construct a deferred entry for the reverted source-side call (drop it from the
  cross-chain stream entirely), OR
- (b) Express the reverting call as a `LookupCall` so destination-side callers can
  observe the revert via the static-context entry point.

This is a behavioral change for the off-chain spec — flag it to the spec maintainers.

### What this fixed

The previous "stuck-queue" bug: when `_consumeAndExecute` reverted with
`entry.returnData`, the cursor++ on `verificationByRollup[destRid].cursor` was rolled
back along with the state-delta mutations. Every subsequent call to that rollup hit the
same failed entry until the next-block lazy reset. Removing `entry.failed` removes the
revert-from-`_consumeAndExecute` path, so the cursor++ always commits.

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
