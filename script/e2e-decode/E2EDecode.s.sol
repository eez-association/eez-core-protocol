// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {
    EEZ,
    ProofSystemBatchPerVerificationEntries,
    ExpectedStateRootPerRollup,
    RollupIdWithProofSystems
} from "../../src/EEZ.sol";
import {Rollup} from "../../src/rollupContract/Rollup.sol";
import {IProofSystem} from "../../src/interfaces/IProofSystem.sol";
import {ExecutionEntry, StateDelta, StaticLookup} from "../../src/interfaces/IEEZ.sol";
import {Counter, CounterAndProxy} from "../../test/mocks/CounterContracts.sol";
import {
    crossChainCallHash,
    noStaticLookups,
    noNestedActions,
    noCalls,
    RollingHashBuilder
} from "../e2e/shared/E2EHelpers.sol";

uint64 constant L2_ROLLUP_ID = 1;
uint64 constant MAINNET_ROLLUP_ID = 0;

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
        uint64 rollupId,
        ExecutionEntry[] calldata entries,
        StaticLookup[] calldata staticLookups,
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
        rps[0] = RollupIdWithProofSystems({rollupId: rollupId, proofSystemIndexes: psIdx});

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            expectedStateRootPerRollup: new ExpectedStateRootPerRollup[](0),
            entries: entries,
            staticLookups: staticLookups,
            immediateEntryCount: 0,
            immediateStaticLookupCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs,
            blockNumber: 0
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
        bytes32 callHash = crossChainCallHash(
            L2_ROLLUP_ID, counterL2Addr, 0, incrementCallData, counterAndProxyAddr, MAINNET_ROLLUP_ID
        );

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            currentState: keccak256("l2-initial-state"),
            newState: keccak256("l2-state-after-scenario1"),
            etherDelta: 0
        });

        // No L1 top-level calls; rolling hash is just the entry-begin seed.
        bytes32 rh = RollingHashBuilder.entryBegin(stateDeltas, callHash);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: stateDeltas,
            proxyEntryHash: callHash,
            destinationRollupId: L2_ROLLUP_ID,
            l2ToL1Calls: noCalls(),
            expectedL1ToL2Calls: noNestedActions(),
            rollingHash: rh,
            success: true,
            returnData: abi.encode(uint256(1))
        });

        batcher.execute(
            rollups, proofSystemAddr, L2_ROLLUP_ID, entries, noStaticLookups(), CounterAndProxy(counterAndProxyAddr)
        );

        console.log("done");
        console.log("counter=%s", CounterAndProxy(counterAndProxyAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(counterAndProxyAddr).targetCounter());

        vm.stopBroadcast();
    }
}
