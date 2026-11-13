import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { buildQuoteModels, isQuoteTrace } from '../flow/quote-model.mjs';
import { renderFlowHtml } from '../flow/render-flow.mjs';
import { quoteFixture } from './fixtures/quote.mjs';

const traceOf = q => q.diagnostics.trace;

test('quote result and RPC envelope preserve cross-chain topology and independent run identity', () => {
  const q = quoteFixture(), before = JSON.stringify(q);
  assert.ok(isQuoteTrace(q)); assert.ok(isQuoteTrace({ result: q }));
  assert.equal(isQuoteTrace({ diagnostics: [], frames: [], logicalNodes: [] }), false);
  const models = buildQuoteModels(q);
  assert.deepEqual(models, buildQuoteModels({ jsonrpc: '2.0', id: 1, result: q }));
  assert.equal(JSON.stringify(q), before);
  assert.equal(models.length, 3);
  const m = models[0];
  assert.equal(m.simulation.runId, 2);
  assert.deepEqual(m.nodes.map(n => n.chain), ['L2', 'L2', 'L1', 'L1']);
  assert.deepEqual(m.nodes.map(n => n.children), [[1], [2], [3], []]);
  assert.equal(m.nodes[2].crossing.status, 'simulated');
  assert.equal(m.stats.crossings, 1); assert.equal(m.stats.matched, 0);
  assert.equal(m.nodes[3].output, '0x' + '02'.padStart(64, '0'));
  assert.equal(new Set(models.flatMap(m => m.nodes.map(n => n.frameId))).size, 12);
  for (const m of models) {
    assert.equal(m.txHash, null); assert.equal(m.gas, null);
    assert.deepEqual(m.transactions, []); assert.deepEqual(m.settlements, []);
    assert.ok(m.nodes.every(n => n.tx === null && n.block === null));
  }
});

test('last final composition is preferred, or last composition when final validation is absent', () => {
  const q = quoteFixture();
  const last = structuredClone(traceOf(q).runs[2]); last.id = 10; last.pass = 2;
  traceOf(q).runs.push(last);
  assert.equal(buildQuoteModels(q)[0].simulation.runId, 10);
  traceOf(q).runs.forEach(r => { r.phase = 'gas_estimation'; });
  assert.equal(buildQuoteModels(q)[0].simulation.runId, 10);
});

test('unordered frames, repeated calls and chain bounces keep their supplied ancestry', () => {
  const q = quoteFixture(), run = traceOf(q).runs[2];
  run.frames.push({ ...structuredClone(run.frames[0]), id: 4, parentId: 3, crossChain: true });
  run.frames = [run.frames[4], run.frames[3], run.frames[1], run.frames[0], run.frames[2]];
  const m = buildQuoteModels(q)[0];
  assert.equal(m.roots.length, 1);
  assert.equal(m.nodes[m.roots[0].node].path, '0');
  assert.equal(m.stats.crossings, 2);
  assert.deepEqual(m.nodes.find(n => n.path === '3').children, [0]);
});

test('truncation, omitted runs, incomplete runs and detached children stay visibly incomplete', () => {
  const q = quoteFixture(), t = traceOf(q); t.truncated = true; t.omittedRuns = 1;
  t.runs[2].complete = false;
  t.runs[2].frames[0].parentId = 900;
  t.runs[2].frames[3].output = { hex: '0x1234', length: 100, truncated: true };
  const m = buildQuoteModels(q)[0];
  assert.match(m.executionNotice, /Incomplete simulation capture/);
  assert.ok(m.unresolved.some(i => i.code === 'missing-simulation-parent'));
  assert.ok(m.unresolved.some(i => i.code === 'truncated-frame-bytes'));
  assert.equal(m.nodes[3].outputInfo.length, 100);
  assert.equal(m.nodes[3].ret.status, 'raw');
});

