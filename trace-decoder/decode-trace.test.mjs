import assert from "node:assert/strict";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { ethers } from "ethers";
import {
  BATCH_POSTED_TOPIC, loadLocalABIs, decodeReceiptLogs, decodeEventLog,
  extractL2BlocksFromTx, findL2BlocksFromL1, findBatchBlockByL2Ref,
  enrichCallTree, serializeCallNode, serializeEvent, buildJsonResponse,
  findMatchingL2Trace, resolveProxyTargetFromChain, detectChain,
  discoverSystemContracts, traceTransaction,
} from "./decode-trace.mjs";

// Encode fixtures with the actual contract ABI, not a copy of the decoder's ABI.
const out = fileURLToPath(new URL("../out/", import.meta.url));
loadLocalABIs(out);
const artifact = name => new ethers.Interface(
  JSON.parse(fs.readFileSync(`${out}/${name}.sol/${name}.json`, "utf8")).abi);
const l1ABI = artifact("EEZ");
const l2ABI = artifact("EEZL2");
const coder = ethers.AbiCoder.defaultAbiCoder();
const L1 = "0x1111111111111111111111111111111111111111";
const L2 = "0x2222222222222222222222222222222222222222";
const OTHER = "0x3333333333333333333333333333333333333333";
const PROXY = "0x4444444444444444444444444444444444444444";
const HASH = ethers.id("call");
const TX1 = ethers.id("transaction one");
const TX2 = ethers.id("transaction two");
const opts = { rollups: L1, managerL2: L2, noExplorer: true };

function batch(callData) {
  return {
    expectedRootPerRollup: [{ rollupId: 1, root: HASH }],
    entries: [{
      rollupUpdates: [{ rollupId: 1, etherDelta: 0, currentRoot: HASH, newRoot: HASH }],
      proxyEntryHash: HASH, l2ToL1Calls: [], expectedL1ToL2Calls: [],
      rollingHash: HASH, destinationRollupId: 1, success: true, returnData: "0x",
    }],
    staticEntries: [], immediateEntryCount: 0, immediateStaticEntryCount: 0,
    proofSystems: [OTHER], rollupIdsWithProofSystems: [{ rollupId: 1, proofSystemIndexes: [0] }],
    blobIndices: [], callData, proofs: ["0x1234"], blockNumber: 0,
    bindMsgSenderInPublicInput: false,
  };
}

const refs = blocks => coder.encode(["uint256[]", "bytes[]"], [blocks, blocks.map(() => "0xab")]);
const post = data => ({ to: L1, data: l1ABI.encodeFunctionData("postAndVerifyBatch", [batch(data)]) });
function event(iface, name, args, address, extra = {}) {
  return { ...iface.encodeEventLog(iface.getEvent(name), args), address, ...extra };
}
const posted = (txHash, extra = {}) => event(l1ABI, "BatchPosted", [HASH, [1]], L1,
  { transactionHash: txHash, blockNumber: 100, ...extra });
const incoming = (extra = {}) => event(l2ABI, "IncomingCrossChainCallExecuted",
  [HASH, false, OTHER, 0, PROXY, 0, 0, "0x1234"], L2, extra);
const outgoing = (extra = {}) => event(l1ABI, "CrossChainCallExecuted",
  [HASH, PROXY, OTHER, "0x1234", 0], L1, extra);
function receipt(logs, extra = {}) {
  return {
    hash: TX1, blockHash: ethers.id("block"), blockNumber: 100,
    status: 1, from: OTHER, to: L1,
    logs: logs.map((log, index) => ({ ...log, index })), ...extra,
  };
}

test("batch discovery uses the current two-field contract event", () => {
  assert.equal(BATCH_POSTED_TOPIC, l1ABI.getEvent("BatchPosted").topicHash);
  assert.notEqual(BATCH_POSTED_TOPIC, ethers.id("BatchPosted(uint256,bytes32,uint64[])"));
});

test("reads callData from the batch tuple with nonempty preceding fields", async () => {
  const provider = { getTransaction: async () => post(refs([41, 42, 41])) };
  assert.deepEqual(await extractL2BlocksFromTx(TX1, provider, L1), [41, 42]);
});

test("opaque payloads and unsupported wrappers do not invent block references", async () => {
  const payloads = ["0x", "0x1234", refs([2n ** 64n]),
    coder.encode(["uint256[]", "bytes[]"], [[41], []])];
  for (const data of payloads) {
    assert.deepEqual(await extractL2BlocksFromTx(TX1, { getTransaction: async () => post(data) }, L1), []);
  }
  assert.deepEqual(await extractL2BlocksFromTx(TX1, {
    getTransaction: async () => ({ ...post(refs([41])), to: OTHER }),
  }, L1), []);
  assert.deepEqual(await extractL2BlocksFromTx(TX1, { getTransaction: async () => null }, L1), []);
});

