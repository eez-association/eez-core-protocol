# E2E Tests — Setup & Running

Cross-chain scenarios under `script/e2e/scenarios/<category>/<direction>/<scenario>/`.
Categories: `one_way`, `multi_call`, `multi_tx`, `nested`, `reentrant`, `revert`, `static`; directions:
`L1_to_L2`, `L2_to_L1`.

The predeployed-proxy scenarios `topLevelStaticReentrantCounter` and
`topLevelStaticReentrantCounterL2` are included in automatic `all` / default runs.
The staged runner checks composer status before classifying absent cross-chain
triggers and reports unresolved triggers at its monitor deadline. Inclusion in
`all` does not guarantee that a live deployment supports these scenarios.
The missing-proxy variants `topLevelStaticReentrantMissingProxy` and
`topLevelStaticReentrantMissingProxyL2` are expected-rejection tests in the
**staged network runner**. They pass only when `eez_getCrossChainTransaction`
on the matching source-chain front (`L1_FRONT` or `L2_FRONT`) reports the matching
hash as terminal with `SimulationFailed` and
an exact `executor: static callback source proxy ... is not deployed on chain ...;
it must exist before the read` error, and neither source nor front RPC has a
receipt. Null responses, timeouts, other errors, and mined transactions do not
pass. Evidence is saved in each job's `composer-rejection-<hash>.json` and
`expected-rejections.csv`; verification checks it again against live RPCs.
`--resend` does not resend these negative tests. Local Anvil tests still exercise
catch/create/retry recovery. These scenarios remain excluded from `all`; select
them explicitly. Other network runners retain their successful-execution checks.
See [their call trees and commands](BUILD_AND_REVIEW_E2E_TESTS.md#one-static-round-trip-in-either-direction).

This doc covers **running** the suite. For the authoritative, self-contained guide
to writing and auditing scenarios, see [BUILD_AND_REVIEW_E2E_TESTS.md](BUILD_AND_REVIEW_E2E_TESTS.md).

Two modes:

- **Local** — everything on anvil; the test itself plays sequencer and posts batches.
- **Network** — live devnet; the test only sends the user trigger tx, the composer
  posts the batch on L1 and loads the table on L2, and the runner verifies the
  on-chain result against locally computed expectations.

**Encoding rule (both modes):** frame lifetime determines grouping. A committed
top-level mutable L1→L2 call has one L1 source entry and one L2 system delivery.
L1→L2 static reads, calls that revert on L2, and calls erased by a source-frame
revert are lookups without L2 delivery. One L2 user transaction has one zero-hash
L1 L2Tx entry containing all its ordered L2→L1 calls,
even though its L2 table has one source entry per proxy consumption. Calls made while
a cross-chain frame remains open stay in that frame's nested tables/sub-arrays and
never become later system deliveries.

**NOT LIVE YET — static reads around local writes:** `staticLocalWrite`,
`staticLocalWriteL2`, `nestedStaticLocalWriteL1`, and `nestedStaticLocalWriteL2`
have passed local Anvil runs only. They are not validated for live staged or
parallel network testing. They are excluded from `all` / `all:N` discovery in
`staged.sh` and `parallel.sh`, from `sequential.sh all`,
and from the local parallel runner's default / `all` set. Each scenario carries
an `E2E_EXCLUDE_FROM_ALL` marker; remove it only when the scenario is ready.
Explicit names and category selections still include them; use explicit local
runs for development. See the [scenario descriptions](BUILD_AND_REVIEW_E2E_TESTS.md#static-read--local-write--read-with-callbacks).

Network verification uses exact composer transaction links by default, including
full L2 static-table checks. See [transaction roles and compatibility modes](RPC.md#eez_getcrosschaintransaction)
and [saved verification evidence](RUNNER_GUIDE.md#exact-transaction-links).

Classic network preparation requires the source chain's front (`L1_FRONT` or
`L2_FRONT`) and uses the greater of the node and front nonces. Failed nonce reads
retry for up to `E2E_NONCE_TIMEOUT` seconds (default 30); they never substitute
zero. The L1 catch-up loop shares a 120-second deadline across retries. The staged
plan path retains its existing batched deployment barrier.

The 22 call-pattern scenarios added in PR #54 are explicit-only pending live
validation. Their `E2E_EXCLUDE_FROM_ALL` markers exclude them from `all`, `all:N`
and default local runs; named scenarios and category selections remain available.

### Cross-chain trigger fees

Follow the [L1/L2 cross-chain quote, retry and recovery rules](RPC.md#eez_quotefee).

## Script layout

```text
script/
  e2e/
    scenarios/      one_way/, multi_call/, multi_tx/, nested/, reentrant/, revert/, static/
      shared/       Solidity deployment, verification and scenario helpers
    run/network/    setup.sh, staged.sh, sequential.sh, parallel.sh, load-testing.sh
    run/local/      parallel.sh
    lib/            shared shell helpers, composer discovery, staged recovery
    tests/          network configuration, evidence, settlement and recovery regression tests
    COMMANDS.md     short command list
    RUNNER_GUIDE.md detailed examples, funding, recovery and verification
    RPC.md          composer RPC methods, inputs and responses
  tools/            block/trace decoding and explorer verification
  DeployBridge.s.sol  shared deployment utility used beyond E2E
```

Start with `run/network/setup.sh`, then `run/network/staged.sh counter:1`.
`lib/network-scenario.sh` is the internal single-scenario worker; `sequential.sh` shares one wallet;
`parallel.sh` runs complete scenarios on separate wallets; `staged.sh` separates
preparation, sending and verification and supports resume. `load-testing.sh` measures
transaction submission/receipts without cross-chain settlement verification.
Local runners own their Anvil chains. Tools and libraries are separate from
these entry points because they have different jobs.

The old flat script paths have moved; examples below use the new paths.
Wallet pool, faucet, MultiSend cache and lock files remain in `script/e2e/run/`
so existing funding identities and locks continue to be used. Run artifacts
remain in their existing `tmp/` directories.

Run the network runner regression tests with:

```bash
(cd script/e2e/tests && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -v)
```

## Prerequisites

[Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`,
and `anvil` for local mode), Bash, and a successful `forge build`. Network runners
also use `curl`, `jq`, `bc`, `flock`, GNU `timeout`, and Python 3 for setup/regression
helpers. Network mode needs a test-only key (see step 1).

## Local mode (no setup)

```bash
bash script/e2e/run/local/parallel.sh              # default selection (omits E2E_EXCLUDE_FROM_ALL scenarios)
bash script/e2e/run/local/parallel.sh one_way      # one category
bash script/e2e/run/local/parallel.sh counter bridge
```

## Network mode

### 1. Configure endpoints and credentials

Use exported variables or an optional `chain.env` in the repo root (gitignored).
`DEVNET_ENV=<file>` explicitly selects another file. Discovery uses Bash,
`curl`, `jq`, and `bc`. Python 3 is still used by setup balance calculations and
the remaining setup regression tests. Fresh network runs call `eez_composerInfo` once on `L1_FRONT` and check
both chain RPC IDs before funding or deployment. A metadata failure, malformed
response, or chain mismatch stops the run. Other endpoints are not queried for
composer metadata.

Discovery runs once at startup of the batch/setup script and exports the resolved
values to its workers. Keep URLs and credentials in the optional env file; avoid
writing discovered addresses back to it, since they can change after a reset.
Staged runs save their resolved network in the run directory for later resume.

```bash
L1_RPC=https://l1-rpc.example.net                     # L1 read/deploy RPC
L1_FRONT=http://x.x.x.x:18999                         # L1→L2 triggers, composer metadata/status
L2_RPC=http://x.x.x.x:18688                           # L2 read/deploy RPC
L2_FRONT=http://x.x.x.x:18998                         # L2→L1 triggers and composer status
PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a  # private key to use in testing (example: anvil #2)
```

`SOURCE_PK` is also accepted when `PK` is unset. You do not need `ROLLUPS` or
`MANAGER_L2` in this file: the E2E runners discover them automatically. Existing
address entries are replaced in memory when starting a fresh run.

From the repository root, run your existing tests directly:

```bash
bash script/e2e/run/network/staged.sh counter:1
# Select another connection/key file:
DEVNET_ENV=chain.env2 bash script/e2e/run/network/staged.sh counter:1
# The sequential runner also loads chain.env and discovers addresses:
bash script/e2e/run/network/sequential.sh counter
```

Endpoints and keys remain operator configuration. Deployment addresses and chain
IDs come from the composer; stale addresses in an env file are replaced:

| Response field | Exported variable |
| --- | --- |
| `eezContracts.eezRegistryAddress` | `ROLLUPS` |
| `eezContracts.eezRollupManagerAddress` | `EEZ_ROLLUP_MANAGER` |
| `eezContracts.eezL2Address` | `MANAGER_L2` |
| `supportedNetworks.eezL1`, `eezL2` | `EXPECTED_L1_CHAIN_ID`, `EXPECTED_L2_CHAIN_ID` |
| `version` | `COMPOSER_VERSION` |

Inspect the response without signing or sending transactions:

```bash
bash script/e2e/lib/composer-info.sh --l1-front https://composer.example.net/l1
# Load endpoints/keys and discover addresses for manual commands:
source script/e2e/lib/network-config.sh
load_network_config
```

Discovery uses only `L1_FRONT`; inspect the current response for the environment
you are running against rather than relying on an earlier deployment snapshot.
The response contains no endpoint URLs, keys, or EEZ rollup IDs. Ethereum chain
IDs must not be used as EEZ rollup IDs (`L2_ROLLUP_ID` still defaults to 1).

Staged resume/verify uses the saved run network snapshot rather than rediscovering
a potentially different deployment. The single-scenario runner (`lib/network-scenario.sh`) loads `chain.env` (or
`DEVNET_ENV`) before applying CLI overrides and discovery.
Fully explicit address arguments on the single-scenario runner remain supported
for workers and historical deployments; these bypass env-file loading and discovery.
Decoder invocations discover missing addresses through an exported `L1_FRONT`,
or accept explicit `--rollups` and `--manager-l2` addresses.

Verify the manager with
`cast call $MANAGER_L2 "ROLLUP_ID()(uint256)" --rpc-url $L2_RPC`.

**Key hygiene:** prefer a fresh throwaway key (`cast wallet new`) — well-known anvil
keys may be shared with devnet actors (notably #0: composer/system), and the nonce
races show up as triggers held forever.

### 2. Fund the source wallet on L1

```bash
source script/e2e/lib/network-config.sh
load_network_config
ADDR=$(cast wallet address --private-key $PK)
ANVIL2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a  # devnet faucet
cast send $ADDR --value 10ether --private-key $ANVIL2 --rpc-url $L1_RPC
```

The source wallet funds the runners; setup below supplies its L2 balance.

### 3. Set up the network (once per reset)

Setup bridges ETH to the same wallet on L2 and waits for delivery, using
`SOURCE_PK` (fallback: `PK`). Only L1 needs funds initially.

```bash
# Top up the source wallet to 1.1 ETH on L2:
DEVNET_ENV=chain.env2 bash script/e2e/run/network/setup.sh 1.1
```

`1.1` is the target L2 balance, not the amount sent; only the missing ETH is
bridged. Without arguments, setup uses `chain.env` and a 0.1 ETH target.
No CREATE2 factory or keyless-signer funding is needed. `flash-loan` deploys and
links separate L1/L2 Bridges; L2 wrapped tokens still use CREATE2 internally.

### 4. Check the deployment is alive

Inspect recent registry activity before sending a suite. Recent events confirm
activity at that address; an empty window can also mean an idle composer and does
not by itself prove that the address is wrong or the service is down:

```bash
LATEST=$(cast block-number --rpc-url "$L1_RPC")
cast logs --rpc-url "$L1_RPC" --from-block $((LATEST-100)) --to-block $LATEST --address "$ROLLUPS" | grep -c blockNumber   # recent registry log count
```

### 5. Run — sequential set-runner

```bash
bash script/e2e/run/network/sequential.sh one_way              # category
bash script/e2e/run/network/sequential.sh counter              # single scenario
bash script/e2e/run/network/sequential.sh counter bridge       # scenarios
bash script/e2e/run/network/sequential.sh all                  # default selection (omits E2E_EXCLUDE_FROM_ALL scenarios)
DEVNET_ENV=other.env bash script/e2e/run/network/sequential.sh one_way
```

Scenarios run sequentially from `PK` (fallback: `SOURCE_PK`), which needs gas on
both chains. Each deploys fresh contracts and sends its trigger, without funding
worker wallets or a faucet. Staged/parallel `--direct` still funds worker wallets.

Progress, trigger hashes and receipt-wait updates stream to the terminal and
`tmp/e2e-network/<scenario>.log`. Receipt timeout defaults to 420 seconds;
any failure exits 1.

### 5b. Run — PARALLEL orchestrator (per-worker wallets)

Every job gets a separate wallet from the persistent wallet pool, so scenarios run
concurrently — including the same scenario N times. `--fresh` creates new wallets
and appends them to the pool:

```bash
bash script/e2e/run/network/parallel.sh counter:10            # counter 10x
bash script/e2e/run/network/parallel.sh counter:5 bridge:3    # mixed
bash script/e2e/run/network/parallel.sh all                   # each once
bash script/e2e/run/network/parallel.sh one_way:2 nested      # categories too
```

Self-funding: `faucet.txt` (in `script/e2e/run/`, gitignored) is the orchestrator's faucet —
created on first run and topped up from `SOURCE_PK` (default Anvil #2) when short.
Workers below `FLOOR_ETH` (default 0.0015 ETH) are topped up to `FUND_ETH`
(default 0.003 ETH) per chain via MultiSend. A `flock` serializes funding; it does
not reserve pool wallets for the duration of concurrent runs.

Flags: `--direct` funds workers straight from the source key (anvil #2, or
`SOURCE_PK`) with no faucet account; `--fund <eth>` sets the per-worker amount:

```bash
bash script/e2e/run/network/parallel.sh --direct --fund 0.05 counter:10
```

Env knobs: `MAX_PARALLEL` (default 100), `FUND_ETH`, `FLOOR_ETH`, `SOURCE_PK`,
`RECEIPT_TIMEOUT`, `DEVNET_ENV`. Logs + worker keys:
`tmp/e2e-parallel-net/<timestamp>/`.

Caveats:

- **Memory is the ceiling** — ~20 concurrent jobs on a 32 GB machine; stacking runs
  can OOM-kill runners (logs cut off with no error text).
- **Sibling batches:** repeated scenarios can have identical call hashes. With
  Composer correlation, the runner restricts calldata candidates to the returned
  posting transactions. Without correlation it uses range-scan candidates and
  may rescan for eventless settlement discovery. `L1_CALLDATA_TIMEOUT` defaults
  to 180 s for L2 triggers and 60 s for L1 triggers, capped by the overall
  verification deadline.

### Run one scenario

Use the same batch entry points with one selected case:

```bash
bash script/e2e/run/network/staged.sh counter:1
MAX_PARALLEL=1 bash script/e2e/run/local/parallel.sh counter
```

The runners call their internal workers in `lib/`; no separate public single-case
command is needed. See [COMMANDS.md](COMMANDS.md) for more run examples.

Timeouts (env, seconds): `RECEIPT_TIMEOUT` 300 (the set-runners raise it to 420)
covers sending/initial mining. `E2E_VERIFY_TIMEOUT` 600 is one deadline per job for
receipt refresh, settlement discovery, semantic verification and reorg retries.
`L1_SETTLE_TIMEOUT` 120, `L1_CALLDATA_TIMEOUT` (60 for L1 triggers, 180 for L2),
`L2_SETTLE_TIMEOUT` 180 and `VERIFY_NETWORK_TIMEOUT` 60 cap their individual steps
within that deadline. Without correlation, `L2_ABSENT_GRACE` 60 retains the wait
before checking that an expected-absent delivery left no evidence.

## Operational notes

The runner already handles endpoint routing, fresh nonces, RPC-lag retries, and
bounded waits. Still your job:

1. **Heartbeat first** (step 4) — held-forever triggers with zero errors usually
   mean composer trouble, not a test bug.
2. **Fronts hold, they don't relay** — non-cross-chain txs sent to a front are
   silently dropped; a held trigger has no receipt until bundled.
3. **Load-balanced L1 RPCs lag their own writes** — for manual cast/forge, wait for
   consolidation; fronts double as fresh read nodes.
4. **Devnets may pin an older protocol commit** — this branch's `Verify.s.sol`
   only decodes the current ABI (no legacy-layout support); the devnet must run
   contracts with matching struct layouts and hash formulas.

## How L1 and L2 runs are correlated

The runner refreshes trigger receipts by transaction hash and asks the Composer
front for correlations using each receipt's **block hash**. The response supplies
posting transaction hashes and exact L2 blocks; every trigger and matched
settlement is retained, including jobs split across batches.

Correlation identifies candidates. Independent content checks still establish
correctness: call identities, posted tables, rolling-hash replay with posted
roots, return bytes and execution-event assertions. Eventless entries still
require posted-calldata comparison.

Receipt lookups try direct and front RPCs and can recover a missing transaction
index through receipts for an exact known block. The runner retains block hashes,
refreshes inclusion metadata, and rechecks the observed canonical blocks before
reporting either success or a semantic failure. A changed inclusion restarts
verification under the original deadline. A stable semantic mismatch fails.

When the fronts do not support correlation (`-32601`), or
`E2E_CORRELATION=off`, pre-trigger snapshots bound the existing content scans.
Index catch-up and transport failures do not silently disable correlation.
See the [RPC reference](RPC.md) and
[detailed verification flow](RUNNER_GUIDE.md#settlement-correlation-rpc-eez_getsettlementbyl2block--co).

## What a network run verifies

Known limits and deferred work are listed under [Verification TODO](#verification-todo). In particular,
completion matching across a block does not yet bind an identical execution to
one specific posting occurrence. The runners use the existing Solidity tooling;
there is no Python settlement collector.

- **L1 settlement**: each expected committing entry needs a distinct
  `EntryExecuted` with its actual posted rolling hash. Proxy entries also need
  `ExecutionConsumed` with the expected call hash and destination rollup. A total
  completion count cannot replace these checks. Network discovery first scans call
  hashes; completion matching happens after decoding the real posted roots.
- **L1 posted batch** (when the scenario prints `EXPECTED_L1_TABLE`): the
  `postAndVerifyBatch` calldata is decoded and every
  expected entry is field-matched against a posted twin (calls, reentrant frames,
  returnData and success flags; state updates compare rollupId + etherDelta exactly).
  Update-chain contiguity is required when the batch contains only matched entries;
  interleaved foreign entries make a discontinuity a NOTE. No-op root rejection is
  not a universal verifier check. Entry structure and immediate-prefix checks also
  run. The network runner fails if the required settlement transaction
  cannot be identified. Local runs perform this comparison for all expected L1
  tables, including entries that have completion events.
- **Rolling-hash replay**: all 36 scenarios that print `EXPECTED_L1_TABLE` also
  export `EXPECTED_L1_STEPS` via `_printL1Steps`. Each matched posted entry's
  rolling hash must be reproduced from scenario-defined call identities, outcomes,
  return bytes and nesting boundaries, starting from the seed rebuilt from the
  POSTED state roots. Seed-only entries export empty step sequences. Ordinary
  reverts erase inner folds; deliberate rollback spans preserve their folds while
  undoing state. The verifier retains a content-only fallback (with a NOTE) for
  callers omitting steps; none of the current L1-table scenarios use it.
- **Live roots**: the verifier checks the registry against posted update chains.
  It can follow later updates within the decoded batch; advancement by separate
  later posts in the same block remains a limitation listed below.
- **L2 table**: every expected entry needs a distinct, byte-identical loaded twin
  (subset match — extra entries from other actors are ignored), plus structural
  invariants. Successful entries also need distinct completion evidence matching
  the rolling hash and direct call count, with the reported nested cursor bounded
  by the expected table length. Explicit `EVENTLESS_L2_HASHES` exemptions cover
  entries whose enclosing frame rolls back; they do not prove that the attempt occurred.
- **L2 calls**: `IncomingCrossChainCallExecuted` fields must re-hash to the emitted
  call hash and match the expected inbound call.

The verifier accepts `postAndVerifyBatch` calls to `ROLLUPS` or a batcher whose
`eez()` returns `ROLLUPS` at the settlement block. Optional `EEZ_POST_BATCHER`
restricts the batcher address without bypassing that check. Missing calldata
matches fail verification; `postBatch(batch,bool)` is unsupported.

It reads completion logs from the pinned settlement block: the protocol
requires deferred consumption in the posting block. Each scenario's expected
`success=true` entries are expected to commit; a queued but unused or skipped entry
does not satisfy this check. Reverting entries and static reads retain their input
checks but have no required completion event. L1's final nested cursor is no longer
emitted or checked directly; nested table contents and rolling hashes still are.
The regression tests in `test/E2EEventVerification.t.sol` exercise missing,
unrelated, duplicate and malformed completion evidence, both event layouts,
single-use L2 table matching, and decoder summaries.

## Verification TODO

The current runners use the existing Solidity verifier and current event ABI.
The proposed Python settlement collector was removed. Passing the current local
scenarios does not establish coverage of the deferred cases below.

- [ ] Associate L1 completions with the exact posting occurrence and queue generation.
  Current checks match distinct completion hashes across the settlement block.
  A completion from an earlier identical post can satisfy a later post's input
  check even if the later entry was unused. Add a negative test with two identical
  posts, only the first consumed, plus same-block queue replacement and disjoint queues.
- [ ] Support generic wrapper calldata and multiple posts inside one transaction.
  The current network runner accepts the `postAndVerifyBatch` selector on EEZ or
  an `eez()`-bound batcher, and already unions mutable-entry matches across
  multiple posting transactions for qualifying multi-trigger jobs. The local
  runner still expects one candidate to contain the full table. Static tables
  are checked in full per candidate, so partial static coverage is not supported.
  Cover arbitrary wrapper selectors, multiple internal posts and reverted wrapper
  frames before claiming general posting support.
- [ ] Handle final-root checks when later posts in the same block advance a rollup.
  A candidate batch containing only the scenario's entries does not imply that it
  is the block's only batch. Preserve checks of the expected entry's own updates.
- [x] Export expected L1 hash-replay steps for every scenario supplying an L1 table:
  **36 covered, 0 missing**. The scenario sources include seed-only, ordinary-revert
  and deliberate-rollback steps. Runner regression coverage checks that nonempty
  step blobs reach the verifier in both trigger directions. This source coverage
  does not establish the status of a currently running devnet deployment.
- [ ] Assert exact observed revert bytes and persisted caller evidence for eventless
  network scenarios. A table with `success=false` and no delivery logs does not
  establish that the intended attempt happened. A generic `lastCallFailed` flag
  also accepts an unexpected lookup failure. Add negative tests for the wrong
  revert reason and for an unused posted reverting entry.
- [ ] Extend occurrence attribution to L2 table replacements. Exact loaded entries
  and completion logs now have single-use matching, but matching across a queried
  block set is not a complete reconstruction of each table-load generation.

Backward compatibility with older event ABIs is outside the current scope.

## Load test one deployment

Use [`load-testing.sh`](run/network/load-testing.sh) to deploy a scenario once and send thousands of transactions through the same contract setup:

```bash
bash script/e2e/run/network/load-testing.sh --workers 20 --txs-per-wallet 500 counter
bash script/e2e/run/network/load-testing.sh --workers 50 --txs-per-wallet 100 nestedCounter
```

Funding matches the staged and parallel runners: wallets below **0.0015 ETH**
are topped up to **0.003 ETH** on each chain before the run. Override with
`--fund` / `FUND_ETH` and `--floor` / `FLOOR_ETH`; the floor defaults to half the
target. Size the balance for the whole load run, including deployment gas on
the first worker.

Reports trigger receipts and throughput; full settlement verification stays in the e2e runners.
