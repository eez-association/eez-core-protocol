// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {
    EEZ,
    ProofSystemBatchPerVerificationEntries,
    ExpectedStateRootPerRollup,
    RollupIdWithProofSystems
} from "../../src/EEZ.sol";
import {EEZL2} from "../../src/L2/EEZL2.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {FlashLoan} from "../../src/periphery/defiMock/FlashLoan.sol";
import {FlashLoanBridgeExecutor} from "../../src/periphery/defiMock/FlashLoanBridgeExecutor.sol";
import {ExecutionEntry, StateDelta, L2ToL1Call, StaticLookup} from "../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2ExecutionEntry, StaticLookup as L2StaticLookup} from "../../src/interfaces/IEEZL2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    crossChainCallHash,
    noCalls,
    noNestedActions,
    noL2Calls,
    noL2OutgoingCalls,
    noL2StaticLookups,
    RollingHashBuilder
} from "../e2e/shared/E2EHelpers.sol";

/// @title ExecuteFlashLoanL2 -- Load execution table + trigger cross-chain calls on L2
/// @dev Usage:
///   forge script script/flash-loan-test/ExecuteFlashLoan.s.sol:ExecuteFlashLoanL2 \
///     --rpc-url $L2_RPC --broadcast --private-key $PK \
///     --sig "run(address,address,address,address,address,address,address,address,string,string,uint8)" \
///     $MANAGER_L2 $BRIDGE_L1 $BRIDGE_L2 $EXECUTOR_L1 $EXECUTOR_L2 $FLASH_LOANERS_NFT $TOKEN $WRAPPED_TOKEN_L2 $TOKEN_NAME $TOKEN_SYMBOL $TOKEN_DECIMALS
contract ExecuteFlashLoanL2 is Script {
    uint64 constant L2_ROLLUP_ID = 1;
    uint64 constant MAINNET_ROLLUP_ID = 0;

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
    )
        external
    {
        EEZL2 manager = EEZL2(managerL2);

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

        // ── Compute proxy-entry hashes (new computeCrossChainCallHash formula) ──

        // Entry 0: receiveTokens on L2 bridge (from L1 bridge proxy)
        bytes32 actionHash0 =
            crossChainCallHash(L2_ROLLUP_ID, bridgeL2, 0, fwdReceiveTokensCalldata, bridgeL1, MAINNET_ROLLUP_ID);

        // Entry 1: claimAndBridgeBack on executor L2 (from executor L1 proxy)
        bytes32 actionHash1 =
            crossChainCallHash(L2_ROLLUP_ID, executorL2, 0, claimAndBridgeBackCalldata, executorL1, MAINNET_ROLLUP_ID);

        // Entry 2: receiveTokens return on L1 bridge (from L2 bridge proxy). Consumed on L1; kept
        // in the L2 table to mirror the L1 side.
        bytes32 actionHash2 =
            crossChainCallHash(MAINNET_ROLLUP_ID, bridgeL1, 0, retReceiveTokensCalldata, bridgeL2, L2_ROLLUP_ID);

        vm.startBroadcast();

        // Load execution table (3 entries -- no incomingCalls, simple sequential consumption).
        // PENDING EEZL2: L2 rolling-hash seed (entryBeginL2) is provisional until EEZL2.sol lands.
        L2ExecutionEntry[] memory l2Entries = new L2ExecutionEntry[](3);

        l2Entries[0] = L2ExecutionEntry({
            proxyEntryHash: actionHash0,
            incomingCalls: noL2Calls(),
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: RollingHashBuilder.entryBeginL2(actionHash0), // PENDING EEZL2
            success: true,
            returnData: ""
        });

        l2Entries[1] = L2ExecutionEntry({
            proxyEntryHash: actionHash1,
            incomingCalls: noL2Calls(),
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: RollingHashBuilder.entryBeginL2(actionHash1), // PENDING EEZL2
            success: true,
            returnData: ""
        });

        l2Entries[2] = L2ExecutionEntry({
            proxyEntryHash: actionHash2,
            incomingCalls: noL2Calls(),
            expectedOutgoingCalls: noL2OutgoingCalls(),
            rollingHash: RollingHashBuilder.entryBeginL2(actionHash2), // PENDING EEZL2
            success: true,
            returnData: ""
        });

        manager.loadExecutionTable(l2Entries, noL2StaticLookups());
        console.log("L2 execution table loaded (3 entries)");

        vm.stopBroadcast();
    }
}

