// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IEEZ} from "../src/interfaces/IEEZ.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {ICounterView} from "./mocks/CounterContracts.sol";
import {StaticRoundTripFailureReader} from "./mocks/StaticRoundTripContracts.sol";

contract StaticRoundTripFailureReaderTest is Test {
    StaticRoundTripFailureReader reader;
    address constant MANAGER = address(0x1000);
    address constant TARGET = address(0x2000);
    address constant CALLBACK = address(0x3000);
    address constant PROXY = address(0x4000);

    function setUp() public {
        vm.mockCall(
            MANAGER, abi.encodeCall(IEEZ.computeCrossChainProxyAddress, (CALLBACK, uint64(1))), abi.encode(PROXY)
        );
        reader = new StaticRoundTripFailureReader(TARGET, MANAGER, CALLBACK, 1);
    }

    function test_RecordsExactFailureAndLeavesProxyAbsent() public {
        bytes memory expected = abi.encodeWithSelector(EEZBase.StaticCallProxyNotDeployed.selector, PROXY);
        vm.mockCallRevert(TARGET, abi.encodeCall(ICounterView.counter, ()), expected);
        reader.recordFailure();
        assertEq(reader.failedReads(), 1);
        assertEq(reader.missingProxyError(), expected);
        assertEq(PROXY.code.length, 0);
    }

    function test_RejectsUnrelatedFailure() public {
        vm.mockCallRevert(TARGET, abi.encodeCall(ICounterView.counter, ()), hex"deadbeef");
        vm.expectRevert("wrong missing-proxy revert");
        reader.recordFailure();
        assertEq(reader.failedReads(), 0);
        assertEq(reader.missingProxyError().length, 0);
    }

    function test_RejectsErrorForDifferentProxy() public {
        vm.mockCallRevert(
            TARGET,
            abi.encodeCall(ICounterView.counter, ()),
            abi.encodeWithSelector(EEZBase.StaticCallProxyNotDeployed.selector, address(0x5000))
        );
        vm.expectRevert("wrong missing-proxy revert");
        reader.recordFailure();
    }

    function test_RejectsUnexpectedSuccess() public {
        vm.mockCall(TARGET, abi.encodeCall(ICounterView.counter, ()), abi.encode(uint256(1)));
        vm.expectRevert("missing callback proxy unexpectedly succeeded");
        reader.recordFailure();
    }

    function test_RejectsPredeployedProxy() public {
        vm.etch(PROXY, hex"00");
        vm.expectRevert("callback proxy already deployed before read");
        reader.recordFailure();
    }
}
