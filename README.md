# Sync Rollups

Smart contracts to manage synchronous rollups on Ethereum.

## Overview

Sync Rollups enables synchronous composability between based rollups sharing the same L1 sequencer. By pre-computing state transitions off-chain and loading them with ZK proofs, the protocol enables atomic cross-rollup calls that execute within a single L1 block.

This restores the synchronous execution semantics that DeFi protocols depend on — now across multiple rollups.

## Features

- **Atomic Multi-Rollup Execution**: state changes across multiple rollups happen atomically in a single transaction.
- **Cross-Rollup Flash Loans**: borrow on Rollup A, use on Rollup B, repay on A — all atomic.
- **Unified Liquidity**: AMMs can source liquidity from multiple rollups.
- **ZK-Verified State Transitions**: every L1 batch is verified with a single ZK proof.
- **Flat Sequential Execution**: calls live in a single flat array per entry, processed in order with a rolling hash for integrity. No recursive scope navigation, no `RESULT` / `REVERT` action types.
- **Reentrant Calls via `NestedAction`**: cross-chain reentrancy is resolved by consuming pre-computed `NestedAction` entries, not by recursion.
- **Static Call Support**: read-only and reverting reentrant calls are pre-computed as `StaticCall` entries and looked up via a view function.
- **In-Tx Consumption via `IMetaCrossChainReceiver`**: an L1 batch poster can drive consumption of the batch's transient prefix via a callback hook in the same transaction.
- **L1 + L2 Contracts**: L1 `Rollups` contract manages state and proofs; L2 `EEZL2` handles execution without ZK overhead.
- **ETH Balance Tracking (L1)**: per-rollup ETH accounting with conservation guarantees, verified per entry.

## Architecture

### Core Contracts

| Contract | Description |
|----------|-------------|
| `Rollups.sol` | L1 contract managing rollup state roots, ZK-proven batch posting, transient/deferred execution split, the meta-hook callback, and cross-chain call execution. |
| `CrossChainProxy.sol` | Proxy contract deployed via CREATE2 for each `(address, rollupId)` pair. Routes incoming calls to the manager via `executeCrossChainCall` (or `staticCallLookup` in static context); forwards manager-driven outbound calls via `executeOnBehalf`. |
| `EEZL2.sol` | L2-side contract for cross-chain execution via pre-computed execution tables loaded by a system address. No ZK proofs, no rollup registry, no state deltas. |
| `IZKVerifier.sol` | Interface for external ZK proof verification. |
| `IMetaCrossChainReceiver.sol` | Optional callback interface invoked on `postBatch`'s `msg.sender` (when it has code) so the sender can consume the batch's transient entries inline. |

### Data Types

The protocol uses a **flat sequential execution model**. There is no `ActionType` enum, no `scope` array, no `RESULT` / `REVERT` / `REVERT_CONTINUE` actions, and no recursive scope navigation.

```solidity
// Off-chain only — used to compute actionHash. The contracts reconstruct
// the hash from individual fields rather than storing the struct.
// Field declaration order matches the abi.encode preimage; do not reorder.
struct Action {
    uint256 targetRollupId;
    address targetAddress;
    uint256 value;
    bytes   data;
    address sourceAddress;
    uint256 sourceRollupId;
}

struct StateDelta {
    uint256 rollupId;
    bytes32 newState;       // post-execution state root (no currentState — bound by proof)
    int256  etherDelta;     // signed change in rollup's ETH balance
}

struct CrossChainCall {
    address targetAddress;
    uint256 value;
    bytes   data;
    address sourceAddress;
    uint256 sourceRollupId;
    uint256 revertSpan;     // 0 = normal call; N>0 = isolated revert context spanning next N calls
}

struct NestedAction {
    bytes32 actionHash;     // hash of the reentrant call
    uint256 callCount;      // entries from calls[] consumed inside this nested action
    bytes   returnData;     // pre-computed return value (must succeed)
}

struct ExecutionEntry {
    StateDelta[]     stateDeltas;
    bytes32          actionHash;     // bytes32(0) = immediate (L2TX or state commitment)
    CrossChainCall[] calls;          // ALL calls flat, in execution order
    NestedAction[]   nestedActions;  // sequentially consumed by reentrant calls
    uint256          callCount;      // entry-level iterations
    bytes            returnData;     // pre-computed return data for entry's top-level call
    bool             failed;         // if true, entry's top-level call reverts with returnData
    bytes32          rollingHash;    // expected hash after all calls + nestings
}

struct StaticCall {
    bytes32          actionHash;
    bytes            returnData;
    bool             failed;
    bytes32          stateRoot;
    uint64           callNumber;                 // _currentCallNumber at lookup time
    uint64           lastNestedActionConsumed;   // _lastNestedActionConsumed at lookup time
    CrossChainCall[] calls;                      // optional sub-calls executed in static context
    bytes32          rollingHash;                // expected hash of those sub-calls
}

struct ProxyInfo {
    address originalAddress;
    uint64  originalRollupId;
}

struct RollupConfig {
    address owner;
    bytes32 verificationKey;
    bytes32 stateRoot;
    uint256 etherBalance;
}
```

