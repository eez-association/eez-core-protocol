# Caveats

## Calling through cross-chain proxies

- **Opcodes that differ on cross-chain proxies**:
  - These opcodes return information about the proxy itself, not the proxied contract: `delegatecall`, `balance`, `extcodesize`, `extcodecopy`.
  - Block-state opcodes (`blocknumber`, `blockhash`, `blockgaslimit`, `chainid`, `coinbase`, …) reflect the chain the call is executing on, not the source chain — values will differ when the same logical action is observed on L1 vs L2.

- **Indistinguishable revert reasons when calling a proxy**: A caller (contract or EOA) cannot differentiate between a proxy call reverting because the execution table did not contain a matching entry vs. the underlying destination call actually reverting. Both cases bubble up as a revert from the proxy.

- **Proxy ETH recovery is best-effort:** ETH sent to a proxy address before deployment is swept to the recovery address in the constructor, once, ignoring failure, so a recovery address that always rejects ETH cannot block proxy creation. The sweep gets at most 100k gas, so a recipient that burns everything it receives only adds that much to the deployment cost. If the sweep fails the ETH stays in the proxy for good.

## Delivery and execution semantics

- **The `gas` field on a call is a cap, not a guarantee:** `_processNCalls` forwards it with `call{gas: callGas}`, and the EVM gives the callee min(callGas, gas available minus 1/64). If the transaction is running low, the destination gets less than the entry committed to, may fail for that reason alone, and the entry then reverts (or is skipped, for an immediate L2Tx) even though the table was correct. Guaranteeing at least `callGas` would require the manager to check `gasleft()` before every proxy call and revert early; that check is not implemented today, so posters must supply enough gas for the whole batch.

- **Posting does not guarantee delivery of every entry:** consumption forward-scans and skips non-matching entries for good, so composers must account for alternatives and work that are never executed.

- **Cross-rollup calls inside the meta hook only work between rollups verified in the same batch:** a rollup verified by an earlier batch this block is unreachable from the hook (`ExecutionNotFound`); interact with it after `postAndVerifyBatch` returns, or verify both rollups together.

- **Immediate dispatch is not proven:** `immediateEntryCount`, `immediateStaticEntryCount` and `expectedRootPerRollup` are outside the public input, so the poster picks them within the on-chain constraints (counts in range, no L2Tx stranded at the boundary, static prefix only when a meta hook fires). Consuming immediate entries is therefore a collaboration between composer, poster and users: a poster can receive the meta hook in a contract that consumes nothing and let those entries be discarded, so a valid proof alone does not guarantee they execute. When some entries must be processed a certain way, set `bindMsgSenderInPublicInput` so only the intended poster can post the batch, and enforce the policy in that poster's hook.

- **L2 retries reuse the first matching result:** A failed entry restores the cursor, so retrying the same call hash hits the same row; a later row for that hash is only reachable after another successful consumption. This is why the system should load a fresh table for every transaction, or at least whenever the environment those results depend on changes.

## Static-result validity

- **Root pins do not cover uncommitted context:** a static result whose value depends on a timestamp, block number or other context outside the committed state can still be served while the roots are unchanged. EEZ imposes no expiry of its own; capturing such dependencies is up to the rollup's validity rules or to refreshing the table.

## Deployment and trust assumptions

- **Accepted proofs replace queues before deferred root checks:** Every accepted batch replaces the participating rollups' execution/static queues and updates `lastVerifiedBlock`. An old proof that still verifies can therefore replace useful queued work or activate the same-block `setRoot` lock even if its deferred entries cannot execute against the current roots. Root advancement prevents stale state transitions; it does not prevent these posting-side effects. Queue replacement is a liveness policy, and rollup-defined verification context can enforce freshness where needed.

- **Proof domains are a deployment responsibility:** Each rollup is verified on its designated L1. Public inputs do not explicitly bind `block.chainid`, the registry address, or a protocol version; independent deployments must use distinct verification domains. Reusing identical rollup/proof configurations across them is outside the intended model.

## Edge cases

- **Reverts also undo missing-call markers:** An ordinary enclosing revert rolls back the transient rolling hash, including `CALL_NOT_FOUND`. Only the explicit `ContextResult` path carries that hash across its deliberate revert. A caught validation error is reflected only through the execution outcomes that remain recorded.
