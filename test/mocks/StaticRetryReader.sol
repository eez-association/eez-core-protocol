// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Exercises sibling static rows while the enclosing EEZ call remains in flight.
contract StaticRetryReader {
    uint256 public rate;

    function readAroundWrites(address proxy, bytes calldata data, bool failAtOne) external returns (uint256) {
        for (uint256 i; i < 3; i++) {
            rate = i == 1 ? 2 : 1;
            (bool ok, bytes memory result) = proxy.staticcall(data);
            require(ok == !(failAtOne && rate == 1), "wrong static success flag");
            require(abi.decode(result, (uint256)) == rate, "wrong static candidate");
        }
        return 77;
    }
}
