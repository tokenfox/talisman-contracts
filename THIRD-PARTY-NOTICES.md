# Third-party notices

The Talismans contracts are MIT-licensed (see `LICENSE`). They incorporate, or
build against, the third-party software listed here. Each entry states what is
used, which licence applies, and whether that code ends up inside the deployed
bytecode.

Everything compiled into a deployed contract is MIT-licensed. No copyleft code
is compiled into, linked into, or distributed as part of any deployed contract.

Dependencies under `lib/` are git submodules pinned to the exact revisions
listed at the end of this file. This repository distributes none of their code;
it records where to fetch it and at which commit. Fetch the tree with
`git submodule update --init --recursive` before building.

---

## Compiled into the deployed bytecode

### Limit Break — creator-token-standards

The ERC-721C creator-token interfaces in `src/ICreatorToken.sol`
(`ICreatorToken`, `ICreatorTokenLegacy`, `ITransferValidator`) are transcribed
from Limit Break's `creator-token-standards`, so that the interface ids match
byte-for-byte and marketplaces recognise the collection as royalty-enforcing.
`src/CreatorTokenBase.sol` carries the same validator logic, re-hosted on
OpenZeppelin 5's `_update` hook.

Source: <https://github.com/limitbreakinc/creator-token-standards>

```
MIT License

Copyright (c) 2023 Limit Break Inc

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### OpenZeppelin Contracts

`lib/openzeppelin-contracts` — ERC-721, ERC-2981, Ownable / Ownable2Step,
ReentrancyGuard, MerkleProof, SafeERC20, and the ERC-165 / ERC-4906 / ERC-6093
interfaces. The undeployed `TalismanSwapV1` additionally uses
`ReentrancyGuardTransient` and the `IERC20` / `IERC1155` interfaces.

Source: <https://github.com/OpenZeppelin/openzeppelin-contracts>
Licence: MIT — Copyright (c) 2016-2025 Zeppelin Group Ltd
Full text: `lib/openzeppelin-contracts/LICENSE`

### Solady

`lib/solady` — `Base64`, `DynamicBufferLib`, `FixedPointMathLib`, `LibString`.

Source: <https://github.com/vectorized/solady>
Licence: MIT — Copyright (c) 2022-2025 Solady.
Full text: `lib/solady/LICENSE.txt`

### solidity-trigonometry

`lib/solidity-trigonometry` — `Trigonometry`, used by the SVG renderers for
mesh projection.

Source: <https://github.com/mds1/solidity-trigonometry>
Licence: MIT — Copyright (c) 2021 Matt Solomon
Full text: `lib/solidity-trigonometry/LICENSE`

This library carries its own upstream lineage, preserved in its file header: it
is based on Lefteris Karapetsas' Solidity trigonometry library, which is in turn
based on Dave Dribin's `trigint` C library.

---

## Build and test dependencies only

None of the following is compiled into, linked into, or distributed as part of
any deployed contract. They are development-time dependencies.

### Forge Standard Library

`lib/forge-std` — the test harness (`forge-std/Test.sol`) used by `test/*` and
the scripting base (`forge-std/Script.sol`) used by `script/*`.

Source: <https://github.com/foundry-rs/forge-std>
Licence: MIT OR Apache-2.0 (dual) — Copyright Contributors to Forge Standard Library
Full text: `lib/forge-std/LICENSE-MIT`, `lib/forge-std/LICENSE-APACHE`

### PRBMath

`lib/solidity-trigonometry/lib/prb-math` — a transitive dependency of
solidity-trigonometry. Present in the dependency tree; not imported by any
contract, test, or script in this repository.

Source: <https://github.com/PaulRBerg/prb-math>
Licence: Unlicense (public domain dedication)

### ds-test

`lib/solidity-trigonometry/lib/forge-std/lib/ds-test` — a transitive dependency
of the *nested* forge-std beneath solidity-trigonometry.

Source: <https://github.com/dapphub/ds-test>
Licence: **GPL-3.0-or-later**

**This code is fetched but never compiled and never linked.** It is called out
explicitly because automated licence scanners flag transitive GPL and may report
a false positive against this repository:

- No file in `src/`, `test/`, or `script/` imports `ds-test`.
- The pinned top-level `lib/forge-std` does not depend on ds-test at all; it
  vendors its own assertion library under MIT. ds-test reaches the tree only
  through the *nested* forge-std that solidity-trigonometry pins for its own
  test suite, which this repository never builds.
- The `ds-test/` line in `remappings.txt` resolves to this directory but is
  never exercised. It is retained deliberately: removing it changes the
  remappings recorded in compiler metadata and would break byte-exact
  verification of the already deployed contracts. `remappings.txt` cannot
  carry a comment saying so — Foundry rejects any line that is not
  `key=value` — so the warning lives in `README.md` instead.
- Consequently no deployed contract, and no artefact distributed from this
  repository, is a derivative work of ds-test.

---

## Pinned versions

The deployed bytecode reproduces only against these exact revisions.

| Dependency | Revision |
| --- | --- |
| `lib/forge-std` | `3f999523613ab5454a5c4ae4abeaa8ea2ba7bcae` |
| `lib/openzeppelin-contracts` | `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0` (v5.4.0) |
| `lib/solady` | `73f13dd1483707ef6b4d16cb0543570b7e1715a8` |
| `lib/solidity-trigonometry` | `58af3a912ab3e2203cf21189012caefe24471e29` |
| `lib/openzeppelin-contracts/lib/erc4626-tests` | `232ff9ba8194e406967f52ecc5cb52ed764209e9` |
| `lib/openzeppelin-contracts/lib/forge-std` | `3b20d60d14b343ee4f908cb8079495c07f5e8981` |
| `lib/openzeppelin-contracts/lib/halmos-cheatcodes` | `7328abe100445fc53885c21d0e713b95293cf14c` |
| `lib/solidity-trigonometry/lib/forge-std` | `2a2ce3692b8c1523b29de3ec9d961ee9fbbc43a6` |
| `lib/solidity-trigonometry/lib/forge-std/lib/ds-test` | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` |
| `lib/solidity-trigonometry/lib/prb-math` | `e33a042e4d1673fe9b333830b75c4765ccf3f5f2` |

The nested entries matter as much as the top-level ones: Foundry derives a
remapping from every directory in the tree, and the resulting remapping list is
recorded in the compiler metadata that ends up hashed into the deployed
bytecode. A tree missing `erc4626-tests` or `halmos-cheatcodes` produces a
different metadata hash and will not full-match on-chain.
