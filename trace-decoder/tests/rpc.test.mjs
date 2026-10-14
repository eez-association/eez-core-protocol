import assert from 'node:assert/strict';
import test from 'node:test';
import { makeRpc, ChainReader } from '../src/rpc.mjs';
import { hash } from './fixtures/scenarios.mjs';

const response = body => ({ ok: true, json: async () => body });
const reply = (r, result = r.params[0]) => ({ jsonrpc: '2.0', id: r.id, result });

test('RPC batches use at most 100 requests and restore reordered responses by ID', async () => {
  const payloads = [];
  const rpc = makeRpc({ fetch: async (_, options) => {
    const requests = JSON.parse(options.body); payloads.push(requests);
    return response(requests.map(r => reply(r)).reverse());
  } });
  const params = Array.from({ length: 205 }, (_, n) => [n]);
  assert.deepEqual(await rpc.batch('rpc', 'read', params), params.flat());
  assert.deepEqual(payloads.map(p => p.length), [100, 100, 5]);
  assert.equal(new Set(payloads.flat().map(r => r.id)).size, 205);
});

test('explicit batch rejection is remembered and ordinary requests stay bounded', async () => {
  for (const httpError of [false, true]) {
    let batches = 0, active = 0, peak = 0;
    const rpc = makeRpc({ fetch: async (_, options) => {
      const request = JSON.parse(options.body);
      if (Array.isArray(request)) {
        batches++;
        return { ok: !httpError, status: 400, json: async () => ({ error: { code: -32600, message: 'Batch unsupported' } }) };
      }
      peak = Math.max(peak, ++active);
      await new Promise(resolve => setImmediate(resolve)); active--;
      return response(reply(request));
    } });
    const params = Array.from({ length: 105 }, (_, n) => [n]);
    assert.deepEqual(await rpc.batch('rpc', 'read', params), params.flat());
    assert.deepEqual(await rpc.batch('rpc', 'read', [[106]]), [106]);
    assert.equal(batches, 1); assert.ok(peak > 1 && peak <= 8);
  }
});

test('missing, duplicate, unknown batch IDs and member errors are rejected', async () => {
  for (const corrupt of [
    rs => [reply(rs[0])],
    rs => [reply(rs[0]), reply(rs[0])],
    rs => [reply(rs[0]), { ...reply(rs[1]), id: 999 }],
    rs => [reply(rs[0]), { jsonrpc: '2.0', id: rs[1].id, error: { code: -32000, message: 'unavailable' } }],
  ]) {
    const rpc = makeRpc({ fetch: async (_, options) => response(corrupt(JSON.parse(options.body))) });
    await assert.rejects(rpc.batch('rpc', 'read', [[1], [2]]), /batch|unavailable/);
  }
});

test('prefetched blocks cannot be cached under the wrong number', async () => {
  const rpc = makeRpc({ fetch: async (_, options) => response(JSON.parse(options.body).map(r => reply(r, {
    number: '0x99', hash: hash('wrong-block'), transactions: [],
  }))) });
  const reader = new ChainReader('L2', 'rpc', null, rpc);
  await assert.rejects(reader.prefetchBlocks([1, 2]), /invalid block batch/);
  assert.equal(reader.blocks.size, 0);
});

test('failed batch reads retain the archive fallback for ordinary block reads', async () => {
  const calls = [];
  const rpc = makeRpc({ fetch: async (url, options) => {
    const r = JSON.parse(options.body); calls.push({ url, batch: Array.isArray(r) });
    if (url === 'primary') throw new Error('history unavailable');
    return response(reply(r, { number: r.params[0], hash: hash(r.params[0]), transactions: [] }));
  } });
  const reader = new ChainReader('L1', 'primary', 'archive', rpc);
  await reader.prefetchBlocks([1, 2]);
  assert.equal((await reader.block(2)).hash, hash('0x2'));
  assert.equal(calls.filter(c => c.url === 'archive').length, 2);
});
