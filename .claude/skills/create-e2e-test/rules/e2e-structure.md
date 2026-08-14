# E2E File Structure (flatten model)

Authoritative layout rules for every `script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol`.

Categories: `one_way`, `multi_call`, `multi_tx` (one user tx per consumption; network mode
fires all triggers without waiting via an `NUM_TXS=N` ExecuteNetwork output — the runner
pre-signs N copies with consecutive nonces), `nested`, `reentrant`, `revert`. Directions:
`L1_to_L2` (trigger on L1) / `L2_to_L1` (trigger on L2). **File names are unique per
scenario on purpose** — identically named scripts share one `out/` artifact bucket and
forge can silently pick another scenario's contracts. Contract names inside stay
generic (`Deploy`, `Execute`, …); the file name disambiguates.

## Single file, multiple contracts

All test logic lives in one `.sol` file. The runners (`run/local.sh` / `run/network.sh`)
discover contracts by name and route them to the right chain.

Contract order inside the file (top to bottom):

```
// 1. Shared constants + Actions base (abstract) — single source of truth
abstract contract FooActions {
    function _callHash(...) internal pure returns (bytes32) { ... }
    function _l1Entries(...) internal pure returns (ExecutionEntry[] memory) { ... }
    function _l2Entries(...) internal pure returns (L2ExecutionEntry[] memory) { ... }
}

// 2. Mocks (if scenario-specific) — prefer reusing test/mocks/

// 3. Deploy contracts (order determines execution order)
contract Deploy is Script { ... }     // runs on L1 RPC (default)
contract DeployL2 is Script { ... }   // runs on L2 RPC (name contains "L2")

// 4. ExecuteL2 (L2-side local driver) / Execute (L1-side local driver).
//    Execute posts postAndVerifyBatch(immediateSingleRollupBatch(...)) then makes the
//    user trigger, as top-level broadcast calls — the runner mines them in one block
//    (execute_l1_same_block), so every trigger comes from the broadcaster EOA.
contract ExecuteL2 is Script, FooActions { ... }
contract Execute is Script, FooActions { ... }

// 5. ExecuteNetwork OR ExecuteNetworkL2 (view-only tx-shape oracle; the "L2" name
//    is the direction switch the runners grep for)
contract ExecuteNetwork is Script { ... }

// 6. ComputeExpected (view-only, drives ALL verification)
contract ComputeExpected is ComputeExpectedBase, FooActions { ... }
```

## Chain routing convention

- `Deploy*` contracts are auto-discovered in file order; a name containing `L2` runs
  on `$L2_RPC`, otherwise `$L1_RPC`. Later phases: `Deploy2`, `Deploy2L2`, …
- `Execute`, `ExecuteL2`, `ExecuteNetwork`, `ExecuteNetworkL2`, `ComputeExpected` are
  invoked by **exact name** — don't vary them.
- Direction auto-detect: the presence of `contract ExecuteNetworkL2 ` makes the
  runners treat the scenario as L2-starting.
- Local execution order is fixed: ExecuteL2 first (same-block wrapper), then Execute.
  Omit one only for genuinely one-sided scenarios — every current scenario is
  two-sided (both `Execute` and `ExecuteL2`).

## Imports

Import struct types from the real interfaces (5 levels up from the scenario dir):

```solidity
import {StateUpdate, L2ToL1Call, ExpectedL1ToL2Call, ExecutionEntry, StaticExecutionEntry}
    from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash, crossChainCallHashL2Out, getOrCreateProxy,
    noStaticEntries, noNestedActions, noCalls, noL2Calls, noL2OutgoingCalls,
    noL2StaticEntries, immediateSingleRollupBatch, RollingHashBuilder, expectedL1toL2Hash
} from "../../../shared/E2EHelpers.sol";
```

Mocks from `test/mocks/` (CounterContracts.sol, MultiCallContracts.sol,
ReentrantCounter.sol) can be reused directly.

## Env var conventions

