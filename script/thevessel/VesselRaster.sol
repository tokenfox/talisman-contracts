// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TalismanForms} from "../../src/TalismanForms.sol";
import {TalismanGeneratorV2} from "../../src/TalismanGeneratorV2.sol";
import {TalismanMaterials} from "../../src/TalismanMaterials.sol";
import {TalismanSvgRendererV3} from "../../src/TalismanSvgRendererV3.sol";
import {Camera, LightSettings, Material, Point2D, Point3D, ProjectedTriangle} from "../../src/TalismanStructs.sol";

/// @notice Renders a Talisman as greyscale bytes for a craft of The Vessel: one byte
///         per pixel, row-major from the top-left, the order The Vessel draws.
/// @dev Runs only inside a forge script's local EVM - nothing here is deployed.
///      The mesh, lighting and projection come from the collection's own
///      contracts (generator, flat Lambert bake, painter-sorted projection), so
///      the craft shows the Talisman exactly as the chain defines it. Only the
///      rasterisation is new: 4x4 supersampling into a byte buffer, painter's
///      order, back faces culled with the SVG renderer's winding rule.
library VesselRaster {
    struct Stack {
        TalismanMaterials materials;
        TalismanGeneratorV2 generator;
        TalismanSvgRendererV3 svg;
    }

    uint256 internal constant ADDRESS_WORD = 32;
    uint256 internal constant MAX_COLS = 100;
    uint256 internal constant SUPERSAMPLE = 4;
    uint256 internal constant GREY_FLOOR = 32;

    // Restated from TalismanRendererV3's private camera constants; the raster
    // must look at the Talisman from exactly where the collection's image does.
    int256 internal constant CAM_DIST_PER_MILLE = 4230;
    int256 internal constant CAM_Y_PER_MILLE = 970;
    int256 internal constant CAM_XZ_PER_MILLE = 2910;
    int256 internal constant FOV_WAD = 35 * 1e18;

    int256 private constant WAD = 1e18;
    int256 private constant SVG_HALF = 256; // TalismanSvgRendererV2.SVG_WIDTH / 2
    int256 private constant SVG_TENTHS = 5120; // the 512-unit viewport, in tenths
    int256 private constant SUB = 256; // fixed-point steps per sample

    // --- Vessel grid ---------------------------------------------------------

    /// @notice The Vessel renderer's grid for a craft of `n` bytes.
    function grid(uint256 n) internal pure returns (uint256 cols, uint256 rows) {
        cols = ceilSqrt(n);
        if (cols > MAX_COLS) {
            cols = MAX_COLS;
        }
        rows = (n + cols - 1) / cols;
    }

    /// @notice Whether the final grid row of craft `n` is exactly one address word.
    function isExactFit(uint256 n) internal pure returns (bool) {
        if (n <= ADDRESS_WORD) {
            return false;
        }
        (uint256 cols, uint256 rows) = grid(n);
        // Measured as a length, not `n % cols`: with 32 columns a full last row
        // leaves no remainder.
        return n - cols * (rows - 1) == ADDRESS_WORD;
    }

    /// @notice The image rectangle of craft `n`: the full grid rows that fit before
    ///         the address word. For an exact-fit craft, every row but the last.
    function imageSize(uint256 n) internal pure returns (uint256 width, uint256 height) {
        (width,) = grid(n);
        height = n < ADDRESS_WORD ? 0 : (n - ADDRESS_WORD) / width;
    }

    function ceilSqrt(uint256 x) internal pure returns (uint256 s) {
        if (x == 0) {
            return 0;
        }
        s = x;
        uint256 z = (x + 1) / 2;
        while (z < s) {
            s = z;
            z = (x / z + z) / 2;
        }
        if (s * s != x) {
            s += 1;
        }
    }

    // --- rendering -----------------------------------------------------------

    /// @notice The Talisman `(materialId, form, coreCount, seed)` as a `width` x
    ///         `height` greyscale image, centred in the largest square that fits.
    function render(
        Stack memory stack,
        uint8 materialId,
        TalismanForms.ShapeForm form,
        uint8 coreCount,
        uint16 seed,
        uint256 width,
        uint256 height
    ) internal pure returns (bytes memory image) {
        TalismanGeneratorV2.Talisman memory tal = _generate(stack, materialId, form, coreCount, seed);
        Camera memory cam = camera(tal.maxRadius);
        Material[] memory lit = stack.svg.computeLitMaterials(tal.triangles, tal.materials, light(tal, cam));
        ProjectedTriangle[] memory projected = stack.svg.transformSortAndProjectTris(tal.triangles, cam);

        uint256 side = width < height ? width : height;
        bytes memory samples = _rasterise(projected, lit, side * SUPERSAMPLE);
        image = _resolve(samples, side, width, height);
    }

    function camera(int256 maxRadius) internal pure returns (Camera memory) {
        int256 camDist = (maxRadius * CAM_DIST_PER_MILLE) / 1000;
        int256 camY = (camDist * CAM_Y_PER_MILLE) / CAM_DIST_PER_MILLE;
        int256 camXz = (camDist * CAM_XZ_PER_MILLE) / CAM_DIST_PER_MILLE;
        return Camera({
            location: Point3D({x: camXz, y: camY, z: camXz}), lookAt: Point3D({x: 0, y: 0, z: 0}), fieldOfView: FOV_WAD
        });
    }

    function light(TalismanGeneratorV2.Talisman memory tal, Camera memory cam)
        internal
        pure
        returns (LightSettings memory)
    {
        return LightSettings({
            enabled: true,
            direction: Point3D({x: -cam.location.x, y: -cam.location.y, z: -cam.location.z}),
            ambient: tal.material.ambient,
            orientOutward: false,
            meshCenter: Point3D({x: 0, y: 0, z: 0}),
            reflectance: tal.material.reflectance,
            emissive: tal.material.emissive
        });
    }

    /// @notice Rec. 709 luma of a packed 0xRRGGBB colour, lifted so the darkest
    ///         material still separates from the black ground.
    function grey(uint32 color) internal pure returns (uint256) {
        uint256 y = (54 * ((color >> 16) & 0xFF) + 183 * ((color >> 8) & 0xFF) + 19 * (color & 0xFF)) >> 8;
        return GREY_FLOOR + (y * (255 - GREY_FLOOR)) / 255;
    }

    /// @notice An 8-bit greyscale BMP of an image, for previews: browsers and
    ///         image viewers open it as-is.
    function bmp(bytes memory image, uint256 width, uint256 height) internal pure returns (bytes memory out) {
        uint256 stride = (width + 3) & ~uint256(3);
        uint256 offset = 14 + 40 + 1024;
        out = new bytes(offset + stride * height);
        out[0] = "B";
        out[1] = "M";
        _le(out, 2, out.length, 4);
        _le(out, 10, offset, 4);
        _le(out, 14, 40, 4);
        _le(out, 18, width, 4);
        _le(out, 22, height, 4);
        _le(out, 26, 1, 2);
        _le(out, 28, 8, 2);
        _le(out, 34, stride * height, 4);
        _le(out, 38, 2835, 4);
        _le(out, 42, 2835, 4);
        _le(out, 46, 256, 4);
        for (uint256 i; i < 256; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes1 g = bytes1(uint8(i));
            out[54 + 4 * i] = g;
            out[55 + 4 * i] = g;
            out[56 + 4 * i] = g;
        }
        for (uint256 y; y < height; ++y) {
            uint256 dst = offset + (height - 1 - y) * stride;
            for (uint256 x; x < width; ++x) {
                out[dst + x] = image[y * width + x];
            }
        }
    }

    // --- internals -----------------------------------------------------------

    function _generate(Stack memory stack, uint8 materialId, TalismanForms.ShapeForm form, uint8 coreCount, uint16 seed)
        private
        pure
        returns (TalismanGeneratorV2.Talisman memory)
    {
        TalismanMaterials.Material memory mat = stack.materials.getMaterial(materialId);
        TalismanGeneratorV2.FacetTier tier = stack.generator.tierFromCores(coreCount, mat.essence);
        return stack.generator.generate(mat, materialId, form, coreCount, tier, seed);
    }

    function _rasterise(ProjectedTriangle[] memory projected, Material[] memory lit, uint256 ss)
        private
        pure
        returns (bytes memory samples)
    {
        samples = new bytes(ss * ss);
        for (uint256 i; i < projected.length; ++i) {
            ProjectedTriangle memory t = projected[i];
            if (!_frontFacing(t)) {
                continue;
            }
            uint16 id = t.materialId;
            uint256 level = grey(id < lit.length ? lit[id].color : 0xFFFFFF);
            (int256 x0, int256 y0) = _toSample(t.p1, ss);
            (int256 x1, int256 y1) = _toSample(t.p2, ss);
            (int256 x2, int256 y2) = _toSample(t.p3, ss);
            _fill(samples, ss, [x0, y0, x1, y1, x2, y2], level);
        }
    }

    /// @dev Same winding rule as TalismanSvgRendererV2._shouldRenderTriangle
    ///      under CullMode.Back.
    function _frontFacing(ProjectedTriangle memory t) private pure returns (bool) {
        return (t.p2.x - t.p1.x) * (t.p3.y - t.p1.y) - (t.p2.y - t.p1.y) * (t.p3.x - t.p1.x) >= 0;
    }

    /// @dev TalismanSvgRendererV2._projectOnSvg (tenths of an SVG unit, Y down),
    ///      then scaled onto the sample grid in SUB fixed-point steps.
    function _toSample(Point2D memory p, uint256 ss) private pure returns (int256 x, int256 y) {
        int256 xt = 10 * SVG_HALF + (p.x * 10) / (WAD / SVG_HALF);
        int256 yt = 10 * SVG_HALF - (p.y * 10) / (WAD / SVG_HALF);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 scale = int256(ss) * SUB;
        x = (xt * scale) / SVG_TENTHS;
        y = (yt * scale) / SVG_TENTHS;
    }

    function _fill(bytes memory samples, uint256 ss, int256[6] memory v, uint256 level) private pure {
        int256 area = _edge(v[0], v[1], v[2], v[3], v[4], v[5]);
        if (area == 0) {
            return;
        }
        if (area < 0) {
            (v[2], v[3], v[4], v[5]) = (v[4], v[5], v[2], v[3]);
        }
        (int256 sx0, int256 sx1) = _span(_min3(v[0], v[2], v[4]), _max3(v[0], v[2], v[4]), ss);
        (int256 sy0, int256 sy1) = _span(_min3(v[1], v[3], v[5]), _max3(v[1], v[3], v[5]), ss);
        if (sx0 > sx1 || sy0 > sy1) {
            return;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes1 b = bytes1(uint8(level)); // grey() never exceeds 255
        unchecked {
            int256 px0 = sx0 * SUB + SUB / 2;
            for (int256 sy = sy0; sy <= sy1; ++sy) {
                int256 py = sy * SUB + SUB / 2;
                int256 w0 = _edge(v[2], v[3], v[4], v[5], px0, py);
                int256 w1 = _edge(v[4], v[5], v[0], v[1], px0, py);
                int256 w2 = _edge(v[0], v[1], v[2], v[3], px0, py);
                int256 d0 = -(v[5] - v[3]) * SUB;
                int256 d1 = -(v[1] - v[5]) * SUB;
                int256 d2 = -(v[3] - v[1]) * SUB;
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 row = uint256(sy) * ss;
                for (int256 sx = sx0; sx <= sx1; ++sx) {
                    if (w0 >= 0 && w1 >= 0 && w2 >= 0) {
                        // forge-lint: disable-next-line(unsafe-typecast)
                        samples[row + uint256(sx)] = b;
                    }
                    w0 += d0;
                    w1 += d1;
                    w2 += d2;
                }
            }
        }
    }

    /// @dev Sample indices whose centres fall in [lo, hi], clamped to the grid.
    function _span(int256 lo, int256 hi, uint256 ss) private pure returns (int256 a, int256 b) {
        a = _ceilDiv(lo - SUB / 2, SUB);
        b = _floorDiv(hi - SUB / 2, SUB);
        if (a < 0) {
            a = 0;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 last = int256(ss) - 1;
        if (b > last) {
            b = last;
        }
    }

    function _resolve(bytes memory samples, uint256 side, uint256 width, uint256 height)
        private
        pure
        returns (bytes memory image)
    {
        image = new bytes(width * height);
        uint256 offX = (width - side) / 2;
        uint256 offY = (height - side) / 2;
        uint256 ss = side * SUPERSAMPLE;
        uint256 n = SUPERSAMPLE * SUPERSAMPLE;
        for (uint256 py; py < side; ++py) {
            for (uint256 px; px < side; ++px) {
                uint256 sum;
                for (uint256 j; j < SUPERSAMPLE; ++j) {
                    uint256 base = (py * SUPERSAMPLE + j) * ss + px * SUPERSAMPLE;
                    for (uint256 k; k < SUPERSAMPLE; ++k) {
                        sum += uint8(samples[base + k]);
                    }
                }
                // forge-lint: disable-next-line(unsafe-typecast)
                image[(offY + py) * width + offX + px] = bytes1(uint8((sum + n / 2) / n)); // a mean of bytes
            }
        }
    }

    function _edge(int256 ax, int256 ay, int256 bx, int256 by, int256 px, int256 py) private pure returns (int256) {
        return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
    }

    function _floorDiv(int256 a, int256 b) private pure returns (int256 q) {
        q = a / b;
        if (a % b != 0 && a < 0) {
            q -= 1;
        }
    }

    function _ceilDiv(int256 a, int256 b) private pure returns (int256 q) {
        q = a / b;
        if (a % b != 0 && a > 0) {
            q += 1;
        }
    }

    function _min3(int256 a, int256 b, int256 c) private pure returns (int256 m) {
        m = a < b ? a : b;
        m = m < c ? m : c;
    }

    function _max3(int256 a, int256 b, int256 c) private pure returns (int256 m) {
        m = a > b ? a : b;
        m = m > c ? m : c;
    }

    function _le(bytes memory out, uint256 at, uint256 value, uint256 len) private pure {
        for (uint256 i; i < len; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            out[at + i] = bytes1(uint8(value >> (8 * i)));
        }
    }
}
