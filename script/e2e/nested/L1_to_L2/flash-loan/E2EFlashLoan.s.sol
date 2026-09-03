// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {IEEZ} from "../../../../../src/interfaces/IEEZ.sol";
import {RollupUpdate, L2ToL1Call, ExecutionEntry, StaticExecutionEntry} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../../../src/interfaces/IEEZL2.sol";
import {Bridge} from "../../../../../src/periphery/Bridge.sol";
import {WrappedToken} from "../../../../../src/periphery/WrappedToken.sol";
import {FlashLoan} from "../../../../../src/periphery/defiMock/FlashLoan.sol";
import {FlashLoanBridgeExecutor} from "../../../../../src/periphery/defiMock/FlashLoanBridgeExecutor.sol";
import {FlashLoanersNFT} from "../../../../../src/periphery/defiMock/FlashLoanersNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {_deployBridge} from "../../../../DeployBridge.s.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    crossChainCallHash,
    crossChainCallHashL2Out,
    expectedL1toL2Hash,
    getOrCreateProxy,
    noCalls,
    noL2Calls,
    noNestedActions,
    noStaticEntries,
    noL2StaticEntries,
    immediateSingleRollupBatch,
    RollingHashBuilder,
    HashStep
} from "../../../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  FlashLoan scenario — DeFi composite: flash loan whose repayment depends
//  on a full L1→L2→L1 bridge round trip, all inside ONE L1 user tx.
//
//  Trigger: EOA → executorL1.execute() → pool.flashLoan(token, 10k) →
//  executorL1.onFlashLoan():
//    1. bridge.bridgeTokens(token, 10k, L2, executorL2)
//       → locks 10k in bridgeL1, calls the L2-bridge proxy
//       → consumes L1 entry 0 (key: bridge→bridge receiveTokens forward).
//    2. executorL2Proxy.call(claimAndBridgeBack)
//       → consumes L1 entry 1 (key: executorL1→executorL2). Its single
//         top-level l2ToL1Call is the RETURN bridge leg: bridgeL2→bridgeL1
//         receiveTokens runs ON L1 and releases the escrowed 10k back to
//         executorL1 (native-token path).
//    3. repay the pool — solvent only because step 2 released the escrow.
//
//  L2 view: two inbound deliveries (one system tx each).
//    Entry 0: receiveTokens on bridgeL2 — deploys WrappedToken, mints 10k
//             to executorL2.
//    Entry 1: claimAndBridgeBack on executorL2 — claims the token-gated
//             NFT, then bridgeTokens(wrapped) burns the 10k and makes the
//             outgoing return call, matched against expectedOutgoingCalls[0].
//
//  The Bridge is CREATE2-deployed at the SAME address on both chains
//  (fresh salt per run), so `_bridgeAddress()` proxy lookups line up
//  without setCanonicalBridgeAddress.
//
//  Final state: L1 pool = 10k, bridgeL1 escrow = 0, executorL1 = 0;
//  L2 wrapped supply = 0 (minted then burned), NFT #1 owned by executorL2.
// ═══════════════════════════════════════════════════════════════════════

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

/// @notice Every address the scenario's calls fold into a hash. `bridge` is the
///         same CREATE2 address on both chains.
struct FlashLoanAddrs {
    address bridge;
    address token;
    address executorL1;
    address executorL2;
    address wrappedTokenL2;
    address nftL2;
}

/// @dev Native L1 token backing the flash loan; 1M minted to the deployer.
contract TestToken is ERC20 {
    constructor() ERC20("Test Token", "TT") {
        _mint(msg.sender, 1_000_000e18);
    }
}

