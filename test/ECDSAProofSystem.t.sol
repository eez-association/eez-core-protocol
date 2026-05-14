// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {ECDSAProofSystem} from "../src/proofSystems/ECDSAProofSystem.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries, RollupIdWithProofSystems} from "../src/EEZ.sol";
import {ExecutionEntry, LookupCall} from "../src/interfaces/IEEZ.sol";

contract ECDSAProofSystemTest is Test {
    ECDSAProofSystem verifier;

    uint256 constant SIGNER_PK = 0xA11CE;
    address signerAddr;
    address owner = address(0xBEEF);

    function setUp() public {
        signerAddr = vm.addr(SIGNER_PK);
        verifier = new ECDSAProofSystem(owner, signerAddr);
    }

    function _sign(uint256 pk, bytes32 publicInputsHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, publicInputsHash);
        return abi.encodePacked(r, s, v);
    }

    function test_verify_validSignature() public view {
        bytes32 message = keccak256("test message");
        bytes memory proof = _sign(SIGNER_PK, message);
        assertTrue(verifier.verify(proof, message));
    }

    function test_verify_wrongSigner() public view {
        bytes32 message = keccak256("test message");
        uint256 wrongPk = 0xBAD;
        bytes memory proof = _sign(wrongPk, message);
        assertFalse(verifier.verify(proof, message));
    }

    function test_setSigner_byOwner() public {
        address newSigner = address(0x1234);
        vm.prank(owner);
        verifier.setSigner(newSigner);
        assertEq(verifier.signer(), newSigner);
    }

    function test_setSigner_byNonOwner_reverts() public {
        address nonOwner = address(0xDEAD);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        verifier.setSigner(address(0x1234));
    }
}

/// @notice End-to-end test driving `postAndVerifyBatch` with a real ECDSA-signed proof on
///         a rollup whose manager allows `ECDSAProofSystem` as its proof system.
contract ECDSAProofSystemIntegrationTest is Base {
    ECDSAProofSystem verifier;
    uint256 constant SIGNER_PK = 0xA11CE;
    address signerAddr;
    address ownerAddr = address(0xBEEF);

    function setUp() public {
        setUpBase();
        signerAddr = vm.addr(SIGNER_PK);
        verifier = new ECDSAProofSystem(ownerAddr, signerAddr);
    }

    function _sign(uint256 pk, bytes32 publicInputsHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, publicInputsHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Mirrors `EEZ._verifyProofSystemBatch` for the single-PS / single-rollup shape
    ///      we build below. The reference `Rollup` manager returns `(0, bytes32(0))` from
    ///      `getTimestampAndBlockHash`, so the per-rollup `(blockHash, timestamp)` pair
    ///      folded into the accumulator is `(bytes32(0), 0)`.
    function _computePublicInputsHash(
        ExecutionEntry[] memory entries,
        LookupCall[] memory lookupCalls,
        uint256 rid,
        bytes32 vk
    )
        internal
        pure
        returns (bytes32)
    {
        bytes32[] memory entryHashes = new bytes32[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            entryHashes[i] = keccak256(abi.encode(entries[i]));
        }
        bytes32[] memory lookupCallHashes = new bytes32[](lookupCalls.length);
        for (uint256 i = 0; i < lookupCalls.length; i++) {
            lookupCallHashes[i] = keccak256(abi.encode(lookupCalls[i]));
        }
        bytes32[] memory blobHashes = new bytes32[](0);

        bytes32 sharedPublicInput = keccak256(
            abi.encodePacked(
                abi.encode(entryHashes),
                abi.encode(lookupCallHashes),
                abi.encode(blobHashes),
                keccak256(""),
                bytes32(0)
            )
        );

        bytes32 acc = bytes32(0);
        acc = keccak256(abi.encode(acc, rid, vk, bytes32(0), uint256(0)));

        return keccak256(abi.encodePacked(sharedPublicInput, acc));
    }

    function _makeECDSARollup(bytes32 initialState, bytes32 vk) internal returns (RollupHandle memory) {
        address[] memory psList = new address[](1);
        psList[0] = address(verifier);
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = vk;
        return _makeRollupCustom(initialState, psList, vks, 1, defaultOwner);
    }

    function _buildECDSABatch(
        RollupHandle memory r,
        ExecutionEntry[] memory entries,
        bytes memory proof
    )
        internal
        view
        returns (ProofSystemBatchPerVerificationEntries memory batch)
    {
        address[] memory psList = new address[](1);
        psList[0] = address(verifier);
        bytes[] memory proofs = new bytes[](1);
        proofs[0] = proof;

        uint64[] memory psIdx = new uint64[](1);
        psIdx[0] = 0;
        RollupIdWithProofSystems[] memory rps = new RollupIdWithProofSystems[](1);
        rps[0] = RollupIdWithProofSystems({rollupId: r.id, proofSystemIndex: psIdx});

        batch = ProofSystemBatchPerVerificationEntries({
            entries: entries,
            l1ToL2lookupCalls: _emptyLookupCalls(),
            transientExecutionEntryCount: 1,
            transientLookupCallCount: 0,
            proofSystems: psList,
            rollupIdsWithProofSystems: rps,
            crossProofSystemInteractions: bytes32(0),
            blobIndices: new uint256[](0),
            callData: "",
            proofs: proofs
        });
    }

    function test_postAndVerifyBatch_withECDSAVerifier() public {
        bytes32 initialState = keccak256("initial");
        bytes32 newState = keccak256("new");
        bytes32 vk = keccak256("vk");

        RollupHandle memory r = _makeECDSARollup(initialState, vk);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, initialState, newState);

        bytes32 publicInputsHash = _computePublicInputsHash(entries, _emptyLookupCalls(), r.id, vk);
        bytes memory proof = _sign(SIGNER_PK, publicInputsHash);

        rollups.postAndVerifyBatch(_buildECDSABatch(r, entries, proof));

        assertEq(_getRollupState(r.id), newState);
    }

    function test_postAndVerifyBatch_withWrongSigner_reverts() public {
        bytes32 initialState = keccak256("initial");
        bytes32 newState = keccak256("new");
        bytes32 vk = keccak256("vk");

        RollupHandle memory r = _makeECDSARollup(initialState, vk);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, initialState, newState);

        bytes32 publicInputsHash = _computePublicInputsHash(entries, _emptyLookupCalls(), r.id, vk);
        bytes memory proof = _sign(0xBAD, publicInputsHash);

        ProofSystemBatchPerVerificationEntries memory batch = _buildECDSABatch(r, entries, proof);
        vm.expectRevert(EEZ.InvalidProof.selector);
        rollups.postAndVerifyBatch(batch);
    }
}
