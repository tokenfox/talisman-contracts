// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MATERIAL_COUNT} from "./TalismanMaterials.sol";

/// @title TalismanLitMaterials
/// @notice How each material takes the light. The per-vertex lit model has
///         seven terms a material can move, and this table holds them for
///         all 48: a gem carries a tight white pin, a metal a highlight in
///         its own colour, a glowing material no reflection at all.
/// @dev One row of seven bytes per material, in material-id order:
///      shininess, specular gain, rim power, rim gain, tint, wrap, glow. The
///      two exponents are whole numbers; the rest are hundredths, returned
///      in WAD. Inlined wherever it is used, so it is never deployed alone.
library TalismanLitMaterials {
    error UnknownMaterial(uint8 materialId);

    uint256 private constant ROW = 7;

    struct LitParams {
        uint256 shininess;
        int256 specularGain;
        uint256 rimPower;
        int256 rimGain;
        int256 tint;
        int256 wrap;
        int256 glow;
    }

    bytes internal constant TABLE =
        hex"080002286414041a3c031e6400000600023264160750640619320500463c05143704016482052a2d00000a0f0428640c04060f021e641b050a0f031e6416030514031c6404030c0a042d640a0104000432641606466405283c00006e5a05202d0000123704143c0501a0b4061e230000050a050800020008000223641b06503c051e370500163204121e07012da004234b0001060f041c641405080f0328640f03374b04160a0a003c28043c4b190a060a031e641b05060a0323641405050f040f5a0c000612041246020046500514190000060f041e641105080f031955140208140228640f060a19031e64160406140323640c040100021e000f01102303235a0a051a00051e640c040a1402236411040100043c0000010a1e02234b14021664041e5a0200140f03236414050c0f03196411070a230223640f06060f03466411070e1e0323640f061428031e5a0f04";

    /// @notice The lit terms of a material, in the units the shading math takes.
    /// @param materialId The material, 0 to 47.
    /// @return p Two whole exponents and five WAD fractions.
    function params(uint8 materialId) internal pure returns (LitParams memory p) {
        bytes7 r = row(materialId);
        p.shininess = uint8(r[0]);
        p.specularGain = _wad(r[1]);
        p.rimPower = uint8(r[2]);
        p.rimGain = _wad(r[3]);
        p.tint = _wad(r[4]);
        p.wrap = _wad(r[5]);
        p.glow = _wad(r[6]);
    }

    /// @notice A material's row as stored, so a viewer can print the very
    ///         numbers the image was lit with.
    /// @param materialId The material, 0 to 47.
    /// @return r Shininess, specular gain, rim power, rim gain, tint, wrap, glow.
    function row(uint8 materialId) internal pure returns (bytes7 r) {
        if (materialId >= MATERIAL_COUNT) {
            revert UnknownMaterial(materialId);
        }
        bytes memory table = TABLE;
        uint256 at = 32 + uint256(materialId) * ROW;
        assembly ("memory-safe") {
            r := and(mload(add(table, at)), shl(200, 0xFFFFFFFFFFFFFF))
        }
    }

    function _wad(bytes1 centi) private pure returns (int256) {
        return int256(uint256(uint8(centi))) * 1e16;
    }
}
