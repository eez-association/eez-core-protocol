# Static Entry Specification (unified reentrant table + top-level `StaticExecutionEntry` pool)

This document specifies how **read-only cross-chain calls** (STATICCALLs) and **pre-verified
reverting calls** resolve — every cross-chain interaction whose result is *looked up* from
prover-supplied data instead of returned by a live top-level `ExecutionEntry` success path.

There are **two homes**, split by execution context:

| Situation | Mechanism | Lives in | Match key |
|---|---|---|---|
| REENTRANT static read, fired `_insideExecution()` | STATIC-kind `ExpectedL1ToL2Call` | the entry's unified `expectedL1ToL2Calls[]` table | `expectedL1toL2Hash == keccak256(crossChainCallHash, _rollingHash)`, with `isStatic = true` folded into `crossChainCallHash` |
| REENTRANT call that reverts (caller catches with `try/catch`) | REVERTED-kind `ExpectedL1ToL2Call` (`success == false`) | same table | same key, with `isStatic = false` |
| TOP-LEVEL static read (including one that reverts) | `StaticExecutionEntry` | L1: `_transientStaticEntries` while a batch is mid-flight, else per-rollup `staticEntryQueue`; L2: the `staticEntries` pool | L1: `proxyEntryHash` + `destinationRollupId` + every `expectedStateRoots` pin live (full scan); L2: `proxyEntryHash` alone, same-block only (`lastLoadBlock == block.number`) |
| TOP-LEVEL state-changing call that reverts | normal `ExecutionEntry` with `success == false` | entry queue | see `EXECUTION_ENTRY_SPEC.md` — out of scope here |

There is no separate lookup struct and no separate lookup key space: reentrant reads and
reverted reentrant calls are ordinary rows of the **one** reentrant table (`ExpectedL1ToL2Call`
on L1, `ExpectedOutgoingCrossChainCall` on L2), content-addressed by the same position key as
plain-success reentrant calls. Field names below are L1's (`src/interfaces/IEEZ.sol`); L2
(`src/interfaces/IEEZL2.sol`) mirrors with self-relative names (`expectedOutgoingHash`,
`incomingCalls`, `expectedOutgoingCalls`, cursor `_lastOutgoingCallConsumed`) and drops the
L1-only fields (`destinationRollupId`, `expectedStateRoots`).

This document complements `EXECUTION_ENTRY_SPEC.md` (how `ExecutionEntry`s are built) and
`CORE_PROTOCOL_SPEC.md` §E (rolling hash; §E.2 for the untagged static schema).

---

## 1. Routing: how a read reaches `staticCrossChainCall`

A contract performs a cross-chain read by STATICCALLing the counterparty's `CrossChainProxy`.
The proxy detects the static frame itself (`CrossChainProxy._fallback`): it self-calls
`staticCheck()`, which attempts a transient store — `tstore` reverts inside a STATICCALL, so a
failed self-call means "static context". The proxy then routes to the manager's
`staticCrossChainCall(msg.sender, msg.data)` via STATICCALL (a normal frame routes to
`executeCrossChainCall` instead).

`staticCrossChainCall` is `view`. It computes the call's identity with the canonical
formula (`EEZBase.computeCrossChainCallHash` — `CORE_PROTOCOL_SPEC.md` §C.3), with
`isStatic = true` (a read keys DISTINCTLY from a state-changing call), `value = 0`,
source = the proxy's caller on this chain's rollup ID, target = the proxy's
(`originalAddress`, `originalRollupId`), and the original calldata. Static keys fold
`callGas = 0` on both chains — a read never keys on gas, even on an L2 with
`USE_GAS_LEFT`. It then branches on `_insideExecution()`:
**inside** → the active entry's unified reentrant table (§4.1); **outside** → the top-level
`StaticExecutionEntry` pool (§4.2).

---

## 2. Field reference

