// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Material, Point3D, Triangle} from "./TalismanStructs.sol";
import {TalismanForms} from "./TalismanForms.sol";
import {TalismanFormsV2} from "./TalismanFormsV2.sol";
import {VIEWPORT_RADIUS} from "./TalismanGenerator.sol";
import {TalismanMaterials} from "./TalismanMaterials.sol";

/// @title TalismanGeneratorV2
/// @notice Deterministic brilliant-cut gem generator. From a talisman's packed
///         identity it drives the per-form geometry pipeline, fits the mesh to
///         the viewport, then bakes a per-triangle face color from the material
///         record in {TalismanMaterials}. The facet tier sets the polygon
///         count, so rarity reads in the geometry.
/// @dev Deployed as a standalone contract so callers reach the pipeline via an
///      external call rather than inlining the full generator + forms code into
///      every consumer. Triangulation comes from {TalismanFormsV2}, so every
///      emitted mesh is closed and consistently outward-wound.
contract TalismanGeneratorV2 {
    // ---- Fixed-point constants ----

    int256 private constant WAD = 1e18;
    uint256 private constant WAD_UINT = 1e18;

    // ---- Facet tier (rarity controls polygon count) ----

    enum FacetTier {
        Raw, // N=3 -> 16 triangles, sharp triangular cut
        Cut, // N=4 -> 22 triangles, square cut
        Fine, // N=5 -> 28 triangles, pentagonal brilliant
        Prime // N=6 -> 34 triangles, hexagonal brilliant - rarest
    }

    // ---- Output ----

    struct Talisman {
        Triangle[] triangles;
        Material[] materials;
        uint8 materialId;
        uint8 chroma;
        uint8 facetTier;
        uint8 shapeForm;
        /// @dev Number of cores composing this talisman. Derived as
        ///      `(facetTier + 1)` for Lithic/Lumic essences and
        ///      `2 * (facetTier + 1)` for Mythic essence - Mythic requires one
        ///      core from each of the Lithic and Lumic poles to form, so the
        ///      core count doubles. Cores is the storage-canonical rarity
        ///      signal; `facetTier` is the derived label via `tierFromCores`.
        uint8 cores;
        uint256 vertexCount;
        int256 maxRadius;
        /// @dev Approximate mesh volume in WAD cubic units. Computed via signed
        ///      tetrahedra from origin - exact for star-shaped closed meshes, which
        ///      talismans are. Gives a sense of scale.
        uint256 volume;
        /// @dev Full material record from {TalismanMaterials}. Off-chain consumers
        ///      read every material facet through this field without re-fetching
        ///      from the materials library.
        TalismanMaterials.Material material;
    }

    // ---- Entry points ----

    /// @notice Deterministically generate a talisman from its packed identity. The
    ///         six inputs fully determine the output - no external seed, no rarity
    ///         picks, no implicit table lookups. The caller (Talismans.reveal) owns
    ///         picking these values upstream.
    /// @param mat The material record, fetched by the caller from {TalismanMaterials}.
    /// @param materialId The material's index in {TalismanMaterials}.
    /// @param form The shape form to build.
    /// @param cores The talisman's core count, its canonical rarity signal.
    /// @param tier The facet tier (Raw/Cut/Fine/Prime) driving the polygon count.
    /// @param seed The 16-bit entropy stored in the token core.
    /// @return The fully generated talisman: geometry, baked colors, and metrics.
    /// @dev The generator is pure so a library call site keeps its inlined-internal
    ///      calling convention; `mat` is passed in rather than fetched here. `seed`
    ///      is hashed once with a domain tag into the internal `root` consumed by the
    ///      geometry and color picks, keeping that stream disjoint from other uses.
    function generate(
        TalismanMaterials.Material memory mat,
        uint8 materialId,
        TalismanForms.ShapeForm form,
        uint8 cores,
        FacetTier tier,
        uint16 seed
    ) external pure returns (Talisman memory) {
        return _generateFor(_rootFromSeed(seed), tier, cores, materialId, form, mat);
    }

    /// @dev Domain-tagged expansion of the 16-bit core seed into the bytes32
    ///      root consumed by the geometry and color picks; the tag keeps this
    ///      stream disjoint from any other use of `seed`. Its version names the
    ///      seed stream, not this contract, and is part of every token's
    ///      identity - changing it regenerates every talisman.
    function _rootFromSeed(uint16 seed) private pure returns (bytes32) {
        return keccak256(abi.encode(uint256(seed), "talisman/seed/v1"));
    }

    /// @notice Core count for a given facet tier and essence. The base count is
    ///         `tier + 1` (Raw=1 .. Prime=4); Mythic essence doubles it to 2 / 4 / 6 / 8,
    ///         since a Mythic talisman forms from one core of each of the Lithic and
    ///         Lumic poles.
    /// @param tier The facet tier (Raw/Cut/Fine/Prime).
    /// @param essence The material essence (Lithic, Lumic, or Mythic).
    /// @return The number of cores.
    /// @dev Single source of truth for the cores mapping; inverse of {tierFromCores}.
    function coresForTier(FacetTier tier, TalismanMaterials.Essence essence) external pure returns (uint8) {
        uint8 base = uint8(tier) + 1;
        if (essence == TalismanMaterials.Essence.Mythic) {
            return base * 2;
        }
        return base;
    }

    /// @notice Recover the facet tier from a talisman's core count and essence,
    ///         undoing the Mythic doubling. Cores is the canonical rarity signal;
    ///         tier is its derived label.
    /// @param cores The talisman's core count.
    /// @param essence The material essence (Lithic, Lumic, or Mythic).
    /// @return The facet tier.
    /// @dev Inverse of {coresForTier}. Reverts via enum bounds if `cores` is outside
    ///      the legal { 1..4, 2/4/6/8 } range for the supplied essence.
    function tierFromCores(uint8 cores, TalismanMaterials.Essence essence) external pure returns (FacetTier) {
        uint8 base = essence == TalismanMaterials.Essence.Mythic ? cores / 2 : cores;
        return FacetTier(base - 1);
    }

    /// @notice The human-readable name of a facet tier ("Raw", "Cut", "Fine", "Prime").
    /// @param t The facet tier.
    /// @return The tier's display name.
    function facetTierName(FacetTier t) external pure returns (string memory) {
        if (t == FacetTier.Raw) {
            return "Raw";
        }
        if (t == FacetTier.Cut) {
            return "Cut";
        }
        if (t == FacetTier.Fine) {
            return "Fine";
        }
        return "Prime";
    }

    function _generateFor(
        bytes32 root,
        FacetTier tier,
        uint8 cores,
        uint8 materialId,
        TalismanForms.ShapeForm form,
        TalismanMaterials.Material memory mat
    ) private pure returns (Talisman memory tal) {
        tal.facetTier = uint8(tier);
        tal.cores = cores;
        tal.shapeForm = uint8(form);

        uint256 N = uint256(tier) + 3;
        Point3D[] memory base = TalismanForms.baseForForm(form, N);
        tal.vertexCount = base.length;
        Point3D[] memory pts = TalismanForms.perturb(root, base, form);
        pts = _centerByBoundingBox(pts);
        pts = _fitToViewport(pts);
        tal.triangles = TalismanFormsV2.triangulateForForm(form, pts, N);
        tal.triangles = _centerTrianglesByBoundingBox(tal.triangles);
        tal.triangles = _scaleTriangles(tal.triangles, TalismanForms.sizeBoost(form));

        tal.materialId = materialId;
        tal.material = mat;
        tal.chroma = uint8(mat.chroma);
        tal.materials = _bakeColors(tal.triangles, mat, tier, root, mat.chroma, N);
        tal.maxRadius = _meshMaxRadius(tal.triangles);
        tal.volume = _meshVolume(tal.triangles);
    }

    // ---- Mesh metrics ----

    /// @dev Approximate mesh volume via signed tetrahedra formed by each triangle and
    ///      the origin: V = (1/6) * sum |p1 * (p2 x p3)|. Magnitude per-triangle keeps the
    ///      result positive even for skew meshes where winding drifts. Exact for convex
    ///      star-shaped meshes, which talismans are post-fit. Output is in WAD cubic units
    ///      (same scale as coordinates) - divide by WAD at the display layer for a readable
    ///      number (e.g. ~33 for a unit-radius sphere viewport fill).
    function _meshVolume(Triangle[] memory tris) private pure returns (uint256) {
        uint256 sixV;
        for (uint256 i = 0; i < tris.length; i++) {
            Triangle memory t = tris[i];
            int256 cx = (t.p2.y * t.p3.z - t.p2.z * t.p3.y) / WAD;
            int256 cy = (t.p2.z * t.p3.x - t.p2.x * t.p3.z) / WAD;
            int256 cz = (t.p2.x * t.p3.y - t.p2.y * t.p3.x) / WAD;
            int256 dot = (t.p1.x * cx + t.p1.y * cy + t.p1.z * cz) / WAD;
            sixV += dot >= 0 ? uint256(dot) : uint256(-dot);
        }
        return sixV / 6;
    }

    /// @dev True bounding-sphere radius from origin after all mesh transforms. Captures both
    ///      the bbox-centering shift and per-form size boost so the camera can frame the
    ///      actual silhouette instead of a stale nominal viewport radius.
    function _meshMaxRadius(Triangle[] memory tris) private pure returns (int256) {
        uint256 maxSq;
        for (uint256 i = 0; i < tris.length; i++) {
            maxSq = _updateMaxSq(maxSq, tris[i].p1);
            maxSq = _updateMaxSq(maxSq, tris[i].p2);
            maxSq = _updateMaxSq(maxSq, tris[i].p3);
        }
        return int256(FixedPointMathLib.sqrt(maxSq));
    }

    function _updateMaxSq(uint256 cur, Point3D memory p) private pure returns (uint256) {
        uint256 ss = uint256(p.x * p.x + p.y * p.y + p.z * p.z);
        return ss > cur ? ss : cur;
    }

    // ---- Centering + viewport fit ----

    function _centerByBoundingBox(Point3D[] memory pts) private pure returns (Point3D[] memory out) {
        int256 minX = pts[0].x;
        int256 maxX = pts[0].x;
        int256 minY = pts[0].y;
        int256 maxY = pts[0].y;
        int256 minZ = pts[0].z;
        int256 maxZ = pts[0].z;
        for (uint256 i = 1; i < pts.length; i++) {
            if (pts[i].x < minX) {
                minX = pts[i].x;
            }
            if (pts[i].x > maxX) {
                maxX = pts[i].x;
            }
            if (pts[i].y < minY) {
                minY = pts[i].y;
            }
            if (pts[i].y > maxY) {
                maxY = pts[i].y;
            }
            if (pts[i].z < minZ) {
                minZ = pts[i].z;
            }
            if (pts[i].z > maxZ) {
                maxZ = pts[i].z;
            }
        }
        int256 midX = (minX + maxX) / 2;
        int256 midY = (minY + maxY) / 2;
        int256 midZ = (minZ + maxZ) / 2;
        out = new Point3D[](pts.length);
        for (uint256 i = 0; i < pts.length; i++) {
            out[i] = Point3D({x: pts[i].x - midX, y: pts[i].y - midY, z: pts[i].z - midZ});
        }
    }

    function _fitToViewport(Point3D[] memory pts) private pure returns (Point3D[] memory out) {
        int256 maxSq;
        for (uint256 i = 0; i < pts.length; i++) {
            int256 ss = pts[i].x * pts[i].x + pts[i].y * pts[i].y + pts[i].z * pts[i].z;
            if (ss > maxSq) {
                maxSq = ss;
            }
        }
        uint256 maxLen = FixedPointMathLib.sqrt(uint256(maxSq));
        if (maxLen == 0) {
            return pts;
        }
        int256 fit = int256((uint256(VIEWPORT_RADIUS) * WAD_UINT) / maxLen);
        out = new Point3D[](pts.length);
        for (uint256 i = 0; i < pts.length; i++) {
            out[i] = Point3D({x: (pts[i].x * fit) / WAD, y: (pts[i].y * fit) / WAD, z: (pts[i].z * fit) / WAD});
        }
    }

    /// @dev Final centering pass on the triangulated mesh: translate every vertex so the
    ///      axis-aligned bounding box midpoint sits at origin. Guarantees visual symmetry
    ///      on screen, at the cost of the
    ///      mass-center being slightly off origin for asymmetric silhouettes.
    function _centerTrianglesByBoundingBox(Triangle[] memory tris) private pure returns (Triangle[] memory out) {
        int256 minX = tris[0].p1.x;
        int256 maxX = minX;
        int256 minY = tris[0].p1.y;
        int256 maxY = minY;
        int256 minZ = tris[0].p1.z;
        int256 maxZ = minZ;
        for (uint256 i = 0; i < tris.length; i++) {
            Triangle memory t = tris[i];
            (minX, maxX) = _updateRange(t.p1.x, minX, maxX);
            (minY, maxY) = _updateRange(t.p1.y, minY, maxY);
            (minZ, maxZ) = _updateRange(t.p1.z, minZ, maxZ);
            (minX, maxX) = _updateRange(t.p2.x, minX, maxX);
            (minY, maxY) = _updateRange(t.p2.y, minY, maxY);
            (minZ, maxZ) = _updateRange(t.p2.z, minZ, maxZ);
            (minX, maxX) = _updateRange(t.p3.x, minX, maxX);
            (minY, maxY) = _updateRange(t.p3.y, minY, maxY);
            (minZ, maxZ) = _updateRange(t.p3.z, minZ, maxZ);
        }
        Point3D memory mid = Point3D({x: (minX + maxX) / 2, y: (minY + maxY) / 2, z: (minZ + maxZ) / 2});
        out = new Triangle[](tris.length);
        for (uint256 i = 0; i < tris.length; i++) {
            out[i] = _shiftTriangle(tris[i], mid);
        }
    }

    function _shiftTriangle(Triangle memory t, Point3D memory shift) private pure returns (Triangle memory) {
        return Triangle({
            p1: Point3D({x: t.p1.x - shift.x, y: t.p1.y - shift.y, z: t.p1.z - shift.z}),
            p2: Point3D({x: t.p2.x - shift.x, y: t.p2.y - shift.y, z: t.p2.z - shift.z}),
            p3: Point3D({x: t.p3.x - shift.x, y: t.p3.y - shift.y, z: t.p3.z - shift.z}),
            materialId: t.materialId
        });
    }

    function _scaleTriangles(Triangle[] memory tris, int256 scale) private pure returns (Triangle[] memory out) {
        if (scale == WAD) {
            return tris;
        }
        out = new Triangle[](tris.length);
        for (uint256 i = 0; i < tris.length; i++) {
            Triangle memory t = tris[i];
            out[i] = Triangle({
                p1: Point3D({x: (t.p1.x * scale) / WAD, y: (t.p1.y * scale) / WAD, z: (t.p1.z * scale) / WAD}),
                p2: Point3D({x: (t.p2.x * scale) / WAD, y: (t.p2.y * scale) / WAD, z: (t.p2.z * scale) / WAD}),
                p3: Point3D({x: (t.p3.x * scale) / WAD, y: (t.p3.y * scale) / WAD, z: (t.p3.z * scale) / WAD}),
                materialId: t.materialId
            });
        }
    }

    function _updateRange(int256 v, int256 lo, int256 hi) private pure returns (int256, int256) {
        if (v < lo) {
            lo = v;
        }
        if (v > hi) {
            hi = v;
        }
        return (lo, hi);
    }

    // ---- Quantized material coloring + per-facet jitter ----

    /// @dev Discrete band count per tier. Drives the stepped color grammar so tier reads
    ///      in the facet-to-facet hue transitions, not just polygon count.
    function _bandsForTier(FacetTier t) private pure returns (uint256) {
        if (t == FacetTier.Raw) {
            return 4;
        }
        if (t == FacetTier.Cut) {
            return 5;
        }
        return 6;
    }

    /// @dev Coloring dispatcher. Mono/Poly materials are baked vertically (Y-banded
    ///      across the 8-stop ramp) with a small per-slot offset that gives adjacent
    ///      azimuth facets slightly different stops in the same band - a subtle
    ///      prismatic shimmer without breaking the gem's depth read. Variegated
    ///      materials are baked regionally - each triangle picks a color from the pool
    ///      by its (layer, azimuth slot) coordinates so adjacent facets carry distinct
    ///      hues regardless of Y.
    function _bakeColors(
        Triangle[] memory tris,
        TalismanMaterials.Material memory mat,
        FacetTier tier,
        bytes32 root,
        TalismanMaterials.Chroma chr,
        uint256 N
    ) private pure returns (Material[] memory mats) {
        if (chr == TalismanMaterials.Chroma.Variegated) {
            return _bakeColorsRegional(tris, mat, root, N);
        }
        return _bakeColorsRamp(tris, mat, tier, root, N);
    }

    function _bakeColorsRamp(
        Triangle[] memory tris,
        TalismanMaterials.Material memory mat,
        FacetTier tier,
        bytes32 root,
        uint256 N
    ) private pure returns (Material[] memory mats) {
        mats = new Material[](tris.length);
        int256 range = VIEWPORT_RADIUS;
        uint256 bands = _bandsForTier(tier);
        bool jitter = !_isUniformMaterial(mat);
        for (uint256 i = 0; i < tris.length; i++) {
            (, uint256 slot) = _layerSlot(i, N);
            uint32 baseColor = _rampColorForTriangle(tris[i], mat, range, bands, slot);
            mats[i] =
                Material({color: jitter ? _jitterColor(baseColor, keccak256(abi.encode(root, "jit", i))) : baseColor});
        }
    }

    /// @dev Y-banded ramp pick with a slot-driven +/-1-stop offset. Lowest vertex picks
    ///      the band; band index maps to a stop in the 8-color ramp evenly; the
    ///      triangle's azimuth slot then nudges that stop by -1, 0, or +1 (cycling
    ///      slot % 3 -> -1/0/+1). Triangles in the same band but different azimuth
    ///      slots therefore land on slightly different ramp stops - same hue family,
    ///      just different toning - so a Diamond reads prismatic instead of three
    ///      flat rings, and Monoliths get faint stripe variation instead of solid
    ///      bands. The offset is small enough that the underlying gem-depth read
    ///      (top brilliant, bot deep) still dominates.
    function _rampColorForTriangle(
        Triangle memory t,
        TalismanMaterials.Material memory mat,
        int256 range,
        uint256 bands,
        uint256 slot
    ) private pure returns (uint32) {
        int256 cy = t.p1.y;
        if (t.p2.y < cy) {
            cy = t.p2.y;
        }
        if (t.p3.y < cy) {
            cy = t.p3.y;
        }
        uint256 tWad;
        if (cy >= range) {
            tWad = WAD_UINT;
        } else if (cy <= -range) {
            tWad = 0;
        } else {
            tWad = (uint256(cy + range) * WAD_UINT) / uint256(2 * range);
        }
        uint256 bucket = (tWad * bands) / WAD_UINT;
        if (bucket >= bands) {
            bucket = bands - 1;
        }
        // bucket=0 (low Y) -> bot (colors[7]); bucket=bands-1 (high Y) -> top (colors[0]).
        uint256 baseStop = bands <= 1 ? 4 : 7 - (bucket * 7) / (bands - 1);
        // Slot-driven offset in {-1, 0, +1}. Cycles through every three azimuth slots.
        int256 offset = int256(slot % 3) - 1;
        int256 stop = int256(baseStop) + offset;
        if (stop < 0) {
            stop = 0;
        }
        if (stop > 7) {
            stop = 7;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return mat.colors[uint256(stop)];
    }

    /// @dev Regional pick for Variegated materials. Pool is authored top-to-bot (light ->
    ///      dark) so adjacent indices are perceptually close. The bake assigns each
    ///      azimuth slot to a distinct pool index - `idx = startIdx + slot` - using a
    ///      contiguous N-color slice of the 8-color pool (no mod-8 wrap-around between
    ///      perceptually distant stops). Layer is intentionally ignored: triangles in
    ///      the same slot share one color from cap to culet, so each stripe reads as
    ///      one segment top-to-bot. The per-token salt picks which slice to use, so
    ///      different tokens of the same material get different stripe arrangements.
    function _bakeColorsRegional(Triangle[] memory tris, TalismanMaterials.Material memory mat, bytes32 root, uint256 N)
        private
        pure
        returns (Material[] memory mats)
    {
        mats = new Material[](tris.length);
        // Contiguous slice of length N out of an 8-stop pool: startIdx in [0, 8 - N].
        uint256 maxStart = 9 - N; // 8 - N + 1
        uint256 startIdx = uint256(keccak256(abi.encode(root, "region"))) % maxStart;
        bool jitter = !_isUniformMaterial(mat);
        for (uint256 i = 0; i < tris.length; i++) {
            (, uint256 slot) = _layerSlot(i, N);
            uint256 idx = startIdx + slot;
            if (idx > 7) {
                idx = 7;
            }
            uint32 baseColor = mat.colors[idx];
            mats[i] =
                Material({color: jitter ? _jitterColor(baseColor, keccak256(abi.encode(root, "jit", i))) : baseColor});
        }
    }

    /// @dev True when every material stop is the same color. Lets uniform materials
    ///      (e.g. Deadform, Foxfire) opt out of the per-triangle +/-5% jitter so the gem
    ///      reads as a true monolith rather than a faintly noisy field.
    function _isUniformMaterial(TalismanMaterials.Material memory mat) private pure returns (bool) {
        uint32 c = mat.colors[0];
        for (uint256 i = 1; i < 8; i++) {
            if (mat.colors[i] != c) {
                return false;
            }
        }
        return true;
    }

    /// @dev Maps a triangulation index to the topological (layer, slot) it belongs to.
    ///      Layout matches the brilliant-cut triangulator: table cap (N-2),
    ///      table<->crown antiprism (2 per slot, N slots), crown<->pavilion quads
    ///      (2 per slot, N slots), pavilion->culet cone (1 per slot, N slots).
    function _layerSlot(uint256 triIdx, uint256 N) private pure returns (uint256 layer, uint256 slot) {
        uint256 tableEnd = N - 2;
        uint256 antiprismEnd = tableEnd + 2 * N; // 3N - 2
        uint256 quadsEnd = antiprismEnd + 2 * N; // 5N - 2
        if (triIdx < tableEnd) {
            return (0, triIdx);
        }
        if (triIdx < antiprismEnd) {
            return (1, (triIdx - tableEnd) / 2);
        }
        if (triIdx < quadsEnd) {
            return (2, (triIdx - antiprismEnd) / 2);
        }
        return (3, triIdx - quadsEnd);
    }

    /// @dev Multiplies all RGB channels by a scalar in [0.95, 1.05] seeded per-face.
    ///      Hue-preserving - single scalar across RGB keeps the material identity intact.
    function _jitterColor(uint32 color, bytes32 h) private pure returns (uint32) {
        uint256 jit = TalismanForms.rangeWad(h, 0.95e18, 1.05e18);
        uint256 r = (((color >> 16) & 0xFF) * jit) / WAD_UINT;
        uint256 g = (((color >> 8) & 0xFF) * jit) / WAD_UINT;
        uint256 b = ((color & 0xFF) * jit) / WAD_UINT;
        if (r > 255) {
            r = 255;
        }
        if (g > 255) {
            g = 255;
        }
        if (b > 255) {
            b = 255;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32((r << 16) | (g << 8) | b);
    }
}
