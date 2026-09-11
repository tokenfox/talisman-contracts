// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

enum FillMode {
    Wireframe,
    Solid
}

enum CullMode {
    None,
    Back,
    Front
}

struct RenderSettings {
    uint8 fillMode;
    uint8 cullMode;
}

struct Material {
    uint32 color;
}

struct Point3D {
    int256 x;
    int256 y;
    int256 z;
}

struct Point2D {
    int256 x;
    int256 y;
}

struct Triangle {
    Point3D p1;
    Point3D p2;
    Point3D p3;
    uint16 materialId;
}

struct ProjectedTriangle {
    Point2D p1;
    Point2D p2;
    Point2D p3;
    uint16 materialId;
}

struct Camera {
    Point3D location;
    Point3D lookAt;
    int256 fieldOfView; // field of view in degrees (fixed-point)
}

struct LightSettings {
    bool enabled;
    Point3D direction; // world-space direction the light points toward (normalized inside computeLitMaterials)
    int256 ambient; // fixed-point WAD, e.g. 0.15e18
    // When true, computeLitMaterials re-orients each face normal outward from `meshCenter` and, for
    // faces whose normal points away from the light, falls back to the centroid-from-center direction
    // as a smoothed normal. When false the raw per-face normal is used as-is and `meshCenter` is ignored.
    // This is an explicit flag rather than a `meshCenter != 0` test: the mesh is legitimately centered at
    // the origin, so the zero vector is a valid center and cannot double as an "off" sentinel.
    bool orientOutward;
    Point3D meshCenter; // object center used to orient face normals outward when `orientOutward` is set
    // Per-light lighting tuning (sourced from the per-token material). Identical math used by
    // SVG bake, Lite HTML JS shader, and the Three.js HTML setup, so all
    // three renderers produce the same final color:
    //
    //     brightness = emissive + reflectance * (ambient + (1 - ambient) * NdotL)
    //     finalRGB   = baseColor * brightness   // clamped 0..1
    //
    // reflectance == 1e18, emissive == 0 reproduces the legacy
    // ambient + (1-ambient)*NdotL behavior. reflectance == 0 with
    // emissive > 0 disables Lambert entirely and renders the material
    // as a flat self-glowing color
    int256 reflectance; // fixed-point WAD; 1e18 = full Lambert response, 0 = none
    int256 emissive; // fixed-point WAD; 1e18 = full self-glow at base color
}
