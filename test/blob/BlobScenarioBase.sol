// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    EEZ,
    ProofSystemBatchPerVerificationEntries,
    RollupIdWithProofSystems,
    ExpectedRootPerRollup
} from "../../src/EEZ.sol";
import {EEZL2} from "../../src/L2/EEZL2.sol";
import {Rollup} from "../../src/rollupContract/Rollup.sol";
import {IEEZ, ExecutionEntry, StaticExecutionEntry} from "../../src/interfaces/IEEZ.sol";
import {
    ExecutionEntry as L2ExecutionEntry,
    StaticExecutionEntry as L2StaticExecutionEntry
} from "../../src/interfaces/IEEZL2.sol";
import {MockProofSystem} from "../mocks/MockProofSystem.sol";
import {BlobMessage, Msg} from "../../script/blob/BlobMessages.sol";
import {BlobCodec} from "../../script/blob/BlobCodec.sol";
import {BlobPacking} from "../../script/blob/BlobPacking.sol";
import {ScenarioStore, CallNode, TxSpec, ChainOpSpec} from "../../script/blob/ScenarioStore.sol";
import {TableGenerator} from "../../script/blob/TableGenerator.sol";
import {TableStitcher} from "../../script/blob/TableStitcher.sol";
import {SidecarStatic} from "../../script/blob/BlobSidecar.sol";
import {ScriptedActor} from "../../script/blob/ScriptedActor.sol";
import {
    ROOT_KIND_CALL,
    ROOT_KIND_STATIC,
    UNIT_KIND_ORIGIN_GROUP,
    STEP_CALL,
    STEP_CALL_EXPECT_REVERT,
    STEP_STATIC_READ,
    STEP_SUBCONTEXT_REVERT,
    STEP_STATIC_EXPECT_REVERT,
    blobGenesisRoot
} from "../../script/blob/BlobConstants.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  BlobScenarioBase — the scenario harness. A test builds a blob message list
//  (the ONLY scenario input) and calls `runScenario`, which proves the full
//  chain of equivalences:
//
//    1. CODEC     encode → 4844-pack → unpack → decode reproduces the messages
//    2. IR        parse → emit reproduces the messages
//    3. BLOB→TABLE  TableGenerator derives every chain's execution tables
//    4. TABLE→BLOB  TableStitcher rebuilds the messages from those tables
//                   (+ the non-table sidecar) — byte-identical blob
//    5. EXECUTION the derived tables actually run on the real EEZ / EEZL2
//                 managers: batch posted and consumed on L1, tables loaded and
//                 driven on every L2, every return value asserted in-flight by
//                 the scripted actors, final roots checked
//
//  Setup contract: `_setUpChains(n)` registers L2 chains with ids 1..n (chain
//  id 0 is L1); scenario addresses must be `newActor(chainId)` instances, and a
//  transaction's root calls must share one `fromAddress` (the origin driver).
// ─────────────────────────────────────────────────────────────────────────────

