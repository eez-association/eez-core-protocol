import assert from 'node:assert/strict';
import test from 'node:test';
import { decodeCrossChainTrace } from '../src/engine.mjs';
import { hex } from '../src/protocol.mjs';
import { scenario, address, frame, hash, event } from './fixtures/scenarios.mjs';

// Pads the L1 settlement/trigger block with unrelated transactions, as on mainnet.
function padL1Block(f, count) {
  const block = f.blocks.L1.get(100);
  for (let i = 0; i < count; i++) {
    const txHash = hash(`unrelated-${i}`), index = block.transactions.length;
    const transaction = { hash: txHash, from: address(700 + i), to: address(800 + i), input: '0x', blockNumber: block.number, blockHash: block.hash, transactionIndex: hex(index), value: '0x0' };
    const receipt = { transactionHash: txHash, blockNumber: block.number, blockHash: block.hash, transactionIndex: hex(index), status: '0x1', logs: [] };
    f.txs.L1.set(txHash, { transaction, receipt, trace: frame(transaction.from, transaction.to) });
    block.transactions.push(transaction);
  }
}
const l1Traces = f => f.calls.filter(c => c.url.includes('l1') && c.method === 'debug_traceTransaction').length;

// Keep the delivery in an interior block, so checking the range boundaries alone
// cannot find it. Most blocks are empty, as in the FalconVerifier devnet capture.
function spreadL2(f, count = 2045) {
  const first = 100, last = first + count - 1;
  for (let n = first; n <= last; n++) if (!f.blocks.L2.has(n)) {
    f.blocks.L2.set(n, { number: hex(n), hash: hash(`L2-block-${n}`), timestamp: hex(n + 1000), transactions: [] });
  }
  f.settlement.l2Blocks = [...f.blocks.L2.values()].map(b => ({ number: b.number, hash: b.hash }));
  f.settlement.l2Range = { firstBlockNumber: hex(first), lastBlockNumber: hex(last), blockCount: hex(count),
    firstBlockHash: f.blocks.L2.get(first).hash, lastBlockHash: f.blocks.L2.get(last).hash };
}

test('a sparse 2045-block settlement takes 21 block batches and no L2 block receipts', async () => {
  const f = scenario(); spreadL2(f);
  const { rpc, ...config } = f.config, requests = [];
  const fetch = async (url, options) => {
    const payload = JSON.parse(options.body); requests.push({ url, payload });
    const run = async r => ({ jsonrpc: '2.0', id: r.id, result: await rpc(url, r.method, r.params) });
    const result = Array.isArray(payload) ? (await Promise.all(payload.map(run))).reverse() : await run(payload);
    return { ok: true, json: async () => result };
  };
  const result = await decodeCrossChainTrace({ ...config, fetch }, f.trigger);
  assert.equal(result.outgoing[0].status, 'matched');
  assert.equal(result.unresolved.length, 0);
  assert.ok(result.transactions.some(t => t.hash === f.deliveries[0]), 'eventless direct-manager delivery survives');
  const blocks = requests.filter(r => r.url === 'l2-rpc' && Array.isArray(r.payload));
  assert.equal(blocks.length, 21); assert.ok(blocks.every(r => r.payload.length <= 100));
  assert.equal(f.calls.filter(c => c.url === 'l2-rpc' && c.method === 'eth_getBlockReceipts').length, 0);
  assert.equal(f.calls.filter(c => c.url === 'l2-rpc' && c.method === 'eth_getLogs').length, 5);
});

test('range logs find a wrapper delivery; unavailable logs fall back to block receipts', async () => {
  for (const unavailable of [false, true]) {
    const f = scenario(); spreadL2(f, 105);
    const delivery = f.txs.L2.get(f.deliveries[0]), inner = delivery.trace;
    delivery.trace = { ...inner, to: address(77), input: '0x', calls: [inner] };
    delivery.transaction.to = address(77); delivery.transaction.input = '0x';
    delivery.receipt.logs = [{ ...event('L2', 'CrossChainCallExecuted', [f.key, f.inProxy, f.source, '0x', 0, 0]),
      transactionHash: f.deliveries[0], blockNumber: '0xc8', blockHash: f.blocks.L2.get(200).hash, logIndex: '0x0' }];
    const rpc = f.config.rpc;
    const result = await decodeCrossChainTrace({ ...f.config, rpc: async (url, method, params) => {
      if (unavailable && url === 'l2-rpc' && method === 'eth_getLogs') throw new Error('logs unavailable');
      return rpc(url, method, params);
    } }, f.trigger);
    assert.equal(result.outgoing[0].status, 'matched');
    assert.equal(f.calls.filter(c => c.url === 'l2-rpc' && c.method === 'eth_getBlockReceipts').length, unavailable ? 1 : 0);
  }
});

test('a canonical hash mismatch in the middle of a prefetched range is rejected', async () => {
  const f = scenario(); spreadL2(f, 105);
  f.settlement.l2Blocks.find(b => b.number === hex(150)).hash = hash('fork');
  const result = await decodeCrossChainTrace(f.config, f.trigger);
  assert.equal(result.settlements.length, 0);
  assert.ok(result.unresolved.some(u => u.code === 'invalid-settlement' && /150/.test(u.message)));
});

