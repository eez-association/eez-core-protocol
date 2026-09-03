import type { EventRecord } from "../types/events";
import type { ArchNode, ArchEdge, Chain, NodeType, TableEntry } from "../types/visualization";
import type { AddressInfo } from "./autoDiscovery";
import { truncateAddress } from "./actionFormatter";
import { processEventForTables } from "./eventProcessor";

/**
 * Per-step highlight data — which nodes and edges glow at each step.
 */
export type StepHighlight = {
  activeNodes: string[];
  activeEdges: string[];
  description: string;
};

/**
 * Per-step table snapshot — execution table state at each step.
 */
export type StepTableState = {
  l1: (TableEntry & { stepStatus: "ja" | "ok" | "jc" | "consumed" })[];
  l2: (TableEntry & { stepStatus: "ja" | "ok" | "jc" | "consumed" })[];
};

/**
 * Per-step contract state — tracked values.
 */
export type StepContractState = {
  entries: { key: string; value: string; changed: boolean }[];
};

export type BundleArchitecture = {
  l1Nodes: ArchNode[];
  l2Nodes: ArchNode[];
  edges: ArchEdge[];
  stepHighlights: StepHighlight[];
  tableStates: StepTableState[];
  contractStates: StepContractState[];
  mergedEvents: EventRecord[];
};

/**
 * Chain-prefixed node ID to disambiguate same address on different chains.
 * e.g. "l1:0xe7f1..." vs "l2:0xe7f1..." are distinct nodes.
 */
function nid(chain: Chain, addr: string): string {
  if (addr.startsWith("__")) return addr; // ghost nodes don't need prefix
  return `${chain}:${addr.toLowerCase()}`;
}

/**
 * Build an architecture diagram scoped to a bundle's events.
 *
 * Strategy:
 * 1. Collect all addresses mentioned in events (source, destination, proxy, manager)
 * 2. Use knownAddresses to label them and determine chain/type
 * 3. Build edges from the call relationships (using chain-prefixed IDs)
 * 4. For each event (step), determine which nodes/edges should glow
 * 5. Compute per-step execution table snapshots and contract state
 */
