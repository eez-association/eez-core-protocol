# Plan: Remaining Work

## Remaining

### 1. Full review of all e2e tests (`script/e2e/*`)
Not a re-run — a correctness/coherence review of each scenario: does it make sense for this
system (flatten execution model), is it internally coherent, and do its assertions actually
check what they should (no vacuous/tautological checks). Cover all 17 scenarios + the shared
harness (`E2EHelpers.sol`, `Verify.s.sol`, `ComputeExpectedBase.sol`, `run-local.sh`).

### 2. Decide: should an L2Tx entry (`proxyEntryHash == 0`) be allowed to set `success == false`?
Currently allowed and honored (`src/EEZ.sol:1106`), but no caller observes the revert and it unwinds
`_applyStateUpdates`, so `stateRoot` cannot advance. Queued path bricks: the revert rolls back the
`entryQueueIndex` advance, so `executeL2Txs(rid)` re-matches the same entry forever. Immediate path
just emits `L2TxSkipped` (and an all-`false` run trips `AllImmediateL2TxsFailed`).

To forbid: `if (entry.proxyEntryHash == bytes32(0) && !entry.success) revert L2TxCannotRevert();` in
the per-entry validation loop (`src/EEZ.sol:532`), plus a test — no coverage either way today.
