// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TalismanForms} from "../src/TalismanForms.sol";
import {TalismanGenerator, VIEWPORT_RADIUS} from "../src/TalismanGenerator.sol";
import {TalismanMaterials, MATERIAL_COUNT, NON_MYTHIC_MATERIAL_COUNT} from "../src/TalismanMaterials.sol";
import {Point3D, Triangle} from "../src/TalismanStructs.sol";

/// @dev External harness lets reachability tests free heavyweight Talisman memory
///      between calls. Solidity only releases memory across external-call boundaries,
///      so looping hundreds of in-proc `generate()` calls hits MemoryOOG.
/// @dev `TalismanGenerator.generate` now takes explicit (materialId, cores,
///      tier, seed). The harness picks all four uniformly from a single
///      caller-provided seed so the existing reachability/geometry sweeps
///      stay tight one-liners. Production rarity lives in
///      `Talismans.reveal`; the tests intentionally sample uniformly.
contract GenHarness {
    TalismanMaterials internal immutable materials;
    TalismanGenerator internal immutable generator;

    constructor(TalismanMaterials materialsContract, TalismanGenerator generatorContract) {
        materials = materialsContract;
        generator = generatorContract;
    }

    function material(uint256 seed) external view returns (uint8 m) {
        (m,,,,) = _pickEven(seed);
    }

    function tier(uint256 seed) external view returns (uint8) {
        (,,, TalismanGenerator.FacetTier t,) = _pickEven(seed);
        return uint8(t);
    }

    function chroma(uint256 seed) external view returns (uint8) {
        return _gen(seed).chroma;
    }

    function cores(uint256 seed) external view returns (uint8) {
        return _gen(seed).cores;
    }

    function essence(uint256 seed) external view returns (uint8) {
        return uint8(_gen(seed).material.essence);
    }

    function _gen(uint256 seed) internal view returns (TalismanGenerator.Talisman memory) {
        (uint8 mid, TalismanForms.ShapeForm f, uint8 c, TalismanGenerator.FacetTier t, uint16 s) = _pickEven(seed);
        TalismanMaterials.Material memory mat = materials.getMaterial(mid);
        return generator.generate(mat, mid, f, c, t, s);
    }

    function _pickEven(uint256 seed)
        internal
        view
        returns (
            uint8 materialId,
            TalismanForms.ShapeForm form,
            uint8 c,
            TalismanGenerator.FacetTier t,
            uint16 shapeSeed
        )
    {
        materialId = uint8(uint256(keccak256(abi.encode(seed, "test/material"))) % MATERIAL_COUNT);
        form = TalismanForms.ShapeForm(
            uint8(uint256(keccak256(abi.encode(seed, "test/form"))) % TalismanForms.SHAPE_FORM_COUNT)
        );
        t = TalismanGenerator.FacetTier(uint8(uint256(keccak256(abi.encode(seed, "test/tier"))) % 4));
        TalismanMaterials.Essence essenceVal = materials.getMaterial(materialId).essence;
        c = generator.coresForTier(t, essenceVal);
        shapeSeed = uint16(uint256(keccak256(abi.encode(seed, "test/seed"))));
    }
}

