# Execution Entry Specification

How to correctly build execution entries for L1 (`postAndVerifyBatch`) and L2 (`loadExecutionTable` / `executeIncomingCrossChainCall`).

The protocol uses a **per-frame, sequential** execution model: every entry carries its own array of top-level calls processed in order (L1: `L2ToL1Call[] l2ToL1Calls`; L2: `CrossChainCall[] incomingCalls`), every reentrant frame carries its **own** sub-call array inside one unified expected-reentrant table (L1: `ExpectedL1ToL2Call[] expectedL1ToL2Calls`; L2: `ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls`), and a single `rollingHash` verifies the entire execution tree at the end.

---

## Entry Structure

```solidity
// L1 (src/interfaces/IEEZ.sol)
struct ExecutionEntry {
    StateDelta[]         stateDeltas;          // the entry's true state transition (≥1, enforced on-chain)
    bytes32              proxyEntryHash;       // inbound proxy-entry call hash; bytes32(0) = L2Tx (immediate / executeL2Txs)
    L2ToL1Call[]         l2ToL1Calls;          // the entry's TOP-LEVEL calls only (reentrant frames carry their own)
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;  // unified reentrant table: SUCCESS / STATIC / REVERTED flavours
    bytes32              rollingHash;          // expected rolling hash over all calls + nestings
    uint64               destinationRollupId;  // routes to a per-rollup queue; must be ∈ stateDeltas
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

The L2 struct does **not** share L1's layout: `stateDeltas` and `destinationRollupId` are L1-only fields and are dropped entirely on L2 (not just left empty). L2's vocabulary is self-relative directional — `incomingCalls` are cross-chain calls executed on this L2 for a remote caller, `expectedOutgoingCalls` are reentrant calls fired from this L2 — because the counterparty can be L1 or another L2, so absolute names like `l1ToL2Calls` would often be wrong.

A top-level entry can **succeed or revert** — the `success` flag decides. When `success == true`, `executeCrossChainCall` returns `entry.returnData` regardless of inner-call outcomes (a naturally-reverting inner call is captured by `CALL_END(false, retData)` in the rolling hash). When `success == false`, the entry is fully executed and verified (rolling hash, ether invariant), then **everything is reverted** with `returnData` as the revert payload — state deltas, cursor advance, inbound value all roll back, and the caller may `try/catch` the revert. Reverting REENTRANT calls are `success == false` `ExpectedL1ToL2Call`s (L2: `ExpectedOutgoingCrossChainCall`s) inside the entry's unified table, and a top-level reverting **read** is a `StaticExecutionEntry` in the static pool.

### Per-rollup queue routing

`destinationRollupId` selects which rollup's queue this entry is loaded into during `postAndVerifyBatch`'s deferred publish. The central `EEZ` registry stores per-rollup queues (`verificationByRollup[rid].entryQueue` and `verificationByRollup[rid].staticEntryQueue`) with a per-rollup cursor (`entryQueueIndex`). Each `postAndVerifyBatch` call carries one `ProofSystemBatchPerVerificationEntries` payload covering one or more rollups; entries are routed by `destinationRollupId` into the matching rollup's queue. Validation requires `destinationRollupId` to be among the entry's own `stateDeltas` rollups (`EntryDestinationNotInStateDeltas`), so an entry can only be parked in a queue it actually proved. Cross-rollup state is independent — a stuck cursor on one rollup does not block another. See `MULTI_PROVER_SPEC.md` for the multi-prover / per-rollup-queue specifics.

### IMMEDIATE entries (`proxyEntryHash == 0` — "L2Tx" entries)

A leading run of the batch's immediate prefix (`entries[0..immediateEntryCount)`) may have `proxyEntryHash == 0`. Each such entry is executed inline by `postAndVerifyBatch` itself, **straight from calldata** (never SSTOREd whole; only its reentrant table is parked transiently), and represents the batch's immediate work — pure L2 transactions or L2 transactions that touch L1. State deltas are applied, calls are processed, and the rolling hash is verified, all within `postAndVerifyBatch`. Each entry runs in a `try/catch` self-call (`_attemptExecuteImmediateL2Txs`); if it reverts, the registry emits `L2TxSkipped(transientIdx, revertData)` and the loop advances — not a hard error. Two hard errors do exist: a non-empty leading L2Tx run where **every** entry reverted unwinds the whole post (`AllImmediateL2TxsFailed`), and an `immediateEntryCount` that strands a leading L2Tx into the queue is rejected at validation (`ImmediateCountStrandsLeadingL2Tx`). Immediate-prefix entries past the leading L2Tx run are meta-hook entries (see the Transaction Model section).

### DEFERRED entries (`proxyEntryHash != 0`, or L2Txs past the leading run)

Loaded into `_transientEntries` (the immediate-prefix remainder, consumed via the meta hook) or into per-rollup `verificationByRollup[rid].entryQueue` (entries past `immediateEntryCount`). Consumed by `executeCrossChainCall` or `executeL2Txs(rollupId)`, and only in the block they were posted (`lastVerifiedBlock(rid) == block.number`; mismatch reverts `ExecutionNotInCurrentBlock`). Each call computes the expected cross-chain call hash from the proxy/call-site context (`executeL2Txs` expects `bytes32(0)`) and **forward-scans** the queue from the cursor for the first entry that fully matches (`_entryMatches`): identity (`proxyEntryHash`), routing (`destinationRollupId`), and state preconditions (every `StateDelta.currentState` equals the live root). Non-matching entries are skipped (a previously-attempted `success == false` entry, whose revert left the cursor in place, doesn't block later calls); no match by end of queue reverts `ExecutionNotFound`. While a batch is mid-flight, consumption is routed through `_transientEntries` with one **global** cursor (`_transientEntryIndex`) instead. Cursor advance is per-rollup on the persistent path.

---

## Action Hash

Every cross-chain call is identified by a single hash computed from seven fields (order: `isStatic` → FROM pair → TO pair → value → data):

```solidity
crossChainCallHash = keccak256(abi.encode(
    bool    isStatic,        // read-only STATICCALL flag — a static read hashes distinctly
    address sourceAddress,   // caller identity on the source rollup
    uint64  sourceRollupId,  // source rollup ID
    address targetAddress,   // contract being called on the target rollup
    uint64  targetRollupId,  // target rollup (which chain executes this call)
    uint256 value,           // ETH sent with the call (always 0 when isStatic)
    bytes   data             // calldata (selector + args)
))
```

The on-chain contracts reconstruct the hash from the proxy's identity (`originalRollupId`, `originalAddress`) and the live call context (`msg.value`, `callData`, the proxy's caller, `MAINNET_ROLLUP_ID` on L1 or `ROLLUP_ID` on L2) via the `public pure` helper `computeCrossChainCallHash` (identical formula on both managers, so a single off-chain helper can target either chain).

### Hash semantics by entry point

| Entry point | isStatic | sourceAddress | sourceRollupId | targetAddress | targetRollupId | value | data |
|---|---|---|---|---|---|---|---|
| `executeCrossChainCall` (L1 proxy) | `false` | proxy's caller | `MAINNET_ROLLUP_ID` (0) | proxy's `originalAddress` | proxy's `originalRollupId` | `msg.value` | original calldata |
| `executeCrossChainCall` (L2 proxy) | `false` | proxy's caller | this L2's `ROLLUP_ID` | proxy's `originalAddress` | proxy's `originalRollupId` | `msg.value` | original calldata |
| Reentrant call (matches an `ExpectedL1ToL2Call` on L1 / `ExpectedOutgoingCrossChainCall` on L2) | same as above (proxy on the chain making the reentrant call) | same | same | same | same | same | same |
| `executeL2Txs` | n/a — entry has `proxyEntryHash == 0` | — | — | — | — | — | — |
| `staticCrossChainCall` | `true` | proxy's caller | this chain's rollup ID | proxy's `originalAddress` | proxy's `originalRollupId` | `0` (static is value-free) | original calldata |
| `executeIncomingCrossChainCall` (L2, system) | `false` | explicit `sourceAddress` param | explicit `sourceRollup` param | explicit `destination` param | this L2's `ROLLUP_ID` | explicit `value` param (`== msg.value`) | explicit `data` param |

The hash is fully determined by the seven fields above; nothing else (caller depth, parent frame, position in the entry) feeds into it. Position is pinned separately, by the rolling hash — see the reentrant table's `expectedL1toL2Hash` key below.

### Cross-chain hash consistency

When the same logical call appears on both chains, the `crossChainCallHash` is identical on both sides:

- **L1→L2 proxy call** generated by `executeCrossChainCall` on L1 (e.g., user calls B's proxy on L1) has `targetRollupId = L2`, `sourceRollupId = MAINNET (0)`. `executeIncomingCrossChainCall` on L2 recomputes the same hash from its explicit params and reverts `EntryHashMismatch` if `entries[0].proxyEntryHash` diverges.
- **Reentrant L2→L1 call** generated mid-execution on L2 (D calls C's proxy on L2) has `targetRollupId = MAINNET`, `sourceRollupId = L2`. That same hash is folded into `NESTED_BEGIN` inside L2's reentrant frame **and** into `CALL_BEGIN` for the call actually executed on L1 — both chains observe the same call identity from their own side.

The seven hash inputs alone determine the hash, with no positional or contextual term mixed in. Note the two chains' **rolling hashes** are NOT equal for a mirrored flow: each side folds only the calls that execute on it, and L1 additionally seeds its hash with the entry's state-delta context. The builder must simulate both sides to predict exact `data`, return data, and `value`.

---

## L2ToL1Call (L2: `CrossChainCall`)

```solidity
struct L2ToL1Call {
    uint16  revertNextNCalls; // >0 = force-revert the next N calls' state effects (this one included)
    bool    isStatic;         // dispatch via STATICCALL (read-only; value must be 0)
    address sourceAddress;    // caller identity on the source rollup (used to derive sourceProxy)
    uint64  sourceRollupId;   // caller's rollup ID
    address targetAddress;    // contract to call on this chain
    uint256 value;            // ETH sent
    bytes   data;             // calldata
}
```

L2's `CrossChainCall` (`IEEZL2.sol`) is field-for-field identical; only the struct name differs.

The processor (`_processNCalls`) walks the given call array by a plain local index and, for each non-revert-span call, derives the `sourceProxy` address from `(sourceAddress, sourceRollupId)`, auto-creates the proxy if it doesn't exist, and routes the call through `CrossChainProxy.executeOnBehalf(targetAddress, data){value: value}` — a plain `.call`, or a `staticcall` when `isStatic` (a static call carrying value is malformed and reverts `StaticCallWithValue`). If the destination call itself reverts, the proxy's `.call` returns `(success=false, retData=revertReason)` and that is hashed into `CALL_END` — natural reverts need no special wrapping. Each call's identity (its `crossChainCallHash`, with `targetRollupId` = the executing chain's ID) is folded into `CALL_BEGIN`, so the hash commits to *which* call ran, not just its result. Every call's `sourceRollupId` must be in the entry's proven set (its `stateDeltas` on L1) — enforced at batch validation (`CallSourceNotVerified`).

### `revertNextNCalls`: forced-revert context

`revertNextNCalls > 0` is the **forced-revert** mechanism: the next `revertNextNCalls` calls (including this one) execute, succeed, and have their state effects rolled back at the protocol layer. The rolling hash still commits to the calls' real outcomes (typically `success=true` with the captured `returnData`); only the EVM state changes disappear. The processor:

1. Bounds-checks the span against the current call array (`RevertSpanOutOfBounds` on a malformed entry).
2. Zeros the trigger's `revertNextNCalls` in its throwaway **memory** copy, then slices the span (`_sliceL2ToL1Calls` / `_sliceCrossChainCalls`) into a fresh array whose first call reads as a normal call.
3. Self-calls `this.executeInContextAndRevert(span)` — that function processes the whole slice and **always reverts** with `error ContextResult(bytes32 rollingHash, uint256 reentrantConsumed, uint256 callsProcessed)` (the 3rd field is always 0 on both sides; it exists for the shared decoder).
4. The revert rolls back **all** transient storage modifications inside the self-call **and** all destination state changes the inner calls produced.
5. The processor decodes `ContextResult` and restores `_rollingHash` and the reentrant cursor (L1: `_lastL1ToL2CallConsumed`; L2: `_lastOutgoingCallConsumed`) to the values **observed at the end of the reverted span**, bridging the rolling hash and cursor across the revert boundary, then emits `CallsReverted` and skips past the span.

A reentrant no-match observed *inside* the span needs no special transport: `CALL_NOT_FOUND` is folded directly into `_rollingHash`, which rides out in the `ContextResult` payload — the divergence surfaces as `RollingHashMismatch` at the entry boundary.

`revertNextNCalls` covers a contiguous run of calls within one call array (an entry's top-level array or one reentrant frame's own sub-array). Nested spans are a prover convention violation rather than an on-chain check — the processor would mechanically recurse, but the outer span's rollback already discards the inner state, so the prover never emits one.

#### When `revertNextNCalls` is the right tool

The canonical use is a cross-chain call from rollup A to rollup B where B's destination call **succeeded**, but the prover output marks the call as reverted in A's view of the world (for example, because the higher-level transaction containing the call was rolled back on A). When B runs the entry, `revertNextNCalls = 1` ensures B's state does not retain effects that A no longer commits to.

For natural failures — a destination contract that simply `revert`s — `revertNextNCalls = 0` is correct and simpler:

- The proxy `.call` returns `success=false` with the destination's revert payload as `retData`.
- `CALL_END(false, retData)` is hashed into the rolling hash.
- The destination's own revert rolls back the destination's state.

Wrapping a single naturally-reverting call in `revertNextNCalls = 1` is purely ceremonial — it produces the same rolling hash and the same on-chain state as `revertNextNCalls = 0`, with an extra self-call frame for nothing. The mechanism only earns its cost when state would otherwise survive.

**Reentrant reverted calls take a different path entirely.** When the destination contract called from `_processNCalls` re-enters the manager via a proxy (a try/catch'd cross-chain call to another rollup), a revert of that nested call is expressed as a `success == false` entry in the SAME unified `expectedL1ToL2Calls[]` (L2: `expectedOutgoingCalls[]`) table — not `revertNextNCalls`. `_consumeNestedCall` matches it by its content-addressed key, and `_resolveNestedReentrant` runs the frame's own sub-array as a mini-entry, checks the sub-hash against `revertedOrStaticRollingHash`, then reverts with the cached `returnData`; the destination's `try/catch` catches it, and the terminal revert rolls back the sub-execution's state, hash, and cursor bump. See the Reentrant Table section below.

Three distinct revert paths, one decision tree:

- Top-level call that reverts → `ExecutionEntry` with `success = false` (run, verified, then reverted with `returnData`). A top-level reverting **read** is a `StaticExecutionEntry` with `success = false` instead.
- Reentrant (re-entered via proxy) call that reverts → `success = false` entry in the unified reentrant table.
- Successful call(s) whose state must be force-reverted at the protocol layer → `revertNextNCalls > 0`. (An inner natural revert of a non-reentrant call is just a plain call in the array — `CALL_END(false, retData)` captures it.)

---

## ExpectedL1ToL2Call (L2: `ExpectedOutgoingCrossChainCall`)

```solidity
struct ExpectedL1ToL2Call {
    bytes32      expectedL1toL2Hash;           // position key: keccak256(crossChainCallHash ‖ expectedRollingHash)
    L2ToL1Call[] l2ToL1Calls;                  // the reentrant frame's OWN sub-calls, run to completion
    bytes32      revertedOrStaticRollingHash;  // expected sub-call hash — checked for STATIC / REVERTED flavours
    bool         success;                      // whether the reentrant call returns or reverts
    bytes        returnData;                   // pre-computed return value (revert payload when !success)
}
```

L2's `ExpectedOutgoingCrossChainCall` (`IEEZL2.sol`) is field-for-field identical modulo names (`expectedOutgoingHash`, `incomingCalls`).

One unified table holds **every** reentrant flavour — plain SUCCESS, read-only STATIC, and try/catch'd REVERTED (`!success`). Each is content-addressed by a single key:

```solidity
expectedL1toL2Hash = keccak256(abi.encodePacked(crossChainCallHash, expectedRollingHash))
```

where `crossChainCallHash` already folds `isStatic` (a static read keys distinctly from a state-changing call) and the routed rollup, and `expectedRollingHash` is the live `_rollingHash` at the instant the call fires — which uniquely pins the execution point, since the hash chain folds every prior call and nesting boundary. There is no positional index to record: the hash IS the position.

When a destination contract called by the processor calls back into a proxy (e.g., contract D on L2 calls C's proxy on L2 to reach C on L1), `executeCrossChainCall` detects `_insideExecution() == true` and routes to `_consumeNestedCall`:

1. Compute `expectedL1toL2Hash = keccak256(crossChainCallHash ‖ _rollingHash)`.
2. Forward-scan the active entry's table from `_lastL1ToL2CallConsumed` (L2: `_lastOutgoingCallConsumed`) — calls are consumed in order, never before the cursor; the first key match IS the entry. On a match, advance the cursor past it, then resolve via `_resolveNestedReentrant`:
   - Hash `NESTED_BEGIN(crossChainCallHash)` into `_rollingHash`.
   - Run the frame's **own** `l2ToL1Calls[]` (L2: `incomingCalls[]`) sub-array to completion via `_processNCalls` — these fold into the same continuous `_rollingHash`.
   - `success == true`: hash `NESTED_END`, return `returnData` to the destination contract.
   - `success == false`: check `_rollingHash == revertedOrStaticRollingHash` (else `RollingHashMismatch`), then revert with `returnData` — the terminal revert rolls back the frame's state, hash, and cursor bump.
3. No match: fold `CALL_NOT_FOUND(crossChainCallHash)` into `_rollingHash` and return empty bytes. The divergence surfaces as `RollingHashMismatch` at the entry boundary — it survives any intermediate `try/catch` (and any `revertNextNCalls` boundary, riding the `ContextResult` payload). On L1 there is one additional gate before all of this: the reentrant call's target rollup must be in the executing entry's proven set (`ReentrantDestinationNotVerified`).

A reverted sub-execution reuses the **host table** for its own deeper reentrant calls (Solidity forbids recursive structs); the live `_rollingHash` folded into each key keeps the contexts distinct. STATIC-flavour entries in this table are matched only via `staticCrossChainCall` (their `crossChainCallHash` folds `isStatic = true`, so a CALL-keyed scan can never hit them) — see the Static Entries section.

### Reverting reentrant calls are table entries too

A reentrant call that **must revert** (the caller catches it with `try/catch`) is a `success == false` entry in the same table — no separate structure, no `revertNextNCalls` wrapper. Its `l2ToL1Calls[]` are any sub-calls that execute (then roll back) during the attempt, `revertedOrStaticRollingHash` is the expected `_rollingHash` after `NESTED_BEGIN` plus those sub-call folds, and `returnData` is the revert payload. Because the terminal revert rolls back the cursor bump, the consumed slot is "un-consumed" again — the key's `expectedRollingHash` component is what keeps a retried or repeated call unambiguous.

### Completeness accounting

There are no per-frame call counts and no shared flat array: each frame's array is run to completion by `_processNCalls`, so completeness is **structural** for calls, and there is no cursor-vs-length check at the entry boundary. Completeness of the SUCCESS reentrant entries rests on the rolling hash: a skipped success frame omits its `NESTED_BEGIN`/`NESTED_END` folds and diverges the hash. An **unconsumed** table entry is inert — the unified table may legitimately contain STATIC and REVERTED entries that a given run never touches (e.g. inside a rolled-back span), so no table-length check is performed.

---

## Static Entries (`StaticExecutionEntry` top-level / STATIC-flavour reentrant entries)

Read-only cross-chain calls (`STATICCALL`s through a proxy) resolve in two homes (full spec: `LOOKUP_SPEC.md`):

```solidity
// NESTED — a STATIC-flavour entry in the unified reentrant table (see previous section).
// Keyed by expectedL1toL2Hash where crossChainCallHash folds isStatic = true and value = 0.
// `l2ToL1Calls[]` are read-only sub-calls run via STATICCALL; `revertedOrStaticRollingHash`
// uses the UNTAGGED static schema (starts at bytes32(0), keccak(prev, success, retData) per call).
// `success = false` ⇒ the resolution reverts with `returnData` (a reverting read).

