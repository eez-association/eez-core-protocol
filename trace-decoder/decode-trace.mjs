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
// ─── PORTING STATUS (feature/multi-prover-flatten) ────────────────────
// This decoder was authored against main's pre-flatten data model.
// Surface renames have been applied (Rollups → EEZ, ManagerL2 → EEZL2,
// postBatch → postAndVerifyBatch). The deep walker logic still assumes
// the old shape and WILL NOT produce correct cross-chain joins on this
// branch:
//   - L1↔L2 matching uses `actionHash`; our model emits `proxyEntryHash`
//     / `crossChainCallHash` via different events.
//   - `ActionType` enum decoding (CALL/RESULT/L2TX/REVERT/REVERT_CONTINUE)
//     has no analogue here — we use flat CrossChainCall[] + NestedAction[]
//     with a rolling-hash accumulator.
//   - `postBatch(entries, blobCount, callData, proof)` calldata parser
//     no longer matches `postAndVerifyBatch(ProofSystemBatchPerVerificationEntries)`.
// Treat this file as a starting point for a flatten-aware decoder, not
// a working tool. The shell wrapper `script/e2e/shared/decode-trace.sh`
// covers most debug needs in the meantime via `cast run --la`.
// ───────────────────────────────────────────────────────────────────────

import { ethers } from "ethers";
import fs from "fs";
import path from "path";

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
    l1Explorer: "https://l1.eez.dev",
    l2Explorer: "https://l2.eez.dev",
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
function discoverSystemContracts(trace, opts) {
  function walk(node) {
    if (node._funcName === "executeCrossChainCall" && node.to) {
      // The contract receiving executeCrossChainCall is Rollups (L1) or ManagerL2 (L2)
      if (!opts.rollups) opts.rollups = node.to;
      else if (node.to.toLowerCase() !== opts.rollups.toLowerCase() && !opts.managerL2) {
        opts.managerL2 = node.to;
      }
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

// Cache for proxy target info: proxyAddr → { originalAddress, originalRollupId }
const proxyTargetCache = new Map();
const PROXY_IFACE = new ethers.Interface([
  "function originalAddress() view returns (address)",
  "function originalRollupId() view returns (uint64)",
]);

async function resolveProxyTargetFromChain(proxyAddr, provider) {
  const lo = proxyAddr.toLowerCase();
  if (proxyTargetCache.has(lo)) return proxyTargetCache.get(lo);
  try {
    const [addrResult, ridResult] = await Promise.all([
      provider.call({ to: proxyAddr, data: PROXY_IFACE.encodeFunctionData("originalAddress") }),
      provider.call({ to: proxyAddr, data: PROXY_IFACE.encodeFunctionData("originalRollupId") }),
    ]);
    const originalAddress = PROXY_IFACE.decodeFunctionResult("originalAddress", addrResult)[0];
    const originalRollupId = Number(PROXY_IFACE.decodeFunctionResult("originalRollupId", ridResult)[0]);
    const info = { originalAddress, originalRollupId };
    proxyTargetCache.set(lo, info);
    return info;
  } catch {
    proxyTargetCache.set(lo, null);
    return null;
  }
}

async function detectChain(txHash, l1, l2) {
  try {
    await l1.getTransaction(txHash);
    return "L1";
  } catch {}
  try {
    await l2.getTransaction(txHash);
    return "L2";
  } catch {}
  return null;
}

// ══════════════════════════════════════════════
//  Cross-chain block correlation
//  (ported from E2EBase.sh / decode-trace.sh)
// ══════════════════════════════════════════════

// BatchPosted event topic (precomputed)
const BATCH_POSTED_TOPIC = "0x2f482312f12dceb86aac9ef0e0e1d9421ac62910326b3d50695d63117321b520";
const L2_CONTEXT = "0x5FbDB2315678afecb367f032d93F642f64180aa3";

// Extract L2 block numbers from a postBatch tx's callData.
// postBatch 3rd arg is bytes callData = abi.encode(uint256[] blockNumbers, bytes[] blockData)
async function extractL2BlocksFromTx(txHash, provider) {
  try {
    const tx = await provider.getTransaction(txHash);
    if (!tx) return [];
    const parsed = decodeFunctionCall(tx.data);
    if (!parsed || parsed.name !== "postAndVerifyBatch") return [];
    const callDataBytes = parsed.args[2]; // 3rd param: bytes callData
    if (!callDataBytes || callDataBytes === "0x") return [];
    const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
      ["uint256[]", "bytes[]"],
      callDataBytes
    );
    return decoded[0].map((n) => Number(n));
  } catch {
    return [];
  }
}

// L1 → L2: find L2 blocks from an L1 block (look for BatchPosted logs)
async function findL2BlocksFromL1(l1Block, opts, l1) {
  const logs = await l1.getLogs({
    fromBlock: l1Block,
    toBlock: l1Block,
    address: opts.rollups,
    topics: [BATCH_POSTED_TOPIC],
  });

  if (logs.length === 0) return { l2Blocks: [], batchTx: null };
  const batchTx = logs[0].transactionHash;
  const l2Blocks = await extractL2BlocksFromTx(batchTx, l1);
  return { l2Blocks, batchTx };
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
  const logs = await l1.getLogs({
    fromBlock: l1From,
    toBlock: l1To,
    address: opts.rollups,
    topics: [BATCH_POSTED_TOPIC],
  });

  // Deduplicate by tx hash
  const seen = new Set();
  for (const log of logs) {
    if (seen.has(log.transactionHash)) continue;
    seen.add(log.transactionHash);
    const l2Blocks = await extractL2BlocksFromTx(log.transactionHash, l1);
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

async function enrichCallTree(node, provider, depth = 0) {
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

  // Decode logs
  node._decodedLogs = (node.logs || []).map((log) => {
    const parsed = decodeLog(log);
    return parsed ? { name: parsed.name, args: parsed.args, fragment: parsed.fragment } : { raw: log };
  });

  // If this is a CrossChainProxy, resolve its target from ExecutionConsumed event in children
  // The consumed action has destination (L2 target) and rollupId
  if (node._label === "CrossChainProxy") {
    for (const child of node.calls || []) {
      const childLogs = collectAllLogs(child);
      const consumed = childLogs.find((l) => l.name === "ExecutionConsumed");
      if (consumed) {
        const action = consumed.args?.action ?? consumed.args?.[1];
        if (action) {
          node._proxyTargetAddr = action[2]; // destination
          node._proxyRollupId = Number(action[1]); // rollupId
        }
        break;
      }
    }
  }

  // Recurse
  for (const child of node.calls || []) {
    await enrichCallTree(child, provider, depth + 1);
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

// ActionType enum: 0=CALL, 1=RESULT, 2=L2TX, 3=REVERT, 4=REVERT_CONTINUE
const ACTION_TYPES = ["CALL", "RESULT", "L2TX", "REVERT", "REVERT_CONTINUE"];

// Format an Action struct from ExecutionConsumed event into a short summary
// action = [actionType, rollupId, destination, value, data, failed, sourceAddress, sourceRollup, scope]
function formatActionSummary(action, prefix) {
  const actionType = ACTION_TYPES[Number(action[0])] || `type(${action[0]})`;
  const rollupId = Number(action[1]);
  const destination = action[2];
  const value = BigInt(action[3]);
  const data = action[4];
  const failed = action[5];
  const sourceAddress = action[6];
  const sourceRollup = Number(action[7]);

  if (actionType === "CALL") {
    const destLabel = label(destination);
    const selector = data?.length >= 10 ? data.slice(0, 10) : "?";
    const parsed = data?.length >= 10 ? decodeFunctionCall(data) : null;
    const fnName = parsed ? parsed.name : selector;
    const srcLabel = label(sourceAddress);
    const valStr = value > 0n ? ` {value: ${value}}` : "";
    return `${prefix}: CALL ${destLabel}.${fnName}()${valStr} from ${srcLabel}@rollup${sourceRollup} → rollup${rollupId}`;
  }

  if (actionType === "RESULT") {
    const status = failed ? "FAILED" : "ok";
    // Try to decode the return data
    let retStr = "";
    if (data && data !== "0x" && data.length > 2) {
      try {
        // Result data is ABI-encoded return value — try common types
        const decoded = ethers.AbiCoder.defaultAbiCoder().decode(["string"], data);
        retStr = ` → "${decoded[0]}"`;
      } catch {
        try {
          const decoded = ethers.AbiCoder.defaultAbiCoder().decode(["uint256"], data);
          retStr = ` → ${decoded[0]}`;
        } catch {
          retStr = data.length > 10 ? ` → ${trimHex(data)}` : "";
        }
      }
    }
    return `${prefix}: RESULT ${status}${retStr}`;
  }

  if (actionType === "L2TX") {
    return `${prefix}: L2TX rollup${rollupId}`;
  }

  if (actionType === "REVERT" || actionType === "REVERT_CONTINUE") {
    return `${prefix}: ${actionType}${failed ? " (failed)" : ""}`;
  }

  return `${prefix}: ${actionType}`;
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

function extractActionHashes(decodedLogs, eventName) {
  const hashes = [];
  for (const dl of decodedLogs) {
    if (dl.name === eventName && dl.args) {
      hashes.push(dl.args.actionHash || dl.args[0]);
    }
  }
  return hashes;
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
    "newScope",
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

function serializeCallNode(node, chain, l2Traces) {
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
  if (node._isExecuteCrossChainCall && l2Traces) {
    const allLogs = collectAllLogs(node);
    const ccEvents = allLogs.filter(l => l.name === "CrossChainCallExecuted");
    for (const ccEvent of ccEvents) {
      const actionHash = String(ccEvent.args?.actionHash ?? ccEvent.args?.[0]);
      const matchingL2 = findMatchingL2Trace(actionHash, l2Traces);
      if (matchingL2) {
        const userCall = findUserExecution(matchingL2);
        const proxyInfo = findProxyInfo(matchingL2);
        serialized.inlinedL2 = {
          txHash: matchingL2._txHash || "",
          blockNumber: matchingL2._blockNumber || 0,
          userCall: userCall ? serializeCallNode(userCall, "L2", l2Traces) : null,
          fullTrace: serializeCallNode(matchingL2, "L2", []),
          proxyInfo: proxyInfo,
        };
        // Also include user call's children
        if (userCall) {
          serialized.inlinedL2.userCall.calls = (userCall.calls || []).map(
            child => serializeCallNode(child, "L2", l2Traces)
          );
        }
      }
    }
  }

  // Recurse children (skip for executeCrossChainCall — handled via inlinedL2)
  if (!node._isExecuteCrossChainCall) {
    serialized.calls = (node.calls || []).map(
      child => serializeCallNode(child, chain, l2Traces)
    );
  }

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
    address: dl.address || "",
    params,
  };
}

function buildJsonResponse(l1Trace, l2Traces, l1Receipt, opts) {
  const callTree = serializeCallNode(l1Trace, "L1", l2Traces);

  // Collect all events
  const events = [];
  const l1Logs = collectAllLogs(l1Trace);
  for (const dl of l1Logs) {
    if (dl.name) events.push(serializeEvent(dl, "L1"));
  }
  for (const l2t of l2Traces) {
    const l2Logs = collectAllLogs(l2t);
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
  lines.push(`│ ${c.dim("Events:")}`);

  const l1Logs = collectAllLogs(l1Trace);
  for (const dl of l1Logs) {
    if (dl.name) eventLines.push(`│   ${c.bold("L1")}  ${formatEvent(dl)}`);
  }
  for (const l2t of l2Traces) {
    const l2Logs = collectAllLogs(l2t);
    for (const dl of l2Logs) {
      if (dl.name) eventLines.push(`│   ${c.bold("L2")}  ${formatEvent(dl)}`);
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
  if (node._isExecuteCrossChainCall) {
    const allLogs = collectAllLogs(node);
    const ccEvents = allLogs.filter((l) => l.name === "CrossChainCallExecuted");
    for (const ccEvent of ccEvents) {
      const actionHash = String(ccEvent.args?.actionHash ?? ccEvent.args?.[0]);
      const matchingL2 = findMatchingL2Trace(actionHash, l2Traces);
      if (matchingL2) {
        lines.push(`│      ${contIndent}${c.dim("═══════════════════ L2 ═══════════════════")}`);
        renderL2Inline(matchingL2, l2Traces, lines, eventLines, opts, depth + 1);
        lines.push(`│      ${contIndent}${c.dim("═════════════════════════════════════════")}`);
      }
    }
  }

  // Recurse into children (skip executeCrossChainCall children — already handled above)
  if (!node._isExecuteCrossChainCall) {
    for (let i = 0; i < children.length; i++) {
      const child = children[i];
      const childIsLast = i === children.length - 1;
      renderNode(child, chain, l2Traces, lines, eventLines, opts, depth + 1, childIsLast);
    }
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

function findMatchingL2Trace(actionHash, l2Traces) {
  for (const l2t of l2Traces) {
    const l2Logs = collectAllLogs(l2t);
    const incoming = l2Logs.find(
      (l) =>
        l.name === "IncomingCrossChainCallExecuted" &&
        String(l.args?.actionHash ?? l.args?.[0]) === actionHash
    );
    if (incoming) return l2t;

    // Also check CrossChainCallExecuted (for L2-side calls)
    const ccall = l2Logs.find(
      (l) =>
        l.name === "CrossChainCallExecuted" &&
        String(l.args?.actionHash ?? l.args?.[0]) === actionHash
    );
    if (ccall) return l2t;
  }
  return null;
}

function findProxyInfo(l2Trace) {
  const logs = collectAllLogs(l2Trace);
  const incoming = logs.find((l) => l.name === "IncomingCrossChainCallExecuted");
  if (incoming) {
    const source = incoming.args?.sourceAddress ?? incoming.args?.[4];
    const sourceRollup = incoming.args?.sourceRollup ?? incoming.args?.[5];
    if (source) {
      return `proxy[${label(source)}@rollup${sourceRollup ?? "?"}]`;
    }
  }
  return null;
}

function resolveProxyTarget(proxyCall, opts) {
  // A CrossChainProxy forwards to executeCrossChainCall
  // The proxy's originalAddress tells us what L2 contract it represents
  // We can get this from CrossChainProxyCreated events or from the proxy's call target
  for (const child of proxyCall.calls || []) {
    if (child._funcName === "executeCrossChainCall" && child._parsed?.args) {
      // 1st arg is sourceAddress, but the proxy target is the address it represents
      // For now, return the proxy label
      return proxyCall._label;
    }
  }
  return null;
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
    discoverSystemContracts(l1Trace, opts);
    refreshSystemLabels(opts);
    if (opts.rollups) log(c.dim(`Rollups: ${label(opts.rollups)} (${opts.rollups})`));
    await enrichCallTree(l1Trace, l1);

    log(c.dim("Finding L2 blocks..."));
    const { l2Blocks } = opts.rollups
      ? await findL2BlocksFromL1(l1Block, opts, l1)
      : { l2Blocks: [] };
    log(c.dim(`L2 blocks: [${l2Blocks.join(", ")}]`));

    if (!opts.managerL2 && opts.rollups) opts.managerL2 = opts.rollups;
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
          discoverSystemContracts(trace, opts);
          refreshSystemLabels(opts);
          await enrichCallTree(trace, l2);
          l2Traces.push(trace);
          const receipt = await l2.getTransactionReceipt(l2TxHash);
          l2Receipts.push(receipt);
        } catch (e) {
          log(c.dim(`  Failed to trace ${l2TxHash.slice(0, 10)}: ${e.message}`));
        }
      }
    }

    return { chain, l1Trace, l2Traces, l1Receipt, l2Receipts, l2Blocks, opts };
  } else {
    log(c.dim("Tracing L2 tx..."));
    const l2Trace = await getCallTrace(l2, txHash);
    l2Trace._txHash = txHash;
    await enrichCallTree(l2Trace, null);
    await discoverLabels(l2Trace, opts);
    discoverSystemContracts(l2Trace, opts);
    refreshSystemLabels(opts);
    await enrichCallTree(l2Trace, l2);
    const l2Receipt = await l2.getTransactionReceipt(txHash);

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
  const outDir = path.resolve(process.cwd(), "out");
  console.log(c.dim("Loading ABIs from " + outDir + "..."));
  loadLocalABIs(outDir);
  console.log(c.dim(`Loaded ${selectorToIface.size} selectors, ${topicToIface.size} event topics`));
  buildLabels(opts);

  const result = await traceTransaction(opts.tx, l1, l2, opts);

  if (result.chain === "L1") {
    if (opts.json) {
      const response = buildJsonResponse(result.l1Trace, result.l2Traces, result.l1Receipt, result.opts);
      response.blockContext = {
        l1Block: result.l1Receipt.blockNumber,
        l2Blocks: result.l2Blocks,
        batchTxHash: result.l1Receipt.hash,
      };
      console.log(JSON.stringify(response, bigintReplacer, 2));
    } else {
      renderUnified(result.l1Trace, result.l2Traces, result.l1Receipt, result.l2Receipts, result.opts);
    }
  } else {
    if (opts.json) {
      const callTree = serializeCallNode(result.l2Trace, "L2", []);
      const events = collectAllLogs(result.l2Trace).filter(dl => dl.name).map(dl => serializeEvent(dl, "L2"));
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

main().catch((e) => {
  console.error(c.red("Fatal: " + e.message));
  process.exit(1);
});
