# Useful testing commands

Parallel network runs use `network-parallel.sh`: one wallet per job, taken from
the persistent pool (`script/e2e/run/wallet-pool.csv`) and topped up to `FUND_ETH`
from the run faucet through the `MultiSend` contract (one batched `fundUpTo` tx per
chain, unspent value refunded), so job count is not limited by the devnet txpool's
per-account pending cap and leftover worker balances are reused run after run.
Workers already holding `FLOOR_ETH` (`--floor`, default `FUND_ETH / 2`) are skipped
entirely — no dust transfers — so back-to-back runs barely move value; keep the
floor above the most expensive scenario's per-chain spend.
Pass `--fresh` to mint brand-new wallets instead of reusing the pool (they are
still appended to it, so their leftovers are recovered later).

```bash
# Point at the devnet env you want (defaults to chain.env)
export DEVNET_ENV=chain.env2
```

## Build the artifacts first

Every runner starts with a `forge build`; with `via_ir = true` a **cold** build
takes ~3 minutes and the staged runner prints nothing else meanwhile (it shows
`== forge build (warming artifacts…)`), so run it yourself once to see the
compiler output and skip the wait inside the run:

```bash
forge build
```

Why it goes cold: `forge script <file>:<Contract>` rewrites
`cache/solidity-files-cache.json` with only that script's dependency subset, so
after any run's parallel forge phases the next `forge build` recompiles the rest.
`network-staged.sh` guards against this (it keeps the warm cache from its first
build and restores it before every forge phase and on exit — back-to-back
staged runs build in well under a second); `network-parallel.sh` /
`network-sequential.sh` do not, so expect a cold build after those.

## Big parallel load mix (770 jobs)

100× the counters, 50× the nested / multi-call / multi-tx / revert families, 20× reentrant:

```bash
DEVNET_ENV=chain.env2 MAX_PARALLEL=30 bash script/e2e/run/network-parallel.sh counter:100 counterL2:100 nestedCounter:50 nestedCounterL2:50 multi-call-nested:50 multi-call-nestedL2:50 multi-call-twice:50 multi-call-twiceL2:50 counter-multi-tx:50 reentrant:20 revertCounter:50 revertCounterL2:50 revertFromOtherChain:50 revertFromOtherChainL2:50
```

Funding math: worst case jobs × `FUND_ETH` (default 0.1) + ~0.05/funding-chunk gas
per chain — 770 jobs budget ~77.5 ETH on each chain from the source key (anvil #2
by default), but reused pool wallets only draw their missing top-up and the rest
refunds to the faucet. Halve the per-worker amount with `--fund 0.05` if the
source key is running low. `MAX_PARALLEL` (default 100) caps concurrency.

## Smaller variants

```bash
# Smoke test the runner + funding path
bash script/e2e/run/network-parallel.sh counter:2

# Every scenario once, in parallel
bash script/e2e/run/network-parallel.sh all

# One category, repeated
bash script/e2e/run/network-parallel.sh one_way:10 nested:5

# Fund workers straight from the source key (skip the run faucet)
bash script/e2e/run/network-parallel.sh --direct counter:10
```

## Staged runs — spam now, verify later (`network-staged.sh`)

`network-staged.sh` splits a run into phases so the local machine never holds more
than a capped number of forge processes, however many txs are in flight:
fund → **prepare** (deploy + pre-sign triggers + ComputeExpected, capped at
`PREPARE_PARALLEL`) → one block snapshot → **send** (`SEND_WORKERS` curl-only
workers fire the pre-signed raw txs and record hashes) → **monitor** (one batched
receipt poll per chain every `POLL_INTERVAL` s until mined or `MINE_TIMEOUT`) →
**verify** (capped at `VERIFY_PARALLEL`, deferrable). Every artifact lives in
`tmp/e2e-staged-net/<ts>/` — per-job manifests + raw txs, `sent.csv`, `mined.csv`,
`pending.csv` (what never mined) — so verification can run later, slowly, or again.

```bash
# Smoke test
bash script/e2e/run/network-staged.sh counter:2

# The 770-job load mix through the staged runner
DEVNET_ENV=chain.env2 PREPARE_PARALLEL=30 VERIFY_PARALLEL=30 MINE_TIMEOUT=1800 bash script/e2e/run/network-staged.sh counter:100 counterL2:100 nestedCounter:50 nestedCounterL2:50 multi-call-nested:50 multi-call-nestedL2:50 multi-call-twice:50 multi-call-twiceL2:50 counter-multi-tx:50 reentrant:20 revertCounter:50 revertCounterL2:50 revertFromOtherChain:50 revertFromOtherChainL2:50

# Every scenario x10 (260 jobs) — everything except bridge/bridgeL2 (see Caveats)
bash script/e2e/run/network-staged.sh counter:10 counterL2:10 counter-multi-tx:10 multi-call-twice:10 multi-call-twiceL2:10 multi-call-two-diff:10 multi-call-two-diffL2:10 multi-call-nested:10 multi-call-nestedL2:10 nestedCounter:10 nestedCounterL2:10 deepNested:10 flash-loan:10 reentrant:10 revertCounter:10 revertCounterL2:10 revertFromOtherChain:10 revertFromOtherChainL2:10 revertFromOtherChainAndCallAgainL2:10 revertFromOtherChainNested:10 nestedCallRevert:10 nestedCallRevertL2:10 topLevelStaticCounter:10 staticCounterL2:10 nestedStaticCounter:10 nestedStaticCounterL2:10

# Send-only now, assess later at a gentle pace
DEVNET_ENV=chain.env2 bash script/e2e/run/network-staged.sh --no-verify counter:1000
VERIFY_PARALLEL=4 bash script/e2e/run/network-staged.sh --verify-only tmp/e2e-staged-net/<ts>
```

