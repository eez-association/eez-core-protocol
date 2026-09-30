// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {EEZ} from "../src/EEZ.sol";
import {Rollup} from "../src/rollupContract/Rollup.sol";

/// @notice Upgrade to an already deployed, storage-compatible implementation.
/// @dev Deploy the new implementation first, review its layout, then broadcast as the ProxyAdmin owner.
abstract contract UpgradeBase is Script {
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    function _upgrade(address proxy, address implementation, bytes memory data) internal {
        require(proxy.code.length != 0 && implementation.code.length != 0, "Contract has no code");
        address admin = address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
        require(admin.code.length != 0, "Missing ProxyAdmin");
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        require(ProxyAdmin(admin).owner() == broadcaster, "Broadcast as upgrade owner");
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, data);
        vm.stopBroadcast();
        console.log("PROXY", proxy);
        console.log("IMPLEMENTATION", implementation);
        console.log("PROXY_ADMIN", admin);
    }
}

contract UpgradeEEZ is UpgradeBase {
    function run(address proxy, address implementation, bytes calldata data) external {
        require(EEZ(proxy).RECOVERY_ADDRESS() == EEZ(implementation).RECOVERY_ADDRESS(), "Recovery mismatch");
        require(
            EEZ(proxy).PROXY_INIT_CODE_HASH() == EEZ(implementation).PROXY_INIT_CODE_HASH(),
            "Cross-chain proxy bytecode mismatch"
        );
        _upgrade(proxy, implementation, data);
    }
}

contract UpgradeRollup is UpgradeBase {
    function run(address proxy, address implementation, bytes calldata data) external {
        require(Rollup(proxy).EEZContract() == Rollup(implementation).EEZContract(), "Registry mismatch");
        _upgrade(proxy, implementation, data);
    }
}
