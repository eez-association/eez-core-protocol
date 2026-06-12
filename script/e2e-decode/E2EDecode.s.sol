// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../../src/EEZ.sol";
import {Rollup} from "../../src/rollupContract/Rollup.sol";
import {IProofSystem} from "../../src/interfaces/IProofSystem.sol";
import {
    ExecutionEntry,
    StateDelta,
    L2ToL1Call,
    ExpectedL1ToL2Call,
    LookupCall,
    ExpectedLookup
} from "../../src/interfaces/IEEZ.sol";
import {Counter, CounterAndProxy} from "../../test/mocks/CounterContracts.sol";

contract MockProofSystem is IProofSystem {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

/// @notice Helper that executes postAndVerifyBatch + incrementProxy in a single transaction.
/// @dev Same-block requirement for executeCrossChainCall after postAndVerifyBatch.
contract Batcher {
    function execute(
        EEZ rollups,
        address proofSystem,
        uint256 rollupId,
        ExecutionEntry[] calldata entries,
        LookupCall[] calldata lookupCalls,
        CounterAndProxy cap
    )
        external
    {
        address[] memory psList = new address[](1);
        psList[0] = proofSystem;
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";

        uint64[] memory psIdx = new uint64[](1);
        psIdx[0] = 0;
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: rollupId, proofSystemIndex: psIdx});

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
        cap.incrementProxy();
    }
}

/// @title E2EDeploy -- Deploy infra + app contracts (single tx)
/// @dev Burns rollupId 0 (MAINNET); L2 rollup at id=1.
contract E2EDeploy is Script {
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function run() external {
        vm.startBroadcast();

        MockProofSystem ps = new MockProofSystem();
        EEZ rollups = new EEZ();

        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = DEFAULT_VK;

        Rollup burn = new Rollup(address(rollups), msg.sender, 1, psList, vks);
        rollups.registerRollup(address(burn), bytes32(0));

        Rollup l2Manager = new Rollup(address(rollups), msg.sender, 1, psList, vks);
        uint256 rid = rollups.registerRollup(address(l2Manager), keccak256("l2-initial-state"));
        require(rid == 1, "expected L2 rollupId = 1");

        Counter counterL2 = new Counter();
        address counterProxy = rollups.createCrossChainProxy(address(counterL2), 1);
        CounterAndProxy counterAndProxy = new CounterAndProxy(Counter(counterProxy));

        console.log("PROOF_SYSTEM=%s", address(ps));
        console.log("ROLLUPS=%s", address(rollups));
        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(counterAndProxy));

        vm.stopBroadcast();
    }
}

/// @title E2EExecute -- postAndVerifyBatch + incrementProxy via Batcher (single tx)
contract E2EExecute is Script {
    function run(address rollupsAddr, address proofSystemAddr, address counterL2Addr, address counterAndProxyAddr)
        external
    {
        vm.startBroadcast();

        Batcher batcher = new Batcher();

        EEZ rollups = EEZ(rollupsAddr);
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // Cross-chain call hash: CounterAndProxy → CounterProxy → counterL2 (rollupId=1).
        bytes32 callHash = keccak256(
            abi.encode(
                uint256(1), // targetRollupId (L2)
                counterL2Addr, // targetAddress
                uint256(0), // value
                incrementCallData, // data
                counterAndProxyAddr, // sourceAddress
                uint256(0) // sourceRollupId (MAINNET)
            )
        );

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: 1,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-scenario1"),
            etherDelta: 0
        });

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: stateDeltas,
            proxyEntryHash: callHash,
            destinationRollupId: 1,
            l2ToL1Calls: new L2ToL1Call[](0),
            expectedL1ToL2Calls: new ExpectedL1ToL2Call[](0),
            expectedLookups: new ExpectedLookup[](0),
            callCount: 0,
            returnData: abi.encode(uint256(1)),
            rollingHash: bytes32(0)
        });

        LookupCall[] memory noLookups = new LookupCall[](0);

        batcher.execute(rollups, proofSystemAddr, 1, entries, noLookups, CounterAndProxy(counterAndProxyAddr));

        console.log("done");
        console.log("counter=%s", CounterAndProxy(counterAndProxyAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(counterAndProxyAddr).targetCounter());

        vm.stopBroadcast();
    }
}
