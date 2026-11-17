import assert from 'node:assert/strict';
import test from 'node:test';
import { ethers } from 'ethers';
import { decodeCrossChainTrace } from '../src/engine.mjs';
import { renderTrace } from '../src/logical.mjs';
import { loadConfig, parseEnv } from '../src/config.mjs';
import { AbiDecoder } from '../src/abi-decoder.mjs';
import { ChainReader, validateSettlement } from '../src/rpc.mjs';
import { hex, lower, shortAddress, protocol } from '../src/protocol.mjs';
import { scenario, address, app, hash, M, frame } from './fixtures/scenarios.mjs';

test('configuration is allowlisted, never evaluates shell, and supports minimal CLI',()=>{
  assert.deepEqual(parseEnv('export L1_RPC="https://one" # comment\nPRIVATE_KEY=secret\nL2_RPC=${L1_RPC}\n'),{L1_RPC:'https://one',L2_RPC:'https://one'});
  assert.throws(()=>parseEnv('L1_RPC=$(cat /secrets)'),/Shell/);
  assert.throws(()=>parseEnv('L1_RPC=${PRIVATE_KEY}'),/Unsupported/);
  assert.throws(()=>parseEnv('L1_RPC=${L2_RPC}\nL2_RPC=${L1_RPC}'),/Cyclic/);
  const config=loadConfig([hash('tx'),'--l1-rpc','override','--json'],{L1_RPC:'one',L2_RPC:'two'},'/nonexistent');
  assert.equal(config.l1Rpc,'override');assert.equal(config.l2Rpc,'two');assert.equal(config.json,true);
  assert.equal(loadConfig(['--tx',hash('tx')],{L1_RPC:'one',L2_RPC:'two'},'/nonexistent').tx,hash('tx'));
  assert.throws(()=>loadConfig([hash('tx'),'--l1-from','5'],{L1_RPC:'one',L2_RPC:'two'},'/nonexistent'),/both/);
  assert.throws(()=>loadConfig([hash('tx'),'--wat'],{},'/nonexistent'),/Unknown/);
});

for(const direction of ['L1','L2'])test(`${direction} trigger discovers and joins the opposite chain`,async()=>{
  const f=scenario({direction});const result=await decodeCrossChainTrace(f.config,f.trigger);
  assert.equal(result.schemaVersion,'1.0.0');assert.equal(result.origin.chain,direction);
  assert.equal(result.settlements.length,1);assert.equal(result.outgoing.length,1);
  assert.equal(result.outgoing[0].status,'matched');assert.equal(result.edges.filter(e=>e.type==='cross-chain').length,1);
  const cross=result.edges.find(e=>e.type==='cross-chain');
  const ret=result.edges.find(e=>e.crossChain&&e.type==='return');
  assert.equal(ret.from,cross.to);assert.equal(ret.to,cross.from);
  assert.equal(ret.continuation,result.frames.find(n=>n.id===cross.from).parentId);
  assert.equal(result.outgoing[0].remoteCall.address,f.target);
  assert.match(renderTrace(result),new RegExp(shortAddress(f.target)));
  assert.ok(JSON.stringify(result).includes(f.target));
  assert.equal(result.metadata.correlation,direction === 'L1' ? 'L1_FRONT' : 'L2_FRONT');
  assert.ok(f.calls.filter(c=>c.method==='eth_call'&&c.params[0].data.length>10).some(c=>c.params[1]===(direction==='L1'?'0x64':'0xc8')));
  assert.ok(!f.calls.filter(c=>c.method.startsWith('debug_')).some(c=>c.url.endsWith('front')));
});

test('composer supersedes stale env managers but explicit historical flags survive',async()=>{
  const f=scenario();const old=address(333);
  const result=await decodeCrossChainTrace({...f.config,rollups:old,managerL2:old,explicitManagers:{L1:false,L2:false}},f.trigger);
  assert.deepEqual(result.metadata.managers,M);assert.equal(result.diagnostics.filter(d=>d.code==='stale-manager-replaced').length,2);
  const historical=await decodeCrossChainTrace({...f.config,rollups:old,managerL2:old,explicitManagers:{L1:true,L2:true}},f.trigger);
  assert.deepEqual(historical.metadata.managers,{L1:old,L2:old});assert.equal(historical.outgoing.length,0);
  f.composer.supportedNetworks.eezL1=101;
  await assert.rejects(decodeCrossChainTrace(f.config,f.trigger),/chain ID/);
});

