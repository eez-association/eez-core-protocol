# E2E Tests — Setup & Running

End-to-end cross-chain scenarios under `script/e2e/<category>/<direction>/<scenario>/`.
Categories: `one_way`, `multi_call`, `nested`, `reentrant`, `revert`. Directions:
`L1_to_L2` (L1-starting) and `L2_to_L1` (L2-starting).

Two modes:

- **Local** — everything on anvil; the test itself plays sequencer and posts the batches.
- **Network** — against a live devnet; the test only sends the user trigger tx, the
  devnet's composer posts the batch on L1 and loads the table on L2, and the runner
  verifies the on-chain result against locally computed expectations.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`), bash.
- `forge build` compiles clean.
- Network mode only: a **test-only** private key funded with gas on BOTH chains.

## Local mode (no setup)

```bash
bash script/e2e/shared/run-all-parallel.sh              # everything
bash script/e2e/shared/run-all-parallel.sh one_way      # one category
bash script/e2e/shared/run-all-parallel.sh counter bridge
```

## Network mode

### 1. Create `chain.env` in the repo root

Gitignored — never commit it, it holds your key.

```bash
L1_RPC=https://l1-rpc.example.net                     # L1 read/deploy RPC
L1_FRONT=http://x.x.x.x:18999                         # L1 x-chain front (L1→L2 trigger txs ONLY)
L2_RPC=http://x.x.x.x:18688                           # L2 read/deploy RPC
L2_FRONT=http://x.x.x.x:18998                         # L2 x-chain front (L2→L1 trigger txs ONLY)
ROLLUPS=0x...                                         # EEZ — L1 rollup registry
MANAGER_L2=0x4200000000000000000000000000000000000007 # EEZL2 — L2 manager (genesis predeploy)
PK=0x...                                              # test key, funded on BOTH chains
```

Endpoints and the `ROLLUPS` address come from the devnet operator. The *fronts* hold
cross-chain trigger txs for the composer — they don't relay normal txs; use them only
for triggers (the runner routes this automatically).

### 2. Prepare the network (once per devnet reset)

Ensures CREATE2 factories on both chains and funds the test account on L2. Idempotent.

```bash
source chain.env
bash script/e2e/shared/prepare-network.sh --l1-rpc "$L1_RPC" --l2-rpc "$L2_RPC" --pk "$PK" --rollups "$ROLLUPS"
```

### 3. Check the deployment is alive

The active registry receives settlement batches every few L1 blocks. No logs here
means a wrong `ROLLUPS` address or a dead composer — triggers would hang forever:

```bash
LATEST=$(cast block-number --rpc-url "$L1_RPC")
cast logs --rpc-url "$L1_RPC" --from-block $((LATEST-100)) --to-block $LATEST --address "$ROLLUPS" | grep -c blockNumber   # >0 → active
```

### 4. Run

```bash
bash script/e2e/shared/run-network-set.sh one_way              # whole category
bash script/e2e/shared/run-network-set.sh multi_call/L1_to_L2  # one direction
bash script/e2e/shared/run-network-set.sh counter bridge       # specific scenarios
bash script/e2e/shared/run-network-set.sh all                  # everything
DEVNET_ENV=other.env bash script/e2e/shared/run-network-set.sh one_way
```

Network runs are always sequential (shared deployer nonce). Per-scenario logs land in
`tmp/e2e-network/<scenario>.log`; the runner prints a PASS/FAIL summary and exits 1
on any failure.

## What a network run verifies

Each scenario computes its full expected execution tables locally (`ComputeExpected`),
then checks the chain did exactly that:

- **L1 settlement**: the batch consumed our entries (`ExecutionConsumed` routing,
  `EntryExecuted` rolling hash + call/nested counts).
- **L1 posted batch**: the `postAndVerifyBatch` tx calldata is decoded and every
  entry is compared field-by-field against the expected table (calls, callCounts,
  returnData, lookups; state deltas: rollupId + etherDelta exact, and the per-rollup
  delta chain must be contiguous and move the state root across the batch).
- **Live state roots**: the registry root must have settled past each posted delta.
- **L2 table**: the `ExecutionTableLoaded` entries must be byte-identical to the
  expected ones, plus structural invariants.
- **L2 calls**: `IncomingCrossChainCallExecuted` fields must re-hash to the emitted
  call hash and match the expected inbound call.
