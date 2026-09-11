// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Talismans} from "../src/Talismans.sol";
import {NotRevealed, RendererNotSet} from "../src/TalismanErrors.sol";
import {ITalismanRenderer} from "../src/ITalismanRenderer.sol";
import {TalismanMaterials} from "../src/TalismanMaterials.sol";
import {TalismanForms} from "../src/TalismanForms.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @dev Minimal renderer stub. Returns a deterministic string keyed on the
///      tokenId so tests can assert the call routed correctly without pulling
///      in the full SVG/HTML pipeline.
contract StubRenderer is ITalismanRenderer {
    string public prefix;

    constructor(string memory _prefix) {
        prefix = _prefix;
    }

    function unrevealedURI(uint256 tokenId) external view returns (string memory) {
        return string.concat(prefix, ":", _u(tokenId));
    }

    function tokenURIFromTraits(
        uint256 tokenId,
        uint8 materialId,
        TalismanForms.ShapeForm form,
        uint8 cores,
        uint16 seed,
        bool genesis
    ) external view returns (string memory) {
        return string.concat(
            prefix,
            ":",
            _u(tokenId),
            ":",
            _u(materialId),
            ":",
            _u(uint8(form)),
            ":",
            _u(cores),
            ":",
            _u(seed),
            ":",
            genesis ? "g" : "n"
        );
    }

    function imageFromTraits(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        external
        view
        returns (string memory)
    {
        return string.concat(
            "<svg ", prefix, ":", _u(materialId), ":", _u(uint8(form)), ":", _u(cores), ":", _u(seed), "</svg>"
        );
    }

    function htmlFromTraits(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        external
        view
        returns (string memory)
    {
        return string.concat(
            "<!DOCTYPE html><html ",
            prefix,
            ":",
            _u(materialId),
            ":",
            _u(uint8(form)),
            ":",
            _u(cores),
            ":",
            _u(seed),
            "</html>"
        );
    }

    function stlFromTraits(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        external
        view
        returns (bytes memory)
    {
        return bytes(
            string.concat("STL ", prefix, ":", _u(materialId), ":", _u(uint8(form)), ":", _u(cores), ":", _u(seed))
        );
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        uint256 t = v;
        while (t != 0) {
            len++;
            t /= 10;
        }
        bytes memory b = new bytes(len);
        uint256 idx = len;
        while (v != 0) {
            idx--;
            b[idx] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(b);
    }
}

/// @dev Renderer that always reverts. Used to confirm Talismans bubbles
///      renderer reverts unchanged.
contract RevertingRenderer is ITalismanRenderer {
    error RendererBlewUp();

    function unrevealedURI(uint256) external pure returns (string memory) {
        revert RendererBlewUp();
    }

    function tokenURIFromTraits(uint256, uint8, TalismanForms.ShapeForm, uint8, uint16, bool)
        external
        pure
        returns (string memory)
    {
        revert RendererBlewUp();
    }

    function imageFromTraits(uint8, TalismanForms.ShapeForm, uint8, uint16) external pure returns (string memory) {
        revert RendererBlewUp();
    }

    function htmlFromTraits(uint8, TalismanForms.ShapeForm, uint8, uint16) external pure returns (string memory) {
        revert RendererBlewUp();
    }

    function stlFromTraits(uint8, TalismanForms.ShapeForm, uint8, uint16) external pure returns (bytes memory) {
        revert RendererBlewUp();
    }
}

/// @dev Minimal ERC-721 safe-transfer receiver used to exercise mint-to-contract paths.
contract GoodReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Receiver that returns a wrong selector — safe-mint must revert.
contract BadReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

/// @dev Plain contract that does not implement {IERC721Receiver} — safe-mint must revert.
contract NonReceiver {}

contract TalismansTest is Test {
    Talismans internal nft;

    address internal deployer = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCAB01);

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event MinterUpdated(address indexed previousMinter, address indexed newMinter);

    function setUp() public {
        nft = new Talismans();
        // Route all mints through the test contract as the authorised minter.
        nft.setMinter(address(this));
    }

    /// @dev Test-controlled mint helper — uses the minter path that production
    ///      buyers go through via TalismanMinter.
    function _mint(address to) internal returns (uint256 tokenId) {
        (tokenId,) = nft.mintWithCommitment(to);
    }

    // ─── Construction ────────────────────────────────────────────────────────

    function test_constructor_metadata() public view {
        assertEq(nft.name(), "Talismans");
        assertEq(nft.symbol(), "TLSM");
    }

    function test_constructor_setsDeployerAsOwner() public view {
        assertEq(nft.owner(), deployer);
        assertEq(nft.pendingOwner(), address(0));
    }

    function test_constructor_startsEmpty() public view {
        assertEq(nft.totalSupply(), 0);
        assertEq(nft.genesisMinted(), 0);
        // Transform outputs start one past the genesis range.
        assertEq(nft.nextTransformId(), nft.MAX_GENESIS_SUPPLY() + 1);
    }

    function test_constructor_setsDefaultCoreRarityWeights() public view {
        // Default reveal weights: Raw 40 / Cut 30 / Fine 20 / Prime 10.
        uint256[] memory w = nft.coreRarityWeights();
        assertEq(w.length, 4);
        assertEq(w[0], 40);
        assertEq(w[1], 30);
        assertEq(w[2], 20);
        assertEq(w[3], 10);
    }

    function test_supportsInterface_erc165AndErc721() public view {
        assertTrue(nft.supportsInterface(type(IERC165).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC721).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC721Metadata).interfaceId));
        assertFalse(nft.supportsInterface(0xffffffff));
    }

    // ─── mintWithCommitment ──────────────────────────────────────────────────

    function test_mint_minterCanMint_toEOA() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, 1);

        uint256 id = _mint(alice);

        assertEq(id, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.totalSupply(), 1);
        assertEq(nft.genesisMinted(), 1);
    }

    function test_mint_assignsIdsSequentiallyStartingAtOne() public {
        uint256 a = _mint(alice);
        uint256 b = _mint(bob);
        uint256 c = _mint(carol);

        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(c, 3);
        assertEq(nft.totalSupply(), 3);
        assertEq(nft.genesisMinted(), 3);
    }

    function test_mint_toGoodReceiver() public {
        GoodReceiver rx = new GoodReceiver();
        uint256 id = _mint(address(rx));
        assertEq(nft.ownerOf(id), address(rx));
    }

    function test_mint_revertsOnBadReceiver() public {
        BadReceiver rx = new BadReceiver();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(rx)));
        _mint(address(rx));
    }

    function test_mint_revertsOnNonReceiverContract() public {
        NonReceiver rx = new NonReceiver();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(rx)));
        _mint(address(rx));
    }

    function test_mint_revertsForZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        _mint(address(0));
    }

    function test_mint_revertsForNonMinter() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Talismans.UnauthorizedMinter.selector, alice));
        nft.mintWithCommitment(alice);
    }

    function test_mint_failedMintDoesNotAdvanceCounter() public {
        BadReceiver rx = new BadReceiver();
        try this.tryMint(address(rx)) {
            fail();
        } catch {}

        uint256 id = _mint(alice);
        assertEq(id, 1);
        assertEq(nft.totalSupply(), 1);
    }

    /// @dev External wrapper so `try` can catch the revert across a call boundary.
    function tryMint(address to) external returns (uint256) {
        return _mint(to);
    }

    function test_mint_assignsCommitBlockAndCountsGenesis() public {
        uint256 expectedCommit = block.number + nft.REVEAL_DELAY();

        uint256 id = _mint(alice);

        assertEq(nft.commitBlockOf(id), expectedCommit);
        assertEq(nft.genesisMinted(), 1);
    }

    function test_isGenesis_marksTheGenesisIdRange() public view {
        uint256 cap = nft.MAX_GENESIS_SUPPLY();
        assertFalse(nft.isGenesis(0), "id 0 is never genesis");
        assertTrue(nft.isGenesis(1), "first id is genesis");
        assertTrue(nft.isGenesis(cap), "cap is the last genesis id");
        assertFalse(nft.isGenesis(cap + 1), "first transform id is not genesis");
        assertFalse(nft.isGenesis(cap + 1000), "later transform ids are not genesis");
    }

    /// @dev Positional, not existence-based: an unminted id in the genesis range
    ///      still reads as genesis.
    function test_isGenesis_isPurelyPositional() public view {
        assertTrue(nft.isGenesis(500), "unminted genesis-range id still reads genesis");
    }

    // ─── tokenURI / renderer ────────────────────────────────────────────────

    event RendererUpdated(address indexed previousRenderer, address indexed newRenderer);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    function test_tokenURI_revertsForNonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(42)));
        nft.tokenURI(42);
    }

    function test_tokenURI_revertsWhenRendererNotSet() public {
        _mint(alice);
        vm.expectRevert(RendererNotSet.selector);
        nft.tokenURI(1);
    }

    function test_tokenURI_forwardsToRenderer() public {
        StubRenderer r = new StubRenderer("stub");
        nft.setRenderer(r);
        _mint(alice);
        _mint(bob);
        assertEq(nft.tokenURI(1), "stub:1");
        assertEq(nft.tokenURI(2), "stub:2");
    }

    function test_tokenURI_bubblesRendererRevert() public {
        nft.setRenderer(new RevertingRenderer());
        _mint(alice);
        vm.expectRevert(RevertingRenderer.RendererBlewUp.selector);
        nft.tokenURI(1);
    }

    function test_setRenderer_emitsRendererUpdatedAndBatchMetadataUpdate() public {
        StubRenderer r = new StubRenderer("a");

        vm.expectEmit(true, true, true, true);
        emit RendererUpdated(address(0), address(r));
        vm.expectEmit(true, true, true, true);
        emit BatchMetadataUpdate(0, type(uint256).max);
        nft.setRenderer(r);

        assertEq(address(nft.renderer()), address(r));
    }

    function test_setRenderer_swapsAndRefreshesAllTokens() public {
        StubRenderer a = new StubRenderer("a");
        StubRenderer b = new StubRenderer("b");

        nft.setRenderer(a);
        _mint(alice);
        assertEq(nft.tokenURI(1), "a:1");

        vm.expectEmit(true, true, true, true);
        emit RendererUpdated(address(a), address(b));
        vm.expectEmit(true, true, true, true);
        emit BatchMetadataUpdate(0, type(uint256).max);
        nft.setRenderer(b);

        assertEq(nft.tokenURI(1), "b:1");
    }

    function test_setRenderer_revertsForNonOwner() public {
        StubRenderer r = new StubRenderer("x");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.setRenderer(r);
    }

    function test_setRenderer_zeroAddressDisablesTokenURI() public {
        nft.setRenderer(new StubRenderer("x"));
        _mint(alice);
        nft.setRenderer(ITalismanRenderer(address(0)));
        vm.expectRevert(RendererNotSet.selector);
        nft.tokenURI(1);
    }

    // ─── freezeRenderer ──────────────────────────────────────────────────────
    //
    // freezeRenderer permanently locks the renderer reference. It is irreversible
    // and keeps tokenURI resolving through whatever renderer was active when frozen.

    event RendererFrozen();

    function test_rendererFrozen_defaultsFalse() public view {
        assertFalse(nft.rendererFrozen());
    }

    /// @dev Once frozen, setRenderer always reverts and the active renderer keeps
    ///      serving tokenURI — even the owner can no longer swap it.
    function test_freezeRenderer_locksRendererPermanently() public {
        StubRenderer r = new StubRenderer("locked");
        nft.setRenderer(r);
        nft.freezeRenderer();
        assertTrue(nft.rendererFrozen());
        assertEq(address(nft.renderer()), address(r));

        StubRenderer other = new StubRenderer("other");
        vm.expectRevert(Talismans.RendererIsFrozen.selector);
        nft.setRenderer(other);
        assertEq(address(nft.renderer()), address(r));

        // The frozen renderer still resolves tokenURI.
        _mint(alice);
        assertEq(nft.tokenURI(1), "locked:1");
    }

    /// @dev A zero renderer can be frozen too: tokenURI stays permanently disabled.
    function test_freezeRenderer_capturesUnsetState() public {
        nft.freezeRenderer();
        _mint(alice);
        vm.expectRevert(RendererNotSet.selector);
        nft.tokenURI(1);
        StubRenderer r = new StubRenderer("x");
        vm.expectRevert(Talismans.RendererIsFrozen.selector);
        nft.setRenderer(r);
    }

    function test_freezeRenderer_revertsWhenAlreadyFrozen() public {
        nft.freezeRenderer();
        vm.expectRevert(Talismans.RendererIsFrozen.selector);
        nft.freezeRenderer();
    }

    function test_freezeRenderer_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.freezeRenderer();
    }

    function test_freezeRenderer_emitsEventOnce() public {
        vm.expectEmit(false, false, false, false);
        emit RendererFrozen();
        nft.freezeRenderer();
    }

    // ─── setMaterials / freezeMaterials ──────────────────────────────────────
    //
    // freezeMaterials permanently locks the materials table reference, fixing
    // every token's derived material identity for good.

    event MaterialsUpdated(address indexed previousMaterials, address indexed newMaterials);
    event MaterialsFrozen();

    function test_setMaterials_emitsMaterialsUpdatedAndBatchMetadataUpdate() public {
        TalismanMaterials m = new TalismanMaterials();

        vm.expectEmit(true, true, true, true);
        emit MaterialsUpdated(address(0), address(m));
        vm.expectEmit(true, true, true, true);
        emit BatchMetadataUpdate(0, type(uint256).max);
        nft.setMaterials(m);

        assertEq(address(nft.materials()), address(m));
    }

    function test_setMaterials_revertsForNonOwner() public {
        TalismanMaterials m = new TalismanMaterials();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.setMaterials(m);
    }

    function test_materialsFrozen_defaultsFalse() public view {
        assertFalse(nft.materialsFrozen());
    }

    /// @dev Once frozen, setMaterials always reverts and the active table is
    ///      retained — even the owner can no longer swap it.
    function test_freezeMaterials_locksMaterialsPermanently() public {
        TalismanMaterials m = new TalismanMaterials();
        nft.setMaterials(m);
        nft.freezeMaterials();
        assertTrue(nft.materialsFrozen());
        assertEq(address(nft.materials()), address(m));

        TalismanMaterials other = new TalismanMaterials();
        vm.expectRevert(Talismans.MaterialsAreFrozen.selector);
        nft.setMaterials(other);
        assertEq(address(nft.materials()), address(m));
    }

    /// @dev An unset (zero) table can be frozen too — the reference stays locked.
    function test_freezeMaterials_capturesUnsetState() public {
        nft.freezeMaterials();
        assertEq(address(nft.materials()), address(0));
        TalismanMaterials m = new TalismanMaterials();
        vm.expectRevert(Talismans.MaterialsAreFrozen.selector);
        nft.setMaterials(m);
    }

    function test_freezeMaterials_revertsWhenAlreadyFrozen() public {
        nft.freezeMaterials();
        vm.expectRevert(Talismans.MaterialsAreFrozen.selector);
        nft.freezeMaterials();
    }

    function test_freezeMaterials_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.freezeMaterials();
    }

    function test_freezeMaterials_emitsEventOnce() public {
        vm.expectEmit(false, false, false, false);
        emit MaterialsFrozen();
        nft.freezeMaterials();
    }

    /// @dev The three freeze switches are independent: freezing the renderer must
    ///      not lock materials or the transformation toggles, and vice versa.
    function test_freezes_areIndependent() public {
        nft.freezeRenderer();
        assertTrue(nft.rendererFrozen());
        assertFalse(nft.materialsFrozen());
        assertFalse(nft.transformationSettingsFrozen());

        nft.freezeMaterials();
        assertTrue(nft.materialsFrozen());
        assertFalse(nft.transformationSettingsFrozen());

        // Materials/renderer frozen, yet transformation settings still toggle.
        nft.setTransformationSettings(true, false);
        assertTrue(nft.bondAndCleaveEnabled());
    }

    function test_supportsInterface_erc4906() public view {
        // ERC-4906 interface id per spec.
        assertTrue(nft.supportsInterface(bytes4(0x49064906)));
    }

    // ─── token surfaces: existence / reveal guards ───────────────────────────
    //
    // Forwarding correctness and the happy path (with a revealed token, a wired
    // material table and the real renderer) live in TalismanMetadataRenderer.t.sol.
    // Here we only pin the shared {_renderableCores} guard: the surfaces must
    // distinguish an unminted id from a minted-but-unrevealed one.

    function test_tokenSurfaces_revertForNonexistent() public {
        nft.setRenderer(new StubRenderer("x"));
        bytes memory expected = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(42));

        vm.expectRevert(expected);
        nft.tokenView(42);
        vm.expectRevert(expected);
        nft.tokenImage(42);
        vm.expectRevert(expected);
        nft.tokenShape(42);
        vm.expectRevert(expected);
        nft.tokenData(42);
    }

    function test_tokenSurfaces_revertForUnrevealed() public {
        nft.setRenderer(new StubRenderer("x"));
        _mint(alice); // minted, never revealed → no cores
        bytes memory expected = abi.encodeWithSelector(NotRevealed.selector, uint256(1));

        vm.expectRevert(expected);
        nft.tokenView(1);
        vm.expectRevert(expected);
        nft.tokenImage(1);
        vm.expectRevert(expected);
        nft.tokenShape(1);
        vm.expectRevert(expected);
        nft.tokenData(1);
    }

    // ─── Two-step ownership ──────────────────────────────────────────────────

    function test_transferOwnership_isTwoStep() public {
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferStarted(deployer, alice);
        nft.transferOwnership(alice);

        // current owner unchanged until acceptance
        assertEq(nft.owner(), deployer);
        assertEq(nft.pendingOwner(), alice);

        // owner-only gate still binds the original owner — try a real owner op
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.setMinter(bob);
    }

    function test_acceptOwnership_completesTransfer() public {
        nft.transferOwnership(alice);

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(deployer, alice);
        vm.prank(alice);
        nft.acceptOwnership();

        assertEq(nft.owner(), alice);
        assertEq(nft.pendingOwner(), address(0));

        // new owner can call owner-only ops
        vm.prank(alice);
        nft.setMinter(bob);
        assertEq(nft.minter(), bob);

        // old owner can no longer
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        nft.setMinter(carol);
    }

    function test_acceptOwnership_revertsForNonPending() public {
        nft.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        nft.acceptOwnership();
    }

    function test_transferOwnership_canBeCancelledByOwner() public {
        nft.transferOwnership(alice);
        // setting pending owner to address(0) cancels the transfer
        nft.transferOwnership(address(0));
        assertEq(nft.pendingOwner(), address(0));

        // alice can no longer accept
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.acceptOwnership();
    }

    function test_transferOwnership_canBeReassignedBeforeAccept() public {
        nft.transferOwnership(alice);
        nft.transferOwnership(bob);
        assertEq(nft.pendingOwner(), bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.acceptOwnership();

        vm.prank(bob);
        nft.acceptOwnership();
        assertEq(nft.owner(), bob);
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.transferOwnership(bob);
    }

    function test_renounceOwnership_setsOwnerToZero() public {
        nft.renounceOwnership();
        assertEq(nft.owner(), address(0));
    }

    function test_renounceOwnership_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.renounceOwnership();
    }

    // ─── Standard ERC-721 transfers still work ───────────────────────────────

    function test_transferFrom_movesToken() public {
        _mint(alice);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.balanceOf(alice), 0);
        assertEq(nft.balanceOf(bob), 1);
        // transfers do not change supply
        assertEq(nft.totalSupply(), 1);
    }

    function test_safeTransferFrom_toGoodReceiver() public {
        GoodReceiver rx = new GoodReceiver();
        _mint(alice);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(rx), 1);
        assertEq(nft.ownerOf(1), address(rx));
    }

    // ─── tokensOfOwner enumeration ────────────────────────────────────────────

    /// @dev Order-independent membership check — tokensOfOwner returns ids in
    ///      storage order, which callers must not depend on.
    function _contains(uint256[] memory ids, uint256 v) internal pure returns (bool) {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == v) {
                return true;
            }
        }
        return false;
    }

    function test_tokensOfOwner_emptyForFreshAddress() public view {
        assertEq(nft.tokensOfOwner(alice).length, 0);
    }

    function test_tokensOfOwner_listsEveryMintedToken() public {
        uint256 a = _mint(alice);
        uint256 b = _mint(alice);
        uint256 c = _mint(alice);

        uint256[] memory ids = nft.tokensOfOwner(alice);
        assertEq(ids.length, 3);
        assertTrue(_contains(ids, a));
        assertTrue(_contains(ids, b));
        assertTrue(_contains(ids, c));
        // Matches balanceOf exactly — no missing or duplicate ids.
        assertEq(ids.length, nft.balanceOf(alice));
    }

    function test_tokensOfOwner_isolatesOwners() public {
        uint256 a1 = _mint(alice);
        uint256 b1 = _mint(bob);
        uint256 a2 = _mint(alice);

        uint256[] memory aIds = nft.tokensOfOwner(alice);
        uint256[] memory bIds = nft.tokensOfOwner(bob);

        assertEq(aIds.length, 2);
        assertTrue(_contains(aIds, a1));
        assertTrue(_contains(aIds, a2));
        assertFalse(_contains(aIds, b1));

        assertEq(bIds.length, 1);
        assertTrue(_contains(bIds, b1));
    }

    function test_tokensOfOwner_movesOnTransfer() public {
        uint256 id = _mint(alice);
        _mint(alice); // a second token that must stay put

        vm.prank(alice);
        nft.transferFrom(alice, bob, id);

        uint256[] memory aIds = nft.tokensOfOwner(alice);
        uint256[] memory bIds = nft.tokensOfOwner(bob);

        assertEq(aIds.length, 1);
        assertFalse(_contains(aIds, id), "transferred id left the sender's set");
        assertEq(bIds.length, 1);
        assertTrue(_contains(bIds, id), "transferred id joined the receiver's set");
    }

    function test_tokensOfOwner_unaffectedBySelfTransfer() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        nft.transferFrom(alice, alice, id);

        uint256[] memory ids = nft.tokensOfOwner(alice);
        assertEq(ids.length, 1);
        assertTrue(_contains(ids, id));
    }

    function testFuzz_tokensOfOwner_matchesBalance(uint8 mintCount, uint8 transferCount) public {
        uint256 toMint = bound(mintCount, 1, 12);
        uint256 toTransfer = bound(transferCount, 0, toMint);

        uint256[] memory minted = new uint256[](toMint);
        for (uint256 i; i < toMint; ++i) {
            minted[i] = _mint(alice);
        }
        for (uint256 i; i < toTransfer; ++i) {
            vm.prank(alice);
            nft.transferFrom(alice, bob, minted[i]);
        }

        assertEq(nft.tokensOfOwner(alice).length, nft.balanceOf(alice));
        assertEq(nft.tokensOfOwner(bob).length, nft.balanceOf(bob));
        assertEq(nft.tokensOfOwner(alice).length, toMint - toTransfer);
        assertEq(nft.tokensOfOwner(bob).length, toTransfer);
    }

    // ─── Fuzzing ─────────────────────────────────────────────────────────────

    function testFuzz_mint_assignsExpectedId(address[5] memory recipients) public {
        for (uint256 i = 0; i < recipients.length; i++) {
            address to = recipients[i];
            vm.assume(to != address(0) && to.code.length == 0);
            uint256 id = _mint(to);
            assertEq(id, i + 1);
            assertEq(nft.ownerOf(id), to);
        }
        assertEq(nft.totalSupply(), recipients.length);
        assertEq(nft.genesisMinted(), recipients.length);
    }

    function testFuzz_mint_revertsForNonMinter(address caller) public {
        vm.assume(caller != address(this));
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Talismans.UnauthorizedMinter.selector, caller));
        nft.mintWithCommitment(alice);
    }
}

