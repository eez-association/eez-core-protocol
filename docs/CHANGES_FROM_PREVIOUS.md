# Changes From Previous Protocol Version

Migration notes from the legacy scope-tree / `ActionType` model to the current **flat sequential execution model**. The current protocol is documented in `SYNC_ROLLUPS_PROTOCOL_SPEC.md` and `EXECUTION_TABLE_SPEC.md`; this file exists only to help readers who remember the old shape map their mental model onto the new one.

> If you are new to the protocol, you do not need to read this file — start with `SYNC_ROLLUPS_PROTOCOL_SPEC.md`.

---

## Removed Concepts

The following concepts existed in the previous protocol version and are gone:

### `ActionType` enum
There is no longer an `ActionType` enum on `Action` or any other struct. All cross-chain work is expressed as `CrossChainCall`s; entry classification (immediate vs. deferred) is derived from `actionHash == bytes32(0)` alone.

### `RESULT` / `REVERT` / `REVERT_CONTINUE` action types
These three action types are removed. Their roles are absorbed as follows:

| Old action     | New mechanism |
|---|---|
| `RESULT`            | Return data is hashed directly into the rolling hash via `CALL_END(callNumber, success, retData)` |
| `REVERT`            | Modeled with `revertSpan > 0` on a `CrossChainCall`, or with `entry.failed = true` for terminal failure of an immediate entry |
| `REVERT_CONTINUE`   | Subsumed by `revertSpan` — the span boundary defines what rolls back; calls outside the span continue normally |

### `scope` arrays and scope navigation
The `scope` field on `Action` is gone. The scope tree, recursive `newScope()` calls, and all scope-resolution helpers (`_resolveScopes`, `_handleScopeRevert`, `_scopesMatch`, `_isChildScope`, `_appendToScope`) are removed. The off-chain prover does not thread scope arrays through nested calls — it emits a flat `calls[]` plus a parallel `NestedAction[]`.

### `ScopeReverted` error
Removed. There is no scope-level revert path; `revertSpan` handles all atomic rollback.

### `currentState` on `StateDelta`
The previous-state-root field was removed from `StateDelta`. The previous state root is read from `rollups[rollupId].stateRoot` at proof time and folded into the entry hash via `_computeEntryHashes`, so the proof itself binds to the live state root. Consequence: there is no `StateRootMismatch` revert during entry consumption — a stale builder produces a proof that fails verification, not one that fails matching.

### `failed` field on `Action`
Removed. The previous `Action` struct had a `failed` flag; the new off-chain `Action` struct carries only the six hash-input fields. Failure is expressed at the call level (`CALL_END.success`), at the entry level (`ExecutionEntry.failed` for immediate entries), or via `revertSpan`.

---

## Replaced Mechanisms

### Scope-tree revert machinery → `revertSpan`
**Old**: `REVERT` / `REVERT_CONTINUE` actions, continuation entries, per-rollup state-root restoration calls, scope-tree navigation.

**New**: `CrossChainCall.revertSpan = N` opens an isolated EVM context covering the next `N` calls. The processor self-calls `executeInContext(N)`, which always reverts with `ContextResult(rollingHash, lastNestedActionConsumed, currentCallNumber)`. The EVM rolls back state inside the span; the three counters escape via the revert payload and the outer flow restores them so the rolling hash and cursors reflect what happened inside.

No continuations to look up. No per-rollup state-root restoration. No scope tree to navigate. The "what happened" is encoded by the calls in the span; the "what state survives" is whatever the EVM rolled back.

### Per-call result tracking → single `rollingHash` per entry
**Old**: separate result entries (`RESULT` actions), per-scope return-data accumulators.

**New**: one `bytes32 rollingHash` per `ExecutionEntry`. Four tagged events update the accumulator (`CALL_BEGIN`, `CALL_END`, `NESTED_BEGIN`, `NESTED_END`). A single mismatch anywhere in the execution tree — wrong return data, wrong success/failure flag, missing or extra calls, incorrect nesting structure — is caught with one comparison at the end of the entry.

### Reentrant calls → `NestedAction` table or `StaticCall`
**Old**: scope navigation tracked nested calls implicitly.

**New**:
- Reentrant call that **succeeds** → consume one entry from `entry.nestedActions[]` (sequential cursor).
- Reentrant call that **reverts** (caller catches with try/catch) → look up a `StaticCall` keyed by `(actionHash, callNumber, lastNestedActionConsumed)` with `failed = true`.
- Reentrant cross-chain `STATICCALL` (read-only) → same `StaticCall` lookup with `failed = false`.

A reverting reentrant call cannot use `NestedAction` because the revert rolls back the consumption-cursor `tstore`, making consumption silent. `StaticCall` is content-addressed and replays the cached revert deterministically.

---

## Removed Symbols

For grep-ability when porting old code/docs:

- `ActionType` (enum)
- `Action.scope` (field)
- `Action.failed` (field)
- `StateDelta.currentState` (field)
- `newScope` (function)
- `_resolveScopes` (helper)
- `_handleScopeRevert` (helper)
- `_scopesMatch` (helper)
- `_isChildScope` (helper)
- `_appendToScope` (helper)
- `ScopeReverted` (error)
- `StateRootMismatch` (error — replaced by proof-time binding)
- `executeIncomingCrossChainCall` (L2 system-only entry point — top-level L2 calls now arrive via user txs hitting proxies)
- `_etherDelta` (transaction-wide ETH accumulator — replaced by per-entry localized accounting on L1)
- `domain` / `block.chainid` term in the proxy CREATE2 salt — salt is now exactly `(originalRollupId, originalAddress)`

---

## When To Read This File

- You are migrating a Rust node/prover or off-chain tool that targets the previous protocol version.
- You are reviewing a PR whose description references one of the removed concepts.
- You found a stale comment or test that mentions the old machinery.

Otherwise, prefer `SYNC_ROLLUPS_PROTOCOL_SPEC.md` (formal spec) and `EXECUTION_TABLE_SPEC.md` (build-side guide).
