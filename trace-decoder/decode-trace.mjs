#!/usr/bin/env node
// ═══════════════════════════════════════════════════════════════════════
// Cross-chain trace decoder — unified view
// ═══════════════════════════════════════════════════════════════════════
//
// Given a tx hash, produces a unified cross-chain execution flow
// joining L1 and L2 traces into one diagram. Events at the end.
//
// Usage:
//   node decode-trace.mjs --tx <HASH> --l1-rpc <RPC> --l2-rpc <RPC>
//     [--l1-explorer <URL>] [--l2-explorer <URL>] [--no-explorer]
//
// EEZ (L1) / EEZL2 addresses are auto-discovered from the trace
// (the contract receiving executeCrossChainCall). Env vars with
// 0x addresses are auto-picked up as labels.
//
// Current EEZ/EEZL2 ABIs come from local artifacts. Top-level event lists use
// committed receipt logs; call-tree logs are explicitly marked as trace evidence.
// Cross-chain hash matches are candidates, not occurrence identities. Different gas
// policies can prevent a match. Batch callData is application-defined: the optional
// block-reference decoder recognizes abi.encode(uint256[], bytes[]) only. Empty or
// other payloads, and internal posts through wrappers, leave block joins unresolved.

import { ethers } from "ethers";
import fs from "fs";
import path from "path";
import { fileURLToPath, pathToFileURL } from "node:url";

// ══════════════════════════════════════════════
//  Colors (disabled when piped)
// ══════════════════════════════════════════════

const isTTY = process.stdout.isTTY;
const c = {
  red: (s) => (isTTY ? `\x1b[31m${s}\x1b[0m` : s),
  green: (s) => (isTTY ? `\x1b[32m${s}\x1b[0m` : s),
  yellow: (s) => (isTTY ? `\x1b[33m${s}\x1b[0m` : s),
  cyan: (s) => (isTTY ? `\x1b[36m${s}\x1b[0m` : s),
  dim: (s) => (isTTY ? `\x1b[2m${s}\x1b[0m` : s),
  bold: (s) => (isTTY ? `\x1b[1m${s}\x1b[0m` : s),
};

// ══════════════════════════════════════════════
//  CLI args
// ══════════════════════════════════════════════

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {
    tx: "",
    l1Rpc: "",
    l2Rpc: "",
    rollups: "",    // auto-discovered from trace
    managerL2: "",  // auto-discovered from trace
    l1Explorer: "https://l1-explorer.example.net",
    l2Explorer: "https://l2-explorer.example.net",
    noExplorer: false,
    json: false,
  };
  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--tx":         opts.tx = args[++i]; break;
      case "--l1-rpc":     opts.l1Rpc = args[++i]; break;
      case "--l2-rpc":     opts.l2Rpc = args[++i]; break;
      case "--l1-explorer": opts.l1Explorer = args[++i]; break;
      case "--l2-explorer": opts.l2Explorer = args[++i]; break;
      case "--no-explorer": opts.noExplorer = true; break;
      case "--json":       opts.json = true; break;
    }
  }
  const required = ["tx", "l1Rpc", "l2Rpc"];
  for (const key of required) {
    if (!opts[key]) {
      console.error(`Missing: --${key.replace(/([A-Z])/g, "-$1").toLowerCase()}`);
      process.exit(1);
    }
  }
  // Pick up ROLLUPS / MANAGER_L2 from env if available
  if (process.env.ROLLUPS) opts.rollups = process.env.ROLLUPS;
  if (process.env.MANAGER_L2) opts.managerL2 = process.env.MANAGER_L2;
  return opts;
}

// Walk callTracer tree to find the contract that receives executeCrossChainCall
function discoverSystemContracts(trace, opts, chain) {
  function walk(node) {
    if (node._funcName === "executeCrossChainCall" && node.to) {
      const key = chain === "L2" ? "managerL2" : "rollups";
      if (!opts[key]) opts[key] = node.to;
    }
    if (node._funcName === "executeIncomingCrossChainCall" && node.to) {
      if (!opts.managerL2) opts.managerL2 = node.to;
    }
    if (node._funcName === "postAndVerifyBatch" && node.to) {
      if (!opts.rollups) opts.rollups = node.to;
    }
    if (node._funcName === "loadExecutionTable" && node.to) {
      if (!opts.managerL2) opts.managerL2 = node.to;
    }
    for (const child of node.calls || []) walk(child);
  }
  walk(trace);
}

// ══════════════════════════════════════════════
//  ABI Registry — 3-tier selector resolution
// ══════════════════════════════════════════════

/** @type {Map<string, ethers.Interface>} selector (0xABCD) or topic0 → Interface that knows it */
const selectorToIface = new Map();
const topicToIface = new Map();
/** All loaded interfaces for brute-force decode attempts */
const allIfaces = [];
/** Interface → contract name (from filename). e.g. iface → "Rollups" */
const ifaceToName = new Map();
/** selector → contract name (derived from ifaceToName) */
const selectorToContractName = new Map();

function loadLocalABIs(outDir) {
  if (!fs.existsSync(outDir)) return;
  const dirs = fs.readdirSync(outDir);
  for (const dir of dirs) {
    const full = path.join(outDir, dir);
    if (!fs.statSync(full).isDirectory()) continue;
    const files = fs.readdirSync(full).filter((f) => f.endsWith(".json"));
    for (const file of files) {
      try {
        const json = JSON.parse(fs.readFileSync(path.join(full, file), "utf8"));
        const abi = json.abi;
        if (!Array.isArray(abi) || abi.length === 0) continue;
        const contractName = file.replace(".json", ""); // e.g. "Rollups"
        const iface = new ethers.Interface(abi);
        allIfaces.push(iface);
        ifaceToName.set(iface, contractName);

        // Index function selectors
        iface.forEachFunction((fn) => {
          selectorToIface.set(fn.selector, iface);
          selectorToContractName.set(fn.selector, contractName);
        });
        // Index event topics
        iface.forEachEvent((ev) => {
          topicToIface.set(ev.topicHash, iface);
        });
      } catch {}
    }
  }
}

