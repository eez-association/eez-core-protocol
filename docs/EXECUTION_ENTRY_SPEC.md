# Execution Entry Specification

How to correctly build execution entries for L1 (`postAndVerifyBatch`) and L2 (`loadExecutionTable` / `executeIncomingCrossChainCall`).

The protocol uses a **per-frame, sequential** execution model: every entry carries its own array of top-level calls processed in order (L1: `L2ToL1Call[] l2ToL1Calls`; L2: `CrossChainCall[] incomingCalls`), every reentrant frame carries its **own** sub-call array inside one unified expected-reentrant table (L1: `ExpectedL1ToL2Call[] expectedL1ToL2Calls`; L2: `ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls`), and a single `rollingHash` verifies the entire execution tree at the end.

---

## Entry Structure

```solidity
// L1 (src/interfaces/IEEZ.sol)
struct ExecutionEntry {
    StateUpdate[]         stateUpdates;          // the entry's true state transition (≥1, enforced on-chain)
    bytes32              proxyEntryHash;       // inbound proxy-entry call hash; bytes32(0) = L2Tx (immediate / executeL2Txs)
    L2ToL1Call[]         l2ToL1Calls;          // the entry's TOP-LEVEL calls only (reentrant frames carry their own)
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;  // unified reentrant table: SUCCESS / STATIC / REVERTED kinds
    bytes32              rollingHash;          // expected rolling hash over all calls + nestings
    uint64               destinationRollupId;  // routes to a per-rollup queue; must be ∈ stateUpdates
    bool                 success;              // false ⇒ the entry runs, is verified, then reverts with returnData
    bytes                returnData;           // pre-computed top-level return value (revert payload when !success)
}

// L2 (src/interfaces/IEEZL2.sol) — leaner: single rollup, no state deltas, no per-rollup routing
struct ExecutionEntry {
    bytes32                          proxyEntryHash;        // hash of the inbound call (never bytes32(0) on L2)
    CrossChainCall[]                 incomingCalls;         // the entry's TOP-LEVEL calls only
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls; // unified reentrant (outgoing) table
    bytes32                          rollingHash;
    bool                             success;
    bytes                            returnData;
}
```

The L2 struct does **not** share L1's layout: `stateUpdates` and `destinationRollupId` are L1-only fields and are dropped entirely on L2 (not just left empty). L2's vocabulary is self-relative directional — `incomingCalls` are cross-chain calls executed on this L2 for a remote caller, `expectedOutgoingCalls` are reentrant calls fired from this L2 — because the counterparty can be L1 or another L2, so absolute names like `l1ToL2Calls` would often be wrong.

A top-level entry can **succeed or revert** — the `success` flag decides. When `success == true`, `executeCrossChainCall` returns `entry.returnData` regardless of inner-call outcomes (a naturally-reverting inner call is captured by `CALL_END(false, retData)` in the rolling hash). When `success == false`, the entry is fully executed and verified (rolling hash, ether invariant), then **everything is reverted** with `returnData` as the revert payload — state deltas, cursor advance, inbound value all roll back, and the caller may `try/catch` the revert. Reverting REENTRANT calls are `success == false` `ExpectedL1ToL2Call`s (L2: `ExpectedOutgoingCrossChainCall`s) inside the entry's unified table, and a top-level reverting **read** is a `StaticExecutionEntry` in the static pool.

Exception — L1 L2Tx entries (`proxyEntryHash == 0`) have no proxy consumer and must be canonical: `success == true`, empty `returnData` (`L2TxEntryNotCanonical` checks this defensively). L2's inbound `entries[0]` stays fully general. Full constraint list: `CORE_PROTOCOL_SPEC.md` §C "Prover constraints".

### Per-rollup queue routing

`destinationRollupId` selects which rollup's queue this entry is loaded into during `postAndVerifyBatch`'s deferred publish. The central `EEZ` registry stores per-rollup queues (`verificationByRollup[rid].entryQueue` and `verificationByRollup[rid].staticEntryQueue`) with a per-rollup cursor (`entryQueueIndex`). Each `postAndVerifyBatch` call carries one `ProofSystemBatchPerVerificationEntries` payload covering one or more rollups; entries are routed by `destinationRollupId` into the matching rollup's queue. Validation requires `destinationRollupId` to be among the entry's own `stateUpdates` rollups (`EntryDestinationNotInStateUpdates`), so an entry can only be parked in a queue it actually proved. Cross-rollup state is independent — a stuck cursor on one rollup does not block another. See `MULTI_PROVER_SPEC.md` for the multi-prover / per-rollup-queue specifics.

### IMMEDIATE entries (`proxyEntryHash == 0` — "L2Tx" entries)

A leading run of the batch's immediate prefix (`entries[0..immediateEntryCount)`) may have `proxyEntryHash == 0`. Each such entry is executed inline by `postAndVerifyBatch` itself, **straight from calldata** (never SSTOREd whole; only its reentrant table is parked transiently), and represents the batch's immediate work — pure L2 transactions or L2 transactions that touch L1. State deltas are applied, calls are processed, and the rolling hash is verified, all within `postAndVerifyBatch`. Each entry runs in a `try/catch` self-call (`_attemptExecuteImmediateL2Txs`); if it reverts, the registry emits `L2TxSkipped(transientIdx, revertData)` and the loop advances — not a hard error. Two hard errors do exist: a non-empty leading L2Tx run where **every** entry reverted unwinds the whole post (`AllImmediateL2TxsFailed`), and an `immediateEntryCount` that strands a leading L2Tx into the queue is rejected at validation (`ImmediateCountStrandsLeadingL2Tx`). Immediate-prefix entries past the leading L2Tx run are meta-hook entries (see the Transaction Model section).

### DEFERRED entries (`proxyEntryHash != 0`, or L2Txs past the leading run)

Loaded into `_transientEntries` (the immediate-prefix remainder, consumed via the meta hook) or into per-rollup `verificationByRollup[rid].entryQueue` (entries past `immediateEntryCount`). Consumed by `executeCrossChainCall` or `executeL2Txs(rollupId)`, and only in the block they were posted (`lastVerifiedBlock(rid) == block.number`; mismatch reverts `ExecutionNotInCurrentBlock`). Each call computes the expected cross-chain call hash from the proxy/call-site context (`executeL2Txs` expects `bytes32(0)`) and **forward-scans** the queue from the cursor for the first entry that fully matches (`_entryMatches`): identity (`proxyEntryHash`), routing (`destinationRollupId`), and state preconditions (every `StateUpdate.currentState` equals the live root). Non-matching entries are skipped (a previously-attempted `success == false` entry, whose revert left the cursor in place, doesn't block later calls); no match by end of queue reverts `ExecutionNotFound`. While a batch is mid-flight, consumption is routed through `_transientEntries` with one **global** cursor (`_transientEntryIndex`) instead. Cursor advance is per-rollup on the persistent path.

---

## Action Hash

A cross-chain call is identified by its `crossChainCallHash`, computed by the `public pure` helper `computeCrossChainCallHash` on either manager (defined in `EEZBase`). `callGas` is `0` at every keying site except calls LEAVING an L2 (`EEZL2.executeCrossChainCall`, top-level `proxyEntryHash` match and nested `expectedOutgoingHash` alike), where `USE_GAS_LEFT` selects the observed `gasleft()` at manager entry (else `0`). Every fixture and current deployment runs `useGasLeft = false`, so build every key with `callGas = 0`. Formula, matching-site table, and off-chain helpers: `CORE_PROTOCOL_SPEC.md` §C.

The on-chain contracts reconstruct the hash from the proxy's identity (`originalRollupId`, `originalAddress`) and the live call context (`msg.value`, `callData`, the proxy's caller, `MAINNET_ROLLUP_ID` on L1 or `ROLLUP_ID` on L2).

