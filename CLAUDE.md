# L1/L2 Sync Smart Contracts

## Project Overview

This is a Foundry-based Solidity project implementing smart contracts for L1/L2 rollup synchronization. The system allows L2 executions to be verified and executed on L1 using ZK proofs, and on L2 via system-loaded execution tables.

EARLY-STAGE IMPLEMENTATION — not audited, interfaces and storage layout still in flux.

## Build & Test Commands

```bash
forge build          # Compile contracts
forge test           # Run all tests
forge test -vvv      # Run tests with verbose output
forge fmt            # Format code
```

## Architecture

### Core Contracts

- **EEZ.sol** (L1): Central registry and execution manager. Manages per-rollup state roots and ether balances, verifies multi-prover batches via `postAndVerifyBatch`, queues `ExecutionEntry`s into per-rollup queues, runs the `IMetaCrossChainReceiver` hook for in-tx consumption, and executes cross-chain calls with rolling-hash verification. Holds no per-rollup policy — that lives in each rollup's own manager contract.
- **base/EEZBase.sol**: Direction-neutral shared base for both managers. Rolling-hash tag constants and fold helpers, the `_rollingHash` accumulator, the `_currentEntryIndex` transient pointer, the `authorizedProxies` registry, CREATE2 proxy creation (`createCrossChainProxy`, `computeCrossChainProxyAddress`), `computeCrossChainCallHash`, `_computeExpectedL1toL2Hash`, and the `ContextResult` revert transport (`_decodeContextResult`).
- **L2/EEZL2.sol**: L2-side manager. No proofs, no rollup registry, no state deltas — a trusted `SYSTEM_ADDRESS` loads execution tables (`loadExecutionTable`) or drives an inbound call atomically (`executeIncomingCrossChainCall`); entries are consumed sequentially via proxy calls in the same block they were loaded.
- **interfaces/IEEZ.sol** + **interfaces/IEEZL2.sol**: Per-side execution structs (see Naming below). L1 structs carry state deltas and per-rollup routing; L2 structs are leaner.
- **rollupContract/Rollup.sol** + **interfaces/IRollup.sol** (`IRollupContract`): Per-rollup manager contract. Each rollup is owned by a pre-deployed contract conforming to `IRollupContract` (the reference `Rollup.sol` bakes in proof systems, vkeys, threshold, owner). The registry calls `rollupContractRegistered(rollupId)` once at registration, `checkProofSystemsAndGetVkeys(address[])` per batch (rejects unknown PS or fewer than threshold), and `getCustomData(blockNumber)` for block binding. The manager can call `EEZ.setStateRoot(rid, newRoot)` as an ops escape hatch.
- **interfaces/IProofSystem.sol**: `verify(bytes proof, bytes32 publicInputsHash) returns (bool)` — any external verifier.
- **interfaces/IMetaCrossChainReceiver.sol**: `executeMetaCrossChainTransactions()` callback fired on `postAndVerifyBatch`'s `msg.sender` (when it has code) so the sender can consume transient entries via cross-chain proxy calls in the same transaction.
- **base/CrossChainProxy.sol**: CREATE2 proxy per (address, rollupId) pair. Routes incoming calls to the manager via `executeCrossChainCall` (or `staticCrossChainCall` in static context, detected via a `tstore` self-call), and forwards manager-driven outbound calls via `executeOnBehalf`.

### Naming conventions

**Entry vs execution**: "entry" is the stored data (an `ExecutionEntry` / `StaticExecutionEntry` in a table or queue — `entryQueue`, `_transientEntries`, `staticEntryQueue`); "execute"/"execution" is the act of running one (`_executeEntry`, `_consumeAndExecuteEntry`, `_insideExecution()`, events/errors like `ExecutionConsumed` / `ExecutionNotFound` that describe the act requested at the call site). Same split on the static side: "static entry" is the data, "static call" is the act (`staticCrossChainCall`).

**Per-side direction**: the execution structs are split per side and named directionally:

