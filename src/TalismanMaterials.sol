// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Total number of materials defined in TalismanMaterials.getMaterial.
uint8 constant MATERIAL_COUNT = 48;

// Size of the leading non-mythic id range. Core generation in Talismans
// draws uniformly from [0, NON_MYTHIC_MATERIAL_COUNT); mythic ids
// [NON_MYTHIC_MATERIAL_COUNT, MATERIAL_COUNT) are reserved for non-core mechanics.
uint8 constant NON_MYTHIC_MATERIAL_COUNT = 32;

/// @title TalismanMaterials
/// @notice Single source of truth for every material in the collection. Each
///         material carries its colors, chroma, lighting, name, primary-color
///         bucket, and element-grid signature - the full identity of one
///         material. Deployed standalone so downstream consumers reach the table
///         via an external call rather than inlining the full 48-material switch.
/// @dev Tweaking any facet of a material is a one-branch edit in
///      `getMaterial(id)`. Per-material lore is kept off chain, not in this table.
contract TalismanMaterials {
    /// @notice Thrown when no material matches the requested essence and element
    ///         bitmask.
    error NoMaterialForSignature(Essence essence, uint8 bitmask);

    // ---- Fixed-point ----

    uint256 private constant WAD_UINT = 1e18;
    int256 private constant DEFAULT_AMBIENT = 25e16;

    /// @dev Raised ambient floor for the dark-shade Lithic materials. Lithic is the
    ///      non-luminous stone essence, so a facet that grazes the single light
    ///      collapses to the ambient term - and for these materials the darkest
    ///      color stop, at the default 0.25 floor, lands near-black against the
    ///      black backdrop. Lifting the floor keeps the worst facet legible. Lumic
    ///      and Mythic are self-luminous, so their deep stops are intentional and
    ///      stay at DEFAULT_AMBIENT.
    int256 private constant DARK_LITHIC_AMBIENT = 33e16;

    // ---- Enums ----

    /// @notice Coarse categorization of a material's color grammar:
    ///         Monochromatic = single hue across all stops; Polychromatic =
    ///         gemstone identity that reads as a multi-stop gem; Variegated =
    ///         natural-phenomenon gradient (sky, sea, biome) whose stops traverse
    ///         distinct hues.
    enum Chroma {
        Monochromatic,
        Polychromatic,
        Variegated
    }

    /// @notice Top of the material taxonomy - the essence-class of a material:
    ///         Lithic = matter, touchable (Lith x Crys); Lumic = event, observed
    ///         (Lume x Vita); Mythic = invented, not natural (Logos x Mythos).
    enum Essence {
        Lithic,
        Lumic,
        Mythic
    }

    // ---- Material table ----

    /// @notice Full per-material record. All facets of a material live in one
    ///         struct so downstream consumers pull from a single declarative
    ///         source.
    struct Material {
        string name;
        string colorBucket;
        uint32[8] colors;
        Chroma chroma;
        int256 reflectance;
        int256 emissive;
        int256 ambient;
        Essence essence;
        bytes4 elementSig;
    }

    // ---- Public accessors ----

    /// @notice The total number of materials in the collection.
    /// @return The material count; valid ids run from 0 to this value minus one.
    function materialCount() external pure returns (uint8) {
        return MATERIAL_COUNT;
    }

    /// @notice The display name of material `id`.
    /// @param id The material id.
    /// @return The material's name.
    function materialName(uint8 id) external pure returns (string memory) {
        return getMaterial(id).name;
    }

    /// @notice The primary-color bucket of material `id`.
    /// @param id The material id.
    /// @return The bucket label (e.g. "red", "cyan", "gray").
    function materialColorBucket(uint8 id) external pure returns (string memory) {
        return getMaterial(id).colorBucket;
    }

    /// @notice The eight ordered color stops of material `id`.
    /// @param id The material id.
    /// @return The eight stops as packed 0xRRGGBB values, top to bottom.
    function materialColors(uint8 id) external pure returns (uint32[8] memory) {
        return getMaterial(id).colors;
    }

    /// @notice The lighting coefficients of material `id`, as WAD fixed-point.
    /// @param id The material id.
    /// @return reflectance How strongly the surface returns directional light.
    /// @return emissive The material's self-illumination, independent of lighting.
    /// @return ambient The floor brightness applied where no directional light reaches.
    /// @dev Every renderer composes these with the same formula:
    ///
    ///          brightness = emissive + reflectance * (ambient + (1 - ambient) * NdotL)
    ///          finalRGB   = baseColor * brightness
    function materialLighting(uint8 id) external pure returns (int256 reflectance, int256 emissive, int256 ambient) {
        Material memory m = getMaterial(id);
        return (m.reflectance, m.emissive, m.ambient);
    }

    /// @notice The display name of a chroma class.
    /// @param c The chroma class.
    /// @return "Monochromatic", "Polychromatic", or "Variegated".
    function chromaName(Chroma c) external pure returns (string memory) {
        if (c == Chroma.Monochromatic) {
            return "Monochromatic";
        }
        if (c == Chroma.Polychromatic) {
            return "Polychromatic";
        }
        return "Variegated";
    }

    /// @notice The display name of an essence class.
    /// @param e The essence class.
    /// @return "Lithic", "Lumic", or "Mythic".
    function essenceName(Essence e) external pure returns (string memory) {
        if (e == Essence.Lithic) {
            return "Lithic";
        }
        if (e == Essence.Lumic) {
            return "Lumic";
        }
        return "Mythic";
    }

    // ---- Element signature bitmask ----

    /// @notice The 4-bit element bitmask of material `id`, derived from its
    ///         element-grid signature.
    /// @param id The material id.
    /// @return The element bitmask, in range 0..15.
    /// @dev One bit per signature position, leftmost char = MSB. The
    ///      "alternate-pole" letter of each essence family maps to 1, the
    ///      "base-pole" letter to 0: Lithic C=1/L=0, Lumic M=1/V=0, Mythic
    ///      Y=1/G=0. Within a family the 16 materials cover every mask 0..15
    ///      bijectively, so {materialIdFromSignature} can invert this.
    function elementBitmask(uint8 id) external pure returns (uint8) {
        return _sigToBitmask(getMaterial(id).elementSig);
    }

    /// @notice The essence and element bitmask of material `id` in a single read
    /// - the pair a synthesiser needs to fold cores and invert the result.
    /// @param id The material id.
    /// @return essence The material's essence class.
    /// @return bitmask The material's element bitmask, in range 0..15.
    function elementOf(uint8 id) external pure returns (Essence essence, uint8 bitmask) {
        Material memory m = getMaterial(id);
        return (m.essence, _sigToBitmask(m.elementSig));
    }

    /// @notice The unique material whose essence and element bitmask match
    ///         `(essence, bitmask)` - the inverse of {elementBitmask}. Reverts
    ///         {NoMaterialForSignature} if none exists.
    /// @param essence The essence class to match.
    /// @param bitmask The element bitmask to match.
    /// @return The matching material id.
    /// @dev A miss is only possible for an out-of-range `bitmask`; the in-range
    ///      grids are fully populated.
    function materialIdFromSignature(Essence essence, uint8 bitmask) external pure returns (uint8) {
        for (uint8 id; id < MATERIAL_COUNT; ++id) {
            Material memory m = getMaterial(id);
            if (m.essence == essence && _sigToBitmask(m.elementSig) == bitmask) {
                return id;
            }
        }
        revert NoMaterialForSignature(essence, bitmask);
    }

    /// @dev Maps a 4-char `elementSig` to its 4-bit mask. C/M/Y -> 1, L/V/G -> 0.
    function _sigToBitmask(bytes4 sig) private pure returns (uint8 mask) {
        for (uint256 j; j < 4; ++j) {
            bytes1 c = sig[j];
            if (c == bytes1("C") || c == bytes1("M") || c == bytes1("Y")) {
                mask |= uint8(1 << (3 - j));
            }
        }
    }

    // ---- Color helpers ----

    /// @dev Expands a (top, mid, bot) anchor triple into the 8-stop ordered ramp used
    ///      by Monochromatic and Polychromatic materials.
    function _r3(uint32 top, uint32 mid, uint32 bot) private pure returns (uint32[8] memory c) {
        c[0] = top;
        c[1] = _lerpColor(top, mid, WAD_UINT / 3);
        c[2] = _lerpColor(top, mid, (WAD_UINT * 2) / 3);
        c[3] = mid;
        c[4] = _lerpColor(mid, bot, WAD_UINT / 4);
        c[5] = _lerpColor(mid, bot, (WAD_UINT * 2) / 4);
        c[6] = _lerpColor(mid, bot, (WAD_UINT * 3) / 4);
        c[7] = bot;
    }

    /// @dev Variegated regional pool - eight explicit hand-authored stops.
    function _v8(uint32 c0, uint32 c1, uint32 c2, uint32 c3, uint32 c4, uint32 c5, uint32 c6, uint32 c7)
        private
        pure
        returns (uint32[8] memory r)
    {
        r[0] = c0;
        r[1] = c1;
        r[2] = c2;
        r[3] = c3;
        r[4] = c4;
        r[5] = c5;
        r[6] = c6;
        r[7] = c7;
    }

    function _lerpColor(uint32 a, uint32 b, uint256 tWad) private pure returns (uint32) {
        uint256 r = _lerp((a >> 16) & 0xFF, (b >> 16) & 0xFF, tWad);
        uint256 g = _lerp((a >> 8) & 0xFF, (b >> 8) & 0xFF, tWad);
        uint256 bl = _lerp(a & 0xFF, b & 0xFF, tWad);
        return uint32((r << 16) | (g << 8) | bl);
    }

    function _lerp(uint256 a, uint256 b, uint256 tWad) private pure returns (uint256) {
        if (tWad > WAD_UINT) {
            tWad = WAD_UINT;
        }
        if (b >= a) {
            return a + ((b - a) * tWad) / WAD_UINT;
        }
        return a - ((a - b) * tWad) / WAD_UINT;
    }

    // ---- Single source of truth ----

    /// @notice The full material record for `id` - name, color bucket, color
    ///         stops, chroma, lighting, essence, and element-grid signature.
    /// @param id The material id.
    /// @return The material's complete record.
    /// @dev One branch per material; every facet of a material lives in one place.
    function getMaterial(uint8 id) public pure returns (Material memory) {
        if (id == 0) {
            return Material({
                name: "Aurora",
                colorBucket: "cyan",
                colors: _v8(0xC8FCE0, 0xA0F2C8, 0x83E9B4, 0x5FE198, 0x3FD688, 0x4DA8B0, 0x4A60A6, 0x2A2D6E),
                chroma: Chroma.Variegated,
                reflectance: 95e16,
                emissive: 6e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "MMMM"
            });
        }
        if (id == 1) {
            return Material({
                name: "Foxfire",
                colorBucket: "red",
                colors: _v8(0xFF7305, 0xFF7305, 0xFF7305, 0xFF7305, 0xFF7305, 0xFF7305, 0xFF7305, 0xFF7305),
                chroma: Chroma.Monochromatic,
                reflectance: 1e18,
                emissive: 10e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "LCLC"
            });
        }
        if (id == 2) {
            return Material({
                name: "Pulsarlike",
                colorBucket: "purple",
                colors: _v8(0xFFE0F8, 0xFF98D8, 0xFF58C0, 0xE848B8, 0xC838D0, 0xA040E0, 0x7848C8, 0x3A2068),
                chroma: Chroma.Variegated,
                reflectance: 95e16,
                emissive: 12e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "MMVV"
            });
        }
        if (id == 3) {
            return Material({
                name: "Amethyst",
                colorBucket: "purple",
                colors: _r3(0xE8C7F0, 0xCC87DB, 0xB148C7),
                chroma: Chroma.Polychromatic,
                reflectance: 1e18,
                emissive: 0,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "CCCL"
            });
        }
        if (id == 4) {
            return Material({
                name: "Citrine",
                colorBucket: "yellow",
                colors: _r3(0xFFEFA0, 0xFFE000, 0xC8941C),
                chroma: Chroma.Monochromatic,
                reflectance: 1e18,
                emissive: 8e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "CCLC"
            });
        }
        if (id == 5) {
            return Material({
                name: "Fire Obsidian",
                colorBucket: "red",
                colors: _r3(0xFF3540, 0xFC2F38, 0x7A2028),
                chroma: Chroma.Monochromatic,
                reflectance: 1e18,
                emissive: 6e16,
                ambient: DARK_LITHIC_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "LLCC"
            });
        }
        if (id == 6) {
            return Material({
                name: "Duskhollow",
                colorBucket: "cyan",
                colors: _r3(0xF0FAFF, 0x68C8FF, 0x2878C8),
                chroma: Chroma.Polychromatic,
                reflectance: 95e16,
                emissive: 10e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "MVMM"
            });
        }
        if (id == 7) {
            return Material({
                name: "Sakura",
                colorBucket: "red",
                colors: _v8(0xFFE8EA, 0xFFD8DF, 0xFFB0CD, 0xFF9AC6, 0xFF80BA, 0xFF5CAD, 0xE03090, 0x801848),
                chroma: Chroma.Variegated,
                reflectance: 95e16,
                emissive: 2e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "VVVM"
            });
        }
        if (id == 8) {
            return Material({
                name: "Rainforest",
                colorBucket: "green",
                colors: _v8(0xE5F0D0, 0xC5E1A5, 0x9BCB7F, 0x84C076, 0x65B05A, 0x43A047, 0x2A6030, 0x4A3818),
                chroma: Chroma.Variegated,
                reflectance: 85e16,
                emissive: 2e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "VVMV"
            });
        }
        if (id == 9) {
            return Material({
                name: "Embermade",
                colorBucket: "red",
                colors: _r3(0xC85868, 0x901428, 0x481018),
                chroma: Chroma.Polychromatic,
                reflectance: 1e18,
                emissive: 10e16,
                ambient: DARK_LITHIC_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "LLCL"
            });
        }
        if (id == 10) {
            return Material({
                name: "Abyss",
                colorBucket: "blue",
                colors: _r3(0x80B0E8, 0x2050A0, 0x203050),
                chroma: Chroma.Monochromatic,
                reflectance: 1e18,
                emissive: 0,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "VMMM"
            });
        }
        if (id == 11) {
            return Material({
                name: "Bloodmoon",
                colorBucket: "red",
                colors: _r3(0xE84830, 0x781020, 0x180A10),
                chroma: Chroma.Polychromatic,
                reflectance: 90e16,
                emissive: 12e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "VMMV"
            });
        }
        if (id == 12) {
            return Material({
                name: "Sugilite",
                colorBucket: "purple",
                colors: _r3(0xE8B8F8, 0xA040D8, 0x501880),
                chroma: Chroma.Monochromatic,
                reflectance: 1e18,
                emissive: 0,
                ambient: DARK_LITHIC_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "CCLL"
            });
        }
        if (id == 13) {
            return Material({
                name: "Bored Ruby",
                colorBucket: "red",
                colors: _v8(0xFFB098, 0xFF8C88, 0xF26A55, 0xE14E56, 0xC85540, 0xC41024, 0x8B2A12, 0x6A1A0E),
                chroma: Chroma.Monochromatic,
                reflectance: 1e18,
                emissive: 0,
                ambient: DARK_LITHIC_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "LCCC"
            });
        }
        if (id == 14) {
            return Material({
                name: "Dawnstone",
                colorBucket: "green",
                colors: _r3(0xF4F0C0, 0xA8C060, 0x587038),
                chroma: Chroma.Polychromatic,
                reflectance: 1e18,
                emissive: 2e16,
                ambient: DARK_LITHIC_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "LCCL"
            });
        }
        if (id == 15) {
            return Material({
                name: "Diamond",
                colorBucket: "cyan",
                colors: _v8(0xFFFFFF, 0xF0F8FF, 0xDCF0FF, 0xC0E5F8, 0xA8DAEC, 0x88C8E0, 0x6EB2D2, 0x5A98BC),
                chroma: Chroma.Polychromatic,
                reflectance: 1e18,
                emissive: 0,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "CCCC"
            });
        }
        if (id == 16) {
            return Material({
                name: "Rock",
                colorBucket: "gray",
                colors: _v8(0xAAA29A, 0xA8A098, 0xA59D96, 0xA29B94, 0xA09992, 0x9D9790, 0x9B948D, 0x98928B),
                chroma: Chroma.Monochromatic,
                reflectance: 70e16,
                emissive: 0,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "LLLL"
            });
        }
        if (id == 17) {
            return Material({
                name: "Daystar",
                colorBucket: "yellow",
                colors: _r3(0xFFF8D8, 0xFFD860, 0xC07A18),
                chroma: Chroma.Monochromatic,
                reflectance: 1e18,
                emissive: 14e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "MMVM"
            });
        }
        if (id == 18) {
            return Material({
                name: "Tsavorite",
                colorBucket: "green",
                colors: _r3(0x42E06E, 0x0FB441, 0x0C501E),
                chroma: Chroma.Monochromatic,
                reflectance: 1e18,
                emissive: 4e16,
                ambient: DARK_LITHIC_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "CLCC"
            });
        }
        if (id == 19) {
            return Material({
                name: "Rhodochrosite",
                colorBucket: "red",
                colors: _r3(0xF09098, 0xE04878, 0x701830),
                chroma: Chroma.Monochromatic,
                reflectance: 1e18,
                emissive: 2e16,
                ambient: DARK_LITHIC_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "CLLC"
            });
        }
        if (id == 20) {
            return Material({
                name: "Copper",
                colorBucket: "red",
                colors: _r3(0xF0AA6E, 0xC57738, 0x784822),
                chroma: Chroma.Monochromatic,
                reflectance: 1e18,
                emissive: 3e16,
                ambient: DARK_LITHIC_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "LCLL"
            });
        }
        if (id == 21) {
            return Material({
                name: "Foxglow",
                colorBucket: "red",
                colors: _v8(0xFFD8B0, 0xFFB070, 0xF08850, 0xC86848, 0x8A7858, 0x588870, 0x48A090, 0x68C0A8),
                chroma: Chroma.Variegated,
                reflectance: 90e16,
                emissive: 12e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "MVMV"
            });
        }
        if (id == 22) {
            return Material({
                name: "Sealume",
                colorBucket: "red",
                colors: _v8(0xFFD8C8, 0xFFB3A7, 0xFFA088, 0xFF917B, 0xFF7B5C, 0xFF6F4F, 0x208888, 0x104050),
                chroma: Chroma.Variegated,
                reflectance: 1e18,
                emissive: 4e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "VMVV"
            });
        }
        if (id == 23) {
            return Material({
                name: "Aquamarine",
                colorBucket: "cyan",
                colors: _r3(0xD8F8F0, 0x6FC8C0, 0x2A6878),
                chroma: Chroma.Polychromatic,
                reflectance: 1e18,
                emissive: 0,
                ambient: DARK_LITHIC_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "LLLC"
            });
        }
        if (id == 24) {
            return Material({
                name: "Blazar",
                colorBucket: "blue",
                colors: _r3(0xFFFFFF, 0x60A0F0, 0x202036),
                chroma: Chroma.Polychromatic,
                reflectance: 1e18,
                emissive: 25e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "MMMV"
            });
        }
        if (id == 25) {
            return Material({
                name: "Sproutsong",
                colorBucket: "green",
                colors: _r3(0xF4FFB8, 0xB4DC58, 0x4A7820),
                chroma: Chroma.Monochromatic,
                reflectance: 95e16,
                emissive: 6e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "MVVV"
            });
        }
        if (id == 26) {
            return Material({
                name: "Heartfern",
                colorBucket: "green",
                colors: _r3(0xB8E8C4, 0x4FA065, 0x1F4A2A),
                chroma: Chroma.Monochromatic,
                reflectance: 90e16,
                emissive: 4e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "VMVM"
            });
        }
        if (id == 27) {
            return Material({
                name: "Moss",
                colorBucket: "green",
                colors: _r3(0x78B818, 0x4AB520, 0x206020),
                chroma: Chroma.Polychromatic,
                reflectance: 85e16,
                emissive: 1e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "VVVV"
            });
        }
        if (id == 28) {
            return Material({
                name: "Cobalt",
                colorBucket: "blue",
                colors: _r3(0x70A8F8, 0x2050F0, 0x1C2660),
                chroma: Chroma.Monochromatic,
                reflectance: 1e18,
                emissive: 4e16,
                ambient: DARK_LITHIC_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "CLLL"
            });
        }
        if (id == 29) {
            return Material({
                name: "Emerald",
                colorBucket: "green",
                colors: _r3(0xB8F0D6, 0x48C888, 0x208050),
                chroma: Chroma.Monochromatic,
                reflectance: 1e18,
                emissive: 0,
                ambient: DARK_LITHIC_AMBIENT,
                essence: Essence.Lithic,
                elementSig: "CLCL"
            });
        }
        if (id == 30) {
            return Material({
                name: "Wisp",
                colorBucket: "green",
                colors: _v8(0xCFFFEC, 0x96FACA, 0x66ECB2, 0x40CC9A, 0x308E78, 0x255866, 0x223C4E, 0x202830),
                chroma: Chroma.Variegated,
                reflectance: 85e16,
                emissive: 15e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "MVVM"
            });
        }
        if (id == 31) {
            return Material({
                name: "Twilight",
                colorBucket: "purple",
                colors: _r3(0xE8B8D8, 0x8870B0, 0x2E2858),
                chroma: Chroma.Polychromatic,
                reflectance: 95e16,
                emissive: 8e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Lumic,
                elementSig: "VVMM"
            });
        }
        if (id == 32) {
            return Material({
                name: "Corona",
                colorBucket: "blue",
                colors: _v8(0xE8EEF4, 0xC0D0E0, 0x90A8C0, 0x68A0C8, 0xFF6820, 0xE83028, 0x708090, 0x586878),
                chroma: Chroma.Variegated,
                reflectance: 90e16,
                emissive: 15e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "YYGY"
            });
        }
        if (id == 33) {
            return Material({
                name: "Strobeflora",
                colorBucket: "green",
                colors: _v8(0xE8FFE8, 0x90F040, 0x48C848, 0x288028, 0xFF48FF, 0xC020A0, 0x6028A0, 0x401860),
                chroma: Chroma.Variegated,
                reflectance: 88e16,
                emissive: 15e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "YYYG"
            });
        }
        if (id == 34) {
            return Material({
                name: "Sigil",
                colorBucket: "yellow",
                colors: _r3(0x6CFFD0, 0xE8C038, 0x583090),
                chroma: Chroma.Polychromatic,
                reflectance: 90e16,
                emissive: 14e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "GYGY"
            });
        }
        if (id == 35) {
            return Material({
                name: "Smokeblossom",
                colorBucket: "gray",
                colors: _v8(0xF4ECD6, 0xE8DDC2, 0xC9341E, 0x8E5350, 0x6E7A88, 0x4D5466, 0x2C3A4A, 0x202838),
                chroma: Chroma.Variegated,
                reflectance: 80e16,
                emissive: 0,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "GGGY"
            });
        }
        // 16x3 expansion: 5 new Lumic + 7 new Mythic to complete the 48-material grid.
        if (id == 36) {
            return Material({
                name: "Saint Spectrum",
                colorBucket: "purple",
                colors: _v8(0x00F8FF, 0x38E8FF, 0xFF28E0, 0xFF2975, 0xF222FF, 0x8C1EFF, 0x5818D0, 0x301060),
                chroma: Chroma.Variegated,
                reflectance: 88e16,
                emissive: 16e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "YGYY"
            });
        }
        if (id == 37) {
            return Material({
                name: "Cypher",
                colorBucket: "purple",
                colors: _r3(0x9EF6C7, 0xEF36D8, 0x418883),
                chroma: Chroma.Polychromatic,
                reflectance: 90e16,
                emissive: 12e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "YGYG"
            });
        }
        if (id == 38) {
            return Material({
                name: "Aether",
                colorBucket: "blue",
                colors: _v8(0xFFFAF0, 0xFFF7E3, 0xFFF2D8, 0xF0F5FF, 0xE0ECFF, 0xC8DCFF, 0xB0C8F4, 0x98B4E8),
                chroma: Chroma.Variegated,
                reflectance: 1e18,
                emissive: 14e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "YYYY"
            });
        }
        if (id == 39) {
            return Material({
                name: "Deadform",
                colorBucket: "gray",
                colors: _v8(0x2A2A2A, 0x2A2A2A, 0x2A2A2A, 0x2A2A2A, 0x2A2A2A, 0x2A2A2A, 0x2A2A2A, 0x2A2A2A),
                chroma: Chroma.Monochromatic,
                reflectance: 80e16,
                emissive: 2e16,
                ambient: 3e16,
                essence: Essence.Mythic,
                elementSig: "GGGG"
            });
        }
        if (id == 40) {
            return Material({
                name: "Nullbloom",
                colorBucket: "green",
                colors: _v8(0xF5F4E4, 0xE8E2D0, 0xA8C898, 0xF0B070, 0xB858F0, 0x6828C8, 0x38A8F0, 0x2E1F58),
                chroma: Chroma.Variegated,
                reflectance: 88e16,
                emissive: 10e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "GYYY"
            });
        }
        if (id == 41) {
            return Material({
                name: "Reliquary",
                colorBucket: "green",
                colors: _r3(0xF0E0A0, 0x48B0A0, 0x403048),
                chroma: Chroma.Polychromatic,
                reflectance: 92e16,
                emissive: 11e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "GGYG"
            });
        }
        if (id == 42) {
            return Material({
                name: "Duskcode",
                colorBucket: "red",
                colors: _r3(0xFF9040, 0x40D0E0, 0x382838),
                chroma: Chroma.Polychromatic,
                reflectance: 92e16,
                emissive: 13e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "GGYY"
            });
        }
        if (id == 43) {
            return Material({
                name: "Phosphor",
                colorBucket: "green",
                colors: _v8(0xB0FF98, 0x90FF70, 0x80FF58, 0x58F038, 0x40D828, 0x38C020, 0x30B018, 0x289810),
                chroma: Chroma.Variegated,
                reflectance: 70e16,
                emissive: 20e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "GYGG"
            });
        }
        if (id == 44) {
            return Material({
                name: "Celestial",
                colorBucket: "yellow",
                colors: _v8(0xFFE838, 0xFFD020, 0xFFF050, 0xFFC818, 0x98D0FF, 0x70C0FF, 0x50A8F8, 0x3898F0),
                chroma: Chroma.Variegated,
                reflectance: 90e16,
                emissive: 12e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "GYYG"
            });
        }
        if (id == 45) {
            return Material({
                name: "Corposant",
                colorBucket: "cyan",
                colors: _v8(0xFFD0F0, 0xA8FFE8, 0x70E8F0, 0x5890E8, 0x6858C8, 0x8840A8, 0x502878, 0x301848),
                chroma: Chroma.Variegated,
                reflectance: 92e16,
                emissive: 15e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "YGGG"
            });
        }
        if (id == 46) {
            return Material({
                name: "Wraithseal",
                colorBucket: "red",
                colors: _v8(0xF9A751, 0xFA6705, 0xFF3C0A, 0xD52308, 0xA5120C, 0x923430, 0x814D5E, 0x402030),
                chroma: Chroma.Polychromatic,
                reflectance: 92e16,
                emissive: 12e16,
                ambient: DEFAULT_AMBIENT,
                essence: Essence.Mythic,
                elementSig: "YGGY"
            });
        }
        return Material({
            name: "Veilscript",
            colorBucket: "blue",
            colors: _v8(0xA0C0FF, 0x6088FF, 0x3050F8, 0x1830C8, 0x4828E0, 0x1820A0, 0x0A1060, 0x080828),
            chroma: Chroma.Variegated,
            reflectance: 95e16,
            emissive: 15e16,
            ambient: DEFAULT_AMBIENT,
            essence: Essence.Mythic,
            elementSig: "YYGG"
        });
    }
}
