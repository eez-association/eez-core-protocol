# E2E Tests — Setup & Running

Cross-chain scenarios under `script/e2e/<category>/<direction>/<scenario>/`.
Categories: `one_way`, `multi_call`, `nested`, `reentrant`, `revert`; directions:
`L1_to_L2`, `L2_to_L1`.

Two modes:

- **Local** — everything on anvil; the test itself plays sequencer and posts batches.
- **Network** — live devnet; the test only sends the user trigger tx, the composer
  posts the batch on L1 and loads the table on L2, and the runner verifies the
  on-chain result against locally computed expectations.

**Encoding rule (both modes):** each top-level cross-chain call is one entry on the
source chain and one system delivery on the destination; calls made *inside* an
entry's execution belong to that entry.

## Prerequisites

[Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`),
bash, `forge build` clean. Network mode also needs a test-only key (see step 1).

## Local mode (no setup)

```bash
bash script/e2e/shared/run-all-parallel.sh              # everything
bash script/e2e/shared/run-all-parallel.sh one_way      # one category
bash script/e2e/shared/run-all-parallel.sh counter bridge
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
bash script/e2e/shared/prepare-network.sh --l1-rpc "$L1_RPC" --l2-rpc "$L2_RPC" --pk "$PK" --rollups "$ROLLUPS"
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
bash script/e2e/shared/run-network-set.sh one_way              # category
bash script/e2e/shared/run-network-set.sh counter bridge       # scenarios
bash script/e2e/shared/run-network-set.sh all                  # everything
DEVNET_ENV=other.env bash script/e2e/shared/run-network-set.sh one_way
```

Sequential because all scenarios share the `chain.env` nonce. Logs:
`tmp/e2e-network/<scenario>.log`; exits 1 on any failure.

### 5b. Run — PARALLEL orchestrator (per-worker wallets)

Every job gets its own ephemeral wallet, so scenarios run concurrently — including
the same scenario N times (load testing):

```bash
bash script/e2e/orchestrator/parallel-e2e.sh counter:10            # counter 10x
bash script/e2e/orchestrator/parallel-e2e.sh counter:5 bridge:3    # mixed
bash script/e2e/orchestrator/parallel-e2e.sh all                   # each once
bash script/e2e/orchestrator/parallel-e2e.sh one_way:2 nested      # categories too
```

Self-funding: `faucet.txt` (repo root, gitignored) is the orchestrator's faucet —
created on first run, topped up from anvil #2 when short; workers get `FUND_ETH`
(default 0.1) per chain via async nonce-sequenced txs; a `flock` serializes
concurrent instances.

Flags: `--direct` funds workers straight from the source key (anvil #2, or
`SOURCE_PK`) with no faucet account; `--fund <eth>` sets the per-worker amount:

```bash
bash script/e2e/orchestrator/parallel-e2e.sh --direct --fund 0.05 counter:10
```

Env knobs: `MAX_PARALLEL` (default 100), `FUND_ETH`, `SOURCE_PK`,
`RECEIPT_TIMEOUT`, `DEVNET_ENV`. Logs + worker keys:
`tmp/e2e-parallel-net/<timestamp>/`.

Caveats:

- **Memory is the ceiling** — ~20 concurrent jobs on a 32 GB machine; stacking runs
  can OOM-kill runners (logs cut off with no error text).
- **`VerifyL1BatchCalldata` is not concurrency-aware** (L2-starting scenarios): it
  may compare against a sibling job's batch → false FAIL. If "expected L1 entries
  executed in range" PASSed and only the posted-calldata diff failed, it's this.

### Manual single scenario

```bash
source chain.env
bash script/e2e/shared/run-network.sh script/e2e/one_way/L1_to_L2/counter/E2ECounter.s.sol \
  --l1-rpc $L1_RPC --l1-front $L1_FRONT --l2-rpc $L2_RPC --l2-front $L2_FRONT \
  --pk $PK --rollups $ROLLUPS --manager-l2 $MANAGER_L2
```

Timeouts (env, seconds): `RECEIPT_TIMEOUT` 420, `L1_SETTLE_TIMEOUT` 300,
`L2_SETTLE_TIMEOUT` 180, `L1_VERIFY_TIMEOUT` 90.

## Operational notes

The runner already handles endpoint routing, fresh nonces, RPC-lag retries, bounded
waits, and legacy event decoding. Still your job:

1. **Heartbeat first** (step 4) — held-forever triggers with zero errors usually
   mean composer trouble, not a test bug.
2. **Fronts hold, they don't relay** — non-cross-chain txs sent to a front are
   silently dropped; a held trigger has no receipt until bundled.
3. **Load-balanced L1 RPCs lag their own writes** — for manual cast/forge, wait for
   consolidation; fronts double as fresh read nodes.
4. **Devnets may pin an older protocol commit** — network mode works across
   versions while the hash formulas are unchanged (`Verify.s.sol` decodes both
   `ExecutionTableLoaded` layouts).

## What a network run verifies

- **L1 settlement**: batch consumed our entries (`ExecutionConsumed` routing,
  `EntryExecuted` rolling hash + call/nested counts).
- **L1 posted batch**: `postAndVerifyBatch` calldata decoded and compared
  field-by-field (calls, callCounts, returnData, lookups; state deltas exact and
  contiguous across the batch).
- **Live state roots**: registry root settled past each posted delta.
- **L2 table**: `ExecutionTableLoaded` entries byte-identical to expected.
- **L2 calls**: `IncomingCrossChainCallExecuted` fields re-hash to the emitted
  call hash and match the expected inbound call.