test("discovers every posting and rejects foreign, removed, malformed and obsolete logs", async () => {
  const queried = [];
  const transactions = new Map([[TX1, post(refs([41]))], [TX2, post(refs([42]))]]);
  const provider = {
    getLogs: async filter => {
      assert.equal(filter.address, L1);
      assert.deepEqual(filter.topics, [l1ABI.getEvent("BatchPosted").topicHash]);
      return [
        posted(ethers.id("foreign"), { address: OTHER }),
        posted(ethers.id("removed"), { removed: true }),
        posted(ethers.id("malformed"), { data: "0x" }),
        posted(ethers.id("obsolete"), { topics: [ethers.id("BatchPosted(uint256,bytes32,uint64[])")] }),
        posted(TX1), posted(TX1), posted(TX2),
      ];
    },
    getTransaction: async hash => { queried.push(hash); return transactions.get(hash); },
  };
  assert.deepEqual(await findL2BlocksFromL1(100, opts, provider), {
    l2Blocks: [41, 42], batchTx: TX1, batchTxs: [TX1, TX2],
  });
  assert.deepEqual(queried, [TX1, TX2]);
  assert.deepEqual(await findBatchBlockByL2Ref(42, 99, 101, opts, provider), {
    l1Block: 100, batchTx: TX2, l2Blocks: [42],
  });
});

test("unknown manager does not trigger an unscoped event query", async () => {
  const provider = { getLogs: async () => assert.fail("unscoped query") };
  assert.deepEqual(await findL2BlocksFromL1(100, {}, provider), {
    l2Blocks: [], batchTx: null, batchTxs: [],
  });
});

test("receipt serialization retains emitter, coordinates and full wire data", () => {
  const r = receipt([outgoing(), outgoing({ address: OTHER })]);
  const decoded = decodeReceiptLogs(r);
  assert.equal(decoded[0].args.crossChainCallHash, HASH);
  const result = decoded.map(log => serializeEvent(log, "L1"));
  assert.equal(result[0].address, L1);
  assert.equal(result[1].address, OTHER);
  assert.equal(result[1].logIndex, 1);
  assert.equal(result[0].transactionHash, TX1);
  assert.equal(result[0].blockHash, r.blockHash);
  assert.equal(result[0].provenance, "receipt");
  assert.equal(result[0].committed, true);
  assert.deepEqual(result[0].topics, r.logs[0].topics);
  assert.equal(result[0].data, r.logs[0].data);
  assert.deepEqual(decodeReceiptLogs({ ...r, status: 0 }), []);
  assert.deepEqual(decodeReceiptLogs(receipt([outgoing({ removed: true })])), []);
});

test("trace attempts remain separate from committed receipts, including parent rollback", async () => {
  const attempted = outgoing();
  const committed = posted(TX1);
  const trace = {
    to: L1, logs: [committed], calls: [{
      to: OTHER, error: "execution reverted", calls: [{
        type: "DELEGATECALL", to: PROXY, logs: [attempted],
      }],
    }],
  };
  const r = receipt([committed]);
  await enrichCallTree(trace, null, 0, { receipt: r });
  const json = buildJsonResponse(trace, [], r, opts);
  assert.deepEqual(json.events.map(e => e.name), ["BatchPosted"]);
  assert.equal(json.callTree.logs[0].provenance, "trace");
  assert.equal(json.callTree.logs[0].committed, null);
  const reverted = json.callTree.calls[0].calls[0].logs[0];
  assert.equal(reverted.address, L1); // Delegatecall emitter, not implementation address.
  assert.equal(reverted.committed, false);
  assert.equal(reverted.provenance, "trace");
});

test("L2 events are sourced from their receipts and retain log order", async () => {
  const l1Trace = { to: L1 };
  const l2Trace = { to: L2, logs: [incoming({ address: OTHER })] };
  await enrichCallTree(l1Trace, null);
  await enrichCallTree(l2Trace, null);
  const r2 = receipt([incoming(), incoming()], { hash: TX2, to: L2 });
  const json = buildJsonResponse(l1Trace, [l2Trace], receipt([]), opts, [r2]);
  assert.deepEqual(json.events.map(e => [e.chain, e.address, e.logIndex]), [
    ["L2", L2, 0], ["L2", L2, 1],
  ]);
  assert.equal(json.events[0].transactionHash, TX2);
});

