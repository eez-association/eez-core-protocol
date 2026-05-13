# TODO

## optimizations:
- optimize structs with other types e.g uint64 for optimizing storage

## open questions:
- **Top-level revert with surviving nested L1→L2 effects — is the current `LookupCall` shape enough?**
  Static lookups work: nested static calls re-enter `staticCallLookup`, replayed via `LookupCall.calls[]` under STATICCALL. The reverted-top-level path (`LookupCall { failed: true }`) is less clear. If a top call on rollup A fires a non-static nested call into rollup B and then reverts, A's view rolls everything back but B committed the nested effect independently — so today the prover emits **two** entries: a `LookupCall(failed=true)` on A and a separate "real" `ExecutionEntry` on B. End-to-end this is possible (per-rollup queues are independent), but encoding one logical operation as two entries is awkward and possibly fragile. Investigate:
    1. Soundness: is the cross-entry split safe under every ordering of A's lookup consumption vs B's entry consumption?
    2. Extend `LookupCall` with `expectedL1ToL2Calls[]` (and a matching `callCount` partition over `calls[]`) so a `failed=true` lookup can host its own surviving nested reentries in one entry — symmetric with `ExecutionEntry`.
    3. Alternative: constrain the prover so `failed=true` top-level lookups are only valid when no nested cross-chain effects survived; forbid the split by construction.
  Pointers: `LookupCall` (`src/interfaces/IEEZ.sol:105`), `ExecutionEntry.expectedL1ToL2Calls` (`src/interfaces/IEEZ.sol:93`), `_consumeNestedAction` (`src/EEZ.sol:746`, `src/L2/EEZL2.sol:221`), `_tryRevertedTopLevelLookup` in `EEZ.sol`. Spec: `docs/SYNC_ROLLUPS_PROTOCOL_SPEC.md` §D.3 and §F.

