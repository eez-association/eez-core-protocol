// New model: no more ActionType/Action enums.
// crossChainCallHash = keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId))

export type CrossChainCall = {
  targetAddress: `0x${string}`;
  value: bigint;
  data: `0x${string}`;
  sourceAddress: `0x${string}`;
  sourceRollupId: bigint;
  revertSpan: bigint;
};

export type NestedAction = {
  crossChainCallHash: `0x${string}`;
  callCount: bigint;
  returnData: `0x${string}`;
};

export type StateDelta = {
  rollupId: bigint;
  currentRoot: `0x${string}`;
  newRoot: `0x${string}`;
  etherDelta: bigint;
};

export type ExecutionEntry = {
  stateDeltas: StateDelta[];
  crossChainCallHash: `0x${string}`;
  destinationRollupId: bigint;
  calls: CrossChainCall[];
  nestedActions: NestedAction[];
  callCount: bigint;
  returnData: `0x${string}`;
  rollingHash: `0x${string}`;
};

export type LookupCall = {
  crossChainCallHash: `0x${string}`;
  destinationRollupId: bigint;
  returnData: `0x${string}`;
  failed: boolean;
  callNumber: bigint;
  lastNestedActionConsumed: bigint;
  calls: CrossChainCall[];
  rollingHash: `0x${string}`;
};