test('capability selection falls through override and L2 frontend to L1 frontend',async()=>{
  const f=scenario(),rpc=f.config.rpc;
  const result=await decodeCrossChainTrace({...f.config,correlationRpc:'override',rpc:async(url,method,params)=>{
    if((url==='override'||url==='l2-front')&&method.startsWith('eez_get'))throw Object.assign(new Error('unsupported'),{code:-32601});
    return rpc(url,method,params);
  }},f.trigger);
  assert.equal(result.metadata.correlation,'L1_FRONT');
});

test('settlement inclusion and canonical hashes are verified',async()=>{
  const f=scenario();const readers={L1:new ChainReader('L1','l1-rpc',null,f.config.rpc),L2:new ChainReader('L2','l2-rpc',null,f.config.rpc)};
  await assert.rejects(validateSettlement({...f.settlement,l1TransactionIndex:'0x1'},readers),/inclusion/);
  await assert.rejects(validateSettlement({...f.settlement,l1BlockHash:hash('reorg')},readers),/Noncanonical/);
  await assert.rejects(validateSettlement({...f.settlement,canonicalL2:false},readers),/canonical/);
  await assert.rejects(validateSettlement({...f.settlement,l2Range:{...f.settlement.l2Range,firstBlockHash:hash('fork')}},readers),/Inconsistent/);
  await assert.rejects(validateSettlement({...f.settlement,l2Blocks:[{number:'0xc8',hash:hash('reorg')}]},readers),/Inconsistent/);
  f.settlement.l1BlockHash=hash('reorg');
  const result=await decodeCrossChainTrace(f.config,f.trigger);
  assert.equal(result.settlements.length,0);assert.equal(result.edges.filter(e=>e.type==='cross-chain').length,0);
  assert.ok(result.unresolved.some(r=>r.code==='invalid-settlement'));
});

test('block transaction/receipt recovery and block tracer recovery retain links',async()=>{
  const f=scenario();f.failure.txLookup.add(f.posting);f.failure.receiptLookup.add(f.posting);f.failure.transactionTrace.add(f.trigger);
  const result=await decodeCrossChainTrace(f.config,f.trigger);
  assert.deepEqual(result.transactions.find(t=>t.hash===f.posting).recovery,['block-transaction','block-receipt']);
  assert.equal(result.transactions.find(t=>t.hash===f.trigger).trace.provenance,'debug_traceBlockByHash');
  assert.equal(result.outgoing[0].status,'matched');
});

test('both missing indexes can recover the origin inside an explicit range',async()=>{
  const f=scenario();f.failure.txLookup.add(f.trigger);f.failure.receiptLookup.add(f.trigger);
  const result=await decodeCrossChainTrace({...f.config,l1From:100,l1To:100},f.trigger);
  assert.equal(result.origin.transactionId,`L1:${f.trigger}`);
});

test('unavailable historical state preserves settlements without synthetic frames',async()=>{
  const f=scenario();f.failure.allTrace.add(f.posting);f.failure.allTrace.add(f.trigger);
  const result=await decodeCrossChainTrace(f.config,f.deliveries[0]);
  assert.equal(result.settlements.length,1);
  assert.ok(result.transactions.some(t=>t.hash===f.posting&&!t.trace.available));
  assert.ok(!result.frames.some(t=>t.transactionHash===f.posting));
  assert.equal(result.edges.filter(e=>e.type==='cross-chain').length,0);
  assert.ok(result.unresolved.some(r=>r.code==='historical-state-unavailable'));
  assert.ok(result.tables.some(t=>t.provenance==='transaction-calldata'));
});

for(const direction of ['L1','L2'])test(`${direction} repeated identical calls use complete ordered occurrences`,async()=>{
  const f=scenario({direction,repeat:2});const result=await decodeCrossChainTrace(f.config,f.trigger);
  assert.equal(result.outgoing.length,2);assert.ok(result.outgoing.every(o=>o.status==='matched'));
  assert.equal(new Set(result.outgoing.map(o=>o.remoteFrameId)).size,2);
  assert.ok(result.outgoing.every(o=>o.matchEvidence.includes('ordered consumed entries and complete delivery sequence')));
});