// Given an address and the calls it received, guess which contract it is
// by matching the selectors against local ABIs.
function identifyContractBySelectors(callNodes) {
  const hits = new Map(); // contractName → count
  for (const node of callNodes) {
    if (!node.input || node.input.length < 10) continue;
    const sel = node.input.slice(0, 10);
    const name = selectorToContractName.get(sel);
    if (name) hits.set(name, (hits.get(name) || 0) + 1);
  }
  // Return the most-matched contract name
  let best = null, bestCount = 0;
  for (const [name, count] of hits) {
    if (count > bestCount) { best = name; bestCount = count; }
  }
  return best;
}

async function fetchBlockscoutABI(addr, explorerUrl) {
  try {
    const url = `${explorerUrl}/api?module=contract&action=getabi&address=${addr}`;
    const resp = await fetch(url, { signal: AbortSignal.timeout(5000) });
    const json = await resp.json();
    if (!json.result || json.result === "Contract source code not verified") return null;
    const abi = JSON.parse(json.result);
    if (!Array.isArray(abi) || abi.length === 0) return null;
    const iface = new ethers.Interface(abi);
    allIfaces.push(iface);
    iface.forEachFunction((fn) => selectorToIface.set(fn.selector, iface));
    iface.forEachEvent((ev) => topicToIface.set(ev.topicHash, iface));
    return iface;
  } catch {
    return null;
  }
}

async function fetch4byte(selector) {
  try {
    const url = `https://www.4byte.directory/api/v1/signatures/?hex_signature=${selector}&ordering=created_at`;
    const resp = await fetch(url, { signal: AbortSignal.timeout(5000) });
    const json = await resp.json();
    if (json.results && json.results.length > 0) {
      return json.results[0].text_signature; // e.g. "transfer(address,uint256)"
    }
  } catch {}
  return null;
}

function decodeFunctionCall(input) {
  const selector = input.slice(0, 10);
  // Tier 1: local ABIs
  const iface = selectorToIface.get(selector);
  if (iface) {
    try {
      const parsed = iface.parseTransaction({ data: input });
      if (parsed) return parsed;
    } catch {}
  }
  // Tier 1b: brute force all loaded interfaces
  for (const ifc of allIfaces) {
    try {
      const parsed = ifc.parseTransaction({ data: input });
      if (parsed) {
        selectorToIface.set(selector, ifc);
        return parsed;
      }
    } catch {}
  }
  return null;
}

function decodeFunctionResult(input, output) {
  const selector = input.slice(0, 10);
  const iface = selectorToIface.get(selector);
  if (!iface) return null;
  try {
    const parsed = iface.parseTransaction({ data: input });
    if (!parsed) return null;
    return iface.decodeFunctionResult(parsed.name, output);
  } catch {
    return null;
  }
}

function decodeLog(log) {
  const topic0 = log.topics?.[0];
  if (!topic0) return null;
  // Tier 1: local ABIs
  const iface = topicToIface.get(topic0);
  if (iface) {
    try {
      return iface.parseLog(log);
    } catch {}
  }
  // Brute force
  for (const ifc of allIfaces) {
    try {
      const parsed = ifc.parseLog(log);
      if (parsed) {
        topicToIface.set(topic0, ifc);
        return parsed;
      }
    } catch {}
  }
  return null;
}

function decodeEventLog(log, provenance, receipt = null, reverted = false) {
  const parsed = decodeLog(log);
  return {
    name: parsed?.name ?? null,
    args: parsed?.args,
    fragment: parsed?.fragment,
    address: log.address ?? null,
    topics: log.topics ?? [],
    data: log.data ?? "0x",
    transactionHash: log.transactionHash ?? receipt?.hash ?? null,
    blockHash: log.blockHash ?? receipt?.blockHash ?? null,
    blockNumber: log.blockNumber ?? receipt?.blockNumber ?? null,
    logIndex: log.index ?? log.logIndex ?? null,
    provenance,
    committed: provenance === "receipt" ? true : (reverted ? false : null),
  };
}

function decodeReceiptLogs(receipt) {
  if (!receipt || Number(receipt.status) !== 1) return [];
  return (receipt.logs || []).filter(log => !log.removed)
    .map(log => decodeEventLog(log, "receipt", receipt));
}

// ══════════════════════════════════════════════
//  Label Registry
// ══════════════════════════════════════════════

const labels = new Map();

function label(addr) {
  if (!addr) return "?";
  return labels.get(addr.toLowerCase()) || addr.slice(0, 10) + "...";
}

function buildLabels(opts) {
  if (opts.rollups) labels.set(opts.rollups.toLowerCase(), "EEZ");
  if (opts.managerL2) labels.set(opts.managerL2.toLowerCase(), "EEZL2");
}

function refreshSystemLabels(opts) {
  if (opts.rollups) labels.set(opts.rollups.toLowerCase(), "EEZ");
  if (opts.managerL2) labels.set(opts.managerL2.toLowerCase(), "EEZL2");
}

