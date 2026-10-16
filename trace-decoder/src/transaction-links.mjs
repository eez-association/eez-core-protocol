import { abiValue, hex, lower, parseCall, parseEvent, protocol, same } from './protocol.mjs';

import { validateSettlement } from './rpc.mjs';

const METHOD = 'eez_getCrossChainTransaction';
function require(ok, message) { if (!ok) throw new Error(message); }
function quantity(value) {
  require(typeof value === 'number' || typeof value === 'string' && /^0x[0-9a-f]+$/i.test(value), 'Invalid link quantity');
  const n = Number(value);
  require(Number.isSafeInteger(n) && n >= 0, 'Inexact link quantity');
  return n;
}
function hash(value) {
  require(typeof value === 'string' && /^0x[0-9a-f]{64}$/i.test(value), 'Invalid transaction link hash');
  return lower(value);
}

// Match the E2E reference contract: chain IDs are Ethereum IDs, not rollup IDs.
export function normalizeTransactionLinks(raw, origin, chainIds) {
  if (raw == null) return { state: 'pending', raw };
  require(typeof raw === 'object' && !Array.isArray(raw), 'Invalid cross-chain transaction record');
  require(same(raw.hash, origin.hash) && raw.direction === (origin.chain === 'L1' ? 'inbound' : 'outbound'), 'Cross-chain source identity/direction mismatch');
  require(raw.ownership?.rejection == null, 'Cross-chain transaction was rejected');
  if (!Object.hasOwn(raw, 'transactions')) return { state: 'legacy', raw };
  const t = raw.transactions;
  require(t && typeof t === 'object' && typeof t.complete === 'boolean', 'Invalid transaction links completeness');
  if (!t.complete) return { state: 'pending', raw };
  function reference(value, chain, role) {
    require(value && quantity(value.chainId) === quantity(hex(chainIds[chain])), 'Transaction link chain ID mismatch');
    return { chain, chainId: chainIds[chain], hash: hash(value.hash), role };
  }
  const l1 = reference(t.l1, 'L1', origin.chain === 'L1' ? 'source' : 'l1-execution');
  const post = reference(t.postBatch, 'L1', 'l1-post-batch');
  require(Array.isArray(t.l2), 'Missing L2 transaction links');
  const l2 = t.l2.map(r => reference(r, 'L2', origin.chain === 'L1' ? 'l2-delivery' : same(r?.hash, origin.hash) ? 'source' : 'l2-table-load'));
  require(new Set(l2.map(r => r.hash)).size === l2.length, 'Duplicate L2 transaction links');
  require(origin.chain === 'L1' ? same(l1.hash, origin.hash) : same(l1.hash, post.hash) && l2.some(r => r.role === 'source'), 'Missing source or unsupported L1 execution layout');
  if (origin.chain === 'L2') require(l2.filter(r => r.role === 'l2-table-load').length === 1, 'Expected one L2 table loader');
  return { state: 'complete', id: `transaction-links:${origin.chain}:${lower(origin.hash)}`,
    sourceChain: origin.chain, sourceHash: lower(origin.hash), references: [l1, post, ...l2], raw };
}

