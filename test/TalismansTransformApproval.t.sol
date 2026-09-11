// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Talismans} from "../src/Talismans.sol";
import {ITalismanTransformable} from "../src/ITalismanTransformable.sol";
import {TalismanCore} from "../src/TalismanCore.sol";
import {TalismanMaterials} from "../src/TalismanMaterials.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @title Transformation approval — the separate operator-delegation surface
/// @notice Option 3: transformations gate on a dedicated transformation
///         approval ({setTransformationApprovalForAll}), fully decoupled from
///         ERC-721 transfer approval. These tests pin the decoupling in both
///         directions and the ERC-721-faithful shape of the surface:
///
///         • An ERC-721 approval (per-token or operator-wide) NEVER authorises a
///           transformation — listing on a marketplace can't confer reshape power.
///         • A transformation approval NEVER authorises a transfer — a
///           batch-transform helper can't move or steal a holder's tokens.
///         • A transformation operator may run any op; the output always mints
///           to the owner, never the operator.
contract TalismansTransformApprovalTest is Test {
    Talismans internal nft;
    TalismanMaterials internal mats;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        nft = new Talismans();
        nft.setMinter(address(this));
        mats = new TalismanMaterials();
        nft.setMaterials(mats);
        nft.setTransformationSettings(true, true); // all four transformations on
        vm.roll(100);
        vm.prevrandao(bytes32(uint256(0xc0ffee)));
    }

    // ─── helpers (mint+reveal to an exact pole + core count) ─────────────────────

    function _reveal(address to, bool wantLithic, uint256 want) internal returns (uint256 id) {
        for (uint256 attempt; attempt < 2048; ++attempt) {
            uint256 commitBlock;
            (id, commitBlock) = nft.mintWithCommitment(to);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("ta", to, wantLithic, want, attempt)))));
            nft.reveal(id);
            if (nft.coreCount(id) != want) {
                continue;
            }
            uint8 mid = TalismanCore.materialId(nft.coresOf(id)[0]);
            (TalismanMaterials.Essence essence,) = mats.elementOf(mid);
            if ((essence == TalismanMaterials.Essence.Lithic) == wantLithic) {
                return id;
            }
        }
        revert("could not produce desired (pole, core count)");
    }

    function _lithic(address to, uint256 cores) internal returns (uint256) {
        return _reveal(to, true, cores);
    }

    function _lumic(address to, uint256 cores) internal returns (uint256) {
        return _reveal(to, false, cores);
    }

    function _mythic(address to) internal returns (uint256 bonded) {
        uint256 a = _lithic(to, 1);
        uint256 b = _lumic(to, 1);
        vm.prank(to);
        bonded = nft.bond(a, b);
    }

    // ─── the surface: set / query / revoke / event ──────────────────────────────

    function test_setAndQuery_reflectsState() public {
        assertFalse(nft.isTransformationApprovedForAll(alice, bob), "starts unapproved");
        vm.prank(alice);
        nft.setTransformationApprovalForAll(bob, true);
        assertTrue(nft.isTransformationApprovedForAll(alice, bob), "granted");
    }

    function test_revoke_clearsApproval() public {
        vm.startPrank(alice);
        nft.setTransformationApprovalForAll(bob, true);
        nft.setTransformationApprovalForAll(bob, false);
        vm.stopPrank();
        assertFalse(nft.isTransformationApprovedForAll(alice, bob), "revoked");
    }

    function test_set_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit ITalismanTransformable.TransformationApprovalForAll(alice, bob, true);
        vm.prank(alice);
        nft.setTransformationApprovalForAll(bob, true);
    }

    function test_approvalIsPerOwner_notGlobal() public {
        vm.prank(alice);
        nft.setTransformationApprovalForAll(bob, true);
        // bob is approved for alice's tokens only — not for a third party's.
        assertTrue(nft.isTransformationApprovedForAll(alice, bob));
        assertFalse(nft.isTransformationApprovedForAll(address(0xBEEF), bob));
    }

    // ─── separation A: ERC-721 approval does NOT authorise a transformation ──────

    function test_erc721PerTokenApprove_cannotCleave() public {
        uint256 m = _mythic(alice);
        vm.prank(alice);
        nft.approve(bob, m);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Talismans.TransformationInsufficientApproval.selector, bob, m));
        nft.cleave(m);
    }

    function test_erc721OperatorApproval_cannotCut() public {
        uint256 id = _lithic(alice, 2); // homogeneous 2-core token is cuttable
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Talismans.TransformationInsufficientApproval.selector, bob, id));
        nft.cut(id, 1);
    }

    // ─── separation B: transformation approval does NOT authorise a transfer ─────

    function test_transformApproval_cannotTransfer() public {
        uint256 id = _lithic(alice, 1);
        vm.prank(alice);
        nft.setTransformationApprovalForAll(bob, true);
        // bob may reshape alice's tokens, but the ERC-721 transfer gate is
        // untouched: a transformation operator can never move a token.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, id));
        nft.transferFrom(alice, bob, id);
    }

    // ─── the operator may run any op; the output always lands with the owner ─────

    function test_transformOperator_canCleave_outputToOwner() public {
        uint256 m = _mythic(alice);
        vm.prank(alice);
        nft.setTransformationApprovalForAll(bob, true);
        vm.prank(bob);
        (uint256 lithicId, uint256 lumicId) = nft.cleave(m);
        assertEq(nft.ownerOf(lithicId), alice, "cleave half mints to owner, not operator");
        assertEq(nft.ownerOf(lumicId), alice, "cleave half mints to owner, not operator");
    }

    function test_transformOperator_canCut_outputToOwner() public {
        uint256 id = _lithic(alice, 2);
        vm.prank(alice);
        nft.setTransformationApprovalForAll(bob, true);
        vm.prank(bob);
        (uint256 headId, uint256 tailId) = nft.cut(id, 1);
        assertEq(nft.ownerOf(headId), alice, "cut head mints to owner, not operator");
        assertEq(nft.ownerOf(tailId), alice, "cut tail mints to owner, not operator");
    }

    function test_owner_transformsWithoutAnyApproval() public {
        uint256 m = _mythic(alice);
        vm.prank(alice);
        nft.cleave(m); // owner path needs no approval and must not revert
    }

    function test_revokedOperator_canNoLongerTransform() public {
        uint256 m = _mythic(alice);
        vm.startPrank(alice);
        nft.setTransformationApprovalForAll(bob, true);
        nft.setTransformationApprovalForAll(bob, false);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Talismans.TransformationInsufficientApproval.selector, bob, m));
        nft.cleave(m);
    }

    // ─── ERC-165 advertises the surface ──────────────────────────────────────────

    function test_supportsInterface_advertisesTransformable() public view {
        assertTrue(nft.supportsInterface(type(ITalismanTransformable).interfaceId), "ITalismanTransformable");
        assertTrue(nft.supportsInterface(0x80ac58cd), "ERC-721 still advertised");
        assertFalse(nft.supportsInterface(0xffffffff), "sanity: unknown id unsupported");
    }
}
