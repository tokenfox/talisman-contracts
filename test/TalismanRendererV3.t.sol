// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ITalismanHost} from "../src/ITalismanHost.sol";
import {Talismans} from "../src/Talismans.sol";
import {TalismanCore} from "../src/TalismanCore.sol";
import {TalismanForms} from "../src/TalismanForms.sol";
import {TalismanGeneratorV2} from "../src/TalismanGeneratorV2.sol";
import {TalismanLiteHtmlRenderer} from "../src/TalismanLiteHtmlRenderer.sol";
import {TalismanLitMaterials} from "../src/TalismanLitMaterials.sol";
import {TalismanVertexLitHtmlRenderer} from "../src/TalismanVertexLitHtmlRenderer.sol";
import {TalismanVertexLitViewerScript} from "../src/TalismanVertexLitViewerScript.sol";
import {TalismanMaterials} from "../src/TalismanMaterials.sol";
import {TalismanRendererV2} from "../src/TalismanRendererV2.sol";
import {TalismanRendererV3} from "../src/TalismanRendererV3.sol";
import {TalismanSvgRendererV2} from "../src/TalismanSvgRendererV2.sol";
import {TalismanSvgRendererV3} from "../src/TalismanSvgRendererV3.sol";
import {
    Camera,
    CullMode,
    FillMode,
    LightSettings,
    Material,
    Point3D,
    RenderSettings,
    Triangle
} from "../src/TalismanStructs.sol";

/// @dev A host whose `coresOf` always reverts, to prove the renderer degrades to
///      the fallback instead of taking a token's whole document down with it.
contract RevertingHost is ITalismanHost {
    address private immutable OWNER;

    constructor(address owner_) {
        OWNER = owner_;
    }

    function owner() external view returns (address) {
        return OWNER;
    }

    function coresOf(uint256) external pure returns (uint256[] memory) {
        revert("no cores for you");
    }
}

/// @dev Opens the per-face lighting model so a single facet can be lit under a
///      chosen material, without going through a whole image.
contract LitHarness is TalismanSvgRendererV3 {
    function face(Triangle memory tri, Camera memory camera, LightSettings memory light, uint8 materialId)
        external
        pure
        returns (FaceLight memory)
    {
        return _faceLight(tri, camera, light, TalismanLitMaterials.params(materialId));
    }
}

