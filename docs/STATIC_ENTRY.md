# Static Entry Specification

This document specifies how **read-only cross-chain calls** (STATICCALLs) and **pre-verified
reverting calls** resolve — every cross-chain interaction whose result is *looked up* from
prover-supplied data instead of returned by a live top-level `ExecutionEntry` success path.

There are **two homes**, split by execution context:

| Situation | Mechanism | Lives in | Match key |
|---|---|---|---|
| REENTRANT static read, fired `_insideExecution()` | STATIC-kind `ExpectedL1ToL2Call` | the entry's unified `expectedL1ToL2Calls[]` table | `expectedL1toL2Hash == keccak256(crossChainCallHash, _rollingHash)`, with `isStatic = true` folded into `crossChainCallHash` |
| REENTRANT call that reverts (caller catches with `try/catch`) | REVERTED-kind `ExpectedL1ToL2Call` (`success == false`) | same table | same key, with `isStatic = false` |
| TOP-LEVEL static read (including one that reverts) | `StaticExecutionEntry` | L1: `_transientStaticEntries` while a batch is mid-flight, else per-rollup `staticEntryQueue`; L2: the `staticEntries` pool | L1: `proxyEntryHash` + `destinationRollupId` + every `expectedRoots` pin live (full scan); L2: `proxyEntryHash` + `expectedEntryIndex == entryIndex` |
| TOP-LEVEL state-changing call that reverts | normal `ExecutionEntry` with `success == false` | entry queue | see `EXECUTION_ENTRY_SPEC.md` — out of scope here |

There is no separate lookup struct and no separate lookup key space: reentrant reads and
reverted reentrant calls are ordinary rows of the **one** reentrant table (`ExpectedL1ToL2Call`
on L1, `ExpectedOutgoingCrossChainCall` on L2), content-addressed by the same position key as
plain-success reentrant calls. Field names below are L1's (`src/interfaces/IEEZ.sol`); L2
(`src/interfaces/IEEZL2.sol`) mirrors with self-relative names (`expectedOutgoingHash`,
`incomingCalls`, `expectedOutgoingCalls`, cursor `_lastOutgoingCallConsumed`) and drops the
L1-only fields (`destinationRollupId`, `expectedRoots`).

Seen from the frame that carries them:

- **Top-level mutable frame** (an `ExecutionEntry`). Callbacks to L1 go in `l2ToL1Calls`. Any
  reentrant call back into a rollup the entry proves, static included, goes in
  `expectedL1ToL2Calls` as a row — that is why the row struct has
  `revertedOrStaticRollingHash`: the expected sub-call hash for STATIC and REVERTED rows. The
  frame is an execution environment, so it can carry expected results for its nested reads.
- **Top-level static frame** (a `StaticExecutionEntry`). Callbacks to L1 go in `l2ToL1Calls`,
  run with STATICCALL. Reentrant reads cannot be carried inside because a static frame cannot
  mark itself as an execution (`_insideExecution()` stays false), so each becomes another
  top-level `StaticExecutionEntry` in the pool, matched independently (§4.2).

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
`callGas = 0` on L1. On L2 they fold `uint64(gasleft())` sampled after proxy
validation/storage reads when `USE_GAS_LEFT`, otherwise `0`. It then branches on `_insideExecution()`:
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
    L2ToL1Call[] l2ToL1Calls;            // this frame's OWN sub-calls, processed in order (subject to gas checks)
    bytes32 revertedOrStaticRollingHash; // expected sub-call hash, checked for STATIC / REVERTED; must be 0 for SUCCESS
    bool success;                        // whether resolution returns or reverts
    bytes returnData;                    // returned on success / reverted-with when !success
}

