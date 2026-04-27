// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../src/Rollups.sol";
import {CrossChainManagerL2} from "../../src/CrossChainManagerL2.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {FlashLoan} from "../../src/periphery/defiMock/FlashLoan.sol";
import {FlashLoanBridgeExecutor} from "../../src/periphery/defiMock/FlashLoanBridgeExecutor.sol";
import {
    ExecutionEntry,
    StateDelta,
    CrossChainCall,
    NestedAction,
    StaticCall
} from "../../src/ICrossChainManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ── Rolling hash tag constants (must match contracts) ──
uint8 constant CALL_BEGIN = 1;
uint8 constant CALL_END = 2;
uint8 constant NESTED_BEGIN = 3;
uint8 constant NESTED_END = 4;

/// @title ExecuteFlashLoanL2 -- Load execution table + trigger cross-chain calls on L2
/// @dev Usage:
///   forge script script/flash-loan-test/ExecuteFlashLoan.s.sol:ExecuteFlashLoanL2 \
///     --rpc-url $L2_RPC --broadcast --private-key $PK \
///     --sig "run(address,address,address,address,address,address,address,address,string,string,uint8)" \
///     $MANAGER_L2 $BRIDGE_L1 $BRIDGE_L2 $EXECUTOR_L1 $EXECUTOR_L2 $FLASH_LOANERS_NFT $TOKEN $WRAPPED_TOKEN_L2 $TOKEN_NAME $TOKEN_SYMBOL $TOKEN_DECIMALS
contract ExecuteFlashLoanL2 is Script {
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;

    function run(
        address managerL2,
        address bridgeL1,
        address bridgeL2,
        address executorL1,
        address executorL2,
        address flashLoanersNFT,
        address token,
        address wrappedTokenL2,
        string calldata name,
        string calldata symbol,
        uint8 tokenDecimals
    ) external {
        CrossChainManagerL2 manager = CrossChainManagerL2(managerL2);

        // Forward receiveTokens: L1 -> L2
        bytes memory fwdReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (token, MAINNET_ROLLUP_ID, executorL2, 10_000e18, name, symbol, tokenDecimals, MAINNET_ROLLUP_ID)
        );

        // claimAndBridgeBack
        bytes memory claimAndBridgeBackCalldata = abi.encodeCall(
            FlashLoanBridgeExecutor.claimAndBridgeBack,
            (wrappedTokenL2, flashLoanersNFT, bridgeL2, MAINNET_ROLLUP_ID, executorL1)
        );

        // Return receiveTokens: L2 -> L1
        bytes memory retReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (token, MAINNET_ROLLUP_ID, executorL1, 10_000e18, name, symbol, tokenDecimals, L2_ROLLUP_ID)
        );

        // ── Compute action hashes ──

        // Entry 0: receiveTokens on L2 bridge (from L1 bridge proxy)
        // proxy identity: bridgeL1 on MAINNET, calling bridgeL2
        bytes32 actionHash0 = keccak256(
            abi.encode(
                L2_ROLLUP_ID,      // proxy.originalRollupId (where the bridge proxy represents)
                bridgeL2,          // proxy.originalAddress (destination bridge)
                uint256(0),        // value
                fwdReceiveTokensCalldata,
                bridgeL1,          // sourceAddress
                MAINNET_ROLLUP_ID  // sourceRollup
            )
        );

        // Entry 1: claimAndBridgeBack on executor L2 (from executor L1 proxy)
        bytes32 actionHash1 = keccak256(
            abi.encode(
                L2_ROLLUP_ID,      // proxy.originalRollupId
                executorL2,        // destination
                uint256(0),        // value
                claimAndBridgeBackCalldata,
                executorL1,        // sourceAddress
                MAINNET_ROLLUP_ID  // sourceRollup
            )
        );

        // Entry 2: receiveTokens return on L1 bridge (from L2 bridge proxy)
        // This entry is consumed on L1, but included here for the L2 table
        bytes32 actionHash2 = keccak256(
            abi.encode(
                MAINNET_ROLLUP_ID, // proxy.originalRollupId
                bridgeL1,          // destination
                uint256(0),        // value
                retReceiveTokensCalldata,
                bridgeL2,          // sourceAddress
                L2_ROLLUP_ID       // sourceRollup
            )
        );

        vm.startBroadcast();

        // Load execution table (3 entries -- no calls[], simple sequential consumption)
        ExecutionEntry[] memory l2Entries = new ExecutionEntry[](3);
        StateDelta[] memory emptyDeltas = new StateDelta[](0);
        CrossChainCall[] memory noCalls = new CrossChainCall[](0);
        NestedAction[] memory noNested = new NestedAction[](0);
        StaticCall[] memory noStaticCalls = new StaticCall[](0);

        l2Entries[0] = ExecutionEntry({
            stateDeltas: emptyDeltas,
            actionHash: actionHash0,
            calls: noCalls,
            nestedActions: noNested,
            callCount: 0,
            returnData: "",
            failed: false,
            rollingHash: bytes32(0)
        });

        l2Entries[1] = ExecutionEntry({
            stateDeltas: emptyDeltas,
            actionHash: actionHash1,
            calls: noCalls,
            nestedActions: noNested,
            callCount: 0,
            returnData: "",
            failed: false,
            rollingHash: bytes32(0)
        });

        l2Entries[2] = ExecutionEntry({
            stateDeltas: emptyDeltas,
            actionHash: actionHash2,
            calls: noCalls,
            nestedActions: noNested,
            callCount: 0,
            returnData: "",
            failed: false,
            rollingHash: bytes32(0)
        });

        manager.loadExecutionTable(l2Entries, noStaticCalls);
        console.log("L2 execution table loaded (3 entries)");

        vm.stopBroadcast();
    }
}

