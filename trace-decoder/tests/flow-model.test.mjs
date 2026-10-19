import assert from 'node:assert/strict';
import test from 'node:test';
import { renderTrace } from '../src/logical.mjs';
import { decodeCrossChainTrace } from '../src/engine.mjs';
import { buildFlowModel, explorerSite, standardRevert } from '../flow/model.mjs';
import { inlineModelSource, preferSavedTrace, renderFlowHtml } from '../flow/render-flow.mjs';
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


test('a requested plain L1 transfer never inherits another same-block trigger or title', async () => {
  const { trace } = await decode();
  const hash = '0x' + 'cd'.repeat(32), id = `L1:${hash}:0`;
  const decoded = { contractName: 'RequestedRecipient', functionName: 'receive', arguments: [], returns: [] };
  trace.transactions.push({ chain: 'L1', hash, blockNumber: 100, transactionIndex: 2, receipt: { status: '0x1' }, trace: { available: true } });
  trace.frames.push({ id, chain: 'L1', transactionHash: hash, path: '0', parentId: null, children: [], type: 'CALL', role: 'application', to: address(77), input: '0x', output: '0x', value: '1', decoded });
  trace.logicalNodes.push({ id, decoded, children: [] }); trace.logicalRoots.push(id);
  trace.origin = { chain: 'L1', transactionId: `L1:${hash}` }; trace.txHash = hash;
  const m = buildFlowModel(trace);
  assert.equal(m.label, 'RequestedRecipient.receive()');
  assert.equal(m.stats.crossings, 0);
  assert.equal(m.roots[0].tx, hash);
  assert.ok(m.transactions.filter(t => !t.requested).every(t => t.inFlow === false));
});

test('shared L1 posting does not connect a second trigger to the requested call tree', async () => {
  const { f, trace } = await decode({ direction: 'L2' });
  const second = '0x' + 'ef'.repeat(32), oldPrefix = `L2:${f.trigger}`, prefix = `L2:${second}`;
  const replace = x => JSON.parse(JSON.stringify(x).replaceAll(oldPrefix, prefix).replaceAll(f.trigger, second));
  trace.transactions.push({ ...replace(trace.transactions.find(t => t.hash === f.trigger)), transactionIndex: 2 });
  const copiedFrames = trace.frames.filter(f => f.id.startsWith(oldPrefix)).map(replace);
  trace.frames.push(...copiedFrames);
  // An unresolved second trigger loads the same table. That dependency must not
  // expand the requested flow to its calls, even when the call bytes are identical.
  const copiedIds = new Set(copiedFrames.map(f => f.id));
  trace.logicalNodes.push(...trace.logicalNodes.filter(n => n.id.startsWith(oldPrefix)).map(replace).map(n => ({ ...n, children: n.children.filter(id => copiedIds.has(id)) })));
  trace.logicalRoots.push(`${prefix}:0`);
  const out = replace(trace.outgoing[0]); delete out.remoteFrameId; out.status = 'unresolved'; trace.outgoing.push(out);
  trace.unresolved.push({ code: 'remote-execution-unavailable', message: 'Unrelated batch entry', frameId: out.frameId });
  const m = buildFlowModel(trace);
  assert.equal(m.transactions.find(t => t.hash === second).inFlow, false);
  assert.equal(m.roots.find(r => r.tx === second).inFlow, false);
  assert.ok(m.nodes.filter(n => n.tx === second).every(n => n.inFlow === false));
  assert.ok(!m.unresolved.some(u => u.frameId === out.frameId));
  assert.equal(m.stats.crossings, 1);
  assert.equal(m.stats.matched, 1);
});


function physicalLinks(trace) {
  trace.transactionLinks = [{ state: 'complete', sourceChain: trace.origin.chain, sourceHash: trace.txHash,
    references: trace.transactions.map(t => ({ chain: t.chain, hash: t.hash,
      role: t.hash === trace.txHash ? 'source' : t.chain === 'L1' ? 'l1-post-batch' : 'l2-delivery' })) }];
}

test('physical views keep proxy inconsistencies and missing identity unresolved', async () => {
  const { trace } = await decode(); physicalLinks(trace);
  const frameId = trace.outgoing[0].managerFrameId;
  const codes = ['proxy-forwarding-mismatch', 'proxy-identity-unavailable'];
  trace.unresolved = codes.map(code => ({ code, message: 'Cannot validate proxy request', frameId }));
  const model = buildFlowModel(trace, { mode: 'physical' });
  assert.deepEqual(model.unresolved.map(u => u.code), codes);
  assert.equal(model.matchingNotes.length, 0);
});

