// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TalismanForms} from "./TalismanForms.sol";

/// @title TalismanCore
/// @dev Stable bit layout for the `uint256` core value emitted by
///      `Talismans.reveal` and consumed by every reader that needs
///      to interpret a core (renderers, UIs, future on-chain mechanics).
///
/// ## Layout (LSB = bit 0)
///
/// | Bits     | Width | Field          | Notes                                |
/// |----------|-------|----------------|--------------------------------------|
/// | 0..5     | 6     | `materialId`   | 0..63 valid; 0..47 used by current   |
/// |          |       |                | material table; 0..31 picked by core |
/// |          |       |                | generation today.                    |
/// | 6..9     | 4     | `shapeForm`    | 0..15 valid; 0..13 used by current   |
/// |          |       |                | form enum.                           |
/// | 10..25   | 16    | `seed`         | Per-token shape-randomization        |
/// |          |       |                | entropy. Drives all internal         |
/// |          |       |                | pseudo-random draws in              |
/// |          |       |                | `TalismanGenerator.generate`        |
/// |          |       |                | (perturbation, palette region picks, |
/// |          |       |                | etc). 16 bits -> 65 536 unique shapes|
/// |          |       |                | per (material, form, tier) tuple.    |
/// | 26..255  | 230   | _reserved_     | Future extensions (e.g. element sig, |
/// |          |       |                | tier, palette modifier). Readers     |
/// |          |       |                | MUST mask only the bits they own -   |
/// |          |       |                | do NOT assume reserved bits are zero |
/// |          |       |                | once future versions ship.           |
///
/// ## Extension rules
///
/// - Allocate new fields by appending upward from the lowest free bit.
/// - Never reshuffle existing bit ranges - old cores must keep their meaning.
/// - Widen a field by claiming an adjacent reserved range; do not narrow.
/// - Add a new accessor when you add a field; keep packers and getters
///   symmetric - the pack/unpack round-trip must always hold.
library TalismanCore {
    uint256 internal constant MATERIAL_BITS = 6;
    uint256 internal constant FORM_BITS = 4;
    uint256 internal constant SEED_BITS = 16;

    uint256 internal constant MATERIAL_SHIFT = 0;
    uint256 internal constant FORM_SHIFT = MATERIAL_SHIFT + MATERIAL_BITS;
    uint256 internal constant SEED_SHIFT = FORM_SHIFT + FORM_BITS;

    uint256 internal constant MATERIAL_MASK = (uint256(1) << MATERIAL_BITS) - 1;
    uint256 internal constant FORM_MASK = (uint256(1) << FORM_BITS) - 1;
    uint256 internal constant SEED_MASK = (uint256(1) << SEED_BITS) - 1;

    /// @dev Build a packed core value from its component fields. Caller is
    ///      responsible for ensuring `materialId_`, `shapeForm_`, and `seed_`
    ///      fit in their declared widths; values outside the mask are truncated
    ///      silently. Pickers in {Talismans} draw from constrained ranges so
    ///      this is safe at the documented call sites.
    function pack(uint8 materialId_, uint8 shapeForm_, uint16 seed_) internal pure returns (uint256) {
        return (uint256(materialId_) & MATERIAL_MASK) | ((uint256(shapeForm_) & FORM_MASK) << FORM_SHIFT)
            | ((uint256(seed_) & SEED_MASK) << SEED_SHIFT);
    }

    function materialId(uint256 core) internal pure returns (uint8) {
        return uint8(core & MATERIAL_MASK);
    }

    function shapeForm(uint256 core) internal pure returns (TalismanForms.ShapeForm) {
        return TalismanForms.ShapeForm(uint8((core >> FORM_SHIFT) & FORM_MASK));
    }

    function seed(uint256 core) internal pure returns (uint16) {
        return uint16((core >> SEED_SHIFT) & SEED_MASK);
    }
}
