// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {EEZBridge} from "../src/periphery/EEZBridge.sol";
import {EEZToken} from "../src/periphery/defiMock/EEZToken.sol";
import {EEZWrappedNative} from "../src/periphery/defiMock/EEZWrappedNative.sol";
import {MiniUniswapFactory} from "../src/periphery/defiMock/MiniUniswapFactory.sol";
import {MiniUniswapRouter} from "../src/periphery/defiMock/MiniUniswapRouter.sol";
import {MiniPermit2} from "../src/periphery/defiMock/MiniPermit2.sol";

/// @notice Deploy application contracts on one existing chain. Run once per chain.
/// @dev No EEZ infrastructure, execution tables, mock proofs or cross-chain calls.
contract DeployUniswapLab is Script {
    function run(address manager, uint64 rollupId, address owner, uint256 expectedChainId) external {
        require(block.chainid == expectedChainId, "Unexpected chain");
        require(manager.code.length > 0, "Missing EEZ manager");
        if (rollupId != 0) require(EEZL2(manager).ROLLUP_ID() == rollupId, "L2 rollup ID mismatch");
        uint256 key = vm.envUint("PK");
        require(vm.addr(key) == owner, "Unexpected signer");
        vm.startBroadcast(key);
        new EEZBridge(manager, rollupId, owner);
        MiniUniswapFactory factory = new MiniUniswapFactory();
        MiniPermit2 permit = new MiniPermit2();
        EEZWrappedNative native = new EEZWrappedNative(manager);
        new MiniUniswapRouter(address(factory), address(permit), address(native));
        if (rollupId == 0) new EEZToken(manager, "Lab Token", "LAB", owner, 1_000_000 ether);
        vm.stopBroadcast();
    }
}
