import type { EventRecord } from "../types/events";
import type { DiagramItem } from "../types/visualization";
import { truncateAddress } from "./actionFormatter";

const KNOWN_SELECTORS: Record<string, string> = {
  "0xd09de08a": "increment()",
  "0x06661abd": "counter()",
  "0x1c71ef55": "incrementProxy()",
};

export type CallFlowNode = {
  address: string;
  label: string;
  chain: "l1" | "l2";
  type: "user" | "contract" | "proxy" | "system";
};

export type CallFlowStep = {
  from: CallFlowNode;
  to: CallFlowNode;
  label: string;
  isReturn: boolean;
};

/**
 * Build a call flow diagram from a bundle's events.
 * Uses CrossChainCallExecuted and CallResult events to trace the flow.
 */
export function buildCallFlow(
  events: EventRecord[],
  knownAddresses: Map<string, { label: string; type: string; chain: string }>,
): DiagramItem[] {
  const items: DiagramItem[] = [];

  // Extract call flow from CrossChainCallExecuted events
  for (const event of events) {
    if (event.eventName !== "CrossChainCallExecuted") continue;

    const src = event.args.sourceAddress as string;
    const proxy = event.args.proxy as string;
    const callData = event.args.callData as string;
    const chain = event.chain;

    const srcInfo = resolveAddress(src, knownAddresses);
    const proxyInfo = resolveAddress(proxy, knownAddresses);

    if (items.length === 0) {
      items.push({
        kind: "node",
        label: srcInfo.label,
        sub: srcInfo.type,
        type: srcInfo.type,
        chain: srcInfo.chain || chain,
      });
    }

    // Arrow with function call
    const selector = callData && callData.length >= 10 ? callData.slice(0, 10) : callData ?? "";
    const fnName = KNOWN_SELECTORS[selector.toLowerCase()] ?? selector;
    items.push({ kind: "arrow", label: fnName });

    // Proxy node
    items.push({
      kind: "node",
      label: proxyInfo.label,
      sub: proxyInfo.type,
      type: proxyInfo.type,
      chain,
    });

    // Arrow to manager
    items.push({ kind: "arrow", label: "execCC" });

    // Manager node
    const mgrLabel = chain === "l1" ? "Rollups" : "ManagerL2";
    items.push({
      kind: "node",
      label: mgrLabel,
      sub: "system",
      type: "system",
      chain,
    });
  }

  return items;
}

function resolveAddress(
  addr: string,
  known: Map<string, { label: string; type: string; chain: string }>,
): { label: string; type: string; chain: string } {
  const info = known.get(addr.toLowerCase());
  if (info) return info;
  return {
    label: truncateAddress(addr),
    type: "contract",
    chain: "l1",
  };
}

/**
 * Build a step-by-step description list from bundle events.
 */
export type BundleStep = {
  eventId: string;
  chain: "l1" | "l2";
  title: string;
  detail: string;
  eventName: string;
  txHash: string;
};

export function buildBundleSteps(events: EventRecord[]): BundleStep[] {
  return events.map((event) => ({
    eventId: event.id,
    chain: event.chain,
    title: stepTitle(event),
    detail: stepDetail(event),
    eventName: event.eventName,
    txHash: event.transactionHash,
  }));
}

function stepTitle(event: EventRecord): string {
  switch (event.eventName) {
    case "BatchPosted":
      return `Post batch (${String(event.args.rollupCount ?? 0)} rollups)`;
    case "ExecutionTableLoaded": {
      const entries = event.args.entries as unknown[] | undefined;
      return `Load execution table (${entries?.length ?? 0} entries)`;
    }
    case "ExecutionConsumed":
      return "Entry consumed";
    case "CrossChainCallExecuted":
      return "Cross-chain call executed";
    case "L2TXExecuted":
      return "L2TX executed";
    case "CrossChainProxyCreated":
      return "Proxy created";
    case "RollupContractChanged":
      return "Rollup contract changed";
    case "ImmediateEntrySkipped":
      return "Immediate entry skipped";
    case "CallResult":
      return "Call result";
    case "NestedActionConsumed":
      return "Nested action consumed";
    case "EntryExecuted":
      return "Entry executed";
    case "RevertSpanExecuted":
      return "Revert span executed";
    default:
      return event.eventName;
  }
}

function stepDetail(event: EventRecord): string {
  switch (event.eventName) {
    case "ExecutionConsumed":
      return `crossChainCallHash: ${(event.args.crossChainCallHash as string)?.slice(0, 18)}... rollupId: ${String(event.args.rollupId ?? "")} cursor: ${String(event.args.cursor ?? "")}`;
    case "CrossChainCallExecuted":
      return `proxy=${truncateAddress(event.args.proxy as string)} src=${truncateAddress(event.args.sourceAddress as string)}`;
    case "L2TXExecuted":
      return `rollupId=${String(event.args.rollupId ?? "")} cursor=${String(event.args.cursor ?? "")}`;
    case "CallResult":
      return `call#${String(event.args.callNumber ?? "")} success=${String(event.args.success ?? "")}`;
    case "NestedActionConsumed":
      return `nested#${String(event.args.nestedNumber ?? "")} callCount=${String(event.args.callCount ?? "")}`;
    case "EntryExecuted":
      return `calls=${String(event.args.callsProcessed ?? "")} nested=${String(event.args.nestedActionsConsumed ?? "")}`;
    case "RevertSpanExecuted":
      return `startCall=${String(event.args.startCallNumber ?? "")} span=${String(event.args.span ?? "")}`;
    case "ImmediateEntrySkipped":
      return `transientIdx=${String(event.args.transientIdx ?? "")}`;
    case "BatchPosted":
      return `rollupCount=${String(event.args.rollupCount ?? "")}`;
    case "RollupContractChanged":
      return `rollupId=${String(event.args.rollupId ?? "")} new=${truncateAddress(event.args.newContract as string)}`;
    default:
      return `block ${event.blockNumber.toString()}, tx ${event.transactionHash.slice(0, 10)}...`;
  }
}
