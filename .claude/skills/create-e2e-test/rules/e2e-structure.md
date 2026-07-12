# E2E File Structure (flatten model)

Authoritative layout rules for every `script/e2e/<category>/<direction>/<scenario>/E2E<Name>.s.sol`.

## Single file, multiple contracts

All test logic lives in one `.sol` file. The runner (`run-local.sh` / `run-network.sh`) discovers contracts by name and routes them to the right chain.

Contract order inside the file (top to bottom):

```
// 1. Shared constants + Actions base (abstract)
abstract contract FooActions {
    function _someAction(...) internal pure returns (Action memory) { ... }
    function _l1Entries(...) internal pure returns (ExecutionEntry[] memory) { ... }
    function _l2Entries(...) internal pure returns (ExecutionEntry[] memory) { ... }
    function _expectedRollingHash(...) internal pure returns (bytes32) { ... }
}

// 2. Batcher (L1-starting) or inline broadcasts (L2-starting)
contract Batcher { ... }

// 3. Deploy contracts (order determines execution order)
contract DeployL2 is Script { ... }   // runs on L2 RPC (name contains "L2")
contract Deploy is Script { ... }     // runs on L1 RPC (default)
contract Deploy2 is Script { ... }    // later L1 phase

// 4. Execute (L1-side local mode)
contract Execute is Script, FooActions { ... }

// 5. ExecuteL2 (L2-side local mode) — omit if not needed
contract ExecuteL2 is Script, FooActions { ... }

// 6. ExecuteNetwork / ExecuteNetworkL2 (view-only, for network mode)
contract ExecuteNetwork is Script { ... }
contract ExecuteNetworkL2 is Script { ... }

// 7. ComputeExpected (view-only, for verification)
contract ComputeExpected is ComputeExpectedBase, FooActions { ... }
```

## Chain routing convention

The runner classifies each `Deploy*` contract by name:
- Name contains `L2` → runs on `$L2_RPC`
- Otherwise → runs on `$L1_RPC`

Only contracts starting with the prefix `Deploy` are auto-discovered. Put the L1-first deploy as `Deploy`, the L2-first deploy as `DeployL2`, and any later phases as `Deploy2`, `Deploy2L2` etc.

Execute/ExecuteL2/ExecuteNetwork/ExecuteNetworkL2/ComputeExpected are invoked by **exact name** — don't vary them.

## Deploy order by test direction

- **L1-starting test** (user calls a proxy on L1): `DeployL2` first (to get L2 addresses referenced by L1 proxies), then `Deploy` on L1. If a post-L1 step needs the L1-created proxy as an L2 param, add `DeployL2B` after `Deploy`.
- **L2-starting test** (user calls a proxy on L2): same pattern but usually `Deploy` on L1 first (to get L1 destination addresses), then `DeployL2` to create L2 proxies + user contracts.
- **Mutual / complex**: keep the strict dependency order and split into `Deploy`, `DeployL2`, `Deploy2`, `Deploy2L2` etc. Name them in the order they must run.

## Imports

Always import the flatten types via their fully-qualified struct names:

```solidity
import {
    Action,
    StateDelta,
    CrossChainCall,
    NestedAction,
    ExecutionEntry,
    StaticCall
} from "../../../src/IEEZ.sol";
```

Plus helpers:

```solidity
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, noNestedActions, noCalls, RollingHashBuilder} from "../shared/E2EHelpers.sol";
```

Mocks from `test/mocks/` (CounterContracts.sol, MultiCallContracts.sol, ReentrantCounter.sol, helloword.sol) can be reused directly.

## Env var conventions

Every `Deploy*` contract emits its outputs as `KEY=VALUE` lines via `console.log`. The runner grep-extracts them and re-exports as env vars for later contracts. Screaming-snake-case, with a chain suffix when an address exists on a specific chain:

