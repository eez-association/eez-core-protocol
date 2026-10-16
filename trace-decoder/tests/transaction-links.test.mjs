import assert from 'node:assert/strict';
import test from 'node:test';
import { decodeCrossChainTrace } from '../src/engine.mjs';
import { buildFlowModel } from '../flow/model.mjs';
import { abiValue, hex, protocol } from '../src/protocol.mjs';
import { scenario, hash, event, address, batch, frame, M, l1Entry } from './fixtures/scenarios.mjs';

function linked(options = {}) {
  const f = scenario(options), direction = options.direction || 'L1';
  for (const chain of ['L1', 'L2']) for (const rec of f.txs[chain].values()) {
    rec.receipt.to = rec.transaction.to;
    rec.transaction.chainId = chain === 'L1' ? '0x64' : '0xc8';
    rec.transaction.nonce = '0x0';
  }
  function receiptEvent(txHash, log) {
    const rec = f.txs.L2.get(txHash), r = rec.receipt;
    r.logs.push({ ...log, transactionHash: txHash, blockNumber: r.blockNumber, blockHash: r.blockHash, logIndex: hex(r.logs.length) });
  }
  if (direction === 'L1') for (const txHash of f.deliveries) {
    const parsed = protocol.L2.parseTransaction({ data: f.txs.L2.get(txHash).transaction.input });
    const c = parsed.args[0][0].incomingCalls[0];
    receiptEvent(txHash, event('L2', 'IncomingCrossChainCallExecuted', [f.key, c.isStatic, c.sourceAddress, c.sourceRollupId, c.targetAddress, c.value, c.gas, c.data]));
  } else {
    const parsed = protocol.L2.parseTransaction({ data: f.txs.L2.get(hash('table-load')).transaction.input });
    receiptEvent(hash('table-load'), event('L2', 'ExecutionTableLoaded', [parsed.args[0], parsed.args[1]]));
  }
  const ref = (chainId, hash) => ({ chainId, hash });
  f.status = { hash: f.trigger, direction: direction === 'L1' ? 'inbound' : 'outbound', lifecycle: 'SourceCompleted',
    sender: f.txs[direction].get(f.trigger).transaction.from, nonce: '0x0',
    ownership: { state: 'Included', canonical: { hash: f.blocks.L1.get(100).hash, number: '0x64' } },
    transactions: { complete: true, basis: 'execution', attemptGeneration: '0x1',
      l1: ref('0x64', direction === 'L1' ? f.trigger : f.posting), postBatch: ref('0x64', f.posting),
      l2: (direction === 'L1' ? f.deliveries : [hash('table-load'), f.trigger]).map(h => ref('0xc8', h)) } };
  const rpc = f.config.rpc;
  f.linkCalls = [];
  f.config.rpc = async (url, method, params) => {
    if (method === 'eez_getCrossChainTransaction') { f.linkCalls.push({ url, params }); return structuredClone(f.status); }
    return rpc(url, method, params);
  };
  return f;
}

for (const direction of ['L1', 'L2']) for (const repeat of [1, 2]) test(`exact ${direction} links preserve ${repeat} occurrences without scanning`, async () => {
  const f = linked({ direction, repeat });
  // Unrelated manager transactions in the same block must never be traced.
  const result = await decodeCrossChainTrace(f.config, f.trigger);
  assert.equal(result.transactionLinks.length, 1, JSON.stringify(result.unresolved));
  assert.equal(result.outgoing.length, repeat);
  assert.ok(result.outgoing.every(o => o.status === 'matched' && o.matchEvidence.includes('verified transaction link scope')));
  assert.equal(new Set(result.outgoing.map(o => o.remoteFrameId)).size, repeat);
  assert.equal(result.metadata.search.length, 0);
  assert.ok(!f.calls.some(c => c.method === 'eth_getLogs' || c.method.startsWith('eez_getSettlement')));
  assert.deepEqual(f.linkCalls, Array(2).fill({ url: direction.toLowerCase() + '-front', params: [f.trigger] }));
  assert.ok(result.transactionLinks[0].checks.includes('canonical-recheck'));
  const model = buildFlowModel(result);
  assert.equal(model.transactions.find(t => t.requested).inFlow, true);
});