### Hash semantics by entry point

| Entry point | isStatic | sourceAddress | sourceRollupId | targetAddress | targetRollupId | value | callGas | data |
|---|---|---|---|---|---|---|---|---|
| `executeCrossChainCall` (L1 proxy) | `false` | proxy's caller | `MAINNET_ROLLUP_ID` (0) | proxy's `originalAddress` | proxy's `originalRollupId` | `msg.value` | `0` | original calldata |
| `executeCrossChainCall` (L2 proxy) | `false` | proxy's caller | this L2's `ROLLUP_ID` | proxy's `originalAddress` | proxy's `originalRollupId` | `msg.value` | **`gasleft()` if `USE_GAS_LEFT`, else `0`** | original calldata |
| Reentrant call (matches an `ExpectedL1ToL2Call` on L1 / `ExpectedOutgoingCrossChainCall` on L2) | same as the `executeCrossChainCall` row for the chain making the call | same | same | same | same | same | same | same |
| `executeL2Txs` | n/a — entry has `proxyEntryHash == 0` | — | — | — | — | — | — | — |
| `staticCrossChainCall` (both chains) | `true` | proxy's caller | this chain's rollup ID | proxy's `originalAddress` | proxy's `originalRollupId` | `0` (static is value-free) | `0` | original calldata |
| `executeIncomingCrossChainCall` (L2, system) | `incomingCalls[0].isStatic` | `incomingCalls[0].sourceAddress` | `incomingCalls[0].sourceRollupId` | `incomingCalls[0].targetAddress` | this L2's `ROLLUP_ID` | `incomingCalls[0].value` | `0` | `incomingCalls[0].data` |
| Flat-call `CALL_BEGIN` fold (both chains) | `cc.isStatic` | `cc.sourceAddress` | `cc.sourceRollupId` | `cc.targetAddress` | executing chain's ID | `cc.value` | `0` | `cc.data` |

Note the two L2 rows that fold `callGas = 0` despite living on an L2: a static read never keys on gas, and a flat call is one being *delivered* on this chain rather than leaving it — its `cc.gas` caps the proxy's destination call but is not part of the identity hash.

The hash is fully determined by the fields above; nothing else (caller depth, parent frame, position in the entry) feeds into it. Position is pinned separately, by the rolling hash — see the reentrant table's `expectedL1toL2Hash` key below.

### Cross-chain hash consistency

When the same logical call appears on both chains, the `crossChainCallHash` is identical on both sides:

