---
description: Sequentially run all e2e tests against the devnet and summarize results
---

# /run-e2e — Daily e2e test runner (flatten model)

Runs every e2e scenario in `script/e2e/` **sequentially** against the configured devnet and reports pass/fail. Sequential execution is mandatory — the shared deployer nonce makes parallel runs unsafe.

## Preconditions

- `.devnet.md` in repo root provides `L1_RPC`, `L2_RPC`, `PK`, `ROLLUPS`, `MANAGER_L2`. If absent, ask the user to supply them.
- Both chains must be producing blocks (not stuck at block 0). A quick `cast block-number` sanity check catches dead RPCs.
- CREATE2 factory deployed on both chains (use `script/e2e/shared/prepare-network.sh` if uncertain).

## Local vs network mode

- **Local** (default): `bash script/e2e/shared/run-local.sh script/e2e/<scenario>/E2E.s.sol` — spins up two anvils, runs full flow, decodes events.
- **Network**: `bash script/e2e/shared/run-network.sh script/e2e/<scenario>/E2E.s.sol` — uses the configured devnet, goes through the user-tx-then-batch interception flow.

## Ordered test list (simplest → most complex)

Sequence chosen so that a later test's failure usually indicates a genuinely new issue, not a regression in the primitives.

Implemented today:
1. `counter` — L1→L2 simplest, single deferred entry (no calls, no nested)
2. `counterL2` — L2→L1 mirror (`loadExecutionTable` + proxy trigger on L2)
3. `bridge` — L1→L2 with value + `etherDelta` state delta
4. `helloWorld` — L1→L2 with rich precomputed `returnData`
5. `multi-call-twice` — two deferred entries with **same** `proxyEntryHash` consumed sequentially
6. `multi-call-two-diff` — two deferred entries with **different** `proxyEntryHash`es
7. `nestedCounter` — outer entry with `L2ToL1Calls[]` + `expectedL1ToL2Calls[]`; reentrant proxy call consumes a precomputed nested return
8. `nestedCounterL2` — L2 mirror of `nestedCounter` (single entry, 1 call + 1 nested)
9. `revertCounter` — `L2ToL1Call.revertSpan=1` forced revert on L1 (inner call succeeds, EVM state rolled back; rolling hash still commits to success)
10. `revertCounterL2` — `revertCounter` mirror on L2
11. `revertContinue` — outer try/catch over a reentrant call that succeeds then naturally reverts; flow continues, rolling hash captures `(success=false, retData)` via `CALL_END`
12. `revertContinueL2` — `revertContinue` mirror on L2 (rolling hash matches L1's — protocol parity)
13. `nestedCallRevert` — reverting reentrant routed through `LookupCall { failed: true }` fallback (no NESTED tags in the rolling hash — the failed reentrant is replayed outside the chain)
14. `deepNested` — two levels of nesting (`NestedCaller → CAP → Counter`)
15. `multi-call-nested` — multi-entry mix of pure and nested entries on both L1 and L2
16. `multi-call-nestedL2` — L2-side mirror of `multi-call-nested` (single entry, 2 calls × 1 nested each)
17. `reentrant` — 4-hop cross-chain reentrant chain via `ReentrantCounter.deepCall(3)` (L1 entry has 2 calls + 2 cascading nested actions)

Pending:
- `flash-loan` — refactor of `script/flash-loan-test/ExecuteFlashLoan.s.sol` into the E2E.s.sol template

`siblingScopes` from main is deliberately **not** ported — scope arrays don't exist in the flatten model. Its coverage is subsumed by `multi-call-two-diff`.

## Failure diagnosis

Common flatten-model errors (selectors via `cast 4byte <selector>`):

| Selector | Error | Cause |
|---|---|---|
| `0x7d79e7e5` | `RollingHashMismatch` | Expected rolling hash ≠ computed. Recompute using `RollingHashBuilder` with exact tag ordering (CALL_BEGIN/NESTED_BEGIN/NESTED_END/CALL_END). Don't forget nested call iteration: one NESTED_BEGIN/END pair per `nestedActions[i]`, wrapping `_processNCalls(nested.callCount)` inside. |
| `0xa2cdd0ba` | `UnconsumedNestedActions` | Entry declares more nested actions than the live execution consumed. Either off-chain script misaligned calls vs. nested counts, or the target contract didn't reenter. |
| `0x16c31b8c` | `UnconsumedCalls` | `entry.callCount` < `entry.calls.length`. Set `callCount = calls.length` for entries that consume all calls on first trigger. |
| `0xed6bc750` | `ExecutionNotFound` | Next sequential entry doesn't match the expected `proxyEntryHash`, or the hash fields differ (wrong `sourceAddress`, missing `sourceRollupId`, wrong `targetRollupId`). Recompute with `crossChainCallHash(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId)` (canonical) — the legacy `Action`/`actionHash(...)` shim still works but routes to the same formula. |
| `0xf9d330ad` | `ExecutionNotInCurrentBlock` | `lastStateUpdateBlock` (L1) or `lastLoadBlock` (L2) ≠ current block. Use the `execute_l2_same_block` wrapper or ensure `postBatch` + user tx land in the same block. |
| `0x3a2df6d3` | `NotSelf` | `executeInContext` invoked by someone other than the manager itself (must be `address(this)` self-call). |

On failure, `bash script/e2e/shared/decode-block.sh --l1-block <N> ...` dumps the actual execution table for comparison with `forge script <SOL>:ComputeExpected`.

## Output directories

- `tmp/e2e-success/` — successful runs (summary only)
- `tmp/e2e-failures/` — raw forge output + decoded block diagnostics for failed runs
- `script/e2e/TODO_FIXES.md` — known test-side bugs tracked for follow-up
- `gh_issue/` — suspected system bugs (rollups / managerL2 / proxy)
