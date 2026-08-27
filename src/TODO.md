# TODO

- [ ] Evaluate making the cross-chain proxies beacon proxies (`CrossChainProxy`, raised 2026-08-14).
      Today each proxy is a full contract CREATE2-deployed per `(originalAddress, originalRollupId)`
      with the EEZ contract baked in as an immutable — once deployed, proxy logic can never change
      without changing every proxy address (the CREATE2 derivation folds the creation code). A
      beacon pattern would let all proxies share one upgradable implementation while keeping their
      addresses stable. Trade-offs to weigh: extra delegatecall + beacon SLOAD per proxy call,
      an upgrade authority (who controls the beacon?) vs. today's immutability guarantees, and the
      effect on `computeCrossChainProxyAddress` (the derivation would fold the lighter beacon-proxy
      creation code instead).

# Gas Audit — EEZ hot paths

Scope: the recurring L1 flows — `postAndVerifyBatch`, `executeCrossChainCall` / entry execution, and proxy creation (`createCrossChainProxy` + the auto-create in `_processNCalls`) — plus the shared `CrossChainProxy` hop. Read-only audit: no code was changed.

**Methodology.** Baselines are measured, not estimated: the repo's own `test/GasCost.t.sol` / `test/GasExecPaths.t.sol` suites (steady-state, cold-storage-normalized, run 2026-08-27 on the current `feature/defensive-checks` working tree). Per-opcode reasoning uses Cancun pricing: SSTORE 0→nonzero 20,000 / rewrite 2,900, cold slot +2,100, clear refund 4,800 (capped at tx_gas/5, EIP-3529), `tstore`/`tload` 100, keccak 30 + 6/word.

## Measured baselines

| Flow (steady-state) | Gas |
|---|---|
| Immediate L2Tx executed inline in `postAndVerifyBatch` | 121,872 |
| Same entry via the meta-hook transient tables | 534,628 |
| Save 1 bare entry to a per-rollup queue (marginal) | 139,924 |
| Execute a deferred entry via proxy (tx 2 of save+exec) | 153,338 |
| Marginal cost per extra `RootUpdate` (post, steady) | 29,054 |
| Marginal cost per extra `RootUpdate` (exec side) | 15,761 |
| Marginal reentrant `ExpectedL1ToL2Call`, executed inline (net of refunds) | 34,003 |
| Handle one entry: storage save vs existing transient serializer | 482,985 vs 143,725 |

The last row is the repo's own A/B proof that the `ExpectedL1ToL2CallTransient` approach is ~3.4× cheaper than storage for the same data — the anchor for finding G-2.

---

## Findings (ranked by win ÷ effort)

### G-1. Proxy init-code hash recomputed on every call — make it an `immutable`

`computeCrossChainProxyAddress` (EEZBase) does
`keccak256(abi.encodePacked(type(CrossChainProxy).creationCode, abi.encode(address(this))))`
on **every invocation**. Creation code is 1,365 bytes, so each call pays a CODECOPY of ~43 words, a ~1.4 KB memory build, and a 44-word keccak — **~600–800 gas** — before the actual CREATE2 address hash.

It runs once per executed `L2ToL1Call` (`_processNCalls`), once per static sub-call (`_processNStaticCalls`), and on every external `computeCrossChainProxyAddress` view. The operands are fixed at deployment (`address(this)` is final inside the constructor), so:

```solidity
bytes32 internal immutable PROXY_INIT_CODE_HASH; // set once in the EEZBase constructor
```

- **Win:** ~700 gas × every sub-call in every entry, L1 and L2 (e.g. a 3-call entry saves ~2.1k; also shrinks runtime code).
- **Change:** ~10 lines in `EEZBase.sol` (add constructor + immutable, use it in `computeCrossChainProxyAddress`). No ABI, storage, or protocol change.
- **Risk:** none worth noting.

### G-2. Meta-hook tables (`_transientEntries`) do a full storage round-trip — extend the transient serializer

`postAndVerifyBatch` step 7 `push`es every meta-hook entry into the storage array `_transientEntries`, then `delete`s it in step 9 — all within one tx. Measured: the same entry costs **121,872 inline vs 534,628 via the meta hook (+412,756)**, and the refund model already loses to the EIP-3529 cap (measured raw refund 39,800 vs cap 36,797 — clipped). Net cost is ~16–20k per storage word vs ~200 per transient word.

