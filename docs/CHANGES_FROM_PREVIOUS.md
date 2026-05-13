# Changes From Previous Protocol Version

Migration notes from the legacy scope-tree / `ActionType` model to the current **flat sequential execution model**. The current protocol is documented in `SYNC_ROLLUPS_PROTOCOL_SPEC.md` and `EXECUTION_TABLE_SPEC.md`; this file exists only to help readers who remember the old shape map their mental model onto the new one.

> If you are new to the protocol, you do not need to read this file — start with `SYNC_ROLLUPS_PROTOCOL_SPEC.md`.

---

## Removed Concepts

The following concepts existed in the previous protocol version and are gone:

### `ActionType` enum
There is no longer an `ActionType` enum on `Action` or any other struct. All cross-chain work is expressed as `L2ToL1Call`s; entry classification (immediate vs. deferred) is derived from `ExecutionEntry.proxyEntryHash == bytes32(0)` alone.

### `RESULT` / `REVERT` / `REVERT_CONTINUE` action types
These three action types are removed. Their roles are absorbed as follows:

| Old action     | New mechanism |
|---|---|
| `RESULT`            | Return data is hashed directly into the rolling hash via `CALL_END(callNumber, success, retData)` |
| `REVERT`            | Modeled with `revertSpan > 0` on an `L2ToL1Call`, or — for an immediate entry that naturally reverts — caught by the `try/catch` around `attemptApplyImmediate` and emitted as `ImmediateEntrySkipped(transientIdx, revertData)` |
| `REVERT_CONTINUE`   | Subsumed by `revertSpan` — the span boundary defines what rolls back; calls outside the span continue normally |

### `scope` arrays and scope navigation
The `scope` field on `Action` is gone. The scope tree, recursive `newScope()` calls, and all scope-resolution helpers (`_resolveScopes`, `_handleScopeRevert`, `_scopesMatch`, `_isChildScope`, `_appendToScope`) are removed. The off-chain prover does not thread scope arrays through nested calls — it emits a flat `L2ToL1Calls[]` plus a parallel `expectedL1ToL2Calls[]`.

### `ScopeReverted` error
Removed. There is no scope-level revert path; `revertSpan` handles all atomic rollback.

### `failed` field on `ExecutionEntry`
Removed. Top-level entries always succeed. A reverting top-level cross-chain call is expressed as a `LookupCall { failed: true }` consumed via `staticCallLookup` (static context), via the failed-reentry fallback in `_consumeNestedAction`, or via the new top-level fallback `_tryRevertedTopLevelLookup` (`src/EEZ.sol:1043`, `src/L2/EEZL2.sol`).

### `failed` field on `Action`
Removed from the off-chain `Action` shim — it carries only the six hash-input fields. Failure is expressed at the call level (`CALL_END.success`) or via `revertSpan`. Entry-level failure for top-level calls is now expressed via `LookupCall { failed: true }`, not via an `ExecutionEntry` flag.

---

## Replaced Mechanisms

### Scope-tree revert machinery → `revertSpan`
**Old**: `REVERT` / `REVERT_CONTINUE` actions, continuation entries, per-rollup state-root restoration calls, scope-tree navigation.

**New**: `CrossChainCall.revertSpan = N` opens an isolated EVM context covering the next `N` calls. The processor self-calls `executeInContext(N)`, which always reverts with `ContextResult(rollingHash, lastNestedActionConsumed, currentCallNumber)`. The EVM rolls back state inside the span; the three counters escape via the revert payload and the outer flow restores them so the rolling hash and cursors reflect what happened inside.

No continuations to look up. No per-rollup state-root restoration. No scope tree to navigate. The "what happened" is encoded by the calls in the span; the "what state survives" is whatever the EVM rolled back.

### Per-call result tracking → single `rollingHash` per entry
**Old**: separate result entries (`RESULT` actions), per-scope return-data accumulators.

**New**: one `bytes32 rollingHash` per `ExecutionEntry`. Four tagged events update the accumulator (`CALL_BEGIN`, `CALL_END`, `NESTED_BEGIN`, `NESTED_END`). A single mismatch anywhere in the execution tree — wrong return data, wrong success/failure flag, missing or extra calls, incorrect nesting structure — is caught with one comparison at the end of the entry.

