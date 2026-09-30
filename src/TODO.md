# TODO

## Gas

- [ ] **Meta-hook entries through the transient serializer.** `_transientEntries` /
      `_transientStaticEntries` go to storage and back within one tx. Extend
      `ExpectedL1ToL2CallTransient` to whole entries and point the four read
      sites at it. Same for L2 `executeIncomingCrossChainCall` (`loadExecutionTable` stays storage).
      Benchmark the savings per meta-hook batch against inline execution.
- [ ] **Look up reentrant rows without copying the whole table.** Every nested call copies
      `expectedL1ToL2Calls` to memory before scanning. Scan the keys in place and copy only the match
      (nested CALL and STATICCALL; immediate, meta-hook and persistent tables — transient rows are
      already key-addressable). Keep cursor/rollback and empty-table behavior; no ABI, proof or
      storage-layout change. Benchmark deep nesting (copying is quadratic today), gas and bytecode.
      Do after the item above.

## Benchmarks

- [ ] **Benchmark execution log payloads (L1/L2).** Events carry full return data; L2 also logs the
      whole loaded table. Set payload budgets; use hashes/IDs where full data is unnecessary.

## Observability

- [ ] **Identify execution events clearly.** Immediate entries report index zero, nested call
      indices repeat, and `BatchPosted` carries a shared public-input hash and rollup IDs. Consider batch IDs, real entry
      indices and frame IDs, and distinguish proof acceptance, committed execution, deliberate
      rollback and omitted work. Reverted frames erase their own logs, so keep the surviving
      rollback-summary events distinct from committed target calls.

## Bytecode

EEZ runtime 23,857 B of the 24,576 B EIP-170 limit (719 B headroom); EEZL2 13,932 B.
EEZ creation bytecode is 25,533 B, below the 49,152 B initcode limit. The compiler is tuned for size
(`optimizer_runs = 1`, via-IR), so savings need config or source changes.

Remeasure the per-region figures below before estimating savings for the current build.
Regions share helpers, so the deltas overlap:

| Region | Bytes |
|---|---|
| `postAndVerifyBatch` subsystem (validation 1,814 · verify 1,901 · vkeys 610 · save remainder 518 · transient pushes 393) | 9,681 |
| `_processL2ToL1Calls` | 1,721 |
| Embedded `CrossChainProxy` creation code (data block) | 1,458 |
| `ExpectedL1ToL2CallTransient` serializer | 1,140 |
| Nested path (`_consumeNestedCall`, `_resolveNestedReentrant`, `_getExpectedL1toL2Calls`) | 1,122 |
| Consume/match (`_consumeAndExecuteEntry`, `_findMatchingEntry`, `_entryMatches`) | 1,094 |
| `_executeEntry` | 1,021 |
| Static read path | 975 |
| `executeCrossChainCall` | 939 |
| `registerRollup` + `setRoot` + views | 746 |
| Revert-span machinery | 318 |
| CBOR metadata trailers (EEZ + embedded proxy initcode) | 107 |

The dominant cost is ABI machinery for the nested batch calldata struct: decoding, per-entry
`abi.encode` hashing, and full struct copies into storage / transient tables.

- [ ] **Drop CBOR metadata — measure the savings.** In `foundry.toml` `[profile.default]`:
      `bytecode_hash = "none"`, `cbor_metadata = false`. Explorers lose the embedded IPFS source
      hash; verification by compiler settings still works. Check the proxy init-code hash impact.

- [ ] **Stop embedding the proxy initcode.** Move `CrossChainProxy` creation code into
      a separate helper so EEZ and EEZL2 no longer embed it. Preserve proxy behavior and
      measure bytecode savings and deployment gas.

- [ ] **Move batch validation + proof verification to an external library — estimated 3.5–4 KB.**
      `_validateBatchStructure`, `_verifyProofSystemBatch`, `_getVerificationKeysPerRollup` are
      self-contained `view` logic over the calldata batch (`rollups` passes as a storage pointer).
      Cost: one extra deployment plus a DELEGATECALL per post. Use when the two above are not enough.