A run is bound to the network it was prepared on: the resolved endpoints are
saved in `<run-dir>/devnet.env` and `--resume` / `--verify-only` reload them, so
`DEVNET_ENV` is only needed on the initial command.

Defaults: `PREPARE_PARALLEL=40`, `SEND_WORKERS=80` (`--workers`), `VERIFY_PARALLEL=4`,
`POLL_INTERVAL=10`, `MINE_TIMEOUT=600`; funding flags/env are the same as
`network-parallel.sh` (both source `orchestrator-lib.sh`). `counter-multi-tx` jobs
can FAIL with a "composer split the triggers across blocks" NOTE when their
triggers mine in different blocks — the known single-batch verifier limitation,
not a protocol failure.

Prepare runs in **wave mode** by default: each job's k-th Deploy contract is
dry-run and its planned txs re-signed with `cast mktx` (per-job
`FOUNDRY_BROADCAST` keeps the dry-run JSONs private), then the whole wave is
fired by the curl workers and mined ONCE before wave k+1 — so deploy mining
blocks the run a handful of times instead of once per job. A batched
`eth_getCode` pass asserts every predicted address holds code before the
read-only finish step (trigger presign + ComputeExpected). `PREPARE_MODE=classic`
restores per-job forge deploys; `DEPLOY_MINE_TIMEOUT` (default 300 s) bounds each
wave's mine wait.

Stopping and continuing is first-class: `--resume <run-dir>` first re-runs the
read-only finish step (trigger presign + ComputeExpected) for every job whose
deploys all mined but that never got a manifest — nothing is redeployed — then
fires whatever is prepared and unsent (a multi-tx job whose send stopped
part-way continues from the next raw tx); `--verify-only <run-dir>` re-syncs
receipts (one batched re-poll) and (re)runs verification — `SKIP_VERIFIED=1`
skips jobs whose verify.log already passed. Jobs the prepare phase dropped keep a
`.prepare-failed` marker so they stay in the fail count even on a truncated run. Verification shares a per-run settlement-calldata
cache and prefilters candidate txs by the job's own contract addresses, so
hundreds of parallel sibling settlements don't grind the calldata matcher.

## Settlement correlation RPC (`eez_getSettlementByL2Block` & co.)

Composer/follower L2 nodes can expose the canonical L2-block ⇄ L1-settlement
mapping. `network.sh` probes the L2 RPC once per verification
(`eez_correlation_detect` in `E2EBase.sh`) and, when the method exists:

- L2 trigger: `eez_getSettlementByL2Block(<receipt block>)` is polled until the
  block is settled, then only that L1 block is verified and only the named
  posting tx is calldata-decoded — no `[L1_BLOCK_BEFORE..latest]` scan, no
  candidate sifting.
- L1 trigger: `eez_getSettledL2RangesByL1Block(<settlement block>)` gives the
  L2 range the batch proved; the composer puts every cross-chain system tx of a
  batch in the LAST block of that range, so the L2 call scan starts at
  `lastBlockNumber` instead of at the pre-trigger snapshot (upper bound stays
  "latest").

Networks without the method (-32601 / no answer) keep today's range scans;
`E2E_CORRELATION=off` forces them. Response field names are matched by shape
(`_eez_pick`); an unrecognised shape is logged as
`eez_…: unrecognised response shape: {…}` and falls back — pin the exact keys
in `eez_settlement_by_l2_block` / `eez_l2_ranges_by_l1_block` once seen.

## Verify contracts on the devnet explorer from tx hashes

`script/e2e/run/verify-from-txs.sh` traces the given txs (callTracer), collects
every call target with code, dedupes by runtime codehash, matches each unique code
against the repo's `out/` artifacts (immutables masked; falls back to a compare that
ignores the trailing solc metadata hash), then submits the matches with
`forge verify-contract --verifier blockscout`.

```bash
# L1 (RPC 19545, Blockscout BACKEND 34556 — the browsable frontend 34557 cannot verify)
bash script/e2e/run/verify-from-txs.sh -r http://83.52.86.125:19545 -e http://83.52.86.125:34556 <txhash> [...]

# L2 (RPC 19546, backend 34560; frontend 34561), hashes from a file
bash script/e2e/run/verify-from-txs.sh -r http://83.52.86.125:19546 -e http://83.52.86.125:34560 -f hashes.txt

# Dry run: trace + identify only, no submissions
bash script/e2e/run/verify-from-txs.sh -n -r <rpc> -e <api> <txhash>
```

Contracts whose deployed bytecode no longer matches the working tree (e.g. EEZ after
local bytecode changes) are reported as NO_MATCH — verify those from the commit that
deployed them.

## Caveats

- `bridge` / `bridgeL2` are excluded from the parallel mix: `bridgeL2` needs the
  escrow `bridge` deposits (both use the same 0.001 ether), so run them
  sequentially — `bash script/e2e/run/network-sequential.sh` covers the order.
- Don't launch two orchestrator runs at once (`network-parallel.sh` OR
  `network-staged.sh` — they share the wallet pool): both take pool wallets from
  the same index 0 and would race nonces. Check `pgrep -af network-` first (or use
  `--fresh` for the second run). `--verify-only` is exempt — it sends nothing.
- Logs land in `tmp/e2e-parallel-net/<timestamp>/<job>.log`; worker keys in
  `wallets.csv` in the same dir.