### Reentrant calls → `ExpectedL1ToL2Call` table or `LookupCall`
**Old**: scope navigation tracked nested calls implicitly.

**New**:
- Reentrant call that **succeeds** → consume one entry from `entry.expectedL1ToL2Calls[]` (sequential cursor).
- Reentrant call that **reverts** (caller catches with try/catch) → look up a `LookupCall` keyed by `(crossChainCallHash, callNumber, lastNestedActionConsumed)` with `failed = true`.
- Reentrant cross-chain `STATICCALL` (read-only) → same `LookupCall` lookup with `failed = false`.

A reverting reentrant call cannot use `ExpectedL1ToL2Call` because the revert rolls back the consumption-cursor `tstore`, making consumption silent. `LookupCall` is content-addressed and replays the cached revert deterministically.

---

## Removed Symbols

For grep-ability when porting old code/docs:

- `ActionType` (enum)
- `Action.scope` (field)
- `Action.failed` (field)
- `ExecutionEntry.failed` (field — top-level entries always succeed; reverting top-level calls use `LookupCall { failed: true }`)
- `newScope` (function)
- `_resolveScopes` (helper)
- `_handleScopeRevert` (helper)
- `_scopesMatch` (helper)
- `_isChildScope` (helper)
- `_appendToScope` (helper)
- `ScopeReverted` (error)
- `setRollupContract` (function) / `RollupContractChanged` (event) — the manager-handoff path was removed. A rollup's manager contract is set at registration time and is immutable thereafter (see `src/rollupContract/Rollup.sol:144-149` natspec).
- `_etherDelta` (transaction-wide ETH accumulator — replaced by per-entry localized accounting on L1)
- `domain` / `block.chainid` term in the proxy CREATE2 salt — salt is now exactly `(originalRollupId, originalAddress)`

Note: `StateRootMismatch(uint256 rollupId)` and `StateDelta.currentState` were *briefly* removed in an earlier draft of this refactor but have been **re-added** as the soundness backstop — entries whose recorded `currentState` doesn't match `rollups[rid].stateRoot` at consumption time revert `StateRootMismatch` (`src/EEZ.sol:209, 936`).

---

## When To Read This File

- You are migrating a Rust node/prover or off-chain tool that targets the previous protocol version.
- You are reviewing a PR whose description references one of the removed concepts.
- You found a stale comment or test that mentions the old machinery.

Otherwise, prefer `SYNC_ROLLUPS_PROTOCOL_SPEC.md` (formal spec) and `EXECUTION_TABLE_SPEC.md` (build-side guide).

---

## Multi-prover refactor on `feature/flatten`

A second migration layered on top of the flat-sequential model. Full design notes live in `MULTI_PROVER_DESIGN.md`; the bullets below are a quick orientation.

### Shape changes

