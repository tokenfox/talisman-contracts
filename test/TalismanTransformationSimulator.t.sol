// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Talismans} from "../src/Talismans.sol";
import {TokenState} from "../src/ITalismanTransformationSimulator.sol";
import {
    TalismanTransformationSimulator,
    ITalismansTransformationView
} from "../src/TalismanTransformationSimulator.sol";
import {TalismanCore} from "../src/TalismanCore.sol";
import {TalismanMaterials} from "../src/TalismanMaterials.sol";
import {TalismanMetadataRenderer} from "../src/TalismanMetadataRenderer.sol";
import {TalismanGenerator} from "../src/TalismanGenerator.sol";
import {TalismanSvgRenderer} from "../src/TalismanSvgRenderer.sol";
import {TalismanLiteHtmlRenderer} from "../src/TalismanLiteHtmlRenderer.sol";
import {
    CannotBondSameToken,
    TokenNotCleavable,
    InvalidCutIndex,
    MergeRequiresSameKind
} from "../src/TalismanErrors.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @title Transformation simulator spec
/// @notice Documents the standalone-preview design: the four `simulate*` entry
///         points live on the {TalismanTransformationSimulator} module, which
///         holds a read-only pointer to {Talismans} and runs the SAME
///         {TalismanTransformationLib} algebra the mutating ops run. The keystone is
///         {test_previewMatchesExecution_forAllFourOps}: it proves the preview
///         and the real mutation can never drift.
contract TalismanTransformationSimulatorTest is Test {
    Talismans internal nft;
    TalismanMaterials internal mats;
    TalismanMetadataRenderer internal renderer;
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
        nft.setTransformationSettings(true, true);
        vm.roll(100);
        vm.prevrandao(bytes32(uint256(0xc0ffee)));
    }

    // ─── crafting helpers ─────────────────────────────────────────────────────

    function _reveal(address to, bool wantLithic, uint256 want) internal returns (uint256 id) {
        for (uint256 attempt; attempt < 4096; ++attempt) {
            uint256 commitBlock;
            (id, commitBlock) = nft.mintWithCommitment(to);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("sim", to, wantLithic, want, attempt)))));
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

    function _revealOfMaterial(address to, uint8 material, uint256 want) internal returns (uint256 id) {
        for (uint256 attempt; attempt < 8192; ++attempt) {
            uint256 commitBlock;
            (id, commitBlock) = nft.mintWithCommitment(to);
            vm.roll(commitBlock + 1);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("simMat", to, material, want, attempt)))));
            nft.reveal(id);
            if (nft.coreCount(id) == want && nft.coreMaterialId(id) == material) {
                return id;
            }
        }
        revert("could not produce desired (material, core count)");
    }

    function _assertCoresEq(uint256[] memory got, uint256[] memory want) internal pure {
        assertEq(got.length, want.length, "core length mismatch");
        for (uint256 i; i < want.length; ++i) {
            assertEq(got[i], want[i], "core mismatch");
        }
    }

    // ─── rendering ────────────────────────────────────────────────────────────

    function test_simulate_rendersResultingToken() public {
        uint256 a = _reveal(alice, true, 1);
        uint256 b = _reveal(alice, false, 1);
        TokenState memory sim = simulator.simulateBond(a, b);
        assertTrue(LibString.contains(sim.image, "<svg"), "simulate must render");
        assertEq(sim.coreCount, 2);
    }

    function test_independentSimulators_produceIdenticalPreview() public {
        uint256 a = _reveal(alice, true, 1);
        uint256 b = _reveal(alice, false, 1);

        // A second, freshly deployed simulator pointed at the same NFT must
        // produce the identical preview — the preview is a pure function of NFT
        // state and the shared library, not of the simulator instance.
        TalismanTransformationSimulator second =
            new TalismanTransformationSimulator(ITalismansTransformationView(address(nft)));
        TokenState memory first = simulator.simulateBond(a, b);
        TokenState memory other = second.simulateBond(a, b);

        assertEq(other.tokenId, first.tokenId);
        assertEq(other.materialId, first.materialId);
        assertEq(other.seed, first.seed);
        _assertCoresEq(other.cores, first.cores);
    }

    // ─── THE drift guard ──────────────────────────────────────────────────────

    /// @notice For each op, capture the simulator's preview, execute the real op,
    ///         then assert the predicted id(s), cores, materialId, form,
    ///         coreCount, and seed exactly match the resulting on-chain token(s).
    function test_previewMatchesExecution_forAllFourOps() public {
        // ── bond ──
        uint256 ba = _reveal(alice, true, 2);
        uint256 bb = _reveal(alice, false, 2);
        TokenState memory simBond = simulator.simulateBond(ba, bb);
        vm.prank(alice);
        uint256 bonded = nft.bond(ba, bb);
        _assertMatches(simBond, bonded);

        // ── cleave ── (cleave the bonded Mythic)
        (TokenState memory simLithic, TokenState memory simLumic) = simulator.simulateCleave(bonded);
        vm.prank(alice);
        (uint256 lithicId, uint256 lumicId) = nft.cleave(bonded);
        _assertMatches(simLithic, lithicId);
        _assertMatches(simLumic, lumicId);

        // ── cut ──
        uint256 cutTok = _reveal(alice, true, 3);
        (TokenState memory simHead, TokenState memory simTail) = simulator.simulateCut(cutTok, 1);
        vm.prank(alice);
        (uint256 headId, uint256 tailId) = nft.cut(cutTok, 1);
        _assertMatches(simHead, headId);
        _assertMatches(simTail, tailId);

        // ── merge ── (merge the head + tail back)
        TokenState memory simMerge = simulator.simulateMerge(headId, tailId);
        vm.prank(alice);
        uint256 mergedId = nft.merge(headId, tailId);
        _assertMatches(simMerge, mergedId);
    }

    function _assertMatches(TokenState memory sim, uint256 tokenId) internal view {
        assertEq(sim.tokenId, tokenId, "predicted id must match minted id");
        _assertCoresEq(sim.cores, nft.coresOf(tokenId));
        assertEq(sim.materialId, nft.coreMaterialId(tokenId), "materialId drift");
        assertEq(uint8(sim.form), uint8(nft.coreShapeForm(tokenId)), "form drift");
        assertEq(sim.coreCount, uint8(nft.coreCount(tokenId)), "coreCount drift");
        assertEq(sim.seed, nft.coreSeed(tokenId), "seed drift");
    }

    // ─── identical reverts ────────────────────────────────────────────────────

    /// @notice Each `simulate*` must revert with the SAME error selector its
    ///         mutating op would, since both run the shared library.
    function test_simulate_revertsIdentically() public {
        // bond same token
        uint256 a = _reveal(alice, true, 1);
        vm.expectRevert(abi.encodeWithSelector(CannotBondSameToken.selector, a));
        simulator.simulateBond(a, a);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CannotBondSameToken.selector, a));
        nft.bond(a, a);

        // cleave a non-Mythic
        uint256 pure_ = _reveal(alice, true, 2);
        vm.expectRevert(abi.encodeWithSelector(TokenNotCleavable.selector, pure_));
        simulator.simulateCleave(pure_);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenNotCleavable.selector, pure_));
        nft.cleave(pure_);

        // cut at index 0
        uint256 cuttable = _reveal(alice, true, 2);
        vm.expectRevert(abi.encodeWithSelector(InvalidCutIndex.selector, uint256(0), uint256(2)));
        simulator.simulateCut(cuttable, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidCutIndex.selector, uint256(0), uint256(2)));
        nft.cut(cuttable, 0);

        // merge different material
        uint256 m0 = _revealOfMaterial(alice, 0, 1);
        uint256 m1 = _revealOfMaterial(alice, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(MergeRequiresSameKind.selector, m0, m1));
        simulator.simulateMerge(m0, m1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MergeRequiresSameKind.selector, m0, m1));
        nft.merge(m0, m1);
    }
}
