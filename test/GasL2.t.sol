// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {BaseL2} from "./BaseL2.t.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {GasMeter} from "./helpers/GasMeter.sol";
import {ExecutionEntry, StaticExecutionEntryL2, CrossChainCall} from "../src/interfaces/IEEZL2.sol";

contract GasL2Sink {
    fallback() external {}
}

/// @notice L2 EVM execution gas only, with observed-gas hash keying disabled as in BaseL2.
///         Run with --isolate. Excludes L2 transaction fees, calldata/DA charges and proving.
///         Existing dispatch proxies are reused; measurements use vm.lastCallGas.
contract GasL2 is BaseL2 {
    GasMeter internal meter;
    address internal alice = address(0xA11CE);
    address internal remote = address(0xBEEF);
    address internal proxy;
    address internal incomingProxy;
    GasL2Sink internal sink;

    function setUp() public override {
        super.setUp();
        proxy = manager.createCrossChainProxy(remote, MAINNET);
        incomingProxy = manager.createCrossChainProxy(alice, MAINNET);
        sink = new GasL2Sink();
        meter = new GasMeter();
    }

    function _emit(string memory label, uint256 value) internal pure {
        console.log(string.concat("bench.l2.", label), value);
    }

    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(sink));
        vm.cool(incomingProxy);
    }

    function _rows(uint256 n) internal pure returns (ExecutionEntry[] memory entries) {
        entries = new ExecutionEntry[](n);
        for (uint256 i; i < n; i++) {
            entries[i] = _buildNoCalls(keccak256(abi.encode(i)), abi.encode(uint256(42)));
        }
    }

    function _loadGas(
        ExecutionEntry[] memory entries,
        StaticExecutionEntryL2[] memory statics
    )
        internal
        returns (uint256)
    {
        _cool();
        return meter.measure(
            address(manager), SYSTEM_ADDRESS, abi.encodeCall(EEZL2.loadExecutionTable, (entries, statics)), false
        )
        .gasUsed;
    }

    function test_TableLoading() public {
        uint256[4] memory sizes = [uint256(0), 1, 2, 8];
        StaticExecutionEntryL2[] memory empty = new StaticExecutionEntryL2[](0);
        for (uint256 i; i < sizes.length; i++) {
            uint256 snapshot = vm.snapshotState();
            ExecutionEntry[] memory entries = _rows(sizes[i]);
            uint256 first = _loadGas(entries, empty);
            vm.roll(block.number + 1);
            uint256 repeat = _loadGas(entries, empty);
            _emit(string.concat("load.entries.", vm.toString(sizes[i]), ".first"), first);
            _emit(string.concat("load.entries.", vm.toString(sizes[i]), ".replacement"), repeat);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_OutgoingL2ToL1Scan() public {
        uint256[3] memory sizes = [uint256(1), 8, 32];
        bytes32 hash = _outgoingCallHash(alice, remote, MAINNET, 0, 0, "");
        for (uint256 i; i < sizes.length; i++) {
            uint256 snapshot = vm.snapshotState();
            ExecutionEntry[] memory entries = _rows(sizes[i]);
            entries[sizes[i] - 1] = _buildNoCalls(hash, abi.encode(uint256(42)));
            _loadEntries(entries, new StaticExecutionEntryL2[](0));
            _cool();
            GasMeter.Sample memory sample = meter.measure(proxy, alice, "", false);
            uint256 gasUsed = sample.gasUsed;
            assertEq(sample.data, abi.encode(uint256(42)));
            assertEq(manager.entryIndex(), sizes[i]);
            _emit(string.concat("outgoing.match_at_position.", vm.toString(sizes[i])), gasUsed);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_StaticLookup() public {
        uint256[3] memory sizes = [uint256(1), 8, 32];
        for (uint256 k; k < sizes.length; k++) {
            StaticExecutionEntryL2[] memory entries = new StaticExecutionEntryL2[](sizes[k]);
            for (uint256 i; i < sizes[k]; i++) {
                entries[i].proxyEntryHash = _ccHash(IS_STATIC, alice, TEST_ROLLUP_ID, remote, MAINNET, 0, abi.encode(i));
                entries[i].success = true;
                entries[i].returnData = abi.encode(uint256(42));
                entries[i].incomingCalls = new CrossChainCall[](0);
            }
            _loadEntries(new ExecutionEntry[](0), entries);
            bytes memory data = abi.encode(sizes[k] - 1);
            _cool();
            GasMeter.Sample memory sample = meter.measure(proxy, alice, data, true);
            uint256 gasUsed = sample.gasUsed;
            assertEq(sample.data, abi.encode(uint256(42)));
            _emit(string.concat("static.match_at_position.", vm.toString(sizes[k])), gasUsed);
        }
    }

    function _incomingRows(uint256 n) internal view returns (ExecutionEntry[] memory entries) {
        CrossChainCall memory call = _cc(address(sink), 0, hex"12345678", alice, MAINNET);
        bytes32 hash = _incomingCallHash(call);
        entries = new ExecutionEntry[](1);
        entries[0] = _buildSimpleEntry(hash, call, "", bytes32(0));
        entries[0].incomingCalls = new CrossChainCall[](n);
        bytes32 rolling = _hEntryBeginL2(hash);
        for (uint256 i; i < n; i++) {
            entries[0].incomingCalls[i] = call;
            rolling = _hCallEnd(_hCallBegin(rolling, hash), true, "");
        }
        entries[0].rollingHash = rolling;
    }

    function test_IncomingL1ToL2Delivery() public {
        uint256 previous;
        for (uint256 n = 1; n <= 2; n++) {
            uint256 snapshot = vm.snapshotState();
            ExecutionEntry[] memory entries = _incomingRows(n);
            StaticExecutionEntryL2[] memory empty = new StaticExecutionEntryL2[](0);
            vm.prank(SYSTEM_ADDRESS);
            manager.executeIncomingCrossChainCall(entries, empty);
            vm.roll(block.number + 1);
            _cool();
            uint256 gasUsed =
                meter.measure(
                address(manager),
                SYSTEM_ADDRESS,
                abi.encodeCall(EEZL2.executeIncomingCrossChainCall, (entries, empty)),
                false
            )
            .gasUsed;
            assertEq(manager.entryIndex(), 1);
            _emit(string.concat("incoming.delivery.", vm.toString(n), "_calls"), gasUsed);
            if (n == 2) _emit("incoming.extra_call", gasUsed - previous);
            previous = gasUsed;
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }
}