// TOP-LEVEL — lives in the static pool (batch.staticEntries → _transientStaticEntries /
// per-rollup staticEntryQueue; L2: the persistent staticEntries table).
// Resolvable ONLY when !_insideExecution().
struct StaticExecutionEntry {
    ExpectedStateRootPerRollup[] expectedStateRoots;  // L1 only — state-root pins, part of the MATCH predicate
    bytes32      proxyEntryHash;       // inbound call hash (isStatic = true, value = 0)
    L2ToL1Call[] l2ToL1Calls;          // read-only sub-calls run via STATICCALL during resolution
    bytes32      rollingHash;          // untagged static schema: keccak(prev, success, retData)
    uint64       destinationRollupId;  // L1 only — routes the pool entry; must be pinned
    bool         success;              // false ⇒ resolution reverts with returnData
    bytes        returnData;
}
```

(L2's `StaticExecutionEntry` mirrors this minus `expectedStateRoots` and `destinationRollupId`.)

Resolution (`_resolveStaticEntry`, shared body for both homes): run the sub-calls via STATICCALL in order, folding the **untagged** accumulator `keccak256(prev, success, retData)` from `bytes32(0)`; the result is always compared against the stored hash (an empty `calls[]` must match hash `0`), then `returnData` is returned — or the resolution reverts with it when `!success`. Referenced source proxies must already be deployed (CREATE2 is unavailable inside a STATICCALL frame; a codeless proxy reverts `StaticCallProxyNotDeployed` rather than letting the prover pre-hash a silent no-op).

### Position pinning

- **Nested (inside an execution)**: the STATIC entry's `expectedL1toL2Hash` folds the live `_rollingHash` at the moment the read fires — the same content-addressed key the reentrant CALLs use, so the read is pinned to an exact execution point. The scan runs forward from the reentrant cursor (a static read cannot advance the cursor — `staticCrossChainCall` is `view` — but it still only matches at/after it). A miss reverts `ExecutionNotFound` immediately. Because the key includes the position, a single entry can carry several reads of the same target at different phases with no ambiguity.
- **Top-level (outside any execution)**: no execution point exists, so on L1 `expectedStateRoots[]` pins the entry to the state trajectory instead — the match predicate is `proxyEntryHash` + `destinationRollupId == the calling proxy's rollup` + **every pin equals the live root** (full scan; a non-matching candidate is skipped, not an error). Top-level static entries have **no block gate**: they stay resolvable across blocks as long as their pins hold (until the next batch touching that rollup wipes its `staticEntryQueue`). While a batch is mid-flight, ONLY the batch's transient static pool (`_transientStaticEntries`) is scanned — the transient phase is self-contained (see `docs/CAVEATS.md`). On L2 the persistent `staticEntries` pool is matched by `proxyEntryHash` alone (no state roots to pin).

