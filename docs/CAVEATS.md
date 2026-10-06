# Caveats

## Calling through cross-chain proxies

- **Opcodes that differ on cross-chain proxies**:
  - These opcodes return information about the proxy itself, not the proxied contract: `delegatecall`, `balance`, `extcodesize`, `extcodecopy`.
  - Block-state opcodes (`blocknumber`, `blockhash`, `blockgaslimit`, `chainid`, `coinbase`, …) reflect the chain the call is executing on, not the source chain — values will differ when the same logical action is observed on L1 vs L2.

- **Proxy self-calls:** A proxy calling itself with `staticCheck()` runs its internal detector instead of making a cross-chain call.

- **Missing entries and destination reverts:** A top-level or static lookup miss reverts at the proxy, as does a matched reverting destination; revert data alone is not a reliable way to distinguish them. A nested mutable lookup miss instead records `CALL_NOT_FOUND` and returns success with empty data. Its rejection depends on the marker surviving until hash validation; see the reverted-probe edge case below.

- **Proxy ETH recovery is best-effort:** ETH sent to a proxy address before deployment is swept to the recovery address in the constructor, once, ignoring failure, so a recovery address that always rejects ETH cannot block proxy creation. The sweep gets at most 100k gas, so a recipient that burns everything it receives only adds that much to the deployment cost. If the sweep fails the ETH stays in the proxy for good.

## Delivery and execution semantics

- **Gas-budget checks are estimates:** Both L1 and L2 check `_hasEnoughCallGas` before dispatching calls with non-zero `gas`. A detected shortage stops the local call array and folds `CALL_INSUFFICIENT_GAS` into the rolling hash; valid proofs must exclude that marker, so hash validation rejects executions that retain it. An ordinary enclosing revert can erase the marker. Static-entry execution instead reverts with `InsufficientCallGas`. The estimate excludes account-creation costs, return-data processing, and the rest of the entry, so it is not an unconditional gas-delivery or completion guarantee. A `gas` value of `0` skips the check and forwards available gas subject to EVM forwarding limits. Posters must still fund the whole batch.

- **Posting does not guarantee delivery of every entry:** Consumption scans forward and permanently skips non-matching entries. During the meta hook, all rollups share one cursor: a third-party operation calling `executeL2Txs(G)` can consume a later G entry and skip pending entries for H, causing H's calls to fail with `ExecutionNotFound`. If the hook catches those failures and returns successfully, the skipped immediate entries are discarded; if it reverts, the whole post rolls back. Executed entries still require valid starting roots and execution checks. Only leading immediate L2Tx entries run automatically; later ones require an explicit `executeL2Txs` call.

- **Cross-rollup calls inside the meta hook only work between rollups verified in the same batch:** a rollup verified by an earlier batch this block is unreachable from the hook (`ExecutionNotFound`); interact with it after `postAndVerifyBatch` returns, or verify both rollups together.

- **Composer-controlled delivery:** The composer can withhold a batch or, when it controls the posting contract, leave optional entries unexecuted. Including execution settings in the proof would not force it to do that work, though it could stop another submitter from changing those settings. Entries that execute must still pass the existing checks. Applications that require particular entries to run must enforce that requirement themselves.

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

  Applications must not treat empty success from a reverted `try/catch` probe as remote approval. A nested mutable call with no matching entry returns `(true, "")`. If the probe reverts and reports that result in its revert data, it erases the missing-call marker. The caller can then act on the apparent success, and the final entry check may accept it despite no proven remote approval.

  For example, a small loan is approved during simulation, but the requested amount is increased before execution. The application probes approval again: no proven entry matches the larger amount, yet the proxy returns success with empty data. The probe then reverts, passing that apparent approval back in its revert data and erasing the missing-call marker. The application catches the revert and may pay the larger amount. This can happen on both L1 and L2. For static calls, a missing entry causes an immediate revert.