const invalid = [
  ['wrong chain', f => { f.status.transactions.l2[0].chainId = '0x1'; }],
  ['wrong direction', f => { f.status.direction = 'outbound'; }],
  ['wrong source', f => { f.status.hash = hash('other'); }],
  ['duplicate delivery', f => { f.status.transactions.l2.push(f.status.transactions.l2[0]); }],
  ['malformed hash', f => { f.status.transactions.l2[0].hash = '0x00'; }],
  ['wrong owner inclusion', f => { f.status.ownership.canonical.hash = hash('reorg'); }],
  ['wrong sender', f => { f.status.sender = address(333); }],
  ['rejection', f => { f.status.ownership.rejection = { error: 'rejected' }; }],
  ['failed receipt', f => { f.txs.L2.get(f.deliveries[0]).receipt.status = '0x0'; }],
  ['missing receipt', f => { f.txs.L2.get(f.deliveries[0]).receipt = null; }],
  ['wrong manager', f => { f.txs.L2.get(f.deliveries[0]).transaction.to = address(444); }],
  ['wrong delivery hash', f => { f.txs.L2.get(f.deliveries[0]).receipt.logs[0].topics[1] = hash('wrong call'); }],
  ['unsafe quantity', f => { f.status.transactions.l2[0].chainId = 9007199254740992; }],
];
for (const [name, change] of invalid) test(`invalid links: ${name} cannot expand into a scan`, async () => {
  const f = linked(); change(f);
  const result = await decodeCrossChainTrace({ ...f.config, l2From: 200, l2To: 200 }, f.trigger);
  assert.equal(result.transactionLinks.length, 0);
  assert.equal(result.metadata.search.length, 0);
  assert.equal(result.edges.filter(e => e.type === 'cross-chain').length, 0);
  assert.ok(result.unresolved.some(u => u.code === 'invalid-transaction-links'));
});

for (const raw of [null, { complete: false }]) test(`supported incomplete links (${JSON.stringify(raw)}) do not fall back`, async () => {
  const f = linked(); if (raw == null) f.status = null; else f.status.transactions = raw;
  const result = await decodeCrossChainTrace(f.config, f.trigger);
  assert.equal(result.transactions.length, 1);
  assert.equal(result.metadata.search.length, 0);
  assert.ok(result.unresolved.some(u => u.code === 'transaction-links-pending'));
});

test('unsupported and legacy records fall back only in auto mode', async () => {
  for (const legacy of [false, true]) {
    const f = legacy ? linked() : scenario();
    if (legacy) delete f.status.transactions;
    assert.equal((await decodeCrossChainTrace(f.config, f.trigger)).outgoing[0].status, 'matched');
    const required = await decodeCrossChainTrace({ ...f.config, txLinks: 'required' }, f.trigger);
    assert.equal(required.metadata.search.length, 0);
    assert.ok(required.unresolved.some(u => u.code === 'invalid-transaction-links'));
  }
});

test('transport failure is not treated as unsupported', async () => {
  const f = linked(), rpc = f.config.rpc;
  f.config.rpc = (url, method, params) => method === 'eez_getCrossChainTransaction' ? Promise.reject(new Error('timeout')) : rpc(url, method, params);
  const result = await decodeCrossChainTrace(f.config, f.trigger);
  assert.equal(result.metadata.search.length, 0);
  assert.ok(result.unresolved.some(u => u.message === 'timeout'));
});

test('L2 canonical ownership refers to L1; a late loader or wrong loader function fails', async () => {
  for (const mutation of ['owner', 'order', 'function']) {
    const f = linked({ direction: 'L2' }), loader = f.txs.L2.get(hash('table-load'));
    if (mutation === 'owner') f.status.ownership.canonical.hash = f.blocks.L2.get(200).hash;
    if (mutation === 'order') {
      const source = f.txs.L2.get(f.trigger), block = f.blocks.L2.get(200);
      block.transactions.reverse();
      for (const [rec, index] of [[source, 0], [loader, 1]]) {
        rec.transaction.transactionIndex = hex(index); rec.receipt.transactionIndex = hex(index);
      }
    }
    if (mutation === 'function') loader.transaction.input = '0x';
    const result = await decodeCrossChainTrace(f.config, f.trigger);
    assert.equal(result.transactionLinks.length, 0);
    assert.ok(result.unresolved.some(u => u.code === 'invalid-transaction-links'));
  }
});

test('a table replacement inside the source rejects the loader association', async () => {
  const f = linked({ direction: 'L2' }), source = f.txs.L2.get(f.trigger);
  const log = structuredClone(f.txs.L2.get(hash('table-load')).receipt.logs[0]);
  Object.assign(log, { transactionHash: f.trigger, logIndex: hex(source.receipt.logs.length) }); source.receipt.logs.push(log);
  const result = await decodeCrossChainTrace(f.config, f.trigger);
  assert.ok(result.unresolved.some(u => /Intervening L2 table replacement/.test(u.message)));
});

