import { isPreparedLookup, isPreparedResult } from './prepared-result.mjs';
import { AbiDecoder } from './abi-decoder.mjs';
import { abiValue, callHash, hex, lower, named, parseCall, parseEvent, protocol, proxyABI, same } from './protocol.mjs';

const outgoingNames = new Set(['executeCrossChainCall', 'staticCrossChainCall']);
const loadNames = new Set(['postAndVerifyBatch', 'loadExecutionTable', 'executeIncomingCrossChainCall']);

export async function buildGraph({ config, transactions, managers, readers, rollupIds, settlements, transactionLinks = [], matchingDisabled = false, unresolvedReason }) {
  // Registry caching is invocation-local, including failed historical reads.
  const registry = new Map(), frames = [], byId = new Map(), events = [], tables = [], physicalRoots = [];
  const parse = new Map(), tableById = new Map();
  function scopes(record, generation = null) {
    if (transactionLinks.length) return transactionLinks.filter(link =>
      link.references.some(r => r.chain === record.chain && same(r.hash, record.hash)) &&
      (!generation || link.references.some(r => r.chain === record.chain && same(r.hash, generation.transactionHash)))
    ).map(link => link.id);
    return settlements.filter(s => record.chain === 'L2'
      ? record.blockNumber >= s.firstL2Block && record.blockNumber <= s.lastL2Block
      : (generation ? same(generation.transactionHash, s.l1TransactionHash) : same(record.hash, s.l1TransactionHash)))
      .map(s => s.id);
  }
  async function proxyInfo(frame, address) {
    const key = `${frame.chain}:${lower(address)}:${frame.blockNumber}`;
    if (!registry.has(key)) registry.set(key, (async () => {
      try {
        const iface = protocol[frame.chain];
        const raw = await readers[frame.chain].send('eth_call', [{ to: managers[frame.chain], data: iface.encodeFunctionData('authorizedProxies', [address]) }, hex(frame.blockNumber)]);
        const [isProxy, originalAddress, originalRollupId] = iface.decodeFunctionResult('authorizedProxies', raw);
        return isProxy ? { originalAddress, originalRollupId: originalRollupId.toString(), blockNumber: frame.blockNumber, provenance: 'authorizedProxies' } : null;
      } catch { return null; }
    })());
    return registry.get(key);
  }
  const systemAddresses = new Map();
  async function l2SystemAddress(frame) {
    if (!systemAddresses.has(frame.blockNumber)) systemAddresses.set(frame.blockNumber, (async () => {
      try {
        const raw = await readers.L2.send('eth_call', [{ to: managers.L2,
          data: protocol.L2.encodeFunctionData('SYSTEM_ADDRESS') }, hex(frame.blockNumber)]);
        return protocol.L2.decodeFunctionResult('SYSTEM_ADDRESS', raw)[0];
      } catch { return null; } // Unverified destinations remain ordinary visible calls.
    })());
    return systemAddresses.get(frame.blockNumber);
  }
  function rowList(table) {
    const rows = [];
    for (const pool of ['entries', 'staticEntries']) for (const [index, entry] of (table[pool] || []).entries()) {
      const list = entry.incomingCalls || entry.l2ToL1Calls || [];
      for (const [i, call] of list.entries()) rows.push({ id: `${table.id}/${pool}/${index}/calls/${i}`, pool, entryIndex: index, callIndex: i, proxyEntryHash: entry.proxyEntryHash, ...call });
      const nested = entry.expectedOutgoingCalls || entry.expectedL1ToL2Calls || [];
      for (const [j, item] of nested.entries()) for (const [i, call] of (item.incomingCalls || item.l2ToL1Calls || []).entries()) {
        rows.push({ id: `${table.id}/${pool}/${index}/nested/${j}/calls/${i}`, pool, entryIndex: index, nestedIndex: j, callIndex: i, proxyEntryHash: entry.proxyEntryHash, positionHash: item.expectedOutgoingHash || item.expectedL1toL2Hash, ...call });
      }
    }
    return rows;
  }
  function newTable(record, frame, parsed, state) {
    let entries, staticEntries;
    if (parsed.name === 'postAndVerifyBatch') {
      const batch = abiValue(parsed.fragment.inputs[0], parsed.args[0]);
      entries = batch.entries; staticEntries = batch.staticEntries;
    } else {
      entries = abiValue(parsed.fragment.inputs[0], parsed.args[0]);
      staticEntries = abiValue(parsed.fragment.inputs[1], parsed.args[1]);
    }
    const table = { id: `${frame.id}/table`, frameId: frame.id, chain: record.chain,
      transactionHash: record.hash, blockNumber: record.blockNumber, previousGeneration: state?.id ?? null,
      committed: !frame.reverted, provenance: 'manager-calldata', entries, staticEntries };
    table.rows = rowList(table); table.settlementIds = scopes(record, record.chain === 'L1' ? table : null);
    tables.push(table); tableById.set(table.id, table); return table;
  }
  const blockState = new Map();
  for (const record of transactions) {
    const chain = record.chain, blockKey = `${chain}:${record.blockNumber}`;
    let state = blockState.get(blockKey) || null;
    function walk(raw, parent, path, staticContext = false, reverted = false) {
      const delegate = ['DELEGATECALL', 'CALLCODE'].includes(raw.type);
      const id = `${chain}:${record.hash}:${path}`;
      const contextAddress = delegate ? parent?.contextAddress : raw.to;
      const frame = { id, chain, transactionHash: record.hash, blockNumber: record.blockNumber,
        transactionIndex: record.transactionIndex, path, parentId: parent?.id ?? null,
        children: [], type: raw.type || 'CALL', from: raw.from ?? null, to: raw.to ?? null,
        contextAddress, input: raw.input || '0x', output: raw.output || '0x',
        value: BigInt(raw.value || '0x0').toString(), gas: raw.gas ?? null, gasUsed: raw.gasUsed ?? null,
        error: raw.error ?? null, revertReason: raw.revertReason ?? null,
        isStatic: staticContext || raw.type === 'STATICCALL', reverted: reverted || !!raw.error,
        role: same(contextAddress, managers[chain]) ? 'manager' : 'application', generationId: state?.id ?? null,
      };
      frames.push(frame); byId.set(id, frame); parent?.children.push(id);
      let parsed = frame.role === 'manager' ? parseCall(protocol[chain], frame.input) : null;
      if (parsed) { parse.set(id, parsed); frame.protocol = { name: parsed.name, signature: parsed.signature, arguments: named(parsed.fragment.inputs, parsed.args) }; }
      const before = state;
      // A delegatecall uses the caller's storage/table and is not a second load.
      if (parsed && loadNames.has(parsed.name) && !(delegate && parent?.role === 'manager' && same(parent.input, frame.input))) {
        state = newTable(record, frame, parsed, state); frame.generationId = state.id;
      }
      for (const [i, log] of (raw.logs || []).entries()) {
        const address = log.address || contextAddress;
        const decoded = same(address, managers[chain]) ? parseEvent(chain, log) : null;
        events.push({ id: `${id}/log/${i}`, frameId: id, chain, transactionHash: record.hash,
          provenance: 'trace', committed: frame.reverted ? false : null, reverted: frame.reverted,
          ...log, address, decoded });
      }
      for (const [i, child] of (raw.calls || []).entries()) walk(child, frame, `${path}.${i}`, frame.isStatic, frame.reverted);
      if (raw.error) state = before;
      return frame;
    }
    if (record.traceResult.trace) physicalRoots.push(walk(record.traceResult.trace, null, '0', false, record.receipt != null && Number(record.receipt.status) === 0).id);
    else if (same(record.transaction?.to, managers[chain])) {
      // Calldata can preserve a table when tracing is unavailable. This is
      // evidence only: never manufacture a physical execution frame.
      const parsed = parseCall(protocol[chain], record.transaction.input || record.transaction.data);
      if (parsed && loadNames.has(parsed.name)) {
        const evidence = { id: `${record.id}:calldata`, reverted: record.receipt?.status == null || Number(record.receipt.status) !== 1 };
        const table = newTable(record, evidence, parsed, state); table.frameId = null; table.provenance = 'transaction-calldata';
        if (!evidence.reverted) state = table;
      }
    }
    blockState.set(blockKey, state);
    for (const [i, log] of (record.receipt?.logs || []).entries()) {
      if (log.removed || Number(record.receipt.status) !== 1) continue;
      events.push({ id: `${record.id}/receipt/${log.logIndex ?? i}`, chain, transactionHash: record.hash,
        provenance: 'receipt', committed: true, ...log,
        decoded: same(log.address, managers[chain]) ? parseEvent(chain, log) : null });
    }
  }
  const recordMap = new Map(transactions.map(r => [r.id, r]));
  const ancestors = frame => {
    const list = []; let parent = byId.get(frame.parentId);
    while (parent) { list.push(parent); parent = byId.get(parent.parentId); }
    return list;
  };
  function managerEvents(frame) {
    const ids = new Set([frame.id]);
    function collect(f) { for (const id of f.children) { const c = byId.get(id); if (['DELEGATECALL', 'CALLCODE'].includes(c.type) && c.role === 'manager') { ids.add(id); collect(c); } } }
    collect(frame);
    return events.filter(e => ids.has(e.frameId) && e.decoded).map(e => e.decoded);
  }
  const outgoing = [], incoming = [];
  for (const frame of frames) {
    const parent = byId.get(frame.parentId), parsed = parse.get(frame.id);
    if (parsed && outgoingNames.has(parsed.name) && !['DELEGATECALL', 'CALLCODE'].includes(frame.type)) {
      const info = parent && same(parent.to, frame.from) ? await proxyInfo(frame, frame.from) : null;
      if (!info) { unresolvedReason('proxy-identity-unavailable', 'Cannot confirm outgoing proxy at the transaction block', { frameId: frame.id }); continue; }
      const sourceAddress = parsed.args[0], data = parsed.args[1];
      if (!same(sourceAddress, parent.from) || !same(data, parent.input) || frame.value !== parent.value) {
        unresolvedReason('proxy-forwarding-mismatch', 'Manager request does not match the observed proxy call', { frameId: frame.id }); continue;
      }
      parent.role = 'outgoing-proxy'; parent.proxyIdentity = info;
      const evs = managerEvents(frame), event = evs.find(e => e.name === 'CrossChainCallExecuted');
      const consumed = evs.filter(e => e.name === 'ExecutionConsumed');
      const table = tableById.get(frame.generationId);
      const out = { id: `${parent.id}/outgoing`, frameId: parent.id, managerFrameId: frame.id, chain: frame.chain,
        sourceAddress, sourceRollupId: rollupIds[frame.chain], targetAddress: info.originalAddress, targetRollupId: info.originalRollupId,
        value: frame.value, data, isStatic: parsed.name === 'staticCrossChainCall', gasPolicy: event?.args.callGas ?? '0',
        hashes: [], generationId: frame.generationId, consumed, settlementIds: scopes(recordMap.get(`${frame.chain}:${frame.transactionHash}`), table),
        reverted: parent.reverted, candidates: [], status: 'unresolved' };
      if (out.sourceRollupId != null) out.hashes.push(callHash(out), callHash(out, out.gasPolicy));
      if (event) out.hashes.push(event.args.crossChainCallHash);
      out.hashes = [...new Set(out.hashes)];
      out.entryCandidates = (table?.entries || []).flatMap((e, i) => out.hashes.some(h => same(h,e.proxyEntryHash)) ? [{ generationId: table.id, pool: 'entries', index: i, success: e.success, returnData: e.returnData }] : []);
      out.entryCandidates.push(...(table?.staticEntries || []).flatMap((e, i) => out.hashes.some(h => same(h,e.proxyEntryHash)) ? [{ generationId: table.id, pool: 'staticEntries', index: i, success: e.success, returnData: e.returnData }] : []));
      outgoing.push(out);
    }
    if (!same(frame.from, managers[frame.chain]) || frame.role === 'manager' || ['DELEGATECALL', 'CALLCODE'].includes(frame.type)) continue;
    const forwarded = parseCall(proxyABI, frame.input);
    if (forwarded?.name !== 'executeOnBehalf') continue;
    const info = await proxyInfo(frame, frame.to);
    if (!info) { unresolvedReason('incoming-proxy-identity-unavailable', 'Cannot confirm incoming proxy identity', { frameId: frame.id }); continue; }
    frame.role = 'incoming-proxy'; frame.proxyIdentity = info;
    const [targetAddress, gas, data] = forwarded.args;
    const targets = frame.children.map(id => byId.get(id)).filter(c => same(c.to, targetAddress) && same(c.input, data) && c.value === frame.value && c.type === 'CALL');
    if (targets.length !== 1) { unresolvedReason('incoming-target-unavailable', 'Forwarder has no unique observed target frame', { frameId: frame.id, candidateFrameIds: targets.map(t => t.id) }); continue; }
    const target = targets[0], table = tableById.get(frame.generationId);
    const entry = { id: `${frame.id}/incoming`, frameId: target.id, proxyFrameId: frame.id, chain: frame.chain,
      sourceAddress: info.originalAddress, sourceRollupId: info.originalRollupId, targetAddress, targetRollupId: rollupIds[frame.chain],
      value: frame.value, data, isStatic: frame.isStatic, gas: gas.toString(), generationId: frame.generationId,
      settlementIds: scopes(recordMap.get(`${frame.chain}:${frame.transactionHash}`), table), reverted: target.reverted };
    entry.tableRows = (table?.rows || []).filter(row => sameIdentity(entry, { ...row, targetRollupId: entry.targetRollupId }) && row.gas === entry.gas).map(r => r.id);
    incoming.push(entry);
  }
  for (const frame of frames) if (same(frame.from, frame.to) && parseCall(proxyABI, frame.input)?.name === 'staticCheck') {
    const parent = byId.get(frame.parentId);
    if (parent && ['outgoing-proxy', 'incoming-proxy'].includes(parent.role)) frame.role = 'static-probe';
  }
  const incomingByFrame = new Map(incoming.map(i => [i.frameId, i]));
  const outgoingByFrame = new Map(outgoing.map(o => [o.frameId, o]));
  function nearestIncoming(out) { return ancestors(byId.get(out.frameId)).map(f => incomingByFrame.get(f.id)).find(Boolean); }
  function nearestOutgoing(inc) { return ancestors(byId.get(inc.frameId)).map(f => outgoingByFrame.get(f.id)).find(Boolean); }
  function compatibleScope(out, inc) {
    if (matchingDisabled) return false;
    for (const link of transactionLinks) if (link.l1Execution?.frameId) {
      const l1 = byId.get(out.chain === 'L1' ? out.frameId : inc.frameId);
      const host = link.l1Execution.frameId;
      if (l1.id !== host && !l1.id.startsWith(`${host}.`)) return false;
    }
    if (transactionLinks.length || settlements.length) return out.settlementIds.some(s => inc.settlementIds.includes(s));
    // Bounded fallback has no canonical mapping. Require table evidence and a
    // matching entry identity as well as the full call identity.
    const table = tableById.get(inc.generationId);
    return inc.tableRows.length > 0 && (table?.rows || []).some(r => inc.tableRows.includes(r.id)) && out.entryCandidates.length > 0;
  }
  const assigned = new Map(), used = new Set();
  function available(out) {
    return incoming.filter(inc => !used.has(inc.id) && out.chain !== inc.chain && sameIdentity(out, inc) && compatibleScope(out, inc)).filter(inc => {
      const source = byId.get(out.frameId), target = byId.get(inc.frameId);
      if (!!source.error !== !!target.error || !same(source.output, target.output)) return false;
      const localParent = nearestIncoming(out), remoteParent = nearestOutgoing(inc);
      // Callbacks must return inside the corresponding suspended remote call.
      if (localParent && remoteParent && assigned.has(remoteParent.id)) return assigned.get(remoteParent.id) === localParent.id;
      if (localParent) {
        const matchedParent = outgoing.find(o => assigned.get(o.id) === localParent.id);
        if (matchedParent) return remoteParent?.id === matchedParent.id;
      }
      if (remoteParent && assigned.has(remoteParent.id)) return localParent?.id === assigned.get(remoteParent.id);
      // A nested occurrence cannot be attached before its enclosing call is
      // known. This also prevents mutually recursive candidate assignments.
      return !localParent && !remoteParent;
    });
  }
  function assign(out, inc, evidence) {
    assigned.set(out.id, inc.id); used.add(inc.id); out.status = 'matched'; out.remoteFrameId = inc.frameId;
    out.matchEvidence = ['source/destination identity', 'calldata', 'value', 'static context', transactionLinks.length ? 'verified transaction link scope' : settlements.length ? 'canonical settlement scope' : 'bounded table evidence', ...evidence];
    out.candidates = [inc.frameId]; inc.sourceFrameId = out.frameId;
  }
  let progress = true;
  while (progress) {
    progress = false;
    const pending = outgoing.filter(o => !assigned.has(o.id));
    for (const out of pending) {
      const candidates = available(out);
      // Reciprocal uniqueness prevents greedy theft between repeated requests.
      if (candidates.length === 1 && pending.filter(o => !assigned.has(o.id) && available(o).some(i => i.id === candidates[0].id)).length === 1) {
        assign(out, candidates[0], ['unique occurrence in current nested scope']); progress = true;
      }
    }
    if (progress) continue;
    // Equal repeated requests can be ordered only within one confirmed table
    // generation and one canonical settlement. Require
    // consumed entry positions and matching ordered table rows/delivery entries.
    for (const first of pending.filter(o => !assigned.has(o.id))) {
      const group = pending.filter(o => !assigned.has(o.id) && o.generationId === first.generationId && sameIdentity(first,o));
      if (group.length < 2 || first.settlementIds.length !== 1 || group.some(o => o.consumed.length !== 1 || nearestIncoming(o))) continue;
      if (transactions.some(t => !t.traceResult.trace && scopes(t,tableById.get(first.generationId)).some(s => first.settlementIds.includes(s)))) continue;
      if (first.entryCandidates.filter(e => e.pool === 'entries').length !== group.length) continue;
      const indices = group.map(o => Number(o.consumed[0].args.entryIndex ?? o.consumed[0].args.entryQueueIndex));
      if (new Set(indices).size !== group.length || indices.some((n,i) => !Number.isSafeInteger(n) || (i && n <= indices[i-1]))) continue;
      const candidates = available(first);
      if (candidates.length !== group.length || candidates.some(i => i.settlementIds.length !== 1 || nearestOutgoing(i) || !i.tableRows.length)) continue;
      if (pending.some(o => !group.includes(o) && available(o).some(i => candidates.includes(i)))) continue;
      candidates.sort((a,b) => {
        const x = byId.get(a.frameId), y = byId.get(b.frameId);
        return x.blockNumber - y.blockNumber || x.transactionIndex - y.transactionIndex || frames.indexOf(x) - frames.indexOf(y);
      });
      // L1 -> L2 deliveries replace the table for each delivery, entry zero.
      // L2 -> L1 rows are in a single ordered execution table.
      if (first.chain === 'L1' && new Set(candidates.map(i => i.generationId)).size !== candidates.length) continue;
      if (first.chain === 'L2' && new Set(candidates.map(i => i.generationId)).size !== 1) continue;
      // Ordering cannot override a later call's result or scope constraints.
      // Validate the entire group before assigning any of its occurrences.
      if (group.some((o,i) => !available(o).includes(candidates[i]))) continue;
      group.forEach((o,i) => assign(o,candidates[i], ['ordered consumed entries and complete delivery sequence'])); progress = true;
    }
  }
  for (const out of outgoing.filter(o => !assigned.has(o.id))) {
    // Keep the broader candidates as evidence when a missing enclosing frame
    // prevents the nesting constraints from proving an occurrence.
    const possible = incoming.filter(i => !used.has(i.id) && out.chain !== i.chain && sameIdentity(out,i) && compatibleScope(out,i));
    const source = byId.get(out.frameId);
    out.candidates = possible.filter(i => {
      const target = byId.get(i.frameId);
      return !!source.error === !!target.error && same(source.output,target.output);
    }).map(i => i.frameId);
    out.rejectedCandidates = possible.filter(i => !out.candidates.includes(i.frameId)).map(i => ({ frameId: i.frameId, reason: 'return-or-revert-mismatch' }));
    out.status = out.candidates.length ? 'ambiguous' : 'unresolved';
    out.precomputedResults = out.entryCandidates;
    const missingRemoteTrace = transactions.some(t => t.chain !== out.chain && !t.traceResult.trace);
    const prepared = !missingRemoteTrace && isPreparedLookup(out);
    out.resultKind = prepared ? 'precomputed-result-only' : null;
    if (prepared) {
      out.status = 'prepared-result';
      out.deliveryExpected = false;
      continue; // L1 lookups are resolved from prepared data; no L2 trace is missing.
    }
    unresolvedReason(out.candidates.length ? 'ambiguous-remote-occurrence' : 'remote-execution-unavailable',
      out.candidates.length ? 'Multiple physical occurrences remain possible' : 'No uniquely supported remote execution was observed',
      { frameId: out.frameId, candidateFrameIds: out.candidates, entryCandidates: out.entryCandidates });
  }
  // EEZL2 returns the outgoing value to its configured system address before
  // replaying the prepared result. This is protocol accounting, not an app receiver.
  // Keep the observed frame (including errors/rollback) and verify the destination
  // at the receipt block rather than assuming a network-specific constant.
  for (const frame of frames) {
    const parent = byId.get(frame.parentId);
    if (frame.chain === 'L2' && frame.type === 'CALL' && !frame.isStatic &&
        frame.input === '0x' && BigInt(frame.value) > 0n && frame.value === parent?.value &&
        same(frame.from, managers.L2) && same(parent?.contextAddress, managers.L2) &&
        parse.get(parent.id)?.name === 'executeCrossChainCall' &&
        same(frame.to, await l2SystemAddress(frame))) {
      frame.role = 'system-value-transfer';
      frame.systemTransfer = { address: frame.to, blockNumber: frame.blockNumber, provenance: 'SYSTEM_ADDRESS' };
    }
  }
  const decoder = new AbiDecoder(config, managers);
  for (const frame of frames) {
    const implementations = [];
    function delegates(f) { for (const id of f.children) { const c = byId.get(id); if (c.type === 'DELEGATECALL') { implementations.push(c.to); delegates(c); } } }
    delegates(frame);
    frame.decoded = await decoder.decode(frame, implementations);
  }
  // Cross-chain boundary labels describe the remote application, even when no
  // remote trace exists. This is call metadata, never a fabricated execution.
  for (const out of outgoing) {
    const remoteChain = out.chain === 'L1' ? 'L2' : 'L1';
    const local = byId.get(out.frameId);
    out.localResponse = await decoder.decode({ chain: remoteChain, to: out.targetAddress, input: out.data, output: local?.output || '0x', error: local?.error, role: 'application' });
    out.remoteCall = await decoder.decode({ chain: remoteChain, to: out.targetAddress, input: out.data, output: '0x', role: 'application' });
    if (out.remoteFrameId) out.remoteCall = byId.get(out.remoteFrameId).decoded;
  }
  for (const event of events) if (!event.decoded) {
    const contract = await decoder.contract(event.chain, event.address);
    try {
      const parsed = contract.iface?.parseLog(event);
      if (parsed) event.decoded = { name: parsed.name, signature: parsed.signature, arguments: named(parsed.fragment.inputs, parsed.args), provenance: 'explorer', provider: contract.abiProvider };
    } catch { /* Raw logs are retained. */ }
  }
  const logicalNodes = frames.map(frame => ({ id: frame.id, physicalFrameId: frame.id, chain: frame.chain,
    role: frame.role, decoded: frame.decoded, reverted: frame.reverted, children: [], boundary: outgoingByFrame.get(frame.id) || null }));
  const nodes = new Map(logicalNodes.map(n => [n.id,n]));
  const edges = [], relocated = new Set(outgoing.filter(o => o.remoteFrameId).map(o => o.remoteFrameId));
  for (const frame of frames) {
    const node = nodes.get(frame.id), out = outgoingByFrame.get(frame.id);
    for (const [order, child] of frame.children.entries()) {
      edges.push({ type: 'physical-call', from: frame.id, to: child, order });
      if (relocated.has(child)) continue;
      node.children.push(child);
      edges.push({ type: 'call', from: frame.id, to: child, order: node.children.length - 1 });
      edges.push({ type: 'return', from: child, to: frame.id, callFrom: frame.id });
    }
    if (out?.remoteFrameId) {
      const remote = out.remoteFrameId;
      const position = node.children.indexOf(out.managerFrameId);
      node.children.splice(position < 0 ? 0 : position, 0, remote);
      edges.push({ type: 'cross-chain', from: frame.id, to: remote, order: 0, evidence: out.matchEvidence,
        localProxy: frame.to, managerFrameId: out.managerFrameId, generationId: out.generationId });
      edges.push({ type: 'return', from: remote, to: frame.id, continuation: frame.parentId, crossChain: true });
    }
  }
  // Logical order is distinct from physical order after subtree relocation.
  for (const edge of edges) if (edge.type === 'call' || edge.type === 'cross-chain') edge.order = nodes.get(edge.from).children.indexOf(edge.to);
  // Edges may reference already-present callback frames. The renderer follows
  // each physical identity once; JSON keeps both physical and logical edges.
  return { frames, logicalNodes, logicalRoots: physicalRoots, edges, events, tables, outgoing, incoming };
}

