// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// E2E_EXCLUDE_FROM_ALL: NOT LIVE YET (staged/parallel network tests).
// Validated on local Anvil only. Excluded from automatic all/default runs;
// select explicitly for local testing until live-network validation is complete.

// NestedStaticLocalWriteL1: nested static reads around local writes on L1.
// ONE user tx on L2; reader.run() on L1 performs:
//   rate = 1 -> STATIC quote on L2 -> STATIC callback rate on L1 -> 1
//   rate = 2 -> STATIC quote on L2 -> STATIC callback rate on L1 -> 2
//   rate = 1 -> STATIC quote on L2 -> STATIC callback rate on L1 -> 1
// Reader-side candidates share their key/context; row 1 must be skipped on the
// second read, and reused on the third. Neither static read consumes a row.
// L2: ONE outgoing reader.run() entry executes the three real quotes and
// resolves their callbacks from position-pinned rows. No later delivery.
// L1: ONE immediate zero-hash L2Tx entry runs reader.run(); its two sibling
// quote rows execute the real local rate() callbacks at one unchanged host hash.
// Final reader state: rate=1, quoteAtRate1=1, quoteAtRate2=2, quoteAfterResetToRate1=1, runs=1.

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {
    IEEZ,
    RollupUpdate,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    ExecutionEntry,
    StaticExecutionEntry
} from "../../../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    StaticExecutionEntryL2
} from "../../../../../src/interfaces/IEEZL2.sol";
import {ComputeExpectedBase} from "../../../shared/ComputeExpectedBase.sol";
import {
    output,
    getOrCreateProxy,
    crossChainCallHash,
    expectedL1toL2Hash,
    immediateSingleRollupBatch,
    RollingHashBuilder,
    HashStep
} from "../../../shared/E2EHelpers.sol";

interface ILocalRate {
    function rate() external view returns (uint256);
}

/// @notice The real remote producer calls back through its caller's source proxy.
contract CallbackQuote {
    function quote() external view returns (uint256) {
        return ILocalRate(msg.sender).rate();
    }
}

/// @notice All writes and reads happen inside one invocation, with no table reload.
contract LocalWriteReader {
    CallbackQuote public immutable remote;
    uint256 public rate;
    uint256 public quoteAtRate1;
    uint256 public quoteAtRate2;
    uint256 public quoteAfterResetToRate1;
    uint256 public runs;

    constructor(address proxy) {
        remote = CallbackQuote(proxy);
    }

    function run() external {
        rate = 1;
        quoteAtRate1 = remote.quote();
        require(quoteAtRate1 == 1, "quote must read rate 1");

        rate = 2;
        quoteAtRate2 = remote.quote();
        require(quoteAtRate2 == 2, "quote must read updated rate 2");

        rate = 1;
        quoteAfterResetToRate1 = remote.quote();
        require(quoteAfterResetToRate1 == 1, "quote must read reset rate 1");
        runs++;
    }
}