// Auto-label all addresses in a trace using Blockscout names + local ABI matching
async function discoverLabels(trace, opts) {
  const addrs = collectAllAddresses(trace);

  // Group calls by target address (for ABI-based identification)
  const callsByAddr = new Map();
  function collectCalls(node) {
    if (node.to) {
      const lo = node.to.toLowerCase();
      if (!callsByAddr.has(lo)) callsByAddr.set(lo, []);
      callsByAddr.get(lo).push(node);
    }
    for (const child of node.calls || []) collectCalls(child);
  }
  collectCalls(trace);

  for (const addr of addrs) {
    const lo = addr.toLowerCase();
    if (labels.has(lo)) continue;

    // Strategy 1: Blockscout name
    if (!opts.noExplorer) {
      for (const url of [opts.l1Explorer, opts.l2Explorer]) {
        try {
          const resp = await fetch(`${url}/api/v2/addresses/${addr}`, {
            signal: AbortSignal.timeout(3000),
          });
          const json = await resp.json();
          if (json.is_contract === false) {
            labels.set(lo, `EOA_${addr.slice(0, 8)}`);
            break;
          }
          if (json.name && json.name !== "null") {
            labels.set(lo, json.name);
            await fetchBlockscoutABI(addr, url);
            break;
          }
        } catch {}
      }
    }

    // Strategy 2: identify by which local ABI decodes its calls
    if (!labels.has(lo)) {
      const calls = callsByAddr.get(lo) || [];
      // Check if this is a CrossChainProxy: it receives an arbitrary call
      // and its child calls executeCrossChainCall on a system contract
      const isProxy = calls.some((n) => {
        return (n.calls || []).some((child) => {
          const childParsed = decodeFunctionCall(child.input || "");
          return childParsed && childParsed.name === "executeCrossChainCall";
        });
      });
      if (isProxy) {
        labels.set(lo, "CrossChainProxy");
      } else {
        const contractName = identifyContractBySelectors(calls);
        if (contractName) {
          labels.set(lo, contractName);
        }
      }
    }
  }
}

// ══════════════════════════════════════════════
//  RPC helpers
// ══════════════════════════════════════════════

async function getCallTrace(provider, txHash) {
  return provider.send("debug_traceTransaction", [
    txHash,
    { tracer: "callTracer", tracerConfig: { withLog: true } },
  ]);
}

// Proxy identity lives in the manager registry, not in getters on the proxy.
const proxyTargetCache = new WeakMap();
const PROXY_REGISTRY_IFACE = new ethers.Interface([
  "function authorizedProxies(address) view returns (bool isProxy, address originalAddress, uint64 originalRollupId)",
]);

async function resolveProxyTargetFromChain(proxyAddr, provider, manager, blockTag) {
  if (!manager || blockTag == null) return null;
  let cache = proxyTargetCache.get(provider);
  if (!cache) proxyTargetCache.set(provider, cache = new Map());
  const key = `${manager.toLowerCase()}:${proxyAddr.toLowerCase()}:${blockTag}`;
  if (cache.has(key)) return cache.get(key);
  try {
    const result = await provider.call({
      to: manager,
      data: PROXY_REGISTRY_IFACE.encodeFunctionData("authorizedProxies", [proxyAddr]),
      blockTag,
    });
    const [isProxy, originalAddress, originalRollupId] =
      PROXY_REGISTRY_IFACE.decodeFunctionResult("authorizedProxies", result);
    const info = isProxy ? { originalAddress, originalRollupId: originalRollupId.toString() } : null;
    cache.set(key, info);
    return info;
  } catch {
    return null;
  }
}

async function detectChain(txHash, l1, l2) {
  try {
    if (await l1.getTransaction(txHash)) return "L1";
  } catch {}
  try {
    if (await l2.getTransaction(txHash)) return "L2";
  } catch {}
  return null;
}

// ══════════════════════════════════════════════
//  Cross-chain block correlation
//  (ported from E2EBase.sh / decode-trace.sh)
// ══════════════════════════════════════════════

const BATCH_POSTED_IFACE = new ethers.Interface([
  "event BatchPosted(bytes32 sharedPublicInput, uint64[] rollupIds)",
]);
const BATCH_POSTED_TOPIC = BATCH_POSTED_IFACE.getEvent("BatchPosted").topicHash;
const L2_CONTEXT = "0x5FbDB2315678afecb367f032d93F642f64180aa3";

// Optional application convention, not a core protocol field or delivery proof.
// Only direct posts to the confirmed emitting manager are decoded here.
async function extractL2BlocksFromTx(txHash, provider, manager) {
  try {
    const tx = await provider.getTransaction(txHash);
    if (!tx || !manager || tx.to?.toLowerCase() !== manager.toLowerCase()) return [];
    const parsed = decodeFunctionCall(tx.data);
    if (!parsed || parsed.name !== "postAndVerifyBatch") return [];
    const callDataBytes = parsed.args[0].callData;
    if (!callDataBytes || callDataBytes === "0x") return [];
    const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
      ["uint256[]", "bytes[]"],
      callDataBytes
    );
    if (decoded[0].length !== decoded[1].length) return [];
    return [...new Set(decoded[0].map((n) => ethers.getNumber(n)))];
  } catch {
    return [];
  }
}

// Validate the emitter and payload, as well as topic0, before interpreting a post.
async function getBatchLogs(fromBlock, toBlock, opts, provider) {
  if (!opts.rollups) return [];
  const logs = await provider.getLogs({
    fromBlock, toBlock, address: opts.rollups, topics: [BATCH_POSTED_TOPIC],
  });
  return logs.filter((log) => {
    if (log.removed || log.address?.toLowerCase() !== opts.rollups.toLowerCase()) return false;
    if (log.topics?.[0] !== BATCH_POSTED_TOPIC || !log.transactionHash) return false;
    try {
      return BATCH_POSTED_IFACE.parseLog(log) != null;
    } catch {
      return false;
    }
  });
}