- **L1 (IEEZ.sol)** uses absolute direction: `L2ToL1Call` / `l2ToL1Calls` (calls executed on L1), `ExpectedL1ToL2Call` / `expectedL1ToL2Calls` (pre-computed reentrant calls leaving L1), cursor `_lastL1ToL2CallConsumed`.
- **L2 (IEEZL2.sol)** uses self-relative direction (the counterparty may be L1 OR another L2, so absolute names would often be wrong): `CrossChainCall` / `incomingCalls` (calls executed on this L2 for remote callers), `ExpectedOutgoingCrossChainCall` / `expectedOutgoingCalls` (pre-computed reentrant calls leaving this L2), cursor `_lastOutgoingCallConsumed`.

The rolling-hash frame vocabulary (`NESTED_BEGIN`/`NESTED_END`, `_consumeNestedCall`, `_resolveNestedReentrant`) is shared and direction-neutral — a protocol constant across both chains.

### Data Types (L1 — IEEZ.sol)

```solidity
struct StateUpdate {
    uint64  rollupId;
    bytes32 currentState;   // expected pre-state; checked against rollups[rid].stateRoot
    bytes32 newState;       // post-execution state root
    int256  etherDelta;     // signed ETH change for this rollup
}

struct L2ToL1Call {
    uint16  revertNextNCalls; // >0 force-reverts the next N calls (this one included)
    bool    isStatic;         // dispatch via STATICCALL (read-only, no value)
    uint64  gas;              // gas limit for the target call; 0 = forward all remaining gas
    address sourceAddress;    // originating address on the source rollup
    uint64  sourceRollupId;
    address targetAddress;    // call target on L1
    uint256 value;            // ether to send (0 when isStatic)
    bytes   data;
}

struct ExpectedL1ToL2Call {   // ONE unified reentrant table: SUCCESS, STATIC, and REVERTED kinds
    bytes32      expectedL1toL2Hash;          // position key: keccak256(crossChainCallHash, _rollingHash at fire point)
    L2ToL1Call[] l2ToL1Calls;                 // the reentrant frame's OWN sub-calls, run to completion
    bytes32      revertedOrStaticRollingHash; // expected sub-call hash, checked for STATIC / REVERTED
    bool         success;                     // false ⇒ the reentrant call reverts with returnData
    bytes        returnData;
}

struct ExecutionEntry {
    StateUpdate[]         stateUpdates;         // the entry's true state transition (≥1, enforced on-chain)
    bytes32              proxyEntryHash;      // hashed inbound call; bytes32(0) = pure L2 tx (executeL2Txs)
    L2ToL1Call[]         l2ToL1Calls;         // the entry's TOP-LEVEL calls (reentrant frames carry their own)
    ExpectedL1ToL2Call[] expectedL1ToL2Calls; // unified reentrant table
    bytes32              rollingHash;         // expected hash after all calls + nestings
    uint64               destinationRollupId; // routes to a per-rollup queue
    bool                 success;             // false ⇒ entry runs, verifies, then reverts with returnData
    bytes                returnData;
}

struct ExpectedStateRootPerRollup {
    uint64  rollupId;
    bytes32 stateRoot;      // must equal live rollups[rid].stateRoot
}

struct StaticExecutionEntry {  // TOP-LEVEL static entry — read-only, resolved outside any execution
    ExpectedStateRootPerRollup[] expectedStateRoots; // state-root pins — part of the MATCH predicate (full scan)
    bytes32      proxyEntryHash;
    L2ToL1Call[] l2ToL1Calls;   // read-only sub-calls run via STATICCALL during resolution
    bytes32      rollingHash;   // untagged static schema: keccak(prev, success, retData)
    uint64       destinationRollupId;
    bool         success;       // false ⇒ resolution reverts with returnData
    bytes        returnData;
}
```

There is no flat-array partition: every reentrant frame carries its own `l2ToL1Calls[]` sub-array, run to completion. The unified `expectedL1ToL2Calls[]` table is content-addressed — `expectedL1toL2Hash == keccak256(crossChainCallHash, _rollingHash)` binds each reentrant result to the exact execution point (the live rolling hash folds every prior call and nesting boundary), and `crossChainCallHash` folds `isStatic`, so static reads key distinctly from state-changing calls.

Prover obligation (L1): `stateUpdates` must be the entry's true state transition; at least one `StateUpdate` is enforced on-chain (`EntryHasNoStateUpdates`), and every rollup an entry touches (destination + every call's source) must be in its `stateUpdates` set (proxy protection).

### Data Types (L2 — IEEZL2.sol)

Leaner: no `StateUpdate`, no `destinationRollupId`, no `expectedStateRoots`.

