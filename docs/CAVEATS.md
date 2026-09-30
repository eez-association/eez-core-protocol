# Caveats

## Calling through cross-chain proxies

- **Opcodes that differ on cross-chain proxies**:
  - These opcodes return information about the proxy itself, not the proxied contract: `delegatecall`, `balance`, `extcodesize`, `extcodecopy`.
  - Block-state opcodes (`blocknumber`, `blockhash`, `blockgaslimit`, `chainid`, `coinbase`, …) reflect the chain the call is executing on, not the source chain — values will differ when the same logical action is observed on L1 vs L2.

- **Indistinguishable revert reasons when calling a proxy**: A caller (contract or EOA) cannot differentiate between a proxy call reverting because the execution table did not contain a matching entry vs. the underlying destination call actually reverting. Both cases bubble up as a revert from the proxy.

- **Proxy ETH recovery is best-effort:** ETH sent to a proxy address before deployment is swept to the recovery address in the constructor, once, ignoring failure, so a recovery address that always rejects ETH cannot block proxy creation. The sweep gets at most 100k gas, so a recipient that burns everything it receives only adds that much to the deployment cost. If the sweep fails the ETH stays in the proxy for good.

## Delivery and execution semantics

- **Gas-budget checks are estimates:** Both L1 and L2 check `_hasEnoughCallGas` before dispatching calls with non-zero `gas`. A detected shortage stops the local call array and folds `CALL_INSUFFICIENT_GAS` into the rolling hash; valid proofs must exclude that marker, so hash validation rejects executions that retain it. An ordinary enclosing revert can erase the marker. Static-entry execution instead reverts with `InsufficientCallGas`. The estimate excludes account-creation costs, return-data processing, and the rest of the entry, so it is not an unconditional gas-delivery or completion guarantee. A `gas` value of `0` skips the check and forwards available gas subject to EVM forwarding limits. Posters must still fund the whole batch.

- **Posting does not guarantee delivery of every entry:** consumption forward-scans and skips non-matching entries for good, so composers must account for alternatives and work that are never executed.

- **Cross-rollup calls inside the meta hook only work between rollups verified in the same batch:** a rollup verified by an earlier batch this block is unreachable from the hook (`ExecutionNotFound`); interact with it after `postAndVerifyBatch` returns, or verify both rollups together.

- **Immediate dispatch is not proven:** `immediateEntryCount`, `immediateStaticEntryCount` and `expectedRootPerRollup` are outside the public input, so the poster picks them within the on-chain constraints (counts in range, no L2Tx stranded at the boundary, static prefix only when a meta hook fires). Consuming immediate entries is therefore a collaboration between composer, poster and users: a poster can receive the meta hook in a contract that consumes nothing and let those entries be discarded, so a valid proof alone does not guarantee they execute. When some entries must be processed a certain way, set `bindMsgSenderInPublicInput` so only the intended poster can post the batch, and enforce the policy in that poster's hook.

- **L2 retries reuse the first matching result:** A failed entry restores the cursor, so retrying the same call hash hits the same row; a later row for that hash is only reachable after another successful consumption. The node must refresh tables when state or other dependencies invalidate their cached results. A transaction boundary alone does not require reloading: reuse is allowed while results and lookup contexts remain valid, subject to the manager's same-block gate.

- **Static candidates must be distinguishable:** L1/L2 static lookups select the first candidate whose callback-result hash matches, supporting local writes without changing the cursor, root pins or rolling hash. Identical full execution inputs must produce identical outcomes. Ambiguity arises when a differing dependency, such as gas, is not distinguished by the lookup; builders must reject or restructure conflicting candidates. Retrying callbacks costs gas, and gas alone is not a reliable state identifier.

- **Gas-dependent results can be indistinguishable (accepted support limit):** A view such as `return gasleft() < 400_000 ? 1 : 2` can require different answers for identical calldata. L1 outgoing identity always uses zero gas; L2 outgoing identity does so when `USE_GAS_LEFT == false`. If the reads also share the lookup context and callback-result hash (including zero for two empty callback arrays), both candidates validate and the first wins. Such traces are outside the supported protocol behavior: builders/provers must reject or restructure them. L2 observed-gas keying can distinguish some cases, but does not guarantee unique identities or exact gas-equivalent replay. Candidate retries also spend gas even when outputs are gas-insensitive. See [the gas-sensitive and retry-budget tests](../test/EEZExpressiveness.t.sol).

- **Immediate skips are conditional:** only nonempty caught failures emit `L2TxSkipped`. Empty data aborts with `ImmediateL2TxOutOfGas` without proving OOG. All-failed immediate runs and any later outer revert discard earlier logs.

## Deployment and trust assumptions

- **Accepted proofs replace queues before deferred root checks:** Every accepted batch replaces the participating rollups' execution/static queues and updates `lastVerifiedBlock`. An old proof that still verifies can therefore replace useful queued work or activate the same-block `setRoot` lock even if its deferred entries cannot execute against the current roots. Root advancement prevents stale state transitions; it does not prevent these posting-side effects. Queue replacement is a liveness policy, and rollup-defined verification context can enforce freshness where needed.

- **Proof domains are a deployment responsibility:** Each rollup is verified on its designated L1. Public inputs do not explicitly bind `block.chainid`, the registry address, or a protocol version; independent deployments must use distinct verification domains. Reusing identical rollup/proof configurations across them is outside the intended model.

- **L2 funding is pooled across loads:** table replacement does not erase unused ETH. Partial consumption, reverts and residual inventory require an explicit node/circuit accounting policy; no per-load equality is checked. See [L2 funding and inventory](CORE_PROTOCOL_SPEC.md#l2-funding-and-inventory).

## Edge cases

- **Reverts also undo missing-call markers:** An ordinary enclosing revert rolls back the transient rolling hash, including `CALL_NOT_FOUND`. Only the explicit `ContextResult` path carries that hash across its deliberate revert. A caught validation error is reflected only through the execution outcomes that remain recorded.