- **L1→L2 proxy call** generated by `executeCrossChainCall` on L1 (e.g., user calls B's proxy on L1) has `targetRollupId = L2`, `sourceRollupId = MAINNET (0)`. `executeIncomingCrossChainCall` on L2 recomputes the hash from `entries[0].incomingCalls[0]` (folding its own `gas`; the L1-side key folds `0`, so they coincide when `gas == 0`) and reverts `EntryHashMismatch` if `entries[0].proxyEntryHash` diverges; that the call matches what actually left L1 is an in-circuit obligation.
- **Reentrant L2→L1 call** generated mid-execution on L2 (D calls C's proxy on L2) has `targetRollupId = MAINNET`, `sourceRollupId = L2`. L2 folds its outgoing key (`callGas` = observed gas under `USE_GAS_LEFT`, else `0`) into `NESTED_BEGIN` inside its reentrant frame, while L1 folds `callGas = 0` into `CALL_BEGIN` for the call it actually executes — so the two sides share a hash exactly when the L2 runs `useGasLeft = false` (all current deployments), and diverge only in the `callGas` term otherwise.

The hash inputs alone determine the hash, with no positional or contextual term mixed in. Note the two chains' **rolling hashes** are NOT equal for a mirrored flow: each side folds only the calls that execute on it, and L1 additionally seeds its hash with the entry's state-delta context. The builder must simulate both sides to predict exact `data`, return data, and `value`.

---

## L2ToL1Call (L2: `CrossChainCall`)

```solidity
struct L2ToL1Call {
    uint16  revertNextNCalls; // >0 = force-revert the next N calls' state effects (this one included)
    bool    isStatic;         // dispatch via STATICCALL (read-only; value must be 0)
    uint64  gas;              // gas limit for the target call; 0 = forward all remaining gas
    address sourceAddress;    // caller identity on the source rollup (used to derive sourceProxy)
    uint64  sourceRollupId;   // caller's rollup ID
    address targetAddress;    // contract to call on this chain
    uint256 value;            // ETH sent
    bytes   data;             // calldata
}
```

L2's `CrossChainCall` (`IEEZL2.sol`) is field-for-field identical; only the struct name differs.

The processor (`_processNCalls`) walks the given call array by a plain local index and, for each non-revert-span call, derives the `sourceProxy` address from `(sourceAddress, sourceRollupId)`, auto-creates the proxy if it doesn't exist, and routes the call through `CrossChainProxy.executeOnBehalf(targetAddress, gas, data){value: value}` (the call's `gas` field caps the destination call; `0` forwards all remaining) — a plain `.call`, or a `staticcall` when `isStatic` (a static call carrying value is malformed and reverts `StaticCallWithValue`). If the destination call itself reverts, the proxy's `.call` returns `(success=false, retData=revertReason)` and that is hashed into `CALL_END` — natural reverts need no special wrapping. Each call's identity (its `crossChainCallHash`, with `targetRollupId` = the executing chain's ID) is folded into `CALL_BEGIN`, so the hash commits to *which* call ran, not just its result. Every call's `sourceRollupId` must be in the entry's proven set (its `stateUpdates` on L1) — enforced at batch validation (`CallSourceNotVerified`).

### `revertNextNCalls`: forced-revert context

`revertNextNCalls > 0` is the **forced-revert** mechanism: the next `revertNextNCalls` calls (including this one) execute, succeed, and have their state effects rolled back at the protocol layer. The rolling hash still commits to the calls' real outcomes (typically `success=true` with the captured `returnData`); only the EVM state changes disappear. Mechanically, the processor slices the span and self-calls `executeInContextAndRevert(span)`, which always reverts with `ContextResult(rollingHash, reentrantConsumed, callsProcessed)` — state rolls back, the rolling hash and reentrant cursor escape via the revert payload and are restored by the outer frame. Full mechanics: `CORE_PROTOCOL_SPEC.md` §D.4.

`revertNextNCalls` covers a contiguous run of calls within one call array (an entry's top-level array or one reentrant frame's own sub-array). Nested spans are a prover convention violation rather than an on-chain check — the processor would mechanically recurse, but the outer span's rollback already discards the inner state, so the prover never emits one.

#### When `revertNextNCalls` is the right tool

The canonical use is a cross-chain call from rollup A to rollup B where B's destination call **succeeded**, but the prover output marks the call as reverted in A's view of the world (for example, because the higher-level transaction containing the call was rolled back on A). When B runs the entry, `revertNextNCalls = 1` ensures B's state does not retain effects that A no longer commits to.

For natural failures — a destination contract that simply `revert`s — `revertNextNCalls = 0` is correct and simpler:

- The proxy `.call` returns `success=false` with the destination's revert payload as `retData`.
- `CALL_END(false, retData)` is hashed into the rolling hash.
- The destination's own revert rolls back the destination's state.

Wrapping a single naturally-reverting call in `revertNextNCalls = 1` is purely ceremonial — it produces the same rolling hash and the same on-chain state as `revertNextNCalls = 0`, with an extra self-call frame for nothing. The mechanism only earns its cost when state would otherwise survive.

**Reentrant reverted calls take a different path entirely.** When the destination contract called from `_processNCalls` re-enters the manager via a proxy and the caller try/catches, a revert of that nested call is a `success == false` entry in the unified reentrant table — *not* `revertNextNCalls`: the `try/catch` already provides the isolation boundary, and the row runs the reverted frame with its own sub-hash check (see the Reentrant Table section below). For the full situation → structure decision, see "When to use which structure".

---

## ExpectedL1ToL2Call (L2: `ExpectedOutgoingCrossChainCall`)

```solidity
struct ExpectedL1ToL2Call {
    bytes32      expectedL1toL2Hash;           // position key: keccak256(crossChainCallHash ‖ expectedRollingHash)
    L2ToL1Call[] l2ToL1Calls;                  // the reentrant frame's OWN sub-calls, run to completion
    bytes32      revertedOrStaticRollingHash;  // expected sub-call hash — checked for STATIC / REVERTED kinds; must be 0 for SUCCESS (prover constraint)
    bool         success;                      // whether the reentrant call returns or reverts
    bytes        returnData;                   // pre-computed return value (revert payload when !success)
}
```

L2's `ExpectedOutgoingCrossChainCall` (`IEEZL2.sol`) is field-for-field identical modulo names (`expectedOutgoingHash`, `incomingCalls`).

One unified table holds **every** reentrant kind — plain SUCCESS, read-only STATIC, and try/catch'd REVERTED (`!success`). Each is content-addressed by a single key:

```solidity
expectedL1toL2Hash = keccak256(abi.encodePacked(crossChainCallHash, expectedRollingHash))
```

where `crossChainCallHash` already folds `isStatic` (a static read keys distinctly from a state-changing call) and the routed rollup, and `expectedRollingHash` is the live `_rollingHash` at the instant the call fires — which uniquely pins the execution point, since the hash chain folds every prior call and nesting boundary. There is no positional index to record: the hash IS the position.

When a destination contract called by the processor calls back into a proxy (e.g., contract D on L2 calls C's proxy on L2 to reach C on L1), `executeCrossChainCall` detects `_insideExecution() == true` and routes to `_consumeNestedCall`:

1. Compute `expectedL1toL2Hash = keccak256(crossChainCallHash ‖ _rollingHash)`.
2. Forward-scan the active entry's table from `_lastL1ToL2CallConsumed` (L2: `_lastOutgoingCallConsumed`) — calls are consumed in order, never before the cursor; the first key match IS the entry. On a match, advance the cursor past it, then resolve via `_resolveNestedReentrant`:
   - Hash `NESTED_BEGIN(crossChainCallHash)` into `_rollingHash`.
   - Run the frame's **own** `l2ToL1Calls[]` (L2: `incomingCalls[]`) sub-array to completion via `_processNCalls` — these fold into the same continuous `_rollingHash`.
   - `success == true`: hash `NESTED_END`, return `returnData` to the destination contract (`revertedOrStaticRollingHash` is dead here — `== 0` is a prover constraint).
   - `success == false`: check `_rollingHash == revertedOrStaticRollingHash` (else `RollingHashMismatch`), then revert with `returnData` — the terminal revert rolls back the frame's state, hash, and cursor bump.
3. No match: fold `CALL_NOT_FOUND(crossChainCallHash)` into `_rollingHash` and return empty bytes. The divergence surfaces as `RollingHashMismatch` at the entry boundary — it survives any intermediate `try/catch` (and any `revertNextNCalls` boundary, riding the `ContextResult` payload). On L1 there is one additional gate before all of this: the reentrant call's target rollup must be in the executing entry's proven set (`ReentrantDestinationNotVerified`).

A reverted sub-execution reuses the **host table** for its own deeper reentrant calls (Solidity forbids recursive structs); the live `_rollingHash` folded into each key keeps the contexts distinct. STATIC-kind entries in this table are matched only via `staticCrossChainCall` (their `crossChainCallHash` folds `isStatic = true`, so a CALL-keyed scan can never hit them) — see the Static Entries section.

### Reverting reentrant calls are table entries too

A reentrant call that **must revert** (the caller catches it with `try/catch`) is a `success == false` entry in the same table — no separate structure, no `revertNextNCalls` wrapper. Its `l2ToL1Calls[]` are any sub-calls that execute (then roll back) during the attempt, `revertedOrStaticRollingHash` is the expected `_rollingHash` after `NESTED_BEGIN` plus those sub-call folds, and `returnData` is the revert payload. Because the terminal revert rolls back the cursor bump, the consumed slot is "un-consumed" again — the key's `expectedRollingHash` component is what keeps a retried or repeated call unambiguous.

### Completeness accounting

There are no per-frame call counts and no shared flat array: each frame's array is run to completion by `_processNCalls`, so completeness is **structural** for calls, and there is no cursor-vs-length check at the entry boundary. Completeness of the SUCCESS reentrant entries rests on the rolling hash: a skipped success frame omits its `NESTED_BEGIN`/`NESTED_END` folds and diverges the hash. An **unconsumed** table entry is inert — the unified table may legitimately contain STATIC and REVERTED entries that a given run never touches (e.g. inside a rolled-back span), so no table-length check is performed.

---

## Static Entries (`StaticExecutionEntry` top-level / STATIC-kind reentrant entries)

Read-only cross-chain calls (`STATICCALL`s through a proxy) resolve in two homes — structs, match keys, and full resolution mechanics: **`STATIC_ENTRY.md`**:

- **Nested (inside an execution)** — a STATIC-kind row of the unified reentrant table (previous section), keyed by `expectedL1toL2Hash` with `isStatic = true` and `value = 0` folded into the call hash. The key folds the live `_rollingHash`, pinning the read to an exact execution point; the scan runs forward from the reentrant cursor without consuming (a `view` frame can't advance it), and a miss reverts `ExecutionNotFound` immediately.
- **Top-level (outside any execution)** — a `StaticExecutionEntry` in the pool. L1 has **no block gate** and matches `proxyEntryHash` + `destinationRollupId` + every live `expectedStateRoots` pin (full scan, non-matches skipped; transient pool only while a batch is mid-flight); L2 matches `proxyEntryHash` alone, gated on `lastLoadBlock == block.number` (no pins, so the block gate bounds staleness). L2's struct drops `expectedStateRoots` / `destinationRollupId`.

Both homes resolve through `_resolveStaticEntry`: run the entry's read-only sub-calls via STATICCALL, folding the **untagged** accumulator (`keccak256(prev, success, retData)` from `bytes32(0)`, always compared — an empty `calls[]` must match hash `0`), then return `returnData` — or revert with it when `!success`. Referenced source proxies must already be deployed (`StaticCallProxyNotDeployed`).

### When to use which structure

| Situation | Use |
|---|---|
| Reentrant cross-chain call that **succeeds** | `success = true` entry in the unified reentrant table |
| Reentrant cross-chain call that **reverts** (caller catches with try/catch) | `success = false` entry in the unified reentrant table |
| Reentrant cross-chain `STATICCALL` (read-only; may return or revert) | STATIC-kind entry in the unified reentrant table (`crossChainCallHash` folds `isStatic = true`; `success` as appropriate) |
| Top-level static read (returning **or** reverting) | Top-level `StaticExecutionEntry` in the pool (`success` as appropriate) |
| Top-level cross-chain call that reverts (state-changing) | `ExecutionEntry` with `success = false` |
| Inner natural revert of a non-reentrant call | Plain call in the frame's array with `revertNextNCalls = 0`; `CALL_END(false, retData)` captures it |
| Successful call(s) whose state must be force-reverted | `revertNextNCalls > 0` on the first call of the span |

**How the manager picks** (for a reentrant call that hits the manager via a proxy):

1. If the proxy is in a real STATICCALL frame (its `tstore` self-check reverts), the proxy routes to `staticCrossChainCall`, which computes the hash with `isStatic = true` and scans the active entry's unified table (forward from the cursor) for the key — only STATIC-kind entries can match. Miss → `ExecutionNotFound`.
2. Otherwise (normal CALL frame), the proxy routes to `executeCrossChainCall` → `_consumeNestedCall`, which computes the hash with `isStatic = false` and forward-scans for the key. A match resolves as SUCCESS or REVERTED per its `success` flag; a miss folds `CALL_NOT_FOUND` and returns empty bytes (the entry later fails `RollingHashMismatch` at its boundary) — identically on L1 and L2.

---

## State Deltas (L1 only)

`StateUpdate` exists only in `IEEZ.sol` — the L2 entry struct has no `stateUpdates` field.

```solidity
struct StateUpdate {
    uint64  rollupId;       // which rollup's state changes
    bytes32 currentState;   // expected pre-state root on rollupId — checked against rollups[rid].stateRoot
    bytes32 newState;       // post-execution state root
    int256  etherDelta;     // signed ETH change for this rollup
}
```

`currentState` is checked at consumption time against `rollups[delta.rollupId].stateRoot` — it is part of the entry-match predicate on the queue path (a stale entry is a non-match, skipped by the forward scan), and re-asserted upfront in `_executeEntry` (`StateRootMismatch`) for the immediate L2Tx path that doesn't go through matching. This is the per-rollup-queue model's soundness backstop: entries are content-addressed against the trajectory the proof committed to, so consumption interleaved across rollups can't quietly land an entry whose preconditions don't hold. A stale builder either fails proof verification (the proof binds to the recorded `currentState`) or fails the on-chain match at consumption.

**On-chain requirements** (all enforced by `_validateBatchStructure`, not left to prover convention):

- Every entry must carry **at least one** `StateUpdate` (`EntryHasNoStateUpdates`) — an empty array would leave the entry unpinned from the backstop (and would break `_insideExecution()`, which is backed by the per-entry allowed-rollups array).
- `stateUpdates` must be **strictly increasing by `rollupId`**, starting above `MAINNET_ROLLUP_ID` (`StateUpdatesNotStrictlyIncreasing`) — rejects duplicates and a mainnet delta.
- Every delta's rollup must be in the batch's verified set (`RollupNotInBatch`), and `destinationRollupId` must be among the entry's own deltas (`EntryDestinationNotInStateUpdates`).
- **Proxy protection**: every executed call's `sourceRollupId` (top-level and every reentrant frame's sub-calls) must be ∈ the entry's deltas (`CallSourceNotVerified`, checked at validation); reentrant / static-read **targets** carry no clear-text field at post time, so they're checked at runtime against the same set (`ReentrantDestinationNotVerified`).

The `stateUpdates` attached to an entry must be the entry's true state transition — the proof is what makes them *correct*; the checks above only make them well-formed and pinned.

### Ether bridging (`etherDelta`)

`etherDelta` is signed:
- **Positive**: the rollup gains ETH (deposit / bridged-in)
- **Negative**: the rollup loses ETH (withdrawal / bridged-out); a negative delta exceeding the rollup's tracked balance reverts `InsufficientRollupBalance`
- **Zero**: no change

Per-entry on L1, the contract verifies at the end of `_executeEntry`:

```
Σ stateUpdates[i].etherDelta == _entryEtherDelta
```

where `_entryEtherDelta` is a transient net accumulator: SET to the entry-point call's `msg.value` at the top level (0 for `executeL2Txs` and immediate entries — a dirty accumulator there reverts `ResidualEntryEtherIn`), INCREMENTED by every reentrant call's `msg.value`, and DECREMENTED by the `value` of every **successful** non-static call the processor executes (a failed call's ETH never leaves the manager). Calls inside a `revertNextNCalls` span contribute to **neither** side: the span's revert rolls back their ETH transfers and their accumulator writes together — even though the rolling hash still records the calls as successful. Mismatch reverts `EtherDeltaMismatch`.

L2 has no ether accounting — `executeCrossChainCall` immediately forwards `msg.value` to `SYSTEM_ADDRESS` (burn), and `executeIncomingCrossChainCall` and `loadExecutionTable` mint the total inbound ETH (top-level plus nested incoming values) by attaching it as `msg.value`; matching the committed sum is a prover constraint (consumption may be partial — no on-chain check).

---

## Rolling Hash

A single `bytes32 rollingHash` per entry covers every call result and every nesting boundary. The accumulator is **seeded** with the entry's starting context and identity, then updated at tagged events:

```
seed (L1)      _rollingHash = keccak256(statesHash, proxyEntryHash)
               where statesHash = fold over stateUpdates: keccak256(prev, rollupId_i, currentState_i), from bytes32(0)
seed (L2)      _rollingHash = keccak256(bytes32(0), proxyEntryHash)

CALL_BEGIN     (1)   keccak256(prev, 0x01, crossChainCallHash)   // binds WHICH call runs
CALL_END       (2)   keccak256(prev, 0x02, success, returnData)  // binds its observed outcome
NESTED_BEGIN   (3)   keccak256(prev, 0x03, crossChainCallHash)   // reentrant frame opens
NESTED_END     (4)   keccak256(prev, 0x04)                       // reentrant frame closes (SUCCESS only)
CALL_NOT_FOUND (5)   keccak256(prev, 0x05, crossChainCallHash)   // reentrant no-match; diverges the hash so the
                                                                 // entry reverts — replaces any side flag
```

At the entry boundary the accumulator is compared once against `entry.rollingHash` (`RollingHashMismatch` — also catches a `CALL_NOT_FOUND` divergence), plus L1's ether invariant (`EtherDeltaMismatch`); then, if `!entry.success`, the entry reverts with `entry.returnData`. There are no cursor-vs-length checks: each frame's call array is run to completion structurally, and the unified reentrant table may contain legitimately-unused entries (see Completeness accounting). Static resolutions use a simpler **untagged** accumulator (`keccak256(prev, success, retData)` from `bytes32(0)`). Full hash-chain semantics — the no-index rationale, worked examples, static disambiguation: `CORE_PROTOCOL_SPEC.md` §E.

---

## Transaction Model

### Per-block structure

Each block has at most:
1. **Setup tx**: `postAndVerifyBatch` (L1) or `loadExecutionTable` (L2) — loads the execution table.
2. **Execution tx(s)**: One per cross-chain interaction that consumes entries.

On L1, `postAndVerifyBatch` itself runs the leading L2Tx entries inline and can run user-driven cross-chain calls via the **meta hook** (see below) — those don't need a separate execution tx. On L2, `executeIncomingCrossChainCall` combines setup + execution in one system tx (one such tx per top-level inbound call — see the 1-to-1 rule below).

### Immediate / deferred split (L1 `postAndVerifyBatch`)

`postAndVerifyBatch` takes a single `ProofSystemBatchPerVerificationEntries calldata batch` argument (NOT an array). The batch carries `expectedStateRootPerRollup[]` (optional composer-supplied state-root assertions), `entries[]`, `staticEntries[]`, `immediateEntryCount`, `immediateStaticEntryCount`, `proofSystems[]` (strictly increasing by address), `rollupIdsWithProofSystems[]` (strictly ascending by `rollupId`, each row carrying a strictly-increasing `proofSystemIndexes[]` into `proofSystems[]`), `blobIndices[]`, `callData`, `proofs[]` (one per PS), `blockNumber` (the single L1 block the batch binds to; `0` = no block context, `type(uint64).max` = latest), and `bindMsgSenderInPublicInput` (true folds `msg.sender` into the public input — front-run protection). `immediateEntryCount` / `immediateStaticEntryCount` are UNPROVEN dispatch params — not folded into the public input, so the immediate/persistent split can be re-tuned without re-proving. See `MULTI_PROVER_SPEC.md` for the proof-public-inputs construction.

Flow (numbered as in the code):

0. **Reentry guard** — revert `PostBatchReentry` if `_insideExecution()` or `_transientEntries.length != 0`.
1. (**1a**) Check every `expectedStateRootPerRollup` pin against the live root (`ExpectedStateRootMismatch`), then (**1**) **structural validation** via `_validateBatchStructure(batch)`: PS/rollup sorting + registration, per-rollup PS-index ranges, per-entry `stateUpdates` rules + `destinationRollupId ∈ deltas` + call-source pinning, per-static-entry pin rules, the immediate-prefix bounds (`ImmediateCountExceedsEntries`, `ImmediateStaticEntryCountExceedsStaticEntries`, `ImmediateCountStrandsLeadingL2Tx`), and L2Tx canonicality (`L2TxEntryNotCanonical` — defensive check, see CORE §C).
2. **Fetch vkeys**: `_getVerificationKeysPerRollup` calls each rollup's manager via `IRollupContract.checkProofSystemsAndGetVkeys(subset)` (the manager enforces its own threshold and per-PS membership; `view`, so it can't reenter).
3. **Verify all proofs atomically**: `_verifyProofSystemBatch` builds `sharedPublicInput` (entry hashes, static-entry hashes, blob hashes, `keccak(callData)`, per-rollup `customData` fetched via `getCustomData(batch.blockNumber)`, and the bound sender) plus a per-PS accumulator, and calls `IProofSystem.verify(proofs[k], publicInputsHash[k])` for each PS — any failure reverts the batch (`InvalidProof`).
4. **Mark verified-this-block** (`_markVerifiedBlockAndDeletePreviousEntries(rid)`): wipes the rollup's `entryQueue` / `staticEntryQueue` and resets `entryQueueIndex` on **every** verify — a same-block re-verify REPLACES (does not append to) the prior batch's entries. Sets the read gate (`lastVerifiedBlock(rid) == block.number`) for `executeCrossChainCall` / `executeL2Txs(rollupId)`.
5. (**5+6**) **Drain the leading L2Tx run inline, straight from calldata**: while `entries[i].proxyEntryHash == 0` and `i < immediateEntryCount`, self-call `try this._attemptExecuteImmediateL2Txs(entries[i]) catch { emit L2TxSkipped(i, revertData); }` and advance. The entries are never SSTOREd whole — only each entry's reentrant table is parked transiently for the duration of its run. A non-empty run where nothing succeeded reverts `AllImmediateL2TxsFailed`.
6. (**7**) **Meta hook**: if entries remain in the immediate prefix past the leading L2Tx run, `msg.sender` must have code to receive the hook (revert `MetaEntriesWithoutReceiver` otherwise); push `entries[i..immediateEntryCount)` into `_transientEntries` and `staticEntries[0..immediateStaticEntryCount)` into `_transientStaticEntries`, then call `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()`. The hook can invoke `executeCrossChainCall` / `executeL2Txs(rollupId)` to consume the transient entries (one global cursor, in array order). If no hook fires (empty immediate prefix, or one drained entirely by the L2Tx run) a non-zero `immediateStaticEntryCount` reverts `ImmediateStaticEntriesWithoutImmediateEntries` — the transient static pool is only reachable through the hook, so the declared entries would be silently dropped.
7. (**8**) `_saveRemainderEntries(batch)` (**unconditionally** — even if the meta hook left transient entries unconsumed): push `entries[immediateEntryCount..]` to `verificationByRollup[entry.destinationRollupId].entryQueue` and `staticEntries[immediateStaticEntryCount..]` to the corresponding `staticEntryQueue`. Soundness backstop: each entry's `StateUpdate.currentState` is checked at consumption time, so dropped transient leftovers don't poison persistent consumers — a dependent entry fails its own state-root match.
8. (**9**) **Clear the transient tables** (this also closes the re-entry window), then `emit BatchPosted(batch.rollupIdsWithProofSystems.length)`.

A batch with `immediateEntryCount == 0` means no inline execution and no meta-hook consumption — all entries flow straight to per-rollup queues.

### 1-to-1 rule

The delivery unit is the **top-level cross-chain call**, not the source-chain transaction. Each top-level call produces exactly 1 execution transaction on the destination chain:

- **L1→L2**: User calls a proxy on L1 → `executeCrossChainCall` consumes one entry per call (several consumptions can share one L1 tx — e.g. a contract calling a proxy twice). The system delivers EACH top-level call on L2 as its own `executeIncomingCrossChainCall` tx (system-only; atomically replaces the table with that call's entries and consumes `entries[0]`), keyed by the same cross-chain call hash as the L1 side. Once an inbound execution returns, its frame is closed — the next top-level call, even from the same L1 tx, arrives as a NEW L2 tx (typically in the same L2 block). Only reentrant activity inside the open frame folds into the same tx, via the unified reentrant tables on both sides.
- **L2→L1**: User submits an L2 transaction → on L1 the L2Tx entry is consumed inline by `postAndVerifyBatch` or via `executeL2Txs` (1 tx on L1). The L2 user tx itself is the consumption on L2 (no separate setup tx needed beyond `loadExecutionTable`).

Never split a single top-level call into multiple execution transactions on the same chain — and never merge two top-level calls into one.

---

## Flow Patterns

In the diagrams below, "MAINNET" means rollupId 0 (L1) and "L2" means whichever rollup ID the L2 chain has registered with the `EEZ` registry. `seed` is the per-side entry-begin seed from the Rolling Hash section. Each chain's entry lists only the calls that execute **on that chain**.

Two hash notations appear; they differ only in the `callGas` term:

- `hash(isStatic, src, srcRollup, dest, destRollup, value, data)` — `callGas = 0`. Used for everything on L1, for L2 static keys, and for every flat-call `CALL_BEGIN` fold on both chains. The L2 inbound binding folds `incomingCalls[0].gas` instead.
- `hashL2Out(isStatic, src, srcRollup, dest, destRollup, value, callGas, data)` — explicit `callGas`, marking keys consumed by `EEZL2.executeCrossChainCall`: an L2 entry's top-level `proxyEntryHash` and a `expectedOutgoingHash`. The examples pass `callGas = 0` (`useGasLeft = false` everywhere), where it equals `hash(...)` with the same seven fields; under `useGasLeft = true` the observed gas makes the outgoing key distinct.

### L1→L2 (simple)

Alice on L1 calls a contract B on L2. B's proxy on L1 forwards Alice's call to L1's `EEZ.executeCrossChainCall` (consuming entry [0] — no calls execute on L1, the pre-computed result is returned). The L2 system later delivers the call on L2 via `executeIncomingCrossChainCall`.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] DEFERRED
    proxyEntryHash      = hash(false, src=Alice, srcRollup=MAINNET, dest=B, destRollup=L2, value=v, data=calldata)
    destinationRollupId = L2   // routes into verificationByRollup[L2].entryQueue; must be ∈ stateUpdates
    l2ToL1Calls         = []   // nothing executes on L1 — B runs on L2
    expectedL1ToL2Calls = []
    rollingHash         = seed(stateUpdates, proxyEntryHash)   // no calls: the hash is just the seed
    success             = true
    returnData          = <B's return>   // pre-computed by the prover
    stateUpdates         = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=v? } ]
```

(An immediate L2Tx entry for the batch's other work can live in the same batch ahead of this one, with `proxyEntryHash == 0`.)

**L2 execution table** (loaded atomically by `executeIncomingCrossChainCall`):
```
[0] proxyEntryHash = hash(false, Alice, MAINNET, B, L2, v, calldata)
    // same hash as the L1 entry — executeIncomingCrossChainCall recomputes it from
    // incomingCalls[0] and reverts EntryHashMismatch on divergence
    incomingCalls = [{ revertNextNCalls=0, isStatic=false, src=Alice, srcRollup=MAINNET,
                       dest=B, value=v, data=calldata }]
    expectedOutgoingCalls = []
    rollingHash = H( seed(proxyEntryHash) → CALL_BEGIN(hash of the B call, targetRollup=L2)
                     → CALL_END(true, <B's return>) )
    success     = true
    returnData  = <B's return>
    // no stateUpdates / destinationRollupId — the L2 struct has neither field
```

**Execution**:
- **L1**: Alice calls B's proxy → `executeCrossChainCall(Alice, calldata)` → `_consumeAndExecuteEntry` matches entry [0] (identity + routing + live state pins), applies the deltas, verifies the seed-only rolling hash → returns `<B's return>`.
- **L2**: System submits `executeIncomingCrossChainCall(entries, staticEntries)` with `msg.value == v` → atomically replaces the table, checks `entries[0].proxyEntryHash` against the hash of `incomingCalls[0]`, and drives the call processor → B executes on L2 via Alice's proxy.

### L2→L1 (simple)

Alice on L2 (through contract D) calls a contract C on L1.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] IMMEDIATE (L2Tx)   proxyEntryHash = bytes32(0)
    destinationRollupId = L2   // must be ∈ stateUpdates (MAINNET can never be a delta);
                               // immediate entries inline-execute on L1 regardless of this field
    l2ToL1Calls = [{ revertNextNCalls=0, isStatic=false, src=D, srcRollup=L2,
                     dest=C, value=0, data=calldata }]
    expectedL1ToL2Calls = []
    rollingHash = H( seed(stateUpdates, 0) → CALL_BEGIN(hash(false, D, L2, C, MAINNET, 0, calldata))
                     → CALL_END(true, <C's return>) )
    success     = true
    returnData  = ""
    stateUpdates = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=0 } ]
```

(Often this is `entries[0]` with `immediateEntryCount = 1`, executed inline by `postAndVerifyBatch`; a non-leading L2Tx entry is queued and consumed via `executeL2Txs(L2)`.)

**L2 execution table** (`loadExecutionTable`):
```
[0] DEFERRED
    // L2-OUTGOING key (callGas = 0 under useGasLeft = false)
    proxyEntryHash = hashL2Out(false, src=D, srcRollup=L2, dest=C, destRollup=MAINNET, 0, callGas=0, calldata)
    incomingCalls = []          // nothing executes on L2 — C runs on L1
    expectedOutgoingCalls = []
    rollingHash = seed(proxyEntryHash)
    success     = true
    returnData  = <C's return>
```

**Execution**:
- **L2**: Alice's L2 tx calls D, D calls C's proxy on L2 → `executeCrossChainCall(D, calldata)` → consumes entry [0] (no calls; seed-only hash) → returns `<C's return>` to D.
- **L1**: `postAndVerifyBatch` runs entry [0] in the immediate L2Tx run (or `executeL2Txs(L2)` consumes it) — the call routes through D's auto-created proxy on L1, executes the real C, and matches the rolling hash.

### L1→L2→L1 (reentrant L2→L1 inside an L1→L2 call)

Alice on L1 calls D's proxy on L1 (D lives on L2). D, while executing on L2, calls C's proxy on L2 (C lives on L1) — and that D→C leg is what executes on L1.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] DEFERRED
    proxyEntryHash      = hash(false, Alice, MAINNET, D, L2, 0, incrementProxy)
    destinationRollupId = L2
    l2ToL1Calls = [{ revertNextNCalls=0, isStatic=false, src=D, srcRollup=L2,
                     dest=C, value=0, data=increment }]   // the D→C leg is all that runs on L1
    expectedL1ToL2Calls = []
    rollingHash = H( seed → CALL_BEGIN(hash(false, D, L2, C, MAINNET, 0, increment))
                     → CALL_END(true, abi.encode(1)) )
    success     = true
    returnData  = <D's return on L2>
    stateUpdates = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=0 } ]