export function buildBundleArchitecture(
  bundleEvents: EventRecord[],
  knownAddresses: Map<string, AddressInfo>,
  l1ManagerAddress: string,
  l2ManagerAddress: string,
  allEvents?: EventRecord[],
): BundleArchitecture {
  // Build proxy map from all CrossChainProxyCreated events (for proxy label derivation)
  const proxyMap = new Map<string, { originalAddress: string; originalRollupId: bigint }>();
  for (const event of (allEvents ?? bundleEvents)) {
    if (event.eventName === "CrossChainProxyCreated") {
      const proxy = (event.args.proxy as string).toLowerCase();
      proxyMap.set(`${event.chain}:${proxy}`, {
        originalAddress: (event.args.originalAddress as string).toLowerCase(),
        originalRollupId: event.args.originalRollupId as bigint,
      });
    }
  }

  // Node registry: chain-prefixed ID -> info
  const addrSet = new Map<string, { chain: Chain; type: NodeType; label: string; rawAddr: string }>();

  /**
   * Look up label for an address on a specific chain.
   * Only uses known label if it's on the SAME chain (avoids cross-chain collision).
   */
  function labelFor(addr: string, chain: Chain, hint?: string): string {
    const id = addr.toLowerCase();
    const known = knownAddresses.get(id);
    if (known && known.chain === chain) return known.label;
    return hint ?? truncateAddress(addr);
  }

  function addAddr(addr: string, chain: Chain, type: NodeType, labelHint?: string) {
    const id = nid(chain, addr);
    const raw = addr.toLowerCase();
    if (raw === "0x0000000000000000000000000000000000000000") return;
    if (addrSet.has(id)) return;

    // Check if this is a known proxy (from CrossChainProxyCreated events)
    const pInfo = proxyMap.get(`${chain}:${raw}`);
    if (pInfo && !labelHint) {
      type = "proxy";
      const origChain: Chain = chain === "l1" ? "l2" : "l1";
      const origLabel = labelFor(pInfo.originalAddress, origChain);
      labelHint = `${origLabel}'`;
    }

    const known = knownAddresses.get(raw);
    // Only use known info if chain matches
    const resolvedType = (known?.chain === chain ? known?.type : null) ?? type;
    const label = labelHint ?? labelFor(addr, chain);
    addrSet.set(id, { chain, type: resolvedType, label, rawAddr: raw });
  }

  // Always include the managers
  addAddr(l1ManagerAddress, "l1", "system", "Rollups");
  addAddr(l2ManagerAddress, "l2", "system", "ManagerL2");

  // Collect all edges as we scan events
  const edgeMap = new Map<string, ArchEdge>();

  function addEdge(fromId: string, toId: string, label: string, opts?: { back?: boolean; alt?: boolean }) {
    const id = opts?.back ? `${toId}->${fromId}-back` : `${fromId}->${toId}`;
    if (edgeMap.has(id)) return;
    edgeMap.set(id, { from: fromId, to: toId, label, id, back: opts?.back, alt: opts?.alt });
  }

  const l1MgrId = nid("l1", l1ManagerAddress);
  const l2MgrId = nid("l2", l2ManagerAddress);

  // Reorder events: setup (BatchPosted, ExecutionTableLoaded) first, then actions
  const EVENT_PRIORITY: Record<string, number> = {
    BatchPosted: 0, ExecutionTableLoaded: 1, CrossChainProxyCreated: 2,
    RollupContractChanged: 3, ExecutionConsumed: 4, CrossChainCallExecuted: 5,
    L2TXExecuted: 5, ImmediateEntrySkipped: 5, CallResult: 6, NestedActionConsumed: 6,
    EntryExecuted: 7, RevertSpanExecuted: 6,
  };
  const orderedEvents = [...bundleEvents].sort((a, b) => {
    const pa = EVENT_PRIORITY[a.eventName] ?? 3;
    const pb = EVENT_PRIORITY[b.eventName] ?? 3;
    if (pa !== pb) return pa - pb;
    if (a.blockNumber !== b.blockNumber) return a.blockNumber < b.blockNumber ? -1 : 1;
    return a.logIndex - b.logIndex;
  });

  // Scan events to discover addresses and edges
  for (const event of orderedEvents) {
    switch (event.eventName) {
      case "BatchPosted": {
        addAddr("__prover__", "l1", "ghost", "Prover");
        addEdge("__prover__", l1MgrId, "postBatch");
        break;
      }
      case "ExecutionTableLoaded": {
        addAddr("__system__", "l2", "ghost", "SYSTEM");
        addEdge("__system__", l2MgrId, "loadTable");
        break;
      }
      case "CrossChainCallExecuted": {
        const src = event.args.sourceAddress as string;
        const proxy = event.args.proxy as string;
        const ch = event.chain;
        addAddr(src, ch, "contract");
        addAddr(proxy, ch, "proxy");
        const srcId = nid(ch, src);
        const proxyId = nid(ch, proxy);
        const mgrId = ch === "l1" ? l1MgrId : l2MgrId;
        addEdge(srcId, proxyId, "call");
        addEdge(proxyId, mgrId, "execCC");
        // Return arrows
        addEdge(mgrId, proxyId, "result", { back: true });
        addEdge(proxyId, srcId, "return", { back: true });
        break;
      }
      case "CrossChainProxyCreated": {
        const proxy = event.args.proxy as string;
        const orig = event.args.originalAddress as string;
        const ch = event.chain;
        // The original lives on the OPPOSITE chain
        const origChain: Chain = ch === "l1" ? "l2" : "l1";

        // Ensure the original is registered on its own chain
        addAddr(orig, origChain, "contract");

        // Get the original's label from its own chain context
        const origId = nid(origChain, orig);
        const origInfo = addrSet.get(origId);
        const proxyLabel = origInfo ? `${origInfo.label}'` : truncateAddress(proxy);

        addAddr(proxy, ch, "proxy", proxyLabel);
        const mgrId = ch === "l1" ? l1MgrId : l2MgrId;
        addEdge(nid(ch, proxy), mgrId, "proxy");
        break;
      }
      case "L2TXExecuted": {
        addEdge(l1MgrId, l1MgrId, "L2TX");
        break;
      }
    }
  }

  // Build nodes, assign columns per chain
  const l1Nodes: ArchNode[] = [];
  const l2Nodes: ArchNode[] = [];
  let l1Col = 0, l2Col = 0;

  // Sort: system first, then contracts, then proxies, then ghosts
  const typeOrder: Record<string, number> = { system: 0, contract: 1, user: 1, proxy: 2, ghost: 3 };
  const sorted = [...addrSet.entries()].sort((a, b) => {
    if (a[1].chain !== b[1].chain) return a[1].chain === "l1" ? -1 : 1;
    return (typeOrder[a[1].type] ?? 4) - (typeOrder[b[1].type] ?? 4);
  });

  for (const [id, info] of sorted) {
    const sub = id.startsWith("__")
      ? (id === "__prover__" ? "ZK batch poster" : "sysAddr")
      : truncateAddress(info.rawAddr);
    const node: ArchNode = {
      id,
      label: info.label,
      sub,
      type: info.type,
      col: info.chain === "l1" ? l1Col++ : l2Col++,
    };
    if (info.chain === "l1") l1Nodes.push(node);
    else l2Nodes.push(node);
  }

  // Build per-step highlights
  const stepHighlights: StepHighlight[] = [];

  for (const event of orderedEvents) {
    const nodes: string[] = [];
    const edges: string[] = [];
    let desc: string = event.eventName;

    switch (event.eventName) {
      case "BatchPosted": {
        nodes.push("__prover__", l1MgrId);
        edges.push(`__prover__->${l1MgrId}`);
        desc = "Prover posts batch to Rollups";
        break;
      }
      case "ExecutionTableLoaded": {
        nodes.push("__system__", l2MgrId);
        edges.push(`__system__->${l2MgrId}`);
        desc = "SYSTEM loads execution table on L2";
        break;
      }
      case "CrossChainCallExecuted": {
        const ch = event.chain;
        const srcId = nid(ch, (event.args.sourceAddress as string));
        const proxyId = nid(ch, (event.args.proxy as string));
        const mgrId = ch === "l1" ? l1MgrId : l2MgrId;
        nodes.push(srcId, proxyId, mgrId);
        // Forward: caller -> proxy -> manager
        edges.push(`${srcId}->${proxyId}`, `${proxyId}->${mgrId}`);
        // Return: manager -> proxy -> caller (back edge IDs use to->from-back)
        edges.push(`${proxyId}->${mgrId}-back`, `${srcId}->${proxyId}-back`);
        const srcLabel = addrSet.get(srcId)?.label ?? "caller";
        const proxyLabel = addrSet.get(proxyId)?.label ?? "proxy";
        desc = `${srcLabel} calls ${proxyLabel}`;
        break;
      }
      case "ExecutionConsumed": {
        const ch = event.chain;
        const mgrId = ch === "l1" ? l1MgrId : l2MgrId;
        nodes.push(mgrId);
        const cursor = event.args.cursor ?? event.args.entryIndex ?? "";
        desc = `Entry consumed on ${ch.toUpperCase()} (cursor ${String(cursor)})`;
        break;
      }
      case "CrossChainProxyCreated": {
        const ch = event.chain;
        const proxyId = nid(ch, (event.args.proxy as string));
        const mgrId = ch === "l1" ? l1MgrId : l2MgrId;
        nodes.push(proxyId, mgrId);
        edges.push(`${proxyId}->${mgrId}`);
        const proxyLabel = addrSet.get(proxyId)?.label ?? "proxy";
        desc = `Proxy created: ${proxyLabel}`;
        break;
      }
      case "CallResult": {
        const ch = event.chain;
        const mgrId = ch === "l1" ? l1MgrId : l2MgrId;
        nodes.push(mgrId);
        const success = event.args.success ? "success" : "failed";
        desc = `Call #${String(event.args.callNumber ?? "")} ${success}`;
        break;
      }
      case "EntryExecuted": {
        const ch = event.chain;
        const mgrId = ch === "l1" ? l1MgrId : l2MgrId;
        nodes.push(mgrId);
        desc = `Entry executed (${String(event.args.callsProcessed ?? 0)} calls, ${String(event.args.nestedActionsConsumed ?? 0)} nested)`;
        break;
      }
      default:
        break;
    }

    stepHighlights.push({ activeNodes: nodes, activeEdges: edges, description: desc });
  }

  // ---- Compute per-step execution table states ----
  const tableStates = computeTableStates(orderedEvents);

  // ---- Compute per-step contract state ----
  const contractStates = computeContractStates(orderedEvents);

  // ---- Merge ExecutionConsumed steps into parent call steps (same txHash) ----
  const MERGE_TARGETS = new Set(["CrossChainCallExecuted", "L2TXExecuted"]);
  const mergeInto = new Array<number>(orderedEvents.length).fill(-1);

  for (let i = 0; i < orderedEvents.length; i++) {
    if (orderedEvents[i].eventName !== "ExecutionConsumed") continue;
    const tx = orderedEvents[i].transactionHash;
    // Look forward first (parent call event is emitted after consumed)
    for (let j = i + 1; j < orderedEvents.length; j++) {
      if (orderedEvents[j].transactionHash === tx && MERGE_TARGETS.has(orderedEvents[j].eventName)) {
        mergeInto[i] = j;
        break;
      }
    }
    if (mergeInto[i] === -1) {
      for (let j = i - 1; j >= 0; j--) {
        if (orderedEvents[j].transactionHash === tx && MERGE_TARGETS.has(orderedEvents[j].eventName)) {
          mergeInto[i] = j;
          break;
        }
      }
    }
  }

  // Apply merges
  for (let i = 0; i < bundleEvents.length; i++) {
    if (i >= mergeInto.length) continue;
    const target = mergeInto[i];
    if (target === -1) continue;
    // Merge highlights (union of active nodes/edges)
    const th = stepHighlights[target];
    const ch = stepHighlights[i];
    th.activeNodes = [...new Set([...th.activeNodes, ...ch.activeNodes])];
    th.activeEdges = [...new Set([...th.activeEdges, ...ch.activeEdges])];
    // Use consumed event's table state if it has jc markings (shows what was consumed)
    if (tableStates[i].l1.some(e => e.stepStatus === "jc") || tableStates[i].l2.some(e => e.stepStatus === "jc")) {
      tableStates[target] = tableStates[i];
    }
    // Merge contract state
    if (contractStates[i].entries.some(e => e.changed) && !contractStates[target].entries.some(e => e.changed)) {
      contractStates[target] = contractStates[i];
    }
  }

  const keep = mergeInto.map(t => t === -1);
  const mergedEvents = orderedEvents.filter((_, i) => keep[i]);
  const mergedHighlights = stepHighlights.filter((_, i) => keep[i]);
  const mergedTables = tableStates.filter((_, i) => keep[i]);
  const mergedContracts = contractStates.filter((_, i) => keep[i]);

  return {
    l1Nodes,
    l2Nodes,
    edges: [...edgeMap.values()],
    stepHighlights: mergedHighlights,
    tableStates: mergedTables,
    contractStates: mergedContracts,
    mergedEvents,
  };
}

