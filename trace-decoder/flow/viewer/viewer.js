// Call-flow viewer. Expects buildFlowModel (inlined from model.mjs) and the
// embedded #flow-data payload: [{ label, model }].
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const short = v => (v && v.length > 14 ? `${v.slice(0, 6)}…${v.slice(-4)}` : v || '—');
  const CARD_H = 28, GAP = 8, RET_H = 22, HEAD_H = 34, TOP = 10, GUTTER = 84, PAD = 14, MIN_CARD = 200, MAX_CARD = 380;

  const traces = JSON.parse($('flow-data').textContent || '[]');
  // Which diagram types this page offers, in tab order; the first one opens by default.
  const ALL_VIEWS = ['flow', 'layers', 'sequence', 'timeline'];
  let config = {};
  try { config = JSON.parse($('flow-config')?.textContent || '{}'); } catch { /* Defaults apply. */ }
  const VIEWS = (config.views || ALL_VIEWS).filter(v => ALL_VIEWS.includes(v));
  let M = null, current = -1;
  // returns: 'auto' draws dashed return arrows only on small maps.
  // staticCalls controls additional local reads; cross-chain reads stay visible.
  let readVisibilityChosen = false, traceMode = 'combined';
  const opt = { protocol: false, voidReturns: false, returns: 'auto', staticCalls: false };
  let expanded = new Set(), selection = null, layout = null, step = -1, timer = null, matches = [], matchAt = -1;

  // ---------- visible tree ----------
  let kidsMemo = new Map();
  // A static call stays visible when anything inside it crosses chains.
  const crossesMemo = new Map();
  function crossesInside(id) {
    if (crossesMemo.has(id)) return crossesMemo.get(id);
    const n = M.nodes[id], v = n.children.some(c => M.nodes[c].crossChainRead || M.nodes[c].chain !== n.chain || crossesInside(c));
    crossesMemo.set(id, v);
    return v;
  }
  const hiddenStatic = n => !opt.staticCalls && n.isStatic && !n.protocol && !n.crossChainRead && !n.crossing && !n.outgoing;
  function kids(id) {
    if (kidsMemo.has(id)) return kidsMemo.get(id);
    const out = [];
    for (const c of M.nodes[id].children) {
      const n = M.nodes[c];
      if (n.protocol && !opt.protocol) out.push(...kids(c));
      else if (hiddenStatic(n) && !crossesInside(c)) continue;
      else out.push(c);
    }
    kidsMemo.set(id, out);
    return out;
  }
  function topItems(root) { const n = M.nodes[root.node]; return n.protocol && !opt.protocol ? kids(root.node) : [root.node]; }
  const crossMemo = new Map();
  function hasCrossBelow(id) {
    const key = id + (opt.protocol ? 'p' : '') + (opt.staticCalls ? 's' : '');
    if (crossMemo.has(key)) return crossMemo.get(key);
    const n = M.nodes[id];
    const v = kids(id).some(c => M.nodes[c].chain !== n.chain || hasCrossBelow(c));
    crossMemo.set(key, v);
    return v;
  }
  function subtreeSize(id) { let s = 0; for (const c of kids(id)) s += 1 + subtreeSize(c); return s; }
  function parentMap() {
    const p = new Map();
    const walk = id => { for (const c of kids(id)) { p.set(c, id); walk(c); } };
    for (const r of M.roots) for (const t of topItems(r)) walk(t);
    return p;
  }
  function defaultExpansion() {
    expanded = new Set();
    M.roots.forEach((r, i) => {
      if (r.isOrigin || i === 0) expanded.add(`root:${i}`);
      const walk = id => { if (hasCrossBelow(id)) { expanded.add(id); kids(id).forEach(walk); } };
      topItems(r).forEach(walk);
      if (r.isOrigin || i === 0) topItems(r).forEach(t => expanded.add(t));
    });
  }

  // ---------- returns ----------
  function needsReturn(n, crossIn, isTop) {
    if (isTop) return n.ret.status === 'revert';
    if (crossIn || n.kind === 'ghost') return true;
    if (n.ret.status === 'void') return opt.voidReturns;
    return true;
  }
  const group = s => s.replace(/^-?\d{5,}$/, d => BigInt(d).toLocaleString('en-US'));
  function valueText(v) {
    if (v == null) return '—';
    if (Array.isArray(v)) return `[${v.map(valueText).join(', ')}]`;
    if (typeof v === 'object') return `{${Object.entries(v).map(([k, x]) => `${k}: ${valueText(x)}`).join(', ')}}`;
    const s = String(v);
    if (/^0x[0-9a-f]{40}$/i.test(s)) return short(s);
    if (/^0x[0-9a-f]{66,}$/i.test(s)) return `${s.slice(0, 6)}…${s.slice(-8)} (${(s.length - 2) / 2}B)`;
    return group(s);
  }
  function returnText(n) {
    const r = n.ret;
    switch (r.status) {
      case 'ok': return r.items.length === 1 ? valueText(r.items[0].value) : `(${r.items.map(i => (/^\d+$/.test(i.name) || !i.name ? '' : i.name + ': ') + valueText(i.value)).join(', ')})`;
      case 'void': return 'void';
      case 'revert': return `revert ${r.reason}`;
      case 'created': return `created ${short(n.address)}`;
      case 'precomputed': return `${valueText(r.raw)} · precomputed`;
      case 'unknown': return r.alternatives ? `${r.alternatives} possible results` : 'result not observed';
      default: return r.raw && r.raw !== '0x' ? valueText(r.raw) : 'void';
    }
  }
  const TABLE_FNS = ['postAndVerifyBatch', 'loadExecutionTable', 'executeIncomingCrossChainCall'];
  // Execution tables are summarised by size; the inspector shows them decoded.
  const argsText = n => {
    const t = tableOf(n);
    if (t) return `${t.fn}(${t.entries.length} entr${t.entries.length === 1 ? 'y' : 'ies'}${t.statics.length ? `, ${t.statics.length} static` : ''})`;
    return n.fn.includes('(') && n.signature ? `${n.fn.replace(/\(.*$/, '')}(${n.args.map(a => valueText(a.value)).join(', ')})` : n.fn;
  };

  // ---------- layout ----------
  function computeLayout(width) {
    kidsMemo = new Map();
    const rows = [], maxDepth = { L1: 0, L2: 0 };
    let y = TOP;
    function place(id, parent, depth, crossIn, isTop) {
      const n = M.nodes[id], d = depth[n.chain];
      maxDepth[n.chain] = Math.max(maxDepth[n.chain], d);
      const row = { type: 'call', id, parent, y, depth: d, chain: n.chain, crossIn, isTop };
      rows.push(row); y += CARD_H + GAP;
      const children = kids(id);
      row.hidden = expanded.has(id) ? 0 : subtreeSize(id);
      row.childRows = [];
      if (expanded.has(id)) for (const c of children) {
        const next = { ...depth, [n.chain]: depth[n.chain] + 1 };
        row.childRows.push(place(c, row, next, M.nodes[c].chain !== n.chain, false));
      }
      if (needsReturn(n, crossIn, isTop)) { row.ret = { type: 'return', id, call: row, y }; rows.push(row.ret); y += RET_H; }
      row.end = y - GAP;
      return row;
    }
    M.roots.forEach((r, i) => {
      const key = `root:${i}`, open = expanded.has(key), items = topItems(r);
      rows.push({ type: 'head', root: r, index: i, y, open, count: items.reduce((s, t) => s + 1 + subtreeSize(t), 0) }); y += HEAD_H;
      if (open) for (const t of items) place(t, null, { L1: 0, L2: 0 }, false, true);
      y += 8;
    });
    const W = Math.max(width, 760), laneW = (W - GUTTER) / 2 - PAD * 2;
    const indent = ch => maxDepth[ch] ? Math.max(10, Math.min(28, (laneW - MIN_CARD) / maxDepth[ch])) : 28;
    const geo = { W, laneW, l1x: PAD, l2x: W / 2 + GUTTER / 2 + PAD, gutL: W / 2 - GUTTER / 2, gutR: W / 2 + GUTTER / 2, indent: { L1: indent('L1'), L2: indent('L2') } };
    for (const row of rows) if (row.type === 'call') {
      const ind = geo.indent[row.chain];
      row.x = (row.chain === 'L1' ? geo.l1x : geo.l2x) + row.depth * ind;
      row.w = Math.min(MAX_CARD, Math.max(160, laneW - row.depth * ind));
      row.rail = row.x + Math.min(12, ind / 2);
    }
    return { rows, height: y + 20, geo };
  }

  // ---------- contract map ----------
  // One box per contract, L1 band above L2 band. Columns follow the depth at which a
  // contract is first called, so the flow reads left to right.
  let view = 'flow', G = null;
  // Which transaction the map views draw. The requested one when it was traced;
  // otherwise the related transaction with the most application calls, with a notice.
  let rootIndex = 0;
  const appCalls = r => { let s = 0; const walk = id => { s++; kids(id).forEach(walk); }; topItems(r).forEach(walk); return s; };
  // EEZ system transactions (settlement batch, table loads, deliveries) are plumbing:
  // listed only with it ticked, unless nothing else was traced.
  const PLUMBING_ROLES = ['settlement', 'table-load', 'delivery'];
  const isPlumbing = r => PLUMBING_ROLES.includes(r.role);
  const sectionOf = t => t.relatedSettlement ? 'settlement' : t.requested && t.role === 'other' ? 'flow'
    : t.inFlow === false ? 'other' : PLUMBING_ROLES.includes(t.role) ? 'plumbing' : 'flow';
  const rootVisible = r => r.isOrigin || r.unisolatedEntry || opt.protocol || r.relatedSettlement || !isPlumbing(r) || M.roots.every(isPlumbing);
  const BOTH_CHAINS = -2;
  const linkedRoots = () => M.mode === 'physical' ? M.roots.filter(r => r.preferred || r.isOrigin || r.inFlow && r.role === 'delivery') : [];
  const hasBothChains = () => new Set(linkedRoots().map(r => r.chain)).size > 1;
  function defaultRoot() {
    if (hasBothChains()) return BOTH_CHAINS;
    const preferred = M.roots.findIndex(r => r.preferred);
    if (preferred >= 0) return preferred;
    // The trigger starts the flow; the requested transaction may be its settlement instead.
    const requested = M.roots.findIndex(r => r.isOrigin && !isPlumbing(r));
    if (requested >= 0) return requested;
    const t = M.roots.findIndex(r => r.inFlow !== false && r.role === 'trigger');
    if (t >= 0) return t;
    const i = M.roots.findIndex(r => r.isOrigin && rootVisible(r));
    if (i >= 0) return i;
    let best = -1, most = -1;
    M.roots.forEach((r, j) => { if (!rootVisible(r) || r.inFlow === false && !txOfRoot(r)?.inFlow && !r.relatedSettlement) return; const n = appCalls(r); if (n > most) { most = n; best = j; } });
    return best;
  }
  const currentRoot = () => M.roots[rootIndex] || null;
  function renderRootPicker() {
    const originTx = M.transactions.find(t => M.origin && `${t.chain}:${t.hash}` === M.origin.transactionId);
    const missing = M.origin && !M.roots.some(r => r.isOrigin);
    const shown = M.roots[rootIndex], trigger = M.transactions.find(t => t.inFlow === true && t.role === 'trigger');
    let note = '';
    if (rootIndex === BOTH_CHAINS) {
      const entry = M.roots.find(r => r.preferred);
      note = entry ? `Both chains for your L2 transaction. <b>L2</b> makes the requests and receives prepared responses from its loaded table. <b>L1 entry ${esc(entry.entryIndex)}</b> records the calls against the remote contracts. Each tree keeps its own recorded order; this is not a shared timeline.`
        : 'Both chains for your transaction. The L1 source and its linked L2 deliveries are shown in their own recorded order. Prepared lookups without a delivery stay on L1.';
    }
    else if (shown?.preferred) note = `Showing the recorded L1 execution for your L2 transaction: entry ${esc(shown.entryIndex)}. Calls remain in trace order, including reads and reverted calls. Select the source transaction below to inspect its L2 trace.`;
    else if (missing) note = `<b>The requested ${esc(M.origin.chain)} transaction could not be traced</b> (${esc(originTx?.traceReason || 'no call trace')}), so its own calls cannot be drawn. ${shown ? 'Showing a related transaction found through the settlement; pick another below.' : 'No related transaction was traced either.'} An archive RPC (<code>--l1-trace-rpc</code> / <code>--l2-trace-rpc</code>) usually fixes this.`;
    else if (originTx && shown && !shown.isOrigin && trigger) note = `<b>You asked for the ${esc(originTx.label.toLowerCase())}</b> on ${esc(originTx.chain)} (${esc(short(originTx.hash))}). The flow starts in the <b>trigger transaction on ${esc(trigger.chain)}</b> (${esc(short(trigger.hash))}), shown here. ${trigger.evidence.length ? `Evidence: ${esc(trigger.evidence.join('; '))}.` : ''}`;
    else if (originTx?.role === 'other' && M.roots.some(r => r.relatedSettlement)) note = shown?.relatedSettlement
      ? 'Showing the L1 batch that settles the requested L2 transaction. No cross-chain call was observed in that L2 transaction.'
      : 'No cross-chain calls were observed in this transaction. Choose the L1 settlement below to inspect the batch that includes it.';
    if (M.executionNotice) note += `${note ? '<br>' : ''}${esc(M.executionNotice)}`;
    $('notice').hidden = !note;
    $('notice').innerHTML = note;
    $('root-wrap').hidden = !hasBothChains() && M.roots.filter(rootVisible).length < 2 && !missing;
    const opt = (r, i) => `<option value="${i}">${esc(r.label)}${r.isOrigin ? ' (requested)' : ''} · ${r.chain} · ${esc(short(r.tx))} · ${appCalls(r)} calls</option>`;
    const listed = M.roots.map((r, i) => [r, i]).filter(([r]) => rootVisible(r));
    const groups = [['flow', 'This flow'], ['settlement', 'L1 settlement'], ['plumbing', 'EEZ plumbing'], ['other', 'Not part of this flow']];
    $('root-select').innerHTML = (hasBothChains() ? `<option value="${BOTH_CHAINS}">Both chains · linked execution</option>` : '') + groups.map(([key, title]) => {
      const rows = listed.filter(([r]) => (r.role === 'execution' ? 'flow' : sectionOf(txOfRoot(r) || { role: r.role })) === key);
      return rows.length ? `<optgroup label="${title}">${rows.map(([r, i]) => opt(r, i)).join('')}</optgroup>` : '';
    }).join('');
    $('root-select').value = String(rootIndex);
    const snapshots = M.stateObservations || [];
    $('state-summary').hidden = !snapshots.length;
    $('state-summary').innerHTML = snapshots.map(s => `<div><b>${esc(s.chain)} · ${esc(s.contractName || short(s.address))}</b><span>${(s.values || []).map(v => `${esc(v.name)} = <b>${esc(v.value)}</b>`).join(' · ')}</span><small>Observed after block ${esc(s.blockNumber)}</small></div>`).join('');
  }
  const PALETTE = 10;
  const contractTag = i => i < 26 ? String.fromCharCode(65 + i) : String.fromCharCode(65 + Math.floor(i / 26) - 1) + String.fromCharCode(65 + (i % 26));
  const cidStyle = i => `--cid:var(--c${i % PALETTE})`;
  const tagHtml = b => b && b.tag != null ? `<span class="cid" style="${cidStyle(b.cid)}">${b.tag}</span>` : '';
  const isMap = () => view !== 'timeline';
  const nameOf = n => n.impl && n.impl.contract !== 'Unknown contract' ? n.impl.contract : n.contract;
  function graphModel() {
    kidsMemo = new Map();
    const roots = shownRoots(), root = roots[0];
    const boxes = new Map(), edges = new Map(), seq = [], callerOf = new Map();
    if (!root) return { boxes: [], edges: [], seq, callerOf, roots };
    const add = (key, init) => { if (!boxes.has(key)) boxes.set(key, { key, order: boxes.size, fns: [], ...init }); return boxes.get(key); };
    let num = 0;
    const chainNumbers = { L1: 0, L2: 0 };
    function walk(id, from, depth) {
      const n = M.nodes[id], key = `${n.chain}:${String(n.impl?.address || n.address || 'create').toLowerCase()}`;
      const b = add(key, { kind: n.kind === 'ghost' ? 'ghost' : n.protocol ? 'proto' : 'contract', chain: n.chain, name: nameOf(n), address: n.impl?.address || n.address, depth });
      const fn = n.fn.replace(/\(.*$/, '');
      if (!b.fns.includes(fn)) b.fns.push(fn);
      const ek = `${from}>${key}`;
      if (!edges.has(ek)) edges.set(ek, { key: ek, from, to: key, calls: [] });
      const call = { id, num: M.mode === 'physical' && rootIndex === BOTH_CHAINS ? ++chainNumbers[n.chain] : ++num, edge: ek };
      edges.get(ek).calls.push(call); callerOf.set(id, from);
      seq.push({ type: 'call', ...call });
      for (const c of kids(id)) walk(c, key, depth + 1);
      seq.push({ type: 'return', ...call });
    }
    // One sender per transaction; recorded chains have independent call numbering.
    roots.forEach((r, i) => {
      const key = `eoa:${i}`;
      add(key, { kind: 'eoa', chain: r.chain, name: r.preferred ? 'Entry caller' : 'Transaction sender', address: r.from, depth: 1 });
      for (const t of topItems(r)) walk(t, key, 1);
    });
    // Contract identity shared by every view: a letter and a colour, in first-call order.
    let i = 0;
    for (const b of boxes.values()) if (b.kind !== 'eoa') { b.cid = i++; b.tag = contractTag(b.cid); b.calls = [...edges.values()].filter(e => e.to === b.key).flatMap(e => e.calls).sort((x, y) => x.num - y.num); }
    return { boxes: [...boxes.values()], edges: [...edges.values()], seq, callerOf, root, roots };
  }
  const isSender = key => String(key).startsWith('eoa:');
  const txOfRoot = r => r && M.transactions.find(t => t.hash === r.tx && t.chain === r.chain);
  // The views draw one transaction: the one selected in the transaction list.
  function shownRoots() {
    if (rootIndex === BOTH_CHAINS) return linkedRoots();
    const cur = currentRoot();
    return cur ? [cur] : [];
  }
  // Tidy left-to-right tree. Each contract hangs off the contract that first called it:
  // the first callee continues on the same row, later callees stack below the previous
  // callee's subtree. Rows are counted per band, so L1 and L2 boxes never collide.
  const T = { w: 220, h: 104, eoaW: 170, eoaH: 60, col: 130, row: 40, pad: 48, side: 28 };
  const collapsedBoxes = new Set();
  const boxKeyOf = n => `${n.chain}:${String(n.impl?.address || n.address || 'create').toLowerCase()}`;
  function contractTree(g) {
    const byKey = new Map(g.boxes.map(b => [b.key, b]));
    for (const b of g.boxes) { b.kids = []; b.parent = null; }
    for (const s of g.seq) {
      if (s.type !== 'call') continue;
      const to = byKey.get(boxKeyOf(M.nodes[s.id])), from = g.callerOf.get(s.id);
      if (!isSender(to.key) && to.parent == null && from !== to.key) { to.parent = from; byKey.get(from).kids.push(to.key); }
    }
    const crossBelow = b => b.kids.some(k => { const c = byKey.get(k); return (b.kind !== 'eoa' && c.chain !== b.chain) || crossBelow(c); });
    const size = b => b.kids.reduce((s, k) => s + 1 + size(byKey.get(k)), 0);
    for (const b of g.boxes) { b.cross = crossBelow(b); b.size = size(b); }
    return byKey;
  }
  // Big traces open with local-only subtrees folded; the path to every crossing stays open.
  function initMapState() {
    collapsedBoxes.clear(); opt.returns = 'auto';
    const g = graphModel();
    contractTree(g);
    if (g.boxes.length > 10) for (const b of g.boxes) if (b.kids.length && !b.cross && b.kind !== 'eoa' && !isSender(b.parent)) collapsedBoxes.add(b.key);
  }
  // ---------- map layout and routing ----------
  // Boxes never overlap labels or lines: every arrow ends at its own "port" slot on the
  // target's side with its label just before the arrowhead; column gaps are sized to fit
  // those labels plus a corridor of vertical lanes; lines only run through corridors and
  // through the gaps between rows.
  const PORT = 30, LANE = 7, LBL_GAP = 12, MAX_LBL = 300;
  const textW = s => Math.min(MAX_LBL, Math.round(s.length * 7.2) + 44);
  function lineText(c) {
    const n = M.nodes[c.id], r = n.ret.status === 'void' && !opt.voidReturns ? '' : ` → ${returnText(n)}`;
    return { num: c.num, id: c.id, f: argsText(n), r, bad: n.ret.status === 'revert' };
  }
  function edgeLabel(e) {
    const lines = e.calls.map(lineText);
    const names = [...new Set(e.calls.map(c => M.nodes[c.id].fn.replace(/\(.*$/, '')))].join(', ');
    // Reserve the widest variant so stepping through a multi-call arrow never moves boxes.
    const w = Math.max(...lines.map(l => textW(`${l.num} ${l.f}${l.r}${e.calls.length > 1 ? ' +9' : ''}`)), e.calls.length > 1 ? textW(`▸ ${e.calls.length} calls ${names}`) : 0);
    return { lines, names, w: Math.min(MAX_LBL, w) };
  }
  function mapLayout(g, byKey, orient) {
    const band = b => orient === 'layers' ? b.chain : 'all', cursor = new Map(), visible = new Set();
    function visit(key, col, pref) {
      const b = byKey.get(key), bk = band(b), ck = `${bk}|${col}`;
      b.col = col; b.row = Math.max(pref[bk] ?? 0, cursor.get(ck) ?? 0); cursor.set(ck, b.row + 1); visible.add(key);
      const reach = { [bk]: b.row };
      if (collapsedBoxes.has(key)) return reach;
      const next = { ...pref, [bk]: b.row };
      for (const k of b.kids) {
        const sub = visit(k, col + 1, next);
        for (const [x, r] of Object.entries(sub)) { reach[x] = Math.max(reach[x] ?? -1, r); next[x] = r + 1; }
      }
      return reach;
    }
    // Each transaction's sender starts a tree; later trees go below the earlier ones.
    let pref = {};
    for (const s of g.boxes.filter(b => b.kind === 'eoa')) {
      const reach = visit(s.key, 0, pref);
      for (const [x, r] of Object.entries(reach)) pref[x] = Math.max(pref[x] ?? 0, r + 1);
    }
    const shown = g.boxes.filter(b => visible.has(b.key));
    // Column index used for x. L1 | L2 packs each chain's columns on its own side.
    let divideAt = null;
    if (orient === 'columns') {
      const cols = ch => [...new Set(shown.filter(b => b.chain === ch).map(b => b.col))].sort((a, b) => a - b);
      const c1 = cols('L1'), c2 = cols('L2');
      for (const b of shown) b.ci = b.chain === 'L1' ? c1.indexOf(b.col) : c1.length + c2.indexOf(b.col);
      divideAt = c1.length;
    } else for (const b of shown) b.ci = b.col;
    const nCols = Math.max(...shown.map(b => b.ci)) + 1;

    // Edges, their side (left port for forward calls, right port otherwise) and labels.
    const edges = g.edges.filter(e => visible.has(e.from) && visible.has(e.to));
    for (const b of shown) { b.inL = []; b.inR = []; }
    for (const e of edges) {
      e.A = byKey.get(e.from); e.B = byKey.get(e.to); e.self = e.A === e.B;
      e.side = !e.self && e.B.ci > e.A.ci ? 'l' : 'r'; e.label = edgeLabel(e);
      (e.side === 'l' ? e.B.inL : e.B.inR).push(e);
    }
    const order = (x, y) => x.A.ci - y.A.ci || x.A.row - y.A.row || x.calls[0].num - y.calls[0].num;
    for (const b of shown) {
      b.inL.sort(order); b.inR.sort(order);
      const slots = Math.max(b.inL.length, b.inR.length + (b.inR.length ? 1 : 0));
      b.w = b.kind === 'eoa' ? T.eoaW : T.w;
      b.h = b.kind === 'eoa' ? T.eoaH : Math.max(T.h, slots * PORT + 14);
    }

    // Column widths and gaps: right-port labels | lanes | left-port labels of the next column.
    const colW = Array(nCols).fill(0), Lw = Array(nCols + 1).fill(0), Rw = Array(nCols + 1).fill(0), lanes = Array(nCols + 1).fill(0);
    for (const b of shown) {
      colW[b.ci] = Math.max(colW[b.ci], b.w);
      for (const e of b.inL) Lw[b.ci] = Math.max(Lw[b.ci], e.label.w + LBL_GAP);
      for (const e of b.inR) Rw[b.ci] = Math.max(Rw[b.ci], e.label.w + LBL_GAP);
    }
    // Corridor c sits right of column c. Count the lanes each route needs there.
    const corridorsOf = e => {
      if (e.side === 'l') return e.B.ci === e.A.ci + 1 ? [e.A.ci] : [e.A.ci, e.B.ci - 1];
      return e.self || e.B.ci === e.A.ci ? [e.A.ci] : [e.A.ci, e.B.ci];
    };
    for (const e of edges) for (const c of new Set(corridorsOf(e))) lanes[c]++;
    const corrW = c => 28 + Math.max(0, lanes[c] - 1) * LANE;
    const colX = [], corrX = [];
    let x = T.side, dividerX = null;
    for (let c = 0; c < nCols; c++) {
      colX[c] = x;
      x += (colW[c] || T.w) + Rw[c];
      corrX[c] = x + 14;
      x += corrW(c) + (c + 1 < nCols ? Lw[c + 1] : 0);
      if (divideAt != null && c + 1 === divideAt) { dividerX = corrX[c] + corrW(c) / 2; }
      x += 24;
    }
    const W = x + T.side;

    // Rows: per band, each row as tall as its tallest box.
    const bands = orient === 'layers' ? ['L1', 'L2'] : ['all'], rowTop = {}, rowH = {}, bandTop = {}, bandH = {};
    let y = 0;
    for (const bk of bands) {
      const inBand = shown.filter(b => band(b) === bk), nRows = Math.max(1, ...inBand.map(b => b.row + 1));
      rowH[bk] = Array(nRows).fill(T.h); rowTop[bk] = [];
      for (const b of inBand) rowH[bk][b.row] = Math.max(rowH[bk][b.row], b.h);
      bandTop[bk] = y; let ry = y + T.pad;
      for (let r = 0; r < nRows; r++) { rowTop[bk][r] = ry; ry += rowH[bk][r] + T.row; }
      bandH[bk] = ry - T.row + T.pad - y; y += bandH[bk];
    }
    for (const b of shown) {
      const bk = band(b);
      b.x = colX[b.ci] + ((colW[b.ci] || b.w) - b.w) / 2;
      b.y = rowTop[bk][b.row] + (rowH[bk][b.row] - b.h) / 2;
    }

    // Routes. Every vertical run uses its own lane inside a corridor; horizontal runs
    // across other columns use the gap just above the target's row.
    const used = Array(nCols + 1).fill(0), lane = c => corrX[c] + (used[c]++) * LANE, gapUsed = new Map();
    // Row gap above the target; parallel runs in the same gap get their own offset.
    const gapAbove = b => {
      const bk = band(b), base = b.row === 0 ? bandTop[bk] + T.pad - 14 : rowTop[bk][b.row] - T.row / 2, key = `${bk}|${b.row}`;
      const k = gapUsed.get(key) || 0; gapUsed.set(key, k + 1);
      return base + (k % 2 ? 1 : -1) * Math.ceil(k / 2) * 5;
    };
    for (const b of shown) {
      b.inL.forEach((e, i) => { e.py = b.y + b.h / 2 + (i - (b.inL.length - 1) / 2) * PORT; });
      // Right side: labelled ports on top, then one shared exit slot for outgoing arrows.
      const nR = b.inR.length + (b.inR.length ? 1 : 0);
      b.inR.forEach((e, i) => { e.py = b.y + b.h / 2 + (i - (nR - 1) / 2) * PORT; });
      b.exitY = b.inR.length ? b.y + b.h / 2 + ((nR - 1) / 2) * PORT : b.y + b.h / 2;
    }
    for (const e of edges) {
      const A = e.A, B = e.B, sx = A.x + A.w, sy = A.exitY;
      if (e.self) { const lx = lane(A.ci); e.pts = [[sx, sy], [lx, sy], [lx, e.py], [B.x + B.w + 2, e.py]]; continue; }
      if (e.side === 'l') {
        const ex = B.x - 2;
        if (B.ci === A.ci + 1) { const lx = lane(A.ci); e.pts = [[sx, sy], [lx, sy], [lx, e.py], [ex, e.py]]; }
        else { const l1 = lane(A.ci), l2 = lane(B.ci - 1), gy = gapAbove(B); e.pts = [[sx, sy], [l1, sy], [l1, gy], [l2, gy], [l2, e.py], [ex, e.py]]; }
      } else {
        const ex = B.x + B.w + 2;
        if (B.ci === A.ci) { const lx = lane(A.ci); e.pts = [[sx, sy], [lx, sy], [lx, e.py], [ex, e.py]]; }
        else { const l1 = lane(A.ci), l2 = lane(B.ci), gy = gapAbove(B); e.pts = [[sx, sy], [l1, sy], [l1, gy], [l2, gy], [l2, e.py], [ex, e.py]]; }
      }
    }
    return { orient, shown, visible, edges, W, H: y, boundary: bandTop.L2, bandH, divider: dividerX };
  }
  // Polyline → path with rounded corners.
  function roundPath(pts, r = 9) {
    const p = pts.filter((q, i) => i === 0 || q[0] !== pts[i - 1][0] || q[1] !== pts[i - 1][1]);
    let d = `M${p[0][0]} ${p[0][1]}`;
    for (let i = 1; i < p.length - 1; i++) {
      const [x0, y0] = p[i - 1], [x1, y1] = p[i], [x2, y2] = p[i + 1];
      const r1 = Math.min(r, Math.hypot(x1 - x0, y1 - y0) / 2, Math.hypot(x2 - x1, y2 - y1) / 2);
      const a = [x1 - Math.sign(x1 - x0) * r1, y1 - Math.sign(y1 - y0) * r1], b = [x1 + Math.sign(x2 - x1) * r1, y1 + Math.sign(y2 - y1) * r1];
      d += ` L${a[0]} ${a[1]} Q${x1} ${y1} ${b[0]} ${b[1]}`;
    }
    return d + ` L${p.at(-1)[0]} ${p.at(-1)[1]}`;
  }
  // The same route, shifted a few pixels and reversed, for the dashed return arrow.
  function returnPts(pts) {
    const s = 5, out = pts.map(([x, y], i) => [i === 0 || i === pts.length - 1 ? x : x + s, y + s]);
    return out.reverse();
  }
  // ---------- call flow ----------
  // One box per call, never per contract, so every arrow points right: depth runs left
  // to right, execution order top to bottom. A box's first call stays on its row and later
  // calls stack below the previous call's subtree. L1 calls use the top band, L2 the bottom.
  const flowFolded = new Set();
  const F = { w: 232, h: 100, eoaW: 170, eoaH: 60, gap: 46, row: 22, pad: 48, side: 28 };
  function initFlowState() {
    flowFolded.clear();
    const roots = shownRoots();
    let total = 0;
    const count = id => { total++; kids(id).forEach(count); };
    roots.forEach(r => topItems(r).forEach(count));
    // Large traces open with local-only subtrees folded below the second level.
    if (total > 30) {
      const walk = (id, d) => { const k = kids(id); if (k.length && d >= 2 && !hasCrossBelow(id)) flowFolded.add(id); k.forEach(c => walk(c, d + 1)); };
      roots.forEach(r => topItems(r).forEach(t => walk(t, 1)));
    }
  }
  function renderFlow() {
    G = graphModel(); kidsMemo = new Map();
    const roots = G.roots || [], cur = selection, parts = [], svg = [];
    if (!roots.length) { $('graph').innerHTML = '<div class="empty">No user transaction in this trace.</div>'; return; }
    const numOf = new Map(G.seq.filter(s => s.type === 'call').map(s => [s.id, s.num]));
    const items = [], cursor = new Map(), place = (it, pref) => {
      const ck = `${it.chain}|${it.col}`;
      it.row = Math.max(pref[it.chain] ?? 0, cursor.get(ck) ?? 0); cursor.set(ck, it.row + 1); items.push(it);
    };
    function visit(id, col, pref, parent) {
      const n = M.nodes[id], it = { id, n, parent, col, chain: n.chain, kidsN: kids(id).length, folded: flowFolded.has(id) };
      place(it, pref);
      const reach = { [it.chain]: it.row };
      if (!it.folded) {
        const next = { ...pref, [it.chain]: it.row };
        for (const k of kids(id)) {
          const sub = visit(k, col + 1, next, it);
          for (const [b, r] of Object.entries(sub)) { reach[b] = Math.max(reach[b] ?? -1, r); next[b] = r + 1; }
        }
      }
      return reach;
    }
    const nextRootRow = {};
    for (const [i, root] of roots.entries()) {
      const sender = { id: `eoa:${i}`, root, parent: null, col: 0, chain: root.chain, kidsN: 1 };
      place(sender, nextRootRow);
      const pref = { ...nextRootRow, [root.chain]: sender.row };
      for (const t of topItems(root)) { const sub = visit(t, 1, pref, sender); for (const [b, row] of Object.entries(sub)) pref[b] = row + 1; }
      for (const [chain, row] of Object.entries(pref)) nextRootRow[chain] = Math.max(nextRootRow[chain] || 0, row);
    }

    // One trunk lane per parent inside the corridor to the right of its column.
    const nCols = Math.max(...items.map(i => i.col)) + 1, lanesIn = Array(nCols).fill(0);
    for (const it of items) if (items.some(c => c.parent === it)) it.lane = lanesIn[it.col]++;
    const corr = c => F.gap + Math.max(0, lanesIn[c] - 1) * 7;
    const colX = [];
    let x = F.side;
    for (let c = 0; c < nCols; c++) { colX[c] = x; x += (c === 0 ? F.eoaW : F.w) + corr(c); }
    for (const it of items) {
      it.w = isSender(it.id) ? F.eoaW : F.w;
      it.h = isSender(it.id) ? F.eoaH : it.n?.preparedResponse || it.n?.preparedResult ? 140 : F.h;
    }
    const rowHeights = {}, rowTops = {}, bandHeights = {};
    for (const chain of ['L1', 'L2']) {
      const heights = rowHeights[chain] = Array(Math.max(1, ...items.filter(i => i.chain === chain).map(i => i.row + 1))).fill(F.h);
      for (const it of items.filter(i => i.chain === chain)) heights[it.row] = Math.max(heights[it.row], it.h);
      let y = F.pad;
      rowTops[chain] = heights.map(h => { const top = y; y += h + F.row; return top; });
      bandHeights[chain] = y - F.row + F.pad;
    }
    const split = M.mode === 'physical' && rootIndex === BOTH_CHAINS;
    const paneW = b => {
      const last = Math.max(0, ...items.filter(i => i.chain === b).map(i => i.col));
      return colX[last] + (last ? F.w : F.eoaW) + F.side;
    };
    const left = { L1: 0, L2: split ? paneW('L1') : 0 };
    const W = split ? paneW('L1') + paneW('L2') : x - corr(nCols - 1) + F.side;
    const bandsUsed = ['L1', 'L2'];
    const bandH = b => bandHeights[b], top = { L1: 0, L2: split ? 0 : bandH('L1') };
    for (const it of items) {
      it.x = left[it.chain] + colX[it.col];
      it.y = top[it.chain] + rowTops[it.chain][it.row] + (rowHeights[it.chain][it.row] - it.h) / 2;
    }
    const H = split ? Math.max(bandH('L1'), bandH('L2')) : top.L2 + bandH('L2'), boundary = top.L2;
    for (const b of bandsUsed) {
      parts.push(`<div class="band ${b.toLowerCase()}" style="left:${left[b]}px;top:${top[b]}px;width:${split ? paneW(b) : W}px;height:${split ? H : bandH(b)}px"></div>`);
      parts.push(`<div class="band-label ${b.toLowerCase()}" style="left:${left[b] + 14}px;top:${top[b] + 14}px">${b} · ${esc(M.chains[b].name)} <small>${M.chains[b].chainId ? 'chain ' + esc(M.chains[b].chainId) : ''}</small></div>`);
    }
    if (split) parts.push(`<div style="position:absolute;left:${left.L2}px;top:0;height:${H}px;border-left:1px solid var(--line)"></div>`);
    else parts.push(`<div class="boundary" style="top:${boundary}px"><span>${opt.protocol ? 'chain boundary · calls cross through EEZ proxies' : 'chain boundary'}</span></div>`);

    const selId = cur && ['node', 'return', 'cross'].includes(cur.kind) ? cur.id : null, tags = new Set();
    const byKeyF = new Map(G.boxes.map(b => [b.key, b]));
    // Selecting a call (or a contract) highlights every box of the same contract.
    const selCid = selId != null ? byKeyF.get(boxKeyOf(M.nodes[selId]))?.cid : cur?.kind === 'box' ? byKeyF.get(cur.id)?.cid : null;
    for (const it of items) {
      if (isSender(it.id)) {
        const from = it.root.from || '';
        parts.push(`<div class="box big eoa ${it.chain.toLowerCase()}" style="left:${it.x}px;top:${it.y}px;width:${it.w}px;height:${it.h}px" title="${esc(from)}"><span class="b-name">${it.root.preferred ? 'L1 entry caller' : ['table-load', 'delivery', 'settlement'].includes(it.root.role) ? 'EEZ sender' : 'Transaction sender'}</span><span class="b-addr">${esc(short(from))}</span></div>`);
        continue;
      }
      const n = it.n, c = it.chain.toLowerCase(), num = numOf.get(it.id), sel = selId === it.id;
      const cb = byKeyF.get(boxKeyOf(n)), nth = cb ? cb.calls.findIndex(x => x.id === it.id) + 1 : 0, total = cb ? cb.calls.length : 0;
      const ret = n.ret.status === 'void' ? '' : `<span class="b-ret${n.ret.status === 'revert' ? ' bad' : ''}">→ ${esc(returnText(n))}</span>`;
      const kick = `<span class="b-kick"><span class="num">${num}</span>${tagHtml(cb)}${it.chain}${n.kind === 'ghost' ? ' · not observed' : n.protocol ? ' · EEZ' : ''}${n.isStatic ? ' · read' : ''}${total > 1 ? `<span class="nth" title="Call ${nth} of ${total} to this contract">${nth}/${total}</span>` : ''}</span>`;
      const same = selCid != null && cb && cb.cid === selCid && !sel ? ' same' : '';
      parts.push(`<button type="button" class="box big flow tagged ${c}${n.kind === 'ghost' ? ' ghost' : ''}${n.protocol ? ' proto' : ''}${n.failed ? ' failed' : ''}${sel ? ' sel' : ''}${same}${matches.includes(it.id) ? ' hit' : ''}" data-node="${it.id}" data-cid="${cb?.cid ?? ''}" style="left:${it.x}px;top:${it.y}px;width:${it.w}px;height:${it.h}px;${cb ? cidStyle(cb.cid) : ''}" title="${esc(`${num}. ${nameOf(n)}.${argsText(n)}${ret ? ' → ' + returnText(n) : ''}${total > 1 ? ` · call ${nth} of ${total} to ${nameOf(n)}` : ''}`)}">${kick}<span class="b-name">${esc(nameOf(n))}</span><span class="b-fns">${esc(argsText(n))}</span>${n.preparedResponse ? '<span class="b-response">Prepared L2 table response</span>' : n.preparedResult ? '<span class="b-response">Prepared result · no L2 delivery</span>' : ''}${ret}</button>`);
      if (it.kidsN) parts.push(`<button type="button" class="fold ${c}" data-ffold="${it.id}" style="left:${it.x + it.w - 34}px;top:${it.y + it.h - 30}px" aria-expanded="${!it.folded}" title="${it.folded ? 'Show the calls it makes' : 'Fold the calls it makes'}">${it.folded ? `+${subtreeSize(it.id)}` : '−'}</button>`);
      // Arrow from the caller's trunk into this box.
      const p = it.parent, lx = p.x + p.w + 18 + p.lane * 7, py = p.y + p.h / 2, cy = it.y + it.h / 2;
      const cross = !isSender(p.id) && p.chain !== it.chain, cls = cross ? 'cross' : c;
      svg.push(`<path class="edge ${cls}${sel ? ' hot' : ''}" d="${roundPath([[p.x + p.w, py], [lx, py], [lx, cy], [it.x - 2, cy]])}" marker-end="url(#g-call-${cls})"/>`);
      if (opt.protocol && cross && !tags.has(lx)) { tags.add(lx); parts.push(`<button type="button" class="eez" data-cross="${it.id}" style="left:${lx}px;top:${boundary}px" title="How this call crosses chains">EEZ</button>`); }
    }
    const defs = `<defs>${[['call-l1', 'l1'], ['call-l2', 'l2'], ['call-cross', 'ink']].map(([id, k]) => `<marker id="g-${id}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M1 1 9 5 1 9" style="fill:none;stroke:var(--${k});stroke-width:1.8"/></marker>`).join('')}</defs>`;
    fitGraph(W, H);
    $('graph').innerHTML = `<svg class="edges" width="${W}" height="${H}" aria-hidden="true">${defs}${svg.join('')}</svg>${parts.join('')}`;
  }

  // Unfolds the boxes needed to show one call (its arrow label then shows that call).
  function reveal(id) {
    if (!G) return;
    if (view === 'flow') { const p = parentMap(); for (let a = p.get(id); a != null; a = p.get(a)) flowFolded.delete(a); return; }
    const byKey = new Map(G.boxes.map(b => [b.key, b]));
    for (let k = byKey.get(boxKeyOf(M.nodes[id]))?.parent; k; k = byKey.get(k)?.parent) collapsedBoxes.delete(k);
  }
  // Shrinks a moderately wide map (down to 50%) to fit the panel; wider maps keep full size and scroll.
  // Zoom: 'fit' scales the drawing to the panel width (never below 40%, never above 100%);
  // a number is a zoom the viewer chose, kept until they press Fit.
  let graphScale = 1, zoomMode = 'fit', graphSize = [0, 0];
  const ZOOM_MIN = 0.25, ZOOM_MAX = 2, FIT_MIN = 0.4;
  function fitGraph(W, H) {
    graphSize = [W, H];
    const avail = $('graph-wrap').clientWidth - 2;
    graphScale = zoomMode === 'fit' ? (avail > 0 ? Math.max(FIT_MIN, Math.min(1, avail / W)) : 1) : zoomMode;
    $('graph').style.width = W + 'px'; $('graph').style.height = H + 'px';
    $('graph').style.transform = graphScale === 1 ? '' : `scale(${graphScale})`;
    $('graph-size').style.width = W * graphScale + 'px'; $('graph-size').style.height = H * graphScale + 'px';
    $('zoom-level').textContent = `${Math.round(graphScale * 100)}%`;
    $('zoom-fit').setAttribute('aria-pressed', String(zoomMode === 'fit'));
  }
  // Zooms around the centre of what is on screen.
  function setZoom(next) {
    const w = $('graph-wrap'), cx = (w.scrollLeft + w.clientWidth / 2) / graphScale, cy = (w.scrollTop + w.clientHeight / 2) / graphScale;
    zoomMode = next === 'fit' ? 'fit' : Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, next));
    fitGraph(...graphSize);
    w.scrollTo(cx * graphScale - w.clientWidth / 2, cy * graphScale - w.clientHeight / 2);
  }
  // Called whenever what is drawn changes (view, transaction, checkboxes), not on selection:
  // back to the left edge, at the height of the first (sender) box.
  function resetGraphScroll() {
    const w = $('graph-wrap'), first = $('graph').querySelector('.box.eoa');
    w.scrollTo(0, first ? Math.max(0, first.offsetTop * graphScale - 60) : 0);
  }
  function boxHtml(b, sel, hit, fns) {
    const kick = b.kind === 'eoa' ? '' : `<span class="b-kick">${tagHtml(b)}${b.chain} · ${b.kind === 'ghost' ? 'not observed' : b.kind === 'proto' ? 'EEZ protocol' : 'contract'}</span>`;
    return `<button type="button" class="box big ${b.chain.toLowerCase()} ${b.kind}${b.tag != null ? ' tagged' : ''}${sel ? ' sel' : ''}${hit ? ' hit' : ''}" data-box="${esc(b.key)}" data-cid="${b.cid ?? ''}" style="left:${b.x}px;top:${b.y}px;width:${b.w}px;height:${b.h}px;${b.tag != null ? cidStyle(b.cid) : ''}" title="${esc(b.name + ' · ' + (b.address || ''))}">${kick}<span class="b-name">${esc(b.name)}</span><span class="b-addr">${esc(short(b.address))}</span>${fns}</button>`;
  }
  const boxHit = b => matches.some(id => `${M.nodes[id].chain}:${String(M.nodes[id].impl?.address || M.nodes[id].address).toLowerCase()}` === b.key);
  const boxFns = b => b.kind === 'eoa' ? '' : `<span class="b-fns">${esc(b.fns.slice(0, 3).join(' · '))}${b.fns.length > 3 ? ` +${b.fns.length - 3}` : ''}</span>`;

  // Sequence: contract boxes across the top (L1 group, divider, L2 group), lifelines
  // below, one row per call and per non-void return, in execution order.
  function renderSequence() {
    G = graphModel();
    const PW = 210, PH = 104, PG = 56, LEFT = 30, TOPY = 54, ROW = 46, cur = selection, parts = [], svg = [];
    const groups = { L1: G.boxes.filter(b => b.chain === 'L1'), L2: G.boxes.filter(b => b.chain === 'L2') };
    let x = LEFT;
    for (const b of groups.L1) { b.w = PW; b.h = PH; b.x = x; b.y = TOPY; x += PW + PG; }
    const divider = (groups.L1.length ? x - PG : x) + 40;
    x = divider + 40;
    for (const b of groups.L2) { b.w = PW; b.h = PH; b.x = x; b.y = TOPY; x += PW + PG; }
    const W = Math.max(x - PG + LEFT, divider + 200), life = new Map(G.boxes.map(b => [b.key, b.x + b.w / 2]));
    const rows = [], open = new Map();
    const nextY = { all: TOPY + PH + 40, L1: TOPY + PH + 40, L2: TOPY + PH + 40 };
    const split = M.mode === 'physical' && rootIndex === BOTH_CHAINS;
    for (const s of G.seq) {
      const n = M.nodes[s.id], from = G.callerOf.get(s.id), to = `${n.chain}:${String(n.impl?.address || n.address || 'create').toLowerCase()}`;
      const cross = !isSender(from) && G.boxes.find(b => b.key === from)?.chain !== n.chain;
      const band = split ? n.chain : 'all', y = nextY[band];
      if (s.type === 'call') { rows.push({ s, from, to, y, cross }); open.set(s.id, { to, y }); nextY[band] += ROW; continue; }
      const show = n.ret.status !== 'void' || opt.voidReturns;
      const start = open.get(s.id);
      if (show && !isSender(from)) { rows.push({ s, from: to, to: from, y, cross }); start.end = y; nextY[band] += ROW; } else start.end = y - ROW / 2;
    }
    const H = Math.max(...Object.values(nextY)) + 30;
    parts.push(`<div class="band l1" style="top:0;bottom:0;left:0;right:auto;width:${divider}px"></div><div class="band l2" style="top:0;bottom:0;left:${divider}px;right:auto;width:${W - divider}px"></div>`);
    parts.push(`<div class="band-label l1" style="top:16px">L1 · ${esc(M.chains.L1.name)}</div><div class="band-label l2" style="top:16px;left:${divider + 18}px">L2 · ${esc(M.chains.L2.name)}</div>`);
    parts.push(`<div class="divider" style="left:${divider}px"></div>`);
    for (const b of G.boxes) {
      svg.push(`<line class="lifeline" x1="${life.get(b.key)}" y1="${TOPY + PH}" x2="${life.get(b.key)}" y2="${H - 10}"/>`);
      parts.push(boxHtml(b, cur?.kind === 'box' && cur.id === b.key, boxHit(b), boxFns(b)));
    }
    // Activation bars: the callee is running between its call row and its return row.
    for (const [, a] of open) {
      const lx = life.get(a.to), c = a.to.slice(0, 2).toLowerCase();
      svg.push(`<rect class="act ${c}" x="${lx - 5}" y="${a.y}" width="10" height="${Math.max(8, a.end - a.y)}"/><rect class="act-edge ${c}" x="${lx - 5}" y="${a.y}" width="10" height="${Math.max(8, a.end - a.y)}"/>`);
    }
    const hotId = cur && ['node', 'return', 'cross'].includes(cur.kind) ? cur.id : null;
    for (const r of rows) {
      const n = M.nodes[r.s.id], x1 = life.get(r.from), x2 = life.get(r.to), isCall = r.s.type === 'call';
      const bad = !isCall && n.ret.status === 'revert', hot = hotId === r.s.id, dim = hotId != null && !hot ? ' dim' : '';
      const cls = isCall ? (r.cross ? 'cross' : n.chain.toLowerCase()) : `back${bad ? ' bad' : ''}`;
      const marker = isCall ? `g-call-${r.cross ? 'cross' : n.chain.toLowerCase()}` : `g-${bad ? 'bad' : 'ret'}`;
      let d, lx;
      if (x1 === x2) { d = `M${x1 + 5} ${r.y - 10} h44 v20 h-40`; lx = x1 + 60; }
      else { const dir = Math.sign(x2 - x1); d = `M${x1 + dir * 5} ${r.y} H${x2 - dir * 7}`; lx = (x1 + x2) / 2; }
      svg.push(`<path class="edge ${cls}${hot ? ' hot' : ''}${dim}" d="${d}" marker-end="url(#${marker})"/>`);
      const sel = hot && (isCall ? cur.kind !== 'return' : cur.kind === 'return') ? ' sel' : '';
      const text = isCall ? esc(argsText(n)) : `↩ ${esc(returnText(n))}`;
      parts.push(`<button type="button" class="lbl seq${isCall ? '' : ' ret'}${bad ? ' bad' : ''}${sel}${dim}" ${isCall ? `data-node="${r.s.id}"` : `data-ret="${r.s.id}"`} style="left:${lx}px;top:${r.y - 4}px${x1 === x2 ? ';transform:translate(0,-100%)' : ''}" title="${esc(`${r.s.num}. ${isCall ? nameOf(n) + '.' + argsText(n) : 'returns ' + returnText(n)}`)}"><span class="num">${r.s.num}</span>${text}</button>`);
      if (opt.protocol && isCall && r.cross) parts.push(`<button type="button" class="eez${dim}" data-cross="${r.s.id}" style="left:${divider}px;top:${r.y}px" title="How this call crosses chains">EEZ</button>`);
    }
    const defs = `<defs>${[['call-l1', 'l1'], ['call-l2', 'l2'], ['call-cross', 'ink'], ['ret', 'ret'], ['bad', 'bad']].map(([id, c]) => `<marker id="g-${id}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M1 1 9 5 1 9" style="fill:none;stroke:var(--${c});stroke-width:1.8"/></marker>`).join('')}</defs>`;
    fitGraph(W, H);
    $('graph').innerHTML = `<svg class="edges" width="${W}" height="${H}" aria-hidden="true">${defs}${svg.join('')}</svg>${parts.join('')}`;
  }

  function renderGraph() {
    G = graphModel();
    const byKey = contractTree(G), geo = mapLayout(G, byKey, view === 'columns' ? 'columns' : 'layers');
    const cur = selection, parts = [], svg = [];
    const ch = c => c.toLowerCase();
    const chainLabel = (c, style) => `<div class="band-label ${ch(c)}" style="${style}">${c} · ${esc(M.chains[c].name)} <small>${M.chains[c].chainId ? 'chain ' + esc(M.chains[c].chainId) : ''}</small></div>`;
    if (geo.orient === 'columns') {
      parts.push(`<div class="band l1" style="top:0;bottom:0;left:0;right:auto;width:${geo.divider}px"></div><div class="band l2" style="top:0;bottom:0;left:${geo.divider}px;right:auto;width:${geo.W - geo.divider}px"></div>`);
      parts.push(chainLabel('L1', 'top:16px') + chainLabel('L2', `top:16px;left:${geo.divider + 18}px`));
      parts.push(`<div class="divider" style="left:${geo.divider}px"><span>${opt.protocol ? 'chain boundary · calls cross through EEZ proxies' : 'chain boundary'}</span></div>`);
    } else {
      parts.push(`<div class="band l1" style="top:0;height:${geo.bandH.L1}px"></div><div class="band l2" style="top:${geo.boundary}px;height:${geo.bandH.L2}px"></div>`);
      parts.push(chainLabel('L1', 'top:12px') + chainLabel('L2', `top:${geo.boundary + 12}px`));
      parts.push(`<div class="boundary" style="top:${geo.boundary}px"><span>${opt.protocol ? 'chain boundary · calls cross through EEZ proxies' : 'chain boundary'}</span></div>`);
    }
    // What is highlighted: the edge of the selected call/return, or every edge of a selected box.
    const curEdge = cur && ['node', 'return', 'cross'].includes(cur.kind) ? G.seq.find(s => s.id === cur.id)?.edge : cur?.kind === 'edge' ? cur.id : null;
    const isHot = e => curEdge ? e.key === curEdge : cur?.kind === 'box' ? e.from === cur.id || e.to === cur.id : false;
    const focus = !!(curEdge || cur?.kind === 'box');
    const edges = geo.edges;
    const returnsOn = opt.returns === 'auto' ? edges.length <= 6 : opt.returns;
    $('opt-returns').checked = returnsOn;
    for (const b of geo.shown) {
      const sel = cur?.kind === 'box' && cur.id === b.key;
      parts.push(boxHtml(b, sel, boxHit(b), boxFns(b)));
      if (b.kids.length && b.kind !== 'eoa') {
        const folded = collapsedBoxes.has(b.key);
        parts.push(`<button type="button" class="fold ${ch(b.chain)}" data-fold="${esc(b.key)}" style="left:${b.x + b.w - 34}px;top:${b.y + b.h - 30}px" aria-expanded="${!folded}" title="${folded ? `Show the ${b.size} contract${b.size === 1 ? '' : 's'} it calls` : 'Fold the contracts it calls'}">${folded ? `+${b.size}` : '−'}</button>`);
      }
    }
    const tags = new Set();
    for (const e of edges) {
      const a = e.A, b = e.B, nodes = e.calls.map(c => M.nodes[c.id]);
      const cross = a.kind !== 'eoa' && a.chain !== b.chain, hot = isHot(e), dim = focus && !hot ? ' dim' : '';
      const withValue = e.calls.filter(c => M.nodes[c.id].ret.status !== 'void' || opt.voidReturns);
      const bad = nodes.some(n => n.ret.status === 'revert'), cls = cross ? 'cross' : ch(b.chain);
      svg.push(`<path class="edge ${cls}${hot ? ' hot' : ''}${dim}" d="${roundPath(e.pts)}" marker-end="url(#g-call-${cls})"/>`);
      if (!e.self && withValue.length && (returnsOn || hot)) {
        svg.push(`<path class="edge back${bad ? ' bad' : ''}${hot ? ' hot' : ''}${dim}" d="${roundPath(returnPts(e.pts))}" marker-end="url(#g-${bad ? 'bad' : 'ret'})"/>`);
      }
      // The label sits on the last segment, just before the arrowhead, inside the space
      // the layout reserved for it: right-aligned on a left port, left-aligned on a right port.
      const [ex, ey] = e.pts.at(-1), left = e.side === 'l';
      const pos = `style="left:${left ? ex - LBL_GAP + 2 : ex + LBL_GAP - 2}px;top:${ey}px;max-width:${e.label.w}px"`;
      const cls2 = `lbl port-${left ? 'l' : 'r'}`;
      const shownCall = e.calls.length === 1 ? e.calls[0] : e.calls.find(c => cur && ['node', 'return', 'cross'].includes(cur.kind) && cur.id === c.id);
      if (shownCall) {
        const l = lineText(shownCall), sel = cur && ['node', 'return', 'cross'].includes(cur.kind) && cur.id === l.id ? ' sel' : '';
        const more = e.calls.length > 1 ? ` <span class="more-n">+${e.calls.length - 1}</span>` : '';
        parts.push(`<button type="button" class="${cls2}${sel}${dim}" data-node="${l.id}" ${pos} title="${esc(`${l.num}. ${nameOf(M.nodes[l.id])}.${l.f}${l.r}`)}"><span class="num">${l.num}</span><span class="f">${esc(l.f)}</span>${l.r ? `<span class="r${l.bad ? ' bad' : ''}">${esc(l.r)}</span>` : ''}${more}</button>`);
      } else {
        parts.push(`<button type="button" class="${cls2} more${dim}" data-open="${esc(e.key)}" ${pos} title="Show the ${e.calls.length} calls on this arrow">▸ <b>${e.calls.length} calls</b> <span class="f">${esc(e.label.names)}</span></button>`);
      }
      // EEZ tag where the route crosses the chain boundary (one per corridor lane position).
      if (cross) for (let i = 1; i < e.pts.length; i++) {
        const [x0, y0] = e.pts[i - 1], [x1, y1] = e.pts[i];
        const hit = geo.orient === 'columns' ? (x0 - geo.divider) * (x1 - geo.divider) <= 0 && y0 === y1 && [geo.divider, y0] : (y0 - geo.boundary) * (y1 - geo.boundary) <= 0 && x0 === x1 && [x0, geo.boundary];
        if (hit) {
          const key = `${Math.round(hit[0] / 40)}|${Math.round(hit[1] / 30)}`;
          if (opt.protocol && !tags.has(key)) { tags.add(key); parts.push(`<button type="button" class="eez${dim}" data-cross="${e.calls[0].id}" style="left:${hit[0]}px;top:${hit[1]}px" title="How this call crosses chains">EEZ</button>`); }
          break;
        }
      }
    }
    const defs = `<defs>${[['call-l1', 'l1'], ['call-l2', 'l2'], ['call-cross', 'ink'], ['ret', 'ret'], ['bad', 'bad']].map(([id, c]) => `<marker id="g-${id}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M1 1 9 5 1 9" style="fill:none;stroke:var(--${c});stroke-width:1.8"/></marker>`).join('')}</defs>`;
    fitGraph(geo.W, geo.H);
    $('graph').innerHTML = `<svg class="edges" width="${geo.W}" height="${geo.H}" aria-hidden="true">${defs}${svg.join('')}</svg>${parts.join('')}`;
    if (!G.boxes.length || G.boxes.length === 1) $('graph').innerHTML += '<div class="empty" style="position:absolute;inset:40px 0">No application calls in the user transaction.</div>';
  }
  function scrollGraphTo(sel) {
    const el = $('graph').querySelector(sel), wrap = $('graph-wrap');
    if (!el) return;
    // Element offsets are in unscaled drawing pixels; the scroll area is scaled.
    const ex = el.offsetLeft * graphScale, ey = el.offsetTop * graphScale;
    const x = ex - wrap.clientWidth / 2, y = ey - wrap.clientHeight / 2;
    if (ex < wrap.scrollLeft + 40 || ex > wrap.scrollLeft + wrap.clientWidth - 40 || ey < wrap.scrollTop + 30 || ey > wrap.scrollTop + wrap.clientHeight - 30) wrap.scrollTo({ left: Math.max(0, x), top: Math.max(0, y), behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  }
  function describeStep(s) {
    const n = M.nodes[s.id], caller = G.callerOf.get(s.id), cb = G.boxes.find(b => b.key === caller);
    const who = cb ? (cb.kind === 'eoa' ? 'The transaction sender' : `<b>${esc(cb.name)}</b> on ${cb.chain}`) : 'The caller';
    const cross = cb && cb.kind !== 'eoa' && cb.chain !== n.chain;
    if (s.type === 'call') return `<b>${s.num}.</b> ${who} calls <b>${esc(nameOf(n))}</b>.${esc(argsText(n))}${cross ? ` on ${n.chain}, through EEZ` : ''}.`;
    const r = n.ret.status === 'revert' ? `reverts with <b>${esc(n.ret.reason)}</b>` : n.ret.status === 'void' ? 'finishes and returns nothing' : `returns <b>${esc(returnText(n))}</b>`;
    return `<b>${s.num}.</b> <b>${esc(nameOf(n))}</b> ${r}${cb && cb.kind !== 'eoa' ? ` to ${esc(cb.name)}${cross ? ` on ${cb.chain}` : ''}` : ''}.`;
  }
  function inspectBox(key) {
    const b = G.boxes.find(x => x.key === key);
    if (!b) return;
    $('i-kind').className = `badge ${b.chain.toLowerCase()}`; $('i-kind').textContent = b.kind === 'eoa' ? 'Sender' : `${b.chain} contract`;
    const list = calls => calls.length ? `<div class="calls-list">${calls.map(c => `<button type="button" data-node="${c.id}"><span class="num" style="background:var(--ink);color:var(--surface);border-radius:8px;padding:0 5px">${c.num}</span>${esc(nameOf(M.nodes[c.id]))}.${esc(argsText(M.nodes[c.id]))}</button>`).join('')}</div>` : '<p class="note">None</p>';
    const inbound = G.edges.filter(e => e.to === key).flatMap(e => e.calls), outbound = G.edges.filter(e => e.from === key).flatMap(e => e.calls);
    $('inspector').innerHTML = `<div><h2 class="i-title">${esc(b.name)}</h2></div>${field(b.kind === 'eoa' ? 'Address' : 'Contract', b.address, { copy: true })}
      <div class="sec"><h3>Calls it received (${inbound.length})</h3>${b.kind === 'eoa' ? '<p class="note">It sent the transaction.</p>' : list(inbound.sort((x, y) => x.num - y.num))}</div>
      <div class="sec"><h3>Calls it made (${outbound.length})</h3>${list(outbound.sort((x, y) => x.num - y.num))}</div>`;
  }
  function inspectEdge(key) {
    const e = G.edges.find(x => x.key === key), a = G.boxes.find(b => b.key === e.from), b = G.boxes.find(x => x.key === e.to);
    $('i-kind').className = 'badge'; $('i-kind').textContent = 'Calls';
    $('inspector').innerHTML = `<div><h2 class="i-title">${esc(a.name)} → ${esc(b.name)}</h2></div><div class="calls-list">${e.calls.map(c => `<button type="button" data-node="${c.id}"><span>${c.num}.</span>${esc(argsText(M.nodes[c.id]))} <span style="color:var(--muted)">↩ ${esc(returnText(M.nodes[c.id]))}</span></button>`).join('')}</div>`;
  }

  // ---------- render ----------
  function render(keepScroll = true) {
    if (view === 'flow') { renderFlow(); return; }
    if (view === 'sequence') { renderSequence(); return; }
    if (isMap()) { renderGraph(); return; }
    renderTimeline(keepScroll);
  }
  function renderTimeline(keepScroll = true) {
    const sc = $('scroller'), top = sc.scrollTop, left = sc.scrollLeft;
    layout = computeLayout(sc.clientWidth);
    const { rows, height, geo } = layout;
    $('lanes-head').style.setProperty('--gutter', GUTTER + 'px');
    $('lanes-head').style.width = geo.W + 'px';
    const lt = c => `<div class="lane-title ${c.toLowerCase()}"><span class="badge ${c.toLowerCase()}">${c}</span>${esc(M.chains[c].name)}<button type="button" class="lane-btn" data-lane="${c}" title="Expand every ${c} call">expand ${c}</button><small>${M.chains[c].chainId ? 'chain ' + esc(M.chains[c].chainId) : ''}</small></div>`;
    $('lanes-head').innerHTML = `${lt('L1')}<div class="gutter-title">crossing</div>${lt('L2')}`;
    const parts = [], svg = [];
    parts.push(`<div class="lane-bg l1" style="left:0;width:${geo.gutL}px"></div><div class="lane-bg gut" style="left:${geo.gutL}px;width:${GUTTER}px"></div><div class="lane-bg l2" style="left:${geo.gutR}px;width:${geo.W - geo.gutR}px"></div>`);
    const mid = r => r.y + CARD_H / 2;
    for (const row of rows) {
      if (row.type === 'head') {
        const r = row.root, tx = M.transactions.find(t => t.hash === r.tx && t.chain === r.chain);
        const st = tx ? `<span class="badge ${tx.status === 'success' ? 'ok' : tx.status === 'reverted' ? 'bad' : 'warn'}">${esc(tx.status)}</span>` : '';
        parts.push(`<div class="txhead" style="top:${row.y + 4}px"><span class="badge ${r.chain.toLowerCase()}">${r.chain}</span><b>${esc(r.label)}</b>${st}<code title="${esc(r.tx)}">${esc(r.tx)}</code><span class="mono" style="white-space:nowrap">${r.block != null ? '#' + Number(r.block).toLocaleString('en-US') : ''}</span>${r.isOrigin ? `<span title="${esc(r.from)}">from ${esc(short(r.from))}</span>` : ''}<button type="button" class="btn" data-root="${row.index}">${row.open ? 'Hide' : `Show ${row.count} call${row.count === 1 ? '' : 's'}`}</button></div>`);
        continue;
      }
      if (row.type === 'return') continue;
      const n = M.nodes[row.id], c = n.chain.toLowerCase();
      const status = n.kind === 'ghost' ? ['warn', '?'] : n.failed ? ['bad', '✕'] : n.reverted ? ['warn', '↺'] : null;
      const tags = [];
      if (n.preparedResponse) tags.push('<span class="tag">prepared response from table</span>');
      if (n.preparedResult) tags.push('<span class="tag">prepared result · no L2 delivery</span>');
      if (n.isStatic) tags.push('<span class="tag">read</span>');
      if (n.value && n.value !== '0') tags.push(`<span class="tag chain">${esc(ether(n.value))}</span>`);
      if (n.kind === 'ghost') tags.push(`<span class="tag warn">${esc(n.crossing?.status || 'unresolved')} · not observed</span>`);
      if (n.reverted && !n.failed) tags.push('<span class="tag bad">rolled back</span>');
      if (n.impl && n.impl.contract !== n.contract) tags.push(`<span class="tag">via ${esc(n.contract)}</span>`);
      if (n.protocol) tags.push('<span class="tag">EEZ</span>');
      if (n.callType.startsWith('CREATE')) tags.push('<span class="tag">deploy</span>');
      const name = n.impl && n.impl.contract !== 'Unknown contract' ? n.impl.contract : n.contract;
      const fn = argsText(n);
      const cls = ['card', c, n.kind === 'ghost' ? 'ghost' : '', n.protocol ? 'proto' : '', n.failed ? 'rev' : '', isSel('node', row.id) ? 'sel' : '', matches.includes(row.id) ? 'hit' : ''].join(' ');
      parts.push(`<button type="button" class="${cls}" data-node="${row.id}" style="left:${row.x}px;top:${row.y}px;width:${row.w}px;--card-h:${CARD_H}px" title="${esc(`${name} · ${short(n.address)}\n${fn}`)}"><span class="c-name">${esc(name)}</span><span class="c-fn">${esc(fn)}</span>${tags.join('')}${status ? `<span class="c-status ${status[0]}" aria-label="${n.failed ? 'reverted' : n.kind === 'ghost' ? 'not observed' : 'rolled back'}">${status[1]}</span>` : ''}</button>`);
      const total = kids(row.id).length;
      if (total) {
        const open = expanded.has(row.id);
        parts.push(`<button type="button" class="toggle ${c}" data-toggle="${row.id}" style="left:${row.rail - 7}px;top:${row.y + CARD_H - 6}px" aria-expanded="${open}" title="${open ? 'Collapse' : 'Expand'} this call's execution"><i>${open ? '−' : '+'}</i>${open ? '' : `${row.hidden} call${row.hidden === 1 ? '' : 's'}`}</button>`);
      }
      // Rail: the call is in progress from its card to its return arrow.
      const last = row.ret ? row.ret.y + RET_H / 2 : row.childRows.length ? mid(row.childRows.at(-1)) : null;
      if (last != null) svg.push(`<path class="rail ${c}" data-n="${row.id}" d="M${row.rail} ${row.y + CARD_H} V${last}"/>`);
      // Call arrow from the caller's rail into this card.
      if (row.parent) {
        const p = row.parent, y = mid(row), hot = isSel('node', row.id) ? ' hot' : '';
        if (row.crossIn) {
          const toRight = row.chain === 'L2', x2 = toRight ? row.x : row.x + row.w;
          svg.push(`<path class="call cross${hot}" data-n="${row.id}" d="M${p.rail} ${y} H${x2 + (toRight ? -2 : 2)}" marker-end="url(#m-${c})"/>`);
          const cr = n.crossing || {};
          parts.push(`<button type="button" class="xlabel ${esc(cr.status || '')} ${isSel('cross', row.id) ? 'sel' : ''}" data-cross="${row.id}" style="left:${geo.W / 2}px;top:${y - 8}px;transform:translateX(-50%)" title="Inspect the evidence for this crossing"><span class="dot"></span>${p.chain}→${row.chain}${cr.isStatic ? ' view' : ''}</button>`);
        } else {
          svg.push(`<path class="call ${c}${hot}" data-n="${row.id}" d="M${p.rail} ${y} H${row.x - 2}" marker-end="url(#m-${c})"/>`);
        }
      }
      // Return arrow from this call's rail back to the caller's rail.
      if (row.ret) {
        const y = row.ret.y + RET_H / 2, bad = n.ret.status === 'revert', text = returnText(n), hot = isSel('return', row.id) || isSel('node', row.id) ? ' hot' : '';
        const target = row.parent ? row.parent.rail : row.chain === 'L1' ? geo.l1x - 4 : geo.l2x - 4;
        svg.push(`<path class="ret${row.crossIn ? ' cross' : ''}${bad ? ' bad' : ''}${hot}" data-n="${row.id}" d="M${row.rail} ${y} H${target + (target < row.rail ? 3 : -3)}" marker-end="url(#m-${bad ? 'bad' : 'ret'})"/>`);
        const label = `<b>↩</b><span>${esc(text)}</span>`, sel = isSel('return', row.id) ? ' sel' : '';
        if (row.crossIn) {
          parts.push(`<button type="button" class="pill${bad ? ' bad' : ''}${sel}" data-ret="${row.id}" style="left:${geo.W / 2}px;top:${y - 9}px;transform:translateX(-50%);--pill-max:${Math.min(320, geo.W * 0.4)}px" title="${esc(text)}">${label}</button>`);
        } else {
          const laneEnd = row.chain === 'L1' ? geo.gutL : geo.W;
          parts.push(`<button type="button" class="pill${bad ? ' bad' : ''}${sel}" data-ret="${row.id}" style="left:${row.rail + 10}px;top:${y - 9}px;--pill-max:${Math.max(120, laneEnd - row.rail - 24)}px" title="${esc(text)}">${label}</button>`);
        }
      }
    }
    const defs = `<defs><linearGradient id="cross-grad" gradientUnits="userSpaceOnUse" x1="${geo.gutL - 40}" y1="0" x2="${geo.gutR + 40}" y2="0"><stop offset="0" style="stop-color:var(--l1)"/><stop offset="1" style="stop-color:var(--l2)"/></linearGradient>${['l1', 'l2', 'ret', 'bad'].map(k => `<marker id="m-${k}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M1 1 9 5 1 9" style="fill:none;stroke:var(--${k});stroke-width:1.8"/></marker>`).join('')}</defs>`;
    $('canvas').style.width = geo.W + 'px';
    $('canvas').style.height = height + 'px';
    $('canvas').innerHTML = `<svg class="links" width="${geo.W}" height="${height}" aria-hidden="true">${defs}${svg.join('')}</svg>${parts.join('')}`;
    if (keepScroll) { sc.scrollTop = top; sc.scrollLeft = left; }
  }
  function ether(wei) {
    const v = BigInt(wei), whole = v / 10n ** 18n, frac = (v % 10n ** 18n).toString().padStart(18, '0').replace(/0+$/, '').slice(0, 6);
    return `${whole}${frac ? '.' + frac : ''} ETH`;
  }
  const isSel = (kind, id) => selection && selection.kind === kind && selection.id === id;

  // ---------- inspector ----------
  const field = (label, value, { copy = false, mono = false } = {}) => `<div class="field"><div class="f-label">${esc(label)}${copy && value ? ` <button type="button" class="copy" data-copy="${esc(value)}">copy</button>` : ''}</div><div class="f-value ${mono || copy ? 'mono' : ''}">${esc(value ?? '—')}</div></div>`;
  const kv = list => list.length ? `<dl class="kv">${list.map(a => `<dt>${esc(a.name || '·')}${a.type ? ` <span style="color:var(--faint)">${esc(a.type)}</span>` : ''}</dt><dd>${esc(typeof a.value === 'object' ? JSON.stringify(a.value, null, 1) : a.value)}</dd>`).join('')}</dl>` : '<p class="note">None</p>';
  function retSection(n) {
    const r = n.ret;
    if (r.status === 'ok') return kv(r.items);
    if (r.status === 'revert') return `<p class="note" style="color:var(--bad)">Reverted: ${esc(r.reason)}</p>`;
    if (r.status === 'void') return '<p class="note">No return value.</p>';
    if (r.status === 'created') return `<p class="note">Deployed ${esc(n.address)}</p>`;
    if (r.status === 'precomputed') return `<p class="note">No remote execution was observed. The execution table supplied this result:</p><pre class="box">${esc(r.raw)}</pre>`;
    if (r.status === 'unknown') return `<p class="note">No unique remote execution was observed${r.alternatives ? `; ${r.alternatives} table entries could supply the result` : ''}.</p>`;
    return `<p class="note">Return bytes were not decoded (no ABI).</p><pre class="box">${esc(r.raw)}</pre>`;
  }
  function crossSection(n) {
    const c = n.crossing;
    if (!c) return '';
    const status = c.status === 'matched' ? 'ok' : 'warn';
    return `<div class="sec"><h3>Crossing ${esc(c.from)} → ${esc(c.to)} <span class="badge ${status}">${esc(c.status)}</span></h3>
      ${c.evidence.length ? `<div class="chips">${c.evidence.map(e => `<span>${esc(e)}</span>`).join('')}</div>` : `<p class="note">${c.status === 'matched' ? '' : 'The remote execution could not be uniquely identified. The card shows the requested call only.'}</p>`}
      ${field(`Caller on ${c.from} (logical source)`, c.sourceAddress, { copy: true })}
      ${field(`${c.from} proxy that was called`, c.localProxy, { copy: true })}
      ${c.remoteProxy ? field(`${c.to} proxy that executed the call`, c.remoteProxy, { copy: true }) : ''}
      ${c.hashes[0] ? field('Cross-chain call hash', c.hashes[0], { copy: true }) : ''}
      ${c.remoteTx ? field(`${c.to} transaction`, c.remoteTx, { copy: true }) : ''}
      ${c.precomputed.length ? `<details><summary>Execution-table results (${c.precomputed.length})</summary><pre class="box">${esc(JSON.stringify(c.precomputed, null, 1))}</pre></details>` : ''}</div>`;
  }
  // ---------- verify links ----------
  // Explorer website per chain (already reduced to scheme/host/path by model.mjs).
  const explorerLink = (chain, kind, value, text) => {
    const base = M.chains[chain]?.explorer;
    return base && value ? `<a href="${esc(`${base}/${kind}/${value}`)}" target="_blank" rel="noopener noreferrer">${esc(text ?? value)}</a>` : esc(text ?? value ?? '—');
  };
  function verifyContracts() {
    const map = new Map();
    for (const n of M.nodes) {
      if (n.kind === 'ghost' && !n.address) continue;
      const address = n.impl?.address || n.address;
      if (!address) continue;
      const key = `${n.chain}:${address.toLowerCase()}`;
      const c = map.get(key) || map.set(key, { key, chain: n.chain, address, proxy: n.impl ? n.address : null, name: nameOf(n), calls: 0, protocol: n.protocol, abi: null, observed: false }).get(key);
      c.calls++;
      c.observed ||= n.kind !== 'ghost';
      if (n.abiSource && (!c.abi || n.abiSource.startsWith('explorer'))) c.abi = n.abiSource + (n.abiProvider ? ` · ${n.abiProvider}` : '');
      c.protocol &&= n.protocol;
    }
    const tags = new Map((G?.boxes || []).filter(b => b.tag != null).map(b => [b.key, b]));
    return [...map.values()].map(c => ({ ...c, box: tags.get(c.key) })).sort((a, b) => Number(a.protocol) - Number(b.protocol) || (a.box?.cid ?? 1e9) - (b.box?.cid ?? 1e9) || a.chain.localeCompare(b.chain));
  }
  function renderVerify() {
    const txRow = t => `<tr${sectionOf(t) === 'other' ? ' class="proto-row"' : ''}><td><span class="badge ${t.chain.toLowerCase()}">${t.chain}</span></td><td><b>${esc(t.label)}</b>${t.requested ? ' <span class="badge">requested</span>' : ''}${sectionOf(t) === 'other' ? ' <span class="badge warn">not part of this flow</span>' : ''}${t.evidence?.length ? `<div class="sub">${esc(t.evidence.join('; '))}</div>` : ''}</td><td class="mono">${explorerLink(t.chain, 'tx', t.hash)}</td><td class="num-col">${t.block != null ? Number(t.block).toLocaleString('en-US') : '—'}</td><td><span class="badge ${t.status === 'success' ? 'ok' : t.status === 'reverted' ? 'bad' : 'warn'}">${esc(t.status)}</span>${t.traced ? '' : ' <span class="badge warn">no trace</span>'}</td></tr>`;
    const txRows = [['flow', 'This flow'], ['settlement', 'L1 settlement'], ['plumbing', 'EEZ plumbing'], ['other', 'Not part of this flow']].map(([key, title]) => {
      const list = M.transactions.filter(t => sectionOf(t) === key);
      return list.length ? `<tr class="group-row"><td colspan="5">${title}</td></tr>${list.map(txRow).join('')}` : '';
    }).join('');
    const cRows = verifyContracts().map(c => `<tr${c.protocol ? ' class="proto-row"' : ''}><td>${c.box ? tagHtml(c.box) : ''}</td><td><span class="badge ${c.chain.toLowerCase()}">${c.chain}</span></td><td><b>${esc(c.name)}</b>${c.protocol ? ' <span class="tag">EEZ</span>' : ''}${c.observed ? '' : ' <span class="tag warn">not observed</span>'}</td><td class="mono">${explorerLink(c.chain, 'address', c.address)}${c.proxy ? `<div class="sub">via proxy ${explorerLink(c.chain, 'address', c.proxy)}</div>` : ''}</td><td class="num-col">${c.calls}</td><td>${c.abi?.startsWith('explorer') ? `<span class="badge ok">verified source</span>` : c.abi === 'local-protocol' ? '<span class="badge">protocol ABI</span>' : c.abi ? `<span class="badge warn">${esc(c.abi)}</span>` : '<span class="badge warn">no ABI</span>'}</td></tr>`).join('');
    const noLinks = ['L1', 'L2'].filter(c => !M.chains[c]?.explorer);
    $('verify').innerHTML = `<div class="verify-head"><h2>Verify on the explorers</h2><p class="note">Every transaction and contract in this trace. Links open the chain's explorer in a new tab.${noLinks.length ? ` No explorer website is known for ${noLinks.join(' and ')}; pass <code>--${noLinks[0].toLowerCase()}-explorer-url</code> to add links.` : ''}</p></div>
      <h3>Transactions (${M.transactions.length})</h3><div class="table-wrap"><table><thead><tr><th>Chain</th><th>Role</th><th>Hash</th><th class="num-col">Block</th><th>Status</th></tr></thead><tbody>${txRows}</tbody></table></div>
      <h3>Contracts (${verifyContracts().length})</h3><div class="table-wrap"><table><thead><tr><th></th><th>Chain</th><th>Name</th><th>Address</th><th class="num-col">Calls</th><th>ABI</th></tr></thead><tbody>${cRows}</tbody></table></div>`;
  }
  // Readable execution table for postAndVerifyBatch / loadExecutionTable / executeIncomingCrossChainCall.
  const ZERO = '0x' + '0'.repeat(64);
  // Parameters may be named or positional, depending on the ABI the decoder used.
  function tableOf(n) {
    const fn = n.fn.replace(/\(.*$/, '');
    if (!TABLE_FNS.includes(fn)) return null;
    const arg = (name, i) => n.args.find(a => a.name === name)?.value ?? n.args[i]?.value;
    const batch = fn === 'postAndVerifyBatch' ? arg('batch', 0) || {} : null;
    const list = v => Array.isArray(v) ? v : [];
    return { fn, batch, entries: list(batch ? batch.entries : arg('entries', 0)), statics: list(batch ? batch.staticEntries : arg('staticEntries', 1)) };
  }
  function tableSection(n) {
    const t = tableOf(n);
    if (!t) return '';
    const { batch, entries, statics } = t;
    const callLine = c => `<li><span class="mono">${esc(valueText(c.sourceAddress))}${c.sourceRollupId != null ? ` (rollup ${esc(c.sourceRollupId)})` : ''} → ${esc(valueText(c.targetAddress))} · ${esc(String(c.data || '0x').slice(0, 10))}</span>${c.value && c.value !== '0' ? ` · ${esc(ether(c.value))}` : ''}${c.isStatic ? ' · <span class="tag">read</span>' : ''}${Number(c.revertNextNCalls) ? ` · <span class="tag warn">revert next ${esc(c.revertNextNCalls)}</span>` : ''}</li>`;
    const entryHtml = (e, i, isStatic) => {
      const calls = e.l2ToL1Calls || e.incomingCalls || [];
      const reentrant = e.expectedL1ToL2Calls || e.expectedOutgoingCalls || [];
      const l2tx = String(e.proxyEntryHash).toLowerCase() === ZERO;
      return `<details${i === 0 ? ' open' : ''}><summary>${isStatic ? 'Static entry' : 'Entry'} #${i} · ${l2tx ? '<span class="badge warn">L2Tx · started on L2</span>' : `proxyEntryHash ${esc(valueText(e.proxyEntryHash))}`} · ${e.success === false ? '<span class="badge bad">reverts</span>' : '<span class="badge ok">succeeds</span>'}</summary>
        <dl class="kv">${e.destinationRollupId != null ? `<dt>destination</dt><dd>rollup ${esc(e.destinationRollupId)}</dd>` : ''}${(e.rollupUpdates || []).map(u => `<dt>rollup ${esc(u.rollupId)}</dt><dd>${esc(valueText(u.currentRoot))} → ${esc(valueText(u.newRoot))}${u.etherDelta && u.etherDelta !== '0' ? ` · Δ ${esc(u.etherDelta)} wei` : ''}</dd>`).join('')}<dt>rolling hash</dt><dd>${esc(valueText(e.rollingHash))}</dd>${e.returnData && e.returnData !== '0x' ? `<dt>return data</dt><dd>${esc(valueText(e.returnData))}</dd>` : ''}</dl>
        <p class="note">${calls.length} call${calls.length === 1 ? '' : 's'}${reentrant.length ? `, ${reentrant.length} reentrant row${reentrant.length === 1 ? '' : 's'}` : ''}</p>
        ${calls.length ? `<ol class="entry-calls">${calls.map(callLine).join('')}</ol>` : ''}
        ${reentrant.map((r, j) => `<p class="note">Reentrant row ${j} · ${r.success === false ? 'reverts' : 'succeeds'} · key ${esc(valueText(r.expectedL1toL2Hash || r.expectedOutgoingHash))}</p>${(r.l2ToL1Calls || r.incomingCalls || []).length ? `<ol class="entry-calls">${(r.l2ToL1Calls || r.incomingCalls).map(callLine).join('')}</ol>` : ''}`).join('')}
      </details>`;
    };
    const extra = batch ? `<p class="note">${esc(batch.immediateEntryCount ?? 0)} immediate entr${String(batch.immediateEntryCount) === '1' ? 'y' : 'ies'} run inside this transaction · ${(batch.proofSystems || []).length} proof system${(batch.proofSystems || []).length === 1 ? '' : 's'}</p>` : '';
    return `<div class="sec"><h3>Execution table · ${entries.length} entr${entries.length === 1 ? 'y' : 'ies'}${statics.length ? `, ${statics.length} static` : ''}</h3>${extra}${entries.map((e, i) => entryHtml(e, i, false)).join('')}${statics.map((e, i) => entryHtml(e, i, true)).join('')}</div>`;
  }
  function sameContractSection(n, id) {
    const cb = G?.boxes.find(b => b.key === boxKeyOf(n));
    if (!cb || cb.tag == null || cb.calls.length < 2) return '';
    return `<div class="sec"><h3>${tagHtml(cb)} All ${cb.calls.length} calls to ${esc(cb.name)}</h3><div class="calls-list">${cb.calls.map(c => `<button type="button" data-node="${c.id}"${c.id === id ? ' aria-current="true"' : ''}><span>${c.num}.</span>${esc(argsText(M.nodes[c.id]))} <span style="color:var(--muted)">→ ${esc(returnText(M.nodes[c.id]))}</span></button>`).join('')}</div></div>`;
  }
  function inspectNode(id) {
    const n = M.nodes[id], c = n.chain.toLowerCase();
    $('i-kind').className = `badge ${c}`; $('i-kind').textContent = n.kind === 'ghost' ? `${n.chain} · not observed` : `${n.chain} · ${n.callType}`;
    const status = n.kind === 'ghost' ? '<span class="badge warn">Remote trace missing</span>' : n.failed ? '<span class="badge bad">Reverted</span>' : n.reverted ? '<span class="badge warn">Rolled back by an outer revert</span>' : '<span class="badge ok">Succeeded</span>';
    const responseLabel = n.preparedResponse ? '<span class="badge">L2 request · prepared response from loaded table</span>' : n.preparedResult ? '<span class="badge">Prepared result · no L2 delivery expected</span>' : '';

    const name = n.impl && n.impl.contract !== 'Unknown contract' ? n.impl.contract : n.contract;
    $('inspector').innerHTML = `<div>${status} ${responseLabel}</div><div><h2 class="i-title">${esc(name)}</h2><div class="i-fn ${c}">${esc(tableOf(n) ? argsText(n) : n.signature || n.fn)}</div></div>
      ${field('Contract', n.address, { copy: true })}
      ${n.preparedResponse ? `<p class="note">This is the observed L2 proxy request. Its result comes from the loaded table; the linked L1 entry contains the remote execution.</p>${field('Remote contract on ' + n.remoteChain, n.remoteAddress, { copy: true })}` : ''}
      ${n.impl ? field(`Implementation (DELEGATECALL from ${n.contract})`, n.impl.address, { copy: true }) : ''}
      ${M.chains[n.chain]?.explorer ? `<div class="links">${n.address ? explorerLink(n.chain, 'address', n.impl?.address || n.address, 'Contract on explorer ↗') : ''}${n.tx ? explorerLink(n.chain, 'tx', n.tx, 'Transaction on explorer ↗') : ''}</div>` : ''}
      ${tableSection(n)}
      ${sameContractSection(n, id)}
      ${field('Called by', n.from, { copy: true })}
      <div class="row2">${field('Value', n.value === '0' ? '0' : ether(n.value))}${field('Gas used (incl. children)', n.gasUsed ? BigInt(n.gasUsed).toLocaleString('en-US') : '—')}</div>
      <div class="sec"><h3>Arguments</h3>${tableSection(n) ? '<p class="note">An execution table, shown decoded below. The raw value is under "Raw calldata".</p>' : n.signature ? kv(n.args) : '<p class="note">Calldata not decoded (no ABI for this contract).</p>'}</div>
      <div class="sec"><h3>Returns</h3>${retSection(n)}</div>
      ${crossSection(n)}
      <div class="sec"><h3>Where it ran</h3>${n.tx ? field('Transaction', n.tx, { copy: true }) : '<p class="note">No physical frame: this call was not observed on its chain.</p>'}
      <div class="row2">${field('Block', n.block != null ? Number(n.block).toLocaleString('en-US') : '—')}${field('Call path', n.path, { mono: true })}</div>
      <p class="note">ABI: ${esc(n.abiSource ? n.abiSource + (n.abiProvider ? ' · ' + n.abiProvider : '') : 'none, raw bytes only')}</p></div>
      <details><summary>Raw calldata and output</summary><div class="f-label">Input <button type="button" class="copy" data-copy="${esc(n.input)}">copy</button></div><pre class="box">${esc(n.input)}</pre>${n.output != null ? `<div class="f-label" style="margin-top:6px">Output <button type="button" class="copy" data-copy="${esc(n.output)}">copy</button></div><pre class="box">${esc(n.output)}</pre>` : ''}${n.frameId ? `<div class="f-label" style="margin-top:6px">Frame ID</div><pre class="box">${esc(n.frameId)}</pre>` : ''}</details>`;
  }
  function inspectReturn(id) {
    const n = M.nodes[id], parent = parentMap().get(id), p = parent != null ? M.nodes[parent] : null;
    const cross = p && p.chain !== n.chain;
    $('i-kind').className = `badge ${n.ret.status === 'revert' ? 'bad' : 'ok'}`; $('i-kind').textContent = cross ? `${n.chain} → ${p.chain} return` : 'Return';
    $('inspector').innerHTML = `<div><h2 class="i-title">${p ? `Back to ${esc(p.impl?.contract && p.impl.contract !== 'Unknown contract' ? p.impl.contract : p.contract)}` : 'Back to the transaction sender'}</h2><div class="i-fn ${n.chain.toLowerCase()}">${esc(n.contract)}.${esc(n.fn)}</div></div>
      <div class="sec"><h3>${n.ret.status === 'revert' ? 'Revert' : 'Returned value'}</h3>${retSection(n)}</div>
      ${cross ? `<div class="sec"><h3>How this value crosses chains</h3><p class="note">The ${esc(p.chain)} caller received this result from EEZ's pre-proven execution table during its own transaction. The ${esc(n.chain)} trace shows the matching execution${n.crossing?.status === 'matched' ? ', and its return bytes match' : ''}. The arrow joins the two; it is not a network round trip.</p></div>` : ''}
      ${n.ret.raw ? `<details${n.ret.status === 'raw' ? ' open' : ''}><summary>Return bytes</summary><pre class="box">${esc(n.ret.raw)}</pre></details>` : ''}`;
  }
  function inspectCross(id) {
    const n = M.nodes[id];
    $('i-kind').className = 'badge'; $('i-kind').textContent = 'Crossing';
    $('inspector').innerHTML = `<div><h2 class="i-title">${esc(n.crossing.from)} → ${esc(n.crossing.to)}: ${esc(n.contract)}</h2><div class="i-fn ${n.chain.toLowerCase()}">${esc(n.signature || n.fn)}</div></div>
      <p class="note">The caller called a local CrossChainProxy for the remote contract. The EEZ manager matched the call to a proven execution-table entry. On the other chain, the matching proxy executed the call against the real target. EEZ plumbing shows those frames.</p>${crossSection(n)}`;
  }
  function inspectSummary() {
    $('i-kind').className = 'badge'; $('i-kind').textContent = 'Trace';
    $('inspector').innerHTML = `<p class="note">Select a card, a crossing label or a return value to see its details.</p>
      <div class="sec"><h3>Transactions in this trace</h3><div class="tx-list">${M.transactions.map(t => `<div class="tx-item"><div><span class="badge ${t.chain.toLowerCase()}">${t.chain}</span> <b>${esc(t.label)}</b> <span class="badge ${t.status === 'success' ? 'ok' : t.status === 'reverted' ? 'bad' : 'warn'}">${esc(t.status)}</span>${t.traced ? '' : ' <span class="badge warn">no trace</span>'}</div><code>${esc(t.hash)}</code><span class="note">block ${t.block != null ? Number(t.block).toLocaleString('en-US') : '—'}${t.gasUsed ? ' · ' + BigInt(t.gasUsed).toLocaleString('en-US') + ' gas' : ''}</span></div>`).join('')}</div></div>
      ${M.settlements.length ? `<div class="sec"><h3>Settlement</h3>${M.settlements.map(s => `${field('L1 settlement transaction', s.l1Tx, { copy: true })}<p class="note">Covers L2 blocks ${s.firstL2Block?.toLocaleString?.('en-US') ?? s.firstL2Block}–${s.lastL2Block?.toLocaleString?.('en-US') ?? s.lastL2Block}</p>`).join('')}</div>` : ''}
      ${M.matchingNotes?.length ? `<details class="sec"><summary>Optional call details (${M.matchingNotes.length})</summary><p class="note">Some individual call matches could not be established. The recorded traces are displayed independently in their original order.</p>${M.matchingNotes.map(u => `<p class="note"><b>${esc(u.code)}</b>: ${esc(u.message)}</p>`).join('')}</details>` : ''}
      ${M.unresolved.length ? `<div class="sec"><h3>Unresolved (${M.unresolved.length})</h3>${M.unresolved.map(u => `<p class="note"><b>${esc(u.code)}</b>: ${esc(u.message)}</p>`).join('')}</div>` : ''}`;
  }
  function select(kind, id, scroll = false) {
    selection = kind ? { kind, id } : null;
    if (kind === 'node') inspectNode(id); else if (kind === 'return') inspectReturn(id); else if (kind === 'cross') inspectCross(id);
    else if (kind === 'box') inspectBox(id); else if (kind === 'edge') inspectEdge(id); else inspectSummary();
    if (scroll && isMap() && ['node', 'return', 'cross'].includes(kind)) reveal(id);
    render();
    if (isMap()) {
      const s = G.seq.find(x => x.id === id && x.type === (kind === 'return' ? 'return' : 'call'));
      $('caption').innerHTML = s ? describeStep(s) : captionIdle();
      if (scroll) scrollGraphTo(kind === 'return' ? `[data-ret="${id}"]` : kind === 'box' ? `[data-box="${id}"]` : `[data-node="${id}"]`);
      return;
    }
    if (scroll) {
      const el = document.querySelector(kind === 'return' ? `[data-ret="${id}"]` : `[data-node="${id}"]`);
      if (el) { const sc = $('scroller'), t = el.offsetTop - sc.clientHeight / 2 + 40; if (t > sc.scrollTop + sc.clientHeight - 120 || t < sc.scrollTop - 60 || el.offsetTop < sc.scrollTop + 40 || el.offsetTop > sc.scrollTop + sc.clientHeight - 60) sc.scrollTo({ top: Math.max(0, t), behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' }); }
    }
  }

  // ---------- walkthrough ----------
  function steps() { return isMap() ? G.seq : layout.rows.filter(r => r.type === 'call' || r.type === 'return'); }
  const captionIdle = () => M.mode === 'physical' && rootIndex === BOTH_CHAINS ? 'Call numbering starts at 1 independently on each chain. Read each recorded tree separately; placement across chains does not establish time or execution order.' : ({
    flow: 'Read left to right: each box is one call, numbered in execution order, with its result after →. A box points to the calls it makes; L1 calls sit above the line, L2 calls below. Press › to follow it step by step.',
    columns: 'Each box is a contract: L1 on the left, L2 on the right. Solid arrows are calls, dashed arrows are return values, and the numbers give the order. Press › to follow it step by step.',
    layers: 'Each box is a contract: L1 above the line, L2 below. Solid arrows are calls, dashed arrows are return values, and the numbers give the order. Press › to follow it step by step.',
    sequence: 'Contracts across the top, L1 left and L2 right. Time runs downwards: each row is one call (solid) or one returned value (dashed). Shaded bars show while a contract is running.',
  }[view] || '');
  function goStep(i) {
    const s = steps();
    if (!s.length) return;
    step = Math.max(0, Math.min(s.length - 1, i));
    const r = s[step], n = M.nodes[r.id];
    $('step').textContent = isMap() ? `Step ${step + 1} of ${s.length}` : `${step + 1} / ${s.length} · ${r.type === 'call' ? `${n.chain} calls ${n.contract}.${n.fn.replace(/\(.*$/, '')}` : `${n.contract} returns ${returnText(n)}`}`;
    select(r.type === 'call' ? 'node' : 'return', r.id, true);
  }
  function stop() { clearInterval(timer); timer = null; $('play').textContent = 'Play'; $('play').setAttribute('aria-pressed', 'false'); }

  // ---------- search ----------
  function search() {
    const q = $('search').value.trim().toLowerCase();
    matches = [];
    if (q) {
      const p = parentMap();
      M.nodes.forEach((n, id) => {
        if (n.protocol && !opt.protocol) return;
        const hay = [n.contract, n.impl?.contract, n.fn, n.address, n.impl?.address, ...n.args.map(a => JSON.stringify(a.value)), returnText(n)].join(' ').toLowerCase();
        if (hay.includes(q)) {
          matches.push(id);
          for (let a = p.get(id); a != null; a = p.get(a)) expanded.add(a);
          M.roots.forEach((r, i) => { if (rootOf(id, p) === r.node || topItems(r).includes(rootOf(id, p))) expanded.add(`root:${i}`); });
        }
      });
    }
    matchAt = -1;
    $('hits').textContent = q ? `${matches.length} match${matches.length === 1 ? '' : 'es'}` : '';
    render();
  }
  function rootOf(id, p) { let a = id; while (p.has(a)) a = p.get(a); return a; }

  // ---------- load ----------
  function load(i) {
    stop(); current = i;
    const linked = traces[i].model;
    M = traceMode === 'physical' && linked.recordedView ? linked.recordedView : linked;
    $('mode-wrap').hidden = !linked.recordedView; $('mode-select').value = M.mode;
    kidsMemo = new Map(); crossMemo.clear();
    selection = null; matches = []; step = -1; $('search').value = ''; $('hits').textContent = '';
    crossesMemo.clear(); kidsMemo = new Map();
    if (!readVisibilityChosen) opt.staticCalls = M.mode === 'physical';
    $('opt-static').checked = opt.staticCalls;
    rootIndex = defaultRoot();
    defaultExpansion(); initMapState(); initFlowState();
    G = graphModel(); // contract tags are read by the inspector in every view
    renderRootPicker(); renderStaticLabel(); renderVerify();
    $('trace-select').value = String(i);
    $('title').textContent = traces[i].label || M.label;
    $('kicker').textContent = traces[i].synthetic ? 'Synthetic example · EEZ call flow' : 'EEZ cross-chain call flow';
    const apps = M.nodes.filter(n => !n.protocol && n.inFlow !== false), contracts = new Set(apps.map(n => `${n.chain}:${(n.impl?.address || n.address || '').toLowerCase()}`));
    const unres = M.stats.crossings - M.stats.matched;
    $('stats').innerHTML = [[apps.length, 'application calls'], [contracts.size, 'contracts'], ...(M.mode === 'physical' ? [[M.stats.preparedResponses || 0, 'L2 prepared responses'], [M.stats.preparedResults || 0, 'L1 results without delivery']] : [[`${M.stats.matched}/${M.stats.crossings}`, 'crossings matched', unres ? 'bad' : '']]), [M.transactions.length, 'transactions'], [M.stats.frames, 'physical frames'], [M.unresolved.length, 'unresolved', M.unresolved.length ? 'bad' : '']].map(([v, l, c]) => `<span class="${c || ''}"><b>${esc(v)}</b> ${l}</span>`).join('');
    $('foot').textContent = `Trace schema ${M.schemaVersion || '?'} · ${traces[i].source || 'embedded'} · Everything shown is embedded in this page; it makes no network requests.`;
    inspectSummary();
    $('step').textContent = 'Step through the calls';
    render(false);
    $('caption').innerHTML = captionIdle();
    $('scroller').scrollTop = 0; resetGraphScroll();
  }
  function toast(msg) { const t = $('toast'); t.textContent = msg; t.hidden = false; clearTimeout(toast.t); toast.t = setTimeout(() => { t.hidden = true; }, 2600); }
  function addTrace(json, name) {
    try {
      const data = JSON.parse(json);
      const model = buildFlowModel(data);
      traces.push({ label: model.label, model, source: name });
      $('trace-select').insertAdjacentHTML('beforeend', `<option value="${traces.length - 1}">${esc(model.label)} · ${esc(name)}</option>`);
      load(traces.length - 1);
      toast(`Drew ${name}`);
    } catch (e) { toast(`Could not draw ${name}: ${e.message}`); }
  }
  function readFile(file) { if (!file) return; const r = new FileReader(); r.onload = () => addTrace(String(r.result), file.name); r.onerror = () => toast(`Could not read ${file.name}`); r.readAsText(file); }

  // ---------- events ----------
  document.addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b) return;
    if (b.dataset.copy != null) {
      const v = b.dataset.copy;
      Promise.resolve().then(() => navigator.clipboard.writeText(v)).then(() => toast('Copied'), () => toast('Clipboard unavailable. Select the value to copy it.'));
      return;
    }
    if (b.dataset.toggle != null) { const id = +b.dataset.toggle; expanded.has(id) ? expanded.delete(id) : expanded.add(id); render(); return; }
    if (b.dataset.root != null) { const k = `root:${b.dataset.root}`; expanded.has(k) ? expanded.delete(k) : expanded.add(k); render(); return; }
    if (b.dataset.lane) { const lane = b.dataset.lane; M.nodes.forEach((n, id) => { if (n.chain === lane) expanded.add(id); }); render(); return; }
    if (b.dataset.node != null) { stop(); select('node', +b.dataset.node); return; }
    if (b.dataset.ret != null) { stop(); select('return', +b.dataset.ret); return; }
    if (b.dataset.cross != null) { stop(); select('cross', +b.dataset.cross); return; }
    if (b.dataset.box != null) { stop(); select('box', b.dataset.box); return; }
    if (b.dataset.edge != null) { stop(); select('edge', b.dataset.edge); return; }
    if (b.dataset.ffold != null) { const k = +b.dataset.ffold; flowFolded.has(k) ? flowFolded.delete(k) : flowFolded.add(k); render(); return; }
    if (b.dataset.fold != null) { const k = b.dataset.fold; collapsedBoxes.has(k) ? collapsedBoxes.delete(k) : collapsedBoxes.add(k); render(); return; }
    if (b.dataset.open != null) { stop(); select('edge', b.dataset.open); }
  });
  function setView(v) {
    stop(); view = v; step = -1;
    for (const t of document.querySelectorAll('.view-tab')) t.setAttribute('aria-selected', String(t.dataset.view === v));
    $('graph-wrap').hidden = !isMap(); $('caption').hidden = !isMap();
    for (const id of ['scroller', 'legend', 'expand-all', 'collapse']) $(id).hidden = isMap();
    $('opt-returns-wrap').hidden = !['columns', 'layers'].includes(v);
    $('zoom').hidden = !isMap();
    $('step').textContent = 'Step through the calls';
    const keep = !isMap() && (selection?.kind === 'box' || selection?.kind === 'edge') ? null : selection;
    resetGraphScroll();
    select(keep?.kind, keep?.id, !!keep);
    if (!keep) $('caption').innerHTML = captionIdle();
    try { localStorage.setItem('eez-flow-view', v); } catch { /* Storage is optional. */ }
  }
  for (const t of document.querySelectorAll('.view-tab')) t.onclick = () => setView(t.dataset.view);
  $('expand-all').onclick = () => { M.nodes.forEach((_, id) => expanded.add(id)); M.roots.forEach((r, i) => { if (r.isOrigin || i === 0) expanded.add(`root:${i}`); }); render(); };
  $('collapse').onclick = () => { defaultExpansion(); render(); };
  // Checkboxes that change which calls exist renumber everything, so rebuild the derived state.
  for (const [id, key] of [['opt-protocol', 'protocol'], ['opt-void', 'voidReturns'], ['opt-static', 'staticCalls']]) $(id).onchange = () => {
    stop(); opt[key] = !!$(id).checked;
    if (key === 'staticCalls') readVisibilityChosen = true;
    kidsMemo = new Map(); crossMemo.clear();
    if (key !== 'voidReturns') {
      // Hiding plumbing also hides system transactions; fall back to the default one.
      if (rootIndex !== BOTH_CHAINS && (!M.roots[rootIndex] || !rootVisible(M.roots[rootIndex]))) rootIndex = defaultRoot();
      const keep = expanded; defaultExpansion(); keep.forEach(k => expanded.add(k));
      selection = null; step = -1; initMapState(); initFlowState(); G = graphModel(); inspectSummary();
      $('caption').innerHTML = captionIdle(); renderRootPicker();
      resetGraphScroll();
    }
    render(); renderStaticLabel();
  };
  function renderStaticLabel() {
    // Exactly what ticking the box adds to the transactions on screen.
    const roots = M ? shownRoots() : [], total = () => roots.reduce((s, r) => s + appCalls(r), 0);
    let n = 0;
    if (!opt.staticCalls && roots.length) {
      const before = total();
      opt.staticCalls = true; kidsMemo = new Map();
      n = total() - before;
      opt.staticCalls = false; kidsMemo = new Map();
    }
    $('opt-static-label').textContent = n ? `Local reads (${n} hidden)` : 'Local reads';
  }
  // Hovering a box lights up every box of the same contract.
  function hoverCid(cid) {
    for (const el of $('graph').querySelectorAll('[data-cid]')) el.classList.toggle('same-hover', cid != null && cid !== '' && el.dataset.cid === cid);
  }
  $('graph').addEventListener('mouseover', e => hoverCid(e.target.closest?.('[data-cid]')?.dataset.cid));
  $('graph').addEventListener('mouseleave', () => hoverCid(null));
  $('zoom-in').onclick = () => setZoom(graphScale * 1.25);
  $('zoom-out').onclick = () => setZoom(graphScale / 1.25);
  $('zoom-fit').onclick = () => { setZoom('fit'); resetGraphScroll(); };
  $('graph-wrap').addEventListener('wheel', e => {
    if (!e.ctrlKey && !e.metaKey) return;
    e.preventDefault();
    setZoom(graphScale * (e.deltaY < 0 ? 1.1 : 1 / 1.1));
  }, { passive: false });
  $('opt-returns').onchange = () => { opt.returns = !!$('opt-returns').checked; render(); };
  $('search').addEventListener('input', search);
  $('search').addEventListener('keydown', e => { if (e.key === 'Enter' && matches.length) { matchAt = (matchAt + 1) % matches.length; select('node', matches[matchAt], true); $('hits').textContent = `${matchAt + 1} of ${matches.length}`; } });
  $('prev').onclick = () => { stop(); goStep(step - 1); };
  $('next').onclick = () => { stop(); goStep(step + 1); };
  $('play').onclick = () => {
    if (timer) return stop();
    $('play').textContent = 'Pause'; $('play').setAttribute('aria-pressed', 'true');
    if (step >= steps().length - 1) step = -1;
    goStep(step + 1);
    timer = setInterval(() => { if (step >= steps().length - 1) stop(); else goStep(step + 1); }, 1400);
  };
  $('trace-select').onchange = e => load(+e.target.value);
  $('mode-select').onchange = e => { traceMode = e.target.value; load(current); };
  $('root-select').onchange = e => {
    stop(); rootIndex = +e.target.value; selection = null; step = -1;
    if (M.roots[rootIndex]?.relatedSettlement && !opt.protocol) {
      opt.protocol = true; $('opt-protocol').checked = true;
      kidsMemo = new Map(); crossMemo.clear(); defaultExpansion();
    }
    initMapState(); initFlowState(); G = graphModel(); renderRootPicker(); renderStaticLabel(); resetGraphScroll();
    inspectSummary(); render(); $('caption').innerHTML = captionIdle();
  };
  $('file').onchange = e => { readFile(e.target.files[0]); e.target.value = ''; };
  let dragDepth = 0;
  addEventListener('dragenter', e => { if ([...(e.dataTransfer?.types || [])].includes('Files')) { dragDepth++; $('drop').hidden = false; } });
  addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; $('drop').hidden = true; } });
  addEventListener('dragover', e => e.preventDefault());
  addEventListener('drop', e => { e.preventDefault(); dragDepth = 0; $('drop').hidden = true; readFile(e.dataTransfer?.files?.[0]); });
  let rz;
  addEventListener('resize', () => { cancelAnimationFrame(rz); rz = requestAnimationFrame(() => M && render()); });

  $('trace-select').innerHTML = traces.map((t, i) => `<option value="${i}">${esc(t.label || t.model.label)}</option>`).join('');
  let saved = null;
  try { saved = localStorage.getItem('eez-flow-view'); } catch { /* Storage is optional. */ }
  for (const t of document.querySelectorAll('.view-tab')) t.hidden = !VIEWS.includes(t.dataset.view);
  if (traces.length) { load(0); setView(VIEWS.includes(saved) ? saved : VIEWS[0] || 'flow'); }
  else { $('canvas').innerHTML = '<div class="empty">Open a JSON file written by <code>decode-trace.mjs --json</code> to draw its call flow.</div>'; }
})();
