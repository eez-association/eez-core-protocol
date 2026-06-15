# Execution Entry Specification

How to correctly build execution entries for L1 (`postAndVerifyBatch`) and L2 (`loadExecutionTable`).

The protocol uses a **flat, sequential** execution model: every entry contains a flat array of calls processed in order (L1: `L2ToL1Call[] l2ToL1Calls`; L2: `CrossChainCall[] incomingCalls`), with reentrant calls consumed from a parallel expected-results array (L1: `ExpectedL1ToL2Call[] expectedL1ToL2Calls`; L2: `ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls`) and a single `rollingHash` verifying the entire execution tree at the end.

---

## Entry Structure

```solidity
// L1 (src/interfaces/IEEZ.sol)
struct ExecutionEntry {
    StateDelta[]         stateDeltas;          // state root deltas applied when entry is consumed
    bytes32              proxyEntryHash;       // bytes32(0) = immediate (L2TX or state commitment), else deferred
    uint256              destinationRollupId;  // rollup whose queue this entry routes to (per-rollup queue model)
    L2ToL1Call[]         l2ToL1Calls;          // flat array of ALL calls (entry-level + reentrant), in execution order
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;  // flat array of pre-computed reentrant call results
    ExpectedLookup[]     expectedLookups;      // entry-scoped nested lookups (static reads + try/catch'd reverts)
    uint256              callCount;            // entry-level iterations to process from l2ToL1Calls[]
    bytes                returnData;           // pre-computed return data for the entry's top-level call
    bytes32              rollingHash;          // expected hash after all calls and nestings are processed
}

// L2 (src/interfaces/IEEZL2.sol) — leaner: single rollup, no state deltas, no per-rollup routing
struct ExecutionEntry {
    bytes32                          proxyEntryHash;        // hash of the inbound call (never bytes32(0) on L2)
    CrossChainCall[]                 incomingCalls;         // flat array of ALL calls, in execution order
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls; // pre-computed reentrant (outgoing) call results
    ExpectedLookup[]                 expectedLookups;       // entry-scoped nested lookups
    uint256                          callCount;             // entry-level iterations to process from incomingCalls[]
    bytes                            returnData;
    bytes32                          rollingHash;
}
```

The L2 struct does **not** share L1's layout: `stateDeltas` and `destinationRollupId` are L1-only fields and are dropped entirely on L2 (not just left empty). L2's vocabulary is self-relative directional — `incomingCalls` are cross-chain calls executed on this L2 for a remote caller, `expectedOutgoingCalls` are reentrant calls fired from this L2 — because the counterparty can be L1 or another L2, so absolute names like `l1ToL2Calls` would often be wrong.

Top-level entries always succeed: `executeCrossChainCall` returns `entry.returnData` regardless of inner-call outcomes. There is no entry-level `failed` flag — reverts at the top level are expressed as a top-level `LookupCall` with `failed = true` in the storage pool, executed via `_tryRevertedTopLevelLookup` (or resolved via `staticCallLookup` outside an execution). Reverting REENTRANT calls are nested `ExpectedLookup`s with `failed = true` inside the entry. Naturally-reverting inner calls are still expressible: the proxy `.call` returns `(false, retData)` and the rolling hash captures it via `CALL_END`.

### Per-rollup queue routing

`destinationRollupId` selects which rollup's queue this entry is loaded into during `postAndVerifyBatch`'s deferred publish. The central `EEZ` registry stores per-rollup queues (`verificationByRollup[rid].executionQueue` and `verificationByRollup[rid].lookupQueue`) with their own per-rollup cursor (`executionQueueIndex`). Each `postAndVerifyBatch` call carries one `ProofSystemBatchPerVerificationEntries` payload covering one or more rollups; entries are routed by `destinationRollupId` into the matching rollup's queue. Cross-rollup state is independent — a stuck cursor on one rollup does not block another. See `MULTI_PROVER_SPEC.md` for the multi-prover / per-rollup-queue specifics.

### IMMEDIATE entries (`proxyEntryHash == 0`)

A leading run of the batch's transient stream may have `proxyEntryHash == 0`. Each such entry is executed inline by `postAndVerifyBatch` itself (no proxy call required) and represents the batch's immediate work — pure L2 transactions or L2 transactions that touch L1. State deltas are applied, calls are processed, and the rolling hash is verified, all within `postAndVerifyBatch`. The transient cursor (`_transientExecutionIndex`) advances past each immediate entry before the meta hook fires. If an immediate entry's self-call reverts, the registry emits `ImmediateEntrySkipped(transientIdx, revertData)` and the cursor still advances — it is not a hard error.

### DEFERRED entries (`proxyEntryHash != 0`)

Pushed to `_transientExecutions` (the leading `transientExecutionEntryCount` entries) or to per-rollup `verificationByRollup[rid].executionQueue` (the rest). Consumed in posted order by `executeCrossChainCall` or `executeL2TX(rollupId)`, and only in the block they were posted (`lastVerifiedBlock(rid) == block.number`; mismatch reverts `ExecutionNotInCurrentBlock`). Each call computes the expected cross-chain call hash from the proxy/call-site context (`executeL2TX` expects `bytes32(0)`, so zero-hash entries past the inline-drained leading run are consumed this way) and compares it to the entry at the matching rollup's `executionQueueIndex` (entry's `proxyEntryHash`); mismatch reverts with `ExecutionNotFound` (after the `_tryRevertedTopLevelLookup` fallback). Cursor advance is per-rollup.

---

## Action Hash

Every cross-chain call is identified by a single hash computed from six fields:

```solidity
crossChainCallHash = keccak256(abi.encode(
    uint256 targetRollupId,  // target rollup (which chain executes this call)
    address targetAddress,   // contract being called on the target rollup
    uint256 value,           // ETH sent with the call (0 for STATICCALL)
    bytes   data,            // calldata (selector + args)
    address sourceAddress,   // caller identity on the source rollup
    uint256 sourceRollupId   // source rollup ID
))
```

The on-chain contracts never define an `Action` struct — they reconstruct the hash from the proxy's identity (`originalRollupId`, `originalAddress`) and the live call context (`msg.value`, `callData`, `msg.sender`, `MAINNET_ROLLUP_ID` on L1 or `ROLLUP_ID` on L2) via the `public pure` helper `computeCrossChainCallHash`.

A compatibility `Action` struct exists in tooling (`script/e2e/shared/E2EHelpers.sol`) so off-chain code can compute the same preimage from a single struct. It is not part of the contract API.

### Hash semantics by entry point

