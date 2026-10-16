// Synthetic callTracer fixtures mirroring script/e2e/scenarios. These are ABI-
// encoded executions of those topologies, not historical archive-node captures.
import { ethers } from 'ethers';
import { callHash, hex, lower, protocol, proxyABI } from '../../src/protocol.mjs';
export const address = n => ethers.getAddress(`0x${n.toString(16).padStart(40,'0')}`);
export const hash = ethers.id;
export const M = {L1:address(1),L2:address(2)};
export const app = new ethers.Interface(['function run()','function increment() returns(uint256)','function callNested()','function incrementProxy()','function read() view returns(uint256)']);
const ZERO=ethers.ZeroHash, result=app.encodeFunctionResult('increment',[1]);
export const frame=(from,to,input='0x',calls=[],extra={})=>({type:'CALL',from,to,input,output:'0x',value:'0x0',calls,...extra});
export const event=(chain,name,args)=>({address:M[chain],...protocol[chain].encodeEventLog(protocol[chain].getEvent(name==='CrossChainCallExecuted'&&chain==='L2'?'CrossChainCallExecuted(bytes32,address,address,bytes,uint256,uint64)':name),args)});
export const row=(source,target,data,rid=0,extra={})=>({revertNextNCalls:0,isStatic:false,gas:0,sourceAddress:source,sourceRollupId:rid,targetAddress:target,value:0,data,...extra});
export const l1Entry=(key,calls=[],extra={})=>({rollupUpdates:[{rollupId:1,etherDelta:0,currentRoot:ZERO,newRoot:ZERO}],proxyEntryHash:key,l2ToL1Calls:calls,expectedL1ToL2Calls:[],rollingHash:ZERO,destinationRollupId:1,success:true,returnData:result,...extra});
export const l2Entry=(key,calls=[],extra={})=>({proxyEntryHash:key,incomingCalls:calls,expectedOutgoingCalls:[],rollingHash:ZERO,success:true,returnData:result,...extra});
export const batch=(entries,staticEntries=[])=>({expectedRootPerRollup:[],entries,staticEntries,immediateEntryCount:0,immediateStaticEntryCount:0,proofSystems:[address(90)],rollupIdsWithProofSystems:[{rollupId:1,proofSystemIndexes:[0]}],blobIndices:[],callData:'0x',proofs:['0x'],blockNumber:0,bindMsgSenderInPublicInput:false});

