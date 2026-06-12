# Plan: Remaining Work

## Remaining

### 1. Full review of all e2e tests (`script/e2e/*`)
Not a re-run — a correctness/coherence review of each scenario: does it make sense for this
system (flatten execution model), is it internally coherent, and do its assertions actually
check what they should (no vacuous/tautological checks). Cover all 17 scenarios + the shared
harness (`E2EHelpers.sol`, `Verify.s.sol`, `ComputeExpectedBase.sol`, `run-local.sh`).

### 2. Design questions 
- Separate pure-L2 batches from cross-chain batches.
- Cleaner on-chain encoding of execution entries in `postAndVerifyBatch`.
