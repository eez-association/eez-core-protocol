---
description: Generate an e2e test for a cross-chain scenario using the flatten execution model
allowed-tools: Read, Write, Edit, Bash
---

# Skill: create-e2e-test

Generate a new `script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol` that exercises the flatten execution model end-to-end (local anvils or configured devnet).

## Before writing anything

1. Load the two rules files into context — they are authoritative:
   - `.claude/skills/create-e2e-test/rules/e2e-structure.md` — file/contract layout
   - `.claude/skills/create-e2e-test/rules/entry-construction.md` — how to build `ExecutionEntry` / `StaticCall` / `NestedAction` / `CrossChainCall` in the flatten model
2. Read the closest existing test as a template. Good starting points:
   - Simple L1→L2 with precomputed return: `script/e2e/one_way/L1_to_L2/counter/E2ECounter.s.sol`
   - Simple L2→L1: `script/e2e/one_way/L2_to_L1/counterL2/E2ECounterL2.s.sol`
   - Value + ether delta: `script/e2e/one_way/L1_to_L2/bridge/E2EBridge.s.sol`
   - Same actionHash consumed twice: `script/e2e/multi_call/L1_to_L2/multi-call-twice/E2EMultiCallTwice.s.sol`
   - Different actionHashes consumed sequentially: `script/e2e/multi_call/L1_to_L2/multi-call-two-diff/E2EMultiCallTwoDiff.s.sol`
   - `calls[]` + `nestedActions[]` with rolling-hash replay: `script/e2e/nested/L1_to_L2/nestedCounter/E2ENestedCounter.s.sol`
3. Read `src/Rollups.sol` and `src/EEZL2.sol` — the on-chain bookkeeping is the ground truth for every hash you compute off-chain. `_computeActionInputHash`, `_processNCalls`, `_consumeNestedAction`, and the entry-hash formula in `_computeEntryHashes` should be mirrored exactly by your off-chain builders (use the helpers in `script/e2e/shared/E2EHelpers.sol`).

## Design the tables on paper first

Before any code, list:

- **Trigger source** — who/what starts the chain? A proxy call on L1? An L2 user tx? A batcher?
- **On which chain** each `ExecutionEntry` lives (L1 via `postBatch`, L2 via `loadExecutionTable`).
- For each entry:
  - `actionHash` — the action that will trigger its consumption. `bytes32(0)` means immediate (first entry only).
  - `stateDeltas[]` — L1 entries track rollup state + `etherDelta`. L2 entries must be `new StateDelta[](0)`.
  - `calls[]` — inline cross-chain calls run by the manager as part of entry consumption. Flat list; executed in order.
  - `nestedActions[]` — precomputed return values for reentrant `executeCrossChainCall` invocations that happen *during* `calls[]` processing. Consumed sequentially by index.
  - `callCount` — number of top-level `calls[]` iterations per trigger. Usually `calls.length`; smaller if a later revert span is triggered separately.
  - `returnData` — precomputed return data the proxy surfaces back to the caller.
  - `failed` — when true, after the entry commits, `_consumeAndExecute` replays `returnData` as a revert.
  - `rollingHash` — final expected tagged-hash tape. Compute using `RollingHashBuilder` in exactly the order the on-chain loop will produce.

Do not start writing Solidity until the tables are on paper. Rolling-hash mismatches waste far more time than this planning step.

## File/contract layout

Strictly follow `rules/e2e-structure.md`. Contracts appear in this order inside the `.s.sol`:

1. **Actions base (abstract)** — single source of truth: action-hash helpers, rolling-hash replay, `_l1Entries(...)` / `_l2Entries(...)`.
2. **Batcher** — L1-starting: `postBatch` + user action in one tx. L2-starting: if needed, the `loadExecutionTable` broadcast runs alongside the user tx under `execute_l2_same_block`.
3. **Deploy contracts** — in dependency order. Contracts named `Deploy…L2` get the L2 RPC, rest get L1. Each prints `KEY=VALUE` lines that the runner re-exports as env vars.
4. **Execute** — L1-side local-mode driver.
5. **ExecuteL2** — L2-side local-mode driver. Omit entirely if the test only needs L1.
6. **ExecuteNetwork / ExecuteNetworkL2** — view-only, outputs `TARGET`, `VALUE`, `CALLDATA` for the network-mode runner to broadcast.
7. **ComputeExpected** — prints `EXPECTED_L1_HASHES=[…]`, `EXPECTED_L2_HASHES=[…]`, optional `EXPECTED_L2_CALL_HASHES=[…]`, plus a human-readable table.

