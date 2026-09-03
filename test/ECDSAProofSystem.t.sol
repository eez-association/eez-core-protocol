// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {ECDSAProofSystem} from "../src/proofSystems/ECDSAProofSystem.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EEZ, ProofSystemBatchPerVerificationEntries} from "../src/EEZ.sol";
import {ExecutionEntry, StaticExecutionEntry} from "../src/interfaces/IEEZ.sol";

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

    function test_Verify_ValidSignature() public view {
        bytes32 message = keccak256("test message");
        bytes memory proof = _sign(SIGNER_PK, message);
        assertTrue(verifier.verify(proof, message));
    }

    function test_Verify_WrongSigner() public view {
        bytes32 message = keccak256("test message");
        uint256 wrongPk = 0xBAD;
        bytes memory proof = _sign(wrongPk, message);
        assertFalse(verifier.verify(proof, message));
    }

    function test_SetSigner_ByOwner() public {
        address newSigner = address(0x1234);
        vm.prank(owner);
        verifier.setSigner(newSigner);
        assertEq(verifier.signer(), newSigner);
    }

    function test_SetSigner_ByNonOwnerReverts() public {
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
    ///      we build below. The batch leaves `blockNumber == 0`, so the reference `Rollup`
    ///      manager returns an empty `customData` blob, folded into the shared public input.
    function _computePublicInputsHash(
        ExecutionEntry[] memory entries,
        StaticExecutionEntry[] memory staticEntries,
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
        bytes32[] memory staticEntryHashes = new bytes32[](staticEntries.length);
        for (uint256 i = 0; i < staticEntries.length; i++) {
            staticEntryHashes[i] = keccak256(abi.encode(staticEntries[i]));
        }
        bytes32[] memory blobHashes = new bytes32[](0);

        // Mirror `_verifyProofSystemBatch`: per-rollup customData hashed as an array.
        bytes32[] memory customDataHashes = new bytes32[](1);
        customDataHashes[0] = keccak256(abi.encode(uint64(rid), bytes("")));
        bytes32 sharedPublicInput = keccak256(
            abi.encodePacked(
                abi.encode(entryHashes),
                abi.encode(staticEntryHashes),
                abi.encode(blobHashes),
                keccak256(""),
                abi.encode(customDataHashes),
                address(0) // batches here are not submitter-bound (`bindMsgSenderInPublicInput = false`)
            )
        );

        bytes32 acc = bytes32(0);
        acc = keccak256(abi.encode(acc, rid, vk));

        return keccak256(abi.encodePacked(sharedPublicInput, acc));
    }

    function _makeECDSARollup(bytes32 initialRoot, bytes32 vk) internal returns (RollupHandle memory) {
        address[] memory psList = new address[](1);
        psList[0] = address(verifier);
        bytes32[] memory vks = new bytes32[](1);
        vks[0] = vk;
        return _makeRollupCustom(initialRoot, psList, vks, 1, defaultOwner);
    }

    /// @notice Single-batch wrapper over `Base._raw` swapping the default `ps` for the ECDSA
    ///         `verifier` and its signed `proof`; the one entry is immediate.
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
        batch = _raw(entries, _emptyStaticEntries(), psList, proofs, _rpsOne(r.id, 1), 1, 0);
    }

    function test_PostAndVerifyBatch_WithECDSAVerifier() public {
        bytes32 initialRoot = keccak256("initial");
        bytes32 newRoot = keccak256("new");
        bytes32 vk = keccak256("vk");

        RollupHandle memory r = _makeECDSARollup(initialRoot, vk);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, initialRoot, newRoot);

        bytes32 publicInputsHash = _computePublicInputsHash(entries, _emptyStaticEntries(), r.id, vk);
        bytes memory proof = _sign(SIGNER_PK, publicInputsHash);

        rollups.postAndVerifyBatch(_buildECDSABatch(r, entries, proof));

        assertEq(_getRollupState(r.id), newRoot);
    }

    function test_PostAndVerifyBatch_WrongSignerReverts() public {
        bytes32 initialRoot = keccak256("initial");
        bytes32 newRoot = keccak256("new");
        bytes32 vk = keccak256("vk");

        RollupHandle memory r = _makeECDSARollup(initialRoot, vk);

        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = _immediateEntry(r.id, initialRoot, newRoot);

        bytes32 publicInputsHash = _computePublicInputsHash(entries, _emptyStaticEntries(), r.id, vk);
        bytes memory proof = _sign(0xBAD, publicInputsHash);

        ProofSystemBatchPerVerificationEntries memory batch = _buildECDSABatch(r, entries, proof);
        vm.expectRevert(EEZ.InvalidProof.selector);
        rollups.postAndVerifyBatch(batch);
    }
}