```

**L2 execution table** (loaded atomically by `executeIncomingCrossChainCall`):
```
[0] proxyEntryHash = hash(false, Alice, MAINNET, D, L2, 0, incrementProxy)
    incomingCalls = [{ src=Alice, srcRollup=MAINNET, dest=D, value=0, data=incrementProxy, ... }]
    expectedOutgoingCalls = [ {
        // L2-OUTGOING key (callGas = 0 under useGasLeft = false)
        expectedOutgoingHash = keccak256( hashL2Out(false, D, L2, C, MAINNET, 0, 0, increment)
                                          ‖ fireHash ),
        // fireHash = the L2 _rollingHash right after CALL_BEGIN of the D call — the point the
        // reentrant call fires
        incomingCalls = [],                 // nothing executes on L2 inside this frame
        revertedOrStaticRollingHash = 0,    // required 0 for a SUCCESS frame (prover constraint)
        success = true,
        returnData = abi.encode(1)          // C's pre-computed return
    } ]
    rollingHash = H( seed → CALL_BEGIN(hash of Alice→D, targetRollup=L2)
                     → NESTED_BEGIN(hash of D→C) → NESTED_END
                     → CALL_END(true, <D's return>) )
    success = true
    returnData = <D's return>
```

**Execution**:
- **L1**: Alice → D's proxy → `executeCrossChainCall(Alice, incrementProxy)` → consumes entry [0]. The processor routes the single call through D's proxy on L1 — the real C executes and returns `abi.encode(1)`. The entry then returns `<D's return>` (pre-computed) to Alice.
- **L2**: System tx → `executeIncomingCrossChainCall(entries, staticEntries)` → drives entry [0]. The real D executes; when D calls C's proxy on L2 → `executeCrossChainCall(D, increment)` → `_insideExecution() == true` → `_consumeNestedCall` matches the frame by `keccak256(crossChainCallHash ‖ _rollingHash)` → runs the frame's (empty) sub-array between `NESTED_BEGIN`/`NESTED_END` → returns `abi.encode(1)` to D.

### L2→L1→L2 (reentrant L1→L2 inside an L2→L1 call)

Alice on L2 calls A's proxy on L2 (A lives on L1). A, while executing on L1, calls B's proxy on L1 (B lives on L2) — the A→B leg executes on L2.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] IMMEDIATE (L2Tx)   proxyEntryHash = bytes32(0)
    destinationRollupId = L2
    l2ToL1Calls = [{ src=Alice, srcRollup=L2, dest=A, value=0, data=callBProxy, ... }]
    expectedL1ToL2Calls = [ {
        expectedL1toL2Hash = keccak256( hash(false, A, MAINNET, B, L2, 0, increment)
                                        ‖ fireHash ),
        // fireHash = the L1 _rollingHash right after CALL_BEGIN of the Alice→A call
        l2ToL1Calls = [],                   // nothing executes on L1 inside this frame
        revertedOrStaticRollingHash = 0,    // required 0 for a SUCCESS frame (prover constraint)
        success = true,
        returnData = abi.encode(1)          // B's pre-computed return
    } ]
    rollingHash = H( seed → CALL_BEGIN(hash(false, Alice, L2, A, MAINNET, 0, callBProxy))
                     → NESTED_BEGIN(hash of A→B) → NESTED_END
                     → CALL_END(true, <A's return>) )
    success     = true
    returnData  = ""
    stateUpdates = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=0 } ]
```

**L2 execution table** (`loadExecutionTable`):
```
[0] DEFERRED
    // L2-OUTGOING key (callGas = 0 under useGasLeft = false)
    proxyEntryHash = hashL2Out(false, Alice, L2, A, MAINNET, 0, 0, callBProxy)
    incomingCalls = [{ src=A, srcRollup=MAINNET, dest=B, value=0, data=increment, ... }]
                    // the A→B leg is what executes on L2
    expectedOutgoingCalls = []
    rollingHash = H( seed → CALL_BEGIN(hash of A→B, targetRollup=L2) → CALL_END(true, abi.encode(1)) )
    success     = true
    returnData  = <A's return>
```

**Execution**:
- **L2**: Alice's L2 tx → A's proxy → `executeCrossChainCall(Alice, callBProxy)` → consumes entry [0]. The processor runs the A→B call through A's proxy on L2 — the real B executes — then returns `<A's return>` (pre-computed) to Alice.
- **L1**: `postAndVerifyBatch` runs entry [0] in the immediate run (or via `executeL2Txs`). The real A executes via Alice's proxy; when A calls B's proxy on L1 → `executeCrossChainCall(A, increment)` → reentrant → `_consumeNestedCall` matches `expectedL1ToL2Calls[0]` by its position key → returns `abi.encode(1)` to A.

### Forced revert via `revertNextNCalls`

When a chain's prover output marks a cross-chain call as reverted even though the destination call would succeed, the protocol uses `revertNextNCalls` to delineate the contiguous run of calls whose **state effects** must be rolled back. The rolling hash still records the calls' real outcomes (typically `success=true`); only the EVM state changes are discarded.

Example: SCA on L2 calls SCB which makes a successful cross-chain call to Counter on L1, then SCA reverts. From L1's perspective Counter.increment() ran cleanly, but L2's prover output says the higher-level transaction was rolled back, so L1 must not retain the state change.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] IMMEDIATE (L2Tx)   proxyEntryHash = bytes32(0)
    destinationRollupId = L2
    l2ToL1Calls = [
      // The cross-chain call to Counter is wrapped in a revert span of length 1:
      { revertNextNCalls=1, isStatic=false, src=SCB, srcRollup=L2, dest=Counter, value=0, data=increment },
    ]
    expectedL1ToL2Calls = []
    rollingHash = H( seed → CALL_BEGIN(hash of the Counter call) → CALL_END(true, abi.encode(1)) )
    // The hash chain still includes Counter's success — the span rolls back state, not the rolling hash.
    success     = true
    returnData  = ""
    stateUpdates = [ ... ]   // whatever net delta the prover committed to (the parent tx rolled back on L2)
