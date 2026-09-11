// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Four ERC-721s that share OZ's ERC721 base and differ ONLY in their enumeration
// strategy, so a `--gas-report` on `mint` / `transferFrom` / `burn` isolates the
// enumeration tax apples-to-apples. (`_mint`/`_burn`, not `_safeMint`, so the
// receiver callback adds no noise; ids minted sequentially.)
// ─────────────────────────────────────────────────────────────────────────────

/// A · CURRENT (Option D): per-owner EnumerableSet + a totalSupply counter.
///     Exactly the live `Talismans._update`. No global token index.
contract EnumPerOwnerSet is ERC721 {
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public totalSupply;
    uint256 private _next = 1;
    mapping(address => EnumerableSet.UintSet) private _owned;

    constructor() ERC721("X", "X") {}

    function mint(address to) external returns (uint256 id) {
        id = _next++;
        _mint(to, id);
    }

    function burn(uint256 id) external {
        _burn(id);
    }

    // Transform shapes (enumeration churn only; no cores logic). bond/merge burn
    // two inputs and mint one output; cleave/cut burn one and mint two.
    function burn2mint1(uint256 x, uint256 y, address to) external returns (uint256 id) {
        _burn(x);
        _burn(y);
        id = _next++;
        _mint(to, id);
    }

    function burn1mint2(uint256 x, address to) external returns (uint256 i1, uint256 i2) {
        _burn(x);
        i1 = _next++;
        _mint(to, i1);
        i2 = _next++;
        _mint(to, i2);
    }

    function tokensOfOwner(address o) external view returns (uint256[] memory) {
        return _owned[o].values();
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = super._update(to, id, auth);
        if (from == address(0)) {
            totalSupply++;
        } else if (from != to) {
            _owned[from].remove(id);
        }
        if (to == address(0)) {
            totalSupply--;
        } else if (from != to) {
            _owned[to].add(id);
        }
    }
}

/// B · HAND-OPTIMIZED per-owner-only. Same capability as A (per-owner enum +
///     one-call `tokensOfOwner`, no global index) but reuses `balanceOf` as the
///     position counter, so it drops the EnumerableSet values-array length slot.
///     The "fix the current design without going full" candidate.
contract EnumHandPerOwner is ERC721 {
    uint256 public totalSupply;
    uint256 private _next = 1;
    mapping(address => mapping(uint256 => uint256)) private _ownedTokens; // owner => index => id
    mapping(uint256 => uint256) private _ownedIndex; // id => index

    constructor() ERC721("X", "X") {}

    function mint(address to) external returns (uint256 id) {
        id = _next++;
        _mint(to, id);
    }

    function burn(uint256 id) external {
        _burn(id);
    }

    // Transform shapes (enumeration churn only; no cores logic). bond/merge burn
    // two inputs and mint one output; cleave/cut burn one and mint two.
    function burn2mint1(uint256 x, uint256 y, address to) external returns (uint256 id) {
        _burn(x);
        _burn(y);
        id = _next++;
        _mint(to, id);
    }

    function burn1mint2(uint256 x, address to) external returns (uint256 i1, uint256 i2) {
        _burn(x);
        i1 = _next++;
        _mint(to, i1);
        i2 = _next++;
        _mint(to, i2);
    }

    function tokensOfOwner(address o) external view returns (uint256[] memory ids) {
        uint256 n = balanceOf(o);
        ids = new uint256[](n);
        mapping(uint256 => uint256) storage owned = _ownedTokens[o];
        for (uint256 i; i < n; ++i) {
            ids[i] = owned[i];
        }
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = super._update(to, id, auth);
        if (from == address(0)) {
            totalSupply++;
        } else if (from != to) {
            _removeOwned(from, id);
        }
        if (to == address(0)) {
            totalSupply--;
        } else if (from != to) {
            uint256 idx = balanceOf(to) - 1; // balance already incremented
            _ownedTokens[to][idx] = id;
            _ownedIndex[id] = idx;
        }
    }

    function _removeOwned(address from, uint256 id) private {
        uint256 lastIdx = balanceOf(from); // balance already decremented
        uint256 idx = _ownedIndex[id];
        mapping(uint256 => uint256) storage owned = _ownedTokens[from];
        if (idx != lastIdx) {
            uint256 lastId = owned[lastIdx];
            owned[idx] = lastId;
            _ownedIndex[lastId] = idx;
        }
        delete _ownedIndex[id];
        delete owned[lastIdx];
    }
}

