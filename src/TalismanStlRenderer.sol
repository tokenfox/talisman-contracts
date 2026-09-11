// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Base64} from "solady/utils/Base64.sol";
import {DynamicBufferLib} from "solady/utils/DynamicBufferLib.sol";
import {Material, Triangle} from "./TalismanStructs.sol";

/// @title TalismanStlRenderer
/// @dev Binary STL emitter (VisCAM color convention) for the same
///      `Triangle[]` meshes that drive the SVG and HTML renderers. Each
///      facet carries a 15-bit RGB color in the 2-byte attribute field,
///      so STL-color-aware viewers (three.js STLLoader, PrusaSlicer,
///      Bambu Studio) see the same material coloring as the 2D/3D panels.
///      Vertex coordinates are WAD -> IEEE 754 float32 little-endian and
///      uniformly scaled by `STL_SCALE` (1 WAD source -> STL_SCALE STL
///      units ~ mm). {renderStlBytes} returns the raw binary file;
///      {renderStl} base64-wraps it for text transport (a `data:` URI,
///      a JSON field, console output).
///
///      Color encoding (VisCAM / three.js STLLoader):
///      - Header starts with `COLOR=` + default RGBA bytes so parsers
///        know per-face attribute bytes carry colors.
///      - Per-face 2-byte attribute: bit 15 = 0 (use per-face color),
///        bits 14..10 = B5, 9..5 = G5, 4..0 = R5 (note the inverted
///        channel order vs Materialise Magics).
library TalismanStlRenderer {
    using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;

    int256 internal constant WAD = 1e18;

    /// @dev Uniform scale applied to every vertex. 1 WAD source -> STL_SCALE STL units.
    uint256 internal constant STL_SCALE = 8;

    /// @param reflectance Per-face color is multiplied by this WAD factor before
    ///        VisCAM packing, so the STL viewer's lighting recovers the same
    ///        `baseColor * REF * (AMB + (1-AMB) * NdotL)` Lambert response as
    ///        the SVG and HTML renderers. Pass `WAD` for "no scaling".
    /// @dev Base64 wrapper over {renderStlBytes} for callers transporting the
    ///      mesh as text (a `data:` URI, a JSON field, console output). A view
    ///      returning the binary file should call {renderStlBytes} directly.
    function renderStl(Triangle[] memory triangles, Material[] memory materials, string memory name, int256 reflectance)
        internal
        pure
        returns (string memory)
    {
        return Base64.encode(renderStlBytes(triangles, materials, name, reflectance));
    }

    /// @param reflectance Per-face color is multiplied by this WAD factor before
    ///        VisCAM packing, so the STL viewer's lighting recovers the same
    ///        `baseColor * REF * (AMB + (1-AMB) * NdotL)` Lambert response as
    ///        the SVG and HTML renderers. Pass `WAD` for "no scaling".
    /// @return The raw binary STL file as bytes (VisCAM-colored, little-endian).
    function renderStlBytes(
        Triangle[] memory triangles,
        Material[] memory materials,
        string memory name,
        int256 reflectance
    ) internal pure returns (bytes memory) {
        DynamicBufferLib.DynamicBuffer memory buf;
        buf.reserve(84 + triangles.length * 50);

        _appendHeader(buf, name);
        _appendU32LE(buf, uint32(triangles.length));

        uint256 matLen = materials.length;
        for (uint256 i = 0; i < triangles.length; i++) {
            Triangle memory tri = triangles[i];

            // Normal (3 x float32 LE): emit zero placeholder. Slicers recompute
            // from vertex winding, matching the prior ASCII STL behavior.
            _appendZeros(buf, 12);

            _appendFloat32LE(buf, tri.p1.x);
            _appendFloat32LE(buf, tri.p1.y);
            _appendFloat32LE(buf, tri.p1.z);
            _appendFloat32LE(buf, tri.p2.x);
            _appendFloat32LE(buf, tri.p2.y);
            _appendFloat32LE(buf, tri.p2.z);
            _appendFloat32LE(buf, tri.p3.x);
            _appendFloat32LE(buf, tri.p3.y);
            _appendFloat32LE(buf, tri.p3.z);

            uint32 rgb = tri.materialId < matLen ? materials[tri.materialId].color : 0xFFFFFF;
            _appendU16LE(buf, _packVisCamColor(_scaleColor(rgb, reflectance)));
        }

        return buf.data;
    }

    /// @dev Multiplies each RGB channel by `factor / WAD`, clamped to 8-bit.
    ///      Used to fold per-material reflectance into STL face colors so the
    ///      viewer's Lambert pass matches the SVG/HTML formula.
    function _scaleColor(uint32 rgb, int256 factor) private pure returns (uint32) {
        if (factor == WAD) {
            return rgb;
        }
        if (factor <= 0) {
            return 0;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 f = uint256(factor);
        uint256 r = ((rgb >> 16) & 0xFF) * f / uint256(WAD);
        uint256 g = ((rgb >> 8) & 0xFF) * f / uint256(WAD);
        uint256 b = (rgb & 0xFF) * f / uint256(WAD);
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

    function _appendHeader(DynamicBufferLib.DynamicBuffer memory buf, string memory name) private pure {
        bytes memory header = new bytes(80);
        // VisCAM "COLOR=" marker + default RGBA (all 0xFF = white, fully opaque).
        // three.js STLLoader requires this prefix before it inspects per-facet
        // attribute bytes for color data.
        header[0] = "C";
        header[1] = "O";
        header[2] = "L";
        header[3] = "O";
        header[4] = "R";
        header[5] = "=";
        header[6] = 0xFF;
        header[7] = 0xFF;
        header[8] = 0xFF;
        header[9] = 0xFF;
        header[10] = " ";
        bytes memory src = bytes(name);
        uint256 maxCopy = 80 - 11;
        uint256 copy = src.length < maxCopy ? src.length : maxCopy;
        for (uint256 i = 0; i < copy; i++) {
            header[11 + i] = src[i];
        }
        buf.p(header);
    }

    function _appendZeros(DynamicBufferLib.DynamicBuffer memory buf, uint256 count) private pure {
        bytes memory z = new bytes(count);
        buf.p(z);
    }

    function _appendU32LE(DynamicBufferLib.DynamicBuffer memory buf, uint32 v) private pure {
        buf.pUint8(uint8(v));
        buf.pUint8(uint8(v >> 8));
        buf.pUint8(uint8(v >> 16));
        buf.pUint8(uint8(v >> 24));
    }

    function _appendU16LE(DynamicBufferLib.DynamicBuffer memory buf, uint16 v) private pure {
        buf.pUint8(uint8(v));
        buf.pUint8(uint8(v >> 8));
    }

    /// @dev VisCAM per-facet color: bit 15 = 0 means "use this per-face color"
    ///      (bit 15 = 1 would mean "fall back to the header default"). Channel
    ///      order is R in low bits, B in high bits - the inverse of Magics.
    function _packVisCamColor(uint32 rgb) private pure returns (uint16) {
        uint16 r = uint16((rgb >> 16) & 0xFF) >> 3;
        uint16 g = uint16((rgb >> 8) & 0xFF) >> 3;
        uint16 b = uint16(rgb & 0xFF) >> 3;
        return (b << 10) | (g << 5) | r;
    }

    function _appendFloat32LE(DynamicBufferLib.DynamicBuffer memory buf, int256 wadValue) private pure {
        uint32 bits = _toFloat32Bits(wadValue);
        buf.pUint8(uint8(bits));
        buf.pUint8(uint8(bits >> 8));
        buf.pUint8(uint8(bits >> 16));
        buf.pUint8(uint8(bits >> 24));
    }

    /// @dev Converts a signed WAD value x `STL_SCALE` to IEEE 754 single-precision
    ///      bits. Normalizes the magnitude into [1*WAD, 2*WAD) via iterative shifts
    ///      (O(log range); our mesh coordinates fit in a small integer magnitude so
    ///      the loop runs a handful of times). Mantissa is floor-truncated - sub-ULP
    ///      error, invisible at STL viewer scales.
    function _toFloat32Bits(int256 wadValue) private pure returns (uint32) {
        if (wadValue == 0) {
            return 0;
        }
        uint32 sign = wadValue < 0 ? 1 : 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 absV = wadValue < 0 ? uint256(-wadValue) : uint256(wadValue);
        uint256 val = absV * STL_SCALE;

        int256 e = 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 wad = uint256(WAD);
        while (val >= wad * 2) {
            val >>= 1;
            e += 1;
        }
        while (val < wad) {
            val <<= 1;
            e -= 1;
        }

        uint256 mantissa = ((val - wad) << 23) / wad;
        int256 biased = e + 127;
        if (biased <= 0) {
            return sign << 31;
        }
        if (biased >= 255) {
            return (sign << 31) | (uint32(254) << 23) | 0x7FFFFF;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return (sign << 31) | (uint32(uint256(biased)) << 23) | uint32(mantissa);
    }
}