abstract contract FlashLoanActions {
    uint256 internal constant AMOUNT = 10_000e18;
    // TestToken metadata — folded into both receiveTokens payloads (the forward leg
    // reads it from the L1 token, the return leg from the WrappedToken, which is
    // deployed with these same values).
    string internal constant TOKEN_NAME = "Test Token";
    string internal constant TOKEN_SYMBOL = "TT";
    uint8 internal constant TOKEN_DECIMALS = 18;

    // ── Call payloads ──

    /// Forward leg: built on L1 by `bridgeTokens` (native path) — mints wrapped to executorL2.
    function _fwdReceiveData(FlashLoanAddrs memory a) internal pure returns (bytes memory) {
        return abi.encodeCall(
            Bridge.receiveTokens,
            (
                a.token,
                MAINNET_ROLLUP_ID,
                a.executorL2,
                AMOUNT,
                TOKEN_NAME,
                TOKEN_SYMBOL,
                TOKEN_DECIMALS,
                MAINNET_ROLLUP_ID
            )
        );
    }

    /// Claim leg: executorL1 drives executorL2 through its proxy.
    function _claimData(FlashLoanAddrs memory a) internal pure returns (bytes memory) {
        return abi.encodeCall(
            FlashLoanBridgeExecutor.claimAndBridgeBack,
            (a.wrappedTokenL2, a.nftL2, a.bridge, MAINNET_ROLLUP_ID, a.executorL1)
        );
    }

    /// Return leg: built on L2 by `bridgeTokens` (wrapped path) — releases escrow to executorL1.
    function _retReceiveData(FlashLoanAddrs memory a) internal pure returns (bytes memory) {
        return abi.encodeCall(
            Bridge.receiveTokens,
            (a.token, MAINNET_ROLLUP_ID, a.executorL1, AMOUNT, TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS, L2_ROLLUP_ID)
        );
    }

    // ── Cross-chain call hashes ──

    /// Entry-0 key on both sides: bridgeL1 → bridgeL2 (same address) forward receiveTokens.
    function _fwdHash(FlashLoanAddrs memory a) internal pure returns (bytes32) {
        return crossChainCallHash(false, a.bridge, MAINNET_ROLLUP_ID, a.bridge, L2_ROLLUP_ID, 0, _fwdReceiveData(a));
    }

    /// Entry-1 key on both sides: executorL1 → executorL2 claimAndBridgeBack.
    function _claimHash(FlashLoanAddrs memory a) internal pure returns (bytes32) {
        return crossChainCallHash(false, a.executorL1, MAINNET_ROLLUP_ID, a.executorL2, L2_ROLLUP_ID, 0, _claimData(a));
    }

    /// Return leg as folded on L1 (entry 1's top-level l2ToL1Call): bridgeL2 → bridgeL1.
    function _retHash(FlashLoanAddrs memory a) internal pure returns (bytes32) {
        return crossChainCallHash(false, a.bridge, L2_ROLLUP_ID, a.bridge, MAINNET_ROLLUP_ID, 0, _retReceiveData(a));
    }

    /// Return leg as folded on L2 (the call LEAVES the L2, so it keys with the
    /// L2-outgoing hash; same digest under useGasLeft = false).
    function _retHashL2Out(FlashLoanAddrs memory a) internal pure returns (bytes32) {
        return crossChainCallHashL2Out(a.bridge, L2_ROLLUP_ID, a.bridge, MAINNET_ROLLUP_ID, 0, _retReceiveData(a));
    }

    // ── Tables ──

    function _l1Entries(FlashLoanAddrs memory a) internal pure returns (ExecutionEntry[] memory entries) {
        bytes32 rootAfterFwd = keccak256("l2-state-after-flash-loan-fwd");

        // Entry 0: forward bridge leg — no L1-side calls, seed-only rolling hash.
        RollupUpdate[] memory fwdDeltas = new RollupUpdate[](1);
        fwdDeltas[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID, currentRoot: keccak256("l2-initial-state"), newRoot: rootAfterFwd, etherDelta: 0
        });

        // Entry 1: claim leg — one top-level l2ToL1Call: the return bridge leg runs on L1.
        RollupUpdate[] memory claimDeltas = new RollupUpdate[](1);
        claimDeltas[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: rootAfterFwd,
            newRoot: keccak256("l2-state-after-flash-loan-claim"),
            etherDelta: 0
        });

        L2ToL1Call[] memory claimCalls = new L2ToL1Call[](1);
        claimCalls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: a.bridge,
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: a.bridge,
            value: 0,
            data: _retReceiveData(a)
        });

        bytes32 claimRh = RollingHashBuilder.entryBegin(claimDeltas, _claimHash(a));
        claimRh = RollingHashBuilder.appendCallBegin(claimRh, _retHash(a));
        claimRh = RollingHashBuilder.appendCallEnd(claimRh, true, ""); // receiveTokens returns void

        entries = new ExecutionEntry[](2);
        entries[0] = ExecutionEntry({
            rollupUpdates: fwdDeltas,
            proxyEntryHash: _fwdHash(a),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: RollingHashBuilder.entryBegin(fwdDeltas, _fwdHash(a)),
            success: true,
            returnData: ""
        });
        entries[1] = ExecutionEntry({
            rollupUpdates: claimDeltas,
            proxyEntryHash: _claimHash(a),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: claimCalls,
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: claimRh,
            success: true,
            returnData: ""
        });
    }

    /// Entry-1 rolling-hash folds, replayable by the network verifier over posted roots.
    function _l1Steps(FlashLoanAddrs memory a) internal pure returns (HashStep[][] memory steps) {
        steps = new HashStep[][](2);
        steps[0] = new HashStep[](0); // entry 0: seed only
        steps[1] = new HashStep[](2);
        steps[1][0] = RollingHashBuilder.stepCallBegin(_retHash(a));
        steps[1][1] = RollingHashBuilder.stepCallEnd(true, "");
    }

    function _l2Entries(FlashLoanAddrs memory a) internal pure returns (L2ExecutionEntry[] memory entries) {
        // Entry 0: forward receiveTokens delivery — deploy WrappedToken + mint.
        CrossChainCall[] memory fwdCalls = new CrossChainCall[](1);
        fwdCalls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: a.bridge,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: a.bridge,
            value: 0,
            data: _fwdReceiveData(a)
        });

        bytes32 fwdRh = RollingHashBuilder.entryBeginL2(_fwdHash(a));
        fwdRh = RollingHashBuilder.appendCallBegin(fwdRh, _fwdHash(a));
        fwdRh = RollingHashBuilder.appendCallEnd(fwdRh, true, "");

        // Entry 1: claimAndBridgeBack delivery — the outgoing return leg fires
        // mid-execution and is matched against expectedOutgoingCalls[0].
        CrossChainCall[] memory claimCalls = new CrossChainCall[](1);
        claimCalls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: a.executorL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: a.executorL2,
            value: 0,
            data: _claimData(a)
        });

        bytes32 claimRh = RollingHashBuilder.entryBeginL2(_claimHash(a));
        claimRh = RollingHashBuilder.appendCallBegin(claimRh, _claimHash(a));
        bytes32 rhAtFire = claimRh; // outgoing leg fires right after the call begins
        claimRh = RollingHashBuilder.appendNestedBegin(claimRh, _retHashL2Out(a));
        claimRh = RollingHashBuilder.appendNestedEnd(claimRh);
        claimRh = RollingHashBuilder.appendCallEnd(claimRh, true, "");

        ExpectedOutgoingCrossChainCall[] memory outgoing = new ExpectedOutgoingCrossChainCall[](1);
        outgoing[0] = ExpectedOutgoingCrossChainCall({
            expectedOutgoingHash: expectedL1toL2Hash(_retHashL2Out(a), rhAtFire),
            incomingCalls: noL2Calls(),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: "" // the L1-side receiveTokens returns void
        });

        entries = new L2ExecutionEntry[](2);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: _fwdHash(a),
            incomingCalls: fwdCalls,
            expectedOutgoingCalls: new ExpectedOutgoingCrossChainCall[](0),
            rollingHash: fwdRh,
            success: true,
            returnData: ""
        });
        entries[1] = L2ExecutionEntry({
            proxyEntryHash: _claimHash(a),
            incomingCalls: claimCalls,
            expectedOutgoingCalls: outgoing,
            rollingHash: claimRh,
            success: true,
            returnData: ""
        });
    }
}

