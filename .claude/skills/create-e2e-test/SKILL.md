---
description: Generate an e2e test for a cross-chain scenario using the flatten execution model
allowed-tools: Read, Write, Edit, Bash
---

# Skill: create-e2e-test

Generate a new `script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol` that exercises the flatten execution model end-to-end (local anvils or configured devnet).

## Before writing anything

1. Load the two rules files into context — they are authoritative:
   - `.claude/skills/create-e2e-test/rules/e2e-structure.md` — file/contract layout, runner contract, output protocol
   - `.claude/skills/create-e2e-test/rules/entry-construction.md` — how to build the entry tables (and which docs/specs own each formula)
2. Read the closest existing test as a template — use the pattern index at the end of `rules/entry-construction.md` to pick it.
3. Read `src/EEZ.sol` and `src/L2/EEZL2.sol` — the on-chain bookkeeping is the ground truth for every hash you compute off-chain. `computeCrossChainCallHash`, `_processNCalls`, `_consumeNestedCall`, and the rolling-hash folds in `src/base/EEZBase.sol` are mirrored exactly by `script/e2e/shared/E2EHelpers.sol` — always use those helpers.

## Design the tables on paper first

Before any code, list:

- **Trigger source** — who/what starts the chain? A proxy call on L1? An L2 user tx? (The actual caller address is part of every hash; script-made triggers come from the broadcaster EOA in both modes.)
- **On which chain** each `ExecutionEntry` lives (L1 via `postAndVerifyBatch`, L2 via `loadExecutionTable` / `executeIncomingCrossChainCall`).
- For each entry (current struct fields — see `src/interfaces/IEEZ.sol` / `IEEZL2.sol`):
  - `proxyEntryHash` — the cross-chain call hash that triggers its consumption; `bytes32(0)` = system-driven L2Tx entry (L1 only, leading run must be immediate).
  - `stateUpdates[]` — L1 entries only (≥1; placeholder roots; every touched rollup in the set). L2 entries have none.
  - `l2ToL1Calls[]` / `incomingCalls[]` — the entry's TOP-LEVEL calls; each reentrant frame carries its own sub-array.
  - `expectedL1ToL2Calls[]` / `expectedOutgoingCalls[]` — the unified reentrant table, content-addressed by `expectedL1toL2Hash(ccHash, rollingHashAtFire)`.
  - `success` + `returnData` — `success: false` means the entry runs, verifies, then reverts with `returnData`.
  - `rollingHash` — final expected tagged tape; build with `RollingHashBuilder` in exactly the order the on-chain loop folds.

Do not start writing Solidity until the tables are on paper. Rolling-hash mismatches waste far more time than this planning step.

## File/contract layout

Strictly follow `rules/e2e-structure.md`. Contracts appear in this order inside the `.s.sol`:

1. **Actions base (abstract)** — single source of truth: action-hash helpers, rolling-hash replay, `_l1Entries(...)` / `_l2Entries(...)`.
2. **Deploy contracts** — in dependency order. Contracts named `Deploy…L2` get the L2 RPC, rest get L1. Each prints `KEY=VALUE` lines that the runner re-exports as env vars.
3. **Execute** — L1-side local-mode driver: `postAndVerifyBatch(immediateSingleRollupBatch(...))` then the user trigger, as plain top-level broadcast calls. The runner mines them in one block (`execute_l1_same_block`), so no helper contract is needed and the caller is always the broadcaster EOA.
4. **ExecuteL2** — L2-side local-mode driver (`loadExecutionTable` / `executeIncomingCrossChainCall` + trigger, mined together by `execute_l2_same_block`). Omit entirely if the test only needs L1.
5. **ExecuteNetwork / ExecuteNetworkL2** — view-only, outputs `TARGET`, `VALUE`, `CALLDATA` for the network-mode runner to broadcast.
6. **ComputeExpected** — prints the full machine-parsed output protocol (`EXPECTED_L1_[CALL_]HASHES`, `EXPECTED_L2_[CALL_]HASHES`, the `EXPECTED_*_TABLE` blobs, optional `ABSENT_L2_HASHES`) plus a human-readable table — see `rules/e2e-structure.md`. These lines drive ALL verification; a missing one silently downgrades checks.

