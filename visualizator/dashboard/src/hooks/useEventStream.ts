import { useCallback } from "react";
import { useStore } from "../store";
import { rollupsAbi } from "../abi/rollups";
import { crossChainManagerL2Abi } from "../abi/crossChainManagerL2";
import { useChainWatcher } from "./useChainWatcher";
import { processEventForTables, extractRollupState } from "../lib/eventProcessor";
import { discoverFromEvent } from "../lib/autoDiscovery";
import type { EventRecord } from "../types/events";
import { truncateHex } from "../lib/actionFormatter";

export function useEventStream() {
  const l1RpcUrl = useStore((s) => s.l1RpcUrl);
  const l2RpcUrl = useStore((s) => s.l2RpcUrl);
  const l1ContractAddress = useStore((s) => s.l1ContractAddress);
  const l2ContractAddress = useStore((s) => s.l2ContractAddress);
  const connected = useStore((s) => s.connected);

  const addEvent = useStore((s) => s.addEvent);
  const addL1Entries = useStore((s) => s.addL1Entries);
  const addL2Entries = useStore((s) => s.addL2Entries);
  const consumeL1Entry = useStore((s) => s.consumeL1Entry);
  const consumeL2Entry = useStore((s) => s.consumeL2Entry);
  const addNodes = useStore((s) => s.addNodes);
  const addEdges = useStore((s) => s.addEdges);
  const addKnownAddresses = useStore((s) => s.addKnownAddresses);
  const updateContractState = useStore((s) => s.updateContractState);

  const handleEvent = useCallback(
    (event: EventRecord) => {
      addEvent(event);

      // Process table mutations
      const tableMutations = processEventForTables(event);
      if (tableMutations.l1Adds.length > 0) addL1Entries(tableMutations.l1Adds);
      if (tableMutations.l2Adds.length > 0) addL2Entries(tableMutations.l2Adds);
      for (const info of tableMutations.l1Consumes) consumeL1Entry(truncateHex(info.crossChainCallHash), info.actionDetail);
      for (const info of tableMutations.l2Consumes) consumeL2Entry(truncateHex(info.crossChainCallHash), info.actionDetail);

      // Process architecture discovery
      const store = useStore.getState();
      const existingNodeIds = new Set([
        ...store.l1Nodes.map((n) => n.id),
        ...store.l2Nodes.map((n) => n.id),
      ]);
      const discovery = discoverFromEvent(
        event,
        store.knownAddresses,
        existingNodeIds,
        l1ContractAddress,
        l2ContractAddress,
      );
      if (discovery.newNodes.length > 0) addNodes(discovery.newNodes);
      if (discovery.newEdges.length > 0) addEdges(discovery.newEdges);
      if (discovery.addressInfos.length > 0)
        addKnownAddresses(discovery.addressInfos);

      // Process rollup state
      const rootUpdates = extractRollupState(event);
      for (const { key, value } of rootUpdates) {
        updateContractState(key, value);
      }

      // Set active nodes/edges for this event
      const activeNodes: string[] = [];
      const activeEdges: string[] = [];
      if (event.args.proxy) {
        activeNodes.push((event.args.proxy as string).toLowerCase());
      }
      if (event.args.sourceAddress) {
        activeNodes.push((event.args.sourceAddress as string).toLowerCase());
      }
      // No more IncomingCrossChainCallExecuted event with destination field
      const managerAddr =
        event.chain === "l1"
          ? l1ContractAddress.toLowerCase()
          : l2ContractAddress.toLowerCase();
      if (managerAddr) activeNodes.push(managerAddr);

      if (activeNodes.length > 0) {
        store.setActiveNodes(activeNodes);
        // Build edges between active nodes
        for (let i = 0; i < activeNodes.length - 1; i++) {
          activeEdges.push(`${activeNodes[i]}->${activeNodes[i + 1]}`);
        }
        store.setActiveEdges(activeEdges);
      }
    },
    [
      addEvent,
      addL1Entries,
      addL2Entries,
      consumeL1Entry,
      consumeL2Entry,
      addNodes,
      addEdges,
      addKnownAddresses,
      updateContractState,
      l1ContractAddress,
      l2ContractAddress,
    ],
  );

  useChainWatcher({
    rpcUrl: l1RpcUrl,
    contractAddress: l1ContractAddress as `0x${string}`,
    abi: rollupsAbi,
    chain: "l1",
    onEvent: handleEvent,
    enabled: connected && !!l1ContractAddress,
  });

  useChainWatcher({
    rpcUrl: l2RpcUrl,
    contractAddress: l2ContractAddress as `0x${string}`,
    abi: crossChainManagerL2Abi,
    chain: "l2",
    onEvent: handleEvent,
    enabled: connected && !!l2ContractAddress,
  });
}
