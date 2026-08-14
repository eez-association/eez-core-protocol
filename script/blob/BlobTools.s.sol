// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {DslScenarioBase} from "../../test/blob/ScenarioDSL.sol";
import {BlobMessage, BlobMsgType} from "./BlobMessages.sol";
import {BlobCodec} from "./BlobCodec.sol";
import {ScenarioStore} from "./ScenarioStore.sol";
import {TableGenerator} from "./TableGenerator.sol";
import {UNIT_KIND_ORIGIN_GROUP} from "./BlobConstants.sol";
import {ExecutionEntry, StaticExecutionEntry, L2ToL1Call, StateUpdate} from "../../src/interfaces/IEEZ.sol";
import {ExecutionEntry as L2ExecutionEntry, CrossChainCall} from "../../src/interfaces/IEEZL2.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  BlobTools — file-based entry points into the blob ⇄ table pipeline.
//
//    DSL file → messages → tables (+ wire bytes):
//      forge script script/blob/BlobTools.s.sol --sig "run(string)" \
//          script/blob/examples/showcase.dsl
//
//    Blob-portion hex file (0x… of the logical byte stream) → tables:
//      forge script script/blob/BlobTools.s.sol --sig "runBlob(string)" my-blob.hex
//
//  Both print the derived L1 batch entries, every L2 chain's units, and the
//  sidecar summary. Requires `fs_permissions` read access in foundry.toml.
// ─────────────────────────────────────────────────────────────────────────────

