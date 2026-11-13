// Offline adapter for eez_debugQuoteFee v1. Simulation runs never become mined
// transactions or pass through the decoder's receipt/settlement matching logic.
import { explorerSite, standardRevert } from './model.mjs';

export function isQuoteTrace(value) {
  const diagnostics = value?.result?.diagnostics ?? value?.diagnostics;
  return !!diagnostics && typeof diagnostics === 'object' && !Array.isArray(diagnostics);
}

export function buildQuoteModels(payload, { explorers = {} } = {}) {
  if (payload?.error) throw new Error(`Debug quote RPC error: ${payload.error.message || JSON.stringify(payload.error)}`);
  const quote = payload?.result?.diagnostics ? payload.result : payload;
  const trace = quote?.diagnostics?.trace;
  if (!trace) throw new Error('No debug quote call trace. Request eez_debugQuoteFee with trace: "calls".');
  if (trace.format !== 'eez-quote-call-trace' || trace.version !== 1) throw new Error('Unsupported debug quote trace format/version.');
  if (!Array.isArray(trace.runs) || !trace.runs.length) throw new Error('Debug quote contains no simulation runs.');
  const quantity = (v, label, optional = false) => {
    if (v == null && optional) return null;
    if (!(typeof v === 'number' && Number.isSafeInteger(v) && v >= 0) &&
        !(typeof v === 'string' && /^(0x[0-9a-f]+|[0-9]+)$/i.test(v))) throw new Error(`Invalid ${label}.`);
    return BigInt(v).toString();
  };
  const identifier = (v, label) => {
    if (!Number.isSafeInteger(v) || v < 0) throw new Error(`Invalid ${label}.`);
    return v;
  };
  const context = trace.context || {};
  if (context.simulation !== true) throw new Error('Debug quote trace must identify itself as a simulation.');
  const chainIds = { L1: quantity(context.l1ChainId, 'L1 chain ID'), L2: quantity(context.l2ChainId, 'L2 chain ID') };
  if (chainIds.L1 === chainIds.L2) throw new Error('Debug quote must distinguish L1 and L2 chain IDs.');
  const chainOf = id => {
    const value = quantity(id, 'frame chain ID');
    const chain = Object.keys(chainIds).find(c => chainIds[c] === value);
    if (!chain) throw new Error(`Unknown debug quote chain ID ${value}.`);
    return chain;
  };
  const runIds = new Set();
  const models = trace.runs.map(run => {
    const runId = identifier(run.id, 'run ID');
    if (runIds.has(runId)) throw new Error(`Duplicate run ID ${runId}.`);
    runIds.add(runId);
    if (!Array.isArray(run.frames)) throw new Error(`Run ${runId} has no frames array.`);
    const issues = [];
    const warn = (code, message, frameId = null) => issues.push({ code, message, frameId });
    const incomplete = trace.truncated === true || Number(trace.omittedFrames || 0) > 0 ||
      Number(trace.omittedRuns || 0) > 0 || run.complete !== true;
    if (incomplete) warn('incomplete-quote-trace', `Incomplete simulation capture: run complete=${run.complete === true}, trace truncated=${trace.truncated === true}, omitted runs=${trace.omittedRuns || 0}, omitted frames=${trace.omittedFrames || 0}.`);
    if (!run.frames.length) warn('empty-simulation-run', 'This simulation run contains no call frames.');
    const byId = new Map();
    for (const f of run.frames) {
      identifier(f.id, 'frame ID');
      if (byId.has(f.id)) throw new Error(`Duplicate frame ID ${f.id} in run ${runId}.`);
      byId.set(f.id, f);
    }
    const bytes = (field, name, frameId) => {
      if (field == null) { warn('missing-frame-bytes', `${name} bytes unavailable.`, frameId); return { hex: null, length: null, truncated: false }; }
      if (typeof field !== 'object' || typeof field.hex !== 'string' || !/^0x(?:[0-9a-f]{2})*$/i.test(field.hex) ||
          !Number.isSafeInteger(field.length) || field.length < 0 || typeof field.truncated !== 'boolean') throw new Error(`Invalid ${name} bytes in ${frameId}.`);
      const size = (field.hex.length - 2) / 2;
      if (field.length < size || !field.truncated && field.length !== size) throw new Error(`Inconsistent ${name} length in ${frameId}.`);
      if (field.truncated) warn('truncated-frame-bytes', `${name} truncated: ${size} of ${field.length} bytes retained.`, frameId);
      return { ...field };
    };
    const nodes = run.frames.map((f, index) => {
      const frameId = `quote:${runId}:${f.id}`;
      const input = bytes(f.input, 'Input', frameId), output = bytes(f.output, 'Output', frameId);
      const failed = ['revert', 'reverted', 'error', 'failure', 'failed', 'halt'].includes(String(f.status).toLowerCase());
      const unknown = f.status !== 'success' && !failed;
      if (unknown) warn('unknown-frame-status', `Frame status: ${f.status ?? 'unavailable'}.`, frameId);
      const ret = unknown ? { status: 'unknown', raw: output.hex }
        : failed ? { status: 'revert', reason: (!output.truncated && standardRevert(output.hex)) || f.result || f.status, raw: output.hex }
        : output.hex == null || output.truncated ? { status: 'raw', raw: output.hex }
        : String(f.kind).startsWith('CREATE') ? { status: 'created', raw: null }
        : output.hex === '0x' ? { status: 'void', raw: '0x' } : { status: 'raw', raw: output.hex };
      return {
        id: index, frameId, kind: 'call', chain: chainOf(f.chainId), role: 'application', protocol: false,
        callType: f.kind || 'CALL', contract: 'Unknown contract', address: f.to || null, from: f.from || null,
        codeAddress: f.codeAddress || null,
        fn: String(f.kind).startsWith('CREATE') ? 'constructor()' : (input.hex?.length >= 10 ? input.hex.slice(0, 10) : input.hex === '0x' ? 'receive()' : 'fallback()'),
        signature: null, args: [], ret, value: quantity(f.value, 'call value', true) || '0', isStatic: !!f.isStatic,
        crossChainRead: !!f.isStatic && !!f.crossChain, failed, unknown, reverted: false,
        gasUsed: quantity(f.gasUsed, 'frame gas used', true), gas: quantity(f.gas, 'frame gas', true),
        tx: null, block: null, path: String(f.id), abiSource: null, abiProvider: null,
        input: input.hex, output: output.hex, inputInfo: input, outputInfo: output, children: [], inFlow: true,
        simulationStatus: f.status ?? null, simulationResult: f.result ?? null, executionRoot: !!f.executionRoot,
      };
    });
    const indexOf = new Map(run.frames.map((f, i) => [f.id, i]));
    const parentOf = new Map();
    for (const f of run.frames) {
      if (f.parentId == null) continue;
      identifier(f.parentId, 'parent frame ID');
      if (!byId.has(f.parentId)) {
        if (!incomplete) throw new Error(`Missing parent ${f.parentId} in run ${runId}.`);
        warn('missing-simulation-parent', `Frame ${f.id} has omitted parent ${f.parentId}; displayed as a separate root.`, `quote:${runId}:${f.id}`);
        continue;
      }
      parentOf.set(f.id, f.parentId);
    }
    // Validate the entire forest before the recursive viewer sees it. Order in
    // the input array need not be parent-first; sibling order stays unchanged.
    for (const f of run.frames) {
      const seen = new Set([f.id]); let at = f.id;
      while (parentOf.has(at)) {
        at = parentOf.get(at);
        if (seen.has(at)) throw new Error(`Cycle in simulation run ${runId}.`);
        seen.add(at);
        if (seen.size > 512) throw new Error('Simulation call depth exceeds the viewer limit of 512.');
        if (nodes[indexOf.get(at)].failed) nodes[indexOf.get(f.id)].reverted = true;
      }
    }
    for (const f of run.frames) {
      if (!parentOf.has(f.id)) continue;
      const parent = nodes[indexOf.get(parentOf.get(f.id))], child = nodes[indexOf.get(f.id)];
      parent.children.push(child.id);
      if (parent.chain !== child.chain) {
        child.crossing = {
          from: parent.chain, to: child.chain, status: 'simulated', isStatic: child.isStatic,
          sourceAddress: parent.from, localProxy: parent.address, remoteProxy: child.address,
          targetAddress: child.address, value: child.value, remoteTx: null, hashes: [], precomputed: [],
          evidence: ['Composer simulation parent/child link; not verified mined-transaction evidence.'],
        };
        if (!f.crossChain) warn('unmarked-chain-transition', `Frame ${f.id} changes chains without crossChain: true.`, child.frameId);
      }
    }
    const roots = nodes.filter((_, i) => !parentOf.has(run.frames[i].id)).map(n => ({
      node: n.id, chain: n.chain, tx: null, block: null, from: n.from, inFlow: true, isOrigin: false,
      role: 'simulation', label: `Simulation root · frame ${n.path}`,
    }));
    const feeOption = (quote.options || []).find(o => o.type === run.type) || null;
    const diagnostic = (quote.diagnostics.options || []).find(o => o.request?.type === run.type || o.transaction?.type === run.type) || null;
    const label = `Simulation · ${run.phase || 'unknown phase'} / ${run.purpose || 'unknown purpose'} · pass ${run.pass ?? '?'} · run ${runId} · ${run.type || '?'}`;
    return {
      version: 1, schemaVersion: 'eez-quote-call-trace/1', mode: 'simulation', recordedView: null,
      label, txHash: null, origin: null,
      executionNotice: 'Composer quote simulation. No transaction was submitted by this import; this is not evidence of mining, proof acceptance or settlement.' +
        (issues.length ? ` Capture warnings: ${[...new Set(issues.map(i => i.message))].join(' ')}` : ''),
      chains: Object.fromEntries(['L1', 'L2'].map(c => [c, { chainId: chainIds[c], rollupId: c === 'L1' ? 0 : context.rollupId ?? null,
        manager: null, name: `${c} · chain ${chainIds[c]}`, explorer: explorerSite(explorers[c]) }])),
      transactions: [], settlements: [], stateObservations: [], nodes, roots, gas: null, matchingNotes: [], unresolved: issues,
      simulation: { runId, phase: run.phase, purpose: run.purpose, pass: run.pass, type: run.type, complete: run.complete === true,
        runCount: trace.runs.length, frameCount: trace.runs.reduce((n, r) => n + (r.frames?.length || 0), 0),
        context, request: trace.request, transaction: run.transaction, feeOption, diagnostic,
        expiresAt: quote.expiresAt, gasAccounting: trace.gasAccounting, limits: trace.limits,
        truncated: trace.truncated, omittedFrames: trace.omittedFrames, omittedRuns: trace.omittedRuns },
      stats: { frames: nodes.length, crossings: nodes.filter(n => n.crossing).length, matched: 0, events: 0 },
    };
  });
  // Prefer the last final composition, then the last available composition.
  // Keep all other runs separately selectable, including failed/partial runs.
  const preferred = models.findLastIndex(m => m.simulation.phase === 'final_validation' && m.simulation.purpose === 'composition');
  const index = preferred >= 0 ? preferred : models.findLastIndex(m => m.simulation.purpose === 'composition');
  if (index > 0) models.unshift(...models.splice(index, 1));
  return models;
}
