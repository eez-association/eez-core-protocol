# Entry Construction (flatten model)

How to build the execution tables an e2e scenario feeds to both chains. This file
covers the e2e-specific conventions only — the protocol itself is owned elsewhere,
and those owners win whenever this file disagrees:

- **Struct shapes**: `src/interfaces/IEEZ.sol` (L1) and `src/interfaces/IEEZL2.sol` (L2).
  Import from there; never re-declare.
- **Hash formulas + rolling-hash schema**: `docs/CORE_PROTOCOL_SPEC.md` §C.5 and §E;
  the off-chain mirror is `script/e2e/shared/E2EHelpers.sol` (`crossChainCallHash`,
  `crossChainCallHashL2Out`, `crossChainCallHashStatic`, `RollingHashBuilder`,
  `expectedL1toL2Hash`). Always use the helpers — never hand-roll a keccak.
- **Entry semantics** (consumption, forward-scan, immediate vs deferred, revert cases):
  `docs/EXECUTION_ENTRY_SPEC.md`, `docs/STATIC_ENTRY.md`, `docs/CAVEATS.md`, and the
  "Success vs failure — where each case lives" table in `CLAUDE.md`.

## The Actions mixin is the single source of truth

Every scenario defines one `abstract contract <Name>Actions` exposing `_l1Entries(...)`
and `_l2Entries(...)` (plus the call-hash helpers), parameterized by address. `Execute`,
`ExecuteL2` (or their Batcher), and `ComputeExpected` all inherit it — the entries that
execute and the entries that are verified must come from the same code. Never duplicate
an entry literal.

## Call identity

One logical cross-chain call has ONE hash preimage, computed on both sides:

```solidity
crossChainCallHash(isStatic, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, data)
// callGas folds 0 — all fixtures deploy EEZL2 with useGasLeft = false
```

- L1→L2 scenarios: both sides carry the same `proxyEntryHash = crossChainCallHash(...)`.
- L2→L1 scenarios: the L2 source entry's key is `crossChainCallHashL2Out(...)` (same
  digest under `useGasLeft = false`); the L1 destination entry is system-driven with
  `proxyEntryHash = bytes32(0)` and the inbound calls in `l2ToL1Calls[]`.
- The L1-side caller is whoever actually makes the user call ON L1. Locally that is
  usually the scenario's `Batcher` contract — `Execute` must print `BATCHER_L1=` and
  `ComputeExpected` must use `vm.envOr("BATCHER_L1", msg.sender)` for the L1-side
  source address (network mode falls back to the EOA). Getting this wrong shifts every
  L1 hash. See `deepNested` / `nestedCallRevert` for the pattern.

## Rolling hash

Build with `RollingHashBuilder`, replaying exactly what the contract folds:

- Seed: L1 `entryBegin(stateUpdates, proxyEntryHash)` (folds each `(rollupId,
  currentState)` then the key); L2 `entryBeginL2(proxyEntryHash)`.
- Then `appendCallBegin(rh, crossChainCallHash)` / `appendCallEnd(rh, success, retData)`
  per top-level call, `appendNestedBegin`/`appendNestedEnd` around committing reentrant
  frames, `appendStatic` for static sub-calls. No call/frame index is folded — ever.
- `retData` in `CALL_END` is the raw target returndata (empty for void functions).
- Reentrant table rows are keyed by `expectedL1toL2Hash(ccHash, rollingHashAtFirePoint)`
  — capture the running hash at the exact instant the reentry fires.

## State roots (L1 entries)

`StateUpdate.currentState`/`newState` are LOCAL PLACEHOLDERS in e2e tables
(`keccak256("l2-initial-state")` is what `DeployInfra` registers; pick a fresh
`keccak256("l2-state-after-<scenario>")` per scenario). The verifier never
equality-checks roots against chain data — only `rollupId` + `etherDelta` compare
exactly; roots are checked structurally (chain contiguity, movement, live settlement).
Every entry needs ≥1 `StateUpdate`, and every touched rollup (destination + every
call's `sourceRollupId`) must be in the update set (proxy protection, on-chain).

## Immediate vs deferred (L1)

A leading `proxyEntryHash == 0` run MUST be covered by `immediateEntryCount`
(`ImmediateCountStrandsLeadingL2Tx`) — use `immediateSingleRollupBatch` or the shared
`L2TXBatcher` from `E2EHelpers.sol`, which auto-count it. There is no "defer the
zero-hash entry and drain via `executeL2Txs`" pattern for leading L2Txs.

## ComputeExpected output contract

Machine-parsed lines the runners route on (see `rules/e2e-structure.md` for the full
protocol): print `EXPECTED_L1_CALL_HASHES` whenever any L1 entry is proxy-keyed
(`_printL1CallHashes(l1)`), `EXPECTED_L2_CALL_HASHES` always (`_printL2CallHashes(l2)`),
`EXPECTED_L1_HASHES`/`EXPECTED_L2_HASHES` (entry identities via `_entryHash`), and the
field-check blobs `_printL1Table(l1)` / `_printL2Table(l2)`. Omitting a line silently
downgrades verification — the runners print a NOTE when a table is missing; treat that
NOTE in a green run as a bug.

## Pattern index — living references

| Pattern | Scenario |
|---|---|
| Simplest L1→L2, precomputed return | `script/e2e/one_way/L1_to_L2/counter/E2ECounter.s.sol` |
| Simplest L2→L1 (zero-hash L1 entry) | `script/e2e/one_way/L2_to_L1/counterL2/E2ECounterL2.s.sol` |
| Value transfer + etherDelta | `script/e2e/one_way/L1_to_L2/bridge/E2EBridge.s.sol` |
| Same key consumed twice | `script/e2e/multi_call/L1_to_L2/multi-call-twice/E2EMultiCallTwice.s.sol` (mirror: `multi_call/L2_to_L1/multi-call-twiceL2`) |
| Different keys sequentially | `script/e2e/multi_call/L1_to_L2/multi-call-two-diff/E2EMultiCallTwoDiff.s.sol` (mirror: `multi_call/L2_to_L1/multi-call-two-diffL2`) |
| Reentrant frame (success row) | `script/e2e/nested/L1_to_L2/nestedCounter/E2ENestedCounter.s.sol` |
| Two nesting levels | `script/e2e/nested/L1_to_L2/deepNested/E2EDeepNested.s.sol` |
| Reverting reentrant row (`success: false`) | `script/e2e/revert/L1_to_L2/nestedCallRevert/E2ENestedCallRevert.s.sol` |
| Forced revert (`revertNextNCalls`) | `script/e2e/revert/L1_to_L2/revertCounter/E2ERevertCounter.s.sol` |
| try/catch over natural revert | `script/e2e/revert/L1_to_L2/revertContinue/E2ERevertContinue.s.sol` |
| Cascading multi-hop reentrancy | `script/e2e/reentrant/L1_to_L2/reentrant/E2EReentrant.s.sol` |
