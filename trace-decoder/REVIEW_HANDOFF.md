# Trace decoder — review handoff

Date: 2026-10-18 · Branch: `feature/trace_decoder` (findings include uncommitted working-tree changes)

Scope: everything under `trace-decoder/` — `src/` (config, rpc, engine, transaction-links,
logical, protocol, abi-decoder, explorer), `flow/` (model, render-flow, viewer), `decode-trace.mjs`,
`show-tx.sh`, README.

Baseline checks:

- `npm test`: 175/175 pass.
- `src/protocol-abi.json` matches `forge inspect EEZ abi` / `EEZL2 abi` exactly (no diffs).
- Viewer escaping: explorer-sourced names/ABIs always go through `esc()`; no XSS found.
- Proxy dispatch assumptions in `logical.mjs` (`executeOnBehalf` → plain `CALL` to target, manager
  `STATICCALL`s the proxy for reads) match `src/base/CrossChainProxy.sol`.

## Applied review changes (2026-10-18)

The findings below are the original review; their line numbers describe the pre-fix tree.
The changes remain uncommitted.

- Restored **Linked flow** as the default for exact links, with confirmed cross-chain
  arrows and a **Recorded traces** toggle. Recorded numbering and sequence rows are
  independent per chain. Read visibility respects the user's explicit choice.
- Kept proxy identity/forwarding failures and contradictory remote returns unresolved.
  Optional notes display escaped codes and messages. Shared prepared-result helpers
  reject contradictory legacy candidates; remote metadata no longer borrows local errors.
- Recognize wrapped postings with immediate L2Tx callbacks while retaining source-call
  checks in meta hooks and wrapper siblings. Decoded setup/administration/views can
  fall back on null source records; unknown manager calldata stays unresolved.
- Applied manager pinning from env, empty-export fallback, correlation-only endpoint
  handling, and direction-specific settlement lookups using real receipt block hashes.
  Both current run fronts were checked live: both answer both settlement methods.
- Fresh complete JSON no longer loses to old match counts. Missing-trace reuse is
  limited to the same schema and transaction set, and the printed summary matches
  the rendered capture. `show-tx.sh` now honors explicit `--views`.
- Updated README and tests. `npm --prefix trace-decoder test`: **206 passed**;
  strengthened card-height regression also passed. `git diff --check` passed.
- Re-decoded **35 triggers across 33 passed tests** from run `20261018-193115`.
  Receipt inclusion and transaction sets match the runner's saved evidence.
  The same [index](../tmp/decoder-live-20261018-193115/index.html) is rebuilt.
  Browser validation passed both modes for all 35 triggers: 52 visible linked arrows,
  no overlapping boxes or browser errors, working index links and filter.
  Four tests retain nine explicit uncertain call associations. The unsubmitted
  `revertFromOtherChainAndCallAgainL2-1` job remains listed without a flow.

Deferred cleanup: legacy CLI helper removal (tested exports remain), unreachable
columns branches, and concurrency-helper deduplication. These need a separate
compatibility cleanup rather than being bundled with behavioral fixes. Extended
precompile naming is also deferred until labels can respect the configured chain's
fork activation; no unconditional new address labels were introduced.

---

## Follow-up review applied

- Cross-chain reads now remain visible in both diagram modes; **Local reads**
  controls only additional local reads. Crossing evidence remains available by
  selecting the remote call card with plumbing off.
- Pinned manager/Composer differences emit a warning without replacing the pin.
  Settlement transport failures retry the next endpoint using the same receipt
  block hash; malformed replies stop, and exhausted transport failures never
  authorize a broad timestamp scan.
- System transfer cards say **Value to L2 system**. Model script inlining accepts
  single/double quotes and LF/CRLF, and rejects unbundled imports explicitly.
- The text CLI now defaults to linked flow; `--recorded` selects physical traces.
- Saved-capture reuse also checks canonical inclusion and configuration, and
  rejects failed validation or contradictory return evidence in either capture.
- **231 tests passed**. The existing 33-page / 35-trigger index was rebuilt from
  saved traces. Browser checks passed both modes with 58 visible linked arrows,
  no overlaps/errors, and explicit default-visibility checks for all three
  static-counter scenarios. Existing staged content was preserved; these
  follow-up changes are in the working tree.

---

## Original review

---

## 1. Lost UX: linked L1/L2 flow (top priority)

**Before (committed `b6933be`)**: `flow/model.mjs` built one *combined* logical tree. A matched
cross-chain call had its remote execution grafted inline under the proxy call, so an
L1 → L2 → L1 flow read as a single tree. EEZ plumbing (manager, proxies, table loads,
deliveries) stayed folded until **EEZ plumbing** was ticked.

**Now (uncommitted)**: `buildFlowModel` has `mode: 'physical'`, enabled whenever
`transactionLinks` is `complete` for the origin — which is the normal case on the devnet.
In that mode:

- `visitPhysical` never grafts the remote subtree (`// Metadata only; never graft a guessed remote subtree`).
  The proxy box only shows "X proxy" and a *prepared response / prepared result* badge.
- The viewer defaults to **Both chains · linked execution** (`BOTH_CHAINS`): each transaction is a
  separate tree in its own order, no arrows between chains ("not a shared timeline").
- Read calls are shown by default (`opt.staticCalls = M.mode === 'physical'` in `viewer.js` `load()`).
- Matching problems move from "unresolved" to "matching notes".

The combined view still exists but only runs on the fallback (non-linked) discovery path,
so in practice it is no longer seen.