function identity(link) {
  const raw = link.raw, o = raw.ownership, canonical = o?.canonical;
  return JSON.stringify({ sourceHash: link.sourceHash, direction: raw.direction,
    sender: lower(raw.sender), nonce: raw.nonce == null ? null : quantity(raw.nonce),
    basis: raw.transactions.basis, attemptGeneration: raw.transactions.attemptGeneration == null ? null : quantity(raw.transactions.attemptGeneration),
    ownership: { state: o?.state, reason: o?.reason, replacementHash: lower(o?.replacementHash), rejection: o?.rejection,
      canonical: canonical == null ? null : { hash: hash(canonical.hash), number: canonical.number == null ? null : quantity(canonical.number) } },
    references: link.references.map(r => `${r.chain}:${r.hash}:${r.role}`).sort() });
}
function events(record, manager, name) {
  return (record.receipt.logs || []).filter(l => !l.removed && same(l.address, manager))
    .sort((a, b) => quantity(a.logIndex) - quantity(b.logIndex))
    .map(l => parseEvent(record.chain, l)).filter(e => e?.name === name);
}
function checkInclusion(record, ref, successful = true) {
  const tx = record?.transaction, receipt = record?.receipt;
  require(tx && receipt && record.blockHash, `Linked transaction unavailable: ${ref.chain} ${ref.hash}`);
  require(same(tx.hash, ref.hash) && same(receipt.transactionHash, ref.hash) && [0, 1].includes(quantity(receipt.status)) && (!successful || quantity(receipt.status) === 1), 'Linked transaction/receipt identity or success mismatch');
  require(same(tx.blockHash, record.blockHash) && same(receipt.blockHash, record.blockHash), 'Linked block hash mismatch');
  for (const key of ['blockNumber', 'transactionIndex']) {
    require(quantity(tx[key]) === record[key] && quantity(receipt[key]) === record[key], 'Linked transaction/receipt coordinates mismatch');
  }
  require(tx.chainId == null || quantity(tx.chainId) === quantity(hex(ref.chainId)), 'Linked signed chain ID mismatch');
  for (const log of receipt.logs || []) {
    require(!log.removed && same(log.blockHash, record.blockHash) && same(log.transactionHash, ref.hash) && quantity(log.blockNumber) === record.blockNumber, 'Linked receipt log inclusion mismatch');
  }
}

// Links select transactions; calldata, receipts and call trees still prove what ran.
export async function validateTransactionLinks(link, { readers, managers, rollupIds, origin }) {
  const records = new Map();
  for (const ref of link.references) {
    const key = `${ref.chain}:${ref.hash}`;
    if (!records.has(key)) records.set(key, await readers[ref.chain].recover(ref.hash));
    checkInclusion(records.get(key), ref);
  }
  const source = records.get(`${origin.chain}:${lower(origin.hash)}`), raw = link.raw;
  require(raw.sender == null || same(raw.sender, source.transaction.from), 'Linked source sender mismatch');
  require(raw.nonce == null || quantity(raw.nonce) === quantity(source.transaction.nonce), 'Linked source nonce mismatch');
  const l1 = records.get(`L1:${link.references[0].hash}`);
  if (raw.ownership?.canonical != null) {
    require(same(raw.ownership.canonical.hash, l1.blockHash), 'Ownership L1 inclusion mismatch');
    require(raw.ownership.canonical.number == null || quantity(raw.ownership.canonical.number) === l1.blockNumber, 'Ownership L1 block number mismatch');
  }
  const postRef = link.references.find(r => r.role === 'l1-post-batch');
  const post = records.get(`L1:${postRef.hash}`);
  require(post.blockNumber === l1.blockNumber && post.transactionIndex <= l1.transactionIndex, 'Batch post must precede L1 execution in the same block');
  let posted = same(post.transaction.to, managers.L1) && parseCall(protocol.L1, post.transaction.input)?.name === 'postAndVerifyBatch';
  if (!posted) {
    const trace = await readers.L1.trace(post);
    function hasPost(node, context = null) {
      if (!node || node.error) return false;
      const address = ['DELEGATECALL', 'CALLCODE'].includes(node.type) ? context : node.to;
      return same(address, managers.L1) && parseCall(protocol.L1, node.input)?.name === 'postAndVerifyBatch' ||
        (node.calls || []).some(c => hasPost(c, address));
    }
    posted = hasPost(trace.trace);
  }
  require(posted, 'Linked posting transaction does not post an EEZ batch');
  const tables = link.references.filter(r => r.role === 'l2-table-load' || r.role === 'l2-delivery')
    .map(r => records.get(`L2:${r.hash}`)).sort((a, b) => a.blockNumber - b.blockNumber || a.transactionIndex - b.transactionIndex);
  for (const table of tables) {
    require(same(table.transaction.to, managers.L2) && same(table.receipt.to, managers.L2), 'Linked L2 table targets another manager');
    require(parseCall(protocol.L2, table.transaction.input)?.name === (origin.chain === 'L1' ? 'executeIncomingCrossChainCall' : 'loadExecutionTable'), 'Linked L2 table has the wrong function');
  }
  if (origin.chain === 'L1') {
    require(rollupIds.L2 != null, 'L2 rollup ID unavailable for delivery verification');
    const consumed = events(source, managers.L1, 'ExecutionConsumed').filter(e => e.args.rollupId === rollupIds.L2).map(e => lower(e.args.crossChainCallHash));
    const incoming = tables.map(t => {
      const calls = events(t, managers.L2, 'IncomingCrossChainCallExecuted');
      require(calls.length === 1, 'Each linked delivery must emit one incoming call');
      return lower(calls[0].args.crossChainCallHash);
    });
    require(JSON.stringify(consumed) === JSON.stringify(incoming), 'Linked deliveries disagree with source event order/multiplicity');
  } else {
    const loader = tables[0];
    require(same(loader.blockHash, source.blockHash) && loader.transactionIndex < source.transactionIndex, 'L2 loader must precede source in the same block');
    require(events(loader, managers.L2, 'ExecutionTableLoaded').length === 1, 'Expected one loader event');
    // Check all transactions between loader and source, including the source itself.
    // This also catches wrapper-mediated replacements without assuming adjacency.
    const block = await readers.L2.block(source.blockNumber);
    for (let i = loader.transactionIndex + 1; i <= source.transactionIndex; i++) {
      const tx = block.transactions[i], txHash = typeof tx === 'string' ? tx : tx.hash;
      const rec = await readers.L2.recover(txHash, source.blockNumber);
      checkInclusion(rec, { chain: 'L2', chainId: link.references.find(r => r.chain === 'L2').chainId, hash: lower(txHash) }, false);
      require(events(rec, managers.L2, 'ExecutionTableLoaded').length === 0, 'Intervening L2 table replacement');
    }
  }
  link.checks = ['reference-shape', 'chain-identity', 'successful-receipts', 'canonical-inclusion', 'source-association', 'manager-calldata', 'event-order'];
  return records;
}

