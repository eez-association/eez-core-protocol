// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {EEZ, RollupConfig, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../src/EEZ.sol";
import {Rollup} from "../src/rollupContract/Rollup.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {CrossChainProxy} from "../src/base/CrossChainProxy.sol";
import {
    ExecutionEntry,
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    LookupCall,
    ProxyInfo
} from "../src/interfaces/IEEZ.sol";
import {MockProofSystem} from "./mocks/MockProofSystem.sol";
import {Bridge} from "../src/periphery/Bridge.sol";
import {WrappedToken} from "../src/periphery/WrappedToken.sol";
import {FlashLoan} from "../src/periphery/defiMock/FlashLoan.sol";
import {FlashLoanBridgeExecutor} from "../src/periphery/defiMock/FlashLoanBridgeExecutor.sol";
import {FlashLoanersNFT} from "../src/periphery/defiMock/FlashLoanersNFT.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FlashLoanTestToken is ERC20 {
    constructor() ERC20("Test Token", "TT") {
        _mint(msg.sender, 100_000e18);
    }
}

/// @title IntegrationTestFlashLoan
/// @notice End-to-end test of a cross-chain flash loan scenario
///
/// The flow:
///   1. Phase 1 (setup): Bridge 10,000 tokens from L1 to L2, delivering wrapped tokens
///      to executorL2. Deploy FlashLoanersNFT (gated by wrapped token balance) and executors.
///   2. Phase 2 (flash loan):
///      - executorL1.execute() triggers flash loan on L1
///      - Inside onFlashLoan:
///        a. bridgeL1.bridgeTokens locks tokens on L1 (consumes L1 entry #0)
///        b. executorL2Proxy.call(claimAndBridgeBack) (consumes L1 entry #1):
///           - L1 entry #1 calls[] run claimAndBridgeBack on executorL2 via proxy:
///             * NFT claimed (executorL2 holds >= 10,000 wrapped tokens)
///             * bridgeL2.bridgeTokens burns wrapped, calls L2 proxy (consumes L2 entry #0)
///           - L1 entry #1 calls[] then run receiveTokens on bridgeL1 via proxy:
///             * Releases 10,000 tokens to executorL1
///        c. executorL1 repays flash loan pool
///
/// ┌────┬─────────────────────────────────────────┬──────────┬─────────────────────┐
/// │  # │ Step                                    │ Chain    │ Entry consumed       │
/// ├────┼─────────────────────────────────────────┼──────────┼─────────────────────┤
/// │  1 │ bridgeTokens (lock on L1)               │ L1       │ L1 entry #0 (defer) │
/// │  2 │ claimAndBridgeBack (NFT + burn wrapped) │ L1+L2    │ L1 entry #1 (defer) │
/// │  3 │ bridgeL2.bridgeTokens (burn wrapped)    │ L2       │ L2 entry #0 (defer) │
/// │  4 │ receiveTokens (release on L1)           │ L1       │ (L1 entry #1 call)  │
/// └────┴─────────────────────────────────────────┴──────────┴─────────────────────┘
contract IntegrationTestFlashLoan is Test {
    // ── L1 contracts ──
    EEZ public rollups;
    MockProofSystem public ps;
    Rollup public l2Manager;

    // ── L2 contracts ──
    EEZL2 public managerL2;

    // ── Bridge contracts ──
    Bridge public bridgeL1;
    Bridge public bridgeL2;

    // ── Flash loan ──
    FlashLoan public flashLoanPool;

    // ── Token ──
    FlashLoanTestToken public token;

    // ── DeFi contracts (L2) ──
    FlashLoanersNFT public nftL2;

    // ── Executors ──
    FlashLoanBridgeExecutor public executorL1;
    FlashLoanBridgeExecutor public executorL2;

    // ── Proxy addresses ──
    address public executorL2ProxyL1; // L1 EEZ proxy for (executorL2, L2)
    address public proxyBridgeL1OnL2; // L2 managerL2 proxy for (bridgeL1, MAINNET)

    // ── Wrapped token on L2 ──
    address public wrappedTokenL2;

    // ── Constants ──
    uint256 constant L2_ROLLUP_ID = 1;
    uint256 constant MAINNET_ROLLUP_ID = 0;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    // Rolling hash tag constants (must match contracts)
    uint8 constant CALL_BEGIN = 1;
    uint8 constant CALL_END = 2;
    uint8 constant NESTED_BEGIN = 3;
    uint8 constant NESTED_END = 4;

    function setUp() public {
        // ── L1 infrastructure ──
        rollups = new EEZ();
        ps = new MockProofSystem();

        // Burn rollupId 0 = MAINNET so the L2 rollup gets id 1.
        {
            address[] memory psList = new address[](1);
            psList[0] = address(ps);
            bytes32[] memory vks = new bytes32[](1);
            vks[0] = DEFAULT_VK;
            Rollup burnRollup = new Rollup(address(rollups), address(this), 1, psList, vks);
            rollups.registerRollup(address(burnRollup), bytes32(0));
        }
        {
            address[] memory psList = new address[](1);
            psList[0] = address(ps);
            bytes32[] memory vks = new bytes32[](1);
            vks[0] = DEFAULT_VK;
            l2Manager = new Rollup(address(rollups), address(this), 1, psList, vks);
            uint256 rid = rollups.registerRollup(address(l2Manager), keccak256("l2-initial-state"));
            require(rid == L2_ROLLUP_ID, "expected L2_ROLLUP_ID = 1");
        }

        // ── L2 infrastructure ──
        managerL2 = new EEZL2(L2_ROLLUP_ID, SYSTEM_ADDRESS);

        // ── Bridge deployment ──
        bridgeL1 = new Bridge();
        bridgeL2 = new Bridge();
        bridgeL1.initialize(address(rollups), MAINNET_ROLLUP_ID, address(this));
        bridgeL2.initialize(address(managerL2), L2_ROLLUP_ID, address(this));
        // Cross-reference canonical addresses for bidirectional bridging
        bridgeL2.setCanonicalBridgeAddress(address(bridgeL1));
        bridgeL1.setCanonicalBridgeAddress(address(bridgeL2));

        // ── Token setup ──
        token = new FlashLoanTestToken(); // 100,000e18 minted to address(this)

        // ── Flash loan pool ──
        flashLoanPool = new FlashLoan();
        token.transfer(address(flashLoanPool), 10_000e18);

        // ── Deploy executorL2 with placeholder immutables ──
        // Only claimAndBridgeBack (parameter-based) is called on executorL2; immutables unused.
        executorL2 = new FlashLoanBridgeExecutor(
            address(0), address(0), address(0), address(0), address(0), address(0), address(0), 0, address(0)
        );

        // ── Create proxies ──
        proxyBridgeL1OnL2 = managerL2.createCrossChainProxy(address(bridgeL1), MAINNET_ROLLUP_ID);
        executorL2ProxyL1 = rollups.createCrossChainProxy(address(executorL2), L2_ROLLUP_ID);
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    function _getRollupState(uint256 rollupId) internal view returns (bytes32) {
        (, bytes32 stateRoot,) = rollups.rollups(rollupId);
        return stateRoot;
    }

    /// @dev Computes action hash the same way contracts do
    function _crossChainCallHash(
        uint256 rollupId,
        address destination,
        uint256 value,
        bytes memory data,
        address sourceAddress,
        uint256 sourceRollup
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup));
    }

    /// @dev Helper to create an empty LookupCall array
    /// @dev Wraps a single sub-batch to L2 and posts it.
    function _postBatchToL2(ExecutionEntry[] memory entries, uint256 transientCount) internal {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        uint256[] memory rids = new uint256[](1);
        rids[0] = L2_ROLLUP_ID;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](psList.length);
        for (uint256 _i = 0; _i < psList.length; _i++) {
            psIdx[_i] = uint64(_i);
        }
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](rids.length);
        for (uint256 _i = 0; _i < rids.length; _i++) {
            rps[_i] = RollupIdWithProofSystems({rollupId: rids[_i], proofSystemIndex: psIdx});
        }

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            entries: entries,
            l1ToL2lookupCalls: _noLookupCalls(),
            transientExecutionEntryCount: transientCount,
            transientLookupCallCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
    }

    function _noLookupCalls() internal pure returns (LookupCall[] memory) {
        return new LookupCall[](0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test: Cross-chain flash loan
    //
    //  Phase 1: Bridge 10,000 tokens from L1 to L2, funding executorL2
    //  Phase 2: Execute flash loan on L1 with cross-chain NFT claim + bridge-back
    // ═══════════════════════════════════════════════════════════════════════

    function test_CrossChainFlashLoan() public {
        // ════════════════════════════════════════════
        //  Phase 1a: L1 — Bridge 10,000 tokens to executorL2 on L2
        // ════════════════════════════════════════════
        //
        //  bridgeL1._bridgeAddress() = bridgeL2 (canonical override)
        //  bridgeL1.bridgeTokens creates proxy(bridgeL2, L2) on L1
        //  proxy fallback -> EEZ.executeL1ToL2Call(bridgeL1, receiveTokensCalldata)
        //  proxyInfo: (bridgeL2, L2)
        //  crossChainCallHash = hash(L2, bridgeL2, 0, receiveTokensCalldata, bridgeL1, MAINNET)

        bytes memory phase1ReceiveCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (
                address(token),
                MAINNET_ROLLUP_ID,
                address(executorL2),
                10_000e18,
                "Test Token",
                "TT",
                18,
                MAINNET_ROLLUP_ID
            )
        );

        bytes32 phase1L1ActionHash = _crossChainCallHash(
            L2_ROLLUP_ID, address(bridgeL2), 0, phase1ReceiveCalldata, address(bridgeL1), MAINNET_ROLLUP_ID
        );

        bytes32 s1 = keccak256("l2-state-after-phase1-bridge");

        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: L2_ROLLUP_ID, currentState: keccak256("l2-initial-state"), newState: s1, etherDelta: 0
            });

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = stateDeltas;
            entries[0].proxyEntryHash = phase1L1ActionHash;
            entries[0].destinationRollupId = L2_ROLLUP_ID;
            // No calls, returnData = "", rollingHash = 0

            _postBatchToL2(entries, 0);
        }

        // Bridge tokens from test contract
        token.approve(address(bridgeL1), 10_000e18);
        bridgeL1.bridgeTokens(address(token), 10_000e18, L2_ROLLUP_ID, address(executorL2));

        assertEq(token.balanceOf(address(bridgeL1)), 10_000e18, "Phase 1a: bridgeL1 should hold locked tokens");
        assertEq(_getRollupState(L2_ROLLUP_ID), s1, "Phase 1a: L2 state should be updated");

        // ════════════════════════════════════════════
        //  Phase 1b: L2 — Deliver wrapped tokens to executorL2
        // ════════════════════════════════════════════
        //
        //  Trigger: test contract calls proxyBridgeL1OnL2 with empty data
        //    -> managerL2.executeL1ToL2Call(address(this), "")
        //    -> proxyInfo: (bridgeL1, MAINNET)
        //    -> crossChainCallHash = hash(MAINNET, bridgeL1, 0, "", address(this), L2)
        //    -> entry consumed -> calls[0] routes receiveTokens to bridgeL2

        bytes32 phase1L2TriggerHash =
            _crossChainCallHash(MAINNET_ROLLUP_ID, address(bridgeL1), 0, "", address(this), L2_ROLLUP_ID);

        L2ToL1Call[] memory phase1L2Calls = new L2ToL1Call[](1);
        phase1L2Calls[0] = L2ToL1Call({
            targetAddress: address(bridgeL2),
            value: 0,
            data: phase1ReceiveCalldata,
            sourceAddress: address(bridgeL1),
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        // Rolling hash: 1 call, receiveTokens returns void -> success=true, retData=""
        bytes32 phase1L2RollingHash;
        {
            bytes32 h = bytes32(0);
            h = keccak256(abi.encodePacked(h, CALL_BEGIN, uint256(1)));
            h = keccak256(abi.encodePacked(h, CALL_END, uint256(1), true, bytes("")));
            phase1L2RollingHash = h;
        }

        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].proxyEntryHash = phase1L2TriggerHash;
            entries[0].L2ToL1Calls = phase1L2Calls;
            entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
            entries[0].callCount = 1;
            entries[0].returnData = "";
            entries[0].rollingHash = phase1L2RollingHash;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries, _noLookupCalls());
        }

        // Trigger L2 delivery
        (bool success,) = proxyBridgeL1OnL2.call("");
        assertTrue(success, "Phase 1b: L2 trigger call should succeed");

        // Verify wrapped token deployed and executorL2 funded
        wrappedTokenL2 = bridgeL2.getWrappedToken(address(token), MAINNET_ROLLUP_ID);
        assertTrue(wrappedTokenL2 != address(0), "Phase 1b: wrapped token should be deployed on L2");
        assertEq(
            WrappedToken(wrappedTokenL2).balanceOf(address(executorL2)),
            10_000e18,
            "Phase 1b: executorL2 should have 10,000 wrapped tokens"
        );

        // ════════════════════════════════════════════
        //  Deploy remaining contracts (need wrappedTokenL2 address)
        // ════════════════════════════════════════════

        nftL2 = new FlashLoanersNFT(wrappedTokenL2);

        executorL1 = new FlashLoanBridgeExecutor(
            address(flashLoanPool),
            address(bridgeL1),
            executorL2ProxyL1,
            address(executorL2),
            wrappedTokenL2,
            address(nftL2),
            address(bridgeL2),
            L2_ROLLUP_ID,
            address(token)
        );

        // ════════════════════════════════════════════
        //  Phase 2: Execute the flash loan
        // ════════════════════════════════════════════
        //
        //  executorL1.execute():
        //    -> flashLoanPool.flashLoan(token, 10,000e18)
        //    -> onFlashLoan:
        //       (a) bridge.bridgeTokens -> consumes L1 entry #0
        //       (b) executorL2Proxy.call(claimAndBridgeBack) -> consumes L1 entry #1
        //           entry #1 calls[0]: claimAndBridgeBack on executorL2
        //             -> NFT claim + burn wrapped via bridgeL2 (consumes L2 entry #0)
        //           entry #1 calls[1]: receiveTokens on bridgeL1 (release tokens to executorL1)
        //       (c) repay flash loan

        // ── Compute all action hashes ──

        // L1 Entry #0: bridgeTokens proxy call
        //   bridgeL1._bridgeAddress() = bridgeL2
        //   proxy(bridgeL2, L2) on L1
        //   sourceAddress = executorL1 (bridgeL1 calls the proxy from within bridgeTokens)
        //
        //   Wait: bridgeL1 itself calls bridgeProxy.call(...), so msg.sender at proxy = bridgeL1.
        //   executeL1ToL2Call(sourceAddress=bridgeL1, callData=receiveTokensCalldata_bridge)
        //   proxyInfo: (bridgeL2, L2)
        //   crossChainCallHash = hash(L2, bridgeL2, 0, calldata, bridgeL1, MAINNET)

        bytes memory bridgeReceiveCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (
                address(token),
                MAINNET_ROLLUP_ID,
                address(executorL2),
                10_000e18,
                "Test Token",
                "TT",
                18,
                MAINNET_ROLLUP_ID
            )
        );

        bytes32 l1Entry0ActionHash = _crossChainCallHash(
            L2_ROLLUP_ID, address(bridgeL2), 0, bridgeReceiveCalldata, address(bridgeL1), MAINNET_ROLLUP_ID
        );

        // L1 Entry #1: executorL2Proxy.call(claimAndBridgeBack)
        //   msg.sender at proxy = executorL1 (executorL1 calls executorL2Proxy from onFlashLoan)
        //   executeL1ToL2Call(sourceAddress=executorL1, callData=claimAndBridgeBackCalldata)
        //   proxyInfo: (executorL2, L2)
        //   crossChainCallHash = hash(L2, executorL2, 0, calldata, executorL1, MAINNET)

        bytes memory claimAndBridgeBackCalldata = abi.encodeCall(
            FlashLoanBridgeExecutor.claimAndBridgeBack,
            (wrappedTokenL2, address(nftL2), address(bridgeL2), MAINNET_ROLLUP_ID, address(executorL1))
        );

        bytes32 l1Entry1ActionHash = _crossChainCallHash(
            L2_ROLLUP_ID, address(executorL2), 0, claimAndBridgeBackCalldata, address(executorL1), MAINNET_ROLLUP_ID
        );

        // L2 Entry #0: consumed by bridgeL2.bridgeTokens inside claimAndBridgeBack
        //   bridgeL2.bridgeTokens calls proxy(bridgeL1, MAINNET) on L2
        //   msg.sender at L2 proxy = bridgeL2
        //   managerL2.executeL1ToL2Call(bridgeL2, retReceiveCalldata)
        //   proxyInfo: (bridgeL1, MAINNET)
        //   crossChainCallHash = hash(MAINNET, bridgeL1, 0, retReceiveCalldata, bridgeL2, L2)

        bytes memory retReceiveCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (address(token), MAINNET_ROLLUP_ID, address(executorL1), 10_000e18, "Test Token", "TT", 18, L2_ROLLUP_ID)
        );

        bytes32 l2Entry0ActionHash = _crossChainCallHash(
            MAINNET_ROLLUP_ID, address(bridgeL1), 0, retReceiveCalldata, address(bridgeL2), L2_ROLLUP_ID
        );

        // ── Compute rolling hashes ──

        // L1 Entry #0: no calls -> rollingHash = 0
        // (already default)

        // L1 Entry #1: 2 calls
        //   Call 0 (callNumber=1): claimAndBridgeBack on executorL2 -> void -> success=true, retData=""
        //   Call 1 (callNumber=2): receiveTokens on bridgeL1 -> void -> success=true, retData=""
        bytes32 l1Entry1RollingHash;
        {
            bytes32 h = bytes32(0);
            // Call 0
            h = keccak256(abi.encodePacked(h, CALL_BEGIN, uint256(1)));
            h = keccak256(abi.encodePacked(h, CALL_END, uint256(1), true, bytes("")));
            // Call 1
            h = keccak256(abi.encodePacked(h, CALL_BEGIN, uint256(2)));
            h = keccak256(abi.encodePacked(h, CALL_END, uint256(2), true, bytes("")));
            l1Entry1RollingHash = h;
        }

        // ── Build L1 Entry #1 calls ──
        L2ToL1Call[] memory l1Entry1Calls = new L2ToL1Call[](2);

        // Call 0: execute claimAndBridgeBack on executorL2
        //   sourceProxy = rollups.proxy(executorL2, L2)
        //   Since msg.sender=EEZ (manager), proxy calls executorL2.claimAndBridgeBack(...)
        l1Entry1Calls[0] = L2ToL1Call({
            targetAddress: address(executorL2),
            value: 0,
            data: claimAndBridgeBackCalldata,
            sourceAddress: address(executorL2),
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });

        // Call 1: release tokens to executorL1 via receiveTokens on bridgeL1
        //   sourceProxy = rollups.proxy(bridgeL2, L2)
        //   proxy calls bridgeL1.receiveTokens(...)
        //   bridgeL1.onlyBridgeProxy(L2): checks msg.sender == rollups.proxy(bridgeL2, L2) -> MATCH
        l1Entry1Calls[1] = L2ToL1Call({
            targetAddress: address(bridgeL1),
            value: 0,
            data: retReceiveCalldata,
            sourceAddress: address(bridgeL2),
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });

        // ── New block for postAndVerifyBatch ──
        vm.roll(block.number + 1);

        // ── Load L2 execution table (must be same block as L1 execution) ──
        {
            ExecutionEntry[] memory l2Entries = new ExecutionEntry[](1);
            l2Entries[0].stateDeltas = new StateDelta[](0);
            l2Entries[0].proxyEntryHash = l2Entry0ActionHash;
            // No calls, returnData = "", rollingHash = 0

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(l2Entries, _noLookupCalls());
        }

        // ── Post L1 batch ──

        bytes32 s2 = keccak256("l2-state-after-flash-loan-bridge");
        bytes32 s3 = keccak256("l2-state-after-flash-loan-complete");

        {
            ExecutionEntry[] memory l1Entries = new ExecutionEntry[](2);

            // Entry #0: bridgeTokens proxy call (no calls, simple state delta)
            StateDelta[] memory deltas0 = new StateDelta[](1);
            deltas0[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});
            l1Entries[0].stateDeltas = deltas0;
            l1Entries[0].proxyEntryHash = l1Entry0ActionHash;
            l1Entries[0].destinationRollupId = L2_ROLLUP_ID;
            // calls[], nestedActions[], callCount, returnData, rollingHash all default (empty/zero)

            // Entry #1: executorL2Proxy call (with calls to claimAndBridgeBack + receiveTokens)
            StateDelta[] memory deltas1 = new StateDelta[](1);
            deltas1[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s2, newState: s3, etherDelta: 0});
            l1Entries[1].stateDeltas = deltas1;
            l1Entries[1].proxyEntryHash = l1Entry1ActionHash;
            l1Entries[1].destinationRollupId = L2_ROLLUP_ID;
            l1Entries[1].L2ToL1Calls = l1Entry1Calls;
            l1Entries[1].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
            l1Entries[1].callCount = 2;
            l1Entries[1].returnData = "";
            l1Entries[1].rollingHash = l1Entry1RollingHash;

            _postBatchToL2(l1Entries, 0);
        }

        // ── Pre-flash-loan state ──
        uint256 flashLoanPoolBalanceBefore = token.balanceOf(address(flashLoanPool));
        assertEq(flashLoanPoolBalanceBefore, 10_000e18, "Flash loan pool should have 10,000 tokens");

        // ── Execute the flash loan ──
        executorL1.execute();

        // ── Assertions ──

        // Flash loan pool should be whole (no fee in this implementation)
        assertEq(
            token.balanceOf(address(flashLoanPool)),
            10_000e18,
            "Flash loan pool should still have 10,000 tokens after repayment"
        );

        // NFT should be minted to executorL2
        assertEq(nftL2.balanceOf(address(executorL2)), 1, "executorL2 should own 1 NFT");
        assertTrue(nftL2.hasClaimed(address(executorL2)), "executorL2 should be marked as claimed");

        // Wrapped tokens burned on L2
        assertEq(
            WrappedToken(wrappedTokenL2).balanceOf(address(executorL2)),
            0,
            "executorL2 wrapped token balance should be 0"
        );

        // bridgeL1 token balance: 10,000 (Phase 1) + 10,000 (Phase 2 bridge) - 10,000 (released) = 10,000
        assertEq(
            token.balanceOf(address(bridgeL1)),
            10_000e18,
            "bridgeL1 should have 10,000 tokens locked (Phase 2 bridge unreturned)"
        );

        // L2 rollup state updated
        assertEq(_getRollupState(L2_ROLLUP_ID), s3, "L2 state should be updated to s3");

        // Execution entries consumed
        assertEq(rollups.queueCursor(L2_ROLLUP_ID), 2, "Both L1 entries should be consumed");
        assertEq(managerL2.executionIndex(), 1, "L2 entry should be consumed");
    }
}