/// @notice Entry builders for this scenario's two views of the same source transaction.
abstract contract NestedStaticLocalWriteL1Actions is Script {
    uint64 internal constant L2 = 1;
    bytes32 internal constant INITIAL_ROOT = keccak256("l2-initial-state");
    bytes32 internal constant FINAL_ROOT = keccak256("l2-after-static-local-write");

    struct Actors {
        address reader;
        address quote;
        address alice;
    }

    function _actors() internal view returns (Actors memory a) {
        return Actors(vm.envAddress("READER"), vm.envAddress("QUOTE"), msg.sender);
    }

    function _quoteData() internal pure returns (bytes memory) {
        return abi.encodeCall(CallbackQuote.quote, ());
    }

    function _rateData() internal pure returns (bytes memory) {
        return abi.encodeCall(ILocalRate.rate, ());
    }

    function _runData() internal pure returns (bytes memory) {
        return abi.encodeCall(LocalWriteReader.run, ());
    }

    function _quoteHash(Actors memory a) internal pure returns (bytes32) {
        return crossChainCallHash(true, a.reader, 0, a.quote, L2, 0, _quoteData());
    }

    function _rateHash(Actors memory a) internal pure returns (bytes32) {
        return crossChainCallHash(true, a.quote, L2, a.reader, 0, 0, _rateData());
    }

    function _quoteResult(uint256 rate) internal pure returns (bytes memory) {
        return abi.encode(rate);
    }

    function _callbackHash(uint256 rate) internal pure returns (bytes32) {
        return RollingHashBuilder.appendStatic(bytes32(0), true, abi.encode(rate));
    }

    function _assertReader() internal view {
        LocalWriteReader reader = LocalWriteReader(vm.envAddress("READER"));
        require(reader.quoteAtRate1() == 1, "stored quote at rate 1 mismatch");
        require(reader.quoteAtRate2() == 2, "stored quote at rate 2 mismatch");
        require(reader.quoteAfterResetToRate1() == 1, "stored quote after reset mismatch");
        require(reader.rate() == 1 && reader.runs() == 1, "reader state mismatch");
    }

    function _runHash(Actors memory a) internal pure returns (bytes32) {
        return crossChainCallHash(false, a.alice, L2, a.reader, 0, 0, _runData());
    }

    function _rateAt(uint256 i) internal pure returns (uint256) {
        return i == 1 ? 2 : 1;
    }

    function _deltas() internal pure returns (RollupUpdate[] memory deltas) {
        deltas = new RollupUpdate[](1);
        deltas[0] = RollupUpdate({rollupId: L2, currentRoot: INITIAL_ROOT, newRoot: FINAL_ROOT, etherDelta: 0});
    }

    function _l1Call(
        address source,
        address target,
        bool isStatic,
        bytes memory data
    )
        internal
        pure
        returns (L2ToL1Call memory c)
    {
        c.sourceAddress = source;
        c.sourceRollupId = L2;
        c.targetAddress = target;
        c.isStatic = isStatic;
        c.data = data;
    }

    function _l1Callbacks(Actors memory a) internal pure returns (L2ToL1Call[] memory calls) {
        calls = new L2ToL1Call[](1);
        calls[0] = _l1Call(a.quote, a.reader, true, _rateData());
    }

    function _l2Call(
        address source,
        address target,
        bool isStatic,
        bytes memory data
    )
        internal
        pure
        returns (CrossChainCall memory c)
    {
        c.sourceAddress = source;
        c.sourceRollupId = 0;
        c.targetAddress = target;
        c.isStatic = isStatic;
        c.data = data;
    }

    function _l1Entries(Actors memory a) internal pure returns (ExecutionEntry[] memory entries) {
        entries = new ExecutionEntry[](1);
        ExecutionEntry memory e;
        e.rollupUpdates = _deltas();
        e.proxyEntryHash = bytes32(0);
        e.destinationRollupId = L2;
        e.success = true;
        e.returnData = "";
        bytes32 rh = RollingHashBuilder.entryBegin(e.rollupUpdates, e.proxyEntryHash);
        // One actual reader.run() on L1; all three quote resolutions fire at this hash.
        e.l2ToL1Calls = new L2ToL1Call[](1);
        e.l2ToL1Calls[0] = _l1Call(a.alice, a.reader, false, _runData());
        rh = RollingHashBuilder.appendCallBegin(rh, _runHash(a));
        e.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](2);
        for (uint256 i; i < 2; i++) {
            e.expectedL1ToL2Calls[i] = ExpectedL1ToL2Call({
                expectedL1toL2Hash: expectedL1toL2Hash(_quoteHash(a), rh),
                l2ToL1Calls: _l1Callbacks(a),
                revertedOrStaticRollingHash: _callbackHash(i + 1),
                success: true,
                returnData: _quoteResult(i + 1)
            });
        }
        rh = RollingHashBuilder.appendCallEnd(rh, true, "");
        e.rollingHash = rh;
        entries[0] = e;
    }

    function _l2Entries(Actors memory a) internal pure returns (L2ExecutionEntry[] memory entries) {
        entries = new L2ExecutionEntry[](1);
        L2ExecutionEntry memory e;
        e.proxyEntryHash = _runHash(a);
        e.success = true;
        e.returnData = "";
        bytes32 rh = RollingHashBuilder.entryBeginL2(e.proxyEntryHash);
        e.incomingCalls = new CrossChainCall[](3);
        e.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](3);
        for (uint256 i; i < 3; i++) {
            e.incomingCalls[i] = _l2Call(a.reader, a.quote, true, _quoteData());
            rh = RollingHashBuilder.appendCallBegin(rh, _quoteHash(a));
            e.expectedOutgoingCalls[i] = ExpectedOutgoingCrossChainCall({
                expectedOutgoingHash: expectedL1toL2Hash(_rateHash(a), rh),
                incomingCalls: new CrossChainCall[](0),
                revertedOrStaticRollingHash: bytes32(0),
                success: true,
                returnData: abi.encode(_rateAt(i))
            });
            rh = RollingHashBuilder.appendCallEnd(rh, true, _quoteResult(_rateAt(i)));
        }
        e.rollingHash = rh;
        entries[0] = e;
    }
}

