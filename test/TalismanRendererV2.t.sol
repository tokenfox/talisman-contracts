// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Talismans} from "../src/Talismans.sol";
import {Point2D} from "../src/TalismanStructs.sol";
import {TalismanForms} from "../src/TalismanForms.sol";
import {TalismanGenerator} from "../src/TalismanGenerator.sol";
import {TalismanGeneratorV2} from "../src/TalismanGeneratorV2.sol";
import {TalismanLiteHtmlRenderer} from "../src/TalismanLiteHtmlRenderer.sol";
import {TalismanMaterials} from "../src/TalismanMaterials.sol";
import {TalismanMetadataRenderer} from "../src/TalismanMetadataRenderer.sol";
import {TalismanRendererV2} from "../src/TalismanRendererV2.sol";
import {TalismanSvgRenderer} from "../src/TalismanSvgRenderer.sol";
import {TalismanSvgRendererV2} from "../src/TalismanSvgRendererV2.sol";
import {TalismanTransformationLib} from "../src/TalismanTransformationLib.sol";

/// @dev Exposes the V2 renderer's internal viewport mapping so the precision
///      claim can be tested directly instead of through parsed SVG text.
contract SvgV2Probe is TalismanSvgRendererV2 {
    function projectTenths(int256 px, int256 py) external pure returns (int256 x, int256 y) {
        return _projectOnSvg(Point2D({x: px, y: py}));
    }

    function tenthsToString(int256 v) external pure returns (string memory) {
        return _tenthsToString(v);
    }
}

