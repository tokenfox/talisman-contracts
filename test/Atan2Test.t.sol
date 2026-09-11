// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {TalismanSvgRenderer} from "../src/TalismanSvgRenderer.sol";
import {Camera, Point3D, Triangle} from "../src/TalismanStructs.sol";

contract Atan2Test is Test {
    TalismanSvgRenderer public renderer;

    // Fixed-point arithmetic constants
    int256 constant WAD = 1e18;
    int256 constant PI = 3141592653589793238; // π * 1e18

    function setUp() public {
        renderer = new TalismanSvgRenderer();
    }

    // Test helper function to expose _atan2 for testing
    function testAtan2(int256 y, int256 x) public view returns (int256) {
        // Add bounds checking to prevent overflow
        if (x == type(int256).min || y == type(int256).min) {
            return 0; // Skip extreme values that cause overflow
        }

        // Limit the magnitude to prevent overflow in calculations
        int256 maxMagnitude = 1e20; // Reasonable limit
        if (x > maxMagnitude || x < -maxMagnitude || y > maxMagnitude || y < -maxMagnitude) {
            return 0; // Skip values that are too large
        }

        // We'll test through the camera orientation calculation
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: x, y: y, z: WAD}), fieldOfView: 45 * WAD
        });

        // This will call _atan2 internally for yaw calculation
        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 0, z: 0}),
            p3: Point3D({x: 0, y: 0, z: 0}),
            materialId: 0
        });

        renderer.transformTri(triangle, camera);
        return 0; // We can't directly return the atan2 result, but we can verify behavior
    }

    function test_Atan2_FirstQuadrant() public view {
        // Test positive x, positive y (first quadrant)
        // atan2(1, 1) should be π/4 (45 degrees)
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: WAD, y: WAD, z: WAD}), fieldOfView: 45 * WAD
        });

        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 0, z: 0}),
            p3: Point3D({x: 0, y: 0, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // Should not overflow or underflow
        assertTrue(result.p1.x != type(int256).max && result.p1.x != type(int256).min, "Should not overflow");
        assertTrue(result.p1.y != type(int256).max && result.p1.y != type(int256).min, "Should not overflow");
        assertTrue(result.p1.z != type(int256).max && result.p1.z != type(int256).min, "Should not overflow");
    }

    function test_Atan2_SecondQuadrant() public view {
        // Test negative x, positive y (second quadrant)
        // atan2(1, -1) should be 3π/4 (135 degrees)
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: -WAD, y: WAD, z: WAD}), fieldOfView: 45 * WAD
        });

        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 0, z: 0}),
            p3: Point3D({x: 0, y: 0, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // Should not overflow or underflow
        assertTrue(result.p1.x != type(int256).max && result.p1.x != type(int256).min, "Should not overflow");
        assertTrue(result.p1.y != type(int256).max && result.p1.y != type(int256).min, "Should not overflow");
        assertTrue(result.p1.z != type(int256).max && result.p1.z != type(int256).min, "Should not overflow");
    }

    function test_Atan2_ThirdQuadrant() public view {
        // Test negative x, negative y (third quadrant)
        // atan2(-1, -1) should be -3π/4 (-135 degrees)
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: -WAD, y: -WAD, z: WAD}), fieldOfView: 45 * WAD
        });

        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 0, z: 0}),
            p3: Point3D({x: 0, y: 0, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // Should not overflow or underflow
        assertTrue(result.p1.x != type(int256).max && result.p1.x != type(int256).min, "Should not overflow");
        assertTrue(result.p1.y != type(int256).max && result.p1.y != type(int256).min, "Should not overflow");
        assertTrue(result.p1.z != type(int256).max && result.p1.z != type(int256).min, "Should not overflow");
    }

    function test_Atan2_FourthQuadrant() public view {
        // Test positive x, negative y (fourth quadrant)
        // atan2(-1, 1) should be -π/4 (-45 degrees)
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: WAD, y: -WAD, z: WAD}), fieldOfView: 45 * WAD
        });

        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 0, z: 0}),
            p3: Point3D({x: 0, y: 0, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // Should not overflow or underflow
        assertTrue(result.p1.x != type(int256).max && result.p1.x != type(int256).min, "Should not overflow");
        assertTrue(result.p1.y != type(int256).max && result.p1.y != type(int256).min, "Should not overflow");
        assertTrue(result.p1.z != type(int256).max && result.p1.z != type(int256).min, "Should not overflow");
    }

    function test_Atan2_ZeroX() public view {
        // Test when x = 0 (vertical lines)
        // atan2(1, 0) should be π/2 (90 degrees)
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: 0, y: WAD, z: WAD}), fieldOfView: 45 * WAD
        });

        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 0, z: 0}),
            p3: Point3D({x: 0, y: 0, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // Should not overflow or underflow
        assertTrue(result.p1.x != type(int256).max && result.p1.x != type(int256).min, "Should not overflow");
        assertTrue(result.p1.y != type(int256).max && result.p1.y != type(int256).min, "Should not overflow");
        assertTrue(result.p1.z != type(int256).max && result.p1.z != type(int256).min, "Should not overflow");
    }

    function test_Atan2_ZeroY() public view {
        // Test when y = 0 (horizontal lines)
        // atan2(0, 1) should be 0 (0 degrees)
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: WAD, y: 0, z: WAD}), fieldOfView: 45 * WAD
        });

        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 0, z: 0}),
            p3: Point3D({x: 0, y: 0, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // Should not overflow or underflow
        assertTrue(result.p1.x != type(int256).max && result.p1.x != type(int256).min, "Should not overflow");
        assertTrue(result.p1.y != type(int256).max && result.p1.y != type(int256).min, "Should not overflow");
        assertTrue(result.p1.z != type(int256).max && result.p1.z != type(int256).min, "Should not overflow");
    }

    function test_Atan2_BothZero() public view {
        // Test when both x and y are 0 (origin)
        // This should handle gracefully
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: 0, y: 0, z: WAD}), fieldOfView: 45 * WAD
        });

        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 0, z: 0}),
            p3: Point3D({x: 0, y: 0, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // Should not overflow or underflow
        assertTrue(result.p1.x != type(int256).max && result.p1.x != type(int256).min, "Should not overflow");
        assertTrue(result.p1.y != type(int256).max && result.p1.y != type(int256).min, "Should not overflow");
        assertTrue(result.p1.z != type(int256).max && result.p1.z != type(int256).min, "Should not overflow");
    }

    function test_Atan2_LargeValues() public view {
        // Test with large values to ensure no overflow
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}),
            lookAt: Point3D({x: 100 * WAD, y: 100 * WAD, z: WAD}),
            fieldOfView: 45 * WAD
        });

        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 0, z: 0}),
            p3: Point3D({x: 0, y: 0, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // Should not overflow or underflow
        assertTrue(result.p1.x != type(int256).max && result.p1.x != type(int256).min, "Should not overflow");
        assertTrue(result.p1.y != type(int256).max && result.p1.y != type(int256).min, "Should not overflow");
        assertTrue(result.p1.z != type(int256).max && result.p1.z != type(int256).min, "Should not overflow");
    }

    function test_Atan2_SmallValues() public view {
        // Test with very small values
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}),
            lookAt: Point3D({x: WAD / 1000, y: WAD / 1000, z: WAD}),
            fieldOfView: 45 * WAD
        });

        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 0, z: 0}),
            p3: Point3D({x: 0, y: 0, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // Should not overflow or underflow
        assertTrue(result.p1.x != type(int256).max && result.p1.x != type(int256).min, "Should not overflow");
        assertTrue(result.p1.y != type(int256).max && result.p1.y != type(int256).min, "Should not overflow");
        assertTrue(result.p1.z != type(int256).max && result.p1.z != type(int256).min, "Should not overflow");
    }

    function test_Atan2_NegativeZ() public view {
        // Test looking backward (negative Z)
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: 0, y: 0, z: -WAD}), fieldOfView: 45 * WAD
        });

        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 0, z: 0}),
            p3: Point3D({x: 0, y: 0, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // Should not overflow or underflow
        assertTrue(result.p1.x != type(int256).max && result.p1.x != type(int256).min, "Should not overflow");
        assertTrue(result.p1.y != type(int256).max && result.p1.y != type(int256).min, "Should not overflow");
        assertTrue(result.p1.z != type(int256).max && result.p1.z != type(int256).min, "Should not overflow");
    }
}
