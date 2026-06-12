# Integration Test Notes & Open Questions

Notes for `test/IntegrationTest.t.sol` (single-EVM L1+L2 integration suite). Both managers are
deployed in one EVM, so cross-chain effects that would normally settle asynchronously are
observable in the same transaction.

## Scenarios

Legend: `A` = CounterAndProxy on L1, `B` = Counter on L2, `C` = Counter on L1,
`D` = CounterAndProxy on L2, `X'` = CrossChainProxy for X (deployed on the other chain).

| # | Flow | Type | What it tests |
|---|------|------|---------------|
| 1 | Alice → A (→ B') → resolved | L1 deferred, simple | A calls B' on L1 → `EEZ.executeCrossChainCall` consumes a deferred entry (no `l2ToL1Calls[]`) and returns the pre-computed `returnData`. |
| 2 | Alice → D (→ C') → resolved | L2 deferred, simple | Reverse of 1: D calls C' on L2 → `EEZL2.executeCrossChainCall` consumes a table entry (no `incomingCalls[]`). |
| 3 | Alice → A' (→ A → B') → resolved | L2 entry + calls, nested | L2 entry's `incomingCalls[0]` drives `A.incrementProxy()` via A'; inside it, A calls B', which crosses into `EEZ.executeCrossChainCall` and consumes a separate L1 deferred entry (a different manager — NOT an `expectedOutgoingCalls` slot). |
| 4 | Alice → D' (→ D → C') → resolved | L1 entry + calls, nested | Mirror of 3: L1 entry's `l2ToL1Calls[0]` drives `D.incrementProxy()`; D calls C', consuming a separate L2 table entry. |

## Design notes

- **Cross-manager calls are separate entries.** When an inner call targets the *other* manager
  (Scenarios 3/4), it consumes that manager's own entry — the reentrant tables
  (`expectedL1ToL2Calls` / `expectedOutgoingCalls`) only serve reentry into the SAME manager.
- **Sequential state deltas (L1).** Entries consuming the same rollup must chain
  `currentState → newState`; `StateDelta.currentState` is checked against the live
  `rollups[rid].stateRoot` at consumption (`StateRootMismatch` otherwise).
- **Same-block consumption.** Deferred entries are only consumable in the block their batch was
  posted (`lastVerifiedBlock` gate on L1, `lastLoadBlock` on L2) — tests post and consume in
  the same block.
- **Proxy reentrancy is safe.** A proxy can be entered twice in one transaction (caller's
  `fallback()` then the manager's `executeOnBehalf()`): `CrossChainProxy` holds only immutable
  fields, and the two entry points are independent.

## Open questions / future work

1. **ETH value transfers**: scenarios with non-zero `value`, `etherDelta` accounting in state
   deltas, and negative deltas (rollup sends ETH out). (`IntegrationTestBridge` covers some
   value flow; the delta-accounting matrix is not systematic.)
2. **Deeper nesting**: 3+ levels of same-manager reentry and multiple sibling reentrant calls
   (partial coverage exists in `script/e2e/deepNested/`).
3. **Multiple rollups**: cross-chain calls spanning 3+ rollups with interleaved per-rollup
   queues (unit-level coverage exists in `test/EEZ.t.sol`; no integration scenario).
4. **Many-entry batches**: batches mixing immediate (`proxyEntryHash == 0`) and deferred
   entries at scale.