```

**Mechanism**: when the processor sees `calls[0].revertNextNCalls == 1`, it zeroes the marker in its memory copy, slices the 1-call span, and self-calls `executeInContextAndRevert(span)`, which processes the call (Counter.increment) and then reverts with `ContextResult(rollingHash, reentrantConsumed, 0)`. The revert undoes Counter's effects on L1, but the payload carries the `_rollingHash` computed inside the span back out — so the entry-level hash check still observes Counter's success contribution. `CallsReverted` is emitted and the walk skips past the span.

A single mechanism handles atomic rollback: there are no continuation entries to look up and no per-rollup state-root restoration calls.

### Reverting reentrant call (`success = false` frame)

When a reentrant cross-chain call **must revert** (e.g., the destination wraps the call in `try/catch`), it is a `success = false` entry in the same unified reentrant table:

**`entry.expectedL1ToL2Calls`** of the consuming entry:
```
[k] ExpectedL1ToL2Call {
    expectedL1toL2Hash = keccak256( hash(false, D, MAINNET, B, L2, 0, increment) ‖ fireHash ),
        // fireHash = the live _rollingHash at the instant B's proxy is called — this pins the
        // exact execution point, replacing any positional coordinates
    l2ToL1Calls = [],                     // sub-calls that run (then roll back) during the attempt
    revertedOrStaticRollingHash = H( NESTED_BEGIN(crossChainCallHash) folded onto fireHash
                                     → ...sub-call folds... ),   // tagged schema, checked before reverting
    success = false,
    returnData = <revert payload>,
}
```

When B's proxy is called from inside D's execution (a normal CALL frame), the call routes to `executeCrossChainCall` → `_consumeNestedCall`, which matches the frame by its position key, advances the cursor, folds `NESTED_BEGIN`, runs the frame's own sub-array, checks the sub-hash against `revertedOrStaticRollingHash`, and reverts with the cached payload. D catches the revert and continues; the terminal revert rolled back the sub-calls' state **and** the cursor bump, so nothing was consumed.

### Same action twice (sequential)

When the same proxy call happens N times in a single transaction (e.g., a contract calling B's proxy twice in a row), each call consumes the next matching entry in the queue. Each entry has the same `proxyEntryHash`; the forward scan from the advancing cursor differentiates them.

```
[0] DEFERRED   proxyEntryHash = hash(B, ...) ... returnData = <first return>
[1] DEFERRED   proxyEntryHash = hash(B, ...) ... returnData = <second return>
```

The destination rollup's `entryQueueIndex` advances from 0 → 1 → 2; the second call lands at `verificationByRollup[B's rollupId].entryQueue[1]`. For *reentrant* repeats inside one entry, the `expectedRollingHash` component of each frame's key differs (the hash has moved), so identical calls at different points never collide.

### Continuation pattern (sequential entries within a flow)

A single user action that performs multiple top-level cross-chain calls produces multiple entries. Each top-level entry-point call consumes one entry. There is no `nextAction` redirection — the user's contract makes each call explicitly, and the table has one entry per top-level call.

For sub-calls **within** a single entry, placement follows the frame structure: calls that execute at the entry's top level live in `entry.l2ToL1Calls[]` (L2: `entry.incomingCalls[]`); calls that execute inside a reentrant frame live in that frame's own `l2ToL1Calls[]` (L2: `incomingCalls[]`) sub-array.

---

## L1 vs L2 Entries

| Aspect | L1 (`EEZ`) | L2 (`EEZL2`) |
|---|---|---|
| **How loaded** | `postAndVerifyBatch(ProofSystemBatchPerVerificationEntries calldata batch)` — single struct (not array) carrying `expectedStateRootPerRollup[]`, `entries[]`, `staticEntries[]`, `immediateEntryCount`, `immediateStaticEntryCount`, `proofSystems[]`, `rollupIdsWithProofSystems[]`, `blobIndices[]`, `callData`, `proofs[]`, `blockNumber`, `bindMsgSenderInPublicInput` | `loadExecutionTable(entries, staticEntries)` by `SYSTEM_ADDRESS`; OR `executeIncomingCrossChainCall(...)` for inbound delivery from another rollup (system-only, atomically loads + executes `entries[0]`) |
| **State deltas** | Required: ≥1 per entry, strictly increasing by rollupId, all in batch, `destinationRollupId` ∈ deltas, call sources ∈ deltas (all validation-time); `currentState` checked at consumption (match predicate + `StateRootMismatch` gate); `etherDelta` accounted | No `stateUpdates` field at all — the L2 entry struct omits it (no rollup state on L2) |
| **Matching logic** | Forward-scan from the per-rollup cursor (`_findMatchingEntry`) for the first FULL match: `proxyEntryHash` + `destinationRollupId == destRid` + every `currentState` pin live; non-matches skipped; end-of-queue → `ExecutionNotFound`. Transient branch uses one global cursor with the same predicate | Forward-scan `entries` from `entryIndex` by `proxyEntryHash` alone; end-of-table → `ExecutionNotFound` |
| **Top-level reverting call** | Normal `ExecutionEntry` with `success = false` — run, verified, then reverted with `returnData` (no fallback pool) | Same |
| **Static entries** | Pool: batch `staticEntries[]` → `_transientStaticEntries` (leading `immediateStaticEntryCount`, scanned exclusively while a batch is mid-flight) / per-rollup `staticEntryQueue`. Match: `proxyEntryHash` + `destinationRollupId` + all `expectedStateRoots` pins live (full scan). No block gate — resolvable while pins hold | `staticEntries` pool, matched by `proxyEntryHash` alone, same-block only (`lastLoadBlock == block.number`; no state roots to pin) |
| **Ether accounting** | Per-entry invariant `Σ etherDelta == _entryEtherDelta` (net inbound − successful outbound) | None; `msg.value` is forwarded to `SYSTEM_ADDRESS` |
| **Same action hash** | Each occurrence consumes the next matching entry on the destination rollup's queue; sequential ordering distinguishes them | Same |
| **Immediate/deferred split** | Leading L2Tx run executed straight from calldata; meta-hook remainder in `_transientEntries` / `_transientStaticEntries`; rest published to per-rollup queues **unconditionally** (soundness via the `currentState` match) | No transient tables — all entries go directly to `entries` / `staticEntries` |
| **Meta hook** | `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` if immediate-prefix entries remain past the leading L2Tx run (codeless sender reverts `MetaEntriesWithoutReceiver`) | Not present |
| **Immediate entry** | Leading `proxyEntryHash == 0` entries run inline during `postAndVerifyBatch` via `_attemptExecuteImmediateL2Txs` (try/catch self-call); a failed one emits `L2TxSkipped` and is skipped; an all-failed non-empty run reverts `AllImmediateL2TxsFailed` | Not expressible — no consumption path matches `proxyEntryHash == 0` on L2. Inbound work arrives via `executeIncomingCrossChainCall` (non-zero `proxyEntryHash`); locally-initiated work is consumed by the user's own tx through a proxy |
| **`executeL2Txs`** | `executeL2Txs(uint64 rollupId)` — permissionless; consumes the next matching entry on `rollupId`'s queue with `proxyEntryHash == bytes32(0)` | Not present (L2 has no `executeL2Txs` entry point) |
| **Inbound system-only call** | Not present | `executeIncomingCrossChainCall(entries, staticEntries)` — `onlySystemAddress`, payable (`msg.value` mints the total inbound ETH; prover-constrained, no balance check), atomically replaces the table, requires non-empty `incomingCalls` on `entries[0]`, checks `entries[0].proxyEntryHash` against the hash of `incomingCalls[0]` (`EntryHashMismatch`), consumes `entries[0]` (emitting `IncomingCrossChainCallExecuted` and `ExecutionConsumed(hash, 0)`), returns `entries[0].returnData` |

### Atomicity via Solidity revert

If the calling contract reverts at the Solidity level (e.g., `require()` failure) while inside `executeCrossChainCall` or `executeL2Txs`, the entire EVM transaction reverts — the cursor bump, all transient writes, all state delta applications, everything rolls back. This is **different** from the protocol's `revertNextNCalls` mechanism, which selectively rolls back the inner span while propagating the rolling hash and reentrant cursor across the boundary, and from a `success = false` entry, whose revert is the *verified, intended* outcome.

Use Solidity revert for top-level failures (whole-transaction abort). Use `revertNextNCalls` for inner spans whose state must be rolled back while the outer execution continues.

---

## Don'ts

### Never mark a reverting reentrant call `success = true`

A `success = true` reentrant entry commits its frame into the host's continuous rolling hash and returns. A call the destination expects to revert must be a `success = false` entry — `_resolveNestedReentrant` verifies the sub-hash and then reverts with `returnData`, rolling back the frame's state and cursor bump so the protocol observes "attempted and failed" exactly. Don't wrap it in `revertNextNCalls` either — that mechanism is for forced-reverting *successful* calls in a frame's flat array, not for reentrant frames.

### Never split nested calls into separate transactions

If a cross-chain flow involves reentrant calls (e.g., L1→L2→L1), the reentrant frame lives in the entry's `expectedL1ToL2Calls[]` (L2: `expectedOutgoingCalls[]`) with its own sub-array. The whole entry resolves in **one transaction per chain**, not multiple separate transactions.

Wrong:
```
TX1 on L1: Alice → proxy → executeCrossChainCall (CALL into L2's space)
TX2 on L1: system → executeCrossChainCall (reentrant CALL back from L2)  ← WRONG: separate tx
```

Right:
```
TX1 on L1: Alice → proxy → executeCrossChainCall
  → consumes one entry; the reentrant call hits the manager via a proxy mid-execution and
    matches expectedL1ToL2Calls[k] by keccak256(crossChainCallHash ‖ live rolling hash)
  → the frame's own l2ToL1Calls[] run inside it
  → all calls resolve within this single tx
```

### Never use `executeL2Txs` for L1→L2 flows

`executeL2Txs(rollupId)` exists only on L1 and consumes the next matching entry on that rollup's queue with `proxyEntryHash == 0` — it commits pure L2 transactions (and L2 transactions that touch L1) on L1. For L1→L2 flows, the user's call enters the protocol via `executeCrossChainCall` on the proxy on L1, and the L2 side is delivered by the system via `executeIncomingCrossChainCall`. Don't call `executeL2Txs` to start an L1→L2 flow.

### Never call `executeL2Txs` while inside a cross-chain execution

`executeL2Txs(rollupId)` reverts with `L2TxNotAllowedDuringExecution` if `_insideExecution() == true`. L2Tx entries are top-level only; reentrant calls must use the proxy path.

### Consistent rollupId / sourceRollupId semantics

- `targetRollupId` in every call hash = **target** (where the call executes)
- `sourceRollupId` in every call hash = **origin** (where the caller lives)
- On L1, calls produced by `executeCrossChainCall` have `sourceRollupId = MAINNET (0)` — top-level and reentrant alike.
- On L2, calls produced by `executeCrossChainCall` have `sourceRollupId = ROLLUP_ID` (this L2's ID).
- `isStatic` is part of the hash: a read-only call and an otherwise-identical state-changing call hash differently. Static hashes always carry `value = 0`.
- Every *executed* call's `sourceRollupId` must be a rollup the entry proved (∈ `stateUpdates` on L1), and it can never be the executing chain's own ID (a same-network proxy reverts `SameNetworkProxy`).

### Don't rely on positional grouping across frames

Each call array — the entry's `l2ToL1Calls[]` (L2: `incomingCalls[]`) and every reentrant frame's own sub-array — is executed in array order, to completion, by its own frame. The semantic structure (which calls belong to which frame) comes from **where the array lives**, not from counts or a shared cursor. What binds frames to execution points is the `expectedL1toL2Hash` key: the live rolling hash at fire time. The builder must simulate the execution to capture each frame's fire-point hash exactly; a frame keyed at the wrong point simply never matches, and the resulting `CALL_NOT_FOUND` fold fails the entry.
