// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EEZ} from "../../src/EEZ.sol";
import {EEZProxy} from "../../src/proxy/EEZProxy.sol";
import {EEZTest} from "../EEZ.t.sol";
import {EEZCoverageTest} from "../EEZCoverage.t.sol";
import {EEZStaticLookupTest} from "../EEZStaticLookup.t.sol";

/// @notice Reuses the execution scenarios with the production EEZ proxy.
/// @dev Inherited tests cover nested value inflows/outflows, ETH accounting rejection and rollback,
///      immediate self-calls, queued execution, and cross-chain proxy identity and authorization.
contract EEZProxyExecutionIntegrationTest is EEZTest {
    function _deployEEZ(address recovery) internal override returns (EEZ) {
        return EEZ(address(new EEZProxy(address(new EEZ(recovery)), makeAddr("EEZ upgrade owner"))));
    }
}

/// @notice Exercises force-revert self-calls, reentrancy guards, and meta-hook execution through EEZProxy.
/// @dev Inherited tests assert that rolled-back calls leave target state unchanged while the enclosing
///      successful entry can still advance its root, and malformed executions bubble their errors.
contract EEZProxyRevertIntegrationTest is EEZCoverageTest {
    function _deployEEZ(address recovery) internal override returns (EEZ) {
        return EEZ(address(new EEZProxy(address(new EEZ(recovery)), makeAddr("EEZ upgrade owner"))));
    }
}

/// @notice Runs top-level and nested STATICCALL scenarios through EEZProxy and CrossChainProxy.
/// @dev Includes static callbacks into L1, retries around local writes, cached reverts, and expiry.
contract EEZProxyStaticIntegrationTest is EEZStaticLookupTest {
    function _deployEEZ(address recovery) internal override returns (EEZ) {
        return EEZ(address(new EEZProxy(address(new EEZ(recovery)), makeAddr("EEZ upgrade owner"))));
    }
}
