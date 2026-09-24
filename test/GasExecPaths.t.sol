// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {GasMeter} from "./helpers/GasMeter.sol";
import {GasFixture} from "./GasFixture.t.sol";
import {
    EEZ,
    ProofSystemBatchPerVerificationEntries,
    ExpectedRootPerRollup,
    RollupIdWithProofSystems
} from "../src/EEZ.sol";
import {ExecutionEntry, RollupUpdate, L2ToL1Call, ExpectedL1ToL2Call} from "../src/interfaces/IEEZ.sol";
import {IMetaCrossChainReceiver} from "../src/interfaces/IMetaCrossChainReceiver.sol";

/// @notice A contract poster that drives the meta-hook. Implements IMetaCrossChainReceiver so that,
///         when it posts a batch carrying an immediate (transient) entry it does NOT execute inline,
///         the EEZ calls it back inside the same tx; in the callback it consumes that transient entry
///         by calling the cross-chain proxy.
contract MetaExecDriver is IMetaCrossChainReceiver {
    EEZ public immutable eez;
    address public proxyAddr;
    bytes public proxyCallData;

    constructor(EEZ _eez) {
        eez = _eez;
    }

    function configure(address _proxy, bytes calldata _cd) external {
        proxyAddr = _proxy;
        proxyCallData = _cd;
    }

    function post(ProofSystemBatchPerVerificationEntries calldata batch) external {
        eez.postAndVerifyBatch(batch);
    }

    function executeMetaCrossChainTransactions() external override {
        (bool ok,) = proxyAddr.call(proxyCallData);
        require(ok, "meta proxy call reverted");
    }
}

/// @notice Posts two batches back-to-back inside ONE transaction, so the second runs against whatever
///         the first left behind in transient storage.
contract DoublePoster {
    EEZ public immutable eez;

    constructor(EEZ _eez) {
        eez = _eez;
    }

    function postTwice(
        ProofSystemBatchPerVerificationEntries calldata a,
        ProofSystemBatchPerVerificationEntries calldata b
    )
        external
    {
        eez.postAndVerifyBatch(a);
        eez.postAndVerifyBatch(b);
    }
}