for (const direction of ['L1', 'L2']) for (const mismatch of ['return', 'revert']) {
  test(`${direction} ordered repeated calls reject a later ${mismatch} mismatch`, async () => {
    const f = scenario({ direction, repeat: 2 });
    const second = f.txs[direction].get(f.trigger).trace.calls[1];
    const manager = second.calls[1];
    if (mismatch === 'return') {
      second.output = app.encodeFunctionResult('increment', [2]);
      manager.output = ethers.AbiCoder.defaultAbiCoder().encode(['bytes'], [second.output]);
    } else {
      // Equal bytes must still not match a successful remote return to a revert.
      second.error = manager.error = 'execution reverted';
    }
    const result = await decodeCrossChainTrace(f.config, f.trigger);
    assert.equal(result.outgoing.length, 2);
    assert.ok(result.outgoing.every(o => o.status !== 'matched'));
    assert.equal(result.edges.filter(e => e.type === 'cross-chain').length, 0);
    assert.equal(result.outgoing[1].rejectedCandidates.length, 2);
    assert.ok(result.outgoing[1].rejectedCandidates.every(c => c.reason === 'return-or-revert-mismatch'));
  });
}

test('repeated hashes alone leave candidates ambiguous',async()=>{
  const f=scenario({repeat:2,ambiguous:true});const result=await decodeCrossChainTrace(f.config,f.trigger);
  assert.ok(result.outgoing.every(o=>o.status==='ambiguous'&&o.candidates.length===2));
  assert.equal(result.edges.filter(e=>e.type==='cross-chain').length,0);
});

test('deepNested callback relocation preserves order, return destinations and identities',async()=>{
  const f=scenario({deep:true});const result=await decodeCrossChainTrace(f.config,f.trigger);
  assert.equal(result.outgoing.length,3);assert.ok(result.outgoing.every(o=>o.status==='matched'));
  const seen=new Set(),order=[];const nodes=new Map(result.logicalNodes.map(n=>[n.id,n]));
  function walk(id,path=new Set()) {
    assert.ok(!path.has(id),'logical graph must be acyclic');
    if(seen.has(id))return;seen.add(id);
    const n=nodes.get(id);if(n.boundary)order.push(n.boundary.targetAddress);
    for(const child of n.children)walk(child,new Set([...path,id]));
  }
  const root=result.logicalRoots.find(id=>id.startsWith(`L1:${f.trigger}`));walk(root);
  assert.deepEqual(order,[f.target,address(12),address(13)]);
  assert.equal(result.edges.filter(e=>e.type==='cross-chain').length,3);
  const output=renderTrace(result);
  for(const target of order)assert.equal(output.split(shortAddress(target)).length-1,1);
});

test('static probes, caught reverts, and rollback spans remain physical evidence',async()=>{
  for(const options of [{isStatic:true},{revert:true},{rollback:true}]) {
    const f=scenario(options);const result=await decodeCrossChainTrace(f.config,f.trigger);
    assert.equal(result.outgoing[0].status,'matched');
    assert.ok(result.frames.some(n=>n.role==='static-probe'));
    assert.equal(result.outgoing[0].isStatic,!!options.isStatic);
    if(options.rollback)assert.ok(result.incoming.every(i=>i.reverted));
    if(options.revert)assert.ok(result.frames.some(n=>n.error&&n.role==='outgoing-proxy'));
    assert.ok(renderTrace(result,{full:true}).length>renderTrace(result).length);
  }
});

test('mismatched reverted attempt cannot borrow a later successful delivery',async()=>{
  const f=scenario({revert:true});
  const remote=f.txs.L2.get(f.deliveries[0]).trace.calls[0].calls[0];delete remote.error;remote.output=app.encodeFunctionResult('increment',[1]);
  const result=await decodeCrossChainTrace(f.config,f.trigger);
  assert.equal(result.outgoing[0].status,'unresolved');assert.equal(result.edges.filter(e=>e.type==='cross-chain').length,0);
});

