// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DynamicBufferLib} from "solady/utils/DynamicBufferLib.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";
import {TalismanLitMaterials} from "./TalismanLitMaterials.sol";
import {Camera, FillMode, LightSettings, Material, RenderSettings, Triangle} from "./TalismanStructs.sol";

/// @title TalismanVertexLitHtmlRenderer
/// @notice Emits a self-contained HTML viewer for a mesh, matching the SVG
///         image's projection and lighting.
/// @dev The script is read from an SSTORE2 blob fixed at construction.
contract TalismanVertexLitHtmlRenderer {
    using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;

    error InvalidViewerScript();

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable viewerScript;

    constructor(address viewerScriptPointer) {
        // A STOP byte plus at least one byte of script.
        if (viewerScriptPointer.code.length < 2) {
            revert InvalidViewerScript();
        }
        viewerScript = viewerScriptPointer;
    }

    struct LiteHtmlRenderSettings {
        bool orbitControls;
        bool autoRotate;
        bool debug;
        /// @dev Auto-rotate holds still for this long after load, then eases up
        ///      to speed over `spinEaseMs`. Both zero starts at full speed.
        uint16 spinStallMs;
        uint16 spinEaseMs;
    }

    function renderHtml(
        Triangle[] memory triangles,
        Camera memory camera,
        Material[] memory materials,
        RenderSettings memory settings,
        LightSettings memory light,
        LiteHtmlRenderSettings memory liteSettings,
        bool perVertexLighting,
        uint8 materialId
    ) public view returns (string memory) {
        bool wireframe = settings.fillMode == uint8(FillMode.Wireframe);
        return string.concat(
            "<!DOCTYPE html><html><head><style>html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden}#lite-container{width:100%;height:100%;cursor:grab}canvas{display:block;width:100%;height:100%}</style></head>",
            "<body><div id='lite-container'></div>",
            "<script>(function(){",
            _emitVertexData(triangles, materials),
            _emitCameraConsts(camera),
            _emitLightConsts(light),
            _emitLitMaterial(materialId),
            "var BG=[0,0,0];var BGA=1;",
            _emitMode(
                wireframe,
                liteSettings.orbitControls,
                liteSettings.autoRotate,
                liteSettings.debug,
                settings.cullMode,
                perVertexLighting
            ),
            _emitSpin(liteSettings.spinStallMs, liteSettings.spinEaseMs),
            string(SSTORE2.read(viewerScript)),
            "})();</script></body></html>"
        );
    }

    function _emitVertexData(Triangle[] memory triangles, Material[] memory materials)
        internal
        pure
        returns (string memory)
    {
        DynamicBufferLib.DynamicBuffer memory buf;
        buf.reserve(triangles.length * (9 * 21 + 9) + materials.length * 9 + 300);

        buf.p("var V=[");
        for (uint256 i = 0; i < triangles.length; i++) {
            if (i > 0) {
                buf.p(",");
            }
            buf.p(bytes(LibString.toString(triangles[i].p1.x)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p1.y)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p1.z)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p2.x)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p2.y)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p2.z)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p3.x)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p3.y)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p3.z)));
        }
        buf.p("].map(function(c){return c/1e18;});");

        buf.p("var M=[");
        for (uint256 i = 0; i < triangles.length; i++) {
            if (i > 0) {
                buf.p(",");
            }
            buf.p(bytes(LibString.toString(uint256(triangles[i].materialId))));
        }
        buf.p("];");

        buf.p("var C=[");
        for (uint256 i = 0; i < materials.length; i++) {
            if (i > 0) {
                buf.p(",");
            }
            buf.p(bytes(_colorToCssHex(materials[i].color)));
        }
        buf.p("];");
        return buf.s();
    }

    function _emitCameraConsts(Camera memory camera) internal pure returns (string memory) {
        return string.concat(
            "var CP=[",
            LibString.toString(camera.location.x),
            "/1e18,",
            LibString.toString(camera.location.y),
            "/1e18,",
            LibString.toString(camera.location.z),
            "/1e18];",
            "var CT=[",
            LibString.toString(camera.lookAt.x),
            "/1e18,",
            LibString.toString(camera.lookAt.y),
            "/1e18,",
            LibString.toString(camera.lookAt.z),
            "/1e18];",
            "var FOV=",
            LibString.toString(camera.fieldOfView),
            "/1e18;"
        );
    }

    function _emitLightConsts(LightSettings memory light) internal pure returns (string memory) {
        return string.concat(
            "var LE=",
            light.enabled ? "1" : "0",
            ";var LD=[",
            LibString.toString(light.direction.x),
            "/1e18,",
            LibString.toString(light.direction.y),
            "/1e18,",
            LibString.toString(light.direction.z),
            "/1e18];",
            "var AMB=",
            LibString.toString(light.ambient),
            "/1e18;",
            "var REF=",
            LibString.toString(light.reflectance),
            "/1e18;",
            "var EMI=",
            LibString.toString(light.emissive),
            "/1e18;",
            "var MC=[",
            LibString.toString(light.meshCenter.x),
            "/1e18,",
            LibString.toString(light.meshCenter.y),
            "/1e18,",
            LibString.toString(light.meshCenter.z),
            "/1e18];"
        );
    }

    /// @dev Printed as the table's own numbers, hundredths as two decimals, so
    ///      a reader can check the viewer against the image's source.
    function _emitLitMaterial(uint8 materialId) internal pure returns (string memory) {
        bytes7 r = TalismanLitMaterials.row(materialId);
        return string.concat(
            "var SHIN=",
            LibString.toString(uint256(uint8(r[0]))),
            ",SGAIN=",
            _centi(r[1]),
            ",RPOW=",
            LibString.toString(uint256(uint8(r[2]))),
            ",RGAIN=",
            _centi(r[3]),
            ",TINT=",
            _centi(r[4]),
            ",WRAP=",
            _centi(r[5]),
            ",GLOW=",
            _centi(r[6]),
            ";"
        );
    }

    function _centi(bytes1 c) internal pure returns (string memory) {
        uint256 v = uint8(c);
        uint256 frac = v % 100;
        return string.concat(LibString.toString(v / 100), frac < 10 ? ".0" : ".", LibString.toString(frac));
    }

    function _emitMode(bool wireframe, bool orbit, bool autoRotate, bool debug, uint8 cullMode, bool lit)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "var WF=",
            wireframe ? "1" : "0",
            ";var OC=",
            orbit ? "1" : "0",
            ";var AR=",
            autoRotate ? "1" : "0",
            ";var DBG=",
            debug ? "1" : "0",
            ";var CL=",
            LibString.toString(uint256(cullMode)),
            ";var LIT=",
            lit ? "1" : "0",
            ";"
        );
    }

    function _emitSpin(uint16 stallMs, uint16 easeMs) internal pure returns (string memory) {
        return string.concat(
            "var SD=", LibString.toString(uint256(stallMs)), ";var SE=", LibString.toString(uint256(easeMs)), ";"
        );
    }

    function _colorToCssHex(uint32 color) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789ABCDEF";
        bytes memory result = new bytes(9);
        result[0] = "'";
        result[1] = "#";
        for (uint256 i = 0; i < 6; i++) {
            uint256 nibble = (color >> ((5 - i) * 4)) & 0xF;
            result[2 + i] = hexChars[nibble];
        }
        result[8] = "'";
        return string(result);
    }
}
