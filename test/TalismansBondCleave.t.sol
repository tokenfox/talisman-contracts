// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Talismans} from "../src/Talismans.sol";
import {
    BondRequiresMatchedCores,
    BondRequiresOppositePoles,
    BondTokenNotRevealed,
    CannotBondSameToken,
    TokenNotCleavable
} from "../src/TalismanErrors.sol";
// {BondRequiresSameOwner} is declared on {Talismans} (it is an authorization
// concern the `simulate*` previews skip), so it is referenced as
// `Talismans.BondRequiresSameOwner` rather than imported from {TalismanErrors}.
import {TalismanCore} from "../src/TalismanCore.sol";
import {TalismanMaterials, NON_MYTHIC_MATERIAL_COUNT} from "../src/TalismanMaterials.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @title Bond & Cleave behaviour spec
/// @notice The reaction the collection is built around, under the burn-and-mint
///         model:
///
///         • BOND fuses one Lithic talisman with one Lumic talisman of the SAME
///           tier (equal core counts) into a Mythic of that same tier. It BURNS
///           BOTH inputs and MINTS a bonded token whose id is resolved from the
///           ordered concatenation of their cores (supply −1).
///         • CLEAVE is the exact inverse: it splits a Mythic back into its two
///           poles, burning the Mythic and reminting the two original ids (cores
///           are globally keyed, so the round-trip restores them) (supply +1).
///
///         These tests double as the readable specification: matched + opposite
///         poles only, tier preserved, ids resolved via the cores mapping,
///         round-trip restores originals.
/// @dev The test contract is the authorised minter and enables bond/cleave in
///      setUp. {_reveal} mints+reveals until a token lands on an exact (pole,
///      core-count), so every reaction is built deterministically.
contract TalismansBondCleaveTest is Test {
    Talismans internal nft;
    TalismanMaterials internal mats;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);

    function setUp() public {
        nft = new Talismans();
        nft.setMinter(address(this));
        mats = new TalismanMaterials();
        nft.setMaterials(mats);
        nft.setTransformationSettings(true, false); // bond/cleave on, cut/merge off
        vm.roll(100);
        vm.prevrandao(bytes32(uint256(0xc0ffee)));
    }

    /// @dev Mint to `to` and reveal repeatedly until the token lands on exactly
    ///      `want` cores AND the requested pole (`wantLithic` ? Lithic : Lumic).
    ///      A token's pole is the essence of its (shared) core material. Discards
    ///      stay owned by `to`; tests reference explicit ids so strays are inert.
    function _reveal(address to, bool wantLithic, uint256 want) internal returns (uint256 id) {
        for (uint256 attempt; attempt < 2048; ++attempt) {
            uint256 commitBlock;
            (id, commitBlock) = nft.mintWithCommitment(to);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("bc", to, wantLithic, want, attempt)))));
            nft.reveal(id);
            if (nft.coreCount(id) != want) {
                continue;
            }
            uint8 mid = TalismanCore.materialId(nft.coresOf(id)[0]);
            (TalismanMaterials.Essence essence,) = mats.elementOf(mid);
            bool isLithic = essence == TalismanMaterials.Essence.Lithic;
            if (isLithic == wantLithic) {
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

    function _isMythicMaterial(uint256 tokenId) internal view returns (bool) {
        // Mythic material ids occupy [NON_MYTHIC_MATERIAL_COUNT, MATERIAL_COUNT).
        return nft.coreMaterialId(tokenId) >= NON_MYTHIC_MATERIAL_COUNT;
    }

    // ─── Bond guards ─────────────────────────────────────────────────────────

    function test_bond_revertsOnSelfBond() public {
        uint256 id = _lithic(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CannotBondSameToken.selector, id));
        nft.bond(id, id);
    }

    function test_bond_revertsForNonexistentA() public {
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(99999)));
        nft.bond(99999, b);
    }

    function test_bond_revertsForNonexistentB() public {
        uint256 a = _lithic(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(99999)));
        nft.bond(a, 99999);
    }

    function test_bond_revertsWhenAUnrevealed() public {
        (uint256 a,) = nft.mintWithCommitment(alice); // 0 cores
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondTokenNotRevealed.selector, a));
        nft.bond(a, b);
    }

    function test_bond_revertsWhenBUnrevealed() public {
        uint256 a = _lithic(alice, 1);
        (uint256 b,) = nft.mintWithCommitment(alice); // 0 cores
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondTokenNotRevealed.selector, b));
        nft.bond(a, b);
    }

    function test_bond_revertsWhenSamePole() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lithic(alice, 1); // matched count, but same pole
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondRequiresOppositePoles.selector, a, b));
        nft.bond(a, b);
    }

    function test_bond_revertsWhenCoreCountsMismatch() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 2); // opposite poles, but unmatched counts
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondRequiresMatchedCores.selector, uint256(1), uint256(2)));
        nft.bond(a, b);
    }

    function test_bond_revertsWhenInputIsAlreadyMythic() public {
        // A bonded Mythic spans both poles, so it can never be a bond input.
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b); // a 2-core Mythic
        uint256 other = _lumic(alice, 2); // matched count, so the pole check is what fires
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondRequiresOppositePoles.selector, bonded, other));
        nft.bond(bonded, other);
    }

    // ─── Bond authorization ────────────────────────────────────────────────────

    function test_bond_succeedsForOwnerOfBoth() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        assertEq(nft.coreCount(bonded), 2);
        assertEq(nft.ownerOf(bonded), alice);
    }

    /// @dev A transformation operator may run the bond, but the Mythic mints to
    ///      the token owner — never to the operator. This is the guarantee that
    ///      a transformation approval can't be used to siphon the bonded output
    ///      away; it can reshape, never take ownership.
    function test_bond_transformOperator_mintsToOwnerNotOperator() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        nft.setTransformationApprovalForAll(bob, true);
        vm.prank(bob);
        uint256 bonded = nft.bond(a, b);
        assertEq(nft.coreCount(bonded), 2);
        assertEq(nft.ownerOf(bonded), alice, "bonded mints to the owner, not the transformation operator");
    }

    /// @dev The separation guarantee: an ERC-721 approval (per-token or
    ///      operator-wide) does NOT authorise a transformation. A holder who
    ///      lists on a marketplace grants transfer rights only — never the power
    ///      to reshape their tokens.
    function test_bond_erc721ApprovalDoesNotAuthorize() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        vm.startPrank(alice);
        nft.approve(bob, a);
        nft.setApprovalForAll(bob, true);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Talismans.TransformationInsufficientApproval.selector, bob, a));
        nft.bond(a, b);
    }

    /// @dev Cross-owner bonds are rejected even when the caller is authorised on
    ///      both inputs. Allowing them would burn one owner's token into a Mythic
    ///      owned by someone else; requiring a single owner keeps the output's
    ///      recipient unambiguous and an approval from ever consolidating two
    ///      owners' tokens.
    function test_bond_revertsOnCrossOwnerEvenWhenAuthorized() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(bob, 1);
        vm.prank(alice);
        nft.setTransformationApprovalForAll(carol, true);
        vm.prank(bob);
        nft.setTransformationApprovalForAll(carol, true);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Talismans.BondRequiresSameOwner.selector, a, b));
        nft.bond(a, b);
    }

    function test_bond_revertsWhenUnauthorizedForA() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(bob, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Talismans.TransformationInsufficientApproval.selector, bob, a));
        nft.bond(a, b);
    }

    function test_bond_revertsWhenUnauthorizedForB() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(bob, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Talismans.TransformationInsufficientApproval.selector, alice, b));
        nft.bond(a, b);
    }

    // ─── Bond mechanics ──────────────────────────────────────────────────────

    function test_bond_concatenatesCoresInOrderAThenB() public {
        uint256 a = _lithic(alice, 2);
        uint256 b = _lumic(alice, 2);
        uint256[] memory aBefore = nft.coresOf(a);
        uint256[] memory bBefore = nft.coresOf(b);

        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);

        uint256[] memory after_ = nft.coresOf(bonded);
        assertEq(after_.length, 4);
        assertEq(after_[0], aBefore[0]);
        assertEq(after_[1], aBefore[1]);
        assertEq(after_[2], bBefore[0]);
        assertEq(after_[3], bBefore[1]);
    }

    function test_bond_burnsBothInputs() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        nft.bond(a, b);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, a));
        nft.ownerOf(a);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, b));
        nft.ownerOf(b);
    }

    function test_bond_producesMythicMaterial() public {
        uint256 a = _lithic(alice, 2);
        uint256 b = _lumic(alice, 2);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        assertTrue(_isMythicMaterial(bonded), "bond of opposite poles must yield a Mythic material");
    }

    function test_bond_decrementsTotalSupplyByOne() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        uint256 supplyBefore = nft.totalSupply();
        vm.prank(alice);
        nft.bond(a, b);
        assertEq(nft.totalSupply(), supplyBefore - 1);
    }

    function test_bond_revertsWhenDisabled() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        nft.setTransformationSettings(false, false);
        vm.prank(alice);
        vm.expectRevert(Talismans.TransformationDisabled.selector);
        nft.bond(a, b);
    }

    // ─── Tier preservation: matched k + k ⇒ Mythic of 2k cores ──────────────────

    function test_bond_tierPreserved_rawPlusRaw() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        assertEq(nft.coreCount(bonded), 2); // Mythic tier Raw (2/2 = 1)
        assertTrue(_isMythicMaterial(bonded));
    }

    function test_bond_tierPreserved_cutPlusCut() public {
        uint256 a = _lithic(alice, 2);
        uint256 b = _lumic(alice, 2);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        assertEq(nft.coreCount(bonded), 4); // Mythic tier Cut
    }

    function test_bond_tierPreserved_finePlusFine() public {
        uint256 a = _lithic(alice, 3);
        uint256 b = _lumic(alice, 3);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        assertEq(nft.coreCount(bonded), 6); // Mythic tier Fine
    }

    function test_bond_tierPreserved_primePlusPrime_reachesEightCores() public {
        uint256 a = _lithic(alice, 4);
        uint256 b = _lumic(alice, 4);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        assertEq(nft.coreCount(bonded), 8); // Mythic tier Prime — only reachable via bond
        assertTrue(_isMythicMaterial(bonded));
    }

    // ─── Cleave guards ─────────────────────────────────────────────────────────

    function test_cleave_revertsWhenNotMythic() public {
        uint256 id = _lithic(alice, 2); // a pure token is not cleavable
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenNotCleavable.selector, id));
        nft.cleave(id);
    }

    function test_cleave_revertsForNonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(99999)));
        nft.cleave(99999);
    }

    function test_cleave_revertsWhenUnauthorized() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Talismans.TransformationInsufficientApproval.selector, bob, bonded));
        nft.cleave(bonded);
    }

    function test_cleave_revertsWhenDisabled() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        nft.setTransformationSettings(false, false);
        vm.prank(alice);
        vm.expectRevert(Talismans.TransformationDisabled.selector);
        nft.cleave(bonded);
    }

    // ─── Cleave mechanics: the exact inverse of bond ────────────────────────────

    function test_cleave_restoresTheOriginalIds() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);

        vm.prank(alice);
        (uint256 lithicId, uint256 lumicId) = nft.cleave(bonded);
        assertEq(lithicId, a, "cleave restores the original lithic id");
        assertEq(lumicId, b, "cleave restores the original lumic id");
        assertEq(nft.ownerOf(a), alice, "reminted to the owner");
        assertEq(nft.ownerOf(b), alice);
    }

    function test_cleave_roundTripRestoresExactCores() public {
        uint256 a = _lithic(alice, 2);
        uint256 b = _lumic(alice, 2);
        uint256[] memory aBefore = nft.coresOf(a);
        uint256[] memory bBefore = nft.coresOf(b);

        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        vm.prank(alice);
        nft.cleave(bonded);

        uint256[] memory aAfter = nft.coresOf(a);
        uint256[] memory bAfter = nft.coresOf(b);
        assertEq(aAfter.length, aBefore.length);
        assertEq(bAfter.length, bBefore.length);
        for (uint256 i; i < aBefore.length; ++i) {
            assertEq(aAfter[i], aBefore[i], "lithic cores restored exactly");
        }
        for (uint256 i; i < bBefore.length; ++i) {
            assertEq(bAfter[i], bBefore[i], "lumic cores restored exactly");
        }
    }

    function test_cleave_burnsTheMythic() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        vm.prank(alice);
        nft.cleave(bonded);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, bonded));
        nft.ownerOf(bonded);
    }

    function test_cleave_splitsByPole() public {
        uint256 a = _lithic(alice, 2);
        uint256 b = _lumic(alice, 2);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        vm.prank(alice);
        (uint256 lithicId, uint256 lumicId) = nft.cleave(bonded);

        (TalismanMaterials.Essence le,) = mats.elementOf(TalismanCore.materialId(nft.coresOf(lithicId)[0]));
        (TalismanMaterials.Essence ue,) = mats.elementOf(TalismanCore.materialId(nft.coresOf(lumicId)[0]));
        assertEq(uint8(le), uint8(TalismanMaterials.Essence.Lithic));
        assertEq(uint8(ue), uint8(TalismanMaterials.Essence.Lumic));
    }

    function test_cleave_incrementsTotalSupplyByOne() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        uint256 supplyBefore = nft.totalSupply();
        vm.prank(alice);
        nft.cleave(bonded);
        assertEq(nft.totalSupply(), supplyBefore + 1);
    }

    function test_cleave_remintsToCurrentOwnerAfterTransfer() public {
        uint256 a = _lithic(alice, 1);
        uint256 b = _lumic(alice, 1);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        // Sell the Mythic to bob; cleave should hand bob both halves.
        vm.prank(alice);
        nft.transferFrom(alice, bob, bonded);
        vm.prank(bob);
        (uint256 lithicId, uint256 lumicId) = nft.cleave(bonded);
        assertEq(nft.ownerOf(lithicId), bob, "halves follow the Mythic's current owner");
        assertEq(nft.ownerOf(lumicId), bob);
    }

    // ─── The loop: bond ⇄ cleave ⇄ bond ────────────────────────────────────────

    function test_loop_bondCleaveBondAgain() public {
        uint256 a = _lithic(alice, 2);
        uint256 b = _lumic(alice, 2);
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        vm.prank(alice);
        nft.cleave(bonded);
        // After cleave both are pure again and on opposite poles — re-bondable,
        // and bonding the same ordered pair restores the same bonded id.
        vm.prank(alice);
        uint256 bonded2 = nft.bond(a, b);
        assertEq(bonded2, bonded, "re-bonding the same pair restores the same id");
        assertEq(nft.coreCount(bonded2), 4);
        assertTrue(_isMythicMaterial(bonded2));
    }
}