test('fallback uses the timestamp, ±2000 blocks and 500-block log chunks',async()=>{
  const f=scenario();f.failure.noCorrelation=true;
  const rpc=f.config.rpc;
  const config={...f.config,rpc:async(url,method,params)=>{
    if(url==='l2-rpc'&&method==='eth_getBlockByNumber') {
      const n=params[0]==='latest'?6000:Number(params[0]);
      return {number:hex(n),hash:hash(`fallback-${n}`),timestamp:hex(Math.max(0,n-1900)),transactions:[]};
    }
    if(url==='l2-rpc'&&method==='eth_getLogs')return [];
    return rpc(url,method,params);
  }};
  const result=await decodeCrossChainTrace(config,f.trigger);
  assert.deepEqual(result.metadata.search[0],{chain:'L2',from:1000,to:5000,chunkSize:500,source:'timestamp-fallback'});
  assert.ok(result.unresolved.some(r=>r.code==='bounded-search-exhausted'));
  assert.equal(result.edges.filter(e=>e.type==='cross-chain').length,0);
});

test('explorer first, observed implementation ABI and chain-specific names',async()=>{
  const requests=[];
  const decoder=new AbiDecoder({l1Explorer:'https://l1',l2Explorer:'https://l2',fetch:async url=>{
    requests.push(url);
    const implementation=url.includes(address(9));
    return {ok:true,json:async()=>url.includes('smart-contracts')?{name:implementation?'Implementation':url.includes('l1')?'CounterL1':'CounterL2',abi:implementation?app.formatJson():null}:{result:[]}};
  }},M);
  const f={chain:'L1',to:address(8),input:app.encodeFunctionData('increment'),output:app.encodeFunctionResult('increment',[7])};
  const l1=await decoder.decode(f,[address(9)]);
  assert.equal(l1.provenance.source,'explorer-delegatecall');assert.equal(l1.contractName,'CounterL1');assert.equal(l1.returns[0].value,'7');
  const l2=await decoder.decode({...f,chain:'L2'},[address(9)]);assert.equal(l2.contractName,'CounterL2');
  assert.ok(!requests.some(u=>u.includes('4byte')));
});

test('4byte fallback validates collisions, preserves ambiguity and unknown names',async()=>{
  const requests=[];
  const decoder=new AbiDecoder({l1Explorer:'https://explorer',fetch:async url=>{
    requests.push(url);return {ok:true,json:async()=>url.includes('4byte')?{results:[{text_signature:'burn(uint256)'},{text_signature:'collate_propagate_storage(bytes16)'},{text_signature:'transfer(address,uint256)'}]}:{result:[]}};
  }},M);
  // Famous real selector collision; zero is canonical under both signatures.
  const input=new ethers.Interface(['function burn(uint256)']).encodeFunctionData('burn',[0]);
  const decoded=await decoder.decode({chain:'L1',to:address(8),input,output:'0x'});
  assert.equal(decoded.candidates.length,2);assert.equal(decoded.functionName,null);assert.equal(decoded.contractName,'Unknown contract');
  assert.equal(decoded.rawInput,input);assert.ok(requests.at(-1).includes('4byte'));
  assert.ok(requests.slice(0,-1).every(u=>u.includes('explorer')));
});