- **`postAndVerifyBatch` signature**: `postAndVerifyBatch(ProofSystemBatchPerVerificationEntries calldata batch)` replaces the old single-bundle `postBatch(entries, _staticCalls, transientCount, transientStaticCallCount, blobCount, callData, proof)`. A single struct (not an array) carries the whole batch: `entries[]`, `l1ToL2lookupCalls[]`, `transientExecutionEntryCount`, `transientLookupCallCount`, `proofSystems[]` (sorted ascending), `rollupIdsWithProofSystems[]` (strictly ascending by `rollupId`, each carrying a `proofSystemIndex[]` of indices into `proofSystems[]`), `crossProofSystemInteractions`, `blobIndices[]`, `callData`, `proofs[]` (one per proof system). All proofs in the batch verify atomically. See `src/EEZ.sol:49-60`.
- **File renames / moves**: `src/Rollups.sol` → `src/EEZ.sol`; `src/Rollup.sol` → `src/rollupContract/Rollup.sol`; `src/CrossChainProxy.sol` → `src/base/CrossChainProxy.sol`; `src/EEZL2.sol` → `src/L2/EEZL2.sol`; interfaces moved under `src/interfaces/`. New shared base `src/base/EEZBase.sol` hosts the rolling-hash machinery, proxy registry, and cross-chain-call hash for both L1 and L2.
- **Per-rollup queue model**: the global `executions[]` / `executionIndex` / `lastStateUpdateBlock` are replaced by per-rollup storage `verificationByRollup[rid] = { lastVerifiedBlock, queue, lookupQueue, cursor }`. Consumers (`executeCrossChainCall`, `executeL2TX(rollupId)`, `staticCallLookup`) route to the rollup's queue/cursor; cross-rollup state is independent. `verificationByRollup` is `internal`; public accessors are `lastVerifiedBlock(rid)`, `queueLength(rid)`, `queueCursor(rid)`.
- **Per-rollup manager pattern**: each rollup's owner / threshold / proof-system membership / verification keys live on the rollup's own `IRollupContract`-conforming manager (reference impl: `src/rollupContract/Rollup.sol`). The registry calls `IRollupContract.checkProofSystemsAndGetVkeys(addresses[])` per batch (manager rejects unknown PS or `proofSystems.length < threshold`) and `IRollupContract.getTimestampAndBlockHash()` to fold per-rollup state into the per-PS public input. The central `EEZ` registry no longer holds owner or vkey — it just stores `(rollupContract, stateRoot, etherBalance)` per rollup.
- **`Action` struct removed from contracts**: an off-chain compat-shim still lives in `script/e2e/shared/E2EHelpers.sol` for tooling that wants to compute `crossChainCallHash` from a struct, but the on-chain interface (`IEEZ.sol`) no longer declares it.
- **`entry.failed` removed**: top-level entries always succeed. A reverting cross-chain result at the top level is expressed as a `LookupCall { failed: true }` consumed via `staticCallLookup` (static context), via the failed-reentry fallback in `_consumeNestedAction`, or via the new top-level fallback `_tryRevertedTopLevelLookup`. Naturally-reverting inner calls are still captured via `CALL_END(false, retData)`.
- **Reentry guard simplification**: the early `_inPostBatch` flag is gone. Reentry is detected via `_transientExecutions.length != 0` (cleared at the end of `postAndVerifyBatch`); a reentrant `postAndVerifyBatch` reverts `PostBatchReentry` (`src/EEZ.sol:142-147, 314`).
- **`setStateRoot` reentrancy guard (new)**: in addition to the same-block lockout, `setStateRoot` now reverts `SetStateRootNotAllowedDuringExecution` if `_insideExecution()` is true — the manager cannot rewrite state mid-execution via a reentrant proxy path (`src/EEZ.sol:968-976`).
- **Manager-handoff path removed**: there is no `setRollupContract` and no `RollupContractChanged` event. A rollup's manager binding is set at registration and is immutable.
- **L2 system-only inbound delivery (new)**: `EEZL2.executeIncomingCrossChainCall(destination, value, data, sourceAddress, sourceRollup, entries, _lookupCalls)` is the new top-level inbound path for cross-chain calls from another rollup (`onlySystemAddress`, atomically loads the execution table and consumes `entries[0]`, returns `executions[0].returnData`). Reverts `EmptyEntries` if `entries.length == 0`, `ValueMismatch` if `msg.value != value`. Emits `IncomingCrossChainCallExecuted`. See `src/L2/EEZL2.sol:161-211`.

### Renames (grep table)

