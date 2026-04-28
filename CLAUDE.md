# L1/L2 Sync Smart Contracts

## Project Overview

This is a Foundry-based Solidity project implementing smart contracts for L1/L2 rollup synchronization. The system allows L2 executions to be verified and executed on L1 using ZK proofs, and on L2 via system-loaded execution tables.

## Build & Test Commands

```bash
forge build          # Compile contracts
forge test           # Run all tests
forge test -vvv      # Run tests with verbose output
forge fmt            # Format code
```

## Architecture

### Core Contracts

- **Rollups.sol**: L1 contract managing rollup state roots, ZK-proven batch posting with transient/deferred execution split, the `IMetaCrossChainReceiver` hook for in-tx consumption, and flat sequential cross-chain call execution with rolling-hash verification.
- **IMetaCrossChainReceiver.sol** (`src/interfaces/`): Callback interface invoked on `postBatch`'s `msg.sender` (when it has code) so the sender can consume transient entries via cross-chain proxy calls within the same transaction.
- **CrossChainProxy.sol**: Proxy contract deployed via CREATE2 for each (address, rollupId) pair. Routes incoming calls to the manager via `executeCrossChainCall` (or `staticCallLookup` in static context, detected via a `tstore` self-call), and forwards manager-driven outbound calls via `executeOnBehalf`.
- **CrossChainManagerL2.sol**: L2-side contract for cross-chain execution. No ZK proofs, no rollup registry, no state deltas — a system address loads execution tables which are consumed sequentially by proxy calls.
- **IZKVerifier.sol**: Interface for external ZK proof verification.

### Data Types

The protocol uses a **flat sequential execution model**: every entry contains a flat list of `CrossChainCall`s processed sequentially, with reentrant calls resolved via a parallel `NestedAction[]` table and integrity verified by a single `rollingHash` per entry.

