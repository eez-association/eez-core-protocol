// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TestHashes} from "../TestHashes.sol";
import {EEZL2} from "../../src/L2/EEZL2.sol";
import {Bridge} from "../../src/periphery/Bridge.sol";
import {WrappedToken} from "../../src/periphery/WrappedToken.sol";
import {InitializedBridge} from "../../script/DeployInitializedBridge.s.sol";
import {ICrossChainProxy} from "../../src/interfaces/ICrossChainProxy.sol";
import {
    ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    StaticExecutionEntryL2
} from "../../src/interfaces/IEEZL2.sol";

contract EdgeCaseToken is ERC20 {
    constructor(address holder) ERC20("Review Token", "REV") {
        _mint(holder, 100);
    }
}

/// @dev Deliberately unsupported fixture: takes 10% on every ordinary transfer.
contract EdgeCaseFeeToken is EdgeCaseToken {
    constructor(address holder) EdgeCaseToken(holder) {}

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = amount / 10;
            super._update(from, address(0), fee);
            super._update(from, to, amount - fee);
        } else {
            super._update(from, to, amount);
        }
    }
}

contract EdgeCaseCallbackToken is EdgeCaseToken {
    Bridge immutable bridge;
    bytes public receiveError;
    bytes public adminError;

    constructor(address holder, Bridge target) EdgeCaseToken(holder) {
        bridge = target;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        (bool received, bytes memory receiveResult) = address(bridge)
            .call(
                abi.encodeCall(
                    Bridge.receiveTokens, (address(this), uint64(7), from, amount, "Fake", "FAKE", uint8(18), uint64(9))
                )
            );
        require(!received, "callback forged a bridge message");
        receiveError = receiveResult;
        (bool configured, bytes memory adminResult) =
            address(bridge).call(abi.encodeCall(Bridge.setAcceptedSourceRollupId, (uint64(0))));
        require(!configured, "callback acquired admin permission");
        adminError = adminResult;
        return super.transferFrom(from, to, amount);
    }
}

