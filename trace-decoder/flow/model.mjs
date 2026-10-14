// Converts a trace-decoder result (schema 1.x) into the call-flow diagram model.
// Pure and dependency-free: the viewer inlines this file (minus `export`) so a
// trace JSON opened in the browser goes through exactly the same code.

export const FLOW_MODEL_VERSION = 1;

// Roles the decoder assigns to EEZ plumbing. The diagram folds them by default.
const PROTOCOL_ROLES = new Set(['manager', 'incoming-proxy', 'static-probe', 'outgoing-proxy']);
// Public explorer websites by chain id, used for "verify" links.
const EXPLORER_SITES = { 1: 'https://etherscan.io', 11155111: 'https://sepolia.etherscan.io', 17000: 'https://holesky.etherscan.io', 560048: 'https://hoodi.etherscan.io', 100: 'https://gnosisscan.io', 10200: 'https://gnosis-chiado.blockscout.com' };
// Keeps only scheme, host and path, so an API key or credential can never reach the page.
export function explorerSite(url) {
  try {
    const u = new URL(url);
    // Etherscan API hosts are not websites; those chains use the table above instead.
    if (!/^https?:$/.test(u.protocol) || /(^|\.)etherscan\.io$/.test(u.hostname) && u.hostname.startsWith('api')) return null;
    const p = u.pathname.replace(/\/+$/, '').replace(/\/api(\/v2)?$/, '');
    return `${u.protocol}//${u.host}${p}`;
  } catch { return null; }
}
const CHAIN_NAMES = { 1: 'Ethereum', 100: 'Gnosis', 10200: 'Gnosis Chiado', 11155111: 'Sepolia', 17000: 'Holesky', 560048: 'Hoodi' };
const PRECOMPILES = ['ecrecover', 'sha256', 'ripemd160', 'identity', 'modexp', 'ecAdd', 'ecMul', 'ecPairing', 'blake2f', 'pointEvaluation'];
const lower = v => (v == null ? '' : String(v).toLowerCase());