/**
 * Find a proxy address for originalAddress on a given chain using the proxy map.
 */
function findProxyForOriginal(
  originalAddress: string,
  proxyChain: Chain,
  pMap: Map<string, { originalAddress: string }>,
): string | null {
  const origLower = originalAddress.toLowerCase();
  for (const [key, info] of pMap) {
    if (key.startsWith(`${proxyChain}:`) && info.originalAddress === origLower) {
      return key.slice(proxyChain.length + 1);
    }
  }
  return null;
}

/**
 * Compute per-step execution table snapshots for a bundle.
 */
function computeTableStates(events: EventRecord[]): StepTableState[] {
  const l1Entries: (TableEntry & { stepStatus: "ja" | "ok" | "jc" | "consumed" })[] = [];
  const l2Entries: (TableEntry & { stepStatus: "ja" | "ok" | "jc" | "consumed" })[] = [];
  const states: StepTableState[] = [];

  for (const event of events) {
    // Reset "ja" to "ok" from previous step
    for (const e of l1Entries) if (e.stepStatus === "ja") e.stepStatus = "ok";
    for (const e of l2Entries) if (e.stepStatus === "ja") e.stepStatus = "ok";
    // Remove "consumed" entries from previous step
    const l1Active = l1Entries.filter(e => e.stepStatus !== "consumed");
    const l2Active = l2Entries.filter(e => e.stepStatus !== "consumed");
    l1Entries.length = 0;
    l1Entries.push(...l1Active);
    l2Entries.length = 0;
    l2Entries.push(...l2Active);

    const result = processEventForTables(event);

    // Add new entries
    for (const te of result.l1Adds) {
      l1Entries.push({ ...te, stepStatus: "ja" });
    }
    for (const te of result.l2Adds) {
      l2Entries.push({ ...te, stepStatus: "ja" });
    }

    // Mark consumed entries
    for (const info of result.l1Consumes) {
      const entry = l1Entries.find(e => e.fullCrossChainCallHash === info.crossChainCallHash && e.stepStatus !== "consumed");
      if (entry) {
        entry.stepStatus = "jc";
        if (info.actionDetail && Object.keys(info.actionDetail).length > 0) {
          entry.actionDetail = info.actionDetail;
        }
      }
    }
    for (const info of result.l2Consumes) {
      const entry = l2Entries.find(e => e.fullCrossChainCallHash === info.crossChainCallHash && e.stepStatus !== "consumed");
      if (entry) {
        entry.stepStatus = "jc";
        if (info.actionDetail && Object.keys(info.actionDetail).length > 0) {
          entry.actionDetail = info.actionDetail;
        }
      }
    }

    // Snapshot
    states.push({
      l1: l1Entries.map(e => ({ ...e })),
      l2: l2Entries.map(e => ({ ...e })),
    });

    // After snapshot, move "jc" to "consumed" for next step
    for (const e of l1Entries) if (e.stepStatus === "jc") e.stepStatus = "consumed";
    for (const e of l2Entries) if (e.stepStatus === "jc") e.stepStatus = "consumed";
  }

  return states;
}

