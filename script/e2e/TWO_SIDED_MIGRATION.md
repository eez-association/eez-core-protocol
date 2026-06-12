# Two-sided e2e migration guide

How to upgrade a single-sided e2e scenario (only `Execute` OR only `ExecuteL2`) into a faithful two-sided scenario that exercises **both** anvil chains. Reference implementations: `counter/E2E.s.sol` (L1→L2) and `counterL2/E2E.s.sol` (L2→L1).

## Why two-sided

The current protocol commits to "the destination chain will execute X and produce returnData=Y" on the source side via a cached `returnData` and a per-rollup `StateDelta`. A single-sided test only checks the source-side bookkeeping — the destination chain stays passive (`Counter@dest.counter() == 0`). A two-sided test additionally invokes the destination call for real, so any drift between the cached `returnData` and what the destination would actually produce surfaces as an assertion failure.

The cross-chain hash (`proxyEntryHash` on source side / `crossChainCallHash` parameter of `executeIncomingCrossChainCall` on dest side) is the cryptographic tie: a green two-sided run shows the **same hash** in events on both chains.

## Direction matters

Pick the right destination-side pattern by where the user-trigger lives:

| Source-side trigger | Destination-side simulation |
|---|---|
| L1 (`postAndVerifyBatch` + user tx)  | **`managerL2.executeIncomingCrossChainCall(dest, value, data, src, srcRollup, entries, lookups)` from SYSTEM** — combines load + execute, lazily creates the source proxy on L2, runs `_processNCalls` which actually invokes the destination |
| L2 (`loadExecutionTable` + user tx)  | **L1 batcher with `transientExecutionEntryCount=0` + `EEZ.executeL2TX(rollupId)`** — `postAndVerifyBatch` routes a deferred entry into the L2-rollup queue, then `executeL2TX` drains it via `_consumeAndExecute(rollupId, bytes32(0))` which runs `_processNCalls` on the L1 anvil |

There is no `executeIncomingCrossChainCall` on L1 — the L1-side analog for system-driven execution is `executeL2TX`, and the destination-side entry has `proxyEntryHash = bytes32(0)`.

## File anatomy — the contracts in each `E2E.s.sol`

Add or keep the following Forge `contract` types, in this order:

```
abstract contract <Scenario>Actions {
    // _<callData> builders, _callHash, _l1Entries, _l2Entries — single source of truth
}

contract Deploy{,L2}                 // deploy contracts on each chain (run-local detects suffix)
contract ExecuteL2                   // L2-side trigger / simulation
contract Execute                     // L1-side trigger / simulation
contract ExecuteNetwork{,L2}         // network-mode user-tx helpers (only `view` — emit envs)
contract ComputeExpected             // print expected tables (verification aid)
```

`run-local.sh` auto-runs `ExecuteL2` first then `Execute` (`script/e2e/shared/run-local.sh:72-115`). If only one is present, the other phase is skipped — keep both for two-sided.

## Pattern A — L1→L2 scenarios (counter, bridge, helloWorld, …)

User triggers on L1, destination Counter lives on L2. Single `ExecutionEntry` on each side with **matching `proxyEntryHash`**.

### L1 entry shape (source-side)

```solidity
StateDelta[] deltas = [ StateDelta(L2_ROLLUP_ID, oldRoot, newRoot, etherDelta) ];

ExecutionEntry entry = {
    stateDeltas:         deltas,
    proxyEntryHash:      crossChainCallHash(L2_ROLLUP_ID, dest, value, data, srcAddr, MAINNET_ROLLUP_ID),
    destinationRollupId: L2_ROLLUP_ID,
    l2ToL1Calls:         [],            // no inner calls — top-level only
    expectedL1ToL2Calls: [],
    expectedLookups:     [],            // entry-scoped nested lookups (static/reverted) — empty here
    callCount:           0,
    returnData:          <cached>,
    rollingHash:         bytes32(0),    // zero calls means zero-tape
};
```

### L2 entry shape (destination-side)

