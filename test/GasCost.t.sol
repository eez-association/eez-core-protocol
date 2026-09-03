// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {GasFixture, ArrayStore} from "./GasFixture.t.sol";
import {ExecutionEntry, RollupUpdate, L2ToL1Call, ExpectedL1ToL2Call} from "../src/interfaces/IEEZ.sol";

/// @notice Minimal meta-hook receiver: accepts the callback and returns without consuming,
///         so a posted transient prefix is loaded but never run.
contract NoopMetaReceiver {
    function executeMetaCrossChainTransactions() external {}
}

/// @title GasCost
/// @notice L1-only gas measurements for the EEZ flows. Two kinds of cost:
///         (1) POSTING a table (`postAndVerifyBatch`), and
///         (2) EXECUTING an entry from a user's perspective (user calls a cross-chain proxy
///             that consumes a deferred entry).
///
///         Every measured operation is run TWICE in consecutive blocks and only the SECOND
///         (warm) run is reported — the first pays one-time cold-storage init ("the first one
///         is more expensive"). Numbers are printed via `gasleft()` deltas with `console.log`;
///         run with `-vv`.
///
///         Entry shape is held fixed at "touches 2 rollups (2 RollupUpdates), one destination
///         rollup" so cases are comparable. Cases build up incrementally:
///           bare entry -> +1 L2ToL1Call -> +1 reentrant ExpectedL1ToL2Call
///           -> erc20 / uniswap directly -> erc20 + uniswap + reentrant combined.
contract GasCost is GasFixture {
    /// @notice Poster for meta-prefix batches (deployed here, outside any measured window).
    NoopMetaReceiver internal noopMetaReceiver = new NoopMetaReceiver();

    /// @notice Steady-state post of one rS entry of the given shape. Caller ensures the queue
    ///         already holds one same-shape entry (the "previous block") so it is delete+push over
    ///         non-zero originals. Colds slots first. Entries are built before the measured
    ///         window so the number covers only the post itself.
    function _measurePostSteadyShape(uint256 nCalls, uint256 nExpected) internal returns (uint256 gasUsed) {
        ExecutionEntry[] memory entries = _savedFor(rS.id, 1, nCalls, nExpected);
        _coolProtocol();
        vm.cool(address(rS.manager));
        uint256 g = gasleft();
        _postBatchTwo(rB.id, rS.id, entries);
        gasUsed = g - gasleft();
    }

    /// @notice Posts a batch attesting both rA and rB (so both are verified this block), with all
    ///         entries deferred to rA's queue.
    function _postTwoRollups(ExecutionEntry[] memory entries) internal {
        _postBatchTwo(rA.id, rB.id, entries);
    }

    /// @notice The proxyEntryHash for the top-level trigger: alice calls triggerProxy with "".
    ///         Source = alice on L1 (MAINNET), target = triggerTarget on rA.
    function _triggerHash() internal view returns (bytes32) {
        return _ccHash(NOT_STATIC_CALL, alice, MAINNET_ROLLUP_ID, triggerTarget, uint64(rA.id), 0, "");
    }

    /// @notice A single placeholder reentrant table entry for a DEFERRED cross-rollup reentry
    ///         (actor -> counterProxy.increment() on rB). Never executed, so its position key is
    ///         a placeholder; the only post-validated content is the (empty) sub-call array.
    function _reentrantExpected() internal view returns (ExpectedL1ToL2Call[] memory expected) {
        expected = new ExpectedL1ToL2Call[](1);
        expected[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: _expectedL1toL2Hash(_nestedCch(_reentrantCall()), bytes32(0)),
            l2ToL1Calls: new L2ToL1Call[](0),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    function _noExpected() internal pure returns (ExpectedL1ToL2Call[] memory) {
        return new ExpectedL1ToL2Call[](0);
    }

    // ──────────────────────────────────────────────
    //  Measurement drivers
    // ──────────────────────────────────────────────

    /// @notice Posts the given entries; the same batch is meant to be posted twice (caller posts a
    ///         same-shape warm-up first so the measured post rewrites non-zero slots). Cools first,
    ///         so the measured post prices like a fresh tx against the warmed-up state.
    function _measurePost(ExecutionEntry[] memory entries) internal returns (uint256 gasUsed) {
        _coolProtocol();
        uint256 g = gasleft();
        _postTwoRollups(entries);
        gasUsed = g - gasleft();
    }

    /// @notice Builds + posts one EXECUTED entry routed to rA with `nDeltas` RollupUpdates (1 = one
    ///         rollup, 2 = two rollups). Reads live roots, safe across blocks. The batch always
    ///         attests both rA and rB so a reentrant nested call into rB passes its verified gate,
    ///         independent of how many RollupUpdates the entry carries. Computes the entry's rolling
    ///         hash and reentrant table from the actual calls (seeded with `_hEntryBegin`).
    function _postEntryN(uint8 nDeltas, L2ToL1Call[] memory calls, bytes[] memory rets, bool reentrant) internal {
        bytes32 newA = keccak256(abi.encodePacked(_getRollupState(rA.id), uint8(0xA)));
        bytes32 newB = keccak256(abi.encodePacked(_getRollupState(rB.id), uint8(0xB)));
        RollupUpdate[] memory deltas = nDeltas == 2 ? _twoDeltas(newA, newB) : _oneDelta(newA);
        bytes32 ph = _triggerHash();
        (bytes32 h, ExpectedL1ToL2Call[] memory expected) = _foldExec(_hEntryBegin(deltas, ph), calls, rets, reentrant);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _entry(deltas, ph, calls, expected, "", h);
        _postTwoRollups(entries);
    }

    /// @notice Posts one entry (`nDeltas` rollups touched) then measures alice's trigger call that
    ///         executes it — with cold slots (the realistic "separate user tx" cost).
    function _measureExecN(
        uint8 nDeltas,
        L2ToL1Call[] memory calls,
        bytes[] memory rets,
        bool reentrant
    )
        internal
        returns (uint256 gasUsed)
    {
        _postEntryN(nDeltas, calls, rets, reentrant);
        _coolForExec(); // entry was loaded by the (prior) post tx → all its slots are cold to the user

        uint256 g = gasleft();
        vm.prank(alice);
        (bool ok,) = triggerProxy.call("");
        gasUsed = g - gasleft();
        require(ok, "exec trigger reverted");
    }

    /// @notice Default execution measurement. Touches a single rollup (1 RollupUpdate) unless the
    ///         entry is `reentrant`: a reentrant L1→L2 destination must be in the entry's own
    ///         rollupUpdates (src/EEZ.sol `ReentrantDestinationNotVerified`), so a cross-rollup
    ///         reentrant entry necessarily touches 2 rollups.
    function _measureExec(
        L2ToL1Call[] memory calls,
        bytes[] memory rets,
        bool reentrant
    )
        internal
        returns (uint256 gasUsed)
    {
        uint8 nDeltas = reentrant ? 2 : 1;
        return _measureExecN(nDeltas, calls, rets, reentrant);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  POSTING COST — incremental entry shape (warm: measure the 2nd post)
    // ══════════════════════════════════════════════════════════════════════════

    function test_PostCost_Incremental() public {
        // Deferred entries are never executed, so currentRoot/rollingHash are placeholders.
        bytes32 ph = keccak256("deferred-trigger");

        // P0: bare entry (no calls, no expected)
        ExecutionEntry[] memory p0 = new ExecutionEntry[](1);
        p0[0] = _entry(_twoDeltas("a", "b"), ph, new L2ToL1Call[](0), _noExpected(), "", bytes32(0));

        // P1: +1 L2ToL1Call
        ExecutionEntry[] memory p1 = new ExecutionEntry[](1);
        p1[0] = _entry(_twoDeltas("a", "b"), ph, _calls(_sinkCall()), _noExpected(), "", bytes32(0));

        // P2: +1 L2ToL1Call +1 reentrant ExpectedL1ToL2Call
        ExecutionEntry[] memory p2 = new ExecutionEntry[](1);
        p2[0] = _entry(_twoDeltas("a", "b"), ph, _calls(_reentrantCall()), _reentrantExpected(), "", bytes32(0));

        // Each measured post follows a SAME-SHAPE post in the prior block, so every measurement
        // wipes identical leftovers and rewrites non-zero slots — steady state, comparable deltas.
        _postTwoRollups(p0);
        vm.roll(block.number + 1);

        uint256 g0 = _measurePost(p0);
        vm.roll(block.number + 1);
        _postTwoRollups(p1);
        vm.roll(block.number + 1);
        uint256 g1 = _measurePost(p1);
        vm.roll(block.number + 1);
        _postTwoRollups(p2);
        vm.roll(block.number + 1);
        uint256 g2 = _measurePost(p2);

        console.log("post_bare_entry            ", g0);
        console.log("post_entry_1call           ", g1);
        console.log("post_entry_1call_1expected ", g2);
        console.log("  delta +1 L2ToL1Call      ", g1 - g0);
        console.log("  delta +1 ExpectedL1ToL2  ", g2 - g1);
        assertLt(g0, g1, "an extra L2ToL1Call must cost gas");
        assertLt(g1, g2, "an extra ExpectedL1ToL2Call must cost gas");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  POSTING COST — table with 1 entry vs 2 entries (each: 2 rollups + 1 reentrant)
    // ══════════════════════════════════════════════════════════════════════════

    function test_PostCost_1vs2Entries() public {
        bytes32 ph = keccak256("deferred-trigger");

        // 1 RollupUpdate, deferred (never executed). The reentrant flat call's source is rA, so a
        // single delta passes post-validation; the reentrant table carries no routing.
        ExpectedL1ToL2Call[] memory exp = new ExpectedL1ToL2Call[](1);
        exp[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: keccak256("x"),
            l2ToL1Calls: new L2ToL1Call[](0),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });
        ExecutionEntry memory shaped =
            _entry(_oneDelta(bytes32("b")), ph, _calls(_reentrantCall()), exp, "", bytes32(0));

        ExecutionEntry[] memory one = new ExecutionEntry[](1);
        one[0] = shaped;
        ExecutionEntry[] memory two = new ExecutionEntry[](2);
        two[0] = shaped;
        two[1] = shaped;

        // warm-up then measure
        _postTwoRollups(one);
        vm.roll(block.number + 1);
        uint256 g1 = _measurePost(one);

        vm.roll(block.number + 1);
        _postTwoRollups(two);
        vm.roll(block.number + 1);
        uint256 g2 = _measurePost(two);

        console.log("postBatch_1entry  ", g1);
        console.log("postBatch_2entries", g2);
        console.log("  delta per extra entry", g2 - g1);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  EXECUTION COST — incremental, from the user's perspective
    // ══════════════════════════════════════════════════════════════════════════

    function test_ExecCost_Incremental() public {
        // (a) entry with one plain L2ToL1Call (no expected)
        _measureExec(_calls(_sinkCall()), _rets(""), false); // warm-up
        vm.roll(block.number + 1);
        uint256 gA = _measureExec(_calls(_sinkCall()), _rets(""), false);

        // (b) entry whose single L2ToL1Call re-enters once — SAME-rollup reentry, so still a single
        //     RollupUpdate (1 rollup). Uses _measureExecN(1, ...).
        vm.roll(block.number + 1);
        _measureExecN(1, _calls(_reentrantCallA()), _rets(""), true); // warm-up
        vm.roll(block.number + 1);
        uint256 gB = _measureExecN(1, _calls(_reentrantCallA()), _rets(""), true);

        console.log("exec_entry_1call          ", gA);
        console.log("exec_entry_1call_reentrant", gB);
        console.log("  delta +reentrant        ", gB - gA);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  EXECUTION COST — "usual" behaviours directly (erc20, uniswap)
    // ══════════════════════════════════════════════════════════════════════════

    // Marginal execution cost of touching an extra rollup (one more RollupUpdate): same plain-call
    // entry executed with 1 vs 2 RollupUpdates. The delta is the read of the extra delta + the
    // SSTORE of that rollup's root at consumption.
    function test_ExecCost_PerRollupDelta() public {
        _measureExecN(1, _calls(_sinkCall()), _rets(""), false); // warm-up
        vm.roll(block.number + 1);
        uint256 oneRollup = _measureExecN(1, _calls(_sinkCall()), _rets(""), false);

        vm.roll(block.number + 1);
        _measureExecN(2, _calls(_sinkCall()), _rets(""), false); // warm-up
        vm.roll(block.number + 1);
        uint256 twoRollup = _measureExecN(2, _calls(_sinkCall()), _rets(""), false);

        console.log("exec_1rollup", oneRollup);
        console.log("exec_2rollup", twoRollup);
        console.log("  +1 rollup (RollupUpdate)", twoRollup - oneRollup);
    }

    // Profiling target: a single cooled "Entry · 1 plain call" execution. Run with -vvvv to read
    // the per-call-frame gas (proxy hop, EEZ.executeCrossChainCall, sink call), or --gas-report for
    // per-function gas.
    function test_GasProfile_Entry1Call() public {
        _measureExecN(1, _calls(_sinkCall()), _rets(""), false); // warm-up (creates source proxies)
        vm.roll(block.number + 1);
        _postEntryN(1, _calls(_sinkCall()), _rets(""), false);
        _coolForExec();
        uint256 g = gasleft();
        vm.prank(alice);
        (bool ok,) = triggerProxy.call("");
        require(ok, "profile trigger reverted");
        console.log("total_exec", g - gasleft());
    }

    function test_ExecCost_Erc20() public {
        _measureExec(_calls(_erc20Call()), _rets(abi.encode(true)), false); // warm-up (transfer returns true)
        vm.roll(block.number + 1);
        uint256 g = _measureExec(_calls(_erc20Call()), _rets(abi.encode(true)), false);
        console.log("exec_erc20_transfer", g);
    }

    function test_ExecCost_Uniswap() public {
        _measureExec(_calls(_uniswapCall()), _rets(""), false); // warm-up (sink returns empty)
        vm.roll(block.number + 1);
        uint256 g = _measureExec(_calls(_uniswapCall()), _rets(""), false);
        console.log("exec_uniswap_swap", g);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  EXECUTION COST — erc20 + uniswap + reentrant combined, from the user
    // ══════════════════════════════════════════════════════════════════════════

    function test_ExecCost_Erc20_Uniswap_Reentrant() public {
        L2ToL1Call[] memory calls = new L2ToL1Call[](3);
        calls[0] = _erc20Call();
        calls[1] = _uniswapCall();
        calls[2] = _reentrantCall();

        // call1 erc20 (ret=true), call2 uniswap->sink (ret=""), call3 reentrant (ret="")
        bytes[] memory rets = new bytes[](3);
        rets[0] = abi.encode(true);
        rets[1] = "";
        rets[2] = "";

        _measureExec(calls, rets, true); // warm-up
        vm.roll(block.number + 1);
        uint256 g = _measureExec(calls, rets, true);
        console.log("exec_erc20_uniswap_reentrant", g);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  TRANSIENT (immediate) execution — attemptApplyImmediate during the post.
    //  Same entry (1 L2ToL1Call + 1 ExpectedL1ToL2Call) loaded into the transient table:
    //   - proxyEntryHash == 0  -> runs inline (executed)
    //   - proxyEntryHash != 0  -> loaded + cleared, NOT run
    //  Both batches load+clear the same transient entry, so the delta is the pure inline
    //  execution cost via the transient path (no persistent queue write).
    // ══════════════════════════════════════════════════════════════════════════

    function _postImmediate(bool execute) internal {
        bytes32 newA = keccak256(abi.encodePacked(_getRollupState(rA.id), uint8(0xA)));
        bytes32 newB = keccak256(abi.encodePacked(_getRollupState(rB.id), uint8(0xB)));
        bytes32 peh = execute ? bytes32(0) : keccak256("not-immediate");
        RollupUpdate[] memory deltas = _twoDeltas(newA, newB);
        L2ToL1Call[] memory calls = _calls(_reentrantCall());
        (bytes32 h, ExpectedL1ToL2Call[] memory exp) = _foldExec(_hEntryBegin(deltas, peh), calls, _rets(""), true);
        ExecutionEntry memory e = _entry(deltas, peh, calls, exp, "", h);
        // The !execute case leaves an unexecuted transient prefix, so the poster must implement
        // the meta hook (`MetaEntriesWithoutReceiver`); the no-op receiver loads it and returns.
        vm.prank(execute ? alice : address(noopMetaReceiver));
        _postBatchTwoT(rA.id, rB.id, _one(e), 1); // immediateEntryCount = 1
    }

    function test_Transient_ImmediateExecCost() public {
        // WITH inline execution (proxyEntryHash == 0)
        _postImmediate(true); // warm-up
        vm.roll(block.number + 1);
        _coolForExec();
        uint256 g1 = gasleft();
        _postImmediate(true);
        uint256 withExec = g1 - gasleft();

        // WITHOUT inline execution (entry loaded transiently but not run)
        vm.roll(block.number + 1);
        _postImmediate(false); // warm-up
        vm.roll(block.number + 1);
        _coolForExec();
        uint256 g2 = gasleft();
        _postImmediate(false);
        uint256 withoutExec = g2 - gasleft();

        console.log("transient_batch_with_exec   ", withExec);
        console.log("transient_batch_without_exec", withoutExec);
        // The !execute baseline pays the transient load (SSTORE pushes + hook) the execute case
        // skips, so the delta can be negative.
        if (withExec >= withoutExec) {
            console.log("  immediate execution cost  ", withExec - withoutExec);
        } else {
            console.log("  immediate execution cost  -", withoutExec - withExec);
        }
    }

    // Same-rollup (1 RollupUpdate) reentrant entry loaded into the transient table; proxyEntryHash==0
    // → executed inline. Posted as an EOA (no meta-hook).
    function _postImmediateA() internal {
        bytes32 newA = keccak256(abi.encodePacked(_getRollupState(rA.id), uint8(0xA)));
        RollupUpdate[] memory deltas = _oneDelta(newA);
        L2ToL1Call[] memory calls = _calls(_reentrantCallA());
        (bytes32 h, ExpectedL1ToL2Call[] memory exp) =
            _foldExec(_hEntryBegin(deltas, bytes32(0)), calls, _rets(""), true);
        ExecutionEntry memory e = _entry(deltas, bytes32(0), calls, exp, "", h);
        vm.prank(alice);
        _postBatchTwoT(rA.id, rB.id, _one(e), 1);
    }

    // Full end-to-end cost of getting one entry executed, subsequent (steady) where applicable.
    //   Transient: ONE postBatch tx that loads + executes the entry inline.
    //   Storage:   a postBatch tx that saves the entry (steady) + a separate user tx to execute it.
    // postBatch execution is measured by gasleft(); each transaction additionally pays the 21k base
    // (added in the report). Storage is two transactions, so it pays the base twice.
    function test_FullCost_StorageVsTransient() public {
        _emptyBatch(); // warm-up
        vm.roll(block.number + 1);
        _coolForExec();
        uint256 gb = gasleft();
        _emptyBatch();
        uint256 base = gb - gasleft();

        _postImmediateA(); // warm-up
        vm.roll(block.number + 1);
        _coolForExec();
        uint256 gt = gasleft();
        _postImmediateA();
        uint256 transientFull = gt - gasleft();

        console.log("full_postbatch_base          ", base);
        console.log("full_transient_load_exec_post", transientFull);
    }

    // Empty batch (verify proofs + mark rollups, no entries) — the baseline to subtract so the
    // numbers below are the MARGINAL cost of handling one entry, all inside one post tx (no 21k base).
    function _emptyBatch() internal {
        vm.prank(alice);
        _postBatchTwoT(rA.id, rB.id, new ExecutionEntry[](0), 0);
    }

    // Save one entry to the PERSISTENT queue (deferred, immediateCount=0) — never executed here.
    function _saveDeferred() internal {
        bytes32 newA = keccak256(abi.encodePacked(_getRollupState(rA.id), uint8(0xA)));
        bytes32 newB = keccak256(abi.encodePacked(_getRollupState(rB.id), uint8(0xB)));
        ExecutionEntry memory e = _entry(
            _twoDeltas(newA, newB),
            keccak256("deferred-save"),
            _calls(_reentrantCall()),
            _reentrantExpected(),
            "",
            bytes32(0)
        );
        vm.prank(alice);
        _postBatchTwoT(rA.id, rB.id, _one(e), 0);
    }

    // Fair comparison of two ways to handle ONE entry (1 L2ToL1Call + 1 ExpectedL1ToL2Call), each
    // measured as the marginal cost within a single postAndVerifyBatch tx (no separate-tx 21k base):
    //   - STORAGE: save it to the persistent queue (it lives on, to be executed later)
    //   - TRANSIENT: load it to the transient table and execute it inline, never persisting it
    function test_StorageVsTransient_HandleEntry() public {
        _emptyBatch(); // warm-up
        vm.roll(block.number + 1);
        _coolForExec();
        uint256 gb = gasleft();
        _emptyBatch();
        uint256 baseline = gb - gasleft();

        _saveDeferred(); // warm-up
        vm.roll(block.number + 1);
        _coolForExec();
        uint256 gs = gasleft();
        _saveDeferred();
        uint256 storageSave = gs - gasleft();

        _postImmediate(true); // warm-up
        vm.roll(block.number + 1);
        _coolForExec();
        uint256 gt = gasleft();
        _postImmediate(true);
        uint256 transientExec = gt - gasleft();

        console.log("storage_save_entry      ", storageSave - baseline);
        console.log("transient_load_execute  ", transientExec - baseline);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  DOC: vm.roll only bumps block.number — it does NOT reset warm/cold access
    //  state. So after a warm-up post + vm.roll the slots stay WARM; only vm.cool
    //  colds them. This is why the measurements cool explicitly.
    // ══════════════════════════════════════════════════════════════════════════

    // Probe: `vm.cool` models a FULL transaction boundary for the account — it colds access
    // AND adopts the CURRENT storage values as the originals, as if they had been committed.
    // So an in-test warm-up + cool prices exactly like state seeded in setUp, and zero-init
    // pricing (SSTORE_SET) appears only when the slots' current values are actually zero.
    // This is what lets every measurement here use in-test warm-ups as its steady state.
    function test_Doc_CoolIsTxBoundary() public {
        // COMMITTED: `seeded` had a.fill(2) run in setUp. All three measured calls below go
        // through a stack variable so the call sites are identical.
        ArrayStore committedStore = seeded;
        committedStore.fill(2); // warm up current values inside this tx
        vm.cool(address(committedStore));
        uint256 g = gasleft();
        committedStore.fill(2); // delete + re-push over non-zero slots
        uint256 committedSteady = g - gasleft();

        // IN-TEST: deployed and filled inside this tx, then cooled → must price like COMMITTED.
        ArrayStore inTest = new ArrayStore();
        inTest.fill(2);
        vm.cool(address(inTest));
        g = gasleft();
        inTest.fill(2);
        uint256 inTestSteady = g - gasleft();

        // ZERO-INIT: deployed, cooled, then filled for the FIRST time — slots genuinely zero,
        // so each push pays SSTORE_SET (20k).
        ArrayStore virgin = new ArrayStore();
        vm.cool(address(virgin));
        g = gasleft();
        virgin.fill(2);
        uint256 zeroInit = g - gasleft();

        console.log("array_fill2_committed_steady", committedSteady);
        console.log("array_fill2_intest_steady   ", inTestSteady);
        console.log("array_fill2_zero_init       ", zeroInit);
        assertApproxEqAbs(inTestSteady, committedSteady, 500, "cool must price in-test state like committed state");
        assertLt(committedSteady, zeroInit, "zero-init (SSTORE_SET) must cost more than a steady rewrite");
    }

    // Proves the incremental steady numbers are genuinely steady: rS was seeded FULL in setUp
    // (call+expected slots non-zero originals) → posting a full entry is dirty-cheap; rS2 was
    // seeded BARE (call+expected zero) → posting a full entry pays SSTORE_SET on those slots.
    function test_Doc_SeedShapeMatters() public {
        // rS: bring queue to 1 full entry (prev block), then measure a full-entry post.
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS.id, _savedFor(rS.id, 1, 1, 1));
        vm.roll(block.number + 1);
        _coolProtocol();
        vm.cool(address(rS.manager));
        uint256 gA = gasleft();
        _postBatchTwo(rB.id, rS.id, _savedFor(rS.id, 1, 1, 1));
        uint256 seededFull = gA - gasleft();

        // rS2: same, but its call+expected slots were never seeded → zero originals.
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS2.id, _savedFor(rS2.id, 1, 1, 1));
        vm.roll(block.number + 1);
        _coolProtocol();
        vm.cool(address(rS2.manager));
        uint256 gB = gasleft();
        _postBatchTwo(rB.id, rS2.id, _savedFor(rS2.id, 1, 1, 1));
        uint256 seededBare = gB - gasleft();

        console.log("full_entry_post_seeded_full", seededFull);
        console.log("full_entry_post_seeded_bare", seededBare);
        console.log("  zero-init premium on call+expected", seededBare - seededFull);
        assertLt(seededFull, seededBare, "full-shape seed must make call+expected non-zero originals");
    }

    function test_Doc_RollDoesNotCoolStorage() public {
        _getRollupState(rA.id); // warm the rollups account + the rollup-config slot

        // Cold baseline: cool, then measure one read (cold account + cold slot).
        vm.cool(address(rollups));
        uint256 g0 = gasleft();
        _getRollupState(rA.id);
        uint256 coldRead = g0 - gasleft();

        // Now warm again. Bump the block and measure WITHOUT cooling.
        vm.roll(block.number + 1);
        uint256 g1 = gasleft();
        _getRollupState(rA.id);
        uint256 afterRollRead = g1 - gasleft();

        console.log("read_cold_after_cool", coldRead);
        console.log("read_after_vm_roll  ", afterRollRead);
        console.log("  warmth saved       ", coldRead - afterRollRead);
        // vm.roll left the slot WARM: the post-roll read is much cheaper than the cold read.
        assertLt(afterRollRead, coldRead, "vm.roll must NOT cold storage");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  POSTING COST — steady-state (rS queue seeded in setUp → non-zero originals)
    //  vs first-init (rA queue, zero originals). The gap is the SSTORE_SET premium
    //  the queue's delete+push pays on a never-before-written queue.
    // ══════════════════════════════════════════════════════════════════════════

    function test_PostCost_SteadyState() public {
        // 2-entry steady: rS queue holds 2 (seeded in setUp) → delete 2 + push 2 over non-zero originals.
        vm.roll(block.number + 1);
        _coolProtocol();
        vm.cool(address(rS.manager));
        uint256 g2 = gasleft();
        _postBatchTwo(rB.id, rS.id, _savedFor(rS.id, 2, 1, 1));
        uint256 steady2 = g2 - gasleft();

        // 1-entry steady: first bring the queue down to 1, then measure delete 1 + push 1.
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS.id, _savedFor(rS.id, 1, 1, 1)); // queue -> 1
        vm.roll(block.number + 1);
        _coolProtocol();
        vm.cool(address(rS.manager));
        uint256 g1 = gasleft();
        _postBatchTwo(rB.id, rS.id, _savedFor(rS.id, 1, 1, 1));
        uint256 steady1 = g1 - gasleft();

        console.log("postBatch_1entry_steady  ", steady1);
        console.log("postBatch_2entries_steady", steady2);
        console.log("  steady delta per entry ", steady2 - steady1);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  POSTING COST — marginal cost of one extra RollupUpdate (a posted entry touching
    //  one more rollup). Full-shape steady post with 1 vs 2 RollupUpdates, each on a
    //  rollup seeded with the matching shape so both are steady (non-zero originals).
    // ══════════════════════════════════════════════════════════════════════════

    function test_PostCost_PerRollupUpdate() public {
        // 1 RollupUpdate (rS seeded 1-delta full)
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS.id, _savedFor(rS.id, 1, 1, 1)); // prior block
        vm.roll(block.number + 1);
        _coolProtocol();
        vm.cool(address(rS.manager));
        uint256 g1 = gasleft();
        _postBatchTwo(rB.id, rS.id, _savedFor(rS.id, 1, 1, 1));
        uint256 oneDelta = g1 - gasleft();

        // 2 RollupUpdates (rS3 seeded 2-delta full)
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS3.id, _one(_steadyShaped2(rS3.id))); // prior block
        vm.roll(block.number + 1);
        _coolProtocol();
        vm.cool(address(rS3.manager));
        uint256 g2 = gasleft();
        _postBatchTwo(rB.id, rS3.id, _one(_steadyShaped2(rS3.id)));
        uint256 twoDelta = g2 - gasleft();

        console.log("post_1statedelta_steady", oneDelta);
        console.log("post_2statedelta_steady", twoDelta);
        console.log("  +1 RollupUpdate (steady)", twoDelta - oneDelta);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  POSTING COST — incremental entry shape, STEADY-STATE (non-zero originals)
    //  Each measured post: the queue already holds one same-shape entry from the
    //  prior block, so it is delete+push over non-zero slots (subsequent, not first).
    // ══════════════════════════════════════════════════════════════════════════

    function test_PostCost_IncrementalSteady() public {
        // bare entry
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS.id, _savedFor(rS.id, 1, 0, 0)); // prior block = bare
        vm.roll(block.number + 1);
        uint256 p0 = _measurePostSteadyShape(0, 0);

        // + 1 L2ToL1Call
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS.id, _savedFor(rS.id, 1, 1, 0));
        vm.roll(block.number + 1);
        uint256 p1 = _measurePostSteadyShape(1, 0);

        // + 1 ExpectedL1ToL2Call
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS.id, _savedFor(rS.id, 1, 1, 1));
        vm.roll(block.number + 1);
        uint256 p2 = _measurePostSteadyShape(1, 1);

        console.log("post_bare_steady           ", p0);
        console.log("post_1call_steady          ", p1);
        console.log("post_1call_1expected_steady", p2);
        console.log("  delta +1 L2ToL1Call steady ", p1 - p0);
        console.log("  delta +1 ExpectedL1ToL2 steady", p2 - p1);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  POSTING COST — first batch (zero-init storage) vs steady-state (non-zero)
    //  Both measured access-cold; the gap is the zero->non-zero SSTORE init premium
    //  that we exclude by always reporting the second (steady-state) post.
    // ══════════════════════════════════════════════════════════════════════════

    function test_PostCost_FirstVsSteady() public {
        ExecutionEntry[] memory e = new ExecutionEntry[](1);
        e[0] = _entry(
            _twoDeltas("a", "b"), keccak256("deferred"), _calls(_reentrantCall()), _reentrantExpected(), "", bytes32(0)
        );

        uint256 first = _measurePost(e); // first ever post — slots zero-initialized
        vm.roll(block.number + 1);
        uint256 steady = _measurePost(e); // second post — slots already non-zero

        console.log("postBatch_first_uncounted ", first);
        console.log("postBatch_steady_counted  ", steady);
        console.log("  first - steady          ", first - steady);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  EXECUTION COST — warm slots (post in same tx) vs cold slots (realistic)
    //  Quantifies how much the entry/queue SLOADs cost when the post and the user
    //  execution are SEPARATE transactions (cold) vs warmed by the post (warm).
    // ══════════════════════════════════════════════════════════════════════════

    function test_ExecCost_WarmVsCold() public {
        // Warm-up cycle: deploys the source proxies (CREATE2) and brings every slot to its
        // steady-state non-zero VALUE, so the two measurements below differ ONLY by access warmth.
        _postEntryN(2, _calls(_reentrantCall()), _rets(""), true);
        vm.prank(alice);
        (bool ok0,) = triggerProxy.call("");
        require(ok0, "warm-up exec failed");
        vm.roll(block.number + 1);

        // WARM: post then execute in the same context — entry slots warm from the post.
        _postEntryN(2, _calls(_reentrantCall()), _rets(""), true);
        uint256 g1 = gasleft();
        vm.prank(alice);
        (bool ok1,) = triggerProxy.call("");
        uint256 gWarm = g1 - gasleft();
        require(ok1, "warm exec failed");

        // COLD: post, cool every touched slot (fresh-tx model), then execute.
        vm.roll(block.number + 1);
        _postEntryN(2, _calls(_reentrantCall()), _rets(""), true);
        _coolForExec();
        uint256 g2 = gasleft();
        vm.prank(alice);
        (bool ok2,) = triggerProxy.call("");
        uint256 gCold = g2 - gasleft();
        require(ok2, "cold exec failed");

        console.log("exec_warm_slots", gWarm);
        console.log("exec_cold_slots", gCold);
        console.log("  cold - warm  ", gCold - gWarm);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  IntegrationTest scenario flows — measure ONLY alice's L1 transaction
    //  (the L2 phase of those tests is ignored; the counterparty is rollup rB/rA).
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Scenario 1: alice -> A(CounterAndProxy) -> B'(proxy) -> resolved.
    ///         Simple deferred entry, no sub-calls, returns the precomputed value.
    function test_ExecCost_Scenario1_L1() public {
        _scenario1Post(); // warm-up post (block N)
        vm.prank(alice);
        s1A.incrementProxy(); // consume warm-up entry

        vm.roll(block.number + 1);
        _scenario1Post(); // measured cycle (block N+1)
        _coolProtocol();
        vm.cool(s1ProxyB); // s1A is alice's tx.to → stays warm
        uint256 g = gasleft();
        vm.prank(alice);
        s1A.incrementProxy();
        g = g - gasleft();

        assertEq(s1A.targetCounter(), 1, "scenario1 resolved");
        console.log("exec_scenario1_alice_tx", g);
    }

    function _scenario1Post() internal {
        bytes32 ph = _ccHash(NOT_STATIC_CALL, address(s1A), MAINNET_ROLLUP_ID, s1B, uint64(rB.id), 0, incrementCalldata);
        bytes32 newB = keccak256(abi.encodePacked(_getRollupState(rB.id), uint8(0x1)));

        RollupUpdate[] memory d = new RollupUpdate[](1);
        d[0] =
            RollupUpdate({rollupId: uint64(rB.id), currentRoot: _getRollupState(rB.id), newRoot: newB, etherDelta: 0});

        ExecutionEntry[] memory e = new ExecutionEntry[](1);
        e[0].rollupUpdates = d;
        e[0].proxyEntryHash = ph;
        e[0].destinationRollupId = uint64(rB.id);
        e[0].rollingHash = _hEntryBegin(d, ph);
        e[0].success = true;
        e[0].returnData = abi.encode(uint256(1));
        // l2ToL1Calls / expectedL1ToL2Calls empty

        _postBatchOne(rB, e, _emptyStaticEntries(), 0, 0);
    }

    /// @notice Scenario 3 realized on L1 (mirror of scenario 4): alice -> D'(proxy) consumes an
    ///         entry whose single sub-call runs D.incrementProxy(), and D calls C'(proxy) which
    ///         re-enters EEZ for rA — matched against the entry's one ExpectedL1ToL2Call.
    function test_ExecCost_Scenario3_L1() public {
        _scenario4Post(); // warm-up (block N)
        vm.prank(alice);
        (bool ok0,) = s4ProxyD.call(incrementProxyCalldata);
        require(ok0, "s3 warm-up failed");

        vm.roll(block.number + 1);
        _scenario4Post(); // measured (block N+1)
        _coolProtocol();
        vm.cool(address(s4D));
        vm.cool(s4ProxyC);
        vm.cool(rollups.computeCrossChainProxyAddress(alice, uint64(rB.id))); // (alice, rB) source proxy
        // s4ProxyD is alice's tx.to → stays warm
        uint256 g = gasleft();
        vm.prank(alice);
        (bool ok,) = s4ProxyD.call(incrementProxyCalldata);
        g = g - gasleft();
        require(ok, "s3 exec failed");

        assertEq(s4D.targetCounter(), 1, "scenario3 nested resolved");
        console.log("exec_scenario3_alice_tx", g);
    }

    function _scenario4Post() internal {
        bytes32 ph =
            _ccHash(NOT_STATIC_CALL, alice, MAINNET_ROLLUP_ID, address(s4D), uint64(rB.id), 0, incrementProxyCalldata);
        bytes32 nestedHash =
            _ccHash(NOT_STATIC_CALL, address(s4D), MAINNET_ROLLUP_ID, s4C, uint64(rA.id), 0, incrementCalldata);

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: alice,
            sourceRollupId: uint64(rB.id),
            targetAddress: address(s4D),
            value: 0,
            data: incrementProxyCalldata
        });

        bytes32 newA = keccak256(abi.encodePacked(_getRollupState(rA.id), uint8(0xA)));
        bytes32 newB = keccak256(abi.encodePacked(_getRollupState(rB.id), uint8(0xB)));
        RollupUpdate[] memory deltas = _twoDeltas(newA, newB);

        // Top-level call's identity (target s4D on L1 = MAINNET, source alice on rB).
        bytes32 cchTop =
            _ccHash(NOT_STATIC_CALL, alice, uint64(rB.id), address(s4D), MAINNET_ROLLUP_ID, 0, incrementProxyCalldata);
        bytes32 h = _hEntryBegin(deltas, ph);
        h = _hCallBegin(h, cchTop);
        bytes32 fireHash = h; // reentrant fires here, right after the top call's CALL_BEGIN
        h = _hNestedBegin(h, nestedHash);
        h = _hNestedEnd(h);
        h = _hCallEnd(h, true, ""); // incrementProxy() returns void

        ExpectedL1ToL2Call[] memory exp = new ExpectedL1ToL2Call[](1);
        exp[0] = ExpectedL1ToL2Call({
            expectedL1toL2Hash: _expectedL1toL2Hash(nestedHash, fireHash),
            l2ToL1Calls: new L2ToL1Call[](0),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });

        ExecutionEntry[] memory e = new ExecutionEntry[](1);
        e[0].rollupUpdates = deltas;
        e[0].proxyEntryHash = ph;
        e[0].destinationRollupId = uint64(rB.id);
        e[0].l2ToL1Calls = calls;
        e[0].expectedL1ToL2Calls = exp;
        e[0].rollingHash = h;
        e[0].success = true;

        _postTwoRollups(e);
    }
}
