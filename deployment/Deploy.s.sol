// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {EEZProxy} from "../src/proxy/EEZProxy.sol";
import {EEZ} from "../src/EEZ.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {Rollup} from "../src/rollupContract/Rollup.sol";
import {ECDSAProofSystem} from "../src/proofSystems/ECDSAProofSystem.sol";

abstract contract DeploymentBase is Script {
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    function _deployEEZ(address recovery, address upgradeOwner) internal returns (EEZ eez) {
        require(recovery != address(0) && upgradeOwner != address(0), "Zero address");
        EEZ implementation = new EEZ(recovery);
        eez = EEZ(address(new EEZProxy(address(implementation), upgradeOwner)));
        console.log("EEZ_IMPLEMENTATION", address(implementation));
        console.log("EEZ_PROXY", address(eez));
        console.log("EEZ_PROXY_ADMIN", _admin(address(eez)));
    }

    function _deployRollup(
        address eez,
        address owner,
        address upgradeOwner,
        uint256 threshold,
        address[] memory proofSystems,
        bytes32[] memory vkeys
    )
        internal
        returns (Rollup rollup)
    {
        require(eez.code.length != 0, "EEZ has no code");
        require(owner != address(0) && upgradeOwner != address(0), "Zero address");
        require(proofSystems.length == vkeys.length, "Proof system/key length mismatch");
        for (uint256 i; i < proofSystems.length; ++i) {
            require(proofSystems[i].code.length != 0, "Proof system has no code");
            require(vkeys[i] != bytes32(0), "Zero verification key");
        }
        // The implementation is locked; initialize operational state atomically in the proxy.
        Rollup implementation = new Rollup(eez);
        bytes memory data = abi.encodeCall(Rollup.initialize, (owner, threshold, proofSystems, vkeys));
        rollup = Rollup(address(new TransparentUpgradeableProxy(address(implementation), upgradeOwner, data)));
        console.log("ROLLUP_IMPLEMENTATION", address(implementation));
        console.log("ROLLUP_PROXY", address(rollup));
        console.log("ROLLUP_PROXY_ADMIN", _admin(address(rollup)));
    }

    function _admin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
    }
}

/// @notice Deploy the complete L1 reference stack with one ECDSA proof system and register its rollup.
/// @dev Broadcast as rollupOwner. Use the individual scripts for multisig-owned rollups.
contract DeployL1 is DeploymentBase {
    function run(
        address recovery,
        address eezUpgradeOwner,
        address rollupOwner,
        address rollupUpgradeOwner,
        address proofOwner,
        address proofSigner,
        bytes32 vkey,
        bytes32 initialRoot
    )
        external
        returns (EEZ eez, Rollup rollup, ECDSAProofSystem proofSystem, uint64 rollupId)
    {
        require(proofOwner != address(0) && proofSigner != address(0), "Zero proof owner/signer");
        require(vkey != bytes32(0), "Zero verification key");
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        require(broadcaster == rollupOwner, "Broadcast as rollup owner");
        eez = _deployEEZ(recovery, eezUpgradeOwner);
        proofSystem = new ECDSAProofSystem(proofOwner, proofSigner);
        address[] memory systems = new address[](1);
        systems[0] = address(proofSystem);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = vkey;
        rollup = _deployRollup(address(eez), rollupOwner, rollupUpgradeOwner, 1, systems, keys);
        rollupId = eez.registerRollup(address(rollup), initialRoot);
        vm.stopBroadcast();
        console.log("ECDSA_PROOF_SYSTEM", address(proofSystem));
        console.log("ROLLUP_ID", uint256(rollupId));
    }
}

contract DeployEEZ is DeploymentBase {
    function run(address recovery, address upgradeOwner) external returns (EEZ eez) {
        vm.startBroadcast();
        eez = _deployEEZ(recovery, upgradeOwner);
        vm.stopBroadcast();
    }
}

/// @notice Deploy an unregistered rollup with arbitrary proof systems and threshold.
contract DeployRollup is DeploymentBase {
    function run(
        address eez,
        address owner,
        address upgradeOwner,
        uint256 threshold,
        address[] memory proofSystems,
        bytes32[] memory vkeys
    )
        external
        returns (Rollup rollup)
    {
        vm.startBroadcast();
        rollup = _deployRollup(eez, owner, upgradeOwner, threshold, proofSystems, vkeys);
        vm.stopBroadcast();
    }
}

contract RegisterRollup is Script {
    function run(address eez, address rollup, bytes32 initialRoot) external returns (uint64 rollupId) {
        require(eez.code.length != 0 && rollup.code.length != 0, "Contract has no code");
        require(Rollup(rollup).EEZContract() == eez, "Wrong registry");
        require(Rollup(rollup).rollupId() == 0, "Already registered");
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        require(broadcaster == Rollup(rollup).owner(), "Broadcast as rollup owner");
        rollupId = EEZ(eez).registerRollup(rollup, initialRoot);
        vm.stopBroadcast();
        console.log("ROLLUP_ID", uint256(rollupId));
    }
}

contract DeployProofSystem is Script {
    function run(address owner, address signer) external returns (ECDSAProofSystem proofSystem) {
        require(owner != address(0) && signer != address(0), "Zero address");
        vm.startBroadcast();
        proofSystem = new ECDSAProofSystem(owner, signer);
        vm.stopBroadcast();
        console.log("ECDSA_PROOF_SYSTEM", address(proofSystem));
    }
}

/// @notice Run on the L2 RPC after registering the rollup on L1.
contract DeployL2 is Script {
    function run(uint64 rollupId, address systemAddress, bool useGasLeft) external returns (EEZL2 manager) {
        require(rollupId != 0 && systemAddress != address(0), "Invalid L2 configuration");
        vm.startBroadcast();
        manager = new EEZL2(rollupId, systemAddress, useGasLeft);
        vm.stopBroadcast();
        console.log("EEZ_L2", address(manager));
    }
}