abstract contract BlobScenarioBase is Test {
    uint64 internal constant L1 = 0;
    address internal constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);

    EEZ internal rollups;
    MockProofSystem internal ps;
    mapping(uint64 => EEZL2) internal managers;
    mapping(uint64 => Rollup) internal rollupManagers;
    uint64 internal l2ChainCount;

    mapping(address => uint64) internal _actorChainPlus1;

    // ──────────────────────────────────────────────
    //  Setup
    // ──────────────────────────────────────────────

    /// @notice Deploys the L1 registry and `numL2s` L2 managers; L2 chain ids are 1..numL2s.
    function _setUpChains(uint64 numL2s) internal {
        rollups = new EEZ(makeAddr("recovery"));
        ps = new MockProofSystem();
        for (uint64 i = 1; i <= numL2s; i++) {
            address[] memory psList = new address[](1);
            psList[0] = address(ps);
            bytes32[] memory vks = new bytes32[](1);
            vks[0] = keccak256("blobfw-vk");
            // Named owner (not address(this)): no blob test exercises the owner path,
            // and forge script forbids address(this) in script contracts (BlobTools).
            Rollup manager = new Rollup(address(rollups), makeAddr("rollup-owner"), 1, psList, vks);
            uint64 rid = rollups.registerRollup(address(manager), _genesisRoot(i));
            require(rid == i, "chain id / rollup id mismatch");
            rollupManagers[i] = manager;
            managers[i] = new EEZL2(i, SYSTEM_ADDRESS, false);
        }
        l2ChainCount = numL2s;
        vm.deal(SYSTEM_ADDRESS, 1_000_000 ether);
    }

    /// @notice Deploys a scripted actor living on `chainId` (0 = L1).
    function newActor(uint64 chainId) internal returns (ScriptedActor a) {
        a = new ScriptedActor();
        _actorChainPlus1[address(a)] = chainId + 1;
        vm.deal(address(a), 1_000_000 ether);
    }

    /// @dev The shared `blobGenesisRoot` (same definition TableGenerator's ledger uses).
    function _genesisRoot(uint64 rid) internal pure returns (bytes32) {
        return blobGenesisRoot(rid);
    }

    // ──────────────────────────────────────────────
    //  Scenario pipeline
    // ──────────────────────────────────────────────

    function runScenario(BlobMessage[] memory msgs) internal {
        // 1. Byte codec + 4844 packing round trip.
        _checkCodecRoundTrip(msgs);

        // 2. Messages → IR → messages.
        ScenarioStore store = new ScenarioStore();
        store.fromMessages(msgs);
        _assertMsgsEq(store.toMessages(), msgs, "IR round trip");

        // 3. Observe each L2-sourced call's `callGas` (probe calls against empty tables) —
        //    the values the source chains fold into their outgoing keys. All 0 while the
        //    managers run `useGasLeft = false`; see the probing section at the end of this file.
        _createProxies(store);
        uint64[] memory gasByNode = _probeAllCallGas(store);

        // 4. Blob → Table.
        TableGenerator gen = new TableGenerator();
        gen.generate(store, gasByNode);

        // 5. Table → Blob (tables + sidecar only — never the original store).
        _checkTableRoundTrip(store, gen, msgs, gasByNode);

        // 6. Live execution of the derived tables on the real managers.
        _execute(store, gen);
    }

    // ──────────────────────────────────────────────
    //  callGas observation
    // ──────────────────────────────────────────────

    /// @notice Explicit gas attached to a call fired at nesting depth `d` — a halving ladder so
    ///         every frame can afford its children's explicit requests (and the base stays far
    ///         below the test gas budget, so the 63/64 rule never clips a request). Probe and
    ///         live execution use the same value, which is what makes the observed `callGas`
    ///         reproducible.
    function _gasAtDepth(uint256 d) internal pure returns (uint64) {
        return uint64(200_000_000 >> d);
    }

    /// @notice Explicit gas for static read steps. Static matching never keys on gas, so the value needs
    ///         no reproducibility — it only bounds the proxy's static-context probe burn (see
    ///         `ScriptedActor._dispatchStatic`).
    uint64 internal constant STATIC_STEP_GAS = 5_000_000;

    function _checkCodecRoundTrip(BlobMessage[] memory msgs) internal pure {
        (bytes memory blobPortion, bytes memory tail) = BlobCodec.encode(msgs);
        bytes32[][] memory blobs = BlobPacking.pack(blobPortion);
        BlobMessage[] memory decoded = BlobCodec.decode(BlobPacking.unpack(blobs), tail);
        _assertMsgsEq(decoded, msgs, "codec round trip");
    }

    function _checkTableRoundTrip(
        ScenarioStore store,
        TableGenerator gen,
        BlobMessage[] memory msgs,
        uint64[] memory gasByNode
    )
        internal
    {
        TableStitcher stitcher = new TableStitcher();

        // Tables.
        stitcher.loadL1(gen.l1Entries(), gen.l1StaticEntries());
        for (uint256 i = 0; i < gen.unitCount(); i++) {
            TableGenerator.UnitTag memory tag = gen.unitTag(i);
            stitcher.loadUnit(tag.chainId, tag.kind, gen.unitEntries(i), gen.unitStatics(i));
        }

        // Sidecar: data that provably never reaches a table.
        for (uint256 t = 0; t < store.txCount(); t++) {
            TxSpec memory txSpec = store.getTx(t);
            uint8[] memory kinds = new uint8[](txSpec.rootCalls.length);
            for (uint256 k = 0; k < txSpec.rootCalls.length; k++) {
                kinds[k] = store.getNode(txSpec.rootCalls[k]).isStatic ? ROOT_KIND_STATIC : ROOT_KIND_CALL;
            }
            stitcher.loadSidecarTx(txSpec.originChain, txSpec.txData, kinds);
        }
        uint256[] memory staticIds = store.staticNodesInOrder();
        for (uint256 i = 0; i < staticIds.length; i++) {
            CallNode memory n = store.getNode(staticIds[i]);
            stitcher.loadSidecarStatic(
                SidecarStatic({
                    fromAddress: n.fromAddress, toChain: n.toChain, toAddress: n.toAddress, gas: n.gas, data: n.data
                })
            );
            // Sub-read fields live in the static entry's sub-call array (a table);
            // only their results ride the sidecar.
            for (uint256 c = 0; c < n.children.length; c++) {
                CallNode memory sub = store.getNode(n.children[c]);
                stitcher.loadSidecarStaticSubResult(sub.success, sub.returnData);
            }
        }
        stitcher.loadSidecarRegionSizes(store.regionSizesInOrder());
        for (uint256 t = 0; t < store.txCount(); t++) {
            _feedCallGasSidecar(stitcher, store, store.getTx(t).rootCalls, gasByNode);
        }
        for (uint256 i = 0; i < store.chainOpCount(); i++) {
            ChainOpSpec memory op = store.getChainOp(i);
            stitcher.loadSidecarChainOp(op.chainId, op.operations, op.txsBefore);
        }
        if (store.hasClose()) {
            stitcher.loadSidecarClose(store.closeTxsBefore(), store.closeOpsBefore());
        }

        // Stitch into a fresh store and compare down to the wire bytes.
        ScenarioStore rebuilt = new ScenarioStore();
        stitcher.stitch(rebuilt);
        BlobMessage[] memory msgs2 = rebuilt.toMessages();
        _assertMsgsEq(msgs2, msgs, "table round trip");
        (bytes memory b1, bytes memory t1) = BlobCodec.encode(msgs);
        (bytes memory b2, bytes memory t2) = BlobCodec.encode(msgs2);
        assertEq(b2, b1, "table round trip: blob bytes");
        assertEq(t2, t1, "table round trip: callData bytes");
    }

    /// @dev Feeds each L2-sourced mutable call's observed callGas in execution (DFS) order,
    ///      queued under its destination-kind hash — callGas reaches no table, so it rides
    ///      the sidecar like the static call fields do.
    function _feedCallGasSidecar(
        TableStitcher stitcher,
        ScenarioStore store,
        uint256[] memory siblings,
        uint64[] memory gasByNode
    )
        internal
    {
        for (uint256 i = 0; i < siblings.length; i++) {
            CallNode memory n = store.getNode(siblings[i]);
            if (!n.isStatic && n.fromChain != L1) {
                bytes32 destCallHash = rollups.computeCrossChainCallHash(
                    n.isStatic, n.fromAddress, n.fromChain, n.toAddress, n.toChain, n.value, 0, n.data
                );
                stitcher.loadSidecarCallGas(destCallHash, gasByNode[siblings[i]]);
            }
            _feedCallGasSidecar(stitcher, store, n.children, gasByNode);
        }
    }

    // ──────────────────────────────────────────────
    //  Live execution
    // ──────────────────────────────────────────────

    function _execute(ScenarioStore store, TableGenerator gen) internal {
        uint64[] memory rids = gen.rollupIds();
        for (uint256 i = 0; i < rids.length; i++) {
            require(rids[i] <= l2ChainCount, "scenario uses an unregistered chain");
            _fundRollupBalance(rids[i], 10_000 ether);
        }

        _programActors(store);
        _driveAll(store, gen);

        for (uint256 i = 0; i < rids.length; i++) {
            (, bytes32 liveRoot,) = rollups.rollups(rids[i]);
            assertEq(liveRoot, gen.finalRoot(rids[i]), "final L1 root");
        }
    }

    function _managerOf(uint64 chainId) internal view returns (IEEZ) {
        return chainId == L1 ? IEEZ(address(rollups)) : IEEZ(address(managers[chainId]));
    }

    /// @notice Deploys, for every call: the target's proxy on the calling chain (the
    ///         actor calls it) and the source's proxy on the executing chain (static
    ///         resolution requires it pre-deployed; mutable paths auto-create).
    function _createProxies(ScenarioStore store) internal {
        for (uint256 i = 0; i < store.nodeCount(); i++) {
            CallNode memory n = store.getNode(i);
            _ensureProxy(_managerOf(n.fromChain), n.toAddress, n.toChain);
            _ensureProxy(_managerOf(n.toChain), n.fromAddress, n.fromChain);
        }
    }

    function _ensureProxy(IEEZ manager, address original, uint64 rid) internal {
        if (manager.computeCrossChainProxyAddress(original, rid).code.length == 0) {
            manager.createCrossChainProxy(original, rid);
        }
    }

    /// @notice Derives every actor's behavior from the call tree: per transaction, a
    ///         `drive()` program for the origin driver (the shared root fromAddress),
    ///         then one program per mutable node keyed by its calldata, and static
    ///         results for static nodes.
    function _programActors(ScenarioStore store) internal {
        for (uint256 t = 0; t < store.txCount(); t++) {
            TxSpec memory txSpec = store.getTx(t);
            if (txSpec.rootCalls.length == 0) continue;

            address driver = store.getNode(txSpec.rootCalls[0]).fromAddress;
            require(_actorChainPlus1[driver] == txSpec.originChain + 1, "driver must be an actor on the origin chain");
            for (uint256 k = 1; k < txSpec.rootCalls.length; k++) {
                require(store.getNode(txSpec.rootCalls[k]).fromAddress == driver, "roots must share one driver");
            }

            ScriptedActor(payable(driver))
                .addProgram(
                    abi.encodeCall(ScriptedActor.drive, ()),
                    _buildSteps(store, txSpec.rootCalls, txSpec.originChain, 0),
                    false,
                    ""
                );
            for (uint256 k = 0; k < txSpec.rootCalls.length; k++) {
                _programSubtree(store, txSpec.rootCalls[k], 0);
            }
        }
    }

    function _programSubtree(ScenarioStore store, uint256 nodeId, uint256 depth) internal {
        CallNode memory n = store.getNode(nodeId);
        require(_actorChainPlus1[n.toAddress] == n.toChain + 1, "call target must be an actor on its chain");
        if (n.isStatic) {
            if (n.children.length == 0) {
                ScriptedActor(payable(n.toAddress)).setStaticResult(n.data, n.success, n.returnData);
            } else {
                // A read with sub-reads: when it runs live (STATICCALLed on an
                // executing chain) the actor performs each sub-read for real.
                ScriptedActor(payable(n.toAddress))
                    .setStaticProgram(n.data, _buildStaticSteps(store, n.children, n.toChain), n.success, n.returnData);
                for (uint256 i = 0; i < n.children.length; i++) {
                    _programSubtree(store, n.children[i], depth + 1);
                }
            }
            return;
        }
        ScriptedActor(payable(n.toAddress))
            .addProgram(n.data, _buildSteps(store, n.children, n.toChain, depth + 1), !n.success, n.returnData);
        for (uint256 i = 0; i < n.children.length; i++) {
            _programSubtree(store, n.children[i], depth + 1);
        }
    }

    /// @notice Translates a sibling run into actor steps: one proxy call per child,
    ///         Snapshot regions as reverting sub-context wrappers.
    function _buildSteps(
        ScenarioStore store,
        uint256[] memory siblings,
        uint64 execChain,
        uint256 depth
    )
        internal
        view
        returns (ScriptedActor.Step[] memory steps)
    {
        uint256 regions = 0;
        for (uint256 i = 0; i < siblings.length; i++) {
            if (store.nodeRevertSpan(siblings[i]) > 0) regions++;
        }
        steps = new ScriptedActor.Step[](siblings.length + regions);
        uint256 w = 0;
        for (uint256 i = 0; i < siblings.length; i++) {
            CallNode memory child = store.getNode(siblings[i]);
            require(child.fromChain == execChain, "child does not execute on its parent's chain");
            if (child.revertSpan > 0) {
                steps[w++] = ScriptedActor.Step({
                    kind: STEP_SUBCONTEXT_REVERT,
                    target: address(0),
                    value: 0,
                    stepGas: 0,
                    data: "",
                    expected: "",
                    subCount: child.revertSpan
                });
            }
            uint8 kind;
            if (child.isStatic) {
                kind = child.success ? STEP_STATIC_READ : STEP_STATIC_EXPECT_REVERT;
            } else {
                kind = child.success ? STEP_CALL : STEP_CALL_EXPECT_REVERT;
            }
            steps[w++] = ScriptedActor.Step({
                kind: kind,
                target: _managerOf(execChain).computeCrossChainProxyAddress(child.toAddress, child.toChain),
                value: child.value,
                stepGas: child.isStatic ? STATIC_STEP_GAS : _gasAtDepth(depth),
                data: child.data,
                expected: child.returnData,
                subCount: 0
            });
        }
    }

    /// @dev Static sub-read steps for a read's live evaluation: one static proxy read
    ///      per child, performed on the chain the parent read executes on.
    function _buildStaticSteps(
        ScenarioStore store,
        uint256[] memory children,
        uint64 execChain
    )
        internal
        view
        returns (ScriptedActor.Step[] memory steps)
    {
        steps = new ScriptedActor.Step[](children.length);
        for (uint256 i = 0; i < children.length; i++) {
            CallNode memory sub = store.getNode(children[i]);
            require(sub.fromChain == execChain, "static sub-read does not execute on its parent's chain");
            steps[i] = ScriptedActor.Step({
                kind: sub.success ? STEP_STATIC_READ : STEP_STATIC_EXPECT_REVERT,
                target: _managerOf(execChain).computeCrossChainProxyAddress(sub.toAddress, sub.toChain),
                value: 0,
                stepGas: STATIC_STEP_GAS,
                data: sub.data,
                expected: sub.returnData,
                subCount: 0
            });
        }
    }

    /// @notice Posts one batch per transaction, in message order. An L2-origin tx's
    ///         L2Tx host is `entries[0]` with `immediateEntryCount = 1` — the
    ///         canonical shape: `postAndVerifyBatch` executes it inline, running
    ///         every L1-side call of the tx. (A same-block re-post wipes the touched
    ///         rollups' queues, so each tx's deferred entries are consumed before
    ///         the next batch posts — exactly what `_driveAll` does.)
    function _postTxBatch(TableGenerator gen, uint256 t) internal {
        // Slice this tx's L1 entries + statics (order preserved).
        ExecutionEntry[] memory allEntries = gen.l1Entries();
        StaticExecutionEntry[] memory allStatics = gen.l1StaticEntries();
        uint256[] memory entryTx = gen.l1EntryTxIndexes();
        uint256[] memory staticTx = gen.l1StaticTxIndexes();

        uint256 nE = 0;
        uint256 nS = 0;
        for (uint256 i = 0; i < allEntries.length; i++) {
            if (entryTx[i] == t) nE++;
        }
        for (uint256 i = 0; i < allStatics.length; i++) {
            if (staticTx[i] == t) nS++;
        }
        if (nE == 0 && nS == 0) return; // nothing to commit on L1 for this tx

        ExecutionEntry[] memory entries = new ExecutionEntry[](nE);
        StaticExecutionEntry[] memory statics = new StaticExecutionEntry[](nS);
        uint256 w = 0;
        for (uint256 i = 0; i < allEntries.length; i++) {
            if (entryTx[i] == t) entries[w++] = allEntries[i];
        }
        w = 0;
        for (uint256 i = 0; i < allStatics.length; i++) {
            if (staticTx[i] == t) statics[w++] = allStatics[i];
        }

        // The batch's verified set: every rollup the entries' deltas / statics' pins touch.
        uint64[] memory rids = new uint64[](l2ChainCount);
        uint256 nR = 0;
        for (uint256 i = 0; i < entries.length; i++) {
            for (uint256 d = 0; d < entries[i].rollupUpdates.length; d++) {
                nR = _addRid(rids, nR, entries[i].rollupUpdates[d].rollupId);
            }
        }
        for (uint256 i = 0; i < statics.length; i++) {
            for (uint256 p = 0; p < statics[i].expectedRoots.length; p++) {
                nR = _addRid(rids, nR, statics[i].expectedRoots[p].rollupId);
            }
        }

        address[] memory psList = new address[](1);
        psList[0] = address(ps);
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = "proof";
        uint64[] memory psIdx = new uint64[](1);
        psIdx[0] = 0;
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](nR);
        for (uint256 i = 0; i < nR; i++) {
            rps[i] = RollupIdWithProofSystems({rollupId: rids[i], proofSystemIndexes: psIdx});
        }

        rollups.postAndVerifyBatch(
            ProofSystemBatchPerVerificationEntries({
                expectedRootPerRollup: new ExpectedRootPerRollup[](0),
                entries: entries,
                staticEntries: statics,
                immediateEntryCount: (nE > 0 && entries[0].proxyEntryHash == bytes32(0)) ? 1 : 0,
                immediateStaticEntryCount: 0,
                proofSystems: psList,
                rollupIdsWithProofSystems: rps,
                blobIndices: new uint256[](0),
                callData: "",
                proofs: proofs,
                blockNumber: 0,
                bindMsgSenderInPublicInput: false
            })
        );
    }

    /// @dev Sorted-insert `rid` into `rids[0..n)` if absent; returns the new count.
    function _addRid(uint64[] memory rids, uint256 n, uint64 rid) internal pure returns (uint256) {
        uint256 i = 0;
        while (i < n && rids[i] < rid) {
            i++;
        }
        if (i < n && rids[i] == rid) return n;
        for (uint256 j = n; j > i; j--) {
            rids[j] = rids[j - 1];
        }
        rids[i] = rid;
        return n + 1;
    }

    /// @notice Executes the scenario in message order: per transaction, post its L1
    ///         batch (the L2Tx host runs inline), drive the L1 origin driver if any,
    ///         then each L2 unit — origin groups (load + drive) and inbound
    ///         deliveries (system call).
    function _driveAll(ScenarioStore store, TableGenerator gen) internal {
        uint256 unitN = gen.unitCount();
        uint256 unitIdx = 0;
        for (uint256 t = 0; t < store.txCount(); t++) {
            TxSpec memory txSpec = store.getTx(t);
            _postTxBatch(gen, t);
            if (txSpec.originChain == L1 && txSpec.rootCalls.length > 0) {
                // L1 driver consumes the tx's deferred origin entries.
                ScriptedActor(payable(store.getNode(txSpec.rootCalls[0]).fromAddress)).drive();
            }
            while (unitIdx < unitN && gen.unitTag(unitIdx).txIndex == t) {
                _driveUnit(store, gen, unitIdx);
                unitIdx++;
            }
        }
        assertEq(unitIdx, unitN, "all units driven");
    }

    function _driveUnit(ScenarioStore store, TableGenerator gen, uint256 i) internal {
        TableGenerator.UnitTag memory tag = gen.unitTag(i);
        L2ExecutionEntry[] memory entries = gen.unitEntries(i);
        L2StaticExecutionEntry[] memory statics = gen.unitStatics(i);
        EEZL2 manager = managers[tag.chainId];

        if (tag.kind == UNIT_KIND_ORIGIN_GROUP) {
            // Origin group: load the table, then the origin driver's own tx consumes it.
            vm.prank(SYSTEM_ADDRESS);
            manager.loadExecutionTable(entries, statics);
            TxSpec memory txSpec = store.getTx(tag.txIndex);
            ScriptedActor(payable(store.getNode(txSpec.rootCalls[0]).fromAddress)).drive();
        } else {
            // Inbound delivery: the system atomically loads + drives entries[0].
            CallNode memory n = store.getNode(tag.inboundNodeId);
            vm.prank(SYSTEM_ADDRESS);
            try manager.executeIncomingCrossChainCall{value: n.value}(entries, statics) returns (bytes memory ret) {
                assertTrue(n.success, "inbound call should have reverted");
                assertEq(ret, n.returnData, "inbound return data");
            } catch (bytes memory err) {
                assertFalse(n.success, "inbound call should have succeeded");
                assertEq(err, n.returnData, "inbound revert data");
            }
        }
    }

    /// @dev Mirrors Base.t.sol's `_fundRollup`: EEZ storage layout has `rollups`
    ///      mapping at slot 2; `etherBalance` is the third field of RollupConfig.
    function _fundRollupBalance(uint64 rid, uint256 amount) internal {
        bytes32 baseSlot = keccak256(abi.encode(rid, uint256(2)));
        vm.store(address(rollups), bytes32(uint256(baseSlot) + 2), bytes32(amount));
        vm.deal(address(rollups), address(rollups).balance + amount);
    }

    /// @notice Runs only the Blob→Table direction — for tests asserting table shape.
    function _generateTables(BlobMessage[] memory msgs)
        internal
        returns (ExecutionEntry[] memory l1, uint256 units, address gen)
    {
        ScenarioStore store = new ScenarioStore();
        store.fromMessages(msgs);
        TableGenerator g = new TableGenerator();
        // Shape-only derivation: a zero oracle stands in for observed callGas (hash VALUES differ
        // from a live run, table shapes don't).
        g.generate(store, new uint64[](store.nodeCount()));
        return (g.l1Entries(), g.unitCount(), address(g));
    }

    // ──────────────────────────────────────────────
    //  Assertions
    // ──────────────────────────────────────────────

    function _assertMsgsEq(BlobMessage[] memory got, BlobMessage[] memory want, string memory ctx) internal pure {
        assertEq(got.length, want.length, string.concat(ctx, ": message count"));
        for (uint256 i = 0; i < want.length; i++) {
            assertTrue(Msg.eq(got[i], want[i]), string.concat(ctx, ": message mismatch at index ", vm.toString(i)));
        }
    }

    // ──────────────────────────────────────────────
    //  callGas probing — DORMANT under `useGasLeft = false`
    // ──────────────────────────────────────────────
    //
    //  The harness deploys every `EEZL2` with `useGasLeft = false`, so these probes trivially
    //  observe 0 for every node and the `gasByNode` oracle no longer influences any hash. The
    //  phase is kept in the pipeline (`runScenario` step 3) because it is the ONLY way to build
    //  the oracle under the future observed-gas mode (`useGasLeft = true`) — the whole flow
    //  (probe → `TableGenerator._sourceCch` keys → stitcher callGas sidecar) stays wired and
    //  behavior-identical the day the flag flips.

    /// @notice Observes, per L2-sourced mutable node, the exact `callGas` its consuming proxy call
    ///         will fold into the source chain's key: probes twice against an empty table (block
    ///         gate satisfied, guaranteed no-match) — the first call warms the access path, the
    ///         second measures it warm — reading the value from `EntryNotFound(hash, callGas)`.
    function _probeAllCallGas(ScenarioStore store) internal returns (uint64[] memory gasByNode) {
        uint256 n = store.nodeCount();
        gasByNode = new uint64[](n);
        uint256[] memory depths = new uint256[](n);
        for (uint256 t = 0; t < store.txCount(); t++) {
            _fillDepths(store, store.getTx(t).rootCalls, 0, depths);
        }

        bool[] memory gateLoaded = new bool[](l2ChainCount + 1);
        for (uint256 id = 0; id < n; id++) {
            CallNode memory node = store.getNode(id);
            if (node.isStatic || node.fromChain == L1) continue;
            EEZL2 m = managers[node.fromChain];
            if (!gateLoaded[node.fromChain]) {
                vm.prank(SYSTEM_ADDRESS);
                m.loadExecutionTable(new L2ExecutionEntry[](0), new L2StaticExecutionEntry[](0));
                gateLoaded[node.fromChain] = true;
            }
            address proxyAddr = m.computeCrossChainProxyAddress(node.toAddress, node.toChain);
            uint64 stepGas = _gasAtDepth(depths[id]);
            uint64 observed;
            for (uint256 k = 0; k < 2; k++) {
                vm.prank(node.fromAddress);
                (bool ok, bytes memory err) = proxyAddr.call{value: node.value, gas: stepGas}(node.data);
                require(!ok, "probe: unexpectedly matched an entry");
                require(bytes4(err) == EEZL2.EntryNotFound.selector, "probe: expected EntryNotFound");
                assembly {
                    observed := mload(add(err, 0x44))
                }
            }
            gasByNode[id] = observed;
        }
    }

    function _fillDepths(
        ScenarioStore store,
        uint256[] memory siblings,
        uint256 d,
        uint256[] memory depths
    )
        internal
        view
    {
        for (uint256 i = 0; i < siblings.length; i++) {
            depths[siblings[i]] = d;
            _fillDepths(store, store.getNode(siblings[i]).children, d + 1, depths);
        }
    }
}
