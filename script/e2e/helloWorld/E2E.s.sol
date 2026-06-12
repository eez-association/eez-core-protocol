// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../../src/EEZ.sol";
import {EEZL2} from "../../../src/L2/EEZL2.sol";
import {StateDelta, ExecutionEntry, LookupCall, ExpectedLookup} from "../../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    LookupCall as L2LookupCall,
    ExpectedLookup as L2ExpectedLookup,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall
} from "../../../src/interfaces/IEEZL2.sol";
import {HelloWorldL1, HelloWorldL2, IHelloWorldL2} from "../../../test/mocks/helloword.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {
    crossChainCallHash,
    noLookupCalls,
    noNestedActions,
    noCalls,
    RollingHashBuilder
} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  HelloWorld scenario — L1→L2 with rich return data, two-sided
//
//  L1 side (Execute):
//    HelloWorldL1.helloL2World() → HelloWorldProxy@L1 → EEZ.executeCrossChainCall
//    consumes the L1 entry whose returnData == abi.encode("World"); helloL2World
//    returns that string back to the caller.
//
//  L2 side (ExecuteL2):
//    SYSTEM_ADDRESS calls managerL2.executeIncomingCrossChainCall(...) which
//    forwards into the real HelloWorldL2.getWord() — it returns abi.encode("World")
//    and the rolling hash commits to that retdata.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract HelloActions {
    function _getWordCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHelloWorldL2.getWord.selector);
    }

    function _callHash(address helloL2, address helloL1) internal pure returns (bytes32) {
        return crossChainCallHash(L2_ROLLUP_ID, helloL2, 0, _getWordCallData(), helloL1, MAINNET_ROLLUP_ID);
    }

    function _l1Entries(address helloL2, address helloL1) internal pure returns (ExecutionEntry[] memory entries) {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-helloworld"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            proxyEntryHash: _callHash(helloL2, helloL1),
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            expectedLookups: new ExpectedLookup[](0),
            callCount: 0,
            returnData: abi.encode("World"),
            rollingHash: bytes32(0)
        });
    }

    function _l2Entries(address helloL2, address helloL1) internal pure returns (L2ExecutionEntry[] memory entries) {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            targetAddress: helloL2,
            value: 0,
            data: _getWordCallData(),
            sourceAddress: helloL1,
            sourceRollupId: MAINNET_ROLLUP_ID,
            revertSpan: 0
        });

        bytes32 rh = bytes32(0);
        rh = RollingHashBuilder.appendCallBegin(rh, 1);
        rh = RollingHashBuilder.appendCallEnd(rh, 1, true, abi.encode("World"));

        entries = new L2ExecutionEntry[](1);
        entries[0] = L2ExecutionEntry({
            proxyEntryHash: _callHash(helloL2, helloL1),
            incomingCalls: calls,
            expectedOutgoingCalls: new ExpectedOutgoingCrossChainCall[](0),
            expectedLookups: new L2ExpectedLookup[](0),
            callCount: 1,
            returnData: abi.encode("World"),
            rollingHash: rh
        });
    }
}

contract DeployL2 is Script {
    function run() external {
        vm.startBroadcast();
        HelloWorldL2 h = new HelloWorldL2("World");
        console.log("HELLO_WORLD_L2=%s", address(h));
        vm.stopBroadcast();
    }
}

contract Deploy is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address helloL2Addr = vm.envAddress("HELLO_WORLD_L2");

        vm.startBroadcast();
        EEZ rollups = EEZ(rollupsAddr);

        address helloL2Proxy;
        try rollups.createCrossChainProxy(helloL2Addr, L2_ROLLUP_ID) returns (address p) {
            helloL2Proxy = p;
        } catch {
            helloL2Proxy = rollups.computeCrossChainProxyAddress(helloL2Addr, L2_ROLLUP_ID);
        }

        HelloWorldL1 h1 = new HelloWorldL1(helloL2Proxy);

        console.log("HELLO_WORLD_PROXY=%s", helloL2Proxy);
        console.log("HELLO_WORLD_L1=%s", address(h1));
        vm.stopBroadcast();
    }
}