export function buildFlowModel(trace, { label, explorers = {} } = {}) {
  if (!trace || !Array.isArray(trace.frames) || !Array.isArray(trace.logicalNodes)) {
    throw new Error('This file is not a trace-decoder JSON result: frames and logicalNodes are missing.');
  }
  const frames = new Map(trace.frames.map(f => [f.id, f]));
  const logical = new Map(trace.logicalNodes.map(n => [n.id, n]));
  const outgoingByFrame = new Map((trace.outgoing || []).map(o => [o.frameId, o]));
  const incomingByFrame = new Map((trace.incoming || []).map(i => [i.frameId, i]));
  const nodes = [], seen = new Set();

  function crossing(out) {
    const proxy = frames.get(out.frameId), incoming = out.remoteFrameId ? incomingByFrame.get(out.remoteFrameId) : null;
    const remoteChain = out.chain === 'L1' ? 'L2' : 'L1';
    return {
      from: out.chain, to: remoteChain, status: out.status || 'unresolved', isStatic: !!out.isStatic, value: String(out.value ?? '0'),
      sourceAddress: out.sourceAddress, targetAddress: out.targetAddress,
      sourceRollupId: out.sourceRollupId ?? null, targetRollupId: out.targetRollupId ?? null,
      localProxy: proxy?.to ?? null, managerFrameId: out.managerFrameId ?? null,
      remoteProxy: incoming ? frames.get(incoming.proxyFrameId)?.to ?? null : null,
      remoteTx: out.remoteFrameId ? frames.get(out.remoteFrameId)?.transactionHash ?? null : null,
      hashes: out.hashes || [], evidence: out.matchEvidence || [], resultKind: out.resultKind || null,
      candidates: out.candidates || [], precomputed: (out.precomputedResults || out.entryCandidates || []).map(e => ({ pool: e.pool, index: e.index, success: e.success, returnData: e.returnData })),
      generationId: out.generationId ?? null, settlementIds: out.settlementIds || [],
    };
  }

  const managers = trace.metadata?.managers || {};
  function describe(frame, ln) {
    const d = ln?.decoded || frame.decoded || {};
    let role = ln?.role || frame.role || 'application', contract = d.contractName || 'Unknown contract';
    // Proxy deployment by a manager is delivery plumbing, like the proxies themselves.
    if (frame.type?.startsWith('CREATE') && lower(frame.from) === lower(managers[frame.chain])) role = 'proxy-creation';
    // Precompiles sit at 0x01–0x0a and never make calls of their own.
    const precompile = /^0x0{38}(0[1-9a])$/i.exec(frame.to || '');
    if (contract === 'Unknown contract' && precompile && !(ln?.children || frame.children || []).length) contract = `Precompile · ${PRECOMPILES[parseInt(precompile[1], 16) - 1]}`;
    return {
      kind: 'call', frameId: frame.id, chain: frame.chain, role,
      protocol: PROTOCOL_ROLES.has(role) || role === 'proxy-creation', callType: frame.type || 'CALL',
      contract, address: frame.to ?? null, from: frame.from ?? null,
      fn: functionName(d, frame), signature: d.signature || null, args: (d.arguments || []).map(argument),
      ret: returnInfo(d, frame), value: String(frame.value ?? '0'), isStatic: !!frame.isStatic,
      failed: !!frame.error, reverted: !!frame.reverted, gasUsed: toDecimal(frame.gasUsed),
      tx: frame.transactionHash, block: frame.blockNumber ?? null, path: frame.path,
      abiSource: d.provenance?.source || null, abiProvider: d.provenance?.provider || null,
      input: frame.input || '0x', output: frame.output || '0x', children: [],
    };
  }

  function add(node) { node.id = nodes.length; nodes.push(node); return node.id; }

  function visit(id) {
    if (seen.has(id)) return null;
    const frame = frames.get(id), ln = logical.get(id);
    if (!frame || !ln) return null;
    seen.add(id);
    const node = describe(frame, ln), index = add(node);
    let children = [...ln.children];
    // A proxy forwarding the same calldata by DELEGATECALL is one logical call.
    for (let i = 0; i < children.length; i++) {
      const child = frames.get(children[i]);
      if (!child || child.type !== 'DELEGATECALL' || child.input !== frame.input || seen.has(child.id)) continue;
      seen.add(child.id);
      const inner = logical.get(child.id), d = inner?.decoded || child.decoded || {};
      node.impl = { contract: d.contractName || 'Unknown contract', address: child.to, frameId: child.id };
      if (!node.signature && d.signature) Object.assign(node, { fn: functionName(d, child), signature: d.signature, args: (d.arguments || []).map(argument), ret: returnInfo(d, child), abiSource: d.provenance?.source || null });
      children.splice(i, 1, ...(inner?.children || [])); i--;
    }
    const out = outgoingByFrame.get(id);
    if (out) {
      const info = crossing(out);
      node.outgoing = info;
      if (out.remoteFrameId && children.includes(out.remoteFrameId)) {
        node.remoteChild = out.remoteFrameId;
      } else {
        // No observed remote execution: show the requested call as a ghost. The
        // manager subtree hangs under it, since anything it ran happened during that call.
        const rc = out.remoteCall || {};
        const ghost = {
          kind: 'ghost', frameId: null, chain: info.to, role: 'application', protocol: false, callType: out.isStatic ? 'STATICCALL' : 'CALL',
          contract: rc.contractName || 'Unknown contract', address: out.targetAddress, from: out.sourceAddress,
          fn: functionName(rc, { input: out.data }), signature: rc.signature || null, args: (rc.arguments || []).map(argument),
          ret: ghostReturn(info), value: info.value, isStatic: !!out.isStatic, failed: false, reverted: !!out.reverted,
          gasUsed: null, tx: null, block: null, path: null, abiSource: rc.provenance?.source || null, abiProvider: rc.provenance?.provider || null,
          input: out.data || '0x', output: null, children: [], crossing: info,
        };
        const gi = add(ghost);
        const at = Math.max(0, children.indexOf(out.managerFrameId));
        const manager = children.includes(out.managerFrameId) ? [out.managerFrameId] : [];
        children = children.filter(c => c !== out.managerFrameId);
        node.children = [];
        for (const c of children.slice(0, at)) { const v = visit(c); if (v != null) node.children.push(v); }
        node.children.push(gi);
        for (const c of manager) { const v = visit(c); if (v != null) ghost.children.push(v); }
        for (const c of children.slice(at)) { const v = visit(c); if (v != null) node.children.push(v); }
        return index;
      }
    }
    for (const c of children) {
      const v = visit(c);
      if (v == null) continue;
      node.children.push(v);
      if (out && c === out.remoteFrameId) nodes[v].crossing = node.outgoing;
    }
    return index;
  }

  const originTx = trace.origin?.transactionId || (trace.origin ? `${trace.origin.chain}:${trace.txHash}` : null);
  const transactions = (trace.transactions || []).map(tx => ({
    chain: tx.chain, hash: tx.hash, block: tx.blockNumber ?? null, index: tx.transactionIndex ?? null,
    from: tx.transaction?.from ?? null, to: tx.transaction?.to ?? null,
    status: tx.receipt?.status == null ? 'unknown' : Number(tx.receipt.status) === 1 ? 'success' : 'reverted',
    gasUsed: toDecimal(tx.receipt?.gasUsed), traced: tx.trace?.available !== false, traceReason: tx.trace?.reason || null,
    requested: `${tx.chain}:${tx.hash}` === originTx,
  }));
  classifyTransactions(trace, transactions, frames);
  // Triggers first: they start the flow. Then settlement, system transactions, the rest.
  const rank = { trigger: 0, settlement: 1, 'table-load': 2, delivery: 3, related: 4, other: 5 };
  const txOf = id => transactions.find(t => id.startsWith(`${t.chain}:${t.hash}:`));
  const rootIds = [...(trace.logicalRoots || [])].sort((a, b) => {
    const x = txOf(a), y = txOf(b);
    return (rank[x?.role] ?? 9) - (rank[y?.role] ?? 9) || Number(x?.block ?? 0) - Number(y?.block ?? 0) || Number(x?.index ?? 0) - Number(y?.index ?? 0);
  });
  const roots = [];
  for (const id of rootIds) {
    const frame = frames.get(id), n = visit(id);
    if (n == null) continue;
    const tx = txOf(id);
    roots.push({ node: n, chain: frame.chain, tx: frame.transactionHash, block: frame.blockNumber ?? null, from: frame.from,
      isOrigin: !!tx?.requested, relatedSettlement: !!tx?.relatedSettlement, role: tx?.role || 'other', label: tx?.label || 'Transaction' });
  }
  transactions.sort((a, b) => (rank[a.role] ?? 9) - (rank[b.role] ?? 9) || Number(a.block ?? 0) - Number(b.block ?? 0) || Number(a.index ?? 0) - Number(b.index ?? 0));

  const chainIds = trace.metadata?.chainIds || {};
  return {
    version: FLOW_MODEL_VERSION, schemaVersion: trace.schemaVersion || null,
    label: label || defaultLabel(nodes, roots, trace), txHash: trace.txHash || null,
    origin: trace.origin || null,
    chains: Object.fromEntries(['L1', 'L2'].map(c => [c, {
      chainId: chainIds[c] ?? null, rollupId: trace.metadata?.rollupIds?.[c] ?? null, manager: trace.metadata?.managers?.[c] ?? null,
      name: c === 'L1' ? CHAIN_NAMES[chainIds[c]] || 'L1' : 'EEZ rollup',
      explorer: explorerSite(explorers[c]) || EXPLORER_SITES[chainIds[c]] || null,
    }])),
    settlements: (trace.settlements || []).map(s => ({ id: s.id, l1Tx: s.l1TransactionHash, l1Block: s.l1BlockNumber ?? null, firstL2Block: s.firstL2Block ?? null, lastL2Block: s.lastL2Block ?? null })),
    transactions, roots, nodes,
    unresolved: (trace.unresolved || []).map(u => ({ code: u.code, message: u.message, frameId: u.frameId || null })),
    stats: { frames: trace.frames.length, crossings: (trace.outgoing || []).length, matched: (trace.outgoing || []).filter(o => o.status === 'matched').length, events: (trace.events || []).length },
  };
}