/// TOP-LEVEL static entry — lives in the pool; resolvable only outside an execution.
struct StaticExecutionEntry {
    ExpectedRootPerRollup[] expectedRoots; // root pins — part of the MATCH — see §6
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
it pins the recorded hash context, rather than a unique occurrence or local state version:

- Identical calls key differently when their `_rollingHash` values differ. Local writes with no intervening fold do not change the key.
- A read and a state-changing call with identical params key differently (`isStatic` in the
  call hash).
- A reverted sub-execution reuses the host table for its own reentrant calls; its rows can't
  collide with host-level rows because their keys embed the sub-execution's interior
  `_rollingHash` values.

Matching scans forward from the reentrant cursor `_lastL1ToL2CallConsumed`. A CALL resolves
the first key match and advances the cursor past it. A STATIC read also checks each
candidate's callback-result hash and skips a mismatch. It cannot advance the cursor
(it is a `view` frame), so later reads can reuse any valid row at or after that cursor,
including an earlier candidate skipped by a previous read.

Completeness is enforced by the rolling hash, not by a table-length check: the unified table
mixes success rows with static/reverted ones, so unused rows are inert, while a *skipped*
success row omits its NESTED frame and diverges the entry hash.

---

## 4. Resolution mechanics

### 4.1 Reentrant (inside an execution)

**Static read** — `staticCrossChainCall`, in-execution branch:

1. (L1 only) proxy protection: the read's target rollup must be in the executing entry's
   allowed set (`_containsVerifiedRollup`, from its `rollupUpdates`) — else
   `ReentrantDestinationNotVerified`.
2. Compute the key from the static-kind `crossChainCallHash` + live `_rollingHash`; scan
   the active table forward from `_lastL1ToL2CallConsumed`.
3. On match → `_resolveStaticEntry(l2ToL1Calls, revertedOrStaticRollingHash, success,
   returnData)` (§4.3); if it returns false, continue scanning. On no match → `ExecutionNotFound` on L1, `EntryNotFound(hash, callGas)`
   on L2 (a `view` frame cannot fold a
   `CALL_NOT_FOUND` divergence, so it reverts directly — unlike a reentrant CALL no-match,
   which folds the tag and returns empty so the entry fails later at `RollingHashMismatch`).

**Reverted reentrant call** — `_consumeNestedCall` → `_resolveNestedReentrant`, `success == false`
row:

```
advance _lastL1ToL2CallConsumed past the matched row
_rollingHashNestedBegin(crossChainCallHash)          // open the frame
_processL2ToL1Calls(row.l2ToL1Calls)                      // run the frame's OWN sub-array, tagged schema
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

- While a batch is mid-flight (`_transientEntriesLength != 0`): **only** the batch's
  transient pool `_transientStaticEntries` — the transient phase is self-contained (see
  `docs/CAVEATS.md`).
- Otherwise: the calling proxy's rollup queue,
  `verificationByRollup[destRid].staticEntryQueue`.

Match predicate (full scan — a non-matching candidate is skipped, never an error):

```
staticEntry.proxyEntryHash == crossChainCallHash
&& staticEntry.destinationRollupId == destRid
&& _rootsMatch(staticEntry)        // every pin equals the live root — §6
```

The standard [same-block restriction](CORE_PROTOCOL_SPEC.md#g4-same-block-restriction) applies.
Every batch verifying the rollup also replaces its static and mutable queues.

On L2, lookup scans `staticEntries[0..staticEntriesLength)` and matches
`proxyEntryHash` plus `expectedEntryIndex == entryIndex`. Both load entry points
replace the active mapping bounds and reset the mutable cursor.
The scan restarts at zero for every read, but candidates must also pin the live mutable
cursor. Successful entry consumption therefore allows same-key read → write → read
with distinct cached results. Failed consumption restores the cursor with its state.
Local writes that leave the cursor unchanged can be distinguished by sibling candidates
whose callback-result hashes differ (§4.4). The same retry rule applies to nested reads
at an unchanged host rolling hash. If incompatible candidates both validate, the first
wins; builders must reject or restructure that ambiguity. Observed gas is not a general
state-version discriminator.

A top-level L1→L2 static read is a *lookup*: it resolves from the pool and never produces
an L2 delivery. The same lookup treatment applies to an L1→L2 call that reverts on L2
and to one whose L1 frame is reverted afterwards — a signed prediction (return or revert
data), nothing applied on L2, root unchanged (`CORE_PROTOCOL_SPEC.md` §A.1, L2 prover
constraints). An L2→L1 top-level static read instead executes on L1 within the source
transaction's zero-hash L2Tx entry.

### 4.3 `_resolveStaticEntry` / static call processing

The processor is `_processStaticL2ToL1Calls` on L1 and `_processStaticIncomingCalls` on L2. The pseudocode below uses the L1 name.

Both the reentrant STATIC branch and the top-level pool resolve through `_resolveStaticEntry`:

```
if _processStaticL2ToL1Calls(calls) != rollingHash: return false
if (!success) revert(returnData)
return true // caller returns this row's cached returnData
```

A false result continues the scan in the current lookup window. Exhaustion reports
`ExecutionNotFound` on L1 or `EntryNotFound(hash, callGas)` on L2. A matching cached
revert is terminal, and sub-call validation errors still revert immediately.

`_processStaticL2ToL1Calls` runs the sub-call array flatly in **static context**:

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
- `revertNextNCalls == 0` is both a prover constraint and a runtime requirement (`StaticCallWithRevertSpan`).
- After resolving the already-deployed proxy and encoding the forwarding payload, a nonzero cap is checked by `_hasEnoughCallGas`; shortage reverts `InsufficientCallGas(uint64 callGas)`. Zero cap bypasses the estimate. The exclusions in CORE §B.1 apply.

A naturally-reverting *sub-call* is not special: the STATICCALL returns `(false, retData)` and
the untagged hash captures it. The entry-level `success == false` is for the *whole read*
reverting toward its caller.


### 4.4 Local writes between identical static reads

Suppose the remote `quote()` calls back to the reader's local `rate()` and returns
that value directly. A single reader invocation performs:

```solidity
rate = 1;
quoteAtRate1 = remoteProxy.quote(); // must equal 1
rate = 2;
quoteAtRate2 = remoteProxy.quote(); // must equal 2
rate = 1;
quoteAfterResetToRate1 = remoteProxy.quote(); // must equal 1
```

The local writes occur outside the static calls. They need not change the lookup key,
root pins, entry cursor or host rolling hash. Supply two candidates, in this order:

| Candidate | Callback array | Expected callback-result hash | Cached outcome |
| --- | --- | --- | --- |
| A | STATICCALL the reader's `rate()`, sourced from the remote quote contract | `keccak256(abi.encodePacked(bytes32(0), true, abi.encode(uint256(1))))` | `success = true`, `abi.encode(uint256(1))` |
| B | Same callback | `keccak256(abi.encodePacked(bytes32(0), true, abi.encode(uint256(2))))` | `success = true`, `abi.encode(uint256(2))` |

Both candidates have the same lookup context. The first read selects A. The second
read evaluates A, gets callback result 2, rejects A's hash, then evaluates and selects B.
The third read selects A again. The scan starts from the normal lookup start on every
read; it never remembers the last successful static candidate.

The four E2Es have local Anvil coverage and are excluded from automatic network
suites pending live validation. See the [runner status note](../script/e2e/README.md).

This covers four execution paths:

| Resolver path | Shared candidate context | E2E scenario |
| --- | --- | --- |
| L1 top-level | `proxyEntryHash`, `destinationRollupId`, live `expectedRoots` | [staticLocalWrite](../script/e2e/static/L1_to_L2/staticLocalWrite/E2EStaticLocalWrite.s.sol) |
| L2 top-level | `proxyEntryHash`, `expectedEntryIndex = 0` | [staticLocalWriteL2](../script/e2e/static/L2_to_L1/staticLocalWriteL2/E2EStaticLocalWriteL2.s.sol) |
| L1 nested | `expectedL1toL2Hash = keccak256(staticCallHash, hostHash)`; both rows at/after the cursor | [nestedStaticLocalWriteL1](../script/e2e/static/L2_to_L1/nestedStaticLocalWriteL1/E2ENestedStaticLocalWriteL1.s.sol) |
| L2 nested | `expectedOutgoingHash = keccak256(staticCallHash, hostHash)`; both rows at/after the cursor | [nestedStaticLocalWriteL2](../script/e2e/static/L1_to_L2/nestedStaticLocalWriteL2/E2ENestedStaticLocalWriteL2.s.sol) |

#### Builder and prover handling

1. Simulate the full source transaction, including direct local writes. Keep the real
   caller, calldata, static flag, gas-key mode and frame boundaries for each read.
2. Preserve distinct static alternatives under the same key. Do not deduplicate solely
   by `proxyEntryHash` or the nested position key. Identical complete rows may be reused.
3. For each alternative, record its ordered callback array, callback success/revert
   bytes, untagged callback-result hash, and the remote read's own success/return or
   revert bytes. Prove that outcome against the applicable remote state and callbacks.
4. Keep every required candidate in the same valid lookup window: current root pins
   on L1, the live entry cursor on L2, or indices at/after the nested cursor. Do not
   insert a mutable consumption or change the host hash to distinguish these reads.
5. Represent only the logical cross-chain frames on the producer chain. Candidate
   validation retries are local replay checks, not additional logical remote calls or
   deliveries. In the nested E2Es, one `reader.run()` frame owns all three quotes.
   On the quote chain, the three real quote executions have successive `CALL_BEGIN`
   hashes, so their callback lookup rows are keyed to those separate host positions.
6. Budget gas for every attempted candidate and all its callbacks. Attempts can change
   remaining gas and access warmth even though they cannot write application state.
   Gas-sensitive callbacks require simulation of those effects too.

For top-level L1→L2, obtain the quote results by read-only simulation on L2 with the
source trace's callback results; do not invent an L2 delivery or root transition.
For top-level L2→L1, execute all three real quotes in the transaction's one L1 L2Tx
entry. Nested reads stay within the original mutable frame on both chains.

The callback hash is a validation predicate, not a new globally unique key. Two
candidates with incompatible outcomes that both validate remain ambiguous: the first
wins. Empty callback arrays all hash to zero. A builder must reject or restructure
such cases rather than relying on row consumption, occurrence counts or table reloads
between reads.

#### Retry outcomes

| Result while examining a candidate | Action |
| --- | --- |
| Lookup key/context does not match | Skip without executing its callbacks. |
| Callback-result hash differs | `_resolveStaticEntry` returns false; try the next candidate. |
| Hash matches and `success == true` | Return this candidate's cached `returnData`. |
| Hash matches and `success == false` | Revert with this candidate's cached `returnData`; do not try later candidates. |
| Malformed static sub-call, missing source proxy, or insufficient-gas preflight | Revert immediately with the existing validation error. |
| All candidates exhausted | `ExecutionNotFound()` on L1; `EntryNotFound(crossChainCallHash, callGas)` on L2. |

A callback's own natural revert is folded as `(false, revertData)` into the callback
hash; it is not automatically a candidate-validation error. Mutable entry and mutable
reentrant hash mismatches retain their existing `RollingHashMismatch` behavior.

The four E2Es use the local runner's accepting proof fixture. They check actual
execution, table content and frame mapping; they do not establish production circuit
acceptance. Commands and expected call counts are in the
[E2E authoring guide](../script/e2e/BUILD_AND_REVIEW_E2E_TESTS.md#static-read--local-write--read-with-callbacks).

---

## 5. Per-frame sub-arrays

Every reentrant-table row and every static entry carries its **own** sub-call array, run to
completion by its resolver unless a revert or the mutable processor's gas-shortage return interrupts it:

- STATIC rows / static entries: run flatly by `_processStaticL2ToL1Calls` (untagged hash).
- REVERTED rows: run by `_processL2ToL1Calls` as a mini-entry (tagged schema, may itself contain
  reentrant calls — resolved from the host table — and `revertNextNCalls` spans).

There is no global flat-call cursor and no `callCount` partition: the entry's `l2ToL1Calls[]`
holds only its TOP-LEVEL calls, and each frame's completeness is structural (the resolver
walks its own array; a mutable gas shortage stops only that array and folds tag 6).

---

## 6. Root pins (top-level, L1 only)

`expectedRoots[]` content-addresses a top-level static entry to a point on each pinned
rollup's trajectory: a candidate only **matches** when every pin equals the live
`rollups[rollupId].root` (`_rootsMatch`, full-scan semantics — a mismatching
candidate is skipped and the scan continues; no dedicated error). The pins are:

- **State matching** — pins invalidate a cached read once any pinned rollup's root moves on.
- **Transient-phase capable** — roots advance entry-by-entry during a batch, so a pin can
  target an intermediate mid-batch state.
- **The validation-time proven set.** `_validateBatchStructure` enforces, per static entry:
  pins strictly increasing by `rollupId` (rejects duplicates and, bounding above
  `MAINNET_ROLLUP_ID`, a mainnet pin — `ExpectedRootsNotStrictlyIncreasing`); every
  pinned rollup in the batch (`RollupNotInBatch`); `destinationRollupId` among the pins
  (`StaticEntryDestinationNotPinned` — the routing target must be pinned to proven state,
  mirroring the entry `destination ∈ rollupUpdates` rule); and every sub-call's
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
contains at least one non-L2Tx entry. If no hook fires (empty immediate prefix, or one that
is pure L2Txs), a non-zero `immediateStaticEntryCount` would silently drop the leading
static entries — never loaded transiently, never published to the queues
(`_saveRemainderEntries` starts past them) — so the contract rejects the post
(`ImmediateStaticEntriesWithoutImmediateEntries`, checked after the immediate L2Tx run).
Composers whose immediate prefix is pure L2Txs set `immediateStaticEntryCount = 0` so the
static entries flow to the persistent `staticEntryQueue`s.

---

## 7. L1 / L2 differences

- **Structs**: L2's `StaticExecutionEntryL2` adds `expectedEntryIndex` and drops `expectedRoots` and
  `destinationRollupId` (single rollup, no roots); its reentrant row is
  `ExpectedOutgoingCrossChainCall` with `expectedOutgoingHash` / `incomingCalls` (same layout,
  self-relative names). The key helper (`_computeExpectedL1toL2Hash`) and the untagged
  accumulator (`_rollingHashStaticResult`) are shared in `EEZBase`.
- **Pool**: L1 selects transient-vs-persistent by `_transientEntriesLength` and matches with
  destination + pins; L2 scans the one `staticEntries` table by hash and live `entryIndex`.
- **Call-hash source side**: the static key folds `sourceRollupId = MAINNET_ROLLUP_ID` on L1
  and `= ROLLUP_ID` on L2 (the reader lives on this chain), `value = 0`, and `callGas = 0` on L1;
  on L2 `callGas` follows the outgoing policy — `gasleft()` sampled after proxy validation when
  `USE_GAS_LEFT`, else `0` (see CORE_PROTOCOL_SPEC §C.2/§C.3).
- **Proxy protection**: L1's reentrant static branch checks `_containsVerifiedRollup(destRid)`
  against the executing entry's `rollupUpdates`; L2 has no allowed-rollups set.
- **Reentrant-table source**: L1's `_getExpectedL1toL2Calls()` has three sources (the parked
  immediate-L2Tx table, the transient entry at `_currentEntryIndex`, or the persistent queue
  entry of `_currentEntryRollupId`; an empty parked table with `_currentEntryRollupId == 0`
  yields an empty table, so a static read misses with L1's `ExecutionNotFound` and a CALL folds
  `CALL_NOT_FOUND`); L2's `_getExpectedOutgoingCalls()` always indexes the single `entries` table.

---

## 8. Invariants (summary)

- `success == false` ⇒ resolution ends in `revert(returnData)`; `success == true` ⇒ it
  returns `returnData`. Same polarity on `ExecutionEntry`, `ExpectedL1ToL2Call`, and
  `StaticExecutionEntry`.
- A static read never mutates: STATICCALL dispatch, untagged hash, no cursor advance, no
  proxy auto-creation (`StaticCallProxyNotDeployed` on a codeless proxy), no
  `revertNextNCalls`.
- STATIC rows/entries use the untagged local accumulator seeded at `bytes32(0)`: an empty
  static array requires expected hash `0`.
- REVERTED mutable rows use the tagged host accumulator after `NESTED_BEGIN`. With no
  sub-calls, their expected hash is `keccak256(abi.encodePacked(hostHash, uint8(3), callHash))`,
  generally nonzero.
- STATIC and CALL kinds can never match each other's keys — `crossChainCallHash` folds
  `isStatic`.
- Matching is strictly forward from the reentrant cursor; a CALL consumes its row (cursor
  past it), a static read does not.
- A REVERTED resolution runs its own sub-array with the tagged schema inside NESTED_BEGIN,
  checks the sub-hash, then terminal-reverts — state, cursor, and hash all roll back with it.
- No-match asymmetry: a reentrant CALL no-match folds `CALL_NOT_FOUND` and returns `""` (the
  entry fails at its rolling-hash check); a static no-match reverts immediately, in both
  branches — `ExecutionNotFound` on L1, `EntryNotFound(hash, callGas)` on L2.
- L1 top-level match = `proxyEntryHash` + `destinationRollupId` + all pins live; full-scan
  skip semantics. Every re-verify of the rollup resets `staticEntryQueueIndex` to zero without deleting `staticEntryQueue` mapping entries. Publishing overwrites slots from index zero; lookups scan only below the active bound.
- Validation (L1): pins strictly increasing and in-batch; `destinationRollupId` ∈ pins;
  every sub-call source ∈ pins; whole static entries folded into `publicInputsHash`;
  `immediateStaticEntryCount ≤ staticEntries.length`, and a non-zero count requires the
  meta hook to actually fire (≥1 non-L2Tx immediate entry) — enforced after the immediate
  L2Tx run (`ImmediateStaticEntriesWithoutImmediateEntries`), since the transient static
  pool is only reachable through the hook — see §6.

### L2 cursor pins

`StaticExecutionEntryL2.expectedEntryIndex` must equal the live `entryIndex` when the read fires. A mismatching candidate is skipped. Static reads do not advance the cursor. Consuming mutable entry `j` leaves the cursor at `j + 1`; failed consumption rolls it back. Loading a new table replaces the active prefixes of both mappings and resets the cursor to zero. Static lookup is bounded by `staticEntriesLength`, so retained inactive rows cannot match. The builder must use the live cursor, not a count of successful calls. This distinguishes top-level reads across successful consumptions, but does not version local writes that leave the cursor unchanged. Nested lookup remains keyed by the rolling hash.

### Static reads that still share one lookup context

The local-write example in §4.4 works because the callback results distinguish the
candidates. With identical call inputs, relevant state, callbacks and execution
context, deterministic execution must produce the same result; conflicting cached
outcomes cannot both be correct.

A dependency can nevertheless change without changing the lookup key or callback
hash. For example, `return gasleft() < 400_000 ? 1 : 2` produces different answers
under different budgets. In gas-independent mode, two rows with empty callback
arrays share both the call key and callback hash zero. The first matching row wins.
This is an [accepted support limit](CAVEATS.md): builders must reject or restructure
traces whose required outcomes cannot be selected.

Candidate retries spend gas even when results are gas-insensitive. A stale candidate
can consume the budget needed by the correct one. Mutable calls also have a separate
retry limit: an enclosing revert restores their hash/cursor, and an identical retry
selects the first matching row without trying alternatives on a hash mismatch.
[EEZExpressiveness tests](../test/EEZExpressiveness.t.sol) cover these cases and the
supported static revert/local-write/retry case.

### Other static-read requirements, with examples

These are validity and execution prerequisites, in addition to candidate validation above.

| Case | Example and current behavior |
| --- | --- |
| Cached dependencies changed between transactions | Tx A prepares a callback to `rate() = 1`; another transaction changes it to 2; Tx B reuses the old row. Refresh the table when this invalidates its results. Reuse across transactions is allowed while results and lookup contexts remain valid within the load/verification block. |
| Table is from an earlier block | Load/verify in block N, then read in N+1: the top-level same-block gate rejects it even if application state is unchanged. Load/verify again. |
| Wrong cursor, root pins, call key or lookup window | L2 row expects cursor 1 while the live cursor is 0; L1 row pins R0 while the live root is R1; or a nested row lies before the forward cursor. Such rows do not match; without another matching row the read reverts. Under `USE_GAS_LEFT`, a different sampled gas value also changes the L2 call key. |
| Wrong L1 table scope or proven rollup set | A read in the meta-hook window expects a row only in an older persistent pool, or a nested read targets a rollup absent from the active entry's proven set. Supply the row in the active pool and include the required rollup; there is no fallback to the older pool. |
| Successful mutation during a static callback | A callback attempts `rate = 2`, emits a log or creates a contract: EVM static execution prevents it. An expected failed callback can still be represented; successful mutation cannot. |
| Callback marked mutable or carrying ETH | A static row supplies `isStatic = false` or `value = 1`: the manager rejects it with `NonStaticSubCall` or `StaticCallWithValue`. Static callbacks must be read-only and zero-value. |
| Rollback span inside a static row | A callback has `revertNextNCalls = 1`: rejected with `StaticCallWithRevertSpan`. An ordinary reverting read or callback is supported; mutable rollback spans are not part of static execution. |
| Missing callback source proxy | The read would need to deploy its callback's source proxy: rejected with `StaticCallProxyNotDeployed`. Predeploy it before the static read. |
| Insufficient execution gas | The supplied transaction cannot meet a callback's nonzero gas-cap preflight: `InsufficientCallGas`. A zero cap skips that estimate, not EVM gas limits; it does not guarantee completion. |

Supply all required candidates for within-transaction reads. A gas-dependent key is not a general state-version guarantee.