test("delivery candidates require a unique incoming receipt log from the L2 manager", () => {
  const trace = logs => ({ _receiptLogs: decodeReceiptLogs(receipt(logs)) });
  const genuine = trace([incoming()]);
  const spoof = trace([incoming({ address: OTHER })]);
  const outgoingL2 = trace([event(l2ABI,
    "CrossChainCallExecuted(bytes32,address,address,bytes,uint256,uint64)",
    [HASH, PROXY, OTHER, "0x1234", 0, 0], L2)]);
  assert.equal(findMatchingL2Trace(HASH, [genuine, spoof, outgoingL2], L2), genuine);
  assert.equal(findMatchingL2Trace(HASH, [spoof, outgoingL2], L2), null);
  assert.equal(findMatchingL2Trace(HASH, [genuine, trace([incoming()])], L2), null);
  assert.equal(findMatchingL2Trace(HASH, [trace([incoming(), incoming()])], L2), null);
  assert.equal(findMatchingL2Trace(ethers.id("other gas identity"), [genuine], L2), null);
});

test("unmatched cross-chain calls keep their local callbacks", async () => {
  const trace = {
    to: L1, input: l1ABI.encodeFunctionData("executeCrossChainCall", [OTHER, "0x1234"]),
    calls: [{ to: OTHER, input: "0x12345678" }],
  };
  await enrichCallTree(trace, null);
  const json = serializeCallNode(trace, "L1", [], opts);
  assert.equal(json.inlinedL2, null);
  assert.equal(json.calls.length, 1);
  assert.equal(json.calls[0].to, OTHER);
});

test("reverted outgoing attempts cannot borrow a later committed log's delivery", async () => {
  const trace = {
    to: L1, error: "execution reverted", logs: [outgoing()],
    input: l1ABI.encodeFunctionData("executeCrossChainCall", [OTHER, "0x1234"]),
  };
  await enrichCallTree(trace, null, 0, { receipt: receipt([outgoing()]) });
  const remote = { _receiptLogs: decodeReceiptLogs(receipt([incoming()])) };
  assert.equal(serializeCallNode(trace, "L1", [remote], opts).inlinedL2, null);
});

test("proxy identity is read from the manager at the receipt block", async () => {
  const calls = [];
  const provider = { call: async tx => {
    calls.push(tx);
    assert.equal(tx.to, L1);
    assert.equal(tx.blockTag, 100);
    const args = l1ABI.decodeFunctionData("authorizedProxies", tx.data);
    assert.equal(args[0], PROXY);
    return l1ABI.encodeFunctionResult("authorizedProxies", [true, OTHER, 9007199254740993n]);
  } };
  assert.deepEqual(await resolveProxyTargetFromChain(PROXY, provider, L1, 100), {
    originalAddress: OTHER, originalRollupId: "9007199254740993",
  });
  await resolveProxyTargetFromChain(PROXY, provider, L1, 100);
  assert.equal(calls.length, 1);
  assert.equal(await resolveProxyTargetFromChain(PROXY, provider, L1, undefined), null);
  assert.equal(await resolveProxyTargetFromChain(PROXY, {
    call: async () => l1ABI.encodeFunctionResult("authorizedProxies", [false, ethers.ZeroAddress, 0]),
  }, L1, 100), null);
});

test("missing L1 transactions fall through to L2 and discovery keeps the chains separate", async () => {
  assert.equal(await detectChain(TX1,
    { getTransaction: async () => null }, { getTransaction: async () => ({ hash: TX1 }) }), "L2");
  assert.equal(await detectChain(TX1,
    { getTransaction: async () => null }, { getTransaction: async () => null }), null);
  const options = {};
  discoverSystemContracts({ _funcName: "executeCrossChainCall", to: L2 }, options, "L2");
  assert.deepEqual(options, { managerL2: L2 });
});

test("full local decoder flow discovers posts and uses receipts without network access", async () => {
  const data = post(refs([41]));
  const input = l1ABI.encodeFunctionData("executeCrossChainCall", [OTHER, "0x1234"]);
  const r1 = receipt([outgoing(), posted(TX1)]);
  const r2 = receipt([incoming()], { hash: TX2, blockNumber: 41, to: L2 });
  const l1 = {
    getTransaction: async () => data,
    getTransactionReceipt: async () => r1,
    getLogs: async () => [posted(TX1)],
    send: async method => {
      assert.equal(method, "debug_traceTransaction");
      return { to: L1, from: OTHER, input, logs: [outgoing()] };
    },
  };
  const l2 = {
    getBlock: async () => ({ prefetchedTransactions: [{ to: L2, hash: TX2 }] }),
    getTransactionReceipt: async () => r2,
    send: async () => ({ to: L2, logs: [incoming()] }),
  };
  const result = await traceTransaction(TX1, l1, l2, { ...opts }, { silent: true });
  assert.deepEqual(result.batchTxs, [TX1]);
  assert.deepEqual(result.l2Blocks, [41]);
  const json = buildJsonResponse(result.l1Trace, result.l2Traces, result.l1Receipt, opts, result.l2Receipts);
  assert.equal(json.events.length, 3);
  assert.equal(json.callTree.inlinedL2.correlation, "hash-candidate");
  assert.equal(json.callTree.inlinedL2.txHash, TX2);
  assert.equal(json.l2Traces.length, 1);
});
