# E2E Tests — Building & Reviewing

How to write a new cross-chain scenario and how to audit an existing one. For setup
and running (local/network modes, runners, what a run verifies), see [README.md](README.md).
For entry construction and the rolling-hash schema (tagged folds, seeded with entry
identity, **no call indices**), see `docs/EXECUTION_ENTRY_SPEC.md` and
`docs/CORE_PROTOCOL_SPEC.md` §E; always use the helpers in `shared/E2EHelpers.sol` /
`shared/ComputeExpectedBase.sol` rather than inlining `keccak256` folds.

Living references — when this doc and the code disagree, the code wins:

- Simple L1→L2: `one_way/L1_to_L2/counter`; simple L2→L1: `one_way/L2_to_L1/counterL2`.
- Multiple completed L1→L2 frames from one trigger: `multi_call/L1_to_L2/multi-call-twice`.
- Several L2→L1 calls in one L2 user tx: `multi_call/L2_to_L1/multi-call-twiceL2`.
- Deep open-frame nesting: `reentrant/L1_to_L2/reentrant`.
- Nested revert, both anchorings: `revert/L1_to_L2/nestedCallRevert` and
  `revert/L2_to_L1/nestedCallRevertL2`.
- Successful L2-originated nesting kept in one frame: `nested/L2_to_L1/nestedCounterL2`.
- Static reads, all four homes: `static/L1_to_L2/topLevelStaticCounter` (top-level, the ONLY
  view-only case), `static/L2_to_L1/staticCounterL2` (top-level, read executed on L1),
  `static/L1_to_L2/nestedStaticCounter` and `static/L2_to_L1/nestedStaticCounterL2`
  (nested, STATIC-kind rows + real `isStatic` execution) — see "Static reads" below.

## The frame-coherence invariant

Every entry, call, return value, revert value, and state transition on one chain must
be explained by the same causal execution on the other chain. A scenario is invalid if
it sends an extra transaction merely to create the state or return data expected by
its independently authored table.

The authority for transaction boundaries is **frame lifetime**: a call made before its
current cross-chain frame returns is nested and must remain in that frame. Whether an
event survives is verification evidence; it does not create a new transaction boundary.

Vocabulary, used consistently below:

- **Trigger** — the real user transaction.
- **Top-level cross-chain call** — opens a new remote frame.
- **Nested/reentrant call** — crosses a chain while another remote frame is still open.
- **L2 system delivery** — `executeIncomingCrossChainCall` for a completed top-level
  L1→L2 call.
- **L1 L2Tx entry** — the single zero-hash entry representing one L2 user transaction.

## Why two-sided

The protocol commits on the source side to "the destination chain will execute X and
produce returnData=Y" via a cached `returnData` (plus a per-rollup `RollupUpdate` on L1).
A single-sided test only checks the source-side bookkeeping — the destination chain stays
passive. A two-sided test additionally invokes the destination call for real, so any drift
between the cached `returnData` and what the destination actually produces surfaces as an
assertion failure.

The cross-chain call hash (`computeCrossChainCallHash(...)`, identical formula on both
managers) is the call-level cryptographic tie. For L1→L2 top-level calls, a green
two-sided run can observe the same hash in both chains' consumption events. For an
L2-triggered transaction, L1's zero-hash L2Tx entry has no proxy-consumption hash;
linkage instead comes from matching each L2 source consumption to the corresponding
ordered `l2ToL1Calls[]` preimage, result, and nesting in the single L1 entry. Reverted
nested frames may also erase their event evidence, so table content and rolling hashes
remain part of the proof even when no paired event survives.

## Deriving the tables from the real transaction

Before constructing structs:

1. Identify every actual user transaction.
2. Draw its ordered calls; mark each cross-chain frame opening and full return.
3. Keep all calls made before a frame's return inside that open frame.
4. Only then derive L1 entries, L2 entries, nested rows, and system deliveries.

### L1-originated transaction

One L1 trigger may create multiple L2 system deliveries when it completes one L2
frame and later opens another:

```text
L1 → L2 A → return → L2 B → return     ⇒ two source entries, two L2 deliveries
```

