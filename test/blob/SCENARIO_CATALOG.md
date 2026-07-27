# Scenario Catalog — the L1 batch each shape produces

Companion to [`ScenarioCatalog.t.sol`](./ScenarioCatalog.t.sol). For every basic
cross-chain shape it shows the `ProofSystemBatchPerVerificationEntries` the blob
framework derives and posts on L1 (`EEZ.postAndVerifyBatch`), and who consumes
each entry. All contents below were dumped from the real `TableGenerator` output
for the exact scripts in the test file.

## Legend

| Symbol | Meaning |
|---|---|
| `A`, `B` | rollup ids of L2_A (= 1) and L2_B (= 2); L1 is rollup id 0 |
| `G_A` | L2_A's pre-tx state root (`keccak("blobfw-genesis", A)` on a fresh harness) |
| `S1_A` | L2_A's post-tx state root |
| `driver_X` | the tx's origin driver actor on chain X (fires the root calls) |
| `target_X` | the call-target actor on chain X |
| `cch(...)` | `computeCrossChainCallHash(isStatic, src, srcRid, dst, dstRid, value, data)` — the gas-free destination-kind hash; every hash in the L1 batch uses it |
| `seed` | the entry's rolling-hash seed: fold of each `(rollupId, currentState)` pair, then `proxyEntryHash` |
| `⊕ TAG(...)` | one tagged fold into the rolling hash: `CALL_BEGIN(cch)`, `CALL_END(success, retData)`, `NESTED_BEGIN(cch)`, `NESTED_END` |

Wrapper fields identical in every batch the harness posts (omitted below):

```
expectedStateRootPerRollup = []           // no composer assertions
proofSystems               = [mockPS]     // single proof system
proofs                     = ["proof"]
rollupIdsWithProofSystems  = every rollup the entries' stateUpdates / statics' pins touch
blobIndices                = []
callData                   = ""
blockNumber                = 0            // no block binding
bindMsgSenderInPublicInput = false
immediateStaticEntryCount  = 0
```

Two recurring entry roles:

- **L2Tx host** (`proxyEntryHash = 0`): the single L1 commitment of an
  L2-origin transaction. Posted as `entries[0]` with `immediateEntryCount = 1`,
  so `postAndVerifyBatch` executes it inline — every call that lands on L1
  during that tx runs inside it.
- **Origin entry** (`proxyEntryHash = cch(root call)`): an L1-origin root call.
  Posted deferred (`immediateEntryCount = 0`) into the destination rollup's
  queue; the L1 driver's proxy call consumes it right after the batch, in the
  same block.

State-root note: **every** rollup a tx touches appears in `stateUpdates` with an
advanced root — even when the delivery on that rollup is reverted or rolled
back (cases 12/13). The root models the L2 block that processed (and rolled
back) the call; only *committed effects* are undone, not the block itself.

---

## 1. L2-only transaction

