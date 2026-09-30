// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @notice Keeps the measured call below the isolated transaction boundary.
/// @dev With forge --isolate, lastCallGas on a top-level call includes transaction costs.
///      Capturing the nested target call here yields its execution gas, before refunds.
contract GasMeter {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Sample {
        uint256 gasUsed;
        int64 refund;
        bytes data;
    }

    function measure(
        address target,
        address caller,
        bytes calldata input,
        bool readOnly
    )
        external
        returns (Sample memory)
    {
        return _measure(target, caller, input, readOnly);
    }

    function measureTwice(
        address target,
        address caller,
        bytes calldata input
    )
        external
        returns (Sample memory first, Sample memory second)
    {
        first = _measure(target, caller, input, true);
        second = _measure(target, caller, input, true);
    }

    function _measure(
        address target,
        address caller,
        bytes memory input,
        bool readOnly
    )
        private
        returns (Sample memory sample)
    {
        vm.prank(caller);
        bool ok;
        bytes memory data;
        if (readOnly) {
            (ok, data) = target.staticcall(input);
        } else {
            (ok, data) = target.call(input);
        }
        Vm.Gas memory measured = vm.lastCallGas();
        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
        sample = Sample(measured.gasTotalUsed, measured.gasRefunded, data);
    }
}

/// @notice The benchmark checks that large calldata does not appear as execution gas for this no-op.
contract GasMeterProbe {
    function noop(bytes calldata) external pure returns (uint256) {
        return 7;
    }
}
