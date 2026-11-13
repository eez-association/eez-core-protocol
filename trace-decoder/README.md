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
Incomplete or invalid supported transaction links also require `--allow-partial`.
`--allow-partial` draws the incomplete flow anyway.

Otherwise it prints the transactions it found and their roles, writes
`tmp/flow-diagrams/<hash>.html` (plus the decoded `.json`) and opens the page with
the **Call flow**, **Flame chart** and **Sequence** views. Any of the flow's transactions works as
input: the trigger, the settlement batch or a delivery.

The **Flame chart** draws call depth downwards and execution order left to right; bars
are coloured by chain, so a crossing is a bar whose colour differs from the one above it.
Bar widths count the calls inside, not gas (L1 and L2 gas come from different
transactions); a bar's tooltip shows its gas. Crowded charts expand horizontally
to keep bars separate; use scrolling and zoom to inspect individual calls.

More options (same flags as `decode-trace.mjs`, plus):

```sh
node trace-decoder/flow/render-flow.mjs <TX_HASH> --env-file FILE --views all --open
node trace-decoder/flow/render-flow.mjs tmp/flow-diagrams/<hash>.json --env-file FILE --open   # re-render, no RPC calls
  --l1-rpc URL --l1-trace-rpc URL         # e.g. an archive endpoint for this run
  --l1-explorer-url URL --l2-explorer-url URL   # explorer websites for verify links
  --views flow,flame,layers,sequence,timeline|all
```

The text/JSON CLI uses the same decoder engine: `node trace-decoder/decode-trace.mjs <TX_HASH> [--json]`.

## Show a debug-quote simulation

The flow viewer also imports `eez_debugQuoteFee` responses requested with
`{"transactionTypes":["0x2"],"trace":"calls"}`. Pass either the result object
(the output of `cast rpc ... | jq`) or the full JSON-RPC response envelope:

```sh
node trace-decoder/flow/render-flow.mjs debug-quote.json -o tmp/debug-quote.html
```

Open the generated HTML, or use `--open` to launch it. You can also open/drop a
raw debug-quote JSON into any newly generated viewer page. Import is offline:
no RPC calls, explorer requests, signing or submission.

The viewer opens on the last `final_validation` / `composition` run (or the last
available composition). The **Trace / simulation run** selector exposes every
run independently, including native-system, native-source, settlement and
estimation passes. It preserves the composer's parent/child links across chains;
it does not correlate these runs with mined transactions.

Pages are marked **SIMULATION**. The inspector shows fee fields, context, raw
calldata/output, per-frame gas and status. Contract names and ABI signatures are
not inferred: quote imports currently show addresses, selectors and raw return
bytes. Frame IDs are scoped to their run. Truncation, omitted parents and unknown
statuses stay visible as capture warnings. Frames with unknown statuses are labeled
unknown in the diagrams and inspector, never successful. Invalid graphs and
unsupported trace versions fail explicitly. Only `eez-quote-call-trace` version 1 is supported.

