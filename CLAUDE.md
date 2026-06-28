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

- **EEZ.sol** (L1): Central registry and execution manager. Manages per-rollup state roots and ether balances, verifies multi-prover batches via `postAndVerifyBatch`, queues `ExecutionEntry`s into per-rollup queues, runs the `IMetaCrossChainReceiver` hook for in-tx consumption, and executes flat sequential cross-chain calls with rolling-hash verification. Holds no per-rollup policy — that lives in each rollup's own manager contract.
- **base/EEZBase.sol**: Direction-neutral shared base for both managers. Rolling-hash tag constants and fold helpers, the `_rollingHash` accumulator, neutral transient pointers (`_currentEntryIndex`, `_insideRevertedLookup`, `_revertedLookupIndex`), the `authorizedProxies` registry, CREATE2 proxy creation (`createCrossChainProxy`, `computeCrossChainProxyAddress`), `computeCrossChainCallHash`, and the `ContextResult` revert transport.
- **L2/EEZL2.sol**: L2-side manager. No proofs, no rollup registry, no state deltas — a trusted `SYSTEM_ADDRESS` loads execution tables (`loadExecutionTable`) or drives an inbound call atomically (`executeIncomingCrossChainCall`); entries are consumed sequentially via proxy calls in the same block they were loaded.
- **interfaces/IEEZ.sol** + **interfaces/IEEZL2.sol**: Per-side execution structs (see Naming below). L1 structs carry state deltas and per-rollup routing; L2 structs are leaner.
- **rollupContract/Rollup.sol** + **interfaces/IRollup.sol** (`IRollupContract`): Per-rollup manager contract. Each rollup is owned by a pre-deployed contract conforming to `IRollupContract` (the reference `Rollup.sol` bakes in proof systems, vkeys, threshold, owner). The registry calls `rollupContractRegistered(rollupId)` once at registration, `checkProofSystemsAndGetVkeys(address[])` per batch (rejects unknown PS or fewer than threshold), and `getTimestampAndBlockHash(blockNumber)` for block binding. The manager can call `EEZ.setStateRoot(rid, newRoot)` as an ops escape hatch.
- **interfaces/IProofSystem.sol**: `verify(bytes proof, bytes32 publicInputsHash) returns (bool)` — any external verifier.
- **interfaces/IMetaCrossChainReceiver.sol**: Callback fired on `postAndVerifyBatch`'s `msg.sender` (when it has code) so the sender can consume transient entries via cross-chain proxy calls in the same transaction.
- **base/CrossChainProxy.sol**: CREATE2 proxy per (address, rollupId) pair. Routes incoming calls to the manager via `executeCrossChainCall` (or `staticCallLookup` in static context, detected via a `tstore` self-call), and forwards manager-driven outbound calls via `executeOnBehalf`.

### Naming: per-side directional vocabulary

The execution structs are split per side and named directionally:

- **L1 (IEEZ.sol)** uses absolute direction: `L2ToL1Call` / `l2ToL1Calls` (calls executed on L1), `ExpectedL1ToL2Call` / `expectedL1ToL2Calls` (pre-computed reentrant calls leaving L1), cursors `_currentL2ToL1Call` / `_lastL1ToL2CallConsumed`, event `L1ToL2CallConsumed`, errors `UnconsumedL2ToL1Calls` / `UnconsumedL1ToL2Calls`.
- **L2 (IEEZL2.sol)** uses self-relative direction (the counterparty may be L1 OR another L2, so absolute names would often be wrong): `CrossChainCall` / `incomingCalls` (calls executed on this L2 for remote callers), `ExpectedOutgoingCrossChainCall` / `expectedOutgoingCalls` (pre-computed reentrant calls leaving this L2), cursors `_currentIncomingCall` / `_lastOutgoingCallConsumed`, event `OutgoingCallConsumed`, errors `UnconsumedIncomingCalls` / `UnconsumedOutgoingCalls`.

The rolling-hash frame vocabulary (`NESTED_BEGIN`/`NESTED_END`, `_consumeNestedAction`) is shared and direction-neutral — a protocol constant across both chains.

### Data Types (L1 — IEEZ.sol)