**Recommendation**: in physical mode, inline the remote subtree when a crossing is
`status === 'matched'` (matching already requires a unique occurrence), and keep separate trees
only for ambiguous/unmatched crossings. Alternative: a "Linked flow / Recorded traces" toggle,
defaulting to linked. Update `tests/flow-model.test.mjs` / `tests/flow-viewer.test.mjs` accordingly
(the test "physical entry rendering preserves every frame and its order without call associations"
encodes the current behaviour).

---

## 2. Bugs

### 2.1 Non-source EEZ transactions stuck as "links pending"
`src/transaction-links.mjs:159-183`. Any trace that touches the manager queries
`eez_getCrossChainTransaction`. A `null` record falls back only for `loadExecutionTable`,
`executeIncomingCrossChainCall` or a committed batch post; everything else normalizes to
`pending`. Affected: L1 `executeL2Txs`, `createCrossChainProxy` (proxy setup), `registerRollup`,
`setRoot` via a rollup manager, and apps that only `STATICCALL` views such as
`authorizedProxies` / `computeCrossChainProxyAddress`. These never get a source record, so the
decoder reports `transaction-links-pending` forever and `show-tx.sh` refuses without
`--allow-partial`.
**Fix**: on `null`, fall back (auto mode) when the trace has no outgoing
`executeCrossChainCall` / `staticCrossChainCall`.

### 2.2 `EEZ_CORR_RPC` cannot substitute the source frontend in both directions
`src/transaction-links.mjs:162-167`. With `L1_FRONT`/`L2_FRONT` unset it uses `correlationRpc`,
then requires its chain ID to equal the *source* chain. One URL serves one chain, so the other
direction throws "wrong chain ID" → `invalid-transaction-links` (hard failure, no fallback).
README step 1 says it "can substitute".

### 2.3 Correlation probe requires both methods on one endpoint
`src/engine.mjs:147-153` accepts a candidate only if it answers **both**
`eez_getSettlementByL2Block` and `eez_getSettledL2RangesByL1Block`. `script/e2e/RPC.md:12-13`
documents them on different fronts (L2 / L1); the E2E helper (`network-evidence.sh:261`) probes
only one. If the fronts are really split, no candidate qualifies and the decoder silently drops to
the ±2,000-block timestamp scan. Also the probe sends `'0x1'` while real lookups send
`{ blockHash }`, so the probe does not test the form actually used.

### 2.4 Env-configured managers do not pin
`src/engine.mjs:54`: `ROLLUPS` / `MANAGER_L2` from env or env file are replaced by composer
discovery; only CLI `--l1-manager` / `--l2-manager` set `explicitManagers`
(`src/config.mjs:78`). README says these variables "pin historical manager addresses". After a
redeploy, old transactions decode against the new manager. `EEZ_ROLLUP_MANAGER` is parsed
(`src/config.mjs:10`) but never used.

### 2.5 Saved JSON can shadow newer runs forever
`flow/render-flow.mjs:152-162` keeps the previous `<hash>.json` when it has more traced txs **or**
more matched crossings. A JSON from an older decoder that matched more (possibly incorrectly)
wins over every later correct run. The terminal summary is printed from the new run while the
page is drawn from the old one, so they can disagree. Consider also keying on schema/decoder
version, or only preferring the old file when the new run has untraced transactions.

### 2.6 Exported empty variable drops the file value
`src/config.mjs:76`: `env[key] ?? file[key]` keeps `""` from an exported empty variable
(e.g. `L1_TRACE_RPC=`), which is falsy, so the setting is dropped entirely instead of using the
env-file value.

---

## 3. Inconsistencies / dead code

| # | Where | Issue |
| --- | --- | --- |
| 3.1 | `decode-trace.mjs` | ~1,000 lines of legacy helpers exported only for `decode-trace.test.mjs`, including hard-coded Anvil `L2_CONTEXT` (line 412) and placeholder explorer URLs. `main()` already uses the new engine, so README's "the older text/JSON CLI is unchanged" is misleading. |
| 3.2 | `flow/viewer/viewer.js:1095`, `orient === 'columns'` branches, caption at 997 | Remnants of a `'columns'` view that is not in `ALL_VIEWS`; unreachable. |
| 3.3 | `src/logical.mjs:264`, `src/logical.mjs:355` (`renderTrace`), `flow/model.mjs:38` | "Prepared result" rule duplicated three times with slight differences (only the model requires non-empty `entryCandidates`). Extract one helper. |
| 3.4 | `show-tx.sh` | Appends `--views flow,sequence` after `"$@"`, silently overriding a user `--views`. |
| 3.5 | `src/engine.mjs:161,167` | `correlationAnswered = true` set twice. |
| 3.6 | `src/engine.mjs` `concurrent` vs `src/rpc.mjs` `mapConcurrent` | Duplicate helpers. |
| 3.7 | `flow/model.mjs:22,65` | Precompile labels stop at `0x0a`; Prague BLS precompiles `0x0b`–`0x11` show as "Unknown contract". |

---

## Suggested order

1. Restore the linked flow for matched crossings (§1).
2. Fallback for non-source manager transactions (§2.1).
3. Manager pinning from env + remove/implement `EEZ_ROLLUP_MANAGER` (§2.4).
4. Frontend/correlation endpoint handling (§2.2, §2.3) — confirm the real front layout first.
5. JSON shadowing and empty-env handling (§2.5, §2.6).
6. Cleanups in §3; update README to match.