/// @notice Behaviour spec for {TalismanRendererV3}.
///
///         Every artwork change V3 makes has a switch, so the suite splits in
///         two: parity tests that pin the image, viewer and mesh to V2 exactly
///         once those switches are off, and behaviour tests for what V3 adds -
///         the seam stroke, per-vertex lighting, the kept drawing buffer, the
///         per-pole core facets, `Cores` as text, the configurable
///         `external_url` / `background_color` / `description`, and the
///         owner-guarded configuration surface behind them.
/// @dev The test contract is the authorised minter and the owner of the token
///      contract, so it is also the account V3 accepts configuration from.
contract TalismanRendererV3Test is Test {
    /// @dev 2027-05-23T00:00:00Z, the shipped `external_url` deadline.
    uint64 internal constant EXPIRES_AT = 1811030400;

    string internal constant URL_PREFIX = "https://talismans.tokenfox.art/";

    Talismans internal nft;
    TalismanMaterials internal mats;
    TalismanRendererV2 internal v2;
    TalismanRendererV3 internal v3;
    TalismanRendererV3 internal v3Plain;
    /// @dev V3 as shipped but with per-vertex lighting off, so the tests that
    ///      pin the seam stroke and the kept drawing buffer against V2's flat
    ///      bytes still have a flat V3 to pin them against.
    TalismanRendererV3 internal v3Flat;

    /// @dev The blob the lit viewer under test reads its script from.
    address internal viewerScript;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal stranger = address(0x5747A);

    // A stable trait tuple for the parity tests: Brilliant never flips, so any
    // V2/V3 delta on it would have to come from V3 itself.
    uint8 internal constant CLEAN_MID = 5;
    TalismanForms.ShapeForm internal constant CLEAN_FORM = TalismanForms.ShapeForm.Brilliant;
    uint8 internal constant CLEAN_CORES = 1;
    uint16 internal constant CLEAN_SEED = 0x1234;

    function setUp() public {
        nft = new Talismans();
        nft.setMinter(address(this));
        mats = new TalismanMaterials();
        nft.setMaterials(mats);
        nft.setTransformationSettings(true, true);

        TalismanGeneratorV2 gen = new TalismanGeneratorV2();
        TalismanSvgRendererV2 svg = new TalismanSvgRendererV2();
        TalismanSvgRendererV3 svg3 = new TalismanSvgRendererV3();
        TalismanLiteHtmlRenderer lite = new TalismanLiteHtmlRenderer();
        viewerScript = SSTORE2.write(bytes(TalismanVertexLitViewerScript.JS));
        TalismanVertexLitHtmlRenderer lit = new TalismanVertexLitHtmlRenderer(viewerScript);

        v2 = new TalismanRendererV2(mats, gen, svg, lite);
        v3 = new TalismanRendererV3(mats, gen, svg3, lite, lit, ITalismanHost(address(nft)), _defaultConfig());

        // Parity with V2 is asserted against the killswitch state: shipping
        // the seam stroke and the kept drawing buffer on means V3's image and
        // viewer deliberately differ from V2's, and what must still hold is
        // that switching them off returns both to V2's bytes exactly.
        TalismanRendererV3.MetadataConfig memory plain = _defaultConfig();
        plain.seamStroke = false;
        plain.preserveDrawingBuffer = false;
        plain.perVertexLighting = false;
        v3Plain = new TalismanRendererV3(mats, gen, svg3, lite, lit, ITalismanHost(address(nft)), plain);

        TalismanRendererV3.MetadataConfig memory flat = _defaultConfig();
        flat.perVertexLighting = false;
        v3Flat = new TalismanRendererV3(mats, gen, svg3, lite, lit, ITalismanHost(address(nft)), flat);
        nft.setRenderer(v3);

        vm.roll(100);
        vm.warp(1_700_000_000); // well before EXPIRES_AT
        vm.prevrandao(bytes32(uint256(0xc0ffee)));
    }

    /// @dev The configuration the deploy script ships: link on, black background
    ///      on, description dark, Chroma and Seed off, Genesis, core facets, the
    ///      seam stroke and the kept drawing buffer on.
    function _defaultConfig() internal pure returns (TalismanRendererV3.MetadataConfig memory) {
        return TalismanRendererV3.MetadataConfig({
            externalUrlEnabled: true,
            urlPrefix: URL_PREFIX,
            urlSuffix: "",
            urlExpiresAt: EXPIRES_AT,
            backgroundColorEnabled: true,
            backgroundColor: bytes3(0x000000),
            descriptionEnabled: false,
            description: "",
            chromaTrait: false,
            seedTrait: false,
            genesisTrait: true,
            coreKindTrait: true,
            coreSeedTrait: true,
            seamStroke: true,
            preserveDrawingBuffer: true,
            perVertexLighting: true,
            spinEase: true,
            spinStallMs: 100,
            spinEaseMs: 800
        });
    }

    // --- artwork parity with V2 ----------------------------------------------

    function test_image_byteIdenticalToV2_whenSeamStrokeIsOff() public view {
        assertEq(
            v3Plain.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            v2.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED)
        );
    }

    /// @dev And with it on, the image is deliberately not V2's - the changed
    ///      artwork is the feature, not a regression.
    function test_image_differsFromV2_whenSeamStrokeIsOn() public view {
        assertNotEq(
            v3.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            v2.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED)
        );
    }

    function test_html_byteIdenticalToV2_whenPreserveDrawingBufferIsOff() public view {
        assertEq(
            v3Plain.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            v2.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED)
        );
    }

    /// @dev And with it on, the viewer is deliberately not V2's - a canvas that
    ///      can be captured is the feature.
    function test_html_differsFromV2_whenPreserveDrawingBufferIsOn() public view {
        assertNotEq(
            v3.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            v2.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED)
        );
    }

    function test_stl_byteIdenticalToV2() public view {
        assertEq(
            v3.stlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            v2.stlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED)
        );
    }

    /// @dev Every form at every tier, so parity is a property of the pipeline
    ///      rather than of one lucky tuple.
    function test_artworkParity_acrossFormsAndTiers() public view {
        for (uint8 form; form <= uint8(type(TalismanForms.ShapeForm).max); ++form) {
            for (uint8 cores = 1; cores <= 4; ++cores) {
                TalismanForms.ShapeForm f = TalismanForms.ShapeForm(form);
                uint16 seed = uint16(uint256(form) * 977 + cores);
                assertEq(
                    v3Plain.imageFromTraits(CLEAN_MID, f, cores, seed),
                    v2.imageFromTraits(CLEAN_MID, f, cores, seed),
                    "image drifted from V2"
                );
                assertEq(
                    v3Plain.htmlFromTraits(CLEAN_MID, f, cores, seed),
                    v2.htmlFromTraits(CLEAN_MID, f, cores, seed),
                    "html drifted from V2"
                );
                assertEq(
                    v3.stlFromTraits(CLEAN_MID, f, cores, seed),
                    v2.stlFromTraits(CLEAN_MID, f, cores, seed),
                    "stl drifted from V2"
                );
            }
        }
    }

    /// @dev The fields V3 shares with V2 must be the same bytes; only the ones
    ///      it deliberately adds or rewrites may differ.
    function test_tokenURI_sharesV2ImageAndAnimation() public view {
        string memory json3 = _json(v3Plain.tokenURIFromTraits(1, CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED, true));
        string memory json2 = _json(v2.tokenURIFromTraits(1, CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED, true));
        assertEq(_field(json3, '"image":"'), _field(json2, '"image":"'));
        assertEq(_field(json3, '"animation_url":"'), _field(json2, '"animation_url":"'));
        assertEq(_field(json3, '"name":"'), _field(json2, '"name":"'));
    }

    // --- seam stroke ---------------------------------------------------------

    /// @dev The shared attributes hoist to one group, and only the colour repeats
    ///      per polygon - so the stroke costs 17 bytes a facet, not a full
    ///      attribute set.
    function test_seamStroke_emitsOneGroupAndAMatchingStrokePerFacet() public view {
        // Flat shading, where a facet has one colour to stroke with. The lit
        // reading of the same rule is pinned by
        // test_perVertexLighting_strokesInItsOwnPassUnderEveryFill.
        string memory svg = v3Flat.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(svg, '<g stroke-linejoin="round" stroke-width="1">'), "group missing");
        assertEq(_count(svg, "<g "), 1, "exactly one group");
        assertEq(_count(svg, "</g>"), 1);
        assertEq(_count(svg, "<polygon "), _count(svg, ' stroke="#'), "every facet strokes itself");
        assertFalse(_has(svg, "stroke-miterlimit"), "inert with a round join");
    }

    /// @dev Off means absent, never a zero width - the same discipline every
    ///      other optional part of the document follows.
    function test_seamStroke_offEmitsNoStrokeAtAll() public view {
        string memory svg = v3Plain.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertFalse(_has(svg, "<g "), "no group when off");
        assertFalse(_has(svg, "stroke"), "no stroke attribute of any kind when off");
    }

    /// @dev The flag touches the image only. The viewer and the mesh are the same
    ///      bytes in both states - V2's, once the kept drawing buffer is off
    ///      as well.
    function test_seamStroke_leavesAnimationAndMeshUntouched() public {
        string memory htmlOn = v3.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.seamStroke = false;
        v3.setMetadataConfig(cfg);
        assertEq(v3.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED), htmlOn);
        assertEq(
            v3Plain.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            v2.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED)
        );
        assertEq(
            v3.stlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            v2.stlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED)
        );
        assertEq(
            v3Plain.stlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            v2.stlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED)
        );
        assertEq(v3.unrevealedURI(1), v3Plain.unrevealedURI(1), "the placeholder is unaffected");
    }

    /// @dev Wireframe already writes its own stroke, so the seam stroke must never
    ///      apply there. V3 always renders Solid, but the sub-renderer is public -
    ///      guard it there rather than trusting the caller.
    function test_seamStroke_neverAppliesInWireframe() public {
        TalismanSvgRendererV3 svg3 = new TalismanSvgRendererV3();
        Triangle[] memory tris = new Triangle[](1);
        tris[0] = Triangle({
            p1: Point3D({x: -1e18, y: -1e18, z: 0}),
            p2: Point3D({x: 1e18, y: -1e18, z: 0}),
            p3: Point3D({x: 0, y: 1e18, z: 0}),
            materialId: 0
        });
        Material[] memory pal = new Material[](1);
        pal[0] = Material({color: 0x8899AA});
        Camera memory cam =
            Camera({location: Point3D({x: 0, y: 0, z: 5e18}), lookAt: Point3D({x: 0, y: 0, z: 0}), fieldOfView: 35e18});
        LightSettings memory light;
        RenderSettings memory wire =
            RenderSettings({fillMode: uint8(FillMode.Wireframe), cullMode: uint8(CullMode.None)});

        assertEq(
            svg3.renderSvg(tris, cam, pal, wire, light, true),
            svg3.renderSvg(tris, cam, pal, wire, light, false),
            "the flag must not reach wireframe"
        );
    }

    // --- per-vertex lighting -------------------------------------------------

    /// @dev On, a facet is no longer one flat colour: its tone is carried by a
    ///      gradient fitted to the three corner values, referenced by the polygon
    ///      that uses it. Every gradient defined is used, and every reference
    ///      resolves - a dangling `url(#gN)` renders as black.
    function test_perVertexLighting_emitsAGradientPerVaryingFacet() public view {
        string memory svg = v3.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(svg, "<defs>"), "defs present");
        uint256 defined = _count(svg, "<linearGradient id=");
        assertGt(defined, 0, "at least one facet varies");
        assertEq(defined, _count(svg, 'fill="url(#'), "every gradient is used exactly once");
        for (uint256 i = 0; i < defined; i++) {
            assertTrue(_has(svg, string.concat('id="g', vm.toString(i), '"')), "gradient ids run 0..n-1");
        }
    }

    /// @dev The switch is a shading switch, nothing more: every facet the flat
    ///      image draws appears in the lit image at the same coordinates. The lit
    ///      image adds a second layer per facet for the highlight, but never more
    ///      than one, and drops it where the highlight rounds to nothing. Each
    ///      layer is written twice - once to the stroke pass, once to the fill
    ///      pass - so four polygons a facet is the ceiling.
    function test_perVertexLighting_movesNoVertex() public view {
        string memory lit = v3.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        string memory flat = v3Flat.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);

        uint256 faces = _count(flat, 'points="');
        assertGt(faces, 0, "the flat image drew something");

        uint256 from;
        for (uint256 i = 0; i < faces; i++) {
            uint256 start = LibString.indexOf(flat, 'points="', from) + 8;
            uint256 end = LibString.indexOf(flat, '"', start);
            assertTrue(_has(lit, LibString.slice(flat, start, end)), "facet unmoved");
            from = end;
        }

        uint256 litFaces = _count(lit, 'points="');
        assertGe(litFaces, faces, "no facet lost");
        assertLe(litFaces, 4 * faces, "at most one overlay per facet, in two passes");
    }

    /// @dev Off means the flat image, not a lit image with the terms zeroed: no
    ///      gradient of any kind survives.
    function test_perVertexLighting_offEmitsNoGradientAtAll() public view {
        string memory svg = v3Flat.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertFalse(_has(svg, "linearGradient"), "no gradient when off");
        assertFalse(_has(svg, "<defs>"), "no defs when off");
        assertFalse(_has(svg, "url(#"), "no paint server reference when off");
    }

    /// @dev The seam stroke rule is to stroke a facet in its own paint. A lit
    ///      facet's paint is a gradient, so the stroke takes the gradient - and
    ///      a lit facet is two layers, so the stroke has to go somewhere that
    ///      does not paint either of them twice. It goes in its own pass, under
    ///      every fill:
    ///      fill and stroke on one element both cover the inner half of the stroke
    ///      band, which paints a translucent highlight there twice and draws a
    ///      bright wire around every facet. Pinned here so it cannot drift.
    function test_perVertexLighting_strokesInItsOwnPassUnderEveryFill() public view {
        string memory svg = v3.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(svg, '<g stroke-linejoin="round" stroke-width="1">'), "group still hoists the stroke");
        assertEq(_count(svg, "<g "), 1, "exactly one group - the stroke pass");
        assertEq(_count(svg, 'fill="none"'), _count(svg, " stroke="), "a stroked polygon never fills");
        assertEq(_count(svg, "<polygon "), 2 * _count(svg, " stroke="), "every layer is stroked, then filled");
        // The group closes before the first fill, so no fill can be overpainted by
        // a stroke - which is the whole of the ordering.
        assertTrue(_has(svg, '/>\n</g>\n  <polygon points="'), "the stroke pass ends before the fill pass");
    }

    /// @dev Both switches are independent: lighting on with the stroke off is a
    ///      legal state, and it strokes nothing.
    function test_perVertexLighting_isIndependentOfTheSeamStroke() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.seamStroke = false;
        v3.setMetadataConfig(cfg);
        string memory svg = v3.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(svg, "linearGradient"), "still lit");
        assertFalse(_has(svg, "stroke"), "no stroke of any kind");
        assertFalse(_has(svg, "<g "), "no group");
    }

    /// @dev The viewer follows the image. On, it is the lit viewer with the
    ///      shading model switched on at the top of its own flags.
    function test_perVertexLighting_reachesTheViewer() public view {
        string memory html = v3.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(html, "var LIT=1;"), "viewer is told to light per vertex");
        assertTrue(_has(html, "attribute vec4 c;varying vec4 vc;"), "the shader carries alpha");
        assertTrue(_has(html, "gl.blendFunc(gl.ONE,gl.ONE_MINUS_SRC_ALPHA)"), "the overlay pass can blend");
    }

    /// @dev Off, the viewer is the deployed one - not the lit viewer with its
    ///      flag down. That is what keeps byte parity with V2 reachable at all.
    function test_perVertexLighting_offReturnsTheDeployedViewer() public view {
        string memory html = v3Flat.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertFalse(_has(html, "var LIT="), "no lighting flag at all");
        assertFalse(_has(html, "attribute vec4 c"), "the deployed shader is untouched");
        assertEq(
            LibString.replace(html, ",preserveDrawingBuffer:true", ""),
            v2.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            "off is V2's viewer"
        );
    }

    // --- lit materials ---------------------------------------------------------

    /// @dev The material's seven lit terms reach the viewer as the same numbers
    ///      the image was baked with - printed in the table's own hundredths, so
    ///      a reader can check one against the other. Phosphor lights in its own
    ///      colour, Rock in white. The flat viewer is V2's and knows none of this.
    function test_litMaterials_termsReachTheLitViewerOnly() public view {
        string memory phosphor = v3.htmlFromTraits(43, CLEAN_FORM, 2, CLEAN_SEED);
        assertTrue(_has(phosphor, "TINT=1.00"), "Phosphor tints its highlight fully");
        assertTrue(_has(phosphor, "var SHIN=12,SGAIN=0.15,RPOW=3,RGAIN=0.25,TINT=1.00,WRAP=0.17,GLOW=0.07;"), "row 43");
        assertTrue(_has(phosphor, "var PULL=0.62,ATM=1.25,SEPS=0.012;"), "the script no longer carries its own");

        string memory rock = v3.htmlFromTraits(16, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(rock, "TINT=0.00"), "Rock keeps a white highlight");
        assertTrue(_has(rock, "var SHIN=5,SGAIN=0.10,RPOW=5,RGAIN=0.08,TINT=0.00,WRAP=0.02,GLOW=0.00;"), "row 16");

        // Diamond holds the table's extremes - the sharpest exponents and a gain
        // past one - so its row pins the integer part of the hundredths format.
        string memory diamond = v3.htmlFromTraits(15, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(diamond, "var SHIN=160,SGAIN=1.80,RPOW=6,RGAIN=0.30,TINT=0.35,WRAP=0.00,GLOW=0.00;"), "row 15");
        // Copper's glow is a single hundredth, the branch that pads a leading zero.
        string memory copper = v3.htmlFromTraits(20, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(copper, "GLOW=0.01;"), "row 20");

        string memory flat = v3Flat.htmlFromTraits(16, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertFalse(_has(flat, "var SHIN="), "the flat viewer carries no lit terms");
    }

    /// @dev The overlay colour follows the tint: at tint 0 it is exactly white,
    ///      so Deadform's strong rim shows as a #FFFFFF stop; Copper at tint 0.75
    ///      pulls every highlight toward its own colour, and white never appears.
    function test_litMaterials_tintColoursTheHighlight() public view {
        string memory deadform = v3.imageFromTraits(39, CLEAN_FORM, 2, CLEAN_SEED);
        assertTrue(_has(deadform, 'stop-color="#FFFFFF"'), "a white rim stop");

        string memory copper = v3.imageFromTraits(20, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(copper, "linearGradient"), "still lit");
        assertFalse(_has(copper, "#FFFFFF"), "no white anywhere");
    }

    /// @dev Diamond's gain of 1.80 pushes a facet square to the light past full
    ///      specular, and its shininess of 160 is the deepest the pow loop goes:
    ///      the highlight clamps to exactly one, and no term leaves [0, 1].
    function test_litMaterials_specularClampsAtOneUnderTheStrongestGain() public {
        LitHarness harness = new LitHarness();
        // A facet at the origin, square to a camera on the axis, small enough
        // that every vertex sees the light head-on.
        Triangle memory tri = Triangle({
            p1: Point3D({x: 1e15, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 1e15, z: 0}),
            p3: Point3D({x: -1e15, y: -1e15, z: 0}),
            materialId: 15
        });
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 10e18}), lookAt: Point3D({x: 0, y: 0, z: 0}), fieldOfView: 45e18
        });
        LightSettings memory light;
        light.ambient = 0.15e18;
        light.reflectance = 1e18;

        TalismanSvgRendererV3.FaceLight memory fl = harness.face(tri, camera, light, 15);
        for (uint256 k = 0; k < 3; ++k) {
            assertEq(fl.specular[k], 1e18, "specular clamps at one");
            assertTrue(fl.diffuse[k] > 0.99e18 && fl.diffuse[k] <= 1e18, "diffuse lit in full, inside [0, 1]");
        }
    }

    /// @dev Every material has a row, and every row renders both surfaces.
    ///      Mythics take two cores for the first tier, so they are rendered on two.
    function test_litMaterials_everyMaterialRendersImageAndViewer() public view {
        for (uint8 id = 0; id < 48; ++id) {
            uint8 cores = mats.getMaterial(id).essence == TalismanMaterials.Essence.Mythic ? 2 : 1;
            string memory svg = v3.imageFromTraits(id, CLEAN_FORM, cores, CLEAN_SEED);
            assertTrue(_has(svg, "</svg>"), "image renders");
            string memory html = v3.htmlFromTraits(id, CLEAN_FORM, cores, CLEAN_SEED);
            assertTrue(_has(html, "var LIT=1;"), "viewer renders lit");
            assertTrue(_has(html, ",GLOW="), "viewer carries the row");
        }
    }

    // --- eased-in spin (lit viewer only) --------------------------------------

    /// @dev The shipped timings reach the lit viewer as its two spin constants,
    ///      and the script eases on them with a smoothstep.
    function test_spinEase_reachesTheLitViewer() public view {
        string memory html = v3.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(html, "var SD=100;var SE=800;"), "stall and ease reach the viewer");
        assertTrue(_has(html, "x*x*(3-2*x)"), "the script eases on them");
    }

    /// @dev Off, the timings are not merely ignored but emitted as zero, which
    ///      is the script's branch for starting at full speed.
    function test_spinEase_offEmitsZeroesWhateverTheTimingsSay() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.spinEase = false;
        cfg.spinStallMs = 250;
        cfg.spinEaseMs = 1500;
        v3.setMetadataConfig(cfg);
        string memory html = v3.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(html, "var SD=0;var SE=0;"), "zeroes when off");
        assertFalse(_has(html, "SE=1500"), "the stored timings stay out of the document");
    }

    /// @dev Both timings are dials and round-trip through the configuration.
    function test_spinEase_timingsAreAdjustable() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.spinStallMs = 250;
        cfg.spinEaseMs = 1500;
        v3.setMetadataConfig(cfg);
        assertEq(v3.config().spinStallMs, 250);
        assertEq(v3.config().spinEaseMs, 1500);
        string memory html = v3.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(html, "var SD=250;var SE=1500;"), "new timings reach the viewer");
        cfg.spinStallMs = 0;
        cfg.spinEaseMs = 0;
        v3.setMetadataConfig(cfg);
        html = v3.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(html, "var SD=0;var SE=0;"), "on with zero timings is full speed at once");
    }

    /// @dev The flat viewer is V2's deployed one and cannot ease, so the switch
    ///      never reaches it: with per-vertex lighting off the document carries
    ///      no spin constants at all, whatever the switch says.
    function test_spinEase_neverReachesTheDeployedViewer() public view {
        string memory html = v3Flat.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertFalse(_has(html, "var SD="), "no stall constant");
        assertFalse(_has(html, "var SE="), "no ease constant");
    }

    /// @dev Ships on with the measured timings.
    function test_spinEase_defaultIsOnAndRoundTrips() public {
        assertTrue(v3.config().spinEase, "ships on");
        assertEq(v3.config().spinStallMs, 100);
        assertEq(v3.config().spinEaseMs, 800);
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.spinEase = false;
        v3.setMetadataConfig(cfg);
        assertFalse(v3.config().spinEase);
        cfg.spinEase = true;
        v3.setMetadataConfig(cfg);
        assertTrue(v3.config().spinEase);
    }

    /// @dev The image the marketplace shows and the viewer beside it never
    ///      disagree about which shading model is in force.
    function test_perVertexLighting_imageAndViewerAgree() public {
        string memory json = _json(v3.tokenURIFromTraits(1, CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED, true));
        assertTrue(_has(_image(json), "linearGradient"), "on: the image is lit");
        assertTrue(_has(_animation(json), "var LIT=1;"), "on: the viewer is lit");

        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.perVertexLighting = false;
        v3.setMetadataConfig(cfg);
        json = _json(v3.tokenURIFromTraits(1, CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED, true));
        assertFalse(_has(_image(json), "linearGradient"), "off: the image is flat");
        assertFalse(_has(_animation(json), "var LIT="), "off: the viewer is flat");
    }

    /// @dev A fresh V3 ships lit, and the switch round-trips.
    function test_perVertexLighting_defaultsOnAndRoundTrips() public {
        assertTrue(v3.config().perVertexLighting, "ships on");
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.perVertexLighting = false;
        v3.setMetadataConfig(cfg);
        assertFalse(v3.config().perVertexLighting, "writes off");
        cfg.perVertexLighting = true;
        v3.setMetadataConfig(cfg);
        assertTrue(v3.config().perVertexLighting, "and back on");
    }

    /// @dev The switch touches the image and the viewer only. The mesh has no
    ///      shading to carry, so it is the same bytes either way.
    function test_perVertexLighting_leavesTheMeshUntouched() public view {
        assertEq(
            v3.stlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            v3Flat.stlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            "STL is shading-blind"
        );
    }

    // --- kept drawing buffer -------------------------------------------------

    string internal constant WEBGL_CALL =
        "cv.getContext('webgl',{antialias:true,alpha:true,preserveDrawingBuffer:true})";
    string internal constant EXPERIMENTAL_WEBGL_CALL =
        "cv.getContext('experimental-webgl',{antialias:true,alpha:true,preserveDrawingBuffer:true})";

    /// @dev Both WebGL context calls ask for a kept buffer - the standard one and
    ///      the legacy fallback - and nothing else in the viewer moves: stripping
    ///      the attribute back out gives V2's bytes exactly.
    function test_preserveDrawingBuffer_asksEveryWebGlContextToKeepItsFrame() public view {
        // Against the flat viewer, which is the deployed one: that is the only
        // state in which the attribute can be the whole diff from V2.
        string memory html = v3Flat.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(html, WEBGL_CALL), "webgl call");
        assertTrue(_has(html, EXPERIMENTAL_WEBGL_CALL), "experimental-webgl call");
        assertEq(_count(html, "preserveDrawingBuffer:true"), 2, "exactly the two context calls");
        assertEq(
            LibString.replace(html, ",preserveDrawingBuffer:true", ""),
            v2.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            "the attribute is the whole diff"
        );
    }

    /// @dev Off means absent: the attribute is not written as `false`, the viewer
    ///      is V2's.
    function test_preserveDrawingBuffer_offLeavesTheViewerAsV2() public view {
        string memory html = v3Plain.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertFalse(_has(html, "preserveDrawingBuffer"), "no attribute of any kind when off");
        assertEq(html, v2.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED));
    }

    function test_preserveDrawingBuffer_reachesTheAnimationUrl() public {
        string memory json = _json(v3.tokenURIFromTraits(1, CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED, true));
        assertTrue(_has(_animation(json), WEBGL_CALL), "on: animation_url carries the attribute");

        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.preserveDrawingBuffer = false;
        v3.setMetadataConfig(cfg);
        json = _json(v3.tokenURIFromTraits(1, CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED, true));
        assertFalse(_has(_animation(json), "preserveDrawingBuffer"), "off: animation_url is V2's");
    }

    /// @dev The switch touches the viewer only: image, mesh and placeholder are
    ///      the same bytes in both states.
    function test_preserveDrawingBuffer_leavesImageMeshAndPlaceholderUntouched() public {
        string memory imageOn = v3.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        bytes memory stlOn = v3.stlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        string memory placeholderOn = v3.unrevealedURI(1);

        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.preserveDrawingBuffer = false;
        v3.setMetadataConfig(cfg);
        assertEq(v3.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED), imageOn);
        assertEq(v3.stlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED), stlOn);
        assertEq(v3.unrevealedURI(1), placeholderOn);
    }

    function test_preserveDrawingBuffer_defaultIsOnAndRoundTrips() public {
        assertTrue(v3.config().preserveDrawingBuffer, "ships on");

        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.preserveDrawingBuffer = false;
        v3.setMetadataConfig(cfg);
        assertFalse(v3.config().preserveDrawingBuffer);

        cfg.preserveDrawingBuffer = true;
        v3.setMetadataConfig(cfg);
        assertTrue(v3.config().preserveDrawingBuffer);
    }

    // --- Cores as text -------------------------------------------------------

    /// @dev The eight (essence, count) pairs. A Mythic reaches twice a
    ///      single-pole talisman's count, so 2 and 4 are the two values that used
    ///      to mean two different things at once.
    function test_coresValue_everyEssenceAndCount() public view {
        assertEq(_coresOf(_uriFor(1, false, 1)), "1");
        assertEq(_coresOf(_uriFor(1, false, 2)), "2");
        assertEq(_coresOf(_uriFor(1, false, 3)), "3");
        assertEq(_coresOf(_uriFor(1, false, 4)), "4");

        assertEq(_coresOf(_uriFor(1, true, 2)), "1 + 1");
        assertEq(_coresOf(_uriFor(1, true, 4)), "2 + 2");
        assertEq(_coresOf(_uriFor(1, true, 6)), "3 + 3");
        assertEq(_coresOf(_uriFor(1, true, 8)), "4 + 4");
    }

    /// @dev The whole point: a Cut-tier Mythic and a Prime both hold four cores,
    ///      and after V3 they no longer share a value an offer could match.
    function test_coresValue_mythicNeverCollidesWithSinglePole() public view {
        assertTrue(
            keccak256(bytes(_coresOf(_uriFor(1, true, 4)))) != keccak256(bytes(_coresOf(_uriFor(1, false, 4)))),
            "4-core Mythic still collides with a Prime"
        );
        assertTrue(
            keccak256(bytes(_coresOf(_uriFor(1, true, 2)))) != keccak256(bytes(_coresOf(_uriFor(1, false, 2)))),
            "2-core Mythic still collides with a Cut"
        );
    }

    function test_coresValue_isAQuotedString() public view {
        assertTrue(_has(_json(_uriFor(1, false, 4)), '{"trait_type":"Cores","value":"4"}'), "Cores is not a string");
    }

    // --- core facets ---------------------------------------------------------

    function test_coreFacets_singlePoleNamesItsKindAndItsCores() public {
        uint256 id = _lithic(alice, 2);
        string memory json = _json(nft.tokenURI(id));

        assertTrue(_has(json, _facet("Lithic Kind", _expectedKind(id))), "kind facet missing");
        assertTrue(_has(json, _facet("Lithic Core I", _expectedCore(id, 0))), "core I missing");
        assertTrue(_has(json, _facet("Lithic Core II", _expectedCore(id, 1))), "core II missing");
        assertFalse(_has(json, '"trait_type":"Lithic Core III"'), "phantom third core");
        assertFalse(_has(json, '"trait_type":"Lumic Kind"'), "a pole it does not fill");
    }

    /// @dev The count of core facets is the token's core count - that occupancy
    ///      is what makes the facet list track the rarity axis.
    function test_coreFacets_oneFacetPerCore() public {
        for (uint256 cores = 1; cores <= 4; ++cores) {
            uint256 id = _lithic(alice, cores);
            assertEq(_count(_json(nft.tokenURI(id)), '"trait_type":"Lithic Core '), cores, "core facet count");
        }
    }

    function test_coreFacets_mythicFillsBothPolesLithicFirst() public {
        uint256 lithicId = _lithic(alice, 1);
        uint256 lumicId = _lumic(alice, 1);
        string memory lithicKind = _expectedKind(lithicId);
        string memory lumicKind = _expectedKind(lumicId);

        vm.prank(alice);
        uint256 mythic = nft.bond(lithicId, lumicId);

        string[] memory kinds = _kinds(mythic);
        assertEq(kinds.length, 2, "a Mythic must name both poles");
        assertEq(kinds[0], lithicKind, "Lithic pole must come first");
        assertEq(kinds[1], lumicKind);

        string memory json = _json(nft.tokenURI(mythic));
        assertTrue(_has(json, _facet("Lithic Kind", lithicKind)));
        assertTrue(_has(json, _facet("Lumic Kind", lumicKind)));
        assertTrue(_has(json, '"trait_type":"Lithic Core I"'), "Lithic ordinals start at I");
        assertTrue(_has(json, '"trait_type":"Lumic Core I"'), "Lumic ordinals restart at I");
        assertLt(
            _indexOf(json, '"trait_type":"Lithic Kind"'),
            _indexOf(json, '"trait_type":"Lumic Kind"'),
            "Lithic pole must be emitted first"
        );
    }

    /// @dev The invariant the superseded design broke: a Mythic emitted two
    ///      entries under one `trait_type`, and an indexer keyed by name keeps
    ///      only the last - so its Lithic pole was unfindable. No key may repeat,
    ///      in any configuration, on any token.
    function test_coreFacets_noRepeatedTraitTypeOnAnyToken() public {
        uint256 lithicId = _lithic(alice, 2);
        uint256 lumicId = _lumic(alice, 2);
        vm.prank(alice);
        uint256 mythic = nft.bond(lithicId, lumicId);

        _assertNoRepeatedTraitType(_json(nft.tokenURI(mythic)));
        _assertNoRepeatedTraitType(_json(nft.tokenURI(_lithic(alice, 4))));
        _assertNoRepeatedTraitType(_json(nft.tokenURI(_lumic(alice, 1))));
    }

    /// @dev A cleave must hand back exactly what the facets advertised: the two
    ///      products carry the kinds the Mythic named, on the matching poles.
    function test_coreFacets_cleaveProductsMatchTheAdvertisedKinds() public {
        uint256 lithicId = _lithic(alice, 1);
        uint256 lumicId = _lumic(alice, 1);
        vm.prank(alice);
        uint256 mythic = nft.bond(lithicId, lumicId);

        string[] memory advertised = _kinds(mythic);

        vm.prank(alice);
        (uint256 lithicOut, uint256 lumicOut) = nft.cleave(mythic);

        assertTrue(_has(_json(nft.tokenURI(lithicOut)), _facet("Lithic Kind", advertised[0])));
        assertTrue(_has(_json(nft.tokenURI(lumicOut)), _facet("Lumic Kind", advertised[1])));
    }

    /// @dev A hypothetical tuple has no cores to name, so it gets no core facets
    ///      at all - a kind facet without its cores would misstate how many the
    ///      talisman holds.
    function test_coreFacets_absentWhenCoresCannotBeRead() public view {
        assertFalse(_has(_json(_uriFor(1, false, 1)), " Kind\""), "kind facet on an unbacked tuple");
        assertFalse(_has(_json(_uriFor(1, false, 1)), " Core \""), "seed facets on an unbacked tuple");
    }

    /// @dev A core value is its seed and nothing else: `0x` then four lowercase
    ///      hex digits, zero-padded. The prefix is what keeps a core value from
    ///      colliding with a kind value, and reads as an opaque id rather than a
    ///      kind anyone could filter on.
    function test_coreFacets_seedIsFourLowercaseHexDigits() public {
        uint256 id = _lithic(alice, 1);
        string memory value = _expectedCore(id, 0);
        assertTrue(_has(_json(nft.tokenURI(id)), _facet("Lithic Core I", value)));
        assertEq(bytes(value).length, 6, "0x + four hex digits");
        assertTrue(_has(value, "0x"), "core value must carry the 0x marker");
        assertFalse(_has(value, " "), "core value names no material or form");
    }

    /// @dev The kind facet and the seed facets carry their own switches, so all
    ///      four states must render. The document is the only thing they govern:
    ///      `coreFacetsOf` describes the talisman and keeps returning both sorts
    ///      whatever the switches say.
    function test_coreFacets_kindAndSeedsSwitchIndependently() public {
        uint256 id = _lithic(alice, 2);

        for (uint256 mask; mask < 4; ++mask) {
            bool kind = mask & 1 != 0;
            bool seeds = mask & 2 != 0;
            TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
            cfg.coreKindTrait = kind;
            cfg.coreSeedTrait = seeds;
            v3.setMetadataConfig(cfg);

            string memory json = _json(nft.tokenURI(id));
            assertEq(_has(json, _facet("Lithic Kind", _expectedKind(id))), kind, "kind facet");
            assertEq(_has(json, _facet("Lithic Core I", _expectedCore(id, 0))), seeds, "seed facet I");
            assertEq(_has(json, _facet("Lithic Core II", _expectedCore(id, 1))), seeds, "seed facet II");
            assertTrue(_isBalancedJson(json), "unbalanced JSON");
            assertFalse(_has(json, ",,"), "double comma");
            _assertNoRepeatedTraitType(json);

            TalismanRendererV3.CoreFacet[] memory facets =
                v3.coreFacetsOf(id, nft.coreMaterialId(id), nft.coreShapeForm(id), 2);
            assertEq(facets.length, 3, "the view is not governed by the switches");
            assertTrue(facets[0].kind, "first entry is the pole's kind");
            assertFalse(facets[1].kind, "the rest are seeds");
        }
    }

    /// @dev Suppressing the kind facets must not renumber what is left: each
    ///      pole's ordinals still start at `I`, so a Mythic reads the same way
    ///      whether or not its kinds are shown.
    function test_coreFacets_seedOrdinalsSurviveTheKindFacetBeingOff() public {
        uint256 lithicId = _lithic(alice, 1);
        uint256 lumicId = _lumic(alice, 1);
        vm.prank(alice);
        uint256 mythic = nft.bond(lithicId, lumicId);

        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.coreKindTrait = false;
        v3.setMetadataConfig(cfg);

        string memory json = _json(nft.tokenURI(mythic));
        assertFalse(_has(json, '"Lithic Kind"'), "kind facet is off");
        assertFalse(_has(json, '"Lumic Kind"'), "kind facet is off");
        assertTrue(_has(json, '"trait_type":"Lithic Core I"'), "Lithic ordinals start at I");
        assertTrue(_has(json, '"trait_type":"Lumic Core I"'), "Lumic ordinals start at I");
        _assertNoRepeatedTraitType(json);
    }

    /// @dev Bonding the same pair the other way round must not reorder the
    ///      document - the order is fixed by pole, not by input order.
    function test_mergeKinds_orderIsIndependentOfBondInputOrder() public {
        uint256 lithicA = _lithic(alice, 1);
        uint256 lumicA = _lumic(alice, 1);
        vm.prank(alice);
        uint256 forward = nft.bond(lithicA, lumicA);
        string[] memory forwardKinds = _kinds(forward);

        vm.prank(alice);
        (uint256 lithicBack, uint256 lumicBack) = nft.cleave(forward);
        vm.prank(alice);
        uint256 reversed = nft.bond(lumicBack, lithicBack);

        string[] memory reversedKinds = _kinds(reversed);
        assertEq(reversedKinds.length, forwardKinds.length);
        assertEq(reversedKinds[0], forwardKinds[0]);
        assertEq(reversedKinds[1], forwardKinds[1]);
    }

    /// @dev The kinds name what a talisman holds, not a tally: a merged
    ///      token made of two same-kind halves still names that kind once.
    function test_mergeKinds_deduplicatesAcrossCores() public {
        (uint256 a, uint256 b) = _twoOfAKind(alice);

        vm.prank(alice);
        uint256 merged = nft.merge(a, b);

        string[] memory kinds = _kinds(merged);
        assertEq(kinds.length, 1, "two cores of one kind must yield one entry");
        assertEq(_count(_json(nft.tokenURI(merged)), ' Kind"'), 1, "one kind facet for one kind");
    }

    /// @dev The kind must be the very key merging compares, so the trait can
    ///      never advertise a pairing the token contract would reject.
    function test_mergeKinds_matchesTheKeyMergeItselfCompares() public {
        (uint256 a, uint256 b) = _twoOfAKind(alice);
        assertEq(_kinds(a)[0], _kinds(b)[0], "same-kind tokens must share a value");

        vm.prank(alice);
        nft.merge(a, b); // would revert MergeRequiresSameKind if they did not
    }

    /// @dev A hypothetical tuple rendered against an unrelated live id must
    ///      describe the tuple, not whatever that id happens to hold.
    function test_mergeKinds_ignoresCoresThatContradictThePassedTraits() public {
        uint256 id = _lithic(alice, 1);
        uint8 otherMid = _differentMaterialFrom(nft.coreMaterialId(id));

        string[] memory kinds =
            v3.mergeKindsOf(id, otherMid, TalismanForms.ShapeForm.Brilliant, nft.coreCount(id) == 1 ? 1 : 1);
        assertEq(kinds.length, 1);
        assertEq(
            kinds[0],
            string.concat(
                mats.getMaterial(otherMid).name, " ", TalismanForms.shapeFormName(TalismanForms.ShapeForm.Brilliant)
            )
        );
    }

    function test_mergeKinds_unmintedIdFallsBackToPassedTraits() public view {
        string[] memory kinds = v3.mergeKindsOf(999_999, CLEAN_MID, CLEAN_FORM, CLEAN_CORES);
        assertEq(kinds.length, 1);
        assertEq(kinds[0], string.concat(mats.getMaterial(CLEAN_MID).name, " ", _formName(CLEAN_FORM)));
    }

    /// @dev A Mythic tuple with no readable cores has no recoverable poles, and
    ///      gets no entry rather than a placeholder that would become a kind of
    ///      its own.
    function test_mergeKindsOf_unrecoverableMythicReturnsNothing() public view {
        uint8 mythicMid = _aMythicMaterial();
        assertEq(v3.mergeKindsOf(999_999, mythicMid, CLEAN_FORM, 2).length, 0);
        string memory doc = _json(v3.tokenURIFromTraits(999_999, mythicMid, CLEAN_FORM, 2, CLEAN_SEED, false));
        assertFalse(_has(doc, " Kind\""), "no kind facet");
        assertFalse(_has(doc, " Core \""), "no seed facets");
    }

    /// @dev The read-back is a convenience, never a dependency: a host that
    ///      cannot answer costs a token its core facets, not its whole document.
    ///      {mergeKindsOf} still falls back to the passed traits - it describes
    ///      a merge key, which a tuple alone determines - but the facets cannot,
    ///      because a tuple carries no cores to enumerate.
    function test_coreFacets_surviveAHostThatReverts() public {
        TalismanRendererV3 isolated = new TalismanRendererV3(
            mats,
            v3.generator(),
            v3.svgRenderer(),
            v3.liteRenderer(),
            v3.vertexLitRenderer(),
            ITalismanHost(address(new RevertingHost(address(this)))),
            _defaultConfig()
        );
        string memory json = _json(isolated.tokenURIFromTraits(7, CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED, true));
        assertFalse(_has(json, " Kind\""), "unreadable cores must yield no kind facet");
        assertFalse(_has(json, " Core \""), "unreadable cores must yield no seed facets");
        assertTrue(_isBalancedJson(json), "the document must survive intact");
        assertEq(isolated.mergeKindsOf(7, CLEAN_MID, CLEAN_FORM, CLEAN_CORES).length, 1, "the view still falls back");
    }

    // --- optional traits -----------------------------------------------------

    function test_defaultConfig_dropsChromaAndSeedKeepsGenesis() public view {
        string memory json = _json(_uriFor(1, false, 1));
        assertFalse(_has(json, '"trait_type":"Chroma"'), "Chroma is off by default");
        assertFalse(_has(json, '"trait_type":"Seed"'), "Seed is off by default");
        assertTrue(_has(json, '"trait_type":"Genesis"'), "Genesis stays on");
        assertTrue(_has(json, '"trait_type":"Material"'));
        assertTrue(_has(json, '"trait_type":"Essence"'));
        assertTrue(_has(json, '"trait_type":"Form"'));
        assertTrue(_has(json, '"trait_type":"Tier"'));
        assertTrue(_has(json, '"trait_type":"Cores"'));
    }

    /// @dev Five independently switchable entries in a hand-built list is where a
    ///      stray comma would hide, so every combination is rendered and parsed.
    function test_traitSwitchMatrix_alwaysValidJson() public {
        // A real token, so the core facets genuinely appear when switched on;
        // the unbacked tuple below can never carry them, and so
        // covers the other extreme of the same comma logic.
        uint256 id = _lithic(alice, 2);

        for (uint256 mask; mask < 32; ++mask) {
            TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
            cfg.chromaTrait = mask & 1 != 0;
            cfg.seedTrait = mask & 2 != 0;
            cfg.genesisTrait = mask & 4 != 0;
            cfg.coreKindTrait = mask & 8 != 0;
            cfg.coreSeedTrait = mask & 16 != 0;
            v3.setMetadataConfig(cfg);

            string memory json = _json(nft.tokenURI(id));
            string memory bare = _json(_uriFor(1, false, 1));
            for (uint256 k; k < 2; ++k) {
                string memory doc = k == 0 ? json : bare;
                assertTrue(_isBalancedJson(doc), "unbalanced JSON");
                assertFalse(_has(doc, ",]"), "trailing comma in attributes");
                assertFalse(_has(doc, "[,"), "leading comma in attributes");
                assertFalse(_has(doc, ",,"), "double comma");
            }
            assertEq(_has(json, '"trait_type":"Chroma"'), cfg.chromaTrait);
            assertEq(_has(json, '"trait_type":"Seed"'), cfg.seedTrait);
            assertEq(_has(json, '"trait_type":"Genesis"'), cfg.genesisTrait);
            assertEq(_has(json, '"Lithic Kind"'), cfg.coreKindTrait, "kind facet tracks its own switch");
            assertEq(_has(json, '"Lithic Core I"'), cfg.coreSeedTrait, "seed facets track their own switch");
            assertFalse(_has(bare, " Kind\""), "kind facet on an unbacked tuple");
            assertFalse(_has(bare, " Core "), "seed facets on an unbacked tuple");
        }
    }

    /// @dev The three top-level switches crossed with the extreme trait cases -
    ///      the hardest comma shapes the document can take.
    function test_topLevelSwitchMatrix_alwaysValidJson() public {
        for (uint256 mask; mask < 8; ++mask) {
            for (uint256 traits; traits < 2; ++traits) {
                TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
                cfg.externalUrlEnabled = mask & 1 != 0;
                cfg.backgroundColorEnabled = mask & 2 != 0;
                cfg.descriptionEnabled = mask & 4 != 0;
                if (cfg.descriptionEnabled) {
                    cfg.description = "A talisman.";
                }
                cfg.chromaTrait = traits == 1;
                cfg.seedTrait = traits == 1;
                cfg.genesisTrait = traits == 1;
                cfg.coreKindTrait = traits == 1;
                cfg.coreSeedTrait = traits == 1;
                v3.setMetadataConfig(cfg);

                string memory json = _json(_uriFor(1, false, 1));
                assertTrue(_isBalancedJson(json), "unbalanced JSON");
                assertFalse(_has(json, ",,"), "double comma");
                assertFalse(_has(json, "{,"), "leading comma in document");
                assertFalse(_has(json, ",}"), "trailing comma in document");
                assertEq(_has(json, '"external_url"'), cfg.externalUrlEnabled);
                assertEq(_has(json, '"background_color"'), cfg.backgroundColorEnabled);
                assertEq(_has(json, '"description"'), cfg.descriptionEnabled);
            }
        }
    }

    // --- external_url --------------------------------------------------------

    function test_externalUrl_composesPrefixIdSuffix() public view {
        assertTrue(
            _has(_json(_uriFor(1496, false, 1)), '"external_url":"https://talismans.tokenfox.art/1496"'),
            "link is not the token's page"
        );
    }

    function test_externalUrl_honoursASuffix() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.urlPrefix = "https://example.test/t/";
        cfg.urlSuffix = ".html";
        v3.setMetadataConfig(cfg);
        assertTrue(_has(_json(_uriFor(7, false, 1)), '"external_url":"https://example.test/t/7.html"'));
    }

    function test_externalUrl_absentWhenSwitchedOffEvenWithAPrefixStored() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.externalUrlEnabled = false;
        v3.setMetadataConfig(cfg);
        assertEq(v3.config().urlPrefix, URL_PREFIX, "the prefix is parked, not cleared");
        assertFalse(_has(_json(_uriFor(1, false, 1)), "external_url"));
    }

    /// @dev The deadline is exclusive: at the expiry second itself the link is
    ///      already gone, so there is no ambiguous instant.
    function test_externalUrl_expiryBoundaryIsExclusive() public {
        vm.warp(EXPIRES_AT - 1);
        assertTrue(_has(_json(_uriFor(1, false, 1)), "external_url"), "still live one second before");

        vm.warp(EXPIRES_AT);
        assertFalse(_has(_json(_uriFor(1, false, 1)), "external_url"), "must be gone at the deadline");

        vm.warp(EXPIRES_AT + 365 days);
        assertFalse(_has(_json(_uriFor(1, false, 1)), "external_url"));
    }

    function test_externalUrl_zeroExpiryNeverExpires() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.urlExpiresAt = 0;
        v3.setMetadataConfig(cfg);
        vm.warp(EXPIRES_AT + 100 * 365 days);
        assertTrue(_has(_json(_uriFor(1, false, 1)), "external_url"));
    }

    // --- background_color ----------------------------------------------------

    function test_backgroundColor_isSixLowercaseHexWithNoHash() public {
        assertTrue(_has(_json(_uriFor(1, false, 1)), '"background_color":"000000"'));

        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.backgroundColor = bytes3(0x00ff00);
        v3.setMetadataConfig(cfg);
        assertTrue(_has(_json(_uriFor(1, false, 1)), '"background_color":"00ff00"'), "must be left-padded to six");

        cfg.backgroundColor = bytes3(0xffffff);
        v3.setMetadataConfig(cfg);
        assertTrue(_has(_json(_uriFor(1, false, 1)), '"background_color":"ffffff"'));
        assertFalse(_has(_json(_uriFor(1, false, 1)), '"background_color":"#'), "no leading hash");
    }

    // --- description ---------------------------------------------------------

    function test_description_absentUnderTheShippedDefault() public view {
        assertFalse(_has(_json(_uriFor(1, false, 1)), "description"));
        assertFalse(_has(_json(v3.unrevealedURI(1)), "description"));
    }

    function test_description_absentWhileStoredButSwitchedOff() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.description = "Stored, not shown.";
        v3.setMetadataConfig(cfg);
        assertEq(v3.config().description, "Stored, not shown.");
        assertFalse(_has(_json(_uriFor(1, false, 1)), '"description"'));
    }

    function test_description_emittedRightAfterNameOnceEnabled() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.descriptionEnabled = true;
        cfg.description = "A talisman, cut from a single core.";
        v3.setMetadataConfig(cfg);

        string memory json = _json(_uriFor(1, false, 1));
        assertTrue(_has(json, '"description":"A talisman, cut from a single core."'));
        assertTrue(_has(json, '","description":"'), "description must follow name");
        assertTrue(_has(_json(v3.unrevealedURI(1)), '"description":"A talisman'), "pre-reveal carries it too");
    }

    // --- pre-reveal ----------------------------------------------------------

    function test_unrevealed_carriesTheTopLevelFieldsButNoTraits() public view {
        string memory json = _json(v3.unrevealedURI(42));
        assertTrue(_has(json, '"external_url":"https://talismans.tokenfox.art/42"'));
        assertTrue(_has(json, '"background_color":"000000"'));
        assertFalse(_has(json, "attributes"), "traits stay withheld until reveal");
        assertTrue(_has(json, '"image":"data:image/svg+xml;base64,'));
        assertTrue(_isBalancedJson(json));
    }

    function test_unrevealed_placeholderImageMatchesV2() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.externalUrlEnabled = false;
        cfg.backgroundColorEnabled = false;
        v3.setMetadataConfig(cfg);
        assertEq(v3.unrevealedURI(42), v2.unrevealedURI(42), "the placeholder art must not have moved");
    }

    // --- configuration surface -----------------------------------------------

    function test_config_readsBackWhatWasWritten() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.urlSuffix = "/view";
        cfg.backgroundColor = bytes3(0x123456);
        cfg.chromaTrait = true;
        v3.setMetadataConfig(cfg);

        TalismanRendererV3.MetadataConfig memory got = v3.config();
        assertEq(got.urlSuffix, "/view");
        assertEq(got.backgroundColor, bytes3(0x123456));
        assertTrue(got.chromaTrait);
    }

    function test_setMetadataConfig_rejectsAStranger() public {
        vm.prank(stranger);
        vm.expectRevert(TalismanRendererV3.NotHostOwner.selector);
        v3.setMetadataConfig(_defaultConfig());
    }

    /// @dev The owner is mirrored, not snapshotted: handing the collection over
    ///      hands its renderer over in the same act.
    function test_ownership_followsTheTokenContract() public {
        nft.transferOwnership(bob);
        vm.prank(bob);
        nft.acceptOwnership();

        vm.expectRevert(TalismanRendererV3.NotHostOwner.selector);
        v3.setMetadataConfig(_defaultConfig());

        vm.prank(bob);
        v3.setMetadataConfig(_defaultConfig());
    }

    /// @dev A pending, unaccepted handover must not yet grant control.
    function test_ownership_pendingTransferGrantsNothing() public {
        nft.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert(TalismanRendererV3.NotHostOwner.selector);
        v3.setMetadataConfig(_defaultConfig());
    }

    function test_setMetadataConfig_emitsTheFullNewState() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.chromaTrait = true;
        vm.expectEmit(address(v3));
        emit TalismanRendererV3.MetadataConfigUpdated(cfg);
        v3.setMetadataConfig(cfg);
    }

    function test_freezeConfig_locksTheDocumentForGood() public {
        v3.setMetadataConfig(_defaultConfig());

        vm.expectEmit(address(v3));
        emit TalismanRendererV3.MetadataConfigFrozen();
        v3.freezeConfig();

        assertTrue(v3.configFrozen());
        vm.expectRevert(TalismanRendererV3.ConfigIsFrozen.selector);
        v3.setMetadataConfig(_defaultConfig());
        vm.expectRevert(TalismanRendererV3.ConfigIsFrozen.selector);
        v3.freezeConfig();
    }

    function test_freezeConfig_rejectsAStranger() public {
        vm.prank(stranger);
        vm.expectRevert(TalismanRendererV3.NotHostOwner.selector);
        v3.freezeConfig();
    }

    /// @dev Frozen means frozen: reading still works, and the document is exactly
    ///      what it was at the moment of the lock.
    function test_freezeConfig_leavesRenderingIntact() public {
        string memory before = v3.tokenURIFromTraits(1, CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED, true);
        v3.freezeConfig();
        assertEq(v3.tokenURIFromTraits(1, CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED, true), before);
    }

    // --- viewer script -------------------------------------------------------

    /// @dev The script is no longer inlined in the viewer's own bytecode, so the
    ///      first thing to pin is that the blob still reaches the document whole -
    ///      a truncated or mis-spliced read would still produce valid HTML, just a
    ///      viewer that never draws. Read through a renderer with the kept drawing
    ///      buffer off, since that switch rewrites the script's own WebGL context
    ///      attributes on the way out.
    function test_viewerScript_reachesTheDocumentWhole() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.preserveDrawingBuffer = false;
        TalismanRendererV3 lit = new TalismanRendererV3(
            mats,
            v3.generator(),
            v3.svgRenderer(),
            v3.liteRenderer(),
            v3.vertexLitRenderer(),
            ITalismanHost(address(nft)),
            cfg
        );
        string memory html = lit.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertTrue(_has(html, TalismanVertexLitViewerScript.JS), "the whole script must be inlined");
    }

    /// @dev The point of holding the script separately: a second viewer built
    ///      against the same blob renders the same document, so a later viewer
    ///      that changes how the scene is emitted - but not how it is drawn -
    ///      costs a small contract rather than another ~12 KB of JavaScript.
    function test_viewerScript_isSharedByEveryViewerBuiltOnIt() public {
        TalismanVertexLitHtmlRenderer second = new TalismanVertexLitHtmlRenderer(viewerScript);
        assertEq(second.viewerScript(), v3.vertexLitRenderer().viewerScript(), "both must read the same blob");

        TalismanRendererV3 other = new TalismanRendererV3(
            mats,
            v3.generator(),
            v3.svgRenderer(),
            v3.liteRenderer(),
            second,
            ITalismanHost(address(nft)),
            _defaultConfig()
        );
        assertEq(
            other.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            v3.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED),
            "a viewer sharing the blob must render identically"
        );
    }

    /// @dev The blob is the authority on what the viewer draws, so it must be
    ///      exactly the source constant - that is what lets a reader verify the
    ///      deployed blob against the published source.
    function test_viewerScript_blobMatchesTheSourceConstant() public view {
        assertEq(string(SSTORE2.read(viewerScript)), TalismanVertexLitViewerScript.JS);
    }

    /// @dev A pointer with nothing behind it would render every viewer empty, so
    ///      it is refused at construction rather than discovered at render time.
    function test_viewerConstructor_rejectsAPointerWithNoCode() public {
        vm.expectRevert(TalismanVertexLitHtmlRenderer.InvalidViewerScript.selector);
        new TalismanVertexLitHtmlRenderer(address(0));
        vm.expectRevert(TalismanVertexLitHtmlRenderer.InvalidViewerScript.selector);
        new TalismanVertexLitHtmlRenderer(alice);
    }

    // --- validation ----------------------------------------------------------

    function test_urlValidation_rejectsBytesThatWouldBreakTheDocument() public {
        string[6] memory bad = [
            'https://x.test/"',
            "https://x.test/\\",
            "https://x.test/ a",
            string(abi.encodePacked("https://x.test/", bytes1(0x00))),
            string(abi.encodePacked("https://x.test/", bytes1(0x7F))),
            string(abi.encodePacked("https://x.test/", bytes1(0xC3), bytes1(0xA9)))
        ];
        for (uint256 i; i < bad.length; ++i) {
            TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
            cfg.urlPrefix = bad[i];
            vm.expectRevert(TalismanRendererV3.InvalidUrlComponent.selector);
            v3.setMetadataConfig(cfg);
        }
    }

    function test_urlValidation_rejectsAnOverLongComponent() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.urlSuffix = _repeat("a", 129);
        vm.expectRevert(TalismanRendererV3.InvalidUrlComponent.selector);
        v3.setMetadataConfig(cfg);

        cfg.urlSuffix = _repeat("a", 128);
        v3.setMetadataConfig(cfg); // the cap itself is allowed
    }

    function test_urlValidation_rejectsEnablingWithoutAPrefix() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.urlPrefix = "";
        vm.expectRevert(TalismanRendererV3.ExternalUrlEnabledWithoutPrefix.selector);
        v3.setMetadataConfig(cfg);

        cfg.externalUrlEnabled = false;
        v3.setMetadataConfig(cfg); // blank is fine once the link is off
    }

    function test_descriptionValidation_rejectsBytesThatWouldBreakTheDocument() public {
        string[6] memory bad = [
            'He said "no".',
            "A back\\slash.",
            "Line one\nline two.",
            "Tabbed\there.",
            string(abi.encodePacked("Curly", bytes1(0xE2), bytes1(0x80), bytes1(0x99), "s")),
            string(abi.encodePacked("Null", bytes1(0x00)))
        ];
        for (uint256 i; i < bad.length; ++i) {
            TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
            cfg.descriptionEnabled = true;
            cfg.description = bad[i];
            vm.expectRevert(TalismanRendererV3.InvalidDescription.selector);
            v3.setMetadataConfig(cfg);
        }
    }

    /// @dev Prose needs the space and ASCII punctuation a URL does not.
    function test_descriptionValidation_acceptsOrdinaryProse() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.descriptionEnabled = true;
        cfg.description = "A talisman - cut, bonded, or cleaved; it's one core's shape, at 100% on-chain.";
        v3.setMetadataConfig(cfg);
        assertTrue(_has(_json(_uriFor(1, false, 1)), "it's one core's shape"));
    }

    function test_descriptionValidation_rejectsAnOverLongString() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.description = _repeat("a", 513);
        vm.expectRevert(TalismanRendererV3.InvalidDescription.selector);
        v3.setMetadataConfig(cfg);

        cfg.description = _repeat("a", 512);
        v3.setMetadataConfig(cfg);
    }

    function test_descriptionValidation_rejectsEnablingWithNoText() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.descriptionEnabled = true;
        vm.expectRevert(TalismanRendererV3.DescriptionEnabledWithoutText.selector);
        v3.setMetadataConfig(cfg);
    }

    /// @dev The same rules apply at deploy time, so a bad argument cannot reach
    ///      a live address.
    function test_constructor_appliesTheSameValidation() public {
        TalismanRendererV3.MetadataConfig memory cfg = _defaultConfig();
        cfg.urlPrefix = 'https://x.test/"';
        // Read the sub-renderers first: `expectRevert` arms the very next call,
        // and a getter resolved inside the argument list would consume it.
        TalismanGeneratorV2 gen = v3.generator();
        TalismanSvgRendererV3 svg = v3.svgRenderer();
        TalismanLiteHtmlRenderer lite = v3.liteRenderer();
        TalismanVertexLitHtmlRenderer lit = v3.vertexLitRenderer();

        vm.expectRevert(TalismanRendererV3.InvalidUrlComponent.selector);
        new TalismanRendererV3(mats, gen, svg, lite, lit, ITalismanHost(address(nft)), cfg);
    }

    // --- live-token end to end -----------------------------------------------

    function test_tokenURI_throughTheTokenContractIsValidAndComplete() public {
        uint256 id = _lithic(alice, 1);
        string memory json = _json(nft.tokenURI(id));
        assertTrue(_isBalancedJson(json));
        assertTrue(_has(json, string.concat('"name":"Talisman #', LibString.toString(id), '"')));
        assertTrue(_has(json, string.concat('"external_url":"', URL_PREFIX, LibString.toString(id), '"')));
        assertTrue(_has(json, '"background_color":"000000"'));
        assertTrue(_has(json, _facet("Lithic Kind", _expectedKind(id))));
        assertTrue(_has(json, _facet("Lithic Core I", _expectedCore(id, 0))));
        assertTrue(_has(json, '{"trait_type":"Cores","value":"1"}'));
    }

    function test_tokenURI_isStableAcrossCalls() public {
        uint256 id = _lithic(alice, 1);
        assertEq(nft.tokenURI(id), nft.tokenURI(id));
    }

    // --- helpers -------------------------------------------------------------

    /// @dev Mint to `to` and reveal until the token lands on exactly `want` cores
    ///      of the requested pole. Discards stay owned by `to` and are inert.
    function _reveal(address to, bool wantLithic, uint256 want) internal returns (uint256 id) {
        for (uint256 attempt; attempt < 4096; ++attempt) {
            uint256 commitBlock;
            (id, commitBlock) = nft.mintWithCommitment(to);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("v3", to, wantLithic, want, attempt)))));
            nft.reveal(id);
            if (nft.coreCount(id) != want) {
                continue;
            }
            (TalismanMaterials.Essence essence,) = mats.elementOf(TalismanCore.materialId(nft.coresOf(id)[0]));
            if ((essence == TalismanMaterials.Essence.Lithic) == wantLithic) {
                return id;
            }
        }
        revert("could not produce desired (pole, core count)");
    }

    function _lithic(address to, uint256 cores) internal returns (uint256) {
        return _reveal(to, true, cores);
    }

    function _lumic(address to, uint256 cores) internal returns (uint256) {
        return _reveal(to, false, cores);
    }

    /// @dev Two single-core tokens that share a kind, so the pair is genuinely
    ///      mergeable. Chasing a *specific* kind costs more mints than the
    ///      genesis supply holds - a material and form both have to land - so
    ///      this waits for any collision among what it draws instead, which
    ///      arrives within a few dozen reveals.
    function _twoOfAKind(address to) internal returns (uint256, uint256) {
        uint256 cap = 400;
        uint256[] memory ids = new uint256[](cap);
        uint8[] memory midOf = new uint8[](cap);
        uint8[] memory formOf = new uint8[](cap);
        uint256 n;

        for (uint256 attempt; attempt < cap; ++attempt) {
            (uint256 id, uint256 commitBlock) = nft.mintWithCommitment(to);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("pair", to, attempt)))));
            nft.reveal(id);
            if (nft.coreCount(id) != 1) {
                continue;
            }
            uint8 mid = nft.coreMaterialId(id);
            uint8 form = uint8(nft.coreShapeForm(id));
            for (uint256 i; i < n; ++i) {
                if (midOf[i] == mid && formOf[i] == form) {
                    return (ids[i], id);
                }
            }
            ids[n] = id;
            midOf[n] = mid;
            formOf[n] = form;
            ++n;
        }
        revert("could not draw two talismans of one kind");
    }

    function _kinds(uint256 tokenId) internal view returns (string[] memory) {
        return v3.mergeKindsOf(
            tokenId, nft.coreMaterialId(tokenId), nft.coreShapeForm(tokenId), uint8(nft.coreCount(tokenId))
        );
    }

    function _expectedKind(uint256 tokenId) internal view returns (string memory) {
        return
            string.concat(
                mats.getMaterial(nft.coreMaterialId(tokenId)).name, " ", _formName(nft.coreShapeForm(tokenId))
            );
    }

    /// @dev Mirrors the renderer's form-name override so the expectation is not
    ///      written against the raw enum name the renderer no longer emits.
    function _formName(TalismanForms.ShapeForm form) internal pure returns (string memory) {
        if (form == TalismanForms.ShapeForm.Rock) {
            return "Boulder";
        }
        return TalismanForms.shapeFormName(form);
    }

    /// @dev The value a given core is expected to render as: its own seed as
    ///      `0x` and four lowercase hex digits, and nothing else.
    function _expectedCore(uint256 tokenId, uint256 index) internal view returns (string memory) {
        uint256 core = nft.coresOf(tokenId)[index];
        return LibString.toHexString(uint256(TalismanCore.seed(core)), 2);
    }

    function _facet(string memory key, string memory value) internal pure returns (string memory) {
        return string.concat('{"trait_type":"', key, '","value":"', value, '"}');
    }

    /// @dev Scan every `"trait_type":"..."` in the document and fail if any name
    ///      appears twice. Bytes-level, so it needs no JSON parser.
    function _assertNoRepeatedTraitType(string memory json) internal pure {
        string[] memory seen = new string[](64);
        uint256 n;
        bytes memory hay = bytes(json);
        bytes memory needle = bytes('"trait_type":"');

        for (uint256 i; i + needle.length < hay.length; ++i) {
            bool hit = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (!hit) {
                continue;
            }
            uint256 start = i + needle.length;
            uint256 end = start;
            while (end < hay.length && hay[end] != '"') {
                ++end;
            }
            bytes memory key = new bytes(end - start);
            for (uint256 k; k < key.length; ++k) {
                key[k] = hay[start + k];
            }
            string memory name = string(key);
            for (uint256 k; k < n; ++k) {
                assertFalse(_eqStr(seen[k], name), string.concat("repeated trait_type: ", name));
            }
            seen[n++] = name;
        }
        assertGt(n, 0, "no traits found");
    }

    function _eqStr(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev Byte offset of `needle` in `hay`, or `type(uint256).max` when absent.
    function _indexOf(string memory hay, string memory needle) internal pure returns (uint256) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) {
            return type(uint256).max;
        }
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool hit = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) {
                return i;
            }
        }
        return type(uint256).max;
    }

    /// @dev A tokenURI for a synthetic (essence, core count) pair - the direct way
    ///      to reach Mythic counts the mint path cannot produce on demand.
    function _uriFor(uint256 tokenId, bool mythic, uint8 cores) internal view returns (string memory) {
        uint8 mid = mythic ? _aMythicMaterial() : CLEAN_MID;
        return v3.tokenURIFromTraits(tokenId, mid, CLEAN_FORM, cores, CLEAN_SEED, true);
    }

    function _aMythicMaterial() internal view returns (uint8) {
        for (uint8 id = 32; id < 48; ++id) {
            if (mats.getMaterial(id).essence == TalismanMaterials.Essence.Mythic) {
                return id;
            }
        }
        revert("no Mythic material");
    }

    function _differentMaterialFrom(uint8 mid) internal pure returns (uint8) {
        return mid == 0 ? 1 : 0;
    }

    function _coresOf(string memory uri) internal pure returns (string memory) {
        return _field(_json(uri), '"trait_type":"Cores","value":"');
    }

    function _json(string memory uri) internal pure returns (string memory) {
        string memory prefix = "data:application/json;base64,";
        return string(Base64.decode(LibString.slice(uri, bytes(prefix).length)));
    }

    /// @dev The decoded `image` document of a metadata JSON.
    function _image(string memory json) internal pure returns (string memory) {
        string memory prefix = "data:image/svg+xml;base64,";
        return string(Base64.decode(LibString.slice(_field(json, '"image":"'), bytes(prefix).length)));
    }

    /// @dev The decoded `animation_url` document of a metadata JSON.
    function _animation(string memory json) internal pure returns (string memory) {
        string memory prefix = "data:text/html;base64,";
        return string(Base64.decode(LibString.slice(_field(json, '"animation_url":"'), bytes(prefix).length)));
    }

    /// @dev The text between `needle` and the next `"`.
    function _field(string memory haystack, string memory needle) internal pure returns (string memory) {
        uint256 at = LibString.indexOf(haystack, needle);
        require(at != LibString.NOT_FOUND, "field not found");
        uint256 from = at + bytes(needle).length;
        uint256 end = LibString.indexOf(haystack, '"', from);
        return LibString.slice(haystack, from, end);
    }

    function _has(string memory haystack, string memory needle) internal pure returns (bool) {
        return LibString.indexOf(haystack, needle) != LibString.NOT_FOUND;
    }

    function _count(string memory haystack, string memory needle) internal pure returns (uint256 n) {
        uint256 from;
        while (true) {
            uint256 at = LibString.indexOf(haystack, needle, from);
            if (at == LibString.NOT_FOUND) {
                return n;
            }
            ++n;
            from = at + bytes(needle).length;
        }
    }

    function _repeat(string memory unit, uint256 times) internal pure returns (string memory out) {
        for (uint256 i; i < times; ++i) {
            out = string.concat(out, unit);
        }
    }

    /// @dev A cheap structural check: braces and brackets balance and quotes come
    ///      in pairs. Enough to catch the comma and quoting mistakes a hand-built
    ///      document is prone to, without a JSON parser on-chain.
    function _isBalancedJson(string memory json) internal pure returns (bool) {
        bytes memory b = bytes(json);
        int256 braces;
        int256 brackets;
        uint256 quotes;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == "{") {
                ++braces;
            } else if (c == "}") {
                --braces;
            } else if (c == "[") {
                ++brackets;
            } else if (c == "]") {
                --brackets;
            } else if (c == '"') {
                ++quotes;
            }
            if (braces < 0 || brackets < 0) {
                return false;
            }
        }
        return braces == 0 && brackets == 0 && quotes % 2 == 0;
    }
}
