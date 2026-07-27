// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
//  ScriptedActor — a programmable contract standing in for the application
//  contracts a blob scenario references. The harness derives each actor's
//  behavior from the call tree: when invoked (through a source proxy by the
//  manager, or via `drive()` as a transaction's origin driver), the actor runs
//  the next queued program for its calldata — a list of proxy calls mirroring
//  the node's children — and finally returns (or reverts with) the node's
//  return data, raw.
//
//  Programs are queued PER CALLDATA HASH: an entry whose program ends in a
//  revert rolls the queue cursor back with the rest of the state, and only an
//  identical later call would re-run it — which is exactly the repeatable
//  behavior a reverting entry has on-chain.
//
//  Static reads can't touch the queue (view context), so they resolve from a
//  calldata-keyed result map; STATICCALL context is detected with the same
//  transient-store probe `CrossChainProxy` uses.
// ─────────────────────────────────────────────────────────────────────────────

contract ScriptedActor {
    /// @dev Sentinel a forced-revert sub-context terminates with.
    error ForcedRevert();

    uint8 public constant STEP_CALL = 1; // call target; expect success + exact return data
    uint8 public constant STEP_CALL_EXPECT_REVERT = 2; // call target; expect revert with exact payload
    uint8 public constant STEP_STATIC_READ = 3; // staticcall target; expect success + exact return data
    uint8 public constant STEP_SUBCONTEXT_REVERT = 4; // run the next `subCount` steps, then roll them back (Snapshot…Revert)
    uint8 public constant STEP_STATIC_EXPECT_REVERT = 5; // staticcall target; expect revert with exact payload

    struct Step {
        uint8 kind;
        address target; // the cross-chain proxy (on this actor's chain) to call
        uint256 value;
        uint64 stepGas; // explicit gas for mutable proxy calls (reproduces the probed callGas); 0 = forward all
        bytes data;
        bytes expected; // exact return / revert payload
        uint16 subCount; // STEP_SUBCONTEXT_REVERT: how many following steps the region covers
    }

    struct Program {
        bool finalRevert;
        bytes finalData;
    }

    Program[] internal _programs;
    mapping(uint256 => Step[]) internal _steps;
    mapping(bytes32 => uint256[]) internal _queue; // calldata hash → program ids, FIFO
    mapping(bytes32 => uint256) internal _queueCursor;

    mapping(bytes32 => bool) internal _staticKnown; // calldata hash → static read result
    mapping(bytes32 => bool) internal _staticReverts;
    mapping(bytes32 => bytes) internal _staticReturns;
    mapping(bytes32 => Step[]) internal _staticSteps; // sub-reads performed before answering

    /// @notice Committed mutable executions — a rolled-back invocation (span marker,
    ///         failed entry, forced-revert region) rolls this back with it.
    uint256 public execCount;

    uint256 transient _staticDetector;

    // ──────────────────────────────────────────────
    //  Programming (harness)
    // ──────────────────────────────────────────────

    /// @notice Queues a program for invocations carrying `invokeData` (empty for `drive()`).
    function addProgram(bytes calldata invokeData, Step[] calldata steps, bool finalRevert, bytes calldata finalData)
        external
    {
        uint256 id = _programs.length;
        _programs.push(Program({finalRevert: finalRevert, finalData: finalData}));
        for (uint256 i = 0; i < steps.length; i++) {
            _steps[id].push(steps[i]);
        }
        _queue[keccak256(invokeData)].push(id);
    }

    function setStaticResult(bytes calldata data, bool success, bytes calldata ret) external {
        bytes32 k = keccak256(data);
        _staticKnown[k] = true;
        _staticReverts[k] = !success;
        _staticReturns[k] = ret;
    }

    /// @notice Like `setStaticResult`, but the actor first performs `steps` (static
    ///         proxy reads only — the invocation context is a STATICCALL) and asserts
    ///         each result before answering.
    function setStaticProgram(bytes calldata data, Step[] calldata steps, bool success, bytes calldata ret) external {
        bytes32 k = keccak256(data);
        _staticKnown[k] = true;
        _staticReverts[k] = !success;
        _staticReturns[k] = ret;
        for (uint256 i = 0; i < steps.length; i++) {
            require(
                steps[i].kind == STEP_STATIC_READ || steps[i].kind == STEP_STATIC_EXPECT_REVERT,
                "ScriptedActor: static programs allow only static reads"
            );
            _staticSteps[k].push(steps[i]);
        }
    }

    // ──────────────────────────────────────────────
    //  Invocation
    // ──────────────────────────────────────────────

    /// @notice Origin-driver entry point: runs the next program queued for the
    ///         `drive()` calldata — the transaction's root calls.
    function drive() external payable {
        _run(msg.data);
    }

    fallback() external payable {
        // STATICCALL detection: a tstore attempt in a self-call reverts in static
        // context (same probe CrossChainProxy uses, same gas cap — the static-context
        // fault consumes everything forwarded).
        (bool mutableCtx,) = address(this).call{gas: 1000}(abi.encodeCall(this.staticProbe, ()));
        if (mutableCtx) {
            _run(msg.data);
        } else {
            _serveStatic();
        }
    }

    function staticProbe() external {
        require(msg.sender == address(this), "ScriptedActor: probe is internal");
        _staticDetector = 1;
    }

    /// @notice Self-call target for STEP_SUBCONTEXT_REVERT: runs the span's steps,
    ///         then always reverts so their state effects roll back.
    function runSpanAndRevert(uint256 programId, uint256 from, uint256 count) external {
        require(msg.sender == address(this), "ScriptedActor: span is internal");
        _runSteps(programId, from, from + count);
        revert ForcedRevert();
    }

    // ──────────────────────────────────────────────
    //  Internals
    // ──────────────────────────────────────────────

    function _run(bytes memory invokeData) internal {
        bytes32 k = keccak256(invokeData);
        uint256[] storage q = _queue[k];
        require(_queueCursor[k] < q.length, "ScriptedActor: no program queued for calldata");
        uint256 id = q[_queueCursor[k]++];
        execCount++;

        _runSteps(id, 0, _steps[id].length);

        Program storage p = _programs[id];
        bytes memory d = p.finalData;
        if (p.finalRevert) {
            assembly {
                revert(add(d, 0x20), mload(d))
            }
        }
        assembly {
            return(add(d, 0x20), mload(d))
        }
    }

    function _runSteps(uint256 programId, uint256 start, uint256 end) internal {
        uint256 i = start;
        while (i < end) {
            Step storage s = _steps[programId][i];
            if (s.kind == STEP_SUBCONTEXT_REVERT) {
                (bool ok, bytes memory ret) =
                    address(this).call(abi.encodeCall(this.runSpanAndRevert, (programId, i + 1, s.subCount)));
                require(!ok && bytes4(ret) == ForcedRevert.selector, "ScriptedActor: span did not revert cleanly");
                i += 1 + s.subCount;
            } else {
                _runStep(s);
                i++;
            }
        }
    }

    function _runStep(Step storage s) internal {
        bool ok;
        bytes memory ret;
        if (s.kind == STEP_CALL) {
            (ok, ret) = _dispatch(s);
            require(ok, "ScriptedActor: expected call to succeed");
        } else if (s.kind == STEP_CALL_EXPECT_REVERT) {
            (ok, ret) = _dispatch(s);
            require(!ok, "ScriptedActor: expected call to revert");
        } else if (s.kind == STEP_STATIC_READ) {
            (ok, ret) = _dispatchStatic(s);
            require(ok, "ScriptedActor: expected static read to succeed");
        } else if (s.kind == STEP_STATIC_EXPECT_REVERT) {
            (ok, ret) = _dispatchStatic(s);
            require(!ok, "ScriptedActor: expected static read to revert");
        } else {
            revert("ScriptedActor: unknown step kind");
        }
        require(keccak256(ret) == keccak256(s.expected), "ScriptedActor: unexpected return/revert data");
    }

    /// @dev Mutable proxy call with the step's explicit gas when set.
    function _dispatch(Step storage s) internal returns (bool ok, bytes memory ret) {
        if (s.stepGas == 0) return s.target.call{value: s.value}(s.data);
        return s.target.call{value: s.value, gas: s.stepGas}(s.data);
    }

    /// @dev Static proxy read with the step's explicit gas when set. Capping matters: the proxy's
    ///      static-context probe (`staticCheck`) burns everything forwarded to it inside a
    ///      STATICCALL, so an uncapped read would torch ~63/64 of this frame's remaining gas and
    ///      starve the explicit requests of the steps after it.
    function _dispatchStatic(Step storage s) internal view returns (bool ok, bytes memory ret) {
        if (s.stepGas == 0) return s.target.staticcall(s.data);
        return s.target.staticcall{gas: s.stepGas}(s.data);
    }

    function _serveStatic() internal view {
        bytes32 k = keccak256(msg.data);
        require(_staticKnown[k], "ScriptedActor: unknown static read");
        Step[] storage steps = _staticSteps[k];
        for (uint256 i = 0; i < steps.length; i++) {
            Step storage s = steps[i];
            (bool ok, bytes memory got) = _dispatchStatic(s);
            require(ok == (s.kind == STEP_STATIC_READ), "ScriptedActor: unexpected static sub-read outcome");
            require(keccak256(got) == keccak256(s.expected), "ScriptedActor: unexpected static sub-read data");
        }
        bytes memory ret = _staticReturns[k];
        if (_staticReverts[k]) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        assembly {
            return(add(ret, 0x20), mload(ret))
        }
    }
}