/// @dev Reads the scenario's exported addresses back from the runner's env.
abstract contract FlashLoanEnv is Script {
    function _envAddrs() internal view returns (FlashLoanAddrs memory) {
        return FlashLoanAddrs({
            bridge: vm.envAddress("BRIDGE"),
            token: vm.envAddress("TOKEN"),
            executorL1: vm.envAddress("EXECUTOR_L1"),
            executorL2: vm.envAddress("EXECUTOR_L2"),
            wrappedTokenL2: vm.envAddress("PREDICTED_WRAPPED_TOKEN_L2"),
            nftL2: vm.envAddress("FLASH_LOANERS_NFT")
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Deploys — three-phase order:
//    1. Deploy (L1)   — TestToken + Bridge (CREATE2, fresh salt per run).
//    2. DeployL2 (L2) — Bridge twin (same salt/address), executorL2,
//                       pre-computed WrappedToken address, FlashLoanersNFT.
//    3. Deploy2 (L1)  — FlashLoan pool (funded), executorL2 proxy, executorL1.
// ═══════════════════════════════════════════════════════════════════════

/// Env: ROLLUPS
/// Outputs: TOKEN, BRIDGE, BRIDGE_SALT
contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");

        vm.startBroadcast();
        TestToken token = new TestToken();

        // Salt keyed on the fresh token address — unique per run, so reruns through the
        // shared keyless CREATE2 factory never collide with an earlier bridge.
        bytes32 salt = keccak256(abi.encodePacked("e2e-flash-loan", address(token)));
        address bridge = _deployBridge(salt);
        Bridge(bridge).initialize(rollupsAddr, MAINNET_ROLLUP_ID, msg.sender);

        output("TOKEN", address(token));
        output("BRIDGE", bridge);
        output("BRIDGE_SALT", salt);
        vm.stopBroadcast();
    }
}

/// Env: MANAGER_L2, TOKEN, BRIDGE, BRIDGE_SALT
/// Outputs: EXECUTOR_L2, PREDICTED_WRAPPED_TOKEN_L2 (no code until the forward leg), FLASH_LOANERS_NFT
contract DeployL2 is Script, FlashLoanActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address tokenAddr = vm.envAddress("TOKEN");
        address bridgeL1 = vm.envAddress("BRIDGE");
        bytes32 salt = vm.envBytes32("BRIDGE_SALT");

        vm.startBroadcast();
        address bridge = _deployBridge(salt);
        require(bridge == bridgeL1, "bridge address mismatch across chains");
        Bridge(bridge).initialize(managerAddr, L2_ROLLUP_ID, msg.sender);

        // Config args unused on the L2 side — claimAndBridgeBack takes everything as parameters.
        FlashLoanBridgeExecutor executorL2 = new FlashLoanBridgeExecutor(
            address(0), address(0), address(0), address(0), address(0), address(0), address(0), 0, address(0)
        );

        // Pre-compute the WrappedToken address the forward leg will deploy: CREATE2 from
        // the bridge with the original-token salt and the L1 token's metadata (mirrors
        // Bridge._getOrDeployWrapped) — the NFT needs it before the token exists.
        bytes32 wrappedSalt = keccak256(abi.encodePacked(tokenAddr, MAINNET_ROLLUP_ID));
        bytes32 wrappedInitHash = keccak256(
            abi.encodePacked(
                type(WrappedToken).creationCode, abi.encode(TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS, bridge)
            )
        );
        address wrappedTokenL2 =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), bridge, wrappedSalt, wrappedInitHash)))));

        FlashLoanersNFT nft = new FlashLoanersNFT(wrappedTokenL2);

        output("EXECUTOR_L2", address(executorL2));
        output("PREDICTED_WRAPPED_TOKEN_L2", wrappedTokenL2);
        output("FLASH_LOANERS_NFT", address(nft));
        vm.stopBroadcast();
    }
}

