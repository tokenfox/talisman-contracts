// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// File-level errors shared between {Talismans}, {TalismanTransformationLib}, and
// {TalismanTransformationSimulator}. Declaring them here (rather than per-contract)
// makes the error *selectors* identical across all three, which is critical:
// the `simulate*` previews must revert with the SAME selector the matching
// mutating op would, so a frontend can `eth_call` a preview and surface the
// exact failure reason. Errors used only by {Talismans} (minter/reveal/genesis
// toggles) stay declared on that contract.

/// @notice Thrown when a material-dependent read or transformation runs before the materials table is set.
error MaterialsNotSet();
/// @notice Thrown when rendering is attempted with no renderer wired.
error RendererNotSet();
/// @notice Thrown when an operation needs a token's cores but the token has not revealed.
/// @param tokenId The unrevealed token.
error NotRevealed(uint256 tokenId);

// --- bond --------------------------------------------------------------------
/// @notice Thrown by {bond} when both inputs are the same token.
/// @param tokenId The token passed for both inputs.
error CannotBondSameToken(uint256 tokenId);
/// @notice Thrown by {bond} when one of its inputs has not revealed.
/// @param tokenId The unrevealed input.
error BondTokenNotRevealed(uint256 tokenId);
/// @notice Thrown by {bond} when its two inputs hold different core counts; bonding requires an equal count on each.
/// @param keepCores The first input's core count.
/// @param mergedCores The second input's core count.
error BondRequiresMatchedCores(uint256 keepCores, uint256 mergedCores);
/// @notice Thrown by {bond} when its inputs are not on opposite poles; bonding requires one Lithic and one Lumic input.
/// @param tokenId The first input.
/// @param mergedTokenId The second input.
error BondRequiresOppositePoles(uint256 tokenId, uint256 mergedTokenId);

// --- cleave ------------------------------------------------------------------
/// @notice Thrown by {cleave} when the token is not a Mythic, and so has no two poles to split.
/// @param tokenId The token that cannot be cleaved.
error TokenNotCleavable(uint256 tokenId);

// --- cut ---------------------------------------------------------------------
/// @notice Thrown by {cut} when the token is a Mythic; a Mythic spans two materials and cannot be cut.
/// @param tokenId The rejected Mythic.
error CutRejectsMythic(uint256 tokenId);
/// @notice Thrown by {cut} when the token is not homogeneous, i.e. its cores do not all share one material and form.
/// @param tokenId The token that cannot be cut.
error TokenNotCuttable(uint256 tokenId);
/// @notice Thrown by {cut} when the split point is out of range; it must satisfy `1 <= index < coreCount`.
/// @param index The rejected split point.
/// @param coreCount The token's core count.
error InvalidCutIndex(uint256 index, uint256 coreCount);

// --- merge -------------------------------------------------------------------
/// @notice Thrown by {merge} when both inputs are the same token.
/// @param tokenId The token passed for both inputs.
error CannotMergeSameToken(uint256 tokenId);
/// @notice Thrown by {merge} when an input is a Mythic; only non-Mythic tokens merge.
/// @param tokenId The rejected Mythic.
error MergeRejectsMythic(uint256 tokenId);
/// @notice Thrown by {merge} when its inputs are not the same kind, i.e. they differ in derived material or form.
/// @param a The first input.
/// @param b The second input.
error MergeRequiresSameKind(uint256 a, uint256 b);
/// @notice Thrown by {merge} when the combined core count would exceed the pure-tier ceiling.
/// @param totalCores The rejected combined core count.
error MergeExceedsTier(uint256 totalCores);
