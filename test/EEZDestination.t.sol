// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {EEZ} from "../src/EEZ.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {EEZProxy} from "../src/proxy/EEZProxy.sol";
import {IEEZ, L2ToL1Call, ExpectedL1ToL2Call} from "../src/interfaces/IEEZ.sol";
import {CrossChainCall, ExpectedOutgoingCrossChainCall} from "../src/interfaces/IEEZL2.sol";

// L2ToL1Call and CrossChainCall have identical ABI layouts. Encoded calls let the
// same regression tests exercise both managers' real dispatch and nested paths.
interface IDestinationHarness {
    function run(bytes calldata encodedCalls, bool staticEntry) external returns (bytes32);
    function runNested(bytes calldata encodedCalls, bool success) external;
}

contract L1DestinationHarness is EEZ {
    constructor() EEZ(address(0xCAFE)) {}

    function run(bytes calldata encodedCalls, bool staticEntry) external returns (bytes32) {
        L2ToL1Call[] memory calls = abi.decode(encodedCalls, (L2ToL1Call[]));
        if (staticEntry) return _processStaticL2ToL1Calls(calls);
        _processL2ToL1Calls(calls);
        return _rollingHash;
    }

    function runNested(bytes calldata encodedCalls, bool success) external {
        ExpectedL1ToL2Call memory row;
        row.l2ToL1Calls = abi.decode(encodedCalls, (L2ToL1Call[]));
        row.success = success;
        _resolveNestedReentrant(row, bytes32(uint256(1)));
    }
}

contract L2DestinationHarness is EEZL2 {
    ExpectedOutgoingCrossChainCall private _row;

    constructor() EEZL2(1, address(0xBEEF), false, address(0xCAFE)) {}

    function run(bytes calldata encodedCalls, bool staticEntry) external returns (bytes32) {
        CrossChainCall[] memory calls = abi.decode(encodedCalls, (CrossChainCall[]));
        if (staticEntry) return _processStaticIncomingCalls(calls);
        _processIncomingCalls(calls);
        return _rollingHash;
    }

    function runNested(bytes calldata encodedCalls, bool success) external {
        _row.incomingCalls = abi.decode(encodedCalls, (CrossChainCall[]));
        _row.success = success;
        _resolveNestedReentrant(_row, bytes32(uint256(1)));
    }
}

contract DestinationTarget {
    uint256 public value;
    address public caller;

    function setValue(uint256 next) external payable {
        value = next;
        caller = msg.sender;
    }
}

abstract contract DestinationTestBase is Test {
    IDestinationHarness internal manager;
    DestinationTarget internal target;

    function _deploy() internal virtual returns (address);

    function setUp() public {
        manager = IDestinationHarness(_deploy());
        target = new DestinationTarget();
    }

    function _calls(address destination, bool isStatic) internal view returns (CrossChainCall[] memory calls) {
        calls = new CrossChainCall[](1);
        calls[0].sourceAddress = address(this);
        calls[0].sourceRollupId = 2;
        calls[0].targetAddress = destination;
        calls[0].isStatic = isStatic;
        calls[0].data = abi.encodeCall(IEEZ.STATIC_CHECK_GAS, ());
    }

    function testFuzz_RejectSelfBeforeDispatch(bool isStatic, uint64 callGas, uint96 value) public {
        CrossChainCall[] memory calls = _calls(address(manager), isStatic);
        calls[0].gas = callGas;
        calls[0].value = isStatic ? 0 : value;
        vm.deal(address(manager), value);
        address sourceProxy = EEZBase(address(manager)).computeCrossChainProxyAddress(address(this), 2);

        vm.expectRevert(EEZBase.EEZDestinationForbidden.selector);
        manager.run(abi.encode(calls), false);

        assertEq(sourceProxy.code.length, 0);
        assertEq(address(manager).balance, value);
    }

    function testFuzz_StaticEntryRejectsSelf(uint64 callGas) public {
        CrossChainCall[] memory calls = _calls(address(manager), true);
        calls[0].gas = callGas;
        (bool ok, bytes memory result) =
            address(manager).staticcall(abi.encodeCall(IDestinationHarness.run, (abi.encode(calls), true)));
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(EEZBase.EEZDestinationForbidden.selector));
    }

    function testFuzz_NestedFrameRejectsSelf(bool success) public {
        CrossChainCall[] memory calls = _calls(address(manager), false);
        vm.expectRevert(EEZBase.EEZDestinationForbidden.selector);
        manager.runNested(abi.encode(calls), success);
    }

    function test_RevertSpanCannotHideForbiddenDestination() public {
        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = _calls(address(target), false)[0];
        calls[0].data = abi.encodeCall(DestinationTarget.setValue, (42));
        calls[0].revertNextNCalls = 2;
        calls[1] = _calls(address(manager), false)[0];

        vm.expectRevert(
            abi.encodeWithSelector(
                EEZBase.UnexpectedContextRevert.selector,
                abi.encodeWithSelector(EEZBase.EEZDestinationForbidden.selector)
            )
        );
        manager.run(abi.encode(calls), false);
        assertEq(target.value(), 0);
    }

    function test_RevertSpanStartingAtSelfIsRejected() public {
        CrossChainCall[] memory calls = _calls(address(manager), false);
        calls[0].revertNextNCalls = 1;
        vm.expectRevert(EEZBase.EEZDestinationForbidden.selector);
        manager.run(abi.encode(calls), false);
    }

    function testFuzz_DelegatecallManagerRejectsItsOwnAddress(bool staticEntry) public {
        manager = IDestinationHarness(address(new EEZProxy(address(manager), address(this))));
        CrossChainCall[] memory calls = _calls(address(manager), staticEntry);
        vm.expectRevert(EEZBase.EEZDestinationForbidden.selector);
        manager.run(abi.encode(calls), staticEntry);
    }

    function test_OtherDestinationStillReceivesValueAndProxyIdentity() public {
        CrossChainCall[] memory calls = _calls(address(target), false);
        calls[0].data = abi.encodeCall(DestinationTarget.setValue, (42));
        calls[0].value = 1 ether;
        vm.deal(address(manager), 1 ether);
        manager.run(abi.encode(calls), false);

        assertEq(target.value(), 42);
        assertEq(address(target).balance, 1 ether);
        assertEq(target.caller(), EEZBase(address(manager)).computeCrossChainProxyAddress(address(this), 2));
    }

    function test_OtherStaticDestinationStillReturnsExpectedHash() public {
        EEZBase(address(manager)).createCrossChainProxy(address(this), 2);
        CrossChainCall[] memory calls = _calls(address(target), true);
        calls[0].data = abi.encodeWithSignature("value()");
        (bool ok, bytes memory result) =
            address(manager).staticcall(abi.encodeCall(IDestinationHarness.run, (abi.encode(calls), true)));
        assertTrue(ok);
        assertEq(abi.decode(result, (bytes32)), keccak256(abi.encodePacked(bytes32(0), true, abi.encode(uint256(0)))));
    }
}

contract EEZDestinationTest is DestinationTestBase {
    function _deploy() internal override returns (address) {
        return address(new L1DestinationHarness());
    }
}

contract EEZL2DestinationTest is DestinationTestBase {
    function _deploy() internal override returns (address) {
        return address(new L2DestinationHarness());
    }
}
