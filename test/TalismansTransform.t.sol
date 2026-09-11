// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Talismans} from "../src/Talismans.sol";
import {TokenState} from "../src/ITalismanTransformationSimulator.sol";
import {
    TalismanTransformationSimulator,
    ITalismansTransformationView
} from "../src/TalismanTransformationSimulator.sol";
import {
    CutRejectsMythic,
    InvalidCutIndex,
    MergeExceedsTier,
    MergeRejectsMythic,
    MergeRequiresSameKind
} from "../src/TalismanErrors.sol";
import {TalismanCore} from "../src/TalismanCore.sol";
import {TalismanForms} from "../src/TalismanForms.sol";
import {TalismanMaterials, NON_MYTHIC_MATERIAL_COUNT} from "../src/TalismanMaterials.sol";
import {TalismanMetadataRenderer} from "../src/TalismanMetadataRenderer.sol";
import {TalismanGenerator} from "../src/TalismanGenerator.sol";
import {TalismanSvgRenderer} from "../src/TalismanSvgRenderer.sol";
import {TalismanLiteHtmlRenderer} from "../src/TalismanLiteHtmlRenderer.sol";
import {LibString} from "solady/utils/LibString.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Transformations spec — bond / cleave / cut / merge
/// @notice Documents the burn-and-mint model in executable form:
///
///         • Every op burns its inputs and mints its outputs.
///         • Output ids are resolved from the *ordered* core sequence via a
///           global mapping, so a token's cores (hence its id and art) never
///           change once minted — that is why ops emit no MetadataUpdate.
///         • Every op's outputs mint to the input owner — bond/merge are
///           dual-input and require both inputs to share that one owner; cut/
///           cleave are single-input. An approved caller may trigger any op,
///           but never receives the result.
///         • Inverse pairs round-trip exactly: bond⇄cleave, cut⇄merge.
///         • The two op pairs toggle independently and have no owner bypass.
///         • Genesis is capped at MAX_GENESIS_SUPPLY; transformations mint freely past
///           it from the same shared id counter.
/// @dev The test contract is the authorised minter and enables all ops in
///      setUp. {_reveal} crafts a token of an exact (pole, core-count) by
///      mint+reveal retries; the production contract has no test-only mutators.
contract TalismansTransformTest is Test {
    Talismans internal nft;
    TalismanMaterials internal mats;
    TalismanMetadataRenderer internal renderer;
    TalismanTransformationSimulator internal simulator;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    // Local copies of the transformation events for vm.expectEmit matching.
    event Bonded(uint256 indexed tokenIdA, uint256 indexed tokenIdB, uint256 indexed bondedId, address operator);
    event Cleaved(uint256 indexed tokenId, uint256 indexed lithicId, uint256 indexed lumicId, address operator);
    event Cut(uint256 indexed tokenId, uint256 indexed headId, uint256 indexed tailId, uint256 index, address operator);
    event Merged(uint256 indexed tokenIdA, uint256 indexed tokenIdB, uint256 indexed mergedId, address operator);
    event TransformationSettingsFrozen();

    function setUp() public {
        nft = new Talismans();
        nft.setMinter(address(this));
        mats = new TalismanMaterials();
        nft.setMaterials(mats);
        renderer = new TalismanMetadataRenderer(
            mats, new TalismanGenerator(), new TalismanSvgRenderer(), new TalismanLiteHtmlRenderer()
        );
        nft.setRenderer(renderer);
        simulator = new TalismanTransformationSimulator(ITalismansTransformationView(address(nft)));
        nft.setTransformationSettings(true, true); // both pairs on
        vm.roll(100);
        vm.prevrandao(bytes32(uint256(0xc0ffee)));
    }

    // ─── crafting helpers ──────────────────────────────────────────────────────

    /// @dev Mint+reveal to `to` until the token has exactly `want` cores AND the
    ///      requested pole. Returns the id; strays stay owned by `to`.
    function _reveal(address to, bool wantLithic, uint256 want) internal returns (uint256 id) {
        for (uint256 attempt; attempt < 4096; ++attempt) {
            uint256 commitBlock;
            (id, commitBlock) = nft.mintWithCommitment(to);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("tx", to, wantLithic, want, attempt)))));
            nft.reveal(id);
            if (nft.coreCount(id) != want) {
                continue;
            }
            (TalismanMaterials.Essence essence,) = mats.elementOf(TalismanCore.materialId(nft.coresOf(id)[0]));
            if ((essence == TalismanMaterials.Essence.Lithic) == wantLithic) {
                return id;
            }
        }
        revert("could not produce desired (pole, core count)");
    }

    /// @dev Mint+reveal to `to` until the token has exactly `want` cores AND its
    ///      shared material id equals `material`. Used to craft same-kind tokens
    ///      for merge tests (homogeneous tokens derive their material from the
    ///      per-core material).
    function _revealOfMaterial(address to, uint8 material, uint256 want) internal returns (uint256 id) {
        for (uint256 attempt; attempt < 8192; ++attempt) {
            uint256 commitBlock;
            (id, commitBlock) = nft.mintWithCommitment(to);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("mat", to, material, want, attempt)))));
            nft.reveal(id);
            if (nft.coreCount(id) == want && nft.coreMaterialId(id) == material) {
                return id;
            }
        }
        revert("could not produce desired (material, core count)");
    }

    /// @dev Like {_revealOfMaterial} but also pins the shape form, so two
    ///      crafted tokens are guaranteed same-kind (material AND form).
    function _revealOfKind(address to, uint8 material, uint8 form, uint256 want) internal returns (uint256 id) {
        for (uint256 attempt; attempt < 16384; ++attempt) {
            uint256 commitBlock;
            (id, commitBlock) = nft.mintWithCommitment(to);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("kind", to, material, form, want, attempt)))));
            nft.reveal(id);
            if (nft.coreCount(id) == want && nft.coreMaterialId(id) == material && uint8(nft.coreShapeForm(id)) == form)
            {
                return id;
            }
        }
        revert("could not produce desired (material, form, core count)");
    }

    function _bond(uint256 a, uint256 b) internal returns (uint256) {
        vm.prank(alice);
        return nft.bond(a, b);
    }

    // ─── bond ───────────────────────────────────────────────────────────────────

    function test_bond_burnsBothInputs_mintsResolvedId() public {
        uint256 a = _reveal(alice, true, 1);
        uint256 b = _reveal(alice, false, 1);

        // Predict the resolved id from the ordered cores before bonding.
        uint256[] memory combined = _concat(nft.coresOf(a), nft.coresOf(b));
        uint256 predicted = nft.nextTransformId();

        uint256 bonded = _bond(a, b);

        assertEq(bonded, predicted, "fresh sequence claims the next id");
        assertEq(nft.tokenIdForCores(combined), bonded, "cores recorded against bonded id");
        assertEq(nft.coreCount(a), 0, "input a burned");
        assertEq(nft.coreCount(b), 0, "input b burned");
        assertEq(nft.ownerOf(bonded), alice);
    }

    /// @dev Round-trip: bond then cleave returns the SAME two original ids with
    ///      identical cores — the keystone of the burn-and-mint id model.
    function test_cleaveOfBond_restoresExactOriginalIds() public {
        uint256 a = _reveal(alice, true, 2);
        uint256 b = _reveal(alice, false, 2);
        uint256[] memory aCores = nft.coresOf(a);
        uint256[] memory bCores = nft.coresOf(b);

        uint256 bonded = _bond(a, b);
        vm.prank(alice);
        (uint256 lithicId, uint256 lumicId) = nft.cleave(bonded);

        assertEq(lithicId, a);
        assertEq(lumicId, b);
        _assertCoresEq(nft.coresOf(lithicId), aCores);
        _assertCoresEq(nft.coresOf(lumicId), bCores);
    }

    /// @dev tokensOfOwner tracks across a bond→cleave round-trip: bond burns the
    ///      two inputs (removed from the set) and mints the bonded id (added);
    ///      cleave then burns the bonded id and RE-MINTS the two original
    ///      content-addressed ids. Confirms the per-owner set's remove/add stays
    ///      consistent when an id is burned and later re-minted.
    function test_tokensOfOwner_tracksBondThenCleaveRoundTrip() public {
        uint256 a = _reveal(alice, true, 2);
        uint256 b = _reveal(alice, false, 2);
        // The mint+reveal retry loop leaves strays owned by alice, so assert on
        // deltas and membership rather than absolute length.
        uint256 baseline = nft.tokensOfOwner(alice).length;
        assertTrue(_contains(nft.tokensOfOwner(alice), a));
        assertTrue(_contains(nft.tokensOfOwner(alice), b));

        uint256 bonded = _bond(a, b);
        uint256[] memory afterBond = nft.tokensOfOwner(alice);
        assertEq(afterBond.length, baseline - 1, "two inputs burned, one bonded minted");
        assertTrue(_contains(afterBond, bonded));
        assertFalse(_contains(afterBond, a), "input a left the set on burn");
        assertFalse(_contains(afterBond, b), "input b left the set on burn");

        vm.prank(alice);
        nft.cleave(bonded);
        uint256[] memory afterCleave = nft.tokensOfOwner(alice);
        assertEq(afterCleave.length, baseline, "bonded burned, two originals re-minted");
        assertTrue(_contains(afterCleave, a), "id a re-minted into the set");
        assertTrue(_contains(afterCleave, b), "id b re-minted into the set");
        assertFalse(_contains(afterCleave, bonded), "bonded id left the set on burn");
    }

    function _contains(uint256[] memory ids, uint256 v) internal pure returns (bool) {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == v) {
                return true;
            }
        }
        return false;
    }

    /// @dev Mirror of {test_cleaveOfBond_restoresExactOriginalIds} with the
    ///      argument order flipped: the Lumic token comes FIRST, so the combined
    ///      sequence is `lumicCores ++ lithicCores`. cleave partitions by essence
    ///      (Lithic cores first, Lumic second) regardless of bond order, so it
    ///      must still restore BOTH original ids with their exact ordered cores.
    ///      This locks in the pole-split direction the Lithic-first test misses.
    function test_cleaveOfBond_lumicFirst_restoresExactOriginalIds() public {
        uint256 lithic = _reveal(alice, true, 2);
        uint256 lumic = _reveal(alice, false, 2);
        uint256[] memory lithicCores = nft.coresOf(lithic);
        uint256[] memory lumicCores = nft.coresOf(lumic);

        // Bond with the Lumic token first: combined = lumicCores ++ lithicCores.
        uint256 bonded = _bond(lumic, lithic);

        vm.prank(alice);
        (uint256 lithicId, uint256 lumicId) = nft.cleave(bonded);

        assertEq(lithicId, lithic, "cleave restores the original lithic id");
        assertEq(lumicId, lumic, "cleave restores the original lumic id");
        _assertCoresEq(nft.coresOf(lithicId), lithicCores);
        _assertCoresEq(nft.coresOf(lumicId), lumicCores);
    }

    /// @dev Concatenation order is significant: bond(A,B) and bond(B,A) fold the
    ///      cores in a different order and therefore resolve to different ids.
    function test_bond_orderSensitive_distinctIds() public {
        uint256 a = _reveal(alice, true, 1);
        uint256 b = _reveal(alice, false, 1);

        uint256 ab = _bond(a, b);
        // Cleave back so a and b exist again for the reverse bond.
        vm.prank(alice);
        nft.cleave(ab);

        uint256 ba = _bond(b, a);
        assertTrue(ab != ba, "bond(A,B) and bond(B,A) must differ");
    }

    // ─── cut ─────────────────────────────────────────────────────────────────────

    function test_cut_splitsAtIndex_preservesMaterialAndForm() public {
        uint256 id = _reveal(alice, true, 3);
        uint8 mat = nft.coreMaterialId(id);
        TalismanForms.ShapeForm form = nft.coreShapeForm(id);
        uint256[] memory cores = nft.coresOf(id);

        vm.prank(alice);
        (uint256 headId, uint256 tailId) = nft.cut(id, 1);

        assertEq(nft.coreCount(headId), 1);
        assertEq(nft.coreCount(tailId), 2);
        assertEq(nft.coreMaterialId(headId), mat, "head keeps material");
        assertEq(nft.coreMaterialId(tailId), mat, "tail keeps material");
        assertEq(uint8(nft.coreShapeForm(headId)), uint8(form));
        assertEq(uint8(nft.coreShapeForm(tailId)), uint8(form));
        assertEq(nft.coresOf(headId)[0], cores[0]);
        assertEq(nft.coresOf(tailId)[0], cores[1]);
        assertEq(nft.coresOf(tailId)[1], cores[2]);
    }

    function test_cut_revertsOnMythic() public {
        uint256 a = _reveal(alice, true, 1);
        uint256 b = _reveal(alice, false, 1);
        uint256 bonded = _bond(a, b);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CutRejectsMythic.selector, bonded));
        nft.cut(bonded, 1);
    }

    function test_cut_revertsOnInvalidIndex() public {
        uint256 id = _reveal(alice, true, 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidCutIndex.selector, uint256(0), uint256(2)));
        nft.cut(id, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidCutIndex.selector, uint256(2), uint256(2)));
        nft.cut(id, 2);
    }

    function test_cut_acceptsHomogeneousRejectsHeterogeneous() public {
        // Cut requires every core to share material AND form (an intra-material
        // split). The only heterogeneous token reachable in this system is a
        // Mythic (spans two materials), which is rejected via CutRejectsMythic
        // (see test_cut_revertsOnMythic). A non-Mythic token is always
        // homogeneous by construction — mint draws one material+form per token —
        // so the TokenNotCuttable branch guards a defensively-unreachable state.
        // Here we pin the positive side: a homogeneous token cuts cleanly.
        uint256 id = _reveal(alice, true, 2);
        vm.prank(alice);
        (uint256 headId, uint256 tailId) = nft.cut(id, 1);
        assertEq(nft.coreCount(headId), 1);
        assertEq(nft.coreCount(tailId), 1);
    }

    function test_cut_singleCore_revertsInvalidIndex() public {
        // A 1-core token has no valid interior cut index.
        uint256 id = _reveal(alice, true, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidCutIndex.selector, uint256(1), uint256(1)));
        nft.cut(id, 1);
    }

    // ─── merge ─────────────────────────────────────────────────────────────────

    function test_mergeOfCut_restoresExactOriginalId() public {
        uint256 id = _reveal(alice, true, 3);
        uint256[] memory cores = nft.coresOf(id);

        vm.prank(alice);
        (uint256 headId, uint256 tailId) = nft.cut(id, 1);

        vm.prank(alice);
        uint256 merged = nft.merge(headId, tailId);
        assertEq(merged, id, "cut then merge in order restores the original id");
        _assertCoresEq(nft.coresOf(merged), cores);
    }

    function test_merge_strictGate_rejectsDifferentMaterialOrForm() public {
        // Two single-core tokens of distinct materials cannot merge.
        uint256 m0 = _revealOfMaterial(alice, 0, 1);
        uint256 m1 = _revealOfMaterial(alice, 1, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MergeRequiresSameKind.selector, m0, m1));
        nft.merge(m0, m1);
    }

    function test_merge_rejectsMythic() public {
        // A Mythic input is rejected up front, before any same-kind check, so
        // the second input just needs to be any revealed non-Mythic token.
        uint256 a = _reveal(alice, true, 1);
        uint256 b = _reveal(alice, false, 1);
        uint256 bonded = _bond(a, b);
        uint256 other = _reveal(alice, true, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MergeRejectsMythic.selector, bonded));
        nft.merge(bonded, other);
    }

    function test_merge_exceedsTierCap() public {
        // 3 + 2 = 5 cores > MAX_CORES_PER_MINT (4) for two same-kind tokens.
        // Craft `a` freely, then craft `b` matching its (material, form) so the
        // kind gate passes and the tier-cap gate is the one that fires.
        uint256 a = _reveal(alice, true, 3);
        uint256 b = _revealOfKind(alice, nft.coreMaterialId(a), uint8(nft.coreShapeForm(a)), 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MergeExceedsTier.selector, uint256(5)));
        nft.merge(a, b);
    }

    function test_merge_revertsWhenDisabled() public {
        uint256 id = _reveal(alice, true, 2);
        vm.prank(alice);
        (uint256 headId, uint256 tailId) = nft.cut(id, 1);
        nft.setTransformationSettings(true, false); // cut/merge off
        vm.prank(alice);
        vm.expectRevert(Talismans.TransformationDisabled.selector);
        nft.merge(headId, tailId);
    }

    /// @dev A transformation operator may run the merge, but the result mints to
    ///      the token owner — never to the operator.
    function test_merge_transformOperator_mintsToOwnerNotOperator() public {
        uint256 id = _reveal(alice, true, 2);
        vm.prank(alice);
        (uint256 headId, uint256 tailId) = nft.cut(id, 1);
        vm.prank(alice);
        nft.setTransformationApprovalForAll(bob, true);
        vm.prank(bob);
        uint256 merged = nft.merge(headId, tailId);
        assertEq(nft.ownerOf(merged), alice, "merge output mints to the owner, not the transformation operator");
    }

    /// @dev Cross-owner merges revert even when the caller is authorised on both
    ///      inputs — minting one owner's token into a result held by another
    ///      would be ambiguous, so a single owner is required. The owner gate
    ///      fires before the same-kind gate, so the inputs need not be same-kind
    ///      to exercise it.
    function test_merge_revertsOnCrossOwnerEvenWhenAuthorized() public {
        uint256 a = _reveal(alice, true, 1);
        uint256 b = _reveal(bob, true, 1);
        vm.prank(alice);
        nft.setTransformationApprovalForAll(bob, true); // bob authorised on a (alice's) and owns b
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Talismans.MergeRequiresSameOwner.selector, a, b));
        nft.merge(a, b);
    }

    // ─── conservation & supply ───────────────────────────────────────────────────

    function test_conservation() public {
        // Sum of coreCounts before == after for each op.
        // bond
        uint256 a = _reveal(alice, true, 2);
        uint256 b = _reveal(alice, false, 2);
        uint256 before = nft.coreCount(a) + nft.coreCount(b);
        uint256 bonded = _bond(a, b);
        assertEq(nft.coreCount(bonded), before, "bond conserves cores");
        // cleave
        vm.prank(alice);
        (uint256 lithicId, uint256 lumicId) = nft.cleave(bonded);
        assertEq(nft.coreCount(lithicId) + nft.coreCount(lumicId), before, "cleave conserves cores");
        // cut
        uint256 c = _reveal(alice, true, 3);
        uint256 cBefore = nft.coreCount(c);
        vm.prank(alice);
        (uint256 headId, uint256 tailId) = nft.cut(c, 1);
        assertEq(nft.coreCount(headId) + nft.coreCount(tailId), cBefore, "cut conserves cores");
        // merge
        vm.prank(alice);
        uint256 merged = nft.merge(headId, tailId);
        assertEq(nft.coreCount(merged), cBefore, "merge conserves cores");
    }

    function test_supply_pm1() public {
        // bond/merge: totalSupply -1; cut/cleave: +1.
        uint256 a = _reveal(alice, true, 2);
        uint256 b = _reveal(alice, false, 2);
        uint256 s0 = nft.totalSupply();
        uint256 bonded = _bond(a, b);
        assertEq(nft.totalSupply(), s0 - 1, "bond is -1");

        uint256 s1 = nft.totalSupply();
        vm.prank(alice);
        nft.cleave(bonded);
        assertEq(nft.totalSupply(), s1 + 1, "cleave is +1");

        uint256 c = _reveal(alice, true, 2);
        uint256 s2 = nft.totalSupply();
        vm.prank(alice);
        (uint256 headId, uint256 tailId) = nft.cut(c, 1);
        assertEq(nft.totalSupply(), s2 + 1, "cut is +1");

        uint256 s3 = nft.totalSupply();
        vm.prank(alice);
        nft.merge(headId, tailId);
        assertEq(nft.totalSupply(), s3 - 1, "merge is -1");
    }

    // ─── toggles ─────────────────────────────────────────────────────────────────

    function test_transformationsDisabledByDefault_revert() public {
        // Fresh contract: no transformation setting enabled.
        Talismans fresh = new Talismans();
        fresh.setMinter(address(this));
        fresh.setMaterials(mats);
        (uint256 id, uint256 cb) = fresh.mintWithCommitment(alice);
        vm.roll(cb + 1);
        fresh.reveal(id);
        (uint256 id2, uint256 cb2) = fresh.mintWithCommitment(alice);
        vm.roll(cb2 + 1);
        fresh.reveal(id2);

        vm.startPrank(alice);
        vm.expectRevert(Talismans.TransformationDisabled.selector);
        fresh.bond(id, id2);
        vm.expectRevert(Talismans.TransformationDisabled.selector);
        fresh.cleave(id);
        vm.expectRevert(Talismans.TransformationDisabled.selector);
        fresh.cut(id, 1);
        vm.expectRevert(Talismans.TransformationDisabled.selector);
        fresh.merge(id, id2);
        vm.stopPrank();
    }

    function test_setTransformationSettings_perPairToggle() public {
        // Enabling only bond/cleave still reverts cut/merge, and vice versa.
        // No owner bypass: this contract IS the owner and still reverts.
        nft.setTransformationSettings(true, false);
        assertTrue(nft.bondAndCleaveEnabled());
        assertFalse(nft.cutAndMergeEnabled());
        uint256 id = _reveal(alice, true, 2);
        vm.prank(alice);
        vm.expectRevert(Talismans.TransformationDisabled.selector);
        nft.cut(id, 1);

        nft.setTransformationSettings(false, true);
        assertFalse(nft.bondAndCleaveEnabled());
        assertTrue(nft.cutAndMergeEnabled());
        uint256 a = _reveal(alice, true, 1);
        uint256 b = _reveal(alice, false, 1);
        vm.prank(alice);
        vm.expectRevert(Talismans.TransformationDisabled.selector);
        nft.bond(a, b);
    }

    // ─── freeze: the one-way Stage 2 lock ─────────────────────────────────────────
    //
    // Rollout is staged: Stage 0 both pairs off, Stage 1 the owner toggles them
    // (and can revert), Stage 2 the owner freezes the toggles forever. Freeze is
    // irreversible and captures whatever on/off state the toggles hold.

    function test_transformationSettingsFrozen_defaultsFalse() public view {
        assertFalse(nft.transformationSettingsFrozen());
    }

    /// @dev Once frozen, setTransformationSettings always reverts and the
    ///      toggles keep their frozen-in state — the owner can no longer flip
    ///      a pair. setUp left both pairs enabled, so this freezes them on.
    function test_freeze_locksTogglesPermanently() public {
        nft.freezeTransformationSettings();
        assertTrue(nft.transformationSettingsFrozen());
        assertTrue(nft.bondAndCleaveEnabled());
        assertTrue(nft.cutAndMergeEnabled());

        // Even the owner (this contract) can no longer change them.
        vm.expectRevert(Talismans.TransformationSettingsAreFrozen.selector);
        nft.setTransformationSettings(false, false);
        assertTrue(nft.bondAndCleaveEnabled());
        assertTrue(nft.cutAndMergeEnabled());
    }

    /// @dev Freezing changes nothing for callers: a pair enabled at freeze stays
    ///      callable — now permanently and ungated.
    function test_freeze_transformsStillCallable() public {
        uint256 a = _reveal(alice, true, 1);
        uint256 b = _reveal(alice, false, 1);
        nft.freezeTransformationSettings();
        vm.prank(alice);
        uint256 bonded = nft.bond(a, b);
        assertEq(nft.coreCount(bonded), 2);
    }

    /// @dev Freeze captures the OFF state too: a pair frozen while disabled stays
    ///      off forever and can never be turned on. This is a frozen Stage 0.
    function test_freeze_capturesDisabledState() public {
        nft.setTransformationSettings(false, false);
        nft.freezeTransformationSettings();

        uint256 a = _reveal(alice, true, 1);
        uint256 b = _reveal(alice, false, 1);
        vm.prank(alice);
        vm.expectRevert(Talismans.TransformationDisabled.selector);
        nft.bond(a, b);

        // ...and it can never be re-enabled.
        vm.expectRevert(Talismans.TransformationSettingsAreFrozen.selector);
        nft.setTransformationSettings(true, true);
    }

    function test_freeze_revertsWhenAlreadyFrozen() public {
        nft.freezeTransformationSettings();
        vm.expectRevert(Talismans.TransformationSettingsAreFrozen.selector);
        nft.freezeTransformationSettings();
    }

    function test_freeze_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.freezeTransformationSettings();
    }

    function test_freeze_emitsEventOnce() public {
        vm.expectEmit(false, false, false, false);
        emit TransformationSettingsFrozen();
        nft.freezeTransformationSettings();
    }

    // ─── genesis cap & id counter ────────────────────────────────────────────────

    function test_genesisCap_1536() public {
        assertEq(nft.MAX_GENESIS_SUPPLY(), 1536);
    }

    /// @dev Transformation outputs draw from a separate counter that starts one
    ///      past the genesis range, so a fresh transform id never lands in the
    ///      genesis id space — even while the genesis sale is still open.
    function test_transformId_startsPastGenesisRange_whenTransformingDuringMint() public {
        uint256 id = _reveal(alice, true, 2); // one genesis token (plus reveal retries)
        assertTrue(nft.isGenesis(id), "genesis input sits in the genesis range");

        uint256 genesisBefore = nft.genesisMinted();
        uint256 nextBefore = nft.nextTransformId();
        assertEq(nextBefore, nft.MAX_GENESIS_SUPPLY() + 1, "transform ids start past the genesis cap");

        vm.prank(alice);
        (uint256 head, uint256 tail) = nft.cut(id, 1); // two outputs → next advances by 2

        assertEq(nft.nextTransformId(), nextBefore + 2, "cut claims two fresh transform ids");
        assertEq(nft.genesisMinted(), genesisBefore, "cut does not count as genesis");
        assertFalse(nft.isGenesis(head), "transform output is not genesis");
        assertFalse(nft.isGenesis(tail), "transform output is not genesis");
        assertGt(head, nft.MAX_GENESIS_SUPPLY(), "transform id sits above the genesis range");
        assertGt(tail, nft.MAX_GENESIS_SUPPLY(), "transform id sits above the genesis range");
    }

    // ─── simulate: raw svg + html, no base64 ─────────────────────────────────────

    function test_simulate_returnsRawSvgAndHtml_noBase64_bond() public {
        uint256 a = _reveal(alice, true, 2);
        uint256 b = _reveal(alice, false, 2);
        TokenState memory sim = simulator.simulateBond(a, b);
        _assertRaw(sim);

        // Compare to the real op's resulting on-chain state.
        uint256 bonded = _bond(a, b);
        assertEq(sim.tokenId, bonded);
        assertEq(sim.materialId, nft.coreMaterialId(bonded));
        assertEq(uint8(sim.form), uint8(nft.coreShapeForm(bonded)));
        assertEq(sim.coreCount, uint8(nft.coreCount(bonded)));
        assertEq(sim.seed, nft.coreSeed(bonded));
        _assertCoresEq(sim.cores, nft.coresOf(bonded));
    }

    function test_simulate_returnsRawSvgAndHtml_noBase64_cut() public {
        uint256 id = _reveal(alice, true, 3);
        (TokenState memory head, TokenState memory tail) = simulator.simulateCut(id, 1);
        _assertRaw(head);
        _assertRaw(tail);

        vm.prank(alice);
        (uint256 headId, uint256 tailId) = nft.cut(id, 1);
        assertEq(head.tokenId, headId);
        assertEq(tail.tokenId, tailId);
        _assertCoresEq(head.cores, nft.coresOf(headId));
        _assertCoresEq(tail.cores, nft.coresOf(tailId));
        assertEq(head.materialId, nft.coreMaterialId(headId));
        assertEq(tail.seed, nft.coreSeed(tailId));
    }

    function test_simulate_returnsRawSvgAndHtml_noBase64_cleave() public {
        uint256 a = _reveal(alice, true, 2);
        uint256 b = _reveal(alice, false, 2);
        uint256 bonded = _bond(a, b);
        (TokenState memory lithic, TokenState memory lumic) = simulator.simulateCleave(bonded);
        _assertRaw(lithic);
        _assertRaw(lumic);
        assertEq(lithic.tokenId, a);
        assertEq(lumic.tokenId, b);
    }

    function test_simulate_returnsRawSvgAndHtml_noBase64_merge() public {
        uint256 id = _reveal(alice, true, 3);
        vm.prank(alice);
        (uint256 headId, uint256 tailId) = nft.cut(id, 1);
        TokenState memory sim = simulator.simulateMerge(headId, tailId);
        _assertRaw(sim);
        assertEq(sim.tokenId, id, "merge sim predicts the restored original id");
    }

    // ─── no MetadataUpdate on transforms ─────────────────────────────────────────

    function test_noMetadataUpdateOnTransform() public {
        uint256 a = _reveal(alice, true, 2);
        uint256 b = _reveal(alice, false, 2);

        vm.recordLogs();
        uint256 bonded = _bond(a, b);
        _assertNoMetadataUpdate();

        vm.recordLogs();
        vm.prank(alice);
        nft.cleave(bonded);
        _assertNoMetadataUpdate();

        uint256 c = _reveal(alice, true, 2);
        vm.recordLogs();
        vm.prank(alice);
        (uint256 headId, uint256 tailId) = nft.cut(c, 1);
        _assertNoMetadataUpdate();

        vm.recordLogs();
        vm.prank(alice);
        nft.merge(headId, tailId);
        _assertNoMetadataUpdate();
    }

    // ─── transformation events ──────────────────────────────────────────────────
    //
    // Each op emits a custom event correlating its burned inputs with its minted
    // outputs — a link the raw ERC-721 Transfers can't carry. Output ids are
    // predicted via the matching simulate* view (its purpose), then matched
    // exactly with vm.expectEmit (all topics + data).

    function test_bond_emitsBondedEvent() public {
        uint256 a = _reveal(alice, true, 1);
        uint256 b = _reveal(alice, false, 1);
        TokenState memory r = simulator.simulateBond(a, b);

        vm.expectEmit(true, true, true, true, address(nft));
        emit Bonded(a, b, r.tokenId, alice);
        vm.prank(alice);
        nft.bond(a, b);
    }

    function test_cleave_emitsCleavedEvent() public {
        uint256 a = _reveal(alice, true, 2);
        uint256 b = _reveal(alice, false, 2);
        uint256 bonded = _bond(a, b);

        (TokenState memory lithic, TokenState memory lumic) = simulator.simulateCleave(bonded);

        vm.expectEmit(true, true, true, true, address(nft));
        emit Cleaved(bonded, lithic.tokenId, lumic.tokenId, alice);
        vm.prank(alice);
        nft.cleave(bonded);
    }

    function test_cut_emitsCutEvent() public {
        uint256 id = _reveal(alice, true, 2); // homogeneous 2-core token cuts at 1
        (TokenState memory head, TokenState memory tail) = simulator.simulateCut(id, 1);

        vm.expectEmit(true, true, true, true, address(nft));
        emit Cut(id, head.tokenId, tail.tokenId, 1, alice);
        vm.prank(alice);
        nft.cut(id, 1);
    }

    function test_merge_emitsMergedEvent() public {
        // Cutting a homogeneous token yields two same-kind halves to merge back.
        uint256 id = _reveal(alice, true, 2);
        vm.prank(alice);
        (uint256 headId, uint256 tailId) = nft.cut(id, 1);
        TokenState memory r = simulator.simulateMerge(headId, tailId);

        vm.expectEmit(true, true, true, true, address(nft));
        emit Merged(headId, tailId, r.tokenId, alice);
        vm.prank(alice);
        nft.merge(headId, tailId);
    }

    // ─── internal asserts ──────────────────────────────────────────────────────

    function _assertRaw(TokenState memory s) internal pure {
        assertTrue(LibString.contains(s.image, "<svg"), "image must contain <svg");
        assertFalse(LibString.startsWith(s.image, "data:"), "image must not be a data uri");
        assertTrue(
            LibString.contains(s.html, "<html") || LibString.contains(s.html, "<!DOCTYPE"), "html must be raw html"
        );
        assertFalse(LibString.startsWith(s.html, "data:"), "html must not be a data uri");
    }

    function _assertNoMetadataUpdate() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 metaTopic = IERC4906.MetadataUpdate.selector;
        bytes32 batchTopic = IERC4906.BatchMetadataUpdate.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft)) {
                continue;
            }
            assertTrue(logs[i].topics[0] != metaTopic, "transform must not emit MetadataUpdate");
            assertTrue(logs[i].topics[0] != batchTopic, "transform must not emit BatchMetadataUpdate");
        }
    }

    function _assertCoresEq(uint256[] memory got, uint256[] memory want) internal pure {
        assertEq(got.length, want.length, "core length mismatch");
        for (uint256 i; i < want.length; ++i) {
            assertEq(got[i], want[i], "core mismatch");
        }
    }

    function _concat(uint256[] memory a, uint256[] memory b) internal pure returns (uint256[] memory out) {
        out = new uint256[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            out[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            out[a.length + i] = b[i];
        }
    }
}