| Old | New |
|---|---|
| `Rollups.sol` (file) | `EEZ.sol` |
| `Rollups` (contract / registry) | `EEZ is EEZBase` |
| `IRollup` (interface name) | `IRollupContract` (file is still `src/interfaces/IRollup.sol`) |
| `getVkeysFromProofSystems` (manager method) | `checkProofSystemsAndGetVkeys` |
| `postBatch` | `postAndVerifyBatch` (takes single struct, not array) |
| `ProofSystemBatch` (struct) | `ProofSystemBatchPerVerificationEntries` |
| `ProofSystemBatch.rollupIds` (field) | Replaced by `rollupIdsWithProofSystems[]` (each row has `rollupId` + explicit `proofSystemIndex[]`) |
| `ProofSystemBatch.lookupCalls` (field) | `l1ToL2lookupCalls` |
| `ProofSystemBatch.transientCount` (field) | `transientExecutionEntryCount` |
| `ProofSystemBatch.proof` (field) | `proofs` |
| `StaticCall` (struct) | `LookupCall` |
| `CrossChainCall` (struct) | `L2ToL1Call` |
| `NestedAction` (struct) | `ExpectedL1ToL2Call` |
| `ExecutionEntry.crossChainCallHash` (field) | `proxyEntryHash` |
| `ExecutionEntry.calls` (field) | `L2ToL1Calls` |
| `ExecutionEntry.nestedActions` (field) | `expectedL1ToL2Calls` |
| `staticCalls` / `_staticCalls` (storage / arg) | `lookupCalls` / `_transientLookupCalls` / per-rollup `lookupQueue` |
| `transientStaticCallCount` (postBatch arg) | `transientLookupCallCount` (batch field) |
| `actionHash` (struct field name) | `crossChainCallHash` (and on `ExecutionEntry`, `proxyEntryHash`) |
| `executeInContext` | `executeInContextAndRevert` |
| `_computeActionInputHash` | `computeCrossChainCallHash` (now `public pure`, lives on `EEZBase`) |
| `executeL2TX()` | `executeL2TX(uint256 rollupId)` |
| `IZKVerifier` | `IProofSystem` |
| `MANAGER` (immutable on `CrossChainProxy`) | `EEZ` |

### Events / errors reshaped or dropped

| Event/error | Status |
|---|---|
| `RollupCreated(rollupId, rollupContract, initialState)` | Reshaped to 3 fields (no more owner / vkey) |
| `BatchPosted(uint256 rollupCount)` | Reshaped — counts `batch.rollupIdsWithProofSystems.length` (was previously `subBatchCount`) |
| `ExecutionConsumed(crossChainCallHash, rollupId, cursor)` | Reshaped — adds rollupId; cursor is per-rollup. L2 variant has signature `ExecutionConsumed(crossChainCallHash, cursor)` (single rollup, no rollupId). |
| `L2TXExecuted(rollupId, cursor)` | Reshaped — adds rollupId |
| `IncomingCrossChainCallExecuted(crossChainCallHash, destination, value, data, sourceAddress, sourceRollup)` | New (L2) — fires from `executeIncomingCrossChainCall` |
| `ImmediateEntrySkipped(transientIdx, revertData)` | New — emitted instead of reverting when an immediate entry's self-call fails |
| `CallResult`, `NestedActionConsumed`, `EntryExecuted`, `RevertSpanExecuted` | Declared on `EEZBase`; emitted from the shared execution machinery on both L1 and L2 |
| `StateUpdated`, `VerificationKeyUpdated`, `OwnershipTransferred`, `L2ExecutionPerformed` | Dropped (the corresponding owner-only entry points moved to `Rollup.sol`) |
| `RollupContractChanged` / `setRollupContract` | **Dropped** — manager binding is immutable after registration. |
| `RollupBatchActiveThisBlock(rollupId)`, `RollupNotInBatch(rollupId)`, `StateRootMismatch(rollupId)`, `ExecutionNotInCurrentBlock(rollupId)` (L1; L2 variant takes no arg), `PostBatchReentry`, `InvalidProofSystemConfig`, `DuplicateProofSystem`, `SetStateRootNotAllowedDuringExecution` | New errors covering the per-rollup / multi-prover invariants |
| `EmptyEntries`, `ValueMismatch` (L2 only) | New — thrown by `executeIncomingCrossChainCall` |

### Owner-only operations

`setStateByOwner`, `setVerificationKey`, `transferRollupOwnership` are gone from the central registry. They live on the per-rollup manager contract (`src/rollupContract/Rollup.sol` or any `IRollupContract`-conforming contract the rollup owner deployed). The `EEZ` registry exposes only:
- `setStateRoot(uint256 rollupId, bytes32 newStateRoot)` — callable by the registered rollup contract; reverts `RollupBatchActiveThisBlock` if a batch hit `rid` earlier in this block, and reverts `SetStateRootNotAllowedDuringExecution` if `_insideExecution()` is true.

There is no `setRollupContract` and no manager-handoff path: a rollup's manager binding is set at registration and is immutable thereafter.