for (const [name, edit, message] of [
  ['cycle', r => { r.frames[0].parentId = 3; }, /Cycle/],
  ['missing parent', r => { r.frames[0].parentId = 900; }, /Missing parent/],
  ['duplicate frame', r => { r.frames.push(r.frames[0]); }, /Duplicate frame/],
  ['unknown chain', r => { r.frames[0].chainId = '0x99'; }, /Unknown.*chain/],
  ['invalid bytes', r => { r.frames[0].input.hex = '0x0'; }, /Invalid Input/],
  ['false byte length', r => { r.frames[0].output.length = 1; }, /Inconsistent Output/],
  ['negative gas', r => { r.frames[0].gasUsed = -1; }, /Invalid.*gas/],
]) test(`rejects ${name} without rendering misleading data`, () => {
  const q = quoteFixture(); edit(traceOf(q).runs[0]);
  assert.throws(() => buildQuoteModels(q), message);
});

test('RPC errors, missing trace and unsupported schemas have explicit errors', () => {
  assert.throws(() => buildQuoteModels({ error: { code: -32601, message: 'unsupported' } }), /RPC error: unsupported/);
  assert.throws(() => buildQuoteModels({ diagnostics: {} }), /trace: "calls"/);
  const q = quoteFixture(); traceOf(q).version = 2;
  assert.throws(() => buildQuoteModels(q), /format\/version/);
  traceOf(q).version = 1; traceOf(q).runs = [];
  assert.throws(() => buildQuoteModels(q), /no simulation runs/);
});

test('reverts roll back successful descendants, unknown status stays unknown, and gas keeps precision', () => {
  const q = quoteFixture(), frames = traceOf(q).runs[2].frames;
  frames[0].gasUsed = '0xffffffffffffffff';
  frames[1].status = 'revert'; frames[1].result = 'Revert';
  frames[1].output = { hex: '0x4e487b71' + '11'.padStart(64, '0'), length: 36, truncated: false };
  frames[3].status = 'future-status';
  const m = buildQuoteModels(q)[0];
  assert.equal(m.nodes[0].gasUsed, '18446744073709551615');
  assert.equal(m.nodes[1].ret.reason, 'Panic(0x11)');
  assert.equal(m.nodes[2].failed, false); assert.equal(m.nodes[2].reverted, true);
  assert.equal(m.nodes[3].ret.status, 'unknown');
  assert.ok(m.unresolved.some(i => i.code === 'unknown-frame-status'));
});

test('imported quote metadata cannot escape the HTML data script', () => {
  const q = quoteFixture(); traceOf(q).runs[2].phase = '</script><script>alert(1)</script>';
  const html = renderFlowHtml(buildQuoteModels(q).map(model => ({ model })));
  assert.ok(!html.includes('<script>alert(1)'));
  assert.ok(!/__FLOW_(DATA|CONFIG|SCRIPT)__/.test(html));
});

test('CLI imports both quote JSON shapes offline and renders all runs', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'quote-flow-'));
  try {
    for (const envelope of [false, true]) {
      const q = quoteFixture(), input = path.join(dir, 'quote.json'), output = path.join(dir, 'quote.html');
      fs.writeFileSync(input, JSON.stringify(envelope ? { jsonrpc: '2.0', result: q } : q));
      const run = spawnSync(process.execPath, [new URL('../flow/render-flow.mjs', import.meta.url).pathname, input, '-o', output], { encoding: 'utf8', env: { ...process.env, DEVNET_ENV: '/nonexistent' } });
      assert.equal(run.status, 0, run.stderr);
      const html = fs.readFileSync(output, 'utf8');
      const data = JSON.parse(html.match(/id="flow-data">([\s\S]*?)<\/script>/)[1]);
      assert.equal(data.length, 3); assert.equal(data[0].model.simulation.runId, 2);
      assert.ok(data.every(t => t.model.mode === 'simulation'));
      assert.match(run.stdout, /Simulation.*4 frames/);
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
