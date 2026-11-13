# Composer RPC reference

These are the five `eez_` RPC methods used by this repository. All are read-only
and run on a composer front. Use the existing network configuration.
The examples show JSON-RPC `params` arrays; replace angle-bracket placeholders.

| Method | Use | Front |
| --- | --- | --- |
| `eez_composerInfo` | Discover version, contracts and chains | L1 |
| `eez_quoteFee` | Get the fee for an exact source transaction | Source chain |
| `eez_getCrossChainTransaction` | Check a transaction's progress or rejection | Source chain |
| `eez_getSettlementByL2Block` | Find the L1 settlement for an L2 block | L2 |
| `eez_getSettledL2RangesByL1Block` | Find the settled L2 blocks associated with an L1 block | L1 |

## API compatibility and observed changes

The `version` returned by `eez_composerInfo` identifies the composer build;
`eez_quoteFee.version` identifies the quote response version. Record both when
reporting an integration failure. A quote version alone does not establish that
every field name is unchanged.

On 2026-10-15, this harness observed version-1 fee options change from
`intentHash` to `requestHash`, with `recoveryMode` also disappearing. The runner
accepts either hash spelling and preserves the raw quote fields in its evidence.
Both spellings remain supported; neither is assumed to be the final API field name.

On 2026-10-16, the composer rejected an unquoted L1 trigger with
`l1_tip_underfunded` and returned a valid version-1 quote on L1. The staged runner
now quotes both L1 and L2 triggers, retaining the same intent and fee checks.
Standalone and load-test cross-chain triggers use the same policy. Older
deployments may return `unsupported_direction`; without a supported quote RPC,
cross-chain submission stops.

For another schema change, retain the exact request, response and composer build
version, compare them with this reference, and add a regression fixture before
changing the parser. Missing or malformed required quote fields stop submission;
they must not trigger guessed fees or bypass intent validation.

## eez_composerInfo

**Params:** `[]`

Returns `version`, `eezContracts` and `supportedNetworks`. Contract fields are
`eezRegistryAddress`, `eezRollupManagerAddress` and `eezL2Address`.
Network fields `eezL1` and `eezL2` are Ethereum chain IDs, not EEZ rollup IDs.
Use discovery instead of copying deployment addresses from an older run.
The network harness then calls `ROLLUP_ID()` on `eezL2Address` through the L2
read RPC. It requires a nonzero uint64 ID and checks that L1 registry
`rollups(id).rollupContract` equals `eezRollupManagerAddress`. This validated ID
is exported as canonical decimal `L2_ROLLUP_ID`; an explicit decimal value must
agree numerically. These reads retry transient transport failures at most three
times (20 seconds per attempt, one-second delays); invalid identities fail immediately.
The expected manager assertion is bound to the validated network configuration
when inherited by workers.
The rollup ID is distinct from
`supportedNetworks.eezL2`, which is the Ethereum chain ID.

## eez_quoteFee

**Params:**
```json
[{"from":"<funded sender>","to":"<deployed target>","data":"<exact calldata>","value":"0x0","nonce":"0x2"}]
```

`nonce` is the exact nonce of the prepared trigger, also for consecutive
same-account bursts. Never let the quote select a different nonce. A selected
option's `error.code` and `error.message` are terminal diagnostics; do not sign
or fall back to node fees when an option is rejected.

`value` is the native amount in wei as a hex quantity; replace `0x0` for a
nonzero transfer. Quote after deployment, immediately before signing and sending.

Version 1 returns `chainId`, `nonce`, `expiresAt` (Unix seconds) and `options[]`.
Older deployments also returned `recoveryMode`. Chain ID, nonce, expiry and option
quantities are hex encoded.

| Option type | Fields to sign with |
| --- | --- |
| Legacy (`0x0`) | `gas`, `gasPrice` |
| EIP-1559 (`0x2`) | `gas`, `maxFeePerGas`, `maxPriorityFeePerGas` |

Each option also has `estimatedFee` and `requestHash` (`intentHash` on older
deployments). This hash is quote metadata, **not a transaction hash**.

Require matching chain IDs for the front, read node, candidate and quote.
Staged and load runs check each front/read pair once per run (in memory only);
other callers read both chain IDs per trigger.

Preserve sender, target, calldata, value, nonce and transaction type. Check expiry
and funds; maximum cost is native value plus quoted gas times the gas price
(or maximum fee per gas). Use the quoted gas even if the prepared limit differs.
Keep quote/sign/send together and save the quote. Only cross-chain trigger
transactions on L1 and L2 use `eez_quoteFee`. Deployments, funding transfers and
other ordinary transactions keep their existing node fee path.

