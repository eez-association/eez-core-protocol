import assert from 'node:assert/strict';
import test from 'node:test';
import { decodeCrossChainTrace } from '../src/engine.mjs';
import { lookupTransactionLinks } from '../src/transaction-links.mjs';
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
  assert.ok(!f.calls.some(c => c.method === 'eth_getLogs' || /^eez_getSettle/.test(c.method)));
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
  const model = buildFlowModel(result);
  assert.equal(model.stats.frames, model.nodes.filter(n => n.inFlow && n.frameId).length);
  assert.ok(!model.roots.some(r => r.tx === f.deliveries[0]));
  assert.equal(result.edges.filter(e => e.type === 'cross-chain').length, 0);
});

test('SourceCompleted with no delivery retains only source and posting transactions', async () => {
  const f = linked({ isStatic: true }); f.status.transactions.l2 = [];
  const result = await decodeCrossChainTrace(f.config, f.trigger);
  assert.equal(result.transactionLinks.length, 1, JSON.stringify(result.unresolved));
  assert.deepEqual(result.transactions.map(t => t.hash).sort(), [f.trigger, f.posting].sort());
  assert.equal(result.outgoing[0].resultKind, 'precomputed-result-only');
  assert.equal(result.outgoing[0].status, 'prepared-result');
  const model = buildFlowModel(result);
  assert.equal(model.unresolved.length, 0);
  assert.ok(!model.nodes.some(n => n.kind === 'ghost'));
  assert.ok(model.nodes.some(n => n.preparedResult));
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


function wrappedPosting() {
  const f = linked({ direction: 'L2' }), post = f.txs.L1.get(f.posting);
  const wrapper = address(700), inner = post.trace;
  inner.from = wrapper;
  post.trace = frame(post.transaction.from, wrapper, '0x12345678', [inner]);
  Object.assign(post.transaction, { to: wrapper, input: post.trace.input });
  post.receipt.to = wrapper;
  // Block transactions share this transaction object, retaining inclusion identity.
  f.status = null;
  return f;
}

test('wrapped batch without a source record discovers the same flow in auto and off modes', async () => {
  const f = wrappedPosting();
  const auto = await decodeCrossChainTrace(f.config, f.posting);
  assert.deepEqual(auto.metadata.transactionLinks, { state: 'fallback', reason: 'system transaction has no source record', observation: null });
  assert.ok(!auto.unresolved.some(u => u.code === 'transaction-links-pending'));
  assert.ok(f.calls.some(c => /^eez_getSettle/.test(c.method)), 'auto must use settlement discovery');
  const off = await decodeCrossChainTrace({ ...f.config, txLinks: 'off' }, f.posting);
  const ids = r => r.transactions.map(t => `${t.chain}:${t.hash}`).sort();
  assert.deepEqual(ids(auto), [`L1:${f.posting}`, `L2:${f.trigger}`, `L2:${hash('table-load')}`].sort());
  assert.deepEqual(ids(auto), ids(off));
  for (const result of [auto, off]) {
    assert.equal(result.outgoing.length, 1);
    assert.equal(result.outgoing[0].status, 'matched');
    assert.ok(result.outgoing[0].remoteFrameId.startsWith(`L1:${f.posting}:0.0.`));
  }
});


const postingInput = protocol.L1.encodeFunctionData('postAndVerifyBatch', [batch([])]);
const postFrame = () => frame(address(700), M.L1, postingInput);
const wrapFrame = child => frame(address(99), address(700), '0x12345678', [child]);
const sourceFrame = (name, extra = {}) => frame(address(20), M.L1,
  protocol.L1.encodeFunctionData(name, [address(10), '0x']), [], extra);

const postingCases = [
  ['direct committed posting', () => postFrame(), 'system'],
  ['deeply wrapped posting', () => wrapFrame(wrapFrame(wrapFrame(postFrame()))), 'system'],
  ['wrong destination', () => ({ ...postFrame(), to: address(701) }), 'local'],
  ['undecodable posting', () => ({ ...postFrame(), input: postingInput.slice(0, 10) }), 'pending'],
  ['reverted posting', () => wrapFrame({ ...postFrame(), error: 'execution reverted' }), 'pending'],
  ['reverted enclosing frame', () => wrapFrame({ ...wrapFrame(postFrame()), error: 'execution reverted' }), 'pending'],
  ['reverted transaction', () => ({ ...wrapFrame(postFrame()), error: 'execution reverted' }), 'pending'],
  ['caught attempt followed by committed posting', () => ({ ...wrapFrame(postFrame()),
    calls: [{ ...wrapFrame(postFrame()), error: 'execution reverted' }, postFrame()] }), 'system'],
];
// Manager identity follows storage context, for both delegation opcodes.
for (const type of ['DELEGATECALL', 'CALLCODE']) {
  postingCases.push(
    [`manager proxy using ${type}`, () => wrapFrame(frame(address(700), M.L1, '0x12345678', [
      frame(M.L1, address(702), postingInput, [], { type }),
    ])), 'system'],
    [`wrapper using manager code via ${type}`, () => wrapFrame({ ...postFrame(), type }), 'local'],
  );
}
for (const name of ['executeCrossChainCall', 'staticCrossChainCall']) {
  for (const reverted of ['none', 'call', 'ancestor']) {
    postingCases.push([`posting with ${name}, revert=${reverted}`, () => {
      let source = sourceFrame(name, reverted === 'call' ? { error: 'execution reverted' } : {});
      if (reverted === 'ancestor') source = { ...wrapFrame(source), error: 'execution reverted' };
      return { ...wrapFrame(postFrame()), calls: [postFrame(), source] };
    }, 'pending']);
  }
}
for (const [name, makeTrace, expected] of postingCases) test(`batch fallback: ${name}`, async () => {
  const f = wrappedPosting(), rec = f.txs.L1.get(f.posting), trace = makeTrace();
  const result = await lookupTransactionLinks({ config: { ...f.config, rollups: M.L1 }, rpc: f.config.rpc,
    origin: { ...rec, hash: f.posting, chain: 'L1', traceResult: { trace } }, chainIds: { L1: '100', L2: '200' } });
  assert.equal(result.state, expected === 'pending' ? 'pending' : 'fallback');
  if (expected !== 'pending') assert.equal(result.reason, expected === 'system'
    ? 'system transaction has no source record' : 'local transaction has no EEZ calls');
});

for (const variant of ['required', 'incomplete', 'invalid', 'transport', 'missing trace', 'direct missing trace']) {
  test(`wrapped posting keeps conservative link handling: ${variant}`, async () => {
    const f = wrappedPosting();
    if (variant === 'incomplete' || variant === 'invalid') {
      f.status = { hash: f.posting, direction: 'inbound', transactions: { complete: variant === 'invalid' } };
    }
    if (variant === 'transport') {
      const rpc = f.config.rpc;
      f.config.rpc = (url, method, params) => method === 'eez_getCrossChainTransaction'
        ? Promise.reject(new Error('timeout')) : rpc(url, method, params);
    }
    if (variant.includes('missing trace')) {
      if (variant === 'direct missing trace') {
        const post = f.txs.L1.get(f.posting);
        post.transaction.to = post.receipt.to = M.L1;
        post.transaction.input = post.trace.calls[0].input;
        post.trace = post.trace.calls[0];
      }
      f.failure.allTrace.add(f.posting);
    }
    const result = await decodeCrossChainTrace({ ...f.config, ...(variant === 'required' ? { txLinks: 'required' } : {}) }, f.posting);
    assert.equal(result.transactions.length, 1);
    assert.equal(result.metadata.search.length, 0);
    assert.ok(!f.calls.some(c => /^eez_getSettle/.test(c.method)));
    assert.ok(result.unresolved.some(u => u.code === (['invalid', 'transport'].includes(variant)
      ? 'invalid-transaction-links' : 'transaction-links-pending')), JSON.stringify(result.unresolved));
  });
}


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
  const model = buildFlowModel(result, { mode: 'physical' }), nodes = [];
  const walk = id => { nodes.push(model.nodes[id]); model.nodes[id].children.forEach(walk); };
  walk(model.roots.find(r => r.preferred).node);
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


test('physical entry rendering preserves every frame and its order without call associations', async () => {
  const { f, secondSource } = orderedSources();
  const trace = await decodeCrossChainTrace(f.config, secondSource);
  const host = trace.transactionLinks[0].l1Execution.frameId;
  // Pairing metadata may be ambiguous or absent; the observed subtree is complete.
  for (const o of trace.outgoing) { delete o.remoteFrameId; o.status = 'ambiguous'; }
  trace.unresolved.push({ code: 'ambiguous-remote-occurrence', message: 'Repeated calls', frameId: trace.outgoing.at(-1).frameId });
  const model = buildFlowModel(trace, { mode: 'physical' }), root = model.roots.find(r => r.preferred);
  assert.equal(model.mode, 'physical');
  assert.equal(model.nodes[root.node].frameId, host);
  const frames = new Map(trace.frames.map(f => [f.id, f])), expected = [], actual = [];
  const walkFrames = id => { expected.push(id); frames.get(id).children.forEach(walkFrames); };
  const walkNodes = id => { actual.push(model.nodes[id].frameId); model.nodes[id].children.forEach(walkNodes); };
  walkFrames(host); walkNodes(root.node);
  assert.deepEqual(actual, expected);
  assert.ok(!model.nodes.some(n => n.kind === 'ghost'));
  assert.equal(model.unresolved.length, 0);
  assert.equal(model.matchingNotes.length, 1);
  const { renderTrace } = await import('../src/logical.mjs');
  const text = renderTrace(trace, { full: true, recorded: true });
  assert.ok(text.includes('L1 entry 3'));
  assert.ok(text.includes(host));
  assert.ok(!text.includes(`L1:${f.posting}:0.2.`));
});


for (const name of ['executeCrossChainCall', 'staticCrossChainCall']) {
  for (const placement of ['immediate', 'reverted immediate', 'meta hook', 'outside batch', 'foreign attempt']) {
    test(`batch callback classification: ${name} in ${placement}`, async () => {
      const f = wrappedPosting(), rec = f.txs.L1.get(f.posting), post = rec.trace.calls[0];
      const parsed = protocol.L1.parseTransaction({ data: post.input });
      const entry = abiValue(parsed.fragment.inputs[0], parsed.args[0]).entries[0];
      const attempt = frame(M.L1, M.L1, protocol.L1.encodeFunctionData('_attemptExecuteImmediateL2Txs', [entry]),
        [frame(M.L1, address(21), '0x', [sourceFrame(name)])]);
      post.calls = [attempt];
      if (placement === 'reverted immediate') attempt.error = 'execution reverted';
      if (placement === 'meta hook') post.calls.push(frame(M.L1, rec.transaction.to, '0x12345678', [sourceFrame(name)]));
      if (placement === 'outside batch') rec.trace.calls.push(sourceFrame(name));
      if (placement === 'foreign attempt') attempt.from = address(999);
      const result = await lookupTransactionLinks({ config: { ...f.config, rollups: M.L1 }, rpc: f.config.rpc,
        origin: { ...rec, hash: f.posting, chain: 'L1', traceResult: { trace: rec.trace } }, chainIds: { L1: '100', L2: '200' } });
      assert.equal(result.state, placement.includes('immediate') ? 'fallback' : 'pending');
      if (result.state === 'fallback') assert.equal(result.reason, 'system transaction has no source record');
    });
  }
}


for (const [name,args] of [
  ['executeL2Txs',[1]], ['createCrossChainProxy',[address(10),1]],
  ['getOrCreateCrossChainProxy',[address(10),1]], ['registerRollup',[address(10),hash('root')]],
  ['setRoot',[1,hash('root')]], ['authorizedProxies',[address(10)]],
  ['computeCrossChainProxyAddress',[address(10),1]],
]) test(`non-source manager transaction ${name} can use fallback`, async () => {
  const f = wrappedPosting(), rec = f.txs.L1.get(f.posting);
  const call = frame(address(700),M.L1,protocol.L1.encodeFunctionData(name,args));
  const origin = { ...rec,hash:f.posting,chain:'L1',traceResult:{trace:wrapFrame(call)} };
  const options = { config:{...f.config,rollups:M.L1},rpc:f.config.rpc,origin,chainIds:{L1:'100',L2:'200'} };
  assert.equal((await lookupTransactionLinks(options)).reason,'non-source manager transaction has no source record');
  assert.equal((await lookupTransactionLinks({...options,config:{...options.config,txLinks:'required'}})).state,'pending');
  origin.traceResult.trace.calls.push(sourceFrame('executeCrossChainCall'));
  assert.equal((await lookupTransactionLinks(options)).state,'pending');
});

test('correlation-only endpoint on the other chain is fallback in auto, not an invalid source record', async () => {
  const f = linked({direction:'L2'}), rec = f.txs.L2.get(f.trigger);
  const options = { config:{...f.config,l1Front:null,l2Front:null,correlationRpc:'l1-front',managerL2:M.L2},
    rpc:f.config.rpc,origin:{...rec,hash:f.trigger,chain:'L2',traceResult:{trace:rec.trace}},chainIds:{L1:'100',L2:'200'} };
  assert.equal((await lookupTransactionLinks(options)).reason,'correlation endpoint is not a source-chain frontend');
  assert.equal(f.linkCalls.length,0);
  await assert.rejects(lookupTransactionLinks({...options,config:{...options.config,txLinks:'required'}}),/wrong chain ID/);
  await assert.rejects(lookupTransactionLinks({...options,config:{...options.config,l2Front:'l1-front'}}),/wrong chain ID/);
});


test('text CLI defaults to linked flow and offers recorded traces explicitly', async () => {
  const f=linked({direction:'L2'}),trace=await decodeCrossChainTrace(f.config,f.trigger);
  const {renderTrace}=await import('../src/logical.mjs');
  assert.match(renderTrace(trace),/⇢ L1/);
  assert.doesNotMatch(renderTrace(trace),/L1 l1-execution/);
  assert.match(renderTrace(trace,{recorded:true}),/L1 l1-execution/);
});
