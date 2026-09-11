// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {TalismanSvgRenderer} from "../src/TalismanSvgRenderer.sol";
import {Camera, Point3D, Triangle} from "../src/TalismanStructs.sol";

contract CameraOrientationTest is Test {
    TalismanSvgRenderer public renderer;

    // Fixed-point arithmetic constants
    int256 constant WAD = 1e18;
    int256 constant PI = 3141592653589793238; // π * 1e18

    function setUp() public {
        renderer = new TalismanSvgRenderer();
    }

    function test_CameraLookingForward() public view {
        // Camera at origin looking along positive Z-axis
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: 0, y: 0, z: WAD}), fieldOfView: 45 * WAD
        });

        // Test that a point at (0, 0, 1) stays at (0, 0, 1) after transformation
        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: WAD}),
            p2: Point3D({x: 0, y: 0, z: WAD}),
            p3: Point3D({x: 0, y: 0, z: WAD}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // Should be looking forward, so Z should remain positive
        assertTrue(result.p1.z > 0, "Camera should be looking forward");
    }

    function test_CameraLookingBackward() public view {
        // Camera at origin looking along negative Z-axis
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: 0, y: 0, z: -WAD}), fieldOfView: 45 * WAD
        });

        // Test that a point at (0, 0, 1) gets transformed appropriately
        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: WAD}),
            p2: Point3D({x: 0, y: 0, z: WAD}),
            p3: Point3D({x: 0, y: 0, z: WAD}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // Should be looking backward, so Z should be negative
        assertTrue(result.p1.z < 0, "Camera should be looking backward");
    }

    function test_CameraLookingRight() public view {
        // Camera at origin looking along positive X-axis
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: WAD, y: 0, z: 0}), fieldOfView: 45 * WAD
        });

        // Test that a point at (1, 0, 0) gets transformed correctly
        Triangle memory triangle = Triangle({
            p1: Point3D({x: WAD, y: 0, z: 0}),
            p2: Point3D({x: WAD, y: 0, z: 0}),
            p3: Point3D({x: WAD, y: 0, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // For a camera looking right, a point on the positive X-axis should be transformed
        // to have positive Z in camera space (in front of the camera)
        assertTrue(result.p1.z > 0, "Camera should be looking right");
    }

    function test_CameraLookingUp() public view {
        // Camera at origin looking along positive Y-axis
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: 0, y: WAD, z: 0}), fieldOfView: 45 * WAD
        });

        // Test that a point at (0, 1, 0) gets transformed correctly
        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: WAD, z: 0}),
            p2: Point3D({x: 0, y: WAD, z: 0}),
            p3: Point3D({x: 0, y: WAD, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // For a camera looking up, a point on the positive Y-axis should be transformed
        // to have positive Z in camera space (in front of the camera)
        assertTrue(result.p1.z > 0, "Camera should be looking up");
    }

    function test_CameraAtOffsetLookingAtOrigin() public view {
        // Camera at (0, 0, -2) looking at origin
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: -2 * WAD}), lookAt: Point3D({x: 0, y: 0, z: 0}), fieldOfView: 45 * WAD
        });

        // Test that a point at origin gets transformed appropriately
        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: 0, z: 0}),
            p2: Point3D({x: 0, y: 0, z: 0}),
            p3: Point3D({x: 0, y: 0, z: 0}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // After translation and rotation, the point should be at (0, 0, 2) in camera space
        assertEq(result.p1.x, 0, "X should be 0 after transformation");
        assertEq(result.p1.y, 0, "Y should be 0 after transformation");
        assertEq(result.p1.z, 2 * WAD, "Z should be 2 after transformation");
    }

    function test_DebugRightCamera() public view {
        // Debug test for right camera
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: WAD, y: 0, z: 0}), fieldOfView: 45 * WAD
        });

        // Test with a point that should be in front of the camera
        Triangle memory triangle = Triangle({
            p1: Point3D({x: WAD, y: 0, z: WAD}),
            p2: Point3D({x: WAD, y: 0, z: WAD}),
            p3: Point3D({x: WAD, y: 0, z: WAD}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // For a camera looking right, a point at (1, 0, 1) should have positive Z in camera space
        assertTrue(result.p1.z > 0, "Point should be in front of right-looking camera");
    }

    function test_DebugUpCamera() public view {
        // Debug test for up camera
        Camera memory camera = Camera({
            location: Point3D({x: 0, y: 0, z: 0}), lookAt: Point3D({x: 0, y: WAD, z: 0}), fieldOfView: 45 * WAD
        });

        // Test with a point that should be in front of the camera
        Triangle memory triangle = Triangle({
            p1: Point3D({x: 0, y: WAD, z: WAD}),
            p2: Point3D({x: 0, y: WAD, z: WAD}),
            p3: Point3D({x: 0, y: WAD, z: WAD}),
            materialId: 0
        });

        Triangle memory result = renderer.transformTri(triangle, camera);

        // For a camera looking up, a point at (0, 1, 1) should have positive Z in camera space
        assertTrue(result.p1.z > 0, "Point should be in front of up-looking camera");
    }
}
