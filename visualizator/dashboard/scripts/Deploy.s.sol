// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups, ProofSystemBatch, RollupConfig} from "src/Rollups.sol";
import {Rollup} from "src/rollupContract/Rollup.sol";
import {IProofSystem} from "src/interfaces/IProofSystem.sol";
import {EEZL2} from "src/EEZL2.sol";
import {ExecutionEntry, StateDelta, CrossChainCall, NestedAction, LookupCall} from "src/interfaces/IEEZ.sol";
import {Counter, CounterAndProxy} from "test/mocks/CounterContracts.sol";

contract MockProofSystem is IProofSystem {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 1: Deploy L2 base infrastructure (ManagerL2 + Counter B)
// ═══════════════════════════════════════════════════════════════
contract DeployL2Base is Script {
    function run() external {
        vm.startBroadcast();

        address systemAddress = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        EEZL2 managerL2 = new EEZL2(1, systemAddress);
        Counter counterL2 = new Counter(); // B

        vm.stopBroadcast();

        console.log("MANAGER_L2=%s", address(managerL2));
        console.log("COUNTER_L2=%s", address(counterL2));
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 2: Deploy L1 infrastructure
// Burns rollupId 0 (MAINNET) so the L2 rollup gets id 1.
// ═══════════════════════════════════════════════════════════════
contract DeployL1 is Script {
    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function run() external {
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();

        MockProofSystem ps = new MockProofSystem();
        Rollups rollups = new Rollups();

        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = DEFAULT_VK;

        // Burn rollupId 0 (MAINNET).
        Rollup burn = new Rollup(address(rollups), msg.sender, 1, psList, vks);
        rollups.registerRollup(address(burn), bytes32(0));

        Rollup l2Manager = new Rollup(address(rollups), msg.sender, 1, psList, vks);
        uint256 rid = rollups.registerRollup(address(l2Manager), keccak256("l2-initial-state"));
        require(rid == 1, "expected L2 rollupId = 1");

        Counter counterL1 = new Counter(); // C

        // B': proxy for B on L1 (uses B's real L2 address)
        address counterProxy = rollups.createCrossChainProxy(counterL2Addr, 1);

        // A: CounterAndProxy on L1, targets B'
        CounterAndProxy counterAndProxy = new CounterAndProxy(Counter(counterProxy));

        vm.stopBroadcast();

        console.log("PROOF_SYSTEM=%s", address(ps));
        console.log("ROLLUPS=%s", address(rollups));
        console.log("L2_MANAGER=%s", address(l2Manager));
        console.log("COUNTER_L1=%s", address(counterL1));
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(counterAndProxy));
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 3: Deploy L2 application contracts
// ═══════════════════════════════════════════════════════════════
contract DeployL2Apps is Script {
    function run() external {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address managerL2Addr = vm.envAddress("MANAGER_L2");

        EEZL2 managerL2 = EEZL2(payable(managerL2Addr));

        vm.startBroadcast();

        // C': proxy for C on L2 (uses C's real L1 address)
        address counterProxyL2 = managerL2.createCrossChainProxy(counterL1Addr, 0);

        // D: CounterAndProxy on L2, targets C'
        CounterAndProxy counterAndProxyL2 = new CounterAndProxy(Counter(counterProxyL2));

        vm.stopBroadcast();

        console.log("COUNTER_PROXY_L2=%s", counterProxyL2);
        console.log("COUNTER_AND_PROXY_L2=%s", address(counterAndProxyL2));
    }
}

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

/// @dev Computes the cross-chain call hash the same way executeCrossChainCall does.
function _crossChainCallHash(
    uint256 targetRollupId,
    address targetAddress,
    uint256 value,
    bytes memory data,
    address sourceAddress,
    uint256 sourceRollupId
) pure returns (bytes32) {
    return keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId));
}

function _noLookupCalls() pure returns (LookupCall[] memory) {
    return new LookupCall[](0);
}

// ═══════════════════════════════════════════════════════════════
// Stage 4: Scenario 1 — L2 Phase (SYSTEM operations)
// ═══════════════════════════════════════════════════════════════
contract Scenario1_L2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        EEZL2 managerL2 = EEZL2(payable(managerL2Addr));
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // D calls C' (proxy: originalAddress=counterL1, originalRollupId=0). msg.sender at C' is D.
        bytes32 callHash = _crossChainCallHash(
            0, // targetRollupId (MAINNET, where C lives)
            counterL1Addr, // targetAddress
            0, // value
            incrementCallData, // data
            counterAndProxyL2Addr, // sourceAddress (D)
            1 // sourceRollupId (L2)
        );

        vm.startBroadcast();

        // Load execution table: one deferred entry, no calls, returns abi.encode(1)
        {
            StateDelta[] memory emptyDeltas = new StateDelta[](0);
            CrossChainCall[] memory calls = new CrossChainCall[](0);
            NestedAction[] memory nestedActions = new NestedAction[](0);

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0] = ExecutionEntry({
                stateDeltas: emptyDeltas,
                crossChainCallHash: callHash,
                destinationRollupId: 1,
                calls: calls,
                nestedActions: nestedActions,
                callCount: 0,
                returnData: abi.encode(uint256(1)),
                rollingHash: bytes32(0)
            });

            managerL2.loadExecutionTable(entries, _noLookupCalls());
        }

        vm.stopBroadcast();

        console.log("L2 execution table loaded with 1 entry");
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 5: Scenario 1 — L1 Phase (deployer operations)
// ═══════════════════════════════════════════════════════════════
contract Scenario1_L1 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address proofSystemAddr = vm.envAddress("PROOF_SYSTEM");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");

        Rollups rollups = Rollups(payable(rollupsAddr));
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // A calls B' (proxy: originalAddress=counterL2, originalRollupId=1).
        bytes32 callHash = _crossChainCallHash(
            1, // targetRollupId (L2)
            counterL2Addr, // targetAddress (B)
            0, // value
            incrementCallData,
            counterAndProxyAddr, // sourceAddress (A)
            0 // sourceRollupId (MAINNET)
        );

        bytes32 newState = keccak256("l2-state-after-increment");

        vm.startBroadcast();

        // Post batch: 1 deferred entry, no calls, returns abi.encode(1), with L2 state delta
        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: 1,
                currentState: keccak256("l2-initial-state"),
                newState: newState,
                etherDelta: 0
            });

            CrossChainCall[] memory calls = new CrossChainCall[](0);
            NestedAction[] memory nestedActions = new NestedAction[](0);

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0] = ExecutionEntry({
                stateDeltas: stateDeltas,
                crossChainCallHash: callHash,
                destinationRollupId: 1,
                calls: calls,
                nestedActions: nestedActions,
                callCount: 0,
                returnData: abi.encode(uint256(1)),
                rollingHash: bytes32(0)
            });

            address[] memory psList = new address[](1);
            psList[0] = proofSystemAddr;
            uint256[] memory rids = new uint256[](1);
            rids[0] = 1;
            bytes[] memory proofs = new bytes[](1);
            proofs[0] = "proof";
            ProofSystemBatch[] memory batches = new ProofSystemBatch[](1);
            batches[0] = ProofSystemBatch({
                proofSystems: psList,
                rollupIds: rids,
                entries: entries,
                lookupCalls: _noLookupCalls(),
                transientCount: 0,
                transientLookupCallCount: 0,
                blobIndices: new uint256[](0),
                callData: "",
                proof: proofs,
                crossProofSystemInteractions: bytes32(0)
            });
            rollups.postBatch(batches);
        }

        // Alice (= deployer) calls A.incrementProxy()
        // -> A calls B' -> executeCrossChainCall -> callHash matches -> returnData returned
        CounterAndProxy(counterAndProxyAddr).incrementProxy();

        vm.stopBroadcast();

        // Verify
        uint256 aCounter = CounterAndProxy(counterAndProxyAddr).counter();
        uint256 aTarget = CounterAndProxy(counterAndProxyAddr).targetCounter();
        console.log("A.counter=%d (expected 1)", aCounter);
        console.log("A.targetCounter=%d (expected 1)", aTarget);
        require(aCounter == 1, "A.counter should be 1");
        require(aTarget == 1, "A.targetCounter should be 1");
    }
}
