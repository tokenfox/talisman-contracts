// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TalismanLitMaterials} from "../src/TalismanLitMaterials.sol";
import {MATERIAL_COUNT} from "../src/TalismanMaterials.sol";

/// @notice Behaviour spec for {TalismanLitMaterials}: the table's shape, the
///         units each field decodes to, and the bounds the lit model relies on.
contract TalismanLitMaterialsTest is Test {
    uint256 internal constant ROW = 7;

    function test_table_isOneRowOfSevenBytesPerMaterial() public pure {
        assertEq(TalismanLitMaterials.TABLE.length, uint256(MATERIAL_COUNT) * ROW);
        assertEq(uint256(MATERIAL_COUNT), 48);
    }

    /// @dev A zero exponent would flatten the pow to one and paint every facet
    ///      at full gain; the WAD bounds keep the terms inside what the model
    ///      was tuned over.
    function test_everyMaterial_decodesInsideTheModelsBounds() public pure {
        for (uint8 id = 0; id < MATERIAL_COUNT; ++id) {
            TalismanLitMaterials.LitParams memory p = TalismanLitMaterials.params(id);
            assertGe(p.shininess, 1, "shininess");
            assertGe(p.rimPower, 1, "rim power");
            assertTrue(p.specularGain >= 0 && p.specularGain <= 2e18, "specular gain");
            assertTrue(p.rimGain >= 0 && p.rimGain <= 2e18, "rim gain");
            assertTrue(p.tint >= 0 && p.tint <= 1e18, "tint");
            assertTrue(p.wrap >= 0 && p.wrap <= 1e18, "wrap");
            assertTrue(p.glow >= 0 && p.glow <= 0.5e18, "glow");
        }
    }

    /// @dev The row is read straight off the table, so the first material pins
    ///      the byte order: the two exponents whole, the rest in hundredths.
    function test_params_decodeTheRowInOrder() public pure {
        TalismanLitMaterials.LitParams memory p = TalismanLitMaterials.params(0);
        assertEq(p.shininess, 8);
        assertEq(p.specularGain, 0);
        assertEq(p.rimPower, 2);
        assertEq(p.rimGain, 0.4e18);
        assertEq(p.tint, 1e18);
        assertEq(p.wrap, 0.2e18);
        assertEq(p.glow, 0.04e18);
        bytes7 expected = hex"08000228641404";
        assertEq(TalismanLitMaterials.row(0), expected);
    }

    function test_row_lastMaterialReadsCleanly() public pure {
        bytes7 expected = hex"1428031e5a0f04";
        assertEq(TalismanLitMaterials.row(47), expected);
        TalismanLitMaterials.LitParams memory p = TalismanLitMaterials.params(47);
        assertEq(p.shininess, 20);
        assertEq(p.glow, 0.04e18);
    }

    function test_tint_phosphorIsItsOwnColourAndRockIsWhite() public pure {
        assertEq(TalismanLitMaterials.params(43).tint, 1e18, "Phosphor");
        assertEq(TalismanLitMaterials.params(16).tint, 0, "Rock");
    }

    function test_row_rejectsAnUnknownMaterial() public {
        vm.expectRevert(abi.encodeWithSelector(TalismanLitMaterials.UnknownMaterial.selector, 48));
        this.rowOf(48);
        vm.expectRevert(abi.encodeWithSelector(TalismanLitMaterials.UnknownMaterial.selector, 255));
        this.paramsOf(255);
    }

    function rowOf(uint8 id) external pure returns (bytes7) {
        return TalismanLitMaterials.row(id);
    }

    function paramsOf(uint8 id) external pure returns (TalismanLitMaterials.LitParams memory) {
        return TalismanLitMaterials.params(id);
    }
}