test('multiple settlements in one L1 block retain their separate table generations and ranges',async()=>{
  const f=scenario(), other=scenario();
  const post2=hash('post2'),trigger2=hash('trigger2'),delivery2=hash('delivery2');
  function copy(chain,oldHash,newHash,blockNumber,index) {
    const record=structuredClone(other.txs[chain].get(oldHash));
    const blockHash=chain==='L1'?f.blocks.L1.get(100).hash:hash('second-l2-block');
    Object.assign(record.transaction,{hash:newHash,blockNumber:hex(blockNumber),blockHash,transactionIndex:hex(index)});
    Object.assign(record.receipt,{transactionHash:newHash,blockNumber:hex(blockNumber),blockHash,transactionIndex:hex(index)});
    for(const log of record.receipt.logs)Object.assign(log,{transactionHash:newHash,blockNumber:hex(blockNumber),blockHash});
    f.txs[chain].set(newHash,record);
    if(!f.blocks[chain].has(blockNumber))f.blocks[chain].set(blockNumber,{number:hex(blockNumber),hash:blockHash,timestamp:hex(1201),transactions:[]});
    f.blocks[chain].get(blockNumber).transactions.push(record.transaction);
  }
  copy('L1',other.posting,post2,100,2);copy('L1',other.trigger,trigger2,100,3);copy('L2',other.deliveries[0],delivery2,201,0);
  const second={...f.settlement,l1TransactionHash:post2,l1TransactionIndex:'0x2',l2Blocks:[{number:'0xc9',hash:f.blocks.L2.get(201).hash}],l2Range:{...f.settlement.l2Range,firstBlockNumber:'0xc9',lastBlockNumber:'0xc9',firstBlockHash:f.blocks.L2.get(201).hash,lastBlockHash:f.blocks.L2.get(201).hash}};
  const rpc=f.config.rpc;
  const result=await decodeCrossChainTrace({...f.config,rpc:async(url,method,params)=>method==='eez_getSettledL2RangesByL1Block'&&params[0]?.blockHash===f.blocks.L1.get(100).hash?[f.settlement,second]:rpc(url,method,params)},f.trigger);
  assert.equal(result.settlements.length,2);assert.equal(result.outgoing.length,2);
  assert.ok(result.outgoing.every(o=>o.status==='matched'));
  assert.notEqual(result.outgoing[0].generationId,result.outgoing[1].generationId);
  assert.notEqual(result.outgoing[0].remoteFrameId,result.outgoing[1].remoteFrameId);
});

test('wrapper-mediated eventless delivery is found by the observed manager trace (thorough scan)',async()=>{
  const f=scenario();const delivery=f.txs.L2.get(f.deliveries[0]);
  const inner=delivery.trace;delivery.trace={...inner,to:address(77),input:'0x',calls:[inner]};
  delivery.transaction.to=address(77);delivery.transaction.input='0x';delivery.receipt.logs=[];
  // The default events-first scan skips a transaction with no manager call or event.
  const quick=await decodeCrossChainTrace(f.config,f.trigger);
  assert.notEqual(quick.outgoing[0].status,'matched');
  const result=await decodeCrossChainTrace({...f.config,thorough:true},f.trigger);
  assert.equal(result.outgoing[0].status,'matched');
  assert.ok(result.outgoing[0].remoteFrameId.endsWith('0.0.0.0'));
});

test('missing remote trace preserves local callbacks and precomputed result evidence',async()=>{
  const f=scenario({deep:true});f.failure.allTrace.add(f.deliveries[0]);
  const result=await decodeCrossChainTrace(f.config,f.trigger);
  assert.equal(result.edges.filter(e=>e.type==='cross-chain').length,0);
  assert.ok(result.frames.some(n=>n.to===address(12)));
  assert.ok(result.outgoing[0].precomputedResults.length);
  assert.equal(result.outgoing[0].resultKind,null,'missing trace cannot prove result-only execution');
  assert.ok(renderTrace(result).includes(shortAddress(address(12))));
});

test('a precomputed static result is represented without inventing a remote execution',async()=>{
  const f=scenario({isStatic:true});const delivery=f.txs.L2.get(f.deliveries[0]);delivery.trace.calls=[];
  const result=await decodeCrossChainTrace(f.config,f.trigger);
  assert.equal(result.outgoing[0].status,'prepared-result');assert.equal(result.outgoing[0].resultKind,'precomputed-result-only');
  assert.ok(!result.unresolved.some(u=>u.code==='remote-execution-unavailable'));
  assert.equal(result.incoming.length,0);assert.equal(result.edges.filter(e=>e.type==='cross-chain').length,0);
});

test('gas-policy differences do not make the hash an occurrence identity',async()=>{
  const f=scenario({direction:'L2'});
  const manager=f.txs.L2.get(f.trigger).trace.calls[0].calls[1];
  const original=manager.logs[0];
  const parsed=protocol.L2.parseLog(original);
  manager.logs[0]={...original,...protocol.L2.encodeEventLog(parsed.fragment,[hash('sampled-gas-call'),parsed.args.proxy,parsed.args.sourceAddress,parsed.args.callData,0,123456])};
  const result=await decodeCrossChainTrace(f.config,f.trigger);
  assert.equal(result.outgoing[0].status,'matched');assert.equal(result.outgoing[0].gasPolicy,'123456');
});

