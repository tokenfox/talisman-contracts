// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Trigonometry} from "solidity-trigonometry/Trigonometry.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibString} from "solady/utils/LibString.sol";
import {
    Camera,
    CullMode,
    FillMode,
    LightSettings,
    Material,
    Point2D,
    Point3D,
    ProjectedTriangle,
    RenderSettings,
    Triangle
} from "./TalismanStructs.sol";

/**
 * @title TalismanSvgRenderer
 * @notice Pure renderer that projects a triangle mesh into a complete SVG image. It transforms
 * each face through the camera, applies per-face Lambert lighting, depth-sorts the faces with the
 * painter's algorithm (farthest first), and emits a 512x512 `<svg>` document on a solid black
 * background. The gem material carries the chromatic identity; the backdrop is a fixed neutral.
 */
contract TalismanSvgRenderer {
    // SVG constants
    int256 constant SVG_WIDTH = 512;
    int256 constant SVG_HEIGHT = 512;

    // Fixed-point arithmetic constants (using 18 decimal places)
    int256 internal constant WAD = 1e18;
    int256 internal constant PI = 3141592653589793238; // pi * 1e18

    /**
     * @notice Renders a triangle mesh as a complete 512x512 SVG document. Faces are transformed
     * through the camera, lit per-face when lighting is enabled, depth-sorted farthest first, and
     * drawn as polygons over a solid black background.
     * @param triangles The mesh faces, each a triangle with a material id.
     * @param camera The viewpoint: location, look-at target, and field of view.
     * @param materials The material palette indexed by each triangle's material id; the color is used as fill.
     * @param settings The render settings: cull mode and fill mode (solid or wireframe).
     * @param light The lighting settings: when enabled, applies Lambert shading folded into each face's color.
     * @return svgString The full SVG document as a string.
     */
    function renderSvg(
        Triangle[] memory triangles,
        Camera memory camera,
        Material[] memory materials,
        RenderSettings memory settings,
        LightSettings memory light
    ) public pure returns (string memory svgString) {
        if (light.enabled) {
            materials = computeLitMaterials(triangles, materials, light);
        }

        ProjectedTriangle[] memory projected = transformSortAndProjectTris(triangles, camera);

        // Start building SVG string. Background is always solid black - the gem material
        // carries the chromatic identity; the backdrop is a fixed neutral.
        svgString = string.concat(
            '<?xml version="1.0" encoding="UTF-8"?>\n',
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ',
            LibString.toString(SVG_WIDTH),
            " ",
            LibString.toString(SVG_HEIGHT),
            '" width="512" height="512">\n',
            '<rect width="',
            LibString.toString(SVG_WIDTH),
            '" ',
            ' height="',
            LibString.toString(SVG_HEIGHT),
            '" fill="#000000"/>\n'
        );

        for (uint256 i = 0; i < projected.length; i++) {
            if (_shouldRenderTriangle(projected[i], settings.cullMode)) {
                svgString = string.concat(svgString, _renderTriangleSvg(projected[i], materials, settings));
            }
        }

        svgString = string.concat(svgString, "</svg>");
    }

    function _renderTriangleSvg(
        ProjectedTriangle memory triangle,
        Material[] memory materials,
        RenderSettings memory settings
    ) internal pure returns (string memory svgString) {
        (int256 x1, int256 y1) = _projectOnSvg(triangle.p1);
        (int256 x2, int256 y2) = _projectOnSvg(triangle.p2);
        (int256 x3, int256 y3) = _projectOnSvg(triangle.p3);

        uint32 materialColor = _getMaterialColor(triangle.materialId, materials);
        uint8 fillMode = settings.fillMode;
        return _svgPolygon(x1, y1, x2, y2, x3, y3, materialColor, fillMode);
    }

    function _getMaterialColor(uint16 materialId, Material[] memory materials) internal pure returns (uint32 color) {
        if (materialId < materials.length) {
            return materials[materialId].color;
        }
        // Default to white (0xFFFFFF) if material not found
        return 0xFFFFFF;
    }

    // Draws a triangle as an SVG polygon with material color
    function _svgPolygon(int256 x1, int256 y1, int256 x2, int256 y2, int256 x3, int256 y3, uint32 color, uint8 fillMode)
        internal
        pure
        returns (string memory)
    {
        string memory colorHex = _uint32ColorToHex(color);
        string memory style;
        if (fillMode == uint8(FillMode.Wireframe)) {
            style = string.concat('fill="none" stroke="#', colorHex, '" stroke-width="1"');
        } else {
            style = string.concat('fill="#', colorHex, '"');
        }
        return string.concat(
            '  <polygon points="',
            LibString.toString(x1),
            ",",
            LibString.toString(y1),
            " ",
            LibString.toString(x2),
            ",",
            LibString.toString(y2),
            " ",
            LibString.toString(x3),
            ",",
            LibString.toString(y3),
            '" ',
            style,
            "/>\n"
        );
    }

    function _uint32ColorToHex(uint32 color) internal pure returns (string memory hexString) {
        bytes memory hexChars = "0123456789ABCDEF";
        bytes memory result = new bytes(6);

        for (uint256 i = 0; i < 6; i++) {
            uint256 nibble = (color >> ((5 - i) * 4)) & 0xF;
            result[i] = hexChars[nibble];
        }

        return string(result);
    }

    /// @notice Transform a triangle mesh into camera space, depth-sort it
    ///         farthest-first (painter's algorithm), and project it to 2D.
    /// @param triangles The world-space mesh.
    /// @param camera The camera the mesh is viewed through.
    /// @return projectedTriangles The depth-sorted, projected 2D triangles.
    function transformSortAndProjectTris(Triangle[] memory triangles, Camera memory camera)
        public
        pure
        returns (ProjectedTriangle[] memory projectedTriangles)
    {
        Triangle[] memory transformedTriangles = transformTris(triangles, camera);

        // Sort triangles by depth (average Z-coordinate, farthest first)
        _sortTrianglesByDepth(transformedTriangles);

        projectedTriangles = projectTris(transformedTriangles, camera);
    }

    function projectTris(Triangle[] memory transformedTriangles, Camera memory camera)
        internal
        pure
        returns (ProjectedTriangle[] memory projectedTriangles)
    {
        projectedTriangles = new ProjectedTriangle[](transformedTriangles.length);
        for (uint256 i = 0; i < transformedTriangles.length; i++) {
            projectedTriangles[i] = ProjectedTriangle({
                p1: projectPoint(transformedTriangles[i].p1, camera.fieldOfView),
                p2: projectPoint(transformedTriangles[i].p2, camera.fieldOfView),
                p3: projectPoint(transformedTriangles[i].p3, camera.fieldOfView),
                materialId: transformedTriangles[i].materialId
            });
        }
    }

    function _sortTrianglesByDepth(Triangle[] memory triangles) internal pure {
        uint256 n = triangles.length;
        if (n <= 1) {
            return;
        }

        // Use insertion sort for simplicity and gas efficiency
        for (uint256 i = 1; i < n; i++) {
            Triangle memory key = triangles[i];
            int256 keyDepth = _getTriangleDepth(key);
            uint256 j = i;

            // Move elements that are closer than key to one position ahead
            while (j > 0 && _getTriangleDepth(triangles[j - 1]) < keyDepth) {
                triangles[j] = triangles[j - 1];
                j--;
            }
            triangles[j] = key;
        }
    }

    function _getTriangleDepth(Triangle memory triangle) internal pure returns (int256 depth) {
        depth = (triangle.p1.z + triangle.p2.z + triangle.p3.z) / 3;
    }

    /// @notice Transform every triangle in `triangles` from world space into the
    ///         space of `camera`.
    /// @param triangles The world-space mesh.
    /// @param camera The camera to transform into.
    /// @return transformedTriangles The mesh in camera space.
    function transformTris(Triangle[] memory triangles, Camera memory camera)
        public
        pure
        returns (Triangle[] memory transformedTriangles)
    {
        uint256 length = triangles.length;
        transformedTriangles = new Triangle[](length);

        for (uint256 i; i < length;) {
            transformedTriangles[i] = transformTri(triangles[i], camera);
            unchecked {
                ++i;
            }
        }
    }

    function projectPoint(Point3D memory point, int256 fieldOfView)
        internal
        pure
        returns (Point2D memory projectedPoint)
    {
        // Convert field of view from degrees to radians
        int256 fovRadians = (fieldOfView * PI) / (180 * WAD);

        // Calculate focal length from field of view: focal_length = 1 / tan(fov/2)
        int256 halfFov = fovRadians / 2;
        int256 tanHalfFov = _tan(halfFov);
        int256 focalLength = (WAD * WAD) / tanHalfFov;

        // Minimum Z distance to avoid division by zero and handle points behind camera
        int256 minZ = WAD / 10; // 0.1 in fixed-point

        // Ensure Z is at least minZ (points behind camera are projected at minZ)
        int256 z = point.z < minZ ? minZ : point.z;

        // Perspective projection: projected = (focal_length * coordinate) / z
        // Aspect ratio is hardcoded to 1:1 for square viewport
        projectedPoint = Point2D({x: (focalLength * point.x) / z, y: (focalLength * point.y) / z});
    }

    function _cos(int256 x) internal pure returns (int256) {
        // Normalize negative values to positive by adding 2*PI until positive
        if (x < 0) {
            x += 2 * int256(PI) * ((-x - 1) / (2 * int256(PI)) + 1);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return Trigonometry.cos(uint256(x));
    }

    function _sin(int256 x) internal pure returns (int256) {
        // Normalize negative values to positive by adding 2*PI until positive
        if (x < 0) {
            x += 2 * int256(PI) * ((-x - 1) / (2 * int256(PI)) + 1);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return Trigonometry.sin(uint256(x));
    }

    function _tan(int256 x) internal pure returns (int256) {
        // tan(x) = sin(x) / cos(x)
        int256 sinX = _sin(x);
        int256 cosX = _cos(x);

        // Avoid division by zero
        if (cosX == 0) {
            return type(int256).max; // Return max value for undefined tan
        }

        return FixedPointMathLib.sDivWad(sinX, cosX);
    }

    function _projectOnSvg(Point2D memory p) internal pure returns (int256 x, int256 y) {
        x = SVG_WIDTH / 2 + p.x / (WAD / (SVG_WIDTH / 2));
        // Remove Y-axis flipping to match Three.js right-handed coordinates
        y = SVG_HEIGHT / 2 - p.y / (WAD / (SVG_HEIGHT / 2));
    }

    function _shouldRenderTriangle(ProjectedTriangle memory triangle, uint8 cullMode) internal pure returns (bool) {
        if (cullMode == uint8(CullMode.None)) {
            return true;
        }

        // Calculate winding order (2D cross product)
        // Positive winding = counter-clockwise = front-facing
        // Negative winding = clockwise = back-facing
        int256 winding = (triangle.p2.x - triangle.p1.x) * (triangle.p3.y - triangle.p1.y)
            - (triangle.p2.y - triangle.p1.y) * (triangle.p3.x - triangle.p1.x);

        if (cullMode == uint8(CullMode.Front)) {
            // Cull front-facing triangles (positive winding)
            return winding <= 0;
        } else if (cullMode == uint8(CullMode.Back)) {
            // Cull back-facing triangles (negative winding)
            return winding >= 0;
        }

        return true;
    }

    /// @notice Transform a single triangle from world space into the space of
    ///         `camera`.
    /// @param triangle The world-space triangle.
    /// @param camera The camera to transform into.
    /// @return transformedTriangle The triangle in camera space.
    function transformTri(Triangle memory triangle, Camera memory camera)
        public
        pure
        returns (Triangle memory transformedTriangle)
    {
        // Translate triangle relative to camera location
        Triangle memory translated = Triangle({
            p1: Point3D({
                x: triangle.p1.x - camera.location.x,
                y: triangle.p1.y - camera.location.y,
                z: triangle.p1.z - camera.location.z
            }),
            p2: Point3D({
                x: triangle.p2.x - camera.location.x,
                y: triangle.p2.y - camera.location.y,
                z: triangle.p2.z - camera.location.z
            }),
            p3: Point3D({
                x: triangle.p3.x - camera.location.x,
                y: triangle.p3.y - camera.location.y,
                z: triangle.p3.z - camera.location.z
            }),
            materialId: triangle.materialId
        });

        // Compute lookAt matrix
        Point3D memory f = normalize(
            Point3D({
                x: camera.lookAt.x - camera.location.x,
                y: camera.lookAt.y - camera.location.y,
                z: camera.lookAt.z - camera.location.z
            })
        );
        Point3D memory up = Point3D({x: 0, y: 1e18, z: 0});
        Point3D memory r = normalize(cross(up, f));
        Point3D memory u = cross(f, r);

        // Apply lookAt rotation to each point
        transformedTriangle.p1 = applyLookAt(translated.p1, r, u, f);
        transformedTriangle.p2 = applyLookAt(translated.p2, r, u, f);
        transformedTriangle.p3 = applyLookAt(translated.p3, r, u, f);
        transformedTriangle.materialId = translated.materialId;
    }

    function applyLookAt(Point3D memory p, Point3D memory r, Point3D memory u, Point3D memory f)
        internal
        pure
        returns (Point3D memory rotatedPoint)
    {
        // 3x3 matrix multiply (row-major)
        rotatedPoint.x = (p.x * r.x + p.y * r.y + p.z * r.z) / 1e18;
        rotatedPoint.y = (p.x * u.x + p.y * u.y + p.z * u.z) / 1e18;
        rotatedPoint.z = (p.x * f.x + p.y * f.y + p.z * f.z) / 1e18;

        // Flip X to match SVG/Three.js handedness if needed
        rotatedPoint.x = -rotatedPoint.x;
    }

    /// @notice The unit vector pointing the same direction as `v`, or the zero
    ///         vector when `v` has zero length.
    /// @param v The vector to normalize.
    /// @return nv The normalized vector.
    function normalize(Point3D memory v) public pure returns (Point3D memory nv) {
        int256 len = int256(FixedPointMathLib.sqrt(uint256(v.x * v.x + v.y * v.y + v.z * v.z)));
        if (len == 0) {
            nv = Point3D({x: 0, y: 0, z: 0});
        } else {
            nv = Point3D({x: (v.x * 1e18) / len, y: (v.y * 1e18) / len, z: (v.z * 1e18) / len});
        }
    }

    function cross(Point3D memory a, Point3D memory b) internal pure returns (Point3D memory c) {
        c.x = (a.y * b.z - a.z * b.y) / 1e18;
        c.y = (a.z * b.x - a.x * b.z) / 1e18;
        c.z = (a.x * b.y - a.y * b.x) / 1e18;
    }

    function _dotProduct(Point3D memory a, Point3D memory b) internal pure returns (int256) {
        return (a.x * b.x + a.y * b.y + a.z * b.z) / WAD;
    }

    function _computeFaceNormal(Triangle memory tri) internal pure returns (Point3D memory n) {
        Point3D memory e1 = Point3D({x: tri.p2.x - tri.p1.x, y: tri.p2.y - tri.p1.y, z: tri.p2.z - tri.p1.z});
        Point3D memory e2 = Point3D({x: tri.p3.x - tri.p1.x, y: tri.p3.y - tri.p1.y, z: tri.p3.z - tri.p1.z});
        n = normalize(cross(e1, e2));
    }

    function _orientNormalOutward(Point3D memory normal, Triangle memory tri, Point3D memory meshCenter)
        internal
        pure
        returns (Point3D memory)
    {
        Point3D memory centroid = Point3D({
            x: (tri.p1.x + tri.p2.x + tri.p3.x) / 3,
            y: (tri.p1.y + tri.p2.y + tri.p3.y) / 3,
            z: (tri.p1.z + tri.p2.z + tri.p3.z) / 3
        });
        Point3D memory toOutward =
            Point3D({x: centroid.x - meshCenter.x, y: centroid.y - meshCenter.y, z: centroid.z - meshCenter.z});
        if (_dotProduct(normal, toOutward) < 0) {
            normal.x = -normal.x;
            normal.y = -normal.y;
            normal.z = -normal.z;
        }
        return normal;
    }

    function _applyBrightness(uint32 color, int256 brightness) internal pure returns (uint32) {
        uint256 r = (color >> 16) & 0xFF;
        uint256 g = (color >> 8) & 0xFF;
        uint256 b = color & 0xFF;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 wad = brightness > 0 ? uint256(brightness) : 0;
        if (wad > 1e18) {
            wad = 1e18;
        }
        r = (r * wad) / 1e18;
        g = (g * wad) / 1e18;
        b = (b * wad) / 1e18;
        if (r > 255) {
            r = 255;
        }
        if (g > 255) {
            g = 255;
        }
        if (b > 255) {
            b = 255;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32((r << 16) | (g << 8) | b);
    }

    /// @dev brightness = emissive + reflectance * (ambient + (1-ambient) * NdotL).
    ///      reflectance == 0 means "no Lambert response, base color is emissive-only";
    ///      callers must set both fields explicitly (no implicit defaults).
    function _brightness(LightSettings memory light, int256 dot) internal pure returns (int256) {
        int256 lambert = light.ambient + (dot * (WAD - light.ambient)) / WAD;
        return light.emissive + (light.reflectance * lambert) / WAD;
    }

    /// @notice Bake per-face Lambert lighting into a copy of `materials`, so each
    ///         triangle carries its lit color. Returns the materials unchanged
    ///         when `light` is disabled.
    /// @param triangles The mesh whose face normals drive the shading.
    /// @param materials The per-face base materials.
    /// @param light The light direction and coefficients to apply.
    /// @return litMaterials The materials with lit per-face colors.
    function computeLitMaterials(Triangle[] memory triangles, Material[] memory materials, LightSettings memory light)
        public
        pure
        returns (Material[] memory litMaterials)
    {
        uint256 n = triangles.length;
        litMaterials = new Material[](n);
        Point3D memory lightDir = normalize(light.direction);
        for (uint256 i = 0; i < n; i++) {
            Point3D memory normal = _computeFaceNormal(triangles[i]);
            if (light.orientOutward) {
                normal = _orientNormalOutward(normal, triangles[i], light.meshCenter);
            }
            int256 dot = -_dotProduct(normal, lightDir);
            if (dot <= 0 && light.orientOutward) {
                Point3D memory centroid = Point3D({
                    x: (triangles[i].p1.x + triangles[i].p2.x + triangles[i].p3.x) / 3,
                    y: (triangles[i].p1.y + triangles[i].p2.y + triangles[i].p3.y) / 3,
                    z: (triangles[i].p1.z + triangles[i].p2.z + triangles[i].p3.z) / 3
                });
                Point3D memory toFace = Point3D({
                    x: centroid.x - light.meshCenter.x,
                    y: centroid.y - light.meshCenter.y,
                    z: centroid.z - light.meshCenter.z
                });
                int256 lenSq = toFace.x * toFace.x + toFace.y * toFace.y + toFace.z * toFace.z;
                if (lenSq > 0) {
                    Point3D memory faceDir = normalize(toFace);
                    dot = -_dotProduct(faceDir, lightDir);
                }
            }
            if (dot < 0) {
                dot = 0;
            }
            uint16 materialId = triangles[i].materialId;
            uint32 baseColor = materialId < materials.length ? materials[materialId].color : 0xFFFFFF;
            litMaterials[i] = Material({color: _applyBrightness(baseColor, _brightness(light, dot))});
            // forge-lint: disable-next-line(unsafe-typecast)
            triangles[i].materialId = uint16(i);
        }
    }
}