test('correlation is pinned to the receipt block hash on both chains', async () => {
  for (const direction of ['L1', 'L2']) {
    const f = scenario({ direction });
    await decodeCrossChainTrace(f.config, f.trigger);
    const method = direction === 'L1' ? 'eez_getSettledL2RangesByL1Block' : 'eez_getSettlementByL2Block';
    const lookups = f.calls.filter(c => c.method === method && c.params[0] !== '0x1');
    assert.deepEqual(lookups.map(c => c.params), [[{ blockHash: f.txs[direction].get(f.trigger).receipt.blockHash }]]);
  }
});

test('a fully traced local L2 transaction follows its exact settlement without a range scan', async () => {
  const f = scenario({ direction: 'L2' }); spreadL2(f);
  const trigger = f.txs.L2.get(f.trigger);
  trigger.trace.calls = []; trigger.receipt.logs = [];
  const result = await decodeCrossChainTrace(f.config, f.trigger);
  assert.deepEqual(result.transactions.map(t => t.hash).sort(), [f.trigger, f.posting].sort());
  assert.ok(result.transactions.every(t => t.trace.available));
  assert.equal(result.metadata.search.length, 0);
  assert.equal(result.outgoing.length, 0);
  assert.equal(f.calls.filter(c => c.method === 'eth_getLogs' || c.method === 'eth_getBlockReceipts').length, 0);
  assert.ok(result.diagnostics.some(d => d.code === 'local-transaction-settlement'));
  const thorough = await decodeCrossChainTrace({ ...f.config, thorough: true }, f.trigger);
  assert.equal(thorough.metadata.search.length, 1);
  assert.ok(thorough.transactions.some(t => t.hash === hash('table-load')));
});

test('failed or mismatched hash correlation never expands to a timestamp scan', async () => {
  for (const failure of ['transport', 'hash']) {
    const f = scenario({ direction: 'L2' }), rpc = f.config.rpc;
    const result = await decodeCrossChainTrace({ ...f.config, rpc: async (url, method, params) => {
      if (method === 'eez_getSettlementByL2Block' && params[0]?.blockHash) {
        if (failure === 'transport') throw new Error('index catching up');
        return { ...f.settlement, matchedL2Block: { number: '0xc8', hash: hash('reorg') } };
      }
      return rpc(url, method, params);
    } }, f.trigger);
    assert.equal(result.settlements.length, 0);
    assert.equal(result.metadata.search.length, 0);
    assert.ok(result.unresolved.some(u => u.code === (failure === 'transport' ? 'correlation-lookup-failed' : 'invalid-settlement')));
  }
});

test('without block receipts the scan falls back to manager logs, never to tracing every transaction', async () => {
  const f = scenario({ direction: 'L2' });
  padL1Block(f, 20);
  const rpc = f.config.rpc;
  const noReceipts = (url, method, params) => method === 'eth_getBlockReceipts' && url.includes('l1') ? Promise.reject(new Error('method not found')) : rpc(url, method, params);
  const result = await decodeCrossChainTrace({ ...f.config, rpc: noReceipts }, f.trigger);
  assert.equal(result.outgoing[0].status, 'matched');
  assert.ok(l1Traces(f) <= 2, `traced ${l1Traces(f)} L1 transactions`);
  const line = result.diagnostics.find(d => d.code === 'block-prefiltered' && d.chain === 'L1');
  assert.notEqual(line.source, 'receipts');
});

test('a non-archive read RPC is backed by the archive trace RPC for historical reads', async () => {
  for (const direction of ['L1', 'L2']) {
    const f = scenario({ direction });
    const rpc = f.config.rpc;
    // l1-rpc behaves like a pruned node: no history, no receipts, no tracing.
    const pruned = (url, method, params) => {
      if (url === 'l1-rpc') {
        if (method === 'eth_call' && params[1] !== 'latest') return Promise.reject(new Error('missing trie node'));
        if (method === 'eth_getTransactionReceipt') return Promise.resolve(null);
        if (method === 'eth_getBlockReceipts' || method.startsWith('debug_')) return Promise.reject(new Error('historical state unavailable'));
      }
      return rpc(url, method, params);
    };
    const prunedOnly = await decodeCrossChainTrace({ ...f.config, rpc: pruned }, f.trigger);
    assert.notEqual(prunedOnly.outgoing[0]?.status, 'matched', `${direction}: a pruned read RPC alone cannot match`);
    const withArchive = await decodeCrossChainTrace({ ...f.config, rpc: pruned, l1TraceRpc: 'l1-archive' }, f.trigger);
    assert.equal(withArchive.outgoing[0].status, 'matched', direction);
    assert.ok(withArchive.transactions.every(t => t.trace.available), direction);
  }
});

test('L1 blocks trace only manager calls and manager events; --thorough traces everything', async () => {
  const quick = scenario({ direction: 'L2' });
  padL1Block(quick, 20);
  const fast = await decodeCrossChainTrace(quick.config, quick.trigger);
  assert.equal(fast.outgoing[0].status, 'matched');
  assert.ok(l1Traces(quick) <= 2, `traced ${l1Traces(quick)} L1 transactions`);
  assert.ok(fast.diagnostics.some(d => d.code === 'block-prefiltered' && d.total === 21));

  const full = scenario({ direction: 'L2' });
  padL1Block(full, 20);
  const slow = await decodeCrossChainTrace({ ...full.config, thorough: true }, full.trigger);
  assert.equal(slow.outgoing[0].status, 'matched');
  assert.ok(l1Traces(full) >= 21, `traced ${l1Traces(full)} L1 transactions`);
  assert.deepEqual(slow.transactions.map(t => t.hash), fast.transactions.map(t => t.hash), 'same transactions found either way');
});
