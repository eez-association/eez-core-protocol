# E2E harness — open items

Last updated 2026-09-03.

1. **Verify phase is RPC-bound, not CPU-bound**: 28 jobs take ~56 s at `VERIFY_PARALLEL=8` and
   ~108 s at 12 (each job runs 5–7 forge scripts, each forking the devnet RPC). Keep 8. To go
   faster, cut forge invocations per job (one script that runs the L1 settlement + calldata +
   L2 checks against a single fork) rather than adding parallelism.
2. **Delete wave mode** (`PREPARE_MODE=waves`: `presign_deploy_contract`, `deploy:<k>`,
   `.deploys-done`-on-exit-2, v1 finish path) once plan mode v2 has a few more full-suite runs
   behind it.
