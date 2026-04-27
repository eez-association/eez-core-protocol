// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Rollups} from "../../../src/Rollups.sol";
import {
    Action,
    StateDelta,
    CrossChainCall,
    NestedAction,
    ExecutionEntry,
    StaticCall
} from "../../../src/ICrossChainManager.sol";
import {HelloWorldL1, HelloWorldL2, IHelloWorldL2} from "../../../test/mocks/helloword.sol";
import {ComputeExpectedBase} from "../shared/ComputeExpectedBase.sol";
import {actionHash, noStaticCalls, noNestedActions, noCalls} from "../shared/E2EHelpers.sol";

// ═══════════════════════════════════════════════════════════════════════
//  HelloWorld scenario — L1→L2 with rich return data
//
//  HelloWorldL1.helloL2World() calls HelloWorldL2.getWord() via a cross-chain
//  proxy. The entry precomputes the return value ("World") as abi-encoded
//  bytes and exposes it through the proxy call.
// ═══════════════════════════════════════════════════════════════════════

uint256 constant L2_ROLLUP_ID = 1;
uint256 constant MAINNET_ROLLUP_ID = 0;

abstract contract HelloActions {
    function _getWordCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHelloWorldL2.getWord.selector);
    }

    function _callAction(address helloL2, address helloL1) internal pure returns (Action memory) {
        return Action({
            rollupId: L2_ROLLUP_ID,
            destination: helloL2,
            value: 0,
            data: _getWordCallData(),
            sourceAddress: helloL1,
            sourceRollup: MAINNET_ROLLUP_ID
        });
    }

    function _l1Entries(address helloL2, address helloL1)
        internal
        pure
        returns (ExecutionEntry[] memory entries)
    {
        StateDelta[] memory deltas = new StateDelta[](1);
        deltas[0] = StateDelta({
            rollupId: L2_ROLLUP_ID,
            newState: keccak256("l2-state-after-helloworld"),
            etherDelta: 0
        });

        entries = new ExecutionEntry[](1);
        entries[0] = ExecutionEntry({
            stateDeltas: deltas,
            actionHash: actionHash(_callAction(helloL2, helloL1)),
            calls: noCalls(),
            nestedActions: noNestedActions(),
            callCount: 0,
            returnData: abi.encode("World"),
            failed: false,
            rollingHash: bytes32(0)
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
        Rollups rollups = Rollups(rollupsAddr);

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
    function execute(Rollups rollups, ExecutionEntry[] calldata entries, StaticCall[] calldata statics, HelloWorldL1 h1)
        external
        returns (string memory greeting)
    {
        rollups.postBatch(entries, statics, 0, 0, 0, "", "proof");
        greeting = h1.helloL2World();
    }
}

contract Execute is Script, HelloActions {
    function run() external {
        address rollupsAddr = vm.envAddress("ROLLUPS");
        address helloL2Addr = vm.envAddress("HELLO_WORLD_L2");
        address h1Addr = vm.envAddress("HELLO_WORLD_L1");

        vm.startBroadcast();
        Batcher batcher = new Batcher();
        string memory greeting = batcher.execute(
            Rollups(rollupsAddr),
            _l1Entries(helloL2Addr, h1Addr),
            noStaticCalls(),
            HelloWorldL1(h1Addr)
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
        bytes32 l1Hash = _entryHash(l1[0]);

        console.log("EXPECTED_L1_HASHES=[%s]", vm.toString(l1Hash));
        console.log("");
        console.log("=== EXPECTED L1 TABLE (1 entry) ===");
        _logEntry(0, l1[0]);
    }
}
