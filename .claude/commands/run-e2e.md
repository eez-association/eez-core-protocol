---
description: Run all e2e tests against the devnet and summarize results
---

# /run-e2e — Daily e2e test runner (flatten model)

Runs every e2e scenario in `script/e2e/` and reports pass/fail.

- **Local mode runs in parallel by default** — each scenario gets its own anvil pair on unique ports + chain IDs (so forge `broadcast/<basename>/<chainId>/` dirs and deployer nonces don't collide).
- **Network mode stays sequential** — the shared on-chain deployer nonce makes parallel runs against a real devnet unsafe.

## Preconditions

- Network mode: `chain.env` in repo root (gitignored) provides `L1_RPC`, `L1_FRONT`, `L2_RPC`, `L2_FRONT`, `ROLLUPS`, `MANAGER_L2`, `PK` — see the template + liveness pre-flight in `script/e2e/README.md`. If absent, ask the user to supply it.
- Both chains must be producing blocks (not stuck at block 0). A quick `cast block-number` sanity check catches dead RPCs.
- CREATE2 factory deployed on both chains (use `script/e2e/shared/prepare-network.sh` if uncertain).

## How to run

- **Local — all scenarios in parallel (default):**
  `bash script/e2e/shared/run-all-parallel.sh`
  Forks one `run-local.sh` per scenario with unique `L1_PORT`/`L2_PORT`/`L1_CHAIN_ID`/`L2_CHAIN_ID`. Cap concurrency with `MAX_PARALLEL=N`. Args may be scenario names, categories, or category/direction paths: `bash script/e2e/shared/run-all-parallel.sh one_way multi-call-twice`. Per-scenario logs land in `tmp/e2e-parallel/<scenario>.log`; passes also copied to `tmp/e2e-success/`, failures to `tmp/e2e-failures/`.
- **Local — single scenario:**
  `bash script/e2e/shared/run-local.sh script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol` — spins up two anvils (defaults: 8545/8546). Override with `L1_PORT`/`L2_PORT`; optionally `L1_CHAIN_ID`/`L2_CHAIN_ID` to override anvil's default chain id (31337) so broadcast dirs don't collide with concurrent runs.
- **Network — set of scenarios (sequential, the intended entry point):**
  `bash script/e2e/shared/run-network-set.sh all` (or a category / `category/direction` / scenario names; `DEVNET_ENV=other.env` for another devnet). Logs land in `tmp/e2e-network/<scenario>.log`. Never parallelize network runs — shared deployer nonce.
- **Network — single scenario:**
  `bash script/e2e/shared/run-network.sh <sol> --l1-rpc … --l1-front … --l2-rpc … --l2-front … --pk … --rollups … --manager-l2 …` — user-tx-then-composer flow with content-scan settlement discovery.

## Ordered test list (simplest → most complex)

Sequence chosen so that a later test's failure usually indicates a genuinely new issue, not a regression in the primitives.

Implemented today:
1. `counter` — L1→L2 simplest, single deferred entry (no calls, no nested)
2. `counterL2` — L2→L1 mirror (`loadExecutionTable` + proxy trigger on L2)
3. `bridge` — L1→L2 with value + `etherDelta` state delta
4. `multi-call-twice` — two deferred entries with **same** `proxyEntryHash` consumed sequentially
5. `multi-call-twiceL2` — L2→L1 mirror of `multi-call-twice` (two L2 source entries, one zero-hash L1 entry with 2 calls)
6. `multi-call-two-diff` — two deferred entries with **different** `proxyEntryHash`es
7. `multi-call-two-diffL2` — L2→L1 mirror of `multi-call-two-diff`
8. `nestedCounter` — outer entry with `L2ToL1Calls[]` + `expectedL1ToL2Calls[]`; reentrant proxy call consumes a precomputed nested return
9. `nestedCounterL2` — L2 mirror of `nestedCounter` (single entry, 1 call + 1 nested)
10. `revertCounter` — `L2ToL1Call.revertNextNCalls=1` forced revert on L1 (inner call succeeds, EVM state rolled back; rolling hash still commits to success)
11. `revertCounterL2` — `revertCounter` mirror on L2
12. `revertContinue` — outer try/catch over a reentrant call that succeeds then naturally reverts; flow continues, rolling hash captures `(success=false, retData)` via `CALL_END`
13. `revertContinueL2` — `revertContinue` mirror on L2 (rolling hash matches L1's — protocol parity)
14. `nestedCallRevert` — reverting reentrant expressed as a `success: false` row in the unified reentrant table
15. `deepNested` — two levels of nesting (`NestedCaller → CAP → Counter`)
16. `multi-call-nested` — multi-entry mix of pure and nested entries on both L1 and L2
17. `multi-call-nestedL2` — L2-side mirror of `multi-call-nested` (single entry, 2 calls × 1 nested each)
18. `reentrant` — 4-hop cross-chain reentrant chain via `ReentrantCounter.deepCall(3)` (L1 entry has 2 calls + 2 cascading nested actions)

Pending:
- `flash-loan` — refactor of `script/flash-loan-test/ExecuteFlashLoan.s.sol` into the scenario template

`siblingScopes` from main is deliberately **not** ported — scope arrays don't exist in the flatten model. Its coverage is subsumed by `multi-call-two-diff`.

## Failure diagnosis

Common flatten-model errors (decode any selector with `cast 4byte <sel>` or grep `src/` for the error name):

| Selector | Error | Cause |
|---|---|---|
| `0xf3a3b67c` | `RollingHashMismatch` | Expected rolling hash ≠ computed. Recompute using `RollingHashBuilder` with exact tag ordering (seed → CALL_BEGIN/NESTED pairs/CALL_END); no index is folded. A wrong caller address (an intermediate contract instead of the broadcaster EOA) is the usual root cause. |
| `0x7a5c2981` | `EntryNotFound(bytes32,uint64)` | L2: no table entry matches the outgoing call's key from the cursor onward — recompute with `crossChainCallHashL2Out`; check `sourceAddress` is the contract that called the proxy. |
| `0xc2098b88` | `EntryHashMismatch` | L2 `executeIncomingCrossChainCall`: `entries[0].proxyEntryHash` ≠ hash of the explicit params. |
| `0xf9d330ad` | `ExecutionNotInCurrentBlock` | `lastVerifiedBlock` (L1, per rollup) or `lastLoadBlock` (L2) ≠ current block. The runner's `execute_same_block` wrapper must mine table + trigger together — don't roll blocks inside `Execute`/`ExecuteL2`. |
| `0xfa3021e5` | `AllImmediateL2TxsFailed` | Every immediate L2Tx entry reverted inside `postAndVerifyBatch` — usually a `RollingHashMismatch` inside the entry (check the inner revert via `trace_failed_txs` / `cast run`). |
| `0xa296e78c` | `ImmediateCountStrandsLeadingL2Tx` | A leading zero-hash entry was left out of `immediateEntryCount` — use `immediateSingleRollupBatch`, which auto-counts it. |
| `0x29c3b7ee` | `NotSelf` | `executeInContextAndRevert` invoked by someone other than the manager itself (must be `address(this)` self-call). |

On failure, `bash script/e2e/shared/decode-block.sh --l1-block <N> ...` dumps the actual execution table for comparison with `forge script <SOL>:ComputeExpected`.

## Output directories

- `tmp/e2e-success/` — successful local runs
- `tmp/e2e-failures/` — raw forge output + diagnostics for failed local runs
- `tmp/e2e-network/` — per-scenario network-mode logs (`run-network-set.sh`)
