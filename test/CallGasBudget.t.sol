// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {TestHashes} from "./TestHashes.sol";
import {EEZ} from "../src/EEZ.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {ICrossChainProxy} from "../src/interfaces/ICrossChainProxy.sol";
import {CrossChainCall} from "../src/interfaces/IEEZL2.sol";
import {ExecutionEntry, L2ToL1Call, StaticExecutionEntry, ExpectedRootPerRollup} from "../src/interfaces/IEEZ.sol";

contract CallGasBudgetHarness is EEZL2 {
    constructor() EEZL2(2, address(0x1234), false, address(0x1234)) {}

    function probe(
        address proxy,
        address target,
        uint64 cap,
        bytes memory data,
        uint256 value,
        bool isStatic
    )
        external
        returns (bool enough, bool success, bytes memory result)
    {
        bytes memory payload = abi.encodeCall(ICrossChainProxy.executeOnBehalf, (target, cap, data));
        if (!_hasEnoughCallGas(cap, payload.length, value)) return (false, false, "");
        uint256 callGas = cap == 0 ? gasleft() : cap;
        if (isStatic) (success, result) = proxy.staticcall{gas: callGas}(payload);
        else (success, result) = proxy.call{value: value, gas: callGas}(payload);
        return (true, success, result);
    }

    function unprotected(address proxy, address target, uint64 cap) external returns (bool, bytes memory) {
        return proxy.call(abi.encodeCall(ICrossChainProxy.executeOnBehalf, (target, cap, bytes(""))));
    }

    function run(CrossChainCall[] memory calls) external returns (bytes32) {
        _rollingHash = bytes32(uint256(1));
        _processIncomingCalls(calls);
        bytes32 result = _rollingHash;
        _rollingHash = 0;
        return result;
    }

    function runStatic(CrossChainCall[] memory calls) external view returns (bytes32) {
        return _processStaticIncomingCalls(calls);
    }
}

contract GasBudgetTarget {
    function below(uint256 upperBound) external view returns (bool) {
        return gasleft() < upperBound;
    }
}

