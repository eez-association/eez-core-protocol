// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EEZ} from "../src/EEZ.sol";
import {IEEZ} from "../src/interfaces/IEEZ.sol";
import {CrossChainProxy} from "../src/base/CrossChainProxy.sol";
import {ICrossChainProxy} from "../src/interfaces/ICrossChainProxy.sol";

contract GasBurningRecovery {
    receive() external payable {
        assembly { invalid() }
    }
}

contract ProxyManagerHarness {
    address public RECOVERY_ADDRESS;
    uint256 public STATIC_CHECK_GAS = 1_000;

    function setStaticCheckGas(uint256 newCap) external {
        STATIC_CHECK_GAS = newCap;
    }
    address public observedSource;
    uint256 public observedValue;
    bytes public observedData;

    constructor(address recovery) {
        RECOVERY_ADDRESS = recovery;
    }

    function deploy(bytes32 salt) external returns (address) {
        return address(new CrossChainProxy{salt: salt}());
    }

    function executeCrossChainCall(address source, bytes calldata data) external payable returns (bytes memory) {
        observedSource = source;
        observedValue = msg.value;
        observedData = data;
        return bytes("forwarded");
    }

    function callSelf(CrossChainProxy proxy) external {
        ICrossChainProxy(address(proxy)).executeOnBehalf(address(proxy), 0, abi.encodeWithSignature("staticCheck()"));
    }

    function staticCrossChainCall(address, bytes calldata data) external pure returns (bytes memory) {
        return data;
    }
}