### When to use which structure

| Situation | Use |
|---|---|
| Reentrant cross-chain call that **succeeds** | `success = true` entry in the unified reentrant table |
| Reentrant cross-chain call that **reverts** (caller catches with try/catch) | `success = false` entry in the unified reentrant table |
| Reentrant cross-chain `STATICCALL` (read-only; may return or revert) | STATIC-flavour entry in the unified reentrant table (`crossChainCallHash` folds `isStatic = true`; `success` as appropriate) |
| Top-level static read (returning **or** reverting) | Top-level `StaticExecutionEntry` in the pool (`success` as appropriate) |
| Top-level cross-chain call that reverts (state-changing) | `ExecutionEntry` with `success = false` |
| Inner natural revert of a non-reentrant call | Plain call in the frame's array with `revertNextNCalls = 0`; `CALL_END(false, retData)` captures it |
| Successful call(s) whose state must be force-reverted | `revertNextNCalls > 0` on the first call of the span |

**How the manager picks** (for a reentrant call that hits the manager via a proxy):

1. If the proxy is in a real STATICCALL frame (its `tstore` self-check reverts), the proxy routes to `staticCrossChainCall`, which computes the hash with `isStatic = true` and scans the active entry's unified table (forward from the cursor) for the key — only STATIC-flavour entries can match. Miss → `ExecutionNotFound`.
2. Otherwise (normal CALL frame), the proxy routes to `executeCrossChainCall` → `_consumeNestedCall`, which computes the hash with `isStatic = false` and forward-scans for the key. A match resolves as SUCCESS or REVERTED per its `success` flag; a miss folds `CALL_NOT_FOUND` and returns empty bytes (the entry later fails `RollingHashMismatch` at its boundary) — identically on L1 and L2.

