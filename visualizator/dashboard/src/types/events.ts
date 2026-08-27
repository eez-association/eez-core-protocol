import type { Chain } from "./visualization";
import type { ExecutionEntry } from "./chain";

export type EventName =
  | "RollupCreated"
  | "RollupContractChanged"
  | "CrossChainProxyCreated"
  | "ExecutionConsumed"
  | "CrossChainCallExecuted"
  | "L2TXExecuted"
  | "BatchPosted"
  | "ImmediateEntrySkipped"
  | "ExecutionTableLoaded"
  | "CallResult"
  | "NestedActionConsumed"
  | "EntryExecuted"
  | "RevertSpanExecuted";

export type EventRecord = {
  id: string;
  chain: Chain;
  eventName: EventName;
  blockNumber: bigint;
  logIndex: number;
  transactionHash: `0x${string}`;
  args: Record<string, unknown>;
  timestamp?: number;
};

export type DecodedLog = {
  eventName: string;
  args: Record<string, unknown>;
  address: `0x${string}`;
  logIndex: number;
};

export type TxMetadata = {
  hash: `0x${string}`;
  blockNumber: bigint;
  from: `0x${string}`;
  to: `0x${string}` | null;
  gasUsed: bigint;
  logs: DecodedLog[];
};

// Parsed event payloads for typed access

// Post-refactor: BatchPosted is just a count. Entries no longer ride the event;
// they must be decoded from the postBatch tx input or reconstructed from
// EntryExecuted / ExecutionConsumed / CallResult / NestedActionConsumed.
export type BatchPostedArgs = {
  subBatchCount: bigint;
};

export type ExecutionTableLoadedArgs = {
  entries: ExecutionEntry[];
};

export type ExecutionConsumedArgs = {
  crossChainCallHash: `0x${string}`;
  rollupId: bigint;
  cursor: bigint;
};

export type CrossChainProxyCreatedArgs = {
  proxy: `0x${string}`;
  originalAddress: `0x${string}`;
  originalRollupId: bigint;
};

export type CrossChainCallExecutedArgs = {
  crossChainCallHash: `0x${string}`;
  proxy: `0x${string}`;
  sourceAddress: `0x${string}`;
  callData: `0x${string}`;
  value: bigint;
};

export type CallResultArgs = {
  entryIndex: bigint;
  callNumber: bigint;
  success: boolean;
  returnData: `0x${string}`;
};

export type NestedActionConsumedArgs = {
  entryIndex: bigint;
  nestedNumber: bigint;
  crossChainCallHash: `0x${string}`;
  callCount: bigint;
};

export type EntryExecutedArgs = {
  entryIndex: bigint;
  rollingHash: `0x${string}`;
  callsProcessed: bigint;
  nestedActionsConsumed: bigint;
};

export type RollupCreatedArgs = {
  rollupId: bigint;
  rollupContract: `0x${string}`;
  initialRoot: `0x${string}`;
};

export type RollupContractChangedArgs = {
  rollupId: bigint;
  previousContract: `0x${string}`;
  newContract: `0x${string}`;
};

export type ImmediateEntrySkippedArgs = {
  transientIdx: bigint;
  revertData: `0x${string}`;
};

export type L2TXExecutedArgs = {
  rollupId: bigint;
  cursor: bigint;
};