/// @title FlashLoanBatcher -- postAndVerifyBatch + executor.execute() in single tx
contract FlashLoanBatcher {
    uint64 constant L2_ROLLUP_ID = 1;

    function execute(
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        StaticLookup[] calldata staticLookups,
        FlashLoanBridgeExecutor executor
    )
        external
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        uint64[] memory rids = new uint64[](1);
        rids[0] = L2_ROLLUP_ID;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](psList.length);
        for (uint256 _i = 0; _i < psList.length; _i++) {
            psIdx[_i] = uint64(_i);
        }
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](rids.length);
        for (uint256 _i = 0; _i < rids.length; _i++) {
            rps[_i] = RollupIdWithProofSystems({rollupId: rids[_i], proofSystemIndexes: psIdx});
        }

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            expectedStateRootPerRollup: new ExpectedStateRootPerRollup[](0),
            entries: entries,
            staticLookups: staticLookups,
            immediateEntryCount: 0,
            immediateStaticLookupCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs,
            blockNumber: 0
        });
        rollups.postAndVerifyBatch(batch);
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
    uint64 constant L2_ROLLUP_ID = 1;
    uint64 constant MAINNET_ROLLUP_ID = 0;

    function run(
        address rollupsAddr,
        address proofSystemAddr,
        address bridgeL1,
        address bridgeL2,
        address executorL1,
        address executorL2,
        address flashLoanersNFT,
        address token,
        address wrappedTokenL2
    )
        external
    {
        EEZ rollups = EEZ(rollupsAddr);

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

        // ── Compute cross-chain call hashes (new computeCrossChainCallHash formula) ──

        // L1 entry 0: forward bridge call (bridgeTokens -> L2-bridge proxy -> executeCrossChainCall)
        bytes32 callForwardHash =
            crossChainCallHash(L2_ROLLUP_ID, bridgeL2, 0, fwdReceiveTokensCalldata, bridgeL1, MAINNET_ROLLUP_ID);

        // L1 entry 1: claimAndBridgeBack (executor calls executorL2 proxy)
        bytes32 callClaimHash =
            crossChainCallHash(L2_ROLLUP_ID, executorL2, 0, claimAndBridgeBackCalldata, executorL1, MAINNET_ROLLUP_ID);

        // The return bridge runs back ON L1 (target = bridgeL1 @ MAINNET) inside entry 1's execution,
        // so it is a top-level l2ToL1Call of entry 1, not a reentrant (L1->L2) frame.
        bytes32 callReturnHash =
            crossChainCallHash(MAINNET_ROLLUP_ID, bridgeL1, 0, retReceiveTokensCalldata, bridgeL2, L2_ROLLUP_ID);

        // ── State deltas ──
        bytes32 s1 = keccak256("l2-tokens-bridged-to-executor");
        bytes32 s2 = keccak256("l2-nft-claimed-tokens-bridged-back");
        bytes32 s3 = keccak256("l2-bridge-return-executed");

        // 3 deferred entries
        StateDelta[] memory deltas1 = new StateDelta[](1);
        deltas1[0] = StateDelta({
            rollupId: L2_ROLLUP_ID, currentState: keccak256("l2-initial-state"), newState: s1, etherDelta: 0
        });

        StateDelta[] memory deltas2 = new StateDelta[](1);
        deltas2[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});

        StateDelta[] memory deltas3 = new StateDelta[](1);
        deltas3[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s2, newState: s3, etherDelta: 0});

        ExecutionEntry[] memory entries = new ExecutionEntry[](3);

        // Entry 0: forward bridge call -- consumed when bridgeTokens triggers the L2-bridge proxy.
        // No L1 top-level calls; rolling hash is just the entry-begin seed.
        entries[0] = ExecutionEntry({
            stateDeltas: deltas1,
            proxyEntryHash: callForwardHash,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(deltas1, callForwardHash),
            success: true,
            returnData: ""
        });

        // Entry 1: claimAndBridgeBack -- consumed when the executor calls the executorL2 proxy.
        // The return bridge call executes ON L1 as the entry's single top-level l2ToL1Call.
        L2ToL1Call[] memory entry1Calls = new L2ToL1Call[](1);
        entry1Calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: bridgeL2,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: bridgeL1,
            value: 0,
            data: retReceiveTokensCalldata
        });

        bytes32 rh1 = RollingHashBuilder.entryBegin(deltas2, callClaimHash);
        rh1 = RollingHashBuilder.appendCallBegin(rh1, callReturnHash);
        rh1 = RollingHashBuilder.appendCallEnd(rh1, true, "");

        entries[1] = ExecutionEntry({
            stateDeltas: deltas2,
            proxyEntryHash: callClaimHash,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: entry1Calls,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh1,
            success: true,
            returnData: ""
        });

        // Entry 2: final state update (L2TX -- proxyEntryHash == 0, consumed via executeL2Txs)
        entries[2] = ExecutionEntry({
            stateDeltas: deltas3,
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(deltas3, bytes32(0)),
            success: true,
            returnData: ""
        });

        vm.startBroadcast();

        // Batcher ensures postAndVerifyBatch + execute happen in the same block
        FlashLoanBatcher batcher = new FlashLoanBatcher();
        batcher.execute(rollups, proofSystemAddr, entries, new StaticLookup[](0), FlashLoanBridgeExecutor(executorL1));

        // Consume the L2TX entry
        rollups.executeL2Txs(L2_ROLLUP_ID);

        console.log("L1 execution complete");

        vm.stopBroadcast();
    }
}