// Include every confirmed post in this block, not only the first transaction.
async function findL2BlocksFromL1(l1Block, opts, l1) {
  const logs = await getBatchLogs(l1Block, l1Block, opts, l1);
  const batchTxs = [...new Set(logs.map((log) => log.transactionHash))];
  const l2Blocks = new Set();
  for (const txHash of batchTxs) {
    for (const block of await extractL2BlocksFromTx(txHash, l1, opts.rollups)) l2Blocks.add(block);
  }
  return { l2Blocks: [...l2Blocks], batchTx: batchTxs[0] ?? null, batchTxs };
}

// L2 → L1: find the L1 batch block from an L2 block via L2Context contract.
// L2Context.contexts(l2Block) returns (parentL1Block, hash). Batch is at parent+1.
async function findL1BlockFromL2(l2Block, l2) {
  try {
    const iface = new ethers.Interface(["function contexts(uint256) view returns (uint256, bytes32)"]);
    const data = iface.encodeFunctionData("contexts", [l2Block]);
    const result = await l2.call({ to: L2_CONTEXT, data });
    const decoded = iface.decodeFunctionResult("contexts", result);
    const parentL1 = Number(decoded[0]);
    if (parentL1 === 0) return null;
    return parentL1 + 1; // batch is typically at parent + 1
  } catch {
    return null;
  }
}

// Search L1 blocks [from..to] for a BatchPosted tx referencing a specific L2 block.
async function findBatchBlockByL2Ref(l2Block, l1From, l1To, opts, l1) {
  const logs = await getBatchLogs(l1From, l1To, opts, l1);

  // Deduplicate by tx hash
  const seen = new Set();
  for (const log of logs) {
    if (seen.has(log.transactionHash)) continue;
    seen.add(log.transactionHash);
    const l2Blocks = await extractL2BlocksFromTx(log.transactionHash, l1, opts.rollups);
    if (l2Blocks.includes(l2Block)) {
      return { l1Block: log.blockNumber, batchTx: log.transactionHash, l2Blocks };
    }
  }
  return null;
}

// Find all ManagerL2 txs in an L2 block
async function findL2ManagerTxs(l2Block, opts, l2) {
  const block = await l2.getBlock(l2Block, true);
  if (!block || !block.prefetchedTransactions) return [];
  const managerLo = opts.managerL2.toLowerCase();
  return block.prefetchedTransactions
    .filter((tx) => tx.to && tx.to.toLowerCase() === managerLo)
    .map((tx) => tx.hash);
}

// ══════════════════════════════════════════════
//  Call tree enrichment
// ══════════════════════════════════════════════

async function enrichCallTree(node, provider, depth = 0, context = {}) {
  const reverted = !!context.reverted || !!node.error || Number(context.receipt?.status) === 0;
  const receiptLogs = context.receiptLogs ?? decodeReceiptLogs(context.receipt);
  node._receiptLogs = receiptLogs;
  const addr = node.to?.toLowerCase() || "";
  node._label = label(node.to);
  node._depth = depth;

  // Decode function name
  if (node.input && node.input.length >= 10) {
    const parsed = decodeFunctionCall(node.input);
    if (parsed) {
      node._funcName = parsed.name;
      node._args = parsed.args;
      node._parsed = parsed;
    } else {
      node._funcName = node.input.slice(0, 10); // raw selector
    }
  } else {
    node._funcName = node.type === "CREATE" || node.type === "CREATE2" ? "constructor" : "fallback";
  }

  // Decode return value
  if (node.output && node.output !== "0x" && node.input) {
    const result = decodeFunctionResult(node.input, node.output);
    if (result) {
      node._returnDecoded = formatResult(result);
    }
  }

  // Trace logs may have been reverted; only receipt logs establish commitment.
  node._decodedLogs = (node.logs || []).map(log => decodeEventLog(log, "trace", null, reverted));

  for (const child of node.calls || []) {
    await enrichCallTree(child, provider, depth + 1, { ...context, receiptLogs, reverted });
  }

  if (node._label === "CrossChainProxy" && provider) {
    const managerCall = (node.calls || []).find(child =>
      child._funcName === "executeCrossChainCall" || child._funcName === "staticCrossChainCall");
    if (managerCall) {
      const info = await resolveProxyTargetFromChain(
        node.to, provider, managerCall.to, context.receipt?.blockNumber);
      if (info) {
        node._proxyTargetAddr = info.originalAddress;
        node._proxyRollupId = info.originalRollupId;
      }
    }
  }

  // Identify cross-chain boundaries
  node._isCrossChainCall =
    node._funcName === "executeCrossChainCall" ||
    node._funcName === "executeIncomingCrossChainCall";
  node._isExecuteCrossChainCall = node._funcName === "executeCrossChainCall";
  node._isIncomingCrossChainCall = node._funcName === "executeIncomingCrossChainCall";
}

function formatResult(result) {
  if (!result) return "";
  const parts = [];
  for (let i = 0; i < result.length; i++) {
    const val = result[i];
    parts.push(formatValue(val));
  }
  return parts.length === 1 ? parts[0] : `(${parts.join(", ")})`;
}

function formatValue(val) {
  if (val === null || val === undefined) return "null";
  if (typeof val === "string") {
    if (val.startsWith("0x") && val.length > 42) return val.slice(0, 10) + "..." + val.slice(-8);
    return `"${val}"`;
  }
  if (typeof val === "bigint") return val.toString();
  if (Array.isArray(val)) return `[${val.map(formatValue).join(", ")}]`;
  return String(val);
}

function trimHex(hex) {
  if (!hex || hex.length <= 42) return hex;
  return hex.slice(0, 10) + "..." + hex.slice(-8);
}

