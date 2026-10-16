import { ethers } from 'ethers';
import { ChainReader, makeRpc, validateSettlement } from './rpc.mjs';
import { protocol, hex, lower, number, parseEvent, same } from './protocol.mjs';
import { buildGraph } from './logical.mjs';
import { lookupTransactionLinks, validateTransactionLinks, recheckTransactionLinks, isolateL2Execution } from './transaction-links.mjs';

async function concurrent(items, fn, limit = 8) {
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) await fn(items[next++]);
  }));
}

export async function decodeCrossChainTrace(inputConfig, txHash) {
  if (!/^0x[0-9a-f]{64}$/i.test(txHash)) throw new Error('Invalid transaction hash');
  const config = { ...inputConfig }, rpc = makeRpc(config);
  for (const chain of ['l1','l2']) {
    const from = config[`${chain}From`], to = config[`${chain}To`];
    if ((from == null) !== (to == null)) throw new Error(`Provide both ${chain}From and ${chain}To`);
    if (from != null && (number(from) > number(to))) throw new Error(`Inverted ${chain} search range`);
    if (from != null) { config[`${chain}From`] = number(from); config[`${chain}To`] = number(to); }
  }
  if (config.scanConcurrency != null && (!Number.isSafeInteger(config.scanConcurrency) || config.scanConcurrency < 1)) throw new Error('scanConcurrency must be a positive integer');
  const unresolved = [], diagnostics = [];
  function report(code, message, details = {}) {
    const item = { code, message, ...details };
    diagnostics.push(item); config.onDiagnostic?.(item);
    return item;
  }
  function unresolvedReason(code, message, details = {}) { const item = report(code, message, details); unresolved.push(item); }
  const readers = {
    L1: new ChainReader('L1', config.l1Rpc, config.l1TraceRpc, rpc, report),
    L2: new ChainReader('L2', config.l2Rpc, config.l2TraceRpc, rpc, report),
  };
  for (const r of Object.values(readers)) if (!r.url) throw new Error(`Missing ${r.chain} RPC URL`);
  const chainIds = {};
  await Promise.all(Object.values(readers).map(async r => {
    chainIds[r.chain] = BigInt(await r.send('eth_chainId')).toString();
    if (r.traceUrl !== r.url && BigInt(await r.send('eth_chainId', [], true)).toString() !== chainIds[r.chain]) throw new Error(`${r.chain} trace RPC has the wrong chain ID`);
  }));
  let composer = null;
  if (config.l1Front) {
    try { composer = await rpc(config.l1Front, 'eez_composerInfo', []); }
    catch (e) { report('composer-unavailable', e.message); }
    if (composer) {
      for (const [chain, field] of [['L1', 'eezL1'], ['L2', 'eezL2']]) {
        const expected = composer.supportedNetworks?.[field];
        if (typeof expected !== 'number' || !Number.isSafeInteger(expected) || expected <= 0) throw new Error(`Invalid composer supportedNetworks.${field}`);
        if (BigInt(expected).toString() !== chainIds[chain]) throw new Error(`${chain} RPC chain ID disagrees with composer`);
      }
      for (const [chain, key, field] of [['L1', 'rollups', 'eezRegistryAddress'], ['L2', 'managerL2', 'eezL2Address']]) {
        const value = composer.eezContracts?.[field];
        if (!ethers.isAddress(value) || same(value, ethers.ZeroAddress)) throw new Error(`Invalid composer eezContracts.${field}`);
        const explicit = config.explicitManagers?.[chain] ?? !!inputConfig[key];
        if (!explicit) {
          if (config[key] && !same(config[key], value)) report('stale-manager-replaced', `${chain} environment manager replaced by composer discovery`);
          config[key] = value;
        }
      }
    }
  }
  for (const chain of ['L1', 'L2']) {
    const expected = config[`expected${chain}ChainId`];
    if (expected != null && BigInt(expected).toString() !== chainIds[chain]) throw new Error(`${chain} configured chain ID mismatch`);
  }
  const managers = { L1: config.rollups, L2: config.managerL2 };
  for (const [chain, address] of Object.entries(managers)) if (!ethers.isAddress(address) || same(address, ethers.ZeroAddress)) throw new Error(`${chain} manager unavailable; configure L1_FRONT for composer discovery or an explicit historical manager`);
  const rollupIds = { L1: '0', L2: null };
  try {
    const data = protocol.L2.encodeFunctionData('ROLLUP_ID');
    rollupIds.L2 = protocol.L2.decodeFunctionResult('ROLLUP_ID', await readers.L2.send('eth_call', [{ to: managers.L2, data }, 'latest']))[0].toString();
  } catch (e) { report('rollup-id-unavailable', `Cannot read L2 ROLLUP_ID: ${e.message}`); }

  const records = new Map();
  function touchesManager(chain, node, context = null) {
    if (!node) return false;
    const next = node.type === 'DELEGATECALL' || node.type === 'CALLCODE' ? context : node.to;
    return same(next, managers[chain]) || same(node.from, managers[chain]) ||
      (node.calls || []).some(c => touchesManager(chain, c, next));
  }
  async function add(chain, hash, hint = null, required = false) {
    const key = `${chain}:${lower(hash)}`;
    if (records.has(key)) return records.get(key);
    let rec;
    try { rec = await readers[chain].recover(hash, hint); }
    catch (e) { unresolvedReason('transaction-recovery-failed', e.message, { chain, transactionHash: hash }); return null; }
    if (!rec) {
      if (required) unresolvedReason('transaction-unavailable', `Transaction and receipt unavailable on ${chain}`, { chain, transactionHash: hash });
      return null;
    }
    rec.id = key;
    rec.traceResult = await readers[chain].trace(rec);
    // A wrapper may enter the manager without a committed event (STATICCALL or
    // caught revert). Inspect every trace in the bounded scope, not just tx.to.
    const eventEvidence = (rec.receipt?.logs || []).some(l => same(l.address, managers[chain]) && !l.removed && parseEvent(chain, l));
    if (!required && !same(rec.transaction?.to, managers[chain]) && !eventEvidence && !touchesManager(chain, rec.traceResult.trace)) return null;
    records.set(key, rec);
    if (!rec.traceResult.trace) unresolvedReason(rec.traceResult.reason, `Call trace unavailable for ${chain} ${hash}`, { chain, transactionHash: hash, attempts: rec.traceResult.failures });
    if (!rec.receipt) unresolvedReason('receipt-unavailable', `Receipt unavailable for ${chain} ${hash}`, { chain, transactionHash: hash });
    return rec;
  }
  const detections = await Promise.allSettled(Object.keys(readers).map(async chain => ({ chain, record: await readers[chain].recover(txHash) })));
  let detected = detections.filter(r => r.status === 'fulfilled' && r.value.record).map(r => r.value);
  // If both hash indexes are unavailable there is no timestamp to search by.
  // User-specified ranges permit a finite block-read recovery on either chain.
  if (!detected.length) for (const chain of ['L1', 'L2']) {
    const from = config[`${chain.toLowerCase()}From`], to = config[`${chain.toLowerCase()}To`];
    if (from == null || to == null) continue;
    for (let n = from; n <= to; n++) {
      const block = await readers[chain].block(n);
      if (block?.transactions.some(tx => same(typeof tx === 'string' ? tx : tx.hash, txHash))) {
        detected.push({ chain, record: await readers[chain].recover(txHash, n) }); break;
      }
    }
  }
  if (detected.length > 1) throw new Error('Transaction exists on both chains; the hash is ambiguous');
  if (!detected.length) throw new Error('Transaction not found on either chain; provide explicit search ranges if both hash indexes are unavailable');
  const origin = await add(detected[0].chain, txHash, detected[0].record.blockNumber, true);
  if (!origin) throw new Error('Cannot recover the originating transaction');
  if (origin.blockNumber == null) throw new Error('Transaction is pending; no settlement block is available');
  // The rollup ID is read at the transaction context as well when starting on L2.
  if (origin.chain === 'L2') try {
    rollupIds.L2 = protocol.L2.decodeFunctionResult('ROLLUP_ID', await readers.L2.send('eth_call', [{ to: managers.L2, data: protocol.L2.encodeFunctionData('ROLLUP_ID') }, hex(origin.blockNumber)]))[0].toString();
  } catch { /* Latest immutable ROLLUP_ID remains useful on an unpruned deployment. */ }

  let linkDiscovery = { state: 'fallback' }, linkedRecords = null;
  const transactionLinks = [];
  try {
    linkDiscovery = await lookupTransactionLinks({ config, rpc, origin, chainIds });
    if (linkDiscovery.state === 'complete') {
      linkedRecords = await validateTransactionLinks(linkDiscovery, { readers, managers, rollupIds, origin });
      for (const record of linkedRecords.values()) await add(record.chain, record.hash, record.blockNumber, true);
      linkDiscovery.l1Execution = await isolateL2Execution(linkDiscovery, { rpc, readers, managers, rollupIds, chainIds, origin, records: linkedRecords });
      await recheckTransactionLinks(linkDiscovery, { rpc, url: linkDiscovery.endpoint, origin, chainIds, readers, records: linkedRecords });
      const { endpoint, ...evidence } = linkDiscovery;
      transactionLinks.push(evidence);
      report('transaction-links-verified', `Following ${linkedRecords.size} exact linked transactions`);
    } else if (linkDiscovery.state === 'pending') {
      unresolvedReason('transaction-links-pending', 'Cross-chain transaction links are not complete; retry after composer processing');
    } else report('transaction-links-fallback', linkDiscovery.reason);
  } catch (e) {
    linkDiscovery = { ...linkDiscovery, state: 'invalid' };
    unresolvedReason('invalid-transaction-links', e.message);
  }
  const legacyDiscovery = linkDiscovery.state === 'fallback';
  let correlation = null;
  if (legacyDiscovery && !config.noCorrelation) for (const [name, url] of [['override', config.correlationRpc], ['L2_FRONT', config.l2Front], ['L1_FRONT', config.l1Front], ['L2_RPC', config.l2Rpc]].filter(([,url], i, a) => url && a.findIndex(([,u]) => u === url) === i)) {
    try {
      const [l2, l1] = await Promise.all([
        rpc(url, 'eez_getSettlementByL2Block', ['0x1']), rpc(url, 'eez_getSettledL2RangesByL1Block', ['0x1']),
      ]);
      if ((l2 !== null && typeof l2 !== 'object') || !Array.isArray(l1)) throw new Error('Unrecognized settlement capability response');
      correlation = { name, url }; break;
    } catch (e) { report('correlation-candidate-unavailable', `${name}: ${e.message}`); }
  }
  const settlements = [];
  let correlationAnswered = false;
  if (correlation) {
    // A supported endpoint failing or still indexing must not silently turn into
    // an unrelated timestamp scan. Pin the lookup to the observed inclusion, as E2E does.
    correlationAnswered = true;
    const method = origin.chain === 'L2' ? 'eez_getSettlementByL2Block' : 'eez_getSettledL2RangesByL1Block';
    try {
      const raw = await rpc(correlation.url, method, [{ blockHash: origin.blockHash }]);
      if (origin.chain === 'L1' && !Array.isArray(raw)) throw new Error('Unrecognized settlement range response');
      const items = origin.chain === 'L2' ? (raw == null ? [] : [raw]) : raw;
      correlationAnswered = true;
      for (const item of items) try {
        report('settlement-validation', `Validating ${item.l2Blocks?.length ?? 'range boundary'} L2 block hashes in batches`);
        const s = await validateSettlement(item, readers, { [origin.chain]: origin.blockNumber, blockHash: origin.blockHash });
        if (!settlements.some(x => x.id === s.id)) settlements.push(s);
      } catch (e) { unresolvedReason('invalid-settlement', e.message, { settlement: item }); }
      if (!items.length) unresolvedReason('settlement-not-found', 'No settled range is currently recorded for this block');
    } catch (e) { unresolvedReason('correlation-lookup-failed', e.message); }
  }
  const search = [], scanned = new Set();
  // Blocks can hold hundreds of unrelated transactions. Unless `thorough`, only those sent
  // to the manager or carrying a manager event are traced (one receipts call per block);
  // a wrapper that reaches the manager without any event is then missed.
  // Event sources, cheapest first: the block's receipts, then the manager's logs for the
  // block. When neither is available only transactions sent to the manager are kept.
  async function eventCandidates(chain, block, rangeLogs = null) {
    const managerEvent = l => !l.removed && same(l.address, managers[chain]) && parseEvent(chain, l);
    let withEvent = null, source = 'receipts';
    if (!block.transactions.length) return { hashes: [], source: 'empty block' };
    if (rangeLogs !== null) {
      if (rangeLogs.some(l => !same(l.blockHash, block.hash))) throw new Error(`${chain}: range logs disagree with canonical block ${number(block.number)}`);
      withEvent = new Set(rangeLogs.filter(managerEvent).map(l => lower(l.transactionHash)));
      source = 'range logs';
    } else {
      const receipts = await readers[chain].receipts(block);
      if (receipts.length) withEvent = new Set(receipts.filter(r => (r.logs || []).some(managerEvent)).map(r => lower(r.transactionHash)));
    }
    if (!withEvent) {
      // Some RPCs reject the blockHash filter; a one-block range works everywhere.
      for (const filter of [{ blockHash: block.hash }, { fromBlock: hex(number(block.number)), toBlock: hex(number(block.number)) }]) {
        try {
          const logs = await readers[chain].send('eth_getLogs', [{ address: managers[chain], ...filter }]);
          withEvent = new Set(logs.filter(managerEvent).map(l => lower(l.transactionHash))); source = 'logs';
          break;
        } catch { /* Try the next filter form. */ }
      }
      if (!withEvent) { withEvent = new Set(); source = 'manager calls only'; }
    }
    const hashes = block.transactions.map(tx => typeof tx === 'string' ? { hash: tx } : tx)
      .filter(tx => withEvent.has(lower(tx.hash)) || same(tx.to, managers[chain])).map(tx => tx.hash);
    return { hashes, source };
  }
  async function scanBlock(chain, n, rangeLogs = null) {
    const key = `${chain}:${n}`;
    if (scanned.has(key)) return;
    scanned.add(key);
    try {
      const block = await readers[chain].block(n);
      if (!block) { unresolvedReason('block-unavailable', `${chain} block ${n} unavailable`, { chain, blockNumber: n }); return; }
      const all = block.transactions.map(tx => typeof tx === 'string' ? tx : tx.hash);
      const picked = config.thorough ? null : await eventCandidates(chain, block, rangeLogs);
      // Only blocks where something was skipped are worth a line.
      if (picked && picked.hashes.length < all.length) report('block-prefiltered', `${chain} block ${n}: tracing ${picked.hashes.length} of ${all.length} transactions (EEZ calls/events via ${picked.source}; --thorough traces all)`, { chain, blockNumber: n, traced: picked.hashes.length, total: all.length, source: picked.source });
      await concurrent(picked?.hashes ?? all, hash => add(chain, hash, n), 4);
    } catch (e) { unresolvedReason('block-scan-failed', e.message, { chain, blockNumber: n }); }
  }
  async function scanRange(chain, from, to, source) {
    search.push({ chain, from, to, chunkSize: 500, source });
    for (let start = from; start <= to; start += 500) {
      const end = Math.min(start + 499, to);
      report('search-progress', `Inspecting ${chain} blocks ${start}–${end}`, { chain, from: start, to: end });
      const numbers = Array.from({ length: end - start + 1 }, (_, i) => start + i);
      await readers[chain].prefetchBlocks(numbers);
      let logsByBlock = null;
      // Events discover wrapper-mediated deliveries even when trace state is gone.
      try {
        const logs = await readers[chain].send('eth_getLogs', [{ address: managers[chain], fromBlock: hex(start), toBlock: hex(end) }]);
        if (!Array.isArray(logs)) throw new Error('Invalid range logs response');
        const relevant = logs.filter(l => !l.removed && same(l.address, managers[chain]) && parseEvent(chain, l));
        const grouped = new Map();
        for (const log of relevant) {
          const n = number(log.blockNumber);
          if (n < start || n > end) throw new Error('Range log outside requested blocks');
          if (!grouped.has(n)) grouped.set(n, []);
          grouped.get(n).push(log);
        }
        logsByBlock = grouped;
      } catch (e) { report('event-search-unavailable', e.message, { chain, from: start, to: end }); }
      // Reuse range events instead of fetching every block's receipts again. Full
      // block transactions still find direct manager calls with no committed event.
      await concurrent(numbers, n => scanBlock(chain, n, logsByBlock === null ? null : logsByBlock.get(n) || []), config.scanConcurrency ?? 4);
    }
  }
  // Queued entries may be consumed by another transaction in the posting block.
  // A complete local L2 trace cannot have a remote EEZ execution without touching
  // its manager. Correlation already names its settlement; do not scan other jobs
  // in that batch. Explicit ranges and --thorough still request broader discovery.
  const localL2 = !config.thorough && origin.chain === 'L2' && !!origin.traceResult.trace &&
    !touchesManager('L2', origin.traceResult.trace) && settlements.length > 0;
  if (legacyDiscovery && !localL2) await scanBlock(origin.chain, origin.blockNumber);
  else if (localL2) report('local-transaction-settlement', 'No EEZ calls in the L2 trace; tracing its exact L1 settlement without scanning other transactions');
  for (const s of settlements) {
    await add('L1', s.l1TransactionHash, s.l1BlockNumber, true);
    if (localL2) continue;
    await scanBlock('L1', s.l1BlockNumber);
    await scanBlock('L2', s.lastL2Block); // E2E delivery convention: inspect last first.
    await scanRange('L2', s.firstL2Block, s.lastL2Block, 'settlement');
  }
  if (legacyDiscovery && !settlements.length && !correlationAnswered) {
    const other = origin.chain === 'L1' ? 'L2' : 'L1';
    let from = config[`${other.toLowerCase()}From`], to = config[`${other.toLowerCase()}To`];
    if (from == null || to == null) {
      const originBlock = await readers[origin.chain].block(origin.blockNumber);
      const nearest = await readers[other].nearest(number(originBlock.timestamp));
      from = Math.max(0, nearest.block - 2000); to = Math.min(nearest.head, nearest.block + 2000);
    }
    await scanRange(other, from, to, config[`${other.toLowerCase()}From`] == null ? 'timestamp-fallback' : 'explicit');
    unresolvedReason('bounded-search-exhausted', `Completed bounded ${other} search ${from}–${to}; no canonical settlement mapping is available`, { chain: other, from, to });
  }
  // Explicit ranges extend discovery even when correlation is available/null.
  for (const chain of ['L1', 'L2']) {
    const from = config[`${chain.toLowerCase()}From`], to = config[`${chain.toLowerCase()}To`];
    if (legacyDiscovery && from != null && to != null && !search.some(s => s.chain === chain && s.from <= from && s.to >= to)) await scanRange(chain, from, to, 'explicit');
  }
  const transactions = [...records.values()].sort((a,b) => a.chain.localeCompare(b.chain) || a.blockNumber - b.blockNumber || a.transactionIndex - b.transactionIndex);
  const graph = await buildGraph({ config: { ...config, chainIds }, transactions, managers, readers, rollupIds, settlements, transactionLinks, matchingDisabled: !legacyDiscovery && !transactionLinks.length, unresolvedReason });
  return {
    schemaVersion: '1.0.0', txHash: lower(txHash), origin: { chain: origin.chain, transactionId: origin.id },
    metadata: { chainIds, rollupIds, managers, composer, correlation: correlation?.name ?? null, transactionLinks: { state: linkDiscovery.state, reason: linkDiscovery.reason ?? null, observation: linkDiscovery.raw ?? null }, search },
    transactions: transactions.map(({ traceResult, ...r }) => ({ ...r, trace: { available: !!traceResult.trace, provenance: traceResult.provenance ?? null, reason: traceResult.reason ?? null, failures: traceResult.failures ?? [] } })),
    originalTraces: transactions.map(r => ({ chain: r.chain, transactionHash: r.hash, trace: r.traceResult.trace })),
    settlements, transactionLinks, ...graph, unresolved, diagnostics,
  };
}