/// C · HAND-OPTIMIZED FULL ENUMERABLE: balance-indexed per-owner index (as in B)
///     PLUS a global array+index for `tokenByIndex`. The full IERC721Enumerable
///     surface, hand-inlined. Same algorithm OZ uses, written directly.
contract EnumHandFull is ERC721 {
    uint256 private _next = 1;

    uint256[] private _allTokens;
    mapping(uint256 => uint256) private _allTokensIndex;
    mapping(address => mapping(uint256 => uint256)) private _ownedTokens;
    mapping(uint256 => uint256) private _ownedIndex;

    constructor() ERC721("X", "X") {}

    function mint(address to) external returns (uint256 id) {
        id = _next++;
        _mint(to, id);
    }

    function burn(uint256 id) external {
        _burn(id);
    }

    // Transform shapes (enumeration churn only; no cores logic). bond/merge burn
    // two inputs and mint one output; cleave/cut burn one and mint two.
    function burn2mint1(uint256 x, uint256 y, address to) external returns (uint256 id) {
        _burn(x);
        _burn(y);
        id = _next++;
        _mint(to, id);
    }

    function burn1mint2(uint256 x, address to) external returns (uint256 i1, uint256 i2) {
        _burn(x);
        i1 = _next++;
        _mint(to, i1);
        i2 = _next++;
        _mint(to, i2);
    }

    function totalSupply() external view returns (uint256) {
        return _allTokens.length;
    }

    function tokenByIndex(uint256 i) external view returns (uint256) {
        return _allTokens[i];
    }

    function tokenOfOwnerByIndex(address o, uint256 i) external view returns (uint256) {
        return _ownedTokens[o][i];
    }

    function tokensOfOwner(address o) external view returns (uint256[] memory ids) {
        uint256 n = balanceOf(o);
        ids = new uint256[](n);
        mapping(uint256 => uint256) storage owned = _ownedTokens[o];
        for (uint256 i; i < n; ++i) {
            ids[i] = owned[i];
        }
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = super._update(to, id, auth);
        if (from == address(0)) {
            _allTokensIndex[id] = _allTokens.length;
            _allTokens.push(id);
        } else if (from != to) {
            _removeOwned(from, id);
        }
        if (to == address(0)) {
            _removeAll(id);
        } else if (from != to) {
            uint256 idx = balanceOf(to) - 1;
            _ownedTokens[to][idx] = id;
            _ownedIndex[id] = idx;
        }
    }

    function _removeOwned(address from, uint256 id) private {
        uint256 lastIdx = balanceOf(from);
        uint256 idx = _ownedIndex[id];
        mapping(uint256 => uint256) storage owned = _ownedTokens[from];
        if (idx != lastIdx) {
            uint256 lastId = owned[lastIdx];
            owned[idx] = lastId;
            _ownedIndex[lastId] = idx;
        }
        delete _ownedIndex[id];
        delete owned[lastIdx];
    }

    function _removeAll(uint256 id) private {
        uint256 last;
        unchecked {
            last = _allTokens.length - 1;
        }
        uint256 idx = _allTokensIndex[id];
        if (idx != last) {
            uint256 lastId = _allTokens[last];
            _allTokens[idx] = lastId;
            _allTokensIndex[lastId] = idx;
        }
        _allTokens.pop();
        delete _allTokensIndex[id];
    }
}

/// Baseline · bare ERC-721, no enumeration of any kind. Anchors the per-op tax.
contract EnumNone is ERC721 {
    uint256 private _next = 1;

    constructor() ERC721("X", "X") {}

    function mint(address to) external returns (uint256 id) {
        id = _next++;
        _mint(to, id);
    }

    function burn(uint256 id) external {
        _burn(id);
    }

    // Transform shapes (enumeration churn only; no cores logic). bond/merge burn
    // two inputs and mint one output; cleave/cut burn one and mint two.
    function burn2mint1(uint256 x, uint256 y, address to) external returns (uint256 id) {
        _burn(x);
        _burn(y);
        id = _next++;
        _mint(to, id);
    }

    function burn1mint2(uint256 x, address to) external returns (uint256 i1, uint256 i2) {
        _burn(x);
        i1 = _next++;
        _mint(to, i1);
        i2 = _next++;
        _mint(to, i2);
    }
}