```solidity
struct CrossChainCall {       // same field layout as L1's L2ToL1Call
    uint16  revertNextNCalls;
    bool    isStatic;
    uint64  gas;
    address sourceAddress;
    uint64  sourceRollupId;
    address targetAddress;
    uint256 value;
    bytes   data;
}

struct ExpectedOutgoingCrossChainCall {   // unified reentrant table, mirrors L1's ExpectedL1ToL2Call
    bytes32          expectedOutgoingHash;         // keccak256(crossChainCallHash, expectedRollingHash)
    CrossChainCall[] incomingCalls;                // the frame's own sub-calls
    bytes32          revertedOrStaticRollingHash;
    bool             success;
    bytes            returnData;
}

struct ExecutionEntry {
    bytes32                          proxyEntryHash;        // never bytes32(0) on L2 (executeL2Txs is L1-only)
    CrossChainCall[]                 incomingCalls;         // TOP-LEVEL calls
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls; // unified reentrant table
    bytes32                          rollingHash;
    bool                             success;               // false ⇒ entry runs, verifies, then reverts
    bytes                            returnData;
}

struct StaticExecutionEntry {   // TOP-LEVEL static entry — persistent pool; matched by proxyEntryHash alone
    bytes32          proxyEntryHash;
    CrossChainCall[] incomingCalls;  // read-only sub-calls run via STATICCALL
    bytes32          rollingHash;    // untagged static schema
    bool             success;
    bytes            returnData;
}
```

### L1 batch struct

```solidity
struct RollupIdWithProofSystems {
    uint64   rollupId;
    uint64[] proofSystemIndexes;   // strictly increasing indices into the batch's proofSystems[]
}

struct ProofSystemBatchPerVerificationEntries {
    ExpectedStateRootPerRollup[] expectedStateRootPerRollup; // optional composer assertions; mismatch reverts the tx
    ExecutionEntry[]             entries;
    StaticExecutionEntry[]       staticEntries;
    uint256                      immediateEntryCount;        // leading prefix executed this tx (immediate L2Txs + meta-hook entries)
    uint256                      immediateStaticEntryCount;  // leading static entries resolvable this tx via the meta hook
    address[]                    proofSystems;               // batch-global, strictly increasing, no address(0)
    RollupIdWithProofSystems[]   rollupIdsWithProofSystems;  // strictly increasing rollupIds
    uint256[]                    blobIndices;                // tx-level EIP-4844 blobs this batch consumes
    bytes                        callData;                   // batch-scoped calldata
    bytes[]                      proofs;                     // one per proofSystems entry
    uint64                       blockNumber;                // block binding; 0 = none, uint64.max = latest
    bool                         bindMsgSenderInPublicInput; // true = fold msg.sender into the public input (front-run protection)
}
```

`immediateEntryCount` / `immediateStaticEntryCount` are UNPROVEN dispatch params — not folded into the public input, so the immediate/persistent split can be re-tuned without re-proving.

An `ExecutionEntry` carries a `success` flag: when false the entry is run, verified, then reverted with `returnData` so all of its state effects roll back (the caller may try/catch). Reverting REENTRANT calls are `success == false` rows in the unified reentrant table; a top-level reverting READ is a `StaticExecutionEntry { success: false }`. Inner naturally-reverting calls are still expressible: the proxy `.call` returns `(false, retData)` and the rolling hash captures it via `CALL_END`.

Cross-chain call hash — **L1 and L2 key calls DIFFERENTLY**. The gas-free formula (EEZBase, exposed on both managers) keys everything on L1 plus L2 inbound/static matching:

```solidity
keccak256(abi.encode(isStatic, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, data))
```

Calls **leaving an L2** (`EEZL2.executeCrossChainCall` — both top-level entry matching and nested `expectedOutgoingHash` keys) use the L2-only gas-folding overload. `callGas` depends on the constructor flag `useGasLeft` (immutable `USE_GAS_LEFT`): when true, `uint64(gasleft())` observed at manager entry (what the caller forwarded); when false — current deployments and all test fixtures — a fixed `0`, keeping the 8-field encoding but making outgoing hashes gas-independent. The folded value is emitted in L2's `CrossChainCallExecuted`:

```solidity
keccak256(abi.encode(isStatic, sourceAddress, sourceRollupId, targetAddress, targetRollupId, value, callGas, data))
```