The load-test runner has an explicit cached-fee exception described in
[the load-test guide](README.md): after a valid worker quote, it may
reuse fee numbers when transient retries for a later quote are exhausted.
Explicit rejections and malformed quotes remain terminal. Such sends are labeled
`cached-load-test` and do not carry a valid quote for their new nonce.

With `--burst`, the load runner instead shares one initial quote's gas/fee
numbers across wallets for the same call template, optionally multiplying fee
prices. Burst sends bypass the per-chain lock and are marked `cached-load-test`;
definite underfunded refusals allow up to three successive 1.18× fee bumps
(rounded up), preserving the nonce. Underfunding after the third bump enters
the normal fresh-quote retry path. Workers retain successfully accepted
gas/fee values for subsequent sends, including refreshed quote values. Uncertain sends are never repriced or resent.

For all other paths, a valid composer quote is required before signing or submitting a cross-chain
trigger. Recognized transport failures (including timeouts, connection errors and
HTTP 5xx) retry the same quote request within `EEZ_QUOTE_TIMEOUT` (default 120
seconds). Each RPC attempt is capped at 30 seconds or the remaining deadline,
whichever is shorter; retries wait up to two seconds and are capped at 60 attempts.
There is no node-fee fallback. Exhausting the deadline stops submission.
Unsupported quote RPCs (-32601 or -32004/unsupported_direction), disabled quotes,
unknown composer errors, invalid params, simulation reverts, and malformed, expired
or inconsistent returned quotes stop submission immediately.

Serialize the full quote/sign/send sequence per source chain, holding
`$TMPDIR/eez-e2e-fee-quote-<chainId>.lock` through submission. Different chains
use independent locks; same-chain workers and recovery share a lock.
Queue waiting is separate from `EEZ_QUOTE_TIMEOUT` (default 120
seconds), which starts at the quote request. In addition to transport failures,
retry explicit `quote_busy`, `stale_context`, HTTP 429, or known temporary
`quote_unavailable` responses within that deadline. Inspect typed `data.code` and
`data.message` before treating generic `-32004` as terminal, for both JSON-RPC
and Cast-formatted errors. The allowed `quote_unavailable` messages are
`quote unavailable: settlement reconciliation pending`,
`quote unavailable: unsettled native history requires reconciliation`, and
`quote unavailable: queued predecessor is entering composition`.
Other `quote_unavailable` reasons remain terminal. Exhausting the quote deadline
or retry count is terminal. Invalid returned quotes and local failures also remain terminal.

A definite `-32003` admission rejection with `quote_busy`, `stale_context`, or one
of those `quote_unavailable` messages waits up to two seconds and retries the
identical signed bytes under the original deadline while retaining the lock.
It does not obtain a fresh quote or change the prepared nonce, payload, or fees;
quote expiry still stops submission. Local persistence failures, uncertain sends
and other submission errors do not take this retry path. Every recognized refusal
is retained in `fee-quote-*.rejections.jsonl`.

Definite `-32003` refusals with `l1_tip_underfunded` / `l2_tip_underfunded` also
retry with a fresh composer quote under the same deadline, never with node fees.
Each refusal is logged (chain, nonce, signed hash; staged: `send-failed.log`), and
the staged exit summary counts them. A pending-nonce `-32602` quote refusal stays
terminal: waiting for mining would break same-account bursts (`counter-multi-tx`).

Resume obtains fresh quotes for unsent transactions; a known saved transaction
is adopted without resending. Stuck cross-chain triggers on either chain require a
fresh composer quote, using the same bounded retries for transient RPC failures.
A returned quote must preserve nonce/gas and satisfy
replacement pricing; otherwise recovery stops. Deployment recovery uses node
fees directly. Uncertain submissions never cause a fallback resend.

Staged evidence: `jobs/<job>/fee-quote-<index>.json`.
Load-test evidence: `fee-quote-<worker>-<index>.json` in the run directory.
Before validating an initial-send quote, the runner appends the RPC response to
`fee-quote-<index>.responses.jsonl` beside its evidence file (load runs include
the worker in the filename). Each record has the timestamp, requested intent,
prepared nonce/type and `rawResponse` text, including malformed/non-JSON responses.
Retries and resumes append; no signing key is recorded. RPC failures remain in
the send log. Failure to save the response stops submission.
Initial-send evidence records `feeSource: composer`, signed hash, gas and fees.
Older run evidence may contain `feeSource: node` from the former fallback policy.
Local Anvil tests do not use this service. Node fees remain applicable to ordinary
deployments and funding transfers only.

## eez_getCrossChainTransaction

**Params:** `["<source transaction hash>"]`