test('explicit fallback ranges avoid timestamp search and record bounded exhaustion',async()=>{
  const f=scenario();f.failure.noCorrelation=true;
  const result=await decodeCrossChainTrace({...f.config,l2From:'200',l2To:'200'},f.trigger);
  assert.ok(!f.calls.some(c=>c.method==='eth_getBlockByNumber'&&c.params[0]==='latest'));
  assert.ok(result.metadata.search.every(s=>s.from===200&&s.to===200));
  assert.equal(result.outgoing[0].status,'matched');
});

test('real reth changeset exhaustion is reported as unavailable historical state',async()=>{
  const f=scenario(),rpc=f.config.rpc;
  const reader=new ChainReader('L1','l1-rpc',null,async(url,method,params)=>{
    if(method.startsWith('debug_'))throw new Error('failed to apply blockhash contract call: insufficient changesets to revert to block #23456276');
    return rpc(url,method,params);
  });
  const record=await reader.recover(f.posting);const trace=await reader.trace(record);
  assert.equal(trace.reason,'historical-state-unavailable');assert.equal(trace.failures.length,3);
});

test('block trace cannot fall back to a different explicitly identified transaction',async()=>{
  const f=scenario(),rpc=f.config.rpc;
  const reader=new ChainReader('L1','l1-rpc',null,async(url,method,params)=>{
    if(method==='debug_traceTransaction')throw new Error('no transaction index');
    if(method.startsWith('debug_traceBlock'))return [
      {txHash:hash('wrong1'),result:f.txs.L1.get(f.posting).trace},
      {txHash:hash('wrong2'),result:f.txs.L1.get(f.trigger).trace},
    ];
    return rpc(url,method,params);
  });
  assert.equal((await reader.trace(await reader.recover(f.trigger))).trace,null);
});

test('block receipt recovery rejects inconsistent canonical coordinates',async()=>{
  const f=scenario();f.failure.receiptLookup.add(f.posting);
  f.txs.L1.get(f.posting).receipt.blockHash=hash('fork');
  const reader=new ChainReader('L1','l1-rpc',null,f.config.rpc);
  await assert.rejects(reader.recover(f.posting),/canonical inclusion/);
});

test('delegatecall manager frames share a table load and outgoing occurrence',async()=>{
  const f=scenario();const manager=f.txs.L1.get(f.trigger).trace.calls[0].calls[1];
  const inner=structuredClone(manager);inner.type='DELEGATECALL';inner.to=address(55);inner.from=M.L1;
  manager.calls=[inner];manager.logs=[];
  const delivery=f.txs.L2.get(f.deliveries[0]).trace;
  const impl=structuredClone(delivery);impl.type='DELEGATECALL';impl.to=address(56);impl.from=M.L2;delivery.calls=[impl];
  const result=await decodeCrossChainTrace(f.config,f.trigger);
  assert.equal(result.outgoing.length,1);assert.equal(result.outgoing[0].status,'matched');
  assert.equal(result.tables.filter(t=>t.chain==='L2').length,1);
});

test('failed nested table replacement restores the previous generation',async()=>{
  const f=scenario();const root=f.txs.L1.get(f.trigger).trace;
  const failed=structuredClone(f.txs.L1.get(f.posting).trace);failed.error='execution reverted';
  root.calls.unshift(failed);
  const result=await decodeCrossChainTrace(f.config,f.trigger);
  const original=result.tables.find(t=>t.transactionHash===f.posting);
  assert.equal(result.outgoing[0].generationId,original.id);assert.equal(result.outgoing[0].status,'matched');
  assert.ok(result.tables.some(t=>!t.committed));
});


test('an L2-to-L1 read with missing execution is not an expected no-delivery result', async () => {
  const f = scenario({ direction: 'L2', isStatic: true });
  f.txs.L1.get(f.posting).trace.calls = [];
  const result = await decodeCrossChainTrace(f.config, f.trigger);
  assert.equal(result.outgoing[0].status, 'unresolved');
  assert.equal(result.outgoing[0].resultKind, null);
  assert.ok(result.unresolved.some(u => u.code === 'remote-execution-unavailable'));
});


