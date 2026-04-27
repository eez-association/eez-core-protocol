# Caveats

## Edge Cases

- **Indistinguishable revert reasons when calling a proxy**: A caller (contract or EOA) cannot differentiate between a proxy call reverting because the execution table did not contain a matching entry vs. the underlying destination call actually reverting. Both cases bubble up as a revert from the proxy.

- **Opcodes that differ on cross-chain proxies**:
  - These opcodes return information about the proxy itself, not the proxied contract: `delegatecall`, `balance`, `extcodesize`, `extcodecopy`.
  - Block-state opcodes (`blocknumber`, `blockhash`, `blockgaslimit`, `chainid`, `coinbase`, …) reflect the chain the call is executing on, not the source chain — values will differ when the same logical action is observed on L1 vs L2.

- **Reverting reentrant calls must use `StaticCall`, not `NestedAction`**: All entries in `entry.nestedActions[]` must describe **successful** reentrant cross-chain calls. A reverted nested call rolls back transient storage (including `_lastNestedActionConsumed` and `_currentCallNumber`), making it impossible to distinguish "the call was made and reverted" from "the call was never made". Build any reverting reentrant call as a `StaticCall` with `failed = true` instead — `StaticCall` is content-addressed by `(actionHash, callNumber, lastNestedActionConsumed)`, so the revert is replayed deterministically without losing position in the execution stream.

- **Same-block consumption is mandatory**: Every entry posted by `postBatch` (L1) or `loadExecutionTable` (L2) must be consumed in the same block it was loaded — `executeCrossChainCall`, `executeL2TX`, and `staticCallLookup` all guard on `lastStateUpdateBlock == block.number` (L1) or `lastLoadBlock == block.number` (L2). Entries that survive the block are silently dropped on the next load: the table is `delete`d at the start of every load.

- **Partial transient consumption drops the deferred remainder**: When `postBatch` runs the immediate entry (`entries[0].actionHash == 0`) and fires the `IMetaCrossChainReceiver` hook on `msg.sender`, the deferred remainder (`entries[transientCount..]` and `_staticCalls[transientStaticCallCount..]`) is published to persistent storage **only** if the hook drained the transient table completely (`_transientExecutionIndex == _transientExecutions.length`). If the hook reverts mid-batch or simply doesn't consume every transient entry, the remainder is discarded. The ZK proof attests to the batch as an ordered group, so a partial prefix can't be soundly extended.

- **Static call disambiguation by `(callNumber, lastNestedActionConsumed)`**: A single deferred entry may issue several STATICCALLs with the same `actionHash` at different points in its execution tree. `staticCalls[]` is matched by `(actionHash, callNumber, lastNestedActionConsumed)` — the builder must record the values of `_currentCallNumber` and `_lastNestedActionConsumed` at the exact moment each STATICCALL is issued, otherwise the lookup reverts with `ExecutionNotFound`.

- **`revertSpan` is rewritten in storage during execution**: When the call processor encounters `entry.calls[i].revertSpan != 0`, it temporarily zeroes that field in storage before self-calling `executeInContext`, and restores it after the catch. If a nested execution path observes `entry.calls[i]` while the field is zeroed (e.g., another contract reads the public `executions(uint256)` getter mid-flight), it will see the cleared value. This is intentional — the inner call must see `revertSpan == 0` to avoid recursively opening another context — but external observers should not snapshot `entry.calls` during a running batch.

- **`executeL2TX` cannot run during an active execution**: `executeL2TX` reverts with `L2TXNotAllowedDuringExecution` whenever `_insideExecution()` is true. L2TX entries are top-level only; reentrant calls must use the proxy path.

- **Sequential consumption is strict**: Entries are consumed in the exact order they were posted. `_consumeAndExecute` increments `executionIndex` (or `_transientExecutionIndex`) by one each call and reverts with `ExecutionNotFound` if the next entry's `actionHash` doesn't match the expected hash. There is no hash-based search and no swap-and-pop — a single out-of-order call from the prover invalidates the rest of the batch.

- **`failed` semantics on entries**: `ExecutionEntry.failed = true` reverts the top-level call with `entry.returnData` after rolling-hash and call-count verification. It is intended for terminal failure of an immediate entry only; deferred entries that reach this path roll back `executionIndex++`, permanently blocking the rest of the table.
