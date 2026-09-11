// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DynamicBufferLib} from "solady/utils/DynamicBufferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibString} from "solady/utils/LibString.sol";
import {TalismanLitMaterials} from "./TalismanLitMaterials.sol";
import {TalismanSvgRendererV2} from "./TalismanSvgRendererV2.sol";
import {
    Camera,
    FillMode,
    LightSettings,
    Material,
    Point3D,
    ProjectedTriangle,
    RenderSettings,
    Triangle
} from "./TalismanStructs.sol";

/// @title TalismanSvgRendererV3
/// @notice Adds two switches to {TalismanSvgRendererV2}: a seam stroke that
///         closes the hairline between facets, and per-vertex lighting that
///         takes the light the way the material does. With both off the
///         image is V2's, byte for byte.
/// @dev Anti-aliased fills leave a gap on shared edges; stroking each facet in
///      its own paint closes it. Per-vertex terms are affine across a triangle,
///      so a linear gradient reproduces them exactly. The highlight's shape
///      and colour come from {TalismanLitMaterials}.
contract TalismanSvgRendererV3 is TalismanSvgRendererV2 {
    using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;

    /// @dev Round joins keep acute apexes from growing miter spikes.
    string private constant SEAM_GROUP_OPEN = '<g stroke-linejoin="round" stroke-width="1">\n';
    string private constant SEAM_GROUP_CLOSE = "</g>\n";

    /// @dev Fraction of the camera distance the light is pulled in to, so it
    ///      sits inside the scene.
    int256 internal constant LIGHT_PULL = 62e16;
    /// @dev Falloff cap, normalised so the mesh centre keeps V2's brightness.
    int256 internal constant ATT_MAX = 125e16;
    /// @dev Below this the highlight rounds to nothing.
    int256 internal constant SPEC_EPSILON = 12e15;

    /// @dev `highlight` is the overlay colour: white pulled toward the face's
    ///      own colour by the material's tint.
    struct FaceLight {
        int256[3] diffuse;
        int256[3] specular;
        uint32 highlight;
    }

    /// @dev `ok` is false when the term is flat across the face.
    struct Ramp {
        bool ok;
        int256 x1;
        int256 y1;
        int256 x2;
        int256 y2;
        int256 lo;
        int256 hi;
    }

    /// @notice Renders the SVG, lit per vertex the way `materialId` takes the
    ///         light. The seam stroke is ignored in wireframe mode.
    /// @param materialId The material whose lit terms shape and colour the highlight.
    function renderSvg(
        Triangle[] memory triangles,
        Camera memory camera,
        Material[] memory materials,
        RenderSettings memory settings,
        LightSettings memory light,
        bool seamStroke,
        bool perVertexLighting,
        uint8 materialId
    ) public pure returns (string memory svgString) {
        if (!perVertexLighting || !light.enabled || settings.fillMode == uint8(FillMode.Wireframe)) {
            return renderSvg(triangles, camera, materials, settings, light, seamStroke);
        }
        return
            _renderLit(
                triangles, camera, materials, settings, light, seamStroke, TalismanLitMaterials.params(materialId)
            );
    }

    function renderSvg(
        Triangle[] memory triangles,
        Camera memory camera,
        Material[] memory materials,
        RenderSettings memory settings,
        LightSettings memory light,
        bool seamStroke
    ) public pure returns (string memory svgString) {
        if (!seamStroke || settings.fillMode == uint8(FillMode.Wireframe)) {
            return renderSvg(triangles, camera, materials, settings, light);
        }

        if (light.enabled) {
            materials = computeLitMaterials(triangles, materials, light);
        }

        ProjectedTriangle[] memory projected = transformSortAndProjectTris(triangles, camera);

        svgString = string.concat(_documentHeader(), SEAM_GROUP_OPEN);

        for (uint256 i = 0; i < projected.length; i++) {
            if (_shouldRenderTriangle(projected[i], settings.cullMode)) {
                svgString = string.concat(svgString, _strokedPolygon(projected[i], materials));
            }
        }

        svgString = string.concat(svgString, SEAM_GROUP_CLOSE, "</svg>");
    }

    /// @dev V2's preamble byte for byte, double space before `height` included.
    function _documentHeader() private pure returns (string memory) {
        return string.concat(
            '<?xml version="1.0" encoding="UTF-8"?>\n',
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ',
            LibString.toString(SVG_WIDTH),
            " ",
            LibString.toString(SVG_HEIGHT),
            '" width="512" height="512">\n',
            '<rect width="',
            LibString.toString(SVG_WIDTH),
            '" ',
            ' height="',
            LibString.toString(SVG_HEIGHT),
            '" fill="#000000"/>\n'
        );
    }

    /// @dev Shading terms are taken before the depth sort, with material ids
    ///      rewritten to face indices so the sorted output can find them.
    ///      Strokes go in one pass beneath every fill; stroked on the element
    ///      itself, a translucent highlight would paint its stroke band twice.
    function _renderLit(
        Triangle[] memory triangles,
        Camera memory camera,
        Material[] memory materials,
        RenderSettings memory settings,
        LightSettings memory light,
        bool seamStroke,
        TalismanLitMaterials.LitParams memory lit
    ) private pure returns (string memory) {
        uint32[] memory baseColors = new uint32[](triangles.length);
        FaceLight[] memory faceLights = new FaceLight[](triangles.length);
        for (uint256 i = 0; i < triangles.length; i++) {
            baseColors[i] = _getMaterialColor(triangles[i].materialId, materials);
            faceLights[i] = _faceLight(triangles[i], camera, light, lit);
            faceLights[i].highlight = _highlight(baseColors[i], lit.tint);
            // forge-lint: disable-next-line(unsafe-typecast)
            triangles[i].materialId = uint16(i);
        }

        ProjectedTriangle[] memory projected = transformSortAndProjectTris(triangles, camera);

        DynamicBufferLib.DynamicBuffer memory defs;
        DynamicBufferLib.DynamicBuffer memory strokes;
        DynamicBufferLib.DynamicBuffer memory fills;
        uint256 gradientId;
        for (uint256 i = 0; i < projected.length; i++) {
            if (_shouldRenderTriangle(projected[i], settings.cullMode)) {
                uint256 face = projected[i].materialId;
                gradientId = _emitLitFace(
                    defs, strokes, fills, projected[i], faceLights[face], baseColors[face], gradientId, seamStroke
                );
            }
        }

        return string.concat(
            _documentHeader(),
            "<defs>",
            string(defs.s()),
            "</defs>\n",
            seamStroke ? string.concat(SEAM_GROUP_OPEN, string(strokes.s()), SEAM_GROUP_CLOSE) : "",
            string(fills.s()),
            "</svg>"
        );
    }

    /// @dev Two layers because the diffuse and specular ramps run in different
    ///      directions.
    function _emitLitFace(
        DynamicBufferLib.DynamicBuffer memory defs,
        DynamicBufferLib.DynamicBuffer memory strokes,
        DynamicBufferLib.DynamicBuffer memory fills,
        ProjectedTriangle memory tri,
        FaceLight memory fl,
        uint32 base,
        uint256 gradientId,
        bool seamStroke
    ) private pure returns (uint256) {
        (int256[3] memory px, int256[3] memory py) = _screenPoints(tri);

        Ramp memory dr = _ramp(px, py, fl.diffuse);
        if (dr.ok) {
            uint32 c0 = _applyBrightness(base, dr.lo);
            uint32 c1 = _applyBrightness(base, dr.hi);
            if (c0 == c1) {
                _emitLayer(strokes, fills, tri, string.concat("#", _uint32ColorToHex(c0)), "", seamStroke);
            } else {
                string memory id = string.concat("g", LibString.toString(gradientId++));
                defs.p(
                    bytes(
                        _gradient(
                            id,
                            dr,
                            string.concat('stop-color="#', _uint32ColorToHex(c0), '"'),
                            string.concat('stop-color="#', _uint32ColorToHex(c1), '"')
                        )
                    )
                );
                _emitLayer(strokes, fills, tri, string.concat("url(#", id, ")"), "", seamStroke);
            }
        } else {
            int256 avg = (fl.diffuse[0] + fl.diffuse[1] + fl.diffuse[2]) / 3;
            string memory flat = string.concat("#", _uint32ColorToHex(_applyBrightness(base, avg)));
            _emitLayer(strokes, fills, tri, flat, "", seamStroke);
        }

        Ramp memory sr = _ramp(px, py, fl.specular);
        if (sr.ok) {
            if (sr.hi < SPEC_EPSILON) {
                return gradientId;
            }
            string memory id = string.concat("g", LibString.toString(gradientId++));
            string memory stop = string.concat('stop-color="#', _uint32ColorToHex(fl.highlight), '" stop-opacity="');
            defs.p(
                bytes(
                    _gradient(
                        id,
                        sr,
                        string.concat(stop, _wadToDecimal(sr.lo), '"'),
                        string.concat(stop, _wadToDecimal(sr.hi), '"')
                    )
                )
            );
            _emitLayer(strokes, fills, tri, string.concat("url(#", id, ")"), "", seamStroke);
        } else {
            int256 avg = (fl.specular[0] + fl.specular[1] + fl.specular[2]) / 3;
            if (avg >= SPEC_EPSILON) {
                _emitLayer(
                    strokes,
                    fills,
                    tri,
                    string.concat("#", _uint32ColorToHex(fl.highlight)),
                    _wadToDecimal(avg),
                    seamStroke
                );
            }
        }
        return gradientId;
    }

    /// @dev The stroke carries the opacity so it never draws denser than the fill.
    function _emitLayer(
        DynamicBufferLib.DynamicBuffer memory strokes,
        DynamicBufferLib.DynamicBuffer memory fills,
        ProjectedTriangle memory tri,
        string memory paint,
        string memory opacity,
        bool seamStroke
    ) private pure {
        string memory points = _pointsOf(tri);
        if (seamStroke) {
            string memory strokeOpacity = bytes(opacity).length == 0 ? "" : string.concat('" stroke-opacity="', opacity);
            strokes.p(
                bytes(
                    string.concat(
                        '  <polygon points="', points, '" fill="none" stroke="', paint, strokeOpacity, '"/>\n'
                    )
                )
            );
        }
        string memory fillOpacity = bytes(opacity).length == 0 ? "" : string.concat('" fill-opacity="', opacity);
        fills.p(bytes(string.concat('  <polygon points="', points, '" fill="', paint, fillOpacity, '"/>\n')));
    }

    function _strokedPolygon(ProjectedTriangle memory triangle, Material[] memory materials)
        private
        pure
        returns (string memory)
    {
        (int256 x1, int256 y1) = _projectOnSvg(triangle.p1);
        (int256 x2, int256 y2) = _projectOnSvg(triangle.p2);
        (int256 x3, int256 y3) = _projectOnSvg(triangle.p3);

        string memory colorHex = _uint32ColorToHex(_getMaterialColor(triangle.materialId, materials));

        return string.concat(
            '  <polygon points="',
            _tenthsToString(x1),
            ",",
            _tenthsToString(y1),
            " ",
            _tenthsToString(x2),
            ",",
            _tenthsToString(y2),
            " ",
            _tenthsToString(x3),
            ",",
            _tenthsToString(y3),
            '" fill="#',
            colorHex,
            '" stroke="#',
            colorHex,
            '"/>\n'
        );
    }

    // --- the lighting model --------------------------------------------------

    function _faceLight(
        Triangle memory tri,
        Camera memory camera,
        LightSettings memory light,
        TalismanLitMaterials.LitParams memory lit
    ) internal pure returns (FaceLight memory fl) {
        Point3D memory lightPos = Point3D({
            x: (camera.location.x * LIGHT_PULL) / WAD,
            y: (camera.location.y * LIGHT_PULL) / WAD,
            z: (camera.location.z * LIGHT_PULL) / WAD
        });
        int256 lightRadius = _length(lightPos);
        Point3D memory normal = _computeFaceNormal(tri);

        Point3D[3] memory verts = [tri.p1, tri.p2, tri.p3];
        for (uint256 k = 0; k < 3; k++) {
            (fl.diffuse[k], fl.specular[k]) =
                _vertexTerms(verts[k], normal, camera.location, lightPos, lightRadius, light, lit);
        }
    }

    /// @dev The normal is turned toward the eye, so a back face shades as a front one.
    function _vertexTerms(
        Point3D memory p,
        Point3D memory faceNormal,
        Point3D memory eye,
        Point3D memory lightPos,
        int256 lightRadius,
        LightSettings memory light,
        TalismanLitMaterials.LitParams memory lit
    ) private pure returns (int256 diffuse, int256 specular) {
        Point3D memory toLight = Point3D({x: lightPos.x - p.x, y: lightPos.y - p.y, z: lightPos.z - p.z});
        int256 lightDist = _length(toLight);
        if (lightDist == 0) {
            lightDist = 1;
        }
        Point3D memory l = normalize(toLight);
        Point3D memory v = normalize(Point3D({x: eye.x - p.x, y: eye.y - p.y, z: eye.z - p.z}));

        Point3D memory n = faceNormal;
        if (_dotProduct(n, v) < 0) {
            n = Point3D({x: -n.x, y: -n.y, z: -n.z});
        }

        int256 attenuation = (lightRadius * WAD) / lightDist;
        if (attenuation > ATT_MAX) {
            attenuation = ATT_MAX;
        }
        // Wrap lifts the terminator toward the dark side; fully wrapped shades flat.
        int256 nDotL = ((_dotProduct(n, l) + lit.wrap) * WAD) / (WAD + lit.wrap);
        if (nDotL < 0) {
            nDotL = 0;
        }
        diffuse = _clamp01(lit.glow + _brightness(light, (nDotL * attenuation) / WAD));

        int256 nDotH = _dotProduct(n, normalize(Point3D({x: l.x + v.x, y: l.y + v.y, z: l.z + v.z})));
        if (nDotH < 0) {
            nDotH = 0;
        }
        int256 nDotV = _dotProduct(n, v);
        if (nDotV < 0) {
            nDotV = 0;
        }
        specular = _clamp01(
            (_powWadInt(nDotH, lit.shininess) * lit.specularGain) / WAD * light.reflectance / WAD
                + (_powWadInt(WAD - nDotV, lit.rimPower) * lit.rimGain) / WAD
        );
    }

    /// @dev Rounded the way the viewer's Math.round rounds, so both surfaces
    ///      land on the same byte; tint 0 is exactly white.
    function _highlight(uint32 base, int256 tint) private pure returns (uint32 out) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 pull = uint256(tint);
        for (uint256 shift = 0; shift < 24; shift += 8) {
            uint256 channel = (base >> shift) & 0xFF;
            uint256 tinted = (255 * 1e18 - pull * (255 - channel) + 5e17) / 1e18;
            // forge-lint: disable-next-line(unsafe-typecast)
            out |= uint32(tinted << shift);
        }
    }

    /// @dev The field `t = a*x + b*y + c` varies along `(a, b)`; projecting the
    ///      vertices onto it gives the ramp's ends, where the extremes sit.
    function _ramp(int256[3] memory px, int256[3] memory py, int256[3] memory t) internal pure returns (Ramp memory r) {
        int256 det = (px[1] - px[0]) * (py[2] - py[0]) - (px[2] - px[0]) * (py[1] - py[0]);
        if (det == 0) {
            return r;
        }
        int256 a = ((t[1] - t[0]) * (py[2] - py[0]) - (t[2] - t[0]) * (py[1] - py[0])) / det;
        int256 b = ((px[1] - px[0]) * (t[2] - t[0]) - (px[2] - px[0]) * (t[1] - t[0])) / det;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 g = int256(FixedPointMathLib.sqrt(uint256(a * a + b * b)));
        if (g == 0) {
            return r;
        }
        int256 dx = (a * WAD) / g;
        int256 dy = (b * WAD) / g;

        uint256 lo;
        uint256 hi;
        int256 sLo = (px[0] * dx + py[0] * dy) / WAD;
        int256 sHi = sLo;
        for (uint256 k = 1; k < 3; k++) {
            int256 s = (px[k] * dx + py[k] * dy) / WAD;
            if (s < sLo) {
                sLo = s;
                lo = k;
            }
            if (s > sHi) {
                sHi = s;
                hi = k;
            }
        }
        if (t[lo] == t[hi]) {
            return r;
        }
        r.ok = true;
        r.x1 = (dx * sLo) / WAD;
        r.y1 = (dy * sLo) / WAD;
        r.x2 = (dx * sHi) / WAD;
        r.y2 = (dy * sHi) / WAD;
        r.lo = t[lo];
        r.hi = t[hi];
    }

    function _gradient(string memory id, Ramp memory r, string memory stop0, string memory stop1)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '<linearGradient id="',
            id,
            '" gradientUnits="userSpaceOnUse" x1="',
            _tenthsToString(r.x1),
            '" y1="',
            _tenthsToString(r.y1),
            '" x2="',
            _tenthsToString(r.x2),
            '" y2="',
            _tenthsToString(r.y2),
            '"><stop offset="0" ',
            stop0,
            '/><stop offset="1" ',
            stop1,
            "/></linearGradient>"
        );
    }

    function _pointsOf(ProjectedTriangle memory tri) private pure returns (string memory) {
        (int256[3] memory px, int256[3] memory py) = _screenPoints(tri);
        return string.concat(
            _tenthsToString(px[0]),
            ",",
            _tenthsToString(py[0]),
            " ",
            _tenthsToString(px[1]),
            ",",
            _tenthsToString(py[1]),
            " ",
            _tenthsToString(px[2]),
            ",",
            _tenthsToString(py[2])
        );
    }

    function _screenPoints(ProjectedTriangle memory tri)
        private
        pure
        returns (int256[3] memory px, int256[3] memory py)
    {
        (px[0], py[0]) = _projectOnSvg(tri.p1);
        (px[1], py[1]) = _projectOnSvg(tri.p2);
        (px[2], py[2]) = _projectOnSvg(tri.p3);
    }

    /// @dev 1e18 -> "1", 123456789012345678 -> "0.123".
    function _wadToDecimal(int256 v) internal pure returns (string memory) {
        if (v >= WAD) {
            return "1";
        }
        if (v <= 0) {
            return "0";
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 thousandths = uint256(v) / 1e15;
        if (thousandths == 0) {
            return "0";
        }
        string memory digits = LibString.toString(thousandths);
        if (thousandths < 10) {
            digits = string.concat("00", digits);
        } else if (thousandths < 100) {
            digits = string.concat("0", digits);
        }
        return string.concat("0.", digits);
    }

    function _powWadInt(int256 x, uint256 n) internal pure returns (int256 result) {
        result = WAD;
        while (n != 0) {
            if (n & 1 == 1) {
                result = (result * x) / WAD;
            }
            x = (x * x) / WAD;
            n >>= 1;
        }
    }

    function _length(Point3D memory v) private pure returns (int256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(FixedPointMathLib.sqrt(uint256(v.x * v.x + v.y * v.y + v.z * v.z)));
    }

    function _clamp01(int256 v) private pure returns (int256) {
        if (v < 0) {
            return 0;
        }
        return v > WAD ? WAD : v;
    }
}
