// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MeshProbe} from "../script/DiagnoseMesh.s.sol";
import {Point3D, Triangle} from "../src/TalismanStructs.sol";
import {TalismanForms} from "../src/TalismanForms.sol";
import {TalismanGenerator} from "../src/TalismanGenerator.sol";
import {TalismanGeneratorV2} from "../src/TalismanGeneratorV2.sol";
import {TalismanMaterials} from "../src/TalismanMaterials.sol";
import {TalismanTransformationLib} from "../src/TalismanTransformationLib.sol";

/// @notice Regression parity between the deployed generator and
///         {TalismanGeneratorV2}: identical output wherever V1 wound the mesh
///         correctly, and a delta confined to exactly the wrongly-wound faces
///         where it did not. Flip classification
///         reuses the {MeshProbe} diagnostic used for the collection-wide scan.
contract TalismanGeneratorV2Test is Test {
    TalismanMaterials internal mats;
    TalismanGenerator internal gen1;
    TalismanGeneratorV2 internal gen2;
    MeshProbe internal probe;

    /// @dev The seven jittery forms the seed-space sweep found flips in, all at
    ///      Raw tier (backface-culling-fix.html §3).
    uint8[7] internal flippyForms = [
        uint8(TalismanForms.ShapeForm.Shard),
        uint8(TalismanForms.ShapeForm.Jagged),
        uint8(TalismanForms.ShapeForm.Teardrop),
        uint8(TalismanForms.ShapeForm.Cluster),
        uint8(TalismanForms.ShapeForm.Geode),
        uint8(TalismanForms.ShapeForm.Rock),
        uint8(TalismanForms.ShapeForm.Husk)
    ];

    function setUp() public {
        mats = new TalismanMaterials();
        gen1 = new TalismanGenerator();
        gen2 = new TalismanGeneratorV2();
        probe = new MeshProbe();
    }

    // ─── Sweep replication ──────────────────────────────────────────────────

    /// @notice Replays the documented 256-seed sweep cell for Husk × Raw and
    ///         expects the exact incidence the scan reported: 17 seeds with at
    ///         least one V1-flipped face. Pins that the flip classifier used
    ///         throughout this suite is the one the collection scan ran.
    function test_sweep_huskRaw_reproduces17FlippedSeedsOf256() public view {
        uint256 bad;
        for (uint256 s = 0; s < 256; s++) {
            (, uint256 flipped) = _flips(uint8(TalismanForms.ShapeForm.Husk), 0, uint16(s * 256));
            if (flipped > 0) {
                bad++;
            }
        }
        assertEq(bad, 17, "Husk/Raw sweep incidence diverged from the collection scan");
    }

    /// @notice The stable forms never flipped in the scan; spot-check Brilliant
    ///         across all four tiers stays clean over the same seed grid.
    function test_sweep_brilliantAllTiers_neverFlips() public view {
        for (uint8 t = 0; t < 4; t++) {
            for (uint256 s = 0; s < 64; s++) {
                (, uint256 flipped) = _flips(uint8(TalismanForms.ShapeForm.Brilliant), t, uint16(s * 1024));
                assertEq(flipped, 0, "Brilliant should never flip");
            }
        }
    }

    // ─── Byte-identical regression on clean seeds ───────────────────────────

    /// @notice For every form × tier, a seed V1 wound correctly regenerates
    ///         byte-identically under V2 - geometry, colors, and metrics.
    function test_generate_cleanSeed_byteIdentical_everyFormAndTier() public view {
        for (uint8 f = 0; f < TalismanForms.SHAPE_FORM_COUNT; f++) {
            for (uint8 t = 0; t < 4; t++) {
                uint16 seed = _findSeed(f, t, false);
                (TalismanGenerator.Talisman memory a, TalismanGeneratorV2.Talisman memory b) = _pair(f, t, seed);
                assertEq(keccak256(abi.encode(b)), keccak256(abi.encode(a)), "clean mesh not byte-identical");
            }
        }
    }

    // ─── Delta confined to the flipped faces ────────────────────────────────

    /// @notice For each jittery form, a Raw-tier seed V1 got wrong differs
    ///         under V2 in exactly the diagnosed faces - and only by a p2/p3
    ///         swap. Everything else (positions, colors, metrics, face order)
    ///         is untouched.
    function test_generate_flippedSeed_differsOnlyInFlippedFaces() public view {
        for (uint256 k = 0; k < flippyForms.length; k++) {
            uint8 f = flippyForms[k];
            uint16 seed = _findSeed(f, 0, true);
            (uint256 mask, uint256 flipped) = _flips(f, 0, seed);
            assertGt(flipped, 0, "expected a flipped seed");
            (TalismanGenerator.Talisman memory a, TalismanGeneratorV2.Talisman memory b) = _pair(f, 0, seed);
            _assertDeltaIsExactlyMask(a, b, mask);
        }
    }

    /// @notice Live-token regression for reported token #1496 (Twilight Husk,
    ///         Raw): its actual mainnet core reproduces the diagnosed single
    ///         flipped face, and V2 changes that face only.
    function test_liveToken1496_singleFaceRewoundOnly() public view {
        uint256[] memory cores = new uint256[](1);
        cores[0] = 32218975;

        uint8 mid = TalismanTransformationLib.deriveMaterialId(mats, cores);
        TalismanForms.ShapeForm form = TalismanTransformationLib.deriveShapeForm(cores);
        uint16 seed = TalismanTransformationLib.deriveSeed(cores);
        TalismanGenerator.FacetTier tier = gen1.tierFromCores(1, mats.getMaterial(mid).essence);

        assertEq(mats.getMaterial(mid).name, "Twilight", "material");
        assertEq(uint8(form), uint8(TalismanForms.ShapeForm.Husk), "form");
        assertEq(uint8(tier), uint8(TalismanGenerator.FacetTier.Raw), "tier");

        (uint256 mask, uint256 flipped) = _flips(uint8(form), uint8(tier), seed);
        assertEq(flipped, 1, "#1496 has exactly one flipped face");

        TalismanMaterials.Material memory mat = mats.getMaterial(mid);
        TalismanGenerator.Talisman memory a = gen1.generate(mat, mid, form, 1, tier, seed);
        TalismanGeneratorV2.Talisman memory b =
            gen2.generate(mat, mid, form, 1, TalismanGeneratorV2.FacetTier(uint8(tier)), seed);
        _assertDeltaIsExactlyMask(a, b, mask);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    /// @dev V1-flip diagnosis for one (form, tier, seed): rebuild the point set
    ///      the deployed triangulator saw, and compare each face's deployed
    ///      orientation against the reference parity fixed on the convex base.
    function _flips(uint8 formU, uint8 tierU, uint16 seed) internal view returns (uint256 mask, uint256 count) {
        (Point3D[] memory pts, Point3D[] memory base, uint256 n) = probe.reconstruct(formU, tierU, seed);
        uint256[3][] memory tri = probe.rawTriples(n);
        for (uint256 i = 0; i < tri.length; i++) {
            (uint256 a, uint256 b, uint256 c) = (tri[i][0], tri[i][1], tri[i][2]);
            bool refO = probe.facesOutward(base[a], base[b], base[c]);
            bool depO = probe.facesOutward(pts[a], pts[b], pts[c]);
            if (refO != depO) {
                mask |= (1 << i);
                count++;
            }
        }
    }

    /// @dev First seed (scanning up from 0) whose V1 mesh does / does not carry
    ///      a flipped face for the given cell.
    function _findSeed(uint8 formU, uint8 tierU, bool wantFlipped) internal view returns (uint16) {
        for (uint256 s = 0; s < 2048; s++) {
            (, uint256 flipped) = _flips(formU, tierU, uint16(s));
            if ((flipped > 0) == wantFlipped) {
                return uint16(s);
            }
        }
        revert("no seed with requested flip state");
    }

    function _pair(uint8 formU, uint8 tierU, uint16 seed)
        internal
        view
        returns (TalismanGenerator.Talisman memory a, TalismanGeneratorV2.Talisman memory b)
    {
        // Any non-Mythic material works: material only affects colors, which the
        // parity checks cover; cores = tier + 1 for the pole essences.
        TalismanMaterials.Material memory mat = mats.getMaterial(0);
        uint8 cores = tierU + 1;
        TalismanForms.ShapeForm form = TalismanForms.ShapeForm(formU);
        a = gen1.generate(mat, 0, form, cores, TalismanGenerator.FacetTier(tierU), seed);
        b = gen2.generate(mat, 0, form, cores, TalismanGeneratorV2.FacetTier(tierU), seed);
    }

    /// @dev Asserts V2 output equals V1 except that exactly the faces in `mask`
    ///      have p2/p3 swapped (re-wound), with colors and metrics untouched.
    function _assertDeltaIsExactlyMask(
        TalismanGenerator.Talisman memory a,
        TalismanGeneratorV2.Talisman memory b,
        uint256 mask
    ) internal pure {
        assertEq(b.triangles.length, a.triangles.length, "triangle count");
        for (uint256 i = 0; i < a.triangles.length; i++) {
            Triangle memory ta = a.triangles[i];
            Triangle memory tb = b.triangles[i];
            assertEq(tb.materialId, ta.materialId, "face material id");
            assertEq(keccak256(abi.encode(tb.p1)), keccak256(abi.encode(ta.p1)), "p1 moved");
            if ((mask >> i) & 1 == 1) {
                assertEq(keccak256(abi.encode(tb.p2)), keccak256(abi.encode(ta.p3)), "flipped face p2 != V1 p3");
                assertEq(keccak256(abi.encode(tb.p3)), keccak256(abi.encode(ta.p2)), "flipped face p3 != V1 p2");
            } else {
                assertEq(keccak256(abi.encode(tb)), keccak256(abi.encode(ta)), "unflipped face changed");
            }
        }
        assertEq(keccak256(abi.encode(b.materials)), keccak256(abi.encode(a.materials)), "baked colors changed");
        assertEq(b.maxRadius, a.maxRadius, "maxRadius");
        assertEq(b.volume, a.volume, "volume");
        assertEq(b.vertexCount, a.vertexCount, "vertexCount");
    }
}
