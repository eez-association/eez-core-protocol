// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEEZ} from "../../src/interfaces/IEEZ.sol";
import {EEZBase} from "../../src/base/EEZBase.sol";
import {ICounterView} from "./CounterContracts.sol";

/// @notice Makes the callback source distinct from the original remote-read target.
contract StaticCounterCallback is ICounterView {
    ICounterView public immutable target;

    constructor(address proxy) {
        target = ICounterView(proxy);
    }

    function counter() external view returns (uint256) {
        return target.counter();
    }
}

contract StaticCounterForwarder is ICounterView {
    ICounterView public immutable callback;

    constructor(address helper) {
        callback = ICounterView(helper);
    }

    function counter() external view returns (uint256) {
        return callback.counter();
    }
}

/// @notice One source transaction. Missing-proxy mode observes the exact failed static
/// read, creates the source proxy in normal context, and retries the SAME lookup.
contract StaticRoundTripReader {
    ICounterView public immutable readTarget;
    IEEZ public immutable manager;
    address public immutable callbackSource;
    uint64 public immutable sourceRollup;
    bool public immutable expectMissing;
    uint256 public counter;
    uint256 public lastRead;
    bytes public missingProxyError;

    constructor(address target, address managerAddress, address source, uint64 rollup, bool missing) {
        readTarget = ICounterView(target);
        manager = IEEZ(managerAddress);
        callbackSource = source;
        sourceRollup = rollup;
        expectMissing = missing;
    }

    function increment() external returns (uint256) {
        address sourceProxy = manager.computeCrossChainProxyAddress(callbackSource, sourceRollup);
        if (expectMissing) {
            require(sourceProxy.code.length == 0, "callback proxy already deployed before read");
            (bool ok, bytes memory result) = address(readTarget).staticcall(abi.encodeCall(ICounterView.counter, ()));
            require(!ok, "missing callback proxy unexpectedly succeeded");
            bytes memory expected = abi.encodeWithSelector(EEZBase.StaticCallProxyNotDeployed.selector, sourceProxy);
            require(keccak256(result) == keccak256(expected), "wrong missing-proxy revert");
            missingProxyError = result;
            require(sourceProxy.code.length == 0, "static read deployed callback proxy");
            // This call is outside static context and belongs to the user transaction.
            require(manager.createCrossChainProxy(callbackSource, sourceRollup) == sourceProxy, "wrong proxy deployed");
        }
        require(sourceProxy.code.length != 0, "callback source proxy missing");
        lastRead = readTarget.counter();
        require(lastRead == 1, "wrong round-trip result");
        counter++;
        return lastRead;
    }
}
