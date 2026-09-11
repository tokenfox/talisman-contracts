// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ITalismanRenderer} from "./ITalismanRenderer.sol";
import {TalismanGenerator} from "./TalismanGenerator.sol";
import {TalismanMaterials} from "./TalismanMaterials.sol";
import {TalismanForms} from "./TalismanForms.sol";
import {TalismanSvgRenderer} from "./TalismanSvgRenderer.sol";
import {TalismanLiteHtmlRenderer} from "./TalismanLiteHtmlRenderer.sol";
import {TalismanStlRenderer} from "./TalismanStlRenderer.sol";
import {Camera, CullMode, FillMode, LightSettings, Point3D, RenderSettings} from "./TalismanStructs.sol";

/// @title TalismanMetadataRenderer
/// @notice Default {ITalismanRenderer} implementation. Builds the full
///         ERC-721 metadata document - name, description, trait list, SVG
///         image, and a self-contained HTML viewer for `animation_url` -
///         and returns it as a base64-encoded `data:application/json` URI.
/// @dev A pure function of the traits {Talismans} hands it: it holds no
///      reference back to the token contract and reads no token state, so the
///      dependency runs one way. Intentionally a *bundle*: this contract
///      hard-references the inner SVG and HTML renderers. Upgrading either means
///      deploying a fresh `TalismanMetadataRenderer` with the new dependencies
///      and calling `Talismans.setRenderer` - there is no in-place mutability
///      here.
contract TalismanMetadataRenderer is ITalismanRenderer {
    /// @dev Camera tuning - the canonical base pose: yaw=45deg, pitch~13.27deg,
    ///      FOV=35deg, camera distance = 4.23 x maxRadius. Encoded as integer
    ///      multipliers (per mille) so we don't drag Trigonometry into the
    ///      view path. Per-token jitter is intentionally omitted; replace
    ///      the renderer to get pose variation.
    int256 private constant CAM_DIST_PER_MILLE = 4230;
    int256 private constant CAM_Y_PER_MILLE = 970;
    int256 private constant CAM_XZ_PER_MILLE = 2910;
    int256 private constant FOV_WAD = 35 * 1e18;

    TalismanMaterials public immutable materials;
    TalismanGenerator public immutable generator;
    TalismanSvgRenderer public immutable svgRenderer;
    TalismanLiteHtmlRenderer public immutable liteRenderer;

    constructor(
        TalismanMaterials materialsContract,
        TalismanGenerator generatorContract,
        TalismanSvgRenderer svgRendererContract,
        TalismanLiteHtmlRenderer liteRendererContract
    ) {
        materials = materialsContract;
        generator = generatorContract;
        svgRenderer = svgRendererContract;
        liteRenderer = liteRendererContract;
    }

    /// @inheritdoc ITalismanRenderer
    function unrevealedURI(uint256 tokenId) external pure override returns (string memory) {
        return _unrevealedURI(tokenId);
    }

    /// @inheritdoc ITalismanRenderer
    function tokenURIFromTraits(
        uint256 tokenId,
        uint8 materialId,
        TalismanForms.ShapeForm form,
        uint8 cores,
        uint16 seed,
        bool genesis
    ) external view override returns (string memory) {
        return _buildTokenURI(tokenId, _generate(materialId, form, cores, seed), seed, genesis);
    }

    /// @inheritdoc ITalismanRenderer
    /// @dev Returns the raw `<svg ...>` document (no base64, no `data:` prefix) so
    ///      callers (e.g. the `simulate*` previews) can embed it directly.
    function imageFromTraits(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        external
        view
        override
        returns (string memory)
    {
        return _renderSvg(_generate(materialId, form, cores, seed));
    }

    /// @inheritdoc ITalismanRenderer
    /// @dev Returns the raw HTML viewer document (no base64, no `data:` prefix).
    function htmlFromTraits(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        external
        view
        override
        returns (string memory)
    {
        return _renderHtml(_generate(materialId, form, cores, seed));
    }

    /// @inheritdoc ITalismanRenderer
    /// @dev Returns the raw binary STL (no base64, no `data:` prefix).
    function stlFromTraits(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        external
        view
        override
        returns (bytes memory)
    {
        return _renderStl(_generate(materialId, form, cores, seed));
    }

    /// @dev Pre-reveal placeholder. Returns name + a static SVG
    ///      placeholder image (the Talismans logo over a black field, stroke
    ///      pulsating between white and light grey to signal "temporary").
    ///      No `animation_url`, no traits - those are intentionally withheld
    ///      until the token is revealed.
    function _unrevealedURI(uint256 tokenId) private pure returns (string memory) {
        string memory json = string.concat(
            '{"name":"Talisman #',
            LibString.toString(tokenId),
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_unrevealedSvg())),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @dev Inline SVG used as the pre-reveal placeholder image. Black 512x512
    ///      ground with the Talismans logo, stroke colour animating between
    ///      white and light grey so wallets surface it as "in progress" rather
    ///      than a finished piece.
    function _unrevealedSvg() private pure returns (string memory) {
        return string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 512 512'>",
            "<rect width='100%' height='100%' fill='#000'/>",
            "<svg viewBox='-8 -8 302 366' x='128' y='128' width='256' height='256' preserveAspectRatio='xMidYMid meet'>",
            "<path d='M 3 62 L 63 222 L 138 350 L 213 222 L 283 62 L 183 2 L 93 2 M 183 2 L 143 52 L 3 62 L 93 2 L 143 52 L 63 222 L 213 222 L 143 52 L 283 62'",
            " fill='none' stroke='#ffffff' stroke-width='6' stroke-linecap='round' stroke-linejoin='round'>",
            "<animate attributeName='stroke' values='#ffffff;#9aa0a6;#ffffff' dur='2.4s' repeatCount='indefinite'/>",
            "</path>",
            "</svg>",
            "</svg>"
        );
    }

    /// @dev Splits the per-call locals out of {tokenURIFromTraits} so we stay
    ///      under the Solidity stack-depth ceiling. The body holds the camera +
    ///      light + settings + two renderer outputs simultaneously, which is
    ///      enough to tip an inlined version over.
    function _buildTokenURI(uint256 tokenId, TalismanGenerator.Talisman memory tal, uint16 seed, bool genesis)
        private
        view
        returns (string memory)
    {
        string memory svg = _renderSvg(tal);
        string memory html = _renderHtml(tal);

        string memory json = string.concat(
            "{",
            '"name":"Talisman #',
            LibString.toString(tokenId),
            '",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '",',
            '"animation_url":"data:text/html;base64,',
            Base64.encode(bytes(html)),
            '",',
            '"attributes":',
            _attributes(tal, genesis, seed),
            "}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @dev Runs the generator from a fully-derived trait tuple. {Talismans}
    ///      derives the tuple for a live token and hands it to
    ///      {tokenURIFromTraits}; the preview path passes a hypothetical tuple
    ///      the same way. Caller must guarantee the token is revealed - pre-reveal
    ///      tokens take the {unrevealedURI} path instead. Tier is derived from
    ///      cores + essence so the renderer doesn't need to track it
    ///      independently.
    function _generate(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        private
        view
        returns (TalismanGenerator.Talisman memory)
    {
        TalismanMaterials.Material memory mat = materials.getMaterial(materialId);
        TalismanGenerator.FacetTier tier = generator.tierFromCores(cores, mat.essence);
        return generator.generate(mat, materialId, form, cores, tier, seed);
    }

    /// @dev Render the raw SVG for a generated talisman. Shared by the live
    ///      tokenURI path and {imageFromTraits}. Split into its own function to
    ///      keep callers under the stack-depth ceiling.
    function _renderSvg(TalismanGenerator.Talisman memory tal) private view returns (string memory) {
        Camera memory camera = _buildCamera(tal.maxRadius);
        LightSettings memory light = _buildLight(tal, camera);
        RenderSettings memory settings =
            RenderSettings({fillMode: uint8(FillMode.Solid), cullMode: uint8(CullMode.Back)});
        return svgRenderer.renderSvg(tal.triangles, camera, tal.materials, settings, light);
    }

    /// @dev Render the raw HTML viewer for a generated talisman. Shared by the
    ///      live tokenURI path and {htmlFromTraits}.
    function _renderHtml(TalismanGenerator.Talisman memory tal) private view returns (string memory) {
        Camera memory camera = _buildCamera(tal.maxRadius);
        LightSettings memory light = _buildLight(tal, camera);
        RenderSettings memory settings =
            RenderSettings({fillMode: uint8(FillMode.Solid), cullMode: uint8(CullMode.Back)});
        TalismanLiteHtmlRenderer.LiteHtmlRenderSettings memory liteSettings =
            TalismanLiteHtmlRenderer.LiteHtmlRenderSettings({orbitControls: true, autoRotate: true, debug: false});
        return liteRenderer.renderHtml(tal.triangles, camera, tal.materials, settings, light, liteSettings);
    }

    /// @dev Emit the raw binary STL for a generated talisman. Shared by the
    ///      live STL path and {stlFromTraits}. STL is a model-space mesh, so -
    ///      unlike {_renderSvg}/{_renderHtml} - it needs no camera; per-face
    ///      colour is pre-multiplied by the material's reflectance to match the
    ///      Lambert response the SVG and HTML renderers bake in.
    function _renderStl(TalismanGenerator.Talisman memory tal) private pure returns (bytes memory) {
        return TalismanStlRenderer.renderStlBytes(tal.triangles, tal.materials, "Talisman", tal.material.reflectance);
    }

    // --- attributes ----------------------------------------------------------

    function _attributes(TalismanGenerator.Talisman memory tal, bool genesis, uint16 seed)
        private
        view
        returns (string memory)
    {
        return string.concat(
            "[",
            _strTrait("Material", tal.material.name),
            ",",
            _strTrait("Chroma", materials.chromaName(TalismanMaterials.Chroma(tal.chroma))),
            ",",
            _strTrait("Essence", materials.essenceName(tal.material.essence)),
            ",",
            _strTrait("Form", TalismanForms.shapeFormName(TalismanForms.ShapeForm(tal.shapeForm))),
            ",",
            _strTrait("Tier", generator.facetTierName(TalismanGenerator.FacetTier(tal.facetTier))),
            ",",
            _numTrait("Cores", uint256(tal.cores)),
            ",",
            _strTrait("Seed", LibString.toHexString(uint256(seed), 2)),
            ",",
            _boolTrait("Genesis", genesis),
            "]"
        );
    }

    /// @dev Emits `{"trait_type":"<key>","value":<rawValue>}` where `rawValue`
    ///      is the already-encoded JSON literal (a quoted string or a bare
    ///      number). Single source of the trait-object wrapper.
    function _trait(string memory key, string memory rawValue) private pure returns (string memory) {
        return string.concat('{"trait_type":"', key, '","value":', rawValue, "}");
    }

    function _strTrait(string memory key, string memory value) private pure returns (string memory) {
        return _trait(key, string.concat('"', value, '"'));
    }

    function _numTrait(string memory key, uint256 value) private pure returns (string memory) {
        return _trait(key, LibString.toString(value));
    }

    /// @dev Emits the value as a bare JSON boolean (`true`/`false`), not a quoted
    ///      string - so consumers see a real boolean trait.
    function _boolTrait(string memory key, bool value) private pure returns (string memory) {
        return _trait(key, value ? "true" : "false");
    }

    // --- camera / light ------------------------------------------------------

    function _buildCamera(int256 maxRadius) private pure returns (Camera memory) {
        int256 camDist = (maxRadius * CAM_DIST_PER_MILLE) / 1000;
        int256 camY = (camDist * CAM_Y_PER_MILLE) / CAM_DIST_PER_MILLE;
        int256 camXZ = (camDist * CAM_XZ_PER_MILLE) / CAM_DIST_PER_MILLE;
        return Camera({
            location: Point3D({x: camXZ, y: camY, z: camXZ}), lookAt: Point3D({x: 0, y: 0, z: 0}), fieldOfView: FOV_WAD
        });
    }

    function _buildLight(TalismanGenerator.Talisman memory tal, Camera memory camera)
        private
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
