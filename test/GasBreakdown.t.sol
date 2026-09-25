// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {GasFixture} from "./GasFixture.t.sol";
import {GasMeter, GasMeterProbe} from "./helpers/GasMeter.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries} from "../src/EEZ.sol";
import {
    ExecutionEntry,
    StaticExecutionEntry,
    ExpectedRootPerRollup,
    ExpectedL1ToL2Call,
    RollupUpdate,
    L2ToL1Call
} from "../src/interfaces/IEEZ.sol";

/// @notice Holds the L2-to-L1 driver count fixed while varying the number of nested L1-to-L2 calls.
contract GasRepeatCaller {
    function repeat(address proxy, uint256 count) external {
        for (uint256 i; i < count; i++) {
            (bool ok,) = proxy.call("");
            require(ok, "nested proxy call failed");
        }
    }
}

/// @notice Contract-body gas only: build inputs before cooling, then capture vm.lastCallGas
///         immediately after the measured call. No test setup, caller-side ABI encoding,
///         intrinsic/calldata/blob fees, or refund discounts are included.
/// @dev All proxies used for dispatch already exist. Roots are non-zero and the verifier is mocked.
///      Immediate execution uses no-op roots so warm-up and measured batches have identical shapes.
contract GasBreakdown is GasFixture {
    GasRepeatCaller internal repeatCaller;
    address internal genericProxy;
    address internal actorProxy;

    function setUp() public override {
        super.setUp();
        repeatCaller = new GasRepeatCaller();
        genericProxy = rollups.getOrCreateCrossChainProxy(genericSource, uint64(rA.id));
        actorProxy = rollups.getOrCreateCrossChainProxy(actorCaller, uint64(rA.id));
    }

    function _coolBench() internal {
        _coolForExec();
        vm.cool(address(repeatCaller));
        vm.cool(genericProxy);
        vm.cool(actorProxy);
    }

    function _batch(
        ExecutionEntry[] memory entries,
        StaticExecutionEntry[] memory statics,
        uint256 immediate
    )
        internal
        view
        returns (ProofSystemBatchPerVerificationEntries memory)
    {
        return _stdBatch(rA.id, entries, statics, immediate, 0);
    }

    function _postGas(ProofSystemBatchPerVerificationEntries memory batch) internal returns (uint256 gasUsed) {
        _coolBench();
        return meter.measure(address(rollups), alice, abi.encodeCall(EEZ.postAndVerifyBatch, (batch)), false).gasUsed;
    }

    function _steadyPost(ProofSystemBatchPerVerificationEntries memory batch) internal returns (uint256) {
        uint256 snapshot = vm.snapshotState();
        rollups.postAndVerifyBatch(batch);
        vm.roll(block.number + 1);
        uint256 gasUsed = _postGas(batch);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        return gasUsed;
    }

    function _emit(string memory name, uint256 gasUsed) internal pure {
        console.log(string.concat("bench.", name), gasUsed);
    }

    function _bytes(uint256 size) internal pure returns (bytes memory data) {
        data = new bytes(size);
        for (uint256 i; i < size; i++) {
            data[i] = 0x5a;
        }
    }

    function _saved(
        uint256 n,
        uint256 calls,
        uint256 expected,
        uint256 payload
    )
        internal
        view
        returns (ExecutionEntry[] memory entries)
    {
        entries = _savedFor(rA.id, n, calls, expected);
        // Non-zero commitments avoid an artificial zero-to-nonzero premium when changing commitments.
        for (uint256 i; i < n; i++) {
            entries[i].rollingHash = keccak256("benchmark rolling hash");
            entries[i].returnData = _bytes(payload);
        }
    }

    function _statics(uint256 n, uint256 payload) internal view returns (StaticExecutionEntry[] memory entries) {
        entries = new StaticExecutionEntry[](n);
        for (uint256 i; i < n; i++) {
            entries[i].expectedRoots = new ExpectedRootPerRollup[](1);
            entries[i].expectedRoots[0] = ExpectedRootPerRollup({rollupId: uint64(rA.id), root: _getRollupState(rA.id)});
            entries[i].proxyEntryHash = _ccHash(IS_STATIC, alice, 0, triggerTarget, uint64(rA.id), 0, abi.encode(i));
            entries[i].destinationRollupId = uint64(rA.id);
            entries[i].l2ToL1Calls = _emptyCalls();
            entries[i].success = true;
            entries[i].returnData = _bytes(payload);
        }
    }

    function test_MeterExcludesTransactionCalldataCosts() public {
        GasMeterProbe probe = new GasMeterProbe();
        GasMeter.Sample memory sample =
            meter.measure(address(probe), alice, abi.encodeCall(GasMeterProbe.noop, (_bytes(4096))), false);
        assertEq(abi.decode(sample.data, (uint256)), 7);
        assertLt(sample.gasUsed, 2000, "transaction intrinsic/calldata costs leaked into execution measurement");
        _emit("calibration.noop_with_4096_calldata_bytes", sample.gasUsed);
    }

    function test_BatchBase() public {
        ProofSystemBatchPerVerificationEntries memory one = _batch(_emptyEntries(), _emptyStaticEntries(), 0);
        uint256 first = _postGas(one);
        vm.roll(block.number + 1);
        uint256 steady = _postGas(one);
        ProofSystemBatchPerVerificationEntries memory two =
            _twoRollupBatch(rA.id, rB.id, _emptyEntries(), _emptyStaticEntries(), 0, 0);
        uint256 twoGas = _steadyPost(two);
        _emit("post.empty.1rollup.first", first);
        _emit("post.empty.1rollup.steady", steady);
        _emit("post.empty.2rollups.steady", twoGas);
        _emit("post.empty.extra_rollup", twoGas - steady);
    }

    function test_DeferredEntryScaling() public {
        uint256[4] memory sizes = [uint256(1), 2, 8, 32];
        uint256 previous;
        for (uint256 i; i < sizes.length; i++) {
            uint256 n = sizes[i];
            uint256 gasUsed = _steadyPost(_batch(_saved(n, 0, 0, 0), _emptyStaticEntries(), 0));
            _emit(string.concat("post.deferred.bare.", vm.toString(n)), gasUsed);
            if (n == 2) _emit("post.deferred.extra_bare_entry", gasUsed - previous);
            previous = gasUsed;
        }
    }

    function test_DeferredShapeAndChangedCommitments() public {
        uint256 bare = _steadyPost(_batch(_saved(1, 0, 0, 0), _emptyStaticEntries(), 0));
        uint256 withCall = _steadyPost(_batch(_saved(1, 1, 0, 0), _emptyStaticEntries(), 0));
        uint256 withExpected = _steadyPost(_batch(_saved(1, 0, 1, 0), _emptyStaticEntries(), 0));
        _emit("post.deferred.extra_l2_to_l1_record", withCall - bare);
        _emit("post.deferred.extra_l1_to_l2_record", withExpected - bare);

        ProofSystemBatchPerVerificationEntries memory seeded = _batch(_saved(1, 1, 1, 32), _emptyStaticEntries(), 0);
        rollups.postAndVerifyBatch(seeded);
        vm.roll(block.number + 1);
        uint256 identical = _postGas(seeded);
        // Change three non-zero scalar fields, without changing nested array sizes or payloads.
        seeded.entries[0].proxyEntryHash = keccak256("next proxy hash");
        seeded.entries[0].rollingHash = keccak256("next rolling hash");
        seeded.entries[0].rollupUpdates[0].newRoot = bytes32(uint256(0x51));
        vm.roll(block.number + 1);
        uint256 changed = _postGas(seeded);
        _emit("post.deferred.full.identical_rewrite", identical);
        _emit("post.deferred.full.three_changed_commitments", changed);
        _emit("post.deferred.full.changed_commitment_premium", changed - identical);
    }

    function test_FirstWriteVsReuse() public {
        ProofSystemBatchPerVerificationEntries memory batch = _batch(_saved(1, 1, 1, 32), _emptyStaticEntries(), 0);
        uint256 first = _postGas(batch);
        vm.roll(block.number + 1);
        uint256 steady = _postGas(batch);
        _emit("post.deferred.full.first_write", first);
        _emit("post.deferred.full.reuse", steady);
        assertGt(first, steady, "fresh queue slots must cost more than reuse");
    }

    function test_ReturnDataScaling() public {
        uint256[5] memory sizes = [uint256(0), 32, 128, 1024, 4096];
        for (uint256 i; i < sizes.length; i++) {
            uint256 n = sizes[i];
            _emit(
                string.concat("post.deferred.return_bytes.", vm.toString(n)),
                _steadyPost(_batch(_saved(1, 0, 0, n), _emptyStaticEntries(), 0))
            );
        }
    }

    function test_BatchCalldataScaling() public {
        uint256[5] memory sizes = [uint256(0), 32, 128, 1024, 4096];
        for (uint256 i; i < sizes.length; i++) {
            ProofSystemBatchPerVerificationEntries memory batch = _batch(_emptyEntries(), _emptyStaticEntries(), 0);
            batch.callData = _bytes(sizes[i]);
            _emit(string.concat("post.batch_data_bytes.", vm.toString(sizes[i])), _steadyPost(batch));
        }
    }

    function test_StaticEntryScaling() public {
        uint256[4] memory sizes = [uint256(1), 2, 8, 32];
        uint256 previous;
        for (uint256 i; i < sizes.length; i++) {
            uint256 gasUsed = _steadyPost(_batch(_emptyEntries(), _statics(sizes[i], 32), 0));
            _emit(string.concat("post.static.entries.", vm.toString(sizes[i])), gasUsed);
            if (sizes[i] == 2) _emit("post.static.extra_entry", gasUsed - previous);
            previous = gasUsed;
        }
    }

    function _resetGas(uint256 count) internal returns (uint256) {
        rollups.postAndVerifyBatch(_batch(_saved(count, 1, 1, 128), _statics(count, 128), 0));
        vm.roll(block.number + 1);
        return _postGas(_batch(_emptyEntries(), _emptyStaticEntries(), 0));
    }

    function test_QueueResetConstantCost() public {
        uint256 one = _resetGas(1);
        uint256 thirtyTwo = _resetGas(32);
        _emit("post.reset.1execution_1static", one);
        _emit("post.reset.32execution_32static", thirtyTwo);
        assertApproxEqAbs(one, thirtyTwo, 100, "reset cost must not scale with retained queue contents");
    }

    function _executedEntry(bytes32 proxyHash, uint256 nCalls) internal view returns (ExecutionEntry memory entry) {
        RollupUpdate[] memory deltas = _oneDelta(_getRollupState(rA.id));
        L2ToL1Call[] memory calls = new L2ToL1Call[](nCalls);
        bytes[] memory rets = new bytes[](nCalls);
        for (uint256 i; i < nCalls; i++) {
            calls[i] = _sinkCall();
        }
        (bytes32 h, ExpectedL1ToL2Call[] memory expected) =
            _foldExec(_hEntryBegin(deltas, proxyHash), calls, rets, false);
        return _entry(deltas, proxyHash, calls, expected, "", h);
    }

    function test_InlineEntriesAndL2ToL1Calls() public {
        ExecutionEntry[] memory one = _one(_executedEntry(bytes32(0), 0));
        ExecutionEntry[] memory two = new ExecutionEntry[](2);
        two[0] = one[0];
        two[1] = one[0];
        uint256 e1 = _steadyPost(_batch(one, _emptyStaticEntries(), 1));
        uint256 e2 = _steadyPost(_batch(two, _emptyStaticEntries(), 2));
        uint256 c1 = _steadyPost(_batch(_one(_executedEntry(bytes32(0), 1)), _emptyStaticEntries(), 1));
        uint256 c2 = _steadyPost(_batch(_one(_executedEntry(bytes32(0), 2)), _emptyStaticEntries(), 1));
        _emit("post.inline.bare.1entry", e1);
        _emit("post.inline.bare.2entries", e2);
        _emit("post.inline.extra_bare_entry", e2 - e1);
        _emit("post.inline.1_l2_to_l1_call", c1);
        _emit("post.inline.2_l2_to_l1_calls", c2);
        _emit("post.inline.first_l2_to_l1_call", c1 - e1);
        _emit("post.inline.extra_l2_to_l1_call", c2 - c1);
    }

    function _triggerHash() internal view returns (bytes32) {
        return _ccHash(NOT_STATIC_CALL, alice, 0, triggerTarget, uint64(rA.id), 0, "");
    }

    function _consumeGas(ExecutionEntry memory entry) internal returns (uint256 gasUsed) {
        uint256 snapshot = vm.snapshotState();
        rollups.postAndVerifyBatch(_batch(_one(entry), _emptyStaticEntries(), 0));
        _coolBench();
        gasUsed = meter.measure(triggerProxy, alice, "", false).gasUsed;
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function test_TopLevelL1ToL2AndCallbacks() public {
        uint256 noCallback = _consumeGas(_executedEntry(_triggerHash(), 0));
        uint256 oneCallback = _consumeGas(_executedEntry(_triggerHash(), 1));
        uint256 twoCallbacks = _consumeGas(_executedEntry(_triggerHash(), 2));
        _emit("execute.l1_to_l2.no_callback", noCallback);
        _emit("execute.l1_to_l2.1_callback", oneCallback);
        _emit("execute.l1_to_l2.2_callbacks", twoCallbacks);
        _emit("execute.l1_to_l2.first_callback", oneCallback - noCallback);
        _emit("execute.l1_to_l2.extra_callback", twoCallbacks - oneCallback);
    }

    function _reentrantEntry(uint256 count, bytes32 proxyHash) internal view returns (ExecutionEntry memory) {
        RollupUpdate[] memory deltas = _oneDelta(_getRollupState(rA.id));
        bytes memory data = abi.encodeCall(GasRepeatCaller.repeat, (counterProxyA, count));
        L2ToL1Call memory call = _call(actorCaller, uint64(rA.id), address(repeatCaller), 0, data);
        bytes32 outerHash = _ccHash(NOT_STATIC_CALL, actorCaller, uint64(rA.id), address(repeatCaller), 0, 0, data);
        bytes32 nestedHash =
            _ccHash(NOT_STATIC_CALL, address(repeatCaller), 0, address(counterReal), uint64(rA.id), 0, "");
        bytes32 h = _hCallBegin(_hEntryBegin(deltas, proxyHash), outerHash);
        ExpectedL1ToL2Call[] memory expected = new ExpectedL1ToL2Call[](count);
        for (uint256 i; i < count; i++) {
            expected[i] = ExpectedL1ToL2Call({
                expectedL1toL2Hash: _expectedL1toL2Hash(nestedHash, h),
                l2ToL1Calls: _emptyCalls(),
                revertedOrStaticRollingHash: bytes32(0),
                success: true,
                returnData: abi.encode(uint256(1))
            });
            h = _hNestedEnd(_hNestedBegin(h, nestedHash));
        }
        h = _hCallEnd(h, true, "");
        return _entry(deltas, proxyHash, _oneCall(call), expected, "", h);
    }

    function test_IsolatedReentrantL1ToL2() public {
        uint256[3] memory inlineGas;
        uint256[3] memory deferredGas;
        for (uint256 n; n < 3; n++) {
            inlineGas[n] = _steadyPost(_batch(_one(_reentrantEntry(n, bytes32(0))), _emptyStaticEntries(), 1));
            deferredGas[n] = _consumeGas(_reentrantEntry(n, _triggerHash()));
            _emit(string.concat("post.inline.fixed_driver.nested_calls.", vm.toString(n)), inlineGas[n]);
            _emit(string.concat("execute.fixed_driver.nested_calls.", vm.toString(n)), deferredGas[n]);
        }
        _emit("post.inline.first_nested_l1_to_l2", inlineGas[1] - inlineGas[0]);
        _emit("post.inline.extra_nested_l1_to_l2", inlineGas[2] - inlineGas[1]);
        _emit("execute.first_nested_l1_to_l2", deferredGas[1] - deferredGas[0]);
        _emit("execute.extra_nested_l1_to_l2", deferredGas[2] - deferredGas[1]);
    }

    function test_QueueScanScaling() public {
        uint256[3] memory sizes = [uint256(1), 8, 32];
        for (uint256 k; k < sizes.length; k++) {
            uint256 n = sizes[k];
            ExecutionEntry[] memory entries = new ExecutionEntry[](n);
            for (uint256 i; i < n; i++) {
                entries[i] = _executedEntry(keccak256(abi.encode(i)), 0);
            }
            entries[n - 1] = _executedEntry(_triggerHash(), 0);
            rollups.postAndVerifyBatch(_batch(entries, _emptyStaticEntries(), 0));
            _coolBench();
            uint256 gasUsed = meter.measure(triggerProxy, alice, "", false).gasUsed;
            assertEq(rollups.entryQueueIndex(uint64(rA.id)), n);
            _emit(string.concat("execute.match_at_position.", vm.toString(n)), gasUsed);
        }
    }

    function _staticGas(bytes memory data, bool cold) internal returns (uint256 gasUsed) {
        if (cold) _coolBench();
        GasMeter.Sample memory sample = meter.measure(triggerProxy, alice, data, true);
        assertEq(sample.data, _bytes(32));
        return sample.gasUsed;
    }

    function test_StaticLookupScaling() public {
        uint256[3] memory sizes = [uint256(1), 8, 32];
        for (uint256 k; k < sizes.length; k++) {
            uint256 n = sizes[k];
            rollups.postAndVerifyBatch(_batch(_emptyEntries(), _statics(n, 32), 0));
            bytes memory data = abi.encode(n - 1);
            if (n == 1) {
                _coolBench();
                (GasMeter.Sample memory first, GasMeter.Sample memory repeat) =
                    meter.measureTwice(triggerProxy, alice, data);
                assertEq(first.data, _bytes(32));
                assertEq(repeat.data, _bytes(32));
                _emit("static.match_at_position.1", first.gasUsed);
                _emit("static.repeat_warm", repeat.gasUsed);
            } else {
                _emit(string.concat("static.match_at_position.", vm.toString(n)), _staticGas(data, true));
            }
        }
    }

    function test_AdditionalRollupUpdate() public {
        ExecutionEntry[] memory entries = _saved(1, 0, 0, 0);
        ProofSystemBatchPerVerificationEntries memory one =
            _twoRollupBatch(rA.id, rB.id, entries, _emptyStaticEntries(), 0, 0);
        uint256 oneGas = _steadyPost(one);
        entries[0].rollupUpdates = _twoDeltas(bytes32(uint256(0x50)), bytes32(uint256(0x60)));
        uint256 twoGas = _steadyPost(_twoRollupBatch(rA.id, rB.id, entries, _emptyStaticEntries(), 0, 0));
        _emit("post.extra_rollup_update", twoGas - oneGas);
    }

    function test_ProxyDeployment() public {
        address original = address(0xC001);
        _coolBench();
        uint256 deployment =
            meter.measure(
            address(rollups),
            alice,
            abi.encodeWithSignature("createCrossChainProxy(address,uint64)", original, uint64(rA.id)),
            false
        )
        .gasUsed;
        _coolBench();
        uint256 existing =
            meter.measure(
            address(rollups),
            alice,
            abi.encodeWithSignature("getOrCreateCrossChainProxy(address,uint64)", original, uint64(rA.id)),
            false
        )
        .gasUsed;
        _emit("proxy.deploy", deployment);
        _emit("proxy.get_existing", existing);
    }
}
