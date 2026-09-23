// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// E2E_EXCLUDE_FROM_ALL: NOT LIVE YET (staged/parallel network tests).
// Validated on local Anvil only. Excluded from automatic all/default runs;
// select explicitly for local testing until live-network validation is complete.

// StaticLocalWriteL2: top-level static reads around local writes on L2.
// ONE user tx on L2; reader.run() on L2 performs:
//   rate = 1 -> STATIC quote on L1 -> STATIC callback rate on L2 -> 1
//   rate = 2 -> STATIC quote on L1 -> STATIC callback rate on L2 -> 2
//   rate = 1 -> STATIC quote on L1 -> STATIC callback rate on L2 -> 1
// Reader-side candidates share their key/context; row 1 must be skipped on the
// second read, and reused on the third. Neither static read consumes a row.
// L2: two static pool rows at entryIndex 0; one direct reader trigger.
// L1: ONE immediate zero-hash L2Tx entry executes all three real quotes;
// each quote's callback resolves from a position-pinned nested static row.
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
abstract contract StaticLocalWriteL2Actions is Script {
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
        return crossChainCallHash(true, a.reader, L2, a.quote, 0, 0, _quoteData());
    }

    function _rateHash(Actors memory a) internal pure returns (bytes32) {
        return crossChainCallHash(true, a.quote, 0, a.reader, L2, 0, _rateData());
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

    function _l2Callbacks(Actors memory a) internal pure returns (CrossChainCall[] memory calls) {
        calls = new CrossChainCall[](1);
        calls[0] = _l2Call(a.quote, a.reader, true, _rateData());
    }

    function _l2Statics(Actors memory a) internal pure returns (StaticExecutionEntryL2[] memory rows) {
        rows = new StaticExecutionEntryL2[](2);
        for (uint256 i; i < rows.length; i++) {
            rows[i].proxyEntryHash = _quoteHash(a);
            rows[i].expectedEntryIndex = 0;
            rows[i].incomingCalls = _l2Callbacks(a);
            rows[i].rollingHash = _callbackHash(i + 1);
            rows[i].success = true;
            rows[i].returnData = _quoteResult(i + 1);
        }
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
        // The three remote quotes execute for real on L1. Their callbacks into L2
        // resolve at three different host hashes, following the source transaction.
        e.l2ToL1Calls = new L2ToL1Call[](3);
        e.expectedL1ToL2Calls = new ExpectedL1ToL2Call[](3);
        for (uint256 i; i < 3; i++) {
            e.l2ToL1Calls[i] = _l1Call(a.reader, a.quote, true, _quoteData());
            rh = RollingHashBuilder.appendCallBegin(rh, _quoteHash(a));
            e.expectedL1ToL2Calls[i] = ExpectedL1ToL2Call({
                expectedL1toL2Hash: expectedL1toL2Hash(_rateHash(a), rh),
                l2ToL1Calls: new L2ToL1Call[](0),
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

contract Deploy is StaticLocalWriteL2Actions {
    function run() external {
        vm.startBroadcast();
        output("QUOTE", address(new CallbackQuote()));
        vm.stopBroadcast();
    }
}

contract DeployReaderL2 is StaticLocalWriteL2Actions {
    function run() external {
        IEEZ manager = IEEZ(vm.envAddress("MANAGER_L2"));
        vm.startBroadcast();
        address quoteProxy = getOrCreateProxy(manager, vm.envAddress("QUOTE"), 0);
        output("READER", address(new LocalWriteReader(quoteProxy)));
        vm.stopBroadcast();
    }
}

contract DeployCallbacks is StaticLocalWriteL2Actions {
    function run() external {
        IEEZ manager = IEEZ(vm.envAddress("ROLLUPS"));
        vm.startBroadcast();
        address readerProxy = getOrCreateProxy(manager, vm.envAddress("READER"), L2);
        output("READER_PROXY", readerProxy);
        vm.stopBroadcast();
    }
}

contract ExecuteL2 is StaticLocalWriteL2Actions {
    function run() external {
        Actors memory a = _actors();
        EEZL2 manager = EEZL2(vm.envAddress("MANAGER_L2"));
        vm.startBroadcast();
        manager.loadExecutionTable(new L2ExecutionEntry[](0), _l2Statics(a));
        LocalWriteReader(a.reader).run();
        _assertReader();
        require(manager.entryIndex() == 0, "unexpected mutable consumption");
        vm.stopBroadcast();
        console.log("done: L2 static reads around local writes");
    }
}

contract Execute is StaticLocalWriteL2Actions {
    function run() external {
        Actors memory a = _actors();
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        vm.startBroadcast();
        manager.postAndVerifyBatch(
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), L2, _l1Entries(a), new StaticExecutionEntry[](0))
        );
        (, bytes32 root,) = manager.rollups(L2);
        require(root == FINAL_ROOT, "unexpected root transition");
        vm.stopBroadcast();
        console.log("done: L1 static reads around local writes");
    }
}

contract ExecuteNetworkL2 is StaticLocalWriteL2Actions {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("READER"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(_runData()));
    }
}

contract VerifyNetworkL2 is StaticLocalWriteL2Actions {
    function run() external view {
        _assertReader();
        console.log("VERIFY_PASS: local rate 1 -> 2 -> 1, quotes 1 -> 2 -> 1");
    }
}

contract ComputeExpected is ComputeExpectedBase, StaticLocalWriteL2Actions {
    function run() external view {
        Actors memory a = _actors();
        ExecutionEntry[] memory l1 = _l1Entries(a);
        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(_entryHash(l1[0])));
        _printL1CallHashes(l1);
        HashStep[][] memory steps = new HashStep[][](1);
        steps[0] = new HashStep[](6);
        for (uint256 i; i < 3; i++) {
            steps[0][2 * i] = RollingHashBuilder.stepCallBegin(_quoteHash(a));
            steps[0][2 * i + 1] = RollingHashBuilder.stepCallEnd(true, _quoteResult(_rateAt(i)));
        }
        _printL1Steps(l1, steps);
        _printL1Table(l1);
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("EXPECTED_L2_CALL_HASHES=[]");
    }
}
