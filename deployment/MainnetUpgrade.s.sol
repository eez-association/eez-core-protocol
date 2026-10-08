// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {EEZ} from "../src/EEZ.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";

/// @notice Mainnet-only upgrade from v0.1.0-rc.1 to 97449508fd460a2fa59d98583db2a8335e2525c8.
/// @dev Supply deployment addresses at runtime through upgrade-mainnet.sh. No Rollup upgrade or migration.
///      Runtime code hashes pin the reviewed release, including its immutable configuration.
contract MainnetUpgrade is Script {
    bytes32 public constant PROXY_HASH = 0x26f77730044fbffb547593b1a676eb53cbbb9a57879c3f2cf090cee88a283a4a;
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 internal constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    function _implementation(address manager) internal view returns (address) {
        return address(uint160(uint256(vm.load(manager, IMPLEMENTATION_SLOT))));
    }

    function _admin(address manager) internal view returns (address) {
        return address(uint160(uint256(vm.load(manager, ADMIN_SLOT))));
    }

    function _targetHash() internal view returns (bytes32) {
        require(block.chainid == 1 || block.chainid == 696990, "Unexpected chain");
        return block.chainid == 1
            ? bytes32(0x345cf74d366b15cd6c826b31495d3955c04a95813dcc76a76f627dbbda996a73)
            : bytes32(0x18091f625067095bc16d7cf36e58c136a0b0f8591f02ab6843ee91994a9864b3);
    }

    /// @notice Read-only preflight. Signing mode validates the dedicated key without broadcasting.
    function check(address manager, address owner, bool signing) public view returns (bool alreadyUpgraded) {
        bytes32 target = _targetHash();
        require(manager.code.length != 0, "Missing manager");
        require(owner != address(0), "Missing upgrade owner");
        address admin = _admin(manager);
        require(admin.code.length != 0 && ProxyAdmin(admin).owner() == owner, "Unexpected upgrade owner");
        if (signing) require(vm.addr(vm.envUint("UPGRADE_PRIVATE_KEY")) == owner, "Wrong UPGRADE_PRIVATE_KEY");

        address implementation = _implementation(manager);
        alreadyUpgraded = implementation.codehash == target;
        if (!alreadyUpgraded) {
            bytes32 oldHash = block.chainid == 1
                ? bytes32(0x16c4c81a9b2259f9b1b082e7316b8d7b20d083404425d96bd17ff0a44e30cd91)
                : bytes32(0x432e1c7af4d49fc907681f91e313965b17c3f35c857d8c58442cdbfca7925e4d);
            require(implementation.codehash == oldHash, "Unexpected old bytecode");
        }
        require(EEZ(manager).PROXY_INIT_CODE_HASH() == PROXY_HASH, "Proxy hash mismatch");
    }

    /// @notice Verify the actual RPC state after broadcast; accepts only reviewed target bytecode.
    function verify(address manager, address owner) external view {
        require(check(manager, owner, false), "Upgrade not complete");
        console.log("Verified chain", block.chainid);
        console.log("IMPLEMENTATION", _implementation(manager));
    }

    /// @notice Plan with false; signing with true additionally needs CLI --broadcast to send.
    /// @dev A fresh implementation and an empty-data upgrade are two separate transactions.
    function run(address manager, address owner, bool signing) external {
        if (check(manager, owner, signing)) {
            console.log("Already upgraded on chain", block.chainid);
            return;
        }
        address admin = _admin(manager);
        if (signing) vm.startBroadcast(vm.envUint("UPGRADE_PRIVATE_KEY"));
        else vm.startBroadcast(owner);

        address next;
        if (block.chainid == 1) {
            next = address(new EEZ(EEZ(manager).RECOVERY_ADDRESS()));
        } else {
            EEZL2 current = EEZL2(manager);
            next = address(
                new EEZL2(
                    current.ROLLUP_ID(), current.SYSTEM_ADDRESS(), current.USE_GAS_LEFT(), current.RECOVERY_ADDRESS()
                )
            );
        }
        // Evaluated during simulation before Foundry broadcasts any transaction.
        require(next.codehash == _targetHash(), "Build differs from reviewed HEAD");
        require(next.code.length <= 24576, "Implementation exceeds EIP-170");
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(manager), next, "");
        vm.stopBroadcast();
        require(check(manager, owner, false), "Post-upgrade verification failed");
        console.log("CHAIN_ID", block.chainid);
        console.log("PROXY", manager);
        console.log("IMPLEMENTATION", next);
    }
}
