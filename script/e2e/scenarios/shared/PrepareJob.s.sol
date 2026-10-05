// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";

/// @title PrepareJob — runs every Deploy* contract of one scenario in a single forge process
/// @notice Staged prepare driver (E2EBase.sh plan_job_deploys). Each chain is forked once and
///         kept for the whole run, so a later Deploy contract sees what earlier ones deployed
///         there; the wallet nonce is set from the orchestrator's reading so the planned txs
///         and CREATE addresses are those the real chain will produce. Deploy outputs reach
///         later contracts through vm.setEnv (E2EHelpers.output). Dry run only: the
///         orchestrator re-signs and fires the planned txs itself.
/// Env: E2E_SCENARIO_FILE (artifact file, e.g. "E2ECounter.s.sol"), E2E_DEPLOY_CONTRACTS
///      (comma-separated Deploy* names in file order), E2E_WALLET (the broadcast sender),
///      E2E_L1_NONCE / E2E_L2_NONCE, E2E_L1_BLOCK / E2E_L2_BLOCK, L1_RPC / L2_RPC,
///      E2E_TRIGGER_CONTRACT and E2E_HAS_COMPUTE.
contract PrepareJob is Script {
    function run() external {
        string memory file = vm.envString("E2E_SCENARIO_FILE");
        string[] memory contracts = vm.split(vm.envString("E2E_DEPLOY_CONTRACTS"), ",");
        address wallet = vm.envAddress("E2E_WALLET");

        uint256 l1 = vm.createFork(vm.envString("L1_RPC"), vm.envUint("E2E_L1_BLOCK"));
        uint256 l2 = vm.createFork(vm.envString("L2_RPC"), vm.envUint("E2E_L2_BLOCK"));
        vm.selectFork(l1);
        vm.setNonce(wallet, uint64(vm.envUint("E2E_L1_NONCE")));
        vm.selectFork(l2);
        vm.setNonce(wallet, uint64(vm.envUint("E2E_L2_NONCE")));

        for (uint256 i = 0; i < contracts.length; i++) {
            // "L2" in the contract name selects L2, as the shell routes Deploy* contracts.
            vm.selectFork(vm.indexOf(contracts[i], "L2") == type(uint256).max ? l1 : l2);
            bytes memory code = vm.getCode(string.concat(file, ":", contracts[i]));
            address deployer;
            assembly {
                deployer := create(0, add(code, 0x20), mload(code))
            }
            require(deployer != address(0), string.concat("PrepareJob: cannot instantiate ", contracts[i]));
            (bool ok, bytes memory ret) = deployer.call(abi.encodeWithSignature("run()"));
            if (!ok) {
                // surface the scenario's own revert reason
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }

        // The trigger oracle and ComputeExpected read msg.sender as the user ("alice") in
        // the scenarios where the wallet itself calls a proxy; the standalone runner gave
        // them the wallet via `--sender`, so they are called here as the wallet too.
        string memory trigger = vm.envString("E2E_TRIGGER_CONTRACT");
        vm.selectFork(vm.indexOf(trigger, "L2") == type(uint256).max ? l1 : l2);
        _runAs(file, trigger, wallet);

        if (vm.envBool("E2E_HAS_COMPUTE")) {
            vm.selectFork(l1);
            _runAs(file, "ComputeExpected", wallet);
        }
    }

    function _runAs(string memory file, string memory contractName, address sender) private {
        bytes memory code = vm.getCode(string.concat(file, ":", contractName));
        address runner;
        assembly {
            runner := create(0, add(code, 0x20), mload(code))
        }
        require(runner != address(0), string.concat("PrepareJob: cannot instantiate ", contractName));
        vm.prank(sender);
        (bool ok, bytes memory ret) = runner.call(abi.encodeWithSignature("run()"));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
