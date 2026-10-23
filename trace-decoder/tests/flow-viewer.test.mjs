// Runs the real page script against a minimal stub DOM and checks what it draws:
// layout geometry, contract tags and the checkboxes. No browser needed.
import assert from 'node:assert/strict';
import test from 'node:test';
import { decodeCrossChainTrace } from '../src/engine.mjs';
import { buildFlowModel } from '../flow/model.mjs';
import { renderFlowHtml } from '../flow/render-flow.mjs';
import { buildQuoteModels } from '../flow/quote-model.mjs';
import { quoteFixture } from './fixtures/quote.mjs';
import { buildSamples } from '../samples/build-samples.mjs';
import { scenario, hash, address, frame } from './fixtures/scenarios.mjs';

const plain = v => JSON.parse(JSON.stringify(v, (_, x) => typeof x === 'bigint' ? x.toString() : x));

function page(html) {
  const data = html.match(/id="flow-data">([\s\S]*?)<\/script>/)[1];
  const cfg = html.match(/id="flow-config">([\s\S]*?)<\/script>/)[1];
  const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1];
  const tabs = ['flow', 'flame', 'layers', 'sequence', 'timeline'].map(view => ({ dataset: { view }, hidden: false, setAttribute() {} }));
  const els = {}, listeners = new Map();
  const el = id => els[id] || (els[id] = { id, innerHTML: '', textContent: id === 'flow-data' ? data : id === 'flow-config' ? cfg : '', hidden: false, checked: false, value: '',
    style: { setProperty() {} }, dataset: {}, clientWidth: 1100, clientHeight: 700, scrollTop: 0, scrollLeft: 0, offsetTop: 0, offsetLeft: 0,
    setAttribute() {}, getAttribute() {}, insertAdjacentHTML() {}, addEventListener() {}, querySelector() { return null; }, querySelectorAll() { return []; }, scrollTo() {} });
  const sandbox = {
    document: { getElementById: el, addEventListener: (event, handler) => listeners.set(event, handler), querySelector() { return null; }, querySelectorAll: s => s === '.view-tab' ? tabs : [] },
    addEventListener() {}, matchMedia: () => ({ matches: false }), requestAnimationFrame: () => 0, cancelAnimationFrame() {},
    localStorage: { getItem: () => null, setItem() {} }, navigator: {}, FileReader: class { readAsText(file) { this.result = file.content; this.onload(); } },
  };
  new Function(...Object.keys(sandbox), script)(...Object.values(sandbox));
  return { el, token: (id, index = 0) => listeners.get('click')({ target: { closest: selector => selector === '[data-token-note]' ? { dataset: { tokenNote: `${id}:${index}` } } : null } }), tab: v => tabs.find(t => t.dataset.view === v).onclick(), trace: i => el('trace-select').onchange({ target: { value: String(i) } }) };
}

// Boxes never overlap, no line crosses a box, every call arrow points right.
function geometry(html) {
  const boxes = [...html.matchAll(/<(?:button|div) [^>]*class="box big (?:flow|eoa)[^"]*"[^>]*style="left:([\d.-]+)px;top:([\d.-]+)px;width:([\d.]+)px;height:([\d.]+)px/g)]
    .map(m => ({ x: +m[1], y: +m[2], w: +m[3], h: +m[4] }));
  const overlap = (a, b) => a.x < b.x + b.w - 1 && b.x < a.x + a.w - 1 && a.y < b.y + b.h - 1 && b.y < a.y + a.h - 1;
  const problems = [];
  boxes.forEach((a, i) => boxes.slice(i + 1).forEach(b => overlap(a, b) && problems.push('box overlap')));
  for (const [, d] of html.matchAll(/<path class="edge[^"]*" d="([^"]+)"/g)) {
    const n = d.replace(/[MLQ]/g, ' ').trim().split(/\s+/).map(Number), pts = [];
    for (let i = 0; i < n.length; i += 2) pts.push([n[i], n[i + 1]]);
    if (pts.at(-1)[0] <= pts[0][0]) problems.push('leftward arrow');
    for (let i = 1; i < pts.length; i++) for (let s = 0; s <= 1; s += 0.02) {
      const x = pts[i - 1][0] + (pts[i][0] - pts[i - 1][0]) * s, y = pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * s;
      if (boxes.some(b => x > b.x + 3 && x < b.x + b.w - 3 && y > b.y + 3 && y < b.y + b.h - 3)) { problems.push('line through box'); break; }
    }
  }
  return { boxes: boxes.length, problems };
}