contract CallGasBudgetTest is Test, TestHashes {
    CallGasBudgetHarness h;
    address proxy;
    address constant TARGET = address(0xABCDEF);
    address constant DELEGATED = address(0xDE1E6A7E);
    address constant SOURCE = address(0xABCD);

    function setUp() public {
        h = new CallGasBudgetHarness();
        proxy = h.createCrossChainProxy(SOURCE, 1);
        vm.deal(address(h), 10 ether);
        // GAS is the first opcode: the returned sample is exactly the entry budget minus 2.
        vm.etch(TARGET, hex"5a5f5260205ff3");
        vm.etch(DELEGATED, abi.encodePacked(hex"ef0100", TARGET));
    }

    function _access(bool cold, address target) internal {
        if (cold) {
            vm.cool(proxy);
            vm.cool(target);
            if (target == DELEGATED) vm.cool(TARGET);
        } else {
            // EXTCODESIZE warms the accounts without executing their code.
            assertGt(proxy.code.length, 0);
            assertGt(target.code.length, 0);
            assertGt(TARGET.code.length, 0);
        }
    }

    function _probe(
        bytes memory payload,
        uint256 gasBudget
    )
        internal
        returns (bool enough, bool success, uint256 delivered)
    {
        (bool ok, bytes memory result) = address(h).call{gas: gasBudget}(payload);
        if (!ok) {
            // An extremely small outer budget may fail during decoding, before the guard.
            assertEq(result.length, 0, "unexpected probe revert");
            return (false, false, 0);
        }
        bytes memory returned;
        (enough, success, returned) = abi.decode(result, (bool, bool, bytes));
        if (!enough) return (false, false, 0);
        if (!success) {
            // A small proxy budget can run out during decoding, forwarding or return-data copying.
            assertEq(returned.length, 0, "unexpected proxy failure");
            return (true, false, 0);
        }
        assertEq(returned.length, 32);
        delivered = abi.decode(returned, (uint256)) + 2;
    }

    function test_ReproduceUnderfundedCallWithoutGuard() public {
        (bool ok, bytes memory result) = h.unprotected{gas: 80_000}(proxy, TARGET, 100_000);
        assertTrue(ok);
        assertLt(abi.decode(result, (uint256)) + 2, 100_000);
        (bool enough,,) = h.probe{gas: 80_000}(proxy, TARGET, 100_000, "", 0, false);
        assertFalse(enough);
    }

    function testFuzz_AcceptedBudgetBoundsTargetGas(uint64 cap, uint32 supplied, uint16 size, uint8 mode) public {
        cap = uint64(bound(cap, 100, 300_000));
        uint256 gasBudget = bound(supplied, 30_000, 700_000);
        bytes memory data = new bytes(size);
        bool isStatic = mode & 1 != 0;
        uint256 value = !isStatic && mode & 2 != 0 ? 1 : 0;
        address target = mode & 4 != 0 ? DELEGATED : TARGET;
        _access(mode & 8 != 0, target);
        (bool enough, bool success, uint256 delivered) =
            _probe(abi.encodeCall(h.probe, (proxy, target, cap, data, value, isStatic)), gasBudget);
        if (enough && success) assertLt(delivered, uint256(cap) + (value == 0 ? 0 : 2300));
    }

    function test_BoundaryBudgets_AllAccessValueAndPayloadModes() public {
        for (uint256 mode; mode < 16; mode++) {
            for (uint256 sizeCase; sizeCase < 4; sizeCase++) {
                uint256 size = sizeCase == 0 ? 0 : sizeCase == 1 ? 33 : sizeCase == 2 ? 4096 : 131_072;
                uint64 cap = sizeCase == 0 ? 100 : sizeCase == 1 ? 10_000 : 100_000;
                bool isStatic = mode & 1 != 0;
                uint256 value = !isStatic && mode & 2 != 0 ? 1 : 0;
                address target = mode & 4 != 0 ? DELEGATED : TARGET;
                bool cold = mode & 8 != 0;
                bytes memory payload = abi.encodeCall(h.probe, (proxy, target, cap, new bytes(size), value, isStatic));
                uint256 lo = 1;
                uint256 hi = 1_000_000;
                _access(cold, target);
                (bool baselineAccepted, bool baselineSuccess, uint256 baselineGas) = _probe(payload, hi);
                assertTrue(baselineAccepted);
                if (baselineSuccess) assertLt(baselineGas, uint256(cap) + (value == 0 ? 0 : 2300));
                // Find the first outer gas budget accepted by the actual helper, not a copy of its formula.
                while (lo < hi) {
                    uint256 mid = (lo + hi) / 2;
                    _access(cold, target);
                    (bool enough, bool success, uint256 delivered) = _probe(payload, mid);
                    if (enough) {
                        assertEq(success, baselineSuccess, "outer budget changed proxy outcome");
                        assertEq(delivered, baselineGas, "outer budget reduced target gas");
                        hi = mid;
                    } else {
                        lo = mid + 1;
                    }
                }
                _access(cold, target);
                (bool accepted, bool succeeded, uint256 gasDelivered) = _probe(payload, hi);
                assertTrue(accepted);
                assertEq(succeeded, baselineSuccess);
                assertEq(gasDelivered, baselineGas);
                _access(cold, target);
                (accepted,,) = _probe(payload, hi - 1);
                assertFalse(accepted);
            }
        }
    }

    function test_ZeroCapAndMaximumCap() public {
        (bool enough, bool ok, bytes memory returned) = h.probe{gas: 80_000}(proxy, TARGET, 0, "", 0, false);
        assertTrue(enough && ok);
        assertGt(abi.decode(returned, (uint256)), 0);
        (enough,,) = h.probe(proxy, TARGET, type(uint64).max, "", 0, false);
        assertFalse(enough, "uint64 cap must widen without overflow");
    }

    function _calls(uint64 cap, bool isStatic) internal pure returns (CrossChainCall[] memory calls) {
        calls = new CrossChainCall[](1);
        calls[0].sourceAddress = SOURCE;
        calls[0].sourceRollupId = 1;
        calls[0].targetAddress = TARGET;
        calls[0].gas = cap;
        calls[0].isStatic = isStatic;
    }

    function test_ProxyBudgetIncludesOverhead() public {
        for (uint256 mode; mode < 2; mode++) {
            (bool enough, bool success, bytes memory returned) =
                h.probe{gas: 100_000}(proxy, TARGET, 100, "", 0, mode == 1);
            assertTrue(enough, "outer budget is sufficient");
            assertFalse(success, "100 gas cannot cover the proxy's own work");
            assertEq(returned.length, 0);
        }
    }

    function _boundedCalls(uint64 cap, bool isStatic) internal returns (CrossChainCall[] memory calls) {
        vm.etch(TARGET, type(GasBudgetTarget).runtimeCode);
        calls = _calls(cap, isStatic);
        // A capped proxy must also pay its own work before the EIP-150 target forwarding limit.
        calls[0].data = abi.encodeCall(GasBudgetTarget.below, (uint256(cap) * 63 / 64));
    }

    function _identity(CrossChainCall memory c) internal pure returns (bytes32) {
        return _ccHash(c.isStatic, SOURCE, 1, TARGET, 2, c.value, c.data);
    }

    function testFuzz_ActualL2LoopMatchesProxyBudgetOrShortage(uint32 budget, bool isStatic) public {
        CrossChainCall[] memory calls = _boundedCalls(100_000, isStatic);
        bytes32 begun = _hCallBegin(bytes32(uint256(1)), _identity(calls[0]));
        bytes32 executed = _hCallEnd(begun, true, abi.encode(true));
        bytes32 shortage = _hCallInsufficientGas(begun);
        vm.cool(proxy);
        vm.cool(TARGET);
        (bool ok, bytes memory result) =
            address(h).call{gas: bound(budget, 50_000, 300_000)}(abi.encodeCall(h.run, (calls)));
        assertTrue(ok);
        bytes32 actual = abi.decode(result, (bytes32));
        assertTrue(actual == executed || actual == shortage, "loop did not enforce the proxy budget");
    }

    function test_ActualStaticLoopRejectsShortage() public {
        CrossChainCall[] memory calls = _boundedCalls(type(uint64).max, true);
        vm.expectRevert(abi.encodeWithSelector(EEZBase.InsufficientCallGas.selector, type(uint64).max));
        h.runStatic(calls);
        calls = _boundedCalls(100_000, true);
        assertEq(h.runStatic(calls), _hStatic(bytes32(0), true, abi.encode(true)));
    }

    function test_MarkerStopsLocalArrayAndSurvivesDeliberateRollback() public {
        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = _boundedCalls(type(uint64).max, false)[0];
        calls[1] = _boundedCalls(100_000, false)[0];
        bytes32 shortage = _hCallInsufficientGas(_hCallBegin(bytes32(uint256(1)), _identity(calls[0])));
        assertEq(h.run(calls), shortage, "must omit remaining calls");
        calls[0].revertNextNCalls = 1;
        bytes32 resumed = _hCallEnd(_hCallBegin(shortage, _identity(calls[1])), true, abi.encode(true));
        assertEq(h.run(calls), resumed, "span transports marker; parent array continues");
    }
}

