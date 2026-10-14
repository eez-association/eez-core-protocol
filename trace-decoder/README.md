# Cross-chain trace decoder

Decodes one EEZ transaction (L1 or L2), finds the related transactions on the other
chain, matches every cross-chain call to its remote execution, and draws the flow.
Read-only: it only uses RPC reads/traces and explorer lookups.

## Show a transaction

```sh
trace-decoder/show-tx.sh <TX_HASH> --env-file chain.envmainnet
```

Every transaction it finds (the requested one and the related L1/L2 ones) must have a
call trace. If an endpoint cannot trace one, it exits with an error naming the
transaction and the missing setting (`L1_TRACE_RPC` / `L2_TRACE_RPC`), writes nothing
except `<hash>.partial.json`, and keeps any complete trace saved earlier.
`--allow-partial` draws the incomplete flow anyway.

Otherwise it prints the transactions it found and their roles, writes
`tmp/flow-diagrams/<hash>.html` (plus the decoded `.json`) and opens the page with
the **Call flow** and **Sequence** views. Any of the flow's transactions works as
input: the trigger, the settlement batch or a delivery.

More options (same flags as `decode-trace.mjs`, plus):

```sh
node trace-decoder/flow/render-flow.mjs <TX_HASH> --env-file FILE --views all --open
node trace-decoder/flow/render-flow.mjs tmp/flow-diagrams/<hash>.json --env-file FILE --open   # re-render, no RPC calls
  --l1-rpc URL --l1-trace-rpc URL         # e.g. an archive endpoint for this run
  --l1-explorer-url URL --l2-explorer-url URL   # explorer websites for verify links
  --views flow,layers,sequence,timeline|all
```

The older text/JSON CLI is unchanged: `node trace-decoder/decode-trace.mjs <TX_HASH> [--json]`.

## Configuration

Read from `--env-file`, then `DEVNET_ENV`, then `chain.env`; exported variables override
the file and CLI flags override both. A minimal env file:

```sh
export L1_RPC=https://<l1-rpc>
export L2_RPC=https://<l2-rpc>
export L1_TRACE_RPC=https://<l1-archive-rpc>      # only if L1_RPC cannot trace
export L2_FRONT=https://<l2-frontend>             # settlement correlation
export EXPLORER_L1=https://etherscan.io/
export EXPLORER_L2=https://<l2-explorer>
export L1_EXPLORER_API_KEY=<etherscan-key>        # Etherscan requires a key
```

`EXPLORER_L1` / `EXPLORER_L2` serve twice: the decoder uses them for contract names and
ABIs (an Etherscan website URL is mapped to its V2 API, a Blockscout site to its API), and
the page uses them, reduced to scheme/host/path, for the explorer links in the Verify
panel. Re-rendering a saved JSON reads them from the same env file
(`render-flow.mjs <hash>.json --env-file FILE`). Without them, known chains (Ethereum,
Sepolia, Gnosis, Chiado) still get links.

Only these variables are parsed; everything else in the file (including private keys)
is ignored:

| Variable | Use |
| --- | --- |
| `L1_RPC`, `L2_RPC` | required: transactions, receipts, blocks, `eth_call` |
| `L1_TRACE_RPC`, `L2_TRACE_RPC` | `debug_trace*`; also retried for reads the read RPC cannot answer (historical `eth_call`, missing receipts), so one archive endpoint here is enough |
| `L1_FRONT`, `L2_FRONT`, `EEZ_CORR_RPC` | composer info and settlement correlation |
| `EXPLORER_L1`, `EXPLORER_L2`, `L1_EXPLORER_TYPE`, `L2_EXPLORER_TYPE` | contract names and ABIs (Etherscan or Blockscout) |
| `L1_EXPLORER_API_KEY`, `L2_EXPLORER_API_KEY`, `ETHERSCAN_API_KEY` | explorer keys |
| `ROLLUPS`, `MANAGER_L2`, `EEZ_ROLLUP_MANAGER` | pin historical manager addresses |
| `EXPECTED_L1_CHAIN_ID`, `EXPECTED_L2_CHAIN_ID` | chain-id safety checks |

