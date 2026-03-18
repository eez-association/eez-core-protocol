// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Represents an action used to build the entrypoint hash
struct Action {
    uint256 rollupId;
    address destination;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollup;
}

/// @notice Represents a state delta
struct StateDelta {
    uint256 rollupId;
    bytes32 newState;
    int256 etherDelta;
}

/// @notice Represents a cross-chain call within an execution entry
/// @dev revertSpan > 0 opens an isolated revert context spanning the next revertSpan calls (including this one)
struct CrossChainCall {
    address destination;
    uint256 value;
    bytes data;
    address sourceAddress;
    uint256 sourceRollup;
    uint256 revertSpan;
}

/// @notice Pre-computed result for a successful reentrant cross-chain call triggered during execution
/// @dev Consumed sequentially from the entry's nestedActions array. If a nested action itself
///      triggers a reentrant call, it consumes the next element in the same flat array.
/// @dev All nested actions must succeed. Failed calls should use StaticCall instead.
struct NestedAction {
    bytes32 actionHash;
    CrossChainCall[] calls;
    bytes returnData;
}

/// @notice Pre-computed result for a static call or a call that reverts
/// @dev Used for read-only calls and for calls whose revert needs to be replayed.
///      Loaded via postBatch (L1) or loadExecutionTable (L2).
struct StaticCall {
    bytes32 actionHash;
    bytes returnData;
    bool failed;
    bytes32 stateRoot;
    uint64 crossChainCall;
    uint64 nestedAction;
    CrossChainCall[] calls;
}

/// @notice Represents an execution entry with pre-computed calls and return hash verification
struct ExecutionEntry {
    StateDelta[] stateDeltas;
    bytes32 actionHash;
    CrossChainCall[] calls;
    NestedAction[] nestedActions;
    bytes returnData;
    bool failed;
    bytes32 rollingHash;
}

/// @notice Stores the identity of an authorized CrossChainProxy
struct ProxyInfo {
    address originalAddress;
    uint64 originalRollupId;
}

/// @title ICrossChainManager
/// @notice Interface for cross-chain manager contracts (L1 Rollups and L2 CrossChainManagerL2)
interface ICrossChainManager {
    function executeCrossChainCall(address sourceAddress, bytes calldata callData)
        external
        payable
        returns (bytes memory result);
    function createCrossChainProxy(address originalAddress, uint256 originalRollupId) external returns (address proxy);
    function computeCrossChainProxyAddress(address originalAddress, uint256 originalRollupId)
        external
        view
        returns (address);
}