test('an unobserved remote call never inherits a local manager failure', async () => {
  const f = scenario({ revert: true });
  f.txs.L2.get(f.deliveries[0]).trace.calls = [];
  const result = await decodeCrossChainTrace(f.config, f.trigger), out = result.outgoing[0];
  assert.equal(out.localResponse.rawOutput, '0xdeadbeef');
  assert.ok(out.localResponse.error);
  assert.equal(out.remoteCall.rawOutput, '0x');
  assert.equal(out.remoteCall.error, null);
  assert.notEqual(out.remoteCall, out.localResponse);
});


test('file references use exported overrides, with empty exports falling back to the file', async () => {
  const fs = await import('node:fs'), os = await import('node:os'), path = await import('node:path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'decoder-config-'));
  try {
    fs.writeFileSync(path.join(dir, 'chain.env'),
      'L1_RPC=https://old.example\nL2_RPC=https://l2.example\nL1_FRONT=$L1_RPC\nL1_TRACE_RPC=${L1_FRONT}\n');
    const overridden = loadConfig([hash('tx')], { L1_RPC: 'https://new.example' }, dir);
    assert.equal(overridden.l1Rpc, 'https://new.example');
    assert.equal(overridden.l1Front, overridden.l1Rpc);
    assert.equal(overridden.l1TraceRpc, overridden.l1Rpc);
    const empty = loadConfig([hash('tx')], { L1_RPC: '', L1_FRONT: '' }, dir);
    assert.equal(empty.l1Front, 'https://old.example');
    assert.equal(empty.l1TraceRpc, empty.l1Front);
    const cli = loadConfig([hash('tx'), '--l1-front', 'https://cli.example'], { L1_RPC: 'https://new.example' }, dir);
    assert.equal(cli.l1Front, 'https://cli.example');
    // Exported URLs are literal, even if their paths contain a dollar sign.
    const literal = 'https://new.example/$L2_RPC';
    assert.equal(loadConfig([hash('tx')], { L1_RPC: literal }, dir).l1Front, literal);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('empty exported settings fall back to the file and env managers pin discovery', async () => {
  const fs = await import('node:fs'), os = await import('node:os'), path = await import('node:path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'decoder-config-'));
  try {
    const f = scenario(), old = address(333);
    fs.writeFileSync(path.join(dir, 'chain.env'), `L1_RPC=l1-rpc\nL2_RPC=l2-rpc\nL1_TRACE_RPC=archive\nROLLUPS=${old}\nMANAGER_L2=${old}\n`);
    const loaded = loadConfig([f.trigger], { L1_RPC: '', L1_TRACE_RPC: '' }, dir);
    assert.equal(loaded.l1Rpc, 'l1-rpc'); assert.equal(loaded.l1TraceRpc, 'archive');
    assert.deepEqual(loaded.explicitManagers, { L1:true, L2:true });
    const result = await decodeCrossChainTrace({ ...f.config, ...loaded, l1TraceRpc:undefined }, f.trigger);
    assert.deepEqual(result.metadata.managers, { L1:old, L2:old });
    const overridden = loadConfig([f.trigger, '--l1-manager', M.L1], { ROLLUPS:address(444) }, dir);
    assert.equal(overridden.rollups, M.L1);
  } finally { fs.rmSync(dir, { recursive:true, force:true }); }
});

for (const direction of ['L1','L2']) test(`split settlement fronts use the ${direction} block-hash method only`, async () => {
  const f = scenario({ direction }), rpc = f.config.rpc, lookups = [];
  const result = await decodeCrossChainTrace({ ...f.config, rpc:async (url,method,params) => {
    if (method.startsWith('eez_getSettlement') || method.startsWith('eez_getSettled')) {
      lookups.push({url,method,params});
      assert.ok(params[0]?.blockHash, 'no numeric capability probe');
      const allowed = method === 'eez_getSettlementByL2Block' ? 'l2-front' : 'l1-front';
      if (url !== allowed) throw Object.assign(new Error('method not found'), {code:-32601});
    }
    return rpc(url,method,params);
  } }, f.trigger);
  assert.equal(result.outgoing[0].status,'matched');
  assert.equal(lookups.length,1);
  assert.equal(lookups[0].url,direction.toLowerCase()+'-front');
  assert.ok(!result.metadata.search.some(s=>s.source==='timestamp-fallback'));
});


for (const variant of ['system', 'reverted', 'wrong destination', 'unavailable identity', 'application caller', 'different value', 'nonempty calldata']) {
  test(`L2 system value transfer classification: ${variant}`, async () => {
    const f = scenario({direction:'L2'}), root = f.txs.L2.get(f.trigger).trace;
    const proxy = root.calls[0], manager = proxy.calls[1], system = address(700);
    root.value = proxy.value = manager.value = '0x5';
    const transfer = frame(M.L2,system,'0x',[],{value:'0x5'});
    manager.calls.push(transfer);
    if (variant === 'reverted') manager.error = 'execution reverted';
    if (variant === 'wrong destination') transfer.to = address(701);
    if (variant === 'application caller') transfer.from = f.source;
    if (variant === 'different value') transfer.value = '0x4';
    if (variant === 'nonempty calldata') transfer.input = '0x12345678';
    const rpc = f.config.rpc, reads = [];
    f.config.rpc = (url,method,params) => {
      if (method === 'eth_call' && params[0].data === protocol.L2.encodeFunctionData('SYSTEM_ADDRESS')) {
        reads.push(params);
        if (variant === 'unavailable identity') throw new Error('historical read unavailable');
        return protocol.L2.encodeFunctionResult('SYSTEM_ADDRESS',[system]);
      }
      return rpc(url,method,params);
    };
    const result = await decodeCrossChainTrace(f.config,f.trigger);
    const found = result.frames.find(n=>n.to===transfer.to && n.input===transfer.input && n.from===transfer.from);
    assert.ok(found);
    const verified = ['system','reverted'].includes(variant);
    assert.equal(found.role,verified?'system-value-transfer':'application');
    if (verified) {
      assert.equal(found.decoded.contractName,'L2 system');
      assert.equal(found.reverted,variant==='reverted');
      assert.ok(reads.length && reads.every(p=>p[1]==='0xc8'));
      assert.ok(!renderTrace(result).includes('L2 system'));
      assert.ok(renderTrace(result,{full:true}).includes('L2 system'));
    }
  });
}


test('a conflicting pinned manager warns without replacing the pin',async()=>{
  const f=scenario(),old=address(333);
  const result=await decodeCrossChainTrace({...f.config,rollups:old,managerL2:old,explicitManagers:{L1:true,L2:true}},f.trigger);
  assert.deepEqual(result.metadata.managers,{L1:old,L2:old});
  assert.deepEqual(result.diagnostics.filter(d=>d.code==='pinned-manager-mismatch').map(d=>d.chain),['L1','L2']);
});

for(const failure of ['connection','timeout','http'])test(`correlation retries ${failure} failures without broad scanning`,async()=>{
  const f=scenario({direction:'L2'}),rpc=f.config.rpc,attempts=[];
  const result=await decodeCrossChainTrace({...f.config,rpc:async(url,method,params)=>{
    if(method==='eez_getSettlementByL2Block'){
      attempts.push(url);
      if(url==='l2-front')throw Object.assign(new Error(failure),failure==='http'?{transport:true}:{code:failure==='connection'?'ECONNRESET':'ETIMEDOUT'});
    }
    return rpc(url,method,params);
  }},f.trigger);
  assert.deepEqual(attempts,['l2-front','l1-front']);
  assert.equal(result.metadata.correlation,'L1_FRONT');
  assert.equal(result.outgoing[0].status,'matched');
  assert.ok(!result.metadata.search.some(s=>s.source==='timestamp-fallback'));
  assert.ok(!result.unresolved.some(u=>u.code==='correlation-lookup-failed'));
});

test('malformed settlement answers stop endpoint failover and broad scanning',async()=>{
  const f=scenario({direction:'L2'}),rpc=f.config.rpc,attempts=[];
  const result=await decodeCrossChainTrace({...f.config,rpc:async(url,method,params)=>{
    if(method==='eez_getSettlementByL2Block'){attempts.push(url);return 'not a settlement';}
    return rpc(url,method,params);
  }},f.trigger);
  assert.deepEqual(attempts,['l2-front']);
  assert.equal(result.metadata.search.length,0);
  assert.ok(result.unresolved.some(u=>u.code==='correlation-lookup-failed'));
});