Action hash formula (single, used everywhere):

```solidity
keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId))
```

### Execution Flow

1. **Load Phase**: a prover off-chain computes a valid execution and submits it via `postBatch()` (L1) with a single ZK proof, or `loadExecutionTable()` (L2) signed by the system address. On L1, the leading `transientCount` entries land in `_transientExecutions` (cleared at end of `postBatch`); the rest are deferred to persistent `executions` only if the transient table is fully drained.
2. **Immediate Entry (L1)**: if `entries[0].actionHash == 0` and `transientCount >= 1`, that entry is executed inline by `postBatch` (state deltas applied, calls processed, rolling hash verified). The transient cursor advances past it.
3. **Meta Hook (L1)**: if `msg.sender` has code, `IMetaCrossChainReceiver.executeMetaCrossChainTransactions()` is invoked. The hook can consume remaining transient entries via cross-chain proxy calls inside the same transaction.
4. **Deferred Consumption**: users / system call `CrossChainProxy` contracts. The proxy forwards to `executeCrossChainCall` on the manager. Top-level calls consume the next entry via `executionIndex++`; reentrant calls (detected via `_insideExecution()`) consume the next `NestedAction` from the active entry.
5. **Per-Entry Verification**: at the end of every entry, the contract verifies the rolling hash, that all `calls[]` were consumed, that all `nestedActions[]` were consumed, and (L1 only) that ether accounting balances per entry.

```
User calls CrossChainProxy.someFunction()
    ├─> CrossChainProxy detects normal vs static context (via tstore self-call)
    │   ├─> normal: forwards to manager.executeCrossChainCall(sender, calldata)
    │   │   ├─> compute actionHash from proxy identity + msg context
    │   │   ├─> if _insideExecution(): consume next NestedAction (rolling-hash bound)
    │   │   └─> else: consume next ExecutionEntry (sequential, by actionHash)
    │   │       ├─> apply state deltas (L1 only)
    │   │       ├─> _processNCalls(entry.callCount): for each call,
    │   │       │     - revertSpan == 0 → route through source proxy.executeOnBehalf
    │   │       │     - revertSpan > 0  → self-call executeInContext (always reverts);
    │   │       │                          decode ContextResult to bridge state
    │   │       ├─> verify _rollingHash == entry.rollingHash
    │   │       ├─> verify counts (calls / nestedActions consumed)
    │   │       └─> return entry.returnData (or revert with it if entry.failed)
    │   └─> static: forwards to manager.staticCallLookup(sender, calldata)
    │       └─> match by (actionHash, callNumber, lastNestedActionConsumed)
    │           replay any sub-calls; check rolling hash; return / revert
```

### L2 Execution (EEZL2)

On L2, `EEZL2` handles cross-chain execution without ZK proofs or rollup state:

- A **system address** loads execution tables via `loadExecutionTable(entries, _staticCalls)`. There is no transient/deferred split on L2 — all entries go to persistent `executions`.
- Local proxy calls go through `executeCrossChainCall(sourceAddress, callData)`. `msg.value` is forwarded to `SYSTEM_ADDRESS` (burn) — no ether accounting.
- `staticCallLookup` works the same as on L1 but only scans persistent `staticCalls`.
- Sequential consumption, rolling-hash verification, and `revertSpan` handling are identical to L1.

