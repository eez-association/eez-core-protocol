// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../src/Rollups.sol";
import {
    ExecutionEntry,
    StateDelta,
    CrossChainCall,
    NestedAction,
    StaticCall
} from "../../src/ICrossChainManager.sol";
import {IZKVerifier} from "../../src/IZKVerifier.sol";
import {Counter, CounterAndProxy} from "../../test/mocks/CounterContracts.sol";

contract MockZKVerifier is IZKVerifier {
    function verify(bytes calldata, bytes32) external pure override returns (bool) {
        return true;
    }
}

/// @notice Helper that executes postBatch + incrementProxy in a single transaction
/// @dev Needed because executeCrossChainCall requires same block as postBatch
contract Batcher {
    function execute(
        Rollups rollups,
        ExecutionEntry[] calldata entries,
        StaticCall[] calldata staticCalls,
        CounterAndProxy cap
    ) external {
        rollups.postBatch(entries, staticCalls, 0, 0, 0, "", "proof");
        cap.incrementProxy();
    }
}

/// @title E2EDeploy -- Deploy infra + app contracts
contract E2EDeploy is Script {
    function run() external {
        vm.startBroadcast();

        MockZKVerifier verifier = new MockZKVerifier();
        Rollups rollups = new Rollups(address(verifier), 1);
        rollups.createRollup(keccak256("l2-initial-state"), keccak256("verificationKey"), msg.sender);

        Counter counterL2 = new Counter();
        address counterProxy = rollups.createCrossChainProxy(address(counterL2), 1);
        CounterAndProxy counterAndProxy = new CounterAndProxy(Counter(counterProxy));

        console.log("ROLLUPS=%s", address(rollups));
        console.log("COUNTER_L2=%s", address(counterL2));
        console.log("COUNTER_PROXY=%s", counterProxy);
        console.log("COUNTER_AND_PROXY=%s", address(counterAndProxy));

        vm.stopBroadcast();
    }
}

/// @title E2EExecute -- postBatch + incrementProxy via Batcher (single tx)
contract E2EExecute is Script {
    function run(address rollupsAddr, address counterL2Addr, address counterAndProxyAddr) external {
        vm.startBroadcast();

        Batcher batcher = new Batcher();

        Rollups rollups = Rollups(rollupsAddr);
        bytes memory incrementCallData = abi.encodeWithSelector(Counter.increment.selector);

        // actionHash: what executeCrossChainCall builds when CounterAndProxy calls B' (proxy for counterL2)
        // B' proxy: originalAddress=counterL2Addr, originalRollupId=1
        // sourceAddress=counterAndProxyAddr (A, msg.sender to B'), sourceRollup=0 (MAINNET)
        bytes32 actionHash = keccak256(
            abi.encode(
                uint256(1),              // rollupId (L2)
                counterL2Addr,           // destination (counterL2)
                uint256(0),              // value
                incrementCallData,       // data
                counterAndProxyAddr,     // sourceAddress
                uint256(0)               // sourceRollup (MAINNET)
            )
        );

        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: 1,
            newState: keccak256("l2-state-after-scenario1"),
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

        StaticCall[] memory noStaticCalls = new StaticCall[](0);

        // Single tx: postBatch + incrementProxy
        batcher.execute(rollups, entries, noStaticCalls, CounterAndProxy(counterAndProxyAddr));

        console.log("done");
        console.log("counter=%s", CounterAndProxy(counterAndProxyAddr).counter());
        console.log("targetCounter=%s", CounterAndProxy(counterAndProxyAddr).targetCounter());

        vm.stopBroadcast();
    }
}
