// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {L2ToL1Call} from "../../src/interfaces/IEEZ.sol";
import {CrossChainCall} from "../../src/interfaces/IEEZL2.sol";
import {CallNode, CallParams} from "./ScenarioStore.sol";
import {SidecarStatic} from "./BlobSidecar.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  CallShapes — one library for every conversion between the framework's call
//  representations. Three shapes describe the same call:
//
//    CallNode / CallParams   the IR view (ScenarioStore): from + to, both chains
//    L2ToL1Call              the L1 table view: source fields, target on L1
//    CrossChainCall          the L2 table view: source fields, target on that L2
//
//  The table views don't name the chain they execute on (it's implied by which
//  table holds them), so every conversion back to the IR takes `execChain`
//  explicitly. TableGenerator uses the IR → table direction; TableStitcher the
//  table → IR direction.
// ─────────────────────────────────────────────────────────────────────────────

library CallShapes {
    // ── IR → table (TableGenerator) ──

    /// @notice The L1-table row for `node`, with span marker `span`.
    function toL1Call(CallNode memory node, uint16 span) internal pure returns (L2ToL1Call memory) {
        return L2ToL1Call({
            revertNextNCalls: span,
            isStatic: node.isStatic,
            gas: node.gas,
            sourceAddress: node.fromAddress,
            sourceRollupId: node.fromChain,
            targetAddress: node.toAddress,
            value: node.value,
            data: node.data
        });
    }

    /// @notice The L2-table row for `node`, with span marker `span`.
    function toL2Call(CallNode memory node, uint16 span) internal pure returns (CrossChainCall memory) {
        return CrossChainCall({
            revertNextNCalls: span,
            isStatic: node.isStatic,
            gas: node.gas,
            sourceAddress: node.fromAddress,
            sourceRollupId: node.fromChain,
            targetAddress: node.toAddress,
            value: node.value,
            data: node.data
        });
    }

    // ── table → IR (TableStitcher) ──

    /// @notice IR params of an L1-table row executing on `execChain` (L1 for the
    ///         entry's own arrays; the reader chain for a static entry's sub-reads).
    function toParams(L2ToL1Call memory call, uint64 execChain) internal pure returns (CallParams memory) {
        return CallParams({
            isStatic: call.isStatic,
            fromChain: call.sourceRollupId,
            fromAddress: call.sourceAddress,
            toChain: execChain,
            toAddress: call.targetAddress,
            value: call.value,
            gas: call.gas,
            data: call.data
        });
    }

    /// @notice IR params of an L2-table row executing on `execChain`.
    function toParams(CrossChainCall memory call, uint64 execChain) internal pure returns (CallParams memory) {
        return CallParams({
            isStatic: call.isStatic,
            fromChain: call.sourceRollupId,
            fromAddress: call.sourceAddress,
            toChain: execChain,
            toAddress: call.targetAddress,
            value: call.value,
            gas: call.gas,
            data: call.data
        });
    }

    /// @notice IR params of a sidecar static call fired from `origin` (statics carry
    ///         no value by construction).
    function toParams(SidecarStatic memory staticCall, uint64 origin) internal pure returns (CallParams memory) {
        return CallParams({
            isStatic: true,
            fromChain: origin,
            fromAddress: staticCall.fromAddress,
            toChain: staticCall.toChain,
            toAddress: staticCall.toAddress,
            value: 0,
            gas: staticCall.gas,
            data: staticCall.data
        });
    }
}
