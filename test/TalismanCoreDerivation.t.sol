// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Talismans} from "../src/Talismans.sol";
import {TalismanTransformationLib} from "../src/TalismanTransformationLib.sol";
import {TalismanCore} from "../src/TalismanCore.sol";
import {TalismanForms} from "../src/TalismanForms.sol";
import {TalismanMaterials} from "../src/TalismanMaterials.sol";
import {MaterialsNotSet} from "../src/TalismanErrors.sol";

/// @dev Exposes the token-level derivation algebra (now in
///      {TalismanTransformationLib}) so crafted core arrays can exercise the mode /
///      XOR-dedup / material-synthesis edge cases that a live reveal — which
///      always produces cores sharing material and form — cannot reach. Extends
///      {Talismans} so it reuses its `materials` pointer + owner setter.
contract TalismansDeriveHarness is Talismans {
    function deriveMaterialId(uint256[] memory cores) external view returns (uint8) {
        return TalismanTransformationLib.deriveMaterialId(materials, cores);
    }

    function deriveShapeForm(uint256[] memory cores) external pure returns (TalismanForms.ShapeForm) {
        return TalismanTransformationLib.deriveShapeForm(cores);
    }

    function deriveSeed(uint256[] memory cores) external pure returns (uint16) {
        return TalismanTransformationLib.deriveSeed(cores);
    }
}