/// @notice Output parity between the deployed V1 renderer stack and
///         {TalismanRendererV2}: byte-identical everywhere except the three
///         sanctioned fixes - the black page background in `animation_url`,
///         the re-wound faces of previously-broken meshes, and one-decimal
///         SVG coordinates.
contract TalismanRendererV2Test is Test {
    string internal constant BG_NEEDLE = "html,body{margin:0";
    string internal constant BG_INJECTED = "html,body{background:#000;margin:0";

    /// @dev V1's whole-unit viewport divisor: WAD / (512 / 2).
    int256 internal constant V1_STEP = 1e18 / 256;

    TalismanMaterials internal mats;
    TalismanMetadataRenderer internal r1;
    TalismanRendererV2 internal r2;
    SvgV2Probe internal probe;

    // A stable trait tuple: Brilliant never flips under either generator, so
    // every V1/V2 delta on it comes from the shading fixes alone.
    uint8 internal constant CLEAN_MID = 5;
    TalismanForms.ShapeForm internal constant CLEAN_FORM = TalismanForms.ShapeForm.Brilliant;
    uint8 internal constant CLEAN_CORES = 1;
    uint16 internal constant CLEAN_SEED = 0x1234;

    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    function setUp() public {
        mats = new TalismanMaterials();
        TalismanLiteHtmlRenderer lite = new TalismanLiteHtmlRenderer();
        r1 = new TalismanMetadataRenderer(mats, new TalismanGenerator(), new TalismanSvgRenderer(), lite);
        r2 = new TalismanRendererV2(mats, new TalismanGeneratorV2(), new TalismanSvgRendererV2(), lite);
        probe = new SvgV2Probe();
    }

    // ─── Pre-reveal ─────────────────────────────────────────────────────────

    function test_unrevealedURI_byteIdenticalToV1() public view {
        assertEq(r2.unrevealedURI(1), r1.unrevealedURI(1));
        assertEq(r2.unrevealedURI(999), r1.unrevealedURI(999));
    }

    // ─── §2.2 background fix ────────────────────────────────────────────────

    function test_html_onlyDifferenceIsBlackPageBackground() public view {
        string memory html1 = r1.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        string memory html2 = r2.htmlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);

        // The head CSS rule the injection widens occurs exactly once in V1
        // output, so the replace is surgical.
        uint256 first = LibString.indexOf(html1, BG_NEEDLE, 0);
        assertTrue(first != LibString.NOT_FOUND, "V1 head CSS rule missing");
        assertEq(LibString.indexOf(html1, BG_NEEDLE, first + 1), LibString.NOT_FOUND, "needle not unique in V1 html");

        assertTrue(LibString.contains(html2, BG_INJECTED), "page background not declared black");
        assertEq(html2, LibString.replace(html1, BG_NEEDLE, BG_INJECTED), "html differs beyond the background fix");
    }

    // ─── §2.7 coordinate precision ──────────────────────────────────────────

    /// @notice The tenths mapping never drifts more than one whole unit from
    ///         V1's - it resolves the same projection more finely, it does not
    ///         move the geometry.
    function test_projection_tenthsStayWithinOneUnitOfV1() public view {
        int256[9] memory samples = [int256(0), 1e17, -1e17, 5e17, -5e17, 999e15, -999e15, 3e18, -3e18];
        for (uint256 i = 0; i < samples.length; i++) {
            for (uint256 j = 0; j < samples.length; j++) {
                (int256 x10, int256 y10) = probe.projectTenths(samples[i], samples[j]);
                int256 v1x = 256 + samples[i] / V1_STEP;
                int256 v1y = 256 - samples[j] / V1_STEP;
                assertLt(_abs(x10 - v1x * 10), 10, "x drifted a whole unit from V1");
                assertLt(_abs(y10 - v1y * 10), 10, "y drifted a whole unit from V1");
            }
        }
    }

    /// @notice A tenths value is written as a fixed one-decimal number, with the
    ///         sign carried by the whole part only.
    function test_tenthsToString_formatsSignAndFraction() public view {
        assertEq(probe.tenthsToString(2851), "285.1");
        assertEq(probe.tenthsToString(2560), "256.0");
        assertEq(probe.tenthsToString(0), "0.0");
        assertEq(probe.tenthsToString(-37), "-3.7");
        assertEq(probe.tenthsToString(-5), "-0.5");
    }

    function test_svg_everyCoordinateCarriesOneDecimal() public view {
        string memory svg = r2.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        (, int256[] memory coords, uint256 polys) = _parseSvg(svg, true);
        assertGt(polys, 0, "no polygons rendered");
        assertEq(coords.length, polys * 6, "each polygon carries three points");
    }

    /// @notice The image keeps V1's faces, order, and colours - the seam fix was
    ///         outscoped, so solid polygons carry no stroke - and differs only in
    ///         that each coordinate is resolved to a tenth.
    function test_svg_matchesV1ExceptFinerCoordinates() public view {
        string memory svg1 = r1.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        string memory svg2 = r2.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        _assertSvgIsV1AtTenthPrecision(svg1, svg2);
    }

    function test_svg_solidPolygonsCarryNoStroke() public view {
        string memory svg = r2.imageFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertFalse(LibString.contains(svg, "stroke"), "solid polygons must not be stroked");
        assertTrue(LibString.contains(svg, 'fill="#000000"/>'), "background rect changed");
    }

    // ─── tokenURI: everything else byte-identical ───────────────────────────

    function test_tokenURI_differsOnlyBySanctionedFixes() public view {
        string memory json1 = _jsonOf(r1.tokenURIFromTraits(42, CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED, true));
        string memory json2 = _jsonOf(r2.tokenURIFromTraits(42, CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED, true));

        // Attributes (and everything after them) byte-identical.
        uint256 attrs1 = LibString.indexOf(json1, '"attributes":', 0);
        uint256 attrs2 = LibString.indexOf(json2, '"attributes":', 0);
        assertEq(
            LibString.slice(json2, attrs2, bytes(json2).length),
            LibString.slice(json1, attrs1, bytes(json1).length),
            "attributes changed"
        );

        // Name prefix byte-identical.
        assertEq(
            LibString.slice(json2, 0, LibString.indexOf(json2, '"image":', 0)),
            LibString.slice(json1, 0, LibString.indexOf(json1, '"image":', 0)),
            "name segment changed"
        );

        // Embedded viewer is V1's plus the background declaration; embedded
        // image is V1's at tenth-unit coordinates.
        assertEq(
            _extractB64(json2, '"animation_url":"data:text/html;base64,'),
            string(
                Base64.encode(
                    bytes(
                        LibString.replace(
                            string(Base64.decode(_extractB64(json1, '"animation_url":"data:text/html;base64,'))),
                            BG_NEEDLE,
                            BG_INJECTED
                        )
                    )
                )
            ),
            "embedded viewer differs beyond the background fix"
        );
        _assertSvgIsV1AtTenthPrecision(
            string(Base64.decode(_extractB64(json1, '"image":"data:image/svg+xml;base64,'))),
            string(Base64.decode(_extractB64(json2, '"image":"data:image/svg+xml;base64,')))
        );
    }

    function test_tokenURI_emitsValidJson() public view {
        string memory json = _jsonOf(r2.tokenURIFromTraits(7, CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED, false));
        vm.parseJson(json); // reverts on malformed JSON
        assertEq(vm.parseJsonString(json, ".name"), "Talisman #7");
        assertTrue(LibString.startsWith(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,"));
        assertTrue(LibString.startsWith(vm.parseJsonString(json, ".animation_url"), "data:text/html;base64,"));
    }

    // ─── §2.6 mesh fix, end to end on reported token #1496 ──────────────────

    function test_affectedToken1496_stillGainsItsMissingFace() public view {
        (uint8 mid, TalismanForms.ShapeForm form, uint8 cores, uint16 seed) = _traits1496();

        string memory svg1 = r1.imageFromTraits(mid, form, cores, seed);
        string memory svg2 = r2.imageFromTraits(mid, form, cores, seed);

        // The face V1 wound inside-out was culled while front-facing; V2 renders
        // it, in the lit colour pinned by the collection scan.
        assertEq(_countPolygons(svg2), _countPolygons(svg1) + 1, "exactly one previously-culled face appears");
        assertFalse(LibString.contains(svg1, "#9D7C92"), "V1 unexpectedly renders the face");
        assertTrue(LibString.contains(svg2, 'fill="#9D7C92"'), "V2 must render the re-wound face");
    }

    function test_affectedToken1496_stlDiffersInExactlyOneFacet() public view {
        (uint8 mid, TalismanForms.ShapeForm form, uint8 cores, uint16 seed) = _traits1496();
        bytes memory stl1 = r1.stlFromTraits(mid, form, cores, seed);
        bytes memory stl2 = r2.stlFromTraits(mid, form, cores, seed);

        assertEq(stl2.length, stl1.length, "stl length must not change");
        // Binary STL: 80-byte header + uint32 count + 50-byte facets.
        assertEq(keccak256(_sliceBytes(stl2, 0, 84)), keccak256(_sliceBytes(stl1, 0, 84)), "header changed");
        uint256 facets = (stl1.length - 84) / 50;
        uint256 differing;
        for (uint256 i = 0; i < facets; i++) {
            uint256 off = 84 + i * 50;
            if (keccak256(_sliceBytes(stl1, off, off + 50)) != keccak256(_sliceBytes(stl2, off, off + 50))) {
                differing++;
            }
        }
        assertEq(differing, 1, "exactly the flipped facet re-winds");
    }

    /// @notice STL is a model-space mesh, so the SVG-only precision fix must not
    ///         reach it: a correctly-wound mesh exports byte-identically.
    function test_stl_byteIdenticalForCleanMesh() public view {
        bytes memory stl1 = r1.stlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        bytes memory stl2 = r2.stlFromTraits(CLEAN_MID, CLEAN_FORM, CLEAN_CORES, CLEAN_SEED);
        assertEq(keccak256(stl2), keccak256(stl1), "clean stl must be byte-identical");
    }

    // ─── Rollout: the one-call renderer swap ────────────────────────────────

    function test_setRenderer_swapsEveryTokenToV2Output() public {
        Talismans nft = new Talismans();
        nft.setMinter(address(this));
        nft.setMaterials(mats);
        nft.setRenderer(r1);

        (uint256 id, uint256 commitBlock) = nft.mintWithCommitment(address(0xA11CE));
        vm.roll(commitBlock + 1);
        nft.reveal(id);

        string memory uri1 = nft.tokenURI(id);

        vm.expectEmit();
        emit BatchMetadataUpdate(0, type(uint256).max);
        nft.setRenderer(r2);

        string memory uri2 = nft.tokenURI(id);
        assertTrue(keccak256(bytes(uri2)) != keccak256(bytes(uri1)), "swap must change tokenURI");
        assertEq(
            uri2,
            r2.tokenURIFromTraits(
                id,
                nft.coreMaterialId(id),
                nft.coreShapeForm(id),
                uint8(nft.coreCount(id)),
                nft.coreSeed(id),
                nft.isGenesis(id)
            ),
            "tokenURI must come verbatim from RendererV2"
        );
        // And the swapped output carries the sanctioned fixes.
        string memory json = _jsonOf(uri2);
        string memory html = string(Base64.decode(_extractB64(json, '"animation_url":"data:text/html;base64,')));
        assertTrue(LibString.contains(html, BG_INJECTED), "swapped viewer missing black background");
        _assertSvgIsV1AtTenthPrecision(
            string(Base64.decode(_extractB64(_jsonOf(uri1), '"image":"data:image/svg+xml;base64,'))),
            string(Base64.decode(_extractB64(json, '"image":"data:image/svg+xml;base64,')))
        );
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    /// @dev Asserts `svg2` is `svg1` re-emitted at tenth-unit precision: same
    ///      polygons in the same order with the same fills, every coordinate
    ///      within one whole unit of V1's, and at least one coordinate actually
    ///      carrying a non-zero fraction (so the finer grid is really in use).
    function _assertSvgIsV1AtTenthPrecision(string memory svg1, string memory svg2) internal pure {
        (bytes32 fills1, int256[] memory c1, uint256 n1) = _parseSvg(svg1, false);
        (bytes32 fills2, int256[] memory c2, uint256 n2) = _parseSvg(svg2, true);
        assertEq(n2, n1, "polygon count changed");
        assertEq(fills2, fills1, "fill sequence changed");
        assertEq(c2.length, c1.length, "coordinate count changed");

        bool sawFraction;
        for (uint256 i = 0; i < c1.length; i++) {
            assertLt(_abs(c2[i] - c1[i]), 10, "coordinate moved a whole unit");
            if (c2[i] % 10 != 0) {
                sawFraction = true;
            }
        }
        assertTrue(sawFraction, "no coordinate used the finer grid");
    }

    /// @dev Walks every `<polygon>` in an SVG, returning a hash of the fill
    ///      sequence, all coordinates scaled to tenths, and the polygon count.
    ///      `decimal` selects the coordinate grammar: V2 writes `285.1`, V1
    ///      writes `285` (scaled to tenths here so the two compare directly).
    function _parseSvg(string memory svg, bool decimal)
        internal
        pure
        returns (bytes32 fillsHash, int256[] memory coords, uint256 polygons)
    {
        bytes memory b = bytes(svg);
        int256[] memory buf = new int256[](_countPolygons(svg) * 6);
        bytes memory fills;
        uint256 w;
        uint256 pos;
        while (true) {
            uint256 p = LibString.indexOf(svg, '<polygon points="', pos);
            if (p == LibString.NOT_FOUND) {
                break;
            }
            uint256 start = p + bytes('<polygon points="').length;
            uint256 end = LibString.indexOf(svg, '"', start);

            uint256 tok = start;
            for (uint256 i = start; i <= end; i++) {
                if (i == end || b[i] == "," || b[i] == " ") {
                    buf[w] = _parseTenths(b, tok, i, decimal);
                    w++;
                    tok = i + 1;
                }
            }

            uint256 f = LibString.indexOf(svg, 'fill="#', end);
            fills = bytes.concat(fills, bytes(LibString.slice(svg, f + 7, f + 13)));
            polygons++;
            pos = end;
        }
        assertEq(w, buf.length, "polygon did not carry three points");
        fillsHash = keccak256(fills);
        coords = buf;
    }

    /// @dev Parses one coordinate token into tenths. Whole-unit (V1) tokens are
    ///      multiplied up; decimal (V2) tokens keep their fractional digit.
    function _parseTenths(bytes memory b, uint256 start, uint256 end, bool decimal) internal pure returns (int256) {
        bool neg;
        uint256 i = start;
        if (b[i] == "-") {
            neg = true;
            i++;
        }
        int256 whole;
        int256 frac;
        bool afterDot;
        for (; i < end; i++) {
            if (b[i] == ".") {
                afterDot = true;
                continue;
            }
            int256 d = int256(uint256(uint8(b[i]))) - 48;
            if (afterDot) {
                frac = d;
            } else {
                whole = whole * 10 + d;
            }
        }
        assertEq(afterDot, decimal, "unexpected coordinate grammar");
        int256 v = whole * 10 + frac;
        return neg ? -v : v;
    }

    /// @dev Derived traits of mainnet token #1496 from its actual core.
    function _traits1496() internal view returns (uint8 mid, TalismanForms.ShapeForm form, uint8 cores, uint16 seed) {
        uint256[] memory coreArr = new uint256[](1);
        coreArr[0] = 32218975;
        mid = TalismanTransformationLib.deriveMaterialId(mats, coreArr);
        form = TalismanTransformationLib.deriveShapeForm(coreArr);
        seed = TalismanTransformationLib.deriveSeed(coreArr);
        cores = 1;
    }

    function _jsonOf(string memory uri) internal pure returns (string memory) {
        return
            string(
                Base64.decode(LibString.slice(uri, bytes("data:application/json;base64,").length, bytes(uri).length))
            );
    }

    function _extractB64(string memory json, string memory fieldPrefix) internal pure returns (string memory) {
        uint256 start = LibString.indexOf(json, fieldPrefix, 0);
        require(start != LibString.NOT_FOUND, "field missing");
        start += bytes(fieldPrefix).length;
        uint256 end = LibString.indexOf(json, '"', start);
        return LibString.slice(json, start, end);
    }

    function _countPolygons(string memory svg) internal pure returns (uint256 n) {
        uint256 pos;
        while (true) {
            uint256 p = LibString.indexOf(svg, "<polygon", pos);
            if (p == LibString.NOT_FOUND) {
                return n;
            }
            n++;
            pos = p + 8;
        }
    }

    function _sliceBytes(bytes memory data, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = data[i];
        }
    }

    function _abs(int256 v) internal pure returns (int256) {
        return v < 0 ? -v : v;
    }
}
