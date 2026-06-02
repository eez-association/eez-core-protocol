// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestToken is ERC20 {
    constructor() ERC20("Test Token", "TT") {
        _mint(msg.sender, 10000e18);
    }
}

/// @title IntegrationTestBridge
/// @notice End-to-end tests of L1 <-> L2 bridging flows for ETH and ERC20 tokens
///
/// Adapted to the new flat-calls + rolling-hash execution model:
///   - ExecutionEntry now has: calls[], nestedActions[], callCount, returnData, failed, rollingHash
///   - StateDelta no longer has currentState
///   - crossChainCallHash = keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup))
///   - Rolling hash computed with tagged events: CALL_BEGIN(1), CALL_END(2), NESTED_BEGIN(3), NESTED_END(4)
///   - No executeIncomingCrossChainCall on L2 -- all entries consumed via proxy calls
///   - executeL2TX() takes no args on L1
///   - postAndVerifyBatch takes (entries, staticCalls, transientCount, transientLookupCallCount, blobCount, callData, proof)
///   - loadExecutionTable takes (entries, staticCalls)
///
/// ┌────┬───────────────────────────────────────┬──────────┬──────────────────┐
/// │  # │ Flow                                  │ Direction│ Asset            │
/// ├────┼───────────────────────────────────────┼──────────┼──────────────────┤
/// │  1 │ Alice bridges 1 ETH to herself        │ L1 → L2  │ Ether            │
/// │  2 │ Alice bridges 100 tokens to herself   │ L1 → L2  │ ERC20            │
/// │  3 │ Alice bridges tokens then back again  │ L1→L2→L1 │ ERC20 roundtrip  │
/// └────┴───────────────────────────────────────┴──────────┴──────────────────┘
contract IntegrationTestBridge is Test {
    // ── L1 contracts ──
    EEZ public rollups;
    MockProofSystem public ps;
    Rollup public l2Manager;

    // ── L2 contracts ──
    EEZL2 public managerL2;

    // ── Bridge contracts ──
    Bridge public bridgeL1;
    Bridge public bridgeL2;

    // ── Test token ──
    TestToken public token;

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

    address public alice = makeAddr("alice");

    function setUp() public {
        // ── L1 infrastructure ──
        rollups = new EEZ();
        ps = new MockProofSystem();

        // registerRollup skips id 0 (MAINNET_ROLLUP_ID), so the first registered rollup
        // lands at id 1 = L2_ROLLUP_ID.
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
        bridgeL2.setCanonicalBridgeAddress(address(bridgeL1));

        // ── Token setup ──
        token = new TestToken();
        token.transfer(alice, 1000e18);

        // ── Fund alice ──
        vm.deal(alice, 10 ether);
    }

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

    /// @dev Computes rolling hash for a sequence of calls (no nesting)
    /// Each call: CALL_BEGIN(callNumber) then CALL_END(callNumber, success, retData)
    /// @param calls The calls in the entry
    /// @param successes Whether each call succeeds
    /// @param retDatas The return data from each call
    function _computeRollingHash(L2ToL1Call[] memory calls, bool[] memory successes, bytes[] memory retDatas)
        internal
        pure
        returns (bytes32 hash)
    {
        hash = bytes32(0);
        for (uint256 i = 0; i < calls.length; i++) {
            uint256 callNumber = i + 1; // 1-indexed
            hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, callNumber));
            hash = keccak256(abi.encodePacked(hash, CALL_END, callNumber, successes[i], retDatas[i]));
        }
    }

    /// @dev Helper to create an empty LookupCall array
    function _noLookupCalls() internal pure returns (LookupCall[] memory) {
        return new LookupCall[](0);
    }

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
            blockNumber: 0,
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

    // ═══════════════════════════════════════════════════════════════════════
    //  Test 1: Alice bridges 1 ETH from L1 to L2
    //
    //  Phase 1 (L1):
    //    Alice calls bridgeL1.bridgeEther{value: 1 ether}(L2_ROLLUP_ID, alice)
    //    → Bridge creates proxy for (alice, L2_ROLLUP_ID) on L1
    //    → proxy.call{value: 1 ether}("") → proxy fallback
    //    → EEZ.executeL1ToL2Call(bridgeL1, "") with 1 ether
    //    → crossChainCallHash matches deferred entry → state delta applied → returnData="" returned
    //
    //  Phase 2 (L2):
    //    System loads execution table with entry containing ETH delivery call.
    //    Alice triggers by calling proxy(bridgeL1, MAINNET) on L2.
    //    Entry's calls[] send 1 ETH to alice via proxy(bridgeL1, MAINNET).
    // ═══════════════════════════════════════════════════════════════════════

    function test_BridgeEther_L1toL2() public {
        // ════════════════════════════════════════════
        //  Phase 1: L1 — Alice bridges 1 ether via bridgeL1
        // ════════════════════════════════════════════

        // The crossChainCallHash that executeL1ToL2Call will compute when bridgeL1 calls
        // proxy(alice, L2_ROLLUP_ID) on L1:
        //   proxyInfo: originalAddress=alice, originalRollupId=L2_ROLLUP_ID
        //   crossChainCallHash = keccak256(abi.encode(L2_ROLLUP_ID, alice, 1 ether, "", bridgeL1, MAINNET_ROLLUP_ID))
        bytes32 l1ActionHash =
            _crossChainCallHash(L2_ROLLUP_ID, alice, 1 ether, "", address(bridgeL1), MAINNET_ROLLUP_ID);

        bytes32 newState = keccak256("l2-state-after-ether-bridge");

        // L1 deferred entry: no calls (simple hash resolution), returnData = ""
        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: L2_ROLLUP_ID,
                currentState: keccak256("l2-initial-state"),
                newState: newState,
                etherDelta: 1 ether
            });

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = stateDeltas;
            entries[0].proxyEntryHash = l1ActionHash;
            entries[0].destinationRollupId = L2_ROLLUP_ID;
            // calls[] empty, nestedActions[] empty, callCount=0, returnData="", rollingHash=0
            // (all default zero values)

            _postBatchToL2(entries, 0);
        }

        // Alice triggers the bridge
        uint256 aliceL1BalanceBefore = alice.balance;
        vm.prank(alice);
        bridgeL1.bridgeEther{value: 1 ether}(L2_ROLLUP_ID, alice);

        assertEq(alice.balance, aliceL1BalanceBefore - 1 ether, "Alice L1 balance should decrease by 1 ether");
        assertEq(_getRollupState(L2_ROLLUP_ID), newState, "L2 rollup state should be updated");

        // ════════════════════════════════════════════
        //  Phase 2: L2 — Deliver 1 ether to alice
        // ════════════════════════════════════════════
        //
        //  The execution entry on L2 contains a call that sends 1 ETH to alice
        //  via proxy(bridgeL1, MAINNET). The entry is triggered by alice calling
        //  proxy(bridgeL1, MAINNET) on L2.
        //
        //  Trigger call: alice calls proxy(bridgeL1, MAINNET) with empty data
        //    → proxy fallback → executeL1ToL2Call(alice, "")
        //    → crossChainCallHash = keccak256(abi.encode(MAINNET, bridgeL1, 0, "", alice, L2))
        //    → entry consumed → calls[] execute → alice receives 1 ETH

        // Create proxy for (bridgeL1, MAINNET) on L2
        address proxyBridgeL1OnL2 = managerL2.createCrossChainProxy(address(bridgeL1), MAINNET_ROLLUP_ID);

        // Fund managerL2 with ETH for the delivery
        vm.deal(address(managerL2), 1 ether);

        // Build the L2 execution entry
        bytes32 l2TriggerHash = _crossChainCallHash(MAINNET_ROLLUP_ID, address(bridgeL1), 0, "", alice, L2_ROLLUP_ID);

        L2ToL1Call[] memory l2Calls = new L2ToL1Call[](1);
        l2Calls[0] = L2ToL1Call({
            targetAddress: alice,
            value: 1 ether,
            data: "",
            sourceAddress: address(bridgeL1),
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        // Compute rolling hash for the single call
        // Call sends 1 ETH to alice (EOA) → success=true, retData=""
        bool[] memory successes = new bool[](1);
        successes[0] = true;
        bytes[] memory retDatas = new bytes[](1);
        retDatas[0] = "";
        bytes32 l2RollingHash = _computeRollingHash(l2Calls, successes, retDatas);

        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].proxyEntryHash = l2TriggerHash;
            entries[0].L2ToL1Calls = l2Calls;
            entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
            entries[0].callCount = 1;
            entries[0].returnData = "";
            entries[0].rollingHash = l2RollingHash;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries, _noLookupCalls());
        }

        uint256 aliceBalanceBefore = alice.balance;

        // Alice triggers the L2 delivery by calling proxy(bridgeL1, MAINNET)
        vm.prank(alice);
        (bool success,) = proxyBridgeL1OnL2.call("");
        assertTrue(success, "L2 trigger call should succeed");

        assertEq(alice.balance, aliceBalanceBefore + 1 ether, "Alice should receive 1 ether on L2");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test 2: Alice bridges 100 tokens from L1 to L2
    //
    //  Phase 1 (L1):
    //    Alice calls bridgeL1.bridgeTokens(token, 100e18, L2_ROLLUP_ID, alice)
    //    → Bridge locks tokens, creates proxy for (bridgeL1, L2_ROLLUP_ID) on L1
    //    → proxy.call(receiveTokensCalldata) → proxy fallback
    //    → EEZ.executeL1ToL2Call(bridgeL1, receiveTokensCalldata)
    //    → crossChainCallHash matches → state delta → returnData="" → done
    //
    //  Phase 2 (L2):
    //    System loads execution table with entry containing receiveTokens call.
    //    Alice triggers by calling proxy(bridgeL1, MAINNET) on L2.
    //    Entry's calls[] route receiveTokens to bridgeL2 via proxy(bridgeL1, MAINNET).
    //    bridgeL2 deploys WrappedToken, mints 100e18 to alice.
    // ═══════════════════════════════════════════════════════════════════════

    function test_BridgeTokens_L1toL2() public {
        // receiveTokens calldata: same encoding on both L1 and L2
        bytes memory receiveTokensCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (address(token), MAINNET_ROLLUP_ID, alice, 100e18, "Test Token", "TT", 18, MAINNET_ROLLUP_ID)
        );

        // ════════════════════════════════════════════
        //  Phase 1: L1 — Alice bridges tokens via bridgeL1
        // ════════════════════════════════════════════

        // bridgeL1._bridgeAddress() = bridgeL1 (no canonical override)
        // Bridge creates proxy for (bridgeL1, L2_ROLLUP_ID) on L1
        // proxy.call(receiveTokensCalldata) from bridgeL1
        // proxyInfo: originalAddress=bridgeL1, originalRollupId=L2_ROLLUP_ID
        // crossChainCallHash = keccak256(abi.encode(L2_ROLLUP_ID, bridgeL1, 0, calldata, bridgeL1, MAINNET))
        bytes32 l1ActionHash = _crossChainCallHash(
            L2_ROLLUP_ID, address(bridgeL1), 0, receiveTokensCalldata, address(bridgeL1), MAINNET_ROLLUP_ID
        );

        bytes32 newState = keccak256("l2-state-after-token-bridge");

        // L1 deferred entry: no calls, just hash resolution
        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: L2_ROLLUP_ID, currentState: keccak256("l2-initial-state"), newState: newState, etherDelta: 0
            });

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = stateDeltas;
            entries[0].proxyEntryHash = l1ActionHash;
            entries[0].destinationRollupId = L2_ROLLUP_ID;

            _postBatchToL2(entries, 0);
        }

        // Alice approves and bridges tokens
        vm.prank(alice);
        token.approve(address(bridgeL1), 100e18);

        vm.prank(alice);
        bridgeL1.bridgeTokens(address(token), 100e18, L2_ROLLUP_ID, alice);

        assertEq(token.balanceOf(address(bridgeL1)), 100e18, "Bridge should hold 100e18 locked tokens");
        assertEq(token.balanceOf(alice), 900e18, "Alice should have 900e18 tokens remaining");
        assertEq(_getRollupState(L2_ROLLUP_ID), newState, "L2 rollup state should be updated");

        // ════════════════════════════════════════════
        //  Phase 2: L2 — Deliver wrapped tokens to alice
        // ════════════════════════════════════════════
        //
        //  Entry contains a call that routes receiveTokens to bridgeL2
        //  via proxy(bridgeL1, MAINNET). bridgeL2.receiveTokens deploys
        //  WrappedToken and mints 100e18 to alice.
        //
        //  Trigger: alice calls proxy(bridgeL1, MAINNET) on L2 with empty data
        //    → executeL1ToL2Call(alice, "") → entry consumed

        // Create proxy for (bridgeL1, MAINNET) on L2
        address proxyBridgeL1OnL2 = managerL2.createCrossChainProxy(address(bridgeL1), MAINNET_ROLLUP_ID);

        // Trigger crossChainCallHash
        bytes32 l2TriggerHash = _crossChainCallHash(MAINNET_ROLLUP_ID, address(bridgeL1), 0, "", alice, L2_ROLLUP_ID);

        // Entry's calls: route receiveTokens to bridgeL2 via proxy(bridgeL1, MAINNET)
        L2ToL1Call[] memory l2Calls = new L2ToL1Call[](1);
        l2Calls[0] = L2ToL1Call({
            targetAddress: address(bridgeL2),
            value: 0,
            data: receiveTokensCalldata,
            sourceAddress: address(bridgeL1),
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        // Compute rolling hash: receiveTokens returns void → success=true, retData=""
        bool[] memory successes = new bool[](1);
        successes[0] = true;
        bytes[] memory retDatas = new bytes[](1);
        retDatas[0] = "";
        bytes32 l2RollingHash = _computeRollingHash(l2Calls, successes, retDatas);

        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].proxyEntryHash = l2TriggerHash;
            entries[0].L2ToL1Calls = l2Calls;
            entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
            entries[0].callCount = 1;
            entries[0].returnData = "";
            entries[0].rollingHash = l2RollingHash;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries, _noLookupCalls());
        }

        // Trigger L2 delivery
        vm.prank(alice);
        (bool success,) = proxyBridgeL1OnL2.call("");
        assertTrue(success, "L2 trigger call should succeed");

        // Assert wrapped token was deployed and minted
        address wrappedAddr = bridgeL2.getWrappedToken(address(token), MAINNET_ROLLUP_ID);
        assertTrue(wrappedAddr != address(0), "Wrapped token should be deployed on L2");
        assertEq(WrappedToken(wrappedAddr).balanceOf(alice), 100e18, "Alice should have 100e18 wrapped tokens");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Test 3: Alice bridges 100 tokens L1→L2, then bridges them back L2→L1
    //
    //  Round-trip: lock on L1 → mint wrapped on L2 → burn wrapped on L2 → release on L1
    //
    //  Phase 1 (L1): Lock tokens — deferred entry consumed by bridgeTokens call
    //  Phase 2 (L2): Mint wrapped — entry with calls[] delivering receiveTokens
    //  Phase 3 (L2): Burn wrapped — entry consumed by bridgeTokens proxy call
    //  Phase 4 (L1): Release tokens — entry with calls[] delivering receiveTokens to bridgeL1
    // ═══════════════════════════════════════════════════════════════════════

    function test_BridgeTokens_Roundtrip() public {
        // Cross-reference canonical addresses so onlyBridgeProxy works in both directions
        bridgeL1.setCanonicalBridgeAddress(address(bridgeL2));
        // bridgeL2 already has bridgeL1 set as canonical from setUp

        // ════════════════════════════════════════════
        //  Phase 1: L1 — Lock tokens
        // ════════════════════════════════════════════
        //
        //  bridgeL1._bridgeAddress() = bridgeL2 (canonical override set above)
        //  Bridge creates proxy for (bridgeL2, L2_ROLLUP_ID) on L1
        //  proxy.call(receiveTokensCalldata) from bridgeL1
        //  proxyInfo: originalAddress=bridgeL2, originalRollupId=L2_ROLLUP_ID
        //  crossChainCallHash = keccak256(abi.encode(L2_ROLLUP_ID, bridgeL2, 0, calldata, bridgeL1, MAINNET))

        bytes memory fwdCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (address(token), MAINNET_ROLLUP_ID, alice, 100e18, "Test Token", "TT", 18, MAINNET_ROLLUP_ID)
        );

        bytes32 fwdActionHash =
            _crossChainCallHash(L2_ROLLUP_ID, address(bridgeL2), 0, fwdCalldata, address(bridgeL1), MAINNET_ROLLUP_ID);

        bytes32 s1 = keccak256("l2-state-after-roundtrip-fwd");

        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: L2_ROLLUP_ID, currentState: keccak256("l2-initial-state"), newState: s1, etherDelta: 0
            });

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = stateDeltas;
            entries[0].proxyEntryHash = fwdActionHash;
            entries[0].destinationRollupId = L2_ROLLUP_ID;

            _postBatchToL2(entries, 0);
        }

        vm.prank(alice);
        token.approve(address(bridgeL1), 100e18);

        vm.prank(alice);
        bridgeL1.bridgeTokens(address(token), 100e18, L2_ROLLUP_ID, alice);

        assertEq(token.balanceOf(address(bridgeL1)), 100e18, "Phase 1: bridgeL1 should hold locked tokens");
        assertEq(token.balanceOf(alice), 900e18, "Phase 1: alice should have 900e18 tokens");
        assertEq(_getRollupState(L2_ROLLUP_ID), s1, "Phase 1: L2 state should be S1");

        // ════════════════════════════════════════════
        //  Phase 2: L2 — Mint wrapped tokens
        // ════════════════════════════════════════════
        //
        //  Entry's calls[] route receiveTokens to bridgeL2 via proxy(bridgeL1, MAINNET).
        //  onlyBridgeProxy(MAINNET): proxy for (_bridgeAddress()=bridgeL1, MAINNET) ✓
        //  Foreign token → deploys WrappedToken, mints to alice.
        //
        //  Trigger: alice calls proxy(bridgeL1, MAINNET) on L2 with empty data.

        address proxyBridgeL1OnL2 = managerL2.createCrossChainProxy(address(bridgeL1), MAINNET_ROLLUP_ID);

        bytes32 l2FwdTriggerHash = _crossChainCallHash(MAINNET_ROLLUP_ID, address(bridgeL1), 0, "", alice, L2_ROLLUP_ID);

        L2ToL1Call[] memory fwdL2Calls = new L2ToL1Call[](1);
        fwdL2Calls[0] = L2ToL1Call({
            targetAddress: address(bridgeL2),
            value: 0,
            data: fwdCalldata,
            sourceAddress: address(bridgeL1),
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        bool[] memory fwdSuccesses = new bool[](1);
        fwdSuccesses[0] = true;
        bytes[] memory fwdRetDatas = new bytes[](1);
        fwdRetDatas[0] = "";
        bytes32 fwdL2RollingHash = _computeRollingHash(fwdL2Calls, fwdSuccesses, fwdRetDatas);

        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].proxyEntryHash = l2FwdTriggerHash;
            entries[0].L2ToL1Calls = fwdL2Calls;
            entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
            entries[0].callCount = 1;
            entries[0].returnData = "";
            entries[0].rollingHash = fwdL2RollingHash;

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries, _noLookupCalls());
        }

        vm.prank(alice);
        (bool success,) = proxyBridgeL1OnL2.call("");
        assertTrue(success, "Phase 2: L2 trigger call should succeed");

        address wrappedAddr = bridgeL2.getWrappedToken(address(token), MAINNET_ROLLUP_ID);
        assertTrue(wrappedAddr != address(0), "Phase 2: wrapped token should be deployed");
        assertEq(WrappedToken(wrappedAddr).balanceOf(alice), 100e18, "Phase 2: alice should have 100e18 wrapped");

        // ════════════════════════════════════════════
        //  Phase 3: L2 — Burn wrapped tokens (bridgeTokens back to L1)
        // ════════════════════════════════════════════
        //
        //  Alice calls bridgeL2.bridgeTokens(wrappedToken, 100e18, MAINNET_ROLLUP_ID, alice)
        //    → Burns wrapped tokens
        //    → bridgeL2._bridgeAddress() = bridgeL1 (canonical override)
        //    → Creates/finds proxy for (bridgeL1, MAINNET) on L2
        //    → proxy.call(retCalldata) from bridgeL2
        //    → executeL1ToL2Call(bridgeL2, retCalldata) with value=0
        //    → proxyInfo: originalAddress=bridgeL1, originalRollupId=MAINNET
        //    → crossChainCallHash = keccak256(abi.encode(MAINNET, bridgeL1, 0, retCalldata, bridgeL2, L2))
        //    → Entry consumed → returnData="" → done

        bytes memory retCalldata = abi.encodeCall(
            Bridge.receiveTokens,
            (address(token), MAINNET_ROLLUP_ID, alice, 100e18, "Test Token", "TT", 18, L2_ROLLUP_ID)
        );

        bytes32 retActionHash =
            _crossChainCallHash(MAINNET_ROLLUP_ID, address(bridgeL1), 0, retCalldata, address(bridgeL2), L2_ROLLUP_ID);

        {
            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = new StateDelta[](0);
            entries[0].proxyEntryHash = retActionHash;
            // No calls (simple resolution), no rolling hash needed

            vm.prank(SYSTEM_ADDRESS);
            managerL2.loadExecutionTable(entries, _noLookupCalls());
        }

        vm.prank(alice);
        bridgeL2.bridgeTokens(wrappedAddr, 100e18, MAINNET_ROLLUP_ID, alice);

        assertEq(WrappedToken(wrappedAddr).balanceOf(alice), 0, "Phase 3: alice wrapped balance should be 0");

        // ════════════════════════════════════════════
        //  Phase 4: L1 — Release tokens via executeL2TX
        // ════════════════════════════════════════════
        //
        //  executeL2TX() consumes the next entry with crossChainCallHash == bytes32(0).
        //  The entry's calls[] route receiveTokens to bridgeL1 via proxy(bridgeL2, L2).
        //  bridgeL1.receiveTokens → onlyBridgeProxy(L2): proxy for (_bridgeAddress()=bridgeL2, L2) ✓
        //  originalRollupId(MAINNET) == rollupId(MAINNET) → native → release tokens to alice

        vm.roll(block.number + 1); // new block for postAndVerifyBatch

        bytes32 s2 = keccak256("l2-state-after-roundtrip-ret");

        // The call inside the entry: proxy(bridgeL2, L2).executeOnBehalf(bridgeL1, retCalldata)
        L2ToL1Call[] memory retL1Calls = new L2ToL1Call[](1);
        retL1Calls[0] = L2ToL1Call({
            targetAddress: address(bridgeL1),
            value: 0,
            data: retCalldata,
            sourceAddress: address(bridgeL2),
            sourceRollupId: L2_ROLLUP_ID,
            revertSpan: 0
        });

        // Compute rolling hash: receiveTokens returns void → success=true, retData=""
        bool[] memory retSuccesses = new bool[](1);
        retSuccesses[0] = true;
        bytes[] memory retRetDatas = new bytes[](1);
        retRetDatas[0] = "";
        bytes32 retRollingHash = _computeRollingHash(retL1Calls, retSuccesses, retRetDatas);

        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({rollupId: L2_ROLLUP_ID, currentState: s1, newState: s2, etherDelta: 0});

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0].stateDeltas = stateDeltas;
            entries[0].proxyEntryHash = bytes32(0); // immediate / L2TX
            entries[0].destinationRollupId = L2_ROLLUP_ID;
            entries[0].L2ToL1Calls = retL1Calls;
            entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
            entries[0].callCount = 1;
            entries[0].returnData = "";
            entries[0].rollingHash = retRollingHash;

            _postBatchToL2(entries, 1);
        }

        // The immediate entry (crossChainCallHash==0) was already executed during postAndVerifyBatch.
        // Tokens should be released to alice.

        // ── Final assertions ──
        assertEq(token.balanceOf(alice), 1000e18, "Roundtrip: alice should have all 1000e18 tokens back");
        assertEq(token.balanceOf(address(bridgeL1)), 0, "Roundtrip: bridgeL1 should have 0 locked tokens");
        assertEq(WrappedToken(wrappedAddr).balanceOf(alice), 0, "Roundtrip: alice wrapped balance should be 0");
        assertEq(_getRollupState(L2_ROLLUP_ID), s2, "Roundtrip: L2 state should be S2");
    }
}