Nested ping-pong does NOT create more deliveries — while the original frame stays
open, later hops belong in that entry's nested tables and frame-owned sub-arrays:

```text
L1 → L2 A → L1 B → L2 C                ⇒ ONE L2 delivery; B, C live in its tables
```

### L2-originated transaction

One L2 user tx produces exactly **one** L1 zero-hash L2Tx entry, regardless of how
many sequential L2→L1 calls it makes — they are ordered elements of that entry's
`l2ToL1Calls[]`:

```text
one L2 user tx: L1 A → return → L1 B   ⇒ one L1 entry, l2ToL1Calls = [A, B]
```

The L2 table still has one source entry per outgoing proxy consumption — entry
counts are NOT required to match across chains. For a nested round trip
(`L2 → L1 A → L2 B`), B executes inside the same L2 source entry that initiated A —
through that entry's `incomingCalls[]` or a frame-owned sub-array. Never append a
later `executeIncomingCrossChainCall` for B.

## Direction matters — destination-side simulation

| Source-side trigger | Destination-side simulation |
|---|---|
| L1 (`postAndVerifyBatch` + user tx) | `managerL2.executeIncomingCrossChainCall(entries, staticEntries)` from `SYSTEM_ADDRESS` — atomically replaces the table and drives `entries[0]` (its `incomingCalls[0]` is the inbound call), lazily creating the source proxy on L2 |
| L2 (`loadExecutionTable` + user tx) | L1 batcher posting an entry with `proxyEntryHash = bytes32(0)` covered by `immediateEntryCount` — the entry executes inline during `postAndVerifyBatch` as an immediate L2Tx |

There is no `executeIncomingCrossChainCall` on L1 — the L1-side analog for system-driven
execution is the immediate-L2Tx path. Note the batch-structure rule: the leading run of
`proxyEntryHash == 0` entries **must** be covered by `immediateEntryCount`
(`ImmediateCountStrandsLeadingL2Tx` otherwise); `executeL2Txs(rollupId)` only serves
zero-hash entries that sit *behind* a non-zero-hash entry in the queue.

## File anatomy — the contracts in each scenario script (`E2E<Name>.s.sol`)

```
abstract contract <Scenario>Actions {
    // callData builders, call-hash helpers, _l1Entries, _l2Entries — single source of truth
}

contract Deploy{,L2}                 // deploy contracts on each chain (run-local detects suffix)
contract ExecuteL2                   // L2-side trigger / simulation
contract Execute                     // L1-side trigger / simulation
contract ExecuteNetwork{,L2}         // network-mode user-tx helpers (only `view` — emit envs)
contract ComputeExpected             // computes expected tables — DRIVES all verification
                                     // (its EXPECTED_* output lines switch every check on/off)
contract VerifyNetwork{,L2}          // OPTIONAL network-mode self-verification: read-only
                                     // asserts on live state after the trigger (L1/L2 RPC);
                                     // mandatory when ComputeExpected is omitted
```

`run/local.sh` auto-runs `ExecuteL2` first, then `Execute`. If only one is present the
other phase is skipped — keep both for two-sided.

## Patterns

- **Pattern A — L1→L2** (`counter`, `bridge`): one `ExecutionEntry` per side with
  **matching `proxyEntryHash`**. The L1 (source) entry caches `success`/`returnData`
  produced by the real L2 execution — in the simple flat case it has no calls
  (`rollingHash` is just the seeded accumulator); the L2 (destination) entry carries
  the real inbound call in `incomingCalls[0]` and is driven by
  `executeIncomingCrossChainCall`. When the remote execution calls back: calls
  executing on L1 go in the L1 entry's `l2ToL1Calls`; deeper L1→L2 reentries in
  `expectedL1ToL2Calls`; the L2 entry's outgoing nested frames in
  `expectedOutgoingCalls`, each frame's calls back into L2 in that frame's own
  `incomingCalls`.
