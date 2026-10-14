# Useful testing commands

To fund the source wallet on L2 from L1, follow [network setup](README.md#3-set-up-the-network-once-per-reset).

Before launching a suite containing `bridgeL2`, run the L1→L2 bridge E2E once
and wait for it to pass. It deposits **0.00001 ETH by default** into rollup escrow
and verifies delivery to L2. Use the same `DEVNET_ENV` for this command and the
subsequent suite.

```bash
# Default deposit: 0.00001 ETH
DEVNET_ENV=chain.env bash script/e2e/run/network/staged.sh bridge:1

```

`E2E_BRIDGE_AMOUNT_WEI` changes only the L1→L2 `bridge` scenario. Each `bridgeL2`
withdrawal needs **0.00001 ETH** of escrow. Deposit enough to cover the total
number of planned withdrawals. The bridge worker also needs enough L1 ETH for
the chosen deposit plus deployment and trigger gas.

Staged, parallel, and load runs share the same funding behavior: the default
worker target is **0.001 ETH per chain**, and the floor is **0.0005 ETH**.
Use `--fund` / `FUND_ETH` and `--floor` / `FLOOR_ETH` in any of the three runners
to override them. Without an explicit floor, it follows `FUND_ETH / 2`.
Balances are checked once before the run; eligible wallets receive only the
missing amount, and wallets are not refilled during the run. Existing balances
above the target are kept. For load tests, allow enough balance for the whole
transaction count plus deployment gas on the first worker.

Parallel network runs use `parallel.sh`: one wallet per job, taken from
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

The staged, parallel-network and load runners build artifacts before their
parallel work. Other workers compile as needed through `forge script`. With
`via_ir = true`, a cold build can take several minutes; the staged runner prints
a warming-artifacts message while suppressing build output. Build once yourself
to see compiler output before launching a suite:

```bash
forge build
```

Why it goes cold: `forge script <file>:<Contract>` rewrites
`cache/solidity-files-cache.json` with only that script's dependency subset, so
after any run's parallel forge phases the next `forge build` recompiles the rest.
`staged.sh` guards against this (it keeps the warm cache from its first
build and restores it before every forge phase and on exit — back-to-back
staged runs can reuse it); the other runners do not provide that cache-restoration
guarantee. Build times depend on the machine and which artifacts are warm.

## Big parallel load mix (770 jobs)

100× the counters, 50× the nested / multi-call / multi-tx / revert families, 20× reentrant:

```bash
DEVNET_ENV=chain.env2 MAX_PARALLEL=30 bash script/e2e/run/network/parallel.sh counter:100 counterL2:100 nestedCounter:50 nestedCounterL2:50 multi-call-nested:50 multi-call-nestedL2:50 multi-call-twice:50 multi-call-twiceL2:50 counter-multi-tx:50 reentrant:20 revertCounter:50 revertCounterL2:50 revertFromOtherChain:50 revertFromOtherChainL2:50
```

Funding checks worker balances separately on each chain first. Only workers below
`FLOOR_ETH` (default 0.0005) and `FUND_ETH` (default 0.001) enter the funding plan.
The faucet needs their total missing ETH plus 0.05 ETH per nonempty funding chunk
and a 0.1 ETH gas/deployment reserve. Its existing balance reduces the source
key's top-up. Chains with no deficient workers skip faucet top-ups and MultiSend
transactions entirely. The source key defaults to Anvil #2. Use `--fund` and
`--floor` to adjust worker funding. `MAX_PARALLEL` (default 100) caps concurrency.

## Smaller variants

```bash
# Smoke test the runner + funding path
bash script/e2e/run/network/parallel.sh counter:2

# Every scenario once, in parallel
bash script/e2e/run/network/parallel.sh all

# One category, repeated
bash script/e2e/run/network/parallel.sh one_way:10 nested:5

# Fund workers straight from the source key (skip the run faucet)
bash script/e2e/run/network/parallel.sh --direct counter:10
```

## Staged runs — spam now, verify later (`staged.sh`)

`staged.sh` splits a run into phases so the local machine never holds more
than a capped number of forge processes, however many txs are in flight:
fund → **prepare** (one forge plan run per job: simulated deploys + trigger
presign + ComputeExpected, capped at `PREPARE_PARALLEL`; then all deploys fired
and mined at once) → one block snapshot → **send** (`SEND_WORKERS` curl-only
workers fire the pre-signed raw txs and record hashes) → **monitor** (batched
receipt polls per chain with a source-RPC fallback, every 3 seconds, with recovery every `MINE_TIMEOUT` seconds) →
**verify** (capped at `VERIFY_PARALLEL`, deferrable). Every artifact lives in
`tmp/e2e-staged-net/<ts>/` — per-job manifests + raw txs, `sent.csv`, `mined.csv`,
`pending.csv` (what never mined), `timings.csv` — so verification can run later,
slowly, or again.

```bash

## Network commands
bash script/e2e/run/network/staged.sh all:1
PREPARE_PARALLEL=200 bash script/e2e/run/network/staged.sh --no-verify all:5
bash script/e2e/run/network/load-testing.sh --workers 50 --txs-per-wallet 100 --window 10 counter

# Automatic selection omits scenarios carrying E2E_EXCLUDE_FROM_ALL
bash script/e2e/run/network/staged.sh all:1

# One scenario, or a few
bash script/e2e/run/network/staged.sh counter:1 revertCounter:1

# Smoke test
bash script/e2e/run/network/staged.sh counter:2

DEVNET_ENV=chain.env2 PREPARE_PARALLEL=200 VERIFY_PARALLEL=30 MINE_TIMEOUT=60 bash script/e2e/run/network/staged.sh counter:100 counterL2:100 nestedCounter:50 nestedCounterL2:50 multi-call-nested:50 multi-call-nestedL2:50 multi-call-twice:50 multi-call-twiceL2:50 counter-multi-tx:50 reentrant:20 revertCounter:50 revertCounterL2:50 revertFromOtherChain:50 revertFromOtherChainL2:50

# The 770-job load mix through the staged runner no verify
PREPARE_PARALLEL=200 bash script/e2e/run/network/staged.sh --no-verify counter:100 counterL2:100 nestedCounter:50 nestedCounterL2:50 multi-call-nested:50 multi-call-nestedL2:50 multi-call-twice:50 multi-call-twiceL2:50 counter-multi-tx:50 reentrant:20 revertCounter:50 revertCounterL2:50 revertFromOtherChain:50 revertFromOtherChainL2:50

# Selected 26-scenario mix x10 (260 jobs), excluding bridge/bridgeL2 (see Caveats)
bash script/e2e/run/network/staged.sh counter:10 counterL2:10 counter-multi-tx:10 multi-call-twice:10 multi-call-twiceL2:10 multi-call-two-diff:10 multi-call-two-diffL2:10 multi-call-nested:10 multi-call-nestedL2:10 nestedCounter:10 nestedCounterL2:10 deepNested:10 flash-loan:10 reentrant:10 revertCounter:10 revertCounterL2:10 revertFromOtherChain:10 revertFromOtherChainL2:10 revertFromOtherChainAndCallAgainL2:10 revertFromOtherChainNested:10 nestedCallRevert:10 nestedCallRevertL2:10 topLevelStaticCounter:10 staticCounterL2:10 nestedStaticCounter:10 nestedStaticCounterL2:10

# Send-only now, assess later at a gentle pace
DEVNET_ENV=chain.env2 bash script/e2e/run/network/staged.sh --no-verify counter:1000
VERIFY_PARALLEL=4 bash script/e2e/run/network/staged.sh --verify-only tmp/e2e-staged-net/<ts>

# Big runs: pace the trigger sends (rate = workers / SEND_PAUSE tx/s). A burst of
# ~280 triggers at once was accepted and then dropped by the fronts on 2026-09-03.
SEND_PAUSE=0.5 bash script/e2e/run/network/staged.sh --workers 5 counter:10 counterL2:10   # 10 tx/s

# Re-fire the triggers of a run the fronts dropped (accepted, never mined; nonces
# still free): same pre-signed raw txs, old hashes archived as *.attempt<N>
SEND_PAUSE=0.5 bash script/e2e/run/network/staged.sh --workers 5 --resend tmp/e2e-staged-net/<ts>
# LOAD testing
bash script/e2e/run/network/load-testing.sh --workers 20 --txs-per-wallet 500 counter
DEVNET_ENV=chain.env2 bash script/e2e/run/network/load-testing.sh --workers 50 --txs-per-wallet 100 --window 10 nestedCounter
bash script/e2e/run/network/load-testing.sh --txs 10000 --workers 100 --fund 1 --gas 1000000 deepNested

```

Deployment and trigger progress uses one line: `L1: mined/total | L2: mined/total`.
Receipt polling is fixed at **3 seconds**. The front is queried first for triggers;
unresolved hashes are also checked on the source-chain RPC. Deployments use direct RPCs.

Recovery runs every **60 seconds** (`MINE_TIMEOUT` / `DEPLOY_MINE_TIMEOUT`).
It reconciles all saved mined attempts before querying the pool or fee oracles:

- At the one-minute check, a transaction with no receipt and absent from both
  front/source transaction lookups is marked **DISAPPEARED**, without resending it.
  These tests appear together in a clean **DISAPPEARED TESTS** table at the end of
  the log, with the chain and full transaction hash. A front may hide held transactions;
  the label reports lookup absence. RPC failures are reported separately.
- Visible transactions with low fees allow at most **two fee increases**, retaining
  the same nonce, payload, value, gas limit and access list. The fee cap and tip
  increase by at least **10%**, rounded up, and cover current estimates. Explicit
  fee rejection refreshes estimates and retries immediately within that budget.
- Insufficient funds stop the job. The report gives the required balance and
  available balance in ETH, with the shortfall when known. No automatic top-up.
- A consumed nonce is traced to its mined transaction. Own attempts are reconciled;
  a different hash is reported as **nonce used by another transaction**. Unavailable
  historical status is reported as **RPC status error**, not assumed to be a collision.
- An uncertain read gets one status recheck. Failure is terminal and reported as
  **RPC status error**. An uncertain resend gets one receipt/transaction status
  check; there is no blind resend. Outcomes can remain unknown and may mine later.
- Reverted receipts and other definite rejections are never automatically resent.

Each deployment/trigger monitor waits at most **300 seconds**. `MAX_MONITOR_WAIT`
can shorten that limit (1–300), but cannot disable or extend it. At expiry a visible,
adequately priced transaction is marked **non-mined valid tx**; this label describes
its observed pool/fee status, not successful execution. Missing or unqueryable
transactions retain their specific failure category. RPC calls and recovery already
in progress may delay the final report beyond the nominal deadline.

```bash
# Five-minute maximum; check transaction status after one minute.
bash script/e2e/run/network/staged.sh counter:10 counterL2:10

# Shorter monitor limit.
MAX_MONITOR_WAIT=180 bash script/e2e/run/network/staged.sh counter:10 counterL2:10
```

The run continues to verify completed jobs and exits unsuccessfully if any jobs
remain unmined. `--no-verify` also fails for reverted triggers. The final recovery
report lists affected jobs, chains, hashes, reasons and retry counts, including
transactions which eventually mined after recovery.

`recovery.log` records decisions. `sent.replacements.json` and
`deploy-sent*.replacements.json` persist retry budgets and every signed attempt
before submission. Resume does not reset those budgets or terminal disappearance
results. Saved older attempts can still win; their receipts repair CSVs and per-job signed bytes. Verification-only
reconciles receipts without broadcasting. Recovery remains Bash using `curl`, `jq`,
`cast` and `bc`; its offline regression tests use Python to drive mocked RPCs.

A run is bound to the network it was prepared on: the resolved endpoints are
saved in `<run-dir>/devnet.env` and `--resume` / `--verify-only` reload them, so
`DEVNET_ENV` is only needed on the initial command.

Defaults: `PREPARE_PARALLEL=40`, `PREPARE_JOB_TIMEOUT=300` (a prepare launch past
it is killed and its job dropped, the run continues), `SEND_WORKERS=80`
(`--workers`), `VERIFY_PARALLEL=8`, fixed 3-second receipt polling,
`MAX_MONITOR_WAIT=300`, `MINE_TIMEOUT=60`,
`DEPLOY_MINE_TIMEOUT=60`; funding flags/env are the same as
`parallel.sh` (both source `orchestrator.sh`; the two chains are
funded concurrently, every `fundUpTo` chunk fired at once and mined with one
receipt pass). Multi-trigger jobs can span several posting transactions: the
network verifier unions mutable-entry matches and requires each expected index
exactly once. Generic wrapper calldata and partial static-table matching remain
unsupported; see [Verification TODO](README.md#verification-todo).

Prepare runs in **plan mode** by default: after one batched nonce barrier
(public RPC caught up with the fronts for every wallet) the orchestrator reads
every wallet's nonce and the current block once per chain, and every job gets
ONE forge run (`script/e2e/scenarios/shared/PrepareJob.s.sol`) that drives all of the
scenario's Deploy* contracts in-process against forge's own forks of both
chains, pinned at that block with the wallet nonce injected — a later Deploy
contract sees what earlier ones deployed, CREATE addresses come out as the real
chain will produce them, and nothing waits for a block. Deploy outputs travel
in-process (`output()` in `E2EHelpers.sol` prints the usual `NAME=value` line
and sets it as an env var). The SAME forge process then runs the trigger oracle
(`ExecuteNetwork*`) and `ComputeExpected` on the simulated post-deploy state —
both are pure functions of the deploy outputs — so the plan step also
pre-signs the trigger(s) (nonce = the wallet's plan-time nonce + its planned
deploy txs on that chain, checked contiguous) and writes the job's manifest
(`E2E_MANIFEST_VERSION=2`) before anything is mined. The planned deploy txs of
both chains are re-signed from the multi-chain dry-run JSON (`cast mktx`), ALL
deploy txs are fired at once by the curl workers, mined with ONE wait, and a
batched `eth_getCode` pass asserts every created address holds code; there is
no finish step. A v2 manifest alone does not make a job sendable: it must also
hold `.deploys-done` and no `.prepare-failed` marker (`_job_prepared`), so a job
whose deploys never mined is dropped, not fired. `PREPARE_MODE=waves` is the
per-Deploy-contract dry-run scheme against the real RPCs (one mine wait per
Deploy contract, then the finish step that writes a v1 manifest);
`PREPARE_MODE=classic` is per-job forge deploys.

Stopping and continuing is first-class: `--resume <run-dir>` first fires and
mines the pre-signed deploys of jobs that never reached `.deploys-done`
(continuing after any hash already recorded), re-runs the finish step only for
v1 jobs whose deploys all mined but that never got a manifest — nothing is
redeployed, a v2 manifest is trusted as written — then fires whatever is
prepared and unsent (a multi-tx job whose send stopped part-way continues from
the next raw tx); `--verify-only <run-dir>` re-syncs receipts (one batched
re-poll) and (re)runs verification. Previously passed jobs are revalidated
against current canonical inclusions; `SKIP_VERIFIED=1` no longer bypasses this. Jobs the prepare phase dropped keep a
`.prepare-failed` marker so they stay in the fail count even on a truncated run.
Verification shares a per-run settlement-calldata cache and prefilters
candidate txs by the job's own contract addresses, so hundreds of parallel
sibling settlements don't grind the calldata matcher. A multi-tx job whose
triggers mined in different blocks is settled by several batches: the calldata
matcher then accepts partial matches per settlement tx and requires the union
over the trigger blocks' settlement txs to cover the expected table exactly
once.

Staged receipt polling is fixed at 3 seconds on both chains. Adaptive polling
settings used by other runners do not change this cadence.

Every run records phase timings: `<run-dir>/timings.csv` (run phases: build,
fund, nonce-barrier, plan-inputs, plan, deploy-send, deploy-mine,
deploy-liveness, finish, send, monitor, verify, total — one attempt number per
fresh run / `--resume` / `--verify-only`) and `<run-dir>/job-timings.csv`
(per-job plan / finish / verify durations), summarised at the end with the five
slowest jobs. `E2E_TIMING_BASELINE=<timings.csv of a reference run>` reports
every phase more than `TIMING_REGRESSION_PCT` (default 20) % slower than the
baseline's last attempt.

## Settlement correlation RPC (`eez_getSettlementByL2Block` & co.)

Both Composer fronts expose settlement correlation. The runner probes
`L2_FRONT`, then `L1_FRONT`; regular node RPCs do not serve these methods.

- Every trigger is looked up by transaction hash. Its receipt must identify a
  successful transaction in the current canonical block.
- L2 triggers use `eez_getSettlementByL2Block({"blockHash": receipt.blockHash})`.
  L1 triggers use `eez_getSettledL2RangesByL1Block({"blockHash": receipt.blockHash})`.
- Posting transaction hashes select calldata candidates. Existing table,
  rolling-hash and execution-event checks remain mandatory.
- Every matched posting contributes its exact L2 blocks. Multi-trigger jobs keep
  all settlements and require complete, nonduplicated expected-entry coverage.

Missing receipt indexes are retried across direct/front RPCs. When an exact block
hint is available, `eth_getBlockReceipts(blockHash)` can recover the receipt by
transaction hash. Receipt status and canonical block hash are still checked.
Calldata may be cached by transaction hash; receipt block numbers are not cached.

For discovered L2 delivery blocks, verification reads `eth_getBlockReceipts` once
per exact block hash and selects all required transactions. Each selected receipt
must be unique, have a valid status, and match the canonical header; the usual
success and final canonical checks still apply. These receipts are reused only
within that verification pass. Unsupported, missing or invalid block receipts
fall back to the individual transaction-receipt path.

L2 discovery uses the existing Forge `VerifyL2CallsInRange` scanner: one
`eth_getLogs` range query per attempt finds the expected call hashes. Matched
settlements bound the range, and matches must belong to those settlements.
Detailed table and call checks receive matching blocks plus L2 trigger blocks,
rather than every block in the settlement. A table with no expected call events
retains exact settlement-block coverage because call hashes cannot locate it.
Without correlation, discovery retains the pre-trigger-to-current-head scan.
Bash does not prefetch events, and the Solidity verifiers are unchanged.

Header reads use RPC batches of at most 100 requests. Replies are matched by ID
and must be complete; an explicit batch rejection uses individual requests.
All correlated blocks, including empty ones, retain their canonical hash checks.

Before reporting a result, all observed block hashes are checked again, using
batched header reads.
Changed or unavailable inclusion evidence discards the pass and refreshes the
receipts and correlations. A semantic mismatch with unchanged canonical evidence
remains a failure. Verification retries never submit transactions.

`E2E_VERIFY_TIMEOUT` (default 600 seconds per job) bounds all verification passes,
RPC requests and verifier processes together. Per-step timeouts are capped by
that deadline. `-32001` (index catching up), missing results and transport failures
remain retryable; malformed responses fail. Only `-32601` selects the compatibility
content scans. `E2E_CORRELATION=off` explicitly selects those scans.

## Verify contracts from tx hashes

`script/tools/verify-from-txs.sh` traces transactions, matches contracts to local
artifacts, and verifies them on Etherscan (`-m`, mainnet only) or Blockscout.
The RPC must support `debug_traceTransaction` with `callTracer`.

For mainnet, export `MAINNET_PROVIDER` and `ETHERSCAN_API_KEY`, or load them with
`-E <env-file>` (relative to your current directory; overrides exported values).
No env file loads automatically. `-r` overrides the RPC; `-n` traces and matches
without submitting or requiring an API key. Use `-f hashes.txt` to read tx hashes
from a file.

```bash
# Mainnet / Etherscan (add -n for a dry run)
bash script/tools/verify-from-txs.sh -m -E chain.env2 <txhash>

# Devnet L1 / Blockscout (use the backend, not the frontend)
bash script/tools/verify-from-txs.sh -r https://l1-rpc.example.net -e https://l1-explorer.example.net <txhash>

# Devnet L2 / Blockscout, hashes from a file
bash script/tools/verify-from-txs.sh -r https://l2-rpc.example.net -e https://l2-explorer.example.net -f hashes.txt
```

Blockscout verification includes a fallback for genesis predeploys, whose bytecode
must already be indexed. `NO_MATCH` means no local artifact matches; retry from
the commit that deployed the contract.

## Caveats

- The explicit load mixes above omit `bridge` / `bridgeL2`; automatic `all`
  selection includes them. `bridgeL2` needs the escrow `bridge` deposits (both
  default to 0.00001 ether). Establish that balance first, or run them in order:
  `bash script/e2e/run/network/sequential.sh bridge bridgeL2`. The sequential
  runner requires a selection; invoking it without arguments only prints usage.
- Don't launch two orchestrator runs at once (`parallel.sh` OR
  `staged.sh` — they share the wallet pool): both take pool wallets from
  the same index 0 and would race nonces. Check `pgrep -af 'script/e2e/run/network/(parallel|staged)\.sh'` first (or use
  `--fresh` for the second run). `--verify-only` is exempt — it sends nothing.
- Logs land in `tmp/e2e-parallel-net/<timestamp>/<job>.log`; worker keys in
  `wallets.csv` in the same dir.