Every `Deploy*`/`Execute` contract emits outputs as `KEY=VALUE` `console.log` lines;
the runner re-exports them as env vars for later contracts (`_export_outputs`).
Screaming-snake-case with a chain suffix: `COUNTER_L1`, `COUNTER_PROXY_L2`,
`CALL_TWICE_L2`, … Infrastructure vars come from `DeployInfra.s.sol`: `ROLLUPS`,
`PROOF_SYSTEM`, `MANAGER_L2`, `L2_ROLLUP_ID`. `RLP_ENCODED_TX` is the pre-signed
trigger tx set by the runner.

## ComputeExpected output protocol

Machine-parsed lines (the runners route verification on their presence):

- `EXPECTED_L1_CALL_HASHES=[…]` — non-zero L1 `proxyEntryHash` keys (`_printL1CallHashes(l1)`).
  Absence routes L1 verification to the zero-hash (EntryExecuted-based) verifier, so
  print it whenever any L1 entry is proxy-keyed.
- `EXPECTED_L1_HASHES=[…]` / `EXPECTED_L2_HASHES=[…]` — entry identities
  `keccak(proxyEntryHash, rollingHash)` via `_entryHash`.
- `EXPECTED_L2_CALL_HASHES=[…]` — always (`_printL2CallHashes(l2)`).
- `EXPECTED_L1_TABLE=0x…` / `EXPECTED_L2_TABLE=0x…` — abi-encoded entry arrays
  (`_printL1Table` / `_printL2Table`); these switch ON all field-level checks.
- `ABSENT_L2_HASHES=[…]` — terminal-revert scenarios only (entries that must NOT load).

## Verification contracts (`script/e2e/shared/Verify.s.sol`)

`[, table]` marks an optional trailing `bytes expectedTable` blob (empty = hash-only checks):

- `VerifyL1BatchInRange(from, to, rollups, callHashes[, table])` — `ExecutionConsumed`
  call hashes in [from..to] + field checks (EntryExecuted triple, routing, stateUpdates,
  live roots). A known settlement block is the `from == to` degenerate range
  (`verify_l1_batch` in `E2EBase.sh`).
- `VerifyL1ZeroHashEntriesInRange(from, to, rollups, entryHashes[, table])` — for
  system-driven entries (`proxyEntryHash == 0`): matches `keccak(0, rollingHash)` from
  `EntryExecuted` events.
- `VerifyL1SettlementTxsInRange(from, to, rollups)` — root-agnostic settlement
  discovery for zero-hash entries on a live devnet: lists every tx in range with an
  `EntryExecuted` on the registry (`L1_BATCH_TX_CANDIDATE` lines); the runner pins
  ours by posted-calldata content. Reverts while nothing has settled.
- `VerifyL1BatchCalldata(batchInput, rollups, table, steps)` — decodes the settlement
  tx's `postAndVerifyBatch` calldata and field-matches every expected entry (network
  mode). `table` is REQUIRED here; `steps` (may be empty) replays the recorded
  rolling-hash folds over the posted roots.
- `VerifyL2Blocks(blocks, managerL2, entryHashes[, table])` — `ExecutionTableLoaded`
  full-struct comparison + invariants.
- `VerifyL2Calls(blocks, managerL2, callHashes[, table])` — consumption events +
  incoming-call hash recompute.
- `VerifyL2CallsInRange(from, to, managerL2, callHashes)` — L2 sync-block discovery by
  content scan (no table; prints `L2_MATCH_BLOCKS`).
- `VerifyL2Absent(blocks, managerL2, absentHashes)` — negative check (no table).

Event signatures are declared once as `SIG_*` constants at the top of `Verify.s.sol` —
that file is the reference for what the runtime emits; don't restate them here.

## Same-block requirement

Entries are only consumable in the block their table landed (L1: `lastVerifiedBlock`
gate per rollup; L2: `lastLoadBlock` → `ExecutionNotInCurrentBlock`). Local mode
satisfies it symmetrically on both chains with the `execute_same_block` wrapper
(automine off → all of the Execute contract's broadcast txs → one mined block,
`--isolate`). Network mode relies on the composer bundling the intercepted trigger.