- `ROLLUPS`, `MANAGER_L2`, `VERIFIER` — infrastructure (from `DeployInfra.s.sol`)
- `COUNTER_L1`, `COUNTER_L2` — same contract, different chain
- `COUNTER_PROXY`, `COUNTER_PROXY_L2` — proxies: address on L1 / L2 respectively
- `COUNTER_AND_PROXY`, `COUNTER_AND_PROXY_L2` — same
- `CALL_TWICE`, `CALL_TWO_DIFF` — unique contracts
- `CAP_L2_PROXY` — "CounterAndProxy's L2-facing proxy (lives on L1)"
- `RLP_ENCODED_TX` — pre-signed raw tx set by the runner for L2-starting tests

## Verification contracts (invoked by `run-network.sh`)

The network-mode runner automatically runs three verify contracts (defined in `script/e2e/shared/Verify.s.sol`):

- `VerifyL1Batch` — checks `BatchPosted` logs in the L1 block include all expected entry hashes (subset match).
- `VerifyL2Blocks` — checks `ExecutionTableLoaded` logs in the L2 block(s) include all expected entry hashes.
- `VerifyL2Calls` — checks `CrossChainCallExecuted` logs include all expected action hashes.
- `VerifyL2Absent` — negative check: ensures specific entry hashes are NOT present (used by revert-terminal scenarios).

Entry hash is `keccak256(abi.encode(actionHash, rollingHash))` — both fields are stable identifiers in the flatten model. `_entryHash(entry)` on `ComputeExpectedBase` computes this.

## When to skip ExecuteL2

Omit the `ExecuteL2` contract entirely when the scenario only exercises L1. The simplest L1→L2 precomputed-return case (`counter`) needs **no** L2 execution — the L2 rollup state is updated purely via `StateDelta.newState`. The runner skips the L2 execute step when the contract is absent.

Mirror rule: omit `Execute` when the scenario is L2-only (`counterL2`).

## Events emitted by the flatten runtime

Know these event signatures — `Verify.s.sol` decodes them, `DecodeExecutions.s.sol` formats them:

- `Rollups.BatchPosted(ExecutionEntry[] entries, bytes32 publicInputsHash)` — flatten ABI.
- `EEZL2.ExecutionTableLoaded(ExecutionEntry[] entries)` — flatten ABI.
- `ExecutionConsumed(bytes32 indexed actionHash, uint256 indexed entryIndex)` — fired per entry consumption.
- `CrossChainCallExecuted(bytes32 indexed actionHash, address indexed proxy, address sourceAddress, bytes callData, uint256 value)` — fired on every proxy→manager hop.
- `CallResult(uint256 indexed entryIndex, uint256 indexed callNumber, bool success, bytes returnData)` — one per call in `_processNCalls`.
- `NestedActionConsumed(uint256 indexed entryIndex, uint256 indexed nestedNumber, bytes32 actionHash, uint256 callCount)` — one per `_consumeNestedAction`.
- `EntryExecuted(uint256 indexed entryIndex, bytes32 rollingHash, uint256 callsProcessed, uint256 nestedActionsConsumed)` — the atomic completion marker.
- `RevertSpanExecuted(uint256 indexed entryIndex, uint256 startCallNumber, uint256 span)` — one per `revertSpan` block.
- `L2TXExecuted(uint256 indexed entryIndex)` — L1 only, when `executeL2TX()` consumes an `actionHash == 0` entry.

## Same-block requirement

Both managers refuse consumption in a later block than the one where their table was installed:
- L1: `lastStateUpdateBlock != block.number` → `ExecutionNotInCurrentBlock`
- L2: `lastLoadBlock != block.number` → `ExecutionNotInCurrentBlock`

Local mode satisfies this via:
- L1: a `Batcher` contract that calls `postBatch(...)` and the triggering user action in **one** transaction.
- L2: `execute_l2_same_block` in `E2EBase.sh` disables automine, queues the `loadExecutionTable` broadcast + the user broadcast, then mines a single block containing both.

Network mode satisfies it by the sequencer intercepting the user tx from the mempool and inserting `postBatch` in the same block before the user tx.

If a test needs to trigger multiple actions that each consume entries, a single `Batcher` call is usually the cleanest way to keep them in the same block.
