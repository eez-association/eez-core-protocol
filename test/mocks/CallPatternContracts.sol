// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Application contracts for C01/C02/C03/C06/C07/C08. Each chain owns
/// one actor; peer always points to the OTHER actor's cross-chain proxy.
contract CallPatternActor {
    error FrameFailed(uint256 childResult);
    error PriceUnavailable(uint256 price);
    error GroupUndone();

    CallPatternActor public peer;
    uint256 public total;
    uint256 public completed;
    uint256 public firstRead;
    uint256 public lastRead;
    uint256 public result;
    bytes public failure;
    event Changed(uint256 total, uint256 received);

    function configure(address proxy) external {
        require(address(peer) == address(0), "already configured");
        peer = CallPatternActor(proxy);
    }

    function bump(uint256 amount) external payable returns (uint256) {
        total += amount;
        emit Changed(total, msg.value);
        return total;
    }

    function observeAndBump(uint256 expected, uint256 amount) external returns (uint256) {
        require(total == expected, "rollback changed subsequent observation");
        total += amount;
        emit Changed(total, 0);
        return total;
    }

    function readChain(uint8 depth) external view returns (uint256) {
        require(depth <= 3, "bounded read depth");
        if (depth == 0) return total;
        return peer.readChain(depth - 1) + 1;
    }

    function readUnderMutable() external returns (uint256) {
        lastRead = peer.readChain(2);
        require(lastRead == 2, "deep nested read");
        total++;
        return lastRead;
    }

    function price() external view returns (uint256) {
        revert PriceUnavailable(total);
    }

    function valuation(bool handleFailure) external view returns (uint256) {
        try peer.price() returns (uint256 answer) {
            return answer;
        } catch (bytes memory reason) {
            _exact(reason, abi.encodeWithSelector(PriceUnavailable.selector, uint256(0)));
            if (!handleFailure) {
                assembly { revert(add(reason, 32), mload(reason)) }
            }
            return 777;
        }
    }

    function failAfterChild() external returns (uint256) {
        total += 100;
        uint256 child = peer.bump(2);
        revert FrameFailed(child);
    }

    function catchNested() external returns (uint256) {
        try peer.failAfterChild() returns (uint256) {
            revert("nested failure was replaced by success");
        } catch (bytes memory reason) {
            _exact(reason, abi.encodeWithSelector(FrameFailed.selector, uint256(2)));
            failure = reason;
        }
        require(total == 0, "failed descendant write survived");
        total++;
        return total;
    }

    function purchase() external returns (uint256) {
        total += 10;
        uint256 child = peer.bump(3);
        require(child == 3, "purchase callback");
        return total + child;
    }

    function runCatchRemoteAndNestedRevertsAfterSuccessfulCallbacks() external {
        require(completed == 0, "one source transaction");
        _catchRemote(2);
        require(total == 0, "failed remote child survived");
        require(peer.catchNested() == 1, "caught nested result");
        result = peer.bump(4);
        require(result == 5, "continuation after failed remote");
        completed = 1;
    }

    function runDeepStaticReadCallbacksUnderStaticAndMutableCalls() external {
        require(completed == 0, "one source transaction");
        firstRead = peer.readChain(3);
        require(firstRead == 3, "deep top-level read");
        lastRead = peer.readUnderMutable();
        require(lastRead == 2, "deep read under mutable frame");
        completed = 1;
    }

    function runStaticReadCatchesCallbackRevertAndChecksUncaughtPropagation() external {
        require(completed == 0, "one source transaction");
        firstRead = peer.valuation(true);
        require(firstRead == 777, "handled callback answer");
        try peer.valuation(false) returns (uint256) {
            revert("uncaught callback failure was swallowed");
        } catch (bytes memory reason) {
            _exact(reason, abi.encodeWithSelector(PriceUnavailable.selector, uint256(0)));
            failure = reason;
        }
        completed = 1;
    }

    function runNestedRollbackGroupsRestoreStateBeforeContinuation() external {
        require(completed == 0, "one source transaction");
        try this.outerGroup() {
            revert("outer group committed");
        } catch (bytes memory reason) {
            _exact(reason, abi.encodeWithSelector(GroupUndone.selector));
        }
        // Identical bump(1), same result and no intervening local write:
        // the restored cursor may faithfully reuse its first candidate.
        require(peer.bump(1) == 1, "restored position reuse");
        result = peer.observeAndBump(1, 16);
        require(result == 17, "outer rollback");
        completed = 1;
    }

    function runRollbackGroupWithStaticReadThenWrite() external {
        require(completed == 0, "one source transaction");
        _readFirstGroup(0);
        result = peer.bump(1);
        require(result == 1, "read-first rollback");
        completed = 1;
    }

    function runStaticReadThenNestedWriteCaughtRevertAndRollback() external {
        require(completed == 0, "one source transaction");
        firstRead = peer.readChain(0);
        require(firstRead == 0, "initial mixed read");
        require(peer.purchase() == 13, "nested mutable result");
        _catchRemote(5);
        require(total == 3, "failed callback undid the wrong write");
        _readFirstGroup(10);
        lastRead = peer.readChain(0);
        require(lastRead == 10, "static pool at restored cursor");
        result = peer.bump(1);
        require(result == 11, "mixed continuation");
        completed = 1;
    }

    function outerGroup() external {
        require(msg.sender == address(this), "self only");
        require(peer.bump(1) == 1, "A");
        try this.innerGroup() {
            revert("inner group committed");
        } catch (bytes memory reason) {
            _exact(reason, abi.encodeWithSelector(GroupUndone.selector));
        }
        require(peer.observeAndBump(1, 8) == 9, "D must observe inner rollback");
        revert GroupUndone();
    }

    function innerGroup() external {
        require(msg.sender == address(this), "self only");
        require(peer.bump(2) == 3, "B");
        require(peer.bump(4) == 7, "C");
        revert GroupUndone();
    }

    function readFirstGroup(uint256 expected) external {
        require(msg.sender == address(this), "self only");
        require(peer.readChain(0) == expected, "group's successful first read");
        require(peer.bump(5) == expected + 5, "group's successful sibling write");
        revert GroupUndone();
    }

    function _readFirstGroup(uint256 expected) private {
        try this.readFirstGroup(expected) {
            revert("read-first group committed");
        } catch (bytes memory reason) {
            _exact(reason, abi.encodeWithSelector(GroupUndone.selector));
        }
    }

    function _catchRemote(uint256 expectedChild) private {
        try peer.failAfterChild() returns (uint256) {
            revert("remote failure was replaced by success");
        } catch (bytes memory reason) {
            _exact(reason, abi.encodeWithSelector(FrameFailed.selector, expectedChild));
            failure = reason;
        }
    }

    function _exact(bytes memory actual, bytes memory expected) private pure {
        require(keccak256(actual) == keccak256(expected), "wrong application failure bytes");
    }

    // Each focused trigger below makes only the calls needed for one behavior.
    function runCatchRemoteRevertAfterCallback() external {
        require(completed == 0, "one source transaction");
        _catchRemote(2);
        require(total == 0, "failed callback write survived");
        completed = 1;
    }

    function runCatchNestedRevertAfterCallback() external {
        require(completed == 0, "one source transaction");
        result = peer.catchNested();
        require(result == 1 && total == 0, "nested failure rollback");
        completed = 1;
    }

    function runStaticReadCallsBackAndReadsAgain() external {
        require(completed == 0, "one source transaction");
        firstRead = peer.readChain(2);
        require(firstRead == 2, "read callback's own read");
        completed = 1;
    }

    function readThenAddOne() external returns (uint256) {
        lastRead = peer.readChain(1);
        require(lastRead == 1, "nested read callback");
        total++;
        return lastRead;
    }

    function runMutableCallMakesReadThatCallsBack() external {
        require(completed == 0, "one source transaction");
        result = peer.readThenAddOne();
        require(result == 1, "mutable call's read result");
        completed = 1;
    }

    function runStaticReadHandlesFailedCallback() external {
        require(completed == 0, "one source transaction");
        firstRead = peer.valuation(true);
        require(firstRead == 777, "handled callback failure result");
        completed = 1;
    }

    function runStaticReadPropagatesFailedCallback() external {
        require(completed == 0, "one source transaction");
        try peer.valuation(false) returns (uint256) {
            revert("callback failure was swallowed");
        } catch (bytes memory reason) {
            _exact(reason, abi.encodeWithSelector(PriceUnavailable.selector, uint256(0)));
            failure = reason;
        }
        completed = 1;
    }

    function runNestedRollbackRestoresInnerThenOuterState() external {
        require(completed == 0, "one source transaction");
        try this.minimalOuterGroup() {
            revert("outer group committed");
        } catch (bytes memory reason) {
            _exact(reason, abi.encodeWithSelector(GroupUndone.selector));
        }
        lastRead = peer.readChain(0);
        require(lastRead == 0, "outer group's writes survived");
        completed = 1;
    }

    function singleWriteThenRevert(uint256 amount) external {
        require(msg.sender == address(this), "self only");
        require(peer.bump(amount) == amount, "write before rollback");
        revert GroupUndone();
    }

    function runStaticReadThenWriteWithCallback() external {
        require(completed == 0, "one source transaction");
        firstRead = peer.readChain(0);
        require(firstRead == 0, "initial read");
        result = peer.purchase();
        require(result == 13 && total == 3, "write and callback result");
        completed = 1;
    }

    function failAfterWrite() external returns (uint256) {
        total += 100;
        revert FrameFailed(0);
    }

    function runStaticReadThenCatchFailedWrite() external {
        require(completed == 0, "one source transaction");
        firstRead = peer.readChain(0);
        require(firstRead == 0, "initial read");
        try peer.failAfterWrite() returns (uint256) {
            revert("write unexpectedly succeeded");
        } catch (bytes memory reason) {
            _exact(reason, abi.encodeWithSelector(FrameFailed.selector, uint256(0)));
            failure = reason;
        }
        completed = 1;
    }

    function runStaticReadThenRollbackWrite() external {
        require(completed == 0, "one source transaction");
        firstRead = peer.readChain(0);
        require(firstRead == 0, "initial read");
        try this.singleWriteThenRevert(5) {
            revert("write group committed");
        } catch (bytes memory reason) {
            _exact(reason, abi.encodeWithSelector(GroupUndone.selector));
        }
        lastRead = peer.readChain(0);
        require(lastRead == 0, "write group's change survived");
        completed = 1;
    }

    function minimalOuterGroup() external {
        require(msg.sender == address(this), "self only");
        require(peer.bump(1) == 1, "outer write");
        try this.minimalInnerGroup() {
            revert("inner group committed");
        } catch (bytes memory reason) {
            _exact(reason, abi.encodeWithSelector(GroupUndone.selector));
        }
        require(peer.observeAndBump(1, 8) == 9, "next call must observe inner rollback");
        revert GroupUndone();
    }

    function minimalInnerGroup() external {
        require(msg.sender == address(this), "self only");
        require(peer.bump(2) == 3, "inner write");
        revert GroupUndone();
    }
}