The codebase already contains the fix pattern: `ExpectedL1ToL2CallTransient` serializes a full struct array into a namespaced EIP-1153 region (packed, length-authoritative, revert-safe), and `test_StorageVsTransient_HandleEntry` measures it at **143,725 vs 482,985** for one entry. Extend that serializer to full `ExecutionEntry` (incl. `RootUpdate` rows) and `StaticExecutionEntry`, then point the four read sites at it (`_getExpectedL1toL2Calls` branch (b), `_consumeAndExecuteEntry` transient branch, `staticCrossChainCall` pool branch, and the `PostBatchReentry` guard — the guard just reads the tstored length word instead of `.length`).

The same applies on L2 to `executeIncomingCrossChainCall` (atomic, same-tx — transient-eligible). `loadExecutionTable` must **stay** storage: its entries are consumed by *later txs* in the same block, and transient storage dies with the tx.

- **Win:** ~300–400k per meta-hook batch (shape-dependent; ~75–90% of the current 412k overhead).
- **Change:** medium-large — ~250–350 lines of new serializer (mirroring the existing one) + rewiring the read sites; extend the `test_Stale_TwoBatchesOneTx`-style stale-table tests to the new region.
- **Risk:** medium — serialization bugs are subtle; mitigated by the proven in-repo pattern and existing test shapes. Note: Solidity's `transient` keyword still doesn't cover arrays/structs (the code's own TODO), so this is the manual namespaced-region version, same as the already-accepted `ExpectedL1ToL2CallTransient`.

### G-3. `_verifiedRollupInCurrentExecutingEntry` is a storage array pushed/deleted per executed entry

Every `_executeEntry` pushes each `RootUpdate.rollupId` into a **storage** array and `delete`s it at the end — the array also backs `_insideExecution()`. Per top-level entry with 1 delta that's a length-slot + element-slot round trip: ~50,000 gross, ~9,600 refund → **~30–40k net per executed entry** (~25–33% of a bare execution's 122k), plus ~17k per extra delta (visible in the measured +15.8k per exec-side `RootUpdate`, which this dominates).

Fix: a small transient region — one count word + one id word per delta (`tstore` at `base+i`), `_insideExecution()` = count ≠ 0, `_isRollupAllowed` scans `tload`s. Clearing = store count 0 (length-authoritative, same convention as the existing serializer). Reverts roll transient writes back exactly like storage, so all revert paths keep their semantics.

- **Win:** ~30k per executed entry (every immediate L2Tx, every consumed queue entry, every meta-hook entry — it stacks with G-2).
- **Change:** ~50–70 lines (tiny region + swap 4 touch points: push loop, `delete`, `_insideExecution`, `_isRollupAllowed`).
- **Risk:** low-medium. Same `transient`-keyword caveat as G-2 (arrays unsupported → assembly region).

### G-4. Queue path copies the whole entry to memory — including the reentrant table it never reads

`_consumeAndExecuteEntry` resolves `entry = rec.entryQueue[idx]` (storage) and calls `_executeEntry(entry)` whose parameter is `memory` → Solidity copies the **entire** entry, `expectedL1ToL2Calls` included. `_executeEntry` never reads that field (nested resolution goes through `_getExpectedL1toL2Calls()`, which reads storage again). Each unused reentrant row copied = ~5 fixed slots + 4 per sub-call + `returnData` words, at 2,100/cold SLOAD → **≥10.5k wasted per row**, linear in table size, on every deferred consumption.

Fix: don't pass the full struct — load only the fields `_executeEntry` uses (`rootUpdates`, `proxyEntryHash`, `l2ToL1Calls`, `rollingHash`, `success`, `returnData`), either as separate params or a slim internal struct. The immediate-L2Tx calldata path can keep the current signature via a thin wrapper.

- **Win:** ~10–20k per deferred entry with a 1–2-row table; grows ~10k+/row.
- **Change:** ~30–50 lines, internal only (no ABI/protocol change).
- **Risk:** low.

### G-5. Reentrant-table materialization is O(N²) 

