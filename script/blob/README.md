# Blob ⇄ Table Testing Framework

Proves that the [standardized blob message format](https://github.com/eez-association/eez-core-protocol/blob/567768cd975aacfb4d1f31a1612a185a2280ceb2/docs/blobs/BLOB_FORMAT_SPEC.md)
(version `00`) and this repo's execution tables are two faithful encodings of the same
cross-chain execution: given a set of messages, the framework derives every chain's tables,
derives the messages back from those tables, and **executes the derived tables on the real
`EEZ` / `EEZL2` managers**.

## The pipeline

A scenario is written as a blob message list — nothing else. `runScenario` then checks:

```
                 1. codec round trip
  BlobMessage[] ──encode──▶ bytes ──4844 pack──▶ blobs ──unpack+decode──▶ BlobMessage[]  ═ input

                 2. IR round trip
  BlobMessage[] ──parse──▶ ScenarioStore (call forest) ──emit──▶ BlobMessage[]           ═ input

                 3. callGas probe
  ScenarioStore ──probe calls vs empty tables──▶ per-node callGas oracle (gasByNode)
                                                 (all 0 when useGasLeft = false)

                 4. Blob → Table          5. Table → Blob
  ScenarioStore ──TableGenerator──▶ tables ──TableStitcher(+sidecar)──▶ BlobMessage[]    ═ input
                                                                        (byte-identical blob)

                 6. Live execution
  tables ──▶ postAndVerifyBatch / loadExecutionTable / executeIncomingCrossChainCall
         ──▶ scripted actors make the real proxy calls
         ──▶ every return value, revert payload, rollback, ether delta and final
             state root asserted
```

## Files

Framework core (this folder, `script/blob/`):

| File | Role |
|---|---|
| `BlobMessages.sol` | Message model + `Msg` builders (`initiate`, `call`, `returnSuccess`, …) |
| `BlobCodec.sol` | Wire codec (LE scalars, protobuf varints, version byte) + §5 validity (bracket discipline via the context stack, placement, padding, close marker) |
| `BlobPacking.sol` | §4 EIP-4844 packing: 31 stream bytes per field element, LSB-first |
| `ScenarioStore.sol` | The IR — a stored call forest; messages→IR parser and IR→messages emitter |
| `TableGenerator.sol` | **Blob → Table**: walks the forest once and builds the L1 batch entries (L2Tx hosts, origin entries, static pool, state-delta ledger, ether invariant) and each L2's units (origin groups / inbound deliveries), simulating every chain's rolling hash exactly |
| `TableStitcher.sol` | **Table → Blob**: rebuilds the forest from tables + sidecar, matching reentrant rows by their content-addressed keys against a re-simulated live hash, and cross-checking every stored `rollingHash` |
| `ScriptedActor.sol` | Programmable stand-in for application contracts; performs the real nested proxy calls and asserts returns in-flight |
| `BlobTranslator.sol` | One-call facade: blob ⇄ byte stream ⇄ tables (each direction a single function — see below) |
| `BlobConstants.sol` | Shared scalar vocabulary: unit kinds, root kinds, actor step kinds, sentinels, `MAX_CALL_DEPTH`, `blobGenesisRoot` |
| `BlobSidecar.sol` | The sidecar's data model (per-tx metadata, static call fields, sub-read results, chain ops) — shared by stitcher, translator, and harness |
| `CallShapes.sol` | Conversion library between the three call representations: IR (`CallNode`/`CallParams`) ⇄ L1 table rows (`L2ToL1Call`) ⇄ L2 table rows (`CrossChainCall`) |
| `BlobTools.s.sol` + `examples/` | File-based tools: DSL file → tables + wire bytes, blob hex → tables (see below) |

Tests (`test/blob/`):

| File | Role |
|---|---|
| `BlobScenarioBase.sol` | Test harness: chain/actor setup, the 6-step pipeline, per-tx batch posting, unit driving |
| `ScenarioDSL.sol` | The DSL compiler (`DslScenarioBase`): script → messages, auto chain/actor setup, auto `execCount` asserts |
| `DslExamples.t.sol` | Commented walkthrough examples — the place to START reading |
| `ScenarioCatalog.t.sol` + `SCENARIO_CATALOG.md` | The direction catalog: one test per basic cross-chain shape; the MD documents the exact L1 batch each shape produces, and the test pins that shape with assertions |
| `DslScenarios.t.sol` | End-to-end scenarios authored in the DSL (several mirror `BlobScenarios` raw-message twins) |
| `BlobScenarios.t.sol` | End-to-end scenarios authored as raw message lists (shapes the DSL can't express: chain ops, callData tail, custom payloads) |
| `DslParser.t.sol` | DSL rejection tests — every parse error with its exact `DSL line <n>: <reason>` message |
| `BlobCodec.t.sol` | Byte-layer unit tests (round trips + one test per §5 rejection) |
| `BlobTranslator.t.sol` | Facade round trips: blob → data → tables → data → blob, byte-identical |

## One-call conversions: `BlobTranslator`

`BlobTranslator.sol` is a facade over the pipeline — each direction is a single call,
no store/generator/stitcher orchestration at the call site:

| Call | Conversion |
|---|---|
| `blobsToData(blobs)` | EIP-4844 blobs → logical byte stream (§4 unpack; padding included, the codec skips it) |
| `dataToBlobs(blobData)` | byte stream (blob portion) → full-size blobs (§4 pack) |
| `dataToTables(blobData, callDataTail)` | byte stream → `Tables` (decode → parse → generate) |
| `tablesToData(tables)` | `Tables` → byte stream + callData tail (stitch → emit → encode; byte-identical to the source stream) |
| `blobsToTables` / `tablesToBlobs` | the two composed end to end |
| `messagesToTables` / `tablesToMessages` | same directions at the `BlobMessage[]` level |

`Tables` bundles the L1 batch artifacts, every L2 chain's units in execution order, and
the sidecar — so `dataToTables` output feeds `tablesToData` directly and round-trips to
the exact input bytes. Tables are derived with a zero callGas oracle (correct while
deployments run `useGasLeft = false`; the observed-gas mode needs the harness's probe
phase instead). Round-trip tests: `test/blob/BlobTranslator.t.sol`.

## Files in, tables out: `BlobTools.s.sol`

Scenarios can live in `.dsl` files (see `examples/showcase.dsl`) and be turned into
tables from the command line:

```bash
# DSL file → messages, wire bytes, and every chain's tables
forge script script/blob/BlobTools.s.sol --sig "run(string)" script/blob/examples/showcase.dsl

# blob-portion hex file (0x…, padding optional) → messages and tables
forge script script/blob/BlobTools.s.sol --sig "runBlob(string)" my-blob.hex
```

Needs `fs_permissions` read access (set in `foundry.toml`).

## Writing a new scenario

```solidity
contract MyScenario is BlobScenarioBase {
    function setUp() public {
        _setUpChains(2);                        // registers L2 chains 1..2 (chain 0 = L1)
        driver = newActor(0);                   // a tx's root calls share one driver actor
        target = newActor(1);                   //   on the origin chain
    }

    function test_myFlow() public {
        MsgList memory l = Msg.list(8);
        Msg.push(l, Msg.initiate(0, "tx-data"));                                    // origin chain
        Msg.push(l, Msg.call(1, address(driver), address(target), 0, hex"aabb"));   // L1 → chain 1
        Msg.push(l, Msg.returnSuccess("hello"));                                    // its result
        Msg.push(l, Msg.finish());
        Msg.push(l, Msg.closeBlobStream());
        runScenario(Msg.done(l));               // codec + both translations + live execution

        assertEq(target.execCount(), 1);        // committed mutable executions survive;
    }                                           // rolled-back ones (regions, failures) don't
}
```

Rules the harness enforces:
- every `fromAddress` / `toAddress` must be a `newActor(chainId)` on the right chain;
  a call's `fromAddress` must be the actor executing it (the parent's `toAddress`,
  or the tx's driver for root calls);
- chain ids are rollup ids: `0` = L1, L2s are `1..n` in `_setUpChains(n)` order.

Covered message shapes: nested calls across L1/L2A/L2B in every direction, callbacks into
the origin (reentrant tables on both sides), sibling repeats, `ReturnFail` at top level
(entry runs → verifies → reverts) and nested (caught, `success = false` row),
`StaticCall` reentrant (STATIC row) and top-level (pool entry with state-root pins,
optionally carrying its own live-verified sub-reads),
`Snapshot`/`Revert` (destination-side `revertNextNCalls`, protocol-level rollback observed
via `execCount`), value transfer (L1 ether-delta invariant + L2 mint), `ChainOperation`s
and multi-transaction slots with a callData tail.

## Authoring scenarios as pseudo-code (the DSL)

For generic flows there is a second authoring layer: `DslScenarioBase`
(`test/blob/ScenarioDSL.sol`) compiles a pseudo-code script into the message
list, auto-deploys the referenced chains plus one driver and one target actor
per chain, runs the full `runScenario` pipeline, and asserts every actor's
committed `execCount` against what the script implies:

```solidity
contract MyScenarios is DslScenarioBase {          // no setUp needed
    function test_callback() public {
        runDsl(string.concat(
            "L1 call L2_A\n",
            "L2_A staticCall L1\n",
            "L1 return\n",
            "L2_A call L1        # callback into the origin\n",
            "L1 return\n",
            "L2_A return\n"
        ));
    }
}
```

Grammar (case-insensitive; `#` starts a comment; blank lines ignored):

| Line | Meaning |
|---|---|
| `<chain> call <chain> [value <amount> [wei\|gwei\|ether]]` | executor calls target; opens a frame (optionally carrying ether — default unit wei) |
| `<chain> staticCall <chain>` | read-only frame (a top-level one may nest leaf static sub-reads of the origin chain) |
| `<chain> return` / `<chain> returnFail` | closes the innermost frame |
| `<chain> snapshot` … `<chain> revert` | forced-revert region in the current frame |
| `--` | transaction separator |

`<chain>` is `L1` or `L2_a`..`L2_z` (chain id 0, 1..26). The leading chain token
is the chain **executing** the instruction and is validated against the context
stack — any structural mistake reverts with `DSL line <n>: <reason>`. The first
instruction of each transaction fixes the origin (implicit Initiate); `--` and
end-of-script emit Finish, and end-of-script adds CloseBlobStream. All payloads
are auto-generated and globally unique (`dsl.tx#i`, `dsl.call#k`, `dsl.ret#k`,
…), so repeated shapes never re-match a rolled-back entry. `dslCompile(script)`
returns the compiled `BlobMessage[]` without executing, for message-level
assertions.

DSL limits (beyond the v1 shape restrictions below): no
`ChainOperation`s, and one `runDsl` per test (a second run would diverge from a
fresh generator's genesis-derived state roots). Scenarios live in
`test/blob/DslScenarios.t.sol`; parser rejection tests in
`test/blob/DslParser.t.sol`.

## What the sidecar is (and why it's honest)

`TableStitcher` never sees the original messages — only the generator's tables plus a
sidecar of data that *provably never reaches any table*:

- per-tx metadata: origin chain, `tx_data`, root-slot kinds (tables don't delimit txs);
- `ChainOperation` payloads and the `CloseBlobStream` position (chain-local, not cross-chain);
- static call fields (both managers match static reads by hash only) — except a read's
  own sub-reads, whose fields live in the static entry's sub-call array: for those only
  the RESULTS ride the sidecar (they are only ever hashed into the untagged accumulator);
- region sizes (destination markers can't distinguish one region over two siblings from
  two adjacent regions).

Everything else — call fields, results, ordering, nesting, revert structure — is recovered
from the tables and cross-checked against every entry's stored `rollingHash`.

## v1 shape restrictions (translation layer, not the codec)

The byte codec accepts any spec-valid stream; the table translation additionally requires:
a static call nests only when it is a TOP-LEVEL read, and then only leaf static sub-reads
of the reader chain (the chain that fired the read) — that is the shape the static
entries verify, re-running the sub-read array live on the resolving chain against the
untagged rolling hash; `Snapshot` regions don't nest, `CloseBlobStream` sits
between transactions, a `ReturnFail` frame carries no committed (successful mutable)
sub-call — the frame's terminal revert rolls back its own nested consumptions on the
executing chain, so no stored rolling hash could match live (failing or static sub-calls
are fine) — and a repeated identical call after a reverted region/entry on the
same origin may re-match the rolled-back entry (protocol scan semantics). `ScenarioStore`
rejects unsupported shapes with `UnsupportedShape(reason)`.