- **Pattern B — L2→L1** (`counterL2`, `revertCounterL2`): the L2 side is the source
  (entry via `loadExecutionTable` + proxy trigger); the L1 side executes for real via
  ONE immediate `proxyEntryHash = bytes32(0)` entry whose ordered `l2ToL1Calls[]` are
  the destination calls, with nested L1→L2 resolutions in `expectedL1ToL2Calls`. Any
  call returning to L2 inside a consumption executes from that same source entry's
  `incomingCalls[]` (`nestedCounterL2`, `nestedCallRevertL2`).
- **Pattern C — multi-call flows**: N top-level calls from ONE user trigger.
  L1→L2 (`multi-call-twice`, `multi-call-two-diff`): N proxy consumptions on L1 → N
  deliveries on L2 (one entry per tx), both sides sharing the per-call
  `proxyEntryHash`. L2→L1 (`multi-call-twiceL2`, `multi-call-two-diffL2`,
  `multi-call-nestedL2`): N outgoing entries + an L2 trigger contract firing the N
  proxy calls (the contract's address is the entries' `sourceAddress`), while the L1
  side stays ONE L2Tx entry — so the sides' `proxyEntryHash` values diverge by design
  and the cross-chain tie is the mapping checklist below plus destination-state
  assertions.

## Static reads (cross-chain STATICCALLs)

A cross-chain read RESOLVES from prover-supplied data on the reader's chain
(`staticCrossChainCall`, a `view` path) but — with one exception — still EXECUTES for
real on the chain that owns the read state. Split by where the read fires:

- **Inside an execution** (nested): the reader's chain resolves it from a STATIC-kind
  row of the active entry's unified reentrant table, keyed
  `keccak(staticCcHash, rollingHash-at-fire)` — position-pinned, never consumed, and
  folding NOTHING into the rolling hash (the surrounding `CALL_END` retData pins the
  value instead). The chain that owns the state executes the read for real: that is
  what `isStatic: true` on `L2ToL1Call` exists for — put the read in the destination
  entry's `l2ToL1Calls[]` (or the reentrant frame's own sub-array when it fires inside
  a nested frame) and `_processL2ToL1Calls` dispatches it via STATICCALL through the
  reader's source proxy into the live contract, folding
  `CALL_BEGIN(staticCcHash)` / `CALL_END(success, realRetData)`.
- **Top-level from L2** (outside any execution, reading L1): the reader's chain
  resolves it from the `staticEntries` pool (same-block gate, matched by hash and live `entryIndex`),
  and the read still executes for real on L1 — the L2 user tx maps to its usual
  zero-hash L2Tx entry, whose `l2ToL1Calls[0]` is the `isStatic: true` read.
- **Top-level from L1 reading L2** — the ONLY view-only case: L2 executes NOTHING (no
  delivery exists for it). The read resolves from the routed rollup's
  `staticEntryQueue` on L1 (match = key + `destinationRollupId` + every root pin
  live), and requires `lastVerifiedBlock(destRid) == block.number`. Matching roots
  do not extend validity beyond the verification block. The L2-side truth is checked
  against the pinned state and the real producer's value.