/// @dev Exercises {Talismans.rescueBalance} — the owner escape hatch for ETH
///      force-sent to a contract that has no payable entry point.
contract TalismansRescueTest is Test {
    Talismans internal nft;

    address internal alice = address(0xA11CE);

    function setUp() public {
        nft = new Talismans(); // owner == address(this)
    }

    function test_rescueBalance_sweepsToOwner() public {
        // The token has no payable function; vm.deal stands in for a forced send.
        vm.deal(address(nft), 3 ether);
        uint256 balanceBefore = address(this).balance;

        nft.rescueBalance();

        assertEq(address(nft).balance, 0, "token not drained");
        assertEq(address(this).balance, balanceBefore + 3 ether, "owner did not receive funds");
    }

    function test_rescueBalance_revertsForNonOwner() public {
        vm.deal(address(nft), 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.rescueBalance();
        assertEq(address(nft).balance, 1 ether, "balance leaked");
    }

    function test_rescueBalance_revertsWhenEmpty() public {
        vm.expectRevert(Talismans.NothingToRescue.selector);
        nft.rescueBalance();
    }

    /// @dev The sweep follows ownership: after a two-step transfer the rescued
    ///      ETH lands with the new owner, and only they may trigger it.
    function test_rescueBalance_followsCurrentOwner() public {
        nft.transferOwnership(alice);
        vm.prank(alice);
        nft.acceptOwnership();

        vm.deal(address(nft), 2 ether);
        uint256 before = alice.balance;

        vm.prank(alice);
        nft.rescueBalance();

        assertEq(alice.balance, before + 2 ether);
        assertEq(address(nft).balance, 0);
    }

    receive() external payable {}
}