const ZERO_HASH = '0x' + '0'.repeat(64);
const ROLE_LABELS = {
  trigger: 'Trigger', settlement: 'Settlement batch (postAndVerifyBatch)', 'table-load': 'Execution table load',
  delivery: 'L2 delivery', related: 'Linked transaction', other: 'Same batch · no cross-chain calls', untraced: 'Untraced transaction',
};
// Gives every transaction a role from evidence, not from block ranges. The decoder
// collects every transaction in the settled range; only some belong to the flow.
//   trigger     an application transaction with a top-level cross-chain call (not nested in a delivered call)
//   settlement  calls postAndVerifyBatch; on L1 it also runs the L1 side of L2-started flows
//   table-load / delivery  EEZL2 system transactions
//   related     has cross-chain frames but starts nothing itself
//   other       no cross-chain calls at all (e.g. proxy setup); settled in the same batch, not part of the flow
function classifyTransactions(trace, transactions, frames) {
  const keyOf = id => String(id).split(':').slice(0, 2).join(':');
  const byKey = new Map(transactions.map(t => [`${t.chain}:${t.hash}`, t]));
  const tableTx = new Map((trace.tables || []).map(t => [t.id, `${t.chain}:${t.transactionHash}`]));
  for (const t of transactions) Object.assign(t, { outgoing: 0, topOutgoing: 0, incoming: 0, evidence: [] });
  const fns = new Map(transactions.map(t => [`${t.chain}:${t.hash}`, new Set()]));
  for (const f of frames.values()) if (f.protocol?.name) fns.get(keyOf(f.id))?.add(f.protocol.name);
  const nested = id => { for (let f = frames.get(frames.get(id)?.parentId); f; f = frames.get(f.parentId)) if (f.role === 'incoming-proxy') return true; return false; };
  const links = new Map(transactions.map(t => [`${t.chain}:${t.hash}`, new Set()]));
  const link = (a, b) => { if (a && b && a !== b && links.has(a) && links.has(b)) { links.get(a).add(b); links.get(b).add(a); } };
  const rows = (trace.tables || []).flatMap(t => (t.rows || []).map(r => ({ ...r, tx: `${t.chain}:${t.transactionHash}` })));
  const sameCall = (r, o) => lower(r.sourceAddress) === lower(o.sourceAddress) && lower(r.targetAddress) === lower(o.targetAddress) && lower(r.data) === lower(o.data);
  for (const o of trace.outgoing || []) {
    const k = keyOf(o.frameId), t = byKey.get(k);
    if (!t) continue;
    t.outgoing++;
    if (!nested(o.frameId)) t.topOutgoing++;
    if (o.remoteFrameId) link(k, keyOf(o.remoteFrameId));
    if (o.generationId) link(k, tableTx.get(o.generationId));
    for (const r of rows) if (sameCall(r, o)) link(k, r.tx);
  }
  for (const i of trace.incoming || []) {
    const k = keyOf(i.frameId), t = byKey.get(k);
    if (!t) continue;
    t.incoming++;
    if (i.generationId) link(k, tableTx.get(i.generationId));
  }
  for (const t of transactions) {
    const f = fns.get(`${t.chain}:${t.hash}`);
    t.role = f.has('postAndVerifyBatch') ? 'settlement' : f.has('executeIncomingCrossChainCall') ? 'delivery'
      : f.has('loadExecutionTable') ? 'table-load' : t.topOutgoing ? 'trigger' : t.outgoing + t.incoming ? 'related'
      : t.traced ? 'other' : 'untraced';
    // A batch whose own top-level calls cross chains (meta hook) is also the trigger.
    if (t.role === 'settlement' && t.topOutgoing) { t.role = 'trigger'; t.evidence.push('postAndVerifyBatch with its own top-level cross-chain calls (meta hook)'); }
  }
  // L1 batch entries with proxyEntryHash == 0 are L2Tx entries: work that started on L2.
  const l2TxEntries = (trace.tables || []).filter(t => t.chain === 'L1').flatMap(t => (t.entries || []).map((e, index) => ({ e, index, tx: `${t.chain}:${t.transactionHash}` })))
    .filter(x => lower(x.e.proxyEntryHash) === ZERO_HASH);
  for (const t of transactions) {
    if (t.role !== 'trigger') continue;
    t.startsOn = t.chain;
    const outs = (trace.outgoing || []).filter(o => keyOf(o.frameId) === `${t.chain}:${t.hash}` && !nested(o.frameId));
    for (const x of l2TxEntries) if ((x.e.l2ToL1Calls || []).some(r => outs.some(o => sameCall(r, o)))) {
      t.evidence.push(`matches L2Tx entry #${x.index} of the settlement batch (proxyEntryHash = 0: started on L2)`);
      link(`${t.chain}:${t.hash}`, x.tx);
    }
    t.evidence.unshift(`${t.topOutgoing} top-level cross-chain call${t.topOutgoing === 1 ? '' : 's'}`);
  }
  for (const t of transactions) {
    if (t.role === 'settlement' && l2TxEntries.length) t.evidence.push(`${l2TxEntries.filter(x => x.tx === `${t.chain}:${t.hash}`).length} L2Tx entries (proxyEntryHash = 0)`);
    if (t.role === 'other') t.evidence.push('no cross-chain calls; in the settled block range only');
    t.label = t.role === 'trigger' ? `Trigger · starts on ${t.chain}` : ROLE_LABELS[t.role];
    // Transactions connected to a trigger through matched calls, tables or batch entries.
    t.links = [...links.get(`${t.chain}:${t.hash}`)];
  }
  const triggers = transactions.filter(t => t.role === 'trigger');
  const reach = new Set(triggers.map(t => `${t.chain}:${t.hash}`)), queue = [...reach];
  while (queue.length) for (const k of links.get(queue.shift()) || []) if (!reach.has(k)) { reach.add(k); queue.push(k); }
  // inFlow: true / false from evidence; null when the transaction could not be traced.
  for (const t of transactions) t.inFlow = t.role === 'untraced' ? null : reach.has(`${t.chain}:${t.hash}`) && t.role !== 'other';
  // A local L2 transaction still has an L1 settlement. Keep that relationship
  // visible without inventing a cross-chain call or including unrelated batch jobs.
  const requested = transactions.find(t => t.requested);
  if (requested?.role === 'other') {
    requested.label = 'Requested transaction · no cross-chain calls';
    requested.evidence = ['no cross-chain calls observed in the requested transaction'];
    for (const t of transactions) {
      t.relatedSettlement = requested.chain === 'L2' && t.chain === 'L1' && (trace.settlements || []).some(s =>
        s.canonical === true && lower(s.l1TransactionHash) === lower(t.hash) &&
        requested.block >= s.firstL2Block && requested.block <= s.lastL2Block);
      if (t.relatedSettlement) t.evidence.push('settles the requested L2 transaction; no cross-chain call is implied');
    }
  }
}

