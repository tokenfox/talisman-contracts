// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TalismanCore} from "./TalismanCore.sol";
import {TalismanForms} from "./TalismanForms.sol";
import {TalismanMaterials} from "./TalismanMaterials.sol";
import {
    MaterialsNotSet,
    NotRevealed,
    BondTokenNotRevealed,
    BondRequiresMatchedCores,
    BondRequiresOppositePoles,
    TokenNotCleavable,
    CutRejectsMythic,
    TokenNotCuttable,
    InvalidCutIndex,
    MergeRejectsMythic,
    MergeRequiresSameKind,
    MergeExceedsTier
} from "./TalismanErrors.sol";

/// @title TalismanTransformationLib
/// @dev The shared, side-effect-free algebra behind the four transformations
///      (bond / cleave / cut / merge). Both the mutating ops in {Talismans}
///      and the read-only `simulate*` previews in {TalismanTransformationSimulator}
///      call into THESE `internal` functions - they inline into each caller,
///      so the two contracts compute (and revert on) the exact same logic.
///      That shared source of truth is what makes preview/execution drift
///      impossible.
///
///      Every function is `pure`/`view` and never touches storage of the
///      caller; ids and supply are mutated only by {Talismans}. Core caps are
///      passed in (not hardcoded) so the library stays policy-agnostic.
library TalismanTransformationLib {
    /// @dev Pole purity of a token's cores. A token is `Lithic`/`Lumic` only
    ///      when *every* core shares that essence; any cross-pole token is a
    ///      `Mythic` (the synthesis of both poles) and cannot be a bond input.
    enum Pole {
        Lithic,
        Lumic,
        Mythic
    }

    // --- primitives -----------------------------------------------------------

    /// @dev Canonical key for an ordered core sequence. `abi.encodePacked`
    ///      keeps order significant - `[A,B]` and `[B,A]` hash differently.
    function coreKey(uint256[] memory cores) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(cores));
    }

    /// @dev Concatenate two cores arrays (`a` first, then `b`). Order matters.
    function concat(uint256[] memory a, uint256[] memory b) internal pure returns (uint256[] memory out) {
        uint256 al = a.length;
        uint256 bl = b.length;
        out = new uint256[](al + bl);
        for (uint256 i; i < al; ++i) {
            out[i] = a[i];
        }
        for (uint256 i; i < bl; ++i) {
            out[al + i] = b[i];
        }
    }

    // --- derivations ----------------------------------------------------------

    /// @dev Mode of the cores' forms; ties resolve to the later (higher-index)
    ///      core. Iterating ascending with `>=` lets a later form with an equal
    ///      count overwrite an earlier one. O(n^2), but n <= MAX_CORES_PER_TOKEN.
    function deriveShapeForm(uint256[] memory cores) internal pure returns (TalismanForms.ShapeForm) {
        uint256 len = cores.length;
        TalismanForms.ShapeForm best = TalismanCore.shapeForm(cores[0]);
        uint256 bestCount;
        for (uint256 i; i < len; ++i) {
            TalismanForms.ShapeForm candidate = TalismanCore.shapeForm(cores[i]);
            uint256 count;
            for (uint256 j; j < len; ++j) {
                if (TalismanCore.shapeForm(cores[j]) == candidate) {
                    ++count;
                }
            }
            if (count >= bestCount) {
                bestCount = count;
                best = candidate;
            }
        }
        return best;
    }

    /// @dev XOR of the cores' seeds with duplicates dropped - only the first
    ///      occurrence of each distinct seed contributes, so even-count
    ///      duplicates don't cancel out. O(n^2), n <= MAX_CORES_PER_TOKEN.
    function deriveSeed(uint256[] memory cores) internal pure returns (uint16) {
        uint256 len = cores.length;
        uint16 acc;
        for (uint256 i; i < len; ++i) {
            uint16 s = TalismanCore.seed(cores[i]);
            bool dup;
            for (uint256 j; j < i; ++j) {
                if (TalismanCore.seed(cores[j]) == s) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                acc ^= s;
            }
        }
        return acc;
    }

    /// @dev Pole purity of a cores array: {Pole.Lithic} or {Pole.Lumic} when
    ///      every core shares that essence, else {Pole.Mythic}. Requires
    ///      `mats` to be set; reverts {MaterialsNotSet} otherwise.
    function poleOf(TalismanMaterials mats, uint256[] memory cores) internal view returns (Pole) {
        if (address(mats) == address(0)) {
            revert MaterialsNotSet();
        }
        bool hasLithic;
        bool hasLumic;
        uint256 len = cores.length;
        for (uint256 i; i < len; ++i) {
            (TalismanMaterials.Essence essence,) = mats.elementOf(TalismanCore.materialId(cores[i]));
            if (essence == TalismanMaterials.Essence.Lithic) {
                hasLithic = true;
            } else if (essence == TalismanMaterials.Essence.Lumic) {
                hasLumic = true;
            } else {
                hasLithic = true;
                hasLumic = true;
            }
        }
        if (hasLithic && hasLumic) {
            return Pole.Mythic;
        }
        return hasLithic ? Pole.Lithic : Pole.Lumic;
    }

    /// @dev Synthesise a token's material from its cores' element signatures.
    ///      Each core contributes its material's 4-bit element bitmask. The
    ///      masks are folded left: a mask equal to the running accumulator is
    ///      kept as-is - so identical cores never XOR-cancel and a single-
    ///      material token keeps its material at any core count - otherwise it
    ///      is XOR-blended. Essence resolves to Mythic when the cores span both
    ///      poles; otherwise it is the shared essence. Requires `mats` to be
    ///      set; reverts {MaterialsNotSet} otherwise.
    function deriveMaterialId(TalismanMaterials mats, uint256[] memory cores) internal view returns (uint8) {
        if (address(mats) == address(0)) {
            revert MaterialsNotSet();
        }

        bool hasLithic;
        bool hasLumic;
        bool hasMythic;
        uint8 acc;
        uint256 len = cores.length;
        for (uint256 i; i < len; ++i) {
            (TalismanMaterials.Essence essence, uint8 mask) = mats.elementOf(TalismanCore.materialId(cores[i]));
            if (essence == TalismanMaterials.Essence.Lithic) {
                hasLithic = true;
            } else if (essence == TalismanMaterials.Essence.Lumic) {
                hasLumic = true;
            } else {
                hasMythic = true;
            }
            if (i == 0) {
                acc = mask;
            } else if (mask != acc) {
                acc ^= mask;
            }
        }

        TalismanMaterials.Essence outEssence = (hasMythic || (hasLithic && hasLumic))
            ? TalismanMaterials.Essence.Mythic
            : (hasLithic ? TalismanMaterials.Essence.Lithic : TalismanMaterials.Essence.Lumic);

        return mats.materialIdFromSignature(outEssence, acc);
    }

    // --- op guards ------------------------------------------------------------

    /// @dev Shared bond guard. Reverts unless both tokens are revealed, hold
    ///      equal core counts, and sit on opposite poles. A Mythic is
    ///      {Pole.Mythic} (spans both poles) and so can never be a bond input.
    function requireBondable(
        TalismanMaterials mats,
        uint256 idA,
        uint256 idB,
        uint256[] memory coresA,
        uint256[] memory coresB
    ) internal view {
        uint256 keepLen = coresA.length;
        uint256 mergedLen = coresB.length;
        if (keepLen == 0) {
            revert BondTokenNotRevealed(idA);
        }
        if (mergedLen == 0) {
            revert BondTokenNotRevealed(idB);
        }
        if (keepLen != mergedLen) {
            revert BondRequiresMatchedCores(keepLen, mergedLen);
        }
        Pole keepPole = poleOf(mats, coresA);
        Pole mergedPole = poleOf(mats, coresB);
        bool opposite = (keepPole == Pole.Lithic && mergedPole == Pole.Lumic)
            || (keepPole == Pole.Lumic && mergedPole == Pole.Lithic);
        if (!opposite) {
            revert BondRequiresOppositePoles(idA, idB);
        }
    }

    // --- op computations ------------------------------------------------------
    // Each helper runs the EXACT validation of its mutating op (reverting the
    // same errors) and returns the output core array(s). {Talismans} calls them
    // before resolving ids/minting; the simulator calls them before predicting
    // ids. Identical inputs => identical reverts and identical outputs.

    /// @dev bond: assert bondable, cap the combined count, return concat(a,b).
    function bondCores(
        TalismanMaterials mats,
        uint256 a,
        uint256 b,
        uint256[] memory coresA,
        uint256[] memory coresB,
        uint256 maxCoresPerToken
    ) internal view returns (uint256[] memory combined) {
        requireBondable(mats, a, b, coresA, coresB);
        combined = concat(coresA, coresB);
        assert(combined.length <= maxCoresPerToken);
    }

    /// @dev cleave: require {Pole.Mythic}, split by pole in encounter order.
    ///      Reverts {TokenNotCleavable} on any non-Lithic/non-Lumic core (the
    ///      self-enforcing guard).
    function cleaveCores(TalismanMaterials mats, uint256 tokenId, uint256[] memory cores)
        internal
        view
        returns (uint256[] memory lithic, uint256[] memory lumic)
    {
        if (poleOf(mats, cores) != Pole.Mythic) {
            revert TokenNotCleavable(tokenId);
        }
        uint256 len = cores.length;
        uint256 lithicCount;
        for (uint256 i; i < len; ++i) {
            (TalismanMaterials.Essence e,) = mats.elementOf(TalismanCore.materialId(cores[i]));
            if (e == TalismanMaterials.Essence.Lithic) {
                ++lithicCount;
            }
        }
        lithic = new uint256[](lithicCount);
        lumic = new uint256[](len - lithicCount);
        uint256 li;
        uint256 ui;
        for (uint256 i; i < len; ++i) {
            (TalismanMaterials.Essence e,) = mats.elementOf(TalismanCore.materialId(cores[i]));
            if (e == TalismanMaterials.Essence.Lithic) {
                lithic[li++] = cores[i];
            } else if (e == TalismanMaterials.Essence.Lumic) {
                lumic[ui++] = cores[i];
            } else {
                revert TokenNotCleavable(tokenId);
            }
        }
    }

    /// @dev cut: require revealed, reject Mythic, require homogeneous (same
    ///      material AND form), then `1 <= index < len`. Splits into head
    ///      `[0,index)` and tail `[index,len)`. Takes `mats` only for the
    ///      explicit Mythic check.
    function cutCores(TalismanMaterials mats, uint256 tokenId, uint256 index, uint256[] memory cores)
        internal
        view
        returns (uint256[] memory head, uint256[] memory tail)
    {
        uint256 len = cores.length;
        if (len == 0) {
            revert NotRevealed(tokenId);
        }
        // Mythics are heterogeneous (two materials); reject them with a clearer
        // error before the general homogeneity check would catch them anyway.
        if (poleOf(mats, cores) == Pole.Mythic) {
            revert CutRejectsMythic(tokenId);
        }
        uint8 mat0 = TalismanCore.materialId(cores[0]);
        TalismanForms.ShapeForm form0 = TalismanCore.shapeForm(cores[0]);
        for (uint256 i = 1; i < len; ++i) {
            if (TalismanCore.materialId(cores[i]) != mat0 || TalismanCore.shapeForm(cores[i]) != form0) {
                revert TokenNotCuttable(tokenId);
            }
        }
        if (index < 1 || index >= len) {
            revert InvalidCutIndex(index, len);
        }
        head = new uint256[](index);
        tail = new uint256[](len - index);
        for (uint256 i; i < index; ++i) {
            head[i] = cores[i];
        }
        for (uint256 i = index; i < len; ++i) {
            tail[i - index] = cores[i];
        }
    }

    /// @dev merge: both revealed, reject Mythic on each, strict same-kind gate
    ///      (derived material AND form), total within the pure-tier cap, return
    ///      concat(a,b).
    function mergeCores(
        TalismanMaterials mats,
        uint256 a,
        uint256 b,
        uint256[] memory coresA,
        uint256[] memory coresB,
        uint256 maxCoresPerMint
    ) internal view returns (uint256[] memory combined) {
        if (coresA.length == 0) {
            revert NotRevealed(a);
        }
        if (coresB.length == 0) {
            revert NotRevealed(b);
        }
        if (poleOf(mats, coresA) == Pole.Mythic) {
            revert MergeRejectsMythic(a);
        }
        if (poleOf(mats, coresB) == Pole.Mythic) {
            revert MergeRejectsMythic(b);
        }
        // Strict kind gate: same derived material and form. For homogeneous
        // non-Mythic tokens the derived material equals the per-core material.
        if (
            deriveMaterialId(mats, coresA) != deriveMaterialId(mats, coresB)
                || deriveShapeForm(coresA) != deriveShapeForm(coresB)
        ) {
            revert MergeRequiresSameKind(a, b);
        }
        uint256 total = coresA.length + coresB.length;
        if (total > maxCoresPerMint) {
            revert MergeExceedsTier(total);
        }
        combined = concat(coresA, coresB);
    }
}
