// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Trigonometry} from "solidity-trigonometry/Trigonometry.sol";
import {Point3D, Triangle} from "./TalismanStructs.sol";

/// @title TalismanForms
/// @dev Shape-form catalog and brilliant-cut geometry pipeline. Owns the
///      `ShapeForm` enum, per-form base-vertex layouts, perturbation ranges,
///      triangulation, and the post-fit size boost. Generator drives the
///      pipeline; this library carries everything that depends on a form.
library TalismanForms {
    // ---- Fixed-point ----

    int256 internal constant WAD = 1e18;
    uint256 internal constant WAD_UINT = 1e18;
    int256 internal constant TWO_PI = 6283185307179586476;

    // ---- Shape forms ----

    /// @dev Number of entries in the {ShapeForm} enum. Off-chain
    ///      configurators and on-chain pickers read this so a new form is
    ///      a single-line edit to the enum plus a bump here.
    uint8 internal constant SHAPE_FORM_COUNT = 14;

    /// @dev Each form is a different proportion/perturbation preset on the
    ///      brilliant-cut topology (table + crown + pavilion + culet).
    enum ShapeForm {
        Brilliant, // classic 4-layer cut
        Cushion, // wider table, fuller pavilion, shallow culet - rounded gem
        Pendant, // elongated - narrow girdle, deep pavilion, sharp culet
        Block, // small table + wide girdle - crisp, sharp corners feel
        Dome, // high narrow table + broad shoulders + shallow pavilion
        Shard, // brilliant topology with aggressive axis skew + radial perturbation
        Jagged, // brilliant topology with heavy radial jitter - roughened crystal
        Orb, // near-spherical - huge table, wide pavilion, very shallow culet
        Dagger, // super-elongated - thin crown, extra-deep sharp culet
        Teardrop, // wide rounded top, slim bottom, long culet
        Cluster, // brilliant base with heavy per-vertex radial jitter - broken cluster feel
        Geode, // lumpy rounded crystal - orb-ish base with aggressive asymmetric jitter
        Rock, // deformed blob: rounded base + heavy axis skew, never angular
        Husk // rocky chunk with heavier radial + axial jitter than Rock/Geode
    }

    // ---- Base brilliant-cut proportions (unit scale; shared across most forms) ----

    int256 private constant TABLE_Y = 0.6e18;
    int256 private constant TABLE_R = 0.48e18;
    int256 private constant CROWN_Y = 0.22e18;
    int256 private constant CROWN_R = 1.0e18; // widest ring (girdle)
    int256 private constant PAVILION_Y = -0.38e18;
    int256 private constant PAVILION_R = 0.62e18;
    int256 private constant CULET_Y = -1.0e18;

    /// @dev Human-readable form name, surfaced as the token's Form trait. Single
    ///      source of truth so adding a form is a one-line edit here next to the
    ///      enum.
    function shapeFormName(ShapeForm form) internal pure returns (string memory) {
        if (form == ShapeForm.Brilliant) {
            return "Brilliant";
        }
        if (form == ShapeForm.Cushion) {
            return "Cushion";
        }
        if (form == ShapeForm.Pendant) {
            return "Pendant";
        }
        if (form == ShapeForm.Block) {
            return "Block";
        }
        if (form == ShapeForm.Dome) {
            return "Dome";
        }
        if (form == ShapeForm.Shard) {
            return "Shard";
        }
        if (form == ShapeForm.Jagged) {
            return "Jagged";
        }
        if (form == ShapeForm.Orb) {
            return "Orb";
        }
        if (form == ShapeForm.Dagger) {
            return "Dagger";
        }
        if (form == ShapeForm.Teardrop) {
            return "Teardrop";
        }
        if (form == ShapeForm.Cluster) {
            return "Cluster";
        }
        if (form == ShapeForm.Geode) {
            return "Geode";
        }
        if (form == ShapeForm.Rock) {
            return "Rock";
        }
        return "Husk";
    }

    // ---- Public pipeline ----

    /// @dev Builds the base vertex layout for `form` at ring resolution `N`
    ///      (one ring point per azimuth slot, 3 rings + culet = 3N + 1 vertices).
    function baseForForm(ShapeForm form, uint256 N) internal pure returns (Point3D[] memory) {
        if (form == ShapeForm.Cushion) {
            return _baseCushion(N);
        }
        if (form == ShapeForm.Pendant) {
            return _basePendant(N);
        }
        if (form == ShapeForm.Block) {
            return _baseBlock(N);
        }
        if (form == ShapeForm.Dome) {
            return _baseDome(N);
        }
        if (form == ShapeForm.Orb) {
            return _baseOrb(N);
        }
        if (form == ShapeForm.Dagger) {
            return _baseDagger(N);
        }
        if (form == ShapeForm.Teardrop) {
            return _baseTeardrop(N);
        }
        if (form == ShapeForm.Geode) {
            return _baseGeode(N);
        }
        if (form == ShapeForm.Rock) {
            return _baseRock(N);
        }
        if (form == ShapeForm.Husk) {
            return _baseHusk(N);
        }
        return _baseBrilliant(N); // Brilliant / Shard / Jagged / Cluster share base layout
    }

    /// @dev Applies per-form radial + anisotropic axis scaling to a pre-built base.
    function perturb(bytes32 root, Point3D[] memory base, ShapeForm form) internal pure returns (Point3D[] memory pts) {
        PerturbParams memory p = _perturbParams(root, form);
        pts = new Point3D[](base.length);
        for (uint256 i = 0; i < base.length; i++) {
            int256 radial = int256(rangeWad(keccak256(abi.encode(root, "pt", i)), WAD_UINT - p.amp, WAD_UINT + p.amp));
            pts[i] = _applyScale(base[i], radial, p);
        }
    }

    /// @dev Builds the triangulation for the brilliant-cut topology. Every form
    ///      currently shares the same triangulator - proportions vary; topology
    ///      does not.
    function triangulateForForm(ShapeForm form, Point3D[] memory pts, uint256 N)
        internal
        pure
        returns (Triangle[] memory)
    {
        form; // silence unused - every form routes through the brilliant-cut triangulator
        return _triangulate(pts, N);
    }

    /// @dev Per-form silhouette boost applied after centering + fit. Lumpy / boulder
    ///      forms scale up more aggressively so their tightened bounding box still
    ///      reads as bigger than the gem-shaped forms; Cluster and Dome get a small
    ///      lift so their distinct silhouettes don't undersize.
    function sizeBoost(ShapeForm form) internal pure returns (int256) {
        if (form == ShapeForm.Rock) {
            return 1.914e18;
        }
        if (form == ShapeForm.Husk) {
            return 2.15e18;
        }
        if (form == ShapeForm.Geode) {
            return 1.452e18;
        }
        if (form == ShapeForm.Cluster) {
            return 1.518e18;
        }
        if (form == ShapeForm.Dome) {
            return 1.254e18;
        }
        return 1.32e18;
    }

    // ---- Perturbation ----

    struct PerturbParams {
        uint256 amp;
        int256 sx;
        int256 sy;
        int256 sz;
    }

    function _perturbParams(bytes32 root, ShapeForm form) private pure returns (PerturbParams memory p) {
        (uint256 ampMin, uint256 ampMax, uint256 axMin, uint256 axMax) = _perturbRanges(form);
        p.amp = rangeWad(keccak256(abi.encode(root, "amp")), ampMin, ampMax);
        p.sx = int256(rangeWad(keccak256(abi.encode(root, "ax")), axMin, axMax));
        p.sy = int256(rangeWad(keccak256(abi.encode(root, "ay")), 0.9e18, 1.3e18));
        p.sz = int256(rangeWad(keccak256(abi.encode(root, "az")), axMin, axMax));
    }

    /// @dev Per-form perturbation ranges - Shard tilts axes hard, Jagged just jitters
    ///      radii, Cluster/Geode push radial amp harder for broken/lumpy crystal reads,
    ///      Rock uses moderate radial with heavy asymmetric axis stretch. Dagger and
    ///      Jagged carry tightened ranges to avoid silhouette-flipping perturbations
    ///      that opened back-face culled holes in earlier tunings.
    function _perturbRanges(ShapeForm form)
        private
        pure
        returns (uint256 ampMin, uint256 ampMax, uint256 axMin, uint256 axMax)
    {
        if (form == ShapeForm.Jagged) {
            return (0.25e18, 0.42e18, 0.85e18, 1.15e18);
        }
        if (form == ShapeForm.Shard) {
            return (0.15e18, 0.35e18, 0.65e18, 1.35e18);
        }
        if (form == ShapeForm.Cluster) {
            return (0.25e18, 0.45e18, 0.8e18, 1.2e18);
        }
        if (form == ShapeForm.Geode) {
            return (0.25e18, 0.45e18, 0.75e18, 1.25e18);
        }
        if (form == ShapeForm.Rock) {
            return (0.2e18, 0.4e18, 0.7e18, 1.3e18);
        }
        if (form == ShapeForm.Husk) {
            return (0.22e18, 0.42e18, 0.7e18, 1.32e18);
        }
        if (form == ShapeForm.Dagger) {
            return (0.04e18, 0.12e18, 0.93e18, 1.07e18);
        }
        return (0.08e18, 0.22e18, 0.85e18, 1.15e18);
    }

    function _applyScale(Point3D memory b, int256 radial, PerturbParams memory p)
        private
        pure
        returns (Point3D memory)
    {
        return Point3D({
            x: (((b.x * radial) / WAD) * p.sx) / WAD,
            y: (((b.y * radial) / WAD) * p.sy) / WAD,
            z: (((b.z * radial) / WAD) * p.sz) / WAD
        });
    }

    // ---- Base layouts ----

    function _baseBrilliant(uint256 N) private pure returns (Point3D[] memory b) {
        b = _baseBrilliantWith(N, TABLE_Y, TABLE_R, CROWN_Y, CROWN_R, PAVILION_Y, PAVILION_R, CULET_Y);
    }

    /// @dev Cushion - wider table, fuller pavilion, shallower culet.
    function _baseCushion(uint256 N) private pure returns (Point3D[] memory b) {
        b = _baseBrilliantWith(N, 0.55e18, 0.65e18, 0.2e18, 1.0e18, -0.35e18, 0.78e18, -0.85e18);
    }

    /// @dev Pendant - tall elongated brilliant: narrow girdle, deep pavilion, sharp culet.
    function _basePendant(uint256 N) private pure returns (Point3D[] memory b) {
        b = _baseBrilliantWith(N, 0.7e18, 0.4e18, 0.35e18, 0.85e18, -0.45e18, 0.55e18, -1.2e18);
    }

    /// @dev Block - small table + wide girdle, crisp silhouette.
    function _baseBlock(uint256 N) private pure returns (Point3D[] memory b) {
        b = _baseBrilliantWith(N, 0.55e18, 0.3e18, 0.18e18, 1.05e18, -0.3e18, 0.7e18, -0.9e18);
    }

    /// @dev Dome - high narrow table + broad shoulders; culet pulled deeper to shed the flat read.
    function _baseDome(uint256 N) private pure returns (Point3D[] memory b) {
        b = _baseBrilliantWith(N, 0.9e18, 0.25e18, 0.4e18, 0.95e18, -0.2e18, 0.85e18, -0.95e18);
    }

    /// @dev Orb - rounded gem; culet deepened so it no longer looks disc-flat.
    function _baseOrb(uint256 N) private pure returns (Point3D[] memory b) {
        b = _baseBrilliantWith(N, 0.5e18, 0.75e18, 0.15e18, 1.0e18, -0.35e18, 0.9e18, -0.9e18);
    }

    /// @dev Dagger - very elongated, thin, extra-deep sharp culet.
    function _baseDagger(uint256 N) private pure returns (Point3D[] memory b) {
        b = _baseBrilliantWith(N, 0.8e18, 0.3e18, 0.5e18, 0.7e18, -0.3e18, 0.45e18, -1.4e18);
    }

    /// @dev Teardrop - wide round top, slim tapering bottom, long culet.
    function _baseTeardrop(uint256 N) private pure returns (Point3D[] memory b) {
        b = _baseBrilliantWith(N, 0.75e18, 0.55e18, 0.45e18, 0.95e18, -0.1e18, 0.7e18, -1.1e18);
    }

    /// @dev Geode - lumpy rounded crystal, narrower girdle + deeper culet.
    function _baseGeode(uint256 N) private pure returns (Point3D[] memory b) {
        b = _baseBrilliantWith(N, 0.55e18, 0.55e18, 0.15e18, 0.85e18, -0.45e18, 0.8e18, -1.05e18);
    }

    /// @dev Rock - boulder with asymmetric axis skew. Base taller and narrower so
    ///      the default silhouette is closer to cube-proportioned before perturbation.
    function _baseRock(uint256 N) private pure returns (Point3D[] memory b) {
        b = _baseBrilliantWith(N, 0.55e18, 0.7e18, 0.1e18, 0.9e18, -0.5e18, 0.75e18, -1.15e18);
    }

    /// @dev Husk - same base proportions as Rock; unique perturb ranges define its
    ///      heavier silhouette.
    function _baseHusk(uint256 N) private pure returns (Point3D[] memory b) {
        b = _baseBrilliantWith(N, 0.55e18, 0.7e18, 0.1e18, 0.9e18, -0.5e18, 0.75e18, -1.15e18);
    }

    /// @dev Shared brilliant-topology base builder with per-form proportions.
    function _baseBrilliantWith(
        uint256 N,
        int256 tableY,
        int256 tableR,
        int256 crownY,
        int256 crownR,
        int256 pavY,
        int256 pavR,
        int256 culetY
    ) private pure returns (Point3D[] memory b) {
        b = new Point3D[](3 * N + 1);
        for (uint256 i = 0; i < N; i++) {
            b[i] = _ringVert((i * uint256(TWO_PI)) / N, tableY, tableR);
        }
        for (uint256 i = 0; i < N; i++) {
            b[N + i] = _ringVert(((2 * i + 1) * uint256(TWO_PI)) / (2 * N), crownY, crownR);
        }
        for (uint256 i = 0; i < N; i++) {
            b[2 * N + i] = _ringVert((i * uint256(TWO_PI)) / N, pavY, pavR);
        }
        b[3 * N] = Point3D({x: 0, y: culetY, z: 0});
    }

    function _ringVert(uint256 theta, int256 y, int256 r) private pure returns (Point3D memory) {
        int256 cosT = Trigonometry.cos(theta);
        int256 sinT = Trigonometry.sin(theta);
        return Point3D({x: (r * cosT) / WAD, y: y, z: (r * sinT) / WAD});
    }

    // ---- Triangulation (6N - 2 triangles) ----

    function _triangulate(Point3D[] memory pts, uint256 N) private pure returns (Triangle[] memory tris) {
        uint256 triCount = 6 * N - 2;
        tris = new Triangle[](triCount);
        uint256 w;
        uint256 culet = 3 * N;

        // Table cap - fan from vertex 0.
        for (uint256 i = 1; i < N - 1; i++) {
            tris[w] = _orientedTriangle(pts[0], pts[i], pts[i + 1], uint16(w));
            w++;
        }

        // Table <-> Crown antiprism (crown ring rotated half-segment).
        for (uint256 i = 0; i < N; i++) {
            uint256 tNext = (i + 1) % N;
            uint256 crown = N + i;
            uint256 crownPrev = N + ((i + N - 1) % N);
            tris[w] = _orientedTriangle(pts[i], pts[crownPrev], pts[crown], uint16(w));
            w++;
            tris[w] = _orientedTriangle(pts[i], pts[crown], pts[tNext], uint16(w));
            w++;
        }

        // Crown <-> Pavilion aligned quads.
        for (uint256 i = 0; i < N; i++) {
            uint256 crown = N + i;
            uint256 crownNext = N + ((i + 1) % N);
            uint256 pav = 2 * N + i;
            uint256 pavNext = 2 * N + ((i + 1) % N);
            tris[w] = _orientedTriangle(pts[crown], pts[pav], pts[pavNext], uint16(w));
            w++;
            tris[w] = _orientedTriangle(pts[crown], pts[pavNext], pts[crownNext], uint16(w));
            w++;
        }

        // Pavilion -> Culet cone.
        for (uint256 i = 0; i < N; i++) {
            uint256 pav = 2 * N + i;
            uint256 pavNext = 2 * N + ((i + 1) % N);
            tris[w] = _orientedTriangle(pts[pav], pts[culet], pts[pavNext], uint16(w));
            w++;
        }
    }

    function _orientedTriangle(Point3D memory p1, Point3D memory p2, Point3D memory p3, uint16 matId)
        private
        pure
        returns (Triangle memory)
    {
        if (_facesOutward(p1, p2, p3)) {
            return Triangle({p1: p1, p2: p2, p3: p3, materialId: matId});
        }
        return Triangle({p1: p1, p2: p3, p3: p2, materialId: matId});
    }

    function _facesOutward(Point3D memory p1, Point3D memory p2, Point3D memory p3) private pure returns (bool) {
        int256 nx = (p2.y - p1.y) * (p3.z - p1.z) - (p2.z - p1.z) * (p3.y - p1.y);
        int256 ny = (p2.z - p1.z) * (p3.x - p1.x) - (p2.x - p1.x) * (p3.z - p1.z);
        int256 nz = (p2.x - p1.x) * (p3.y - p1.y) - (p2.y - p1.y) * (p3.x - p1.x);
        int256 cx = p1.x + p2.x + p3.x;
        int256 cy = p1.y + p2.y + p3.y;
        int256 cz = p1.z + p2.z + p3.z;
        return (nx / WAD) * cx + (ny / WAD) * cy + (nz / WAD) * cz >= 0;
    }

    // ---- Misc ----

    /// @dev Uniform sample in [minWad, maxWad). Internal so Generator's jitter
    ///      and any other consumer can share one definition.
    function rangeWad(bytes32 h, uint256 minWad, uint256 maxWad) internal pure returns (uint256) {
        uint256 r = uint256(h) % WAD_UINT;
        return minWad + ((maxWad - minWad) * r) / WAD_UINT;
    }
}
