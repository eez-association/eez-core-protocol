# AGENTS.md

Sync Rollups implements synchronous cross-chain calls using prepared remote results:
L1 verifies batches; L2 replays tables supplied by its trusted system integration.
This is an early-stage protocol. Local replay, proof acceptance, and live settlement are distinct claims.

## Find your bearings

Read [README.md](README.md) for setup and [CLAUDE.md](CLAUDE.md) for architecture and naming.
Use implementation and regression tests to establish current behavior; flag disagreements with specs.

| Area | Where to work |
| --- | --- |
| L1 registry, roots, ETH accounting, batch verification and queues | `src/EEZ.sol` |
| L2 system-loaded tables and execution | `src/L2/EEZL2.sol` |
| Shared hashes, transient state and CREATE2 call proxies | `src/base/` |
| ABI, per-rollup policy and proof verifiers | `src/interfaces/`, `src/rollupContract/`, `src/proofSystems/` |
| Upgradeable manager proxies and deployment | `src/proxy/`, [deployment/README.md](deployment/README.md) |
| Solidity tests and shared fixtures | `test/`; `Base.t.sol`, `BaseL2.t.sol`, `IntegrationBase.t.sol`, `TestHashes.sol` |
| Blob codec, DSL, table generation and reconstruction | [script/blob/README.md](script/blob/README.md), `test/blob/`, `docs/blobs/` |
| E2E scenarios, runners and verifier | Under `script/e2e/`: `scenarios/`, `run/`, `lib/`, `tests/` |
| Transaction decoding and flow viewer | [trace-decoder/README.md](trace-decoder/README.md), `script/tools/` |

`src/periphery/` contains bridge/token/DeFi fixtures outside the core protocol audit scope.
For ancillary work, read the local README in `script/balancer/`, `experiments/uniswap-lab/`,
`jsBlobs/`, `jev-test/`, or `transient-storage-demo/`; they have separate workflows.

## Commands that matter

Run from the repository root. Use focused checks first, then the relevant broader suite.

```bash
forge build
FOUNDRY_ISOLATE=false forge test
FOUNDRY_ISOLATE=false forge test --match-path 'test/EEZ*.t.sol' -vvv
FOUNDRY_ISOLATE=false forge test --match-path 'test/blob/*.t.sol'
MAX_PARALLEL=1 bash script/e2e/run/local/parallel.sh counter counterL2
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s script/e2e/tests -v
npm --prefix trace-decoder test
```

- Keep `FOUNDRY_ISOLATE=false` scoped to unit/integration tests: transient-state fixtures
  need calls in one transaction. E2E execution and isolated gas benchmarks retain `--isolate`.
- The local E2E runner with no scenario arguments runs the default suite. Use
  `MAX_PARALLEL=1` for reproducibility, as CI does.
- Solidity is pinned to **0.8.34**, via IR, optimizer runs **1**; CI pins Foundry **v1.7.1**.
  EEZ is near EIP-170's 24,576-byte runtime limit. Follow the deployable-contract size
  guard in [.github/workflows/ci.yml](.github/workflows/ci.yml); script-only `BlobTranslator` exceeds it intentionally.
- Format changed Solidity files with `forge fmt <paths>`. Decoder dependencies install
  with `npm ci --prefix trace-decoder`.

## Protocol rules to preserve

- **Both sides matter.** Shared execution changes need review on EEZ and EEZL2.
  Keep interfaces, hash helpers, blob generator/stitcher, verifier, decoder ABI and relevant docs in sync.
  Preserve L1's absolute direction names and L2's incoming/outgoing names.
- **Consumption is block-bound.** L1 uses `lastVerifiedBlock`; L2 uses `lastLoadBlock`.
  L1 checks live roots; top-level L2 static rows pin `expectedEntryIndex`.
  Reusable mappings have active bounds: retained rows outside them must stay invisible.
- **Use existing hash builders.** Reuse `TestHashes`, E2E `RollingHashBuilder` and
  `ComputeExpectedBase`; do not invent inline folds. Entry seeds, static hashes and
  nested hashes differ; call indices are not folded. Check `USE_GAS_LEFT` before assuming zero gas.