Without explorers, EEZ contracts still decode from the bundled `src/protocol-abi.json`;
other contracts show as "Unknown contract" and function names come from validated
4byte.directory matches (`--no-4byte` disables that lookup, `--no-explorer` both).

## What a decode does

1. Finds the transaction on L1 or L2 and asks the correlation endpoint (`EEZ_CORR_RPC`,
   `L2_FRONT`, `L1_FRONT`, `L2_RPC`, first that answers) which settlement and L2 block range
   belong to its exact receipt block hash, as the E2E runner does. Without correlation
   it searches ±2,000 blocks of the other chain. A failed lookup on a supported
   endpoint is reported as unresolved instead of expanding to a timestamp search.
   Settlement block hashes are independently checked using JSON-RPC batches of up
   to 100 reads; providers rejecting batches fall back to bounded individual reads.
2. Scans the requested block, the settlement block and the settled L2 range for the other
   transactions of the flow (the correlation endpoints return block ranges, not transaction
   lists). In every scanned block only transactions sent to the EEZ manager or carrying an
   EEZ manager event are traced. Range scans reuse `eth_getLogs` results and the
   prefetched blocks instead of fetching every block's receipts. Empty blocks need
   no receipt lookup. If range logs fail, block receipts/logs remain the fallback.
   Full block transactions retain direct manager calls without committed events.
   A fully traced L2 transaction that never touches the EEZ manager follows its exact
   settlement directly, without scanning other jobs in the settled range. Hash
   validation is unchanged; `--thorough` or explicit ranges can extend discovery.
   `--thorough` traces every transaction instead; use it when a wrapper may reach the
   manager without emitting any event (e.g. an eventless wrapper delivery on L2).
3. Builds the call graph, matches crossings and decodes contracts through the explorers.

## How transactions are classified

The decoder collects every transaction in the settled L2 block range. The page keeps
only those connected to the flow by evidence (`classifyTransactions` in `flow/model.mjs`):

- **Trigger**: an application transaction whose cross-chain call is top-level (not nested
  in a delivered call). If an L1 batch entry with `proxyEntryHash == 0` (an L2Tx entry)
  carries the same call, the flow started on L2.
- **Settlement batch / execution table load / L2 delivery**: by the EEZ function called.
- **Not part of this flow**: no cross-chain calls (for example proxy setup), settled in
  the same batch only.

Table loads and deliveries are shown with **EEZ plumbing** ticked; their inspector shows
the decoded execution table. View (static) calls are hidden until **View calls** is ticked.
For a requested L2 transaction without cross-chain calls, its correlated **L1 settlement**
is available directly in the transaction selector. Selecting it reveals the batch's
protocol calls; this settlement relationship does not create a cross-chain call edge.

## Layout

```
show-tx.sh           one-command entry point
decode-trace.mjs     text/JSON CLI and public API (decodeCrossChainTrace)
src/                 decoder: config, engine, rpc, logical (call graph + matching),
                     protocol (+ protocol-abi.json), abi-decoder, explorer
flow/                diagram: model.mjs (trace → call tree, roles), render-flow.mjs (CLI),
                     viewer/ (template.html, viewer.js)
samples/             synthetic example traces (build-samples.mjs)
tests/               node:test suites and fixtures
```

Update `src/protocol-abi.json` when the EEZ/EEZL2 ABI changes.

## Tests

```sh
cd trace-decoder && npm test
```

`tests/flow-viewer.test.mjs` runs the page script against a stub DOM and checks that
boxes never overlap, every call arrow points right and contract tags are consistent.
Fixtures are synthetic callTracer traces of the E2E topologies, not archive captures.
