# Entry Construction (flatten model)

Authoritative reference for building `ExecutionEntry`, `StaticCall`, `CrossChainCall`, and `NestedAction` in the flatten execution model.

The flatten model replaced the main branch's `ActionType` enum + scope tree + `REVERT_CONTINUE` actions with:

- A flat `CrossChainCall[] calls` array (executed in sequence by `_processNCalls`).
- A flat `NestedAction[] nestedActions` array (consumed by reentrant `executeCrossChainCall` / `_consumeNestedAction`).
- A `bytes32 rollingHash` computed over the tagged event tape of the entire entry execution.
- `CrossChainCall.revertSpan` + `executeInContext` self-call + `ContextResult` error for isolated revert contexts.
- `StaticCall[]` for reverting / view-only calls (looked up by `staticCallLookup` from the proxy's static-context detection path).

There is no `ActionType` enum. The only `Action` struct is off-chain glue used to compute action hashes.

---

## 1. Action and actionHash

```solidity
struct Action {
    uint256 rollupId;       // target rollup
    address destination;    // target contract
    uint256 value;          // ETH sent along with the call
    bytes   data;           // calldata
    address sourceAddress;  // original caller (msg.sender as seen by the source proxy)
    uint256 sourceRollup;   // calling rollup
}

actionHash = keccak256(abi.encode(
    rollupId, destination, value, data, sourceAddress, sourceRollup
))
```

Use `actionHash(Action{...})` from `E2EHelpers.sol` — don't hand-encode in every test.

### Field rules

| Field | Value |
|---|---|
| `rollupId` | For a `call` from chain A to proxy-for-B: the **target** chain (B). For `executeL2TX` entries, the chain where the tx executes. |
| `destination` | Original contract address on the target chain (what the proxy represents). |
| `value` | `msg.value` sent with the call (L2 manager burns this; L1 tracks it via `etherDelta`). |
| `data` | Raw calldata as the proxy receives it. No prefix stripping. |
| `sourceAddress` | The `msg.sender` as seen by the proxy — i.e., the user or calling contract (NOT the proxy). |
| `sourceRollup` | The rollup ID of the source chain (`MAINNET_ROLLUP_ID=0` for L1, `1` for L2). |

Getting one byte wrong anywhere inside `data` or any field → entirely different hash → `ExecutionNotFound`.

---

## 2. StateDelta

```solidity
struct StateDelta {
    uint256 rollupId;
    bytes32 newState;
    int256  etherDelta;  // positive: rollup received ETH; negative: rollup sent ETH
}
```

Rules:

- **L1 entries** track rollup state roots + ether balances. Always non-empty unless the entry is a pure L1 effect.
- **L2 entries** must use `new StateDelta[](0)`. The L2 manager doesn't track rollup state.
- `newState` is arbitrary in tests (we mock the ZK verifier). Use `keccak256("some-descriptive-label")` so traces are readable.
- `etherDelta` sum across all state deltas in an immediate entry must equal zero (ether conservation — enforced by `_applyAndExecute`).

---

## 3. CrossChainCall

```solidity
struct CrossChainCall {
    address destination;
    uint256 value;
    bytes   data;
    address sourceAddress;
    uint256 sourceRollup;
    uint256 revertSpan;   // >0 = open an isolated revert context over the next `revertSpan` calls
}
```

`_processNCalls` iterates `entry.calls[]` starting at `_currentCallNumber`. For each call:
- If `revertSpan == 0`: execute normally. The source proxy (for `(sourceAddress, sourceRollup)`) is auto-created if missing, then `proxy.call{value}(abi.encodeCall(executeOnBehalf, (destination, data)))`.
- If `revertSpan > 0`: the manager self-calls `executeInContext(revertSpan)` which runs the next `revertSpan` calls in an isolated context that **always reverts**. The revert carries a `ContextResult` error with `(rollingHash, lastNestedActionConsumed, currentCallNumber)`; the outer loop decodes these and restores state, then skips past the span.

### When to set `revertSpan`

- A call (or group of consecutive calls) whose on-chain effects need to be atomically rolled back despite the surrounding entry committing. Typical use: try-call-retry patterns.
- Only the **first** call in a span carries `revertSpan > 0`; the other calls in the span have `revertSpan == 0`.
- The span counts from that first call inclusive. `revertSpan = 2` → that call plus the next one execute together in isolated context.

---

## 4. NestedAction

```solidity
struct NestedAction {
    bytes32 actionHash;     // what triggers consumption via reentrant executeCrossChainCall
    uint256 callCount;      // iterations to run from entry.calls[] during this nested consumption
    bytes   returnData;     // precomputed bytes returned to the reentrant caller
}
```

Consumed sequentially by `_consumeNestedAction`:

1. `_lastNestedActionConsumed++`
2. Next entry `nestedActions[idx]` picked up
3. `_rollingHash = keccak(hash, NESTED_BEGIN, nestedNumber)`
4. `_processNCalls(nested.callCount)` — pulls `callCount` more calls from the SAME `entry.calls[]` array (the flat array is shared).
5. `_rollingHash = keccak(hash, NESTED_END, nestedNumber)`
6. Returns `nested.returnData` to the reentrant caller.

### Rules

- **Must succeed.** A revert inside `_processNCalls` during a nested action would roll back `_lastNestedActionConsumed++`, producing inconsistent state. For reverting reentrant calls, use `StaticCall` instead (see §6).
- **Flat `calls[]` is shared.** An entry's `calls[]` is a single flat array. When a nested action consumes `callCount` calls, they come from the same array. So `entry.callCount + Σ nestedActions[i].callCount = entry.calls.length`.
- **`actionHash` matches the reentrant call.** The source contract inside the currently-executing call must itself call a proxy, producing `actionHash = keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup))` — and that must equal `nestedActions[_lastNestedActionConsumed].actionHash`.

---

## 5. ExecutionEntry

```solidity
struct ExecutionEntry {
    StateDelta[]      stateDeltas;
    bytes32           actionHash;      // bytes32(0) = immediate (first entry only)
    CrossChainCall[]  calls;           // flat array, consumed in order
    NestedAction[]    nestedActions;   // flat array, consumed in order by reentrant calls
    uint256           callCount;       // entry-level iterations from calls[] on first trigger
    bytes             returnData;      // precomputed bytes surfaced by the proxy to the caller
    bool              failed;          // replay returnData as revert AFTER entry commits
    bytes32           rollingHash;     // tagged-hash tape expected at entry completion
}
```

### Field-by-field notes

- `stateDeltas` — L1 non-empty when the entry should update a rollup's state/ether balance; L2 must be `new StateDelta[](0)`.
- `actionHash` — `bytes32(0)` only if this is the **first** entry and should execute immediately as a state commitment. For deferred entries, must match the action that will trigger it.
- `calls` — flat array of all calls executed during this entry, including calls consumed by nested actions. Do **not** separate into "top-level" vs "nested" subarrays.
- `nestedActions` — flat array of precomputed returns, one per reentrant cross-chain call expected during execution.
- `callCount` — the number of `calls[]` iterations `_processNCalls` will run at the **top level** (i.e., when the entry is first triggered). If the entry has no top-level calls but reentrancy happens inside the triggering call, `callCount = 0`.
- `returnData` — what the proxy surfaces to the caller. For a `void`-returning destination, use `""`. For a `uint256` return, use `abi.encode(uint256(1))`. For a `string` return, use `abi.encode("World")`.
- `failed` — dangerous. When `true`, after the entry fully executes (deltas applied + rolling hash verified), the return data is replayed as a revert. **Do not** set on entries that must be consumed in order — see §8.
- `rollingHash` — see §7.

---

## 6. StaticCall — the reverting / view path

```solidity
struct StaticCall {
    bytes32    actionHash;
    bytes      returnData;
    bool       failed;              // replay returnData as revert
    bytes32    stateRoot;           // diagnostics only, not enforced on-chain
    uint64     callNumber;          // matches _currentCallNumber at lookup time
    uint64     lastNestedActionConsumed;  // matches _lastNestedActionConsumed at lookup time
    CrossChainCall[] calls;         // static-context calls whose rolling hash is verified
    bytes32    rollingHash;         // expected hash of the static calls' (success, retData) tape
}
```

The proxy's `_fallback` detects STATICCALL context via a self-call to `staticCheck()` (which attempts `tstore` — reverts in static context). When detection succeeds, the proxy routes to `manager.staticCallLookup(sender, data)` (view function).

`staticCallLookup` linearly scans `staticCalls[]` matching on `(actionHash, callNumber, lastNestedActionConsumed)` — the `callNumber` and `lastNestedActionConsumed` fields disambiguate multiple static calls within the same broader execution. If the match has calls, they're executed via `staticcall` and their rolling hash checked. If `failed`, the returnData is replayed as a revert.

### Use StaticCall when

- A view call on a cross-chain proxy (the natural case for solidity `view` functions).
- A reverting nested call whose revert must be precomputed (wrapping it in a `revertSpan` would also work, but `StaticCall` is cheaper).

### Rules

- `callNumber` must equal `_currentCallNumber` at the moment the static lookup fires. For a top-level static query (outside any entry execution), `callNumber = 0, lastNestedActionConsumed = 0`.
- `StaticCall.calls[]` executes in static context (cannot CREATE2 the source proxy — it must already exist). Rolling hash formula: `keccak256(prev, success, retData)` per call.

---

## 7. Rolling hash — tagged-hash replay

Tags (uint8 constants):
- `CALL_BEGIN = 1`
- `CALL_END = 2`
- `NESTED_BEGIN = 3`
- `NESTED_END = 4`

Per-step formula (matches `Rollups._processNCalls` / `_consumeNestedAction` exactly):

```
before call n (1-indexed):   hash = keccak256(prev, CALL_BEGIN, n)
after  call n:               hash = keccak256(prev, CALL_END, n, success, retData)
before nested m (1-indexed): hash = keccak256(prev, NESTED_BEGIN, m)
after  nested m:             hash = keccak256(prev, NESTED_END, m)
```

Use `RollingHashBuilder` from `E2EHelpers.sol`:

```solidity
using RollingHashBuilder for bytes32;

bytes32 h = bytes32(0);
h = h.appendCallBegin(1);
// any nested reentrancy during call 1:
h = h.appendNestedBegin(1);
// nested action's own _processNCalls iterations:
// for each call k inside nestedAction[0].callCount:
//     h = h.appendCallBegin(k')
//     h = h.appendCallEnd(k', success, retData)
h = h.appendNestedEnd(1);
h = h.appendCallEnd(1, true, retData_of_call_1);
```

### Key subtleties

- `retData` in `CALL_END` is the raw bytes returned by `destination.call(data)`. For `void`-returning functions, that's empty bytes (`""`).
- Call numbers are **global 1-indexed counters** across the entire entry. If calls[0] has a nested action that triggers 1 inner call, the inner call gets `callNumber = 2` (it advances `_currentCallNumber`).
- Nested numbers are **1-indexed** per entry (`idx + 1` in `_consumeNestedAction`).
- Nested actions share `calls[]` with the outer entry. A nested action with `callCount=1` consumes one more `calls[]` entry, which itself could have a nested action, and so on recursively.

---

## 8. `failed: true` — the trap

The simplest case is "this entry exists so that when its actionHash fires, the proxy reverts with specific data". Setting `failed: true` + `returnData: revertBytes` does this — but watch the ordering:

- `_consumeAndExecute` does `executionIndex++` BEFORE calling `_applyAndExecute`.
- After `_applyAndExecute` returns, `failed` causes a revert with `returnData`.
- That revert rolls back the entire tx, **including the `executionIndex++`**.
- Next time the same action fires, the entry is still at the same index and still reverts → table is permanently stuck.

**Safe use:** only set `failed: true` on entries that are the last thing to execute in that tx context (the full tx reverts anyway). For recoverable reverts, use `StaticCall` (proxy routes there automatically in static context) or `revertSpan` (the outer loop catches the `ContextResult`).

---

## 9. Patterns by scenario

### Simple L1→L2 with precomputed return
- One L1 entry: `calls=[], nestedActions=[], callCount=0, returnData=abi.encode(value)`.
- `stateDeltas`: one delta for L2 `(rollupId=1, newState, etherDelta=0)`.
- `rollingHash = bytes32(0)` (no calls, no nesting).
- Example: `script/e2e/one_way/L1_to_L2/counter/E2ECounter.s.sol`.

### Simple L2→L1
- One L2 entry: `calls=[], nestedActions=[], callCount=0, returnData=abi.encode(value)`.
- `stateDeltas = []` (L2 never tracks state).
- Example: `script/e2e/one_way/L2_to_L1/counterL2/E2ECounterL2.s.sol`.

### Value transfer (bridge)
- Like simple L1→L2, but action has `value > 0` and the L2 state delta has `etherDelta: int256(value)`.
- Example: `script/e2e/one_way/L1_to_L2/bridge/E2EBridge.s.sol`.

### Multi-call same target
- Two L1 entries with the **same** `actionHash` but different `returnData`. The two calls to the proxy inside the triggering user tx consume them in order (entry 0 returns 1, entry 1 returns 2).
- Example: `script/e2e/multi_call/L1_to_L2/multi-call-twice/E2EMultiCallTwice.s.sol`.

### Multi-call different targets
- Two L1 entries with **different** `actionHash` values, one per proxy. Still sequential consumption.
- Example: `script/e2e/multi_call/L1_to_L2/multi-call-two-diff/E2EMultiCallTwoDiff.s.sol`.

### Nested (calls + nestedActions)
- Outer L1 entry with `calls=[one_call]`, `callCount=1`, plus `nestedActions=[one_return]`. The user tx triggers consumption; `calls[0]` invokes a contract that reentrantly calls another proxy → `_consumeNestedAction` matches `nestedActions[0]`.
- Rolling hash: `CALL_BEGIN(1) → NESTED_BEGIN(1) → (any inner calls) → NESTED_END(1) → CALL_END(1, true, retDataOfCall1)`.
- Example: `script/e2e/nested/L1_to_L2/nestedCounter/E2ENestedCounter.s.sol`.

### Revert with static lookup
- Trigger proxy call is a view or known-revert call. No deferred entry. Instead: a `StaticCall[]` entry with matching `actionHash, callNumber=0, lastNestedActionConsumed=0, failed=true, returnData=revertBytes`. The proxy's static-context detection routes through `staticCallLookup`.
- Use when the revert happens outside any entry execution (e.g., user-initiated view that must fail deterministically).

### Revert with isolated context (revertSpan)
- Outer L1 entry with calls[] where one call has `revertSpan > 0`. That call plus the next `revertSpan-1` calls run inside `executeInContext`. The on-chain loop catches the `ContextResult` error and advances past the span. The rolling hash still closes because the `ContextResult` payload contains the updated `_rollingHash` and `_lastNestedActionConsumed`.
- Use when a group of calls must revert atomically but the surrounding entry commits.

### Deep reentrancy (reentrant chain)
- Entry with one top-level call that internally triggers a chain of reentrant proxy calls. Each reentrancy consumes one `nestedActions[i]`. `calls[]` stays length-1; `nestedActions[]` is as deep as the chain.
- The rolling hash tape grows: `CALL_BEGIN(1) → NESTED_BEGIN(1) → NESTED_BEGIN(2) → ... → NESTED_END(2) → NESTED_END(1) → CALL_END(1, true, "")`.

---

## 10. Common pitfalls

| Pitfall | Symptom | Fix |
|---|---|---|
| Wrong `sourceAddress` (used the proxy instead of the caller) | `ExecutionNotFound` | `sourceAddress` is the original caller — `msg.sender` as seen by the source proxy. |
| Forgot `sourceRollup` for L2→L1 | `ExecutionNotFound` | L2-originated calls have `sourceRollup = L2_ROLLUP_ID`. |
| `callCount != calls.length` (when no revertSpan) | `UnconsumedCalls` or `UnexpectedContextRevert` | For standard entries, `callCount = calls.length`. |
| Off-by-one on rolling hash iterations | `RollingHashMismatch` | Use `RollingHashBuilder`, replay exactly. Double-check nested call counts. |
| `retData` in `CALL_END` set to something other than what `destination.call` returns | `RollingHashMismatch` | For `void` destination functions, `retData = ""`. For returning functions, the raw ABI-encoded bytes. |
| `failed: true` on a non-terminal entry | Execution table permanently stuck | Only set `failed` on the last entry consumed in that tx context; for recoverable reverts use `StaticCall` or `revertSpan`. |
| L2 entry with non-empty `stateDeltas` | The L2 manager ignores them (silent). Verify hash still mismatches on L1 replay | Always `new StateDelta[](0)` for L2 entries. |
| Forgot static-context detection for view calls | Reverts with `UnauthorizedProxy` or infinite loop | A view call from a contract goes through the proxy's STATICCALL path; ensure there's a matching `StaticCall` entry, or mark the call `view` on the proxy-side interface. |