contract DeployL2 is NestedStaticLocalWriteL1Actions {
    function run() external {
        vm.startBroadcast();
        output("QUOTE", address(new CallbackQuote()));
        vm.stopBroadcast();
    }
}

contract DeployReader is NestedStaticLocalWriteL1Actions {
    function run() external {
        IEEZ manager = IEEZ(vm.envAddress("ROLLUPS"));
        vm.startBroadcast();
        address quoteProxy = getOrCreateProxy(manager, vm.envAddress("QUOTE"), L2);
        output("READER", address(new LocalWriteReader(quoteProxy)));
        vm.stopBroadcast();
    }
}

contract DeployCallbacksL2 is NestedStaticLocalWriteL1Actions {
    function run() external {
        IEEZ manager = IEEZ(vm.envAddress("MANAGER_L2"));
        vm.startBroadcast();
        address readerProxy = getOrCreateProxy(manager, vm.envAddress("READER"), 0);
        output("READER_PROXY", readerProxy);
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is NestedStaticLocalWriteL1Actions {
    function run() external {
        Actors memory a = _actors();
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        vm.startBroadcast();
        manager.loadExecutionTable(_l2Entries(a), new StaticExecutionEntryL2[](0));
        LocalWriteReader(vm.envAddress("READER_PROXY")).run();
        require(manager.entryIndex() == 1, "unexpected mutable consumption");
        vm.stopBroadcast();
        console.log("done: L2 static reads around local writes");
    }
}

contract Execute is NestedStaticLocalWriteL1Actions {
    function run() external {
        Actors memory a = _actors();
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        vm.startBroadcast();
        manager.postAndVerifyBatch(
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), L2, _l1Entries(a), new StaticExecutionEntry[](0))
        );
        _assertReader();
        (, bytes32 root,) = manager.rollups(L2);
        require(root == FINAL_ROOT, "unexpected root transition");
        vm.stopBroadcast();
        console.log("done: L1 static reads around local writes");
    }
}

contract ExecuteNetworkL2 is NestedStaticLocalWriteL1Actions {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("READER_PROXY"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(_runData()));
    }
}

contract VerifyNetwork is NestedStaticLocalWriteL1Actions {
    function run() external view {
        _assertReader();
        console.log("VERIFY_PASS: local rate 1 -> 2 -> 1, quotes 1 -> 2 -> 1");
    }
}

contract ComputeExpected is ComputeExpectedBase, NestedStaticLocalWriteL1Actions {
    function run() external view {
        Actors memory a = _actors();
        ExecutionEntry[] memory l1 = _l1Entries(a);
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        _printL1CallHashes(l1);
        HashStep[][] memory steps = new HashStep[][](1);
        steps[0] = new HashStep[](2);
        steps[0][0] = RollingHashBuilder.stepCallBegin(_runHash(a));
        steps[0][1] = RollingHashBuilder.stepCallEnd(true, "");
        _printL1Steps(l1, steps);
        _printL1Table(l1);
        L2ExecutionEntry[] memory l2 = _l2Entries(a);
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(_entryHash(l2[0])));
        _printL2CallHashes(l2);
        _printL2Table(l2);
    }
}
