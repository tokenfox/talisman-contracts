// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TalismanForms} from "../../src/TalismanForms.sol";
import {TalismanGeneratorV2} from "../../src/TalismanGeneratorV2.sol";
import {TalismanMaterials} from "../../src/TalismanMaterials.sol";
import {TalismanSvgRendererV3} from "../../src/TalismanSvgRendererV3.sol";
import {VesselRaster} from "../../script/thevessel/VesselRaster.sol";

/// @dev The craft rasteriser, against a locally deployed render stack.
contract VesselRasterTest is Test {
    VesselRaster.Stack internal stack;

    function setUp() public {
        stack = VesselRaster.Stack({
            materials: new TalismanMaterials(), generator: new TalismanGeneratorV2(), svg: new TalismanSvgRendererV3()
        });
    }

    function _render(uint8 materialId, uint8 form, uint8 cores, uint16 seed, uint256 w, uint256 h)
        internal
        view
        returns (bytes memory)
    {
        return VesselRaster.render(stack, materialId, TalismanForms.ShapeForm(form), cores, seed, w, h);
    }

    function test_Grid_MatchesVesselRenderer() public pure {
        (uint256 cols, uint256 rows) = VesselRaster.grid(9832);
        assertEq(cols, 100);
        assertEq(rows, 99);
        (cols, rows) = VesselRaster.grid(1364);
        assertEq(cols, 37);
        assertEq(rows, 37);
        (cols, rows) = VesselRaster.grid(10000);
        assertEq(cols, 100);
        assertEq(rows, 100);
    }

    function test_ExactFit() public pure {
        assertTrue(VesselRaster.isExactFit(9832));
        assertTrue(VesselRaster.isExactFit(9344));
        assertTrue(VesselRaster.isExactFit(1364));
        assertFalse(VesselRaster.isExactFit(9920));
        assertFalse(VesselRaster.isExactFit(10000));
        assertFalse(VesselRaster.isExactFit(32));
        (uint256 w, uint256 h) = VesselRaster.imageSize(9832);
        assertEq(w, 100);
        assertEq(h, 98);
    }

    /// @dev With 32 columns the address word fills the last row exactly, so
    ///      `n % cols` is 0, not 32. 992 is 31 rows, 1024 is 32 rows.
    function test_ExactFit_ThirtyTwoColumns() public pure {
        uint256[2] memory sizes = [uint256(992), 1024];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 n = sizes[i];
            (uint256 cols, uint256 rows) = VesselRaster.grid(n);
            assertEq(cols, 32);
            assertTrue(VesselRaster.isExactFit(n));
            (uint256 w, uint256 h) = VesselRaster.imageSize(n);
            assertEq(w, 32);
            assertEq(h, rows - 1);
            assertEq(w * h + 32, n, "image plus the address word fills the craft");
        }
        assertFalse(VesselRaster.isExactFit(993), "32 columns, a one-cell last row");
        assertFalse(VesselRaster.isExactFit(1023), "32 columns, a 31-cell last row");
    }

    function test_ImageSize_PlusAddressWordIsTheCraft() public pure {
        for (uint256 n = 33; n <= 10_000; ++n) {
            if (!VesselRaster.isExactFit(n)) {
                continue;
            }
            (uint256 w, uint256 h) = VesselRaster.imageSize(n);
            assertEq(w * h + 32, n);
        }
    }

    function test_Render_LengthAndDeterminism() public view {
        bytes memory a = _render(15, 0, 4, 1234, 100, 98);
        assertEq(a.length, 100 * 98);
        assertEq(keccak256(a), keccak256(_render(15, 0, 4, 1234, 100, 98)));
    }

    function test_Render_BlackGroundAndLiftedFloor() public view {
        bytes memory img = _render(10, 7, 2, 42, 100, 98);
        assertEq(uint8(img[0]), 0, "corner is background");
        assertEq(uint8(img[img.length - 1]), 0, "corner is background");
        uint256 covered;
        uint256 maxV;
        for (uint256 i; i < img.length; ++i) {
            uint8 v = uint8(img[i]);
            if (v != 0) {
                covered++;
            }
            if (v > maxV) {
                maxV = v;
            }
        }
        assertGt(covered, 1000, "Talisman covers a real share of the square");
        assertGe(maxV, VesselRaster.GREY_FLOOR, "covered pixels sit on or above the floor");
    }

    function test_Render_SquareIsCentred() public view {
        bytes memory img = _render(15, 0, 4, 1234, 100, 98);
        // The 98x98 square leaves one background column on each side.
        for (uint256 y; y < 98; ++y) {
            assertEq(uint8(img[y * 100]), 0);
            assertEq(uint8(img[y * 100 + 99]), 0);
        }
    }

    // A craft chosen by hand need not be an exact fit: the image takes the full rows
    // before the address word, and padding makes up the rest.
    function test_ImageSize_FitsBeforeTheAddressWordForAnyCraft() public pure {
        for (uint256 n = 32; n <= 10_000; ++n) {
            (uint256 w, uint256 h) = VesselRaster.imageSize(n);
            assertLe(w * h + 32, n);
            assertGt(w * (h + 1) + 32, n, "no full row is left unused");
        }
        (uint256 w684, uint256 h684) = VesselRaster.imageSize(684);
        assertEq(w684, 27);
        assertEq(h684, 24);
    }

    function test_Grey_FloorAndCeiling() public pure {
        assertEq(VesselRaster.grey(0x000000), VesselRaster.GREY_FLOOR);
        assertEq(VesselRaster.grey(0xFFFFFF), 255);
    }
}
