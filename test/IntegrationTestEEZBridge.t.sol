// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.t.sol";
import {ExecutionEntry, RollupUpdate, L2ToL1Call, ExpectedL1ToL2Call} from "../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2Entry, CrossChainCall, ExpectedOutgoingCrossChainCall} from "../src/interfaces/IEEZL2.sol";
import {Bridge} from "../src/periphery/Bridge.sol";
import {EEZBridge} from "../src/periphery/EEZBridge.sol";
import {EEZBridgedToken} from "../src/periphery/EEZBridgedToken.sol";
import {EEZToken} from "../src/periphery/defiMock/EEZToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Paired L1/L2 execution using real managers, bridges and authenticated proxies.
/// @dev Only proofs use IntegrationBase's test proof system. No manager calls are
/// mocked and no remote proxy is impersonated. Each L1-origin call is delivered
/// through executeIncomingCrossChainCall with the identical call identity.
contract IntegrationTestEEZBridge is IntegrationBase {
    EEZBridge internal bridgeL1;
    EEZBridge internal bridgeL2;
    EEZToken internal token;
    EEZBridgedToken internal wrapped;
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    function setUp() public override {
        super.setUp();
        bridgeL1 = new EEZBridge(address(rollups), MAINNET_ROLLUP_ID, address(this));
        bridgeL2 = new EEZBridge(address(managerL2), L2_ROLLUP_ID, address(this));
        bridgeL1.setCanonicalBridgeAddress(address(bridgeL2));
        bridgeL2.setCanonicalBridgeAddress(address(bridgeL1));
        token = new EEZToken(address(rollups), "Original", "ORG", alice, 1000 ether);
    }

    function test_lockMintTransferApproveBurnReleaseRoundTrip() public {
        _bridgeOut(alice, 100 ether);
        assertEq(wrapped.BRIDGE(), address(bridgeL2));
        assertEq(address(wrapped.EEZContract()), address(managerL2));
        assertEq(wrapped.name(), token.name());
        assertEq(wrapped.symbol(), token.symbol());
        assertEq(wrapped.decimals(), token.decimals());
        assertEq(token.balanceOf(alice), 900 ether);
        assertEq(wrapped.balanceOf(alice), 100 ether);
        _assertBacking(100 ether);

        vm.startPrank(alice);
        assertTrue(wrapped.transfer(bob, 10 ether));
        assertTrue(wrapped.approve(spender, 40 ether));
        vm.stopPrank();
        vm.prank(spender);
        assertTrue(wrapped.transferFrom(alice, bob, 30 ether));
        assertEq(wrapped.balanceOf(alice), 60 ether);
        assertEq(wrapped.balanceOf(bob), 40 ether);
        assertEq(wrapped.allowance(alice, spender), 10 ether);
        _assertBacking(100 ether);

        _bridgeBack(bob, 40 ether);
        assertEq(token.balanceOf(bob), 40 ether);
        assertEq(wrapped.balanceOf(bob), 0);
        _assertBacking(60 ether);
        _bridgeBack(alice, 60 ether);
        assertEq(token.balanceOf(alice), 960 ether);
        assertEq(wrapped.balanceOf(alice), 0);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), token.totalSupply());
        _assertBacking(0);
    }

    function test_remoteTransfersAndAllowancesUseRealProxyExecution() public {
        address aliceProxy = managerL2.computeCrossChainProxyAddress(alice, MAINNET_ROLLUP_ID);
        address bobProxy = managerL2.computeCrossChainProxyAddress(bob, MAINNET_ROLLUP_ID);
        address spenderProxy = managerL2.computeCrossChainProxyAddress(spender, MAINNET_ROLLUP_ID);
        _bridgeOut(aliceProxy, 100 ether);

        _remoteTokenCall(alice, abi.encodeCall(IERC20.transfer, (bob, 10 ether)));
        _remoteTokenCall(alice, abi.encodeCall(IERC20.approve, (spender, 40 ether)));
        _remoteTokenCall(spender, abi.encodeCall(IERC20.transferFrom, (alice, bob, 30 ether)));
        assertEq(wrapped.balanceOf(aliceProxy), 60 ether);
        assertEq(wrapped.balanceOf(bobProxy), 40 ether);
        assertEq(wrapped.balanceOf(alice), 0);
        assertEq(wrapped.balanceOf(bob), 0);
        assertEq(wrapped.allowance(aliceProxy, spenderProxy), 10 ether);
        assertGt(aliceProxy.code.length, 0);
        assertGt(spenderProxy.code.length, 0);
        _assertBacking(100 ether);

        // A local account with the same address as the remote spender has no authority.
        vm.expectRevert();
        vm.prank(spender);
        wrapped.transferFrom(aliceProxy, bob, 1 ether);
        assertEq(wrapped.balanceOf(aliceProxy), 60 ether);
        _assertBacking(100 ether);
    }

    function _assertBacking(uint256 amount) private view {
        assertEq(token.balanceOf(address(bridgeL1)), amount, "L1 escrow");
        assertEq(wrapped.totalSupply(), amount, "L2 supply must match escrow");
        assertEq(wrapped.balanceOf(address(bridgeL2)), 0, "return path burns instead of locking");
    }

    function _payload(address recipient, uint256 amount, uint64 sourceRollup) private view returns (bytes memory) {
        return abi.encodeCall(
            Bridge.receiveTokens,
            (address(token), MAINNET_ROLLUP_ID, recipient, amount, "Original", "ORG", 18, sourceRollup)
        );
    }

    function _bridgeOut(address recipient, uint256 amount) private {
        bytes memory data = _payload(recipient, amount, MAINNET_ROLLUP_ID);
        bytes32 hash = _ccHash(false, address(bridgeL1), MAINNET_ROLLUP_ID, address(bridgeL2), L2_ROLLUP_ID, 0, data);
        _prepareL1Call(hash, "");
        vm.startPrank(alice);
        token.approve(address(bridgeL1), amount);
        bridgeL1.bridgeTokens(address(token), amount, L2_ROLLUP_ID, recipient);
        vm.stopPrank();
        _deliverToL2(address(bridgeL1), address(bridgeL2), data, "", hash);
        wrapped = EEZBridgedToken(bridgeL2.getWrappedToken(address(token), MAINNET_ROLLUP_ID));
        assertTrue(address(wrapped) != address(0));
    }

    function _remoteTokenCall(address user, bytes memory data) private {
        bytes memory returned = abi.encode(true);
        bytes32 hash = _ccHash(false, user, MAINNET_ROLLUP_ID, address(wrapped), L2_ROLLUP_ID, 0, data);
        _prepareL1Call(hash, returned);
        address proxy = rollups.getOrCreateCrossChainProxy(address(wrapped), L2_ROLLUP_ID);
        vm.prank(user);
        (bool ok, bytes memory result) = proxy.call(data);
        assertTrue(ok, "L1 source lookup");
        assertEq(result, returned);
        _deliverToL2(user, address(wrapped), data, returned, hash);
    }

    function _prepareL1Call(bytes32 hash, bytes memory returned) private {
        vm.roll(block.number + 1);
        RollupUpdate[] memory updates = _nextUpdate(hash);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].rollupUpdates = updates;
        entries[0].proxyEntryHash = hash;
        entries[0].destinationRollupId = L2_ROLLUP_ID;
        entries[0].l2ToL1Calls = new L2ToL1Call[](0);
        entries[0].expectedL1ToL2Calls = new ExpectedL1ToL2Call[](0);
        entries[0].rollingHash = _hEntryBegin(updates, hash);
        entries[0].success = true;
        entries[0].returnData = returned;
        _postBatchToL2(entries);
    }

    function _deliverToL2(
        address source,
        address target,
        bytes memory data,
        bytes memory returned,
        bytes32 hash
    )
        private
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: source,
            sourceRollupId: MAINNET_ROLLUP_ID,
            targetAddress: target,
            value: 0,
            data: data
        });
        L2Entry[] memory entries = new L2Entry[](1);
        entries[0] = L2Entry({
            proxyEntryHash: hash,
            incomingCalls: calls,
            expectedOutgoingCalls: new ExpectedOutgoingCrossChainCall[](0),
            rollingHash: _hCallEnd(_hCallBegin(_hEntryBeginL2(hash), hash), true, returned),
            success: true,
            returnData: returned
        });
        vm.prank(SYSTEM_ADDRESS);
        assertEq(managerL2.executeIncomingCrossChainCall(entries, _emptyL2StaticEntries()), returned);
    }

    function _bridgeBack(address holder, uint256 amount) private {
        vm.roll(block.number + 1);
        bytes memory data = _payload(holder, amount, L2_ROLLUP_ID);
        bytes32 outgoing = _ccHashL2Out(address(bridgeL2), address(bridgeL1), MAINNET_ROLLUP_ID, 0, data);
        L2Entry[] memory l2Entries = new L2Entry[](1);
        l2Entries[0] = L2Entry({
            proxyEntryHash: outgoing,
            incomingCalls: new CrossChainCall[](0),
            expectedOutgoingCalls: new ExpectedOutgoingCrossChainCall[](0),
            rollingHash: _hEntryBeginL2(outgoing),
            success: true,
            returnData: ""
        });
        _loadL2Table(l2Entries, _emptyL2StaticEntries());
        vm.prank(holder);
        bridgeL2.bridgeTokens(address(wrapped), amount, MAINNET_ROLLUP_ID, holder);

        // One real L2 user transaction maps to one zero-hash L1 entry. Its call
        // comes from the L2 bridge's authenticated proxy and releases L1 escrow.
        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: address(bridgeL2),
            sourceRollupId: L2_ROLLUP_ID,
            targetAddress: address(bridgeL1),
            value: 0,
            data: data
        });
        RollupUpdate[] memory updates = _nextUpdate(outgoing);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            rollupUpdates: updates,
            proxyEntryHash: bytes32(0),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: calls,
            expectedL1ToL2Calls: new ExpectedL1ToL2Call[](0),
            rollingHash: _hCallEnd(_hCallBegin(_hEntryBegin(updates, bytes32(0)), outgoing), true, ""),
            success: true,
            returnData: ""
        });
        _postBatchToL2(entries, 1);
    }

    function _nextUpdate(bytes32 callHash) private view returns (RollupUpdate[] memory updates) {
        bytes32 current = _getRollupState(L2_ROLLUP_ID);
        updates = new RollupUpdate[](1);
        updates[0] = RollupUpdate({
            rollupId: L2_ROLLUP_ID,
            currentRoot: current,
            newRoot: keccak256(abi.encode(current, callHash)),
            etherDelta: 0
        });
    }
}