```solidity
// L1 — src/interfaces/IEEZ.sol

/// One row of the entry's UNIFIED reentrant table. Serves three kinds:
/// plain SUCCESS, read-only STATIC, and try/catch'd REVERTED (`!success`).
struct ExpectedL1ToL2Call {
    bytes32 expectedL1toL2Hash;          // position key: keccak256(crossChainCallHash, expectedRollingHash)
    L2ToL1Call[] l2ToL1Calls;            // this frame's OWN sub-calls, run to completion
    bytes32 revertedOrStaticRollingHash; // expected sub-call hash, checked for STATIC / REVERTED; must be 0 for SUCCESS
    bool success;                        // whether resolution returns or reverts
    bytes returnData;                    // returned on success / reverted-with when !success
}

/// TOP-LEVEL static entry — lives in the pool; resolvable only outside an execution.
struct StaticExecutionEntry {
    ExpectedStateRootPerRollup[] expectedStateRoots; // state-root pins — part of the MATCH — see §6
    bytes32 proxyEntryHash;      // the inbound call's crossChainCallHash (isStatic = true folded in)
    L2ToL1Call[] l2ToL1Calls;    // read-only sub-calls run via STATICCALL during resolution
    bytes32 rollingHash;         // expected untagged hash of the sub-calls — see §5
    uint64 destinationRollupId;  // routes the pool entry; must match the calling proxy's rollup
    bool success;                // whether resolution returns or reverts
    bytes returnData;            // returned on success / reverted-with when !success
}
```

Notes:

- **One `success` polarity everywhere.** `ExecutionEntry`, `ExpectedL1ToL2Call`, and
  `StaticExecutionEntry` all carry `success`; `false` always means "run/verify the sub-calls,
  then `revert(returnData)`" and `true` means "…then return `returnData`".
- **No kind selector on the reentrant row.** STATIC vs CALL is decided by the *key*:
  `crossChainCallHash` folds `isStatic`, so a static read can only ever match a row whose key
  was built from a static hash, and `staticCrossChainCall` / `_consumeNestedCall` each compute
  their own side of it. SUCCESS vs REVERTED within the CALL kind is the row's `success` flag.
- **`destinationRollupId`** (top-level, L1) routes publishing into
  `verificationByRollup[rid].staticEntryQueue` and is re-checked at match time. It is
  load-bearing for the transient pool (one global table, not queue-routed) and coherent by
  construction for the persistent queues: the scan targets the calling proxy's
  `originalRollupId`, which is also the target rollup bound into `crossChainCallHash`.
- **No recursion structs needed.** A reverted sub-execution's own reentrant calls resolve from
  the SAME host table, disambiguated by the live `_rollingHash` folded into each key (§3).

---

## 3. The position key (`expectedL1toL2Hash`)

Every reentrant-table row is content-addressed by one value
(`EEZBase._computeExpectedL1toL2Hash`):

```
expectedL1toL2Hash = keccak256(abi.encodePacked(crossChainCallHash, expectedRollingHash))
```

where `expectedRollingHash` is the live `_rollingHash` at the instant the reentrant call (or
read) fires. The rolling hash is a chain over every prior call result and nesting boundary, so
it **uniquely pins the execution point** — no cursor coordinates, no context index:

- Two textually identical calls at different points key differently (different `_rollingHash`).
- A read and a state-changing call with identical params key differently (`isStatic` in the
  call hash).
- A reverted sub-execution reuses the host table for its own reentrant calls; its rows can't
  collide with host-level rows because their keys embed the sub-execution's interior
  `_rollingHash` values.