For each static read, correlate the source/target address and rollup pairs, calldata,
static mode, and exact result bytes from the real producer (rule 3). Call-hash equality
also requires matching gas inputs: L1 static keys and delivered-call `CALL_BEGIN`
folds on both chains use `callGas = 0`; outgoing L2 static keys use
`uint64(gasleft())` sampled after proxy authorization/storage reads when
`USE_GAS_LEFT` is enabled, and zero otherwise. This applies to both top-level and
nested static lookups. The gas-independent fixtures can compare these hashes directly;
observed-gas integrations must correlate the call fields while accounting for the
site-specific gas value. See the [core hash matrix](../../../docs/CORE_PROTOCOL_SPEC.md#c-action-hash-computation).

Authoring notes specific to static scenarios:

- **Keys fold the proxy caller's address.** A static entry only matches reads from the
  caller it was keyed to — any other sender gets `ExecutionNotFound`.
- **Predictions are obtained, not hardcoded** (view-only top-level L1→L2 case only,
  `topLevelStaticCounter`): the producer-chain deploy performs the actual staticcall
  and exports its raw returndata (`PREDICTED_STATIC_RESULT`, env bytes — generic over
  return types); the entry caches those bytes verbatim, replicating how a composer
  predicts the result from the node. A client learns the same result through the
  standard no-tx query: an eth_call through the proxy impersonating the READER
  (`vm.prank(address(reader))` — forge never broadcasts static calls), resolving the
  SAME entry the trigger uses. Exercise it in local `Execute` only (same block): the
  entry requires both current-block verification and matching root pins. A root change
  or queue replacement can invalidate it within that block, and the block gate rejects
  it in later blocks even if the roots still match. A deferred `VerifyNetwork` must
  therefore verify persisted evidence rather than re-issue the read.
- **Eventless sides are verified from calldata, not events.** Static resolution emits
  no events and a posted L1 `staticEntries` batch emits nothing per-entry either.
  Export `EXPECTED_*_HASHES` only for sides that actually have `ExecutionEntry`s
  (`staticCounterL2` exports L1 only), an eventless side explicitly as `[]` (the
  network runner treats a MISSING export as an error), and the L1 static entries via
  `_printL1StaticTable` (`EXPECTED_L1_STATIC_TABLE`): both runners match them
  field-by-field from the settlement tx's `postAndVerifyBatch` calldata with the
  root-pin VALUES neutralized. A scenario with NO `ExecutionEntry` on either side
  (`topLevelStaticCounter`) therefore still has a ComputeExpected — all hash lists
  `[]` plus the static table — and its `VerifyNetwork` asserts persisted state only.
- **A lookup's absence on L2 is ASSERTED, not assumed.** A scenario whose L1→L2 call is
  a lookup (reverts on L2: `revertCounter`; top-level static read:
  `topLevelStaticCounter`) exports `ABSENT_L2_HASHES=[<call key>]`; both runners run
  `VerifyL2Absent` over the post-trigger L2 range (network: snapshot..latest, scanned
  once L2 has produced the last block the settlement proved — correlation RPC — or
  after `L2_ABSENT_GRACE` without it) and
  fail on any delivery / consumption event or loaded entry / static entry with that key.
  An empty `EXPECTED_L2_HASHES` alone only skips the L2 checks — it proves nothing.
- **A sub-call-less static entry needs `rollingHash == 0`** (the untagged static
  accumulator seeds at zero and an empty sub-array is always compared).

### Static read → write → read scenarios

Each scenario runs one source transaction without reloading tables between reads:

| Source | Scenario | Proxy calls in the trigger | Calls executed on the destination |
| --- | --- | --- | --- |
| L1 | `static/L1_to_L2/staticReadWrite` | read 0 → increment 1 → read 1 | One L2 increment delivery; static reads are L1 lookups. |
| L2 | `static/L2_to_L1/staticReadWriteL2` | read 0 → increment 1 → read 1 | Three L1 calls in one zero-hash L2Tx entry. |
| L1 | `static/L1_to_L2/staticReadX2Write` | read 0 → read 0 → increment 1 → read 1 → read 1 | One L2 increment delivery; static reads are L1 lookups. |
| L2 | `static/L2_to_L1/staticReadX2WriteL2` | read 0 → read 0 → increment 1 → read 1 → read 1 | Five L1 calls in one zero-hash L2Tx entry. |

All four use two static rows: before and after the increment. L1 rows pin the
pre/post L2 roots; L2 rows pin `expectedEntryIndex` 0 and 1. The future row is first
so matching must check the context. The X2 variants reuse each row twice and check
that static reads do not advance the cursor.

Each scenario file contains its target counter, trigger, `Actions`, deployment,
execution and `ComputeExpected` contracts. Assertions check the observed read values,
the real destination increment, and one mutable consumption. L1-originating cases
also verify that static reads produce no L2 delivery or loaded entry.

```bash
bash script/e2e/run/local-parallel.sh staticReadWrite staticReadWriteL2
bash script/e2e/run/local-parallel.sh staticReadX2Write staticReadX2WriteL2
```

### Static read → local write → read with callbacks

**Status: NOT LIVE YET in staged or parallel network testing.** These four scenarios
are validated locally only and excluded from automatic `all` / `all:N` runs and the
local default set. Their `E2E_EXCLUDE_FROM_ALL` markers control this exclusion.
The explicit command below is for local development; names and category selections
remain available and do not imply live readiness.

These scenarios cover candidate retries without a mutable EEZ call between reads.
Each scenario file contains its reader, remote quote producer, and both chains'
entry builders. One `reader.run()` sets its local rate to `1 → 2 → 1` and reads the same
remote `quote()` after each write. The quote calls back to the reader's `rate()` and
returns that rate directly; all three results (`1 → 2 → 1`) are asserted individually inside the
actual reader transaction and persisted for inspection. `run()` returns no data; there is no aggregate result to interpret.

| Resolver under test | Scenario | Trigger and paired execution |
| --- | --- | --- |
| L1 top-level | `static/L1_to_L2/staticLocalWrite` | Direct L1 reader call; two static rows with identical live root pins. Real L2 quote results come from fork-only prediction with the source callback values. No L2 delivery; the quote key is asserted absent from mined L2 tables/events. |
| L2 top-level | `static/L2_to_L1/staticLocalWriteL2` | Direct L2 reader call; two static rows at cursor 0. One L1 zero-hash L2Tx entry executes the three real quotes and resolves their static callbacks. |
| L1 nested | `static/L2_to_L1/nestedStaticLocalWriteL1` | One L2 proxy call to the L1 reader. One L1 zero-hash L2Tx entry runs the reader with two sibling quote rows. The same L2 source entry executes all three real quotes, with callback rows keyed to their firing positions. |
| L2 nested | `static/L1_to_L2/nestedStaticLocalWriteL2` | One L1 proxy call to the L2 reader. One L2 delivery runs the reader with two sibling quote rows. The L1 source entry executes the three real quotes, with callback rows keyed to their firing positions. |

The reader-side rows have equal lookup keys and distinct callback hashes. The second
read must reject the first candidate before selecting the second; the third must reuse
the first. No reload occurs between reads. L2 asserts cursor 0 for top-level reads and
exactly one mutable consumption for nested cases; L1 checks the expected root transition
(or unchanged root for top-level L1 reads). Expected tables and L1 fold steps are built
from the same call preimages used by both executions.

The nested scenario suffix names the chain where the retry is tested; its directory
names the mutable trigger direction. Local E2Es use `AcceptAllProofSystem`, so success
establishes paired execution and table consistency, not production circuit acceptance.

```bash
bash script/e2e/run/local-parallel.sh staticLocalWrite staticLocalWriteL2 nestedStaticLocalWriteL1 nestedStaticLocalWriteL2
```

Protocol rules, candidate construction and failure handling:
[STATIC_ENTRY §4.4](../../docs/STATIC_ENTRY.md#44-local-writes-between-identical-static-reads).

## Authoring rules (the audit checklist)

Every scenario must satisfy all of these; they are what the suite is audited against.

1. **One trigger per flow.** Each independent flow has exactly ONE user trigger tx (an
   EOA call into a proxy, an app contract, or a plain contract whose code fires the
   cross-chain call — see `reentrant`). `loadExecutionTable` and `postAndVerifyBatch`
   are setup, not triggers. The `multi_tx` category is the explicit exception: several
   real user txs, each an independent flow with its own complete paired representation.

2. **Every other tx must be derived from a completed top-level frame**
   (`docs/EXECUTION_ENTRY_SPEC.md` §1-to-1 rule) — never invent a transaction to make
   the scenario work. A delivery exists only for a completed top-level call that the
   destination can be proven to have executed — the trigger tx itself is the observable
   cause. Lookups get NO delivery: a top-level static read, and an L1→L2 call that
   reverts on L2 (`revertCounter` has no L2 side at all — the signed revert data travels
   in its `success=false` source entry). Reentrant/nested activity NEVER
   gets its own delivery, whether its frame commits or reverts: it folds into the
   still-open frame — `incomingCalls[]` of the entry the trigger consumes on L2
   (`nestedCounterL2` committing, `nestedCallRevertL2` reverting) or `l2ToL1Calls[]` /
   the unified reentrant tables on L1.

3. **Real producer.** Every non-empty `returnData` / revert-data in a table must be
   produced by real contract code executed somewhere in the flow — a real `Counter`
   returning `abi.encode(1)`, a real `RevertCounter` reverting
   `Error("always reverts")`. A span-erased execution still counts as a producer
   (`revertFromOtherChainL2`: the call runs, returns 1, and its state is erased).
   Hard-coding `abi.encode(1)` is acceptable only when the paired real execution
   provably returns that exact value at that exact point in the sequence.

4. **Rolling hashes.** Per entry: seed with `entryBegin` / `entryBeginL2`; fold every
   locally executed call with `CALL_BEGIN`/`CALL_END`; capture `rhFire` immediately
   after the containing call's `CALL_BEGIN` and before the nested call fires; key each
   nested row `expectedL1toL2Hash(crossChainCallHash, rhFire)` — where a call LEAVING
   an L2 keys with `crossChainCallHashL2Out` (equal to the plain hash only under
   `useGasLeft = false`, which all fixtures and current deployments use); for a COMMITTING frame
   fold `NESTED_BEGIN`, the frame's own sub-calls, and `NESTED_END` in runtime order.
   A frame that reverts leaves NO tags in the committed hash (the try/catch unwinds
   its folds and cursor bumps); its `revertedOrStaticRollingHash` is
   `appendNestedBegin(rhFire, innerHash)` + the frame's own sub-call folds and **no
   `appendNestedEnd`** — the manager checks it right after the sub-calls and folds
   `NESTED_END` only on the success path (`EEZ._resolveNestedReentrant`). A naturally
   reverting plain sub-call is `appendCallEnd(rh, false, revertData)` with
   `revertNextNCalls = 0`. Repeated calls may share a plain call hash; their nested
   keys still differ because `rhFire` advances. The two chains' rolling hashes
   describe different local executions and are not expected to be equal.

5. **Unwound events have no event-level expectations.** A `success=false` consumption
   erases its own `ExecutionConsumed`/`EntryExecuted` events — `ComputeExpected` must
   not export `EXPECTED_*_CALL_HASHES`/`EXPECTED_*_HASHES` for those sides (state a
   comment saying what pins that side instead: trigger assertions locally, the posted
   table on the network).

6. **Structure.** One shared `<Scenario>Actions` abstract builds BOTH sides' hashes
   from the same env addresses (no inlined duplicate `crossChainCallHash` calls that
   can drift); each contract role deployed on exactly one chain; the file header
   carries the ASCII call-flow schema (topology, one tree per side, final state) —
   copy the shape from `revert/L1_to_L2/nestedCallRevert`. Create proxies with the
   shared `getOrCreateProxy` helper, not inline try/create/catch (the inline form
   breaks forge's simulation replay when the proxy already exists).

## Cross-chain mapping checklist

For every call, match ALL of these across the two views — never accept final counter
values alone as proof of linkage:

- static/non-static mode; source address and source rollup; target address and target
  rollup; value and gas mode; exact calldata;
- success or failure; exact return or revert bytes;
- order in the transaction; nesting parent and frame boundary.

Top-level L1→L2 counterparts share the same cross-chain call identity. L2→L1 L1
entries use `proxyEntryHash == 0`, so their linkage is through their ordered
`l2ToL1Calls`, the L2 source consumptions, and nested rows — not equal entry hashes.

## Auditing an existing scenario

1. Read the header schema; check it matches what the Execute contracts actually do.
2. Identify the real user transaction(s); draw the cross-chain call tree and mark
   frame closure points; derive the expected number of L2 deliveries and L1 L2Tx
   entries from frame lifetimes (rules 1–2), then compare with `Execute`/`ExecuteL2`
   — no nested return implemented as a later system delivery, setup/consumption
   respecting the same-block gates.
3. Map every L1 `l2ToL1Calls[]` element to the L2 proxy call that caused it, and
   every nested row to its concrete call site and counterpart sub-array; run the
   mapping checklist field by field.
4. Trace each entry's `RollingHashBuilder` sequence fold-by-fold against rule 4
   (rhFire capture points, NESTED tags only for committing frames, no
   `appendNestedEnd` in reverted sub-hashes).
5. Chase every non-empty `returnData`/revert-data to its real producer (rule 3).
6. Check `ComputeExpected`: exports the complete expected tables (repeated hashes
   with correct multiplicity), nothing event-level for unwound sides (rule 5), both
   tables built from the same shared `Actions` helpers (rule 6).
7. Run it: `bash script/e2e/run/local.sh <path to E2E<Name>.s.sol>` must be green.

Reject the scenario if any call or entry can only be explained as "the test sends
another transaction to make the other chain reach the expected state."

### Fast rejection questions

1. Can every system transaction be derived from a completed top-level call?
2. Does every L2 user transaction map to exactly one L1 L2Tx entry?
3. Are all nested calls kept inside their open frame?
4. Does every cached result have a real producer?
5. Can every call be mapped field-for-field to the opposite-chain view?
6. Would the scenario still make causal sense without its final-state assertions?

### Known verifier limitation

The verification pipeline checks the expected L1 and L2 tables largely as independent
expected subsets; it does not build a causal frame graph and prove a bijection between
every call on the two chains. A self-consistent but fabricated extra transaction can
pass if the scenario itself declares it expected. Manual frame review (steps 2–3
above) remains mandatory until the verifier also checks trigger-to-entry grouping,
one L2Tx entry per L2 user tx, one delivery per completed top-level frame, no
deliveries for nested calls, and call/result multiplicity across both views.

## Gotchas

Scenario-model gotchas:

- **`msg.value` conservation** for `executeIncomingCrossChainCall` — `msg.value` mints
  the total inbound ETH the committed calls consume — a prover constraint, no on-chain
  check (an under-mint fails as a value call with insufficient balance).
- **Same-block requirement** on both chains. `run/local.sh`'s `execute_l2_same_block`
  wrapper disables automine, queues txs, and mines them together — don't roll blocks
  manually in `Execute`/`ExecuteL2`.
- **Strict ascending order** for `proofSystems` and `rollupIdsWithProofSystems` in the
  batch. The `E2EHelpers.sol` builders handle the single-prover / single-rollup case.

Solidity / toolchain gotchas:

- **No `@L1` / `@L2` in `///` docblocks.** Solidity natspec parses `@…` as a tag. Use
  `(CAP on L1, MAINNET)` phrasing in `///` blocks; `//` comments are fine.
- **Unattributed via-ir stack-too-deep.** solc can fail with `Variable ... too deep in
  the stack` naming NO contract when a `ComputeExpected` carries several big
  `abi.encode`s. The failure is order-sensitive: printing `EXPECTED_L1_STEPS` BEFORE
  `EXPECTED_L1_TABLE` is what resolves it in `staticCounterL2`. Bisect by disabling
  function bodies, and trust only the full `forge build` — a single-file
  `forge build --contracts <file>` composes a different compilation unit and can blame
  an innocent file.
- **Public getter selectors.** `Counter.counter.selector` does not compile (contract-
  type lookup can't see public-variable getters) and the instance-bound form
  (`Counter(address(0)).counter.selector`) is not `pure` for solc. Declare a small
  interface the mock implements (`ICounterView` in `test/mocks/CounterContracts.sol`)
  and use `abi.encodeCall(ICounterView.counter, ())` / `ICounterView.counter.selector`.
- **`forge fmt` mangles `override` on public variables.** A state variable declared
  `public override` makes fmt mis-indent every following contract in the file; interface
  implementations don't need the keyword — drop it.

## Verifying your scenario

```bash
L1_PORT=<port> L2_PORT=<port+1> bash script/e2e/run/local.sh script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol
```

A green two-sided run shows the expected surviving consumption events, complete matched
tables, correct rolling hashes/results, and real destination state advanced. L1→L2
top-level flows additionally expose the same call hash in both event groups; L2-triggered
zero-hash entries and reverted nested frames use the content-based linkage described
above. On failure, decode the block with `shared/decode-block.sh` and compare against
`forge script <SOL>:ComputeExpected`.