export function scenario({direction='L1',repeat=1,deep=false,isStatic=false,revert=false,rollback=false,ambiguous=false}={}) {
  const calls=[],txs={L1:new Map(),L2:new Map()},blocks={L1:new Map(),L2:new Map()},registry={L1:new Map(),L2:new Map()};
  const source=address(10),target=address(11),callback=address(12),inner=address(13);
  const outProxy=address(20),inProxy=address(21),backProxy=address(22),callbackProxy=address(23),innerProxy=address(24),innerSourceProxy=address(25);
  const remote=direction==='L1'?'L2':'L1',sourceRid=direction==='L1'?0:1,targetRid=1-sourceRid;
  const data=app.encodeFunctionData(isStatic?'read':deep?'callNested':'increment');
  const key=callHash({isStatic,sourceAddress:source,sourceRollupId:sourceRid,targetAddress:target,targetRollupId:targetRid,value:0,data});
  registry[direction].set(lower(outProxy),[true,target,targetRid]); registry[remote].set(lower(inProxy),[true,source,sourceRid]);
  const output=revert?'0xdeadbeef':result;
  function outgoing(chain,from,proxy,data,key,index,children=[]) {
    const fn=isStatic?'staticCrossChainCall':'executeCrossChainCall';
    const logs=isStatic?[]:[event(chain,'CrossChainCallExecuted',chain==='L1'?[key,proxy,from,data,0]:[key,proxy,from,data,0,0]),event(chain,'ExecutionConsumed',chain==='L1'?[key,1,index]:[key,index])];
    const manager=frame(proxy,M[chain],protocol[chain].encodeFunctionData(fn,[from,data]),children,{logs,output:revert?output:ethers.AbiCoder.defaultAbiCoder().encode(['bytes'],[output]),...(revert?{error:'execution reverted'}:{})});
    const probe=frame(proxy,proxy,proxyABI.encodeFunctionData('staticCheck'),[],isStatic?{error:'write protection'}:{});
    return frame(from,proxy,data,[probe,manager],{output,...(isStatic?{type:'STATICCALL'}:{}),...(revert?{error:'execution reverted'}:{})});
  }
  function delivery(chain,proxy,target,data,children=[]) {
    return frame(M[chain],proxy,proxyABI.encodeFunctionData('executeOnBehalf',[target,0,data]),[frame(proxy,target,data,children,{output,...(revert?{error:'execution reverted'}:{})})],{output,...(isStatic?{type:'STATICCALL'}:{}),...(revert?{error:'execution reverted'}:{})});
  }
  let localCallbacks=[],remoteChildren=[],l1Callbacks=[],nestedL2=[];
  if(deep) {
    if(direction!=='L1')throw new Error('Deep fixture mirrors E2EDeepNested');
    const backData=app.encodeFunctionData('incrementProxy'),innerData=app.encodeFunctionData('increment');
    const backKey=callHash({isStatic:false,sourceAddress:target,sourceRollupId:1,targetAddress:callback,targetRollupId:0,value:0,data:backData});
    const innerKey=callHash({isStatic:false,sourceAddress:callback,sourceRollupId:0,targetAddress:inner,targetRollupId:1,value:0,data:innerData});
    registry.L2.set(lower(backProxy),[true,callback,0]);registry.L1.set(lower(callbackProxy),[true,target,1]);
    registry.L1.set(lower(innerProxy),[true,inner,1]);registry.L2.set(lower(innerSourceProxy),[true,callback,0]);
    localCallbacks=[delivery('L1',callbackProxy,callback,backData,[outgoing('L1',callback,innerProxy,innerData,innerKey,0)])];
    remoteChildren=[outgoing('L2',target,backProxy,backData,backKey,0,[delivery('L2',innerSourceProxy,inner,innerData)])];
    l1Callbacks=[row(target,callback,backData,1)];
    nestedL2=[{expectedOutgoingHash:ZERO,incomingCalls:[row(callback,inner,innerData)],revertedOrStaticRollingHash:ZERO,success:true,returnData:result}];
  }
  const trigger=hash(`trigger-${direction}`),posting=hash('posting'),deliveries=[];
  const entriesL1=Array.from({length:repeat},()=>l1Entry(direction==='L1'?key:ZERO,direction==='L1'?l1Callbacks:[row(source,target,data,1,{isStatic})]));
  const entriesL2=Array.from({length:repeat},()=>l2Entry(key,direction==='L2'?[]:[row(source,target,data,0,{isStatic})],{expectedOutgoingCalls:nestedL2}));
  if(rollback)for(const entry of entriesL2)for(const call of entry.incomingCalls)call.revertNextNCalls=1;
  function add(chain,txHash,n,index,trace) {
    const blockHash=hash(`${chain}-block-${n}`);
    const transaction={hash:txHash,from:trace.from,to:trace.to,input:trace.input,blockNumber:hex(n),blockHash,transactionIndex:hex(index),value:'0x0'};
    const receipt={transactionHash:txHash,blockNumber:hex(n),blockHash,transactionIndex:hex(index),status:trace.error?'0x0':'0x1',logs:[]};
    function logs(f) {if(f.error)return;for(const l of f.logs||[])receipt.logs.push({...l,transactionHash:txHash,blockNumber:hex(n),blockHash,logIndex:hex(receipt.logs.length)});for(const c of f.calls||[])logs(c);}
    logs(trace);txs[chain].set(txHash,{transaction,receipt,trace});
    if(!blocks[chain].has(n))blocks[chain].set(n,{number:hex(n),hash:blockHash,timestamp:hex(n+1000),transactions:[]});
    blocks[chain].get(n).transactions.push(transaction);
  }
  const outs=Array.from({length:repeat},(_,i)=>outgoing(direction,source,outProxy,data,key,i,localCallbacks));
  if(ambiguous)for(const out of outs)out.calls[1].logs=out.calls[1].logs.filter(l=>l.topics[0]!==protocol[direction].getEvent('ExecutionConsumed').topicHash);
  if(direction==='L1') {
    add('L1',posting,100,0,frame(address(99),M.L1,protocol.L1.encodeFunctionData('postAndVerifyBatch',[batch(entriesL1)]),[],{logs:[event('L1','BatchPosted',[ZERO,[1]])]}));
    add('L1',trigger,100,1,frame(address(99),source,app.encodeFunctionData('run'),outs));
    for(let i=0;i<repeat;i++) {
      const id=hash(`delivery-${i}`);deliveries.push(id);
      let dispatch=delivery('L2',inProxy,target,data,remoteChildren);
      if(rollback)dispatch=frame(M.L2,M.L2,protocol.L2.encodeFunctionData('executeInContextAndRevert',[entriesL2[i].incomingCalls]),[dispatch],{error:'execution reverted'});
      add('L2',id,200,i,frame(address(98),M.L2,protocol.L2.encodeFunctionData('executeIncomingCrossChainCall',[[entriesL2[i]],[]]),[dispatch]));
    }
  } else {
    add('L2',hash('table-load'),200,0,frame(address(98),M.L2,protocol.L2.encodeFunctionData('loadExecutionTable',[entriesL2,[]])));
    add('L2',trigger,200,1,frame(address(99),source,app.encodeFunctionData('run'),outs));
    add('L1',posting,100,0,frame(address(99),M.L1,protocol.L1.encodeFunctionData('postAndVerifyBatch',[batch(entriesL1)]),Array.from({length:repeat},()=>delivery('L1',inProxy,target,data)),{logs:[event('L1','BatchPosted',[ZERO,[1]])]}));
    deliveries.push(posting);
  }
  const settlement={l1BlockNumber:'0x64',l1BlockHash:blocks.L1.get(100).hash,l1TransactionHash:posting,l1TransactionIndex:'0x0',l2Range:{firstBlockNumber:'0xc8',lastBlockNumber:'0xc8',blockCount:'0x1',firstBlockHash:blocks.L2.get(200).hash,lastBlockHash:blocks.L2.get(200).hash},l2Blocks:[{number:'0xc8',hash:blocks.L2.get(200).hash}],canonicalL2:true,l2Finalized:true};
  const composer={version:'test',supportedNetworks:{eezL1:100,eezL2:200},eezContracts:{eezRegistryAddress:M.L1,eezL2Address:M.L2,eezRollupManagerAddress:address(3)}};
  const failure={noCorrelation:false,txLookup:new Set(),receiptLookup:new Set(),transactionTrace:new Set(),allTrace:new Set()};
  async function rpc(url,method,params=[]) {
    calls.push({url,method,params});const chain=url.includes('l1')?'L1':'L2';
    if(method==='eth_chainId')return chain==='L1'?'0x64':'0xc8';
    if(method==='eez_composerInfo')return composer;
    if(method==='eez_getCrossChainTransaction')throw Object.assign(new Error('method not found'),{code:-32601});
    if(method.startsWith('eez_get')) {
      if(failure.noCorrelation||url.endsWith('-rpc'))throw new Error('method not found');
      if(params[0]==='0x1')return method==='eez_getSettlementByL2Block'?null:[];
      if (method==='eez_getSettlementByL2Block') {
        const matched = params[0]?.blockHash ? [...blocks.L2.values()].find(b=>b.hash===params[0].blockHash) : blocks.L2.get(Number(params[0]));
        return {...settlement, ...(matched ? {matchedL2Block:{number:matched.number,hash:matched.hash}} : {})};
      }
      return [settlement];
    }
    if(method==='eth_call') {
      const call=protocol[chain].parseTransaction({data:params[0].data});
      if(call.name==='ROLLUP_ID')return protocol[chain].encodeFunctionResult('ROLLUP_ID',[1]);
      if(call.name==='authorizedProxies')return protocol[chain].encodeFunctionResult('authorizedProxies',registry[chain].get(lower(call.args[0]))||[false,ethers.ZeroAddress,0]);
    }
    const tx=txs[chain].get(params[0]);
    if(method==='eth_getTransactionByHash')return failure.txLookup.has(params[0])?null:tx?.transaction??null;
    if(method==='eth_getTransactionReceipt')return failure.receiptLookup.has(params[0])?null:tx?.receipt??null;
    const block=method.endsWith('ByHash')||method==='eth_getBlockReceipts'?[...blocks[chain].values()].find(b=>b.hash===params[0]||b.number===params[0]):params[0]==='latest'?[...blocks[chain].values()].at(-1):blocks[chain].get(Number(params[0]));
    if(method==='eth_getBlockByNumber'||method==='eth_getBlockByHash')return block??null;
    if(method==='eth_getBlockReceipts')return block?.transactions.map(t=>txs[chain].get(t.hash).receipt)??[];
    if(method==='debug_traceTransaction'){if(failure.transactionTrace.has(params[0])||failure.allTrace.has(params[0]))throw new Error('historical state unavailable');return tx?.trace??null;}
    if(method.startsWith('debug_traceBlock'))return block?.transactions.map(t=>failure.allTrace.has(t.hash)?{txHash:t.hash,error:'historical state unavailable'}:{txHash:t.hash,result:txs[chain].get(t.hash).trace})??[];
    if(method==='eth_getLogs')return [...txs[chain].values()].flatMap(t=>t.receipt.logs).filter(l=>Number(l.blockNumber)>=Number(params[0].fromBlock)&&Number(l.blockNumber)<=Number(params[0].toBlock));
    throw new Error(`Unsupported fixture RPC: ${method}`);
  }
  return {config:{l1Rpc:'l1-rpc',l2Rpc:'l2-rpc',l1Front:'l1-front',l2Front:'l2-front',noExplorer:true,no4byte:true,rpc},calls,txs,blocks,registry,settlement,composer,failure,trigger,posting,deliveries,key,source,target,outProxy,inProxy};
}