// Try to decode the output of executeCrossChainCall (returns bytes = ABI-encoded proxy result).
// The proxy wraps the actual return value, so we try to unwrap it.
function tryDecodeProxyReturn(output) {
  if (!output || output === "0x") return null;
  try {
    // executeCrossChainCall returns (bytes result) — the result is what the proxy returned
    const outerDecoded = ethers.AbiCoder.defaultAbiCoder().decode(["bytes"], output);
    const innerBytes = outerDecoded[0];
    if (!innerBytes || innerBytes === "0x") return null;
    // Try to decode the inner bytes as common return types
    try {
      const s = ethers.AbiCoder.defaultAbiCoder().decode(["string"], innerBytes);
      return `"${s[0]}"`;
    } catch {}
    try {
      const n = ethers.AbiCoder.defaultAbiCoder().decode(["uint256"], innerBytes);
      return n[0].toString();
    } catch {}
    try {
      const b = ethers.AbiCoder.defaultAbiCoder().decode(["bool"], innerBytes);
      return b[0].toString();
    } catch {}
    return trimHex(innerBytes);
  } catch {
    return null;
  }
}

// ══════════════════════════════════════════════
//  Cross-chain matching
// ══════════════════════════════════════════════

// Only logs emitted in this call (including its delegatecall implementation).
function ownCallLogs(node) {
  return [ ...(node._decodedLogs || []), ...(node.calls || [])
    .filter(child => child.type === "DELEGATECALL").flatMap(ownCallLogs) ];
}

function committedOutgoingCalls(node, manager) {
  if (!manager) return [];
  return ownCallLogs(node).filter(log => {
    if (log.committed === false || log.name !== "CrossChainCallExecuted" ||
        log.address?.toLowerCase() !== manager.toLowerCase()) return false;
    const matches = (node._receiptLogs || []).filter(receiptLog =>
      receiptLog.address?.toLowerCase() === log.address.toLowerCase() &&
      receiptLog.data === log.data && JSON.stringify(receiptLog.topics) === JSON.stringify(log.topics));
    // Identical occurrences cannot be assigned to a frame from payload alone.
    return matches.length === 1;
  });
}

function collectAllLogs(node) {
  const logs = [...(node._decodedLogs || [])];
  for (const child of node.calls || []) {
    logs.push(...collectAllLogs(child));
  }
  return logs;
}

function collectAllAddresses(node) {
  const addrs = new Set();
  if (node.to) addrs.add(node.to);
  if (node.from) addrs.add(node.from);
  for (const child of node.calls || []) {
    for (const a of collectAllAddresses(child)) addrs.add(a);
  }
  return addrs;
}

// Find the actual user-contract call inside an L2 trace
// (skip executeIncomingCrossChainCall wrapper, scope navigation, proxy plumbing)
function findUserExecution(node) {
  const systemLabels = new Set(["EEZ", "EEZL2", "CrossChainProxy"]);
  const systemFuncs = new Set([
    "executeCrossChainCall",
    "executeIncomingCrossChainCall",
    "loadExecutionTable",
    "executeOnBehalf",
    "postAndVerifyBatch",
  ]);

  // DFS: find the deepest non-system call
  function dfs(n) {
    const lbl = labels.get(n.to?.toLowerCase());
    const isSystem = systemLabels.has(lbl) || systemFuncs.has(n._funcName);

    if (!isSystem && n._funcName && n._funcName !== "fallback") {
      return n;
    }

    for (const child of n.calls || []) {
      const found = dfs(child);
      if (found) return found;
    }
    return null;
  }

  return dfs(node);
}

// ══════════════════════════════════════════════
//  JSON serialization (for --json / --serve)
// ══════════════════════════════════════════════

function serializeCallNode(node, chain, l2Traces, opts = {}) {
  const serialized = {
    type: node.type || "CALL",
    from: node.from || "",
    to: node.to || "",
    value: node.value || "0",
    error: node.error || null,
    label: node._label || "",
    funcName: node._funcName || "",
    returnDecoded: node._returnDecoded || null,
    depth: node._depth || 0,
    isCrossChainCall: !!node._isExecuteCrossChainCall,
    isIncomingCrossChainCall: !!node._isIncomingCrossChainCall,
    proxyTargetLabel: null,
    proxyRollupId: node._proxyRollupId ?? null,
    inlinedL2: null,
    logs: (node._decodedLogs || []).filter(dl => dl.name).map(dl => serializeEvent(dl, chain)),
    calls: [],
  };

  // Proxy info
  if (node._label === "CrossChainProxy") {
    serialized.proxyTargetLabel = node._proxyTargetAddr ? label(node._proxyTargetAddr) : null;
    const innerFn = resolveInnerFunction(node);
    serialized.funcName = innerFn;
  }

  // Cross-chain inlining
  if (chain === "L1" && node._isExecuteCrossChainCall && l2Traces) {
    const ccEvents = committedOutgoingCalls(node, opts.rollups);
    for (const ccEvent of ccEvents) {
      const callHash = String(ccEvent.args.crossChainCallHash);
      const matchingL2 = findMatchingL2Trace(callHash, l2Traces, opts.managerL2);
      if (matchingL2) {
        const userCall = findUserExecution(matchingL2);
        const proxyInfo = findProxyInfo(matchingL2);
        serialized.inlinedL2 = {
          correlation: "hash-candidate",
          txHash: matchingL2._txHash || "",
          blockNumber: matchingL2._blockNumber || 0,
          userCall: userCall ? serializeCallNode(userCall, "L2", [], opts) : null,
          fullTrace: serializeCallNode(matchingL2, "L2", [], opts),
          proxyInfo: proxyInfo,
        };
        // Also include user call's children
        if (userCall) {
          serialized.inlinedL2.userCall.calls = (userCall.calls || []).map(
            child => serializeCallNode(child, "L2", [], opts)
          );
        }
      }
    }
  }

  // Local callbacks remain visible even when remote correlation is unavailable.
  serialized.calls = (node.calls || []).map(
    child => serializeCallNode(child, chain, l2Traces, opts)
  );

  return serialized;
}