The two formulas are deliberately distinct: with `useGasLeft = true` an L2 outgoing call's identity binds the observed forwarded gas, so the prover must commit to it (deterministic for a sequencer replaying the block). Gas-observed keying is the intended future production mode; until the node supplies observed gas, deployments run `useGasLeft = false`.

### Key Functions (L1 — EEZ)

1. **registerRollup(address rollupContract, bytes32 initialState) → uint64 rollupId** — caller pre-deploys an `IRollupContract` manager, then registers it. Registry assigns a fresh id and fires `rollupContractRegistered(rollupId)` once on the manager.
2. **postAndVerifyBatch(ProofSystemBatchPerVerificationEntries batch)** — (1) validates structure (sorted invariants, transient prefix bounds, proxy protection: every touched rollup ∈ the entry's `stateUpdates` / the static entry's pins), (2) fetches the vkey matrix via each rollup's `checkProofSystemsAndGetVkeys`, (3) verifies one proof per proof system against `publicInputsHash` (atomic: any failure reverts the batch), (4) marks each rollup verified this block (wiping its queues), (5-6) runs the leading run of `proxyEntryHash == 0` entries straight from calldata (`try _attemptExecuteImmediateL2Txs` — a revert emits `L2TxSkipped` and advances; all-failed reverts `AllImmediateL2TxsFailed`), (7) loads the remaining transient prefix into `_transientEntries` / `_transientStaticEntries` and fires `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` if `msg.sender` has code, (8) clears the transient tables, (9) publishes the remainder into per-rollup queues UNCONDITIONALLY via `_saveRemainderEntries` (soundness backstop: `StateUpdate.currentState` is re-checked at consumption, so orphaned entries fail `StateRootMismatch`).
3. **executeCrossChainCall(sourceAddress, callData)** — payable entry point for proxies. Computes the call hash with `sourceRollupId = MAINNET_ROLLUP_ID` and tracks ether via `_entryEtherDelta`. Top-level → forward-scan the routed rollup's queue from its cursor (`_findMatchingEntry`: match = `proxyEntryHash` + `destinationRollupId` + live `currentState` pins, skipping non-matching candidates; transient table first while a batch is mid-flight); reentrant (`_insideExecution()`) → `_consumeNestedCall` against the unified reentrant table.
4. **executeL2Txs(uint64 rollupId)** — permissionless. Forward-scans `rollupId`'s queue for the next matching `proxyEntryHash == bytes32(0)` entry and executes it. Not callable mid-execution.
5. **staticCrossChainCall(sourceAddress, callData)** — view. Inside an execution: forward-scans the active host's unified `expectedL1ToL2Calls` for `expectedL1toL2Hash == keccak256(crossChainCallHash, _rollingHash)` (the static-kind key; position-pinned, not consumed). Outside: scans the transient pool while a batch is mid-flight, else the routed rollup's `staticEntryQueue`, matching `proxyEntryHash` + `destinationRollupId` + live state-root pins (full scan). Runs cached sub-calls in static context, then returns `returnData` or reverts with it (when `!success`).
6. **setStateRoot(uint64 rollupId, bytes32 newStateRoot)** — manager-only (caller must equal `rollups[rid].rollupContract`). Reverts `RollupBatchActiveThisBlock` if the rollup had a verified batch this block.
7. **Views**: `lastVerifiedBlock(rid)`, `queueLength(rid)`, `entryQueueIndex(rid)`.

### Key Functions (L2 — EEZL2)

Constructor: `EEZL2(uint64 rollupId != 0, address systemAddress, bool useGasLeft)`. `SYSTEM_ADDRESS` is a trusted, node-controlled address (no key, not reentry-reachable). `useGasLeft` selects the `callGas` folded into outgoing call hashes: observed `gasleft()` (true) or a fixed `0` (false — what tests and current deployments use).

