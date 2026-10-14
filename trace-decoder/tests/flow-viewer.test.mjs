// Runs the real page script against a minimal stub DOM and checks what it draws:
// layout geometry, contract tags and the checkboxes. No browser needed.
import assert from 'node:assert/strict';
import test from 'node:test';
import { decodeCrossChainTrace } from '../src/engine.mjs';
import { buildFlowModel } from '../flow/model.mjs';
import { renderFlowHtml } from '../flow/render-flow.mjs';
import { buildSamples } from '../samples/build-samples.mjs';
import { scenario } from './fixtures/scenarios.mjs';

const plain = v => JSON.parse(JSON.stringify(v, (_, x) => typeof x === 'bigint' ? x.toString() : x));

function page(html) {
  const data = html.match(/id="flow-data">([\s\S]*?)<\/script>/)[1];
  const cfg = html.match(/id="flow-config">([\s\S]*?)<\/script>/)[1];
  const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1];
  const tabs = ['flow', 'layers', 'sequence', 'timeline'].map(view => ({ dataset: { view }, hidden: false, setAttribute() {} }));
  const els = {};
  const el = id => els[id] || (els[id] = { id, innerHTML: '', textContent: id === 'flow-data' ? data : id === 'flow-config' ? cfg : '', hidden: false, checked: false, value: '',
    style: { setProperty() {} }, dataset: {}, clientWidth: 1100, clientHeight: 700, scrollTop: 0, scrollLeft: 0, offsetTop: 0, offsetLeft: 0,
    setAttribute() {}, getAttribute() {}, insertAdjacentHTML() {}, addEventListener() {}, querySelector() { return null; }, querySelectorAll() { return []; }, scrollTo() {} });
  const sandbox = {
    document: { getElementById: el, addEventListener() {}, querySelector() { return null; }, querySelectorAll: s => s === '.view-tab' ? tabs : [] },
    addEventListener() {}, matchMedia: () => ({ matches: false }), requestAnimationFrame: () => 0, cancelAnimationFrame() {},
    localStorage: { getItem: () => null, setItem() {} }, navigator: {}, FileReader: class {},
  };
  new Function(...Object.keys(sandbox), script)(...Object.values(sandbox));
  return { el, tab: v => tabs.find(t => t.dataset.view === v).onclick(), trace: i => el('trace-select').onchange({ target: { value: String(i) } }) };
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
  assert.equal(p.el('opt-static-label').textContent, 'View calls');
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
  const p = page(renderFlowHtml(await samples, { views: ['flow', 'layers', 'sequence', 'timeline'] }));
  for (const i of (await samples).keys()) {
    p.trace(i);
    p.tab('sequence'); assert.ok(/class="lbl seq/.test(p.el('graph').innerHTML));
    p.tab('layers'); assert.ok(/class="box big/.test(p.el('graph').innerHTML));
    p.tab('timeline'); assert.ok(/class="card/.test(p.el('canvas').innerHTML));
    p.tab('flow');
  }
});
