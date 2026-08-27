# E2E Tests — Setup & Running

Cross-chain scenarios under `script/e2e/<category>/<direction>/<scenario>/`.
Categories: `one_way`, `multi_call`, `multi_tx`, `nested`, `reentrant`, `revert`; directions:
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
bash script/e2e/run/prepare-network.sh --l1-rpc "$L1_RPC" --l2-rpc "$L2_RPC" --pk "$PK" --rollups "$ROLLUPS"
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
  `L1_CALLDATA_TIMEOUT` (default 180s) before failing the posted-calldata check.

### Manual single scenario

```bash
source chain.env
bash script/e2e/run/network.sh script/e2e/one_way/L1_to_L2/counter/E2ECounter.s.sol \
  --l1-rpc $L1_RPC --l1-front $L1_FRONT --l2-rpc $L2_RPC --l2-front $L2_FRONT \
  --pk $PK --rollups $ROLLUPS --manager-l2 $MANAGER_L2
```

Timeouts (env, seconds): `RECEIPT_TIMEOUT` 300 (the set-runners raise it to 420),
`L1_SETTLE_TIMEOUT` 300, `L2_SETTLE_TIMEOUT` 180, `L1_VERIFY_TIMEOUT` 90.

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
   (`L1_SETTLE_TIMEOUT`, `L2_SETTLE_TIMEOUT`, `L1_VERIFY_TIMEOUT`) bound the wait.

Concretely: the settlement block is discovered by scanning `[snapshot..latest]` —
by expected call hashes on L1 proxy-consumed entries (`VerifyL1BatchInRange`), by
listing `EntryExecuted` txs + calldata content-match for L1 zero-hash entries
(`VerifyL1SettlementTxsInRange`), by call hashes on L2 (`VerifyL2CallsInRange`) —
and the receipt block of the trigger tx is
only ever a *candidate* — the composer may bundle the actual consumption in a
later block on either chain.

## What a network run verifies

- **L1 settlement**: batch consumed our entries (`ExecutionConsumed` routing,
  `EntryExecuted` rolling hash + call/nested counts).
- **L1 posted batch** (when the settlement tx is identifiable and the scenario
  prints `EXPECTED_L1_TABLE`): the `postAndVerifyBatch` calldata is decoded and every
  expected entry is field-matched against a posted twin (calls, reentrant frames,
  returnData, success flags; state updates: rollupId + etherDelta exact; the matched
  entries' per-rollup update chain must be contiguous and move the root), plus the
  structural invariants the contract itself enforces (proxy protection, immediate
  prefix rules).
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

## Two-sided scenario design

How a two-sided scenario exercises **both** anvil chains, and which pattern to pick per direction. Living references: `one_way/L1_to_L2/counter/E2ECounter.s.sol` (L1→L2) and `one_way/L2_to_L1/counterL2/E2ECounterL2.s.sol` (L2→L1) — when this doc and the code disagree, the code wins.

### Why two-sided

The protocol commits on the source side to "the destination chain will execute X and produce returnData=Y" via a cached `returnData` (plus a per-rollup `RollupUpdate` on L1). A single-sided test only checks the source-side bookkeeping — the destination chain stays passive. A two-sided test additionally invokes the destination call for real, so any drift between the cached `returnData` and what the destination actually produces surfaces as an assertion failure.

The cross-chain call hash (`computeCrossChainCallHash(...)`, identical formula on both managers) is the cryptographic tie: a green two-sided run shows the **same hash** in events on both chains.

### Direction matters

Pick the destination-side pattern by where the user-trigger lives:

| Source-side trigger | Destination-side simulation |
|---|---|
| L1 (`postAndVerifyBatch` + user tx) | `managerL2.executeIncomingCrossChainCall(entries, staticEntries)` from `SYSTEM_ADDRESS` — atomically replaces the table and drives `entries[0]` (its `incomingCalls[0]` is the inbound call), lazily creating the source proxy on L2 |
| L2 (`loadExecutionTable` + user tx) | L1 batcher posting an entry with `proxyEntryHash = bytes32(0)` covered by `immediateEntryCount` — the entry executes inline during `postAndVerifyBatch` as an immediate L2Tx |

There is no `executeIncomingCrossChainCall` on L1 — the L1-side analog for system-driven execution is the immediate-L2Tx path. Note the batch-structure rule: the leading run of `proxyEntryHash == 0` entries **must** be covered by `immediateEntryCount` (`ImmediateCountStrandsLeadingL2Tx` otherwise); `executeL2Txs(rollupId)` only serves zero-hash entries that sit *behind* a non-zero-hash entry in the queue.

### File anatomy — the contracts in each scenario script (`E2E<Name>.s.sol`)

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
```

`run/local.sh` auto-runs `ExecuteL2` first, then `Execute`. If only one is present the other phase is skipped — keep both for two-sided.

### Patterns

- **Pattern A — L1→L2** (`counter`, `bridge`): one `ExecutionEntry` per side with **matching `proxyEntryHash`**. The L1 (source) entry has no calls (`rollingHash` is just the seeded accumulator); the L2 (destination) entry carries the real inbound call in `incomingCalls[0]` and is driven by `executeIncomingCrossChainCall`.
- **Pattern B — L2→L1** (`counterL2`, `revertCounterL2`): the L2 side is the source (zero-call entry via `loadExecutionTable` + proxy trigger); the L1 side executes for real via an immediate `proxyEntryHash = bytes32(0)` entry whose `l2ToL1Calls[0]` is the destination call.
- **Pattern C — multi-entry destination** (`multi-call-twice`, `multi-call-two-diff`, `multi-call-nested`): `executeIncomingCrossChainCall` drives one entry per transaction, so N-entry destinations instead use `loadExecutionTable` + an L2 trigger contract that fires the proxy calls. The trigger contract's L2 address becomes the entries' `sourceAddress`, so L1/L2 `proxyEntryHash` values necessarily diverge — the cross-chain tie is asserting real destination state at the end of `ExecuteL2`.

For entry construction and the rolling-hash schema (tagged folds, seeded with entry identity, **no call indices**), see `docs/EXECUTION_ENTRY_SPEC.md` and `docs/CORE_PROTOCOL_SPEC.md` §E; use the helpers in `shared/E2EHelpers.sol` / `shared/ComputeExpectedBase.sol` rather than inlining `keccak256` folds.

### Gotchas

- **No `@L1` / `@L2` in `///` docblocks.** Solidity natspec parses `@…` as a tag. Use `(CAP on L1, MAINNET)` phrasing in `///` blocks; `//` comments are fine.
- **`msg.value` conservation** for `executeIncomingCrossChainCall` — `msg.value` mints the total inbound ETH the committed calls consume — a prover constraint, no on-chain check (an under-mint fails as a value call with insufficient balance).
- **Same-block requirement** on both chains. `run/local.sh`'s `execute_l2_same_block` wrapper disables automine, queues txs, and mines them together — don't roll blocks manually in `Execute`/`ExecuteL2`.
- **Strict ascending order** for `proofSystems` and `rollupIdsWithProofSystems` in the batch. The `E2EHelpers.sol` builders handle the single-prover / single-rollup case.

### Verification

```bash
L1_PORT=<port> L2_PORT=<port+1> bash script/e2e/run/local.sh script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol
```

A green two-sided run shows the source-side events on one chain, the destination-side events on the other, the same cross-chain hash in both event groups, and real destination state advanced. On failure, decode the block with `shared/decode-block.sh` and compare against `forge script <SOL>:ComputeExpected`.