function serializeEvent(dl, chain) {
  const params = [];
  if (dl.fragment && dl.args) {
    for (let i = 0; i < dl.fragment.inputs.length; i++) {
      const inp = dl.fragment.inputs[i];
      const val = dl.args[i];
      params.push({ name: inp.name, value: formatValue(val) });
    }
  }
  return {
    chain,
    name: dl.name || null,
    address: dl.address ?? null,
    transactionHash: dl.transactionHash,
    blockHash: dl.blockHash,
    blockNumber: dl.blockNumber,
    logIndex: dl.logIndex,
    provenance: dl.provenance,
    committed: dl.committed,
    topics: dl.topics,
    data: dl.data,
    params,
  };
}

function buildJsonResponse(l1Trace, l2Traces, l1Receipt, opts, l2Receipts = []) {
  const callTree = serializeCallNode(l1Trace, "L1", l2Traces, opts);

  // Collect all events
  const events = [];
  const l1Logs = decodeReceiptLogs(l1Receipt);
  for (const dl of l1Logs) {
    if (dl.name) events.push(serializeEvent(dl, "L1"));
  }
  for (const receipt of l2Receipts) {
    const l2Logs = decodeReceiptLogs(receipt);
    for (const dl of l2Logs) {
      if (dl.name) events.push(serializeEvent(dl, "L2"));
    }
  }

  return {
    txHash: l1Receipt.hash,
    chain: "L1",
    blockNumber: l1Receipt.blockNumber,
    status: l1Receipt.status === 1 ? "success" : "revert",
    from: l1Receipt.from,
    to: l1Receipt.to,
    callTree,
    l2Traces: l2Traces.map(trace => serializeCallNode(trace, "L2", [], opts)),
    events,
    blockContext: null, // filled by caller if needed
    systemContracts: {
      rollups: opts.rollups || null,
      managerL2: opts.managerL2 || null,
    },
  };
}

// ══════════════════════════════════════════════
//  Unified renderer
// ══════════════════════════════════════════════

function renderUnified(l1Trace, l2Traces, l1Receipt, l2Receipts, opts) {
  const lines = [];
  const eventLines = [];

  const l1Status = l1Trace.error ? c.red("✗") : c.green("✓");
  lines.push("");
  lines.push(c.bold(`┌─── Cross-Chain Execution ${l1Status} ────────────────────────────────`));
  lines.push("│");

  // Render the full call tree with proper indentation
  renderNode(l1Trace, "L1", l2Traces, lines, eventLines, opts, 0, true);

  // Events section
  lines.push("│");
  lines.push(`│ ${c.dim("Committed receipt events:")}`);

  const l1Logs = decodeReceiptLogs(l1Receipt);
  for (const dl of l1Logs) {
    if (dl.name) eventLines.push(`│   ${c.bold("L1")}  ${dl.address ?? "?"} ${formatEvent(dl)}`);
  }
  for (const receipt of l2Receipts) {
    const l2Logs = decodeReceiptLogs(receipt);
    for (const dl of l2Logs) {
      if (dl.name) eventLines.push(`│   ${c.bold("L2")}  ${dl.address ?? "?"} ${formatEvent(dl)}`);
    }
  }

  lines.push(...eventLines);
  lines.push("│");
  lines.push(c.bold("└────────────────────────────────────────────────────────────────"));
  console.log(lines.join("\n"));
}

/**
 * Render a call node with tree-style indentation.
 * @param {object} node - callTracer node
 * @param {string} chain - "L1" or "L2"
 * @param {object[]} l2Traces - all L2 trace roots (for cross-chain inlining)
 * @param {string[]} lines - output lines accumulator
 * @param {string[]} eventLines - event lines accumulator
 * @param {object} opts
 * @param {number} depth - current nesting depth (for indentation)
 * @param {boolean} isLast - whether this is the last child (└─ vs ├─)
 */
function renderNode(node, chain, l2Traces, lines, eventLines, opts, depth, isLast) {
  const children = node.calls || [];
  const chainTag = c.bold(chain);

  // Build tree prefix: "│   " for each ancestor that continues, "    " for last ancestors
  // We use depth-based simple indentation with tree chars
  const indent = depth === 0 ? "" : "│   ".repeat(depth - 1) + (isLast ? "└── " : "├── ");
  const contIndent = depth === 0 ? "" : "│   ".repeat(depth);

  // Format the call line
  const icon = node.error ? c.red("✗") : c.cyan("→");
  const funcDisplay = formatCallHeader(node, chain, opts);
  lines.push(`│ ${chainTag} ${indent}${icon} ${funcDisplay}`);

  // If this is executeCrossChainCall, inline the matching L2 trace
  if (chain === "L1" && node._isExecuteCrossChainCall) {
    const ccEvents = committedOutgoingCalls(node, opts.rollups);
    for (const ccEvent of ccEvents) {
      const callHash = String(ccEvent.args.crossChainCallHash);
      const matchingL2 = findMatchingL2Trace(callHash, l2Traces, opts.managerL2);
      if (matchingL2) {
        lines.push(`│      ${contIndent}${c.dim("════════════ L2 hash candidate ═══════════")}`);
        renderL2Inline(matchingL2, l2Traces, lines, eventLines, opts, depth + 1);
        lines.push(`│      ${contIndent}${c.dim("═════════════════════════════════════════")}`);
      }
    }
  }

  for (let i = 0; i < children.length; i++) {
    renderNode(children[i], chain, l2Traces, lines, eventLines, opts, depth + 1, i === children.length - 1);
  }

  // Return value (only at the call site, not for internal system calls)
  if (depth > 0 && !node.error) {
    // For executeCrossChainCall, decode the proxy-wrapped return
    if (node._isExecuteCrossChainCall) {
      const decoded = tryDecodeProxyReturn(node.output);
      if (decoded) {
        lines.push(`│ ${chainTag} ${contIndent}${c.green("← " + decoded)}`);
      }
    } else if (node._returnDecoded) {
      lines.push(`│ ${chainTag} ${contIndent}${c.green("← " + node._returnDecoded)}`);
    }
  }
}