test('legacy prepared labels cannot hide rejected remote return values', async () => {
  const { trace } = await decode({ isStatic: true }, f => {
    f.txs.L2.get(f.deliveries[0]).trace.calls[0].calls[0].output = '0xdeadbeef';
  });
  const out = trace.outgoing[0];
  assert.ok(out.rejectedCandidates.length);
  out.resultKind = 'precomputed-result-only'; // Older decoder incorrectly used this for a mismatch.
  physicalLinks(trace);
  const model = buildFlowModel(trace, { mode: 'physical' });
  assert.ok(!model.nodes.some(n => n.preparedResult));
  assert.ok(model.unresolved.some(u => u.frameId === out.frameId));
  assert.ok(!renderTrace(trace).includes('no L2 delivery expected'));
});

test('prepared status is shared by HTML and text; unrelated errors stay unresolved', async () => {
  const { trace } = await decode({ isStatic: true }); physicalLinks(trace);
  const out = trace.outgoing[0];
  out.status = 'prepared-result'; delete out.resultKind;
  trace.unresolved = [{ code: 'receipt-unavailable', message: 'Receipt missing', frameId: out.frameId }];
  const model = buildFlowModel(trace, { mode: 'physical' });
  assert.equal(model.stats.preparedResults, 1);
  assert.equal(model.unresolved[0].code, 'receipt-unavailable');
  assert.ok(renderTrace(trace).includes('no L2 delivery expected'));
});


test('verified links default to matched cross-chain arrows with an independent recorded alternative', async () => {
  const { trace } = await decode({ deep:true }); physicalLinks(trace);
  const model = buildFlowModel(trace);
  assert.equal(model.mode,'combined'); assert.equal(model.recordedView.mode,'physical');
  assert.equal(model.nodes.filter(n=>n.crossing?.status==='matched').length,3);
  assert.ok(!model.recordedView.nodes.some(n=>n.crossing));
});

test('new complete decodes replace saved captures even when match counts drop', () => {
  const transaction = {chain:'L1',hash:'tx',blockHash:'block',blockNumber:10,transactionIndex:0,receipt:{status:1},trace:{available:true}};
  const previous = {schemaVersion:'1.0.0',transactions:[transaction],outgoing:[{status:'matched'}]};
  const current = {...previous,outgoing:[{status:'unresolved'}]};
  assert.equal(preferSavedTrace(previous,current),false);
  const incomplete = {...current,transactions:[{...transaction,trace:{available:false}}]};
  assert.equal(preferSavedTrace(previous,incomplete),true);
  assert.equal(preferSavedTrace(previous,{...incomplete,schemaVersion:'2.0.0'}),false);
  assert.equal(preferSavedTrace(previous,{...incomplete,transactions:[{...incomplete.transactions[0],hash:'other'}]}),false);
});


test('saved captures never hide changed inclusion or fresh validation failures', () => {
  const transaction={chain:'L1',hash:'tx',blockHash:'block',blockNumber:10,transactionIndex:0,receipt:{status:1},trace:{available:true}};
  const previous={schemaVersion:'1',txHash:'tx',transactions:[transaction]};
  const current={...previous,transactions:[{...transaction,trace:{available:false}}]};
  for(const mutation of [
    {transactions:[{...current.transactions[0],blockHash:'reorg'}]},
    {transactions:[{...current.transactions[0],transactionIndex:1}]},
    {transactions:[{...current.transactions[0],blockHash:null}]},
    {metadata:{transactionLinks:{state:'invalid'}}},
    {metadata:{transactionLinks:{state:'pending'}}},
    {unresolved:[{code:'invalid-transaction-links'}]},
    {unresolved:[{code:'correlation-lookup-failed'}]},
    {outgoing:[{rejectedCandidates:[{reason:'return-or-revert-mismatch'}]}]},
    {metadata:{chainIds:{L1:'different chain'}}},
  ]) assert.equal(preferSavedTrace(previous,{...current,...mutation}),false);
});

for(const quote of ["'",'"'])for(const newline of ['\n','\r\n'])test(`model inlining tolerates quote ${quote} and newline ${JSON.stringify(newline)}`,()=>{
  const code=`import { isPreparedResult } from ${quote}../src/prepared-result.mjs${quote};${newline}export const marker = 1;${newline}`;
  const inline=inlineModelSource(code);
  assert.doesNotMatch(inline,/^import/m);assert.doesNotMatch(inline,/^export/m);
  assert.equal(new Function(`${inline}; return marker;`)(),1);
});
test('model inlining rejects unbundled imports explicitly',()=>{
  assert.throws(()=>inlineModelSource('import x from "./unbundled.mjs";'),/Unbundled import/);
});