export async function recheckTransactionLinks(link, { rpc, url, origin, chainIds, readers, records }) {
  const fresh = normalizeTransactionLinks(await rpc(url, METHOD, [origin.hash]), origin, chainIds);
  require(fresh.state === 'complete' && identity(fresh) === identity(link), 'Transaction links changed during decoding');
  const blocks = new Map();
  for (const record of records.values()) {
    const key = `${record.chain}:${record.blockNumber}`;
    if (!blocks.has(key)) blocks.set(key, await readers[record.chain].send('eth_getBlockByNumber', [hex(record.blockNumber), true]));
    const block = blocks.get(key), tx = block?.transactions?.[record.transactionIndex];
    require(same(block?.hash, record.blockHash) && same(typeof tx === 'string' ? tx : tx?.hash, record.hash), 'Linked transaction changed canonical inclusion during decoding');
  }
  link.checks.push('execution-identity-recheck', 'canonical-recheck');
}

export async function lookupTransactionLinks({ config, rpc, origin, chainIds }) {
  const mode = config.txLinks ?? 'auto';
  require(['auto', 'required', 'off'].includes(mode), 'txLinks must be auto, required, or off');
  if (mode === 'off' || config.noCorrelation) return { state: 'fallback', reason: 'disabled' };
  const manager = origin.chain === 'L1' ? config.rollups : config.managerL2;
  function managerCall(node, names = null, context = null) {
    if (!node) return false;
    const address = ['DELEGATECALL', 'CALLCODE'].includes(node.type) ? context : node.to;
    return same(address, manager) && (!names || names.includes(parseCall(protocol[origin.chain], node.input)?.name)) ||
      (node.calls || []).some(c => managerCall(c, names, address));
  }
  if (mode === 'auto' && origin.traceResult?.trace && !managerCall(origin.traceResult.trace)) {
    return { state: 'fallback', reason: 'local transaction has no EEZ calls' };
  }
  const url = config[origin.chain === 'L1' ? 'l1Front' : 'l2Front'] || config.correlationRpc;
  if (!url) {
    require(mode !== 'required', 'Required transaction links need the source frontend or --correlation-rpc');
    return { state: 'fallback', reason: 'source frontend not configured' };
  }
  require(BigInt(await rpc(url, 'eth_chainId', [])).toString() === chainIds[origin.chain], 'Transaction link frontend has the wrong chain ID');
  let raw;
  try { raw = await rpc(url, METHOD, [origin.hash]); }
  catch (e) {
    if (e.code !== -32601 || mode === 'required') throw e;
    return { state: 'fallback', reason: 'RPC method unsupported' };
  }
  // The method is keyed by source hash. A delivery/loader or a non-source batch
  // may have no source record; retain block correlation for those entry points.
  const fn = same(origin.transaction?.to, manager) ? parseCall(protocol[origin.chain], origin.transaction.input)?.name : null;
  if (raw == null && mode === 'auto' && (['loadExecutionTable', 'executeIncomingCrossChainCall'].includes(fn) || fn === 'postAndVerifyBatch' && origin.traceResult?.trace && !managerCall(origin.traceResult.trace, ['executeCrossChainCall', 'staticCrossChainCall']))) {
    return { state: 'fallback', reason: 'system transaction has no source record' };
  }
  const link = normalizeTransactionLinks(raw, origin, chainIds);
  if (link.state === 'legacy') {
    require(mode !== 'required', 'Required transaction links absent from legacy record');
    return { state: 'fallback', reason: 'legacy record without transactions', raw };
  }
  return { ...link, endpoint: url };
}


