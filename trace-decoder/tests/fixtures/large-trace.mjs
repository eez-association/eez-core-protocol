// Deterministic synthetic capture for renderer tests, not a historical execution.
import { decodeCrossChainTrace } from '../../src/engine.mjs';
import { scenario, address } from './scenarios.mjs';

export async function largeTrace(count = 10_000, { uniqueContracts = false } = {}) {
  const fixture = scenario({ deep: true });
  const result = await decodeCrossChainTrace(fixture.config, fixture.trigger);
  const byId = new Map(result.frames.map(f => [f.id, f]));
  const logical = new Map(result.logicalNodes.map(n => [n.id, n]));
  const roots = [result.frames.find(f => f.transactionHash === fixture.trigger && f.path === '0'), byId.get(result.outgoing[0].remoteFrameId)];
  let parent;
  const initial = result.frames.length;
  for (let i = initial; i < count; i++) {
    const offset = i - initial;
    if (offset % 100 === 0) parent = roots[Math.floor(offset / 100) % 2];
    const path = `${parent.path}.${parent.children.length}`;
    const id = `${parent.chain}:${parent.transactionHash}:${path}`;
    const frame = { id, chain: parent.chain, transactionHash: parent.transactionHash, blockNumber: parent.blockNumber, path, parentId: parent.id,
      children: [], type: i % 17 === 0 ? 'STATICCALL' : 'CALL', role: 'application', from: parent.to, to: address(uniqueContracts ? 1000 + i : 40 + i % 3),
      input: `0x12345678${i.toString(16).padStart(64, '0')}`, output: '0x' + '01'.padStart(64, '0'), value: '0',
      isStatic: i % 17 === 0, error: i % 97 === 0 ? 'caught synthetic revert' : null, reverted: i % 97 === 0,
      decoded: { contractName: 'SyntheticWorker', functionName: 'localWork', signature: 'localWork(bytes32)',
        arguments: [{ name: 'key', type: 'string', value: `needle-${String(i).padStart(5, '0')}` }], returns: [{ name: '', type: 'uint256', value: String(i) }], provenance: { source: 'synthetic-fixture' } } };
    parent.children.push(id); logical.get(parent.id).children.push(id);
    const node = { id, physicalFrameId: id, chain: frame.chain, role: 'application', children: [], decoded: frame.decoded };
    result.frames.push(frame); result.logicalNodes.push(node); byId.set(id, frame); logical.set(id, node);
    result.edges.push({ type: 'physical-call', from: parent.id, to: id, order: parent.children.length - 1 }, { type: 'call', from: parent.id, to: id, order: logical.get(parent.id).children.length - 1 }, { type: 'return', from: id, to: parent.id });
    result.events.push({ id: `${id}/log/0`, frameId: id, chain: frame.chain, transactionHash: frame.transactionHash, provenance: 'trace', committed: null, reverted: frame.reverted, data: frame.input, decoded: { name: 'Work', arguments: frame.decoded.arguments } });
    parent = frame;
  }
  // Reconstruct original physical trees iteratively from the indexed frames.
  const raw = new Map(result.frames.map(f => [f.id, { type: f.type, from: f.from, to: f.to, input: f.input, output: f.output, value: f.value, calls: [], ...(f.error ? { error: f.error } : {}) }]));
  for (const f of result.frames) for (const id of f.children) raw.get(f.id).calls.push(raw.get(id));
  result.originalTraces = result.frames.filter(f => !f.parentId).map(f => ({ chain: f.chain, transactionHash: f.transactionHash, trace: raw.get(f.id) }));
  const ordered = [], stack = result.frames.filter(f => !f.parentId).reverse();
  while (stack.length) {
    const f = stack.pop(); ordered.push(f);
    for (let i = f.children.length - 1; i >= 0; i--) stack.push(byId.get(f.children[i]));
  }
  result.frames = ordered;
  result.logicalNodes = ordered.map(f => logical.get(f.id));
  return result;
}
