// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TalismanCore} from "../src/TalismanCore.sol";
import {TalismanForms} from "../src/TalismanForms.sol";
import {TalismanMaterials, MATERIAL_COUNT, NON_MYTHIC_MATERIAL_COUNT} from "../src/TalismanMaterials.sol";

/// @dev Direct unit tests for the bit-packing contract in {TalismanCore}.
contract TalismanCoreTest is Test {
    function test_layout_constantsAreNonOverlapping() public pure {
        assertEq(TalismanCore.MATERIAL_SHIFT, 0);
        assertEq(TalismanCore.FORM_SHIFT, TalismanCore.MATERIAL_BITS);
        assertEq(TalismanCore.SEED_SHIFT, TalismanCore.MATERIAL_BITS + TalismanCore.FORM_BITS);
        assertTrue(TalismanCore.MATERIAL_BITS > 0);
        assertTrue(TalismanCore.FORM_BITS > 0);
        assertTrue(TalismanCore.SEED_BITS > 0);
    }

    function test_layout_widthsCoverCurrentDomain() public pure {
        // Material ids extend through the full TalismanMaterials table; the
        // bit width must cover MATERIAL_COUNT-1, not just the non-mythic
        // range, so future extensions reading material from a core never
        // truncate.
        assertGe((uint256(1) << TalismanCore.MATERIAL_BITS), MATERIAL_COUNT);
        // 14 shape forms today; widen if the enum grows past 16.
        assertGe((uint256(1) << TalismanCore.FORM_BITS), 14);
        // Per design, seed must be at least 16 bits so each (material, form,
        // tier) tuple can address ≥ 65 536 unique generator outputs.
        assertGe(TalismanCore.SEED_BITS, 16);
    }

    function test_pack_unpackRoundTrip() public pure {
        // Sweep material and form on a fixed seed, plus a small seed sweep on
        // a fixed (m, f) to keep iteration cost down. Each axis is verified
        // independently — same property.
        for (uint8 m = 0; m < MATERIAL_COUNT; ++m) {
            for (uint8 f; f <= uint8(TalismanForms.ShapeForm.Husk); ++f) {
                uint256 core = TalismanCore.pack(m, f, 0xBEEF);
                assertEq(TalismanCore.materialId(core), m, "material round-trip");
                assertEq(uint8(TalismanCore.shapeForm(core)), f, "shape round-trip");
                assertEq(TalismanCore.seed(core), 0xBEEF, "seed round-trip");
            }
        }
        uint16[5] memory seeds = [uint16(0), 1, 0x7FFF, 0xFFFE, 0xFFFF];
        for (uint256 i; i < seeds.length; ++i) {
            uint256 core = TalismanCore.pack(7, uint8(TalismanForms.ShapeForm.Rock), seeds[i]);
            assertEq(TalismanCore.seed(core), seeds[i], "seed boundary round-trip");
        }
    }

    function test_pack_doesNotLeakIntoReservedBits() public pure {
        // Pack the maximum representable material+form+seed. All bits above
        // the declared field widths must be zero — so adding a future field
        // can assume a clean slate.
        uint256 core = TalismanCore.pack(
            uint8(TalismanCore.MATERIAL_MASK), uint8(TalismanCore.FORM_MASK), uint16(TalismanCore.SEED_MASK)
        );
        uint256 declaredBits = TalismanCore.MATERIAL_BITS + TalismanCore.FORM_BITS + TalismanCore.SEED_BITS;
        uint256 reservedMask = ~((uint256(1) << declaredBits) - 1);
        assertEq(core & reservedMask, 0, "no leakage into reserved bits");
    }

    function test_pack_truncatesOverwidthInputs() public pure {
        // Documented behavior: caller must keep inputs within mask bounds.
        // Pickers in {Talismans} do; this test pins the truncation contract
        // so we notice if the helper's tolerance changes accidentally.
        uint8 overMaterial = uint8(TalismanCore.MATERIAL_MASK) + 1; // overflows the field
        uint256 core = TalismanCore.pack(overMaterial, 0, 0);
        assertEq(TalismanCore.materialId(core), 0, "high material bit silently dropped");
    }

    function testFuzz_unpack_ignoresReservedBits(uint256 noise) public pure {
        // Reader must mask only its own bits. Adding noise into reserved
        // territory must not change material, form, or seed readings.
        uint256 declaredBits = TalismanCore.MATERIAL_BITS + TalismanCore.FORM_BITS + TalismanCore.SEED_BITS;
        uint256 reservedNoise = (noise >> declaredBits) << declaredBits;
        uint256 clean = TalismanCore.pack(7, uint8(TalismanForms.ShapeForm.Rock), 0xC0DE);
        uint256 noisy = clean | reservedNoise;
        assertEq(TalismanCore.materialId(noisy), 7);
        assertEq(uint8(TalismanCore.shapeForm(noisy)), uint8(TalismanForms.ShapeForm.Rock));
        assertEq(TalismanCore.seed(noisy), 0xC0DE);
    }
}
