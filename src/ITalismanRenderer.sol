// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TalismanForms} from "./TalismanForms.sol";

/// @title ITalismanRenderer
/// @notice The metadata renderer behind {Talismans.tokenURI}. The owner of
///         {Talismans} picks the active renderer via {Talismans.setRenderer};
///         the token contract derives each token's traits and hands them here,
///         then returns whatever this renderer produces. A renderer may bundle
///         any number of inner renderers (SVG, HTML, ...) behind this single
///         entry point.
/// @dev A renderer is a pure function of the traits it is given: it reads no
///      {Talismans} state and holds no reference back to the token contract, so
///      the dependency runs one way. Implementations MUST be view/pure - no
///      writes, no payable, no reentrancy hazards - and a misbehaving one can
///      revert or return malformed data but can never mutate {Talismans} state.
interface ITalismanRenderer {
    /// @notice The pre-reveal placeholder metadata URI for `tokenId` - a name
    ///         and a static placeholder image, with no traits or `animation_url`
    ///         until the token reveals. Returned as a
    ///         `data:application/json;base64,...` URI.
    /// @param tokenId The token to render a placeholder for.
    /// @return The placeholder metadata URI.
    function unrevealedURI(uint256 tokenId) external view returns (string memory);

    /// @notice The metadata URI for a revealed token described directly by its
    ///         derived traits - the full metadata document (name, description,
    ///         attributes, image, animation_url), returned as a
    ///         `data:application/json;base64,...` URI. The live entry point for a
    ///         revealed token's {Talismans.tokenURI}, and equally a way to render
    ///         a previewed result - e.g. a bond or cleave that has not been
    ///         executed.
    /// @dev `tokenId` is used only as a display label (e.g. the `name` field) and
    ///      `genesis` only sets the Genesis attribute; the artwork is fully
    ///      determined by `(materialId, form, cores, seed)`. The artwork is built
    ///      inline, so expect this call to be expensive.
    /// @param tokenId The id to label the rendered token with.
    /// @param materialId The token-level material id.
    /// @param form The token-level shape form.
    /// @param cores The token's core count.
    /// @param seed The token-level shape-randomization seed.
    /// @param genesis Whether the token belongs to the genesis id range.
    /// @return The metadata URI for the described token.
    function tokenURIFromTraits(
        uint256 tokenId,
        uint8 materialId,
        TalismanForms.ShapeForm form,
        uint8 cores,
        uint16 seed,
        bool genesis
    ) external view returns (string memory);

    /// @notice The raw SVG markup for a token described by its derived traits -
    ///         an `<svg ...>` document, not a base64 `data:` URI, so a frontend
    ///         can embed the image directly.
    /// @dev Fully determined by `(materialId, form, cores, seed)`. Used by the
    ///      transformation previews.
    /// @param materialId The token-level material id.
    /// @param form The token-level shape form.
    /// @param cores The token's core count.
    /// @param seed The token-level shape-randomization seed.
    /// @return The raw `<svg ...>` document.
    function imageFromTraits(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        external
        view
        returns (string memory);

    /// @notice The raw HTML viewer document for a token described by its derived
    ///         traits - not a base64 `data:` URI. The companion of
    ///         {imageFromTraits} for transformation previews.
    /// @dev Fully determined by `(materialId, form, cores, seed)`.
    /// @param materialId The token-level material id.
    /// @param form The token-level shape form.
    /// @param cores The token's core count.
    /// @param seed The token-level shape-randomization seed.
    /// @return The raw, self-contained HTML viewer document.
    function htmlFromTraits(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        external
        view
        returns (string memory);

    /// @notice The 3D mesh for a token described by its derived traits, as a
    ///         binary STL file - the raw bytes, not a base64 `data:` URI, so a
    ///         caller can save them straight to a `.stl`. Faces carry per-material
    ///         colour (VisCAM convention), so colour-aware viewers and slicers
    ///         show the same materials as the image.
    /// @dev Fully determined by `(materialId, form, cores, seed)`. The companion
    ///      of {imageFromTraits} and {htmlFromTraits} for the 3D form.
    /// @param materialId The token-level material id.
    /// @param form The token-level shape form.
    /// @param cores The token's core count.
    /// @param seed The token-level shape-randomization seed.
    /// @return The binary STL file as raw bytes.
    function stlFromTraits(uint8 materialId, TalismanForms.ShapeForm form, uint8 cores, uint16 seed)
        external
        view
        returns (bytes memory);
}