| Entry point | targetRollupId | targetAddress | value | data | sourceAddress | sourceRollupId |
|---|---|---|---|---|---|---|
| `executeCrossChainCall` (L1 proxy) | proxy's `originalRollupId` | proxy's `originalAddress` | `msg.value` | original calldata | proxy's caller | `MAINNET_ROLLUP_ID` (0) |
| `executeCrossChainCall` (L2 proxy) | proxy's `originalRollupId` | proxy's `originalAddress` | `msg.value` | original calldata | proxy's caller | this L2's `ROLLUP_ID` |
| Reentrant call (consumes `ExpectedL1ToL2Call` on L1 / `ExpectedOutgoingCrossChainCall` on L2) | same as above (proxy on the chain making the reentrant call) | same | same | same | same | same |
| `executeL2TX` | n/a — entry has `proxyEntryHash == 0` | — | — | — | — | — |
| `staticCallLookup` | proxy's `originalRollupId` | proxy's `originalAddress` | `0` (static is value-free) | original calldata | proxy's caller | this chain's rollup ID |

The hash is fully determined by the six fields above; nothing else (caller depth, parent action, position in the entry) feeds into it.

### Cross-chain hash consistency

When the same logical call appears on both chains, the hash is identical on both sides:

- **L1→L2 proxy call** generated by `executeCrossChainCall` on L1 (e.g., user calls D's proxy on L1) has `targetRollupId = L2`, `sourceRollupId = MAINNET (0)`. The same hash is the trigger for L2's entry produced by the corresponding L1 entry's call processor.
- **Reentrant L2→L1 call** generated mid-execution on L2 has `targetRollupId = MAINNET`, `sourceRollupId = L2`. The same hash identifies an `ExpectedL1ToL2Call` slot on L1's entry **and** an `ExpectedOutgoingCrossChainCall` slot on L2's entry — both chains observe the same reentrant call from their own perspective.

Identical reentrant calls on both chains always hash identically — the six hash inputs alone determine the hash, with no positional or contextual term mixed in. The builder still must simulate both sides to predict exact `data` (calldata and return data) and `value`.

---

## L2ToL1Call (L2: `CrossChainCall`)

```solidity
struct L2ToL1Call {
    address targetAddress;  // contract to call on the target rollup
    uint256 value;          // ETH sent
    bytes   data;           // calldata
    address sourceAddress;  // caller identity (used to derive sourceProxy)
    uint256 sourceRollupId; // caller's rollup ID
    uint256 revertSpan;     // 0 = normal call; N>0 = force-revert the next N calls' state effects
}
```

L2's `CrossChainCall` (`IEEZL2.sol`) is field-for-field identical; only the struct name differs.

The processor reads `entry.l2ToL1Calls[_currentL2ToL1Call]` (L2: `entry.incomingCalls[_currentIncomingCall]`) from storage and, for each non-revert-span call, derives the `sourceProxy` address from `(sourceAddress, sourceRollupId)`, auto-creates the proxy if it doesn't exist, and routes the call through `CrossChainProxy.executeOnBehalf(targetAddress, data){value: value}`. If the destination call itself reverts, `_processNCalls` captures `(success=false, retData=revertReason)` from the proxy's `.call` and hashes that into `CALL_END` — natural reverts need no special wrapping.

### `revertSpan`: forced-revert context

`revertSpan > 0` is the **forced-revert** mechanism: the next `revertSpan` calls (including this one) execute, succeed, and have their state effects rolled back at the protocol layer. The rolling hash still commits to the calls' real outcomes (typically `success=true` with the captured `returnData`); only the EVM state changes disappear. The processor:

1. Saves the call cursor (L1: `_currentL2ToL1Call`; L2: `_currentIncomingCall`).
2. Zeros `entry.l2ToL1Calls[savedCallNumber].revertSpan` (L2: `incomingCalls`) in storage so the inner self-call sees `revertSpan == 0` at the same index and runs the call normally.
3. Self-calls `this.executeInContextAndRevert(revertSpan)` — that function processes the next `revertSpan` calls and **always reverts** with `error ContextResult(bytes32 rollingHash, uint256 reentrantConsumed, uint256 callsProcessed, bool callNotFound)`. (The 4th field carries L1's deferred no-match flag `_l1ToL2CallNotFound` out of the reverted span; L2 always sends `false`.)
4. The revert rolls back **all** transient storage modifications inside the self-call (including the `tstore` writes for `_rollingHash` and the two cursors) **and** all destination state changes the inner calls produced.
5. The processor decodes `ContextResult` and restores `_rollingHash` and the two cursors (L1: `_lastL1ToL2CallConsumed`, `_currentL2ToL1Call`; L2: `_lastOutgoingCallConsumed`, `_currentIncomingCall`) to the values **observed at the end of the reverted span**, bridging the rolling hash and counters across the revert boundary. On L1 it also OR-merges the decoded `callNotFound` flag back into `_l1ToL2CallNotFound`, so a no-match observed inside the span still reverts the entry at its boundary.
6. Restores `entry.l2ToL1Calls[savedCallNumber].revertSpan = revertSpan` so the storage layout matches what the proof committed to.

`revertSpan` covers a contiguous run of calls. The first call inside the span has its `revertSpan` field cleared so it executes as a normal call; subsequent calls inside the span have `revertSpan == 0` to begin with. Nested spans are a prover convention violation rather than an on-chain check — the processor would mechanically recurse, but the outer span's rollback already discards the inner state, so the prover never emits one.

#### When `revertSpan` is the right tool

The canonical use is a cross-chain call from rollup A to rollup B where B's destination call **succeeded**, but the prover output marks the call as reverted in A's view of the world (for example, because the higher-level transaction containing the call was rolled back on A). When B runs the entry, `revertSpan = 1` ensures B's state does not retain effects that A no longer commits to.

For natural failures — a destination contract that simply `revert`s — `revertSpan = 0` is correct and simpler:

- The proxy `.call` returns `success=false` with the destination's revert payload as `retData`.
- `CALL_END(false, retData)` is hashed into the rolling hash.
- The destination's own revert rolls back the destination's state.

Wrapping a single naturally-reverting call in `revertSpan = 1` is purely ceremonial — it produces the same rolling hash and the same on-chain state as `revertSpan = 0`, with an extra self-call frame for nothing. The mechanism only earns its cost when state would otherwise survive.

**Reentrant reverted calls take a different path entirely.** When the destination contract called from `_processNCalls` re-enters the manager via a proxy (a try/catch'd cross-chain call to another rollup), reverts of that nested call are expressed as a nested `ExpectedLookup` with `failed = true` inside the entry — not `revertSpan`, not `ExpectedL1ToL2Call`. `_consumeNestedAction` falls back to the matching `ExpectedLookup` at `(crossChainCallHash, l2ToL1CallNumber, lastL1ToL2CallConsumed, executingLookupIndex)` (L2: `(crossChainCallHash, callNumber, lastOutgoingCallConsumed, executingLookupIndex)`) and resolves it via `_executeRevertedNestedLookup`, which runs any sub-execution the lookup carries and then reverts with the cached `returnData`; the destination's `try/catch` catches it, no cursor is advanced, and the terminal revert rolls back any executed sub-call state. See the Lookups section below for the full mechanics.

Three distinct revert paths, one decision tree:

- Top-level call that naturally reverts → `LookupCall` with `failed = true`, consumed via `staticCallLookup`, the reverted-lookup fallback in `_consumeNestedAction`, or the top-level fallback `_tryRevertedTopLevelLookup`. (Or, when the call lives inside `l2ToL1Calls[]` / `incomingCalls[]`, place it with `revertSpan = 0` and let `CALL_END(false, retData)` capture it.)
- Reentrant (re-entered via proxy) call that reverts → `LookupCall` with `failed = true`.
- Successful call(s) whose state must be force-reverted at the protocol layer → `revertSpan > 0`.

---

## ExpectedL1ToL2Call (L2: `ExpectedOutgoingCrossChainCall`)

```solidity
struct ExpectedL1ToL2Call {
    bytes32 crossChainCallHash;   // hash of the reentrant call
    uint256 callCount;    // iterations to process from entry.l2ToL1Calls[] inside this reentrant frame
    bytes   returnData;   // pre-computed return value (must succeed)
}
```

L2's `ExpectedOutgoingCrossChainCall` (`IEEZL2.sol`) is field-for-field identical; only the struct name differs (its `callCount` slices `incomingCalls[]`).

When a destination contract called by the processor calls back into a proxy (e.g., contract D on L2 calls C's proxy on L2 to reach C on L1), `executeCrossChainCall` detects `_insideExecution() == true` and routes to `_consumeNestedAction`:

1. `idx = _lastL1ToL2CallConsumed` (L2: `_lastOutgoingCallConsumed`) — sequential, no search.
2. If `expectedL1ToL2Calls[idx].crossChainCallHash == computedHash`, advance the cursor (L1 advances only on this match; L2 post-increments and the bump rolls back with any fall-through revert). On a miss, scan the entry's `expectedLookups` for a `failed = true` `ExpectedLookup` at the current 4-tuple key (resolved via `_executeRevertedNestedLookup`, which always reverts); with no match anywhere, L1 sets the deferred-revert flag `_l1ToL2CallNotFound`, emits `L1ToL2CallNotFound`, and returns empty bytes (the entry reverts `ExecutionNotFound` at its boundary), while L2 reverts `ExecutionNotFound` immediately.
3. Hash `NESTED_BEGIN` into `_rollingHash`.
4. Recursively call `_processNCalls(nested.callCount)` — these calls come from the same flat `entry.l2ToL1Calls[]` (L2: `incomingCalls[]`) array, sharing the global call cursor.
5. Hash `NESTED_END` into `_rollingHash`.
6. Return `nested.returnData` to the destination contract.

### All expected reentrant calls must succeed

An `ExpectedL1ToL2Call` represents a successful reentrant call. If a reentrant call **must revert**, it cannot be expressed as an `ExpectedL1ToL2Call` — the failed call would `revert` inside the proxy, which rolls back the consumption index `tstore`, leaving the protocol unable to distinguish "the call was attempted and failed" from "the call never happened".

Build reverting reentrant calls as nested `ExpectedLookup`s with `failed = true` inside the entry's `expectedLookups[]` instead. They are content-addressed by `(crossChainCallHash, l2ToL1CallNumber, lastL1ToL2CallConsumed, executingLookupIndex)` (L2: `(crossChainCallHash, callNumber, lastOutgoingCallConsumed, executingLookupIndex)`), so the revert is executed without disturbing the consumption cursor — and only from the entry that carries it.

### `callCount` accounting

Calls in `entry.l2ToL1Calls[]` are read sequentially. The sum of all `callCount` values (entry-level plus all reentrant frames) **must equal** `entry.l2ToL1Calls.length`. The contract enforces this at the end of the entry:

- `_currentL2ToL1Call == entry.l2ToL1Calls.length` else revert `UnconsumedL2ToL1Calls`
- `_lastL1ToL2CallConsumed == entry.expectedL1ToL2Calls.length` else revert `UnconsumedL1ToL2Calls`

(L2 mirrors: `_currentIncomingCall == entry.incomingCalls.length` else `UnconsumedIncomingCalls`; `_lastOutgoingCallConsumed == entry.expectedOutgoingCalls.length` else `UnconsumedOutgoingCalls`.)

---

## Lookups (`ExpectedLookup` nested / `LookupCall` top-level)

Two structs in two homes (full spec: `LOOKUP_SPEC.md`):

```solidity
// NESTED — lives INSIDE the entry: ExecutionEntry.expectedLookups[]
// (L1 names; L2 mirrors with callNumber / lastOutgoingCallConsumed / incomingCalls / expectedOutgoingCalls)
struct ExpectedLookup {
    bytes32              crossChainCallHash;
    bytes                returnData;
    bool                 failed;                  // if true, lookup reverts with returnData
    uint64               l2ToL1CallNumber;        // _currentL2ToL1Call at lookup time
    uint64               lastL1ToL2CallConsumed;  // _lastL1ToL2CallConsumed at lookup time
    uint64               executingLookupIndex;    // 0 = host level; k = inside the sub-execution of expectedLookups[k-1]
    L2ToL1Call[]         l2ToL1Calls;             // sub-calls: STATICCALL in static mode or real calls (reverted mode)
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;     // reverted-mode reentrant table (empty for static mode)
    uint256              callCount;               // reverted-mode top-level iterations (0 for static mode)
    bytes32              rollingHash;             // expected hash of the executed sub-calls (verified)
}

// TOP-LEVEL — lives in the storage pool (batch.l1ToL2lookupCalls → _transientLookupCalls /
// per-rollup lookupQueue; L2: lookupCalls). Consumable ONLY when !_insideExecution().
struct LookupCall {
    bytes32              crossChainCallHash;
    uint256              destinationRollupId;     // L1 only — lookupQueue this is published under
    bytes                returnData;
    bool                 failed;
    L2ToL1Call[]         l2ToL1Calls;
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;
    ExpectedLookup[]     expectedLookups;         // reverted-mode nested lookups for the sub-execution
    uint256              callCount;
    bytes32              rollingHash;
    ExpectedStateRootPerRollup[] expectedStateRoots; // L1 only — state-root pins, part of the MATCH
}
```

Both have two modes, split on `failed`:
- **Static (`failed == false`)** — a read-only call resolved via `staticCallLookup` → `_resolveStaticLookup`; the sub-calls (if any) run via STATICCALL and the untagged hash is checked against `rollingHash` (always compared — an empty array must match `rollingHash == 0`).
- **Failed (`failed == true`)** — a reverting call executed as a mini-entry (`_executeRevertedNestedLookup` for nested, `_executeRevertedTopLevelLookup` for top-level): `l2ToL1Calls[]` run as real calls, `expectedL1ToL2Calls[]` supply reentry, deeper lookups come from the active host table, checked like an entry — then it reverts with `returnData` (the terminal revert rolls the sub-execution's state back).

### Disambiguation by phase (nested lookups)

A single entry can issue several lookups with the same `crossChainCallHash` at different points in its execution. The nested key identifies the phase:

- `l2ToL1CallNumber = _currentL2ToL1Call` (the 1-indexed global call counter)
- `lastL1ToL2CallConsumed = _lastL1ToL2CallConsumed`
- `executingLookupIndex` = the live execution context (`0` at host level; `k` inside the sub-execution of `expectedLookups[k-1]`)

(L2: `callNumber = _currentIncomingCall`, `lastOutgoingCallConsumed = _lastOutgoingCallConsumed`, same `executingLookupIndex`.)

The coordinates advance monotonically through a context, and `executingLookupIndex` binds the context itself — an enforced check, so the old "keep keys collision-free across contexts" prover convention is now on-chain. The builder records these values at the exact moment each lookup is observed in simulation. Top-level lookups need none of this: their context is "outside any execution", and (L1) `expectedStateRoots[]` pins them to the trajectory point instead.

### When to use which structure

| Situation | Use |
|---|---|
| Reentrant cross-chain call that **succeeds** | `ExpectedL1ToL2Call` |
| Reentrant cross-chain call that **reverts** (caller catches with try/catch) | Nested `ExpectedLookup` with `failed = true` (inside the entry) |
| Reentrant cross-chain `STATICCALL` (read-only) | Nested `ExpectedLookup` with `failed = false` (inside the entry) |
| Top-level static read | Top-level `LookupCall` in the pool |
| Top-level cross-chain call that naturally reverts | Top-level `LookupCall` with `failed = true` in the pool (via `_tryRevertedTopLevelLookup`); or place the call inside `l2ToL1Calls[]` / `incomingCalls[]` with `revertSpan = 0` and let `CALL_END(false, retData)` capture it |
| Successful call(s) whose state must be force-reverted | `revertSpan > 0` on the first call of the span (e.g. cross-chain forced revert) |

**How the manager picks** (for a reentrant call that hits `executeCrossChainCall`):

1. If the proxy is in a real STATICCALL frame (its `tstore` self-check reverts), the proxy routes to `staticCallLookup`, which scans the active host's `expectedLookups` for the 4-tuple match — both `failed=true` and `failed=false` are valid here.
2. Otherwise (normal CALL frame), the proxy routes to `executeCrossChainCall` → `_consumeNestedAction`:
   - If `expectedL1ToL2Calls[_lastL1ToL2CallConsumed].crossChainCallHash == crossChainCallHash` → consume the `ExpectedL1ToL2Call` (priority).
   - Otherwise scan the host's `expectedLookups` for a `failed=true` 4-tuple match → `_executeRevertedNestedLookup` runs any sub-execution, then reverts with the cached `returnData`. The destination's `try/catch` catches it.
   - No match → L1 sets the deferred-revert flag `_l1ToL2CallNotFound` and returns empty bytes (the entry reverts `ExecutionNotFound` at its boundary); L2 reverts `ExecutionNotFound` immediately.

This means a reverting reentrant call inside try/catch needs **only** a nested `ExpectedLookup` with `failed=true` — no companion `ExpectedL1ToL2Call`, no `revertSpan` wrapper. The cursor is not advanced for that call, and the sub-execution's terminal revert rolls back any sub-call state.

---

## State Deltas (L1 only)

`StateDelta` exists only in `IEEZ.sol` — the L2 entry struct has no `stateDeltas` field.

```solidity
struct StateDelta {
    uint256 rollupId;       // which rollup's state changes
    bytes32 currentState;   // expected pre-state root on rollupId — checked against rollups[rid].stateRoot
    bytes32 newState;       // post-execution state root
    int256  etherDelta;     // signed ETH change for this rollup
}
```

`currentState` is checked at consumption time against `rollups[delta.rollupId].stateRoot`; mismatch reverts `StateRootMismatch`. This is the per-rollup-queue model's soundness backstop: entries are content-addressed against the trajectory the proof committed to, so consumption interleaved across rollups can't quietly land an entry whose preconditions don't hold. A stale builder either fails proof verification (the proof binds to the recorded `currentState`) or fails the on-chain match at consumption.

**Prover obligation.** The `stateDeltas` attached to an entry must be the entry's true state transition — the proof is what makes them correct. In addition, every entry must carry **at least one** `StateDelta`: the prover must assert `stateDeltas.length >= 1` for every entry it emits. An empty `stateDeltas[]` is not rejected on-chain, but it leaves the entry unpinned from any rollup trajectory (nothing for the `StateRootMismatch` backstop to check), so the prover must never produce one.

### Ether bridging (`etherDelta`)

`etherDelta` is signed:
- **Positive**: the rollup gains ETH (deposit / bridged-in)
- **Negative**: the rollup loses ETH (withdrawal / bridged-out)
- **Zero**: no change

Per-entry on L1, the contract verifies:

```
totalEtherDelta == entryEtherIn - etherOut
```

where `entryEtherIn` (the transient `_entryEtherIn` accumulator) is ALL `msg.value` received via `executeCrossChainCall` during the entry — the entry-point call's value plus every reentrant call's (`0` for `executeL2TX` and immediate entries unless reentrant receipts occur) — and `etherOut` is the sum of `value` of every **successful** call processed (failed calls' ETH never leaves the manager). Calls inside a `revertSpan` count toward **neither** side: the span's revert rolls back their ETH transfers, and the span-local accumulators are discarded with the frame — even though the rolling hash still records the calls as successful.

L2 has no ether accounting — `executeCrossChainCall` immediately forwards `msg.value` to `SYSTEM_ADDRESS`.

---

## Rolling Hash

A single `bytes32 rollingHash` per entry covers every call result and every nesting boundary. The accumulator starts at `bytes32(0)` and is updated at four tagged events:

```
CALL_BEGIN   = 1   keccak256(prev, 0x01, callNumber)
CALL_END     = 2   keccak256(prev, 0x02, callNumber, success, returnData)
NESTED_BEGIN = 3   keccak256(prev, 0x03, nestedNumber)
NESTED_END   = 4   keccak256(prev, 0x04, nestedNumber)
```

After all calls complete (L1, `_applyAndExecute`):

```solidity
if (_l1ToL2CallNotFound) revert ExecutionNotFound();        // deferred no-match flag (L1 only)
if (_rollingHash != rollingHash) revert RollingHashMismatch();
if (_currentL2ToL1Call != entry.l2ToL1Calls.length) revert UnconsumedL2ToL1Calls();
if (_lastL1ToL2CallConsumed != entry.expectedL1ToL2Calls.length) revert UnconsumedL1ToL2Calls();
if (totalEtherDelta != entryEtherIn - etherOut) revert EtherDeltaMismatch();  // L1 only
```

L2 runs the same checks with its own names (`_currentIncomingCall` / `UnconsumedIncomingCalls`, `_lastOutgoingCallConsumed` / `UnconsumedOutgoingCalls`) and has no deferred flag or ether check.

A single mismatch anywhere in the execution tree changes the final hash — this catches wrong return data, wrong success/failure flags, missing or extra calls, and incorrect nesting structure with one comparison.

For the full hash chain semantics (with worked example and multi-phase static-call disambiguation), see `CORE_PROTOCOL_SPEC.md` §E.

---

## Transaction Model

### Per-block structure

Each block has at most:
1. **Setup tx**: `postAndVerifyBatch` (L1) or `loadExecutionTable` (L2) — loads the execution table.
2. **Execution tx(s)**: One per cross-chain interaction that consumes entries.

On L1, `postAndVerifyBatch` itself can run user-driven cross-chain calls inline via the **meta hook** (see below) — those don't need a separate execution tx.

### transient / deferred split (L1 `postAndVerifyBatch`)

`postAndVerifyBatch` takes a single `ProofSystemBatchPerVerificationEntries calldata batch` argument (NOT an array). The batch carries `entries[]`, `l1ToL2lookupCalls[]`, `transientExecutionEntryCount`, `transientLookupCallCount`, `proofSystems[]` (sorted asc), `rollupIdsWithProofSystems[]` (strictly ascending by `rollupId`, each row carrying a `proofSystemIndex[]` of indices into `proofSystems[]`), `blobIndices[]`, `callData`, `proofs[]` (one per PS), and `blockNumber` (the single L1 block the batch binds to; `0` = no block context, `type(uint64).max` = latest). See `MULTI_PROVER_SPEC.md` for the full struct shape and proof-public-inputs construction.

Flow:

1. **Reentry check** — revert `PostBatchReentry` if `_transientExecutions.length != 0`.
2. **Structural validation** via `_validateStructure(batch)`: sorted `proofSystems[]`, strictly-ascending `rollupIdsWithProofSystems[].rollupId` (and `rollupId > MAINNET_ROLLUP_ID`), each rollup registered, each row's `proofSystemIndex[]` strictly ascending and in range, entry/stateDelta/lookupCall rollup ids ∈ batch's rollup set, transient prefix bounds.
3. **Fetch vkMatrix + verify**: `_fetchVkMatrix` calls each rollup's manager via `IRollupContract.checkProofSystemsAndGetVkeys(subset)` (manager enforces threshold internally and reverts if not met). Then `_verifyProofSystemBatch` builds `sharedPublicInput` plus per-PS `acc_k` (folding each rollup's `(blockHash, timestamp)` fetched via `getTimestampAndBlockHash(batch.blockNumber)`) and calls `IProofSystem.verify(proofs[k], publicInputsHash[k])` for each PS. All proofs must verify atomically.
4. **Mark verified-this-block** (`_markVerifiedBlockPerRollup(rid)`): wipes the rollup's `executionQueue` / `lookupQueue` and resets `executionQueueIndex` on **every** verify — a same-block re-verify REPLACES (does not append to) the prior batch's entries. Sets the read gate for `executeCrossChainCall` / `executeL2TX(rollupId)` (`lastVerifiedBlock(rid) == block.number`).
5. **Load transient stream** (`_loadTransientExecutions`): copy `entries[0..transientExecutionEntryCount)` into `_transientExecutions` and `l1ToL2lookupCalls[0..transientLookupCallCount)` into `_transientLookupCalls`.
6. **Drain leading immediate entries inline**: while `_transientExecutions[idx].proxyEntryHash == 0`, self-call `try this.attemptApplyImmediate(idx) catch { emit ImmediateEntrySkipped(idx, revertData); }` and advance — not a hard error.
7. **Meta hook**: if `_transientExecutionIndex < _transientExecutions.length` AND `msg.sender.code.length > 0`, call `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()`. The hook can invoke `executeCrossChainCall` / `executeL2TX(rollupId)` to consume the rest of the transient stream.
8. **Cleanup transient tables**, then `_publishRemainderExecutions(batch)` (**unconditionally** — even if the meta hook left transient entries unconsumed — pushes `entries[transientExecutionEntryCount..]` to `verificationByRollup[entry.destinationRollupId].executionQueue` and `l1ToL2lookupCalls[transientLookupCallCount..]` to the corresponding `lookupQueue`), then `emit BatchPosted(batch.rollupIdsWithProofSystems.length)`. Soundness backstop: each entry's `StateDelta.currentState` is checked at consumption time, so dropped transient leftover doesn't poison persistent consumers — they fail their own state-root check if they depended on it.

A batch with `transientExecutionEntryCount == 0` means no immediate execution and no meta-hook consumption — all entries flow straight to per-rollup queues.

### 1-to-1 rule

Each user action produces **exactly 1 execution transaction per chain involved**:

- **L1→L2**: User calls a proxy on L1 → `executeCrossChainCall` (1 tx on L1). The system delivers it on L2 via `executeIncomingCrossChainCall` (system-only; atomically loads the table and consumes `entries[0]`) — 1 tx on L2. Reentrant calls are folded into the same tx via `expectedL1ToL2Calls[]` (L2: `expectedOutgoingCalls[]`).
- **L2→L1**: User submits an L2 transaction → on L1 the immediate entry is consumed inline by `postAndVerifyBatch` or via `executeL2TX` (1 tx on L1). The L2 user tx itself is the consumption on L2 (no separate setup tx needed beyond `loadExecutionTable`).

Never split a single cross-chain interaction into multiple execution transactions on the same chain.

---

## Flow Patterns

In the diagrams below, "MAINNET" means rollupId 0 (L1) and "L2" means whichever rollup ID the L2 chain has registered with the `EEZ` registry.

### L1→L2 (simple)

Alice on L1 calls a contract on L2. The proxy for B on L1 forwards Alice's call to L1's `EEZ.executeCrossChainCall` (consuming entry [0]). The L2 system later delivers the call on L2 via `executeIncomingCrossChainCall`.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] DEFERRED
    proxyEntryHash = hash(rollupId=L2, dest=B, value=v, data=calldata, src=Alice, srcRollup=MAINNET)
    destinationRollupId = L2   // routes into verificationByRollup[L2].executionQueue
    l2ToL1Calls = [{ dest=B, value=v, data=calldata, src=Alice, srcRollup=MAINNET, revertSpan=0 }]
    expectedL1ToL2Calls = []
    callCount   = 1
    returnData  = <B's return>     // pre-computed by the prover
    rollingHash = H(CALL_BEGIN(1) → CALL_END(1, true, <B's return>))
    stateDeltas = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=v? } ]   // L2 state moved
```

(An immediate entry for the initial state commitment can also live in the same batch as `entries[0]` with `proxyEntryHash == 0`.)

**L2 execution table** (loaded atomically by `executeIncomingCrossChainCall`):
```
[0] proxyEntryHash = hash(rollupId=L2, dest=B, value=v, data=calldata, src=Alice, srcRollup=MAINNET)
    // same hash as the L1 entry — executeIncomingCrossChainCall recomputes it from its
    // explicit params and reverts EntryHashMismatch on divergence
    incomingCalls = [{ dest=B, value=v, data=calldata, src=Alice, srcRollup=MAINNET, revertSpan=0 }]
    expectedOutgoingCalls = []
    callCount   = 1
    returnData  = <B's return on L2>
    rollingHash = H(CALL_BEGIN(1) → CALL_END(1, true, <B's return on L2>))
    // no stateDeltas / destinationRollupId — the L2 struct has neither field
```

**Execution**:
- **L1**: Alice calls the proxy for B → `executeCrossChainCall(Alice, calldata)` → `_consumeAndExecute` consumes entry [0] → routes through Alice's proxy → returns `<B's return>`.
- **L2**: System submits a tx that calls `executeIncomingCrossChainCall(B, v, calldata, Alice, MAINNET, entries, lookupCalls)` → atomically replaces the table, checks `entries[0].proxyEntryHash`, and drives the flat call processor → B executes on L2 via Alice's proxy.

### L2→L1 (simple)

Alice on L2 calls a contract on L1.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] IMMEDIATE   proxyEntryHash = bytes32(0)
    destinationRollupId = L2   // must reference a rollup in the batch (MAINNET/0 is never in a
                               // batch — _validateStructure rejects it); immediate entries
                               // inline-execute on L1 regardless of this field
    l2ToL1Calls = [{ dest=C, value=0, data=calldata, src=D, srcRollup=L2, revertSpan=0 }]
    expectedL1ToL2Calls = []
    callCount   = 1
    returnData  = ""
    rollingHash = H(CALL_BEGIN(1) → CALL_END(1, true, <C's return>))
    stateDeltas = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=0 } ]
```

(Often the immediate entry on L1 is `entries[0]` with `transientExecutionEntryCount = 1`, executed inline by `postAndVerifyBatch`.)

**L2 execution table** (`loadExecutionTable`):
```
[0] DEFERRED
    proxyEntryHash = hash(rollupId=MAINNET, dest=C, value=0, data=calldata, src=D, srcRollup=L2)
    incomingCalls = [{ dest=C, value=0, data=calldata, src=D, srcRollup=L2, revertSpan=0 }]
    expectedOutgoingCalls = []
    callCount   = 1
    returnData  = <C's return>
    rollingHash = H(CALL_BEGIN(1) → CALL_END(1, true, <C's return>))
```

**Execution**:
- **L2**: Alice's L2 tx calls D, D calls the proxy for C on L2 → `executeCrossChainCall(D, calldata)` → consumes entry [0] → returns `<C's return>` to D.
- **L1**: `postAndVerifyBatch` runs entry [0] as the immediate entry (or via the meta hook) — the call routes through D's auto-created proxy on L1, executes C, and matches the rolling hash.

### L1→L2→L1 (reentrant L2→L1 inside an L1→L2 call)

Alice on L1 calls D's proxy on L1 (D lives on L2). D, while executing on L2, calls C's proxy on L2 (C lives on L1).

**L1 execution table** (`postAndVerifyBatch`):
```
[0] DEFERRED
    proxyEntryHash       = hash(rollupId=L2, dest=D, value=0, data=incrementProxy, src=Alice, srcRollup=MAINNET)
    destinationRollupId = L2
    l2ToL1Calls   = [
      { dest=D, value=0, data=incrementProxy, src=Alice, srcRollup=MAINNET, revertSpan=0 },  // calls[0] entry-level
      { dest=C, value=0, data=increment,      src=D,     srcRollup=L2,      revertSpan=0 },  // calls[1] inside reentrant frame
    ]
    expectedL1ToL2Calls = [ { crossChainCallHash=hash(MAINNET, C, 0, increment, D, L2), callCount=1, returnData=abi.encode(1) } ]
    callCount     = 1   // only calls[0] is entry-level; calls[1] is consumed by the reentrant frame
    returnData    = <D's return on L2>
    rollingHash   = H( CALL_BEGIN(1) → NESTED_BEGIN(1) → CALL_BEGIN(2) → CALL_END(2, true, abi.encode(1)) → NESTED_END(1) → CALL_END(1, true, <D's return>) )
    stateDeltas   = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=0 } ]
```

**L2 execution table** (loaded atomically by `executeIncomingCrossChainCall`):
```
[0] proxyEntryHash = hash(rollupId=L2, dest=D, value=0, data=incrementProxy, src=Alice, srcRollup=MAINNET)
    incomingCalls = [
      { dest=D, value=0, data=incrementProxy, src=Alice, srcRollup=MAINNET, revertSpan=0 },
      { dest=C, value=0, data=increment,      src=D,     srcRollup=L2,      revertSpan=0 },
    ]
    expectedOutgoingCalls = [ { crossChainCallHash=hash(MAINNET, C, 0, increment, D, L2), callCount=1, returnData=abi.encode(1) } ]
    callCount     = 1
    returnData    = <D's return>
    rollingHash   = (same hash chain as L1 — both chains observe the same call/nesting structure)
```

**Execution**:
- **L1**: Alice → D's proxy → `executeCrossChainCall(Alice, incrementProxy)` → consumes entry [0]. The processor routes calls[0] through Alice's proxy → Alice's proxy on L1 calls D's address (the *real* D doesn't live here; this is the L1 representation). When D's logic on L1 calls C's proxy → `executeCrossChainCall(D, increment)` → `_insideExecution() == true` → consumes `expectedL1ToL2Calls[0]` → processes calls[1] (real C executes) → returns `abi.encode(1)`. D's L1 stub returns `<D's return>`.
- **L2**: System tx → `executeIncomingCrossChainCall(D, 0, incrementProxy, Alice, MAINNET, entries, lookupCalls)` → atomically loads the table and drives entry [0]. Same call flow, but real D executes here and the C call routes through D's proxy on L2 — the manager intercepts at the same slot, `expectedOutgoingCalls[0]`.

### L2→L1→L2 (reentrant L1→L2 inside an L2→L1 call)

Alice on L2 calls A's proxy on L2 (A lives on L1). A, while executing on L1, calls B's proxy on L1 (B lives on L2).

**L1 execution table** (`postAndVerifyBatch`):
```
[0] IMMEDIATE   proxyEntryHash = bytes32(0)
    destinationRollupId = L2   // must reference a rollup in the batch; inline-executes regardless
    l2ToL1Calls   = [
      { dest=A, value=0, data=callBProxy,     src=Alice, srcRollup=L2,      revertSpan=0 },  // calls[0]
      { dest=B, value=0, data=increment,      src=A,     srcRollup=MAINNET, revertSpan=0 },  // calls[1]
    ]
    expectedL1ToL2Calls = [ { crossChainCallHash=hash(L2, B, 0, increment, A, MAINNET), callCount=1, returnData=abi.encode(1) } ]
    callCount     = 1
    returnData    = ""
    rollingHash   = H( CALL_BEGIN(1) → NESTED_BEGIN(1) → CALL_BEGIN(2) → CALL_END(2, true, abi.encode(1)) → NESTED_END(1) → CALL_END(1, true, <A's return>) )
    stateDeltas   = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=0 } ]
```

**L2 execution table** (`loadExecutionTable`):
```
[0] DEFERRED
    proxyEntryHash = hash(rollupId=MAINNET, dest=A, value=0, data=callBProxy, src=Alice, srcRollup=L2)
    incomingCalls = [ same two calls as L1, in the same order ]
    expectedOutgoingCalls = [ same expected reentrant call ]
    callCount     = 1
    returnData    = <A's return>
    rollingHash   = (same hash chain)
```

**Execution**:
- **L2**: Alice's L2 tx → A's proxy → `executeCrossChainCall(Alice, callBProxy)` → consumes entry [0]. The manager routes calls[0] through Alice's proxy (A's L2 stub executes), and when the L2 stub calls B's proxy → `executeCrossChainCall(A, increment)` → `_insideExecution() == true` → consumes `expectedOutgoingCalls[0]` → processes calls[1] (B executes on L2).
- **L1**: `postAndVerifyBatch` runs entry [0] as the immediate entry (or via meta hook). Same call flow, but real A executes on L1 and B's call goes through the same reentrant path (`expectedL1ToL2Calls[0]`).

### Forced revert via `revertSpan`

When a chain's prover output marks a cross-chain call as reverted even though the destination call would succeed, the protocol uses `revertSpan` to delineate the contiguous run of calls whose **state effects** must be rolled back. The rolling hash still records the calls' real outcomes (typically `success=true`); only the EVM state changes are discarded.

Example: SCA on L2 calls SCB which makes a successful cross-chain call to Counter on L1, then SCA reverts. From L1's perspective Counter.increment() ran cleanly, but L2's prover output says the higher-level transaction was rolled back, so L1 must not retain the state change.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] IMMEDIATE   proxyEntryHash = bytes32(0)
    destinationRollupId = L2   // must reference a rollup in the batch; inline-executes regardless
    l2ToL1Calls   = [
      // The cross-chain call to Counter is wrapped in a revert span of length 1:
      { dest=Counter, value=0, data=increment, src=SCB, srcRollup=L2, revertSpan=1 },
    ]
    expectedL1ToL2Calls = []
    callCount     = 1
    returnData    = ""
    rollingHash   = H( CALL_BEGIN(1) → CALL_END(1, true, abi.encode(1)) )
    // The hash chain still includes Counter's success — `revertSpan` rolls back state, not the rolling hash.
    stateDeltas   = [ ... ]   // any net L2-state delta that survives the revert (e.g. parent rollup committed nothing)
```

**Mechanism**: when the processor sees `calls[0].revertSpan == 1`, it self-calls `executeInContextAndRevert(1)`, which processes one call (Counter.increment) and then reverts with `ContextResult`. The revert undoes Counter's effects on L1, but the `ContextResult` payload carries the `_rollingHash` value computed inside the span back out — so the entry-level hash check still observes Counter's success contribution.

A single mechanism handles atomic rollback: there are no continuation entries to look up and no per-rollup state-root restoration calls.

### Failed inner call via a nested `ExpectedLookup`

When a reentrant cross-chain call **must revert** (e.g., the destination wraps the call in `try/catch`), it cannot be an `ExpectedL1ToL2Call`. Use a nested `ExpectedLookup` with `failed = true` INSIDE the entry instead:

**`entry.expectedLookups`** of the consuming entry (entry-scoped — never in `l1ToL2lookupCalls`):
```
[0] ExpectedLookup {
    crossChainCallHash     = hash(rollupId=L2, dest=B, value=0, data=increment, src=D, srcRollup=MAINNET),
    returnData             = <revert reason>,
    failed                 = true,
    l2ToL1CallNumber       = 1,    // the entry-level call that triggered B
    lastL1ToL2CallConsumed = 0,    // before any ExpectedL1ToL2Call was consumed
    executingLookupIndex   = 0,    // fired at entry level (not inside a sub-execution)
    l2ToL1Calls            = [],
    expectedL1ToL2Calls    = [],
    callCount              = 0,    // no sub-execution to run
    rollingHash            = bytes32(0),
}
```

When B's proxy is called from inside D's execution (a normal CALL frame), the call routes to `executeCrossChainCall` → `_consumeNestedAction`. No `ExpectedL1ToL2Call` matches, so the manager scans the entry's `expectedLookups`, matches by `(crossChainCallHash, l2ToL1CallNumber=1, lastL1ToL2CallConsumed=0, executingLookupIndex=0)`, and `_executeRevertedNestedLookup` reverts with the cached revert reason (here with no sub-execution, since `callCount = 0`). D catches the revert and continues.

### Same action twice (sequential)

When the same proxy call happens N times in a single transaction (e.g., a contract calling B's proxy twice in a row), each call consumes the next entry in the table — there is no special handling. Each entry has the same `crossChainCallHash`; sequential indexing differentiates them.

```
[0] DEFERRED   proxyEntryHash = hash(B, ...) ... returnData = <first return>
[1] DEFERRED   proxyEntryHash = hash(B, ...) ... returnData = <second return>
```

The destination rollup's `executionQueueIndex` advances from 0 → 1 → 2; the second call to B's proxy lands at `verificationByRollup[B's rollupId].executionQueue[1]`. The hash check `entry.proxyEntryHash == crossChainCallHash` succeeds because both entries were built with the same hash.

### Continuation pattern (sequential entries within a flow)

A single user action that performs multiple top-level cross-chain calls produces multiple entries. Each top-level entry-point call consumes one entry. There is no `nextAction` redirection — the user's contract makes each call explicitly, and the table has one entry per top-level call.

For sub-calls **within** a single entry (e.g., a contract on the destination side that performs several proxy calls), all those sub-calls live in `entry.l2ToL1Calls[]` (L2: `entry.incomingCalls[]`) and either count toward `entry.callCount` (entry-level) or toward an `ExpectedL1ToL2Call`'s (L2: `ExpectedOutgoingCrossChainCall`'s) `callCount`.

---

## L1 vs L2 Entries

| Aspect | L1 (`EEZ`) | L2 (`EEZL2`) |
|---|---|---|
| **How loaded** | `postAndVerifyBatch(ProofSystemBatchPerVerificationEntries calldata batch)` — single struct (not array) carrying `entries[]`, `l1ToL2lookupCalls[]`, `transientExecutionEntryCount`, `transientLookupCallCount`, `proofSystems[]`, `rollupIdsWithProofSystems[]`, `blobIndices[]`, `callData`, `proofs[]`, `blockNumber` | `loadExecutionTable(entries, _lookupCalls)` by `SYSTEM_ADDRESS`; OR `executeIncomingCrossChainCall(...)` for inbound delivery from another rollup (system-only, atomically loads + executes `entries[0]`) |
| **State deltas** | Required for entries that touch rollup state; `delta.currentState` checked against `rollups[id].stateRoot` (mismatch reverts `StateRootMismatch`); `etherDelta` accounted | No `stateDeltas` field at all — the L2 entry struct omits it (no rollup state on L2) |
| **Matching logic** | Per-rollup `verificationByRollup[rid].executionQueueIndex++` (routing rollup = proxy's `originalRollupId` / the `executeL2TX` arg); entry's `proxyEntryHash` must equal the expected hash — no separate `destinationRollupId` check at consumption (the proof binds it into the entry hash, and the call hash already commits to the target rollup) | Sequential `executionIndex` over a single `executions` table. Top-level lookup matching is by `crossChainCallHash` alone (the L2 `LookupCall` has no `destinationRollupId` / `expectedStateRoots`). |
| **Top-level reverted-lookup fallback** | `_tryRevertedTopLevelLookup(crossChainCallHash, destRid)` scans transient table + persistent `lookupQueue` for a `failed` lookup matching `crossChainCallHash` with live state-root pins | `_tryRevertedTopLevelLookup(crossChainCallHash)` scans persistent `lookupCalls` for a `failed` lookup matching `crossChainCallHash` (no transient on L2) |
| **Ether accounting** | Per-entry `etherIn - etherOut == sum(etherDelta)` | None; `msg.value` is forwarded to `SYSTEM_ADDRESS` |
| **Same action hash** | Each occurrence consumes the next entry on the destination rollup's queue; sequential ordering distinguishes them | Same |
| **Transient/deferred split** | `_transientExecutions` + `_transientLookupCalls` populated from the batch's leading prefix; meta hook consumes them; remainder published to per-rollup queues **unconditionally** (soundness via `StateDelta.currentState` check) | No transient table — all entries go directly to `executions` |
| **Meta hook** | `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` if transient stream not yet drained AND `msg.sender` has code | Not present |
| **Immediate entry** | Leading transient entries with `proxyEntryHash == 0` run inline during `postAndVerifyBatch` via `attemptApplyImmediate` (try/catch); failed self-call emits `ImmediateEntrySkipped` and continues | Not expressible — no consumption path matches `proxyEntryHash == 0` on L2. Inbound work arrives via `executeIncomingCrossChainCall` (non-zero `proxyEntryHash`); locally-initiated work is consumed by the user's own tx through a proxy |
| **`executeL2TX`** | `executeL2TX(uint256 rollupId)` — permissionless; consumes the next entry on `rollupId`'s queue, which must have `proxyEntryHash == 0` | Not present (L2 has no `executeL2TX` entry point) |
| **Inbound system-only call** | Not present | `executeIncomingCrossChainCall(destination, value, data, sourceAddress, sourceRollup, entries, _lookupCalls)` — `onlySystemAddress`, strict `msg.value == value`, atomically replaces the execution table and consumes `entries[0]`, emits `IncomingCrossChainCallExecuted`, returns `executions[0].returnData` |

### Atomicity via Solidity revert

If the calling contract reverts at the Solidity level (e.g., `require()` failure) while inside `executeCrossChainCall` or `executeL2TX`, the entire EVM transaction reverts — the per-rollup cursor bump, all transient writes, all state delta applications, everything rolls back. This is **different** from the protocol's `revertSpan` mechanism, which selectively rolls back the inner span while propagating the rolling hash and counters across the boundary.

Use Solidity revert for top-level failures (whole-transaction abort). Use `revertSpan` for inner spans whose state must be rolled back while the outer execution continues.

---

## Don'ts

### Never feed a reverting reentrant call into `expectedL1ToL2Calls`

An `ExpectedL1ToL2Call` represents a successful call. A reverting reentrant call cannot be expressed as an `ExpectedL1ToL2Call` — the failed call's revert rolls back the consumption index, leaving the protocol unable to distinguish "attempted and failed" from "never happened". Use `LookupCall` with `failed = true` instead.

### Never split nested calls into separate transactions

If a cross-chain flow involves reentrant calls (e.g., L1→L2→L1), all sub-calls are folded into the entry's flat `l2ToL1Calls[]` and `expectedL1ToL2Calls[]` (L2: `incomingCalls[]` / `expectedOutgoingCalls[]`). The whole entry resolves in **one transaction per chain**, not multiple separate transactions.

Wrong:
```
TX1 on L1: Alice → proxy → executeCrossChainCall (CALL into L2's space)
TX2 on L1: system → executeCrossChainCall (reentrant CALL back from L2)  ← WRONG: separate tx
```

Right:
```
TX1 on L1: Alice → proxy → executeCrossChainCall
  → consumes one entry whose l2ToL1Calls[] contains both calls[0] (entry-level) and calls[1] (reentrant)
  → the reentrant call hits the manager via the proxy and consumes expectedL1ToL2Calls[0]
  → all calls resolve within this single tx
```

### Never use `executeL2TX` for L1→L2 flows

`executeL2TX(rollupId)` exists only on L1 and consumes the next entry on that rollup's queue, which must have `proxyEntryHash == 0` — it commits pure L2 transactions (and L2 transactions that touch L1) on L1. For L1→L2 flows, the user's call enters the protocol via `executeCrossChainCall` on the proxy on L1, and the L2 side is delivered by the system via `executeIncomingCrossChainCall`. Don't call `executeL2TX` to start an L1→L2 flow.

### Never call `executeL2TX` while inside a cross-chain execution

`executeL2TX(rollupId)` reverts with `L2TXNotAllowedDuringExecution` if `_insideExecution() == true`. L2TX entries are top-level only; reentrant calls must use the proxy path.

### Consistent rollupId / sourceRollupId semantics

- `targetRollupId` on every action = **target** (where the call executes)
- `sourceRollupId` on every action = **origin** (where the caller lives)
- On L1, top-level calls produced by `executeCrossChainCall` have `sourceRollupId = MAINNET (0)`.
- On L2, top-level calls produced by `executeCrossChainCall` have `sourceRollupId = ROLLUP_ID` (this L2's ID).
- Reentrant calls inside an entry have `sourceRollupId` set to whichever chain the caller lives on — same as for top-level calls; the protocol does not distinguish reentrant from top-level in the hash.

### Don't rely on table ordering for correctness within an entry

`entry.l2ToL1Calls[]` (L2: `entry.incomingCalls[]`) is a flat array consumed via the global call cursor (`_currentL2ToL1Call` / `_currentIncomingCall`) — entry-level and reentrant calls share the same cursor. The semantic structure (which calls belong to which reentrant frame) comes from `expectedL1ToL2Calls[i].callCount` (L2: `expectedOutgoingCalls[i].callCount`), not from positional grouping. The builder must lay out the flat array so the cursor advances correctly through entry-level calls and reentrant frames in execution order.