/**
 * Render L2 execution inline (inside L1 cross-chain boundary).
 * Shows only the user contract call, skipping system plumbing.
 */
function renderL2Inline(l2Root, l2Traces, lines, eventLines, opts, depth) {
  const contIndent = "│   ".repeat(depth);
  const l2Tag = c.bold("L2");

  // Find the actual user execution
  const userCall = findUserExecution(l2Root);
  const proxyInfo = findProxyInfo(l2Root);

  if (userCall) {
    const funcDisplay = c.bold(userCall._label + "::" + userCall._funcName + "()");
    const via = proxyInfo ? c.dim(proxyInfo + " → ") : "";
    lines.push(`│ ${l2Tag} ${contIndent}${c.cyan("→")} ${via}${funcDisplay}`);

    // Show user call's children (if the user contract makes sub-calls)
    const userChildren = userCall.calls || [];
    for (let i = 0; i < userChildren.length; i++) {
      renderNode(userChildren[i], "L2", l2Traces, lines, eventLines, opts, depth + 1, i === userChildren.length - 1);
    }

    // Return
    if (userCall._returnDecoded && !userCall.error) {
      lines.push(`│ ${l2Tag} ${contIndent}${c.green("└← " + userCall._returnDecoded)}`);
    } else if (userCall.error) {
      lines.push(`│ ${l2Tag} ${contIndent}${c.red("✗ REVERT: " + userCall.error)}`);
    }
  } else {
    lines.push(`│ ${l2Tag} ${contIndent}${c.dim("(no user execution found)")}`);
  }
}

/**
 * Format the header for a call node.
 * Proxy calls show: proxy[Target@rollupN]::function()
 * Regular calls show: ContractName::function()
 */
function formatCallHeader(node, chain, opts) {
  const lbl = node._label;
  const fn = node._funcName || "?";

  // CrossChainProxy: show proxy[Target@rollupN]::function()
  if (lbl === "CrossChainProxy") {
    const innerFn = resolveInnerFunction(node);
    const target = node._proxyTargetAddr ? label(node._proxyTargetAddr) : "?";
    const rid = node._proxyRollupId ?? "?";
    return c.dim(`proxy[${target}@rollup${rid}]`) + "::" + c.bold(innerFn + "()");
  }

  return c.bold(lbl + "::" + fn + "()");
}

function findMatchingL2Trace(callHash, l2Traces, manager) {
  if (!manager) return null;
  const matches = [];
  for (const trace of l2Traces) {
    for (const log of trace._receiptLogs || []) {
      if (log.name === "IncomingCrossChainCallExecuted" &&
          log.address?.toLowerCase() === manager.toLowerCase() &&
          String(log.args.crossChainCallHash) === callHash) matches.push(trace);
    }
  }
  // An outgoing L2 request is not incoming delivery; repeated hashes are ambiguous.
  return matches.length === 1 ? matches[0] : null;
}

function findProxyInfo(l2Trace) {
  const incoming = (l2Trace._receiptLogs || []).filter(log =>
    log.name === "IncomingCrossChainCallExecuted" &&
    log.address?.toLowerCase() === l2Trace._managerAddress?.toLowerCase());
  if (incoming.length !== 1) return null;
  return `proxy[${label(incoming[0].args.sourceAddress)}@rollup${incoming[0].args.sourceRollup}]`;
}

function resolveInnerFunction(proxyCall) {
  // The proxy's input is the function being called cross-chain
  if (proxyCall.input && proxyCall.input.length >= 10) {
    const parsed = decodeFunctionCall(proxyCall.input);
    if (parsed) return parsed.name;
    return proxyCall.input.slice(0, 10);
  }
  return "fallback";
}

function formatEvent(dl) {
  if (!dl.name) return c.dim("(unknown event)");
  const params = [];
  if (dl.fragment && dl.args) {
    for (let i = 0; i < dl.fragment.inputs.length; i++) {
      const inp = dl.fragment.inputs[i];
      const val = dl.args[i];
      let formatted = formatValue(val);
      if (formatted.length > 50) formatted = formatted.slice(0, 47) + "...";
      params.push(`${inp.name}: ${formatted}`);
    }
  }
  const paramStr = params.length > 0 ? `(${params.join(", ")})` : "";
  // Trim if too long
  const full = `${dl.name}${paramStr}`;
  return full.length > 100 ? full.slice(0, 97) + "..." : full;
}

// ══════════════════════════════════════════════
//  Reusable trace function
// ══════════════════════════════════════════════

