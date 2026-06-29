// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../src/EEZ.sol";
import {ExecutionEntry, StateDelta, L2ToL1Call, ExpectedL1ToL2Call} from "../src/interfaces/IEEZ.sol";
import {Counter, CounterAndProxy} from "./mocks/CounterContracts.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal ERC20 for measuring real transfer cost inside an entry.
contract GasTestToken is ERC20 {
    constructor() ERC20("Gas Test Token", "GTT") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @notice Permissive sink: accepts any calldata/value and returns empty. Used as the
///         target for the "uniswap" swap calldata and a generic baseline call — we only
///         care about the prepared calldata shape, not a real DEX.
contract Sink {
    fallback() external payable {}
}

/// @notice Tiny array-store contract to probe EIP-2200 original-value semantics
///         (delete + re-push of a dynamic array) under Foundry's tx model.
contract ArrayStore {
    uint256[] public a;

    function fill(uint256 n) external {
        delete a;
        for (uint256 i = 0; i < n; i++) {
            a.push(7);
        }
    }
}

/// @notice Just enough of the Uniswap V2 router ABI to encode realistic swap calldata.
interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        returns (uint256[] memory amounts);
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
///         Entry shape is held fixed at "touches 2 rollups (2 StateDeltas), one destination
///         rollup" so cases are comparable. Cases build up incrementally:
///           bare entry -> +1 L2ToL1Call -> +1 reentrant ExpectedL1ToL2Call
///           -> erc20 / uniswap directly -> erc20 + uniswap + reentrant combined.
contract GasCost is Base {
    RollupHandle internal rA; // destination rollup for every entry
    RollupHandle internal rB; // second touched rollup + reentrant target's rollup
    RollupHandle internal rS; // queue seeded FULL-shape in setUp → steady-state post measurements
    RollupHandle internal rS2; // queue seeded BARE in setUp → control: call/expected NOT pre-filled
    RollupHandle internal rS3; // queue seeded 2-StateDelta full in setUp → marginal per-StateDelta

    // L1 mainnet rollup id — the rollup an L1-executed call's target lives on, and the source
    // rollup of any reentrant L1→L2 call (EEZ forces it via `executeCrossChainCall`).
    uint64 internal constant MAINNET_ROLLUP_ID = 0;

    GasTestToken internal token;
    Sink internal sink;

    // Reentrant scaffolding: actor.incrementProxy() -> counterProxy.increment() re-enters EEZ.
    // counterProxy targets rB (cross-rollup reentry); counterProxyA targets rA (same-rollup reentry).
    Counter internal counterReal;
    address internal counterProxy;
    CounterAndProxy internal actor;
    address internal counterProxyA;
    CounterAndProxy internal actorA;

    // Proxies / identities
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal triggerTarget = makeAddr("triggerTarget");
    address internal triggerProxy; // (triggerTarget, rA) — user calls this to consume an entry
    address internal tokenHolder = makeAddr("tokenHolder");
    address internal tokenHolderProxy; // holds tokens; source of the erc20 transfer flat call
    address internal genericSource = makeAddr("genericSource"); // source of sink/uniswap calls
    address internal actorCaller = makeAddr("actorCaller"); // source proxy that calls actor

    // IntegrationTest scenario-1 graph (L1-only): alice -> A -> B' -> resolved
    address internal s1B = makeAddr("s1_remoteB"); // B lives on rB; never actually called
    address internal s1ProxyB; // L1 proxy for (B, rB)
    CounterAndProxy internal s1A; // A = CounterAndProxy(B')

    // IntegrationTest scenario-3 graph realized on L1 (mirror of scenario 4):
    //   alice -> D' -> D -> C' (C' re-enters EEZ for rA via an ExpectedL1ToL2Call)
    address internal s4C = makeAddr("s4_remoteC"); // C lives on rA; never actually called
    address internal s4ProxyC; // L1 proxy for (C, rA)
    CounterAndProxy internal s4D; // D = CounterAndProxy(C')
    address internal s4ProxyD; // L1 proxy for (D, rB) — alice's entry point

    uint256 internal constant AMT = 1e18;

    // Cached calldata
    bytes internal incrementCalldata; // Counter.increment()
    bytes internal incrementProxyCalldata; // CounterAndProxy.incrementProxy()
    bytes internal uniswapCalldata; // realistic swapExactTokensForTokens(...)

    function setUp() public {
        setUpBase();

        rA = _makeRollup(keccak256("rA-init")); // id 1
        rB = _makeRollup(keccak256("rB-init")); // id 2

        token = new GasTestToken();
        sink = new Sink();

        counterReal = new Counter();
        counterProxy = rollups.createCrossChainProxy(address(counterReal), uint64(rB.id));
        actor = new CounterAndProxy(Counter(counterProxy));
        counterProxyA = rollups.createCrossChainProxy(address(counterReal), uint64(rA.id));
        actorA = new CounterAndProxy(Counter(counterProxyA));

        triggerProxy = rollups.createCrossChainProxy(triggerTarget, uint64(rA.id));

        // Fund the source proxy that dispatches the erc20 transfer (it is msg.sender to the token).
        tokenHolderProxy = rollups.createCrossChainProxy(tokenHolder, uint64(rA.id));
        token.transfer(tokenHolderProxy, 1_000_000e18);

        incrementCalldata = abi.encodeWithSelector(Counter.increment.selector);
        incrementProxyCalldata = abi.encodeWithSelector(CounterAndProxy.incrementProxy.selector);

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(token);
        uniswapCalldata =
            abi.encodeCall(IUniswapV2Router.swapExactTokensForTokens, (AMT, 0, path, bob, 1_000_000_000));

        // Scenario-1 graph: A calls B' (proxy for B on rB).
        s1ProxyB = rollups.createCrossChainProxy(s1B, uint64(rB.id));
        s1A = new CounterAndProxy(Counter(s1ProxyB));

        // Scenario-3-on-L1 graph: D calls C' (proxy for C on rA); alice enters via D' (proxy for D on rB).
        s4ProxyC = rollups.createCrossChainProxy(s4C, uint64(rA.id));
        s4D = new CounterAndProxy(Counter(s4ProxyC));
        s4ProxyD = rollups.createCrossChainProxy(address(s4D), uint64(rB.id));

        // Committed in setUp (a separate tx): its slots are non-zero ORIGINAL in every test.
        seeded = new ArrayStore();
        seeded.fill(2);

        // Seed rS's execution queue with 2 entries IN SETUP (a committed prior tx) so that a post
        // measured in a later test tx re-writes non-zero ORIGINAL slots — the production
        // steady-state cost, not first-ever zero-init.
        rS = _makeRollup(keccak256("rS-init")); // id 3
        _postBatchTwo(rB.id, rS.id, _steadyEntries(2));

        // Control: a rollup seeded BARE (no call / no expected). Its call+expected slots have ZERO
        // originals, so writing them later is zero-init — proving the seed shape is what makes the
        // incremental steady numbers steady. See test_Doc_SeedShapeMatters.
        rS2 = _makeRollup(keccak256("rS2-init")); // id 4
        _postBatchTwo(rB.id, rS2.id, _one(_steadyShapedFor(rS2.id, false, false)));

        // Seeded with a 2-StateDelta full entry → measure the marginal cost of one extra StateDelta.
        rS3 = _makeRollup(keccak256("rS3-init")); // id 5
        _postBatchTwo(rB.id, rS3.id, _one(_steadyShaped2(rS3.id)));
    }

    /// @notice One entry routed to `dest` of a given shape (deferred, never executed). Values only
    ///         need to pass postAndVerifyBatch validation, which requires call sources to be in the
    ///         attested set {rB, dest}; the unified reentrant table carries no routing of its own.
    function _steadyShapedFor(uint256 dest, bool withCall, bool withExpected)
        internal
        view
        returns (ExecutionEntry memory e)
    {
        // ONE StateDelta (single rollup). The flat call's source is `dest` itself, so a single delta
        // satisfies post-validation; deferred entries are never executed, so the rolling hash and the
        // reentrant table's position keys are placeholders.
        StateDelta[] memory d = new StateDelta[](1);
        d[0] = StateDelta({
            rollupId: uint64(dest),
            currentState: _getRollupState(dest),
            newState: bytes32(uint256(0x50)),
            etherDelta: 0
        });

        L2ToL1Call[] memory calls = new L2ToL1Call[](withCall ? 1 : 0);
        if (withCall) {
            calls[0] = L2ToL1Call({
                revertNextNCalls: 0,
                isStatic: false,
                sourceAddress: genericSource,
                sourceRollupId: uint64(dest),
                targetAddress: address(sink),
                value: 0,
                data: hex"deadbeef"
            });
        }
        ExpectedL1ToL2Call[] memory exp = new ExpectedL1ToL2Call[](withExpected ? 1 : 0);
        if (withExpected) {
            exp[0] = _deferredExpected();
        }

        e.stateDeltas = d;
        e.proxyEntryHash = keccak256("steady");
        e.destinationRollupId = uint64(dest);
        e.l2ToL1Calls = calls;
        e.expectedL1ToL2Calls = exp;
        e.success = true;
    }

    /// @notice Same full shape as _steadyShapedFor(dest,true,true) but with TWO StateDeltas
    ///         (rB + dest), so the marginal cost of one extra StateDelta can be measured.
    function _steadyShaped2(uint256 dest) internal view returns (ExecutionEntry memory e) {
        StateDelta[] memory d = new StateDelta[](2);
        d[0] = StateDelta({
            rollupId: uint64(rB.id),
            currentState: _getRollupState(rB.id),
            newState: bytes32(uint256(0xB0)),
            etherDelta: 0
        });
        d[1] = StateDelta({
            rollupId: uint64(dest),
            currentState: _getRollupState(dest),
            newState: bytes32(uint256(0x50)),
            etherDelta: 0
        });

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: genericSource,
            sourceRollupId: uint64(dest),
            targetAddress: address(sink),
            value: 0,
            data: hex"deadbeef"
        });
        ExpectedL1ToL2Call[] memory exp = new ExpectedL1ToL2Call[](1);
        exp[0] = _deferredExpected();

        e.stateDeltas = d;
        e.proxyEntryHash = keccak256("steady2");
        e.destinationRollupId = uint64(dest);
        e.l2ToL1Calls = calls;
        e.expectedL1ToL2Calls = exp;
        e.success = true;
    }

    /// @notice A single placeholder reentrant table entry for DEFERRED (never-executed) entries.
    ///         Carries no sub-calls, so post-validation sees nothing to prove; its position key is
    ///         arbitrary because consumption (and the rolling-hash match) never happens.
    function _deferredExpected() internal pure returns (ExpectedL1ToL2Call memory) {
        return ExpectedL1ToL2Call({
            expectedL1toL2Hash: keccak256("steady-nested"),
            l2ToL1Calls: new L2ToL1Call[](0),
            revertedOrStaticRollingHash: bytes32(0),
            success: true,
            returnData: abi.encode(uint256(1))
        });
    }

    function _steadyShaped(bool withCall, bool withExpected) internal view returns (ExecutionEntry memory) {
        return _steadyShapedFor(rS.id, withCall, withExpected);
    }

    /// @notice n identical full-shape (call + expected) entries routed to rS — used to seed setUp.
    function _steadyEntries(uint256 n) internal view returns (ExecutionEntry[] memory entries) {
        ExecutionEntry memory e = _steadyShaped(true, true);
        entries = new ExecutionEntry[](n);
        for (uint256 i = 0; i < n; i++) {
            entries[i] = e;
        }
    }

    function _one(ExecutionEntry memory e) internal pure returns (ExecutionEntry[] memory a) {
        a = new ExecutionEntry[](1);
        a[0] = e;
    }

    /// @notice Steady-state post of one rS entry of the given shape. Caller ensures the queue
    ///         already holds one same-shape entry (the "previous block") so it is delete+push over
    ///         non-zero originals. Colds slots first.
    function _measurePostSteadyShape(bool withCall, bool withExpected) internal returns (uint256 gasUsed) {
        _coolProtocol();
        vm.cool(address(rS.manager));
        uint256 g = gasleft();
        _postBatchTwo(rB.id, rS.id, _one(_steadyShaped(withCall, withExpected)));
        gasUsed = g - gasleft();
    }

    // ──────────────────────────────────────────────
    //  Batch / entry builders
    // ──────────────────────────────────────────────

    /// @notice Posts a batch attesting both rA and rB (so both are verified this block), with all
    ///         entries deferred to rA's queue.
    function _postTwoRollups(ExecutionEntry[] memory entries) internal {
        _postBatchTwo(rA.id, rB.id, entries);
    }

    /// @notice Posts a batch attesting two rollups r1 < r2 (entries route via destinationRollupId).
    function _postBatchTwo(uint256 r1, uint256 r2, ExecutionEntry[] memory entries) internal {
        _postBatchTwoT(r1, r2, entries, 0);
    }

    /// @notice Like _postBatchTwo but with an explicit immediateEntryCount — the leading prefix
    ///         loaded into the transient table (and, where proxyEntryHash==0, run inline via
    ///         attemptApplyImmediate during the post itself).
    function _postBatchTwoT(uint256 r1, uint256 r2, ExecutionEntry[] memory entries, uint256 immediateCount)
        internal
    {
        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](1);
        psIdx[0] = 0;

        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](2);
        rps[0] = RollupIdWithProofSystems({rollupId: uint64(r1), proofSystemIndexes: psIdx});
        rps[1] = RollupIdWithProofSystems({rollupId: uint64(r2), proofSystemIndexes: psIdx});

        ProofSystemBatchPerVerificationEntries memory batch = ProofSystemBatchPerVerificationEntries({
            blockNumber: 0,
            entries: entries,
            staticLookups: _emptyStaticLookups(),
            immediateEntryCount: immediateCount,
            immediateStaticLookupCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
        rollups.postAndVerifyBatch(batch);
    }

    /// @notice Two StateDeltas (rA, rB) — touches 2 rollups.
    function _twoDeltas(bytes32 newA, bytes32 newB) internal view returns (StateDelta[] memory deltas) {
        deltas = new StateDelta[](2);
        deltas[0] =
            StateDelta({rollupId: uint64(rA.id), currentState: _getRollupState(rA.id), newState: newA, etherDelta: 0});
        deltas[1] =
            StateDelta({rollupId: uint64(rB.id), currentState: _getRollupState(rB.id), newState: newB, etherDelta: 0});
    }

    /// @notice One StateDelta (rA) — touches a single rollup.
    function _oneDelta(bytes32 newA) internal view returns (StateDelta[] memory deltas) {
        deltas = new StateDelta[](1);
        deltas[0] =
            StateDelta({rollupId: uint64(rA.id), currentState: _getRollupState(rA.id), newState: newA, etherDelta: 0});
    }

    /// @notice Assembles a single entry routed to rA, with the given calls/expected/hash. `success`
    ///         is always true (these entries return their `returnData`).
    function _entry(
        StateDelta[] memory deltas,
        bytes32 proxyEntryHash,
        L2ToL1Call[] memory calls,
        ExpectedL1ToL2Call[] memory expected,
        bytes memory returnData,
        bytes32 rollingHash
    )
        internal
        view
        returns (ExecutionEntry memory entry)
    {
        entry.stateDeltas = deltas;
        entry.proxyEntryHash = proxyEntryHash;
        entry.destinationRollupId = uint64(rA.id);
        entry.l2ToL1Calls = calls;
        entry.expectedL1ToL2Calls = expected;
        entry.rollingHash = rollingHash;
        entry.success = true;
        entry.returnData = returnData;
    }

    /// @notice The proxyEntryHash for the top-level trigger: alice calls triggerProxy with "".
    ///         Source = alice on L1 (MAINNET), target = triggerTarget on rA.
    function _triggerHash() internal view returns (bytes32) {
        return _ccHash(NOT_STATIC_CALL, alice, MAINNET_ROLLUP_ID, triggerTarget, uint64(rA.id), 0, "");
    }

    // ── flat-call builders ──

    function _sinkCall() internal view returns (L2ToL1Call memory) {
        return L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: genericSource,
            sourceRollupId: uint64(rA.id),
            targetAddress: address(sink),
            value: 0,
            data: hex"deadbeef"
        });
    }

    function _erc20Call() internal view returns (L2ToL1Call memory) {
        return L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: tokenHolder,
            sourceRollupId: uint64(rA.id),
            targetAddress: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (bob, AMT))
        });
    }

    function _uniswapCall() internal view returns (L2ToL1Call memory) {
        return L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: genericSource,
            sourceRollupId: uint64(rA.id),
            targetAddress: address(sink),
            value: 0,
            data: uniswapCalldata
        });
    }

    /// @notice Flat call whose target (actor) re-enters EEZ once, consuming one ExpectedL1ToL2Call.
    function _reentrantCall() internal view returns (L2ToL1Call memory) {
        return L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: actorCaller,
            sourceRollupId: uint64(rA.id),
            targetAddress: address(actor),
            value: 0,
            data: incrementProxyCalldata
        });
    }

    /// @notice SAME-rollup reentrant call: actorA re-enters EEZ for rA (the entry's own rollup),
    ///         so the entry needs only ONE StateDelta (rA).
    function _reentrantCallA() internal view returns (L2ToL1Call memory) {
        return L2ToL1Call({
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: actorCaller,
            sourceRollupId: uint64(rA.id),
            targetAddress: address(actorA),
            value: 0,
            data: incrementProxyCalldata
        });
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

    function _calls(L2ToL1Call memory c0) internal pure returns (L2ToL1Call[] memory arr) {
        arr = new L2ToL1Call[](1);
        arr[0] = c0;
    }

    function _rets(bytes memory r0) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = r0;
    }

    // ── rolling-hash builders (mirror EEZBase fold order) ──

    /// @notice The reentrant cross-chain call hash for a flat reentrant call: the actor re-enters via
    ///         its proxy to call counterReal. Source is the actor on L1 (MAINNET — EEZ forces this),
    ///         target is counterReal on the actor's paired rollup (rB for `actor`, rA for `actorA`).
    function _nestedCch(L2ToL1Call memory c) internal view returns (bytes32) {
        if (c.targetAddress == address(actorA)) {
            return _ccHash(
                NOT_STATIC_CALL, address(actorA), MAINNET_ROLLUP_ID, address(counterReal), uint64(rA.id), 0, incrementCalldata
            );
        }
        return _ccHash(
            NOT_STATIC_CALL, address(actor), MAINNET_ROLLUP_ID, address(counterReal), uint64(rB.id), 0, incrementCalldata
        );
    }

    /// @notice Folds an executed entry's rolling hash AND builds the matching reentrant table.
    /// @dev `seed` is `_hEntryBegin(deltas, proxyEntryHash)`. Each top-level call k folds
    ///      CALL_BEGIN(cch_k) / CALL_END(true, rets[k]); when `reentrant`, the LAST call additionally
    ///      opens a no-sub-call NESTED success frame, and its `ExpectedL1ToL2Call` is position-keyed on
    ///      the rolling hash at the instant it fires (after CALL_BEGIN, before NESTED_BEGIN).
    function _foldExec(bytes32 seed, L2ToL1Call[] memory calls, bytes[] memory rets, bool reentrant)
        internal
        view
        returns (bytes32 h, ExpectedL1ToL2Call[] memory expected)
    {
        h = seed;
        expected = new ExpectedL1ToL2Call[](reentrant ? 1 : 0);
        for (uint256 k = 0; k < calls.length; k++) {
            L2ToL1Call memory c = calls[k];
            // CALL_BEGIN folds the call's identity (target on L1 = MAINNET, source on its rollup).
            bytes32 cch = _ccHash(
                c.isStatic, c.sourceAddress, c.sourceRollupId, c.targetAddress, MAINNET_ROLLUP_ID, c.value, c.data
            );
            h = _hCallBegin(h, cch);
            if (reentrant && k == calls.length - 1) {
                bytes32 fireHash = h;
                bytes32 nestedCch = _nestedCch(c);
                h = _hNestedBegin(h, nestedCch);
                h = _hNestedEnd(h);
                expected[0] = ExpectedL1ToL2Call({
                    expectedL1toL2Hash: _expectedL1toL2Hash(nestedCch, fireHash),
                    l2ToL1Calls: new L2ToL1Call[](0),
                    revertedOrStaticRollingHash: bytes32(0),
                    success: true,
                    returnData: abi.encode(uint256(1))
                });
            }
            h = _hCallEnd(h, true, rets[k]);
        }
    }

    // ──────────────────────────────────────────────
    //  Measurement drivers
    // ──────────────────────────────────────────────

    /// @notice Colds the protocol-side accounts/slots (EEZ registry, both rollup managers, the
    ///         proof system). Models a fresh transaction: prior batches left non-zero VALUES, but
    ///         EVM warm/cold access state resets every transaction, so the slots are cold again.
    function _coolProtocol() internal {
        vm.cool(address(rollups));
        vm.cool(address(rA.manager));
        vm.cool(address(rB.manager));
        vm.cool(address(ps));
    }

    /// @notice Colds everything a user execution touches except the user's tx.to (the entry-point
    ///         proxy stays warm per EIP-2929). Used so execution pays realistic cold SLOAD/account
    ///         costs instead of slots warmed by the post earlier in the same test context.
    function _coolForExec() internal {
        _coolProtocol();
        vm.cool(address(token));
        vm.cool(address(sink));
        vm.cool(address(actor));
        vm.cool(address(counterReal));
        vm.cool(tokenHolderProxy);
        vm.cool(counterProxy);
        vm.cool(rollups.computeCrossChainProxyAddress(genericSource, uint64(rA.id)));
        vm.cool(rollups.computeCrossChainProxyAddress(actorCaller, uint64(rA.id)));
    }

    /// @notice Posts the given entries; the same batch is meant to be posted twice (caller posts a
    ///         warm-up first so VALUES are non-zero). Colds slots first → measured post pays cold
    ///         access like a fresh tx. Returns gas spent on the post.
    function _measurePost(ExecutionEntry[] memory entries) internal returns (uint256 gasUsed) {
        _coolProtocol();
        uint256 g = gasleft();
        _postTwoRollups(entries);
        gasUsed = g - gasleft();
    }

    /// @notice Builds + posts one EXECUTED entry routed to rA with `nDeltas` StateDeltas (1 = one
    ///         rollup, 2 = two rollups). Reads live roots, safe across blocks. The batch always
    ///         attests both rA and rB so a reentrant nested call into rB passes its verified gate,
    ///         independent of how many StateDeltas the entry carries. Computes the entry's rolling
    ///         hash and reentrant table from the actual calls (seeded with `_hEntryBegin`).
    function _postEntryN(uint8 nDeltas, L2ToL1Call[] memory calls, bytes[] memory rets, bool reentrant) internal {
        bytes32 newA = keccak256(abi.encodePacked(_getRollupState(rA.id), uint8(0xA)));
        bytes32 newB = keccak256(abi.encodePacked(_getRollupState(rB.id), uint8(0xB)));
        StateDelta[] memory deltas = nDeltas == 2 ? _twoDeltas(newA, newB) : _oneDelta(newA);
        bytes32 ph = _triggerHash();
        (bytes32 h, ExpectedL1ToL2Call[] memory expected) = _foldExec(_hEntryBegin(deltas, ph), calls, rets, reentrant);
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _entry(deltas, ph, calls, expected, "", h);
        _postTwoRollups(entries);
    }

    /// @notice Posts one entry (`nDeltas` rollups touched) then measures alice's trigger call that
    ///         executes it — with cold slots (the realistic "separate user tx" cost).
    function _measureExecN(uint8 nDeltas, L2ToL1Call[] memory calls, bytes[] memory rets, bool reentrant)
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

    /// @notice Default execution measurement. Touches a single rollup (1 StateDelta) unless the
    ///         entry is `reentrant`: a reentrant L1→L2 destination must be in the entry's own
    ///         stateDeltas (src/EEZ.sol `ReentrantDestinationNotVerified`), so a cross-rollup
    ///         reentrant entry necessarily touches 2 rollups.
    function _measureExec(L2ToL1Call[] memory calls, bytes[] memory rets, bool reentrant)
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
        // Deferred entries are never executed, so currentState/rollingHash are placeholders.
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

        // Warm-up posts (block N), then measured posts (block N+1).
        _postTwoRollups(p0);
        _postTwoRollups(p1);
        _postTwoRollups(p2);
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
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  POSTING COST — table with 1 entry vs 2 entries (each: 2 rollups + 1 reentrant)
    // ══════════════════════════════════════════════════════════════════════════

    function test_PostCost_1vs2Entries() public {
        bytes32 ph = keccak256("deferred-trigger");

        // 1 StateDelta, deferred (never executed). The reentrant flat call's source is rA, so a
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
        //     StateDelta (1 rollup). Uses _measureExecN(1, ...).
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

    // Marginal execution cost of touching an extra rollup (one more StateDelta): same plain-call
    // entry executed with 1 vs 2 StateDeltas. The delta is the read of the extra delta + the
    // SSTORE of that rollup's state root at consumption.
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
        console.log("  +1 rollup (StateDelta)", twoRollup - oneRollup);
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
        StateDelta[] memory deltas = _twoDeltas(newA, newB);
        L2ToL1Call[] memory calls = _calls(_reentrantCall());
        (bytes32 h, ExpectedL1ToL2Call[] memory exp) = _foldExec(_hEntryBegin(deltas, peh), calls, _rets(""), true);
        ExecutionEntry memory e = _entry(deltas, peh, calls, exp, "", h);
        // Post as an EOA: a contract sender would get the meta-hook callback when an unexecuted
        // transient entry remains (the !execute case), which the test contract doesn't implement.
        vm.prank(alice);
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
        console.log("  immediate execution cost  ", withExec - withoutExec);
    }

    // Same-rollup (1 StateDelta) reentrant entry loaded into the transient table; proxyEntryHash==0
    // → executed inline. Posted as an EOA (no meta-hook).
    function _postImmediateA() internal {
        bytes32 newA = keccak256(abi.encodePacked(_getRollupState(rA.id), uint8(0xA)));
        StateDelta[] memory deltas = _oneDelta(newA);
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
        ExecutionEntry memory e =
            _entry(_twoDeltas(newA, newB), keccak256("deferred-save"), _calls(_reentrantCall()), _reentrantExpected(), "", bytes32(0));
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

    // Probe: is a queue seeded in a PRIOR committed tx (setUp) cheaper to re-write than one
    // first written inside the measured tx? If yes, our in-test warm-up does NOT capture the
    // production steady-state cost, and the reported post numbers are first-init (high).
    ArrayStore internal seeded; // filled in setUp (committed) → original values non-zero in tests

    function test_Doc_OriginalValue_SeedInSetup() public {
        // STEADY: `seeded` had a.fill(2) run in setUp, so its slots are non-zero ORIGINAL.
        seeded.fill(2); // warm up current-value inside this tx
        vm.cool(address(seeded));
        uint256 g0 = gasleft();
        seeded.fill(2); // delete + re-push over non-zero originals
        uint256 steady = g0 - gasleft();

        // COLD-INIT: a fresh contract, slots zero at tx start → SSTORE_SET (20k) on each push.
        ArrayStore fresh = new ArrayStore();
        fresh.fill(2); // warm up (still original == 0 within this tx)
        vm.cool(address(fresh));
        uint256 g1 = gasleft();
        fresh.fill(2);
        uint256 coldInit = g1 - gasleft();

        console.log("array_fill2_steady_seeded ", steady);
        console.log("array_fill2_cold_init     ", coldInit);
        assertLt(steady, coldInit, "seeded (non-zero original) must be cheaper than zero-init");
    }

    // Proves the incremental steady numbers are genuinely steady: rS was seeded FULL in setUp
    // (call+expected slots non-zero originals) → posting a full entry is dirty-cheap; rS2 was
    // seeded BARE (call+expected zero) → posting a full entry pays SSTORE_SET on those slots.
    function test_Doc_SeedShapeMatters() public {
        // rS: bring queue to 1 full entry (prev block), then measure a full-entry post.
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS.id, _one(_steadyShapedFor(rS.id, true, true)));
        vm.roll(block.number + 1);
        _coolProtocol();
        vm.cool(address(rS.manager));
        uint256 gA = gasleft();
        _postBatchTwo(rB.id, rS.id, _one(_steadyShapedFor(rS.id, true, true)));
        uint256 seededFull = gA - gasleft();

        // rS2: same, but its call+expected slots were never seeded → zero originals.
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS2.id, _one(_steadyShapedFor(rS2.id, true, true)));
        vm.roll(block.number + 1);
        _coolProtocol();
        vm.cool(address(rS2.manager));
        uint256 gB = gasleft();
        _postBatchTwo(rB.id, rS2.id, _one(_steadyShapedFor(rS2.id, true, true)));
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
        _postBatchTwo(rB.id, rS.id, _steadyEntries(2));
        uint256 steady2 = g2 - gasleft();

        // 1-entry steady: first bring the queue down to 1, then measure delete 1 + push 1.
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS.id, _steadyEntries(1)); // queue -> 1
        vm.roll(block.number + 1);
        _coolProtocol();
        vm.cool(address(rS.manager));
        uint256 g1 = gasleft();
        _postBatchTwo(rB.id, rS.id, _steadyEntries(1));
        uint256 steady1 = g1 - gasleft();

        console.log("postBatch_1entry_steady  ", steady1);
        console.log("postBatch_2entries_steady", steady2);
        console.log("  steady delta per entry ", steady2 - steady1);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  POSTING COST — marginal cost of one extra StateDelta (a posted entry touching
    //  one more rollup). Full-shape steady post with 1 vs 2 StateDeltas, each on a
    //  rollup seeded with the matching shape so both are steady (non-zero originals).
    // ══════════════════════════════════════════════════════════════════════════

    function test_PostCost_PerStateDelta() public {
        // 1 StateDelta (rS seeded 1-delta full)
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS.id, _one(_steadyShapedFor(rS.id, true, true))); // prior block
        vm.roll(block.number + 1);
        _coolProtocol();
        vm.cool(address(rS.manager));
        uint256 g1 = gasleft();
        _postBatchTwo(rB.id, rS.id, _one(_steadyShapedFor(rS.id, true, true)));
        uint256 oneDelta = g1 - gasleft();

        // 2 StateDeltas (rS3 seeded 2-delta full)
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
        console.log("  +1 StateDelta (steady)", twoDelta - oneDelta);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  POSTING COST — incremental entry shape, STEADY-STATE (non-zero originals)
    //  Each measured post: the queue already holds one same-shape entry from the
    //  prior block, so it is delete+push over non-zero slots (subsequent, not first).
    // ══════════════════════════════════════════════════════════════════════════

    function test_PostCost_IncrementalSteady() public {
        // bare entry
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS.id, _one(_steadyShaped(false, false))); // prior block = bare
        vm.roll(block.number + 1);
        uint256 p0 = _measurePostSteadyShape(false, false);

        // + 1 L2ToL1Call
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS.id, _one(_steadyShaped(true, false)));
        vm.roll(block.number + 1);
        uint256 p1 = _measurePostSteadyShape(true, false);

        // + 1 ExpectedL1ToL2Call
        vm.roll(block.number + 1);
        _postBatchTwo(rB.id, rS.id, _one(_steadyShaped(true, true)));
        vm.roll(block.number + 1);
        uint256 p2 = _measurePostSteadyShape(true, true);

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

        StateDelta[] memory d = new StateDelta[](1);
        d[0] = StateDelta({rollupId: uint64(rB.id), currentState: _getRollupState(rB.id), newState: newB, etherDelta: 0});

        ExecutionEntry[] memory e = new ExecutionEntry[](1);
        e[0].stateDeltas = d;
        e[0].proxyEntryHash = ph;
        e[0].destinationRollupId = uint64(rB.id);
        e[0].rollingHash = _hEntryBegin(d, ph);
        e[0].success = true;
        e[0].returnData = abi.encode(uint256(1));
        // l2ToL1Calls / expectedL1ToL2Calls empty

        _postBatchOne(rB, e, _emptyStaticLookups(), 0, 0);
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
        StateDelta[] memory deltas = _twoDeltas(newA, newB);

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
        e[0].stateDeltas = deltas;
        e[0].proxyEntryHash = ph;
        e[0].destinationRollupId = uint64(rB.id);
        e[0].l2ToL1Calls = calls;
        e[0].expectedL1ToL2Calls = exp;
        e[0].rollingHash = h;
        e[0].success = true;

        _postTwoRollups(e);
    }
}