---

## State Deltas (L1 only)

`StateDelta` exists only in `IEEZ.sol` — the L2 entry struct has no `stateDeltas` field.

```solidity
struct StateDelta {
    uint64  rollupId;       // which rollup's state changes
    bytes32 currentState;   // expected pre-state root on rollupId — checked against rollups[rid].stateRoot
    bytes32 newState;       // post-execution state root
    int256  etherDelta;     // signed ETH change for this rollup
}
```

`currentState` is checked at consumption time against `rollups[delta.rollupId].stateRoot` — it is part of the entry-match predicate on the queue path (a stale entry is a non-match, skipped by the forward scan), and re-asserted upfront in `_executeEntry` (`StateRootMismatch`) for the immediate L2Tx path that doesn't go through matching. This is the per-rollup-queue model's soundness backstop: entries are content-addressed against the trajectory the proof committed to, so consumption interleaved across rollups can't quietly land an entry whose preconditions don't hold. A stale builder either fails proof verification (the proof binds to the recorded `currentState`) or fails the on-chain match at consumption.

**On-chain requirements** (all enforced by `_validateBatchStructure`, not left to prover convention):

- Every entry must carry **at least one** `StateDelta` (`EntryHasNoStateDeltas`) — an empty array would leave the entry unpinned from the backstop (and would break `_insideExecution()`, which is backed by the per-entry allowed-rollups array).
- `stateDeltas` must be **strictly increasing by `rollupId`**, starting above `MAINNET_ROLLUP_ID` (`StateDeltasNotStrictlyIncreasing`) — rejects duplicates and a mainnet delta.
- Every delta's rollup must be in the batch's verified set (`RollupNotInBatch`), and `destinationRollupId` must be among the entry's own deltas (`EntryDestinationNotInStateDeltas`).
- **Proxy protection**: every executed call's `sourceRollupId` (top-level and every reentrant frame's sub-calls) must be ∈ the entry's deltas (`CallSourceNotVerified`, checked at validation); reentrant / static-read **targets** carry no clear-text field at post time, so they're checked at runtime against the same set (`ReentrantDestinationNotVerified`).