Returns the composer's record for that transaction. Inspect `hash`,
`lifecycle`, `ownership.state`, `ownership.reason` and
`ownership.rejection.error`. A terminal rejection explains why processing
stopped. A held transaction may have no receipt: a missing receipt alone does
not prove rejection. Front acceptance alone does not prove mining or settlement.

For completed transactions, `transactions` contains `l1`, `postBatch`, `l2[]`,
`complete`, `basis`, and `attemptGeneration`. Each transaction reference contains
an Ethereum `chainId` and `hash` (these are not EEZ rollup IDs).

| Reference | L1 source (`inbound`) | L2 source (`outbound`) |
| --- | --- | --- |
| `l1` | Original user transaction | L1 execution/posting transaction |
| `postBatch` | L1 batch-posting transaction | L1 batch-posting transaction |
| `l2[]` | Committed deliveries | System loader and original user transaction |

One committed top-level mutable L1→L2 call produces one delivery that calls
`executeIncomingCrossChainCall` (load and execute). A multicall can therefore have
several deliveries, including repeated identical calls with distinct transaction
hashes. Nested callbacks add no separate delivery. Static, reverted, or erased
L1 lookups can complete with an empty `l2[]` (`SourceCompleted`).

For L2 sources, identify the original transaction by its known hash; the other
reference must call `loadExecutionTable` on the L2 manager. Its receipt must precede
the source in the same block, without an intervening table replacement. Adjacency
is not required. The current verifier supports one loader per L2 source and the
current composer layout where L2-origin `l1` and `postBatch` refer to the same
transaction; a different layout fails explicitly.

`ownership.canonical` is an **L1 inclusion reference in both directions**.
`complete: true` establishes link completeness only. The runner checks receipts,
canonical headers, calldata, tables, event multiplicity and scenario assertions,
and cross-checks posting hashes with settlement correlation.

Network verification defaults to `E2E_TX_LINKS=required`. Explicit `auto` permits
a logged compatibility fallback only for `-32601` or a legacy record without
`transactions`; `off` uses the previous discovery path. Null/incomplete supported
records wait under the verification deadline. Wrong complete links fail rather
than being replaced with a different transaction found by scanning.
The verifier caches chain IDs only after both chains' front/read endpoints pass
identity checks. If initialization fails, the next verification attempt checks
both chains again before validating transaction links.

## eez_getSettlementByL2Block

**Params:** `[{"blockHash":"<L2 source receipt's block hash>"}]`

Returns a settlement record. Relevant fields include `matchedL2Block`,
`l1TransactionHash`, `l1BlockHash`, `l1BlockNumber`, `l2Blocks`, `l2Range`,
`canonicalL2` and `l2Finalized`. Check that `matchedL2Block.hash` matches the
requested block and `canonicalL2` is true before using it.

## eez_getSettledL2RangesByL1Block

**Params:** `[{"blockHash":"<L1 source receipt's block hash>"}]`

Returns an array of settlement records for the L1 block, including L1 posting
transaction hashes and L2 block/range information. Check each `l1BlockHash`
against the request and retain canonical records. Keep all matching settlements;
a run can span more than one batch.

Both settlement methods take a **block hash, not a transaction hash**. Obtain it
from the source receipt. Correlation finds candidates; verify their actual calls,
tables and results before claiming the cross-chain flow succeeded.
See [how the runner verifies settlement](RUNNER_GUIDE.md#settlement-correlation-rpc-eez_getsettlementbyl2block--co).

## Errors and incomplete results

| Response | Meaning |
| --- | --- |
| `-32601` | Method unsupported |
| `-32001` | Settlement indexing is catching up |
| `-32004` / `unsupported_direction` | Fee quoting is unsupported for this direction on this deployment |
| `quote_busy` | Another quote is running; retry briefly |
| `quote_unavailable` | No quote available; inspect the reason, such as pending settlement reconciliation |
| `l1_tip_underfunded` / `l2_tip_underfunded` | The signed priority payment does not cover the cross-chain fee |

A null result or empty settlement list does not establish a successful flow or
a rejection. Recheck status and receipts; do not infer completion from absence.

Implementation references: [discovery](lib/composer-info.sh),
[fees](lib/network-fees.sh), [status](run/network/staged.sh),
[settlement](lib/network-evidence.sh). For runner examples, see
[COMMANDS.md](COMMANDS.md) and the [full runner guide](RUNNER_GUIDE.md).

## Submission timing records

Each staged trigger send adds a `<job>:send-<index>` row to `jobs/<job>/timings.csv`
(collected into `job-timings.csv`). It covers lock wait, quote retries, signing and
submission, and ends at the send acknowledgement, not mining or settlement.
