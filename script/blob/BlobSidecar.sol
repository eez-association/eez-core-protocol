// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
//  BlobSidecar — the sidecar's data model, shared by TableStitcher (its input),
//  BlobTranslator (bundles it with the tables), and the test harness (feeds it).
//
//  The sidecar carries transaction metadata, the static call tree and outcomes,
//  explicit rollback boundaries, chain operations and stream position. Static
//  values duplicated in lookup rows are checked against those rows; callback
//  outcomes are checked against their accumulators. Mutable fields/results are
//  recovered from tables. This metadata does not replace table validation.
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Per-transaction metadata (tables don't delimit transactions).
struct SidecarTx {
    uint64 originChain;
    bytes txData;
    uint8[] rootKinds; // ROOT_KIND_CALL / ROOT_KIND_STATIC per root slot
}

/// @notice Fields of a hash-matched static call — both managers match static
///         reads by hash only, so the fields ride the blob, never a table.
struct SidecarStatic {
    address fromAddress;
    uint64 toChain;
    address toAddress;
    uint64 gas;
    bytes data;
    uint256 childCount; // static subtree shape; rows alone do not delimit static nesting
}

/// @notice Result of one static node in DFS order. The stitcher cross-checks it
///         against a source lookup and/or the destination callback accumulator.
///         Fully unexecuted static legs require their result in the sidecar.
struct SidecarStaticResult {
    bool success;
    bytes returnData;
}

/// @notice A ChainOperation and its stream position (chain-local, not cross-chain).
struct SidecarChainOp {
    uint64 chainId;
    bytes operations;
    uint256 txsBefore; // # transactions fully emitted before this op
}