The `stateDeltas` attached to an entry must be the entry's true state transition — the proof is what makes them *correct*; the checks above only make them well-formed and pinned.

### Ether bridging (`etherDelta`)

`etherDelta` is signed:
- **Positive**: the rollup gains ETH (deposit / bridged-in)
- **Negative**: the rollup loses ETH (withdrawal / bridged-out); a negative delta exceeding the rollup's tracked balance reverts `InsufficientRollupBalance`
- **Zero**: no change

Per-entry on L1, the contract verifies at the end of `_executeEntry`:

```
Σ stateDeltas[i].etherDelta == _entryEtherDelta
```

where `_entryEtherDelta` is a transient net accumulator: SET to the entry-point call's `msg.value` at the top level (0 for `executeL2Txs` and immediate entries — a dirty accumulator there reverts `ResidualEntryEtherIn`), INCREMENTED by every reentrant call's `msg.value`, and DECREMENTED by the `value` of every **successful** non-static call the processor executes (a failed call's ETH never leaves the manager). Calls inside a `revertNextNCalls` span contribute to **neither** side: the span's revert rolls back their ETH transfers and their accumulator writes together — even though the rolling hash still records the calls as successful. Mismatch reverts `EtherDeltaMismatch`.

L2 has no ether accounting — `executeCrossChainCall` immediately forwards `msg.value` to `SYSTEM_ADDRESS` (burn), and `executeIncomingCrossChainCall` requires `msg.value == value` exactly (the system mints the inbound ETH by attaching it).

---

## Rolling Hash

A single `bytes32 rollingHash` per entry covers every call result and every nesting boundary. The accumulator is **seeded** with the entry's starting context and identity, then updated at tagged events:

```
seed (L1)      _rollingHash = keccak256(statesHash, proxyEntryHash)
               where statesHash = fold over stateDeltas: keccak256(prev, rollupId_i, currentState_i), from bytes32(0)
seed (L2)      _rollingHash = keccak256(bytes32(0), proxyEntryHash)

CALL_BEGIN     (1)   keccak256(prev, 0x01, crossChainCallHash)   // binds WHICH call runs
CALL_END       (2)   keccak256(prev, 0x02, success, returnData)  // binds its observed outcome
NESTED_BEGIN   (3)   keccak256(prev, 0x03, crossChainCallHash)   // reentrant frame opens
NESTED_END     (4)   keccak256(prev, 0x04)                       // reentrant frame closes (SUCCESS only)
CALL_NOT_FOUND (5)   keccak256(prev, 0x05, crossChainCallHash)   // reentrant no-match; diverges the hash so the
                                                                 // entry reverts — replaces any side flag
```

No call/frame *index* is folded in: the accumulator is a chain (each fold depends on the prior value), so order, count, and nesting are already bound by the chain plus the tags — and omitting the index is what lets a `revertNextNCalls` span be processed as a 0-based sub-slice without diverging the hash from a continuous run.

After all calls complete (L1, `_executeEntry`):

```solidity
if (_rollingHash != entry.rollingHash) revert RollingHashMismatch();   // also catches CALL_NOT_FOUND divergence
if (totalEtherDelta != _entryEtherDelta) revert EtherDeltaMismatch();  // L1 only
// then, if !entry.success: revert with entry.returnData (everything above rolls back)
```

There are no cursor-vs-length checks: each frame's call array is run to completion structurally, and the unified reentrant table may contain legitimately-unused entries (see Completeness accounting). L2 runs the same shape with its own names and no ether check.

A single mismatch anywhere in the execution tree changes the final hash — this catches wrong return data, wrong success/failure flags, missing or extra calls, missing reentrant frames, and incorrect nesting structure with one comparison.

Static resolutions use a simpler **untagged** accumulator (`keccak256(prev, success, retData)` from `bytes32(0)`), verified against `StaticExecutionEntry.rollingHash` / the STATIC-flavour entry's `revertedOrStaticRollingHash` — the surrounding key already pins the context. For the full hash chain semantics, see `CORE_PROTOCOL_SPEC.md` §E.

---

## Transaction Model

### Per-block structure

Each block has at most:
1. **Setup tx**: `postAndVerifyBatch` (L1) or `loadExecutionTable` (L2) — loads the execution table.
2. **Execution tx(s)**: One per cross-chain interaction that consumes entries.

On L1, `postAndVerifyBatch` itself runs the leading L2Tx entries inline and can run user-driven cross-chain calls via the **meta hook** (see below) — those don't need a separate execution tx. On L2, `executeIncomingCrossChainCall` combines setup + execution in one system tx.

### Immediate / deferred split (L1 `postAndVerifyBatch`)

`postAndVerifyBatch` takes a single `ProofSystemBatchPerVerificationEntries calldata batch` argument (NOT an array). The batch carries `expectedStateRootPerRollup[]` (optional composer-supplied state-root assertions), `entries[]`, `staticEntries[]`, `immediateEntryCount`, `immediateStaticEntryCount`, `proofSystems[]` (strictly increasing by address), `rollupIdsWithProofSystems[]` (strictly ascending by `rollupId`, each row carrying a strictly-increasing `proofSystemIndexes[]` into `proofSystems[]`), `blobIndices[]`, `callData`, `proofs[]` (one per PS), `blockNumber` (the single L1 block the batch binds to; `0` = no block context, `type(uint64).max` = latest), and `bindMsgSenderInPublicInput` (true folds `msg.sender` into the public input — front-run protection). `immediateEntryCount` / `immediateStaticEntryCount` are UNPROVEN dispatch params — not folded into the public input, so the immediate/persistent split can be re-tuned without re-proving. See `MULTI_PROVER_SPEC.md` for the proof-public-inputs construction.

Flow (numbered as in the code):

0. **Reentry guard** — revert `PostBatchReentry` if `_insideExecution()` or `_transientEntries.length != 0`.
1. (**1a**) Check every `expectedStateRootPerRollup` pin against the live root (`ExpectedStateRootMismatch`), then (**1**) **structural validation** via `_validateBatchStructure(batch)`: PS/rollup sorting + registration, per-rollup PS-index ranges, per-entry `stateDeltas` rules + `destinationRollupId ∈ deltas` + call-source pinning, per-static-entry pin rules, and the immediate-prefix bounds (`ImmediateCountExceedsEntries`, `ImmediateStaticEntryCountExceedsStaticEntries`, `ImmediateStaticEntriesWithoutImmediateEntries`, `ImmediateCountStrandsLeadingL2Tx`).
2. **Fetch vkeys**: `_getVerificationKeysPerRollup` calls each rollup's manager via `IRollupContract.checkProofSystemsAndGetVkeys(subset)` (the manager enforces its own threshold and per-PS membership; `view`, so it can't reenter).
3. **Verify all proofs atomically**: `_verifyProofSystemBatch` builds `sharedPublicInput` (entry hashes, static-entry hashes, blob hashes, `keccak(callData)`, per-rollup `customData` fetched via `getCustomData(batch.blockNumber)`, and the bound sender) plus a per-PS accumulator, and calls `IProofSystem.verify(proofs[k], publicInputsHash[k])` for each PS — any failure reverts the batch (`InvalidProof`).
4. **Mark verified-this-block** (`_markVerifiedBlockAndDeletePreviousEntries(rid)`): wipes the rollup's `entryQueue` / `staticEntryQueue` and resets `entryQueueIndex` on **every** verify — a same-block re-verify REPLACES (does not append to) the prior batch's entries. Sets the read gate (`lastVerifiedBlock(rid) == block.number`) for `executeCrossChainCall` / `executeL2Txs(rollupId)`.
5. (**5+6**) **Drain the leading L2Tx run inline, straight from calldata**: while `entries[i].proxyEntryHash == 0` and `i < immediateEntryCount`, self-call `try this._attemptExecuteImmediateL2Txs(entries[i]) catch { emit L2TxSkipped(i, revertData); }` and advance. The entries are never SSTOREd whole — only each entry's reentrant table is parked transiently for the duration of its run. A non-empty run where nothing succeeded reverts `AllImmediateL2TxsFailed`.
6. (**7**) **Meta hook**: if entries remain in the immediate prefix past the leading L2Tx run AND `msg.sender.code.length > 0`, push `entries[i..immediateEntryCount)` into `_transientEntries` and `staticEntries[0..immediateStaticEntryCount)` into `_transientStaticEntries`, then call `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()`. The hook can invoke `executeCrossChainCall` / `executeL2Txs(rollupId)` to consume the transient entries (one global cursor, in array order).
7. (**8**) `_saveRemainderEntries(batch)` (**unconditionally** — even if the meta hook left transient entries unconsumed): push `entries[immediateEntryCount..]` to `verificationByRollup[entry.destinationRollupId].entryQueue` and `staticEntries[immediateStaticEntryCount..]` to the corresponding `staticEntryQueue`. Soundness backstop: each entry's `StateDelta.currentState` is checked at consumption time, so dropped transient leftovers don't poison persistent consumers — a dependent entry fails its own state-root match.
8. (**9**) **Clear the transient tables** (this also closes the re-entry window), then `emit BatchPosted(batch.rollupIdsWithProofSystems.length)`.