/// Env: ROLLUPS, TOKEN, BRIDGE, EXECUTOR_L2, PREDICTED_WRAPPED_TOKEN_L2, FLASH_LOANERS_NFT
/// Outputs: FLASH_LOAN_POOL, EXECUTOR_L1
contract Deploy2 is Script, FlashLoanActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address tokenAddr = vm.envAddress("TOKEN");
        address bridgeAddr = vm.envAddress("BRIDGE");
        address executorL2Addr = vm.envAddress("EXECUTOR_L2");
        address wrappedTokenL2 = vm.envAddress("PREDICTED_WRAPPED_TOKEN_L2");
        address nftAddr = vm.envAddress("FLASH_LOANERS_NFT");

        vm.startBroadcast();
        FlashLoan pool = new FlashLoan();
        IERC20(tokenAddr).transfer(address(pool), AMOUNT);

        // The proxy executorL1 drives to reach executorL2 (the claim-leg trigger target).
        address executorL2Proxy = getOrCreateProxy(IEEZ(rollupsAddr), executorL2Addr, L2_ROLLUP_ID);

        FlashLoanBridgeExecutor executorL1 = new FlashLoanBridgeExecutor(
            address(pool),
            bridgeAddr,
            executorL2Proxy,
            executorL2Addr,
            wrappedTokenL2,
            nftAddr,
            bridgeAddr,
            L2_ROLLUP_ID,
            tokenAddr
        );

        output("FLASH_LOAN_POOL", address(pool));
        output("EXECUTOR_L1", address(executorL1));
        vm.stopBroadcast();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Executes
// ═══════════════════════════════════════════════════════════════════════

/// ExecuteL2 — local mode: system-driven deliveries of both inbound calls, one
/// executeIncomingCrossChainCall tx per top-level call (delivery granularity),
/// each atomically loading its own single-entry table.
/// Env: MANAGER_L2 + the scenario addresses (FlashLoanEnv)
contract ExecuteL2 is FlashLoanEnv, FlashLoanActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        FlashLoanAddrs memory a = _envAddrs();
        L2ExecutionEntry[] memory entries = _l2Entries(a);
        L2ExecutionEntry[] memory single = new L2ExecutionEntry[](1);

        vm.startBroadcast();

        // Delivery 1: forward receiveTokens — deploys WrappedToken, mints 10k to executorL2.
        single[0] = entries[0];
        EEZL2(managerAddr).executeIncomingCrossChainCall(single, noL2StaticEntries());

        // Delivery 2: claimAndBridgeBack — claims the NFT, burns the wrapped 10k, and its
        // outgoing return leg is matched against expectedOutgoingCalls[0].
        single[0] = entries[1];
        EEZL2(managerAddr).executeIncomingCrossChainCall(single, noL2StaticEntries());

        console.log("done");
        console.log("nft claimed by executorL2=%s", FlashLoanersNFT(a.nftL2).hasClaimed(a.executorL2));
        console.log("wrapped balance of executorL2=%s (expected 0)", IERC20(a.wrappedTokenL2).balanceOf(a.executorL2));
        vm.stopBroadcast();
    }
}