// The composer orders L2 source units and their successful immediate L1 hosts.
// Failed self-calls have no canonical L2 counterpart. Empty native-state entries
// are not cross-chain source units. Verify the whole sequence before using ranks.
export async function isolateL2Execution(link, { rpc, readers, managers, rollupIds, chainIds, origin, records }) {
  if (origin.chain !== 'L2') return null;
  const postHash = link.references.find(r => r.role === 'l1-post-batch').hash;
  const post = records.get(`L1:${postHash}`), trace = (await readers.L1.trace(post)).trace;
  if (!trace) return null;
  const batches = [];
  function walk(node, path = '0', context = null, batch = null, reverted = false, parent = null) {
    const delegate = ['DELEGATECALL', 'CALLCODE'].includes(node.type);
    const address = delegate ? context : node.to, failed = reverted || !!node.error;
    const parsed = same(address, managers.L1) ? parseCall(protocol.L1, node.input) : null;
    if (parsed?.name === 'postAndVerifyBatch' && !(delegate && parent?.input === node.input)) {
      batch = { value: abiValue(parsed.fragment.inputs[0], parsed.args[0]), attempts: [], failed };
      batches.push(batch);
    }
    if (batch && parsed?.name === '_attemptExecuteImmediateL2Txs' && !delegate) {
      batch.attempts.push({ entry: abiValue(parsed.fragment.inputs[0], parsed.args[0]), failed,
        frameId: `L1:${postHash}:${path}` });
    }
    for (const [i, child] of (node.calls || []).entries()) walk(child, `${path}.${i}`, address, batch, failed, node);
  }
  walk(trace);
  const withAttempts = batches.filter(b => b.attempts.length);
  // Older/different execution layouts retain identity-based matching.
  if (!withAttempts.length) return null;
  require(withAttempts.length === 1 && !withAttempts[0].failed, 'Cannot order L2 sources across multiple batch executions');
  const b = withAttempts[0], leading = [];
  for (const entry of b.value.entries.slice(0, Number(b.value.immediateEntryCount))) {
    if (!/^0x0{64}$/i.test(entry.proxyEntryHash)) break;
    leading.push(entry);
  }
  require(leading.length === b.attempts.length, 'Incomplete immediate L2 execution trace');
  b.attempts.forEach((a, i) => {
    require(JSON.stringify(a.entry) === JSON.stringify(leading[i]), 'Immediate attempt calldata disagrees with batch entry order');
    a.entryIndex = i;
  });
  const executed = b.attempts.filter(a => !a.failed && a.entry.destinationRollupId === rollupIds.L2 && a.entry.l2ToL1Calls.length > 0);
  if (!executed.length) return null;
  if (executed.length === 1) return { frameId: executed[0].frameId, entryIndex: executed[0].entryIndex, basis: 'only successful cross-chain L2Tx entry' };

  const rawSettlement = await rpc(link.endpoint, 'eez_getSettlementByL2Block', [{ blockHash: origin.blockHash }]);
  const settlement = await validateSettlement(rawSettlement, readers, { L2: origin.blockNumber, blockHash: origin.blockHash });
  require(same(settlement.l1TransactionHash, postHash), 'L2 source ordering settlement names another batch post');
  const units = [], loaders = new Set(), accounted = new Set(), observed = [];
  const nums = Array.from({ length: settlement.lastL2Block - settlement.firstL2Block + 1 }, (_, i) => settlement.firstL2Block + i);
  await readers.L2.prefetchBlocks(nums);
  for (const n of nums) {
    const block = await readers.L2.block(n);
    require(block, 'L2 source ordering block unavailable');
    for (const item of block.transactions) {
      const txHash = typeof item === 'string' ? item : item.hash;
      const rec = await readers.L2.recover(txHash, n);
      require(rec?.transaction && rec.receipt, 'L2 source ordering needs every transaction and receipt');
      checkInclusion(rec, { chain: 'L2', chainId: chainIds.L2, hash: lower(txHash) }, false);
      if (quantity(rec.receipt.status) !== 1) continue;
      const fn = same(rec.transaction.to, managers.L2) ? parseCall(protocol.L2, rec.transaction.input)?.name : null;
      if (fn === 'loadExecutionTable') { loaders.add(lower(txHash)); continue; }
      if (fn === 'executeIncomingCrossChainCall') continue;
      const raw = await rpc(link.endpoint, METHOD, [txHash]);
      if (raw == null) continue; // Native L2 transactions do not have source records.
      const candidate = normalizeTransactionLinks(raw, rec, chainIds);
      require(candidate.state === 'complete', 'L2 source ordering includes incomplete source records');
      const evidence = await validateTransactionLinks(candidate, { readers, managers, rollupIds, origin: rec });
      const loader = candidate.references.find(r => r.role === 'l2-table-load').hash;
      require(!accounted.has(loader), 'L2 loader attributed to multiple source units');
      accounted.add(loader);
      observed.push({ candidate, origin: rec, records: evidence });
      if (candidate.references.some(r => r.role === 'l1-post-batch' && same(r.hash, postHash))) units.push({ sourceHash: lower(txHash), loaderHash: loader, blockNumber: rec.blockNumber, transactionIndex: rec.transactionIndex });
    }
  }
  require([...loaders].every(h => accounted.has(h)) && [...accounted].every(h => loaders.has(h)), 'Incomplete L2 loader/source sequence');
  require(units.length === executed.length, 'Successful L1 entry count disagrees with canonical L2 source unit count');
  const index = units.findIndex(u => same(u.sourceHash, origin.hash));
  require(index >= 0, 'Requested transaction absent from ordered L2 source units');
  // Recheck every source, not just the requested one, before trusting its rank.
  for (const item of observed) await recheckTransactionLinks(item.candidate, { rpc, url: link.endpoint, chainIds, readers, origin: item.origin, records: item.records });
  return { frameId: executed[index].frameId, entryIndex: executed[index].entryIndex,
    basis: 'ordered successful L1 entries and canonical L2 source units', sourceIndex: index, units, settlement };
}
