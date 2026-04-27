// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups, RollupConfig} from "src/Rollups.sol";
import {CrossChainManagerL2} from "src/CrossChainManagerL2.sol";
import {ExecutionEntry, StateDelta, CrossChainCall, NestedAction, StaticCall} from "src/ICrossChainManager.sol";
import {IZKVerifier} from "src/IZKVerifier.sol";
import {Counter, CounterAndProxy} from "test/mocks/CounterContracts.sol";

contract MockZKVerifier is IZKVerifier {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 1: Deploy L2 base infrastructure (ManagerL2 + Counter B)
// Run on L2 chain with deployer key
// ═══════════════════════════════════════════════════════════════
contract DeployL2Base is Script {
    function run() external {
        vm.startBroadcast();

        address systemAddress = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        CrossChainManagerL2 managerL2 = new CrossChainManagerL2(1, systemAddress);
        Counter counterL2 = new Counter(); // B

        vm.stopBroadcast();

        console.log("MANAGER_L2=%s", address(managerL2));
        console.log("COUNTER_L2=%s", address(counterL2));
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 2: Deploy L1 infrastructure
// Needs COUNTER_L2 env var (from stage 1)
// Run on L1 chain with deployer key
// ═══════════════════════════════════════════════════════════════
contract DeployL1 is Script {
    function run() external {
        address counterL2Addr = vm.envAddress("COUNTER_L2");

        vm.startBroadcast();

        MockZKVerifier verifier = new MockZKVerifier();
        Rollups rollups = new Rollups(address(verifier), 1);

        // Create L2 rollup (rollupId = 1)
        rollups.createRollup(keccak256("l2-initial-state"), keccak256("verificationKey"), msg.sender);

        Counter counterL1 = new Counter(); // C

        // B': proxy for B on L1 (uses B's real L2 address)
        address counterProxy = rollups.createCrossChainProxy(counterL2Addr, 1);

        // A: CounterAndProxy on L1, targets B'
        CounterAndProxy counterAndProxy = new CounterAndProxy(Counter(counterProxy));

        vm.stopBroadcast();

        console.log("ROLLUPS=%s", address(rollups));
        console.log("COUNTER_L1=%s", address(counterL1));
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(counterAndProxy));
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 3: Deploy L2 application contracts
// Needs COUNTER_L1 env var (from stage 2)
// Run on L2 chain with deployer key
// ═══════════════════════════════════════════════════════════════
contract DeployL2Apps is Script {
    function run() external {
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address managerL2Addr = vm.envAddress("MANAGER_L2");

        CrossChainManagerL2 managerL2 = CrossChainManagerL2(payable(managerL2Addr));

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

/// @dev Computes the action hash the same way executeCrossChainCall does
function _actionHash(
    uint256 rollupId,
    address destination,
    uint256 value,
    bytes memory data,
    address sourceAddress,
    uint256 sourceRollup
) pure returns (bytes32) {
    return keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup));
}

/// @dev Creates an empty StaticCall array
function _noStaticCalls() pure returns (StaticCall[] memory) {
    return new StaticCall[](0);
}

// ═══════════════════════════════════════════════════════════════
// Stage 4: Scenario 1 — L2 Phase (SYSTEM operations)
// Loads execution table with one deferred entry, then Alice triggers D.incrementProxy()
// Run on L2 chain as SYSTEM (--sender SYSTEM --unlocked)
// Needs: MANAGER_L2, COUNTER_L1, COUNTER_AND_PROXY_L2
// ═══════════════════════════════════════════════════════════════
contract Scenario1_L2 is Script {
    function run() external {
        address managerL2Addr = vm.envAddress("MANAGER_L2");
        address counterL1Addr = vm.envAddress("COUNTER_L1");
        address counterAndProxyL2Addr = vm.envAddress("COUNTER_AND_PROXY_L2");

        CrossChainManagerL2 managerL2 = CrossChainManagerL2(payable(managerL2Addr));
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // actionHash: what executeCrossChainCall builds when D calls C'
        // C' proxy: originalAddress=counterL1, originalRollupId=MAINNET(0)
        // sourceAddress=counterAndProxyL2 (D, msg.sender to C'), sourceRollup=L2(1)
        bytes32 actionHash = _actionHash(
            0,                          // rollupId (MAINNET, where C lives)
            counterL1Addr,              // destination (C)
            0,                          // value
            incrementCallData,          // data
            counterAndProxyL2Addr,      // sourceAddress (D)
            1                           // sourceRollup (L2)
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
                actionHash: actionHash,
                calls: calls,
                nestedActions: nestedActions,
                callCount: 0,
                returnData: abi.encode(uint256(1)),
                failed: false,
                rollingHash: bytes32(0)
            });

            managerL2.loadExecutionTable(entries, _noStaticCalls());
        }

        vm.stopBroadcast();

        console.log("L2 execution table loaded with 1 entry");
    }
}

// ═══════════════════════════════════════════════════════════════
// Stage 5: Scenario 1 — L1 Phase (deployer operations)
// Posts batch with deferred entry + Alice calls A.incrementProxy()
// Run on L1 chain with deployer key
// Needs: ROLLUPS, COUNTER_L2, COUNTER_AND_PROXY
// ═══════════════════════════════════════════════════════════════
contract Scenario1_L1 is Script {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address counterL2Addr = vm.envAddress("COUNTER_L2");
        address counterAndProxyAddr = vm.envAddress("COUNTER_AND_PROXY");

        Rollups rollups = Rollups(payable(rollupsAddr));
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // actionHash: what executeCrossChainCall builds when A calls B'
        // B' proxy: originalAddress=counterL2, originalRollupId=L2(1)
        // sourceAddress=counterAndProxy (A, msg.sender to B'), sourceRollup=MAINNET(0)
        bytes32 actionHash = _actionHash(
            1,                          // rollupId (L2, where B lives)
            counterL2Addr,              // destination (B)
            0,                          // value
            incrementCallData,          // data
            counterAndProxyAddr,        // sourceAddress (A)
            0                           // sourceRollup (MAINNET)
        );

        bytes32 newState = keccak256("l2-state-after-increment");

        vm.startBroadcast();

        // Post batch: 1 deferred entry, no calls, returns abi.encode(1), with L2 state delta
        {
            StateDelta[] memory stateDeltas = new StateDelta[](1);
            stateDeltas[0] = StateDelta({
                rollupId: 1,
                newState: newState,
                etherDelta: 0
            });

            CrossChainCall[] memory calls = new CrossChainCall[](0);
            NestedAction[] memory nestedActions = new NestedAction[](0);

            ExecutionEntry[] memory entries = new ExecutionEntry[](1);
            entries[0] = ExecutionEntry({
                stateDeltas: stateDeltas,
                actionHash: actionHash,
                calls: calls,
                nestedActions: nestedActions,
                callCount: 0,
                returnData: abi.encode(uint256(1)),
                failed: false,
                rollingHash: bytes32(0)
            });

            rollups.postBatch(entries, _noStaticCalls(), 0, 0, 0, "", "proof");
        }

        // Alice (= deployer) calls A.incrementProxy()
        // -> A calls B' -> executeCrossChainCall -> actionHash matches -> returnData returned
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