```solidity
CrossChainCall[] calls = [
    CrossChainCall(dest, value, data, srcAddr /* CAP on L1 */, MAINNET_ROLLUP_ID, 0 /* revertSpan */)
];

bytes32 rh = bytes32(0);
rh = RollingHashBuilder.appendCallBegin(rh, 1);
rh = RollingHashBuilder.appendCallEnd(rh, 1, true, <cached>);

ExecutionEntry entry = {
    proxyEntryHash:      <same hash as L1 side>,
    incomingCalls:       calls,
    expectedOutgoingCalls: [],
    expectedLookups:     [],            // nested lookups (static/reverted) live HERE when needed
    callCount:           1,
    returnData:          <cached>,
    rollingHash:         rh,
};
```

For scenarios with a try/catch'd reverting reentrant call, put the reverted `ExpectedLookup` inside `expectedLookups` (reference: `nestedCallRevert/E2E.s.sol`).

### `ExecuteL2` contract

```solidity
contract ExecuteL2 is Script, <Scenario>Actions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address destAddr    = vm.envAddress("<DEST_ON_L2>");
        address srcAddr     = vm.envAddress("<SRC_ON_L1>"); // CAP, etc.

        vm.startBroadcast();
        EEZL2(managerAddr).executeIncomingCrossChainCall{value: <value>}(
            destAddr,
            <value>,
            <callData>,
            srcAddr,
            MAINNET_ROLLUP_ID,
            _l2Entries(destAddr, srcAddr),
            noL2LookupCalls()
        );

        console.log("L2 done; counter=%s", <DestContract>(destAddr).counter());
        vm.stopBroadcast();
    }
}
```

`SYSTEM_ADDRESS` is anvil account 0 by default (the broadcaster). The source proxy is lazy-created by `_processNCalls` — no explicit `createCrossChainProxy` needed.

`msg.value` must equal `<value>` strictly (`ValueMismatch` revert otherwise).

