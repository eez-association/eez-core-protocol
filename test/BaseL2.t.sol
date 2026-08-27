// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {
    ExecutionEntry,
    CrossChainCall,
    ExpectedOutgoingCrossChainCall,
    StaticExecutionEntry
} from "../src/interfaces/IEEZL2.sol";
import {TestHashes} from "./TestHashes.sol";

/// @notice Shared fixture for all `*.t.sol` tests touching the L2 `EEZL2` manager.
/// @dev Deploys an `EEZL2` bound to `TEST_ROLLUP_ID` / `SYSTEM_ADDRESS` and exposes the common
///      primitives: table-load helpers (`_loadEntries` / `_loadSingle`), a compact
///      `CrossChainCall` builder (`_cc`), simple entry builders (`_buildSimpleEntry` /
///      `_buildNoCalls`), and the L2 hash helpers (`_incomingCallHash`, `_expectedOutgoingHash`,
///      `_rhSingle`) on top of the `TestHashes` protocol-mirror folds.
///
///      Tests should:
///        1. `is BaseL2` (extend this contract).
///        2. Override `setUp()` and call `super.setUp()` before deploying their own targets.
abstract contract BaseL2 is Test, TestHashes {
    EEZL2 public manager;

    uint64 internal constant TEST_ROLLUP_ID = 42; // this L2's own rollup id
    uint64 internal constant REMOTE_ROLLUP_ID = 1; // a remote counterparty rollup (≠ this L2's own id)
    uint64 internal constant MAINNET = 0; // L1's rollup id
    address internal constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);

    function setUp() public virtual {
        manager = new EEZL2(TEST_ROLLUP_ID, SYSTEM_ADDRESS, false);
    }

    // ──────────────────────────────────────────────
    //  Table-load helpers
    // ──────────────────────────────────────────────

    /// @notice Loads `entries` + `staticEntries` into the execution table as `SYSTEM_ADDRESS`.
    function _loadEntries(ExecutionEntry[] memory entries, StaticExecutionEntry[] memory staticEntries) internal {
        vm.prank(SYSTEM_ADDRESS);
        manager.loadExecutionTable(entries, staticEntries);
    }

    /// @notice Loads a single entry (and no static entries) as `SYSTEM_ADDRESS`.
    function _loadSingle(ExecutionEntry memory entry) internal {
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = entry;
        _loadEntries(entries, new StaticExecutionEntry[](0));
    }

    // ──────────────────────────────────────────────
    //  L2 hash helpers
    // ──────────────────────────────────────────────

    /// @notice Cross-chain call hash of a call executed ON this L2: target rollup is this L2
    ///         (`ROLLUP_ID`), the source is the call's own `(sourceAddress, sourceRollupId)` pair.
    function _incomingCallHash(CrossChainCall memory cc) internal pure returns (bytes32) {
        return
            _ccHash(
                cc.isStatic, cc.sourceAddress, cc.sourceRollupId, cc.targetAddress, TEST_ROLLUP_ID, cc.value, cc.data
            );
    }

    /// @notice Hash of a mutable call LEAVING this L2 (source rollup = this L2) — the kind
    ///         `executeCrossChainCall` keys with; `callGas` comes from `_probeOutgoing`.
    function _outgoingCallHash(
        address src,
        address tgt,
        uint64 tgtRollupId,
        uint256 value,
        uint64 callGas,
        bytes memory data
    )
        internal
        view
        returns (bytes32)
    {
        return manager.computeCrossChainCallHash(false, src, TEST_ROLLUP_ID, tgt, tgtRollupId, value, callGas, data);
    }

    /// @notice Position key for a unified `expectedOutgoingCalls` element:
    ///         `keccak(crossChainCallHash, rollingHashAtFire)`.
    function _expectedOutgoingHash(bytes32 cch, bytes32 rollingHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(cch, rollingHash));
    }

    /// @notice Rolling hash for an entry with a single top-level call:
    ///         seed → CALL_BEGIN(cch) → CALL_END(success, retData).
    function _rhSingle(
        bytes32 proxyEntryHash,
        bytes32 cch,
        bool success,
        bytes memory retData
    )
        internal
        pure
        returns (bytes32)
    {
        return _hCallEnd(_hCallBegin(_hEntryBeginL2(proxyEntryHash), cch), success, retData);
    }

    /// @notice `_rhSingle` overload deriving the call hash from `cc` (executed on this L2).
    function _rhSingle(
        bytes32 proxyEntryHash,
        CrossChainCall memory cc,
        bool success,
        bytes memory retData
    )
        internal
        pure
        returns (bytes32)
    {
        return _rhSingle(proxyEntryHash, _incomingCallHash(cc), success, retData);
    }

    // ──────────────────────────────────────────────
    //  Builders
    // ──────────────────────────────────────────────

    /// @notice Compact `CrossChainCall` builder: non-static, no forced-revert span.
    function _cc(
        address tgt,
        uint256 value_,
        bytes memory data,
        address src,
        uint64 srcRollup
    )
        internal
        pure
        returns (CrossChainCall memory)
    {
        return CrossChainCall({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: src,
            sourceRollupId: srcRollup,
            targetAddress: tgt,
            value: value_,
            data: data
        });
    }

    /// @notice Entry with one top-level call and no reentrant (outgoing) calls.
    function _buildSimpleEntry(
        bytes32 proxyEntryHash,
        CrossChainCall memory cc,
        bytes memory returnData,
        bytes32 rollingHash
    )
        internal
        pure
        returns (ExecutionEntry memory entry)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = cc;
        entry.proxyEntryHash = proxyEntryHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entry.rollingHash = rollingHash;
        entry.success = true;
        entry.returnData = returnData;
    }

    /// @notice No-call entry (just a `proxyEntryHash` match + return data).
    function _buildNoCalls(
        bytes32 proxyEntryHash,
        bytes memory returnData
    )
        internal
        pure
        returns (ExecutionEntry memory entry)
    {
        entry.proxyEntryHash = proxyEntryHash;
        entry.incomingCalls = new CrossChainCall[](0);
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entry.rollingHash = _hEntryBeginL2(proxyEntryHash); // no calls ⇒ rolling hash is just the seed
        entry.success = true;
        entry.returnData = returnData;
    }

    // ──────────────────────────────────────────────
    //  callGas probing — DORMANT under `useGasLeft = false`
    // ──────────────────────────────────────────────
    //
    //  This fixture deploys its manager with `useGasLeft = false`, so the folded `callGas` is a
    //  fixed 0 and these probes trivially observe 0 — the hashes they feed no longer depend on
    //  gas. The machinery is kept because it is the ONLY way to key hashes under the future
    //  observed-gas mode (`useGasLeft = true`): `GasProbe.t.sol` deploys such a manager and keeps
    //  the recipe validated against it.

    /// @notice Explicit gas attached to every probed/consuming proxy call. Under observed-gas
    ///         keying, `callGas` is captured from `gasleft()` at manager entry, so a call only
    ///         reproduces its probed value when it attaches the same explicit gas.
    uint256 internal constant CALL_GAS = 5_000_000;

    /// @notice Explicit gas for a top-level proxy call whose entry fires a NESTED `{gas: CALL_GAS}`
    ///         proxy call: large enough that the 63/64 forwarding rule still lets the nested call
    ///         site pass its full explicit `CALL_GAS`, so the nested probe stays reproducible.
    uint256 internal constant OUTER_CALL_GAS = 20_000_000;

    /// @notice Observes the exact `callGas` a `{gas: CALL_GAS}` proxy call from `caller` will fold
    ///         into its outgoing hash. Loads an EMPTY table (block gate, guaranteed no-match) and
    ///         probes twice: the first call warms the access path, the second measures it warm.
    ///         Wipes any loaded table — probe BEFORE loading the real entries.
    function _probeOutgoing(
        address caller,
        address proxyAddr,
        uint256 value,
        bytes memory data
    )
        internal
        returns (uint64 g)
    {
        return _probeOutgoing(caller, proxyAddr, value, data, CALL_GAS);
    }

    /// @notice `_probeOutgoing` with an explicit attached gas — for the top-level call of a nested
    ///         scenario, which attaches `OUTER_CALL_GAS` (see above) instead of `CALL_GAS`.
    function _probeOutgoing(
        address caller,
        address proxyAddr,
        uint256 value,
        bytes memory data,
        uint256 attachedGas
    )
        internal
        returns (uint64 g)
    {
        _loadEntries(new ExecutionEntry[](0), new StaticExecutionEntry[](0));
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(caller);
            (bool ok, bytes memory err) = proxyAddr.call{value: value, gas: attachedGas}(data);
            require(!ok && bytes4(err) == EEZL2.EntryNotFound.selector, "probe: expected EntryNotFound");
            assembly {
                g := mload(add(err, 0x44))
            }
        }
    }
}