/// @notice Local two-sided characterization, including intentional fixture limits.
/// @dev Real EEZL2 managers, proxies and bridge code on both sides. The test is the trusted
/// system loader. Every cached result is also executed at the destination with identical
/// call identity. This does not test proofs, node integration, or live settlement.
/// Destination execution is performed first to establish the cached source result.
contract BridgeEdgeCasesTest is Test, TestHashes {
    uint64 constant A_ID = 7;
    uint64 constant B_ID = 9;
    address alice = address(0xA11CE);
    EEZL2 managerA;
    EEZL2 managerB;
    InitializedBridge bridgeA;
    InitializedBridge bridgeB;
    EdgeCaseToken token;

    receive() external payable {}

    function setUp() public {
        managerA = new EEZL2(A_ID, address(this), false, address(this));
        managerB = new EEZL2(B_ID, address(this), false, address(this));
        bridgeA = new InitializedBridge(address(managerA), A_ID, address(this));
        bridgeB = new InitializedBridge(address(managerB), B_ID, address(this));
        bridgeA.setCanonicalBridgeAddress(address(bridgeB));
        bridgeB.setCanonicalBridgeAddress(address(bridgeA));
        bridgeA.setAcceptedSourceRollupId(B_ID);
        bridgeB.setAcceptedSourceRollupId(A_ID);
        token = new EdgeCaseToken(alice);
    }

    function _incoming(
        EEZL2 manager,
        CrossChainCall memory call_,
        bool success,
        bytes memory result
    )
        internal
        view
        returns (ExecutionEntry[] memory entries)
    {
        bytes32 hash = _ccHash(
            false,
            call_.sourceAddress,
            call_.sourceRollupId,
            call_.targetAddress,
            manager.ROLLUP_ID(),
            call_.value,
            call_.data
        );
        entries = new ExecutionEntry[](1);
        entries[0].proxyEntryHash = hash;
        entries[0].incomingCalls = new CrossChainCall[](1);
        entries[0].incomingCalls[0] = call_;
        entries[0].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entries[0].rollingHash = _hCallEnd(_hCallBegin(_hEntryBeginL2(hash), hash), success, result);
        entries[0].success = success;
        entries[0].returnData = result;
    }

    function _cache(
        EEZL2 manager,
        CrossChainCall memory call_,
        uint64 targetId,
        bool success,
        bytes memory result
    )
        internal
    {
        bytes32 hash = _ccHash(
            false, call_.sourceAddress, call_.sourceRollupId, call_.targetAddress, targetId, call_.value, call_.data
        );
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0].proxyEntryHash = hash;
        entries[0].incomingCalls = new CrossChainCall[](0);
        entries[0].expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entries[0].rollingHash = _hEntryBeginL2(hash);
        entries[0].success = success;
        entries[0].returnData = result;
        manager.loadExecutionTable(entries, new StaticExecutionEntryL2[](0));
    }

    function _move(
        bool returning,
        address sentToken,
        address original,
        address recipient,
        uint256 amount,
        bool success,
        bytes memory result
    )
        internal
    {
        Bridge source = returning ? bridgeB : bridgeA;
        Bridge destination = returning ? bridgeA : bridgeB;
        EEZL2 sourceManager = returning ? managerB : managerA;
        EEZL2 destinationManager = returning ? managerA : managerB;
        IERC20Metadata metadata = IERC20Metadata(sentToken);
        bytes memory data = abi.encodeCall(
            Bridge.receiveTokens,
            (
                original,
                A_ID,
                recipient,
                amount,
                metadata.name(),
                metadata.symbol(),
                metadata.decimals(),
                source.rollupId()
            )
        );
        CrossChainCall memory call_ = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            gas: 0,
            sourceAddress: address(source),
            sourceRollupId: source.rollupId(),
            targetAddress: address(destination),
            value: 0,
            data: data
        });
        ExecutionEntry[] memory incoming = _incoming(destinationManager, call_, success, result);
        if (!success) vm.expectRevert(result);
        destinationManager.executeIncomingCrossChainCall(incoming, new StaticExecutionEntryL2[](0));
        uint64 destinationId = destination.rollupId();
        _cache(sourceManager, call_, destinationId, success, result);
        vm.startPrank(alice);
        IERC20(sentToken).approve(address(source), amount);
        if (!success) vm.expectRevert(abi.encodeWithSelector(Bridge.ProxyCallFailed.selector, result));
        source.bridgeTokens(sentToken, amount, destinationId, recipient);
        vm.stopPrank();
    }

    function _forward(address original) internal returns (WrappedToken wrapped) {
        _move(false, original, original, alice, 100, true, "");
        wrapped = WrappedToken(bridgeB.getWrappedToken(original, A_ID));
        assertEq(wrapped.balanceOf(alice), 100);
    }

    function test_destinationOutsideAcceptedSourceCanLockButCannotReturn() public {
        bridgeA.setAcceptedSourceRollupId(0);
        WrappedToken wrapped = _forward(address(token));
        assertEq(token.balanceOf(address(bridgeA)), 100);
        _move(
            true,
            address(wrapped),
            address(token),
            alice,
            100,
            false,
            abi.encodeWithSelector(Bridge.SourceRollupNotAccepted.selector, B_ID)
        );
        assertEq(wrapped.balanceOf(alice), 100, "rejected return must roll back burn");
        assertEq(token.balanceOf(address(bridgeA)), 100);
        bridgeA.setAcceptedSourceRollupId(B_ID);
        _move(true, address(wrapped), address(token), alice, 100, true, "");
        assertEq(token.balanceOf(alice), 100);
        assertEq(wrapped.totalSupply(), 0);
    }

    function test_rebindingWithOutstandingFundsBlocksPreviouslyValidReturn() public {
        WrappedToken wrapped = _forward(address(token));
        bridgeA.setAcceptedSourceRollupId(0);
        _move(
            true,
            address(wrapped),
            address(token),
            alice,
            100,
            false,
            abi.encodeWithSelector(Bridge.SourceRollupNotAccepted.selector, B_ID)
        );
        assertEq(wrapped.totalSupply(), 100);
        assertEq(token.balanceOf(address(bridgeA)), 100);
        bridgeA.setAcceptedSourceRollupId(B_ID);
        _move(true, address(wrapped), address(token), alice, 100, true, "");
        assertEq(token.balanceOf(alice), 100);
    }

    function test_acceptingLocalIdEnablesSendingDespiteNoValidIncomingProxy() public {
        bridgeA.setAcceptedSourceRollupId(A_ID);
        assertTrue(bridgeA.sourceRollupSet());
        vm.expectRevert(abi.encodeWithSignature("SameNetworkProxy(uint64)", A_ID));
        managerA.createCrossChainProxy(address(bridgeB), A_ID);
        WrappedToken wrapped = _forward(address(token));
        _move(
            true,
            address(wrapped),
            address(token),
            alice,
            100,
            false,
            abi.encodeWithSelector(Bridge.SourceRollupNotAccepted.selector, B_ID)
        );
        assertEq(token.balanceOf(address(bridgeA)), 100);
    }

    function test_publicProxyCreationDoesNotGrantExecuteOnBehalfPermission() public {
        vm.prank(alice);
        address proxy = managerA.createCrossChainProxy(address(bridgeB), B_ID);
        bytes memory payload = abi.encodeCall(
            Bridge.receiveTokens, (address(token), A_ID, alice, 100, "Review Token", "REV", uint8(18), B_ID)
        );
        bytes memory attack = abi.encodeCall(ICrossChainProxy.executeOnBehalf, (address(bridgeA), uint64(0), payload));
        managerA.loadExecutionTable(new ExecutionEntry[](0), new StaticExecutionEntryL2[](0));
        bytes32 hash = _ccHash(false, alice, A_ID, address(bridgeB), B_ID, 0, attack);
        vm.prank(alice);
        (bool success, bytes memory result) = proxy.call(attack);
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(EEZL2.EntryNotFound.selector, hash, uint64(0)));
        assertEq(token.balanceOf(alice), 100);
        assertEq(bridgeA.getWrappedToken(address(token), B_ID), address(0));
    }

    function test_tokenCallbackCannotForgeInboundMessageOrChangeSource() public {
        EdgeCaseCallbackToken callback = new EdgeCaseCallbackToken(alice, bridgeA);
        _forward(address(callback));
        assertEq(callback.receiveError(), abi.encodeWithSelector(Bridge.UnauthorizedCaller.selector));
        assertEq(callback.adminError(), abi.encodeWithSelector(Bridge.OnlyAdmin.selector));
        assertEq(bridgeA.acceptedSourceRollupId(), B_ID);
        assertEq(callback.balanceOf(address(bridgeA)), 100);
    }

    function test_zeroTokenRecipientRollsBackLockAllowanceAndWrapperCreation() public {
        bytes memory result = abi.encodeWithSignature("ERC20InvalidReceiver(address)", address(0));
        _move(false, address(token), address(token), address(0), 100, false, result);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(address(bridgeA)), 0);
        assertEq(token.allowance(alice, address(bridgeA)), 100);
        assertEq(bridgeB.getWrappedToken(address(token), A_ID), address(0));
    }

    function test_zeroEtherRecipientSucceedsAndTransfersValueToZero() public {
        vm.deal(address(this), 1 ether);
        vm.deal(alice, 1 ether);
        uint256 zeroBalance = address(0).balance;
        CrossChainCall memory call_ = CrossChainCall({
            revertNextNCalls: 0,
            isStatic: false,
            gas: 0,
            sourceAddress: address(bridgeA),
            sourceRollupId: A_ID,
            targetAddress: address(0),
            value: 1 ether,
            data: ""
        });
        managerB.executeIncomingCrossChainCall{value: 1 ether}(
            _incoming(managerB, call_, true, ""), new StaticExecutionEntryL2[](0)
        );
        _cache(managerA, call_, B_ID, true, "");
        vm.prank(alice);
        bridgeA.bridgeEther{value: 1 ether}(B_ID, address(0));
        assertEq(alice.balance, 0);
        assertEq(address(0).balance, zeroBalance + 1 ether);
    }

    function test_feeOnTransferCreatesNominalSupplyAboveEscrow() public {
        EdgeCaseFeeToken taxed = new EdgeCaseFeeToken(alice);
        WrappedToken wrapped = _forward(address(taxed));
        assertEq(taxed.balanceOf(address(bridgeA)), 90);
        assertEq(wrapped.totalSupply(), 100);
        // This fixture burns the 10-token fee first, then fails to transfer 90 from the remaining 80.
        bytes memory result = abi.encodeWithSignature(
            "ERC20InsufficientBalance(address,uint256,uint256)", address(bridgeA), uint256(80), uint256(90)
        );
        _move(true, address(wrapped), address(taxed), alice, 100, false, result);
        assertEq(wrapped.balanceOf(alice), 100);
        assertEq(taxed.balanceOf(address(bridgeA)), 90);
    }
}