function sameIdentity(a, b) {
  return same(a.sourceAddress,b.sourceAddress) && same(a.targetAddress,b.targetAddress) && same(a.data,b.data)
    && String(a.value) === String(b.value) && a.isStatic === b.isStatic
    && a.sourceRollupId != null && b.sourceRollupId != null && String(a.sourceRollupId) === String(b.sourceRollupId)
    && a.targetRollupId != null && b.targetRollupId != null && String(a.targetRollupId) === String(b.targetRollupId);
}

export function renderTrace(result, { full = false, recorded = false } = {}) {
  const link = (result.transactionLinks || []).find(l => l.state === 'complete' &&
    `${l.sourceChain}:${l.sourceHash}` === result.origin?.transactionId);
  if (link && recorded) {
    const frames = new Map(result.frames.map(f => [f.id, f]));
    const outgoing = new Map(result.outgoing.map(o => [o.frameId, o]));
    const roots = [], seen = new Set(), lines = [];
    const isolated = link.l1Execution?.frameId;
    if (isolated && frames.has(isolated)) roots.push({ id: isolated, label: `L1 entry ${link.l1Execution.entryIndex} for the requested L2 transaction` });
    for (const ref of link.references) {
      if (isolated && ref.chain === 'L1') continue;
      const id = `${ref.chain}:${ref.hash}:0`;
      if (frames.has(id) && !roots.some(r => r.id === id)) roots.push({ id, label: `${ref.chain} ${ref.role} ${ref.hash}` });
    }
    function physical(id, depth) {
      if (seen.has(id)) return;
      const f = frames.get(id); if (!f) return; seen.add(id);
      const hidden = !full && ['manager', 'incoming-proxy', 'static-probe', 'system-value-transfer'].includes(f.role);
      if (!hidden) {
        const d = f.decoded || {}, out = outgoing.get(id);
        const prepared = isPreparedResult(out);
        lines.push(`${'  '.repeat(depth)}${f.chain} ${d.contractName || 'Unknown contract'} · ${d.displayAddress || f.to} · ${d.signature || f.input.slice(0, 10)}${f.isStatic ? ' [read]' : ''}${f.error ? ' [reverted]' : f.reverted ? ' [rolled back]' : ''}${prepared ? ' [prepared result; no L2 delivery expected]' : ''}`);
        if (full) lines.push(`${'  '.repeat(depth + 1)}${f.id}`);
      }
      for (const child of f.children) physical(child, depth + (hidden ? 0 : 1));
    }
    for (const root of roots) { lines.push(root.label); physical(root.id, 0); }
    for (const tx of result.transactions.filter(t => !t.trace.available)) lines.push(`${tx.chain} ${tx.hash}: ${tx.trace.reason}`);
    return lines.join('\n');
  }
  const nodes = new Map(result.logicalNodes.map(n => [n.id, n]));
  const boundaries = new Map((result.outgoing || []).map(o => [o.frameId, o]));
  const visited = new Set(), lines = [];
  function walk(id, depth) {
    const node = nodes.get(id);
    if (!node) return;
    if (visited.has(id)) { if (full) lines.push(`${'  '.repeat(depth)}↪ ${id}`); return; }
    visited.add(id);
    const hidden = !full && ['manager','incoming-proxy','static-probe','system-value-transfer'].includes(node.role);
    if (!hidden) {
      const boundary = boundaries.get(id) || node.boundary, prepared = isPreparedResult(boundary);
      const call = prepared ? boundary.localResponse || node.decoded : boundary?.remoteCall || node.decoded;
      const chain = boundary && !prepared ? (node.chain === 'L1' ? 'L2' : 'L1') : node.chain;
      const fn = call.signature || (call.rawInput?.length >= 10 ? `${call.rawInput.slice(0,10)}(?)` : 'fallback()');
      lines.push(`${'  '.repeat(depth)}${boundary && !prepared ? '⇢ ' : ''}${chain}  ${call.contractName} · ${call.displayAddress} · ${fn}${node.reverted ? ' [reverted context]' : ''}${prepared ? ' [prepared result; no L2 delivery expected]' : boundary && boundary.status !== 'matched' ? ` [${boundary.resultKind || boundary.status}]` : ''}`);
      if (full) lines.push(`${'  '.repeat(depth+1)}${call.address || '(creation)'}  [${node.id}]`);
    }
    for (const child of node.children) {
      // A matched target is already named on its boundary. Render its children
      // here, retaining one physical target identity and the caller continuation.
      if (!full && node.boundary?.remoteFrameId === child && !visited.has(child)) {
        visited.add(child);
        for (const grandchild of nodes.get(child)?.children || []) walk(grandchild, depth + (hidden ? 0 : 1));
      } else walk(child, depth + (hidden ? 0 : 1));
    }
    if (!hidden && node.decoded.error) lines.push(`${'  '.repeat(depth + 1)}↳ ${node.decoded.error.name || node.decoded.error.message}`);
  }
  // Show trigger roots first; delivery plumbing disappears in the default view.
  const originRoot = `${result.origin?.transactionId}:0`;
  const roots = (link ? [originRoot].filter(id => nodes.has(id)) : [...result.logicalRoots]).sort((a,b) => {
    const x = nodes.get(a), y = nodes.get(b);
    return Number(x?.role === 'manager') - Number(y?.role === 'manager');
  });
  for (const root of roots) walk(root, 0);
  for (const tx of result.transactions.filter(t => !t.trace.available)) lines.push(`${tx.chain} ${tx.hash}: ${tx.trace.reason}`);
  return lines.join('\n');
}
