# E2E harness — open items

Last updated 2026-09-03.

1. **Delete wave mode** (`PREPARE_MODE=waves`: `presign_deploy_contract`, `deploy:<k>`,
   `.deploys-done`-on-exit-2) once plan mode has a few more full-suite runs behind it (so far one
   clean 28-job run: prepare 57 s, 25/28 — `counter-multi-tx` composer split is the known
   single-batch verifier limitation; the other two scenarios were fixed and re-passed).
