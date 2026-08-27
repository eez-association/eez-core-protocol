// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CallTwice
/// @notice Calls counter.increment() twice on the SAME target address via low-level call.
contract CallTwice {
    function callCounterTwice(address counter) external returns (uint256 first, uint256 second) {
        (bool ok1, bytes memory ret1) = counter.call(abi.encodeWithSignature("increment()"));
        require(ok1, "first call failed");
        first = abi.decode(ret1, (uint256));

        (bool ok2, bytes memory ret2) = counter.call(abi.encodeWithSignature("increment()"));
        require(ok2, "second call failed");
        second = abi.decode(ret2, (uint256));
    }
}

/// @title CallTwoDifferent
/// @notice Calls increment() on two DIFFERENT counter addresses via low-level call.
contract CallTwoDifferent {
    function callBothCounters(address counterA, address counterB) external returns (uint256 a, uint256 b) {
        (bool ok1, bytes memory ret1) = counterA.call(abi.encodeWithSignature("increment()"));
        require(ok1, "first call failed");
        a = abi.decode(ret1, (uint256));

        (bool ok2, bytes memory ret2) = counterB.call(abi.encodeWithSignature("increment()"));
        require(ok2, "second call failed");
        b = abi.decode(ret2, (uint256));
    }
}

/// @title CallTwiceNestedAndOnce
/// @notice Calls nestedProxy.incrementProxy() twice, then simpleProxy.increment() once.
contract CallTwiceNestedAndOnce {
    function execute(address nestedProxy, address simpleProxy) external returns (uint256) {
        (bool ok1,) = nestedProxy.call(abi.encodeWithSignature("incrementProxy()"));
        require(ok1, "first nested call failed");

        (bool ok2,) = nestedProxy.call(abi.encodeWithSignature("incrementProxy()"));
        require(ok2, "second nested call failed");

        (bool ok3, bytes memory ret3) = simpleProxy.call(abi.encodeWithSignature("increment()"));
        require(ok3, "simple call failed");
        return abi.decode(ret3, (uint256));
    }
}

/// @title ConditionalCallTwice
/// @notice Calls two different L2 counter proxies, then conditionally reverts
///         based on the second counter's return value.
contract ConditionalCallTwice {
    function callBothConditional(
        address counterA,
        address counterB,
        uint256 revertThreshold
    )
        external
        returns (uint256 a, uint256 b)
    {
        (bool ok1, bytes memory ret1) = counterA.call(abi.encodeWithSignature("increment()"));
        require(ok1, "first call failed");
        a = abi.decode(ret1, (uint256));

        (bool ok2, bytes memory ret2) = counterB.call(abi.encodeWithSignature("increment()"));
        require(ok2, "second call failed");
        b = abi.decode(ret2, (uint256));

        require(b < revertThreshold, "conditional revert: counterB >= threshold");
    }
}
