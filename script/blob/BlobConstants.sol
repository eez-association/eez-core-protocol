// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
//  BlobConstants — the framework's shared scalar vocabulary, in one place.
//  Every file that stores, loads, or compares one of these values imports it
//  from here; a bare 1/2/0/64 literal for any of these concepts is a bug.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev L2 unit kinds (TableGenerator.UnitTag.kind / TableStitcher unit stream /
///      BlobTranslator.L2Unit.kind): an origin group is loaded via
///      `loadExecutionTable` and consumed by the origin driver's own tx; an
///      inbound delivery is one entry driven by `executeIncomingCrossChainCall`.
uint8 constant UNIT_KIND_ORIGIN_GROUP = 1;
uint8 constant UNIT_KIND_INBOUND = 2;

/// @dev Root slot kinds in the per-tx sidecar (TableStitcher.SidecarTx.rootKinds).
uint8 constant ROOT_KIND_CALL = 0;
uint8 constant ROOT_KIND_STATIC = 1;

/// @dev Shared "no node" sentinel: ScenarioStore's root-frame parent id and the
///      generator/stitcher's open-frame / pending-node markers all use this value —
///      they are compared across contract boundaries (e.g. the stitcher passes it
///      as `newCall`'s parentId), so it must be ONE constant.
uint256 constant NO_NODE = type(uint256).max;

/// @dev "no chain" sentinel for error locators (0 is L1, so it can't serve).
uint64 constant NO_CHAIN = type(uint64).max;

/// @dev ScriptedActor step kinds — how the harness scripts an actor's behavior.
uint8 constant STEP_CALL = 1; // call target; expect success + exact return data
uint8 constant STEP_CALL_EXPECT_REVERT = 2; // call target; expect revert with exact payload
uint8 constant STEP_STATIC_READ = 3; // staticcall target; expect success + exact return data
uint8 constant STEP_SUBCONTEXT_REVERT = 4; // run the next `subCount` steps, then roll them back (Snapshot…Revert)
uint8 constant STEP_STATIC_EXPECT_REVERT = 5; // staticcall target; expect revert with exact payload

/// @dev Maximum call/context nesting depth. One limit shared by the codec's
///      context stack (§5 validation), ScenarioStore's parse-time frame stack,
///      and the DSL compiler's frame stack — they walk the same brackets, so
///      their capacities must agree.
uint256 constant MAX_CALL_DEPTH = 64;