/// @title FlashLoanBatcher -- postBatch + executor.execute() in single tx
contract FlashLoanBatcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata staticCalls,
        FlashLoanBridgeExecutor executor
    ) external {
        rollups.postBatch(entries, staticCalls, 0, 0, 0, "", "proof");
        executor.execute();
    }
}

/// @title ExecuteFlashLoanL1 -- Post batch entries + trigger flash loan (same block)
/// @dev Usage:
///   forge script script/flash-loan-test/ExecuteFlashLoan.s.sol:ExecuteFlashLoanL1 \
///     --rpc-url $L1_RPC --broadcast --private-key $PK \
///     --sig "run(address,address,address,address,address,address,address,address)" \
///     $ROLLUPS $BRIDGE_L1 $BRIDGE_L2 $EXECUTOR_L1 $EXECUTOR_L2 $FLASH_LOANERS_NFT $TOKEN $WRAPPED_TOKEN_L2
contract ExecuteFlashLoanL1 is Script {
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;

    function run(
        address rollupsAddr,
        address bridgeL1,
        address bridgeL2,
        address executorL1,
        address executorL2,
        address flashLoanersNFT,
        address token,
        address wrappedTokenL2
    ) external {
        Rollups rollups = Rollups(rollupsAddr);

        string memory name = ERC20(token).name();
        string memory symbol = ERC20(token).symbol();
        uint8 tokenDecimals = ERC20(token).decimals();

        // Forward receiveTokens: L1 -> L2
        bytes memory fwdReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (token, MAINNET_ROLLUP_ID, executorL2, 10_000e18, name, symbol, tokenDecimals, MAINNET_ROLLUP_ID)
        );

        // claimAndBridgeBack
        bytes memory claimAndBridgeBackCalldata = abi.encodeCall(
            FlashLoanBridgeExecutor.claimAndBridgeBack,
            (wrappedTokenL2, flashLoanersNFT, bridgeL2, MAINNET_ROLLUP_ID, executorL1)
        );

        // Return receiveTokens: L2 -> L1
        bytes memory retReceiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (token, MAINNET_ROLLUP_ID, executorL1, 10_000e18, name, symbol, tokenDecimals, L2_ROLLUP_ID)
        );

        // ── Compute action hashes ──

        // L1 entry for the forward bridge call (bridgeTokens triggers proxy -> executeCrossChainCall)
        // proxy identity: bridgeL1 on L2, sourceAddress = bridgeL1, sourceRollup = MAINNET
        bytes32 callForwardHash = keccak256(
            abi.encode(
                L2_ROLLUP_ID,      // proxy.originalRollupId
                bridgeL2,          // proxy.originalAddress
                uint256(0),        // value
                fwdReceiveTokensCalldata,
                bridgeL1,          // sourceAddress
                MAINNET_ROLLUP_ID  // sourceRollup
            )
        );

        // L1 entry for claimAndBridgeBack (executor calls executorL2Proxy)
        bytes32 callClaimHash = keccak256(
            abi.encode(
                L2_ROLLUP_ID,      // proxy.originalRollupId
                executorL2,        // destination
                uint256(0),        // value
                claimAndBridgeBackCalldata,
                executorL1,        // sourceAddress
                MAINNET_ROLLUP_ID  // sourceRollup
            )
        );

        // L1 entry for return bridge (L2 bridge calls L1 bridge proxy)
        bytes32 callReturnHash = keccak256(
            abi.encode(
                MAINNET_ROLLUP_ID, // proxy.originalRollupId
                bridgeL1,          // destination
                uint256(0),        // value
                retReceiveTokensCalldata,
                bridgeL2,          // sourceAddress
                L2_ROLLUP_ID       // sourceRollup
            )
        );

        // ── State deltas ──
        bytes32 s1 = keccak256("l2-tokens-bridged-to-executor");
        bytes32 s2 = keccak256("l2-nft-claimed-tokens-bridged-back");
        bytes32 s3 = keccak256("l2-bridge-return-executed");

        // 3 deferred entries
        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, newState: s1, etherDelta: 0});

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({rollupId: L2_ROLLUP_ID, newState: s2, etherDelta: 0});

        StateDelta[] memory deltas3 = new StateDelta[](1);
        deltas3[0] = StateDelta({rollupId: L2_ROLLUP_ID, newState: s3, etherDelta: 0});

        CrossChainCall[] memory noCalls = new CrossChainCall[](0);
        NestedAction[] memory noNested = new NestedAction[](0);

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);

        // Entry 0: forward bridge call -- consumed when bridgeTokens triggers proxy
        entries[0] = ExecutionEntry({
            stateDeltas: deltas1,
            actionHash: callForwardHash,
            calls: noCalls,
            nestedActions: noNested,
            callCount: 0,
            returnData: "",
            failed: false,
            rollingHash: bytes32(0)
        });

        // Entry 1: claimAndBridgeBack -- consumed when executor calls executorL2Proxy
        // This entry has a nestedAction for the bridge return call (reentrant)
        NestedAction[] memory nested1 = new NestedAction[](1);
        nested1[0] = NestedAction({
            actionHash: callReturnHash,
            callCount: 0,
            returnData: ""
        });

        entries[1] = ExecutionEntry({
            stateDeltas: deltas2,
            actionHash: callClaimHash,
            calls: noCalls,
            nestedActions: nested1,
            callCount: 0,
            returnData: "",
            failed: false,
            rollingHash: _computeRollingHashForNested1()
        });

        // Entry 2: final state update (L2TX -- actionHash == 0, consumed via executeL2TX)
        entries[2] = ExecutionEntry({
            stateDeltas: deltas3,
            actionHash: bytes32(0),
            calls: noCalls,
            nestedActions: noNested,
            callCount: 0,
            returnData: "",
            failed: false,
            rollingHash: bytes32(0)
        });

        vm.startBroadcast();

        StaticCall[] memory noStaticCalls = new StaticCall[](0);

        // Batcher ensures postBatch + execute happen in the same block
        FlashLoanBatcher batcher = new FlashLoanBatcher();
        batcher.execute(rollups, entries, noStaticCalls, FlashLoanBridgeExecutor(executorL1));

        // Consume the L2TX entry
        rollups.executeL2TX();

        console.log("L1 execution complete");

        vm.stopBroadcast();
    }

    /// @dev Compute rolling hash for entry 1 which has 1 nested action
    function _computeRollingHashForNested1() internal pure returns (bytes32) {
        bytes32 h = bytes32(0);
        // Nested action #1 consumed (nestedNumber = 1)
        h = keccak256(abi.encodePacked(h, NESTED_BEGIN, uint256(1)));
        // No calls inside nested, so nothing between BEGIN and END
        h = keccak256(abi.encodePacked(h, NESTED_END, uint256(1)));
        return h;
    }
}
