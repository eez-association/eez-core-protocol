---
description: Generate an e2e test for a cross-chain scenario using the flatten execution model
allowed-tools: Read, Write, Edit, Bash
---

# Skill: create-e2e-test

Generate a new `script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol` that exercises the flatten execution model end-to-end (local anvils or configured devnet).

## The authoritative guide

**Read `script/e2e/BUILD_AND_REVIEW_E2E_TESTS.md` in full before writing anything.** It is the single source of truth for building and reviewing e2e scenarios: the frame-coherence invariant, why every scenario is two-sided, how to derive the tables from the real transaction, the file anatomy, the patterns (L1→L2, L2→L1, multi-call, static reads), the authoring rules / audit checklist, the cross-chain mapping checklist, and the gotchas. When anything below or in `rules/` disagrees with that document, the document wins; when the document disagrees with the code, the code wins.

Supplementary references (subordinate to the guide):

- `.claude/skills/create-e2e-test/rules/e2e-structure.md` — file/contract layout details, runner routing, the ComputeExpected output protocol, verifier contracts.
- `.claude/skills/create-e2e-test/rules/entry-construction.md` — entry-table construction conventions and the pattern index of living scenario references.
- `script/e2e/README.md` — setup and running (local/network modes, runners).
- `src/EEZ.sol`, `src/L2/EEZL2.sol`, `src/base/EEZBase.sol` — the on-chain ground truth for every hash computed off-chain; `script/e2e/shared/E2EHelpers.sol` mirrors them exactly (`crossChainCallHash*`, `RollingHashBuilder`, `expectedL1toL2Hash`). Always use the helpers — never hand-roll a keccak.

## Workflow

1. Read the guide (above), then the closest existing scenario as a template — pick it from the guide's living references or the pattern index in `rules/entry-construction.md`.
2. Design the tables on paper first, following the guide's "Deriving the tables from the real transaction": the trigger, every frame opening/closing, which entries live on which chain, every rolling-hash fold. Do not write Solidity until the tables are on paper.
3. Write the scenario following the guide's file anatomy and authoring rules (one shared `Actions` abstract, `Deploy*`/`Execute*`/`ComputeExpected` contracts, header ASCII call-flow schema).
4. Verify: `forge build` clean, then `bash script/e2e/run/local.sh <path to E2E<Name>.s.sol>` must be green (use unique `L1_PORT`/`L2_PORT` when other runs may be live). Diagnose failures with `script/e2e/shared/decode-block.sh` against `forge script <SOL>:ComputeExpected`, and the error table in `.claude/commands/run-e2e.md`.

## After the test passes

1. Add the scenario to the ordered list in `.claude/commands/run-e2e.md`.
2. If the scenario clarifies a new pattern, add it to the guide's living references (and, when useful, the pattern index in `rules/entry-construction.md`).
