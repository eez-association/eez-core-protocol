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

const lookupCallTuple = {
  type: "tuple" as const,
  components: [
    { name: "crossChainCallHash", type: "bytes32" },
    { name: "destinationRollupId", type: "uint256" },
    { name: "returnData", type: "bytes" },
    { name: "failed", type: "bool" },
    { name: "callNumber", type: "uint64" },
    { name: "lastNestedActionConsumed", type: "uint64" },
    { name: "calls", type: "tuple[]", components: crossChainCallTuple.components },
    { name: "rollingHash", type: "bytes32" },
  ],
} as const;

const proofSystemBatchTuple = {
  type: "tuple[]" as const,
  components: [
    { name: "proofSystems", type: "address[]" },
    { name: "rollupIds", type: "uint256[]" },
    { name: "entries", type: "tuple[]", components: executionEntryTuple.components },
    { name: "lookupCalls", type: "tuple[]", components: lookupCallTuple.components },
    { name: "transientCount", type: "uint256" },
    { name: "transientLookupCallCount", type: "uint256" },
    { name: "blobIndices", type: "uint256[]" },
    { name: "callData", type: "bytes" },
    { name: "proof", type: "bytes[]" },
    { name: "crossProofSystemInteractions", type: "bytes32" },
  ],
} as const;

export const rollupsAbi = [
  // ── Events ──
  {
    type: "event",
    name: "RollupCreated",
    inputs: [
      { name: "rollupId", type: "uint256", indexed: true },
      { name: "rollupContract", type: "address", indexed: true },
      { name: "initialRoot", type: "bytes32", indexed: false },
    ],
  },
  {
    type: "event",
    name: "RollupContractChanged",
    inputs: [
      { name: "rollupId", type: "uint256", indexed: true },
      { name: "previousContract", type: "address", indexed: true },
      { name: "newContract", type: "address", indexed: true },
    ],
  },
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
    name: "ExecutionConsumed",
    inputs: [
      { name: "crossChainCallHash", type: "bytes32", indexed: true },
      { name: "rollupId", type: "uint256", indexed: true },
      { name: "cursor", type: "uint256", indexed: true },
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
    name: "L2TXExecuted",
    inputs: [
      { name: "rollupId", type: "uint256", indexed: true },
      { name: "cursor", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "BatchPosted",
    inputs: [
      { name: "subBatchCount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ImmediateEntrySkipped",
    inputs: [
      { name: "transientIdx", type: "uint256", indexed: true },
      { name: "revertData", type: "bytes", indexed: false },
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

  // ── Functions ──
  {
    type: "function",
    name: "registerRollup",
    stateMutability: "nonpayable",
    inputs: [
      { name: "rollupContract", type: "address" },
      { name: "initialRoot", type: "bytes32" },
    ],
    outputs: [{ name: "rollupId", type: "uint256" }],
  },
  {
    type: "function",
    name: "postBatch",
    stateMutability: "nonpayable",
    inputs: [
      { ...proofSystemBatchTuple, name: "batches" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "executeCrossChainCall",
    stateMutability: "payable",
    inputs: [
      { name: "sourceAddress", type: "address" },
      { name: "callData", type: "bytes" },
    ],
    outputs: [{ name: "result", type: "bytes" }],
  },
  {
    type: "function",
    name: "executeL2TX",
    stateMutability: "nonpayable",
    inputs: [{ name: "rollupId", type: "uint256" }],
    outputs: [{ name: "result", type: "bytes" }],
  },
  {
    type: "function",
    name: "staticCallLookup",
    stateMutability: "view",
    inputs: [
      { name: "sourceAddress", type: "address" },
      { name: "callData", type: "bytes" },
    ],
    outputs: [{ name: "result", type: "bytes" }],
  },
  {
    type: "function",
    name: "createCrossChainProxy",
    stateMutability: "nonpayable",
    inputs: [
      { name: "originalAddress", type: "address" },
      { name: "originalRollupId", type: "uint256" },
    ],
    outputs: [{ name: "proxy", type: "address" }],
  },
  {
    type: "function",
    name: "computeCrossChainProxyAddress",
    stateMutability: "view",
    inputs: [
      { name: "originalAddress", type: "address" },
      { name: "originalRollupId", type: "uint256" },
    ],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "rollups",
    stateMutability: "view",
    inputs: [{ name: "rollupId", type: "uint256" }],
    outputs: [
      { name: "rollupContract", type: "address" },
      { name: "root", type: "bytes32" },
      { name: "etherBalance", type: "uint256" },
    ],
  },
] as const;