contract TalismanCoreDerivationTest is Test {
    TalismansDeriveHarness internal h;
    TalismanMaterials internal mats;

    // Reference materials and their element bitmasks under the L/C=0/1,
    // M/V=1/0, G/Y=0/1 rule (see TalismanMaterials._sigToBitmask):
    //   Rock     16  Lithic LLLL -> 0000 (0)
    //   Foxfire   1  Lithic LCLC -> 0101 (5)
    //   Diamond  15  Lithic CCCC -> 1111 (15)
    //   Aurora    0  Lumic  MMMM -> 1111 (15)
    //   Moss     27  Lumic  VVVV -> 0000 (0)
    //   Aether   38  Mythic YYYY -> 1111 (15)
    uint8 internal constant ROCK = 16;
    uint8 internal constant FOXFIRE = 1;
    uint8 internal constant DIAMOND = 15;
    uint8 internal constant AURORA = 0;
    uint8 internal constant AETHER = 38;

    function setUp() public {
        h = new TalismansDeriveHarness();
        mats = new TalismanMaterials();
        h.setMaterials(mats);
    }

    function _core(uint8 materialId, uint8 form, uint16 seed) internal pure returns (uint256) {
        return TalismanCore.pack(materialId, form, seed);
    }

    // ─── Shape form: mode, ties resolve to the later core ─────────────────────

    function test_form_singleCore() public view {
        uint256[] memory cores = new uint256[](1);
        cores[0] = _core(3, uint8(TalismanForms.ShapeForm.Brilliant), 0xAAAA);
        assertEq(uint8(h.deriveShapeForm(cores)), uint8(TalismanForms.ShapeForm.Brilliant));
    }

    function test_form_majorityWins() public view {
        uint8 pendant = uint8(TalismanForms.ShapeForm.Pendant);
        uint8 cushion = uint8(TalismanForms.ShapeForm.Cushion);
        uint256[] memory cores = new uint256[](4);
        cores[0] = _core(1, pendant, 1);
        cores[1] = _core(1, pendant, 2);
        cores[2] = _core(1, pendant, 3);
        cores[3] = _core(1, cushion, 4);
        assertEq(uint8(h.deriveShapeForm(cores)), pendant, "3 Pendant vs 1 Cushion -> Pendant");
    }

    function test_form_tieResolvesToLaterCore() public view {
        // Example from spec: cores 0,1 Pendant; 2,3 Cushion -> Cushion (later) wins.
        uint8 pendant = uint8(TalismanForms.ShapeForm.Pendant);
        uint8 cushion = uint8(TalismanForms.ShapeForm.Cushion);
        uint256[] memory cores = new uint256[](4);
        cores[0] = _core(1, pendant, 1);
        cores[1] = _core(1, pendant, 2);
        cores[2] = _core(1, cushion, 3);
        cores[3] = _core(1, cushion, 4);
        assertEq(uint8(h.deriveShapeForm(cores)), cushion, "tie -> last form wins");
    }

    // ─── Seed: XOR of distinct seeds, duplicates dropped ──────────────────────

    function test_seed_singleCore() public view {
        uint256[] memory cores = new uint256[](1);
        cores[0] = _core(1, 0, 0x1234);
        assertEq(h.deriveSeed(cores), 0x1234);
    }

    function test_seed_xorOfDistinct() public view {
        uint256[] memory cores = new uint256[](3);
        cores[0] = _core(1, 0, 0x1111);
        cores[1] = _core(1, 0, 0x2222);
        cores[2] = _core(1, 0, 0x4444);
        assertEq(h.deriveSeed(cores), uint16(0x1111 ^ 0x2222 ^ 0x4444));
    }

    function test_seed_dropsDuplicateBeforeXor() public view {
        // s2 appears twice -> only one occurrence contributes: s1 ^ s2.
        uint256[] memory cores = new uint256[](3);
        cores[0] = _core(1, 0, 0x1111);
        cores[1] = _core(1, 0, 0x2222);
        cores[2] = _core(1, 0, 0x2222);
        assertEq(h.deriveSeed(cores), uint16(0x1111 ^ 0x2222), "duplicate seed must not cancel out");
    }

    function test_seed_allIdenticalCollapsesToOne() public view {
        // Without dedup an even count would XOR to 0; dedup keeps one copy.
        uint256[] memory cores = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            cores[i] = _core(1, 0, 0x7777);
        }
        assertEq(h.deriveSeed(cores), 0x7777, "all-identical seeds collapse to one, not zero");
    }

    // ─── Material: element-signature synthesis ────────────────────────────────

    function _cores(uint8[] memory ids) internal pure returns (uint256[] memory cores) {
        cores = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            cores[i] = _core(ids[i], 0, uint16(i + 1));
        }
    }

    function _ids(uint8 a) internal pure returns (uint8[] memory ids) {
        ids = new uint8[](1);
        ids[0] = a;
    }

    function _ids(uint8 a, uint8 b) internal pure returns (uint8[] memory ids) {
        ids = new uint8[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function test_material_singleCoreRoundTrips() public view {
        // A single core's synthesised material is the core's own material.
        assertEq(h.deriveMaterialId(_cores(_ids(FOXFIRE))), FOXFIRE);
    }

    function test_material_identicalCoresKeepMaterial() public view {
        // Two identical masks would XOR to 0; the keep-on-equal fold preserves
        // the material instead. Aurora's mask is 1111 (the collapse-prone case).
        uint8[] memory ids = new uint8[](4);
        for (uint256 i; i < 4; ++i) {
            ids[i] = AURORA;
        }
        assertEq(h.deriveMaterialId(_cores(ids)), AURORA, "identical cores keep their material at any count");
    }

    function test_material_distinctSameEssenceXorBlends() public view {
        // Rock (mask 0) + Foxfire (mask 5), both Lithic: fold 0 ^ 5 = 5 ->
        // the Lithic material with mask 5 is Foxfire.
        assertEq(h.deriveMaterialId(_cores(_ids(ROCK, FOXFIRE))), FOXFIRE);
    }

    function test_material_crossEssenceSynthesisesMythic() public view {
        // Rock (Lithic, mask 0) + Aurora (Lumic, mask 15): poles span both
        // families -> Mythic; fold 0 ^ 15 = 15 -> Mythic mask 15 is Aether.
        uint8 id = h.deriveMaterialId(_cores(_ids(ROCK, AURORA)));
        assertEq(id, AETHER);
        (TalismanMaterials.Essence essence,) = mats.elementOf(id);
        assertEq(uint8(essence), uint8(TalismanMaterials.Essence.Mythic), "Lithic + Lumic must synthesise Mythic");
    }

    function test_material_crossEssenceEqualMasksStillSynthesise() public view {
        // Diamond (Lithic, mask 15) + Aurora (Lumic, mask 15): equal masks are
        // kept (acc stays 15) but the essence still flips to Mythic -> Aether.
        assertEq(h.deriveMaterialId(_cores(_ids(DIAMOND, AURORA))), AETHER);
    }

    function test_material_revertsWhenMaterialsNotSet() public {
        TalismansDeriveHarness bare = new TalismansDeriveHarness();
        vm.expectRevert(MaterialsNotSet.selector);
        bare.deriveMaterialId(_cores(_ids(ROCK)));
    }
}