An L2_A transaction with no cross-chain calls (raw messages:
`Initiate(A) · Finish` — the DSL can't express a call-free tx).

```
entries = [{
    stateUpdates        = [{ rollupId: A, currentState: G_A, newState: S1_A, etherDelta: 0 }],
    proxyEntryHash      = 0x0,                    // pure L2 tx — the L2Tx host
    destinationRollupId = A,
    l2ToL1Calls         = [],                     // nothing lands on L1
    expectedL1ToL2Calls = [],
    rollingHash         = seed,                   // no folds at all
    success             = true,
    returnData          = "",
}]
staticEntries       = []
immediateEntryCount = 1        // runs inline: just applies the state delta
```

The batch is nothing but the proven state transition of A. On L2_A the tx runs
natively; L1 only advances the root.

## 2. L1 call L2

`L1 call L2_A · L2_A return`

```
entries = [{
    stateUpdates        = [{ rollupId: A, currentState: G_A, newState: S1_A, etherDelta: 0 }],
    proxyEntryHash      = cch(false, driver_L1, 0, target_A, A, 0, callData),
    destinationRollupId = A,
    l2ToL1Calls         = [],                     // the call executes on L2_A, not L1
    expectedL1ToL2Calls = [],
    rollingHash         = seed,
    success             = true,
    returnData          = "dsl.ret#0",            // L2_A's return, pre-computed by the prover
}]
staticEntries       = []
immediateEntryCount = 0        // deferred origin entry
```

The driver's proxy call (`executeCrossChainCall`) scans A's queue, matches
`proxyEntryHash` + the live `currentState` pin, applies the delta, and returns
the pre-computed `returnData` — the actual execution already happened on L2_A
and was proven.

## 3. L2 call L1

`L2_A call L1 · L1 return`

```
entries = [{
    stateUpdates        = [{ rollupId: A, currentState: G_A, newState: S1_A, etherDelta: 0 }],
    proxyEntryHash      = 0x0,                    // L2Tx host
    destinationRollupId = A,
    l2ToL1Calls         = [{
        revertNextNCalls: 0, isStatic: false, gas: 0,
        sourceAddress: driver_A, sourceRollupId: A,
        targetAddress: target_L1, value: 0, data: callData,
    }],
    expectedL1ToL2Calls = [],
    rollingHash         = seed ⊕ CALL_BEGIN(cch_call) ⊕ CALL_END(true, "dsl.ret#0"),
    success             = true,
    returnData          = "",
}]
staticEntries       = []
immediateEntryCount = 1        // postAndVerifyBatch runs the L1 call inline
```

The host's `l2ToL1Calls[0]` is the real L1 execution: the manager CALLs
`target_L1` through its proxy, folds the observed result into the rolling hash,
and one final comparison against `entry.rollingHash` proves the prover
committed to exactly this call and result.

## 4. L1 static_call L2

`L1 staticCall L2_A · L2_A return`

```
entries       = []                                // nothing state-changing on L1
staticEntries = [{
    expectedStateRoots  = [{ rollupId: A, stateRoot: G_A }],  // pin, part of the match
    proxyEntryHash      = cch(true, driver_L1, 0, target_A, A, 0, callData),  // isStatic folded
    destinationRollupId = A,
    l2ToL1Calls         = [],
    rollingHash         = 0x0,                    // untagged static accumulator, no sub-calls
    success             = true,
    returnData          = "dsl.ret#0",            // the pre-computed read result
}]
immediateEntryCount = 0
```

A read changes nothing, so there is no `ExecutionEntry` and no root advance —
only a pool `StaticExecutionEntry` pinned to A's **live** root. The driver's
`staticCrossChainCall` matches it by hash + pins (static entries ignore the
block gate: they stay valid while the pins hold) and returns the cached result.

## 5. L2 static_call L1

`L2_A staticCall L1 · L1 return`

```
entries = [{
    stateUpdates        = [{ rollupId: A, currentState: G_A, newState: S1_A, etherDelta: 0 }],
    proxyEntryHash      = 0x0,                    // L2Tx host
    destinationRollupId = A,
    l2ToL1Calls         = [{                      // the read REALLY runs on L1
        revertNextNCalls: 0, isStatic: true,      //   dispatched via STATICCALL
        gas: 0, sourceAddress: driver_A, sourceRollupId: A,
        targetAddress: target_L1, value: 0, data: readData,
    }],
    expectedL1ToL2Calls = [],
    rollingHash         = seed ⊕ CALL_BEGIN(cch_read) ⊕ CALL_END(true, "dsl.ret#0"),
    success             = true,
    returnData          = "",
}]
staticEntries       = []
immediateEntryCount = 1
```

A read **of L1** cannot be attested by any rollup proof — L1's state is only
live on L1 — so the L2Tx host carries it as an `isStatic: true` row in
`l2ToL1Calls`, executed via STATICCALL when the host runs inline and folded
into the host's rolling hash: the batch verifies on L1 that the value the
prover cached really is what L1 returns. The L2_A side additionally has the
pool `StaticExecutionEntry` (in A's `loadExecutionTable` table, matched by
hash) that answers the driver's read with the same cached result. Compare
case 4, where the read targets a *proven* L2 and a pinned pool entry alone
suffices.

## 6. L1 call L2 call L1

`L1 call L2_A · L2_A call L1 · L1 return · L2_A return`

```
entries = [{
    stateUpdates        = [{ rollupId: A, currentState: G_A, newState: S1_A, etherDelta: 0 }],
    proxyEntryHash      = cch(false, driver_L1, 0, target_A, A, 0, rootData),
    destinationRollupId = A,
    l2ToL1Calls         = [{                      // the callback REALLY runs on L1
        revertNextNCalls: 0, isStatic: false, gas: 0,
        sourceAddress: target_A, sourceRollupId: A,
        targetAddress: target_L1, value: 0, data: cbData,
    }],
    expectedL1ToL2Calls = [],
    rollingHash         = seed ⊕ CALL_BEGIN(cch_cb) ⊕ CALL_END(true, "dsl.ret#1"),
    success             = true,
    returnData          = "dsl.ret#0",            // the root call's L2_A return
}]
staticEntries       = []
immediateEntryCount = 0        // origin entry, consumed by the driver's proxy call
```

Same origin-entry shape as case 2, but the entry carries the L2_A→L1 callback
in its own `l2ToL1Calls` — consuming the entry executes it live on L1.

## 7. L2 call L1 call L2

`L2_A call L1 · L1 call L2_A · L2_A return · L1 return`

```
entries = [{
    stateUpdates        = [{ rollupId: A, currentState: G_A, newState: S1_A, etherDelta: 0 }],
    proxyEntryHash      = 0x0,                    // L2Tx host
    destinationRollupId = A,
    l2ToL1Calls         = [{                      // the root call A→L1
        revertNextNCalls: 0, isStatic: false, gas: 0,
        sourceAddress: driver_A, sourceRollupId: A,
        targetAddress: target_L1, value: 0, data: rootData,
    }],
    expectedL1ToL2Calls = [{                      // unified reentrant table: SUCCESS row
        expectedL1toL2Hash        = keccak256(cch_nested, RH_fire),
        l2ToL1Calls               = [],           // the frame has no sub-calls of its own
        revertedOrStaticRollingHash = 0x0,
        success                   = true,
        returnData                = "dsl.ret#1",  // L2_A's pre-computed callback result
    }],
    rollingHash = seed ⊕ CALL_BEGIN(cch_root) ⊕ NESTED_BEGIN(cch_nested) ⊕ NESTED_END
                       ⊕ CALL_END(true, "dsl.ret#0"),
    success             = true,
    returnData          = "",
}]
staticEntries       = []
immediateEntryCount = 1
```

While `target_L1` executes, its call back into L2_A hits the reentrant table:
the key binds `cch_nested` to `RH_fire` — the live rolling hash right after
`CALL_BEGIN(cch_root)` — so the row can only match at that exact execution
point. The frame opens `NESTED_BEGIN`, runs its (empty) sub-array, commits with
`NESTED_END`, and returns the pre-computed data.

## 8. L1 call L2 static_call L1

`L1 call L2_A · L2_A staticCall L1 · L1 return · L2_A return`

```
entries = [{
    stateUpdates        = [{ rollupId: A, currentState: G_A, newState: S1_A, etherDelta: 0 }],
    proxyEntryHash      = cch(false, driver_L1, 0, target_A, A, 0, rootData),
    destinationRollupId = A,
    l2ToL1Calls         = [{
        revertNextNCalls: 0, isStatic: true,      // dispatched via STATICCALL on L1
        gas: 0, sourceAddress: target_A, sourceRollupId: A,
        targetAddress: target_L1, value: 0, data: readData,
    }],
    expectedL1ToL2Calls = [],
    rollingHash         = seed ⊕ CALL_BEGIN(cch_read) ⊕ CALL_END(true, "dsl.ret#1"),
    success             = true,
    returnData          = "dsl.ret#0",
}]
staticEntries       = []
immediateEntryCount = 0
```

The read targets L1, so it is a **real** L1 read: an `isStatic: true` row in the
origin entry's `l2ToL1Calls`, executed via STATICCALL when the entry is
consumed (its `cch` folds `isStatic = true`, keying it apart from a mutable
call). It still folds CALL_BEGIN/CALL_END like any sub-call — it runs on L1;
only its state effects are impossible by construction.

## 9. L2 call L1 static_call L2

`L2_A call L1 · L1 staticCall L2_A · L2_A return · L1 return`

```
entries = [{
    stateUpdates        = [{ rollupId: A, currentState: G_A, newState: S1_A, etherDelta: 0 }],
    proxyEntryHash      = 0x0,                    // L2Tx host
    destinationRollupId = A,
    l2ToL1Calls         = [{                      // the root call A→L1
        revertNextNCalls: 0, isStatic: false, gas: 0,
        sourceAddress: driver_A, sourceRollupId: A,
        targetAddress: target_L1, value: 0, data: rootData,
    }],
    expectedL1ToL2Calls = [{                      // STATIC row, static-kind key
        expectedL1toL2Hash        = keccak256(cch_read_static, RH_fire),
        l2ToL1Calls               = [],
        revertedOrStaticRollingHash = 0x0,        // untagged accumulator of 0 sub-calls
        success                   = true,
        returnData                = "dsl.ret#1",  // the pre-computed L2_A read result
    }],
    rollingHash = seed ⊕ CALL_BEGIN(cch_root) ⊕ CALL_END(true, "dsl.ret#0"),
                                                  // the read folds NOTHING on the host
    success             = true,
    returnData          = "",
}]
staticEntries       = []
immediateEntryCount = 1
```

The reentrant read of L2_A lives in the same unified table, keyed with the
static-kind hash (`isStatic = true` inside `cch`). `staticCrossChainCall`
resolves it position-pinned but does **not** consume it and folds nothing into
the host hash — compare the `rollingHash` here with case 3: identical shape.

## 10. L1 static_call L2 static_call L1

`L1 staticCall L2_A · L2_A staticCall L1 · L1 return · L2_A return`

The nested read enters **through the static entry**: the pool entry carries
the sub-read in its own sub-call array, re-run live during resolution and
verified by the untagged static rolling hash.

```
entries       = []
staticEntries = [{
    expectedStateRoots  = [{ rollupId: A, stateRoot: G_A }],
    proxyEntryHash      = cch(true, driver_L1, 0, target_A, A, 0, readData),
    destinationRollupId = A,
    l2ToL1Calls         = [{                      // the sub-read of L1, re-run live
        revertNextNCalls: 0, isStatic: true, gas: 0,
        sourceAddress: target_A, sourceRollupId: A,
        targetAddress: target_L1, value: 0, data: innerReadData,
    }],
    rollingHash         = keccak256(0x0, true, innerResult),  // untagged schema
    success             = true,
    returnData          = "dsl.ret#0",            // the outer read's cached result
}]
immediateEntryCount = 0
```

The driver's `staticCrossChainCall` matches the pool entry by hash + pins,
then `_resolveStaticEntry` STATICCALLs the sub-read **for real on L1**
(through the source's proxy via `executeOnBehalf`) and requires the untagged
fold of the observed result to equal `rollingHash` — that is exactly why the
static rolling hash exists. Only then is the cached outer result returned.
The outer read's own execution on L2_A is covered by the state-root pin.

## 11. L2 static_call L1 static_call L2

`L2_A staticCall L1 · L1 staticCall L2_A · L2_A return · L1 return`

The mirror composes cases 5 and 10: the outer read targets L1, so it runs
live on the L2Tx host (case-5 rule), and while it executes there the actor's
sub-read of A resolves as a STATIC row in the host's reentrant table.

```
entries = [{
    stateUpdates        = [{ rollupId: A, currentState: G_A, newState: S1_A, etherDelta: 0 }],
    proxyEntryHash      = 0x0,                    // L2Tx host
    destinationRollupId = A,
    l2ToL1Calls         = [{                      // the outer read, run live on L1
        revertNextNCalls: 0, isStatic: true, gas: 0,
        sourceAddress: driver_A, sourceRollupId: A,
        targetAddress: target_L1, value: 0, data: readData,
    }],
    expectedL1ToL2Calls = [{                      // STATIC row: the sub-read of A
        expectedL1toL2Hash        = keccak256(cch_sub_static, RH_fire),  // fire = after CALL_BEGIN
        l2ToL1Calls               = [],
        revertedOrStaticRollingHash = 0x0,
        success                   = true,
        returnData                = "dsl.ret#1",  // A's cached sub-read result
    }],
    rollingHash = seed ⊕ CALL_BEGIN(cch_read) ⊕ CALL_END(true, "dsl.ret#0"),
                                                  // the STATIC row folds nothing
    success             = true,
    returnData          = "",
}]
staticEntries       = []
immediateEntryCount = 1
```

On the L2_A side the pool `StaticExecutionEntry` (loaded via
`loadExecutionTable`, matched by `proxyEntryHash` alone) carries the sub-read
in its `incomingCalls` — re-run live **on A** during the driver's resolution
and checked against the entry's untagged `rollingHash`, just like case 10 on
L1. So the one flow is verified twice, once per chain, each side re-running
the read that lands on it.

## 12. L2a call L1 call/revert L2b

`L2_A call L1 · L1 call L2_B · L2_B returnFail · L1 return`
(L1 calls L2_B, the delivery fails, L1 catches it and commits.)

```
entries = [{
    stateUpdates = [
        { rollupId: A, currentState: G_A, newState: S1_A, etherDelta: 0 },
        { rollupId: B, currentState: G_B, newState: S1_B, etherDelta: 0 },  // B advances too!
    ],
    proxyEntryHash      = 0x0,                    // L2Tx host
    destinationRollupId = A,
    l2ToL1Calls         = [{                      // the root call A→L1
        revertNextNCalls: 0, isStatic: false, gas: 0,
        sourceAddress: driver_A, sourceRollupId: A,
        targetAddress: target_L1, value: 0, data: rootData,
    }],
    expectedL1ToL2Calls = [{                      // REVERTED row
        expectedL1toL2Hash        = keccak256(cch_toB, RH_fire),
        l2ToL1Calls               = [],           // the failing frame's own sub-calls
        revertedOrStaticRollingHash = RH_fire ⊕ NESTED_BEGIN(cch_toB),  // expected frame hash
        success                   = false,
        returnData                = "dsl.fail#1", // the revert payload L1 catches
    }],
    rollingHash = seed ⊕ CALL_BEGIN(cch_root) ⊕ CALL_END(true, "dsl.ret#0"),
                                                  // the reverted frame leaves NO folds
    success             = true,
    returnData          = "",
}]
staticEntries       = []
immediateEntryCount = 1
```

The `success = false` row runs as a mini-entry: fold `NESTED_BEGIN`, run the
(empty) sub-array, check the live hash against `revertedOrStaticRollingHash`,
then revert with `returnData`. The revert rolls the host's hash and cursor
back to the fire point, so the final `rollingHash` looks as if the frame never
happened — the row itself is the only proof it did. Note B still appears in
`stateUpdates` with an advanced root: its L2 block processed (and reverted)
the delivery.

## 13. L2a call L1 ×3, revert the last two

`L2_A call L1 · snapshot · L2_A call L1 (→ nested L1 call L2_B) · L2_A call L1 · revert`
(Three root calls into L1; a Snapshot…Revert region forces the last two —
including the nested B hop — to roll back after executing.)

```
entries = [{
    stateUpdates = [
        { rollupId: A, currentState: G_A, newState: S1_A, etherDelta: 0 },
        { rollupId: B, currentState: G_B, newState: S1_B, etherDelta: 0 },
    ],
    proxyEntryHash      = 0x0,                    // L2Tx host
    destinationRollupId = A,
    l2ToL1Calls = [
        {                                         // call 1 — survives
            revertNextNCalls: 0, isStatic: false, gas: 0,
            sourceAddress: driver_A, sourceRollupId: A,
            targetAddress: target_L1, value: 0, data: call1Data,
        },
        {                                         // call 2 — opens the span: itself + call 3
            revertNextNCalls: 2, isStatic: false, gas: 0,
            sourceAddress: driver_A, sourceRollupId: A,
            targetAddress: target_L1, value: 0, data: call2Data,
        },
        {                                         // call 3 — rolled back with call 2
            revertNextNCalls: 0, isStatic: false, gas: 0,
            sourceAddress: driver_A, sourceRollupId: A,
            targetAddress: target_L1, value: 0, data: call3Data,
        },
    ],
    expectedL1ToL2Calls = [{                      // the nested L1→L2_B hop inside call 2
        expectedL1toL2Hash        = keccak256(cch_toB, RH_fire_inside_span),
        l2ToL1Calls               = [],
        revertedOrStaticRollingHash = 0x0,
        success                   = true,
        returnData                = "dsl.ret#2",
    }],
    rollingHash = seed ⊕ CALL_BEGIN(c1) ⊕ CALL_END(true, r1)
                       ⊕ CALL_BEGIN(c2) ⊕ NESTED_BEGIN(cch_toB) ⊕ NESTED_END ⊕ CALL_END(true, r2)
                       ⊕ CALL_BEGIN(c3) ⊕ CALL_END(true, r3),   // ALL calls fold — they all ran
    success             = true,
    returnData          = "",
}]
staticEntries       = []
immediateEntryCount = 1
```

`revertNextNCalls = 2` on call 2 makes the manager slice calls 2–3 and run them
inside `executeInContextAndRevert`: they execute fully (results verified, hash
folded), then the protocol-level revert rolls their EVM state back while the
rolling hash and cursors escape via the `ContextResult` payload. That is why
the final `rollingHash` still covers every call, and why B's delivery — driven
with its own `revertNextNCalls` on the L2_B side — advances B's root without
leaving committed state.

## 14. Nested L1 call L2a call L1 call L2b call L1

`L1 call L2_A · L2_A call L1 · L1 call L2_B · L2_B call L1 · returns all the way up`

```
entries = [{
    stateUpdates = [
        { rollupId: A, currentState: G_A, newState: S1_A, etherDelta: 0 },
        { rollupId: B, currentState: G_B, newState: S1_B, etherDelta: 0 },
    ],
    proxyEntryHash      = cch(false, driver_L1, 0, target_A, A, 0, rootData),  // origin entry
    destinationRollupId = A,
    l2ToL1Calls         = [{                      // the A→L1 callback
        revertNextNCalls: 0, isStatic: false, gas: 0,
        sourceAddress: target_A, sourceRollupId: A,
        targetAddress: target_L1, value: 0, data: cbAData,
    }],
    expectedL1ToL2Calls = [{                      // the L1→L2_B frame, fired inside that callback
        expectedL1toL2Hash        = keccak256(cch_toB, RH_fire),
        l2ToL1Calls               = [{            // the frame's OWN sub-call: the B→L1 landing
            revertNextNCalls: 0, isStatic: false, gas: 0,
            sourceAddress: target_B, sourceRollupId: B,
            targetAddress: target_L1, value: 0, data: cbBData,
        }],
        revertedOrStaticRollingHash = 0x0,
        success                   = true,
        returnData                = "dsl.ret#2",  // L2_B's pre-computed return
    }],
    rollingHash = seed ⊕ CALL_BEGIN(cch_AtoL1)
                       ⊕ NESTED_BEGIN(cch_toB)
                       ⊕ CALL_BEGIN(cch_BtoL1) ⊕ CALL_END(true, retB)   // inside the frame
                       ⊕ NESTED_END
                       ⊕ CALL_END(true, retA),
    success             = true,
    returnData          = "dsl.ret#0",            // the root call's L2_A return
}]
staticEntries       = []
immediateEntryCount = 0        // origin entry, consumed by the L1 driver
```

The full recursion collapses into one entry: the top-level callback rides
`l2ToL1Calls`, the L2_B round-trip is a reentrant row, and that row's **own**
`l2ToL1Calls` carries the deepest L1 landing. The single rolling hash chains
every begin/end boundary, so order, count and nesting of all five hops are
verified with one comparison.