```solidity
// Off-chain only — used by tooling to compute actionHash.
// Not stored on-chain; the contracts reconstruct the hash from individual fields.
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
    bytes32 newState;       // post-execution state root (previous root is bound by the proof, not stored here)
    int256  etherDelta;     // signed ETH change for this rollup
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
    CrossChainCall[] calls;          // flat array of ALL calls in execution order
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
    CrossChainCall[] calls;                      // optional sub-calls (executed via STATICCALL)
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

### Key Functions (L1 — Rollups)

1. **createRollup(initialState, verificationKey, owner)** — creates a new rollup.
2. **createCrossChainProxy(originalAddress, originalRollupId)** — deploys a `CrossChainProxy` via CREATE2.
3. **postBatch(entries, _staticCalls, transientCount, transientStaticCallCount, blobCount, callData, proof)** — posts a batch with ZK proof.
   - The first `transientCount` entries go to `_transientExecutions` (cleared at end of `postBatch`); the remainder is published to persistent `executions` only if the transient table is fully drained.
   - If `transientCount >= 1` and `entries[0].actionHash == 0`, that first entry is executed immediately (state deltas + flat call processing + rolling hash verification).
   - After the immediate entry, if `msg.sender` has code, `IMetaCrossChainReceiver(msg.sender).executeMetaCrossChainTransactions()` is called so the sender can consume the rest of the transient entries via proxy calls.
   - `transientCount == 0` means no immediate execution and no meta-hook consumption — all entries go straight to persistent storage. The static-call split via `transientStaticCallCount` works the same way.
4. **executeCrossChainCall(sourceAddress, callData)** — entry point for proxies. Top-level call → `_consumeAndExecute` (consumes next entry via `executionIndex++`); reentrant call (`_insideExecution() == true`) → `_consumeNestedAction` (consumes next `NestedAction` via `_lastNestedActionConsumed++`).
5. **executeL2TX()** — permissionless. Consumes the next entry, which must have `actionHash == bytes32(0)`. Cannot run while `_insideExecution()` is true.
6. **staticCallLookup(sourceAddress, callData)** — view function. Looks up a `StaticCall` by `(actionHash, callNumber, lastNestedActionConsumed)`, scanning `_transientStaticCalls` first then persistent `staticCalls`. Replays cached sub-calls in static context, then either returns `returnData` or reverts with it (when `failed`).
7. **setStateByOwner / setVerificationKey / transferRollupOwnership** — owner-only escape hatches (no proof, do not bump `lastStateUpdateBlock`).
8. **computeCrossChainProxyAddress(originalAddress, originalRollupId)** — computes the deterministic CREATE2 address. (Two parameters — no `domain` / `block.chainid`.)

### Key Functions (L2 — CrossChainManagerL2)

1. **loadExecutionTable(entries, _staticCalls)** — system-only. Wipes existing tables, loads new entries / static calls, sets `lastLoadBlock`.
2. **executeCrossChainCall(sourceAddress, callData)** — same shape as L1, but `sourceRollup` in the action hash is `ROLLUP_ID` (not `MAINNET_ROLLUP_ID`), and any `msg.value` is forwarded to `SYSTEM_ADDRESS` (burn). No state deltas, no ether accounting.
3. **staticCallLookup(sourceAddress, callData)** — same key as L1. Scans only persistent `staticCalls` (no transient table on L2).
4. **createCrossChainProxy(originalAddress, originalRollupId)** — same CREATE2 formula as L1.

### Execution Flow

1. **Load** — `postBatch` (L1) or `loadExecutionTable` (L2) wipes existing tables, populates new entries / static calls, sets `lastStateUpdateBlock` / `lastLoadBlock`. On L1 the leading prefixes go to `_transientExecutions` / `_transientStaticCalls`. `lastStateUpdateBlock` is written **before** any external call so cross-chain calls work during the meta hook and re-entrant `postBatch` is blocked.
2. **Immediate entry (L1 only)** — if `entries[0].actionHash == 0` and `transientCount >= 1`, run it inline: apply state deltas, process its flat `calls[]`, verify rolling hash, ether accounting. `_transientExecutionIndex` advances to 1.
3. **Meta hook (L1 only)** — if `msg.sender` has code, `IMetaCrossChainReceiver.executeMetaCrossChainTransactions()` is called. The hook consumes remaining transient entries via cross-chain proxy calls.
4. **Deferred publish (L1)** — if `_transientExecutionIndex == _transientExecutions.length` (transient drained cleanly), `entries[transientCount..]` and `_staticCalls[transientStaticCallCount..]` are pushed to persistent storage. Otherwise the remainder is dropped.
5. **Cleanup (L1)** — wipe `_transientExecutions` / `_transientStaticCalls`, reset `_transientExecutionIndex`.
6. **Deferred consumption** — users / system call proxies, which forward to `executeCrossChainCall`. Sequential `executionIndex++`. The next entry's `actionHash` must equal the computed hash; mismatch reverts `ExecutionNotFound`.
7. **Per-entry checks** — at the end of every entry execution, the contract verifies `_rollingHash == entry.rollingHash`, `_currentCallNumber == entry.calls.length`, `_lastNestedActionConsumed == entry.nestedActions.length`, and (L1 only) `totalEtherDelta == etherIn - etherOut`.

### Rolling Hash

A single `bytes32 rollingHash` per entry covers every call result and every nesting boundary. Four tagged events update the accumulator:

```
CALL_BEGIN   (1)   keccak256(prev, 0x01, callNumber)
CALL_END     (2)   keccak256(prev, 0x02, callNumber, success, retData)
NESTED_BEGIN (3)   keccak256(prev, 0x03, nestedNumber)
NESTED_END   (4)   keccak256(prev, 0x04, nestedNumber)
```

A single mismatch anywhere — wrong return data, wrong success/failure flag, missing or extra calls, incorrect nesting structure — produces a different final hash and is caught with one comparison. See `docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md` §E for the full specification (formulas, worked example, multi-phase static-call disambiguation).

### `revertSpan`

`revertSpan > 0` opens an isolated EVM context for the next `revertSpan` calls. The processor self-calls `executeInContext(revertSpan)` which always reverts with `error ContextResult(rollingHash, lastNestedActionConsumed, currentCallNumber)`. The EVM rolls back state inside the span, but the three values escape via the revert payload — the outer flow restores them so the rolling hash and counters reflect what happened inside the span.

### `NestedAction` vs `StaticCall`

| Situation | Use |
|---|---|
| Reentrant call that **succeeds** | `NestedAction` |
| Reentrant call that **reverts** (caller catches with try/catch) | `StaticCall` with `failed = true` |
| Reentrant cross-chain `STATICCALL` (read-only) | `StaticCall` with `failed = false` |
| Top-level call that should fail | `entry.failed = true` (immediate entry only) — or wrap in `revertSpan` |

Reverting reentrant calls cannot be `NestedAction` — the failed call's revert rolls back the consumption index `tstore`, making consumption silent. `StaticCall` is content-addressed by `(actionHash, callNumber, lastNestedActionConsumed)` and replays the cached revert deterministically.

`_consumeNestedAction` implements the routing: NestedAction at the cursor wins; on miss, it falls back to a `failed=true` `StaticCall` at the same `(actionHash, callNumber, lastNestedActionConsumed)` and reverts with the cached `returnData`. The fallback bumps no cursor, so the EVM revert has nothing to roll back. `staticCallLookup` (real STATICCALL frames) handles both `failed=true` and `failed=false` entries.

### CREATE2 Address Derivation

```
salt          = keccak256(abi.encodePacked(originalRollupId, originalAddress))
bytecodeHash  = keccak256(creationCode || abi.encode(manager, originalAddress, originalRollupId))
proxyAddress  = address(uint160(uint256(keccak256(0xff || manager || salt || bytecodeHash))))
```

`computeCrossChainProxyAddress(originalAddress, originalRollupId)` takes two parameters — there is no `domain` / `block.chainid` in the salt.

## Documentation

- `docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md` — formal protocol specification (data model, function specs, rolling-hash details with worked example, invariants, security).
- `docs/EXECUTION_TABLE_SPEC.md` — how to build execution entries (entry structure, action hash, flow patterns).
- `docs/CAVEATS.md` — edge cases and gotchas.
- `docs/CHANGES_FROM_PREVIOUS.md` — migration notes from the legacy scope-tree / `ActionType` model. Read only when porting old code/docs or chasing a stale reference.

## Testing

Tests use a `MockZKVerifier` that accepts all proofs by default. Set `verifier.setVerifyResult(false)` to test proof rejection.
