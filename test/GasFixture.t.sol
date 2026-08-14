// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {
    ProofSystemBatchPerVerificationEntries,
    ExpectedStateRootPerRollup,
    RollupIdWithProofSystems
} from "../src/EEZ.sol";
import {ExecutionEntry, StateUpdate, L2ToL1Call, ExpectedL1ToL2Call} from "../src/interfaces/IEEZ.sol";
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

/// @title GasFixture
/// @notice Shared scaffolding for the L1 gas suites (GasCost, GasExecPaths): rollups rA/rB plus the
///         steady-state-seeded rS/rS2/rS3, token/sink targets, reentrant actors and their cross-chain
///         proxies, entry/batch builders, rolling-hash folds, and the vm.cool helpers. Abstract —
///         carries no tests of its own.
abstract contract GasFixture is Base {
    RollupHandle internal rA; // destination rollup for every entry
    RollupHandle internal rB; // second touched rollup + reentrant target's rollup
    RollupHandle internal rS; // queue seeded FULL-shape in setUp → steady-state post measurements
    RollupHandle internal rS2; // queue seeded BARE in setUp → control: call/expected NOT pre-filled
    RollupHandle internal rS3; // queue seeded 2-StateUpdate full in setUp → marginal per-StateUpdate

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

    ArrayStore internal seeded; // filled in setUp (committed) → original values non-zero in tests

    function setUp() public virtual {
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
        uniswapCalldata = abi.encodeCall(IUniswapV2Router.swapExactTokensForTokens, (AMT, 0, path, bob, 1_000_000_000));

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
        _postBatchTwo(rB.id, rS.id, _savedFor(rS.id, 2, 1, 1));

        // Control: a rollup seeded BARE (no call / no expected). Its call+expected slots have ZERO
        // originals, so writing them later is zero-init — proving the seed shape is what makes the
        // incremental steady numbers steady. See test_Doc_SeedShapeMatters.
        rS2 = _makeRollup(keccak256("rS2-init")); // id 4
        _postBatchTwo(rB.id, rS2.id, _savedFor(rS2.id, 1, 0, 0));

        // Seeded with a 2-StateUpdate full entry → measure the marginal cost of one extra StateUpdate.
        rS3 = _makeRollup(keccak256("rS3-init")); // id 5
        _postBatchTwo(rB.id, rS3.id, _one(_steadyShaped2(rS3.id)));
    }

    /// @notice `nEntries` identical DEFERRED (saved, never executed) entries routed to `dest`, each
    ///         carrying `nCalls` placeholder L2ToL1Calls and `nExpected` placeholder
    ///         ExpectedL1ToL2Calls. Rolling hash / keys are placeholders (consumption never happens).
    ///         Source/StateUpdate pin to `dest` so the entry passes post-validation.
    function _savedFor(uint256 dest, uint256 nEntries, uint256 nCalls, uint256 nExpected)
        internal
        view
        returns (ExecutionEntry[] memory entries)
    {
        StateUpdate[] memory d = new StateUpdate[](1);
        d[0] = StateUpdate({
            rollupId: uint64(dest), currentState: _getRollupState(dest), newState: bytes32(uint256(0x50)), etherDelta: 0
        });
        L2ToL1Call[] memory calls = new L2ToL1Call[](nCalls);
        for (uint256 i = 0; i < nCalls; i++) {
            calls[i] = L2ToL1Call({
                gas: 0,
                revertNextNCalls: 0,
                isStatic: false,
                sourceAddress: genericSource,
                sourceRollupId: uint64(dest),
                targetAddress: address(sink),
                value: 0,
                data: hex"deadbeef"
            });
        }
        ExpectedL1ToL2Call[] memory exp = new ExpectedL1ToL2Call[](nExpected);
        for (uint256 i = 0; i < nExpected; i++) {
            exp[i] = _deferredExpected();
        }
        ExecutionEntry memory e;
        e.stateUpdates = d;
        e.proxyEntryHash = keccak256("save-defer");
        e.destinationRollupId = uint64(dest);
        e.l2ToL1Calls = calls;
        e.expectedL1ToL2Calls = exp;
        e.success = true;
        entries = new ExecutionEntry[](nEntries);
        for (uint256 i = 0; i < nEntries; i++) {
            entries[i] = e;
        }
    }

    /// @notice Same full shape as `_savedFor(dest, 1, 1, 1)` but with TWO StateUpdates (rB + dest),
    ///         so the marginal cost of one extra StateUpdate can be measured.
    function _steadyShaped2(uint256 dest) internal view returns (ExecutionEntry memory e) {
        StateUpdate[] memory d = new StateUpdate[](2);
        d[0] = StateUpdate({
            rollupId: uint64(rB.id),
            currentState: _getRollupState(rB.id),
            newState: bytes32(uint256(0xB0)),
            etherDelta: 0
        });
        d[1] = StateUpdate({
            rollupId: uint64(dest), currentState: _getRollupState(dest), newState: bytes32(uint256(0x50)), etherDelta: 0
        });

        L2ToL1Call[] memory calls = new L2ToL1Call[](1);
        calls[0] = L2ToL1Call({
            gas: 0,
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

        e.stateUpdates = d;
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

    function _one(ExecutionEntry memory e) internal pure returns (ExecutionEntry[] memory a) {
        a = new ExecutionEntry[](1);
        a[0] = e;
    }

    // ──────────────────────────────────────────────
    //  Batch / entry builders
    // ──────────────────────────────────────────────

    /// @notice Posts a batch attesting two rollups r1 < r2 (entries route via destinationRollupId).
    function _postBatchTwo(uint256 r1, uint256 r2, ExecutionEntry[] memory entries) internal {
        _postBatchTwoT(r1, r2, entries, 0);
    }

    /// @notice Like _postBatchTwo but with an explicit immediateEntryCount — the leading prefix
    ///         loaded into the transient table (and, where proxyEntryHash==0, run inline via
    ///         attemptApplyImmediate during the post itself).
    function _postBatchTwoT(uint256 r1, uint256 r2, ExecutionEntry[] memory entries, uint256 immediateCount) internal {
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
            expectedStateRootPerRollup: new ExpectedStateRootPerRollup[](0),
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
        rollups.postAndVerifyBatch(batch);
    }

    /// @notice Two StateUpdates (rA, rB) — touches 2 rollups.
    function _twoDeltas(bytes32 newA, bytes32 newB) internal view returns (StateUpdate[] memory deltas) {
        deltas = new StateUpdate[](2);
        deltas[0] =
            StateUpdate({rollupId: uint64(rA.id), currentState: _getRollupState(rA.id), newState: newA, etherDelta: 0});
        deltas[1] =
            StateUpdate({rollupId: uint64(rB.id), currentState: _getRollupState(rB.id), newState: newB, etherDelta: 0});
    }

    /// @notice One StateUpdate (rA) — touches a single rollup.
    function _oneDelta(bytes32 newA) internal view returns (StateUpdate[] memory deltas) {
        deltas = new StateUpdate[](1);
        deltas[0] =
            StateUpdate({rollupId: uint64(rA.id), currentState: _getRollupState(rA.id), newState: newA, etherDelta: 0});
    }

    /// @notice Assembles a single entry routed to rA, with the given calls/expected/hash. `success`
    ///         is always true (these entries return their `returnData`).
    function _entry(
        StateUpdate[] memory deltas,
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
        entry.stateUpdates = deltas;
        entry.proxyEntryHash = proxyEntryHash;
        entry.destinationRollupId = uint64(rA.id);
        entry.l2ToL1Calls = calls;
        entry.expectedL1ToL2Calls = expected;
        entry.rollingHash = rollingHash;
        entry.success = true;
        entry.returnData = returnData;
    }

    // ── flat-call builders ──

    function _sinkCall() internal view returns (L2ToL1Call memory) {
        return L2ToL1Call({
            gas: 0,
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
            gas: 0,
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
            gas: 0,
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
            gas: 0,
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
    ///         so the entry needs only ONE StateUpdate (rA).
    function _reentrantCallA() internal view returns (L2ToL1Call memory) {
        return L2ToL1Call({
            gas: 0,
            revertNextNCalls: 0,
            isStatic: false,
            sourceAddress: actorCaller,
            sourceRollupId: uint64(rA.id),
            targetAddress: address(actorA),
            value: 0,
            data: incrementProxyCalldata
        });
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
                NOT_STATIC_CALL,
                address(actorA),
                MAINNET_ROLLUP_ID,
                address(counterReal),
                uint64(rA.id),
                0,
                incrementCalldata
            );
        }
        return _ccHash(
            NOT_STATIC_CALL,
            address(actor),
            MAINNET_ROLLUP_ID,
            address(counterReal),
            uint64(rB.id),
            0,
            incrementCalldata
        );
    }

    /// @notice Folds an executed entry's rolling hash AND builds the matching reentrant table, for
    ///         any mix of plain/reentrant top-level calls (mirrors EEZ._processNCalls + the
    ///         nested-reentry resolution).
    /// @dev `seed` is `_hEntryBegin(deltas, proxyEntryHash)`. Each top-level call k folds
    ///      CALL_BEGIN(cch_k) / CALL_END(true, rets[k]); each call flagged in `reentrant` additionally
    ///      opens a no-sub-call NESTED success frame, and its `ExpectedL1ToL2Call` is position-keyed on
    ///      the rolling hash at the instant it fires (after CALL_BEGIN, before NESTED_BEGIN).
    function _foldGeneric(bytes32 seed, L2ToL1Call[] memory calls, bool[] memory reentrant, bytes[] memory rets)
        internal
        view
        returns (bytes32 h, ExpectedL1ToL2Call[] memory expected)
    {
        uint256 nRe;
        for (uint256 k = 0; k < reentrant.length; k++) {
            if (reentrant[k]) nRe++;
        }
        expected = new ExpectedL1ToL2Call[](nRe);
        uint256 ei;
        h = seed;
        for (uint256 k = 0; k < calls.length; k++) {
            L2ToL1Call memory c = calls[k];
            // CALL_BEGIN folds the call's identity (target on L1 = MAINNET, source on its rollup).
            bytes32 cch = _ccHash(
                c.isStatic, c.sourceAddress, c.sourceRollupId, c.targetAddress, MAINNET_ROLLUP_ID, c.value, c.data
            );
            h = _hCallBegin(h, cch);
            if (reentrant[k]) {
                bytes32 fireHash = h;
                bytes32 nestedCch = _nestedCch(c);
                h = _hNestedBegin(h, nestedCch);
                h = _hNestedEnd(h);
                expected[ei++] = ExpectedL1ToL2Call({
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

    /// @notice `_foldGeneric` for the common shape where only the LAST call re-enters (`reentrant`),
    ///         or none does.
    function _foldExec(bytes32 seed, L2ToL1Call[] memory calls, bytes[] memory rets, bool reentrant)
        internal
        view
        returns (bytes32 h, ExpectedL1ToL2Call[] memory expected)
    {
        bool[] memory re = new bool[](calls.length);
        if (reentrant) re[calls.length - 1] = true;
        return _foldGeneric(seed, calls, re, rets);
    }

    // ──────────────────────────────────────────────
    //  Cooling helpers
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
}
