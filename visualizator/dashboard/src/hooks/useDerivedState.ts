import { useMemo } from "react";
import { useStore } from "../store";
import type { TableEntry } from "../types/visualization";
import { processEventForTables, extractRollupState } from "../lib/eventProcessor";
import { truncateHex } from "../lib/actionFormatter";
import type { EventRecord } from "../types/events";

/**
 * Compute active nodes and edges for a given event.
 */
function computeActiveForEvent(
  event: EventRecord,
  l1Manager: string,
  l2Manager: string,
): { activeNodes: string[]; activeEdges: string[] } {
  const activeNodes: string[] = [];
  const activeEdges: string[] = [];
  const args = event.args;

  const managerAddr =
    event.chain === "l1"
      ? l1Manager.toLowerCase()
      : l2Manager.toLowerCase();

  switch (event.eventName) {
    case "BatchPosted":
      if (managerAddr) activeNodes.push(managerAddr);
      activeNodes.push("__prover__");
      activeEdges.push(`__prover__->${managerAddr}`);
      break;

    case "ExecutionTableLoaded":
      if (managerAddr) activeNodes.push(managerAddr);
      activeNodes.push("__system__");
      activeEdges.push(`__system__->${managerAddr}`);
      break;

    case "CrossChainCallExecuted": {
      const proxy = (args.proxy as string)?.toLowerCase();
      const src = (args.sourceAddress as string)?.toLowerCase();
      if (src) activeNodes.push(src);
      if (proxy) activeNodes.push(proxy);
      if (managerAddr) activeNodes.push(managerAddr);
      if (src && proxy) activeEdges.push(`${src}->${proxy}`);
      if (proxy && managerAddr) activeEdges.push(`${proxy}->${managerAddr}`);
      break;
    }

    case "CrossChainProxyCreated": {
      const proxy = (args.proxy as string)?.toLowerCase();
      if (proxy) activeNodes.push(proxy);
      if (managerAddr) activeNodes.push(managerAddr);
      if (proxy && managerAddr) activeEdges.push(`${proxy}->${managerAddr}`);
      break;
    }

    case "ExecutionConsumed":
    case "RollupCreated":
    case "RollupContractChanged":
      if (managerAddr) activeNodes.push(managerAddr);
      break;

    default:
      if (managerAddr) activeNodes.push(managerAddr);
      break;
  }

  return { activeNodes, activeEdges };
}

/**
 * Computes state up to the selected event (for replay).
 * If selectedEventId is null, returns current live state.
 */
export function useDerivedState() {
  const events = useStore((s) => s.events);
  const selectedEventId = useStore((s) => s.selectedEventId);
  const l1Table = useStore((s) => s.l1Table);
  const l2Table = useStore((s) => s.l2Table);
  const contractState = useStore((s) => s.contractState);
  const storeActiveNodes = useStore((s) => s.activeNodes);
  const storeActiveEdges = useStore((s) => s.activeEdges);
  const l1ContractAddress = useStore((s) => s.l1ContractAddress);
  const l2ContractAddress = useStore((s) => s.l2ContractAddress);

  return useMemo(() => {
    // Live mode — use store state directly
    if (selectedEventId === null) {
      return {
        l1Table,
        l2Table,
        contractState,
        eventsUpTo: events,
        activeNodes: storeActiveNodes,
        activeEdges: storeActiveEdges,
      };
    }

    // Replay mode — recompute from events
    const selectedIdx = events.findIndex((e) => e.id === selectedEventId);
    if (selectedIdx === -1) {
      return {
        l1Table,
        l2Table,
        contractState,
        eventsUpTo: events,
        activeNodes: storeActiveNodes,
        activeEdges: storeActiveEdges,
      };
    }

    const eventsUpTo = events.slice(0, selectedIdx + 1);
    const replayL1: TableEntry[] = [];
    const replayL2: TableEntry[] = [];
    const replayState: Record<string, string> = {};

    for (let i = 0; i <= selectedIdx; i++) {
      const event = events[i];
      const isCurrent = i === selectedIdx;
      const mutations = processEventForTables(event);

      // Age existing "ja" entries to "ok"
      for (const e of replayL1) {
        if (e.status === "ja") e.status = "ok";
      }
      for (const e of replayL2) {
        if (e.status === "ja") e.status = "ok";
      }

      // Add new entries
      for (const te of mutations.l1Adds) {
        replayL1.push({ ...te, status: isCurrent ? "ja" : "ok" });
      }
      for (const te of mutations.l2Adds) {
        replayL2.push({ ...te, status: isCurrent ? "ja" : "ok" });
      }

      // Consume entries
      for (const info of mutations.l1Consumes) {
        const truncated = truncateHex(info.crossChainCallHash);
        const entry = replayL1.find((e) => e.crossChainCallHash === truncated);
        if (entry) {
          entry.status = isCurrent ? "jc" : "consumed";
          if (info.actionDetail && Object.keys(info.actionDetail).length > 0) {
            entry.actionDetail = info.actionDetail;
          }
        }
      }
      for (const info of mutations.l2Consumes) {
        const truncated = truncateHex(info.crossChainCallHash);
        const entry = replayL2.find((e) => e.crossChainCallHash === truncated);
        if (entry) {
          entry.status = isCurrent ? "jc" : "consumed";
          if (info.actionDetail && Object.keys(info.actionDetail).length > 0) {
            entry.actionDetail = info.actionDetail;
          }
        }
      }

      // State updates
      const rootUpdates = extractRollupState(event);
      for (const { key, value } of rootUpdates) {
        replayState[key] = value;
      }
    }

    // Compute active nodes/edges for the selected event
    const selectedEvent = events[selectedIdx];
    const { activeNodes, activeEdges } = computeActiveForEvent(
      selectedEvent,
      l1ContractAddress,
      l2ContractAddress,
    );

    return {
      l1Table: replayL1,
      l2Table: replayL2,
      contractState: replayState,
      eventsUpTo,
      activeNodes: new Set(activeNodes),
      activeEdges: new Set(activeEdges),
    };
  }, [
    events,
    selectedEventId,
    l1Table,
    l2Table,
    contractState,
    storeActiveNodes,
    storeActiveEdges,
    l1ContractAddress,
    l2ContractAddress,
  ]);
}