## Env var naming conventions

Screaming-snake-case. Common names:
`ROLLUPS`, `MANAGER_L2`, `COUNTER_L1`, `COUNTER_L2`, `COUNTER_PROXY`, `COUNTER_AND_PROXY`, `COUNTER_PROXY_L2`, `COUNTER_AND_PROXY_L2`, `BRIDGE_SENDER`, `HELLO_WORLD_L1`, `HELLO_WORLD_L2`, `CALL_TWICE`, `CALL_TWO_DIFF`, `PROXY_A`, `PROXY_B`, `CAP_L2_PROXY`, `RLP_ENCODED_TX`.

When adding new contracts, pick a consistent noun + chain suffix (`_L1`, `_L2`) and reuse across `Deploy`, `Execute`, `ExecuteNetwork`, `ComputeExpected`.

## Verification loop

1. `forge build` must be clean before running any shell.
2. `bash script/e2e/run/local.sh script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol` must pass. On failure, the runner dumps the full forge script output and traces failed txs.
3. Only after local passes, try `bash script/e2e/run/network-sequential.sh <scenario>` against the devnet (reads endpoints/key from `chain.env`; `run/network.sh` needs the full `--l1-rpc … --pk …` flag set — see `script/e2e/README.md`). Network mode uncovers ordering/same-block issues that local mode hides with its same-block wrapper.
4. Compare `forge script <SOL>:ComputeExpected` output against `decode-block.sh` output — any divergence is a bug in the precomputation.

## Common pitfalls (flatten-specific)

- **Rolling-hash drift** — `RollingHashMismatch` is the most common failure. Replay the tagged sequence exactly: CALL_BEGIN(ccHash) → (any NESTED pairs for committing reentrant frames during this call) → CALL_END(success, retData). `retData` comes from the raw `destination.call` return, which is *empty* for functions that return nothing. No call/frame index is ever folded.
- **Call-hash encoding** — use `crossChainCallHash(isStatic, source, sourceRollupId, target, targetRollupId, value, data)` from `E2EHelpers.sol` (callGas folds 0); never hand-roll. Wrong `sourceAddress` (the proxy instead of the original caller, or an intermediate contract instead of the EOA) is the classic mistake.
- **L1-side caller identity** — script-made L1 triggers come from the broadcaster EOA (same in local and network mode): `Execute` builds entries with `msg.sender` inside `vm.startBroadcast()`, and `ComputeExpected` uses `msg.sender` (the runners pass `--sender`).
- **Reverting reentrants** — a reverting reentrant call is a `success: false` row in the unified table (run against `revertedOrStaticRollingHash`, then reverted); a forced rollback of successful calls is `revertNextNCalls = N`; a naturally-reverting plain sub-call just folds `CALL_END(false, retData)`. See the case table in `CLAUDE.md`.
- **Same-block requirement** — `postAndVerifyBatch` / `loadExecutionTable` and the triggering user tx MUST land in the same block. Local mode runs `Execute` and `ExecuteL2` under the `execute_same_block` wrapper (automine off, `--isolate`, one mined block); network mode relies on the composer bundling the intercepted trigger.
- **Leading zero-hash entries must be immediate** — `ImmediateCountStrandsLeadingL2Tx`; use `immediateSingleRollupBatch`, which auto-counts them.
- **Proxy creation** — use `getOrCreateProxy` (compute-first) in `Deploy*`; try/create/catch records creates that collide on-chain replay.

## After the test passes

1. Add the scenario to the ordered list in `.claude/commands/run-e2e.md`.
2. If the scenario is new enough that it clarifies a pattern, add a one-line reference in `rules/entry-construction.md` under the matching pattern header.
