// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlobScenarioBase} from "./BlobScenarioBase.sol";
import {BlobMessage, Msg, MsgList} from "../../script/blob/BlobMessages.sol";
import {ScriptedActor} from "../../script/blob/ScriptedActor.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  DslScenarioBase — pseudo-code authoring layer over BlobScenarioBase.
//
//  A scenario is a newline-separated script; `runDsl` compiles it into the
//  standardized blob message list, auto-deploys the referenced chains and one
//  driver + one target actor per chain, runs the full `runScenario` pipeline
//  (codec ⇄ IR ⇄ tables ⇄ live execution), and asserts every actor's committed
//  `execCount` against what the script implies.
//
//  Grammar (case-insensitive; `#` starts a comment; blank lines ignored):
//
//      <chain> call <chain>        executor calls target; opens a frame
//      <chain> staticCall <chain>  read-only frame (cannot nest anything)
//      <chain> return              closes the innermost frame with ReturnSuccess
//      <chain> returnFail          closes it with ReturnFail
//      <chain> snapshot            opens a forced-revert region in the current frame
//      <chain> revert              closes the open region (same frame, non-empty)
//      --                          transaction separator
//
//      <chain> := L1 | L2_a .. L2_z     (chain id 0, 1..26; rollup id == chain id)
//
//  The leading chain token is the chain EXECUTING the instruction and is
//  validated against the context stack. The first instruction of each
//  transaction fixes the origin (implicit Initiate); `--`/end-of-script emit
//  Finish, and end-of-script adds CloseBlobStream. All tx/call/return payloads
//  are auto-generated and globally unique ("dsl.tx#i", "dsl.call#k",
//  "dsl.ret#k", …), so repeated shapes never re-match a rolled-back entry.
//
//  Limits: no value transfer, no ChainOperations, one open region at a time,
//  no committed (successful mutable) call inside a returnFail frame (both
//  ScenarioStore v1 rules), one `runDsl` per test.
// ─────────────────────────────────────────────────────────────────────────────

