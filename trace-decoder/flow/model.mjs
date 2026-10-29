import { isPreparedResult } from '../src/prepared-result.mjs';
// Converts a trace-decoder result (schema 1.x) into the call-flow diagram model.
// Pure: the viewer inlines this file and its prepared-result helper so a
// trace JSON opened in the browser goes through exactly the same code.

export const FLOW_MODEL_VERSION = 1;

// Roles the decoder assigns to EEZ plumbing. The diagram folds them by default.
const PROTOCOL_ROLES = new Set(['manager', 'incoming-proxy', 'static-probe', 'outgoing-proxy', 'system-value-transfer']);
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

// Experimental ERC20 notes: require both a trace location and persisted receipt
// evidence. Compare multiplicity so identical events are never assigned by guess.
export function tokenTransfersByFrame(trace) {
  const topic = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
  const zero = '0x' + '0'.repeat(40), result = new Map(), groups = new Map(), metadata = new Map();
  const frames = new Map((trace.frames || []).map(f => [f.id, f]));
  const txKey = x => `${x.chain}:${lower(x.transactionHash || x.hash)}`;
  const tokenKey = (x, address) => `${txKey(x)}:${lower(address)}`;
  const successful = new Set((trace.transactions || []).filter(t => Number(t.receipt?.status) === 1).map(txKey));
  // Metadata is local to the token, chain and transaction. Never assume 18
  // decimals or copy a symbol from a similarly named token on another chain.
  for (const f of frames.values()) {
    if (f.reverted || f.error || !successful.has(txKey(f))) continue;
    const key = tokenKey(f, f.contextAddress || f.to), value = f.decoded?.returns?.[0]?.value;
    const field = lower(f.input) === '0x95d89b41' && typeof value === 'string' && value.length > 0 && value.length <= 80 ? 'symbol'
      : lower(f.input) === '0x313ce567' && /^(0|[1-9][0-9]*)$/.test(String(value)) && Number(value) <= 255 ? 'decimals' : null;
    if (!field) continue;
    if (!metadata.has(key)) metadata.set(key, {});
    const m = metadata.get(key);
    if (!m[field]) m[field] = new Set();
    m[field].add(String(value));
  }
  for (const e of trace.events || []) {
    // ERC721 shares the signature but has four topics and no amount word.
    if (e.removed || e.reverted || e.committed === false || !successful.has(txKey(e)) ||
      e.topics?.length !== 3 || lower(e.topics[0]) !== topic || !/^0x[0-9a-f]{64}$/i.test(e.data || '') ||
      !/^0x[0-9a-f]{40}$/i.test(e.address || '') || !e.topics.slice(1).every(t => /^0x0{24}[0-9a-f]{40}$/i.test(t))) continue;
    const key = `${tokenKey(e, e.address)}:${e.topics.map(lower).join(':')}:${lower(e.data)}`;
    if (!groups.has(key)) groups.set(key, { trace: [], receipt: [] });
    if (e.provenance === 'trace') {
      const f = frames.get(e.frameId);
      if (f && !f.reverted && !f.error && txKey(f) === txKey(e) && lower(f.contextAddress || f.to) === lower(e.address)) groups.get(key).trace.push(e);
    } else if (e.provenance === 'receipt' && e.committed === true) groups.get(key).receipt.push(e);
  }
  for (const group of groups.values()) {
    if (!group.trace.length || group.trace.length !== group.receipt.length) continue;
    for (const e of group.trace) {
      const from = '0x' + e.topics[1].slice(-40).toLowerCase(), to = '0x' + e.topics[2].slice(-40).toLowerCase();
      const m = metadata.get(tokenKey(e, e.address)), one = field => m?.[field]?.size === 1 ? [...m[field]][0] : null;
      const decimals = one('decimals');
      const note = { token: lower(e.address), from, to, amount: BigInt(e.data).toString(),
        symbol: one('symbol'), decimals: decimals == null ? null : Number(decimals),
        kind: from === zero ? 'mint' : to === zero ? 'burn' : 'transfer', eventId: e.id,
        evidence: 'receipt-and-trace' };
      if (!result.has(e.frameId)) result.set(e.frameId, []);
      result.get(e.frameId).push(note);
    }
  }
  return result;
}