Inclusive frame gas and repeated passes are not summed into transaction gas.
The page has no invented transaction hashes, receipts, settlement results or
matched-transaction claims. A successful simulation does not prove a transaction
was mined or settled. Existing transaction-hash decoding retains its receipt and
content checks. See [dApp RPC guide](../dapps_RPC.md#debug-a-cross-chain-fee-quote)
for the request and observed response.

## Configuration

Read from `--env-file`, then `DEVNET_ENV`, then `chain.env`; nonempty exported variables override
the file and CLI flags override both. File references such as `L1_FRONT=$L1_RPC`
also use nonempty exported values; exported values themselves are literal. CLI
flags override individual options after file expansion. A minimal env file:

```sh
export L1_RPC=https://<l1-rpc>
export L2_RPC=https://<l2-rpc>
export L1_TRACE_RPC=https://<l1-archive-rpc>      # only if L1_RPC cannot trace
export L1_FRONT=https://<l1-frontend>             # composer discovery and L1 source links
export L2_FRONT=https://<l2-frontend>             # L2 source links and settlement correlation
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
| `L1_FRONT`, `L2_FRONT`, `EEZ_CORR_RPC` | composer info, source transaction links and settlement correlation |
| `EEZ_TX_LINKS` | `auto` (default), `required`, or `off`; CLI: `--tx-links` |
| `EXPLORER_L1`, `EXPLORER_L2`, `L1_EXPLORER_TYPE`, `L2_EXPLORER_TYPE` | contract names and ABIs (Etherscan or Blockscout) |
| `L1_EXPLORER_API_KEY`, `L2_EXPLORER_API_KEY`, `ETHERSCAN_API_KEY` | explorer keys |
| `ROLLUPS`, `MANAGER_L2` | pin historical manager addresses (CLI flags override them) |
| `EXPECTED_L1_CHAIN_ID`, `EXPECTED_L2_CHAIN_ID` | chain-id safety checks |

Pinned manager addresses are preserved. If Composer reports a different manager,
the decoder emits `pinned-manager-mismatch` with both addresses so stale pins are
visible after a redeployment.

Without explorers, EEZ contracts still decode from the bundled `src/protocol-abi.json`;
other contracts show as "Unknown contract" and function names come from validated
4byte.directory matches (`--no-4byte` disables that lookup, `--no-explorer` both).

## What a decode does

1. Finds the transaction on L1 or L2 and queries `eez_getCrossChainTransaction`
   with its **transaction hash** on the source chain's frontend (`L1_FRONT` or
   `L2_FRONT`; `EEZ_CORR_RPC` can substitute when that frontend is unset and its chain ID matches the source).
   Complete links name `transactions.l1`, `postBatch`, and `l2[]` directly.
   L1 sources link to committed L2 deliveries; L2 sources link to their system
   table loader and original user transaction. Empty L2 delivery lists are valid
   for static/reverted L1 lookups.
2. Checks chain IDs, source identity, successful receipts, canonical inclusion,
   manager calldata, delivery event order/multiplicity, and L2 loader ordering.
   No intervening table replacement is allowed, including inside the source.
   `ownership.canonical` is checked against **L1** in both directions. The status
   identity and canonical headers are rechecked after fetching the linked traces.
   JSON retains the RPC observation, references and validation checks in
   `transactionLinks`; link completeness alone does not prove execution success.
3. Traces only the linked transactions and matches calls inside that exact set,
   using proxy identity, calldata, value, static context, return/revert data,
   execution tables and nested call structure. Identical occurrences remain
   ambiguous unless consumed-entry and delivery order establish their identity.
   Every ordered pair must also agree on return/revert data and execution scope;
   ordering alone never overrides a mismatch.
   For L2 sources executed through `_attemptExecuteImmediateL2Txs`, the decoder
   checks each attempt's calldata against its batch entry, excludes reverted
   attempts and native entries without L1 calls, and selects the matching L1
   subtree. With multiple successful hosts it verifies the complete canonical
   settlement range, groups each loader plus source as one unit, and maps their
   order to successful L1 entries. Source links must name the same posting tx;
   loader coverage and entry/unit counts must agree. Other source units are
   verified through reads, without adding their traces to the requested flow.
   Missing evidence or mismatched counts prevents an ordinal match.
4. When the method is unsupported (`-32601`) or returns a legacy source record
   without `transactions`, `auto` uses the previous block-hash settlement lookup
   and bounded scanning path. Missing frontend configuration and fully traced local transactions without EEZ
   calls also permit this compatibility path. A system transaction (batch, loader or delivery) with no
   source record can still be opened through settlement discovery. Batch postings
   are recognized inside wrapper traces when a successful `postAndVerifyBatch`
   executes in the configured L1 manager's context and no enclosing frame reverts.
   A trace is required. Outgoing source calls from the poster’s meta hook or
   surrounding wrapper block this fallback, including caught or reverted attempts.
   Reentrant callbacks inside the manager’s immediate L2Tx execution are not sources.
   Fully decoded setup/administration calls and views without outgoing source calls
   also permit fallback; unknown manager calldata remains unresolved. A null
   source record alone does not authorize broader discovery. Supported
   incomplete/null **source** records, transport failures and invalid links are
   unresolved; they never silently trigger a broader scan. Run again after a
   pending source completes. `required` disallows compatibility fallback;
   `off` disables exact links; `--no-correlation` disables both RPC linking paths.

A correlation-only endpoint on the other chain is used for settlement discovery
in `auto` mode, not as a source frontend; `required` still needs a matching source
frontend. Legacy discovery queries the method for the source chain with the actual
receipt block hash, trying the corresponding front first after any explicit
correlation override. The two methods may live on different fronts. Unsupported
methods and transport failures try the next endpoint with the same block hash. Malformed successful responses stop discovery. If transport failures
exhaust the endpoints, the result stays unresolved; they never authorize a broad
timestamp scan.

Legacy discovery checks settlement block hashes in batches of up to 100 reads,
then scans manager calls/events in the requested block, posting block and L2 range.
Without settlement support it searches ±2,000 blocks around the nearest timestamp.
`--thorough` and explicit block ranges extend this compatibility search; they do
not expand a supported exact transaction link set. Null historical block reads,
including null batch slots, retry the configured archive trace RPC.

## Linked flow and recorded traces

**Token notes · experimental** adds colored notes inside call-flow boxes for
ERC20-style Transfer events: sent, minted or burned, with a compact amount and
address preview inside the existing call box. Click a note to open a larger card
in the inspector, showing **Token, From, To, Amount**, with full addresses and
known contract names and diagram tags. Toggle notes off in the call-flow toolbar.
Notes require matching trace and receipt events, preserving repeated transfers;
reverted events, unmatched logs and ERC721 events are excluded. Delegatecall
logs follow their folded call box. Symbol and decimals come only from successful
metadata reads of that token on that chain in the captured transaction. Missing
decimals display raw units. These are emitted amounts, not net balance changes
or inferred cross-chain asset transfers. Quote simulations have no token notes.

**Linked flow** is the default, including for verified transaction links. Confirmed
cross-chain matches connect the local request to its remote execution with arrows.
EEZ plumbing stays folded, including L2 value transfers to the manager’s
`SYSTEM_ADDRESS` verified at the receipt block. Those observed calls remain
inspectable with **EEZ plumbing** enabled. EEZ markers on cross-chain arrows also
follow this checkbox in both directions; the default view shows direct application
connections. Ambiguous matches do not become confirmed connections;
unobserved remote calls are explicitly labeled as not observed. This is a logical
call flow, not a shared timeline across chains.

With verified links, **Trace view → Recorded traces** shows each transaction's
physical call tree in its original order. **Both chains** displays the linked trees
without cross-chain arrows; call numbering starts independently on each chain.
The sequence view also gives each chain its own rows. For an L2 source, the
identified L1 entry is shown separately from other entries in its settlement batch.
If that entry cannot be isolated, a notice explains why and the full batch remains
selectable. The complete physical trace is always retained in JSON.

The gas summary shows separate **L1 flow gas** and **L2 flow gas** totals,
including EEZ plumbing, hidden reads and reverted calls. Physical parent/child
relationships prevent nested calls from being counted twice. Totals stay fixed
across view, transaction and visibility selections: they describe the requested
flow. The breakdown includes the source, linked L2 table loading and deliveries,
and the isolated L1 entry when available. Whole transactions use receipt gas;
isolated subtrees use inclusive call-trace gas. Full related transaction receipt
totals are shown separately because settlement batches can contain other flows.
Shared settlement work, transaction overhead and refunds cannot be allocated
exactly to an isolated entry. Missing gas or incomplete attribution is marked
partial; these are gas units, not fees.

Recorded L2 proxy calls label their prepared table responses. State observations,
when supplied, are values after a block, not per-transaction storage writes.
Cross-chain reads always remain visible in both modes. **Local reads** controls
additional read-only calls, and an explicit choice persists across trace and view
changes. Optional association notes show their codes and messages.
Proxy identity failures, forwarding inconsistencies and rejected return/revert
matches remain unresolved. Selecting a remote call card opens its crossing
evidence even with plumbing off.
The text CLI also defaults to linked flow; use `--recorded` for separate physical
traces.

L1→L2 top-level reads, reverting calls, and calls erased by an enclosing revert
use prepared return/revert data and have no L2 delivery. These are labeled
**Prepared result · no L2 delivery expected** when no contradictory remote execution
was observed. L2→L1 reads and reverting calls do execute inside the L1 entry.
Missing traces still require an archive endpoint or explicit partial output.

A fresh complete decode replaces older JSON even if its match count decreases.
With `--allow-partial`, a run missing call traces may retain a complete saved capture
only for the same schema, chain/manager configuration and canonical transaction
inclusion. Fresh validation failures prevent this reuse. The printed summary
describes the capture actually rendered.

## How transactions are classified

The page roots relevance at the **requested transaction** and follows its matched
logical calls. Execution tables and shared batch posts are dependencies; they do
not connect every other trigger in the batch to this flow. The requested application
transaction controls the default view and title, including ordinary transfers.
The raw JSON retains complete physical traces for inspection. Roles are determined
from evidence (`classifyTransactions` in `flow/model.mjs`):

- **Trigger**: an application transaction whose cross-chain call is top-level (not nested
  in a delivered call). If an L1 batch entry with `proxyEntryHash == 0` (an L2Tx entry)
  carries the same call, the flow started on L2.
- **Settlement batch / execution table load / L2 delivery**: by the EEZ function called.
- **Not part of this flow**: no cross-chain calls (for example proxy setup), settled in
  the same batch only.

Table loads and deliveries are shown with **EEZ plumbing** ticked; their inspector shows
the decoded execution table. Cross-chain reads remain visible; **Local reads** adds other static calls.
For a requested L2 transaction without cross-chain calls, its correlated **L1 settlement**
is available directly in the transaction selector. Selecting it reveals the batch's
protocol calls; this settlement relationship does not create a cross-chain call edge.

## Layout

```
show-tx.sh           one-command entry point
decode-trace.mjs     text/JSON CLI and public API (decodeCrossChainTrace)
src/                 decoder: config, engine, rpc, transaction-links, logical (call graph + matching),
                     prepared-result (shared result classification),
                     protocol (+ protocol-abi.json), abi-decoder, explorer
flow/                diagram: model.mjs (trace → call tree, roles), render-flow.mjs (CLI),
                     viewer/ (template.html, viewer.js)
samples/             synthetic example traces (build-samples.mjs)
tests/               node:test suites and fixtures
```

Update `src/protocol-abi.json` when the EEZ/EEZL2 ABI changes.

## Tests

With decoder dependencies installed, build the contract ABIs before the tests:

```sh
forge build
npm --prefix trace-decoder test
```

`tests/flow-viewer.test.mjs` runs the page script against a stub DOM and checks that
boxes never overlap, every call arrow points right and contract tags are consistent.
Fixtures are synthetic callTracer traces of the E2E topologies, not archive captures.
