// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ITalismanHost} from "./ITalismanHost.sol";
import {ITalismanRenderer} from "./ITalismanRenderer.sol";
import {TalismanCore} from "./TalismanCore.sol";
import {TalismanGeneratorV2} from "./TalismanGeneratorV2.sol";
import {TalismanMaterials} from "./TalismanMaterials.sol";
import {TalismanForms} from "./TalismanForms.sol";
import {TalismanSvgRendererV3} from "./TalismanSvgRendererV3.sol";
import {TalismanLiteHtmlRenderer} from "./TalismanLiteHtmlRenderer.sol";
import {TalismanVertexLitHtmlRenderer} from "./TalismanVertexLitHtmlRenderer.sol";
import {TalismanStlRenderer} from "./TalismanStlRenderer.sol";
import {TalismanTransformationLib} from "./TalismanTransformationLib.sol";
import {Camera, CullMode, FillMode, LightSettings, Point3D, RenderSettings} from "./TalismanStructs.sol";

/// @title TalismanRendererV3
/// @notice {ITalismanRenderer} implementation: name, traits, SVG image and HTML
///         viewer, as a base64 `data:application/json` URI. Over V2 it adds a
///         seam stroke, per-vertex lighting, per-pole core facets and an
///         owner-set `external_url`, `background_color` and `description`,
///         each behind a switch. With the artwork switches off, the image and
///         the viewer are V2's byte for byte.
/// @dev A pure function of the traits passed in, bar the `external_url`
///      expiry. Reads through {ITalismanHost} are `view`: the renderer can
///      revert `tokenURI` but never mutate token state.
contract TalismanRendererV3 is ITalismanRenderer {
    /// @dev V2's camera pose: yaw 45deg, pitch ~13.27deg, distance 4.23 x maxRadius.
    int256 private constant CAM_DIST_PER_MILLE = 4230;
    int256 private constant CAM_Y_PER_MILLE = 970;
    int256 private constant CAM_XZ_PER_MILLE = 2910;
    int256 private constant FOV_WAD = 35 * 1e18;

    uint256 private constant MAX_URL_COMPONENT_BYTES = 128;
    uint256 private constant MAX_DESCRIPTION_BYTES = 512;

    /// @dev Without `preserveDrawingBuffer` a snapshot from outside the frame is blank.
    string private constant WEBGL_CONTEXT_ATTRIBUTES = "{antialias:true,alpha:true}";
    string private constant WEBGL_CONTEXT_ATTRIBUTES_PRESERVED =
        "{antialias:true,alpha:true,preserveDrawingBuffer:true}";

    /// @notice What the owner of the token contract can change about the
    ///         metadata document.
    struct MetadataConfig {
        bool externalUrlEnabled;
        string urlPrefix;
        string urlSuffix;
        /// @dev 0 never expires.
        uint64 urlExpiresAt;
        bool backgroundColorEnabled;
        /// @dev Six lowercase hex characters, no `#`.
        bytes3 backgroundColor;
        bool descriptionEnabled;
        /// @dev Printable ASCII only.
        string description;
        bool chromaTrait;
        bool seedTrait;
        bool genesisTrait;
        bool coreKindTrait;
        bool coreSeedTrait;
        bool seamStroke;
        /// @dev Changes no pixel; lets a still be captured from the canvas.
        bool preserveDrawingBuffer;
        bool perVertexLighting;
        /// @dev Whether the lit viewer's auto-rotate holds still for
        ///      `spinStallMs` after load and then eases up to speed over
        ///      `spinEaseMs`. Only the lit viewer can; the flat one is V2's.
        bool spinEase;
        uint16 spinStallMs;
        uint16 spinEaseMs;
    }

    error NotHostOwner();
    error ConfigIsFrozen();
    /// @notice Over-long, or holds a byte that cannot appear unescaped.
    error InvalidUrlComponent();
    error ExternalUrlEnabledWithoutPrefix();
    /// @notice Over-long, or holds a byte that cannot appear unescaped.
    error InvalidDescription();
    error DescriptionEnabledWithoutText();

    event MetadataConfigUpdated(MetadataConfig newConfig);
    event MetadataConfigFrozen();

    // The getters keep V2's names, so integrators read V3 the way they read V2.
    // forge-lint: disable-start(screaming-snake-case-immutable)
    TalismanMaterials public immutable materials;
    TalismanGeneratorV2 public immutable generator;
    TalismanSvgRendererV3 public immutable svgRenderer;
    /// @notice Served while `perVertexLighting` is off; V2's viewer.
    TalismanLiteHtmlRenderer public immutable liteRenderer;
    /// @notice Served while `perVertexLighting` is on.
    TalismanVertexLitHtmlRenderer public immutable vertexLitRenderer;
    /// @notice Source of the owner and of the cores behind the core facets.
    ITalismanHost public immutable host;
    // forge-lint: disable-end(screaming-snake-case-immutable)

    bool public configFrozen;

    MetadataConfig private _config;

    constructor(
        TalismanMaterials materialsContract,
        TalismanGeneratorV2 generatorContract,
        TalismanSvgRendererV3 svgRendererContract,
        TalismanLiteHtmlRenderer liteRendererContract,
        TalismanVertexLitHtmlRenderer vertexLitRendererContract,
        ITalismanHost hostContract,
        MetadataConfig memory initialConfig
    ) {
        materials = materialsContract;
        generator = generatorContract;
        svgRenderer = svgRendererContract;
        liteRenderer = liteRendererContract;
        vertexLitRenderer = vertexLitRendererContract;
        host = hostContract;

        _validateConfig(initialConfig);
        _config = initialConfig;
    }

    // --- configuration -------------------------------------------------------

    function config() external view returns (MetadataConfig memory) {
        return _config;
    }

    /// @notice Owner of the token contract only, while unfrozen.
    /// @dev Follow with the token contract's `setRenderer` to emit ERC-4906
    ///      `BatchMetadataUpdate`.
    function setMetadataConfig(MetadataConfig calldata newConfig) external {
        if (configFrozen) {
            revert ConfigIsFrozen();
        }
        _requireHostOwner();
        _validateConfig(newConfig);
        _config = newConfig;
        emit MetadataConfigUpdated(newConfig);
    }

    /// @notice Owner of the token contract only; irreversible.
    /// @dev Freezes the `external_url` expiry too.
    function freezeConfig() external {
        if (configFrozen) {
            revert ConfigIsFrozen();
        }
        _requireHostOwner();
        configFrozen = true;
        emit MetadataConfigFrozen();
    }

    // --- ITalismanRenderer ---------------------------------------------------

    /// @inheritdoc ITalismanRenderer
    function unrevealedURI(uint256 tokenId) external view override returns (string memory) {
        string memory json = string.concat(
            '{"name":"Talisman #',
            LibString.toString(tokenId),
            '"',
            _descriptionField(),
            ',"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_unrevealedSvg())),
            '"',
            _externalUrlField(tokenId),
            _backgroundColorField(),
            "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
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
        return _buildTokenUri(tokenId, _generate(materialId, form, cores, seed), seed, genesis);
    }

    /// @inheritdoc ITalismanRenderer
    /// @dev Returns the raw SVG.
    function imageFromTraits(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        external
        view
        override
        returns (string memory)
    {
        return _renderSvg(_generate(materialId, form, cores, seed));
    }

    /// @inheritdoc ITalismanRenderer
    /// @dev Returns the raw HTML.
    function htmlFromTraits(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        external
        view
        override
        returns (string memory)
    {
        return _renderHtml(_generate(materialId, form, cores, seed));
    }

    /// @inheritdoc ITalismanRenderer
    /// @dev Returns the raw STL.
    function stlFromTraits(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        external
        view
        override
        returns (bytes memory)
    {
        return _renderStl(_generate(materialId, form, cores, seed));
    }

    // --- core facets ---------------------------------------------------------

    struct CoreFacet {
        string key;
        string value;
        /// @dev True for a `<Pole> Kind` facet, false for a `<Pole> Core N` facet.
        bool kind;
    }

    /// @notice Per filled pole, a `<Pole> Kind` naming the kind it holds, then
    ///         one `<Pole> Core I`..`IV` per core. Lithic first.
    /// @dev Empty when the stored cores cannot be read or do not reproduce the
    ///      traits. Ignores the metadata switches.
    function coreFacetsOf(uint256 tokenId, uint8 materialId, TalismanForms.ShapeForm form, uint8 coreCount)
        external
        view
        returns (CoreFacet[] memory)
    {
        return _coreFacets(tokenId, materialId, form, coreCount);
    }

    // --- merge kinds ---------------------------------------------------------

    /// @notice The `"<Material> <Form>"` kinds a talisman can merge under. A
    ///         Mythic has one per pole, Lithic first.
    /// @dev Falls back to the passed traits when the stored cores do not
    ///      reproduce them; empty when a Mythic's poles cannot be recovered.
    function mergeKindsOf(uint256 tokenId, uint8 materialId, TalismanForms.ShapeForm form, uint8 coreCount)
        external
        view
        returns (string[] memory)
    {
        return _mergeKinds(tokenId, materialId, form, coreCount);
    }

    // --- metadata assembly ---------------------------------------------------

    /// @dev Split out to stay under the stack-depth ceiling.
    function _buildTokenUri(uint256 tokenId, TalismanGeneratorV2.Talisman memory tal, uint16 seed, bool genesis)
        private
        view
        returns (string memory)
    {
        string memory svg = _renderSvg(tal);
        string memory html = _renderHtml(tal);

        string memory json = string.concat(
            '{"name":"Talisman #',
            LibString.toString(tokenId),
            '"',
            _descriptionField(),
            ',"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","animation_url":"data:text/html;base64,',
            Base64.encode(bytes(html)),
            '"',
            _externalUrlField(tokenId),
            _backgroundColorField(),
            ',"attributes":',
            _attributes(tokenId, tal, genesis, seed),
            "}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @dev Validated on write to need no escaping.
    function _descriptionField() private view returns (string memory) {
        if (!_config.descriptionEnabled) {
            return "";
        }
        return string.concat(',"description":"', _config.description, '"');
    }

    function _externalUrlField(uint256 tokenId) private view returns (string memory) {
        MetadataConfig storage cfg = _config;
        if (!cfg.externalUrlEnabled) {
            return "";
        }
        if (cfg.urlExpiresAt != 0 && block.timestamp >= cfg.urlExpiresAt) {
            return "";
        }
        return string.concat(',"external_url":"', cfg.urlPrefix, LibString.toString(tokenId), cfg.urlSuffix, '"');
    }

    function _backgroundColorField() private view returns (string memory) {
        MetadataConfig storage cfg = _config;
        if (!cfg.backgroundColorEnabled) {
            return "";
        }
        return string.concat(
            ',"background_color":"', LibString.toHexStringNoPrefix(uint256(uint24(cfg.backgroundColor)), 3), '"'
        );
    }

    // --- attributes ----------------------------------------------------------

    /// @dev `Material` is unconditional and first, so every later entry prepends
    ///      its own separator.
    function _attributes(uint256 tokenId, TalismanGeneratorV2.Talisman memory tal, bool genesis, uint16 seed)
        private
        view
        returns (string memory)
    {
        MetadataConfig storage cfg = _config;

        string memory buf = string.concat("[", _strTrait("Material", tal.material.name));

        if (cfg.chromaTrait) {
            buf = string.concat(
                buf, ",", _strTrait("Chroma", materials.chromaName(TalismanMaterials.Chroma(tal.chroma)))
            );
        }

        buf = string.concat(
            buf,
            ",",
            _strTrait("Essence", materials.essenceName(tal.material.essence)),
            ",",
            _strTrait("Form", _formName(TalismanForms.ShapeForm(tal.shapeForm))),
            ",",
            _strTrait("Tier", generator.facetTierName(TalismanGeneratorV2.FacetTier(tal.facetTier))),
            ",",
            _strTrait("Cores", _coresValue(tal.cores, tal.material.essence))
        );

        if (cfg.seedTrait) {
            buf = string.concat(buf, ",", _strTrait("Seed", LibString.toHexString(uint256(seed), 2)));
        }
        if (cfg.genesisTrait) {
            buf = string.concat(buf, ",", _boolTrait("Genesis", genesis));
        }
        if (cfg.coreKindTrait || cfg.coreSeedTrait) {
            buf = string.concat(
                buf, _coreFacetEntries(tokenId, tal.materialId, TalismanForms.ShapeForm(tal.shapeForm), tal.cores)
            );
        }

        return string.concat(buf, "]");
    }

    /// @dev A 2+2 Mythic and a four-core Prime both hold four; `"2 + 2"` keeps
    ///      them distinct values. An odd Mythic count is unreachable and falls
    ///      back to the plain count.
    function _coresValue(uint8 cores, TalismanMaterials.Essence essence) private pure returns (string memory) {
        if (essence == TalismanMaterials.Essence.Mythic && cores >= 2 && cores % 2 == 0) {
            string memory perPole = LibString.toString(uint256(cores) / 2);
            return string.concat(perPole, " + ", perPole);
        }
        return LibString.toString(uint256(cores));
    }

    /// @dev An external self-call, so a revert inside costs the token its core
    ///      facets rather than its whole document.
    function _coreFacetEntries(uint256 tokenId, uint8 materialId, TalismanForms.ShapeForm form, uint8 coreCount)
        private
        view
        returns (string memory buf)
    {
        MetadataConfig storage cfg = _config;
        try this.coreFacetsOf(tokenId, materialId, form, coreCount) returns (CoreFacet[] memory facets) {
            for (uint256 i; i < facets.length; ++i) {
                if (facets[i].kind ? cfg.coreKindTrait : cfg.coreSeedTrait) {
                    buf = string.concat(buf, ",", _strTrait(facets[i].key, facets[i].value));
                }
            }
        } catch {}
    }

    /// @dev Only the stored cores can describe a Mythic's two poles; its derived
    ///      material id folds them together.
    function _coreFacets(uint256 tokenId, uint8 materialId, TalismanForms.ShapeForm form, uint8 coreCount)
        private
        view
        returns (CoreFacet[] memory)
    {
        try host.coresOf(tokenId) returns (uint256[] memory cores) {
            if (
                cores.length != 0 && cores.length == coreCount
                    && TalismanTransformationLib.deriveMaterialId(materials, cores) == materialId
                    && TalismanTransformationLib.deriveShapeForm(cores) == form
            ) {
                return _facetsFromCores(cores);
            }
        } catch {}
        return new CoreFacet[](0);
    }

    /// @dev Lithic first, independent of storage order.
    function _facetsFromCores(uint256[] memory cores) private view returns (CoreFacet[] memory) {
        (uint256[] memory lithic, uint256[] memory lumic) = _splitByPole(cores);

        uint256 total;
        if (lithic.length != 0) {
            total += 1 + lithic.length;
        }
        if (lumic.length != 0) {
            total += 1 + lumic.length;
        }

        CoreFacet[] memory out = new CoreFacet[](total);
        uint256 written = _writePole(out, 0, "Lithic", lithic);
        _writePole(out, written, "Lumic", lumic);
        return out;
    }

    /// @dev An empty pole is absent rather than named "None", which would become
    ///      a filterable value.
    function _writePole(CoreFacet[] memory out, uint256 at, string memory pole, uint256[] memory group)
        private
        view
        returns (uint256)
    {
        if (group.length == 0) {
            return at;
        }

        out[at++] = CoreFacet({key: string.concat(pole, " Kind"), value: _kindOf(group), kind: true});

        string memory coreKey = string.concat(pole, " Core");

        // The seed alone; material and form would only restate the kind facet.
        for (uint256 i; i < group.length; ++i) {
            out[at++] = CoreFacet({
                key: string.concat(coreKey, " ", _ordinal(i)),
                value: LibString.toHexString(uint256(TalismanCore.seed(group[i])), 2),
                kind: false
            });
        }

        return at;
    }

    /// @dev A pole never holds more than four cores; the fallback is unreachable.
    function _ordinal(uint256 index) private pure returns (string memory) {
        if (index == 0) {
            return "I";
        }
        if (index == 1) {
            return "II";
        }
        if (index == 2) {
            return "III";
        }
        if (index == 3) {
            return "IV";
        }
        return LibString.toString(index + 1);
    }

    /// @dev Unlike {_coreFacets}, falls back to the passed traits: a merge key
    ///      is determined by those alone.
    function _mergeKinds(uint256 tokenId, uint8 materialId, TalismanForms.ShapeForm form, uint8 coreCount)
        private
        view
        returns (string[] memory)
    {
        try host.coresOf(tokenId) returns (uint256[] memory cores) {
            if (
                cores.length != 0 && cores.length == coreCount
                    && TalismanTransformationLib.deriveMaterialId(materials, cores) == materialId
                    && TalismanTransformationLib.deriveShapeForm(cores) == form
            ) {
                return _kindsFromCores(cores);
            }
        } catch {}
        return _fallbackKinds(materialId, form);
    }

    function _kindsFromCores(uint256[] memory cores) private view returns (string[] memory) {
        (uint256[] memory lithic, uint256[] memory lumic) = _splitByPole(cores);
        uint256 lithicCount = lithic.length;
        uint256 lumicCount = lumic.length;

        string memory lithicKind = lithicCount == 0 ? "" : _kindOf(lithic);
        string memory lumicKind = lumicCount == 0 ? "" : _kindOf(lumic);

        if (lithicCount == 0 && lumicCount == 0) {
            return new string[](0);
        }
        if (lithicCount == 0) {
            return _one(lumicKind);
        }
        if (lumicCount == 0 || _eq(lithicKind, lumicKind)) {
            return _one(lithicKind);
        }

        string[] memory both = new string[](2);
        both[0] = lithicKind;
        both[1] = lumicKind;
        return both;
    }

    /// @dev A Mythic's poles are unrecoverable from the derived pair, so it gets
    ///      no entry rather than a placeholder kind.
    function _fallbackKinds(uint8 materialId, TalismanForms.ShapeForm form) private view returns (string[] memory) {
        TalismanMaterials.Material memory mat = materials.getMaterial(materialId);
        if (mat.essence == TalismanMaterials.Essence.Mythic) {
            return new string[](0);
        }
        return _one(string.concat(mat.name, " ", _formName(form)));
    }

    /// @dev Uses the merge rule's own helpers, so the trait can never name a kind
    ///      that would not merge.
    function _kindOf(uint256[] memory cores) private view returns (string memory) {
        uint8 mid = TalismanTransformationLib.deriveMaterialId(materials, cores);
        TalismanForms.ShapeForm form = TalismanTransformationLib.deriveShapeForm(cores);
        return string.concat(materials.getMaterial(mid).name, " ", _formName(form));
    }

    /// @dev The split cleaving performs. A core of Mythic essence is dropped;
    ///      that state is unreachable.
    function _splitByPole(uint256[] memory cores)
        private
        view
        returns (uint256[] memory lithic, uint256[] memory lumic)
    {
        uint256 len = cores.length;
        uint256 lithicCount;
        uint256 lumicCount;
        for (uint256 i; i < len; ++i) {
            TalismanMaterials.Essence essence = _coreEssence(cores[i]);
            if (essence == TalismanMaterials.Essence.Lithic) {
                ++lithicCount;
            } else if (essence == TalismanMaterials.Essence.Lumic) {
                ++lumicCount;
            }
        }

        lithic = new uint256[](lithicCount);
        lumic = new uint256[](lumicCount);
        uint256 li;
        uint256 ui;
        for (uint256 i; i < len; ++i) {
            TalismanMaterials.Essence essence = _coreEssence(cores[i]);
            if (essence == TalismanMaterials.Essence.Lithic) {
                lithic[li++] = cores[i];
            } else if (essence == TalismanMaterials.Essence.Lumic) {
                lumic[ui++] = cores[i];
            }
        }
    }

    function _coreEssence(uint256 core) private view returns (TalismanMaterials.Essence essence) {
        (essence,) = materials.elementOf(TalismanCore.materialId(core));
    }

    function _one(string memory value) private pure returns (string[] memory out) {
        out = new string[](1);
        out[0] = value;
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev `Rock` reads as `Boulder`, so a Rock-material Rock-form talisman is
    ///      not a "Rock Rock".
    function _formName(TalismanForms.ShapeForm form) private pure returns (string memory) {
        if (form == TalismanForms.ShapeForm.Rock) {
            return "Boulder";
        }
        return TalismanForms.shapeFormName(form);
    }

    function _trait(string memory key, string memory rawValue) private pure returns (string memory) {
        return string.concat('{"trait_type":"', key, '","value":', rawValue, "}");
    }

    function _strTrait(string memory key, string memory value) private pure returns (string memory) {
        return _trait(key, string.concat('"', value, '"'));
    }

    function _boolTrait(string memory key, bool value) private pure returns (string memory) {
        return _trait(key, value ? "true" : "false");
    }

    // --- validation ----------------------------------------------------------

    function _requireHostOwner() private view {
        if (msg.sender != host.owner()) {
            revert NotHostOwner();
        }
    }

    /// @dev Rejected on write rather than escaped on every read: one bad byte
    ///      would break every token's metadata.
    function _validateConfig(MetadataConfig memory cfg) private pure {
        if (!_isEmittable(bytes(cfg.urlPrefix), MAX_URL_COMPONENT_BYTES, false)) {
            revert InvalidUrlComponent();
        }
        if (!_isEmittable(bytes(cfg.urlSuffix), MAX_URL_COMPONENT_BYTES, false)) {
            revert InvalidUrlComponent();
        }
        if (cfg.externalUrlEnabled && bytes(cfg.urlPrefix).length == 0) {
            revert ExternalUrlEnabledWithoutPrefix();
        }
        if (!_isEmittable(bytes(cfg.description), MAX_DESCRIPTION_BYTES, true)) {
            revert InvalidDescription();
        }
        if (cfg.descriptionEnabled && bytes(cfg.description).length == 0) {
            revert DescriptionEnabledWithoutText();
        }
    }

    /// @dev Printable ASCII, no quote or backslash; URLs also refuse the space.
    function _isEmittable(bytes memory value, uint256 maxLen, bool allowSpace) private pure returns (bool) {
        if (value.length > maxLen) {
            return false;
        }
        uint8 low = allowSpace ? 0x20 : 0x21;
        for (uint256 i; i < value.length; ++i) {
            uint8 ch = uint8(value[i]);
            if (ch < low || ch > 0x7E || ch == 0x22 || ch == 0x5C) {
                return false;
            }
        }
        return true;
    }

    // --- artwork -------------------------------------------------------------

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

    function _generate(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        private
        view
        returns (TalismanGeneratorV2.Talisman memory)
    {
        TalismanMaterials.Material memory mat = materials.getMaterial(materialId);
        TalismanGeneratorV2.FacetTier tier = generator.tierFromCores(cores, mat.essence);
        return generator.generate(mat, materialId, form, cores, tier, seed);
    }

    /// @dev Split out to stay under the stack-depth ceiling.
    function _renderSvg(TalismanGeneratorV2.Talisman memory tal) private view returns (string memory) {
        Camera memory camera = _buildCamera(tal.maxRadius);
        LightSettings memory light = _buildLight(tal, camera);
        RenderSettings memory settings =
            RenderSettings({fillMode: uint8(FillMode.Solid), cullMode: uint8(CullMode.Back)});
        return svgRenderer.renderSvg(
            tal.triangles,
            camera,
            tal.materials,
            settings,
            light,
            _config.seamStroke,
            _config.perVertexLighting,
            tal.materialId
        );
    }

    /// @dev Edits on the viewer's output, not its source: the flat viewer is
    ///      V2's deployed one.
    function _renderHtml(TalismanGeneratorV2.Talisman memory tal) private view returns (string memory) {
        Camera memory camera = _buildCamera(tal.maxRadius);
        LightSettings memory light = _buildLight(tal, camera);
        RenderSettings memory settings =
            RenderSettings({fillMode: uint8(FillMode.Solid), cullMode: uint8(CullMode.Back)});
        string memory html;
        if (_config.perVertexLighting) {
            html = vertexLitRenderer.renderHtml(
                tal.triangles,
                camera,
                tal.materials,
                settings,
                light,
                TalismanVertexLitHtmlRenderer.LiteHtmlRenderSettings({
                    orbitControls: true,
                    autoRotate: true,
                    debug: false,
                    spinStallMs: _config.spinEase ? _config.spinStallMs : 0,
                    spinEaseMs: _config.spinEase ? _config.spinEaseMs : 0
                }),
                true,
                tal.materialId
            );
        } else {
            html = liteRenderer.renderHtml(
                tal.triangles,
                camera,
                tal.materials,
                settings,
                light,
                TalismanLiteHtmlRenderer.LiteHtmlRenderSettings({orbitControls: true, autoRotate: true, debug: false})
            );
        }
        html = LibString.replace(html, "html,body{margin:0", "html,body{background:#000;margin:0");
        if (_config.preserveDrawingBuffer) {
            html = LibString.replace(html, WEBGL_CONTEXT_ATTRIBUTES, WEBGL_CONTEXT_ATTRIBUTES_PRESERVED);
        }
        return html;
    }

    /// @dev Colour is pre-multiplied by reflectance to match the Lambert response
    ///      the other renderers bake in.
    function _renderStl(TalismanGeneratorV2.Talisman memory tal) private pure returns (bytes memory) {
        return TalismanStlRenderer.renderStlBytes(tal.triangles, tal.materials, "Talisman", tal.material.reflectance);
    }

    // --- camera / light ------------------------------------------------------

    function _buildCamera(int256 maxRadius) private pure returns (Camera memory) {
        int256 camDist = (maxRadius * CAM_DIST_PER_MILLE) / 1000;
        int256 camY = (camDist * CAM_Y_PER_MILLE) / CAM_DIST_PER_MILLE;
        int256 camXz = (camDist * CAM_XZ_PER_MILLE) / CAM_DIST_PER_MILLE;
        return Camera({
            location: Point3D({x: camXz, y: camY, z: camXz}), lookAt: Point3D({x: 0, y: 0, z: 0}), fieldOfView: FOV_WAD
        });
    }

    function _buildLight(TalismanGeneratorV2.Talisman memory tal, Camera memory camera)
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