Matching walks **strictly forward** from the reentrant cursor `_lastL1ToL2CallConsumed`; the
first key match is the row. A resolved CALL advances the cursor past its row; a static read
cannot (it's a `view` frame) — it is *position-pinned* rather than *consumed*, so the same
STATIC row satisfies repeated identical reads fired at the same hash point, and it still only
matches at or after the cursor.

Completeness is enforced by the rolling hash, not by a table-length check: the unified table
mixes success rows with static/reverted ones, so unused rows are inert, while a *skipped*
success row omits its NESTED frame and diverges the entry hash.

---

## 4. Resolution mechanics

### 4.1 Reentrant (inside an execution)

**Static read** — `staticCrossChainCall`, in-execution branch:

1. (L1 only) proxy protection: the read's target rollup must be in the executing entry's
   allowed set (`_isRollupAllowed`, from its `stateUpdates`) — else
   `ReentrantDestinationNotVerified`.
2. Compute the key from the static-kind `crossChainCallHash` + live `_rollingHash`; scan
   the active table forward from `_lastL1ToL2CallConsumed`.
3. On match → `_resolveStaticEntry(l2ToL1Calls, revertedOrStaticRollingHash, success,
   returnData)` (§4.3). On no match → `ExecutionNotFound` (a `view` frame cannot fold a
   `CALL_NOT_FOUND` divergence, so it reverts directly — unlike a reentrant CALL no-match,
   which folds the tag and returns empty so the entry fails later at `RollingHashMismatch`).

**Reverted reentrant call** — `_consumeNestedCall` → `_resolveNestedReentrant`, `success == false`
row:

```
advance _lastL1ToL2CallConsumed past the matched row
_rollingHashNestedBegin(crossChainCallHash)          // open the frame
_processNCalls(row.l2ToL1Calls)                      // run the frame's OWN sub-array, tagged schema
require _rollingHash == row.revertedOrStaticRollingHash   // else RollingHashMismatch
revert(row.returnData)                               // terminal revert
```

The terminal revert rolls back the sub-execution's **state**, the cursor advance, and the
rolling-hash writes in one shot (all transient/storage writes of the frame unwind with the
EVM revert); the caller's `try/catch` observes exactly `returnData`. A `success == true` row
takes the other branch of the same resolver: it closes the frame with `NESTED_END` into the
host's *continuous* hash and returns `returnData` — that path is a plain reentrant call, not a
lookup, and is specified in `EXECUTION_ENTRY_SPEC.md`.

### 4.2 Top-level (outside any execution)

`staticCrossChainCall`'s pool branch. Source selection on L1:

- While a batch is mid-flight (`_transientEntries.length != 0`): **only** the batch's
  transient pool `_transientStaticEntries` — the transient phase is self-contained (see
  `docs/CAVEATS.md`).
- Otherwise: the calling proxy's rollup queue,
  `verificationByRollup[destRid].staticEntryQueue`.

Match predicate (full scan — a non-matching candidate is skipped, never an error):

```
staticEntry.proxyEntryHash == crossChainCallHash
&& staticEntry.destinationRollupId == destRid
&& _stateRootsMatch(staticEntry)        // every pin equals the live root — §6
```

There is **no block gate** on the top-level static path (unlike entry consumption's
`lastVerifiedBlock == block.number`): a static entry does not go stale with the block — as
long as its state-root pins match the live roots, it resolves. Lifetime is bounded instead by
the queue reset: every batch that verifies a rollup wipes that rollup's `staticEntryQueue`
along with its entry queue.

On L2 the pool is the single `staticEntries` table (replaced wholesale by every
`loadExecutionTable` / `executeIncomingCrossChainCall`), matched by `proxyEntryHash` alone —
but unlike L1, gated on `lastLoadBlock == block.number`. L2 has no pins, so the block gate
is what bounds staleness.

### 4.3 `_resolveStaticEntry` / `_processNStaticCalls` (shared body)

Both the reentrant STATIC branch and the top-level pool resolve through `_resolveStaticEntry`:

```
require _processNStaticCalls(calls) == rollingHash   // else RollingHashMismatch
if (!success) revert(returnData)
return returnData
```

`_processNStaticCalls` runs the sub-call array flatly in **static context**:

- Each sub-call is dispatched `sourceProxy.staticcall(executeOnBehalf(target, cc.gas, data))` —
  read-only, no value, reverts on any state write in the target.
- Results fold into an **untagged** accumulator seeded at `bytes32(0)`
  (`EEZBase._rollingHashStaticResult`): `hash = keccak256(prev, success, retData)` per
  sub-call. No `CALL_BEGIN`/`CALL_END` tags, no call identity — the surrounding static-entry
  key already pins the context (see `CORE_PROTOCOL_SPEC.md` §E.2). The hash is **always**
  compared: an empty `calls[]` hashes to `0`, so a sub-call-less static entry must carry
  `rollingHash == 0`.
- Every referenced source proxy **must already be deployed**: CREATE2 is unavailable inside a
  STATICCALL frame, and a STATICCALL to a codeless address silently returns `(true, "")` — so
  a codeless proxy reverts `StaticCallProxyNotDeployed` rather than letting the prover
  pre-hash a no-op.
- Every sub-call must be marked `isStatic` with `value == 0` — dispatch is read-only whatever
  the fields say, and the untagged hash folds neither, so a mismatch reverts (`NonStaticSubCall`
  / `StaticCallWithValue`) instead of silently executing a proven state-changing call read-only.
- No `revertNextNCalls` handling — nothing mutates state, so there is nothing to force-revert; `== 0` on static sub-calls is a prover constraint.

A naturally-reverting *sub-call* is not special: the STATICCALL returns `(false, retData)` and
the untagged hash captures it. The entry-level `success == false` is for the *whole read*
reverting toward its caller.

---

## 5. Per-frame sub-arrays (no shared partition)

Every reentrant-table row and every static entry carries its **own** sub-call array, run to
completion by its resolver:

- STATIC rows / static entries: run flatly by `_processNStaticCalls` (untagged hash).
- REVERTED rows: run by `_processNCalls` as a mini-entry (tagged schema, may itself contain
  reentrant calls — resolved from the host table — and `revertNextNCalls` spans).

There is no global flat-call cursor and no `callCount` partition: the entry's `l2ToL1Calls[]`
holds only its TOP-LEVEL calls, and each frame's completeness is structural (the resolver
processes the whole array it was handed).