test('changed attempts and reorgs invalidate previously resolved links', async () => {
  for (const mutation of ['attempt', 'block']) {
    const f = linked(), rpc = f.config.rpc; let count = 0;
    f.config.rpc = async (url, method, params) => {
      if (method === 'eez_getCrossChainTransaction' && ++count === 2) {
        if (mutation === 'attempt') f.status.transactions.attemptGeneration = '0x2';
        else f.blocks.L2.get(200).hash = hash('new canonical block');
      }
      return rpc(url, method, params);
    };
    const result = await decodeCrossChainTrace(f.config, f.trigger);
    assert.equal(result.transactionLinks.length, 0);
    assert.equal(result.edges.filter(e => e.type === 'cross-chain').length, 0);
    assert.ok(result.unresolved.some(u => u.code === 'invalid-transaction-links'));
  }
});

test('missing call traces retain verified transaction links without inventing executions', async () => {
  const f = linked(); f.failure.allTrace.add(f.deliveries[0]);
  const result = await decodeCrossChainTrace(f.config, f.trigger);
  assert.equal(result.transactionLinks.length, 1, JSON.stringify(result.unresolved));
  assert.ok(result.transactions.some(t => t.hash === f.deliveries[0] && !t.trace.available));
  assert.equal(result.edges.filter(e => e.type === 'cross-chain').length, 0);
});

test('SourceCompleted with no delivery retains only source and posting transactions', async () => {
  const f = linked({ isStatic: true }); f.status.transactions.l2 = [];
  const result = await decodeCrossChainTrace(f.config, f.trigger);
  assert.equal(result.transactionLinks.length, 1, JSON.stringify(result.unresolved));
  assert.deepEqual(result.transactions.map(t => t.hash).sort(), [f.trigger, f.posting].sort());
  assert.equal(result.outgoing[0].resultKind, 'precomputed-result-only');
});


test('shared L1 batch keeps unrelated native execution out of the requested logical subtree', async () => {
  const f = linked({ direction: 'L2' }), posting = f.txs.L1.get(f.posting);
  const unrelated = structuredClone(posting.trace.calls[0]);
  unrelated.calls[0].to = address(888);
  posting.trace.calls.push(unrelated);
  const result = await decodeCrossChainTrace(f.config, f.trigger), model = buildFlowModel(result);
  assert.equal(result.outgoing[0].status, 'matched');
  const root = model.roots.find(r => r.isOrigin), visible = [];
  const walk = id => { visible.push(model.nodes[id]); model.nodes[id].children.forEach(walk); }; walk(root.node);
  assert.ok(!visible.some(n => n.address === address(888)));
  assert.ok(result.frames.some(n => n.to === address(888)), 'full physical evidence is retained');
});

test('indistinguishable L1 occurrences stay ambiguous rather than using attempt ordinals', async () => {
  const f = linked({ direction: 'L2' }), posting = f.txs.L1.get(f.posting);
  posting.trace.calls.push(structuredClone(posting.trace.calls[0]));
  const parsed = protocol.L1.parseTransaction({ data: posting.transaction.input });
  const entry = abiValue(parsed.fragment.inputs[0], parsed.args[0]).entries[0];
  const entries = [entry, entry];
  posting.transaction.input = posting.trace.input = protocol.L1.encodeFunctionData('postAndVerifyBatch', [batch(entries)]);
  const result = await decodeCrossChainTrace(f.config, f.trigger);
  assert.equal(result.transactionLinks.length, 1);
  assert.equal(result.outgoing[0].status, 'ambiguous');
  assert.equal(result.outgoing[0].candidates.length, 2);
  assert.equal(result.edges.filter(e => e.type === 'cross-chain').length, 0);
});

test('a non-adjacent loader tolerates an unrelated reverted transaction', async () => {
  const f = linked({ direction: 'L2' }), block = f.blocks.L2.get(200), source = f.txs.L2.get(f.trigger);
  const h = hash('unrelated-revert'), tx = { ...source.transaction, hash: h, transactionIndex: '0x1' };
  f.txs.L2.set(h, { transaction: tx, receipt: { ...source.receipt, transactionHash: h, status: '0x0', logs: [] }, trace: { ...source.trace, calls: [], error: 'reverted' } });
  source.transaction.transactionIndex = source.receipt.transactionIndex = '0x2';
  block.transactions.splice(1, 0, tx);
  const result = await decodeCrossChainTrace(f.config, f.trigger);
  assert.equal(result.transactionLinks.length, 1, JSON.stringify(result.unresolved));
  assert.ok(!result.transactions.some(t => t.hash === h));
});