function defaultLabel(nodes, roots, trace) {
  // Name the page after the trigger: the transaction that starts the flow.
  const origin = roots.find(r => r.role === 'trigger') || roots.find(r => r.isOrigin);
  // Never name the page after an unrelated transaction when nothing traced starts the flow.
  if (!origin && trace?.origin) return `Untraced ${trace.origin.chain} transaction ${String(trace.txHash || '').slice(0, 10)}…`;
  if (!origin) return roots.length ? defaultLabel(nodes, [{ ...roots[0], isOrigin: true }]) : 'Empty trace';
  const n = nodes[origin.node];
  return `${n.contract}.${n.fn.replace(/\(.*$/, '')}()`;
}

function functionName(d, frame) {
  if (frame?.type === 'CREATE' || frame?.type === 'CREATE2') return 'constructor()';
  if (d?.functionName) return d.signature ? d.signature.replace(/^[^(]*/, d.functionName).replace(/\(.*\)$/, s => s.length > 60 ? '(…)' : s) : `${d.functionName}()`;
  const input = frame?.input || d?.rawInput || '0x';
  return input.length >= 10 ? input.slice(0, 10) : input === '0x' ? 'receive()' : 'fallback()';
}

function argument(a) { return { name: a.name ?? '', type: a.type ?? '', value: a.value }; }

function returnInfo(d, frame) {
  if (frame.error) {
    const e = d.error || {};
    const reason = e.name ? `${e.name}(${(e.arguments || []).map(x => display(x.value)).join(', ')})` : standardRevert(frame.output) || frame.revertReason || e.message || frame.error;
    return { status: 'revert', reason, raw: frame.output || '0x' };
  }
  if (frame.type === 'CREATE' || frame.type === 'CREATE2') return { status: 'created', raw: null };
  if (Array.isArray(d.returns)) return d.returns.length ? { status: 'ok', items: d.returns.map(argument), raw: frame.output || '0x' } : { status: 'void', raw: frame.output || '0x' };
  return !frame.output || frame.output === '0x' ? { status: 'void', raw: '0x' } : { status: 'raw', raw: frame.output };
}

function ghostReturn(info) {
  if (info.precomputed.length === 1) {
    const p = info.precomputed[0];
    return { status: p.success === false ? 'revert' : 'precomputed', raw: p.returnData, reason: p.success === false ? standardRevert(p.returnData) || 'precomputed revert' : null };
  }
  return { status: 'unknown', raw: null, alternatives: info.precomputed.length };
}

// Error(string) and Panic(uint256) are compiler-level and not part of an app ABI.
export function standardRevert(data) {
  if (typeof data !== 'string') return null;
  const hex = data.toLowerCase();
  try {
    if (hex.startsWith('0x08c379a0') && hex.length >= 138) {
      const body = hex.slice(10), offset = parseInt(body.slice(0, 64), 16) * 2, len = parseInt(body.slice(offset, offset + 64), 16);
      const bytes = body.slice(offset + 64, offset + 64 + len * 2);
      const text = decodeURIComponent(bytes.replace(/../g, '%$&'));
      return `Error("${text}")`;
    }
    if (hex.startsWith('0x4e487b71') && hex.length >= 74) return `Panic(0x${BigInt('0x' + hex.slice(10, 74)).toString(16)})`;
  } catch { /* Malformed revert bytes stay raw. */ }
  return null;
}

function toDecimal(v) {
  if (v == null) return null;
  try { return BigInt(v).toString(); } catch { return String(v); }
}

export function display(value) {
  if (value == null) return '—';
  if (Array.isArray(value)) return `[${value.length}]`;
  if (typeof value === 'object') return '{…}';
  return String(value);
}