export function buildFlowModel(trace, { label, explorers = {}, mode = 'combined' } = {}) {
  if (!trace || !Array.isArray(trace.frames) || !Array.isArray(trace.logicalNodes)) {
    throw new Error('This file is not a trace-decoder JSON result: frames and logicalNodes are missing.');
  }
  const transfers = tokenTransfersByFrame(trace);
  const frames = new Map(trace.frames.map(f => [f.id, f]));
  const logical = new Map(trace.logicalNodes.map(n => [n.id, n]));
  const outgoingByFrame = new Map((trace.outgoing || []).map(o => [o.frameId, o]));
  const incomingByFrame = new Map((trace.incoming || []).map(i => [i.frameId, i]));
  const nodes = [], seen = new Set();
  const exactLink = (trace.transactionLinks || []).find(l => l.state === 'complete' &&
    `${l.sourceChain}:${l.sourceHash}` === trace.origin?.transactionId);
  const physical = !!exactLink && mode === 'physical';
  const prepared = new Set((trace.outgoing || []).filter(isPreparedResult).map(o => o.frameId));

  function crossing(out) {
    const proxy = frames.get(out.frameId), incoming = out.remoteFrameId ? incomingByFrame.get(out.remoteFrameId) : null;
    const remoteChain = out.chain === 'L1' ? 'L2' : 'L1';
    return {
      from: out.chain, to: remoteChain, status: prepared.has(out.frameId) ? 'prepared-result' : out.status || 'unresolved', isStatic: !!out.isStatic, value: String(out.value ?? '0'),
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
    if (role === 'system-value-transfer') contract = 'L2 system';
    // Precompiles sit at 0x01–0x0a and never make calls of their own.
    const precompile = /^0x0{38}(0[1-9a])$/i.exec(frame.to || '');
    if (contract === 'Unknown contract' && precompile && !(ln?.children || frame.children || []).length) contract = `Precompile · ${PRECOMPILES[parseInt(precompile[1], 16) - 1]}`;
    return {
      kind: 'call', frameId: frame.id, chain: frame.chain, role,
      tokenTransfers: [...(transfers.get(frame.id) || [])],
      protocol: PROTOCOL_ROLES.has(role) || role === 'proxy-creation', callType: frame.type || 'CALL',
      contract, address: frame.to ?? null, from: frame.from ?? null,
      fn: role === 'system-value-transfer' ? 'Value to L2 system' : functionName(d, frame), signature: d.signature || null, args: (d.arguments || []).map(argument),
      ret: returnInfo(d, frame), value: String(frame.value ?? '0'), isStatic: !!frame.isStatic,
      crossChainRead: !!frame.isStatic && (outgoingByFrame.has(frame.id) || incomingByFrame.has(frame.id)),
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
      node.tokenTransfers.push(...(transfers.get(child.id) || []));
      const inner = logical.get(child.id), d = inner?.decoded || child.decoded || {};
      node.impl = { contract: d.contractName || 'Unknown contract', address: child.to, frameId: child.id };
      if (!node.signature && d.signature) Object.assign(node, { fn: functionName(d, child), signature: d.signature, args: (d.arguments || []).map(argument), ret: returnInfo(d, child), abiSource: d.provenance?.source || null });
      children.splice(i, 1, ...(inner?.children || [])); i--;
    }
    const out = outgoingByFrame.get(id);
    if (out) {
      const info = crossing(out);
      node.outgoing = info;
      if (prepared.has(id)) {
        node.preparedResult = true; node.protocol = false;
      } else if (out.status === 'matched' && out.remoteFrameId && children.includes(out.remoteFrameId)) {
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
      if (out?.status === 'matched' && c === out.remoteFrameId) nodes[v].crossing = node.outgoing;
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
  const scope = classifyTransactions(trace, transactions, frames);
  const gas = flowGas(trace, transactions, frames, scope.frames, exactLink);
  const isolated = physical && exactLink.l1Execution?.frameId && frames.has(exactLink.l1Execution.frameId) ? exactLink.l1Execution : null;
  const unisolatedL1 = physical && exactLink.sourceChain === 'L2' && !isolated;
  const physicalRoots = [];
  if (physical) {
    scope.roots.clear(); scope.frames.clear();
    if (isolated) physicalRoots.push(isolated.frameId);
    for (const r of exactLink.references) {
      // The complete posting trace is retained in JSON. The diagram uses only
      // the source's isolated entry, rather than the other entries in that post.
      if (isolated && r.chain === 'L1') continue;
      const id = `${r.chain}:${r.hash}:0`;
      if (frames.has(id) && !physicalRoots.includes(id)) physicalRoots.push(id);
      if (frames.has(id) && (r.role === 'source' || r.role === 'l2-delivery')) scope.roots.add(id);
    }
    if (isolated) scope.roots.add(isolated.frameId);
    const collect = id => { if (scope.frames.has(id)) return; scope.frames.add(id); for (const c of frames.get(id)?.children || []) collect(c); };
    for (const id of scope.roots) collect(id);
  }
  function visitPhysical(id) {
    const frame = frames.get(id);
    if (!frame || seen.has(id)) return null;
    seen.add(id);
    const node = describe(frame, null), index = add(node), out = outgoingByFrame.get(id);
    if (out) {
      node.outgoing = crossing(out); // Metadata only; never graft a guessed remote subtree.
      node.protocol = false; // Keep the actual proxy request and its returned result visible.
      node.preparedResult = prepared.has(id);
      node.preparedResponse = out.chain === 'L2' && !!out.generationId;
      node.remoteChain = out.chain === 'L1' ? 'L2' : 'L1';
      node.remoteAddress = out.targetAddress;
      const remote = out.remoteCall;
      if (remote?.functionName) {
        node.fn = functionName(remote, frame); node.signature = remote.signature;
        node.args = (remote.arguments || []).map(argument);
        // Return labels must describe this local frame, regardless of any remote association.
        const response = out.localResponse || (remote.rawOutput === frame.output ? remote : null);
        if (response) node.ret = returnInfo(response, frame);
      }
      node.contract = remote?.contractName && remote.contractName !== 'Unknown contract' ? `${remote.contractName} proxy` : 'Cross-chain proxy';
    }
    for (const child of frame.children || []) {
      const n = visitPhysical(child);
      if (n != null) node.children.push(n);
    }
    return index;
  }
  // Triggers first: they start the flow. Then settlement, system transactions, the rest.
  const rank = { trigger: 0, settlement: 1, 'table-load': 2, delivery: 3, related: 4, other: 5 };
  const txOf = id => transactions.find(t => id.startsWith(`${t.chain}:${t.hash}:`));
  const rootIds = [...(physical ? physicalRoots : trace.logicalRoots || [])].sort((a, b) => {
    const x = txOf(a), y = txOf(b);
    if (isolated && (a === isolated.frameId || b === isolated.frameId)) return a === isolated.frameId ? -1 : 1;
    return Number(scope.roots.has(b)) - Number(scope.roots.has(a)) || (rank[x?.role] ?? 9) - (rank[y?.role] ?? 9) || Number(x?.block ?? 0) - Number(y?.block ?? 0) || Number(x?.index ?? 0) - Number(y?.index ?? 0);
  });
  const roots = [];
  for (const id of rootIds) {
    const frame = frames.get(id), n = physical ? visitPhysical(id) : visit(id);
    if (n == null) continue;
    const tx = txOf(id);
    roots.push({ node: n, chain: frame.chain, tx: frame.transactionHash, block: frame.blockNumber ?? null, from: frame.from,
      inFlow: scope.roots.has(id), isOrigin: !!tx?.requested, relatedSettlement: !!tx?.relatedSettlement, role: id === isolated?.frameId ? 'execution' : tx?.role || 'other',
      unisolatedEntry: !!unisolatedL1 && frame.chain === 'L1',
      preferred: id === isolated?.frameId, entryIndex: id === isolated?.frameId ? isolated.entryIndex : null,
      label: id === isolated?.frameId ? `L1 execution · entry ${isolated.entryIndex}` : tx?.label || 'Transaction' });
  }
  transactions.sort((a, b) => Number(b.inFlow === true || b.requested) - Number(a.inFlow === true || a.requested) || (rank[a.role] ?? 9) - (rank[b.role] ?? 9) || Number(a.block ?? 0) - Number(b.block ?? 0) || Number(a.index ?? 0) - Number(b.index ?? 0));

  for (const node of nodes) node.inFlow = scope.frames.has(node.frameId || node.crossing?.managerFrameId);
  const chainIds = trace.metadata?.chainIds || {};
  const relevantIssues = (trace.unresolved || []).filter(u => (!u.frameId || scope.frames.has(u.frameId)) &&
    !(prepared.has(u.frameId) && u.code === 'remote-execution-unavailable'));
  const associationCodes = new Set(['ambiguous-remote-occurrence', 'remote-execution-unavailable']);
  const optionalAssociation = u => associationCodes.has(u.code) && !outgoingByFrame.get(u.frameId)?.rejectedCandidates?.length;
  const matchingNotes = physical ? relevantIssues.filter(optionalAssociation) : [];
  const unresolved = relevantIssues.filter(u => !physical || !optionalAssociation(u));
  return {
    mode: physical ? 'physical' : 'combined',
    recordedView: exactLink && !physical ? buildFlowModel(trace, { label, explorers, mode: 'physical' }) : null,
    executionNotice: unisolatedL1 ? 'The L1 entry for this L2 transaction could not be isolated. Select the settlement batch to inspect its full trace; it may include other transactions. A combined recorded view is unavailable.' : null,
    version: FLOW_MODEL_VERSION, schemaVersion: trace.schemaVersion || null,
    label: label || defaultLabel(nodes, roots, trace), txHash: trace.txHash || null,
    origin: trace.origin || null,
    chains: Object.fromEntries(['L1', 'L2'].map(c => [c, {
      chainId: chainIds[c] ?? null, rollupId: trace.metadata?.rollupIds?.[c] ?? null, manager: trace.metadata?.managers?.[c] ?? null,
      name: c === 'L1' ? CHAIN_NAMES[chainIds[c]] || 'L1' : 'EEZ rollup',
      explorer: explorerSite(explorers[c]) || EXPLORER_SITES[chainIds[c]] || null,
    }])),
    settlements: (trace.settlements || []).map(s => ({ id: s.id, l1Tx: s.l1TransactionHash, l1Block: s.l1BlockNumber ?? null, firstL2Block: s.firstL2Block ?? null, lastL2Block: s.lastL2Block ?? null })),
    stateObservations: trace.metadata?.stateObservations || [],
    transactions, roots, nodes, gas,
    matchingNotes: matchingNotes.map(u => ({ code: u.code, message: u.message, frameId: u.frameId || null })),
    unresolved: unresolved.map(u => ({ code: u.code, message: u.message, frameId: u.frameId || null })),
    stats: { frames: scope.frames.size, preparedResponses: nodes.filter(n => n.preparedResponse && scope.frames.has(n.frameId)).length, preparedResults: [...prepared].filter(id => scope.frames.has(id)).length, crossings: (trace.outgoing || []).filter(o => scope.frames.has(o.frameId)).length, matched: (trace.outgoing || []).filter(o => scope.frames.has(o.frameId) && o.status === 'matched').length, events: (trace.events || []).filter(e => scope.frames.has(e.frameId)).length },
  };
}

// Gas follows physical ancestry, never the grafted logical graph or visibility
// filters. A parent's inclusive gas already covers its children, including reverts.
function flowGas(trace, transactions, frames, selectedFrames, exactLink) {
  const keyOf = id => String(id).split(':').slice(0, 2).join(':');
  const byKey = new Map(transactions.map(t => [`${t.chain}:${t.hash}`, t]));
  const candidates = new Set(exactLink ? [] : selectedFrames);
  const partial = { L1: false, L2: false };
  if (exactLink) {
    for (const r of exactLink.references || []) {
      if (['source', 'l2-delivery', 'l2-table-load'].includes(r.role)) candidates.add(`${r.chain}:${r.hash}:0`);
    }
    const entry = exactLink.l1Execution?.frameId;
    if (entry && frames.has(entry)) candidates.add(entry);
    else if (exactLink.sourceChain === 'L2') {
      for (const id of selectedFrames) if (frames.get(id)?.chain === 'L1') candidates.add(id);
      partial.L1 = (exactLink.references || []).some(r => r.chain === 'L1');
    }
  } else {
    for (const t of transactions) {
      if (t.requested || t.inFlow && t.role === 'table-load') candidates.add(`${t.chain}:${t.hash}:0`);
    }
    // Matched remote calls alone do not measure their surrounding L1 entry.
    partial.L1 = trace.origin?.chain === 'L2' && transactions.some(t => t.chain === 'L1' && (t.inFlow || t.relatedSettlement));
  }
  for (const out of trace.outgoing || []) {
    if (selectedFrames.has(out.frameId) && out.status !== 'matched' && !isPreparedResult(out)) {
      partial[out.chain === 'L1' ? 'L2' : 'L1'] = true;
    }
  }
  const roots = [...candidates].filter(id => {
    for (let f = frames.get(frames.get(id)?.parentId); f; f = frames.get(f.parentId)) {
      if (candidates.has(f.id)) return false;
    }
    return true;
  });
  const amount = value => {
    try { return value == null || BigInt(value) < 0n ? null : BigInt(value).toString(); } catch { return null; }
  };
  const total = rows => rows.length && rows.every(r => r.gasUsed == null) ? null
    : rows.reduce((sum, r) => sum + BigInt(r.gasUsed ?? 0), 0n).toString();
  return Object.fromEntries(['L1', 'L2'].map(chain => {
    const contributions = roots.filter(id => id.startsWith(`${chain}:`)).map(id => {
      const f = frames.get(id), t = byKey.get(keyOf(id)), whole = id === `${keyOf(id)}:0`;
      return { frameId: id, hash: t?.hash || f?.transactionHash, basis: whole ? 'receipt' : 'frame',
        label: whole ? t?.label || 'Transaction' : id === exactLink?.l1Execution?.frameId
          ? `L1 execution · entry ${exactLink.l1Execution.entryIndex}` : 'Observed call subtree',
        gasUsed: amount(whole ? t?.gasUsed : f?.gasUsed) };
    });
    const related = transactions.filter(t => t.chain === chain && (t.requested || t.inFlow || t.relatedSettlement ||
      (exactLink?.references || []).some(r => r.chain === chain && r.hash === t.hash)));
    const receipts = [...new Map(related.map(t => [t.hash, { hash: t.hash, label: t.label, gasUsed: amount(t.gasUsed) }])).values()];
    const incomplete = partial[chain] || contributions.some(r => r.gasUsed == null);
    return [chain, { gasUsed: contributions.length ? total(contributions) : incomplete ? null : '0',
      partial: incomplete, contributions, transactionGasUsed: total(receipts),
      transactionGasPartial: receipts.some(r => r.gasUsed == null), receipts }];
  }));
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
    const isolation = (trace.transactionLinks || []).find(l => l.sourceChain === t.chain && lower(l.sourceHash) === lower(t.hash))?.l1Execution;
    if (isolation) t.evidence.push(`isolated L1 entry #${isolation.entryIndex}: ${isolation.basis}`);
    for (const x of l2TxEntries) if ((!isolation || x.index === isolation.entryIndex) && (x.e.l2ToL1Calls || []).some(r => outs.some(o => sameCall(r, o)))) {
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
  // Follow logical call trees from the requested transaction. Shared tables are
  // dependencies, never bridges to every other trigger in the same batch.
  const requested = transactions.find(t => t.requested);
  const logical = new Map((trace.logicalNodes || []).map(n => [n.id, n]));
  const descendants = root => {
    const ids = new Set(), pending = [root];
    while (pending.length) {
      const id = pending.pop();
      if (ids.has(id)) continue;
      ids.add(id);
      pending.push(...(logical.get(id)?.children || []));
    }
    return ids;
  };
  const requestedKey = requested ? `${requested.chain}:${requested.hash}` : null;
  const exact = (trace.transactionLinks || []).filter(l => l.references.some(r => `${r.chain}:${r.hash}` === requestedKey));
  const requestedTables = new Set((trace.tables || []).filter(t => `${t.chain}:${t.transactionHash}` === requestedKey).map(t => t.id));
  const selectedRoots = new Set(), selectedFrames = new Set();
  for (const root of trace.logicalRoots || []) {
    const ids = descendants(root);
    const hasRequested = [...ids].some(id => keyOf(id) === requestedKey);
    const usesRequestedTable = ['settlement', 'table-load'].includes(requested?.role) && [...ids].some(id => requestedTables.has(frames.get(id)?.generationId));
    const exactSource = exact.some(l => keyOf(root) === `${l.sourceChain}:${l.sourceHash}`);
    if (!requestedKey || hasRequested || usesRequestedTable || exactSource) {
      selectedRoots.add(root);
      for (const id of ids) selectedFrames.add(id);
    }
  }
  const reach = new Set([...selectedFrames].map(keyOf));
  for (const id of selectedFrames) {
    const dependency = tableTx.get(frames.get(id)?.generationId);
    if (dependency) reach.add(dependency);
  }
  for (const l of exact) for (const r of l.references) reach.add(`${r.chain}:${r.hash}`);
  // inFlow: true / false from evidence; null when the transaction could not be traced.
  for (const t of transactions) t.inFlow = !t.traced ? null : reach.has(`${t.chain}:${t.hash}`) && (t.role !== 'other' || t.requested);
  // A local L2 transaction still has an L1 settlement. Keep that relationship
  // visible without inventing a cross-chain call or including unrelated batch jobs.
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
  return { roots: selectedRoots, frames: selectedFrames };
}

function defaultLabel(nodes, roots, trace) {
  // Name the page after the trigger: the transaction that starts the flow.
  const requested = roots.find(r => r.isOrigin);
  const origin = requested && !['settlement', 'table-load', 'delivery'].includes(requested.role) ? requested
    : roots.find(r => r.inFlow && r.role === 'trigger') || requested;
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
