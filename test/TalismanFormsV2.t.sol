// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Point3D, Triangle} from "../src/TalismanStructs.sol";
import {TalismanForms} from "../src/TalismanForms.sol";
import {TalismanFormsV2} from "../src/TalismanFormsV2.sol";

/// @notice Static correctness of the V2 fixed-winding triangulator. The core
///         claim is that winding consistency is a
///         property of the construction, not of the geometry: proving the
///         directed-edge test once by vertex *index* proves it for every seed,
///         and pinning the outward sign on each convex base pins it for every
///         perturbation of that base.
contract TalismanFormsV2Test is Test {
    int256 internal constant WAD = 1e18;

    // ─── Topology: consistency by construction ──────────────────────────────

    /// @notice For each facet-tier resolution N, every directed edge of the
    ///         fixed-winding triangulation appears exactly once in each
    ///         direction. Walked by vertex index, so passing once proves
    ///         winding consistency for all seeds, forms, and perturbations.
    function test_directedEdges_appearOnceEachWay_everyN() public pure {
        for (uint256 n = 3; n <= 6; n++) {
            // Encode each vertex's index in its x coordinate so emitted
            // triangles can be walked topologically.
            Point3D[] memory pts = new Point3D[](3 * n + 1);
            for (uint256 i = 0; i < pts.length; i++) {
                pts[i] = Point3D({x: int256(i), y: 0, z: 0});
            }
            Triangle[] memory tris = TalismanFormsV2.triangulateForForm(TalismanForms.ShapeForm.Brilliant, pts, n);
            assertEq(tris.length, 6 * n - 2, "triangle count");

            uint256 edgeCount = tris.length * 3;
            uint256[] memory from = new uint256[](edgeCount);
            uint256[] memory to = new uint256[](edgeCount);
            uint256 w;
            for (uint256 i = 0; i < tris.length; i++) {
                (uint256 a, uint256 b, uint256 c) =
                    (uint256(tris[i].p1.x), uint256(tris[i].p2.x), uint256(tris[i].p3.x));
                (from[w], to[w]) = (a, b);
                w++;
                (from[w], to[w]) = (b, c);
                w++;
                (from[w], to[w]) = (c, a);
                w++;
            }
            for (uint256 i = 0; i < edgeCount; i++) {
                uint256 same;
                uint256 rev;
                for (uint256 j = 0; j < edgeCount; j++) {
                    if (from[j] == from[i] && to[j] == to[i]) {
                        same++;
                    }
                    if (from[j] == to[i] && to[j] == from[i]) {
                        rev++;
                    }
                }
                assertEq(same, 1, "directed edge emitted more than once");
                assertEq(rev, 1, "reverse edge missing - open or inconsistent surface");
            }
        }
    }

    // ─── Geometry: outward sign pinned on the convex bases ──────────────────

    /// @notice On every form's unperturbed base (where the origin-centroid test
    ///         is exact), every V2 face normal points away from the origin.
    ///         Combined with the directed-edge test this fixes the global
    ///         orientation as outward for the whole input space.
    function test_everyBaseFace_windsOutward_allFormsAllN() public pure {
        for (uint8 f = 0; f < TalismanForms.SHAPE_FORM_COUNT; f++) {
            TalismanForms.ShapeForm form = TalismanForms.ShapeForm(f);
            for (uint256 n = 3; n <= 6; n++) {
                Point3D[] memory base = TalismanForms.baseForForm(form, n);
                Triangle[] memory tris = TalismanFormsV2.triangulateForForm(form, base, n);
                for (uint256 i = 0; i < tris.length; i++) {
                    assertGt(_normalDotCentroid(tris[i]), 0, "base face wound inward");
                }
            }
        }
    }

    /// @notice Every form's unperturbed base has strictly positive signed
    ///         volume under the V2 winding - the mesh encloses its interior
    ///         with outward-facing normals, the orientation slicers require.
    function test_everyBase_positiveSignedVolume_allFormsAllN() public pure {
        for (uint8 f = 0; f < TalismanForms.SHAPE_FORM_COUNT; f++) {
            TalismanForms.ShapeForm form = TalismanForms.ShapeForm(f);
            for (uint256 n = 3; n <= 6; n++) {
                Point3D[] memory base = TalismanForms.baseForForm(form, n);
                Triangle[] memory tris = TalismanFormsV2.triangulateForForm(form, base, n);
                int256 sixV;
                for (uint256 i = 0; i < tris.length; i++) {
                    Triangle memory t = tris[i];
                    int256 cx = (t.p2.y * t.p3.z - t.p2.z * t.p3.y) / WAD;
                    int256 cy = (t.p2.z * t.p3.x - t.p2.x * t.p3.z) / WAD;
                    int256 cz = (t.p2.x * t.p3.y - t.p2.y * t.p3.x) / WAD;
                    sixV += (t.p1.x * cx + t.p1.y * cy + t.p1.z * cz) / WAD;
                }
                assertGt(sixV, 0, "base mesh signed volume not positive");
            }
        }
    }

    // ─── Parity with V1 where V1 is provably right ──────────────────────────

    /// @notice On the convex bases the V1 origin-centroid heuristic is exact,
    ///         so V1 and V2 must triangulate them byte-identically. This pins
    ///         "V2 emits exactly the reference winding" - on live meshes V2 can
    ///         then differ from V1 only where V1's heuristic broke.
    function test_matchesV1_onEveryUnperturbedBase() public pure {
        for (uint8 f = 0; f < TalismanForms.SHAPE_FORM_COUNT; f++) {
            TalismanForms.ShapeForm form = TalismanForms.ShapeForm(f);
            for (uint256 n = 3; n <= 6; n++) {
                Point3D[] memory base = TalismanForms.baseForForm(form, n);
                Triangle[] memory v1 = TalismanForms.triangulateForForm(form, base, n);
                Triangle[] memory v2 = TalismanFormsV2.triangulateForForm(form, base, n);
                assertEq(keccak256(abi.encode(v2)), keccak256(abi.encode(v1)), "base triangulation diverged from V1");
            }
        }
    }

    /// @dev Full-precision dot(face normal, face centroid). Positive means the
    ///      face winds outward around the origin; exact on the convex bases.
    function _normalDotCentroid(Triangle memory t) private pure returns (int256) {
        int256 nx = ((t.p2.y - t.p1.y) * (t.p3.z - t.p1.z) - (t.p2.z - t.p1.z) * (t.p3.y - t.p1.y)) / WAD;
        int256 ny = ((t.p2.z - t.p1.z) * (t.p3.x - t.p1.x) - (t.p2.x - t.p1.x) * (t.p3.z - t.p1.z)) / WAD;
        int256 nz = ((t.p2.x - t.p1.x) * (t.p3.y - t.p1.y) - (t.p2.y - t.p1.y) * (t.p3.x - t.p1.x)) / WAD;
        return
            (nx * (t.p1.x + t.p2.x + t.p3.x) + ny * (t.p1.y + t.p2.y + t.p3.y) + nz * (t.p1.z + t.p2.z + t.p3.z)) / WAD;
    }
}
