// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Talismans} from "../src/Talismans.sol";
import {TokenState} from "../src/ITalismanTransformationSimulator.sol";
import {
    TalismanTransformationSimulator,
    ITalismansTransformationView
} from "../src/TalismanTransformationSimulator.sol";
import {
    BondRequiresMatchedCores,
    BondRequiresOppositePoles,
    BondTokenNotRevealed,
    CannotBondSameToken,
    TokenNotCleavable
} from "../src/TalismanErrors.sol";
import {TalismanCore} from "../src/TalismanCore.sol";
import {TalismanMetadataRenderer} from "../src/TalismanMetadataRenderer.sol";
import {TalismanMaterials} from "../src/TalismanMaterials.sol";
import {TalismanGenerator} from "../src/TalismanGenerator.sol";
import {TalismanSvgRenderer} from "../src/TalismanSvgRenderer.sol";
import {TalismanLiteHtmlRenderer} from "../src/TalismanLiteHtmlRenderer.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice End-to-end coverage for the default renderer: hook it into
///         Talismans, mint, and assert the metadata URI is shaped correctly.
contract TalismanMetadataRendererTest is Test {
    Talismans internal nft;
    TalismanMetadataRenderer internal renderer;
    TalismanMaterials internal mats;
    TalismanTransformationSimulator internal simulator;

    address internal alice = address(0xA11CE);

    function setUp() public {
        nft = new Talismans();
        nft.setMinter(address(this));
        mats = new TalismanMaterials();
        nft.setMaterials(mats);
        renderer = new TalismanMetadataRenderer(
            mats, new TalismanGenerator(), new TalismanSvgRenderer(), new TalismanLiteHtmlRenderer()
        );
        nft.setRenderer(renderer);
        simulator = new TalismanTransformationSimulator(ITalismansTransformationView(address(nft)));
    }

    function test_tokenURI_unrevealed_emitsPlaceholderSvgOnly() public {
        (uint256 id,) = nft.mintWithCommitment(alice);

        string memory uri = nft.tokenURI(id);
        assertTrue(LibString.startsWith(uri, "data:application/json;base64,"), "wrong scheme");

        string memory json = string(Base64.decode(LibString.slice(uri, bytes("data:application/json;base64,").length)));
        assertTrue(LibString.contains(json, '"name":"Talisman #1"'));
        assertTrue(LibString.contains(json, '"image":"data:image/svg+xml;base64,'), "missing placeholder svg");
        assertFalse(LibString.contains(json, '"animation_url"'), "no animation_url pre-reveal");
        assertFalse(LibString.contains(json, '"attributes"'), "no traits pre-reveal");

        // Decode the embedded SVG and pin the load-bearing tags: black bg + the
        // logo path + the stroke-colour animation.
        uint256 imgPrefix = bytes('"image":"data:image/svg+xml;base64,').length;
        uint256 imgStart = _indexOf(json, '"image":"data:image/svg+xml;base64,') + imgPrefix;
        uint256 imgEnd = _indexOfFrom(json, '"', imgStart);
        string memory svgB64 = LibString.slice(json, imgStart, imgEnd);
        string memory svg = string(Base64.decode(svgB64));
        assertTrue(LibString.contains(svg, "<rect width='100%' height='100%' fill='#000'/>"), "no black bg");
        assertTrue(LibString.contains(svg, "<animate attributeName='stroke'"), "no pulsating animation");
    }

    function _indexOf(string memory hay, string memory needle) internal pure returns (uint256) {
        return LibString.indexOf(hay, needle, 0);
    }

    function _indexOfFrom(string memory hay, string memory needle, uint256 from) internal pure returns (uint256) {
        return LibString.indexOf(hay, needle, from);
    }

    function test_tokenURI_revealed_returnsFullMetadata() public {
        (uint256 id, uint256 commitBlock) = nft.mintWithCommitment(alice);
        vm.roll(commitBlock + 1);
        nft.reveal(id);

        string memory uri = nft.tokenURI(id);
        string memory json = string(Base64.decode(LibString.slice(uri, bytes("data:application/json;base64,").length)));

        assertTrue(LibString.contains(json, '"name":"Talisman #1"'));
        assertTrue(LibString.contains(json, '"image":"data:image/svg+xml;base64,'));
        assertTrue(LibString.contains(json, '"animation_url":"data:text/html;base64,'));
        assertTrue(LibString.contains(json, '"attributes":['));
        assertTrue(LibString.contains(json, '"trait_type":"Material"'));
        assertTrue(LibString.contains(json, '"trait_type":"Cores"'));
        // Token #1 is in the genesis range — Genesis trait is the bare boolean true.
        assertTrue(LibString.contains(json, '{"trait_type":"Genesis","value":true}'), "missing Genesis=true trait");
        assertFalse(LibString.contains(json, '"trait_type":"Stored Cores"'));
        assertFalse(LibString.contains(json, '"trait_type":"Color"'));
        assertFalse(LibString.contains(json, '"trait_type":"Facets"'));
    }

    function test_tokenURI_revertsForNonexistent() public {
        // Talismans guards existence first, so the ERC-721 error wins over
        // anything the renderer would have produced.
        vm.expectRevert();
        nft.tokenURI(123);
    }

    function test_tokenURI_idDistinguishesTokens() public {
        (uint256 a,) = nft.mintWithCommitment(alice);
        (uint256 b,) = nft.mintWithCommitment(alice);

        string memory uriA = nft.tokenURI(a);
        string memory uriB = nft.tokenURI(b);
        assertTrue(keccak256(bytes(uriA)) != keccak256(bytes(uriB)), "different tokens must yield different metadata");
    }

    /// @dev The renderer holds no reference back to Talismans: its placeholder
    ///      entry resolves for any id, including one Talismans never minted,
    ///      without reading token state.
    function test_directRendererCall_unrevealedURI_isStandalone() public view {
        string memory uri = renderer.unrevealedURI(999);
        string memory json = string(Base64.decode(LibString.slice(uri, bytes("data:application/json;base64,").length)));
        assertTrue(LibString.contains(json, '"name":"Talisman #999"'), "labels the requested id");
        assertTrue(LibString.contains(json, '"image":"data:image/svg+xml;base64,'), "missing placeholder svg");
    }

    // ─── Bond & cleave preview ──────────────────────────────────────────────

    /// @dev Mint+reveal repeatedly until the token lands on exactly `want` cores
    ///      AND the requested pole, so bond previews can be built deterministically
    ///      from one Lithic and one Lumic input.
    function _reveal(address to, bool wantLithic, uint256 want) internal returns (uint256 id) {
        for (uint256 attempt; attempt < 2048; ++attempt) {
            uint256 commitBlock;
            (id, commitBlock) = nft.mintWithCommitment(to);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("preview", to, wantLithic, want, attempt)))));
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

    /// @notice The bond preview's rendered art must match the real default
    ///         renderer's raw SVG/HTML for the post-bond cores. Confirms the
    ///         renderer's imageFromTraits/htmlFromTraits route through the same
    ///         generator pipeline as the live tokenURI path.
    function test_simulateBond_rendersRawSvgMatchingRenderer() public {
        nft.setTransformationSettings(true, false);
        uint256 keep = _reveal(alice, true, 2);
        uint256 merged = _reveal(alice, false, 2);

        TokenState memory preview = simulator.simulateBond(keep, merged);

        // Raw markup, not a data: URI. (Default renderer prefixes an XML decl,
        // so check `contains` rather than `startsWith`.)
        assertTrue(LibString.contains(preview.image, "<svg"), "image must be raw svg");
        assertFalse(LibString.startsWith(preview.image, "data:"), "image must not be a data uri");
        assertTrue(LibString.contains(preview.html, "<html"), "html must be raw html");
        assertFalse(LibString.startsWith(preview.html, "data:"), "html must not be a data uri");

        // The preview's image equals what the renderer produces for the derived
        // post-bond traits.
        string memory direct =
            renderer.imageFromTraits(preview.materialId, preview.form, preview.coreCount, preview.seed);
        assertEq(preview.image, direct, "preview image must match renderer output");
    }

    // ─── token surfaces (Talismans → renderer) ───────────────────────────────
    //
    // Each surface must forward the token's derived traits to the matching
    // renderer entry point and return its output verbatim.

    function test_tokenView_matchesRendererHtml() public {
        uint256 id = _reveal(alice, true, 2);
        string memory direct = renderer.htmlFromTraits(
            nft.coreMaterialId(id), nft.coreShapeForm(id), uint8(nft.coreCount(id)), nft.coreSeed(id)
        );

        string memory got = nft.tokenView(id);
        assertEq(got, direct, "tokenView must equal renderer html for derived traits");
        assertTrue(LibString.contains(got, "<html"), "tokenView must be raw html");
        assertFalse(LibString.startsWith(got, "data:"), "tokenView must not be a data uri");
    }

    function test_tokenImage_matchesRendererSvg() public {
        uint256 id = _reveal(alice, true, 2);
        string memory direct = renderer.imageFromTraits(
            nft.coreMaterialId(id), nft.coreShapeForm(id), uint8(nft.coreCount(id)), nft.coreSeed(id)
        );

        string memory got = nft.tokenImage(id);
        assertEq(got, direct, "tokenImage must equal renderer svg for derived traits");
        assertTrue(LibString.contains(got, "<svg"), "tokenImage must be raw svg");
        assertFalse(LibString.startsWith(got, "data:"), "tokenImage must not be a data uri");
    }

    function test_tokenShape_matchesRendererStlAndIsBinaryStl() public {
        uint256 id = _reveal(alice, true, 2);
        bytes memory direct = renderer.stlFromTraits(
            nft.coreMaterialId(id), nft.coreShapeForm(id), uint8(nft.coreCount(id)), nft.coreSeed(id)
        );

        bytes memory got = nft.tokenShape(id);
        assertEq(keccak256(got), keccak256(direct), "tokenShape must equal renderer stl for derived traits");

        // Binary STL layout: 80-byte header + uint32 facet count + 50 bytes/facet,
        // the VisCAM "COLOR=" marker leading the header so colour-aware viewers
        // read per-facet colours.
        assertGe(got.length, 84, "stl too short for header + facet count");
        assertEq((got.length - 84) % 50, 0, "stl body must be whole 50-byte facets");
        assertEq(got[0], bytes1("C"));
        assertEq(got[1], bytes1("O"));
        assertEq(got[2], bytes1("L"));
        assertEq(got[3], bytes1("O"));
        assertEq(got[4], bytes1("R"));
        assertEq(got[5], bytes1("="));

        // The little-endian facet count in the header matches the body length.
        uint32 facets = uint32(uint8(got[80])) | (uint32(uint8(got[81])) << 8) | (uint32(uint8(got[82])) << 16)
            | (uint32(uint8(got[83])) << 24);
        assertEq(uint256(facets) * 50 + 84, got.length, "header facet count must match body length");
    }

    function test_tokenData_matchesCoreGetters() public {
        uint256 id = _reveal(alice, true, 2);
        Talismans.TokenData memory data = nft.tokenData(id);

        assertEq(data.materialId, nft.coreMaterialId(id), "materialId");
        assertEq(uint8(data.form), uint8(nft.coreShapeForm(id)), "form");
        assertEq(data.coreCount, uint8(nft.coreCount(id)), "coreCount");
        assertEq(data.seed, nft.coreSeed(id), "seed");
        assertEq(data.coreCount, uint8(data.cores.length), "coreCount equals cores length");

        uint256[] memory cores = nft.coresOf(id);
        assertEq(data.cores.length, cores.length, "cores length");
        for (uint256 i; i < cores.length; ++i) {
            assertEq(data.cores[i], cores[i], "core element");
        }
    }

    /// @notice Anyone may preview — no ownership/approval needed, unlike bond.
    function test_simulateBond_callableByNonOwner() public {
        uint256 keep = _reveal(alice, true, 1);
        uint256 merged = _reveal(alice, false, 1);

        vm.prank(address(0xDEAD));
        TokenState memory preview = simulator.simulateBond(keep, merged);
        assertTrue(LibString.contains(preview.image, "<svg"), "preview must render");
    }

    function test_simulateBond_revertsOnSelfBond() public {
        uint256 id = _reveal(alice, true, 1);
        vm.expectRevert(abi.encodeWithSelector(CannotBondSameToken.selector, id));
        simulator.simulateBond(id, id);
    }

    function test_simulateBond_revertsWhenSamePole() public {
        uint256 keep = _reveal(alice, true, 1);
        uint256 merged = _reveal(alice, true, 1);
        vm.expectRevert(abi.encodeWithSelector(BondRequiresOppositePoles.selector, keep, merged));
        simulator.simulateBond(keep, merged);
    }

    function test_simulateBond_revertsWhenMismatchedCores() public {
        uint256 keep = _reveal(alice, true, 1);
        uint256 merged = _reveal(alice, false, 2);
        vm.expectRevert(abi.encodeWithSelector(BondRequiresMatchedCores.selector, uint256(1), uint256(2)));
        simulator.simulateBond(keep, merged);
    }

    function test_simulateBond_revertsWhenTokenUnrevealed() public {
        uint256 keep = _reveal(alice, true, 1);
        (uint256 merged,) = nft.mintWithCommitment(alice); // 0 cores
        vm.expectRevert(abi.encodeWithSelector(BondTokenNotRevealed.selector, merged));
        simulator.simulateBond(keep, merged);
    }

    function test_simulateBond_revertsForNonexistentToken() public {
        uint256 keep = _reveal(alice, true, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(99999)));
        simulator.simulateBond(keep, 99999);
    }

    /// @notice The cleave preview must report the original burned ids and render
    ///         the exact two halves the live cleave produces.
    function test_simulateCleave_reportsOriginalIdsAndRenders() public {
        nft.setTransformationSettings(true, false);
        uint256 keep = _reveal(alice, true, 2);
        uint256 merged = _reveal(alice, false, 2);
        vm.prank(alice);
        uint256 bonded = nft.bond(keep, merged);

        (TokenState memory lithic, TokenState memory lumic) = simulator.simulateCleave(bonded);
        assertEq(lithic.tokenId, keep, "preview reports the original lithic id");
        assertEq(lumic.tokenId, merged, "preview reports the original lumic id");
        assertTrue(LibString.contains(lithic.image, "<svg"));
        assertTrue(LibString.contains(lumic.image, "<svg"));
    }

    function test_simulateCleave_revertsWhenNotMythic() public {
        uint256 id = _reveal(alice, true, 2);
        vm.expectRevert(abi.encodeWithSelector(TokenNotCleavable.selector, id));
        simulator.simulateCleave(id);
    }
}
