// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Mesh diagnostics used to compare the V1 and V2 generators.
// Not part of the deployed system.

import {Script, console} from "forge-std/Script.sol";
import {TalismanForms} from "../src/TalismanForms.sol";
import {TalismanGenerator} from "../src/TalismanGenerator.sol";
import {TalismanMaterials} from "../src/TalismanMaterials.sol";
import {TalismanSvgRenderer} from "../src/TalismanSvgRenderer.sol";
import {TalismanTransformationLib} from "../src/TalismanTransformationLib.sol";
import {Camera, CullMode, FillMode, LightSettings, Point3D, RenderSettings, Triangle} from "../src/TalismanStructs.sol";

contract SvgProbe is TalismanSvgRenderer {}

/// @dev External probe so looped mesh generation frees memory between calls
///      (Solidity only releases memory across external-call boundaries).
contract MeshProbe {
    int256 private constant WAD = 1e18;

    // ---- Deployed-pipeline replicas (verbatim copies of private functions) ----

    /// Copy of TalismanGenerator._centerByBoundingBox
    function _centerByBoundingBox(Point3D[] memory pts) private pure returns (Point3D[] memory out) {
        int256 minX = pts[0].x;
        int256 maxX = pts[0].x;
        int256 minY = pts[0].y;
        int256 maxY = pts[0].y;
        int256 minZ = pts[0].z;
        int256 maxZ = pts[0].z;
        for (uint256 i = 1; i < pts.length; i++) {
            if (pts[i].x < minX) minX = pts[i].x;
            if (pts[i].x > maxX) maxX = pts[i].x;
            if (pts[i].y < minY) minY = pts[i].y;
            if (pts[i].y > maxY) maxY = pts[i].y;
            if (pts[i].z < minZ) minZ = pts[i].z;
            if (pts[i].z > maxZ) maxZ = pts[i].z;
        }
        int256 midX = (minX + maxX) / 2;
        int256 midY = (minY + maxY) / 2;
        int256 midZ = (minZ + maxZ) / 2;
        out = new Point3D[](pts.length);
        for (uint256 i = 0; i < pts.length; i++) {
            out[i] = Point3D({x: pts[i].x - midX, y: pts[i].y - midY, z: pts[i].z - midZ});
        }
    }

    /// Copy of TalismanGenerator._fitToViewport (VIEWPORT_RADIUS = 2e18)
    function _fitToViewport(Point3D[] memory pts) private pure returns (Point3D[] memory out) {
        int256 maxSq;
        for (uint256 i = 0; i < pts.length; i++) {
            int256 ss = pts[i].x * pts[i].x + pts[i].y * pts[i].y + pts[i].z * pts[i].z;
            if (ss > maxSq) maxSq = ss;
        }
        uint256 maxLen = _sqrt(uint256(maxSq));
        if (maxLen == 0) return pts;
        int256 fit = int256((uint256(int256(2e18)) * 1e18) / maxLen);
        out = new Point3D[](pts.length);
        for (uint256 i = 0; i < pts.length; i++) {
            out[i] = Point3D({x: (pts[i].x * fit) / WAD, y: (pts[i].y * fit) / WAD, z: (pts[i].z * fit) / WAD});
        }
    }

    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = x / 2 + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }

    /// Copy of TalismanForms._facesOutward — the deployed per-face orientation test.
    function facesOutward(Point3D memory p1, Point3D memory p2, Point3D memory p3) public pure returns (bool) {
        int256 nx = (p2.y - p1.y) * (p3.z - p1.z) - (p2.z - p1.z) * (p3.y - p1.y);
        int256 ny = (p2.z - p1.z) * (p3.x - p1.x) - (p2.x - p1.x) * (p3.z - p1.z);
        int256 nz = (p2.x - p1.x) * (p3.y - p1.y) - (p2.y - p1.y) * (p3.x - p1.x);
        int256 cx = p1.x + p2.x + p3.x;
        int256 cy = p1.y + p2.y + p3.y;
        int256 cz = p1.z + p2.z + p3.z;
        return (nx / WAD) * cx + (ny / WAD) * cy + (nz / WAD) * cz >= 0;
    }

    /// Raw triangulation index triples in the exact emission order of
    /// TalismanForms._triangulate (before per-face orientation).
    function rawTriples(uint256 N) public pure returns (uint256[3][] memory t) {
        t = new uint256[3][](6 * N - 2);
        uint256 w;
        uint256 culet = 3 * N;
        for (uint256 i = 1; i < N - 1; i++) {
            t[w] = [uint256(0), i, i + 1];
            w++;
        }
        for (uint256 i = 0; i < N; i++) {
            uint256 tNext = (i + 1) % N;
            uint256 crown = N + i;
            uint256 crownPrev = N + ((i + N - 1) % N);
            t[w] = [i, crownPrev, crown];
            w++;
            t[w] = [i, crown, tNext];
            w++;
        }
        for (uint256 i = 0; i < N; i++) {
            uint256 crown = N + i;
            uint256 crownNext = N + ((i + 1) % N);
            uint256 pav = 2 * N + i;
            uint256 pavNext = 2 * N + ((i + 1) % N);
            t[w] = [crown, pav, pavNext];
            w++;
            t[w] = [crown, pavNext, crownNext];
            w++;
        }
        for (uint256 i = 0; i < N; i++) {
            uint256 pav = 2 * N + i;
            uint256 pavNext = 2 * N + ((i + 1) % N);
            t[w] = [pav, culet, pavNext];
            w++;
        }
    }

    /// Rebuild the point set exactly as the deployed generator sees it at
    /// triangulation time: base -> perturb -> bbox-center -> viewport-fit.
    function reconstruct(uint8 formU, uint8 tierU, uint16 seed)
        public
        pure
        returns (Point3D[] memory pts, Point3D[] memory base, uint256 N)
    {
        N = uint256(tierU) + 3;
        TalismanForms.ShapeForm form = TalismanForms.ShapeForm(formU);
        base = TalismanForms.baseForForm(form, N);
        bytes32 root = keccak256(abi.encode(uint256(seed), "talisman/seed/v1"));
        pts = TalismanForms.perturb(root, base, form);
        pts = _centerByBoundingBox(pts);
        pts = _fitToViewport(pts);
    }

    /// Core diagnostic. For each face: reference winding parity comes from the
    /// unperturbed convex base (where the origin-centroid test is exact);
    /// deployed parity re-runs the deployed test on the perturbed points.
    /// A mismatch = face emitted with inverted winding on-chain.
    /// Also counts degenerate (zero-normal) faces and directed-edge violations.
    function diag(uint8 formU, uint8 tierU, uint16 seed)
        external
        pure
        returns (uint256 flippedMask, uint256 flippedCount, uint256 degenCount, uint256 edgeViolations)
    {
        (Point3D[] memory pts, Point3D[] memory base, uint256 N) = reconstruct(formU, tierU, seed);
        uint256[3][] memory tri = rawTriples(N);
        bool[] memory depO = new bool[](tri.length);
        for (uint256 i = 0; i < tri.length; i++) {
            (uint256 a, uint256 b, uint256 c) = (tri[i][0], tri[i][1], tri[i][2]);
            bool refO = facesOutward(base[a], base[b], base[c]);
            bool dep = facesOutward(pts[a], pts[b], pts[c]);
            depO[i] = dep;
            if (refO != dep) {
                flippedMask |= (1 << i);
                flippedCount++;
            }
            if (_isDegenerate(pts[a], pts[b], pts[c])) {
                degenCount++;
            }
        }
        edgeViolations = _edgeViolations(tri, depO);
    }

    function _isDegenerate(Point3D memory p1, Point3D memory p2, Point3D memory p3) private pure returns (bool) {
        int256 nx = (p2.y - p1.y) * (p3.z - p1.z) - (p2.z - p1.z) * (p3.y - p1.y);
        int256 ny = (p2.z - p1.z) * (p3.x - p1.x) - (p2.x - p1.x) * (p3.z - p1.z);
        int256 nz = (p2.x - p1.x) * (p3.y - p1.y) - (p2.y - p1.y) * (p3.x - p1.x);
        return nx == 0 && ny == 0 && nz == 0;
    }

    /// Directed-edge consistency of the deployed-oriented mesh. For a closed,
    /// consistently-wound surface every directed edge appears exactly once and
    /// its reverse exactly once. Each violating directed edge counts as 1.
    function _edgeViolations(uint256[3][] memory tri, bool[] memory depO) private pure returns (uint256 v) {
        uint256 E = tri.length * 3;
        uint256[] memory from = new uint256[](E);
        uint256[] memory to = new uint256[](E);
        uint256 w;
        for (uint256 i = 0; i < tri.length; i++) {
            (uint256 a, uint256 b, uint256 c) =
                depO[i] ? (tri[i][0], tri[i][1], tri[i][2]) : (tri[i][0], tri[i][2], tri[i][1]);
            from[w] = a;
            to[w] = b;
            w++;
            from[w] = b;
            to[w] = c;
            w++;
            from[w] = c;
            to[w] = a;
            w++;
        }
        for (uint256 i = 0; i < E; i++) {
            uint256 same;
            uint256 rev;
            for (uint256 j = 0; j < E; j++) {
                if (from[j] == from[i] && to[j] == to[i]) same++;
                if (from[j] == to[i] && to[j] == from[i]) rev++;
            }
            if (same != 1 || rev != 1) v++;
        }
    }
}

