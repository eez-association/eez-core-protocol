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
3. **Time windows** — block-number snapshots taken right before publishing the
   trigger bound every scan range (call hashes are not unique across runs — an
   earlier run of the same scenario emits identical ones), and deadlines
   (`L1_SETTLE_TIMEOUT`, `L2_SETTLE_TIMEOUT`, `L1_VERIFY_TIMEOUT`) bound the wait.

Concretely: the settlement block is discovered by scanning `[snapshot..latest]`
for the expected hashes (`VerifyL1BatchInRange` / `VerifyL1ZeroHashEntriesInRange`
on L1, `VerifyL2CallsInRange` on L2), and the receipt block of the trigger tx is
only ever a *candidate* — the composer may bundle the actual consumption in a
later block on either chain.

## What a network run verifies

Each scenario computes its full expected execution tables locally (`ComputeExpected`),
then checks the chain did exactly that:

- **L1 settlement**: the batch consumed our entries (`ExecutionConsumed` routing,
  `EntryExecuted` rolling hash + call/nested counts).
- **L1 posted batch** (when the settlement tx is identifiable and the scenario
  prints `EXPECTED_L1_TABLE`): the `postAndVerifyBatch` calldata is decoded and every
  expected entry is field-matched against a posted twin (calls, reentrant frames,
  returnData, success flags; state updates: rollupId + etherDelta exact; the matched
  entries' per-rollup update chain must be contiguous and move the root), plus the
  structural invariants the contract itself enforces (proxy protection, immediate
  prefix rules).
- **Live state roots**: the registry root must have settled to (or beyond) each
  touched rollup's posted update.
- **L2 table**: every expected entry must have a byte-identical loaded twin
  (subset match — extra entries from other actors are ignored), plus structural
  invariants.
- **L2 calls**: `IncomingCrossChainCallExecuted` fields must re-hash to the emitted
  call hash and match the expected inbound call.