1. **loadExecutionTable(entries, staticEntries)** — system-only. Wipes existing tables, loads new ones, sets `lastLoadBlock`. Entries are only consumable in the same block (`ExecutionNotInCurrentBlock`).
2. **executeIncomingCrossChainCall(destination, value, data, sourceAddress, sourceRollup, entries, staticEntries)** — system-only, payable (`msg.value == value` mints the inbound ETH). Atomically replaces the table and drives `entries[0]` through the call processor; `entries[0].incomingCalls[0]` is the inbound call itself, and `entries[0].proxyEntryHash` must match the hash of the explicit params.
3. **executeCrossChainCall(sourceAddress, callData)** — same shape as L1, but `sourceRollupId` in the call hash is forced to `ROLLUP_ID`, and any `msg.value` is returned to `SYSTEM_ADDRESS` (burn). No state deltas, no ether accounting.
4. **staticCrossChainCall(sourceAddress, callData)** — same nested key shape as L1 (unified table, static-kind hash); outside an execution it scans the single persistent `staticEntries` pool by `proxyEntryHash` alone (no state roots to pin).

Both managers share `createCrossChainProxy` / `computeCrossChainProxyAddress` from EEZBase.

### Multi-prover Model

A batch carries a global strictly-increasing `proofSystems[]` and one `proofs[k]` per entry. Each participating rollup selects the subset it accepts via `proofSystemIndexes[]` (indices into the global list); the rollup's manager contract validates the subset and returns the per-PS vkeys (`checkProofSystemsAndGetVkeys`), enforcing its own threshold. Verification splits into a shared public input plus a per-PS hash, letting different proof systems attest the same logical batch with their own vkey vectors. `blockNumber` binds the batch to L1 block context via each manager's `getCustomData(blockNumber)`; `bindMsgSenderInPublicInput` folds `msg.sender` (or `address(0)`) into the public input for optional front-run protection; `expectedStateRootPerRollup` lets the composer assert live pre-states (mismatch reverts `ExpectedStateRootMismatch`).

### Per-Rollup Queue Model

`verificationByRollup[rid]` holds `{lastVerifiedBlock, entryQueueIndex, entryQueue, staticEntryQueue}`. `lastVerifiedBlock` triples as: (a) reset marker — EVERY batch touching `rid` wipes that rollup's queues and cursor, so a same-block re-verify fully REPLACES (never appends to) the prior batch's entries; safe because every entry is gated by `StateUpdate.currentState` at consumption; (b) consumption gate — `executeCrossChainCall` / `executeL2Txs` require `lastVerifiedBlock == block.number`, so queues never leak across blocks (static entries are exempt from the block gate — they stay matchable while their state-root pins hold); (c) the `setStateRoot` lockout. Different rollups' queues are independent — meta-hook reentry into another rollup's queue is allowed; same-rollup reentry is blocked.

### Rolling Hash

A single `bytes32 rollingHash` per entry covers every call result and every nesting boundary. The accumulator is SEEDED with the entry's identity — L1: `_rollingHashEntryBegin` folds each `(rollupId, currentState)` pair then `proxyEntryHash`; L2: `_seedRollingHash` folds `keccak256(0, proxyEntryHash)` — then updated by tagged events (EEZBase):

```
CALL_BEGIN     (1)   keccak256(prev, 0x01, crossChainCallHash)   // binds WHICH call ran
CALL_END       (2)   keccak256(prev, 0x02, success, retData)
NESTED_BEGIN   (3)   keccak256(prev, 0x03, crossChainCallHash)   // start of a reentrant frame
NESTED_END     (4)   keccak256(prev, 0x04)
CALL_NOT_FOUND (5)   keccak256(prev, 0x05, crossChainCallHash)   // reentrant no-match; diverges the hash so the entry reverts — replaces a side flag
```

No call/frame index is folded in: the hash is a chain, so order, count, and nesting are already bound — and omitting the index is what lets a `revertNextNCalls` span be processed as a 0-based sub-slice without diverging the hash. One mismatch anywhere — wrong return data, wrong success flag, missing/extra calls, wrong nesting — changes the final hash and is caught with one comparison against `entry.rollingHash`. There is no reentrant table-length check — the table is content-addressed and unused rows are inert; completeness of what DID run is enforced by the hash itself. L1 additionally checks the ether-delta invariant (`Σ etherDelta == _entryEtherDelta`). Static sub-calls use a separate untagged accumulator (`keccak256(prev, success, retData)`) verified against `StaticExecutionEntry.rollingHash` / `revertedOrStaticRollingHash`. See `docs/CORE_PROTOCOL_SPEC.md` §E.

### `revertNextNCalls`

