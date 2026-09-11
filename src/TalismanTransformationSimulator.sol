// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITalismanRenderer} from "./ITalismanRenderer.sol";
import {ITalismanTransformationSimulator, TokenState} from "./ITalismanTransformationSimulator.sol";
import {TalismanTransformationLib} from "./TalismanTransformationLib.sol";
import {TalismanForms} from "./TalismanForms.sol";
import {TalismanMaterials} from "./TalismanMaterials.sol";
import {CannotBondSameToken, CannotMergeSameToken, RendererNotSet} from "./TalismanErrors.sol";

/// @dev Minimal read interface into the core {Talismans} contract - the only
///      state the simulator needs. Defined locally so the simulator stays
///      decoupled from the full {Talismans} ABI. `ownerOf` reverts
///      {ERC721NonexistentToken} for unknown ids, giving the simulator the same
///      existence check the real ops get from `_requireOwned`.
interface ITalismansTransformationView {
    function coresOf(uint256 tokenId) external view returns (uint256[] memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function nextTransformId() external view returns (uint256);
    function tokenIdForCores(uint256[] calldata cores) external view returns (uint256);
    function materials() external view returns (TalismanMaterials);
    function renderer() external view returns (ITalismanRenderer);
    function MAX_CORES_PER_MINT() external view returns (uint256);
    function MAX_CORES_PER_TOKEN() external view returns (uint256);
}

/// @title TalismanTransformationSimulator
/// @notice Read-only previews of the four transformations. Reads the core
///         {Talismans} contract through an immutable pointer and predicts the
///         exact outcome each transformation would produce; callable by anyone,
///         with no authorization and no enabled-gate, so any frontend can
///         preview an op via `eth_call`.
/// @dev Kept separate from {Talismans} so the core ERC-721 stays well under the
///      24,576-byte contract size limit and previews can be redeployed without
///      touching the token. Stateless except the immutable pointer. All
///      validation and core algebra is delegated to {TalismanTransformationLib},
///      the same library the mutating ops use, so a preview can never drift from
///      the op it previews. Predicted ids thread {Talismans.nextTransformId} so
///      multi-output previews (cleave/cut) assign distinct sequential ids that
///      match what the real op would mint.
contract TalismanTransformationSimulator is ITalismanTransformationSimulator {
    ITalismansTransformationView public immutable talismans;

    constructor(ITalismansTransformationView talismans_) {
        talismans = talismans_;
    }

    /// @inheritdoc ITalismanTransformationSimulator
    function simulateBond(uint256 a, uint256 b) external view returns (TokenState memory result) {
        if (a == b) {
            revert CannotBondSameToken(a);
        }
        talismans.ownerOf(a);
        talismans.ownerOf(b);
        TalismanMaterials mats = talismans.materials();
        uint256[] memory combined = TalismanTransformationLib.bondCores(
            mats, a, b, talismans.coresOf(a), talismans.coresOf(b), talismans.MAX_CORES_PER_TOKEN()
        );
        (uint256 id,) = _previewTokenId(combined, talismans.nextTransformId());
        result = _buildState(mats, id, combined);
    }

    /// @inheritdoc ITalismanTransformationSimulator
    function simulateCleave(uint256 tokenId) external view returns (TokenState memory lithic, TokenState memory lumic) {
        talismans.ownerOf(tokenId);
        TalismanMaterials mats = talismans.materials();
        (uint256[] memory lithicCores, uint256[] memory lumicCores) =
            TalismanTransformationLib.cleaveCores(mats, tokenId, talismans.coresOf(tokenId));
        uint256 free = talismans.nextTransformId();
        uint256 lithicTokenId;
        uint256 lumicTokenId;
        (lithicTokenId, free) = _previewTokenId(lithicCores, free);
        (lumicTokenId,) = _previewTokenId(lumicCores, free);
        lithic = _buildState(mats, lithicTokenId, lithicCores);
        lumic = _buildState(mats, lumicTokenId, lumicCores);
    }

    /// @inheritdoc ITalismanTransformationSimulator
    function simulateCut(uint256 tokenId, uint256 index)
        external
        view
        returns (TokenState memory head, TokenState memory tail)
    {
        talismans.ownerOf(tokenId);
        TalismanMaterials mats = talismans.materials();
        (uint256[] memory headCores, uint256[] memory tailCores) =
            TalismanTransformationLib.cutCores(mats, tokenId, index, talismans.coresOf(tokenId));
        uint256 free = talismans.nextTransformId();
        uint256 headTokenId;
        uint256 tailTokenId;
        (headTokenId, free) = _previewTokenId(headCores, free);
        (tailTokenId,) = _previewTokenId(tailCores, free);
        head = _buildState(mats, headTokenId, headCores);
        tail = _buildState(mats, tailTokenId, tailCores);
    }

    /// @inheritdoc ITalismanTransformationSimulator
    function simulateMerge(uint256 a, uint256 b) external view returns (TokenState memory result) {
        if (a == b) {
            revert CannotMergeSameToken(a);
        }
        talismans.ownerOf(a);
        talismans.ownerOf(b);
        TalismanMaterials mats = talismans.materials();
        uint256[] memory combined = TalismanTransformationLib.mergeCores(
            mats, a, b, talismans.coresOf(a), talismans.coresOf(b), talismans.MAX_CORES_PER_MINT()
        );
        (uint256 id,) = _previewTokenId(combined, talismans.nextTransformId());
        result = _buildState(mats, id, combined);
    }

    // --- Internal ------------------------------------------------------------

    /// @dev Non-mutating id prediction. Returns the recorded id if the sequence
    ///      is known, else `nextFree` and an advanced counter so callers can
    ///      thread multiple fresh outputs into distinct sequential ids.
    function _previewTokenId(uint256[] memory cores, uint256 nextFree)
        internal
        view
        returns (uint256 id, uint256 newNextFree)
    {
        uint256 recorded = talismans.tokenIdForCores(cores);
        if (recorded != 0) {
            return (recorded, nextFree);
        }
        return (nextFree, nextFree + 1);
    }

    /// @dev Build a full {TokenState} (derived traits + raw SVG/HTML) for a
    ///      cores sequence. View-only; heavy string building is fine off-chain.
    function _buildState(TalismanMaterials mats, uint256 tokenId, uint256[] memory cores)
        internal
        view
        returns (TokenState memory s)
    {
        ITalismanRenderer r = talismans.renderer();
        if (address(r) == address(0)) {
            revert RendererNotSet();
        }
        uint8 mid = TalismanTransformationLib.deriveMaterialId(mats, cores);
        TalismanForms.ShapeForm form = TalismanTransformationLib.deriveShapeForm(cores);
        uint8 cc = uint8(cores.length);
        uint16 sd = TalismanTransformationLib.deriveSeed(cores);
        s = TokenState({
            tokenId: tokenId,
            cores: cores,
            materialId: mid,
            form: form,
            coreCount: cc,
            seed: sd,
            image: r.imageFromTraits(mid, form, cc, sd),
            html: r.htmlFromTraits(mid, form, cc, sd)
        });
    }
}
