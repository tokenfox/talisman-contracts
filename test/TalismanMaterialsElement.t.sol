// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TalismanMaterials, MATERIAL_COUNT} from "../src/TalismanMaterials.sol";

/// @dev Coverage for the element-signature bitmask API on {TalismanMaterials}:
///      the per-letter bit rule, the per-essence bijection that lets the grids
///      be inverted, and the {materialIdFromSignature} round-trip.
contract TalismanMaterialsElementTest is Test {
    TalismanMaterials internal mats;

    function setUp() public {
        mats = new TalismanMaterials();
    }

    // ─── Bit rule: C/M/Y = 1, L/V/G = 0; leftmost char = MSB ──────────────────

    function test_bitmask_spotValues() public view {
        assertEq(mats.elementBitmask(16), 0, "Rock LLLL -> 0000");
        assertEq(mats.elementBitmask(15), 15, "Diamond CCCC -> 1111");
        assertEq(mats.elementBitmask(1), 5, "Foxfire LCLC -> 0101");
        assertEq(mats.elementBitmask(0), 15, "Aurora MMMM -> 1111 (M=1)");
        assertEq(mats.elementBitmask(27), 0, "Moss VVVV -> 0000 (V=0)");
        assertEq(mats.elementBitmask(39), 0, "Deadform GGGG -> 0000 (G=0)");
        assertEq(mats.elementBitmask(38), 15, "Aether YYYY -> 1111 (Y=1)");
        // Bloodmoon VMMV -> 0 1 1 0 = 0110 (6); Twilight VVMM -> 0 0 1 1 = 0011 (3).
        assertEq(mats.elementBitmask(11), 6, "Bloodmoon VMMV -> 0110");
        assertEq(mats.elementBitmask(31), 3, "Twilight VVMM -> 0011");
    }

    function test_elementOf_matchesSeparateAccessors() public view {
        for (uint8 id; id < MATERIAL_COUNT; ++id) {
            (TalismanMaterials.Essence essence, uint8 mask) = mats.elementOf(id);
            assertEq(mask, mats.elementBitmask(id), "elementOf mask must match elementBitmask");
            assertEq(uint8(essence), uint8(mats.getMaterial(id).essence), "elementOf essence must match record");
        }
    }

    // ─── Per-essence bijection: each family covers masks 0..15 uniquely ───────

    function test_bitmask_bijectiveWithinEachEssence() public view {
        // For each essence, every mask 0..15 must be hit exactly once across
        // the 48 materials — the property that makes the grids invertible.
        uint16[3] memory seen; // one 16-bit bitset per essence
        for (uint8 id; id < MATERIAL_COUNT; ++id) {
            (TalismanMaterials.Essence essence, uint8 mask) = mats.elementOf(id);
            uint256 e = uint256(essence);
            uint16 bit = uint16(1) << mask;
            assertEq(seen[e] & bit, 0, "duplicate (essence, mask) pair");
            seen[e] |= bit;
        }
        for (uint256 e; e < 3; ++e) {
            assertEq(seen[e], uint16(0xFFFF), "every mask 0..15 must be present in each essence");
        }
    }

    // ─── Round-trip: materialIdFromSignature inverts elementBitmask ───────────

    function test_materialIdFromSignature_roundTripsEveryMaterial() public view {
        for (uint8 id; id < MATERIAL_COUNT; ++id) {
            (TalismanMaterials.Essence essence, uint8 mask) = mats.elementOf(id);
            assertEq(mats.materialIdFromSignature(essence, mask), id, "reverse lookup must return the source id");
        }
    }

    function test_materialIdFromSignature_revertsForOutOfRangeMask() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                TalismanMaterials.NoMaterialForSignature.selector, TalismanMaterials.Essence.Lithic, uint8(16)
            )
        );
        mats.materialIdFromSignature(TalismanMaterials.Essence.Lithic, 16);
    }
}
