// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Mainnet} from "./Mainnet.s.sol";

/// @notice The same deployment/verification functions with addresses from the local environment.
contract Devnet is Mainnet {
    constructor() {
        L1_CHAIN_ID = 10200;
        L2_CHAIN_ID = 906969;
    }
}