**Single-entry only.** `executeIncomingCrossChainCall` is designed for one entry per transaction (`_currentEntryIndex`/`_rollingHash` aren't reset between back-to-back invocations in the same tx — its natspec explicitly says "once per tx"). For multi-entry L2 destinations (multi-call-twice, multi-call-two-diff, multi-call-nested), use Pattern C below.

## Pattern C — Multi-entry destination (multi-call-twice, multi-call-two-diff, multi-call-nested)

When the L2 destination needs to consume N entries in sequence — e.g. a `CallTwice` style trigger that loops over multiple proxy calls — `executeIncomingCrossChainCall` doesn't fit. Use `loadExecutionTable` + an L2-side trigger contract that calls trigger proxies:

1. **Deploy on L2 (extend `DeployL2`)**:
   - The destination contracts (real Counter, etc.).
   - **Trigger proxies** on L2 for each destination, tagged `originalRollupId=MAINNET`. The proxy address is what the L2 trigger contract will call.
   - **An L2 trigger contract** (e.g. another `CallTwice`) — its address is the `sourceAddress` baked into the L2 entries' `proxyEntryHash`. Since this address lives on L2, the L2 entries' hash inevitably differs from the L1 entries' hash (different sourceAddress, different sourceRollupId). That's expected — full cross-chain symmetry isn't possible for multi-entry sequential consumption.

2. **L2 entry shape**:
   ```solidity
   proxyEntryHash:      crossChainCallHash(MAINNET_ROLLUP_ID, dest, value, data, l2Trigger, L2_ROLLUP_ID)
   incomingCalls:       [ CrossChainCall(dest, value, data, l2Trigger, L2_ROLLUP_ID, 0) ]
   expectedLookups:     []
   callCount:           1
   rollingHash:         CB(1) → CE(1, true, <cached>)   // starts from 0; _consumeAndExecute
                                                          // resets _rollingHash at the start of
                                                          // each entry consumption.
   ```

3. **ExecuteL2 contract**:
   ```solidity
   vm.startBroadcast();
   EEZL2(managerAddr).loadExecutionTable(_l2Entries(...), noL2LookupCalls());
   CallTwice(l2Trigger).callCounterTwice(triggerProxy);   // or whatever shape the trigger has
   vm.stopBroadcast();
   ```
   Each proxy call inside the trigger forwards to `managerL2.executeCrossChainCall`, which calls `_consumeAndExecute` → resets `_rollingHash`/`_currentIncomingCall` per entry, then `_processNCalls(entry.callCount)`. The trigger pattern matches `multi-call-nested/E2E.s.sol::ExecuteL2` — use it as the reference implementation.

The trade-off: L1 and L2 `proxyEntryHash` values diverge for these scenarios. The cross-chain tie is at the level of "the destination chain produced what the source-side cached `returnData` claimed it would" — verified by asserting real counter state at the end of `ExecuteL2`.

## Pattern B — L2→L1 scenarios (counterL2, bridgeL2 if any, …)

User triggers on L2, destination Counter lives on L1. L2 entry shape is the same as Pattern A's L1 entry (zero calls, just cached returnData). The L1-side simulation looks different:

### L1 entry shape (destination-side, system-driven)

```solidity
L2ToL1Call[] calls = [
    L2ToL1Call(dest /* counterL1 */, value, data, srcAddr /* CAP@L2 */, L2_ROLLUP_ID, 0)
];

bytes32 rh = bytes32(0);
rh = RollingHashBuilder.appendCallBegin(rh, 1);
rh = RollingHashBuilder.appendCallEnd(rh, 1, true, <cached>);

ExecutionEntry entry = {
    stateDeltas:         [],            // optional — set if you want stateRoot to advance
    proxyEntryHash:      bytes32(0),    // ← system-driven; no source-side hash to match
    destinationRollupId: L2_ROLLUP_ID,  // ← queue routed to the L2 rollup id
    l2ToL1Calls:         calls,
    expectedL1ToL2Calls: [],
    expectedLookups:     [],
    callCount:           1,
    returnData:          <cached>,
    rollingHash:         rh,
};
```

### Inline `DeferredL2TXBatcher`

The shared `L2TXBatcher` in `E2EHelpers.sol` auto-promotes leading zero-hash entries into the transient prefix — which would consume the entry inline during `postAndVerifyBatch` and leave nothing for `executeL2TX` to drain. For Pattern B, inline a batcher that pins `transientExecutionEntryCount=0`:

```solidity
contract DeferredL2TXBatcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        uint256 rollupId,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls
    ) external {
        address[] memory psList = new address[](1); psList[0] = proofSystem;
        bytes[] memory proofs = new bytes[](1); proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](1); psIdx[0] = 0;
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: rollupId, proofSystemIndex: psIdx});

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            blockNumber: 0,
            entries: entries,
            l1ToL2lookupCalls: lookupCalls,
            transientExecutionEntryCount: 0,          // ← deferred
            transientLookupCallCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
        rollups.executeL2TX(rollupId);
    }
}

contract Execute is Script, <Scenario>Actions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address psAddr      = vm.envAddress("PROOF_SYSTEM");
        // … other envs …

        vm.startBroadcast();
        new DeferredL2TXBatcher().execute(
            EEZ(rollupsAddr), psAddr, L2_ROLLUP_ID,
            _l1Entries(/* … */),
            noLookupCalls()
        );
        console.log("L1 done; counter=%s", <DestContract>(destAddr).counter());
        vm.stopBroadcast();
    }
}
```

## Rolling hash — the most common bug

For each top-level call in `l2ToL1Calls` (L2: `incomingCalls`):

```
CB(n)              keccak256(prev || 0x01 || n)
... if nested ...
  NB(m)            keccak256(prev || 0x03 || m)
  (nested frame's calls fire here — they advance the same call cursor and add their own CB/CE)
  NE(m)            keccak256(prev || 0x04 || m)
CE(n,s,r)          keccak256(prev || 0x02 || n || success || retData)
```

`n` is the 1-indexed global call number (advances monotonically across the entire entry tree). `m` is the nested-action sequence number. `success`/`retData` are from the actual call result.

Use `RollingHashBuilder.appendCallBegin / appendCallEnd / appendNestedBegin / appendNestedEnd` rather than inline `abi.encodePacked` — it's easier to read and impossible to misalign the argument types.

For Pattern A L1 entry: `callCount=0`, `rollingHash=bytes32(0)` — no calls, no tape.
For Pattern A L2 entry / Pattern B L1 entry: `callCount=1`, one CB/CE pair.

## The `callCount` partition invariant

`entry.callCount + Σ expectedL1ToL2Calls[i].callCount == l2ToL1Calls.length`. Easiest in simple scenarios: `callCount = l2ToL1Calls.length` and no nested actions.

## ComputeExpected — print both tables

```solidity
ExecutionEntry[] memory l1 = _l1Entries(...);
ExecutionEntry[] memory l2 = _l2Entries(...);

console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));

console.log("=== EXPECTED L1 EXECUTION TABLE (N entries) ===");
_logEntry(0, l1[0]);
console.log("=== EXPECTED L2 EXECUTION TABLE (N entries) ===");
_logL2Entry(0, l2[0]);
```

## Gotchas

- **No `@L1` / `@L2` in `///` docblocks.** Solidity natspec parses `@…` as a tag. Use `(CAP on L1, MAINNET)` or `Counter on L2` in `///` blocks. `//` plain comments are fine.
- **Strict `msg.value` match** for `executeIncomingCrossChainCall` — even `value=0` requires `msg.value=0` (won't accept 1 wei).
- **Same-block requirement** on both chains. `run-local.sh`'s `execute_l2_same_block` wrapper disables automine, queues txs, mines them together. Don't manually `vm.roll(...)` in `ExecuteL2`/`Execute`.
- **Strict `proofSystems` and `rollupIds` ordering** in the batch — ascending. Helpers in `E2EHelpers.sol` handle the trivial single-prover / single-rollup case.
- **Legacy shim removal.** Replace `Action({...})` / `actionHash(...)` / `noStaticCalls()` with `crossChainCallHash(...)` / `noLookupCalls()`. They still compile via back-compat shims (`E2EHelpers.sol:52-76`) but new code should use the canonical names.

## Verification

```bash
L1_PORT=<port> L2_PORT=<port+1> bash script/e2e/shared/run-local.sh script/e2e/<scenario>/E2E.s.sol
```

A two-sided green run shows:
- L1 block has the source-side events (`CrossChainCallExecuted` / `L2TXExecuted`).
- L2 block has the destination-side events (`IncomingCrossChainCallExecuted` or the proxy-call `CrossChainCallExecuted`).
- The cross-chain hash printed in both event groups is identical.
- Real destination state advanced (`Counter@dest.counter() == expected`).

Then move the log to `tmp/e2e-success/<scenario>.log`.

## Selector quick-reference

| Selector | Error | Most likely cause in a two-sided context |
|---|---|---|
| `0xf3a3b67c` | `RollingHashMismatch` | Off-chain `rollingHash` doesn't reproduce the on-chain tape — check `success`/`retData` and the partition invariant. |
| `0xed6bc750` | `ExecutionNotFound`  | `crossChainCallHash` differs between source and destination sides — make sure both call `_callHash(...)` from the same `<Scenario>Actions` mixin. |
| `0x2ae204bd` / `0xf9d330ad` | `ExecutionNotInCurrentBlock(uint256)` (L1) / `()` (L2) | `lastVerifiedBlock` (L1) / `lastLoadBlock` (L2) ≠ `block.number` — don't roll blocks between phases. |
| `0xdd0c77c5` / `0x093a2b9f` | `UnconsumedL2ToL1Calls` (L1) / `UnconsumedIncomingCalls` (L2) | `entry.callCount` < flat array length — usually `callCount = l2ToL1Calls.length` for simple entries. |
| `0xed4a913d` / `0x03ae6521` | `UnconsumedL1ToL2Calls` (L1) / `UnconsumedOutgoingCalls` (L2) | An expected reentrant call was declared but the destination didn't re-enter. |
| `0xdd8e4af7` | `ValueMismatch` | `msg.value` ≠ `value` in `executeIncomingCrossChainCall`. |
