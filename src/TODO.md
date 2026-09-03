# TODO

## Design

- [ ] **Beacon proxies for `CrossChainProxy`.** Today proxy logic can never change without
      changing every proxy address. A beacon keeps addresses stable but adds ~2.7k gas per call
      and needs an upgrade owner; break-even ≈ 70 calls per proxy. Decide.

## Gas

- [ ] **Meta-hook entries through the transient serializer.** `_transientEntries` /
      `_transientStaticEntries` go to storage and back within one tx: 534k vs 122k for the same
      entry inline. Extend `ExpectedL1ToL2CallTransient` to whole entries and point the four read
      sites at it. Same for L2 `executeIncomingCrossChainCall` (`loadExecutionTable` stays storage).
      Win ~300–400k per meta-hook batch.
- [ ] **Look up reentrant rows without copying the whole table.** Every nested call copies
      `expectedL1ToL2Calls` to memory before scanning. Scan the keys in place, copy only the match.
      Do after the item above.

## Bytecode

EEZ runtime 23,654 B of the 24,576 B EIP-170 limit (922 B headroom, 2026-09-02); EEZL2 13,382 B.
Initcode is not a concern (25.3 KB of 49 KB). The compiler is already fully tuned for size
(`optimizer_runs = 1`, via-IR), so savings need config or source changes.

Where the bytes go (measured 2026-08-27 by emptying each region; regions share helpers, so the
deltas overlap):

| Region | Bytes |
|---|---|
| `postAndVerifyBatch` subsystem (validation 1,814 · verify 1,901 · vkeys 610 · save remainder 518 · transient pushes 393) | 9,681 |
| `_processNCalls` | 1,721 |
| Embedded `CrossChainProxy` creation code (data block) | 1,365 |
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

- [ ] **Drop CBOR metadata — 107 B, config only.** In `foundry.toml` `[profile.default]`:
      `bytecode_hash = "none"`, `cbor_metadata = false`. Explorers lose the embedded IPFS source
      hash; verification by compiler settings still works.

- [ ] **Stop embedding the proxy initcode — ~1.3 KB on EEZ and on EEZL2.** The runtime carries the
      1,365 B `CrossChainProxy` creation code only for `new CrossChainProxy{salt}(...)`. Instead,
      deploy one template proxy in the manager constructor and CREATE2 a 30 B stub
      (`PUSH20 template; EXTCODECOPY; RETURN` — `abi.encodePacked(0x73, template, hex"803b805f5f843c5ff3")`)
      that copies its code. Same deployer and salt, so only the `PROXY_INIT_CODE_HASH` value changes
      (nothing off-chain hardcodes it; update the CREATE2 section of `CORE_PROTOCOL_SPEC.md` and
      CLAUDE.md). The template is an unregistered proxy (`UnauthorizedProxy`) — add a test. Deploy gas
      per proxy stays about the same; manager deployment costs one extra proxy deploy.

- [ ] **Move batch validation + proof verification to an external library — 3.5–4 KB.**
      `_validateBatchStructure`, `_verifyProofSystemBatch`, `_getVerificationKeysPerRollup` are
      self-contained `view` logic over the calldata batch (`rollups` passes as a storage pointer).
      Cost: one extra deployment plus a DELEGATECALL per post. Use when the two above are not enough.
