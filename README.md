# Sync Rollups

Smart contracts to manage synchronous rollups on Ethereum.

> EARLY-STAGE IMPLEMENTATION — not audited; interfaces and storage layout still in flux.

## Overview

Sync Rollups enables synchronous composability between based rollups sharing the same L1 sequencer. State transitions are pre-computed off-chain and verified on-chain by a configurable set of proof systems, enabling atomic cross-rollup calls (e.g. cross-rollup flash loans) within a single L1 block.

Two sides:

- **`src/EEZ.sol`** (L1) — registry + execution manager: per-rollup state roots and ETH accounting, multi-prover batch verification (`postAndVerifyBatch`), per-rollup execution queues, flat sequential call execution with rolling-hash integrity.
- **`src/L2/EEZL2.sol`** (L2) — executes system-loaded execution tables; no proofs, no registry.

Shared machinery lives in `src/base/` (`EEZBase.sol`, `CrossChainProxy.sol`); per-side execution structs in `src/interfaces/` (`IEEZ.sol` for L1, `IEEZL2.sol` for L2); the per-rollup manager reference implementation in `src/rollupContract/Rollup.sol`. Tests are under `test/`, two-sided e2e devnet scenarios under `script/e2e/`, protocol documentation under `docs/`.

## Build & Test

```bash
forge build          # Compile contracts
forge test           # Run all tests
forge fmt            # Format code
```

## Documentation

Start with [`CLAUDE.md`](CLAUDE.md) — a condensed architecture reference (contracts, data types, key functions, execution flow, naming conventions). For depth:

- [`docs/CORE_PROTOCOL_SPEC.md`](docs/CORE_PROTOCOL_SPEC.md) — formal protocol specification
- [`docs/EXECUTION_ENTRY_SPEC.md`](docs/EXECUTION_ENTRY_SPEC.md) — how to build execution entries
- [`docs/LOOKUP_SPEC.md`](docs/LOOKUP_SPEC.md) — lookup semantics (nested + top-level)
- [`docs/MULTI_PROVER_SPEC.md`](docs/MULTI_PROVER_SPEC.md) — multi-prover design rationale
- [`docs/CAVEATS.md`](docs/CAVEATS.md) — edge cases
