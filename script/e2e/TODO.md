# E2E harness — open items

Last updated 2026-10-15.

1. **Consolidate verification around shared forks.** The linked path still forks
   separately for L1 calldata, L2 tables and L2 calls. Reuse each chain's fork within
   a job and measure the resulting gain; keep scenario assertions, split-batch
   coverage, absence checks and canonical revalidation. Keep `VERIFY_PARALLEL=8`:
   increasing concurrency has previously slowed RPC-bound runs.