There is no `executeIncomingCrossChainCall` and no scope navigation — these belonged to the previous protocol version.

### ETH Balance Tracking (L1)

Each rollup maintains an ETH balance held by the `Rollups` contract. Per-entry, the contract enforces:

```
totalEtherDelta == etherIn - etherOut
```

where `etherIn` is `msg.value` received by the entry-point call (or 0 for `executeL2TX` and immediate entries), and `etherOut` is the sum of `value` fields on every **successful** call inside the entry. Failed calls don't decrement; the manager keeps the ETH.

Rollup balances cannot go negative (`InsufficientRollupBalance` revert on underflow).

L2 has no ether accounting.

## Installation

```bash
# Clone the repository
git clone https://github.com/eez-association/sync-rollups.git
cd sync-rollups

# Install dependencies
forge install
```

## Build & Test

```bash
forge build         # compile contracts
forge test          # run all tests
forge test -vvv     # verbose output
forge fmt           # format code
```

## Usage

### Creating a Rollup

```solidity
Rollups rollups = new Rollups(zkVerifierAddress, startingRollupId);

uint256 rollupId = rollups.registerRollup(
    initialState,      // bytes32
    verificationKey,   // bytes32
    owner              // address
);
```

### Creating a CrossChainProxy

```solidity
address proxy = rollups.createCrossChainProxy(
    originalAddress,    // the contract address this proxy represents
    originalRollupId    // the rollup ID it lives on
);

// Or compute the deterministic address without deploying:
address predicted = rollups.computeCrossChainProxyAddress(
    originalAddress,
    originalRollupId
);
```

### Posting a Batch

```solidity
ExecutionEntry[] memory entries = new ExecutionEntry[](2);

// entries[0]: immediate entry — executed inline by postBatch when transientCount >= 1.
// Used for "pure L2 transactions + L2 transactions that touch L1" — state deltas
// are applied and any cross-chain calls are processed via the flat calls[] array.
entries[0] = ExecutionEntry({
    stateDeltas:   immediateDeltas,
    actionHash:    bytes32(0),
    calls:         immediateCalls,
    nestedActions: immediateNested,
    callCount:     immediateEntryLevelCount,
    returnData:    "",
    failed:        false,
    rollingHash:   immediateRollingHash
});

// entries[1]: deferred — pushed to persistent executions[] (only if the transient
// prefix is fully drained), consumed later by an executeCrossChainCall or executeL2TX.
entries[1] = ExecutionEntry({
    stateDeltas:   deferredDeltas,
    actionHash:    deferredActionHash,
    calls:         deferredCalls,
    nestedActions: deferredNested,
    callCount:     deferredEntryLevelCount,
    returnData:    deferredReturnData,
    failed:        false,
    rollingHash:   deferredRollingHash
});

StaticCall[] memory staticCalls = new StaticCall[](0);

rollups.postBatch(
    entries,
    staticCalls,
    /* transientCount */          1,   // entries[0] runs inline
    /* transientStaticCallCount */ 0,
    /* blobCount */               0,
    /* callData */                "",
    /* proof */                   zkProof
);
```

### Implementing the Meta Hook

If your contract calls `postBatch` and wants to consume the transient entries inline, implement `IMetaCrossChainReceiver`:

```solidity
import {IMetaCrossChainReceiver} from "src/interfaces/IMetaCrossChainReceiver.sol";

contract MyBatcher is IMetaCrossChainReceiver {
    Rollups public immutable rollups;

    function executeMetaCrossChainTransactions() external override {
        require(msg.sender == address(rollups), "only rollups");
        // Drive cross-chain proxy calls here. Each call to a CrossChainProxy
        // forwards to rollups.executeCrossChainCall, which consumes the next
        // transient entry via _consumeAndExecute.
        myProxy.someFunction(args);
    }
}
```

The transient table must be fully drained for the deferred remainder to be published.

## Key Functions

### Rollups (L1)