`revertNextNCalls > 0` is the forced-revert mechanism: the next N calls (the flagged one included) execute, succeed, and have their EVM state effects rolled back at the protocol layer. The processor slices the span and self-calls `executeInContextAndRevert(slice)`, which always reverts with `ContextResult(rollingHash, reentrantConsumed, callsProcessed)` — state rolls back, the cursors and hash escape via the revert payload and are restored by the outer frame (`callsProcessed` is L1-only; 0 on L2). Use only for forced reverts (e.g. a call that ran cleanly on the destination but was rolled back in the source's view). Naturally-reverting destinations need `revertNextNCalls = 0` — the proxy `.call` already captures `(false, retData)` into `CALL_END`.

### Success vs failure — where each case lives

| Situation | Use |
|---|---|
| Reentrant call that **succeeds** | unified-table row with `success: true` (`_resolveNestedReentrant` runs its sub-array as a committing sub-execution) |
| Reentrant call that **reverts** (caller catches with try/catch) | unified-table row with `success: false` (run as a mini-entry against `revertedOrStaticRollingHash`, then reverted) |
| Reentrant cross-chain **STATICCALL** (read-only) | unified-table row keyed with the static-kind hash (resolved by `staticCrossChainCall`, position-pinned, not consumed) |
| Top-level static read (succeeding or reverting) | pool `StaticExecutionEntry` (`success` as appropriate) |
| Top-level call that **reverts** (state-changing) | `ExecutionEntry { success: false }` — run, verified, then reverted with `returnData` |
| Inner natural revert of a non-reentrant call | plain sub-array call with `revertNextNCalls = 0`; `CALL_END(false, retData)` captures it |
| Successful call(s) whose state must be force-reverted | `revertNextNCalls = N` on the first call of the span |

All three reentrant kinds live in ONE table (`expectedL1ToL2Calls` / `expectedOutgoingCalls`), content-addressed by `keccak256(crossChainCallHash, _rollingHash-at-fire-point)` — the live rolling hash makes the execution position an enforced part of the key, and a reverted sub-execution reuses the host table for its own reentrant calls.

### CREATE2 Address Derivation

```
salt          = keccak256(abi.encodePacked(originalRollupId, originalAddress))
bytecodeHash  = keccak256(creationCode || abi.encode(manager))
proxyAddress  = address(uint160(uint256(keccak256(0xff || manager || salt || bytecodeHash))))
```

`computeCrossChainProxyAddress(originalAddress, originalRollupId)` takes two parameters — no `domain` / `block.chainid` in the salt.

## Documentation

- `docs/CORE_PROTOCOL_SPEC.md` — formal protocol specification.
- `docs/MULTI_PROVER_SPEC.md` — design rationale for the multi-prover model.
- `docs/EXECUTION_ENTRY_SPEC.md` — how to build execution entries.
- `docs/STATIC_ENTRY.md` — static entries + reverted-call resolution semantics.
- `docs/BLOB_FORMAT_SPEC.md` — wire format for the blobs publishing cross-chain activity.
- `docs/CAVEATS.md` — edge cases.

## Testing

Tests use a `MockProofSystem` that accepts all proofs by default; `setExpectedPublicInputsHash(h)` pins the exact public input the registry must produce (and enables verification), and `setShouldVerify(true)` without a pin rejects everything. `test/Base.t.sol` is the single-PS happy-path fixture; integration tests deploy a per-rollup `Rollup` manager on the fly. L1 unit tests live in `test/EEZ.t.sol`, L2 in `test/EEZL2.t.sol`; two-sided flows in the `IntegrationTest*.t.sol` files. E2E devnet scenarios live under `script/e2e/` (shared helpers in `script/e2e/shared/`).

All fixtures deploy `EEZL2` with `useGasLeft = false`, so L2-outgoing hashes fold `callGas = 0` and are pre-computable (`_outgoingCallHash` in `test/BaseL2.t.sol`, `_ccHashL2Out` in `test/IntegrationBase.t.sol`). `test/GasProbe.t.sol` deploys its own `useGasLeft = true` manager and validates the probe recipe for observed-gas keying: probe twice with the same explicit `{gas: ...}` against an empty loaded table and decode the folded `callGas` from `EntryNotFound(hash, callGas)` — the value a later identical call will fold, provided it attaches the same explicit gas (helpers `_probeOutgoing` / `CALL_GAS` in `test/BaseL2.t.sol`).