- **Rollback is part of the model.** Ordinary reverts undo state, cursors, hash folds and
  logs; deliberate `revertNextNCalls` spans preserve hash evidence through `ContextResult`.
  Read [CAVEATS](docs/CAVEATS.md) and [CALL_PATTERN_LIMITS](docs/CALL_PATTERN_LIMITS.md)
  before changing retries: mutable candidate retry remains unimplemented.
- **Mocks do not prove remote truth.** `MockProofSystem` accepts by default; pin
  `setExpectedPublicInputsHash` when testing public inputs. Local E2Es also use permissive proofs.
  Prover/node obligations live in [INTEGRATION_BOUNDARIES](docs/INTEGRATION_BOUNDARIES.md).
- **Deployment identity matters.** EEZ rollup IDs differ from Ethereum chain IDs; L1's rollup ID is 0.
  Proxy bytecode changes alter CREATE2 addresses. Review storage layout and immutable configuration
  before upgrades; upgrade scripts do not establish storage compatibility.

For exact semantics, consult [CORE_PROTOCOL_SPEC](docs/CORE_PROTOCOL_SPEC.md),
[EXECUTION_ENTRY_SPEC](docs/EXECUTION_ENTRY_SPEC.md), [STATIC_ENTRY](docs/STATIC_ENTRY.md),
[MULTI_PROVER_SPEC](docs/MULTI_PROVER_SPEC.md) and [EVENTS](docs/EVENTS.md).

## E2E: derive the flow before the tables

Read [BUILD_AND_REVIEW_E2E_TESTS](script/e2e/BUILD_AND_REVIEW_E2E_TESTS.md) before authoring scenarios;
[the E2E README](script/e2e/README.md) covers execution and current verification limits.

- Draw the real trigger and call tree. An L2 user transaction maps to **one zero-hash L1 L2Tx entry**.
  A committed top-level mutable L1→L2 call maps to one L2 delivery. Nested calls stay inside
  their open frame; L1→L2 static/reverted/erased lookups get no delivery.
- Build both sides from shared `<Scenario>Actions` helpers. Every cached return/revert value
  needs a real producer. Never add a transaction just to manufacture expected final state.
- `ComputeExpected` exports enable verification: provide applicable tables and L1 replay steps,
  preserve repeated-call multiplicity, and explicitly export empty event lists for eventless sides.
  Verify exact results and persisted evidence; use `ABSENT_L2_HASHES` for expected nondelivery.
- Respect `E2E_EXCLUDE_FROM_ALL`: default/all runs omit marked scenarios; explicit names/categories
  can include them. A local pass does not establish live readiness.
  Keep the 22 call-pattern scenarios from PR #54 excluded until explicitly enabled.
- For requested network runs, use `script/e2e/run/network/staged.sh` with `chain.env` or `DEVNET_ENV`.
  Discover addresses via `eez_composerInfo` on `L1_FRONT`; resume from the saved run snapshot.
  RPC endpoints handle deployment/reads; fronts receive cross-chain triggers. Never expose keys or
  commit env files, wallet pools or run artifacts.

## Cross-chain trigger fees

Follow the [L1/L2 cross-chain quote, fallback and recovery rules](script/e2e/RPC.md#eez_quotefee).
Quote only cross-chain triggers; deployments and funding transfers use node fees.

## Composer status and settlement

See the [composer RPC reference](script/e2e/RPC.md) and
[how runs are correlated](script/e2e/README.md#how-l1-and-l2-runs-are-correlated).
A held trigger can have no receipt; `null` does not prove rejection. Settlement
queries take the source receipt's block hash, and correlation only locates
candidates: content verification remains required.

When present, verify `transactions.l1`, `transactions.l2[]` and
`transactions.postBatch` against receipts and content checks. L2-origin links
include the system table-loading transaction and the user trigger; `l1` is the
L1 execution/posting transaction. L1 lookups with no L2 delivery can report
`SourceCompleted` with an empty `l2[]`. `ownership.canonical` is an L1 inclusion
reference even for L2-origin settlement. Capture responses during the run;
`complete: true` does not replace independent verification.

## Finish cleanly

Check `git status` before editing and preserve unrelated work. Update affected documentation with
behavior changes. Report what changed, which checks actually ran, and any remaining verification gaps.
