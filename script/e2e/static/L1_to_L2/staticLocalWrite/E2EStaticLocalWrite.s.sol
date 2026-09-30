// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// E2E_EXCLUDE_FROM_ALL: NOT LIVE YET (staged/parallel network tests).
// Validated on local Anvil only. Excluded from automatic all/default runs;
// select explicitly for local testing until live-network validation is complete.

// StaticLocalWrite: top-level static reads around local writes on L1.
// ONE user tx on L1; reader.run() on L1 performs:
//   rate = 1 -> STATIC quote on L2 -> STATIC callback rate on L1 -> 1
//   rate = 2 -> STATIC quote on L2 -> STATIC callback rate on L1 -> 2
//   rate = 1 -> STATIC quote on L2 -> STATIC callback rate on L1 -> 1
// Reader-side candidates share their key/context; row 1 must be skipped on the
// second read, and reused on the third. Neither static read consumes a row.
// L1: static pool with two rows, same root pins; no ExecutionEntry.
// L2: no delivery. Fork-only predictions run the real quote with the source
// callback results; the quote key must be absent from all mined L2 tables/events.
// Final reader state: rate=1, quoteAtRate1=1, quoteAtRate2=2, quoteAfterResetToRate1=1, runs=1.

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "../../../../../src/EEZ.sol";
import {EEZL2} from "../../../../../src/L2/EEZL2.sol";
import {
    IEEZ,
    L2ToL1Call,
    ExecutionEntry,
    StaticExecutionEntry,
    ExpectedRootPerRollup
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
    immediateSingleRollupBatch,
    RollingHashBuilder
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
abstract contract StaticLocalWriteActions is Script {
    uint64 internal constant L2 = 1;
    bytes32 internal constant INITIAL_ROOT = keccak256("l2-initial-state");

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

    // Raw return bytes from the real L2 quote's read-only prediction.
    function _quoteResult(uint256 rate) internal view returns (bytes memory) {
        return vm.envBytes(rate == 1 ? "PREDICTED_QUOTE_ONE" : "PREDICTED_QUOTE_TWO");
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

    function _l1Callbacks(Actors memory a) internal pure returns (L2ToL1Call[] memory calls) {
        calls = new L2ToL1Call[](1);
        calls[0] = _l1Call(a.quote, a.reader, true, _rateData());
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

    function _l1Statics(Actors memory a) internal view returns (StaticExecutionEntry[] memory rows) {
        rows = new StaticExecutionEntry[](2);
        for (uint256 i; i < rows.length; i++) {
            rows[i].proxyEntryHash = _quoteHash(a);
            rows[i].destinationRollupId = L2;
            rows[i].expectedRoots = new ExpectedRootPerRollup[](1);
            rows[i].expectedRoots[0] = ExpectedRootPerRollup(L2, INITIAL_ROOT);
            rows[i].l2ToL1Calls = _l1Callbacks(a);
            rows[i].rollingHash = _callbackHash(i + 1);
            rows[i].success = true;
            rows[i].returnData = _quoteResult(i + 1);
        }
    }
}

contract DeployL2 is StaticLocalWriteActions {
    function run() external {
        vm.startBroadcast();
        output("QUOTE", address(new CallbackQuote()));
        vm.stopBroadcast();
    }
}

contract DeployReader is StaticLocalWriteActions {
    function run() external {
        IEEZ manager = IEEZ(vm.envAddress("ROLLUPS"));
        vm.startBroadcast();
        address quoteProxy = getOrCreateProxy(manager, vm.envAddress("QUOTE"), L2);
        output("READER", address(new LocalWriteReader(quoteProxy)));
        vm.stopBroadcast();
    }
}

contract DeployCallbacksL2 is StaticLocalWriteActions {
    function run() external {
        IEEZ manager = IEEZ(vm.envAddress("MANAGER_L2"));
        vm.startBroadcast();
        address readerProxy = getOrCreateProxy(manager, vm.envAddress("READER"), 0);
        output("READER_PROXY", readerProxy);
        vm.stopBroadcast();
        _predictQuotes(EEZL2(address(manager)), readerProxy);
    }

    /// @dev Only fork simulation after broadcast stops: execute the real quote with
    ///      source-trace callback values. No prediction table or L2 delivery is mined.
    function _predictQuotes(EEZL2 manager, address readerProxy) private {
        Actors memory a = _actors();
        for (uint256 i; i < 2; i++) {
            StaticExecutionEntryL2[] memory rows = new StaticExecutionEntryL2[](1);
            rows[0].proxyEntryHash = _rateHash(a);
            rows[0].incomingCalls = new CrossChainCall[](0);
            rows[0].success = true;
            rows[0].returnData = abi.encode(i + 1);
            vm.prank(manager.SYSTEM_ADDRESS());
            manager.loadExecutionTable(new L2ExecutionEntry[](0), rows);
            vm.prank(readerProxy);
            (bool ok, bytes memory result) = a.quote.staticcall(_quoteData());
            require(ok && abi.decode(result, (uint256)) == (i + 1), "quote prediction failed");
            output(i == 0 ? "PREDICTED_QUOTE_ONE" : "PREDICTED_QUOTE_TWO", result);
        }
    }
}

contract Execute is StaticLocalWriteActions {
    function run() external {
        Actors memory a = _actors();
        EEZ manager = EEZ(vm.envAddress("ROLLUPS"));
        vm.startBroadcast();
        manager.postAndVerifyBatch(
            immediateSingleRollupBatch(vm.envAddress("PROOF_SYSTEM"), L2, new ExecutionEntry[](0), _l1Statics(a))
        );
        LocalWriteReader(a.reader).run();
        _assertReader();
        (, bytes32 root,) = manager.rollups(L2);
        require(root == INITIAL_ROOT, "unexpected root transition");
        vm.stopBroadcast();
        console.log("done: L1 static reads around local writes");
    }
}

contract ExecuteNetwork is StaticLocalWriteActions {
    function run() external view {
        console.log("TARGET=%s", vm.envAddress("READER"));
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(_runData()));
    }
}

contract VerifyNetwork is StaticLocalWriteActions {
    function run() external view {
        _assertReader();
        console.log("VERIFY_PASS: local rate 1 -> 2 -> 1, quotes 1 -> 2 -> 1");
    }
}

contract ComputeExpected is ComputeExpectedBase, StaticLocalWriteActions {
    function run() external view {
        Actors memory a = _actors();
        console.log("EXPECTED_L1_HASHES=[]");
        console.log("EXPECTED_L1_CALL_HASHES=[]");
        console.log("ABSENT_L2_HASHES=[%s]", vm.toString(_quoteHash(a)));
        _printL1StaticTable(_l1Statics(a));
        console.log("EXPECTED_L2_HASHES=[]");
        console.log("EXPECTED_L2_CALL_HASHES=[]");
    }
}