Each nested call / static read copies the **whole** `expectedL1ToL2Calls` table to memory (`_getExpectedL1toL2Calls()`), then scans. Measured marginal per reentrant call: **40,898 gross / 34,003 net** — most of it table-copy, not resolution. `src/TODO.md` already records the fix direction (scan keys in place — each row's key sits at slot+0 of its base in both the storage and transient layouts — and materialize only the matched row). With G-2 in place the transient layout makes this natural.

- **Win:** for entries with N reentrant rows, turns N table-copies into N key-scans — tens of k for N ≥ 3.
- **Change:** medium (~60–100 lines: keyed scan helpers for storage + transient layouts).
- **Risk:** medium; content-addressing semantics must stay byte-identical.

### G-6. Struct packing: `RootUpdate` wastes a slot; `ExpectedL1ToL2Call.success` wastes a slot

- `RootUpdate` = uint64 + bytes32 + bytes32 + int256 → **4 slots**, with 24 dead bytes beside `rollupId`. Narrowing `etherDelta` to `int192` (±3.1e57 wei — far beyond total ETH supply) packs it with `rollupId` → **3 slots (−25%)**. Measured steady post cost per `RootUpdate` is 29,054 → est. ~21–24k after; fresh (first-use) queue slots save a full ~22k each.
- `ExpectedL1ToL2Call.success` (bool) sits alone in a full slot — ~20k per queued row. No small-field partner exists in the struct; the only fix is an encoding trick (e.g. a bit inside `revertedOrStaticRollingHash`), which isn't worth the obscurity. **Documented as accepted.**

⚠️ **Protocol-visible:** entry structs are folded into the public input via `keccak256(abi.encode(entry))`, so changing a field type changes the prover-side encoding, the blob framework, and every off-chain tool. Cheap in Solidity (~5 lines), expensive in coordination — batch it with the next planned struct break, not alone.

### G-7. Queue wipe on every verify — checked, keep as is

Considered replacing `_markVerifiedBlockAndDeletePreviousEntries`'s `delete` with epoch-keyed queues (never delete, address fresh slots per verify). The suite's own measurement kills it: re-posting over previously-populated slots costs **204,780** vs **361,568** over zeroed slots (`test_Doc_SeedShapeMatters` — a 156,788 zero-init premium). Epoching would pay full zero-init every batch *and* forfeit clear refunds *and* bloat state. The current wipe-then-push is the right call. No change.

### G-8. `CrossChainProxy` per-hop and per-deploy costs — quantified for the standing TODO

- **Static-context probe:** every proxy hop self-calls `staticCheck()` (~800–1,000 gas: warm CALL + encode + tstore/revert). The EVM has no "am I static" introspection; avoiding it means splitting the transparent fallback into declared static/non-static entry points — a UX/protocol trade, not a leak. Accepted.
- **Double decode:** `_fallback` ABI-unwraps the returned `bytes` — inherent to the `bytes` return.
- **Deploys:** runtime is 998 bytes → CREATE2 32k + ~200k code deposit per proxy. The TODO's beacon idea would cut deploys to ~40–50k but add ~2.7k (cold beacon SLOAD + delegatecall) to *every* hop: break-even ≈ 70 calls per proxy lifetime. Proxies are per `(address, rollupId)` and hot in steady flows — the current full-contract choice is defensible; these are the numbers for that decision.

### G-9. Micro (each ≤ ~300 gas; listed so they're visibly considered, not worth churn)

- `_executeEntry` re-checks `currentRoot` after `_entryMatches` already did (queue path) — warm SLOADs, ~100–200/delta; keep, it's the gate for the immediate path.
- `rec.lastVerifiedBlock` / `rec.entryQueueIndex` written as two SSTOREs to one packed slot (~100).
- Calldata `.length` re-read per loop iteration in `postAndVerifyBatch` / validation (~3–10 each).
- `registerRollup` writes `etherBalance: 0` (0→0 SSTORE, 100) — one-time path.
- `CallResult` / `CrossChainCallExecuted` events carry full byte payloads at 8 gas/byte — an observability choice; a hash-only event mode is possible later if entry payloads grow.

---

## What the top of the list buys, together

| Flow | Today | After G-1 + G-3 + G-4 | After + G-2 |
|---|---|---|---|
| Immediate inline L2Tx | 121,872 | ~90k (−26%) | — |
| Deferred proxy execution (tx 2) | 153,338 | ~110k (−28%) | — |
| Meta-hook batch (1 entry) | 534,628 | ~500k | ~130–180k (−65–75%) |

Recommended order: **G-1** (trivial, ships alone) → **G-3** → **G-4** → **G-2** (the big one; reuse and extend the existing serializer + stale-table tests) → **G-5** (naturally follows G-2) → **G-6** only alongside the next protocol-encoding break. G-7/G-8/G-9 need no action.

All estimates should be re-measured with the existing `GasCost` / `GasExecPaths` suites after each step — they already isolate exactly these paths.