```solidity
struct StateDelta {
    uint256 rollupId;
    bytes32 currentState;   // expected pre-state; checked against rollups[rid].stateRoot
    bytes32 newState;       // post-execution state root
    int256  etherDelta;     // signed ETH change for this rollup
}

struct L2ToL1Call {
    bool    isStatic;       // true = dispatch via STATICCALL (read-only, no value, reverts on state write)
    address targetAddress;
    uint256 value;
    bytes   data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;     // 0 = normal; N>0 = force-revert state effects of next N calls
}

struct ExpectedL1ToL2Call {
    bytes32 crossChainCallHash;   // hash of the reentrant call
    uint256 callCount;            // slice of l2ToL1Calls[] consumed inside this frame
    bytes   returnData;           // pre-computed return value (must succeed)
}

struct ExecutionEntry {
    StateDelta[]         stateDeltas;
    bytes32              proxyEntryHash;        // hashed inbound call; bytes32(0) = system-driven (L2TX / immediate)
    uint256              destinationRollupId;   // rollup whose queue this entry is routed to
    L2ToL1Call[]         l2ToL1Calls;           // flat array of ALL calls in execution order
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;   // sequentially consumed by reentrant calls
    ExpectedLookup[]     expectedLookups;       // entry-scoped NESTED lookups (static reads + try/catch'd reverts)
    uint256              callCount;             // top-level iterations (partition invariant below)
    bytes                returnData;            // pre-computed return data for the entry's top-level call
    bytes32              rollingHash;           // expected hash after all calls + nestings
}

struct ExpectedLookup {            // NESTED lookup — lives inside the entry; matched by 4-tuple
    bytes32              crossChainCallHash;
    bytes                returnData;
    bool                 failed;
    uint64               l2ToL1CallNumber;        // _currentL2ToL1Call at observation
    uint64               lastL1ToL2CallConsumed;  // _lastL1ToL2CallConsumed at observation
    uint64               executingLookupIndex;    // 0 = host level; k = inside the sub-execution of expectedLookups[k-1]
    L2ToL1Call[]         l2ToL1Calls;             // sub-calls executed during resolution
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;     // reverted-mode reentrant table
    uint256              callCount;               // reverted-mode top-level iterations
    bytes32              rollingHash;             // expected hash of executed sub-calls
}

struct ExpectedStateRootPerRollup {
    uint256 rollupId;
    bytes32 stateRoot;             // must equal live rollups[rid].stateRoot — part of the MATCH (full scan)
}

struct LookupCall {                // TOP-LEVEL lookup — storage pool; consumable only when !_insideExecution()
    bytes32              crossChainCallHash;
    uint256              destinationRollupId;     // lookupQueue this is published under
    bytes                returnData;
    bool                 failed;
    L2ToL1Call[]         l2ToL1Calls;             // sub-calls executed during resolution
    ExpectedL1ToL2Call[] expectedL1ToL2Calls;     // reverted-mode reentrant table
    ExpectedLookup[]     expectedLookups;         // reverted-mode nested lookups for the sub-execution
    uint256              callCount;               // reverted-mode top-level iterations
    bytes32              rollingHash;             // expected hash of executed sub-calls
    ExpectedStateRootPerRollup[] expectedStateRoots;  // state-root pins (L1 only)
}
```

Partition invariant: `callCount + Σ expected*Calls[i].callCount == flatCalls.length` — one global cursor walks the flat array across the whole execution tree.

Prover obligation (L1): `stateDeltas` must be the entry's true state transition, and every entry must carry at least one `StateDelta` — asserted by the prover, not enforced on-chain (an empty array would leave the entry unpinned from the `StateRootMismatch` backstop).

### Data Types (L2 — IEEZL2.sol)

Leaner: no `StateDelta`, no `destinationRollupId`, no `expectedStateRoots`.