contract Batcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        HelloWorldL1 h1
    )
        external
        returns (string memory greeting)
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        uint256[] memory rids = new uint256[](1);
        rids[0] = L2_ROLLUP_ID;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](psList.length);
        for (uint256 _i = 0; _i < psList.length; _i++) {
            psIdx[_i] = uint64(_i);
        }
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](rids.length);
        for (uint256 _i = 0; _i < rids.length; _i++) {
            rps[_i] = RollupIdWithProofSystems({rollupId: rids[_i], proofSystemIndex: psIdx});
        }

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            blockNumber: 0,
            entries: entries,
            l1ToL2lookupCalls: lookupCalls,
            transientExecutionEntryCount: 0,
            transientLookupCallCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
        greeting = h1.helloL2World();
    }
}

/// @title ExecuteL2 — local mode: system-driven L2 simulation that invokes the real getWord().
/// Env: MANAGER_L2, HELLO_WORLD_L2, HELLO_WORLD_L1
contract ExecuteL2 is Script, HelloActions {
    function run() external {
        address managerAddr = vm.envAddress("MANAGER_L2");
        address helloL2Addr = vm.envAddress("HELLO_WORLD_L2");
        address helloL1Addr = vm.envAddress("HELLO_WORLD_L1");

        vm.startBroadcast();
        bytes memory ret = EEZL2(managerAddr)
            .executeIncomingCrossChainCall(
                helloL2Addr,
                0,
                _getWordCallData(),
                helloL1Addr,
                MAINNET_ROLLUP_ID,
                _l2Entries(helloL2Addr, helloL1Addr),
                new L2LookupCall[](0)
            );

        console.log("done");
        console.log("L2 ret length=%s", ret.length);
        vm.stopBroadcast();
    }
}

contract Execute is Script, HelloActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address helloL2Addr = vm.envAddress("HELLO_WORLD_L2");
        address h1Addr = vm.envAddress("HELLO_WORLD_L1");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        string memory greeting = batcher.execute(
            EEZ(rollupsAddr), proofSystemAddr, _l1Entries(helloL2Addr, h1Addr), noLookupCalls(), HelloWorldL1(h1Addr)
        );
        console.log("done");
        console.log("greeting=%s", greeting);
        vm.stopBroadcast();
    }
}

contract ExecuteNetwork is Script {
    function run() external view {
        address target = vm.envAddress("HELLO_WORLD_L1");
        console.log("TARGET=%s", target);
        console.log("VALUE=0");
        console.log("CALLDATA=%s", vm.toString(abi.encodeWithSelector(HelloWorldL1.helloL2World.selector)));
    }
}

contract ComputeExpected is ComputeExpectedBase, HelloActions {
    function _name(address a) internal view override returns (string memory) {
        if (a == vm.envAddress("HELLO_WORLD_L2")) return "HelloWorldL2";
        if (a == vm.envAddress("HELLO_WORLD_L1")) return "HelloWorldL1";
        return _shortAddr(a);
    }

    function run() external view {
        address helloL2Addr = vm.envAddress("HELLO_WORLD_L2");
        address h1Addr = vm.envAddress("HELLO_WORLD_L1");

        ExecutionEntry[] memory l1 = _l1Entries(helloL2Addr, h1Addr);
        L2ExecutionEntry[] memory l2 = _l2Entries(helloL2Addr, h1Addr);
        bytes32 l1Hash = _entryHash(l1[0]);
        bytes32 l2Hash = _entryHash(l2[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("EXPECTED_L2_HASHES=[%s]", vm.toString(l2Hash));
        console.log("EXPECTED_L1_CALL_HASHES=[%s]", vm.toString(l1[0].proxyEntryHash));

        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry) ===");
        _logEntry(0, l1[0]);

        console.log("");
        console.log("=== EXPECTED L2 TABLE (1 entry) ===");
        _logL2Entry(0, l2[0]);
    }
}