/// @title GasExecPaths
/// @notice Callee-body gas for the FOUR ways one proven entry can be executed. Every path uses
///         the EXACT same entry shape — a same-rollup reentrant entry on rA: 1 RollupUpdate, 1 flat
///         L2ToL1Call that re-enters EEZ once, 1 ExpectedL1ToL2Call — so the only thing that varies is
///         the consumption path. All marginal post costs subtract an empty-batch baseline (proofs
///         verified + rollups marked, no entry), so they isolate "handle this one entry".
///
///         The four paths (see EEZ.postAndVerifyBatch):
///           1. IMMEDIATE L2Tx       — proxyEntryHash == 0, run INLINE during the post itself
///                                      (`_attemptExecuteImmediateL2Txs`). One tx, never persisted.
///           2. META-HOOK transient  — proxyEntryHash != 0, loaded into the transient table and driven
///                                      by the poster's `executeMetaCrossChainTransactions()` callback.
///                                      One tx, never persisted.
///           3. SAVE + executeL2Txs  — proxyEntryHash == 0 SAVED to the persistent queue, then a SEPARATE
///                                      permissionless `executeL2Txs(rid)` tx consumes it later.
///           4. SAVE + proxy call    — proxyEntryHash != 0 SAVED to the queue, then a SEPARATE user tx
///                                      (call the cross-chain proxy) consumes it later.
///
///         Paths 1-2 are ONE transaction (post). Paths 3-4 are TWO transactions (save, then execute);
///         each separate tx additionally pays the 21,000 intrinsic base not counted by `gasleft()` —
///         noted in the printout. Reported numbers are the SECOND (warm) run; the first pays one-time
///         cold-slot init. Inputs are built before cooling; vm.lastCallGas excludes fixture construction.
///         Deferred L2Txs also need a preceding boundary entry: subtract its posting cost, but keep
///         its scan overhead in execution. Run with: forge test --match-path test/GasExecPaths.t.sol -vv
contract GasExecPaths is GasFixture {
    MetaExecDriver internal driver;

    // Rollups whose queues are SEEDED in setUp with the exact shape each saved measurement re-writes.
    // Seeding in setUp (a committed prior context) makes the queue slots non-zero ORIGINALS, so the
    // measured re-post pays the STEADY re-write cost — "some entries were already there" — instead of
    // one-time zero-init. Access warmth is reset separately before each measured call.
    RollupHandle internal gBare1; // 1 bare entry
    RollupHandle internal gBare2; // 2 bare entries
    RollupHandle internal g1Call; // 1 entry, 1 L2ToL1Call
    RollupHandle internal g1Exp; //  1 entry, 1 ExpectedL1ToL2Call

    function setUp() public override {
        super.setUp(); // shared gas fixture (rA, rB, proxies, actors, seeded rS*)

        gBare1 = _makeRollup(keccak256("gBare1"));
        gBare2 = _makeRollup(keccak256("gBare2"));
        g1Call = _makeRollup(keccak256("g1Call"));
        g1Exp = _makeRollup(keccak256("g1Exp"));

        _seedQueue(gBare1, _savedFor(gBare1.id, 1, 0, 0));
        _seedQueue(gBare2, _savedFor(gBare2.id, 2, 0, 0));
        _seedQueue(g1Call, _savedFor(g1Call.id, 1, 1, 0));
        _seedQueue(g1Exp, _savedFor(g1Exp.id, 1, 0, 1));
    }

    /// Posts `entries` deferred to `r`'s queue (attesting rB + r), committing the slots in setUp.
    function _seedQueue(RollupHandle memory r, ExecutionEntry[] memory entries) internal {
        _postBatchTwo(rB.id, r.id, entries);
    }

    function _initDriver() internal {
        if (address(driver) == address(0)) {
            driver = new MetaExecDriver(rollups);
            // The driver consumes the transient entry by calling triggerProxy with empty calldata,
            // exactly like a user would (source = driver, target = triggerTarget on rA).
            driver.configure(triggerProxy, "");
        }
    }

    // ──────────────────────────────────────────────
    //  Entry + batch builders (shared shape)
    // ──────────────────────────────────────────────

    /// @notice The shared entry: a same-rollup reentrant entry routed to rA whose consuming proxy call
    ///         is identified by `proxyEntryHash`. `proxyEntryHash == 0` makes it an L2Tx entry.
    function _sharedEntry(bytes32 proxyEntryHash) internal view returns (ExecutionEntry memory e) {
        bytes32 newA = keccak256(abi.encodePacked(_getRollupState(rA.id), uint8(0xA)));
        RollupUpdate[] memory deltas = _oneDelta(newA);
        L2ToL1Call[] memory calls = _calls(_reentrantCallA());
        (bytes32 h, ExpectedL1ToL2Call[] memory exp) =
            _foldExec(_hEntryBegin(deltas, proxyEntryHash), calls, _rets(""), true);
        e = _entry(deltas, proxyEntryHash, calls, exp, "", h);
    }

    /// @notice Trigger hash for a proxy consumption: `caller` calls triggerProxy("") → source = caller,
    ///         target = triggerTarget on rA. This is what `proxyEntryHash` must equal for paths 2 and 4.
    function _proxyEntryHashFrom(address caller) internal view returns (bytes32) {
        return _ccHash(NOT_STATIC_CALL, caller, MAINNET_ROLLUP_ID, triggerTarget, uint64(rA.id), 0, "");
    }

    /// @notice Builds a two-rollup (rA, rB) batch around `entries` with an explicit immediateEntryCount.
    ///         Mirrors GasFixture._postBatchTwoT but RETURNS the struct so any poster (EOA prank or the
    ///         driver contract) can submit it.
    function _buildBatch(
        ExecutionEntry[] memory entries,
        uint256 immediateCount
    )
        internal
        view
        returns (ProofSystemBatchPerVerificationEntries memory batch)
    {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](1);
        psIdx[0] = 0;

        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](2);
        rps[0] = RollupIdWithProofSystems({rollupId: uint64(rA.id), proofSystemIndexes: psIdx});
        rps[1] = RollupIdWithProofSystems({rollupId: uint64(rB.id), proofSystemIndexes: psIdx});

        batch = ProofSystemBatchPerVerificationEntries({
            expectedRootPerRollup: new ExpectedRootPerRollup[](0),
            blockNumber: 0,
            bindMsgSenderInPublicInput: false,
            entries: entries,
            staticEntries: _emptyStaticEntries(),
            immediateEntryCount: immediateCount,
            immediateStaticEntryCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
    }

    // ──────────────────────────────────────────────
    //  Per-path single-shot drivers (one full operation each)
    // ──────────────────────────────────────────────

    /// PATH 1 — post a batch whose single immediate entry (proxyEntryHash == 0) runs INLINE. EOA poster,
    ///          so the meta-hook never fires (the entry is fully consumed by the inline L2Tx run).
    function _runImmediateL2Tx() internal {
        ExecutionEntry[] memory entries = _one(_sharedEntry(bytes32(0)));
        ProofSystemBatchPerVerificationEntries memory batch = _buildBatch(entries, 1);
        vm.prank(alice);
        rollups.postAndVerifyBatch(batch);
    }

    /// PATH 2 — the driver posts a batch whose single immediate entry (proxyEntryHash != 0) is loaded
    ///          transiently and consumed inside the driver's meta-hook callback.
    function _runMetaHook() internal {
        ExecutionEntry[] memory entries = _one(_sharedEntry(_proxyEntryHashFrom(address(driver))));
        ProofSystemBatchPerVerificationEntries memory batch = _buildBatch(entries, 1);
        driver.post(batch);
    }

    /// PATH 3a / 4a — SAVE the entry to the persistent queue (immediateCount = 0, deferred). `peh == 0`
    ///                makes it an executeL2Txs target; a real hash makes it a proxy target.
    /// @dev A deferred L2Tx (`peh == 0`) can't sit at the queue head — `ImmediateCountStrandsLeadingL2Tx`
    ///      guards the boundary slot. Park it behind a non-L2Tx boundary entry so executeL2Txs reaches
    ///      it by scanning. The proxy-target case (`peh != 0`) is itself a valid boundary entry.
    function _savedBatch(bytes32 proxyEntryHash) internal view returns (ProofSystemBatchPerVerificationEntries memory) {
        ExecutionEntry[] memory entries;
        if (proxyEntryHash == bytes32(0)) {
            entries = new ExecutionEntry[](2);
            entries[0] = _sharedEntry(_proxyEntryHashFrom(address(driver))); // non-L2Tx boundary
            entries[1] = _sharedEntry(bytes32(0)); // the deferred L2Tx
        } else {
            entries = _one(_sharedEntry(proxyEntryHash));
        }
        return _buildBatch(entries, 0);
    }

    function _runSave(bytes32 proxyEntryHash) internal {
        ProofSystemBatchPerVerificationEntries memory batch = _savedBatch(proxyEntryHash);
        vm.prank(alice);
        rollups.postAndVerifyBatch(batch);
    }

    /// Empty batch (proofs + mark rollups, no entry) — the baseline subtracted from post costs.
    function _runEmpty(bool viaDriver) internal {
        ProofSystemBatchPerVerificationEntries memory batch = _buildBatch(new ExecutionEntry[](0), 0);
        if (viaDriver) {
            driver.post(batch);
        } else {
            vm.prank(alice);
            rollups.postAndVerifyBatch(batch);
        }
    }

    // ──────────────────────────────────────────────
    //  THE comparison
    // ──────────────────────────────────────────────

    function test_ExecPaths_Compare() public {
        _initDriver();

        // ---- Baselines: empty-batch post cost (EOA poster and driver poster). The driver adds one
        //      constant CALL layer (driver.post -> EEZ), present in path-2's full number too, so the
        //      driver baseline is the right thing to subtract from path 2.
        uint256 baseEoa = _measureEmpty(false);
        uint256 baseDriver = _measureEmpty(true);

        // ---- PATH 1: immediate L2Tx, inline in the post.
        uint256 immediateMarginal = _measureImmediate() - baseEoa;

        // ---- PATH 2: meta-hook transient.
        uint256 metaHookMarginal = _measureMetaHook() - baseDriver;

        // ---- PATH 3: save (peh == 0) then executeL2Txs later.
        (uint256 saveL2Tx, uint256 execL2Tx) = _measureSaveThenExecL2Tx();

        // ---- PATH 4: save (peh != 0) then proxy call later.
        (uint256 saveProxy, uint256 execProxy) = _measureSaveThenExecProxy();

        console.log("base_post_2rollups_direct", baseEoa);
        console.log("base_post_2rollups_driver", baseDriver);
        console.log("== SINGLE-TX immediate paths (marginal post cost, one tx) ==");
        console.log("1_immediate_l2tx_inline   ", immediateMarginal);
        console.log("2_meta_hook_transient     ", metaHookMarginal);
        console.log("");
        console.log("== TWO-TX save-then-execute (intrinsic/calldata gas excluded) ==");
        console.log("3a_add_l2tx_after_boundary          ", saveL2Tx);
        console.log("3b_exec_l2tx_later        ", execL2Tx);
        console.log("   3_total_save+exec       ", saveL2Tx + execL2Tx);
        console.log("4a_save_for_proxy         ", saveProxy);
        console.log("4b_exec_proxy_later       ", execProxy);
        console.log("   4_total_save+exec       ", saveProxy + execProxy);
    }

    // ──────────────────────────────────────────────
    //  Measurement drivers (warm-up in block N, measure cooled in block N+1)
    // ──────────────────────────────────────────────

    function _measureEmpty(bool viaDriver) internal returns (uint256 gasUsed) {
        _runEmpty(viaDriver);
        ProofSystemBatchPerVerificationEntries memory batch = _buildBatch(new ExecutionEntry[](0), 0);
        vm.roll(block.number + 1);
        _coolAll();
        if (viaDriver) {
            return meter.measure(address(driver), alice, abi.encodeCall(MetaExecDriver.post, (batch)), false).gasUsed;
        }
        return meter.measure(address(rollups), alice, abi.encodeCall(EEZ.postAndVerifyBatch, (batch)), false).gasUsed;
    }

    function _measureImmediate() internal returns (uint256 gasUsed) {
        _runImmediateL2Tx();
        ProofSystemBatchPerVerificationEntries memory batch = _buildBatch(_one(_sharedEntry(bytes32(0))), 1);
        vm.roll(block.number + 1);
        _coolAll();
        return meter.measure(address(rollups), alice, abi.encodeCall(EEZ.postAndVerifyBatch, (batch)), false).gasUsed;
    }

    function _measureMetaHook() internal returns (uint256 gasUsed) {
        _runMetaHook();
        ProofSystemBatchPerVerificationEntries memory batch =
            _buildBatch(_one(_sharedEntry(_proxyEntryHashFrom(address(driver)))), 1);
        vm.roll(block.number + 1);
        _coolAll();
        return meter.measure(address(driver), alice, abi.encodeCall(MetaExecDriver.post, (batch)), false).gasUsed;
    }

    /// The L2Tx requires a preceding non-L2Tx boundary. Subtract a boundary-only post,
    /// so the saving delta describes adding the L2Tx; execution still scans over that boundary.
    function _measureSaveThenExecL2Tx() internal returns (uint256 saveMarginal, uint256 execGas) {
        ExecutionEntry[] memory boundary = _one(_sharedEntry(_proxyEntryHashFrom(address(driver))));
        uint256 base = _measurePostSteady(boundary, 0);
        _runSave(bytes32(0));
        ProofSystemBatchPerVerificationEntries memory batch = _savedBatch(bytes32(0));
        vm.roll(block.number + 1);
        _coolAll();
        saveMarginal = meter.measure(address(rollups), alice, abi.encodeCall(EEZ.postAndVerifyBatch, (batch)), false)
            .gasUsed - base;

        _coolAll();
        execGas =
        meter.measure(address(rollups), alice, abi.encodeCall(EEZ.executeL2Txs, (uint64(rA.id))), false).gasUsed;
    }

    /// Save one proxy entry, then measure its consumption with cold protocol storage.
    function _measureSaveThenExecProxy() internal returns (uint256 saveMarginal, uint256 execGas) {
        uint256 base = _measureEmpty(false);
        bytes32 peh = _proxyEntryHashFrom(alice);
        _runSave(peh);
        ProofSystemBatchPerVerificationEntries memory batch = _savedBatch(peh);
        vm.roll(block.number + 1);
        _coolAll();
        saveMarginal = meter.measure(address(rollups), alice, abi.encodeCall(EEZ.postAndVerifyBatch, (batch)), false)
            .gasUsed - base;

        _coolAll();
        execGas = meter.measure(triggerProxy, alice, "", false).gasUsed;
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  PER-UNIT MARGINAL COST — extra L2Tx entry, extra L2ToL1Call, extra L1ToL2Call
    //
    //  Measured two ways, both steady-state (warm-up posts the same shape first so the
    //  measured run re-writes NON-ZERO originals — "some entries were already there", the
    //  common case — and cold access is forced with vm.cool before the measured run):
    //    EXECUTED : entries run INLINE in the post (immediate L2Tx path, EOA poster)
    //    SAVED    : entries deferred to the persistent queue (never executed)
    //  Each per-unit number is a DELTA between two posts (N+1 vs N), so all fixed batch
    //  overhead cancels and only the marginal unit remains.
    // ══════════════════════════════════════════════════════════════════════════

    /// A no-op RollupUpdate on rA (currentRoot == newRoot): lets several same-rollup entries coexist
    /// in one batch without invalidating each other's pre-state, and keeps execution side-effect-free.
    function _noopDelta() internal view returns (RollupUpdate[] memory d) {
        bytes32 cur = _getRollupState(rA.id);
        d = new RollupUpdate[](1);
        d[0] = RollupUpdate({rollupId: uint64(rA.id), currentRoot: cur, newRoot: cur, etherDelta: 0});
    }

    /// One EXECUTED immediate L2Tx entry (proxyEntryHash == 0) with `nSink` plain L2ToL1Calls and
    /// `nReentrant` reentrant L1ToL2Calls (each re-enters EEZ for rA once).
    function _execEntry(uint256 nSink, uint256 nReentrant) internal view returns (ExecutionEntry memory e) {
        uint256 n = nSink + nReentrant;
        L2ToL1Call[] memory calls = new L2ToL1Call[](n);
        bool[] memory reentrant = new bool[](n);
        bytes[] memory rets = new bytes[](n);
        for (uint256 i = 0; i < nSink; i++) {
            calls[i] = _sinkCall();
            reentrant[i] = false;
            rets[i] = "";
        }
        for (uint256 i = 0; i < nReentrant; i++) {
            calls[nSink + i] = _reentrantCallA();
            reentrant[nSink + i] = true;
            rets[nSink + i] = "";
        }
        RollupUpdate[] memory d = _noopDelta();
        (bytes32 h, ExpectedL1ToL2Call[] memory exp) = _foldGeneric(_hEntryBegin(d, bytes32(0)), calls, reentrant, rets);
        e = _entry(d, bytes32(0), calls, exp, "", h);
    }

    /// `nEntries` identical bare EXECUTED L2Tx entries (no calls) — isolates the per-entry overhead.
    function _execBareEntries(uint256 nEntries) internal view returns (ExecutionEntry[] memory entries) {
        ExecutionEntry memory e = _execEntry(0, 0);
        entries = new ExecutionEntry[](nEntries);
        for (uint256 i = 0; i < nEntries; i++) {
            entries[i] = e;
        }
    }

    /// Steady-state SAVE measurement: post the same shape that was seeded into `r`'s queue in setUp, so
    /// the queue slots are non-zero originals (re-write discount). Cools protocol + r before measuring.
    function _measureSavedSteady(
        RollupHandle memory r,
        ExecutionEntry[] memory entries
    )
        internal
        returns (uint256 gasUsed)
    {
        ProofSystemBatchPerVerificationEntries memory batch =
            _twoRollupBatch(rB.id, r.id, entries, _emptyStaticEntries(), 0, 0);
        vm.roll(block.number + 1);
        _coolProtocol();
        vm.cool(address(r.manager));
        gasUsed = meter.measure(address(rollups), alice, abi.encodeCall(EEZ.postAndVerifyBatch, (batch)), false).gasUsed;
    }

    /// Cools every account a measured post/exec can touch (protocol + the reentrant scaffolding that
    /// _coolForExec misses: actorA / counterProxyA), so the measured run pays realistic cold access.
    function _coolAll() internal {
        _coolForExec();
        vm.cool(address(actorA));
        vm.cool(counterProxyA);
        if (address(driver) != address(0)) vm.cool(address(driver));
    }

    /// Steady-state post measurement: warm-up the SAME batch in block N (originals become non-zero),
    /// roll to N+1, cool all touched accounts, then measure the re-post over the non-zero originals.
    function _measurePostSteady(
        ExecutionEntry[] memory entries,
        uint256 immediateCount
    )
        internal
        returns (uint256 gasUsed)
    {
        ProofSystemBatchPerVerificationEntries memory batch = _buildBatch(entries, immediateCount);
        vm.prank(alice);
        rollups.postAndVerifyBatch(batch);
        vm.roll(block.number + 1);
        _coolAll();
        gasUsed = meter.measure(address(rollups), alice, abi.encodeCall(EEZ.postAndVerifyBatch, (batch)), false).gasUsed;
    }

    function test_PerUnit_ExecutedInline() public {
        // Per extra L2Tx: 2 bare immediate entries vs 1.
        uint256 e1 = _measurePostSteady(_execBareEntries(1), 1);
        uint256 e2 = _measurePostSteady(_execBareEntries(2), 2);

        // Per extra EXECUTED L2ToL1Call: 1 entry with 1 vs 2 sink calls.
        uint256 c1 = _measurePostSteady(_one(_execEntry(1, 0)), 1);
        uint256 c2 = _measurePostSteady(_one(_execEntry(2, 0)), 1);

        // Per extra EXECUTED L1ToL2Call (reentrant): 1 entry with 1 vs 2 reentrant calls.
        uint256 r1 = _measurePostSteady(_one(_execEntry(0, 1)), 1);
        uint256 r2 = _measurePostSteady(_one(_execEntry(0, 2)), 1);

        console.log("== EXECUTED INLINE (immediate L2Tx, steady-state) ==");
        console.log("immediate_1entry_bare      ", e1);
        console.log("immediate_2entry_bare      ", e2);
        console.log("  per_extra_L2Tx_entry      ", e2 - e1);
        console.log("exec_1_L2ToL1Call          ", c1);
        console.log("exec_2_L2ToL1Call          ", c2);
        console.log("  per_extra_L2ToL1Call      ", c2 - c1);
        console.log("exec_1_callback_roundtrip          ", r1);
        console.log("exec_2_callback_roundtrips          ", r2);
        console.log("  per_extra_callback_roundtrip      ", r2 - r1);
    }

    /// Posts one immediate batch whose single entry executes `nRe` reentrant L1ToL2Calls inline.
    function _postImmReentrant(uint256 nRe) internal {
        ExecutionEntry[] memory entries = _one(_execEntry(0, nRe));
        vm.prank(alice);
        rollups.postAndVerifyBatch(_buildBatch(entries, 1));
    }

    /// Immediate reentrant tables now use EIP-1153, so parking/clearing them earns no SSTORE refund.
    /// Report raw call refunds separately; a call-level number cannot determine a transaction receipt.
    function test_ImmediateReentrant_GrossGasAndRefunds() public {
        GasMeter.Sample memory one = _immediateReentrantGas(1);
        GasMeter.Sample memory two = _immediateReentrantGas(2);
        console.log("immediate_1roundtrip_body_gas", one.gasUsed);
        console.log("immediate_2roundtrips_body_gas", two.gasUsed);
        console.log("immediate_1roundtrip_raw_refund", int256(one.refund));
        console.log("immediate_2roundtrips_raw_refund", int256(two.refund));
        console.log("extra_roundtrip_body_gas", uint256(two.gasUsed) - one.gasUsed);
        assertEq(one.refund, 0, "transient reentrant table must not earn a storage refund");
        assertEq(two.refund, 0, "transient reentrant table must not earn a storage refund");
    }

    function _immediateReentrantGas(uint256 count) internal returns (GasMeter.Sample memory) {
        _postImmReentrant(count);
        ProofSystemBatchPerVerificationEntries memory batch = _buildBatch(_one(_execEntry(0, count)), 1);
        vm.roll(block.number + 1);
        _coolAll();
        return meter.measure(address(rollups), alice, abi.encodeCall(EEZ.postAndVerifyBatch, (batch)), false);
    }

    /// @dev Two batches in ONE tx. The first parks a 3-row reentrant table and clears it, which only
    ///      zeroes the length word — every row's data stays in its transient slots, and transient
    ///      storage outlives the call. The second must resolve against its OWN 1-row table: the length
    ///      has to be authoritative (rows 1-2 unreachable) and row 0 fully rewritten (not blended with
    ///      the row that occupied those slots).
    function test_Stale_TwoBatchesOneTx() public {
        DoublePoster poster = new DoublePoster(rollups);
        ProofSystemBatchPerVerificationEntries memory a = _buildBatch(_one(_execEntry(0, 3)), 1);
        ProofSystemBatchPerVerificationEntries memory b = _buildBatch(_one(_execEntry(0, 1)), 1);

        uint256 before = actorA.counter();
        poster.postTwice(a, b);

        // 3 reentrant calls from the first batch, 1 from the second — all resolved and executed.
        assertEq(actorA.counter(), before + 4, "every reentrant call ran");
    }

    function test_PerUnit_Saved() public {
        // Each destination was SEEDED in setUp with the SAME shape measured here → steady re-write.
        uint256 e1 = _measureSavedSteady(gBare1, _savedFor(gBare1.id, 1, 0, 0));
        uint256 e2 = _measureSavedSteady(gBare2, _savedFor(gBare2.id, 2, 0, 0));
        uint256 c0 = _measureSavedSteady(gBare1, _savedFor(gBare1.id, 1, 0, 0)); // bare = 0-call baseline
        uint256 c1 = _measureSavedSteady(g1Call, _savedFor(g1Call.id, 1, 1, 0));
        uint256 x1 = _measureSavedSteady(g1Exp, _savedFor(g1Exp.id, 1, 0, 1));

        console.log("== SAVED TO STORAGE (deferred, steady-state, originals seeded in setUp) ==");
        console.log("saved_1entry_bare          ", e1);
        console.log("saved_2entry_bare          ", e2);
        console.log("  per_extra_saved_entry     ", e2 - e1);
        console.log("saved_entry_0_L2ToL1Call   ", c0);
        console.log("saved_entry_1_L2ToL1Call   ", c1);
        console.log("  per_extra_saved_L2ToL1Call", c1 - c0);
        console.log("saved_entry_1_L1ToL2Call   ", x1);
        console.log("  per_extra_saved_L1ToL2Call", x1 - c0);
    }
}