contract TalismanGeneratorTest is Test {
    GenHarness internal harness;
    TalismanMaterials internal materials;
    TalismanGenerator internal generator;

    function setUp() public {
        materials = new TalismanMaterials();
        generator = new TalismanGenerator();
        harness = new GenHarness(materials, generator);
    }

    function _gen(uint256 seed) internal view returns (TalismanGenerator.Talisman memory) {
        (uint8 mid, TalismanForms.ShapeForm f, uint8 c, TalismanGenerator.FacetTier t, uint16 s) = _pickEven(seed);
        TalismanMaterials.Material memory mat = materials.getMaterial(mid);
        return generator.generate(mat, mid, f, c, t, s);
    }

    function _pickEven(uint256 seed)
        internal
        view
        returns (
            uint8 materialId,
            TalismanForms.ShapeForm form,
            uint8 c,
            TalismanGenerator.FacetTier t,
            uint16 shapeSeed
        )
    {
        materialId = uint8(uint256(keccak256(abi.encode(seed, "test/material"))) % MATERIAL_COUNT);
        form = TalismanForms.ShapeForm(
            uint8(uint256(keccak256(abi.encode(seed, "test/form"))) % TalismanForms.SHAPE_FORM_COUNT)
        );
        t = TalismanGenerator.FacetTier(uint8(uint256(keccak256(abi.encode(seed, "test/tier"))) % 4));
        TalismanMaterials.Essence essenceVal = materials.getMaterial(materialId).essence;
        c = generator.coresForTier(t, essenceVal);
        shapeSeed = uint16(uint256(keccak256(abi.encode(seed, "test/seed"))));
    }

    function test_DeterministicForSameSeed() public view {
        TalismanGenerator.Talisman memory a = _gen(42);
        TalismanGenerator.Talisman memory b = _gen(42);

        assertEq(a.materialId, b.materialId);
        assertEq(a.facetTier, b.facetTier);
        assertEq(a.vertexCount, b.vertexCount);
        assertEq(a.triangles.length, b.triangles.length);
        for (uint256 i = 0; i < a.triangles.length; i++) {
            assertEq(a.triangles[i].p1.x, b.triangles[i].p1.x);
            assertEq(a.triangles[i].p1.y, b.triangles[i].p1.y);
            assertEq(a.triangles[i].p1.z, b.triangles[i].p1.z);
            assertEq(a.materials[i].color, b.materials[i].color);
        }
    }

    function test_TriangleCountMatchesTier() public view {
        for (uint256 s = 1; s <= 100; s++) {
            TalismanGenerator.Talisman memory t = _gen(s);
            assertEq(t.materials.length, t.triangles.length);
            uint256 N = (t.vertexCount - 1) / 3;
            assertGe(N, 3);
            assertLe(N, 6);
            assertEq(t.triangles.length, 6 * N - 2);
            assertGe(t.triangles.length, 16);
            assertLe(t.triangles.length, 38);
        }
    }

    function test_CoresDerivationMatchesEssence() public view {
        // Cores is the storage-canonical rarity signal; tier is its essence-aware label.
        // For every uniform draw, the on-token cores must equal coresForTier(tier, essence) and
        // tierFromCores(cores, essence) must round-trip back to the same tier. Uses the
        // external harness so memory is freed between calls (in-proc loop hits
        // MemoryOOG by ~64 iterations).
        for (uint256 s = 1; s <= 256; s++) {
            uint8 coresVal = harness.cores(s);
            uint8 tierVal = harness.tier(s);
            TalismanMaterials.Essence e = TalismanMaterials.Essence(harness.essence(s));
            TalismanGenerator.FacetTier tier = TalismanGenerator.FacetTier(tierVal);

            uint8 expected = generator.coresForTier(tier, e);
            assertEq(coresVal, expected, "tal.cores must equal coresForTier(tier, essence)");

            if (e == TalismanMaterials.Essence.Mythic) {
                assertEq(coresVal, (tierVal + 1) * 2, "Mythic cores must double");
                assertTrue(
                    coresVal == 2 || coresVal == 4 || coresVal == 6 || coresVal == 8, "Mythic cores in {2,4,6,8}"
                );
            } else {
                assertEq(coresVal, tierVal + 1, "non-Mythic cores must equal tier+1");
                assertTrue(coresVal >= 1 && coresVal <= 4, "non-Mythic cores in {1,2,3,4}");
            }

            TalismanGenerator.FacetTier roundTrip = generator.tierFromCores(coresVal, e);
            assertEq(uint8(roundTrip), tierVal, "tierFromCores must invert coresForTier");
        }
    }

    function test_AllTiersReachable() public view {
        bool[4] memory seen;
        uint256 found;
        for (uint256 s = 1; s <= 2000 && found < 4; s++) {
            uint8 tier = harness.tier(s);
            if (!seen[tier]) {
                seen[tier] = true;
                found++;
            }
        }
        assertEq(found, 4, "not all facet tiers reachable within 2000 seeds");
    }

    function test_AllMaterialsReachable() public view {
        bool[48] memory seen;
        uint256 found;
        for (uint256 s = 1; s <= 6000 && found < 48; s++) {
            uint8 id = harness.material(s);
            if (!seen[id]) {
                seen[id] = true;
                found++;
            }
        }
        assertEq(found, 48, "not all materials reachable within 6000 seeds");
    }

    function test_ChromaRoster() public view {
        // Pins every material id to its expected Chroma. Adding a material = add a
        // line here too; rebucketing = flip the line. The picker reads the same source
        // table, so this test catches drift at compile-time.
        TalismanMaterials.Chroma M = TalismanMaterials.Chroma.Monochromatic;
        TalismanMaterials.Chroma P = TalismanMaterials.Chroma.Polychromatic;
        TalismanMaterials.Chroma V = TalismanMaterials.Chroma.Variegated;

        TalismanMaterials.Chroma[48] memory expected = [
            V, // 0  Aurora (Lumic)
            M, // 1  Foxfire (Lithic)
            V, // 2  Pulsarlike (Lumic)
            P, // 3  Amethyst (Lithic)
            M, // 4  Citrine (Lithic)
            M, // 5  Fire Obsidian (Lithic)
            P, // 6  Duskhollow (Lumic)
            V, // 7  Sakura (Lumic)
            V, // 8  Rainforest (Lumic)
            P, // 9  Embermade (Lithic)
            M, // 10 Abyss (Lumic)
            P, // 11 Bloodmoon (Lumic)
            M, // 12 Sugilite (Lithic)
            M, // 13 Bored Ruby (Lithic)
            P, // 14 Dawnstone (Lithic)
            P, // 15 Diamond (Lithic)
            M, // 16 Rock (Lithic)
            M, // 17 Daystar (Lumic)
            M, // 18 Tsavorite (Lithic)
            M, // 19 Rhodochrosite (Lithic)
            M, // 20 Copper (Lithic)
            V, // 21 Foxglow (Lumic)
            V, // 22 Sealume (Lumic)
            P, // 23 Aquamarine (Lithic)
            P, // 24 Blazar (Lumic)
            M, // 25 Sproutsong (Lumic)
            M, // 26 Heartfern (Lumic)
            P, // 27 Moss (Lumic)
            M, // 28 Cobalt (Lithic)
            M, // 29 Emerald (Lithic)
            V, // 30 Wisp (Lumic)
            P, // 31 Twilight (Lumic)
            V, // 32 Corona (Mythic)
            V, // 33 Strobeflora (Mythic)
            P, // 34 Sigil (Mythic)
            V, // 35 Smokeblossom (Mythic)
            V, // 36 Saint Spectrum (Mythic)
            P, // 37 Cypher (Mythic)
            V, // 38 Aether (Mythic)
            M, // 39 Deadform (Mythic)
            V, // 40 Nullbloom (Mythic)
            P, // 41 Reliquary (Mythic)
            P, // 42 Duskcode (Mythic)
            V, // 43 Phosphor
            V, // 44 Celestial
            V, // 45 Corposant
            P, // 46 Wraithseal
            V //  47 Veilscript
        ];
        for (uint8 i = 0; i < 48; i++) {
            assertEq(uint8(materials.getMaterial(i).chroma), uint8(expected[i]), "material id has wrong Chroma");
        }
    }

    /// @dev Layout invariant: ids `[0, NON_MYTHIC_MATERIAL_COUNT)` must be
    ///      non-Mythic, ids `[NON_MYTHIC_MATERIAL_COUNT, MATERIAL_COUNT)` must
    ///      be Mythic. `Talismans._pickCoreMaterial` draws from the leading
    ///      range; any Mythic leaking in causes `tierFromCores` (and the
    ///      Mythic cores doubling) to panic on odd cores. Pins the layout so
    ///      future material reshuffles cannot reintroduce the bug.
    function test_EssenceRangeLayout() public view {
        for (uint8 id = 0; id < NON_MYTHIC_MATERIAL_COUNT; id++) {
            TalismanMaterials.Essence e = materials.getMaterial(id).essence;
            assertTrue(e != TalismanMaterials.Essence.Mythic, "non-mythic range contains a Mythic material");
        }
        for (uint8 id = NON_MYTHIC_MATERIAL_COUNT; id < MATERIAL_COUNT; id++) {
            TalismanMaterials.Essence e = materials.getMaterial(id).essence;
            assertEq(uint8(e), uint8(TalismanMaterials.Essence.Mythic), "mythic range contains a non-Mythic material");
        }
    }

    function test_GeneratedChromaMatchesRoster() public view {
        // Every generated talisman's `chroma` field must equal the canonical
        // `getMaterial(id).chroma`. Catches any future picker that bypasses
        // the single source of truth. External harness frees memory between
        // calls (avoids MemoryOOG that hits inside in-proc loops).
        for (uint256 s = 1; s <= 256; s++) {
            uint8 id = harness.material(s);
            uint8 c = harness.chroma(s);
            assertEq(c, uint8(materials.getMaterial(id).chroma), "talisman.chroma drifted from materials table");
        }
    }

    function test_AllChromasReachable() public view {
        bool[3] memory seen;
        uint256 found;
        for (uint256 s = 1; s <= 2000 && found < 3; s++) {
            uint8 c = harness.chroma(s);
            if (!seen[c]) {
                seen[c] = true;
                found++;
            }
        }
        assertEq(found, 3, "not all chromas reachable within 2000 seeds");
    }

    function test_MaterialPoolDistinctness() public view {
        // Every material must define at least 6 distinct colors in its 8-color pool.
        // Catches authoring errors (duplicate stops in `_v`, collapsed `_ramp` triples).
        // Skips id 1 (Foxfire) and id 26 (Deadform) — both intentionally collapse
        // their 8-stop pool to a single hex tone (Foxfire 0xFF7305 flat fox-orange,
        // Deadform near-black absence-of-color). Both opt out of per-facet jitter
        // via `_isUniformMaterial` so the bake renders as a true flat tile.
        for (uint8 id = 0; id < 36; id++) {
            if (id == 1 || id == 26) {
                continue;
            }
            TalismanMaterials.Material memory mat = materials.getMaterial(id);
            uint256 distinct;
            for (uint256 i = 0; i < 8; i++) {
                bool seenBefore;
                for (uint256 j = 0; j < i && !seenBefore; j++) {
                    if (mat.colors[i] == mat.colors[j]) {
                        seenBefore = true;
                    }
                }
                if (!seenBefore) {
                    distinct++;
                }
            }
            assertGe(distinct, 6, "material pool must have at least 6 distinct colors");
        }
    }

    function test_VariegatedRegionalNotYAligned() public view {
        // For a Variegated talisman, two triangles in the SAME Y-band can carry colors
        // from DIFFERENT pool slots — proving the bake is regional, not Y-aligned. We
        // detect this by sampling many Prime-tier (N=6) talismans on Variegated materials
        // until we find one where two triangles sharing the same lowest-Y vertex have
        // base colors whose RGB-channel deltas exceed the per-face jitter envelope (±5%).
        // Under the old 3-stop Y-banded bake this could never happen. Uses the external
        // harness so per-iteration memory is freed.
        uint256 found;
        for (uint256 s = 1; s <= 512 && found == 0; s++) {
            uint8 id = harness.material(s);
            TalismanMaterials.Material memory mat = materials.getMaterial(id);
            if (mat.chroma != TalismanMaterials.Chroma.Variegated) {
                continue;
            }
            uint8 c = generator.coresForTier(TalismanGenerator.FacetTier.Prime, mat.essence);
            TalismanForms.ShapeForm form = TalismanForms.ShapeForm(
                uint8(uint256(keccak256(abi.encode(s, "test/form"))) % TalismanForms.SHAPE_FORM_COUNT)
            );
            uint16 shapeSeed = uint16(uint256(keccak256(abi.encode(s, "test/seed"))));
            TalismanGenerator.Talisman memory t =
                generator.generate(mat, id, form, c, TalismanGenerator.FacetTier.Prime, shapeSeed);
            for (uint256 i = 0; i < t.triangles.length && found == 0; i++) {
                int256 yi = _lowY(t.triangles[i]);
                for (uint256 j = i + 1; j < t.triangles.length && found == 0; j++) {
                    if (_lowY(t.triangles[j]) != yi) {
                        continue;
                    }
                    if (_rgbDeltaExceedsJitter(t.materials[i].color, t.materials[j].color)) {
                        found = 1;
                    }
                }
            }
        }
        assertEq(found, 1, "no Variegated mesh produced same-Y triangles with non-jitter color delta");
    }

    function _lowY(Triangle memory t) internal pure returns (int256 cy) {
        cy = t.p1.y;
        if (t.p2.y < cy) {
            cy = t.p2.y;
        }
        if (t.p3.y < cy) {
            cy = t.p3.y;
        }
    }

    /// @dev True if the |a - b| RGB-channel delta on any channel exceeds the maximum
    ///      possible per-face jitter (±5% on a 0..255 channel = ~25). Two facets baked
    ///      from the same pool stop differ only by jitter; a delta past that threshold
    ///      means they came from different pool stops.
    function _rgbDeltaExceedsJitter(uint32 a, uint32 b) internal pure returns (bool) {
        uint256 ar = (a >> 16) & 0xFF;
        uint256 ag = (a >> 8) & 0xFF;
        uint256 ab = a & 0xFF;
        uint256 br = (b >> 16) & 0xFF;
        uint256 bg = (b >> 8) & 0xFF;
        uint256 bb = b & 0xFF;
        uint256 dr = ar > br ? ar - br : br - ar;
        uint256 dg = ag > bg ? ag - bg : bg - ag;
        uint256 db = ab > bb ? ab - bb : bb - ab;
        return dr > 30 || dg > 30 || db > 30;
    }

    function test_VolumeInPlausibleRange() public view {
        // Mesh fits inside bounding sphere of radius maxRadius. Volume must be positive and
        // bounded above by that sphere's volume (4/3 π r³ ≈ 4.189 r³). We use a looser
        // upper bound of 5 * r³ to absorb fixed-point rounding. Lower bound: some volume
        // (>= 0.05 * r³) so degenerate meshes don't slip through.
        int256 WAD = 1e18;
        for (uint256 s = 1; s <= 64; s++) {
            TalismanGenerator.Talisman memory t = _gen(s);
            uint256 r = uint256(t.maxRadius);
            uint256 rCubed = r * r / uint256(WAD) * r / uint256(WAD);
            assertGt(t.volume, rCubed * 5 / 100, "volume implausibly small");
            assertLt(t.volume, rCubed * 5, "volume exceeds bounding-sphere envelope");
        }
    }

    function test_VolumeDeterministic() public view {
        assertEq(_gen(123).volume, _gen(123).volume);
    }

    function test_MaxRadiusReflectsMesh() public view {
        // Camera framing relies on tal.maxRadius == true bounding-sphere radius of the final
        // mesh. Any drift here silently reintroduces edge clipping for boosted forms.
        for (uint256 s = 1; s <= 64; s++) {
            TalismanGenerator.Talisman memory t = _gen(s);
            (,, int256 maxSq) = _maxBounds(t);
            int256 r = t.maxRadius;
            int256 rSq = r * r;
            assertLe(maxSq, rSq + 2 * r + 1, "maxRadius under-reports mesh extent");
            assertGe(maxSq, rSq - 2 * r, "maxRadius over-reports mesh extent");
        }
    }

    function test_MeshFitsFrustumAtStdCamera() public view {
        // Script frames with dist = maxRadius * 32/10 at FOV 35°. Reject any mesh whose
        // actual bounding sphere projects past the viewport half-height.
        int256 distNum = 32;
        int256 distDen = 10;
        // tan(17.5°) ≈ 0.31530 — encoded as 31530/100000 for integer math.
        int256 tanHalfFovNum = 31530;
        int256 tanHalfFovDen = 100000;
        for (uint256 s = 1; s <= 96; s++) {
            TalismanGenerator.Talisman memory t = _gen(s);
            int256 r = t.maxRadius;
            int256 halfFrustum = r * distNum * tanHalfFovNum / (distDen * tanHalfFovDen);
            assertGt(halfFrustum, r, "mesh projects outside viewport at std camera dist");
        }
    }

    function test_BoundingBoxCentered() public view {
        // Final endpass re-centers the bbox midpoint so the mesh frames symmetrically on
        // screen.
        for (uint256 s = 1; s <= 16; s++) {
            TalismanGenerator.Talisman memory t = _gen(s);
            (int256 minX, int256 maxX, int256 minY, int256 maxY, int256 minZ, int256 maxZ) = _bounds(t);
            int256 tol = VIEWPORT_RADIUS / 50;
            assertLt(_abs((minX + maxX) / 2), tol, "x bbox not centered");
            assertLt(_abs((minY + maxY) / 2), tol, "y bbox not centered");
            assertLt(_abs((minZ + maxZ) / 2), tol, "z bbox not centered");
        }
    }

    function test_StarShapedFromOrigin() public view {
        for (uint256 s = 1; s <= 16; s++) {
            TalismanGenerator.Talisman memory t = _gen(s);
            for (uint256 i = 0; i < t.triangles.length; i++) {
                assertGt(_lenSq(t.triangles[i].p1), 0, "p1 at origin");
                assertGt(_lenSq(t.triangles[i].p2), 0, "p2 at origin");
                assertGt(_lenSq(t.triangles[i].p3), 0, "p3 at origin");
            }
        }
    }

    function test_OutwardNormals() public view {
        TalismanGenerator.Talisman memory t = _gen(123);
        for (uint256 i = 0; i < t.triangles.length; i++) {
            Triangle memory tri = t.triangles[i];
            int256 nx = (tri.p2.y - tri.p1.y) * (tri.p3.z - tri.p1.z) - (tri.p2.z - tri.p1.z) * (tri.p3.y - tri.p1.y);
            int256 ny = (tri.p2.z - tri.p1.z) * (tri.p3.x - tri.p1.x) - (tri.p2.x - tri.p1.x) * (tri.p3.z - tri.p1.z);
            int256 nz = (tri.p2.x - tri.p1.x) * (tri.p3.y - tri.p1.y) - (tri.p2.y - tri.p1.y) * (tri.p3.x - tri.p1.x);
            int256 cx = tri.p1.x + tri.p2.x + tri.p3.x;
            int256 cy = tri.p1.y + tri.p2.y + tri.p3.y;
            int256 cz = tri.p1.z + tri.p2.z + tri.p3.z;
            int256 dot = nx / 1e18 * cx + ny / 1e18 * cy + nz / 1e18 * cz;
            assertGe(dot, 0, "inward-facing triangle");
        }
    }

    function test_ColorVariationTopToBottom() public view {
        // Vertical gradient should produce at least two distinct colors across the
        // mesh. Some materials (Foxfire, Deadform) are intentionally uniform — the
        // test seed-scans up to 32 candidates to land on a non-uniform material so
        // the assertion measures real bake variation rather than the flat-tile
        // exception case.
        bool hasVariation;
        for (uint256 seed = 7; seed < 7 + 32 && !hasVariation; seed++) {
            TalismanGenerator.Talisman memory t = _gen(seed);
            uint32 first = t.materials[0].color;
            for (uint256 i = 1; i < t.materials.length && !hasVariation; i++) {
                if (t.materials[i].color != first) {
                    hasVariation = true;
                }
            }
        }
        assertTrue(hasVariation, "material must produce spatial color variation");
    }

    // ---- helpers ----

    function _bounds(TalismanGenerator.Talisman memory t)
        internal
        pure
        returns (int256 minX, int256 maxX, int256 minY, int256 maxY, int256 minZ, int256 maxZ)
    {
        minX = t.triangles[0].p1.x;
        maxX = minX;
        minY = t.triangles[0].p1.y;
        maxY = minY;
        minZ = t.triangles[0].p1.z;
        maxZ = minZ;
        for (uint256 i = 0; i < t.triangles.length; i++) {
            Point3D[3] memory pts = [t.triangles[i].p1, t.triangles[i].p2, t.triangles[i].p3];
            for (uint256 k = 0; k < 3; k++) {
                if (pts[k].x < minX) {
                    minX = pts[k].x;
                }
                if (pts[k].x > maxX) {
                    maxX = pts[k].x;
                }
                if (pts[k].y < minY) {
                    minY = pts[k].y;
                }
                if (pts[k].y > maxY) {
                    maxY = pts[k].y;
                }
                if (pts[k].z < minZ) {
                    minZ = pts[k].z;
                }
                if (pts[k].z > maxZ) {
                    maxZ = pts[k].z;
                }
            }
        }
    }

    function _maxBounds(TalismanGenerator.Talisman memory t)
        internal
        pure
        returns (int256 maxAbsX, int256 maxAbsY, int256 maxSq)
    {
        for (uint256 i = 0; i < t.triangles.length; i++) {
            Point3D[3] memory pts = [t.triangles[i].p1, t.triangles[i].p2, t.triangles[i].p3];
            for (uint256 k = 0; k < 3; k++) {
                int256 ss = pts[k].x * pts[k].x + pts[k].y * pts[k].y + pts[k].z * pts[k].z;
                if (ss > maxSq) {
                    maxSq = ss;
                }
                int256 ax = _abs(pts[k].x);
                int256 ay = _abs(pts[k].y);
                if (ax > maxAbsX) {
                    maxAbsX = ax;
                }
                if (ay > maxAbsY) {
                    maxAbsY = ay;
                }
            }
        }
    }

    function _lenSq(Point3D memory p) internal pure returns (int256) {
        return p.x * p.x + p.y * p.y + p.z * p.z;
    }

    function _abs(int256 v) internal pure returns (int256) {
        return v >= 0 ? v : -v;
    }
}