```solidity
struct CrossChainCall {       // same field layout as L1's L2ToL1Call
    bool    isStatic;         // true = dispatch via STATICCALL (read-only, no value, reverts on state write)
    address targetAddress;
    uint256 value;
    bytes   data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;
}

struct ExpectedOutgoingCrossChainCall {
    bytes32 crossChainCallHash;
    uint256 callCount;
    bytes   returnData;
}

struct ExecutionEntry {
    bytes32                          proxyEntryHash;        // never bytes32(0) on L2 (no zero-hash consumption path)
    CrossChainCall[]                 incomingCalls;
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls;
    ExpectedLookup[]                 expectedLookups;       // entry-scoped nested lookups
    uint256                          callCount;
    bytes                            returnData;
    bytes32                          rollingHash;
}

struct ExpectedLookup {            // NESTED lookup — inside the entry; matched by 4-tuple
    bytes32                          crossChainCallHash;
    bytes                            returnData;
    bool                             failed;
    uint64                           callNumber;                // _currentIncomingCall at observation
    uint64                           lastOutgoingCallConsumed;  // _lastOutgoingCallConsumed at observation
    uint64                           executingLookupIndex;      // 0 = host level; k = inside the sub-execution of expectedLookups[k-1]
    CrossChainCall[]                 incomingCalls;
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls;
    uint256                          callCount;
    bytes32                          rollingHash;
}

struct LookupCall {                // TOP-LEVEL lookup — persistent pool; matched by hash alone
    bytes32                          crossChainCallHash;
    bytes                            returnData;
    bool                             failed;
    CrossChainCall[]                 incomingCalls;
    ExpectedOutgoingCrossChainCall[] expectedOutgoingCalls;
    ExpectedLookup[]                 expectedLookups;
    uint256                          callCount;
    bytes32                          rollingHash;
}
```

### L1 batch struct

```solidity
struct RollupIdWithProofSystems {
    uint256  rollupId;
    uint64[] proofSystemIndex;   // strictly increasing indices into the batch's proofSystems[]
}

struct ProofSystemBatchPerVerificationEntries {
    ExecutionEntry[]            entries;
    LookupCall[]                l1ToL2lookupCalls;
    uint256                     immediateEntryCount;   // leading prefix loaded transiently
    uint256                     transientLookupCallCount;
    address[]                   proofSystems;                   // batch-global, strictly increasing
    RollupIdWithProofSystems[]  rollupIdsWithProofSystems;      // strictly increasing rollupIds
    uint256[]                   blobIndices;                    // EIP-4844 blobs this batch consumes
    bytes                       callData;
    bytes[]                     proofs;                         // one per proofSystems entry
    uint64                      blockNumber;                    // block binding; 0 = none, uint64.max = latest
}
```

`ExecutionEntry` always succeeds at the top level. There is no `failed` flag — a reverting top-level call isn't an "execution," it's a lookup. Reverting REENTRANT calls are nested `ExpectedLookup { failed: true }` inside the entry (consumed by the `_consumeNestedAction` fallback); reverting TOP-LEVEL calls are pool `LookupCall { failed: true }` executed via `_tryRevertedTopLevelLookup`. Inner naturally-reverting calls are still expressible: the proxy `.call` returns `(false, retData)` and the rolling hash captures it via `CALL_END`.

Cross-chain call hash formula (single, used everywhere; exposed as `computeCrossChainCallHash(...)` on both managers):

```solidity
keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId))
```

### Key Functions (L1 — EEZ)

1. **registerRollup(address rollupContract, bytes32 initialState) → uint256 rollupId** — caller pre-deploys an `IRollupContract` manager, then registers it. Registry assigns a fresh id and fires `rollupContractRegistered(rollupId)` once on the manager.
2. **postAndVerifyBatch(ProofSystemBatchPerVerificationEntries batch)** — validates sorted invariants, fetches the vkey matrix via each rollup's `checkProofSystemsAndGetVkeys`, verifies one proof per proof system against `publicInputsHash` (atomic: any failure reverts the batch), marks each rollup verified this block, loads the leading `immediateEntryCount` entries into `_transientExecutions`, runs the leading run of `proxyEntryHash == 0` entries inline (`attemptApplyImmediate` self-call with try/catch — a revert emits `ImmediateEntrySkipped` and advances), fires `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` if transient entries remain and `msg.sender` has code, then publishes the remainder into per-rollup queues UNCONDITIONALLY (soundness backstop: `StateDelta.currentState` is re-checked at consumption, so orphaned entries fail `StateRootMismatch`). Transient tables are cleared at the end.
3. **executeCrossChainCall(sourceAddress, callData)** — entry point for proxies. Top-level → consume next entry from the routed rollup's queue (transient table first while a batch is mid-flight); reentrant (`_insideExecution()`) → `_consumeNestedAction`.
4. **executeL2TX(uint256 rollupId)** — permissionless. Consumes the next entry on `rollupId`'s queue, which must have `proxyEntryHash == bytes32(0)`.
5. **staticCallLookup(sourceAddress, callData)** — view. Inside an execution: scans the active host's entry-scoped `expectedLookups` by `(crossChainCallHash, l2ToL1CallNumber, lastL1ToL2CallConsumed, executingLookupIndex)`. Outside: scans the transient table then the routed rollup's `lookupQueue` for a top-level `LookupCall` matching `crossChainCallHash` with live state-root pins (full scan). Runs cached sub-calls in static context, then returns `returnData` or reverts with it (when `failed`).
6. **setStateRoot(uint256 rollupId, bytes32 newStateRoot)** — manager-only (caller must equal `rollups[rid].rollupContract`). Reverts `RollupBatchActiveThisBlock` if the rollup had a verified batch this block.
7. **Views**: `lastVerifiedBlock(rid)`, `queueLength(rid)`, `executionQueueIndex(rid)`.

