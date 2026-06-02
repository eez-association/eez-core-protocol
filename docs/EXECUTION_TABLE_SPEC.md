# Execution Table Specification

How to correctly build execution entries for L1 (`postAndVerifyBatch`) and L2 (`loadExecutionTable`).

The protocol uses a **flat, sequential** execution model: every entry contains a flat array of `L2ToL1Call`s processed in order, with reentrant calls consumed from a parallel `ExpectedL1ToL2Call[]` array and a single `rollingHash` verifying the entire execution tree at the end.

---

## Entry Structure

```solidity
struct ExecutionEntry {
    StateDelta[]           stateDeltas;          // L1 only — state root deltas applied when entry is consumed
    bytes32                proxyEntryHash;       // bytes32(0) = immediate (L2TX or state commitment), else deferred
    uint256                destinationRollupId;  // rollup whose queue this entry routes to (per-rollup queue model)
    L2ToL1Call[]           L2ToL1Calls;          // flat array of ALL calls (entry-level + nested), in execution order
    ExpectedL1ToL2Call[]   expectedL1ToL2Calls;  // flat array of pre-computed reentrant call results
    uint256                callCount;            // entry-level iterations to process from L2ToL1Calls[]
    bytes                  returnData;           // pre-computed return data for the entry's top-level call
    bytes32                rollingHash;          // expected hash after all calls and nestings are processed
}
```

Top-level entries always succeed: `executeCrossChainCall` returns `entry.returnData` regardless of inner-call outcomes. There is no entry-level `failed` flag — reverts at the top level are expressed as a `LookupCall` with `failed = true`, consumed via `staticCallLookup` (static context) or via the failed-reentry fallback in `_consumeNestedAction`. Naturally-reverting inner calls are still expressible: the proxy `.call` returns `(false, retData)` and the rolling hash captures it via `CALL_END`.

### Per-rollup queue routing

`destinationRollupId` selects which rollup's queue this entry is loaded into during `postAndVerifyBatch`'s deferred publish. The central `EEZ` registry stores per-rollup queues (`verificationByRollup[rid].queue` and `verificationByRollup[rid].lookupQueue`) with their own per-rollup `cursor`. Each `postAndVerifyBatch` call carries one `ProofSystemBatchPerVerificationEntries` payload covering one or more rollups; entries are routed by `destinationRollupId` into the matching rollup's queue. Cross-rollup state is independent — a stuck cursor on one rollup does not block another. See `MULTI_PROVER_DESIGN.md` for the multi-prover / per-rollup-queue specifics.

### IMMEDIATE entries (`proxyEntryHash == 0`)

A leading run of the batch's transient stream may have `proxyEntryHash == 0`. Each such entry is executed inline by `postAndVerifyBatch` itself (no proxy call required) and represents the batch's immediate work — pure L2 transactions or L2 transactions that touch L1. State deltas are applied, calls are processed, and the rolling hash is verified, all within `postAndVerifyBatch`. The transient cursor (`_transientExecutionIndex`) advances past each immediate entry before the meta hook fires. If an immediate entry's self-call reverts, the registry emits `ImmediateEntrySkipped(transientIdx, revertData)` and the cursor still advances — it is not a hard error.

### DEFERRED entries (`proxyEntryHash != 0`)

Pushed to `_transientExecutions` (the leading `transientExecutionEntryCount` entries) or to per-rollup `verificationByRollup[rid].queue` (the rest). Consumed in posted order by `executeCrossChainCall` or `executeL2TX(rollupId)`. Each call computes the expected cross-chain call hash from the proxy/call-site context and compares it to the entry at the matching rollup's `cursor` (entry's `proxyEntryHash`); mismatch reverts with `ExecutionNotFound`. Cursor advance is per-rollup.

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
| Reentrant call (consumes `ExpectedL1ToL2Call`) | same as above (proxy on the chain making the reentrant call) | same | same | same | same | same |
| `executeL2TX` | n/a — entry has `proxyEntryHash == 0` | — | — | — | — | — |
| `staticCallLookup` | proxy's `originalRollupId` | proxy's `originalAddress` | `0` (static is value-free) | original calldata | proxy's caller | this chain's rollup ID |

The hash is fully determined by the six fields above; nothing else (caller depth, parent action, position in the entry) feeds into it.

### Cross-chain hash consistency

When the same logical call appears on both chains, the hash is identical on both sides:

- **L1→L2 proxy call** generated by `executeCrossChainCall` on L1 (e.g., user calls D's proxy on L1) has `targetRollupId = L2`, `sourceRollupId = MAINNET (0)`. The same hash is the trigger for L2's entry produced by the corresponding L1 entry's call processor.
- **Reentrant L2→L1 call** generated mid-execution on L2 has `targetRollupId = MAINNET`, `sourceRollupId = L2`. The same hash identifies an `ExpectedL1ToL2Call` slot on L1's entry **and** an `ExpectedL1ToL2Call` slot on L2's entry — both chains observe the same reentrant call from their own perspective.

Identical reentrant calls on both chains always hash identically — the six hash inputs alone determine the hash, with no positional or contextual term mixed in. The builder still must simulate both sides to predict exact `data` (calldata and return data) and `value`.

---

## L2ToL1Call

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

The processor reads `entry.L2ToL1Calls[_currentCallNumber]` from storage and, for each non-revert-span call, derives the `sourceProxy` address from `(sourceAddress, sourceRollupId)`, auto-creates the proxy if it doesn't exist, and routes the call through `CrossChainProxy.executeOnBehalf(targetAddress, data){value: value}`. If the destination call itself reverts, `_processNCalls` captures `(success=false, retData=revertReason)` from the proxy's `.call` and hashes that into `CALL_END` — natural reverts need no special wrapping.

### `revertSpan`: forced-revert context

`revertSpan > 0` is the **forced-revert** mechanism: the next `revertSpan` calls (including this one) execute, succeed, and have their state effects rolled back at the protocol layer. The rolling hash still commits to the calls' real outcomes (typically `success=true` with the captured `returnData`); only the EVM state changes disappear. The processor:

1. Saves `_currentCallNumber`.
2. Zeros `entry.L2ToL1Calls[savedCallNumber].revertSpan` in storage so the inner self-call sees `revertSpan == 0` at the same index and runs the call normally.
3. Self-calls `this.executeInContextAndRevert(revertSpan)` — that function processes the next `revertSpan` calls and **always reverts** with `error ContextResult(bytes32 rollingHash, uint256 lastNestedActionConsumed, uint256 currentCallNumber, bool nestedActionNotFound)`. (The 4th field carries L1's deferred no-match flag out of the reverted span; L2 always sends `false`.)
4. The revert rolls back **all** transient storage modifications inside the self-call (including the `tstore` writes for `_rollingHash`, `_currentCallNumber`, `_lastNestedActionConsumed`) **and** all destination state changes the inner calls produced.
5. The processor decodes `ContextResult` and restores `_rollingHash`, `_lastNestedActionConsumed`, `_currentCallNumber` to the values **observed at the end of the reverted span**, bridging the rolling hash and counters across the revert boundary. On L1 it also OR-merges the decoded `nestedActionNotFound` flag back in, so a no-match observed inside the span still reverts the entry at its boundary.
6. Restores `entry.L2ToL1Calls[savedCallNumber].revertSpan = revertSpan` so the storage layout matches what the proof committed to.

`revertSpan` covers a contiguous run of calls. The first call inside the span has its `revertSpan` field cleared so it executes as a normal call; subsequent calls inside the span have `revertSpan == 0` to begin with. Spans cannot be nested.

#### When `revertSpan` is the right tool

The canonical use is a cross-chain call from rollup A to rollup B where B's destination call **succeeded**, but the prover output marks the call as reverted in A's view of the world (for example, because the higher-level transaction containing the call was rolled back on A). When B replays the entry, `revertSpan = 1` ensures B's state does not retain effects that A no longer commits to.

For natural failures — a destination contract that simply `revert`s — `revertSpan = 0` is correct and simpler:

- The proxy `.call` returns `success=false` with the destination's revert payload as `retData`.
- `CALL_END(false, retData)` is hashed into the rolling hash.
- The destination's own revert rolls back the destination's state.

Wrapping a single naturally-reverting call in `revertSpan = 1` is purely ceremonial — it produces the same rolling hash and the same on-chain state as `revertSpan = 0`, with an extra self-call frame for nothing. The mechanism only earns its cost when state would otherwise survive.

**Reentrant reverted calls take a different path entirely.** When the destination contract called from `_processNCalls` re-enters the manager via a proxy (a try/catch'd cross-chain call to another rollup), reverts of that nested call are expressed as `LookupCall` with `failed = true` — not `revertSpan`, not `ExpectedL1ToL2Call`. `_consumeNestedAction` falls back to the matching `LookupCall` at `(crossChainCallHash, callNumber, lastNestedActionConsumed)` and reverts with the cached `returnData`; the destination's `try/catch` catches it, no cursor is advanced, and the EVM revert has nothing to roll back. See [`LookupCall`](#lookupcall) below for the full lookup mechanics.

Three distinct revert paths, one decision tree:

- Top-level call that naturally reverts → `LookupCall` with `failed = true`, consumed via `staticCallLookup`, the failed-reentry fallback in `_consumeNestedAction`, or the new top-level fallback `_tryRevertedTopLevelLookup`. (Or, when the call lives inside `L2ToL1Calls[]`, place it with `revertSpan = 0` and let `CALL_END(false, retData)` capture it.)
- Reentrant (re-entered via proxy) call that reverts → `LookupCall` with `failed = true`.
- Successful call(s) whose state must be force-reverted at the protocol layer → `revertSpan > 0`.

---

## ExpectedL1ToL2Call

```solidity
struct ExpectedL1ToL2Call {
    bytes32 crossChainCallHash;   // hash of the reentrant call
    uint256 callCount;    // iterations to process from entry.L2ToL1Calls[] inside this nested action
    bytes   returnData;   // pre-computed return value (must succeed)
}
```

When a destination contract called by the processor calls back into a proxy (e.g., contract D on L2 calls C's proxy on L2 to reach C on L1), `executeCrossChainCall` detects `_insideExecution() == true` and routes to `_consumeNestedAction`:

1. `idx = _lastNestedActionConsumed++` (sequential, no search).
2. Verify `entry.expectedL1ToL2Calls[idx].crossChainCallHash == computedHash` — else revert `ExecutionNotFound`.
3. Hash `NESTED_BEGIN` into `_rollingHash`.
4. Recursively call `_processNCalls(nested.callCount)` — these calls come from the same flat `entry.L2ToL1Calls[]` array, sharing the global `_currentCallNumber` cursor.
5. Hash `NESTED_END` into `_rollingHash`.
6. Return `nested.returnData` to the destination contract.

### All nested actions must succeed

An `ExpectedL1ToL2Call` represents a successful reentrant call. If a reentrant call **must revert**, it cannot be expressed as an `ExpectedL1ToL2Call` — the failed call would `revert` inside the proxy, which rolls back the consumption index `tstore`, leaving the protocol unable to distinguish "the call was attempted and failed" from "the call never happened".

Build reverting reentrant calls as `LookupCall` entries with `failed = true` instead. `LookupCall` is content-addressed by `(crossChainCallHash, callNumber, lastNestedActionConsumed)`, so its revert is replayed without disturbing the consumption cursor.

### `callCount` accounting

Calls in `entry.L2ToL1Calls[]` are read sequentially. The sum of all `callCount` values (entry-level plus all nested actions) **must equal** `entry.L2ToL1Calls.length`. The contract enforces this at the end of the entry:

- `_currentCallNumber == entry.L2ToL1Calls.length` else revert `UnconsumedCalls`
- `_lastNestedActionConsumed == entry.expectedL1ToL2Calls.length` else revert `UnconsumedNestedActions`

---

## LookupCall

```solidity
struct LookupCall {
    bytes32         crossChainCallHash;
    uint256         destinationRollupId;       // rollup whose lookupQueue this entry routes to
    bytes           returnData;
    bool            failed;                    // if true, lookup reverts with returnData
    uint64          callNumber;                // _currentCallNumber at lookup time
    uint64          lastNestedActionConsumed;  // _lastNestedActionConsumed at lookup time
    L2ToL1Call[]    calls;                     // optional sub-calls executed in static context
    bytes32         rollingHash;               // expected hash of those sub-calls (verified)
}
```

Lookup calls are looked up — never executed via the normal call path. The proxy detects STATICCALL context (a self-call to `staticCheck()` whose `tstore` reverts), routes to `staticCallLookup` (a view function), and the manager scans `_transientLookupCalls` then the rollup's `verificationByRollup[rid].lookupQueue` for a match on `(crossChainCallHash, callNumber, lastNestedActionConsumed)`.

When found:
- If `lc.calls.length > 0`: replay those calls in static context (`sourceProxy.staticcall(...)`), accumulate the rolling hash, and verify against `lc.rollingHash`. This lets the lookup itself trigger sub-staticcalls.
- If `lc.failed`: revert with `lc.returnData`.
- Otherwise return `lc.returnData`.

### Disambiguation by phase

A single deferred entry can issue several STATICCALLs with the same `crossChainCallHash` at different points in its execution. The `(callNumber, lastNestedActionConsumed)` pair uniquely identifies the phase of execution:

- `callNumber = _currentCallNumber` (the 1-indexed global call counter)
- `lastNestedActionConsumed = _lastNestedActionConsumed`

Together they form a coordinate that advances monotonically and never repeats. The builder must record these two values at the exact moment each STATICCALL is observed in simulation.

### When to use `LookupCall` instead of `ExpectedL1ToL2Call`

| Situation | Use |
|---|---|
| Reentrant cross-chain call that **succeeds** | `ExpectedL1ToL2Call` |
| Reentrant cross-chain call that **reverts** (caller catches with try/catch) | `LookupCall` with `failed = true` |
| Reentrant cross-chain `STATICCALL` (read-only) | `LookupCall` with `failed = false` |
| Top-level cross-chain call that naturally reverts | `LookupCall` with `failed = true` consumed via `staticCallLookup`, the failed-reentry fallback in `_consumeNestedAction`, or the top-level fallback `_tryRevertedTopLevelLookup`; or place the call inside `L2ToL1Calls[]` with `revertSpan = 0` and let `CALL_END(false, retData)` capture it |
| Successful call(s) whose state must be force-reverted | `revertSpan > 0` on the first call of the span (e.g. cross-chain forced revert) |

**How the manager picks between `ExpectedL1ToL2Call` and `LookupCall`** (for a reentrant call that hits `executeCrossChainCall`):

1. If the proxy is in a real STATICCALL frame (its `tstore` self-check reverts), the proxy routes to `staticCallLookup`, which scans the lookup tables (transient first on L1) for a `(crossChainCallHash, callNumber, lastNestedActionConsumed)` match — both `failed=true` and `failed=false` are valid here.
2. Otherwise (normal CALL frame), the proxy routes to `executeCrossChainCall` → `_consumeNestedAction`:
   - If `expectedL1ToL2Calls[_lastNestedActionConsumed].crossChainCallHash == crossChainCallHash` → consume the `ExpectedL1ToL2Call` (priority).
   - Otherwise scan the lookup tables for a `failed=true` match at the current `(callNumber, lastNestedActionConsumed)` → revert with the cached `returnData`. The destination's `try/catch` catches it.
   - No match → revert `ExecutionNotFound`.

This means a reverting reentrant call inside try/catch needs **only** a `LookupCall` with `failed=true` — no companion `ExpectedL1ToL2Call`, no `revertSpan` wrapper. The cursor is not advanced for that call, so the EVM revert has nothing to roll back.

Note: on L2 the lookup match key drops `destinationRollupId` (single rollup) — match is keyed on `(crossChainCallHash, callNumber, lastNestedActionConsumed)` only.

---

## State Deltas

```solidity
struct StateDelta {
    uint256 rollupId;       // which rollup's state changes
    bytes32 currentState;   // expected pre-state root on rollupId — checked against rollups[rid].stateRoot
    bytes32 newState;       // post-execution state root
    int256  etherDelta;     // signed ETH change for this rollup
}
```

`currentState` is checked at consumption time against `rollups[delta.rollupId].stateRoot`; mismatch reverts `StateRootMismatch`. This is the per-rollup-queue model's soundness backstop: entries are content-addressed against the trajectory the proof committed to, so consumption interleaved across rollups can't quietly land an entry whose preconditions don't hold. A stale builder either fails proof verification (the proof binds to the recorded `currentState`) or fails the on-chain match at consumption.

### Ether bridging (`etherDelta`)

`etherDelta` is signed:
- **Positive**: the rollup gains ETH (deposit / bridged-in)
- **Negative**: the rollup loses ETH (withdrawal / bridged-out)
- **Zero**: no change

Per-entry on L1, the contract verifies:

```
totalEtherDelta == etherIn - etherOut
```

where `etherIn` is `msg.value` received by `executeCrossChainCall` (or `0` for `executeL2TX` and immediate entries) and `etherOut` is the sum of `value` of every **successful** call processed (failed calls' ETH stays with the manager).

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

After all calls complete:

```solidity
require(_rollingHash == entry.rollingHash);                              // RollingHashMismatch
require(_currentCallNumber == entry.L2ToL1Calls.length);                 // UnconsumedCalls
require(_lastNestedActionConsumed == entry.expectedL1ToL2Calls.length);  // UnconsumedNestedActions
```

A single mismatch anywhere in the execution tree changes the final hash — this catches wrong return data, wrong success/failure flags, missing or extra calls, and incorrect nesting structure with one comparison.

For the full hash chain semantics (with worked example and multi-phase static-call disambiguation), see `SYNC_ROLLUPS_PROTOCOL_SPEC.md` §E.

---

## Transaction Model

### Per-block structure

Each block has at most:
1. **Setup tx**: `postAndVerifyBatch` (L1) or `loadExecutionTable` (L2) — loads the execution table.
2. **Execution tx(s)**: One per cross-chain interaction that consumes entries.

On L1, `postAndVerifyBatch` itself can run user-driven cross-chain calls inline via the **meta hook** (see below) — those don't need a separate execution tx.

### transient / deferred split (L1 `postAndVerifyBatch`)

`postAndVerifyBatch` takes a single `ProofSystemBatchPerVerificationEntries calldata batch` argument (NOT an array). The batch carries `entries[]`, `l1ToL2lookupCalls[]`, `transientExecutionEntryCount`, `transientLookupCallCount`, `proofSystems[]` (sorted asc), `rollupIdsWithProofSystems[]` (strictly ascending by `rollupId`, each row carrying a `proofSystemIndex[]` of indices into `proofSystems[]`), `proofs[]` (one per PS), `callData`, `blobIndices[]`, and `crossProofSystemInteractions`. See `MULTI_PROVER_DESIGN.md` for the full struct shape and proof-public-inputs construction.

Flow:

1. **Reentry check** — revert `PostBatchReentry` if `_transientExecutions.length != 0`.
2. **Structural validation** via `_validateStructure(batch)`: sorted `proofSystems[]`, strictly-ascending `rollupIdsWithProofSystems[].rollupId` (and `rollupId > MAINNET_ROLLUP_ID`), each rollup registered, each row's `proofSystemIndex[]` strictly ascending and in range, entry/lookupCall `destinationRollupId` ∈ batch's rollup set, transient prefix bounds.
3. **Fetch vkMatrix + verify**: `_fetchVkMatrix` calls each rollup's manager via `IRollupContract.checkProofSystemsAndGetVkeys(subset)` (manager enforces threshold internally and reverts if not met). Then `_verifyProofSystemBatch` builds `sharedPublicInput` plus per-PS `acc_k` (folding each rollup's `(blockHash, timestamp)` via `getTimestampAndBlockHash()`) and calls `IProofSystem.verify(proofs[k], publicInputsHash[k])` for each PS. All proofs must verify atomically.
4. **Mark verified-this-block** (`_markVerifiedThisBlock(rid)`): lazy-resets the queue on first touch this block (subsequent same-block touches append to the existing queue). Sets the read gate for `executeCrossChainCall` / `executeL2TX(rollupId)`.
5. **Load transient stream** (`_loadTransient`): copy `entries[0..transientExecutionEntryCount)` into `_transientExecutions` and `l1ToL2lookupCalls[0..transientLookupCallCount)` into `_transientLookupCalls`.
6. **Drain leading immediate entries inline**: while `_transientExecutions[idx].proxyEntryHash == 0`, self-call `try this.attemptApplyImmediate(idx) catch { emit ImmediateEntrySkipped(idx, revertData); }` and advance — not a hard error.
7. **Meta hook**: if `_transientExecutionIndex < _transientExecutions.length` AND `msg.sender.code.length > 0`, call `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()`. The hook can invoke `executeCrossChainCall` / `executeL2TX(rollupId)` to consume the rest of the transient stream.
8. **Cleanup transient tables**, then `_publishRemainder(batch)` (**unconditionally** — even if the meta hook left transient entries unconsumed — pushes `entries[transientExecutionEntryCount..]` to `verificationByRollup[entry.destinationRollupId].queue` and `l1ToL2lookupCalls[transientLookupCallCount..]` to the corresponding `lookupQueue`), then `emit BatchPosted(batch.rollupIdsWithProofSystems.length)`. Soundness backstop: each entry's `StateDelta.currentState` is checked at consumption time, so dropped transient leftover doesn't poison persistent consumers — they fail their own state-root check if they depended on it.

A batch with `transientExecutionEntryCount == 0` means no immediate execution and no meta-hook consumption — all entries flow straight to per-rollup queues.

### 1-to-1 rule

Each user action produces **exactly 1 execution transaction per chain involved**:

- **L1→L2**: User calls a proxy on L1 → `executeCrossChainCall` (1 tx on L1). The system later calls `executeL2TX` on L2 (1 tx on L2), or for inbound delivery from another rollup, `executeIncomingCrossChainCall` (system-only, atomically loads the table and consumes `entries[0]`). Reentrant calls are folded into the same tx via `expectedL1ToL2Calls[]`.
- **L2→L1**: User submits an L2 transaction → `executeL2TX` on L1 consumes the immediate entry (1 tx on L1). The L2 user tx itself is the consumption on L2 (no separate setup tx needed beyond `loadExecutionTable`).

Never split a single cross-chain interaction into multiple execution transactions on the same chain.

---

## Flow Patterns

In the diagrams below, "MAINNET" means rollupId 0 (L1) and "L2" means whichever rollup ID the L2 chain has registered with the `EEZ` registry.

### L1→L2 (simple)

Alice on L1 calls a contract on L2. The proxy for B on L1 forwards Alice's call to L1's `EEZ.executeCrossChainCall` (consuming entry [0]). The L2 system later calls `executeL2TX` on L2 to commit the L2-side state changes.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] DEFERRED
    proxyEntryHash = hash(rollupId=L2, dest=B, value=v, data=calldata, src=Alice, srcRollup=MAINNET)
    destinationRollupId = L2   // routes into verificationByRollup[L2].queue
    L2ToL1Calls = [{ dest=B, value=v, data=calldata, src=Alice, srcRollup=MAINNET, revertSpan=0 }]
    expectedL1ToL2Calls = []
    callCount   = 1
    returnData  = <B's return>     // pre-computed by the prover
    rollingHash = H(CALL_BEGIN(1) → CALL_END(1, true, <B's return>))
    stateDeltas = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=v? } ]   // L2 state moved
```

(An immediate entry for the initial state commitment can also live in the same batch as `entries[0]` with `proxyEntryHash == 0`.)

**L2 execution table** (`loadExecutionTable`):
```
[0] IMMEDIATE   proxyEntryHash = bytes32(0)
    destinationRollupId = L2   // entry's target queue (L2 has a single rollup)
    L2ToL1Calls = [{ dest=B, value=v, data=calldata, src=Alice, srcRollup=MAINNET, revertSpan=0 }]
    expectedL1ToL2Calls = []
    callCount   = 1
    returnData  = ""
    rollingHash = H(CALL_BEGIN(1) → CALL_END(1, true, <B's return on L2>))
    stateDeltas = []   // L2 doesn't store deltas
```

**Execution**:
- **L1**: Alice calls the proxy for B → `executeCrossChainCall(Alice, calldata)` → `_consumeAndExecute` consumes entry [0] → routes through Alice's proxy → returns `<B's return>`.
- **L2**: System submits a tx that calls `executeL2TX(rollupId)` → consumes entry [0] (`crossChainCallHash == 0`) → routes through Alice's proxy on L2 → B executes on L2.

### L2→L1 (simple)

Alice on L2 calls a contract on L1.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] IMMEDIATE   proxyEntryHash = bytes32(0)
    destinationRollupId = MAINNET   // immediate entry inline-executes on L1
    L2ToL1Calls = [{ dest=C, value=0, data=calldata, src=D, srcRollup=L2, revertSpan=0 }]
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
    destinationRollupId = L2   // (L2's single rollup; tooling sets the field for parity)
    L2ToL1Calls = [{ dest=C, value=0, data=calldata, src=D, srcRollup=L2, revertSpan=0 }]
    expectedL1ToL2Calls = []
    callCount   = 1
    returnData  = <C's return>
    rollingHash = H(CALL_BEGIN(1) → CALL_END(1, true, <C's return>))
    stateDeltas = []
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
    L2ToL1Calls   = [
      { dest=D, value=0, data=incrementProxy, src=Alice, srcRollup=MAINNET, revertSpan=0 },  // calls[0] entry-level
      { dest=C, value=0, data=increment,      src=D,     srcRollup=L2,      revertSpan=0 },  // calls[1] inside nested
    ]
    expectedL1ToL2Calls = [ { crossChainCallHash=hash(MAINNET, C, 0, increment, D, L2), callCount=1, returnData=abi.encode(1) } ]
    callCount     = 1   // only calls[0] is entry-level; calls[1] is consumed by the nested action
    returnData    = <D's return on L2>
    rollingHash   = H( CALL_BEGIN(1) → NESTED_BEGIN(1) → CALL_BEGIN(2) → CALL_END(2, true, abi.encode(1)) → NESTED_END(1) → CALL_END(1, true, <D's return>) )
    stateDeltas   = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=0 } ]
```

**L2 execution table** (`loadExecutionTable`):
```
[0] IMMEDIATE   proxyEntryHash = bytes32(0)
    destinationRollupId = L2
    L2ToL1Calls   = [
      { dest=D, value=0, data=incrementProxy, src=Alice, srcRollup=MAINNET, revertSpan=0 },
      { dest=C, value=0, data=increment,      src=D,     srcRollup=L2,      revertSpan=0 },
    ]
    expectedL1ToL2Calls = [ { crossChainCallHash=hash(MAINNET, C, 0, increment, D, L2), callCount=1, returnData=abi.encode(1) } ]
    callCount     = 1
    returnData    = ""
    rollingHash   = (same hash chain as L1 — both chains observe the same call/nesting structure)
```

**Execution**:
- **L1**: Alice → D's proxy → `executeCrossChainCall(Alice, incrementProxy)` → consumes entry [0]. The processor routes calls[0] through Alice's proxy → Alice's proxy on L1 calls D's address (the *real* D doesn't live here; this is the L1 representation). When D's logic on L1 calls C's proxy → `executeCrossChainCall(D, increment)` → `_insideExecution() == true` → consumes nestedActions[0] → processes calls[1] (real C executes) → returns `abi.encode(1)`. D's L1 stub returns `<D's return>`.
- **L2**: System tx → `executeL2TX(rollupId)` → consumes entry [0]. Same call flow, but real D executes here and the C call routes through D's proxy on L2 — the manager intercepts at the same nested action.

### L2→L1→L2 (reentrant L1→L2 inside an L2→L1 call)

Alice on L2 calls A's proxy on L2 (A lives on L1). A, while executing on L1, calls B's proxy on L1 (B lives on L2).

**L1 execution table** (`postAndVerifyBatch`):
```
[0] IMMEDIATE   proxyEntryHash = bytes32(0)
    destinationRollupId = MAINNET
    L2ToL1Calls   = [
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
    proxyEntryHash       = hash(rollupId=MAINNET, dest=A, value=0, data=callBProxy, src=Alice, srcRollup=L2)
    destinationRollupId = L2
    L2ToL1Calls   = [ same two calls as L1, in the same order ]
    expectedL1ToL2Calls = [ same nested action ]
    callCount     = 1
    returnData    = <A's return>
    rollingHash   = (same hash chain)
```

**Execution**:
- **L2**: Alice's L2 tx → A's proxy → `executeCrossChainCall(Alice, callBProxy)` → consumes entry [0]. The manager routes calls[0] through Alice's proxy (A's L2 stub executes), and when the L2 stub calls B's proxy → `executeCrossChainCall(A, increment)` → `_insideExecution() == true` → consumes nestedActions[0] → processes calls[1] (B executes on L2).
- **L1**: `postAndVerifyBatch` runs entry [0] as the immediate entry (or via meta hook). Same call flow, but real A executes on L1 and B's call goes through the same nested-action path.

### Forced revert via `revertSpan`

When a chain's prover output marks a cross-chain call as reverted even though the destination call would succeed, the protocol uses `revertSpan` to delineate the contiguous run of calls whose **state effects** must be rolled back. The rolling hash still records the calls' real outcomes (typically `success=true`); only the EVM state changes are discarded.

Example: SCA on L2 calls SCB which makes a successful cross-chain call to Counter on L1, then SCA reverts. From L1's perspective Counter.increment() ran cleanly, but L2's prover output says the higher-level transaction was rolled back, so L1 must not retain the state change.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] IMMEDIATE   proxyEntryHash = bytes32(0)
    destinationRollupId = MAINNET
    L2ToL1Calls   = [
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

### Failed inner call via `LookupCall`

When a reentrant cross-chain call **must revert** (e.g., the destination wraps the call in `try/catch`), it cannot be an `ExpectedL1ToL2Call`. Use a `LookupCall` with `failed = true` instead.

**L1 `lookupCalls`** for the matching sub-batch (routed via `destinationRollupId` into the rollup's `lookupQueue`, with leading entries optionally going to `_transientLookupCalls`):
```
[0] LookupCall {
    crossChainCallHash       = hash(rollupId=L2, dest=B, value=0, data=increment, src=D, srcRollup=MAINNET),
    destinationRollupId      = L2,
    returnData               = <revert reason>,
    failed                   = true,
    callNumber               = 1,    // the entry-level call that triggered B
    lastNestedActionConsumed = 0,    // before any nested action (ExpectedL1ToL2Call) was consumed
    calls                    = [],
    rollingHash              = bytes32(0),
}
```

When B's proxy is called from inside D's execution, the proxy detects STATICCALL context (because the call originated from a `try/catch` in D that internally used `staticcall`) and routes to `staticCallLookup`. The lookup matches by `(crossChainCallHash, callNumber=1, lastNestedActionConsumed=0)` and reverts with the cached revert reason. D catches the revert and continues.

### Same action twice (sequential)

When the same proxy call happens N times in a single transaction (e.g., a contract calling B's proxy twice in a row), each call consumes the next entry in the table — there is no special handling. Each entry has the same `crossChainCallHash`; sequential indexing differentiates them.

```
[0] DEFERRED   proxyEntryHash = hash(B, ...) ... returnData = <first return>
[1] DEFERRED   proxyEntryHash = hash(B, ...) ... returnData = <second return>
```

The destination rollup's `cursor` advances from 0 → 1 → 2; the second call to B's proxy lands at `verificationByRollup[B's rollupId].queue[1]`. The hash check `entry.proxyEntryHash == crossChainCallHash` succeeds because both entries were built with the same hash.

### Continuation pattern (sequential entries within a flow)

A single user action that performs multiple top-level cross-chain calls produces multiple entries. Each top-level entry-point call consumes one entry. There is no `nextAction` redirection — the user's contract makes each call explicitly, and the table has one entry per top-level call.

For sub-calls **within** a single entry (e.g., a contract on the destination side that performs several proxy calls), all those sub-calls live in `entry.L2ToL1Calls[]` and either count toward `entry.callCount` (entry-level) or toward an `ExpectedL1ToL2Call`'s `callCount`.

---

## L1 vs L2 Entries

| Aspect | L1 (`EEZ`) | L2 (`EEZL2`) |
|---|---|---|
| **How loaded** | `postAndVerifyBatch(ProofSystemBatchPerVerificationEntries calldata batch)` — single struct (not array) carrying `entries[]`, `l1ToL2lookupCalls[]`, `transientExecutionEntryCount`, `transientLookupCallCount`, `proofSystems[]`, `rollupIdsWithProofSystems[]`, `proofs[]`, `callData`, `blobIndices[]`, `crossProofSystemInteractions` | `loadExecutionTable(entries, _lookupCalls)` by `SYSTEM_ADDRESS`; OR `executeIncomingCrossChainCall(...)` for inbound delivery from another rollup (system-only, atomically loads + executes `entries[0]`) |
| **State deltas** | Required for entries that touch rollup state; `delta.currentState` checked against `rollups[id].stateRoot` (mismatch reverts `StateRootMismatch`); `etherDelta` accounted | Empty by convention; the L2 contract has no rollup state |
| **Matching logic** | Per-rollup `verificationByRollup[rid].cursor++`; entry's `proxyEntryHash` must equal the expected hash and `entry.destinationRollupId` must equal the consumer's routing rollupId | Same — sequential cursor; single rollup. Lookup match key drops `destinationRollupId`. |
| **Top-level reverted-lookup fallback** | `_tryRevertedTopLevelLookup(crossChainCallHash, destRid)` scans transient table + persistent `lookupQueue` for a `failed && callNumber == 0 && lastNestedActionConsumed == 0` match | `_tryRevertedTopLevelLookup(crossChainCallHash)` scans persistent `lookupCalls` only (no transient on L2) |
| **Ether accounting** | Per-entry `etherIn - etherOut == sum(etherDelta)` | None; `msg.value` is forwarded to `SYSTEM_ADDRESS` |
| **Same action hash** | Each occurrence consumes the next entry on the destination rollup's queue; sequential ordering distinguishes them | Same |
| **Transient/deferred split** | `_transientExecutions` + `_transientLookupCalls` populated from the batch's leading prefix; meta hook consumes them; remainder published to per-rollup queues **unconditionally** (soundness via `StateDelta.currentState` check) | No transient table — all entries go directly to `executions` |
| **Meta hook** | `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` if transient stream not yet drained AND `msg.sender` has code | Not present |
| **Immediate entry** | Leading transient entries with `proxyEntryHash == 0` run inline during `postAndVerifyBatch` via `attemptApplyImmediate` (try/catch); failed self-call emits `ImmediateEntrySkipped` and continues | `entries[0]` with `proxyEntryHash == 0` is consumed by `executeL2TX(rollupId)` (no inline execution) |
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

If a cross-chain flow involves reentrant calls (e.g., L1→L2→L1), all sub-calls are folded into the entry's flat `L2ToL1Calls[]` and `expectedL1ToL2Calls[]`. The whole entry resolves in **one transaction per chain**, not multiple separate transactions.

Wrong:
```
TX1 on L1: Alice → proxy → executeCrossChainCall (CALL into L2's space)
TX2 on L1: system → executeCrossChainCall (reentrant CALL back from L2)  ← WRONG: separate tx
```

Right:
```
TX1 on L1: Alice → proxy → executeCrossChainCall
  → consumes one entry whose calls[] contains both calls[0] (entry-level) and calls[1] (nested)
  → the reentrant call hits the manager via the proxy and consumes nestedActions[0]
  → all calls resolve within this single tx
```

### Never use `executeL2TX` for L1→L2 flows

`executeL2TX` consumes the next entry, which must have `proxyEntryHash == 0`. Use it on the **destination** chain to commit the user's L2 transaction's state changes. For L1→L2 flows, the user's call enters the protocol via `executeCrossChainCall` on the proxy on L1; the L2 side commits the state via `executeL2TX`. Don't call `executeL2TX` on L1 to start an L1→L2 flow.

### Never call `executeL2TX` while inside a cross-chain execution

`executeL2TX(rollupId)` reverts with `L2TXNotAllowedDuringExecution` if `_insideExecution() == true`. L2TX entries are top-level only; reentrant calls must use the proxy path.

### Consistent rollupId / sourceRollupId semantics

- `targetRollupId` on every action = **target** (where the call executes)
- `sourceRollupId` on every action = **origin** (where the caller lives)
- On L1, top-level calls produced by `executeCrossChainCall` have `sourceRollupId = MAINNET (0)`.
- On L2, top-level calls produced by `executeCrossChainCall` have `sourceRollupId = ROLLUP_ID` (this L2's ID).
- Reentrant calls inside an entry have `sourceRollupId` set to whichever chain the caller lives on — same as for top-level calls; the protocol does not distinguish reentrant from top-level in the hash.

### Don't rely on table ordering for correctness within an entry

`entry.L2ToL1Calls[]` is a flat array consumed via the global `_currentCallNumber` cursor — entry-level and nested calls share the same cursor. The semantic structure (which calls belong to which nested action) comes from `expectedL1ToL2Calls[i].callCount`, not from positional grouping. The builder must lay out `L2ToL1Calls[]` so the cursor advances correctly through entry-level calls and nested actions in execution order.