## Env var naming conventions

Screaming-snake-case. Common names:
`ROLLUPS`, `MANAGER_L2`, `COUNTER_L1`, `COUNTER_L2`, `COUNTER_PROXY`, `COUNTER_AND_PROXY`, `COUNTER_PROXY_L2`, `COUNTER_AND_PROXY_L2`, `BRIDGE_SENDER`, `HELLO_WORLD_L1`, `HELLO_WORLD_L2`, `CALL_TWICE`, `CALL_TWO_DIFF`, `PROXY_A`, `PROXY_B`, `CAP_L2_PROXY`, `RLP_ENCODED_TX`.

When adding new contracts, pick a consistent noun + chain suffix (`_L1`, `_L2`) and reuse across `Deploy`, `Execute`, `ExecuteNetwork`, `ComputeExpected`.

## Verification loop

1. `forge build` must be clean before running any shell.
2. `bash script/e2e/shared/run-local.sh script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol` must pass. On failure, the runner dumps the full forge script output and traces failed txs.
3. Only after local passes, try `bash script/e2e/shared/run-network.sh script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol` against the devnet. Network mode uncovers ordering/same-block issues that local mode hides with its same-block wrapper.
4. Compare `forge script <SOL>:ComputeExpected` output against `decode-block.sh` output — any divergence is a bug in the precomputation.

## Common pitfalls (flatten-specific)

- **Rolling-hash drift** — `RollingHashMismatch` is the most common failure. Replay the tagged sequence exactly: CALL_BEGIN(n) → (any NESTED pairs for reentrant calls that happen during this call) → CALL_END(n, success, retData). Don't forget `retData` for CALL_END comes from the raw `destination.call` return, which is *empty* for functions that return nothing.
- **`actionHash` encoding** — `keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup))`. Missing one field or getting `sourceRollup` vs `rollupId` mixed up breaks the match. Use `actionHash(Action{...})` from `E2EHelpers.sol` instead of hand-rolling.
- **Empty `stateDeltas` on L2** — L2 entries must have `new StateDelta[](0)`. Only the L1 manager tracks rollup state.
- **`callCount` vs `calls.length`** — they match for normal entries. A non-zero `revertSpan` on one of the calls doesn't change `callCount`; it just groups how many calls execute in the isolated context.
- **Reentrant calls must succeed** — a revert inside a nested action would roll back the `_lastNestedActionConsumed++` and corrupt verification. Use `StaticCall[]` for calls that revert, or wrap them in a `revertSpan`.
- **Same-block requirement** — `postBatch` / `loadExecutionTable` and the triggering user tx MUST land in the same block. Local mode uses `execute_l2_same_block` and `Batcher`; network mode relies on the sequencer intercepting the user tx and sandwiching `postBatch` in the same block.
- **Proxy auto-creation** — `_processNCalls` auto-creates the source proxy via CREATE2 on first use if missing. That silent behavior hides deploy-order bugs; prefer explicit `createCrossChainProxy` or `getOrCreateProxy` in `Deploy*`.
- **`failed: true` entries block the table** — a failed entry reverts *after* `executionIndex++`, which rolls back the increment, so the entry is never consumed. Don't use `failed: true` on entries that aren't the last one to be triggered. For recoverable failures, use `StaticCall` + `staticCallLookup` (the proxy's static-context detection routes to it automatically).

## After the test passes

1. Add the scenario to the ordered list in `.claude/commands/run-e2e.md`.
2. If the scenario is new enough that it clarifies a pattern, add a one-line reference in `rules/entry-construction.md` under the matching pattern header.
