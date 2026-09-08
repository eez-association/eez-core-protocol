# Caveats

## Calling through cross-chain proxies

- **Opcodes that differ on cross-chain proxies**:
  - These opcodes return information about the proxy itself, not the proxied contract: `delegatecall`, `balance`, `extcodesize`, `extcodecopy`.
  - Block-state opcodes (`blocknumber`, `blockhash`, `blockgaslimit`, `chainid`, `coinbase`, …) reflect the chain the call is executing on, not the source chain — values will differ when the same logical action is observed on L1 vs L2.

- **Indistinguishable revert reasons when calling a proxy**: A caller (contract or EOA) cannot differentiate between a proxy call reverting because the execution table did not contain a matching entry vs. the underlying destination call actually reverting. Both cases bubble up as a revert from the proxy.

- **Proxy ETH recovery is best-effort:** ETH sent to a proxy address before deployment is swept to the recovery address in the constructor, once, ignoring failure, so a recovery address that always rejects ETH cannot block proxy creation. The sweep gets at most 100k gas, so a recipient that burns everything it receives only adds that much to the deployment cost. If the sweep fails the ETH stays in the proxy for good.

## Delivery and execution semantics

- **Optional alternatives and best-effort execution:** Forward scanning intentionally skips earlier entries when a later candidate matches. Posting does not guarantee delivery of every entry; composers must account for omitted alternatives and work.

- **L2 retries reuse the first matching result:** A failed entry restores the cursor, so retrying the same call hash hits the same row; a later row for that hash is only reachable after another successful consumption. This is why the system should load a fresh table for every transaction, or at least whenever the environment those results depend on changes.

- **Meta hooks cannot reuse other batches' same-block verifications or queues:** All rollups and entries needed for cross-chain calls in the hook must be verified and supplied in the current batch. Calls resolve only against its transient tables or the executing entry's nested-call table. This isolation is intentional; other batches' queues can be used after `postAndVerifyBatch` finishes, subject to normal validity checks.

- **Immediate dispatch is not proven:** `immediateEntryCount`, `immediateStaticEntryCount` and `expectedRootPerRollup` are outside the public input, so the poster picks them within the on-chain constraints (counts in range, no L2Tx stranded at the boundary, static prefix only when a meta hook fires). Consuming immediate entries is therefore a collaboration between composer, poster and users: a poster can receive the meta hook in a contract that consumes nothing and let those entries be discarded, so a valid proof alone does not guarantee they execute. When some entries must be processed a certain way, set `bindMsgSenderInPublicInput` so only the intended poster can post the batch, and enforce the policy in that poster's hook.

## Static-result validity

Static results are reusable while the state they were computed from is still the live state: L1 top-level static entries stay matchable across blocks as long as every root pin holds, L2 ones only in the block they were loaded, and nested reads are pinned to their host entry's position. None of that covers dependencies outside committed state. A read whose result depends on a timestamp, block number or other uncommitted context can still be served from an unchanged root. Capturing such dependencies is up to the rollup's validity rules, or to refreshing the table; EEZ imposes no expiry of its own.

## Deployment and trust assumptions

- **Accepted proofs replace queues before deferred root checks:** Every accepted batch replaces the participating rollups' execution/static queues and updates `lastVerifiedBlock`. An old proof that still verifies can therefore replace useful queued work or activate the same-block `setRoot` lock even if its deferred entries cannot execute against the current roots. Root advancement prevents stale state transitions; it does not prevent these posting-side effects. Queue replacement is a liveness policy, and rollup-defined verification context can enforce freshness where needed.

- **Proof domains are a deployment responsibility:** Each rollup is verified on its designated L1. Public inputs do not explicitly bind `block.chainid`, the registry address, or a protocol version; independent deployments must use distinct verification domains. Reusing identical rollup/proof configurations across them is outside the intended model.

- **The L2 system address is chain-defined and trusted:** Zero is permitted for chains that support that system-caller convention. The configured address must be node-controlled and unavailable to adversarial or reentrant calls, including during ETH transfers to it. Table replacement relies on this assumption; no additional execution guard is imposed.

## Edge cases

- **Reverts also undo missing-call markers:** An ordinary enclosing revert rolls back the transient rolling hash, including `CALL_NOT_FOUND`. Only the explicit `ContextResult` path carries that hash across its deliberate revert. A caught validation error is reflected only through the execution outcomes that remain recorded.