async function traceTransaction(txHash, l1, l2, opts, { silent = false } = {}) {
  const log = silent ? () => {} : (msg) => console.log(msg);

  // Detect chain
  log(c.dim("Detecting chain..."));
  const chain = await detectChain(txHash, l1, l2);
  if (!chain) throw new Error("tx not found on L1 or L2");
  log(`Chain: ${c.bold(chain)}`);

  if (chain === "L1") {
    log(c.dim("Tracing L1 tx..."));
    const l1Trace = await getCallTrace(l1, txHash);
    const l1Receipt = await l1.getTransactionReceipt(txHash);
    const l1Block = l1Receipt.blockNumber;

    await enrichCallTree(l1Trace, null);
    log(c.dim("Discovering contracts..."));
    await discoverLabels(l1Trace, opts);
    discoverSystemContracts(l1Trace, opts, "L1");
    refreshSystemLabels(opts);
    if (opts.rollups) log(c.dim(`Rollups: ${label(opts.rollups)} (${opts.rollups})`));
    await enrichCallTree(l1Trace, l1, 0, { receipt: l1Receipt });

    log(c.dim("Finding L2 blocks..."));
    const { l2Blocks, batchTxs } = await findL2BlocksFromL1(l1Block, opts, l1);
    log(c.dim(`L2 blocks: [${l2Blocks.join(", ")}]`));

    const l2Traces = [];
    const l2Receipts = [];
    for (const block of l2Blocks) {
      const txs = opts.managerL2 ? await findL2ManagerTxs(block, opts, l2) : [];
      for (const l2TxHash of txs) {
        try {
          log(c.dim(`Tracing L2 tx ${l2TxHash.slice(0, 10)}...`));
          const trace = await getCallTrace(l2, l2TxHash);
          trace._txHash = l2TxHash;
          await enrichCallTree(trace, null);
          await discoverLabels(trace, opts);
          discoverSystemContracts(trace, opts, "L2");
          refreshSystemLabels(opts);
          const receipt = await l2.getTransactionReceipt(l2TxHash);
          await enrichCallTree(trace, l2, 0, { receipt });
          trace._blockNumber = receipt.blockNumber;
          trace._managerAddress = opts.managerL2;
          l2Traces.push(trace);
          l2Receipts.push(receipt);
        } catch (e) {
          log(c.dim(`  Failed to trace ${l2TxHash.slice(0, 10)}: ${e.message}`));
        }
      }
    }

    return { chain, l1Trace, l2Traces, l1Receipt, l2Receipts, l2Blocks, batchTxs, opts };
  } else {
    log(c.dim("Tracing L2 tx..."));
    const l2Trace = await getCallTrace(l2, txHash);
    l2Trace._txHash = txHash;
    await enrichCallTree(l2Trace, null);
    await discoverLabels(l2Trace, opts);
    discoverSystemContracts(l2Trace, opts, "L2");
    refreshSystemLabels(opts);
    const l2Receipt = await l2.getTransactionReceipt(txHash);
    await enrichCallTree(l2Trace, l2, 0, { receipt: l2Receipt });
    l2Trace._blockNumber = l2Receipt.blockNumber;
    l2Trace._managerAddress = opts.managerL2;

    return { chain, l2Trace, l2Receipt, opts };
  }
}

function bigintReplacer(_key, value) {
  return typeof value === "bigint" ? value.toString() : value;
}

// ══════════════════════════════════════════════
//  Main
// ══════════════════════════════════════════════

async function main() {
  const opts = parseArgs();

  const l1 = new ethers.JsonRpcProvider(opts.l1Rpc);
  const l2 = new ethers.JsonRpcProvider(opts.l2Rpc);

  // Load ABIs
  const outDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../out");
  if (!opts.json) console.log(c.dim("Loading ABIs from " + outDir + "..."));
  loadLocalABIs(outDir);
  if (!opts.json) console.log(c.dim(`Loaded ${selectorToIface.size} selectors, ${topicToIface.size} event topics`));
  buildLabels(opts);

  const result = await traceTransaction(opts.tx, l1, l2, opts, { silent: opts.json });

  if (result.chain === "L1") {
    if (opts.json) {
      const response = buildJsonResponse(result.l1Trace, result.l2Traces, result.l1Receipt, result.opts, result.l2Receipts);
      response.blockContext = {
        l1Block: result.l1Receipt.blockNumber,
        l2Blocks: result.l2Blocks,
        batchTxHash: result.batchTxs.length === 1 ? result.batchTxs[0] : null,
        batchTxHashes: result.batchTxs,
      };
      console.log(JSON.stringify(response, bigintReplacer, 2));
    } else {
      renderUnified(result.l1Trace, result.l2Traces, result.l1Receipt, result.l2Receipts, result.opts);
    }
  } else {
    if (opts.json) {
      const callTree = serializeCallNode(result.l2Trace, "L2", [], opts);
      const events = decodeReceiptLogs(result.l2Receipt).filter(dl => dl.name).map(dl => serializeEvent(dl, "L2"));
      const response = {
        txHash: opts.tx,
        chain: "L2",
        blockNumber: result.l2Receipt.blockNumber,
        status: result.l2Receipt.status === 1 ? "success" : "revert",
        from: result.l2Receipt.from,
        to: result.l2Receipt.to,
        callTree,
        events,
        blockContext: null,
        systemContracts: { rollups: opts.rollups || null, managerL2: opts.managerL2 || null },
      };
      console.log(JSON.stringify(response, bigintReplacer, 2));
    } else {
      console.log("");
      console.log(c.bold("L2 Trace:"));
      printCallTree(result.l2Trace, 0);
    }
  }
}

function printCallTree(node, depth) {
  const indent = "  ".repeat(depth);
  const icon = node.error ? c.red("✗") : c.green("✓");
  const fn = node._funcName || "?";
  const ret = node._returnDecoded ? ` → ${node._returnDecoded}` : "";
  console.log(`${indent}${icon} ${node._label}::${fn}()${ret}`);
  for (const child of node.calls || []) {
    printCallTree(child, depth + 1);
  }
}

export {
  BATCH_POSTED_TOPIC, loadLocalABIs, decodeFunctionCall, decodeEventLog, decodeReceiptLogs,
  extractL2BlocksFromTx, findL2BlocksFromL1, findBatchBlockByL2Ref, enrichCallTree,
  serializeCallNode, serializeEvent, buildJsonResponse, findMatchingL2Trace,
  resolveProxyTargetFromChain, detectChain, discoverSystemContracts, traceTransaction,
};

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((e) => {
    console.error(c.red("Fatal: " + e.message));
    process.exitCode = 1;
  });
}
