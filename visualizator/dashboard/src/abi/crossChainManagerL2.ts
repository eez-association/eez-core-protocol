const crossChainCallTuple = {
  type: "tuple" as const,
  components: [
    { name: "targetAddress", type: "address" },
    { name: "value", type: "uint256" },
    { name: "data", type: "bytes" },
    { name: "sourceAddress", type: "address" },
    { name: "sourceRollupId", type: "uint256" },
    { name: "revertSpan", type: "uint256" },
  ],
} as const;

const nestedActionTuple = {
  type: "tuple" as const,
  components: [
    { name: "crossChainCallHash", type: "bytes32" },
    { name: "callCount", type: "uint256" },
    { name: "returnData", type: "bytes" },
  ],
} as const;

const stateDeltaTuple = {
  type: "tuple" as const,
  components: [
    { name: "rollupId", type: "uint256" },
    { name: "currentRoot", type: "bytes32" },
    { name: "newRoot", type: "bytes32" },
    { name: "etherDelta", type: "int256" },
  ],
} as const;

const executionEntryTuple = {
  name: "entries",
  type: "tuple[]" as const,
  components: [
    { name: "stateDeltas", type: "tuple[]", components: stateDeltaTuple.components },
    { name: "crossChainCallHash", type: "bytes32" },
    { name: "destinationRollupId", type: "uint256" },
    { name: "calls", type: "tuple[]", components: crossChainCallTuple.components },
    { name: "nestedActions", type: "tuple[]", components: nestedActionTuple.components },
    { name: "callCount", type: "uint256" },
    { name: "returnData", type: "bytes" },
    { name: "rollingHash", type: "bytes32" },
  ],
} as const;

export const crossChainManagerL2Abi = [
  {
    type: "event",
    name: "CrossChainProxyCreated",
    inputs: [
      { name: "proxy", type: "address", indexed: true },
      { name: "originalAddress", type: "address", indexed: true },
      { name: "originalRollupId", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "ExecutionTableLoaded",
    inputs: [
      { ...executionEntryTuple, indexed: false },
    ],
  },
  {
    type: "event",
    name: "ExecutionConsumed",
    inputs: [
      { name: "crossChainCallHash", type: "bytes32", indexed: true },
      { name: "entryIndex", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "CrossChainCallExecuted",
    inputs: [
      { name: "crossChainCallHash", type: "bytes32", indexed: true },
      { name: "proxy", type: "address", indexed: true },
      { name: "sourceAddress", type: "address", indexed: false },
      { name: "callData", type: "bytes", indexed: false },
      { name: "value", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "CallResult",
    inputs: [
      { name: "entryIndex", type: "uint256", indexed: true },
      { name: "callNumber", type: "uint256", indexed: true },
      { name: "success", type: "bool", indexed: false },
      { name: "returnData", type: "bytes", indexed: false },
    ],
  },
  {
    type: "event",
    name: "NestedActionConsumed",
    inputs: [
      { name: "entryIndex", type: "uint256", indexed: true },
      { name: "nestedNumber", type: "uint256", indexed: true },
      { name: "crossChainCallHash", type: "bytes32", indexed: false },
      { name: "callCount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "EntryExecuted",
    inputs: [
      { name: "entryIndex", type: "uint256", indexed: true },
      { name: "rollingHash", type: "bytes32", indexed: false },
      { name: "callsProcessed", type: "uint256", indexed: false },
      { name: "nestedActionsConsumed", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "RevertSpanExecuted",
    inputs: [
      { name: "entryIndex", type: "uint256", indexed: true },
      { name: "startCallNumber", type: "uint256", indexed: false },
      { name: "span", type: "uint256", indexed: false },
    ],
  },
] as const;
