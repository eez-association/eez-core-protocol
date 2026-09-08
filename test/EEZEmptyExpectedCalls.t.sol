// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {EEZ} from "../src/EEZ.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {ExecutionEntry} from "../src/interfaces/IEEZ.sol";

contract EmptyTableProbe {
    bool public called;
    bool public success;
    bytes public result;

    function probe(address proxy, bool readOnly) external {
        called = true;
        if (readOnly) (success, result) = proxy.staticcall(hex"12345678");
        else (success, result) = proxy.call(hex"12345678");
    }
}

contract EEZEmptyExpectedCallsTest is Base {
    address internal entryProxy;
    bool internal hookRan;

    function setUp() public {
        setUpBase();
    }

    function executeMetaCrossChainTransactions() external {
        require(msg.sender == address(rollups), "only registry");
        hookRan = true;
        (bool ok,) = entryProxy.call("");
        require(ok, "entry failed");
    }

    function _run(uint256 mode, bool readOnly, bool commitNoMatch) internal {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        EmptyTableProbe probe = new EmptyTableProbe();
        entryProxy = rollups.createCrossChainProxy(L2_REMOTE, rid);
        bytes memory data = abi.encodeCall(EmptyTableProbe.probe, (entryProxy, readOnly));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(rid, bytes32(0), bytes32(uint256(1)));
        if (mode != 0) {
            entries[0].proxyEntryHash = _ccHash(false, address(this), 0, L2_REMOTE, rid, 0, "");
        }
        entries[0].l2ToL1Calls = _oneCall(_call(L2_SENDER, rid, address(probe), 0, data));
        bytes32 h = _hCallBegin(
            _hEntryBegin(entries[0].rollupUpdates, entries[0].proxyEntryHash),
            _ccHash(false, L2_SENDER, rid, address(probe), 0, 0, data)
        );
        if (!readOnly && commitNoMatch) {
            h = _hCallNotFound(h, _ccHash(false, address(probe), 0, L2_REMOTE, rid, 0, hex"12345678"));
        }
        entries[0].rollingHash = _hCallEnd(h, true, "");

        if (!commitNoMatch && !readOnly) {
            vm.expectRevert(EEZ.AllImmediateL2TxsFailed.selector);
        }
        _postBatchOne(r, entries, _emptyStaticEntries(), mode == 1 ? 0 : 1, 0);
        if (!commitNoMatch && !readOnly) {
            assertFalse(probe.called());
            assertEq(_getRollupState(rid), bytes32(0));
            return;
        }
        if (mode == 1) {
            (bool ok,) = entryProxy.call("");
            assertTrue(ok);
        }
        assertEq(hookRan, mode == 2);
        assertTrue(probe.called());
        assertEq(probe.success(), !readOnly);
        if (readOnly) assertEq(probe.result(), abi.encodeWithSelector(EEZBase.ExecutionNotFound.selector));
        else assertEq(probe.result(), bytes(""));
        assertEq(_getRollupState(rid), bytes32(uint256(1)));
    }

    function test_ImmediateEmptyCallTable() public {
        _run(0, false, true);
    }

    function test_QueuedEmptyCallTable() public {
        _run(1, false, true);
    }

    function test_MetaHookEmptyCallTable() public {
        _run(2, false, true);
    }

    function test_ImmediateEmptyStaticTable() public {
        _run(0, true, true);
    }

    function test_QueuedEmptyStaticTable() public {
        _run(1, true, true);
    }

    function test_MetaHookEmptyStaticTable() public {
        _run(2, true, true);
    }

    function test_UncommittedNoMatchStillRejectsImmediateEntry() public {
        _run(0, false, false);
    }
}