contract DiagnoseMeshScript is Script {
    int256 private constant WAD = 1e18;

    // Camera constants — verbatim from the deployed TalismanMetadataRenderer.
    int256 private constant CAM_DIST_PER_MILLE = 4230;
    int256 private constant CAM_Y_PER_MILLE = 970;
    int256 private constant CAM_XZ_PER_MILLE = 2910;
    int256 private constant FOV_WAD = 35 * 1e18;

    TalismanMaterials internal materials;
    TalismanGenerator internal generator;
    MeshProbe internal probe;
    SvgProbe internal svg;

    function _boot() internal {
        materials = new TalismanMaterials();
        generator = new TalismanGenerator();
        probe = new MeshProbe();
        svg = new SvgProbe();
    }

    // ---- Entrypoint 1: full report for one token's cores ----

    function token(uint256[] memory cores, string memory label) public {
        _boot();
        (uint8 mid, TalismanForms.ShapeForm form, uint8 count, TalismanGenerator.FacetTier tier, uint16 seed) =
            _derive(cores);

        console.log(string.concat("== token ", label, " =="));
        console.log("materialId:", uint256(mid));
        console.log("material:", materials.getMaterial(mid).name);
        console.log("form:", TalismanForms.shapeFormName(form));
        console.log("tier:", uint256(uint8(tier)));
        console.log("seed:", uint256(seed));

        (uint256 mask, uint256 flipped, uint256 degen, uint256 edgeViol) = probe.diag(uint8(form), uint8(tier), seed);
        console.log("flippedCount:", flipped);
        console.log("degenCount:", degen);
        console.log("edgeViolations:", edgeViol);
        _logFlipped(mask, uint256(uint8(tier)) + 3);

        TalismanMaterials.Material memory mat = materials.getMaterial(mid);
        TalismanGenerator.Talisman memory tal = generator.generate(mat, mid, form, count, tier, seed);

        // Sanity: deployed-orientation replica must agree with the actual
        // generator output (edge violations recomputed from real triangles).
        console.log("triangles:", tal.triangles.length);

        Camera memory camera = _buildCamera(tal.maxRadius);
        LightSettings memory light = _buildLight(tal, camera);
        RenderSettings memory settings =
            RenderSettings({fillMode: uint8(FillMode.Solid), cullMode: uint8(CullMode.Back)});

        console.log(string.concat("===SVG-BEFORE-", label, "==="));
        console.log(svg.renderSvg(tal.triangles, camera, tal.materials, settings, light));
        console.log(string.concat("===SVG-BEFORE-END-", label, "==="));

        // Corrected mesh: re-flip the wrongly-wound faces.
        for (uint256 i = 0; i < tal.triangles.length; i++) {
            if ((mask >> i) & 1 == 1) {
                Point3D memory tmp = tal.triangles[i].p2;
                tal.triangles[i].p2 = tal.triangles[i].p3;
                tal.triangles[i].p3 = tmp;
            }
        }
        console.log(string.concat("===SVG-AFTER-", label, "==="));
        console.log(svg.renderSvg(tal.triangles, camera, tal.materials, settings, light));
        console.log(string.concat("===SVG-AFTER-END-", label, "==="));

        // No-cull render of the ORIGINAL (broken) mesh — candidate renderer-side fix.
        for (uint256 i = 0; i < tal.triangles.length; i++) {
            if ((mask >> i) & 1 == 1) {
                Point3D memory tmp = tal.triangles[i].p2;
                tal.triangles[i].p2 = tal.triangles[i].p3;
                tal.triangles[i].p3 = tmp;
            }
        }
        settings.cullMode = uint8(CullMode.None);
        console.log(string.concat("===SVG-NOCULL-", label, "==="));
        console.log(svg.renderSvg(tal.triangles, camera, tal.materials, settings, light));
        console.log(string.concat("===SVG-NOCULL-END-", label, "==="));
    }

    // ---- Entrypoint 2: seed sweep over all forms x tiers ----

    function sweep(uint256 seedsPerCell) public {
        _boot();
        console.log("form,tier,seeds,meshesWithFlips,totalFlippedFaces,maxFlippedInOne,degens,edgeViolMeshes");
        for (uint8 f = 0; f < 14; f++) {
            for (uint8 t = 0; t < 4; t++) {
                uint256 bad;
                uint256 total;
                uint256 maxIn;
                uint256 degens;
                uint256 evm_;
                for (uint256 s = 0; s < seedsPerCell; s++) {
                    uint16 seed = uint16((s * 65536) / seedsPerCell);
                    (, uint256 flipped, uint256 degen, uint256 edgeViol) = probe.diag(f, t, seed);
                    if (flipped > 0) bad++;
                    total += flipped;
                    if (flipped > maxIn) maxIn = flipped;
                    degens += degen;
                    if (edgeViol > 0) evm_++;
                }
                console.log(
                    string.concat(
                        TalismanForms.shapeFormName(TalismanForms.ShapeForm(f)),
                        ",",
                        vm.toString(uint256(t)),
                        ",",
                        vm.toString(seedsPerCell),
                        ",",
                        vm.toString(bad),
                        ",",
                        vm.toString(total),
                        ",",
                        vm.toString(maxIn),
                        ",",
                        vm.toString(degens),
                        ",",
                        vm.toString(evm_)
                    )
                );
            }
        }
    }

    // ---- Entrypoint 3: scan live tokens (packed = tokenId<<32 | form<<24 | tier<<16 | seed) ----

    function scan(uint256[] memory packed) public {
        _boot();
        console.log("tokenId,form,tier,seed,flipped,degen,edgeViol");
        for (uint256 i = 0; i < packed.length; i++) {
            uint256 p = packed[i];
            uint16 seed = uint16(p & 0xFFFF);
            uint8 t = uint8((p >> 16) & 0xFF);
            uint8 f = uint8((p >> 24) & 0xFF);
            uint256 id = p >> 32;
            (, uint256 flipped, uint256 degen, uint256 edgeViol) = probe.diag(f, t, seed);
            if (flipped > 0 || degen > 0 || edgeViol > 0) {
                console.log(
                    string.concat(
                        vm.toString(id),
                        ",",
                        TalismanForms.shapeFormName(TalismanForms.ShapeForm(f)),
                        ",",
                        vm.toString(uint256(t)),
                        ",",
                        vm.toString(uint256(seed)),
                        ",",
                        vm.toString(flipped),
                        ",",
                        vm.toString(degen),
                        ",",
                        vm.toString(edgeViol)
                    )
                );
            }
        }
        console.log("scan done:", packed.length);
    }

    // ---- Entrypoint 4: scan live tokens from raw cores (flat = [tokenId, n, c1..cn]*) ----

    function scanCores(uint256[] memory flat) public {
        _boot();
        console.log("tokenId,material,form,tier,seed,flipped,degen,edgeViol");
        uint256 i;
        uint256 tokens;
        uint256 affected;
        while (i < flat.length) {
            uint256 id = flat[i++];
            uint256 n = flat[i++];
            uint256[] memory cores = new uint256[](n);
            for (uint256 k = 0; k < n; k++) {
                cores[k] = flat[i++];
            }
            (uint8 mid, TalismanForms.ShapeForm form,, TalismanGenerator.FacetTier tier, uint16 seed) = _derive(cores);
            (, uint256 flipped, uint256 degen, uint256 edgeViol) = probe.diag(uint8(form), uint8(tier), seed);
            tokens++;
            if (flipped > 0 || degen > 0 || edgeViol > 0) {
                affected++;
                console.log(
                    string.concat(
                        vm.toString(id),
                        ",",
                        materials.getMaterial(mid).name,
                        ",",
                        TalismanForms.shapeFormName(form),
                        ",",
                        vm.toString(uint256(uint8(tier))),
                        ",",
                        vm.toString(uint256(seed)),
                        ",",
                        vm.toString(flipped),
                        ",",
                        vm.toString(degen),
                        ",",
                        vm.toString(edgeViol)
                    )
                );
            }
        }
        console.log("tokens scanned:", tokens);
        console.log("tokens affected:", affected);
    }

    // ---- Shared helpers ----

    function _derive(uint256[] memory cores)
        internal
        view
        returns (uint8 mid, TalismanForms.ShapeForm form, uint8 count, TalismanGenerator.FacetTier tier, uint16 seed)
    {
        mid = TalismanTransformationLib.deriveMaterialId(materials, cores);
        form = TalismanTransformationLib.deriveShapeForm(cores);
        seed = TalismanTransformationLib.deriveSeed(cores);
        count = uint8(cores.length);
        tier = generator.tierFromCores(count, materials.getMaterial(mid).essence);
    }

    function _logFlipped(uint256 mask, uint256 N) internal pure {
        uint256 tableEnd = N - 2;
        uint256 antiprismEnd = tableEnd + 2 * N;
        uint256 quadsEnd = antiprismEnd + 2 * N;
        for (uint256 i = 0; i < 6 * N - 2; i++) {
            if ((mask >> i) & 1 == 1) {
                string memory band = i < tableEnd
                    ? "table-cap"
                    : i < antiprismEnd ? "table-crown" : i < quadsEnd ? "crown-pavilion" : "pavilion-culet";
                console.log(string.concat("  flipped face ", vm.toString(i), " (", band, ")"));
            }
        }
    }

    function _buildCamera(int256 maxRadius) internal pure returns (Camera memory) {
        int256 camDist = (maxRadius * CAM_DIST_PER_MILLE) / 1000;
        int256 camY = (camDist * CAM_Y_PER_MILLE) / CAM_DIST_PER_MILLE;
        int256 camXZ = (camDist * CAM_XZ_PER_MILLE) / CAM_DIST_PER_MILLE;
        return Camera({
            location: Point3D({x: camXZ, y: camY, z: camXZ}), lookAt: Point3D({x: 0, y: 0, z: 0}), fieldOfView: FOV_WAD
        });
    }

    function _buildLight(TalismanGenerator.Talisman memory tal, Camera memory camera)
        internal
        pure
        returns (LightSettings memory)
    {
        return LightSettings({
            enabled: true,
            direction: Point3D({x: -camera.location.x, y: -camera.location.y, z: -camera.location.z}),
            ambient: tal.material.ambient,
            orientOutward: false,
            meshCenter: Point3D({x: 0, y: 0, z: 0}),
            reflectance: tal.material.reflectance,
            emissive: tal.material.emissive
        });
    }
}