/// Execute — local mode: postAndVerifyBatch tx + executorL1.execute() trigger tx
/// from the EOA; the runner mines both in one block (execute_l1_same_block).
/// Env: ROLLUPS, PROOF_SYSTEM, FLASH_LOAN_POOL + the scenario addresses (FlashLoanEnv)
contract Execute is FlashLoanEnv, FlashLoanActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address poolAddr = vm.envAddress("FLASH_LOAN_POOL");
        FlashLoanAddrs memory a = _envAddrs();

        vm.startBroadcast();
        EEZ(rollupsAddr)
            .postAndVerifyBatch(
                immediateSingleRollupBatch(proofSystemAddr, L2_ROLLUP_ID, _l1Entries(a), noStaticEntries())
            );
        FlashLoanBridgeExecutor(a.executorL1).execute();

        console.log("done");
        console.log("pool balance=%s (expected %s)", IERC20(a.token).balanceOf(poolAddr), AMOUNT);
        console.log("executorL1 balance=%s (expected 0)", IERC20(a.token).balanceOf(a.executorL1));
        console.log("bridge escrow=%s (expected 0)", IERC20(a.token).balanceOf(a.bridge));
        vm.stopBroadcast();
    }
}

/// ExecuteNetwork — network mode: the single user trigger is executorL1.execute().
contract ExecuteNetwork is Script {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("EXECUTOR_L1"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeCall(FlashLoanBridgeExecutor.execute, ())));
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ComputeExpected
// ═══════════════════════════════════════════════════════════════════════

contract ComputeExpected is ComputeExpectedBase, FlashLoanEnv, FlashLoanActions {
    function _name(address addr) internal view override returns (string memory) {
        if (addr == vm.envAddress("BRIDGE")) return "Bridge(L1/L2)";
        if (addr == vm.envAddress("TOKEN")) return "TestToken";
        if (addr == vm.envAddress("EXECUTOR_L1")) return "ExecutorL1";
        if (addr == vm.envAddress("EXECUTOR_L2")) return "ExecutorL2";
        if (addr == vm.envAddress("PREDICTED_WRAPPED_TOKEN_L2")) return "WrappedToken(L2)";
        if (addr == vm.envAddress("FLASH_LOANERS_NFT")) return "FlashLoanersNFT";
        return _shortAddr(addr);
    }

    function _funcName(bytes4 sel) internal pure override returns (string memory) {
        if (sel == Bridge.receiveTokens.selector) return "receiveTokens";
        if (sel == FlashLoanBridgeExecutor.claimAndBridgeBack.selector) return "claimAndBridgeBack";
        if (sel == FlashLoanBridgeExecutor.execute.selector) return "execute";
        return ComputeExpectedBase._funcName(sel);
    }

    function run() external view {
        FlashLoanAddrs memory a = _envAddrs();
        ExecutionEntry[] memory l1 = _l1Entries(a);
        L2ExecutionEntry[] memory l2 = _l2Entries(a);

        console.log("EXPECTED_L1_HASHES=[%s,%s]", vm.toString(_entryHash(l1[0])), vm.toString(_entryHash(l1[1])));
        console.log("EXPECTED_L2_HASHES=[%s,%s]", vm.toString(_entryHash(l2[0])), vm.toString(_entryHash(l2[1])));
        _printL1CallHashes(l1);
        _printL2CallHashes(l2);
        _printL1Table(l1);
        _printL1Steps(l1, _l1Steps(a));
        _printL2Table(l2);

        console.log("");
        console.log("=== EXPECTED L1 TABLE (2 entries: forward bridge, claim + return leg) ===");
        for (uint256 i = 0; i < l1.length; i++) {
            _logEntry(i, l1[i]);
        }

        console.log("");
        console.log("=== EXPECTED L2 TABLE (2 deliveries: mint, claim + outgoing return) ===");
        for (uint256 i = 0; i < l2.length; i++) {
            _logL2Entry(i, l2[i]);
        }
    }
}