A batch with `immediateEntryCount == 0` means no inline execution and no meta-hook consumption — all entries flow straight to per-rollup queues.

### 1-to-1 rule

Each user action produces **exactly 1 execution transaction per chain involved**:

- **L1→L2**: User calls a proxy on L1 → `executeCrossChainCall` (1 tx on L1). The system delivers it on L2 via `executeIncomingCrossChainCall` (system-only; atomically loads the table and consumes `entries[0]`) — 1 tx on L2. Reentrant calls are folded into the same tx via the unified reentrant tables on both sides.
- **L2→L1**: User submits an L2 transaction → on L1 the L2Tx entry is consumed inline by `postAndVerifyBatch` or via `executeL2Txs` (1 tx on L1). The L2 user tx itself is the consumption on L2 (no separate setup tx needed beyond `loadExecutionTable`).

Never split a single cross-chain interaction into multiple execution transactions on the same chain.

---

## Flow Patterns

In the diagrams below, "MAINNET" means rollupId 0 (L1) and "L2" means whichever rollup ID the L2 chain has registered with the `EEZ` registry. `hash(...)` is `computeCrossChainCallHash(isStatic, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, data)`, and `seed` is the per-side entry-begin seed from the Rolling Hash section. Each chain's entry lists only the calls that execute **on that chain**.