test('system delivery without a source record retains settlement discovery', async () => {
  const f = linked(); f.status = null;
  const result = await decodeCrossChainTrace(f.config, f.deliveries[0]);
  assert.equal(result.metadata.transactionLinks.state, 'fallback');
  assert.equal(result.outgoing[0].status, 'matched');
  assert.ok(result.transactions.some(t => t.hash === f.trigger));
});


function orderedSources() {
  const f = linked({ direction: 'L2' }), block = f.blocks.L2.get(200);
  const secondSource = hash('second-source'), secondLoader = hash('second-loader');
  for (const [oldHash, newHash, index] of [[hash('table-load'), secondLoader, 2], [f.trigger, secondSource, 3]]) {
    const rec = structuredClone(f.txs.L2.get(oldHash));
    Object.assign(rec.transaction, { hash: newHash, transactionIndex: hex(index), nonce: '0x1' });
    Object.assign(rec.receipt, { transactionHash: newHash, transactionIndex: hex(index) });
    for (const log of rec.receipt.logs) Object.assign(log, { transactionHash: newHash, transactionIndex: hex(index) });
    f.txs.L2.set(newHash, rec); block.transactions.push(rec.transaction);
  }
  const secondStatus = structuredClone(f.status);
  secondStatus.hash = secondSource; secondStatus.nonce = '0x1';
  secondStatus.transactions.l2 = [secondLoader, secondSource].map(hash => ({ hash, chainId: '0xc8' }));
  const statuses = new Map([[f.trigger, f.status], [secondSource, secondStatus]]), rpc = f.config.rpc;
  f.config.rpc = (url, method, params) => method === 'eez_getCrossChainTransaction' ? Promise.resolve(structuredClone(statuses.get(params[0]) ?? null)) : rpc(url, method, params);
  const post = f.txs.L1.get(f.posting), parsed = protocol.L1.parseTransaction({ data: post.transaction.input });
  const entry = abiValue(parsed.fragment.inputs[0], parsed.args[0]).entries[0];
  const native = l1Entry('0x' + '0'.repeat(64), [], { returnData: '0x' });
  const entries = [native, entry, entry, entry];
  const encoded = protocol.L1.encodeFunctionData('postAndVerifyBatch', [{ ...batch(entries), immediateEntryCount: entries.length }]);
  post.transaction.input = post.trace.input = encoded;
  const incoming = post.trace.calls[0];
  post.trace.calls = entries.map((e, i) => frame(M.L1, M.L1, protocol.L1.encodeFunctionData('_attemptExecuteImmediateL2Txs', [e]), i === 0 ? [] : [structuredClone(incoming)], i === 1 ? { error: 'execution reverted', output: '0xdeadbeef' } : {}));
  return { f, secondSource, secondLoader, statuses, post };
}

test('ordered canonical source units distinguish identical calls after native and skipped entries', async () => {
  const { f, secondSource } = orderedSources();
  const result = await decodeCrossChainTrace(f.config, secondSource);
  assert.equal(result.transactionLinks.length, 1, JSON.stringify(result.unresolved));
  const isolation = result.transactionLinks[0].l1Execution;
  assert.equal(isolation.entryIndex, 3);
  assert.equal(isolation.sourceIndex, 1);
  assert.deepEqual(isolation.units.map(u => u.sourceHash), [f.trigger, secondSource]);
  assert.equal(result.outgoing[0].status, 'matched');
  assert.ok(result.outgoing[0].remoteFrameId.startsWith(`L1:${f.posting}:0.3.`));
  assert.ok(!result.transactions.some(t => t.hash === f.trigger), 'other source units are verified without tracing their flows');
  const model = buildFlowModel(result), nodes = [];
  const walk = id => { nodes.push(model.nodes[id]); model.nodes[id].children.forEach(walk); };
  walk(model.roots.find(r => r.isOrigin).node);
  assert.ok(nodes.some(n => n.frameId?.startsWith(`L1:${f.posting}:0.3.`)));
  assert.ok(!nodes.some(n => /^0\.[012](\.|$)/.test(n.path) && n.chain === 'L1'));
});

test('source-unit count or missing source evidence prevents an ordinal match', async () => {
  for (const change of ['missing', 'count']) {
    const { f, secondSource, statuses, post } = orderedSources();
    if (change === 'missing') statuses.delete(f.trigger);
    else delete post.trace.calls[1].error; // now three successful hosts, only two canonical source units
    const result = await decodeCrossChainTrace(f.config, secondSource);
    assert.equal(result.transactionLinks.length, 0);
    assert.equal(result.edges.filter(e => e.type === 'cross-chain').length, 0);
    assert.ok(result.unresolved.some(u => /sequence|count/.test(u.message)), JSON.stringify(result.unresolved));
  }
});