/// D · OPENZEPPELIN ERC721Enumerable, used as-is.
contract EnumOZ is ERC721Enumerable {
    uint256 private _next = 1;

    constructor() ERC721("X", "X") {}

    function mint(address to) external returns (uint256 id) {
        id = _next++;
        _mint(to, id);
    }

    function burn(uint256 id) external {
        _burn(id);
    }

    // Transform shapes (enumeration churn only; no cores logic). bond/merge burn
    // two inputs and mint one output; cleave/cut burn one and mint two.
    function burn2mint1(uint256 x, uint256 y, address to) external returns (uint256 id) {
        _burn(x);
        _burn(y);
        id = _next++;
        _mint(to, id);
    }

    function burn1mint2(uint256 x, address to) external returns (uint256 i1, uint256 i2) {
        _burn(x);
        i1 = _next++;
        _mint(to, i1);
        i2 = _next++;
        _mint(to, i2);
    }
}

/// Drives identical op sequences through each harness; read the numbers from
/// `forge test --match-path test/EnumerationGas.t.sol --gas-report`.
contract EnumerationGasTest is Test {
    EnumPerOwnerSet internal a;
    EnumHandPerOwner internal b;
    EnumHandFull internal c;
    EnumOZ internal d;
    EnumNone internal z;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        a = new EnumPerOwnerSet();
        b = new EnumHandPerOwner();
        c = new EnumHandFull();
        d = new EnumOZ();
        z = new EnumNone();
    }

    function test_gas_mint_Z_none() public {
        for (uint256 i; i < 40; ++i) {
            z.mint(alice);
        }
    }

    function test_gas_transfer_Z_none() public {
        for (uint256 i = 1; i <= 40; ++i) {
            z.mint(alice);
        }
        for (uint256 id = 1; id <= 20; ++id) {
            vm.prank(alice);
            z.transferFrom(alice, bob, id);
        }
    }

    function test_gas_burn_Z_none() public {
        for (uint256 i = 1; i <= 40; ++i) {
            z.mint(alice);
        }
        for (uint256 id = 1; id <= 20; ++id) {
            z.burn(id);
        }
    }

    // Steady-state mint to one owner: the first warms the balance slot; every
    // later mint pays only cold enumeration slots.
    function test_gas_mint_A_perOwnerSet() public {
        for (uint256 i; i < 40; ++i) {
            a.mint(alice);
        }
    }

    function test_gas_mint_B_handPerOwner() public {
        for (uint256 i; i < 40; ++i) {
            b.mint(alice);
        }
    }

    function test_gas_mint_C_handFull() public {
        for (uint256 i; i < 40; ++i) {
            c.mint(alice);
        }
    }

    function test_gas_mint_D_oz() public {
        for (uint256 i; i < 40; ++i) {
            d.mint(alice);
        }
    }

    // Transfer churn alice → bob (global index untouched).
    function test_gas_transfer_A_perOwnerSet() public {
        for (uint256 i = 1; i <= 40; ++i) {
            a.mint(alice);
        }
        for (uint256 id = 1; id <= 20; ++id) {
            vm.prank(alice);
            a.transferFrom(alice, bob, id);
        }
    }

    function test_gas_transfer_B_handPerOwner() public {
        for (uint256 i = 1; i <= 40; ++i) {
            b.mint(alice);
        }
        for (uint256 id = 1; id <= 20; ++id) {
            vm.prank(alice);
            b.transferFrom(alice, bob, id);
        }
    }

    function test_gas_transfer_C_handFull() public {
        for (uint256 i = 1; i <= 40; ++i) {
            c.mint(alice);
        }
        for (uint256 id = 1; id <= 20; ++id) {
            vm.prank(alice);
            c.transferFrom(alice, bob, id);
        }
    }

    function test_gas_transfer_D_oz() public {
        for (uint256 i = 1; i <= 40; ++i) {
            d.mint(alice);
        }
        for (uint256 id = 1; id <= 20; ++id) {
            vm.prank(alice);
            d.transferFrom(alice, bob, id);
        }
    }

    // Burn churn (removes from per-owner, + global for C and D).
    function test_gas_burn_A_perOwnerSet() public {
        for (uint256 i = 1; i <= 40; ++i) {
            a.mint(alice);
        }
        for (uint256 id = 1; id <= 20; ++id) {
            a.burn(id);
        }
    }

    function test_gas_burn_B_handPerOwner() public {
        for (uint256 i = 1; i <= 40; ++i) {
            b.mint(alice);
        }
        for (uint256 id = 1; id <= 20; ++id) {
            b.burn(id);
        }
    }

    function test_gas_burn_C_handFull() public {
        for (uint256 i = 1; i <= 40; ++i) {
            c.mint(alice);
        }
        for (uint256 id = 1; id <= 20; ++id) {
            c.burn(id);
        }
    }

    function test_gas_burn_D_oz() public {
        for (uint256 i = 1; i <= 40; ++i) {
            d.mint(alice);
        }
        for (uint256 id = 1; id <= 20; ++id) {
            d.burn(id);
        }
    }

    // ── Transform shape: burn 2, mint 1 (bond / merge) ──────────────────────────
    function test_gas_b2m1_A_perOwnerSet() public {
        for (uint256 i; i < 60; ++i) {
            a.mint(alice);
        }
        for (uint256 i; i < 15; ++i) {
            a.burn2mint1(2 * i + 1, 2 * i + 2, alice);
        }
    }

    function test_gas_b2m1_B_handPerOwner() public {
        for (uint256 i; i < 60; ++i) {
            b.mint(alice);
        }
        for (uint256 i; i < 15; ++i) {
            b.burn2mint1(2 * i + 1, 2 * i + 2, alice);
        }
    }

    function test_gas_b2m1_C_handFull() public {
        for (uint256 i; i < 60; ++i) {
            c.mint(alice);
        }
        for (uint256 i; i < 15; ++i) {
            c.burn2mint1(2 * i + 1, 2 * i + 2, alice);
        }
    }

    function test_gas_b2m1_D_oz() public {
        for (uint256 i; i < 60; ++i) {
            d.mint(alice);
        }
        for (uint256 i; i < 15; ++i) {
            d.burn2mint1(2 * i + 1, 2 * i + 2, alice);
        }
    }

    function test_gas_b2m1_Z_none() public {
        for (uint256 i; i < 60; ++i) {
            z.mint(alice);
        }
        for (uint256 i; i < 15; ++i) {
            z.burn2mint1(2 * i + 1, 2 * i + 2, alice);
        }
    }

    // ── Transform shape: burn 1, mint 2 (cleave / cut) ──────────────────────────
    function test_gas_b1m2_A_perOwnerSet() public {
        for (uint256 i; i < 40; ++i) {
            a.mint(alice);
        }
        for (uint256 id = 1; id <= 15; ++id) {
            a.burn1mint2(id, alice);
        }
    }

    function test_gas_b1m2_B_handPerOwner() public {
        for (uint256 i; i < 40; ++i) {
            b.mint(alice);
        }
        for (uint256 id = 1; id <= 15; ++id) {
            b.burn1mint2(id, alice);
        }
    }

    function test_gas_b1m2_C_handFull() public {
        for (uint256 i; i < 40; ++i) {
            c.mint(alice);
        }
        for (uint256 id = 1; id <= 15; ++id) {
            c.burn1mint2(id, alice);
        }
    }

    function test_gas_b1m2_D_oz() public {
        for (uint256 i; i < 40; ++i) {
            d.mint(alice);
        }
        for (uint256 id = 1; id <= 15; ++id) {
            d.burn1mint2(id, alice);
        }
    }

    function test_gas_b1m2_Z_none() public {
        for (uint256 i; i < 40; ++i) {
            z.mint(alice);
        }
        for (uint256 id = 1; id <= 15; ++id) {
            z.burn1mint2(id, alice);
        }
    }
}