---

## 6. State-root pins (top-level, L1 only)

`expectedStateRoots[]` content-addresses a top-level static entry to a point on each pinned
rollup's trajectory: a candidate only **matches** when every pin equals the live
`rollups[rollupId].stateRoot` (`_stateRootsMatch`, full-scan semantics — a mismatching
candidate is skipped and the scan continues; no dedicated error). The pins are:

- **The freshness predicate** — with no block gate on the static path, the pins are what
  invalidates a cached read once any pinned rollup's root moves on.
- **Transient-phase capable** — roots advance entry-by-entry during a batch, so a pin can
  target an intermediate mid-batch state.
- **The validation-time proven set.** `_validateBatchStructure` enforces, per static entry:
  pins strictly increasing by `rollupId` (rejects duplicates and, bounding above
  `MAINNET_ROLLUP_ID`, a mainnet pin — `ExpectedStateRootsNotStrictlyIncreasing`); every
  pinned rollup in the batch (`RollupNotInBatch`); `destinationRollupId` among the pins
  (`StaticEntryDestinationNotPinned` — the routing target must be pinned to proven state,
  mirroring the entry `destination ∈ stateUpdates` rule); and every sub-call's
  `sourceRollupId` among the pins (`CallSourceNotVerified`).

The prover decides which rollups to pin, but the set can never be empty on L1:
`destinationRollupId` must itself be a pin, so a pin-less static entry fails validation
(`StaticEntryDestinationNotPinned`).

Prover binding: each static entry is hashed whole
(`keccak256(abi.encode(staticEntry))`) into the batch's `publicInputsHash`, so its content
can't be swapped after proving. `immediateStaticEntryCount` — the leading prefix loaded into
`_transientStaticEntries` for the meta-hook window — is an UNPROVEN dispatch parameter (like
`immediateEntryCount`); the remainder past it is published to the per-rollup
`staticEntryQueue`s regardless of whether the meta hook fired.

The static prefix is a companion of the batch's META-HOOK entries, not of the immediate
prefix as a whole: it is loaded only when the meta hook fires, i.e. when the immediate prefix
contains at least one non-L2Tx entry. If the whole immediate prefix is L2Txs, the hook never
runs and a non-zero `immediateStaticEntryCount` silently drops the leading static entries —
they are neither loaded transiently nor published to the queues (`_saveRemainderEntries`
starts past them). Composers whose immediate prefix is pure L2Txs must set
`immediateStaticEntryCount = 0` so the static entries flow to the persistent
`staticEntryQueue`s (which are not block-gated).

