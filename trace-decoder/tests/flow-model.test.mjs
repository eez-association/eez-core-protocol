import assert from 'node:assert/strict';
import test from 'node:test';
import { decodeCrossChainTrace } from '../src/engine.mjs';
import { buildFlowModel, explorerSite, standardRevert } from '../flow/model.mjs';
import { renderFlowHtml } from '../flow/render-flow.mjs';
import { scenario, address } from './fixtures/scenarios.mjs';
import { largeTrace } from './fixtures/large-trace.mjs';

const plain = value => JSON.parse(JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v));
const decode = async (opts = {}, edit) => {
  const f = scenario(opts);
  edit?.(f);
  return { f, trace: plain(await decodeCrossChainTrace(f.config, f.trigger)) };
};
const byRole = (model, role) => model.transactions.filter(t => t.role === role);

test('an L1-started flow: trigger first, settlement and delivery linked', async () => {
  const { f, trace } = await decode({ deep: true });
  const m = buildFlowModel(trace);
  assert.equal(m.transactions[0].role, 'trigger');
  assert.equal(m.transactions[0].hash, f.trigger);
  assert.equal(m.transactions[0].label, 'Trigger · starts on L1');
  assert.equal(byRole(m, 'settlement').length, 1);
  assert.equal(byRole(m, 'delivery').length, 1);
  assert.ok(m.transactions.every(t => t.inFlow === true));
  assert.equal(m.roots[0].role, 'trigger');
  assert.equal(m.stats.matched, 3);
});

test('an L2-started flow is matched to the L2Tx batch entry (proxyEntryHash = 0)', async () => {
  const { f, trace } = await decode({ direction: 'L2' });
  const m = buildFlowModel(trace);
  const trigger = m.transactions[0];
  assert.equal(trigger.role, 'trigger');
  assert.equal(trigger.chain, 'L2');
  assert.equal(trigger.hash, f.trigger);
  assert.ok(trigger.evidence.some(e => /L2Tx entry #0 .*started on L2/.test(e)), trigger.evidence.join('; '));
  assert.equal(byRole(m, 'table-load').length, 1);
});

test('a transaction without cross-chain calls in the settled range is not part of the flow', async () => {
  const { trace } = await decode({ direction: 'L2' });
  const hash = '0x' + 'ab'.repeat(32), id = `L2:${hash}:0`;
  const decoded = { contractName: 'Setup', functionName: 'configure', signature: 'configure()', arguments: [], returns: [] };
  trace.transactions.push({ chain: 'L2', hash, blockNumber: 200, transactionIndex: 9, receipt: { status: '0x1' }, trace: { available: true } });
  trace.frames.push({ id, chain: 'L2', transactionHash: hash, blockNumber: 200, path: '0', parentId: null, children: [], type: 'CALL', role: 'application', from: address(98), to: address(77), input: '0x12345678', output: '0x', value: '0', decoded });
  trace.logicalNodes.push({ id, physicalFrameId: id, chain: 'L2', role: 'application', decoded, children: [], reverted: false });
  trace.logicalRoots.push(id);
  const m = buildFlowModel(trace);
  const setup = m.transactions.find(t => t.hash === hash);
  assert.equal(setup.role, 'other');
  assert.equal(setup.inFlow, false);
  assert.equal(m.transactions.at(-1).hash, hash, 'unrelated transactions are listed last');
  assert.notEqual(m.roots[0].tx, hash);
});

test('an untraced requested transaction is "unknown", never excluded or renamed', async () => {
  const { f, trace } = await decode({ direction: 'L2' }, fx => { fx.failure.transactionTrace.add(fx.trigger); fx.failure.allTrace.add(fx.trigger); });
  const m = buildFlowModel(trace);
  const requested = m.transactions.find(t => t.hash === f.trigger);
  assert.equal(requested.role, 'untraced');
  assert.equal(requested.inFlow, null);
  assert.match(m.label, /^Untraced L2 transaction/);
});

test('explorer links keep only scheme, host and path', () => {
  assert.equal(explorerSite('https://user:pw@scan.example/api/v2?apikey=SECRET#x'), 'https://scan.example');
  assert.equal(explorerSite('https://scan.example/explorer/api'), 'https://scan.example/explorer');
  assert.equal(explorerSite('https://api.etherscan.io/v2/api?chainid=1&apikey=SECRET'), null);
  assert.equal(explorerSite('javascript:alert(1)'), null);
});

test('compiler-level reverts are decoded', () => {
  const reason = '0x08c379a0' + '0000000000000000000000000000000000000000000000000000000000000020'
    + '0000000000000000000000000000000000000000000000000000000000000006' + Buffer.from('LOCKED').toString('hex').padEnd(64, '0');
  assert.equal(standardRevert(reason), 'Error("LOCKED")');
  assert.equal(standardRevert('0x4e487b71' + '11'.padStart(64, '0')), 'Panic(0x11)');
  assert.equal(standardRevert('0xdeadbeef'), null);
});

test('the page escapes embedded data and carries the chosen views', async () => {
  const { trace } = await decode();
  const m = buildFlowModel(trace, { label: '</script><script>alert(1)</script>' });
  const html = renderFlowHtml([{ model: m }], { views: ['flow', 'sequence'] });
  assert.ok(!html.includes('<script>alert(1)'));
  assert.ok(!/__FLOW_(DATA|CONFIG|SCRIPT)__/.test(html));
  assert.match(html, /id="flow-config">\{"views":\["flow","sequence"\]\}/);
  assert.match(html, /\[hidden\]\{display:none!important\}/);
});

test('render-flow refuses a trace with an untraced transaction unless --allow-partial', async () => {
  const { spawnSync } = await import('node:child_process');
  const fs = await import('node:fs'), os = await import('node:os'), path = await import('node:path');
  const { trace } = await decode({ direction: 'L2' }, fx => { fx.failure.transactionTrace.add(fx.posting); fx.failure.allTrace.add(fx.posting); });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'flow-')), input = path.join(dir, 'trace.json'), out = path.join(dir, 'page.html');
  fs.writeFileSync(input, JSON.stringify(trace));
  const cli = new URL('../flow/render-flow.mjs', import.meta.url).pathname;
  try {
    const refused = spawnSync(process.execPath, [cli, input, '-o', out], { encoding: 'utf8' });
    assert.equal(refused.status, 1);
    assert.match(refused.stderr, /No call trace for 1 transaction[\s\S]*L1_TRACE_RPC/);
    assert.ok(!fs.existsSync(out));
    const allowed = spawnSync(process.execPath, [cli, input, '-o', out, '--allow-partial'], { encoding: 'utf8' });
    assert.equal(allowed.status, 0, allowed.stderr);
    assert.ok(fs.existsSync(out));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('a 10,000-frame trace builds quickly', async () => {
  const trace = plain(await largeTrace(10_000));
  const start = performance.now();
  const m = buildFlowModel(trace);
  assert.ok(m.nodes.length >= 10_000);
  assert.ok(performance.now() - start < 3000, `took ${Math.round(performance.now() - start)} ms`);
});