abstract contract DslScenarioBase is BlobScenarioBase {
    uint64 internal constant DSL_MAX_CHAIN = 26; // L2_a .. L2_z
    uint256 internal constant DSL_MAX_DEPTH = 64; // mirrors ScenarioStore's frame stack

    /// @notice Per-chain origin driver / call target, deployed lazily by the compiler.
    mapping(uint64 => ScriptedActor) internal dslDriver;
    mapping(uint64 => ScriptedActor) internal dslTarget;

    /// @dev Expected committed `execCount` per chain, computed during compilation.
    uint256[27] internal _dslExpTarget;
    uint256[27] internal _dslExpDriver;
    bool internal _dslRan;

    // ──────────────────────────────────────────────
    //  Entry points
    // ──────────────────────────────────────────────

    /// @notice Compiles `script`, runs the full scenario pipeline, and asserts every
    ///         actor's committed execution count.
    function runDsl(string memory script) internal {
        require(!_dslRan, "DSL: one runDsl per test");
        _dslRan = true;
        BlobMessage[] memory msgs = dslCompile(script);
        runScenario(msgs);
        for (uint64 c = 0; c <= DSL_MAX_CHAIN; c++) {
            if (address(dslTarget[c]) != address(0)) {
                assertEq(
                    dslTarget[c].execCount(),
                    _dslExpTarget[c],
                    string.concat("DSL: committed executions of target on chain ", vm.toString(c))
                );
            }
            if (address(dslDriver[c]) != address(0)) {
                assertEq(
                    dslDriver[c].execCount(),
                    _dslExpDriver[c],
                    string.concat("DSL: committed executions of driver on chain ", vm.toString(c))
                );
            }
        }
    }

    /// @notice Compilation only (setup + message building, no execution) — for
    ///         message-order inspection and parser tests.
    function dslCompile(string memory script) internal returns (BlobMessage[] memory) {
        string[] memory lines = vm.split(script, "\n");
        (uint64 maxChain, uint256 msgCap) = _dslScan(lines);
        if (address(rollups) == address(0)) {
            _setUpChains(maxChain);
        } else {
            require(l2ChainCount >= maxChain, "DSL: scenario uses more chains than _setUpChains registered");
        }
        return _dslBuild(lines, msgCap);
    }

    // ──────────────────────────────────────────────
    //  Pass 1 — token-shape validation, chain census, exact message count
    // ──────────────────────────────────────────────

    function _dslScan(string[] memory lines) internal pure returns (uint64 maxChain, uint256 msgCap) {
        uint256 instr;
        uint256 seps;
        for (uint256 i = 0; i < lines.length; i++) {
            string[] memory toks = _dslTokens(lines[i]);
            if (toks.length == 0) continue;
            uint256 lineNo = i + 1;
            if (_dslEq(toks[0], "--")) {
                if (toks.length != 1) _dslFail(lineNo, "unexpected tokens after '--'");
                seps++;
                continue;
            }
            uint64 exec = _dslChain(toks[0], lineNo);
            if (exec > maxChain) maxChain = exec;
            if (toks.length < 2) _dslFail(lineNo, "missing verb");
            if (_dslEq(toks[1], "call") || _dslEq(toks[1], "staticcall")) {
                if (toks.length != 3) _dslFail(lineNo, string.concat("expected: <chain> ", toks[1], " <chain>"));
                uint64 tgt = _dslChain(toks[2], lineNo);
                if (tgt > maxChain) maxChain = tgt;
            } else if (
                _dslEq(toks[1], "return") || _dslEq(toks[1], "returnfail") || _dslEq(toks[1], "snapshot")
                    || _dslEq(toks[1], "revert")
            ) {
                if (toks.length != 2) _dslFail(lineNo, string.concat("expected: <chain> ", toks[1]));
            } else {
                _dslFail(lineNo, string.concat("unknown verb '", toks[1], "'"));
            }
            instr++;
        }
        if (instr == 0) revert("DSL: empty script");
        // Every instruction emits exactly one message; each tx adds Initiate+Finish,
        // and the stream ends with one CloseBlobStream.
        msgCap = instr + 2 * (seps + 1) + 1;
    }

    // ──────────────────────────────────────────────
    //  Pass 2 — context-stack walk: emission + structural validation + counts
    // ──────────────────────────────────────────────

    struct DslBuild {
        MsgList l;
        uint64[] frameChain; // executing chain per open frame
        bool[] frameStatic;
        uint256[] frameCall; // global call index (keys the frame's return payload)
        uint256[] frameLine; // line that opened the frame (for error messages)
        uint256 sp;
        bool txOpen;
        uint64 origin;
        uint256 txIdx;
        uint256 txCalls; // calls emitted in the current tx
        bool regionOpen;
        uint256 regionSp; // stack depth the open region's siblings live at
        uint256 regionLine;
        uint256 regionCalls; // completed sibling calls inside the open region
        uint256 gCall; // global call-site counter (payload uniqueness)
        uint256[27][] pending; // pending[d][c]: committed count folded into depth d, per chain
        uint256[27] regionSaved; // checkpoint of pending[regionSp] at Snapshot
        bool[] childOk; // childOk[d]: a frame at depth d closed with `return` (unsupported under returnFail)
    }

    function _dslBuild(string[] memory lines, uint256 msgCap) internal returns (BlobMessage[] memory) {
        DslBuild memory b;
        b.l = Msg.list(msgCap);
        b.frameChain = new uint64[](DSL_MAX_DEPTH);
        b.frameStatic = new bool[](DSL_MAX_DEPTH);
        b.frameCall = new uint256[](DSL_MAX_DEPTH);
        b.frameLine = new uint256[](DSL_MAX_DEPTH);
        b.pending = new uint256[27][](DSL_MAX_DEPTH + 1);
        b.childOk = new bool[](DSL_MAX_DEPTH + 1);
        for (uint256 c = 0; c <= DSL_MAX_CHAIN; c++) {
            _dslExpTarget[c] = 0;
            _dslExpDriver[c] = 0;
        }

        for (uint256 i = 0; i < lines.length; i++) {
            string[] memory toks = _dslTokens(lines[i]);
            if (toks.length == 0) continue;
            uint256 lineNo = i + 1;

            if (_dslEq(toks[0], "--")) {
                _dslFinishTx(b, lineNo);
                continue;
            }

            uint64 exec = _dslChain(toks[0], lineNo);
            string memory verb = toks[1];
            bool isCall = _dslEq(verb, "call");
            bool isStatic = _dslEq(verb, "staticcall");

            if (!b.txOpen) {
                if (!(isCall || isStatic || _dslEq(verb, "snapshot"))) {
                    _dslFail(lineNo, "transaction must start with call, staticCall, or snapshot");
                }
                b.origin = exec;
                b.txOpen = true;
                b.txCalls = 0;
                if (address(dslDriver[exec]) == address(0)) dslDriver[exec] = newActor(exec);
                Msg.push(b.l, Msg.initiate(exec, _dslBytes("dsl.tx#", b.txIdx)));
            }

            uint64 cur = b.sp == 0 ? b.origin : b.frameChain[b.sp - 1];
            if (exec != cur) {
                _dslFail(lineNo, string.concat("executor is ", toks[0], " but ", _dslChainName(cur), " is executing"));
            }

            if (isCall || isStatic) {
                _dslCall(b, toks, exec, isStatic, lineNo);
            } else if (_dslEq(verb, "return") || _dslEq(verb, "returnfail")) {
                _dslReturn(b, _dslEq(verb, "return"), lineNo);
            } else if (_dslEq(verb, "snapshot")) {
                if (b.regionOpen) {
                    _dslFail(
                        lineNo, string.concat("snapshot while a region is open (line ", _dslUint(b.regionLine), ")")
                    );
                }
                if (b.sp > 0 && b.frameStatic[b.sp - 1]) _dslFail(lineNo, "cannot nest inside a static call");
                b.regionOpen = true;
                b.regionSp = b.sp;
                b.regionLine = lineNo;
                b.regionCalls = 0;
                for (uint256 c = 0; c <= DSL_MAX_CHAIN; c++) {
                    b.regionSaved[c] = b.pending[b.sp][c];
                }
                Msg.push(b.l, Msg.snapshot());
            } else {
                // "revert" — the only remaining verb after pass-1 validation.
                if (!b.regionOpen || b.sp != b.regionSp) _dslFail(lineNo, "revert without matching snapshot");
                if (b.regionCalls == 0) _dslFail(lineNo, "empty snapshot region");
                for (uint256 c = 0; c <= DSL_MAX_CHAIN; c++) {
                    b.pending[b.sp][c] = b.regionSaved[c];
                }
                b.regionOpen = false;
                Msg.push(b.l, Msg.revertMarker());
            }
        }

        if (!b.txOpen) _dslFail(lines.length, "empty transaction"); // trailing '--'
        _dslFinishTx(b, lines.length);
        Msg.push(b.l, Msg.closeBlobStream());
        return Msg.done(b.l);
    }

    /// @dev Emits a call/staticCall message and pushes its frame. Root calls come from
    ///      the origin driver (all roots of a tx share it); nested calls come from the
    ///      executing frame's target — exactly the actor wiring the harness enforces.
    function _dslCall(DslBuild memory b, string[] memory toks, uint64 exec, bool isStatic, uint256 lineNo) internal {
        uint64 tgt = _dslChain(toks[2], lineNo);
        if (tgt == exec) _dslFail(lineNo, "call target equals executing chain");
        if (b.sp > 0 && b.frameStatic[b.sp - 1]) _dslFail(lineNo, "cannot nest inside a static call");
        if (b.sp == DSL_MAX_DEPTH) _dslFail(lineNo, "call depth limit exceeded");
        if (address(dslTarget[tgt]) == address(0)) dslTarget[tgt] = newActor(tgt);

        address from = b.sp == 0 ? address(dslDriver[b.origin]) : address(dslTarget[exec]);
        bytes memory data = _dslBytes(isStatic ? "dsl.static#" : "dsl.call#", b.gCall);
        if (isStatic) {
            Msg.push(b.l, Msg.staticCall(tgt, from, address(dslTarget[tgt]), data));
        } else {
            Msg.push(b.l, Msg.call(tgt, from, address(dslTarget[tgt]), 0, data));
        }
        b.frameChain[b.sp] = tgt;
        b.frameStatic[b.sp] = isStatic;
        b.frameCall[b.sp] = b.gCall;
        b.frameLine[b.sp] = lineNo;
        b.sp++;
        b.gCall++;
        b.txCalls++;
    }

    /// @dev Pops the innermost frame. A frame commits (+1 for its target, plus its
    ///      already-committed subtree) only when it closes with `return`; a
    ///      `returnFail` discards the whole subtree, and statics never count.
    function _dslReturn(DslBuild memory b, bool ok, uint256 lineNo) internal pure {
        if (b.sp == 0) _dslFail(lineNo, "return with no open call");
        if (b.regionOpen && b.sp <= b.regionSp) {
            _dslFail(lineNo, string.concat("unclosed snapshot region (opened at line ", _dslUint(b.regionLine), ")"));
        }
        uint256 d = b.sp - 1;
        if (ok) {
            Msg.push(b.l, Msg.returnSuccess(_dslBytes("dsl.ret#", b.frameCall[d])));
            if (!b.frameStatic[d]) {
                for (uint256 c = 0; c <= DSL_MAX_CHAIN; c++) {
                    b.pending[d][c] += b.pending[d + 1][c];
                }
                b.pending[d][b.frameChain[d]] += 1;
                b.childOk[d] = true;
            }
        } else {
            if (b.childOk[d + 1]) {
                _dslFail(lineNo, "returnFail frame contains a committed call (unsupported shape)");
            }
            Msg.push(b.l, Msg.returnFail(_dslBytes("dsl.fail#", b.frameCall[d])));
        }
        for (uint256 c = 0; c <= DSL_MAX_CHAIN; c++) {
            b.pending[d + 1][c] = 0;
        }
        b.childOk[d + 1] = false;
        b.sp--;
        if (b.regionOpen && b.sp == b.regionSp) b.regionCalls++;
    }

    /// @dev Closes the current tx (`--` or end of script): validates all brackets are
    ///      closed, emits Finish, folds the root accumulator into the expectations
    ///      (the origin driver commits exactly once per tx it drives).
    function _dslFinishTx(DslBuild memory b, uint256 lineNo) internal {
        if (!b.txOpen) _dslFail(lineNo, "empty transaction");
        if (b.sp != 0) {
            _dslFail(
                lineNo, string.concat("unclosed call frame (opened at line ", _dslUint(b.frameLine[b.sp - 1]), ")")
            );
        }
        if (b.regionOpen) {
            _dslFail(lineNo, string.concat("unclosed snapshot region (opened at line ", _dslUint(b.regionLine), ")"));
        }
        if (b.txCalls == 0) _dslFail(lineNo, "empty transaction");
        Msg.push(b.l, Msg.finish());
        for (uint256 c = 0; c <= DSL_MAX_CHAIN; c++) {
            _dslExpTarget[c] += b.pending[0][c];
            b.pending[0][c] = 0;
        }
        _dslExpDriver[b.origin] += 1;
        b.childOk[0] = false;
        b.txOpen = false;
        b.txIdx++;
    }

    // ──────────────────────────────────────────────
    //  Lexing helpers
    // ──────────────────────────────────────────────

    /// @dev Strip comment → normalize whitespace/case → split → drop empty tokens.
    function _dslTokens(string memory rawLine) internal pure returns (string[] memory toks) {
        string memory line = vm.split(rawLine, "#")[0];
        line = vm.replace(line, "\t", " ");
        line = vm.replace(line, "\r", "");
        line = vm.toLowercase(vm.trim(line));
        string[] memory parts = vm.split(line, " ");
        uint256 n;
        for (uint256 i = 0; i < parts.length; i++) {
            if (bytes(parts[i]).length != 0) n++;
        }
        toks = new string[](n);
        uint256 w;
        for (uint256 i = 0; i < parts.length; i++) {
            if (bytes(parts[i]).length != 0) toks[w++] = parts[i];
        }
    }

    function _dslChain(string memory tok, uint256 lineNo) internal pure returns (uint64) {
        bytes memory t = bytes(tok);
        if (t.length == 2 && t[0] == "l" && t[1] == "1") return 0;
        if (t.length == 4 && t[0] == "l" && t[1] == "2" && t[2] == "_" && t[3] >= "a" && t[3] <= "z") {
            return uint64(uint8(t[3]) - uint8(bytes1("a")) + 1);
        }
        revert(string.concat("DSL line ", _dslUint(lineNo), ": bad chain token '", tok, "' (want L1 or L2_a..L2_z)"));
    }

    function _dslChainName(uint64 c) internal pure returns (string memory) {
        if (c == 0) return "l1";
        return string.concat("l2_", string(abi.encodePacked(bytes1(uint8(bytes1("a")) + uint8(c) - 1))));
    }

    function _dslBytes(string memory prefix, uint256 n) internal pure returns (bytes memory) {
        return bytes(string.concat(prefix, _dslUint(n)));
    }

    /// @dev Decimal formatter usable from `pure` contexts (vm.toString is external).
    function _dslUint(uint256 n) internal pure returns (string memory) {
        if (n == 0) return "0";
        bytes memory buf = new bytes(78);
        uint256 i = 78;
        while (n > 0) {
            buf[--i] = bytes1(uint8(48 + (n % 10)));
            n /= 10;
        }
        bytes memory out = new bytes(78 - i);
        for (uint256 j = 0; j < out.length; j++) {
            out[j] = buf[i + j];
        }
        return string(out);
    }

    function _dslEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _dslFail(uint256 lineNo, string memory reason) internal pure {
        revert(string.concat("DSL line ", _dslUint(lineNo), ": ", reason));
    }
}