const samples = (async () => (await buildSamples()).map(({ label, trace }) => ({ label, model: buildFlowModel(plain(trace)) })))();

test('call flow: no overlaps, arrows point right, one tag per contract', async () => {
  const p = page(renderFlowHtml(await samples, { views: ['flow', 'sequence'] }));
  const list = await samples;
  for (const [i, s] of list.entries()) for (const unfold of [false, true]) {
    p.trace(i);
    if (unfold) for (let k = 0; k < 250; k++) p.el('next').onclick();
    const html = p.el('graph').innerHTML, g = geometry(html);
    assert.deepEqual(g.problems, [], `${s.label}${unfold ? ' (unfolded)' : ''}`);
    assert.ok(g.boxes > 1, s.label);
    const names = new Map();
    for (const [, cid, name] of html.matchAll(/data-cid="(\d+)"[^>]*title="\d+\. ([^.]+)\./g)) {
      assert.ok(!names.has(cid) || names.get(cid) === name, `tag ${cid} names one contract in ${s.label}`);
      names.set(cid, name);
    }
  }
});

test('view calls are hidden by default and the checkbox adds exactly the announced number', async () => {
  const p = page(renderFlowHtml(await samples, { views: ['flow'] }));
  p.trace(1); // nested deposit: has balanceOf / getReserves / latestAnswer
  const count = () => (p.el('graph').innerHTML.match(/class="box big flow/g) || []).length;
  const hidden = Number(/\((\d+) hidden\)/.exec(p.el('opt-static-label').textContent)?.[1] || 0);
  assert.ok(hidden > 0);
  const before = count();
  p.el('opt-static').checked = true; p.el('opt-static').onchange();
  assert.equal(count() - before, hidden);
  assert.equal(p.el('opt-static-label').textContent, 'Local reads');
});

test('table loads appear only with EEZ plumbing, with the decoded execution table', async () => {
  const f = scenario({ direction: 'L2' });
  const model = buildFlowModel(plain(await decodeCrossChainTrace(f.config, f.trigger)));
  const p = page(renderFlowHtml([{ model }], { views: ['flow'] }));
  assert.ok(!/Execution table load/.test(p.el('root-select').innerHTML));
  p.el('opt-protocol').checked = true; p.el('opt-protocol').onchange();
  assert.match(p.el('root-select').innerHTML, /Execution table load/);
  const index = model.roots.findIndex(r => r.role === 'table-load');
  p.el('root-select').onchange({ target: { value: String(index) } });
  p.el('next').onclick(); // first step selects the loadExecutionTable call
  const inspector = p.el('inspector').innerHTML;
  assert.match(inspector, /Execution table · 1 entry/);
  assert.match(inspector, /Entry #0/);
  assert.match(inspector, /shown decoded below/);
});

test('EEZ plumbing adds the settlement batch and table load to the transaction list', async () => {
  for (const direction of ['L1', 'L2']) {
    const f = scenario({ direction, deep: direction === 'L1' });
    const model = buildFlowModel(plain(await decodeCrossChainTrace(f.config, f.trigger)));
    const p = page(renderFlowHtml([{ model }], { views: ['flow'] }));
    const list = () => p.el('root-select').innerHTML;
    assert.doesNotMatch(list(), /label="EEZ plumbing"/, `${direction}: plumbing hidden by default`);
    assert.match(list(), /Trigger/);
    p.el('opt-protocol').checked = true; p.el('opt-protocol').onchange();
    assert.match(list(), /label="EEZ plumbing">.*Settlement batch/s, direction);
    if (direction === 'L2') assert.match(list(), /Execution table load/);
    // Still one transaction on the canvas: one sender box.
    assert.equal((p.el('graph').innerHTML.match(/class="box big eoa/g) || []).length, 1);
    assert.deepEqual(geometry(p.el('graph').innerHTML).problems, [], direction);
  }
});

test('a local L2 transaction exposes its L1 settlement without inventing a crossing', async () => {
  const f = scenario({ direction: 'L2' });
  const trigger = f.txs.L2.get(f.trigger);
  trigger.trace.calls = []; trigger.receipt.logs = [];
  const model = buildFlowModel(plain(await decodeCrossChainTrace(f.config, f.trigger)));
  assert.equal(model.stats.crossings, 0);
  const settlement = model.transactions.find(t => t.hash === f.posting);
  assert.equal(settlement.relatedSettlement, true);
  assert.equal(settlement.inFlow, false, 'settlement inclusion is not a call edge');
  const p = page(renderFlowHtml([{ model }], { views: ['flow', 'sequence'] }));
  assert.match(p.el('root-select').innerHTML, /label="L1 settlement">.*Settlement batch/s);
  assert.match(p.el('notice').innerHTML, /Choose the L1 settlement/);
  assert.equal(p.el('root-wrap').hidden, false);
  const index = model.roots.findIndex(r => r.relatedSettlement);
  p.el('root-select').onchange({ target: { value: String(index) } });
  assert.equal(p.el('opt-protocol').checked, true);
  assert.match(p.el('graph').innerHTML, /postAndVerifyBatch/);
  assert.deepEqual(geometry(p.el('graph').innerHTML).problems, []);
  p.tab('sequence'); assert.match(p.el('graph').innerHTML, /postAndVerifyBatch/);
});

test('the sequence and timeline views render every sample', async () => {
  const p = page(renderFlowHtml(await samples, { views: ['flow', 'flame', 'layers', 'sequence', 'timeline'] }));
  for (const i of (await samples).keys()) {
    p.trace(i);
    p.tab('sequence'); assert.ok(/class="lbl seq/.test(p.el('graph').innerHTML));
    p.tab('layers'); assert.ok(/class="box big/.test(p.el('graph').innerHTML));
    p.tab('timeline'); assert.ok(/class="card/.test(p.el('canvas').innerHTML));
    p.tab('flow');
  }
});


test('the viewer selects a requested plain transfer over another same-block trigger', async () => {
  const f = scenario(), block = f.blocks.L1.get(100), txHash = hash('plain transfer');
  const transaction = { hash: txHash, from: address(81), to: address(82), input: '0x', blockNumber: block.number, blockHash: block.hash, transactionIndex: '0x2', value: '0x1' };
  f.txs.L1.set(txHash, { transaction, receipt: { transactionHash: txHash, blockNumber: block.number, blockHash: block.hash, transactionIndex: '0x2', status: '0x1', logs: [] }, trace: frame(transaction.from, transaction.to) });
  block.transactions.push(transaction);
  const model = buildFlowModel(plain(await decodeCrossChainTrace(f.config, txHash)));
  const p = page(renderFlowHtml([{ model }], { views: ['flow', 'sequence'] }));
  assert.equal(model.roots[Number(p.el('root-select').value)].tx, txHash);
  assert.match(model.label, /receive/);
  assert.equal(model.stats.crossings, 0);
  assert.equal(model.transactions.find(t => t.hash === f.trigger).inFlow, false);
  assert.ok(!p.el('notice').innerHTML.includes('flow starts in'));
});


test('enabling plumbing selects a related root when the default selection was empty', async () => {
  const f = scenario({ direction: 'L2' }); f.failure.allTrace.add(f.trigger);
  const model = buildFlowModel(plain(await decodeCrossChainTrace(f.config, f.trigger)));
  const post = model.transactions.find(t => t.hash === f.posting); post.inFlow = true;
  // A mixed set of roots hides plumbing by default; the remaining application
  // root is unrelated and must not be chosen to fill an empty selection.
  const unrelatedHash = hash('unrelated-viewer-root');
  model.roots.push({ ...model.roots[0], tx: unrelatedHash, role: 'other', inFlow: false, isOrigin: false });
  model.transactions.push({ chain: 'L1', hash: unrelatedHash, role: 'other', inFlow: false, evidence: [], traced: true });
  const p = page(renderFlowHtml([{ model }], { views: ['flow'] }));
  assert.equal(p.el('root-select').value, '-1');
  p.el('opt-protocol').checked = true; p.el('opt-protocol').onchange();
  assert.equal(model.roots[Number(p.el('root-select').value)].tx, f.posting);
});


test('verified links show both recorded traces and prepared responses, with isolated entry selectable', async () => {
  const f = scenario({ direction: 'L2', isStatic: true });
  const trace = plain(await decodeCrossChainTrace(f.config, f.trigger));
  const host = trace.frames.find(f => f.chain === 'L1' && f.role === 'incoming-proxy');
  trace.transactionLinks = [{ state: 'complete', sourceChain: 'L2', sourceHash: f.trigger,
    references: [
      { chain: 'L1', hash: f.posting, role: 'l1-post-batch' },
      { chain: 'L2', hash: f.trigger, role: 'source' },
    ], l1Execution: { frameId: host.id, entryIndex: 0 } }];
  const model = buildFlowModel(trace, { mode: 'physical' }), p = page(renderFlowHtml([{ model }], { views: ['flow', 'sequence'] }));
  assert.equal(p.el('root-select').value, '-2');
  assert.match(p.el('notice').innerHTML, /own recorded order/);
  assert.match(p.el('graph').innerHTML, /Prepared L2 table response/);
  assert.equal((p.el('graph').innerHTML.match(/class="box big eoa/g) || []).length, 2);
  assert.deepEqual(geometry(p.el('graph').innerHTML).problems, []);
  p.tab('sequence');
  assert.match(p.el('graph').innerHTML, /class="lbl seq/);
  p.tab('flow');
  p.el('opt-protocol').checked = true; p.el('opt-protocol').onchange();
  assert.equal(p.el('root-select').value, '-2');
  assert.deepEqual(geometry(p.el('graph').innerHTML).problems, []);
  p.el('opt-protocol').checked = false; p.el('opt-protocol').onchange();
  const index = model.roots.findIndex(r => r.preferred);
  p.el('root-select').onchange({ target: { value: String(index) } });
  const selected = model.roots[index];
  assert.equal(selected.preferred, true);
  assert.equal(model.nodes[selected.node].frameId, host.id);
  assert.equal(p.el('opt-static').checked, true);
  assert.match(p.el('notice').innerHTML, /recorded L1 execution/);
  assert.ok(!p.el('stats').innerHTML.includes('crossings matched'));
  assert.ok(!model.nodes.some(n => n.kind === 'ghost'));
  assert.ok(model.roots.some(r => r.isOrigin && r.chain === 'L2'));
  for (const r of model.roots) {
    const seen = [], walk = id => { seen.push(model.nodes[id]); model.nodes[id].children.forEach(walk); }; walk(r.node);
    assert.ok(seen.every(n => n.chain === r.chain), 'physical views never move calls across chains');
  }
  p.tab('sequence');
  assert.ok(p.el('graph').innerHTML.length > 0);
});


test('timeline renders prepared results as labels without corrupting status markers', async () => {
  const f = scenario({ isStatic: true }); f.txs.L2.get(f.deliveries[0]).trace.calls = [];
  const model = buildFlowModel(plain(await decodeCrossChainTrace(f.config, f.trigger)));
  const p = page(renderFlowHtml([{ model }], { views: ['flow', 'timeline'] }));
  p.el('opt-static').checked = true; p.el('opt-static').onchange();
  p.el('expand-all').onclick(); p.tab('timeline');
  const html = p.el('canvas').innerHTML;
  assert.match(html, /prepared result · no L2 delivery/);
  assert.ok(!html.includes('c-status <'));
});


test('prepared response labels preserve local results and rollback status', async () => {
  const f = scenario({ direction: 'L2' });
  const trace = plain(await decodeCrossChainTrace(f.config, f.trigger));
  trace.transactionLinks = [{ state: 'complete', sourceChain: 'L2', sourceHash: f.trigger,
    references: [{ chain: 'L2', hash: f.trigger, role: 'source' }] }];
  const out = trace.outgoing.find(o => o.chain === 'L2'), local = trace.frames.find(f => f.id === out.frameId);
  local.reverted = true;
  out.remoteCall = { contractName: 'Remote', functionName: 'read', signature: 'read()', arguments: [], returns: [{ type: 'uint256', value: '999' }], rawOutput: '0xdead' };
  out.localResponse = { ...out.remoteCall, returns: [{ type: 'uint256', value: '7' }], rawOutput: local.output };
  const model = buildFlowModel(trace, { mode: 'physical' }), n = model.nodes.find(n => n.frameId === local.id);
  assert.equal(n.ret.items[0].value, '7', 'a remote association cannot replace the locally observed result');
  assert.equal(n.reverted, true); assert.equal(n.preparedResponse, true);
  assert.equal(model.stats.preparedResponses, 1);
  const p = page(renderFlowHtml([{ model }], { views: ['flow'] }));
  for (let i = 0; i < 2; i++) p.el('next').onclick();
  assert.match(p.el('inspector').innerHTML, /Rolled back by an outer revert/);
  assert.match(p.el('inspector').innerHTML, /prepared response from loaded table/);
});


test('optional notes show escaped codes and messages', async () => {
  const f = scenario(), model = buildFlowModel(plain(await decodeCrossChainTrace(f.config, f.trigger)));
  model.matchingNotes = [{ code: 'ambiguous-remote-occurrence', message: 'Repeated <calls> & returns' }];
  const p = page(renderFlowHtml([{ model }], { views: ['flow'] }));
  assert.match(p.el('inspector').innerHTML, /ambiguous-remote-occurrence/);
  assert.match(p.el('inspector').innerHTML, /Repeated &lt;calls&gt; &amp; returns/);
});

test('explicit read visibility persists when switching trace kinds', async () => {
  const f = scenario(), combined = buildFlowModel(plain(await decodeCrossChainTrace(f.config, f.trigger)));
  const physical = { ...combined, mode: 'physical' };
  const p = page(renderFlowHtml([{ model: physical }, { model: combined }], { views: ['flow'] }));
  assert.equal(p.el('opt-static').checked, true);
  p.el('opt-static').checked = true; p.el('opt-static').onchange();
  p.trace(1); assert.equal(p.el('opt-static').checked, true);
  p.el('opt-static').checked = false; p.el('opt-static').onchange();
  p.trace(0); assert.equal(p.el('opt-static').checked, false);
});


test('linked flow is the default and the recorded toggle preserves confirmed arrows and read preference', async () => {
  const f = scenario({ direction:'L2' }), trace = plain(await decodeCrossChainTrace(f.config,f.trigger));
  const host = trace.frames.find(n=>n.chain==='L1'&&n.role==='incoming-proxy');
  trace.transactionLinks = [{state:'complete',sourceChain:'L2',sourceHash:f.trigger,
    references:[{chain:'L1',hash:f.posting,role:'l1-post-batch'},{chain:'L2',hash:f.trigger,role:'source'}],
    l1Execution:{frameId:host.id,entryIndex:0}}];
  const model = buildFlowModel(trace), p = page(renderFlowHtml([{model}], {views:['flow','sequence','layers']}));
  assert.equal(p.el('mode-select').value,'combined');
  assert.equal(p.el('mode-wrap').hidden,false);
  assert.match(p.el('graph').innerHTML,/class="edge cross/);
  p.el('opt-static').checked=true;p.el('opt-static').onchange();
  p.el('mode-select').onchange({target:{value:'physical'}});
  assert.equal(p.el('root-select').value,'-2');
  assert.equal(p.el('opt-static').checked,true);
  assert.doesNotMatch(p.el('graph').innerHTML,/class="edge cross/);
  assert.deepEqual(geometry(p.el('graph').innerHTML).problems,[]);
  const html=p.el('graph').innerHTML;
  let checkedHeights = 0;
  for (const n of model.recordedView.nodes.filter(n=>!n.protocol)) {
    const match=html.match(new RegExp(`data-node="${n.id}"[^>]*height:([0-9]+)px`));
    if(match) { checkedHeights++; assert.equal(Number(match[1]),n.preparedResponse?156:116); }
  }
  assert.ok(checkedHeights >= 2, 'both prepared and ordinary boxes are checked');
  assert.match(p.el('caption').innerHTML,/independently on each chain/);
  p.tab('sequence'); assert.match(p.el('graph').innerHTML,/class="lbl seq/);
  p.tab('layers'); assert.doesNotMatch(p.el('graph').innerHTML,/class="edge cross/);
  p.el('opt-static').checked=false;p.el('opt-static').onchange();
  p.el('mode-select').onchange({target:{value:'combined'}});
  assert.equal(p.el('opt-static').checked,false);
  p.tab('flow');assert.match(p.el('graph').innerHTML,/class="edge cross/);
});

test('an unisolated L1 entry is explained and its full batch remains selectable', async () => {
  const f=scenario({direction:'L2'}),trace=plain(await decodeCrossChainTrace(f.config,f.trigger));
  trace.transactionLinks=[{state:'complete',sourceChain:'L2',sourceHash:f.trigger,
    references:[{chain:'L1',hash:f.posting,role:'l1-post-batch'},{chain:'L2',hash:f.trigger,role:'source'}]}];
  const p=page(renderFlowHtml([{model:buildFlowModel(trace)}],{views:['flow']}));
  p.el('mode-select').onchange({target:{value:'physical'}});
  assert.match(p.el('notice').innerHTML,/could not be isolated/);
  assert.match(p.el('root-select').innerHTML,/Settlement batch/);
  assert.ok(!p.el('root-select').innerHTML.includes('Both chains'));
});


test('system ETH transfers are folded with plumbing and remain inspectable', async () => {
  const f=scenario({direction:'L2'}),trace=plain(await decodeCrossChainTrace(f.config,f.trigger));
  const model=buildFlowModel(trace),root=model.roots.find(r=>r.isOrigin);
  const id=model.nodes.length;
  model.nodes.push({...model.nodes[root.node],id,frameId:'system-transfer',role:'system-value-transfer',
    contract:'L2 system',fn:'Value to L2 system',protocol:true,children:[],address:address(700)});
  model.nodes[root.node].children.push(id);
  const p=page(renderFlowHtml([{model}],{views:['flow']}));
  assert.doesNotMatch(p.el('graph').innerHTML,/Value to L2 system/);
  p.el('opt-protocol').checked=true;p.el('opt-protocol').onchange();
  assert.match(p.el('graph').innerHTML,/Value to L2 system/);
  assert.deepEqual(geometry(p.el('graph').innerHTML).problems,[]);
});


for (const direction of ['L1','L2']) test(`${direction} linked arrows hide EEZ markers until plumbing is enabled`, async () => {
  const f=scenario({direction}),model=buildFlowModel(plain(await decodeCrossChainTrace(f.config,f.trigger)));
  const p=page(renderFlowHtml([{model}],{views:['flow','sequence','layers']}));
  for (const view of ['flow','sequence','layers']) {
    p.tab(view);
    assert.match(p.el('graph').innerHTML,/class="edge cross/,`${view}: matched arrow remains visible`);
    assert.doesNotMatch(p.el('graph').innerHTML,/class="eez(?: |")/,`${view}: no plumbing marker`);
    p.el('opt-protocol').checked=true;p.el('opt-protocol').onchange();
    assert.match(p.el('graph').innerHTML,/class="eez(?: |")/,`${view}: plumbing marker can be inspected`);
    p.el('opt-protocol').checked=false;p.el('opt-protocol').onchange();
    assert.doesNotMatch(p.el('graph').innerHTML,/class="eez(?: |")/);
  }
});


for(const direction of ['L1','L2'])test(`${direction} cross-chain reads and their details remain visible without plumbing`,async()=>{
  const f=scenario({direction,isStatic:true}),trace=plain(await decodeCrossChainTrace(f.config,f.trigger));
  const model=buildFlowModel(trace),p=page(renderFlowHtml([{model}],{views:['flow','sequence']}));
  assert.equal(p.el('opt-static').checked,false);
  assert.equal(p.el('opt-protocol').checked,false);
  assert.match(p.el('graph').innerHTML,/class="edge cross/);
  assert.doesNotMatch(p.el('graph').innerHTML,/class="eez(?: |")/);
  for(let i=0;i<2;i++)p.el('next').onclick();
  assert.match(p.el('inspector').innerHTML,/Crossing L[12] → L[12]/);
  p.tab('sequence');assert.match(p.el('graph').innerHTML,/class="edge cross/);
});


test('per-chain gas totals and their breakdown stay fixed across visibility and trace modes', async () => {
  const f = scenario({ deep: true });
  const trace = plain(await decodeCrossChainTrace(f.config, f.trigger));
  for (const t of trace.transactions) t.receipt.gasUsed = t.chain === 'L1' ? '123456' : '654321';
  trace.transactionLinks = [{ state: 'complete', sourceChain: 'L1', sourceHash: f.trigger,
    references: trace.transactions.map(t => ({ chain: t.chain, hash: t.hash,
      role: t.hash === f.trigger ? 'source' : t.chain === 'L1' ? 'l1-post-batch' : 'l2-delivery' })) }];
  const p = page(renderFlowHtml([{ model: buildFlowModel(trace) }]));
  const before = p.el('gas-summary').innerHTML;
  assert.match(before, /L1 flow gas.*123,456/s);
  assert.match(before, /L2 flow gas.*654,321/s);
  assert.match(before, /Includes EEZ plumbing/);
  assert.match(before, /Whole related transactions: L1 <b>246,912/);
  for (const id of ['opt-protocol', 'opt-static']) {
    p.el(id).checked = true; p.el(id).onchange();
    assert.equal(p.el('gas-summary').innerHTML, before);
  }
  p.el('mode-select').onchange({ target: { value: 'physical' } });
  assert.equal(p.el('gas-summary').innerHTML, before);
});


test('debug quotes render both chains as simulation in every view and keep runs selectable', () => {
  const models = buildQuoteModels(quoteFixture());
  const p = page(renderFlowHtml(models.map(model => ({ model })), { views: ['flow', 'flame', 'layers', 'sequence', 'timeline'] }));
  assert.match(p.el('kicker').textContent, /SIMULATION/);
  assert.match(p.el('notice').innerHTML, /not evidence of mining/);
  assert.match(p.el('stats').innerHTML, /simulated crossings/);
  assert.doesNotMatch(p.el('stats').innerHTML, /crossings matched|physical frames|transactions/);
  assert.match(p.el('inspector').innerHTML, /Quote option/);
  assert.match(p.el('verify').innerHTML, /Contracts in this simulation/);
  assert.doesNotMatch(p.el('verify').innerHTML, /\/tx\//);
  for (let i = 0; i < models.length; i++) {
    p.trace(i);
    for (const view of ['flow', 'flame', 'layers', 'sequence', 'timeline']) {
      p.tab(view);
      assert.ok((view === 'timeline' ? p.el('canvas') : p.el('graph')).innerHTML.length > 0);
    }
  }
  p.trace(0); p.tab('flow');
  p.el('next').onclick();
  assert.match(p.el('inspector').innerHTML, /Simulation frame/);
  assert.doesNotMatch(p.el('inspector').innerHTML, /No physical frame|Transaction on explorer/);
  assert.deepEqual(geometry(p.el('graph').innerHTML).problems, []);
});

test('browser file import accepts a raw debug-quote envelope and selects final composition', async () => {
  const p = page(renderFlowHtml(await samples, { views: ['flow', 'sequence'] }));
  p.el('file').onchange({ target: { files: [{ name: 'quote.json', content: JSON.stringify({ result: quoteFixture() }) }] } });
  assert.match(p.el('kicker').textContent, /SIMULATION/);
  assert.match(p.el('title').textContent, /final_validation.*run 2/);
  assert.match(p.el('stats').innerHTML, /3<\/b> simulation runs/);
});


test('experimental token notes expand call boxes without overlap and toggle off cleanly', async () => {
  const list = plain(await samples);
  for (const { model } of list) for (const n of model.nodes) if (!n.protocol && n.kind !== 'ghost') {
    n.tokenTransfers = ['transfer', 'mint', 'burn'].map(kind => ({ kind, token: address(900), from: address(901), to: address(902), symbol: '<WETH>', decimals: 18, amount: '1000000000000000' }));
  }
  const p = page(renderFlowHtml(list, { views: ['flow', 'sequence'] }));
  for (let i = 0; i < list.length; i++) {
    p.trace(i);
    assert.match(p.el('graph').innerHTML, /token-note transfer/);
    assert.match(p.el('graph').innerHTML, /0\.001/);
    assert.match(p.el('graph').innerHTML, /&lt;WETH&gt;/);
    assert.doesNotMatch(p.el('graph').innerHTML, /<WETH>/);
    assert.match(p.el('graph').innerHTML, /\+1 more/);
    assert.deepEqual(geometry(p.el('graph').innerHTML).problems, []);
  }
  p.el('opt-tokens').checked = false; p.el('opt-tokens').onchange();
  assert.doesNotMatch(p.el('graph').innerHTML, /class="token-note/);
  assert.deepEqual(geometry(p.el('graph').innerHTML).problems, []);
  p.el('opt-tokens').checked = true; p.el('opt-tokens').onchange();
  assert.match(p.el('graph').innerHTML, /class="token-note/);
  p.tab('sequence'); assert.equal(p.el('opt-tokens-wrap').hidden, true);
  p.tab('flow'); assert.equal(p.el('opt-tokens-wrap').hidden, false);
});

test('token notes preserve large integer amounts and disclose unknown decimals', async () => {
  const model = plain((await samples)[0].model);
  for (const n of model.nodes) if (!n.protocol) n.tokenTransfers = [{ kind: 'transfer', token: address(900), from: address(901), to: address(902), symbol: null, decimals: null, amount: '123456789012345678901234567890' }];
  const p = page(renderFlowHtml([{ model }], { views: ['flow'] }));
  assert.match(p.el('graph').innerHTML, /123456789012345678901234567890 raw units/);
});


test('token parties use contract names on the same chain and retain the full address', async () => {
  const model = plain((await samples)[0].model);
  const node = model.nodes.find(n => !n.protocol && n.kind !== 'ghost' && n.inFlow !== false);
  const from = address(950), to = address(951);
  model.nodes.push({ ...node, id: model.nodes.length, address: from, impl: null, contract: 'Known sender', children: [] });
  model.nodes.push({ ...node, id: model.nodes.length, chain: node.chain === 'L1' ? 'L2' : 'L1', address: to, impl: null, contract: 'Other chain recipient', children: [] });
  node.tokenTransfers = [{ kind: 'transfer', token: node.address, from, to, symbol: 'TEST', decimals: 0, amount: '10' }];
  const p = page(renderFlowHtml([{ model }], { views: ['flow'] }));
  assert.doesNotMatch(p.el('graph').innerHTML, /token-detail-field/);
  p.token(node.id);
  const note = p.el('inspector').innerHTML;
  assert.match(note, /Known sender/);
  assert.doesNotMatch(note, /Other chain recipient/);
  assert.ok(note.includes(from)); assert.ok(note.includes(to));
  const fields = [...note.matchAll(/class="f-label">([^<]+)</g)].map(m => m[1]);
  assert.deepEqual(fields, ['Token', 'From', 'To', 'Amount']);
  assert.match(note, /Back to call details/);
  assert.doesNotMatch(p.el('graph').innerHTML, /token-detail-field/);
});


test('unknown quote statuses remain unknown in the inspector and every diagram', () => {
  for (const status of ['future-status', null, undefined]) {
    const quote = quoteFixture();
    quote.diagnostics.trace.runs[2].frames[0].status = status;
    const p = page(renderFlowHtml(buildQuoteModels(quote).map(model => ({ model }))));
    for (const view of ['flow', 'flame', 'layers', 'sequence', 'timeline']) {
      p.tab(view);
      p.el('next').onclick();
      assert.match(p.el('inspector').innerHTML, /class="badge warn">Unknown simulation status/);
      assert.match(p.el('inspector').innerHTML, /Success or failure could not be determined/);
      assert.doesNotMatch(p.el('inspector').innerHTML, /Simulation succeeded|No unique remote execution/);
      if (view === 'timeline') {
        assert.match(p.el('canvas').innerHTML, /class="c-status warn" aria-label="Unknown simulation status">\?<\/span>/);
      } else {
        assert.match(p.el('graph').innerHTML, /Unknown simulation status/);
      }
    }
  }
  const p = page(renderFlowHtml(buildQuoteModels(quoteFixture()).map(model => ({ model }))));
  p.el('next').onclick();
  assert.match(p.el('inspector').innerHTML, /class="badge ok">Simulation succeeded/);
});

test('crowded flame charts reserve space for every sibling at narrow and wide viewport sizes', () => {
  const quote = quoteFixture(), run = quote.diagnostics.trace.runs[2];
  run.frames = [run.frames[0], ...Array.from({ length: 400 }, (_, i) => ({
    ...structuredClone(run.frames[1]), id: i + 1, parentId: 0,
  }))];
  const p = page(renderFlowHtml(buildQuoteModels(quote).map(model => ({ model }))));
  for (const viewport of [640, 1100]) {
    p.el('graph-wrap').clientWidth = viewport;
    p.tab('flame');
    const bars = [...p.el('graph').innerHTML.matchAll(/class="fbar [^"]*" data-node="(\d+)" style="left:([\d.]+)px;top:([\d.]+)px;width:([\d.]+)px/g)]
      .map(m => ({ id: +m[1], x: +m[2], y: +m[3], width: +m[4] }));
    assert.equal(bars.length, 401, 'all calls remain independently selectable');
    const parent = bars.find(b => b.id === 0), siblings = bars.filter(b => b.id !== 0);
    siblings.forEach((bar, i) => {
      assert.ok(bar.width >= 8, 'bar accommodates its padding and borders');
      assert.ok(bar.x >= parent.x && bar.x + bar.width <= parent.x + parent.width, 'child stays inside parent span');
      if (i) {
        assert.equal(bar.y, siblings[i - 1].y);
        assert.ok(siblings[i - 1].x + siblings[i - 1].width < bar.x, 'siblings have a gap instead of overlapping');
      }
    });
    assert.ok(parseFloat(p.el('graph-size').style.width) > viewport, 'crowded chart can scroll even at fit zoom');
  }
});