| Function | Description |
|----------|-------------|
| `registerRollup(initialState, verificationKey, owner)` | Creates a new rollup and returns its ID. |
| `createCrossChainProxy(originalAddress, originalRollupId)` | Deploys a `CrossChainProxy` via CREATE2. |
| `computeCrossChainProxyAddress(originalAddress, originalRollupId)` | Computes the deterministic CREATE2 address. |
| `postBatch(entries, staticCalls, transientCount, transientStaticCallCount, blobCount, callData, proof)` | Posts a batch with ZK proof. Splits entries into transient (inline-consumed) and deferred (persistent). |
| `executeCrossChainCall(sourceAddress, callData)` | Entry point for proxies. Top-level → consumes next entry; reentrant → consumes next `NestedAction`. |
| `executeL2TX()` | Permissionless. Consumes the next entry which must have `actionHash == 0`. Cannot run during execution. |
| `staticCallLookup(sourceAddress, callData)` | View function. Returns/reverts with cached `StaticCall` data, matched by `(actionHash, callNumber, lastNestedActionConsumed)`. |
| `setStateByOwner(rollupId, newStateRoot)` | Owner-only escape hatch (no proof). |
| `setVerificationKey(rollupId, newVerificationKey)` | Owner-only. |
| `transferRollupOwnership(rollupId, newOwner)` | Owner-only. |

### EEZL2 (L2)

| Function | Description |
|----------|-------------|
| `loadExecutionTable(entries, staticCalls)` | System-only. Wipes existing tables and loads new entries / static calls. |
| `executeCrossChainCall(sourceAddress, callData)` | Same shape as L1, but `sourceRollup = ROLLUP_ID` and `msg.value` is forwarded to `SYSTEM_ADDRESS`. |
| `staticCallLookup(sourceAddress, callData)` | Same as L1, but only scans persistent `staticCalls`. |
| `createCrossChainProxy(originalAddress, originalRollupId)` | Permissionless. Same CREATE2 formula as L1. |
| `computeCrossChainProxyAddress(originalAddress, originalRollupId)` | View. |

## Documentation

- [`docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md`](docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md) — formal protocol specification (data model, function specs, rolling-hash details with worked example, invariants, security).
- [`docs/EXECUTION_TABLE_SPEC.md`](docs/EXECUTION_TABLE_SPEC.md) — how to build execution entries (entry structure, action hash, flow patterns for L1↔L2 simple/nested, revert via `revertSpan`, etc.).
- [`docs/CAVEATS.md`](docs/CAVEATS.md) — edge cases and gotchas.

## Security Considerations

- Only authorized proxies can call `executeCrossChainCall` / `staticCallLookup`. `executeL2TX` is permissionless but cannot run during an active execution.
- `lastStateUpdateBlock = block.number` is written immediately after proof verification — before any external call — to enable cross-chain calls during the meta hook and to block re-entrant `postBatch` via the existing same-block guard.
- The meta hook is **untrusted**. If it doesn't drain the transient table fully, the deferred remainder is dropped (no partial publish to persistent storage).
- All L1 state transitions are verified by a single ZK proof per batch. The previous-state binding lives in the proof: `_computeEntryHashes` reads `rollups[id].stateRoot` and folds it into the entry hash, so a stale builder produces a proof that fails verification.
- Per-entry ether accounting on L1 (`totalEtherDelta == etherIn - etherOut`); rollup balances cannot go negative.
- Rolling-hash integrity is the primary defense: a single mismatch anywhere in the execution tree (wrong return data, wrong success/failure, missing/extra calls, wrong nesting) produces a different final hash.
- `revertSpan` rolls back EVM state inside the span while preserving the rolling hash and consumption cursors via the `ContextResult` revert payload.
- Reverting reentrant calls **must** use `StaticCall` (not `NestedAction`) — a `NestedAction` revert rolls back the consumption-index `tstore`, making the consumption silent.
- Static-context detection in `CrossChainProxy` uses the `tstore`/`tload` asymmetry: a self-call to `staticCheck()` attempts a `tstore`, which reverts in static context and not otherwise.
- On L2, only `SYSTEM_ADDRESS` can load execution tables. There is no system-driven `executeIncomingCrossChainCall` — top-level L2 calls always come from user transactions hitting proxies.

## License

MIT