---

## 7. L1 / L2 differences

- **Structs**: L2's `StaticExecutionEntry` drops `expectedStateRoots` and
  `destinationRollupId` (single rollup, no state roots); its reentrant row is
  `ExpectedOutgoingCrossChainCall` with `expectedOutgoingHash` / `incomingCalls` (same layout,
  self-relative names). The key helper (`_computeExpectedL1toL2Hash`) and the untagged
  accumulator (`_rollingHashStaticResult`) are shared in `EEZBase`.
- **Pool**: L1 selects transient-vs-persistent by `_transientEntries.length` and matches with
  destination + pins, with no block gate (pins bound staleness); L2 scans the one `staticEntries`
  table by hash alone, gated on `lastLoadBlock == block.number`. L2 has no pins, so the block gate
  is its staleness bound — the pool is only resolvable in the block it was loaded.
- **Call-hash source side**: the static key folds `sourceRollupId = MAINNET_ROLLUP_ID` on L1
  and `= ROLLUP_ID` on L2 (the reader lives on this chain), `value = 0` and `callGas = 0` always
  (see CORE_PROTOCOL_SPEC §C.2/§C.3).
- **Proxy protection**: L1's reentrant static branch checks `_isRollupAllowed(destRid)`
  against the executing entry's `stateUpdates`; L2 has no allowed-rollups set.
- **Reentrant-table source**: L1's `_getExpectedL1toL2Calls()` has three sources (the parked
  immediate-L2Tx table, the transient entry at `_currentEntryIndex`, or the persistent queue
  entry of `_currentEntryRollupId`; an empty parked table with `_currentEntryRollupId == 0`
  reverts `NoExpectedL1ToL2CallFound`); L2's `_getExpectedOutgoingCalls()` always indexes the
  single `entries` table.

---

## 8. Invariants (summary)

- `success == false` ⇒ resolution ends in `revert(returnData)`; `success == true` ⇒ it
  returns `returnData`. Same polarity on `ExecutionEntry`, `ExpectedL1ToL2Call`, and
  `StaticExecutionEntry`.
- A static read never mutates: STATICCALL dispatch, untagged hash, no cursor advance, no
  proxy auto-creation (`StaticCallProxyNotDeployed` on a codeless proxy), no
  `revertNextNCalls`.
- STATIC and REVERTED sub-arrays are verified against `revertedOrStaticRollingHash` (rows) /
  `rollingHash` (static entries); the untagged accumulator seeds at `bytes32(0)`, so an empty
  sub-array requires an expected hash of `0`.
- STATIC and CALL kinds can never match each other's keys — `crossChainCallHash` folds
  `isStatic`.
- Matching is strictly forward from the reentrant cursor; a CALL consumes its row (cursor
  past it), a static read does not.
- A REVERTED resolution runs its own sub-array with the tagged schema inside NESTED_BEGIN,
  checks the sub-hash, then terminal-reverts — state, cursor, and hash all roll back with it.
- No-match asymmetry: a reentrant CALL no-match folds `CALL_NOT_FOUND` and returns `""` (the
  entry fails at its rolling-hash check); a static no-match reverts `ExecutionNotFound`
  immediately, in both branches.
- L1 top-level match = `proxyEntryHash` + `destinationRollupId` + all pins live; full-scan
  skip semantics; no block gate — pins govern freshness, and every re-verify of the rollup
  wipes its `staticEntryQueue`.
- Validation (L1): pins strictly increasing and in-batch; `destinationRollupId` ∈ pins;
  every sub-call source ∈ pins; whole static entries folded into `publicInputsHash`;
  `immediateStaticEntryCount ≤ staticEntries.length`, and a non-zero count requires a
  non-zero `immediateEntryCount` (the transient static pool is only reachable while
  transient entries are mid-flight). Note the effective requirement is stronger: the pool
  loads only if the meta hook fires (≥1 non-L2Tx immediate entry) — see §6.
