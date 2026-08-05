# Two-sided e2e scenarios

How a two-sided scenario exercises **both** anvil chains, and which pattern to pick per direction. Living references: `one_way/L1_to_L2/counter/E2ECounter.s.sol` (L1→L2) and `one_way/L2_to_L1/counterL2/E2ECounterL2.s.sol` (L2→L1) — when this doc and the code disagree, the code wins.

## Why two-sided

The protocol commits on the source side to "the destination chain will execute X and produce returnData=Y" via a cached `returnData` (plus a per-rollup `StateUpdate` on L1). A single-sided test only checks the source-side bookkeeping — the destination chain stays passive. A two-sided test additionally invokes the destination call for real, so any drift between the cached `returnData` and what the destination actually produces surfaces as an assertion failure.

The cross-chain call hash (`computeCrossChainCallHash(...)`, identical formula on both managers) is the cryptographic tie: a green two-sided run shows the **same hash** in events on both chains.

## Direction matters

Pick the destination-side pattern by where the user-trigger lives:

| Source-side trigger | Destination-side simulation |
|---|---|
| L1 (`postAndVerifyBatch` + user tx) | `managerL2.executeIncomingCrossChainCall(dest, value, data, src, srcRollup, entries, staticEntries)` from `SYSTEM_ADDRESS` — atomically replaces the table and drives `entries[0]`, lazily creating the source proxy on L2 |
| L2 (`loadExecutionTable` + user tx) | L1 batcher posting an entry with `proxyEntryHash = bytes32(0)` covered by `immediateEntryCount` — the entry executes inline during `postAndVerifyBatch` as an immediate L2Tx |

There is no `executeIncomingCrossChainCall` on L1 — the L1-side analog for system-driven execution is the immediate-L2Tx path. Note the batch-structure rule: the leading run of `proxyEntryHash == 0` entries **must** be covered by `immediateEntryCount` (`ImmediateCountStrandsLeadingL2Tx` otherwise); `executeL2Txs(rollupId)` only serves zero-hash entries that sit *behind* a non-zero-hash entry in the queue.

## File anatomy — the contracts in each scenario script (`E2E<Name>.s.sol`)

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

`run-local.sh` auto-runs `ExecuteL2` first, then `Execute`. If only one is present the other phase is skipped — keep both for two-sided.

## Patterns

- **Pattern A — L1→L2** (`counter`, `bridge`): one `ExecutionEntry` per side with **matching `proxyEntryHash`**. The L1 (source) entry has no calls (`rollingHash` is just the seeded accumulator); the L2 (destination) entry carries the real inbound call in `incomingCalls[0]` and is driven by `executeIncomingCrossChainCall`.
- **Pattern B — L2→L1** (`counterL2`, `revertCounterL2`): the L2 side is the source (zero-call entry via `loadExecutionTable` + proxy trigger); the L1 side executes for real via an immediate `proxyEntryHash = bytes32(0)` entry whose `l2ToL1Calls[0]` is the destination call.
- **Pattern C — multi-entry destination** (`multi-call-twice`, `multi-call-two-diff`, `multi-call-nested`): `executeIncomingCrossChainCall` drives one entry per transaction, so N-entry destinations instead use `loadExecutionTable` + an L2 trigger contract that fires the proxy calls. The trigger contract's L2 address becomes the entries' `sourceAddress`, so L1/L2 `proxyEntryHash` values necessarily diverge — the cross-chain tie is asserting real destination state at the end of `ExecuteL2`.

For entry construction and the rolling-hash schema (tagged folds, seeded with entry identity, **no call indices**), see `docs/EXECUTION_ENTRY_SPEC.md` and `docs/CORE_PROTOCOL_SPEC.md` §E; use the helpers in `shared/E2EHelpers.sol` / `shared/ComputeExpectedBase.sol` rather than inlining `keccak256` folds.

## Gotchas

- **No `@L1` / `@L2` in `///` docblocks.** Solidity natspec parses `@…` as a tag. Use `(CAP on L1, MAINNET)` phrasing in `///` blocks; `//` comments are fine.
- **Strict `msg.value` match** for `executeIncomingCrossChainCall` — even `value=0` requires `msg.value=0`.
- **Same-block requirement** on both chains. `run-local.sh`'s `execute_l2_same_block` wrapper disables automine, queues txs, and mines them together — don't roll blocks manually in `Execute`/`ExecuteL2`.
- **Strict ascending order** for `proofSystems` and `rollupIdsWithProofSystems` in the batch. The `E2EHelpers.sol` builders handle the single-prover / single-rollup case.

## Verification

```bash
L1_PORT=<port> L2_PORT=<port+1> bash script/e2e/shared/run-local.sh script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol
```

A green two-sided run shows the source-side events on one chain, the destination-side events on the other, the same cross-chain hash in both event groups, and real destination state advanced. On failure, decode the block with `shared/decode-block.sh` and compare against `forge script <SOL>:ComputeExpected`.
