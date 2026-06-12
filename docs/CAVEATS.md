# Caveats

## Edge Cases

- **One deterministic consumption order — no alternative/candidate entries in the persistent queues**: each rollup's `executionQueue` (and the L2 `executions` table) encodes exactly ONE valid consumption order. A persistent entry that reverts mid-execution (`StateRootMismatch`, `RollingHashMismatch`, …) reverts the whole consuming transaction WITHOUT advancing the cursor — it blocks the queue rather than being skipped, so publishing several candidate entries and letting "whichever succeeds" apply does NOT work in the persistent path. The ONE exception is the IMMEDIATE prefix: `attemptApplyImmediate` wraps each immediate entry in try/catch, so a reverting candidate emits `ImmediateEntrySkipped` and the cursor still advances — alternatives gated by `StateDelta.currentState` CAN be stacked there, and only the one matching the live root applies.

- **The transient phase is self-contained — no cross-batch interactions inside the meta hook**: while a `postAndVerifyBatch` is mid-flight (`_transientExecutions` non-empty: the immediate-entry drain plus the meta hook window), ALL resolution is served exclusively from that batch's own transient tables — execution entries (`_consumeAndExecute` routes everything through the global transient cursor) AND top-level lookups (`staticCallLookup` / `_tryRevertedTopLevelLookup` never fall through to the persistent queues). A rollup verified by an EARLIER batch in the same block passes the block gate, but any call to it during the hook misses with `ExecutionNotFound`. Consequence: cross-rollup interactions inside the meta hook are only supported between rollups verified TOGETHER in the same batch; interactions with anything else must either wait until the batch finishes (persistent consumption) or be re-verified jointly in one batch.

- **Indistinguishable revert reasons when calling a proxy**: A caller (contract or EOA) cannot differentiate between a proxy call reverting because the execution table did not contain a matching entry vs. the underlying destination call actually reverting. Both cases bubble up as a revert from the proxy.

- **Opcodes that differ on cross-chain proxies**:
  - These opcodes return information about the proxy itself, not the proxied contract: `delegatecall`, `balance`, `extcodesize`, `extcodecopy`.
  - Block-state opcodes (`blocknumber`, `blockhash`, `blockgaslimit`, `chainid`, `coinbase`, …) reflect the chain the call is executing on, not the source chain — values will differ when the same logical action is observed on L1 vs L2.