### L1→L2 (simple)

Alice on L1 calls a contract B on L2. B's proxy on L1 forwards Alice's call to L1's `EEZ.executeCrossChainCall` (consuming entry [0] — no calls execute on L1, the pre-computed result is returned). The L2 system later delivers the call on L2 via `executeIncomingCrossChainCall`.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] DEFERRED
    proxyEntryHash      = hash(false, src=Alice, srcRollup=MAINNET, dest=B, destRollup=L2, value=v, data=calldata)
    destinationRollupId = L2   // routes into verificationByRollup[L2].entryQueue; must be ∈ stateDeltas
    l2ToL1Calls         = []   // nothing executes on L1 — B runs on L2
    expectedL1ToL2Calls = []
    rollingHash         = seed(stateDeltas, proxyEntryHash)   // no calls: the hash is just the seed
    success             = true
    returnData          = <B's return>   // pre-computed by the prover
    stateDeltas         = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=v? } ]
```

(An immediate L2Tx entry for the batch's other work can live in the same batch ahead of this one, with `proxyEntryHash == 0`.)

**L2 execution table** (loaded atomically by `executeIncomingCrossChainCall`):
```
[0] proxyEntryHash = hash(false, Alice, MAINNET, B, L2, v, calldata)
    // same hash as the L1 entry — executeIncomingCrossChainCall recomputes it from its
    // explicit params and reverts EntryHashMismatch on divergence
    incomingCalls = [{ revertNextNCalls=0, isStatic=false, src=Alice, srcRollup=MAINNET,
                       dest=B, value=v, data=calldata }]
    expectedOutgoingCalls = []
    rollingHash = H( seed(proxyEntryHash) → CALL_BEGIN(hash of the B call, targetRollup=L2)
                     → CALL_END(true, <B's return>) )
    success     = true
    returnData  = <B's return>
    // no stateDeltas / destinationRollupId — the L2 struct has neither field
```

**Execution**:
- **L1**: Alice calls B's proxy → `executeCrossChainCall(Alice, calldata)` → `_consumeAndExecuteEntry` matches entry [0] (identity + routing + live state pins), applies the deltas, verifies the seed-only rolling hash → returns `<B's return>`.
- **L2**: System submits `executeIncomingCrossChainCall(B, v, calldata, Alice, MAINNET, entries, staticEntries)` (`msg.value == v`) → atomically replaces the table, checks `entries[0].proxyEntryHash`, and drives the call processor → B executes on L2 via Alice's proxy.

### L2→L1 (simple)

Alice on L2 (through contract D) calls a contract C on L1.

**L1 execution table** (`postAndVerifyBatch`):
```
[0] IMMEDIATE (L2Tx)   proxyEntryHash = bytes32(0)
    destinationRollupId = L2   // must be ∈ stateDeltas (MAINNET can never be a delta);
                               // immediate entries inline-execute on L1 regardless of this field
    l2ToL1Calls = [{ revertNextNCalls=0, isStatic=false, src=D, srcRollup=L2,
                     dest=C, value=0, data=calldata }]
    expectedL1ToL2Calls = []
    rollingHash = H( seed(stateDeltas, 0) → CALL_BEGIN(hash(false, D, L2, C, MAINNET, 0, calldata))
                     → CALL_END(true, <C's return>) )
    success     = true
    returnData  = ""
    stateDeltas = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=0 } ]
```

(Often this is `entries[0]` with `immediateEntryCount = 1`, executed inline by `postAndVerifyBatch`; a non-leading L2Tx entry is queued and consumed via `executeL2Txs(L2)`.)

**L2 execution table** (`loadExecutionTable`):
```
[0] DEFERRED
    proxyEntryHash = hash(false, src=D, srcRollup=L2, dest=C, destRollup=MAINNET, 0, calldata)
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
    stateDeltas = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=0 } ]
```

**L2 execution table** (loaded atomically by `executeIncomingCrossChainCall`):
```
[0] proxyEntryHash = hash(false, Alice, MAINNET, D, L2, 0, incrementProxy)
    incomingCalls = [{ src=Alice, srcRollup=MAINNET, dest=D, value=0, data=incrementProxy, ... }]
    expectedOutgoingCalls = [ {
        expectedOutgoingHash = keccak256( hash(false, D, L2, C, MAINNET, 0, increment)
                                          ‖ fireHash ),
        // fireHash = the L2 _rollingHash right after CALL_BEGIN of the D call — the point the
        // reentrant call fires
        incomingCalls = [],                 // nothing executes on L2 inside this frame
        revertedOrStaticRollingHash = 0,    // unused for a SUCCESS frame
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
- **L2**: System tx → `executeIncomingCrossChainCall(D, 0, incrementProxy, Alice, MAINNET, entries, staticEntries)` → drives entry [0]. The real D executes; when D calls C's proxy on L2 → `executeCrossChainCall(D, increment)` → `_insideExecution() == true` → `_consumeNestedCall` matches the frame by `keccak256(crossChainCallHash ‖ _rollingHash)` → runs the frame's (empty) sub-array between `NESTED_BEGIN`/`NESTED_END` → returns `abi.encode(1)` to D.

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
        revertedOrStaticRollingHash = 0,    // unused for a SUCCESS frame
        success = true,
        returnData = abi.encode(1)          // B's pre-computed return
    } ]
    rollingHash = H( seed → CALL_BEGIN(hash(false, Alice, L2, A, MAINNET, 0, callBProxy))
                     → NESTED_BEGIN(hash of A→B) → NESTED_END
                     → CALL_END(true, <A's return>) )
    success     = true
    returnData  = ""
    stateDeltas = [ { rollupId=L2, currentState=S0, newState=S1, etherDelta=0 } ]
```

**L2 execution table** (`loadExecutionTable`):
```
[0] DEFERRED
    proxyEntryHash = hash(false, Alice, L2, A, MAINNET, 0, callBProxy)
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
    stateDeltas = [ ... ]   // whatever net delta the prover committed to (the parent tx rolled back on L2)
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
| **State deltas** | Required: ≥1 per entry, strictly increasing by rollupId, all in batch, `destinationRollupId` ∈ deltas, call sources ∈ deltas (all validation-time); `currentState` checked at consumption (match predicate + `StateRootMismatch` gate); `etherDelta` accounted | No `stateDeltas` field at all — the L2 entry struct omits it (no rollup state on L2) |
| **Matching logic** | Forward-scan from the per-rollup cursor (`_findMatchingEntry`) for the first FULL match: `proxyEntryHash` + `destinationRollupId == destRid` + every `currentState` pin live; non-matches skipped; end-of-queue → `ExecutionNotFound`. Transient branch uses one global cursor with the same predicate | Forward-scan `entries` from `entryIndex` by `proxyEntryHash` alone; end-of-table → `ExecutionNotFound` |
| **Top-level reverting call** | Normal `ExecutionEntry` with `success = false` — run, verified, then reverted with `returnData` (no fallback pool) | Same |
| **Static entries** | Pool: batch `staticEntries[]` → `_transientStaticEntries` (leading `immediateStaticEntryCount`, scanned exclusively while a batch is mid-flight) / per-rollup `staticEntryQueue`. Match: `proxyEntryHash` + `destinationRollupId` + all `expectedStateRoots` pins live (full scan). No block gate — resolvable while pins hold | Persistent `staticEntries` pool, matched by `proxyEntryHash` alone (no state roots to pin) |
| **Ether accounting** | Per-entry invariant `Σ etherDelta == _entryEtherDelta` (net inbound − successful outbound) | None; `msg.value` is forwarded to `SYSTEM_ADDRESS` |
| **Same action hash** | Each occurrence consumes the next matching entry on the destination rollup's queue; sequential ordering distinguishes them | Same |
| **Immediate/deferred split** | Leading L2Tx run executed straight from calldata; meta-hook remainder in `_transientEntries` / `_transientStaticEntries`; rest published to per-rollup queues **unconditionally** (soundness via the `currentState` match) | No transient tables — all entries go directly to `entries` / `staticEntries` |
| **Meta hook** | `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` if immediate-prefix entries remain past the leading L2Tx run AND `msg.sender` has code | Not present |
| **Immediate entry** | Leading `proxyEntryHash == 0` entries run inline during `postAndVerifyBatch` via `_attemptExecuteImmediateL2Txs` (try/catch self-call); a failed one emits `L2TxSkipped` and is skipped; an all-failed non-empty run reverts `AllImmediateL2TxsFailed` | Not expressible — no consumption path matches `proxyEntryHash == 0` on L2. Inbound work arrives via `executeIncomingCrossChainCall` (non-zero `proxyEntryHash`); locally-initiated work is consumed by the user's own tx through a proxy |
| **`executeL2Txs`** | `executeL2Txs(uint64 rollupId)` — permissionless; consumes the next matching entry on `rollupId`'s queue with `proxyEntryHash == bytes32(0)` | Not present (L2 has no `executeL2Txs` entry point) |
| **Inbound system-only call** | Not present | `executeIncomingCrossChainCall(destination, value, data, sourceAddress, sourceRollup, entries, staticEntries)` — `onlySystemAddress`, strict `msg.value == value`, atomically replaces the table, checks `entries[0].proxyEntryHash` (`EntryHashMismatch`), consumes `entries[0]`, emits `IncomingCrossChainCallExecuted`, returns `entries[0].returnData` |

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

`executeL2Txs(rollupId)` reverts with `L2TXNotAllowedDuringExecution` if `_insideExecution() == true`. L2Tx entries are top-level only; reentrant calls must use the proxy path.

### Consistent rollupId / sourceRollupId semantics

- `targetRollupId` in every call hash = **target** (where the call executes)
- `sourceRollupId` in every call hash = **origin** (where the caller lives)
- On L1, calls produced by `executeCrossChainCall` have `sourceRollupId = MAINNET (0)` — top-level and reentrant alike.
- On L2, calls produced by `executeCrossChainCall` have `sourceRollupId = ROLLUP_ID` (this L2's ID).
- `isStatic` is part of the hash: a read-only call and an otherwise-identical state-changing call hash differently. Static hashes always carry `value = 0`.
- Every *executed* call's `sourceRollupId` must be a rollup the entry proved (∈ `stateDeltas` on L1), and it can never be the executing chain's own ID (a same-network proxy reverts `SameNetworkProxy`).

### Don't rely on positional grouping across frames

Each call array — the entry's `l2ToL1Calls[]` (L2: `incomingCalls[]`) and every reentrant frame's own sub-array — is executed in array order, to completion, by its own frame. The semantic structure (which calls belong to which frame) comes from **where the array lives**, not from counts or a shared cursor. What binds frames to execution points is the `expectedL1toL2Hash` key: the live rolling hash at fire time. The builder must simulate the execution to capture each frame's fire-point hash exactly; a frame keyed at the wrong point simply never matches, and the resulting `CALL_NOT_FOUND` fold fails the entry.
