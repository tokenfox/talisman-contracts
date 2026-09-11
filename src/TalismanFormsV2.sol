// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Point3D, Triangle} from "./TalismanStructs.sol";
import {TalismanForms} from "./TalismanForms.sol";

/// @title TalismanFormsV2
/// @dev Triangulator for the brilliant-cut topology. Each band is emitted with a
///      winding fixed by the ring indices rather than computed per face, so
///      adjacent faces traverse every shared edge in opposite directions and the
///      mesh is a closed, consistently outward-wound surface for every form,
///      tier, and seed - no front-facing face is ever culled, and the exported
///      solid is watertight. Base layouts, perturbation, and the size boost live
///      in {TalismanForms}; this library carries the triangulation.
library TalismanFormsV2 {
    /// @dev Every form shares the brilliant-cut topology, so every form shares
    ///      one triangulation.
    function triangulateForForm(TalismanForms.ShapeForm form, Point3D[] memory pts, uint256 N)
        internal
        pure
        returns (Triangle[] memory)
    {
        form; // silence unused - every form routes through the brilliant-cut triangulator
        return _triangulate(pts, N);
    }

    // ---- Triangulation (6N - 2 triangles, fixed outward winding) ----

    function _triangulate(Point3D[] memory pts, uint256 N) private pure returns (Triangle[] memory tris) {
        uint256 triCount = 6 * N - 2;
        tris = new Triangle[](triCount);
        uint256 w;
        uint256 culet = 3 * N;

        // Table cap - fan from vertex 0, wound CCW seen from above (+y).
        for (uint256 i = 1; i < N - 1; i++) {
            tris[w] = Triangle({p1: pts[0], p2: pts[i + 1], p3: pts[i], materialId: uint16(w)});
            w++;
        }

        // Table <-> Crown antiprism (crown ring rotated half-segment).
        for (uint256 i = 0; i < N; i++) {
            uint256 tNext = (i + 1) % N;
            uint256 crown = N + i;
            uint256 crownPrev = N + ((i + N - 1) % N);
            tris[w] = Triangle({p1: pts[i], p2: pts[crown], p3: pts[crownPrev], materialId: uint16(w)});
            w++;
            tris[w] = Triangle({p1: pts[i], p2: pts[tNext], p3: pts[crown], materialId: uint16(w)});
            w++;
        }

        // Crown <-> Pavilion aligned quads.
        for (uint256 i = 0; i < N; i++) {
            uint256 crown = N + i;
            uint256 crownNext = N + ((i + 1) % N);
            uint256 pav = 2 * N + i;
            uint256 pavNext = 2 * N + ((i + 1) % N);
            tris[w] = Triangle({p1: pts[crown], p2: pts[pavNext], p3: pts[pav], materialId: uint16(w)});
            w++;
            tris[w] = Triangle({p1: pts[crown], p2: pts[crownNext], p3: pts[pavNext], materialId: uint16(w)});
            w++;
        }

        // Pavilion -> Culet cone.
        for (uint256 i = 0; i < N; i++) {
            uint256 pav = 2 * N + i;
            uint256 pavNext = 2 * N + ((i + 1) % N);
            tris[w] = Triangle({p1: pts[pav], p2: pts[pavNext], p3: pts[culet], materialId: uint16(w)});
            w++;
        }
    }
}