### Key Functions (L2 — EEZL2)

Constructor: `EEZL2(rollupId != 0, systemAddress)`. `SYSTEM_ADDRESS` is a trusted, node-controlled address (no key, not reentry-reachable).

1. **loadExecutionTable(entries, lookupCalls)** — system-only. Wipes existing tables, loads new ones, sets `lastLoadBlock`. Entries are only consumable in the same block (`ExecutionNotInCurrentBlock`).
2. **executeIncomingCrossChainCall(destination, value, data, sourceAddress, sourceRollup, entries, lookupCalls)** — system-only, payable (`msg.value == value` mints the inbound ETH). Atomically replaces the table and drives `executions[0]` through the flat call processor; `entries[0].incomingCalls[0]` is the inbound call itself, and `entries[0].proxyEntryHash` must match the hash of the explicit params.
3. **executeCrossChainCall(sourceAddress, callData)** — same shape as L1, but `sourceRollupId` in the call hash is forced to `ROLLUP_ID`, and any `msg.value` is forwarded to `SYSTEM_ADDRESS` (burn). No state deltas, no ether accounting.
4. **staticCallLookup(sourceAddress, callData)** — same lookup key shape as L1 (`callNumber`, `lastOutgoingCallConsumed`); scans the single persistent `lookupCalls` table.

Both managers share `createCrossChainProxy` / `computeCrossChainProxyAddress` from EEZBase.

### Multi-prover Model

A batch carries a global strictly-increasing `proofSystems[]` and one `proofs[k]` per entry. Each participating rollup selects the subset it accepts via `proofSystemIndex[]` (indices into the global list); the rollup's manager contract validates the subset and returns the per-PS vkeys (`checkProofSystemsAndGetVkeys`), enforcing its own threshold. Verification splits into a shared public input plus a per-PS hash, letting different proof systems attest the same logical batch with their own vkey vectors. `blockNumber` binds the batch to L1 block context via each manager's `getTimestampAndBlockHash`.

### Per-Rollup Queue Model

`verificationByRollup[rid]` holds `{lastVerifiedBlock, executionQueue, lookupQueue, executionQueueIndex}`. `lastVerifiedBlock` triples as: (a) reset marker — EVERY batch touching `rid` wipes that rollup's queue and cursor, so a same-block re-verify fully REPLACES (never appends to) the prior batch's entries; safe because every entry is gated by `StateDelta.currentState` at consumption; (b) consumption gate — `executeCrossChainCall` / `executeL2TX` / `staticCallLookup` require `lastVerifiedBlock == block.number`, so queues never leak across blocks; (c) the `setStateRoot` lockout. Different rollups' queues are independent — meta-hook reentry into another rollup's queue is allowed; same-rollup reentry is blocked.

### Rolling Hash

A single `bytes32 rollingHash` per entry covers every call result and every nesting boundary. Four tagged events update the accumulator (EEZBase):