contract BlobTools is DslScenarioBase {
    /// @notice Reads a DSL scenario file, compiles it, prints the messages, the
    ///         wire bytes, and the derived tables.
    function run(string memory path) external {
        BlobMessage[] memory msgs = dslCompile(vm.readFile(path));
        _printMessages(msgs);

        (bytes memory blobData, bytes memory callDataTail) = BlobCodec.encode(msgs);
        console2.log("");
        console2.log("== Wire bytes ==");
        console2.log("blob portion:", blobData.length, "bytes");
        console2.logBytes(blobData);
        if (callDataTail.length > 0) {
            console2.log("callData tail:", callDataTail.length, "bytes");
            console2.logBytes(callDataTail);
        }

        _printTables(_derive(msgs));
    }

    /// @notice Reads a DSL scenario file and runs the FULL pipeline on it — codec and
    ///         IR round trips, table derivation, stitch-back, and live execution on the
    ///         real managers with every actor result asserted (`runDsl`).
    function runLive(string memory path) external {
        BlobMessage[] memory msgs = dslCompile(vm.readFile(path));
        _printMessages(msgs);
        runDsl(vm.readFile(path));
        console2.log("");
        console2.log("== Live execution OK ==");
        for (uint64 c = 0; c <= DSL_MAX_CHAIN; c++) {
            if (address(dslTarget[c]) != address(0) || address(dslDriver[c]) != address(0)) {
                console2.log(
                    string.concat(
                        "  chain ",
                        vm.toString(c),
                        ": driver execs=",
                        vm.toString(address(dslDriver[c]) != address(0) ? dslDriver[c].execCount() : 0),
                        " target execs=",
                        vm.toString(address(dslTarget[c]) != address(0) ? dslTarget[c].execCount() : 0)
                    )
                );
            }
        }
    }

    /// @notice Reads a hex file holding the blob portion of the logical byte stream
    ///         (with or without trailing 4844 padding) and prints messages + tables.
    function runBlob(string memory path) external {
        bytes memory blobData = vm.parseBytes(vm.trim(vm.readFile(path)));
        BlobMessage[] memory msgs = BlobCodec.decode(blobData, "");
        _printMessages(msgs);
        _printTables(_derive(msgs));
    }

    /// @dev Messages → tables with the zero callGas oracle (useGasLeft = false mode) —
    ///      the same derivation BlobTranslator wraps, kept piecemeal here so the
    ///      printer can query one array at a time.
    function _derive(BlobMessage[] memory msgs) internal returns (TableGenerator gen) {
        ScenarioStore store = new ScenarioStore();
        store.fromMessages(msgs);
        gen = new TableGenerator();
        gen.generate(store, new uint64[](store.nodeCount()));
    }

    // ──────────────────────────────────────────────
    //  Printing
    // ──────────────────────────────────────────────

    function _msgTypeName(BlobMsgType t) internal pure returns (string memory) {
        string[11] memory names = [
            "Invalid",
            "CloseBlobStream",
            "ChainOperation",
            "Initiate",
            "Call",
            "StaticCall",
            "ReturnSuccess",
            "ReturnFail",
            "Snapshot",
            "Revert",
            "Finish"
        ];
        return names[uint8(t)];
    }

    function _printMessages(BlobMessage[] memory msgs) internal pure {
        console2.log("== Messages ==");
        for (uint256 i = 0; i < msgs.length; i++) {
            BlobMessage memory m = msgs[i];
            string memory line = string.concat("  ", vm.toString(i), ": ", _msgTypeName(m.msgType));
            if (m.msgType == BlobMsgType.Call || m.msgType == BlobMsgType.StaticCall) {
                line = string.concat(
                    line,
                    " to=chain ",
                    vm.toString(m.chainId),
                    " ",
                    vm.toString(m.toAddress),
                    m.value > 0 ? string.concat(" value=", vm.toString(m.value)) : "",
                    " data=",
                    vm.toString(m.data)
                );
            } else if (
                m.msgType == BlobMsgType.InitiateCrossChainTransaction || m.msgType == BlobMsgType.ChainOperation
            ) {
                line = string.concat(line, " chain=", vm.toString(m.chainId), " data=", vm.toString(m.data));
            } else if (m.msgType == BlobMsgType.ReturnSuccess || m.msgType == BlobMsgType.ReturnFail) {
                line = string.concat(line, " data=", vm.toString(m.data));
            }
            console2.log(line);
        }
    }

    function _printTables(TableGenerator gen) internal view {
        console2.log("");
        console2.log("== L1 batch ==");
        ExecutionEntry[] memory l1Entries = gen.l1Entries();
        console2.log("entries:", l1Entries.length);
        for (uint256 i = 0; i < l1Entries.length; i++) {
            ExecutionEntry memory e = l1Entries[i];
            console2.log(
                string.concat(
                    "  [",
                    vm.toString(i),
                    "] ",
                    e.proxyEntryHash == bytes32(0) ? "L2Tx host" : "origin entry",
                    " dest=",
                    vm.toString(e.destinationRollupId),
                    " success=",
                    e.success ? "true" : "false"
                )
            );
            console2.log(string.concat("      proxyEntryHash=", vm.toString(e.proxyEntryHash)));
            console2.log(string.concat("      rollingHash=   ", vm.toString(e.rollingHash)));
            for (uint256 d = 0; d < e.stateUpdates.length; d++) {
                StateUpdate memory u = e.stateUpdates[d];
                console2.log(
                    string.concat(
                        "      delta rollup ",
                        vm.toString(u.rollupId),
                        ": ",
                        vm.toString(u.currentState),
                        " -> ",
                        vm.toString(u.newState),
                        " ether=",
                        vm.toString(u.etherDelta)
                    )
                );
            }
            for (uint256 c = 0; c < e.l2ToL1Calls.length; c++) {
                L2ToL1Call memory cc = e.l2ToL1Calls[c];
                console2.log(
                    string.concat(
                        "      call[",
                        vm.toString(c),
                        "] ",
                        cc.isStatic ? "STATIC " : "",
                        "from rollup ",
                        vm.toString(cc.sourceRollupId),
                        " to ",
                        vm.toString(cc.targetAddress),
                        cc.value > 0 ? string.concat(" value=", vm.toString(cc.value)) : "",
                        cc.revertNextNCalls > 0 ? string.concat(" revertNext=", vm.toString(cc.revertNextNCalls)) : ""
                    )
                );
            }
            if (e.expectedL1ToL2Calls.length > 0) {
                console2.log(string.concat("      reentrant rows: ", vm.toString(e.expectedL1ToL2Calls.length)));
            }
        }
        StaticExecutionEntry[] memory l1Statics = gen.l1StaticEntries();
        console2.log("static entries:", l1Statics.length);
        for (uint256 i = 0; i < l1Statics.length; i++) {
            StaticExecutionEntry memory se = l1Statics[i];
            console2.log(
                string.concat(
                    "  [",
                    vm.toString(i),
                    "] dest=",
                    vm.toString(se.destinationRollupId),
                    " pins=",
                    vm.toString(se.expectedStateRoots.length),
                    " subReads=",
                    vm.toString(se.l2ToL1Calls.length),
                    " success=",
                    se.success ? "true" : "false"
                )
            );
        }

        console2.log("");
        console2.log("== L2 units (execution order) ==");
        for (uint256 i = 0; i < gen.unitCount(); i++) {
            TableGenerator.UnitTag memory tag = gen.unitTag(i);
            L2ExecutionEntry[] memory unitEntries = gen.unitEntries(i);
            console2.log(
                string.concat(
                    "  [",
                    vm.toString(i),
                    "] chain ",
                    vm.toString(tag.chainId),
                    " ",
                    tag.kind == UNIT_KIND_ORIGIN_GROUP ? "origin group" : "inbound delivery",
                    ": entries=",
                    vm.toString(unitEntries.length),
                    " statics=",
                    vm.toString(gen.unitStatics(i).length)
                )
            );
            for (uint256 k = 0; k < unitEntries.length; k++) {
                L2ExecutionEntry memory e2 = unitEntries[k];
                console2.log(
                    string.concat(
                        "      entry[",
                        vm.toString(k),
                        "] calls=",
                        vm.toString(e2.incomingCalls.length),
                        " reentrantRows=",
                        vm.toString(e2.expectedOutgoingCalls.length),
                        " success=",
                        e2.success ? "true" : "false"
                    )
                );
                for (uint256 c = 0; c < e2.incomingCalls.length; c++) {
                    CrossChainCall memory cc = e2.incomingCalls[c];
                    console2.log(
                        string.concat(
                            "        call[",
                            vm.toString(c),
                            "] ",
                            cc.isStatic ? "STATIC " : "",
                            "from rollup ",
                            vm.toString(cc.sourceRollupId),
                            " to ",
                            vm.toString(cc.targetAddress),
                            cc.value > 0 ? string.concat(" value=", vm.toString(cc.value)) : "",
                            cc.revertNextNCalls > 0
                                ? string.concat(" revertNext=", vm.toString(cc.revertNextNCalls))
                                : ""
                        )
                    );
                }
            }
        }
    }
}
