---
description: Run all e2e tests against the devnet and summarize results
---

# /run-e2e — Daily e2e test runner (flatten model)

Runs every e2e scenario in `script/e2e/` and reports pass/fail.

- **Local mode runs in parallel by default** — each scenario gets its own anvil pair on unique ports + chain IDs (so forge `broadcast/<basename>/<chainId>/` dirs and deployer nonces don't collide).
- **Network mode is sequential with a shared key** (`run/network-sequential.sh` — the shared deployer nonce makes parallel runs unsafe) **or parallel with per-worker wallets** (`script/e2e/run/network-parallel.sh` — a faucet account funds one throwaway wallet per job, removing the nonce constraint; logs in `tmp/e2e-parallel-net/<ts>/`).

## Preconditions

- Network mode: `chain.env` in repo root (gitignored) provides `L1_RPC`, `L1_FRONT`, `L2_RPC`, `L2_FRONT`, `ROLLUPS`, `MANAGER_L2`, `PK` — see the template + liveness pre-flight in `script/e2e/README.md`. If absent, ask the user to supply it.
- Both chains must be producing blocks (not stuck at block 0). A quick `cast block-number` sanity check catches dead RPCs.
- CREATE2 factory deployed on both chains (use `script/e2e/run/prepare-network.sh` if uncertain).

## How to run

- **Local — all scenarios in parallel (default):**
  `bash script/e2e/run/local-parallel.sh`
  Forks one `run/local.sh` per scenario with unique `L1_PORT`/`L2_PORT`/`L1_CHAIN_ID`/`L2_CHAIN_ID`. Cap concurrency with `MAX_PARALLEL=N`. Args may be scenario names, categories, or category/direction paths: `bash script/e2e/run/local-parallel.sh one_way multi-call-twice`. Per-scenario logs land in `tmp/e2e-parallel/<scenario>.log`; passes also copied to `tmp/e2e-success/`, failures to `tmp/e2e-failures/`.
- **Local — single scenario:**
  `bash script/e2e/run/local.sh script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol` — spins up two anvils (defaults: 8545/8546). Override with `L1_PORT`/`L2_PORT`; optionally `L1_CHAIN_ID`/`L2_CHAIN_ID` to override anvil's default chain id (31337) so broadcast dirs don't collide with concurrent runs.
- **Network — set of scenarios (sequential, the intended entry point):**
  `bash script/e2e/run/network-sequential.sh all` (or a category / `category/direction` / scenario names; `DEVNET_ENV=other.env` for another devnet). Logs land in `tmp/e2e-network/<scenario>.log`. Never parallelize network runs with a shared key — use `run/network-parallel.sh` for parallel network runs.
- **Network — single scenario:**
  `bash script/e2e/run/network.sh <sol> --l1-rpc … --l1-front … --l2-rpc … --l2-front … --pk … --rollups … --manager-l2 …` — user-tx-then-composer flow with content-scan settlement discovery.

## Ordered test list (simplest → most complex)

Sequence chosen so that a later test's failure usually indicates a genuinely new issue, not a regression in the primitives.

Implemented today:
1. `counter` — L1→L2 simplest, single deferred entry (no calls, no nested)
2. `counterL2` — L2→L1 mirror (`loadExecutionTable` + proxy trigger on L2)
3. `bridge` — L1→L2 with value + `etherDelta` state delta
4. `bridgeL2` — L2→L1 ETH release (0.001 ether): the L2 trigger burns the value and the immediate zero-hash L2Tx entry releases it to the receiver (`etherDelta -`, receiver-balance assert). A release needs PRIOR escrow: local mode sets it directly on the anvil node (`anvil_setBalance` + `anvil_setStorageAt`, self-checked — `_fundEscrow`); network mode needs the devnet to already hold escrow for rollup 1, guaranteed in a full sequential run because `bridge` (1-ether deposit) sorts first
5. `multi-call-twice` — two deferred entries with **same** `proxyEntryHash` consumed sequentially
6. `multi-call-twiceL2` — L2→L1 mirror of `multi-call-twice` (two L2 source entries, one zero-hash L1 entry with 2 calls)
7. `multi-call-two-diff` — two deferred entries with **different** `proxyEntryHash`es
8. `multi-call-two-diffL2` — L2→L1 mirror of `multi-call-two-diff`
9. `counter-multi-tx` — three deferred entries with the same `proxyEntryHash`, each consumed by its OWN top-level user tx (vs `multi-call-twice`'s single-tx trigger); L2 side delivers each inbound call as its own `executeIncomingCrossChainCall` tx. Network mode fires all triggers WITHOUT waiting (pre-signed consecutive nonces — `NUM_TXS` output + `publish_user_txs_nowait`) and prints every tx hash.
10. `nestedCounter` — outer entry with `L2ToL1Calls[]` + `expectedL1ToL2Calls[]`; reentrant proxy call consumes a precomputed nested return
11. `nestedCounterL2` — L2 mirror of `nestedCounter` (single entry, 1 call + 1 nested)
12. `revertCounter` — natural destination revert as a LOOKUP: the call would revert on L2 (`RevertCounter.increment()`), so it is never delivered (no L2 tx at all); the composer signs the revert data into the source entry (`success=false`), which replays it to the L1 caller (a `SafeCounterAndProxy` try/catch absorbs it). Verified from the posted batch calldata (the entry unwinds its events); the call key is ASSERTED absent on L2 (`ABSENT_L2_HASHES` → `VerifyL2Absent` range scan)
13. `revertCounterL2` — `revertCounter` mirror, L2→L1 (destination `RevertCounter` on L1)
14. `revertFromOtherChain` — the real `revertNextNCalls` producer: `SelfCallerWithRevert` on L2 consumes the same reentrant row twice (first unwound by its inner revert); the L1 entry mirrors BOTH consumptions — `[increment span=1, increment plain]` — so the other chain's revert force-reverts the first increment on L1 (counter ends 1, not 2)
15. `revertFromOtherChainL2` — the SIMPLEST span producer: alice calls `SelfCallerRevertOnly` on L2 directly; its one consumption unwinds with the inner revert, and L1 mirrors it as a single `increment` with `revertNextNCalls=1` — counter ends 0 (ran, returned 1, state erased)
16. `revertFromOtherChainAndCallAgainL2` — same plus a surviving retry: two consumptions of one source entry (first unwound), mirrored on L1 as `[increment span=1, increment plain]` — counter ends 1
17. `nestedCallRevert` — reverting reentrant expressed as a `success: false` row in the unified reentrant table
18. `deepNested` — two levels of nesting (`NestedCaller → CAP → Counter`)
19. `multi-call-nested` — multi-entry mix of pure and nested entries on both L1 and L2
20. `multi-call-nestedL2` — L2-side mirror of `multi-call-nested` (single entry, 2 calls × 1 nested each)
21. `reentrant` — 4-hop cross-chain reentrant chain via `ReentrantCounter.deepCall(3)` (L1 entry has 2 calls + 2 cascading nested actions)
22. `flash-loan` — DeFi composite: flash loan repaid via a full L1→L2→L1 bridge round trip in one user tx (2 proxy-keyed L1 entries — the second's top-level `l2ToL1Call` releases the escrow on L1; 2 L2 deliveries — the second consumes an outgoing return leg from `expectedOutgoingCalls`)
23. `topLevelStaticCounter` — L1→L2 TOP-LEVEL static read, the ONLY view-only case: the batch posts 1 root-pinned reader-keyed `StaticExecutionEntry` whose cached returnData is the exported off-chain prediction (`PREDICTED_STATIC_RESULT` env bytes, captured by the actual staticcall at deploy); NOTHING executes on L2. Its ComputeExpected exports only `EXPECTED_L1_STATIC_TABLE` (no events anywhere) — proof = the trigger tx, the reader's persisted state (`VerifyNetwork`), and the posted static entry matched from the batch calldata (root pin neutralized), plus the key ASSERTED absent on L2 (`ABSENT_L2_HASHES`); the standard no-tx eth_call query as the reader is exercised in local mode only (same block — it is valid just until the next tx that moves L2's root)
24. `staticCounterL2` — L2→L1 TOP-LEVEL static read: the L2 pool (same-block gate) resolves the reader-keyed entry, and the read EXECUTES for real on L1 as an immediate zero-hash L2Tx entry with one `isStatic: true` call; ComputeExpected exports the L1 side only
25. `nestedStaticCounter` — L1→L2→STATIC-L1 nested read: the L2 delivery resolves a STATIC-kind row of `expectedOutgoingCalls` (keyed at rhFire, folds nothing); the L1 source entry EXECUTES the read for real (`isStatic` `l2ToL1Call`, same staticCcHash digest on both sides)
26. `nestedStaticCounterL2` — L2→L1→L2→STATIC-L1, nested read at depth 2: the L1 L2Tx entry's reentrant frame carries the read in its OWN sub-array (real STATICCALL inside the NESTED frame folds); the L2 source entry resolves the STATIC row from its unified table

`siblingScopes` from main is deliberately **not** ported — scope arrays don't exist in the flatten model. Its coverage is subsumed by `multi-call-two-diff`.

## Failure diagnosis

Common flatten-model errors (decode any selector with `cast 4byte <sel>` or grep `src/` for the error name):

| Selector | Error | Cause |
|---|---|---|
| `0xf3a3b67c` | `RollingHashMismatch` | Expected rolling hash ≠ computed. Recompute using `RollingHashBuilder` with exact tag ordering (seed → CALL_BEGIN/NESTED pairs/CALL_END); no index is folded. A wrong caller address (an intermediate contract instead of the broadcaster EOA) is the usual root cause. |
| `0x7a5c2981` | `EntryNotFound(bytes32,uint64)` | L2: no table entry matches the outgoing call's key from the cursor onward — recompute with `crossChainCallHashL2Out`; check `sourceAddress` is the contract that called the proxy. |
| `0xc2098b88` | `EntryHashMismatch` | L2 `executeIncomingCrossChainCall`: `entries[0].proxyEntryHash` ≠ hash of its own `incomingCalls[0]` (that hash folds the call's `gas`). |
| `0xf9d330ad` | `ExecutionNotInCurrentBlock` | `lastVerifiedBlock` (L1, per rollup) or `lastLoadBlock` (L2) ≠ current block. The runner's `execute_same_block` wrapper must mine table + trigger together — don't roll blocks inside `Execute`/`ExecuteL2`. |
| `0xfa3021e5` | `AllImmediateL2TxsFailed` | Every immediate L2Tx entry reverted inside `postAndVerifyBatch` — usually a `RollingHashMismatch` inside the entry (check the inner revert via `trace_failed_txs` / `cast run`). |
| `0xa296e78c` | `ImmediateCountStrandsLeadingL2Tx` | A leading zero-hash entry was left out of `immediateEntryCount` — use `immediateSingleRollupBatch`, which auto-counts it. |
| `0x29c3b7ee` | `NotSelf` | `executeInContextAndRevert` invoked by someone other than the manager itself (must be `address(this)` self-call). |

On failure, `bash script/e2e/shared/decode-block.sh --l1-block <N> ...` dumps the actual execution table for comparison with `forge script <SOL>:ComputeExpected`.

## Output directories

- `tmp/e2e-success/` — successful local runs
- `tmp/e2e-failures/` — raw forge output + diagnostics for failed local runs
- `tmp/e2e-network/` — per-scenario network-mode logs (`run/network-sequential.sh`)
