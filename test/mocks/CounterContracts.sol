// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Explicit gas attached to the cross-chain proxy call sites below. L2 folds the gas observed
///      at manager entry into the outgoing call hash, so these sites attach a fixed amount that a
///      test-side probe with the same attach reproduces (equals `BaseL2.CALL_GAS`).
uint256 constant PROXY_CALL_GAS = 5_000_000;

contract Counter {
    uint256 public counter;

    function increment() external returns (uint256) {
        counter++;
        return counter;
    }
}

contract RevertCounter {
    uint256 public counter;

    function increment() external returns (uint256) {
        revert("always reverts");
    }
}

contract SafeCounterAndProxy {
    Counter public target;
    uint256 public targetCounter;
    uint256 public counter;
    bool public lastCallFailed;

    constructor(Counter _target) {
        target = _target;
    }

    function incrementProxy() external {
        try target.increment{gas: PROXY_CALL_GAS}() returns (uint256 val) {
            targetCounter = val;
        } catch {
            lastCallFailed = true;
        }
        counter++;
    }
}

contract CounterAndProxy {
    Counter public target;
    uint256 public targetCounter;
    uint256 public counter;

    constructor(Counter _target) {
        target = _target;
    }

    function incrementProxy() external {
        targetCounter = target.increment{gas: PROXY_CALL_GAS}();
        counter++;
    }
}

/// @notice Wraps CounterAndProxy to create a deeper call stack in cross-chain tests.
contract NestedCaller {
    CounterAndProxy public target;
    uint256 public counter;

    constructor(CounterAndProxy _target) {
        target = _target;
    }

    function callNested() external {
        target.incrementProxy();
        counter++;
    }
}

/// @notice Makes one call inside a self-call frame that then reverts (caught) — the
///         call's local consumption unwinds with the frame; no retry follows.
contract SelfCallerRevertOnly {
    Counter public target;
    bool public reverted;

    constructor(Counter _target) {
        target = _target;
    }

    function execute() external {
        try this.innerCall() {}
        catch {
            reverted = true;
        }
    }

    function innerCall() external {
        target.increment();
        revert("inner scope revert");
    }
}

/// @notice Calls target via self-call that reverts, then calls target directly.
contract SelfCallerWithRevert {
    Counter public target;
    uint256 public lastResult;

    constructor(Counter _target) {
        target = _target;
    }

    function execute() external {
        try this.innerCall() {} catch {}
        lastResult = target.increment();
    }

    function innerCall() external {
        target.increment();
        revert("inner scope revert");
    }
}

/// @notice Paired counter — returns (ownCounter, otherCounter, id).
/// Deploy two with different IDs and link via setOther() to get distinct return data.
contract JoinedCounter {
    JoinedCounter public other;
    uint256 public counter;
    uint256 public immutable ID;

    constructor(uint256 id) {
        ID = id;
    }

    function setOther(JoinedCounter _other) external {
        other = _other;
    }

    function increment() external returns (uint256 own, uint256 otherVal, uint256 id) {
        counter++;
        return (counter, other.counter(), ID);
    }
}

/// @notice Calls targetA in a reverting self-call, then calls targetB.
contract DualCallerWithRevert {
    JoinedCounter public targetA;
    JoinedCounter public targetB;

    constructor(JoinedCounter _a, JoinedCounter _b) {
        targetA = _a;
        targetB = _b;
    }

    function execute() external {
        try this.innerCall() {} catch {}
        targetB.increment();
    }

    function innerCall() external {
        targetA.increment();
        revert("inner scope revert");
    }
}

/// @notice Calls increment() on two Counter proxies sequentially.
contract CallTwoProxies {
    Counter public target1;
    Counter public target2;

    constructor(Counter _target1, Counter _target2) {
        target1 = _target1;
        target2 = _target2;
    }

    function callBoth() external {
        target1.increment();
        target2.increment();
    }
}
