# E2E Tests — Setup & Running

Cross-chain scenarios under `script/e2e/<category>/<direction>/<scenario>/`.
Categories: `one_way`, `multi_call`, `multi_tx`, `nested`, `reentrant`, `revert`; directions:
`L1_to_L2`, `L2_to_L1`.

This doc covers **running** the suite. For the authoritative, self-contained guide
to writing and auditing scenarios, see [BUILD_AND_REVIEW_E2E_TESTS.md](BUILD_AND_REVIEW_E2E_TESTS.md).

Two modes:

- **Local** — everything on anvil; the test itself plays sequencer and posts batches.
- **Network** — live devnet; the test only sends the user trigger tx, the composer
  posts the batch on L1 and loads the table on L2, and the runner verifies the
  on-chain result against locally computed expectations.

**Encoding rule (both modes):** frame lifetime determines grouping. A completed
top-level L1→L2 call has one L1 source entry and one L2 system delivery. One L2 user
transaction has one zero-hash L1 L2Tx entry containing all its ordered L2→L1 calls,
even though its L2 table has one source entry per proxy consumption. Calls made while
a cross-chain frame remains open stay in that frame's nested tables/sub-arrays and
never become later system deliveries.

**NOT LIVE YET — static reads around local writes:** `staticLocalWrite`,
`staticLocalWriteL2`, `nestedStaticLocalWriteL1`, and `nestedStaticLocalWriteL2`
have passed local Anvil runs only. They are not validated for live staged or
parallel network testing. They are excluded from `all` / `all:N` discovery in
`network-staged.sh` and `network-parallel.sh`, from `network-sequential.sh all`,
and from the local parallel runner's default / `all` set. Each scenario carries
an `E2E_EXCLUDE_FROM_ALL` marker; remove it only when the scenario is ready.
Explicit names and category selections still include them; use explicit local
runs for development. See the [scenario descriptions](BUILD_AND_REVIEW_E2E_TESTS.md#static-read--local-write--read-with-callbacks).

## Prerequisites

[Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`),
bash, `forge build` clean. Network mode also needs a test-only key (see step 1).

## Local mode (no setup)

```bash
bash script/e2e/run/local-parallel.sh              # everything
bash script/e2e/run/local-parallel.sh one_way      # one category
bash script/e2e/run/local-parallel.sh counter bridge
```

## Network mode

### 1. Create `chain.env` in the repo root (gitignored — holds your key)

```bash
L1_RPC=https://l1-rpc.example.net                     # L1 read/deploy RPC
L1_FRONT=http://x.x.x.x:18999                         # L1→L2 trigger txs ONLY
L2_RPC=http://x.x.x.x:18688                           # L2 read/deploy RPC
L2_FRONT=http://x.x.x.x:18998                         # L2→L1 trigger txs ONLY
ROLLUPS=0x...                                         # EEZ — L1 rollup registry
MANAGER_L2=0x4200000000000000000000000000000000000007 # EEZL2 genesis predeploy
PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a  # private key to use in testing (example: anvil #2)
```

Endpoints/addresses come from the devnet operator. Verify the manager with
`cast call $MANAGER_L2 "ROLLUP_ID()(uint256)" --rpc-url $L2_RPC`.

**Key hygiene:** prefer a fresh throwaway key (`cast wallet new`) — well-known anvil
keys may be shared with devnet actors (notably #0: composer/system), and the nonce
races show up as triggers held forever.

### 2. Fund the wallet (every devnet reset — genesis leaves it at 0)

```bash
source chain.env
ADDR=$(cast wallet address --private-key $PK)
ANVIL2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a  # devnet faucet
cast send $ADDR --value 10ether --private-key $ANVIL2 --rpc-url $L1_RPC
cast send $ADDR --value 10ether --private-key $ANVIL2 --rpc-url $L2_RPC
```

(Only needed for the sequential runner — the parallel orchestrator funds itself.)

### 3. Prepare the network (once per reset; idempotent)

```bash
source chain.env
bash script/e2e/run/prepare-network.sh --l1-rpc "$L1_RPC" --l1-front "$L1_FRONT" --l2-rpc "$L2_RPC" --pk "$PK" --rollups "$ROLLUPS"
```

### 4. Check the deployment is alive

The active registry settles batches every few L1 blocks — a heartbeat. Zero logs =
wrong `ROLLUPS` or dead composer (a stale deployment answers reads plausibly, but
triggers hang forever):

```bash
LATEST=$(cast block-number --rpc-url "$L1_RPC")
cast logs --rpc-url "$L1_RPC" --from-block $((LATEST-100)) --to-block $LATEST --address "$ROLLUPS" | grep -c blockNumber   # >0 → active
```

### 5. Run — sequential set-runner

```bash
bash script/e2e/run/network-sequential.sh one_way              # category
bash script/e2e/run/network-sequential.sh counter bridge       # scenarios
bash script/e2e/run/network-sequential.sh all                  # everything
DEVNET_ENV=other.env bash script/e2e/run/network-sequential.sh one_way
```

Sequential because all scenarios share the `chain.env` nonce. Logs:
`tmp/e2e-network/<scenario>.log`; exits 1 on any failure.

### 5b. Run — PARALLEL orchestrator (per-worker wallets)

Every job gets its own ephemeral wallet, so scenarios run concurrently — including
the same scenario N times (load testing):

```bash
bash script/e2e/run/network-parallel.sh counter:10            # counter 10x
bash script/e2e/run/network-parallel.sh counter:5 bridge:3    # mixed
bash script/e2e/run/network-parallel.sh all                   # each once
bash script/e2e/run/network-parallel.sh one_way:2 nested      # categories too
```

Self-funding: `faucet.txt` (in `script/e2e/run/`, gitignored) is the orchestrator's faucet —
created on first run, topped up from anvil #2 when short; workers get `FUND_ETH`
(default 0.1) per chain via async nonce-sequenced txs; a `flock` serializes
concurrent instances.

Flags: `--direct` funds workers straight from the source key (anvil #2, or
`SOURCE_PK`) with no faucet account; `--fund <eth>` sets the per-worker amount:

```bash
bash script/e2e/run/network-parallel.sh --direct --fund 0.05 counter:10
```

Env knobs: `MAX_PARALLEL` (default 100), `FUND_ETH`, `SOURCE_PK`,
`RECEIPT_TIMEOUT`, `DEVNET_ENV`. Logs + worker keys:
`tmp/e2e-parallel-net/<timestamp>/`.

Caveats:

- **Memory is the ceiling** — ~20 concurrent jobs on a 32 GB machine; stacking runs
  can OOM-kill runners (logs cut off with no error text).
- **Sibling batches** (L2-starting scenarios): a parallel job of the same scenario
  can settle an event-identical entry first. The runner tries every candidate
  settlement tx the range scan emitted (`L1_BATCH_TX_CANDIDATE`) and re-scans until
  `L1_CALLDATA_TIMEOUT` (default 180 s for L2 triggers; 60 s for L1 triggers, whose
  candidate set is known up front) before failing the posted-calldata check.

### Manual single scenario

```bash
source chain.env
bash script/e2e/run/network.sh script/e2e/one_way/L1_to_L2/counter/E2ECounter.s.sol \
  --l1-rpc $L1_RPC --l1-front $L1_FRONT --l2-rpc $L2_RPC --l2-front $L2_FRONT \
  --pk $PK --rollups $ROLLUPS --manager-l2 $MANAGER_L2
```

Timeouts (env, seconds): `RECEIPT_TIMEOUT` 300 (the set-runners raise it to 420).
Verification fails fast where the protocol allows it: an L1 trigger's batch can only be
in the trigger's own block (entries are consumable while `lastVerifiedBlock ==
block.number`), so its block is retried for `L1_VERIFY_TIMEOUT` 30 and a range scan
to the head for `L1_LATE_SETTLE_TIMEOUT` 30 only absorb RPC lag; an L2 trigger's
settlement is genuinely asynchronous — `L1_SETTLE_TIMEOUT` 120. The L1→L2 delivery
block is known from the settlement (correlation RPC): once the L2 head is past it the
scan decides within `L2_KNOWN_BLOCK_TIMEOUT` 15; without correlation
`L2_SETTLE_TIMEOUT` 180 bounds the scan.

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

Batches carry no L2 block references on-chain, so the runner never links the two
chains by block number. The link is **content**, in three layers:

1. **Call identity** — both chains compute the identical `crossChainCallHash`
   preimage (`isStatic, source, sourceRollup, target, targetRollup, value,
   callGas, data`), emitted indexed in L1's `ExecutionConsumed` and L2's
   `CrossChainCallExecuted` / `IncomingCrossChainCallExecuted`.
2. **Entry identity** — `keccak256(proxyEntryHash, rollingHash)`. The rolling hash
   folds every call result (`returnData` included) and every nesting boundary, so
   the source side's cached returns are cryptographically bound to the destination
   side's actual execution — any divergence changes the hash and fails the run.
   On L1 this identity is only computable where the seed's roots are known
   (L2 tables, local mode); a live devnet settles real roots, so zero-hash L1
   entries are instead pinned by posted-calldata **content** with roots neutralized
   (the chain itself already verified the posted rolling hash against execution).
3. **Time windows** — block-number snapshots taken right before publishing the
   trigger bound every scan range (call hashes are not unique across runs — an
   earlier run of the same scenario emits identical ones), and deadlines
   (`L1_SETTLE_TIMEOUT`, `L2_SETTLE_TIMEOUT`, `L1_VERIFY_TIMEOUT`, `L1_LATE_SETTLE_TIMEOUT`,
   `L2_KNOWN_BLOCK_TIMEOUT`, see "Manual single scenario") bound the wait.

Concretely: the settlement block is discovered by scanning `[snapshot..latest]` —
by expected call hashes on L1 proxy-consumed entries (`VerifyL1BatchInRange`), by
listing persistent `BatchPosted` txs + calldata content-match for L1 zero-hash or
eventless reverted entries (`VerifyL1SettlementTxsInRange`), by call hashes on L2
(`VerifyL2CallsInRange`) —
and the receipt block of the trigger tx is
only ever a *candidate* — the composer may bundle the actual consumption in a
later block on either chain.

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
  returnData, success flags; state updates: rollupId + etherDelta exact; the matched
  entries' per-rollup update chain must be contiguous and move the root), plus the
  structural invariants the contract itself enforces (proxy protection, immediate
  prefix rules). The network runner fails if the required settlement transaction
  cannot be identified. Local runs perform this comparison for all expected L1
  tables, including entries that have completion events.
- **Rolling-hash replay** (when the scenario prints `EXPECTED_L1_STEPS` via
  `_printL1Steps`): each posted entry's rolling hash must be reproduced by replaying
  the scenario's recorded fold steps over the seed rebuilt from the POSTED state
  roots — exact per-call verification (return data included) without predicting
  roots. Without steps the comparison is content-only (a NOTE says so).
- **Live roots**: the registry root must have settled to (or beyond) each
  touched rollup's posted update.
- **L2 table**: every expected entry must have a byte-identical loaded twin
  (subset match — extra entries from other actors are ignored), plus structural
  invariants.
- **L2 calls**: `IncomingCrossChainCallExecuted` fields must re-hash to the emitted
  call hash and match the expected inbound call.

The calldata verifier currently accepts direct `postAndVerifyBatch` transaction
inputs. It reads completion logs from the pinned settlement block: the protocol
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
- [ ] Support posting through wrappers and combining one scenario's expected entries
  across multiple posts. The current calldata verifier accepts direct
  `postAndVerifyBatch` inputs and the local runner expects one candidate to contain
  the full expected table. Cover multiple posts in one wrapper transaction,
  reverted wrapper frames, and separate posting transactions. Choose the evidence
  extraction design before adding a new tool or dependency.
- [ ] Handle final-root checks when later posts in the same block advance a rollup.
  A candidate batch containing only the scenario's entries does not imply that it
  is the block's only batch. Preserve checks of the expected entry's own updates.
- [ ] Add expected L1 hash-replay steps for the remaining scenarios with runtime calls.
  Nineteen scenarios supplying an L1 table currently omit `EXPECTED_L1_STEPS`.
  Local execution hashes are checked against the locally computed expectations;
  network verification without steps cannot independently compare every expected
  per-call runtime result after roots change. Do not substitute event counts for hashes.
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

Use [network-load.sh] to deploy a scenario once and send thousands of transactions through the same contract setup:

```bash
bash script/e2e/run/network-load.sh --workers 20 --txs-per-wallet 500 counter
bash script/e2e/run/network-load.sh --workers 50 --txs-per-wallet 100 nestedCounter
```

Funding matches the staged and parallel runners: wallets below **0.0005 ETH**
are topped up to **0.001 ETH** on each chain before the run. Override with
`--fund` / `FUND_ETH` and `--floor` / `FLOOR_ETH`; the floor defaults to half the
target. Size the balance for the whole load run, including deployment gas on
the first worker.

Reports trigger receipts and throughput; full settlement verification stays in the e2e runners.