contract CallGasBudgetL1Test is Base {
    address constant TARGET = address(0xABCDEF);

    function setUp() public {
        setUpBase();
        vm.etch(TARGET, type(GasBudgetTarget).runtimeCode);
    }

    function testFuzz_ActualL1ProxyBudgetAndPayload(uint64 cap, uint16 size, bool isStatic) public {
        cap = uint64(bound(cap, 100_000, 300_000));
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, bytes32(0), keccak256("next"));
        bytes memory data =
            bytes.concat(abi.encodeCall(GasBudgetTarget.below, (uint256(cap) * 63 / 64)), new bytes(size));
        L2ToL1Call memory c = _call(L2_SENDER, uint64(r.id), TARGET, 0, data);
        c.gas = cap;
        c.isStatic = isStatic;
        entries[0].l2ToL1Calls = _oneCall(c);
        bytes32 identity = _ccHash(isStatic, L2_SENDER, uint64(r.id), TARGET, 0, 0, c.data);
        entries[0].rollingHash = _hCallEnd(_hCallBegin(entries[0].rollingHash, identity), true, abi.encode(true));
        _postBatchAutoTransient(r, entries);
        assertEq(_getRollupState(r.id), keccak256("next"));
    }

    function test_L1StaticLookupUsesProxyBudget() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        uint64 rid = uint64(r.id);
        address outgoingProxy = rollups.createCrossChainProxy(L2_REMOTE, rid);
        rollups.createCrossChainProxy(L2_SENDER, rid);
        bytes memory query = hex"12345678";
        L2ToL1Call memory c =
            _staticCall(L2_SENDER, rid, TARGET, abi.encodeCall(GasBudgetTarget.below, (uint256(100_000) * 63 / 64)));
        c.gas = 100_000;
        StaticExecutionEntry[] memory statics = new StaticExecutionEntry[](1);
        statics[0].expectedRoots = new ExpectedRootPerRollup[](1);
        statics[0].expectedRoots[0] = ExpectedRootPerRollup({rollupId: rid, root: bytes32(0)});
        statics[0].proxyEntryHash = _ccHash(true, address(this), 0, L2_REMOTE, rid, 0, query);
        statics[0].l2ToL1Calls = _oneCall(c);
        statics[0].rollingHash = _hStatic(bytes32(0), true, abi.encode(true));
        statics[0].destinationRollupId = rid;
        statics[0].success = true;
        statics[0].returnData = abi.encode(true);
        _postBatchOne(r, _emptyEntries(), statics, 0, 0);
        vm.prank(outgoingProxy);
        assertEq(rollups.staticCrossChainCall(address(this), query), abi.encode(true));

        statics[0].l2ToL1Calls[0].gas = type(uint64).max;
        _postBatchOne(r, _emptyEntries(), statics, 0, 0);
        vm.prank(outgoingProxy);
        vm.expectRevert(abi.encodeWithSelector(EEZBase.InsufficientCallGas.selector, type(uint64).max));
        rollups.staticCrossChainCall(address(this), query);
    }

    function test_L1CommitsShortageOnlyWhenExpected() public {
        RollupHandle memory r = _makeRollup(bytes32(0));
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, bytes32(0), keccak256("next"));
        L2ToL1Call memory c = _call(L2_SENDER, uint64(r.id), TARGET, 0, "");
        c.gas = type(uint64).max;
        entries[0].l2ToL1Calls = _oneCall(c);
        bytes32 identity = _ccHash(false, L2_SENDER, uint64(r.id), TARGET, 0, 0, "");
        bytes32 begun = _hCallBegin(entries[0].rollingHash, identity);
        entries[0].rollingHash = _hCallEnd(begun, false, "");
        vm.expectRevert(EEZ.AllImmediateL2TxsFailed.selector);
        _postBatchAutoTransient(r, entries);
        entries[0].rollingHash = _hCallInsufficientGas(begun);
        _postBatchAutoTransient(r, entries);
        assertEq(_getRollupState(r.id), keccak256("next"));
    }
}