```
CALL_BEGIN     (1)   keccak256(prev, 0x01, callNumber)
CALL_END       (2)   keccak256(prev, 0x02, callNumber, success, retData)
NESTED_BEGIN   (3)   keccak256(prev, 0x03, nestedNumber)
NESTED_END     (4)   keccak256(prev, 0x04, nestedNumber)
CALL_NOT_FOUND (5)   keccak256(prev, 0x05, crossChainCallHash)   // reentrant no-match (L1); diverges the hash so the entry reverts — replaces a side flag
```

One mismatch anywhere — wrong return data, wrong success flag, missing/extra calls, wrong nesting — changes the final hash and is caught with one comparison. End-of-entry checks: rolling hash, flat-call cursor == flat array length, reentrant cursor == reentrant table length, and (L1) the ether-delta invariant. Static lookup sub-calls use a simpler untagged accumulator (`keccak256(prev, success, retData)`) verified against `LookupCall.rollingHash`. See `docs/CORE_PROTOCOL_SPEC.md` §E.

### `revertSpan`

`revertSpan > 0` is the forced-revert mechanism: the next `revertSpan` calls execute, succeed, and have their EVM state effects rolled back at the protocol layer. The processor self-calls `executeInContextAndRevert(revertSpan)`, which always reverts with `ContextResult(rollingHash, reentrantConsumed, callsProcessed, callNotFound)` — state rolls back, the cursors and hash escape via the revert payload and are restored by the outer frame. Use only for forced reverts (e.g. a call that ran cleanly on the destination but was rolled back in the source's view). Naturally-reverting destinations need `revertSpan = 0` — the proxy `.call` already captures `(false, retData)` into `CALL_END`.

### Reentrant success vs failure

| Situation | Use |
|---|---|
| Reentrant call that **succeeds** | `ExpectedL1ToL2Call` (L1) / `ExpectedOutgoingCrossChainCall` (L2) |
| Reentrant call that **reverts** (caller catches with try/catch) | Nested `ExpectedLookup { failed: true }` inside the entry |
| Reentrant cross-chain `STATICCALL` (read-only) | Nested `ExpectedLookup { failed: false }` inside the entry |
| Top-level static read or natural revert | Pool `LookupCall` (`failed` as appropriate) |
| Inner natural revert of a non-reentrant call | plain flat-array call with `revertSpan = 0`; `CALL_END(false, retData)` captures it |
| Successful call(s) whose state must be force-reverted | `revertSpan > 0` on the first call of the span |

Nested lookups are content-addressed within their entry by `(crossChainCallHash, callNumber, lastConsumed, executingLookupIndex)` and execute deterministically (`_executeRevertedNestedLookup` runs them as a mini-entry and reverts with the cached `returnData`); the `executingLookupIndex` coordinate makes the execution context an enforced part of the key. Top-level pool lookups match by hash + state-root pins and execute via `_executeRevertedTopLevelLookup`.

### CREATE2 Address Derivation

```
salt          = keccak256(abi.encodePacked(originalRollupId, originalAddress))
bytecodeHash  = keccak256(creationCode || abi.encode(manager, originalAddress, originalRollupId))
proxyAddress  = address(uint160(uint256(keccak256(0xff || manager || salt || bytecodeHash))))
```

`computeCrossChainProxyAddress(originalAddress, originalRollupId)` takes two parameters — no `domain` / `block.chainid` in the salt.

## Documentation

- `docs/CORE_PROTOCOL_SPEC.md` — formal protocol specification.
- `docs/MULTI_PROVER_SPEC.md` — design rationale for the multi-prover model.
- `docs/EXECUTION_ENTRY_SPEC.md` — how to build execution entries.
- `docs/LOOKUP_SPEC.md` — lookup semantics, nested + top-level (static vs reverted modes).
- `docs/CAVEATS.md` — edge cases.

## Testing

Tests use a `MockProofSystem` that accepts all proofs by default; `setExpectedPublicInputsHash(h)` pins the exact public input the registry must produce, and `setShouldVerify(true)` without a pin rejects everything. `test/Base.t.sol` is the single-PS happy-path fixture; integration tests deploy a per-rollup `Rollup` manager on the fly. L1 unit tests live in `test/EEZ.t.sol`, L2 in `test/EEZL2.t.sol`; two-sided flows in the `IntegrationTest*.t.sol` files. E2E devnet scenarios live under `script/e2e/` (shared helpers in `script/e2e/shared/`).