/// @dev Runs EEZ in delegatecall context to test CREATE2 address prediction.
contract DelegateEEZHarness {
    address internal immutable implementation;

    constructor(address impl) {
        implementation = impl;
    }

    fallback() external payable {
        address impl = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract ProxyBehaviorTest is Test {
    bytes4 private constant STATIC_CHECK_SELECTOR = bytes4(keccak256("staticCheck()"));

    function testFuzz_MalformedAdminSelectorForwardsForOtherCallers(bytes calldata suffix) public {
        ProxyManagerHarness manager = new ProxyManagerHarness(address(0xCAFE));
        address proxy = manager.deploy(0);
        // A selector alone, or arbitrary payload, must be forwarded without local decoding.
        bytes memory data = abi.encodePacked(ICrossChainProxy.executeOnBehalf.selector, suffix);
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory result) = proxy.call{value: 1 ether}(data);
        assertTrue(ok);
        assertEq(result, bytes("forwarded"));
        assertEq(manager.observedData(), data);
        assertEq(manager.observedValue(), 1 ether);
    }

    function test_MalformedAdminCallStillRevertsForManager() public {
        ProxyManagerHarness manager = new ProxyManagerHarness(address(0xCAFE));
        address proxy = manager.deploy(0);
        vm.prank(address(manager));
        (bool ok,) = proxy.call(abi.encodePacked(ICrossChainProxy.executeOnBehalf.selector));
        assertFalse(ok);
        assertEq(manager.observedSource(), address(0));
    }

    function testFuzz_StaticCheckForwardsValueAndTrailingData(bytes calldata suffix) public {
        ProxyManagerHarness manager = new ProxyManagerHarness(address(0xCAFE));
        address proxy = manager.deploy(0);
        vm.deal(address(this), 1 ether);
        bytes memory data = abi.encodePacked(STATIC_CHECK_SELECTOR, suffix);
        (bool ok, bytes memory result) = proxy.call{value: 1 ether}(data);
        assertTrue(ok);
        assertEq(result, bytes("forwarded"));
        assertEq(manager.observedSource(), address(this));
        assertEq(manager.observedValue(), 1 ether);
        assertEq(manager.observedData(), data);
        assertEq(proxy.balance, 0);
    }

    function test_ManagerDirectedSelfCallUsesLocalDetector() public {
        ProxyManagerHarness manager = new ProxyManagerHarness(address(0xCAFE));
        CrossChainProxy proxy = CrossChainProxy(payable(manager.deploy(0)));
        manager.callSelf(proxy);
        assertEq(manager.observedSource(), address(0));
        vm.prank(address(proxy));
        (bool ok, bytes memory result) = address(proxy).call{gas: 1000}(abi.encodeWithSelector(STATIC_CHECK_SELECTOR));
        assertTrue(ok, "mutable detector fits the probe gas budget");
        assertEq(result.length, 0);
        vm.prank(address(proxy));
        (ok,) = address(proxy).staticcall{gas: 1000}(abi.encodeWithSelector(STATIC_CHECK_SELECTOR));
        assertFalse(ok);
    }

    function testFuzz_StaticCheckFromOtherCallerInStaticContext(bytes calldata suffix) public {
        ProxyManagerHarness manager = new ProxyManagerHarness(address(0xCAFE));
        address proxy = manager.deploy(0);
        bytes memory data = abi.encodePacked(STATIC_CHECK_SELECTOR, suffix);
        (bool ok, bytes memory result) = proxy.staticcall(data);
        assertTrue(ok);
        assertEq(result, data);
        assertEq(manager.observedSource(), address(0));
    }

    function test_ExistingProxyReadsUpdatedManagerProbeCap() public {
        ProxyManagerHarness manager = new ProxyManagerHarness(address(0xCAFE));
        address proxy = manager.deploy(0);
        bytes memory data = hex"12345678";
        (bool ok, bytes memory result) = proxy.call(data);
        assertTrue(ok);
        assertEq(result, bytes("forwarded"));

        // Zero makes the probe fail even in mutable context, proving the cap is read live.
        manager.setStaticCheckGas(0);
        (ok, result) = proxy.call(data);
        assertTrue(ok);
        assertEq(result, data);

        manager.setStaticCheckGas(2_000);
        (ok, result) = proxy.call(data);
        assertTrue(ok);
        assertEq(result, bytes("forwarded"));
        (ok, result) = proxy.staticcall(data);
        assertTrue(ok);
        assertEq(result, data);
    }

    function test_DelegatecallEEZProxyPredictionRecoveryAndAuthorization() public {
        address recovery = makeAddr("recovery");
        EEZ implementation = new EEZ(recovery);
        EEZ delegated = EEZ(address(new DelegateEEZHarness(address(implementation))));
        address predicted = delegated.computeCrossChainProxyAddress(address(0xBEEF), 1);
        uint256 recoveryBefore = recovery.balance;
        vm.deal(predicted, 1 ether);

        address actual = delegated.createCrossChainProxy(address(0xBEEF), 1);
        assertGt(actual.code.length, 0);
        assertEq(actual, predicted);
        assertEq(delegated.getOrCreateCrossChainProxy(address(0xBEEF), 1), actual);
        assertEq(actual.balance, 0);
        assertEq(recovery.balance, recoveryBefore + 1 ether);

        // The deploying EEZ proxy is authorized; its implementation is not.
        bytes memory payload = abi.encodeCall(
            ICrossChainProxy.executeOnBehalf,
            (address(implementation), uint64(0), abi.encodeCall(IEEZ.STATIC_CHECK_GAS, ()))
        );
        vm.prank(address(delegated));
        (bool ok, bytes memory result) = actual.call(payload);
        assertTrue(ok);
        assertEq(abi.decode(result, (uint256)), implementation.STATIC_CHECK_GAS());
        vm.prank(address(implementation));
        (ok, result) = actual.call(payload);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZ.ExecutionNotInCurrentBlock.selector, uint64(1)));
    }

    function test_DeploymentCanSucceedAfterRecoveryExhaustsForwardedGas() public {
        GasBurningRecovery recovery = new GasBurningRecovery();
        ProxyManagerHarness manager = new ProxyManagerHarness(address(recovery));
        bytes32 initHash = keccak256(type(CrossChainProxy).creationCode);
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(manager), bytes32(0), initHash))))
        );
        vm.deal(predicted, 1 ether);
        // Sweep capped at 100k: a burner costs at most that, so a modest gas budget still deploys.
        address proxy = manager.deploy{gas: 500_000}(0);
        assertEq(proxy, predicted);
        assertGt(proxy.code.length, 0);
        assertEq(proxy.balance, 1 ether);
        assertEq(address(recovery).balance, 0);
    }
}