/**
 * Compute per-step contract state from events.
 */
function computeContractStates(events: EventRecord[]): StepContractState[] {
  const stateMap = new Map<string, string>();
  const states: StepContractState[] = [];

  for (const event of events) {
    const changedKeys = new Set<string>();

    switch (event.eventName) {
      case "RollupCreated": {
        const rid = String(event.args.rollupId);
        const k1 = `Rollup ${rid} state`;
        const k2 = `Rollup ${rid} contract`;
        stateMap.set(k1, truncateHash(event.args.initialRoot as string));
        stateMap.set(k2, truncateAddress(event.args.rollupContract as string));
        changedKeys.add(k1);
        changedKeys.add(k2);
        break;
      }
      case "RollupContractChanged": {
        const rid = String(event.args.rollupId);
        const k = `Rollup ${rid} contract`;
        stateMap.set(k, truncateAddress(event.args.newContract as string));
        changedKeys.add(k);
        break;
      }
      case "BatchPosted": {
        // TODO(user-decision): post-refactor BatchPosted no longer carries entries;
        // state-delta visibility for the batch must be reconstructed from tx input or
        // an alternative event stream.
        break;
      }
    }

    const entries = [...stateMap.entries()].map(([key, value]) => ({
      key,
      value,
      changed: changedKeys.has(key),
    }));
    states.push({ entries });
  }

  return states;
}

function truncateHash(h: string): string {
  if (!h || h.length < 12) return h;
  return `${h.slice(0, 10)}...`;
}
