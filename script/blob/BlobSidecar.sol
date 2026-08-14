// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
//  BlobSidecar — the sidecar's data model, shared by TableStitcher (its input),
//  BlobTranslator (bundles it with the tables), and the test harness (feeds it).
//
//  The sidecar carries exactly the data that provably never reaches any table:
//  per-tx metadata, hash-matched static call fields, static sub-read results,
//  region sizes, ChainOperation payloads, and the CloseBlobStream position.
//  See TableStitcher's header for why each item cannot be recovered from the
//  tables alone.
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
}

/// @notice Result of one static sub-read, in parent-DFS order. A sub-read's
///         FIELDS live in its static entry's sub-call array (a table), but its
///         result is only ever hashed into the untagged accumulator — so the
///         result alone rides the sidecar.
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
