# Talismans — contract sources

Talismans is a fully on-chain generative ERC-721 collection. Every talisman —
its 3D mesh, its materials, its colours, its SVG, its interactive HTML view and
its metadata JSON — is computed inside the contracts at read time. Nothing is
pinned to IPFS or served from a backend: `tokenURI` returns a data URI built
from contract storage.

This repository publishes the Solidity sources, the Foundry test suite, and the
exact build configuration those contracts were compiled with. Its purpose is
narrow and mechanical:

1. **Read the source** of everything that is deployed, or about to be.
2. **Run the tests** against it.
3. **Reproduce the deployed bytecode** byte-for-byte and check it against
   what is on-chain.

That is the whole scope. There is no deployment tooling, no address registry
and no operational documentation here — only what is needed to compile, test
and reproduce.

> Talismans is an NFT art collection. It is unaffiliated with, and unrelated
> to, any other project using a similar name.

## What is in here

```
src/          contract sources
test/         Foundry test suite
script/       libraries imported by the test suite: DiagnoseMesh.s.sol (mesh
              diagnostic), thevessel/TalismanInCraft.sol and
              thevessel/VesselRaster.sol (wrap helpers and craft rasteriser)
foundry.toml  compiler settings (frozen, see below)
remappings.txt import remappings (frozen, see below)
foundry.lock  pinned dependency revisions
lib/          dependencies, as git submodules at pinned revisions
```

| Contract | Role |
| --- | --- |
| `Talismans` | The ERC-721 itself: ownership, commit-reveal, transformations, royalties |
| `TalismanMinter` | Original mint: allowlist stage, public stage, artist proofs |
| `TalismanQueueMinter` | Queue-based mint used for launch; anti-bot per-block spots |
| `TalismanMaterials` | The material table — names, colours, essences, lighting |
| `TalismanGenerator` / `TalismanGeneratorV2` | Turns cores into a shaded 3D mesh |
| `TalismanForms` / `TalismanFormsV2` | Shape families and triangulation |
| `TalismanSvgRenderer` / `TalismanSvgRendererV2` | Rasterises a mesh to SVG |
| `TalismanLiteHtmlRenderer` | Interactive HTML/WebGL view for `animation_url` |
| `TalismanStlRenderer` | Binary STL export of the mesh |
| `TalismanMetadataRenderer` / `TalismanRendererV2` | Assembles the metadata JSON and data URIs |
| `TalismanTransformationSimulator` | Read-only preview of a transformation's result |
| `TalismanRendererV3` | Next metadata renderer: seam stroke, per-vertex lighting, core facets — **not yet active**, see below |
| `TalismanSvgRendererV3` / `TalismanVertexLitHtmlRenderer` | Its lit SVG image and lit HTML/WebGL viewer |
| `TalismanLitMaterials` / `TalismanVertexLitViewerScript` | Per-material lighting terms and the viewer's script (libraries) |
| `TalismanSwapV1` | **Not yet deployed** — see below |
| `thevessel/TalismanInCraftWrapper` | Holds one Talisman wrapped in a craft of The Vessel until the craft's holder unwraps it — see below |

`Talismans` reads its renderer and materials table through pointers the owner
can swap (`setRenderer`, `setMaterials`) or freeze forever (`freezeRenderer`,
`freezeMaterials`). That is how `TalismanRendererV2` replaced the original
renderer without touching the token contract, and how `TalismanRendererV3`
would replace `TalismanRendererV2`.

### `TalismanRendererV3` is not yet active

`TalismanRendererV3` and the files it brings — `TalismanSvgRendererV3`,
`TalismanVertexLitHtmlRenderer`, `TalismanVertexLitViewerScript`,
`TalismanLitMaterials` and `ITalismanHost`, with `test/TalismanRendererV3.t.sol`
and `test/TalismanLitMaterials.t.sol` — are published ahead of activation. Until
`Talismans.setRenderer` points at it, every token renders through
`TalismanRendererV2`.

### `TalismanSwapV1` is not deployed

`src/TalismanSwapV1.sol` and `test/TalismanSwapV1.t.sol` are published ahead of
any deployment, for review. Nothing in this repository should be read as a
commitment that it will ship, or ship in this form. Everything else under
`src/` corresponds to code that is already live and immutable.

### `thevessel/` — Talismans wrapped in crafts of The Vessel

`src/thevessel/`, `test/thevessel/` and `script/thevessel/` hold a module that
builds on the collection without being part of it. A `TalismanInCraftWrapper`
wraps a Talisman in a Capsule craft of The Vessel
(`0xECb92Cc7112b80A2234936315BbB493fb48d1463`): its constructor writes the
Talisman's image and the wrapper's own address into the craft and takes custody
of the Talisman, and whoever holds the craft can later `unwrap` it once to
receive the Talisman.

Each wrap deploys its own wrapper, so there is one wrapper contract per wrapped
Talisman. Every wrapper shares the same runtime bytecode; only the constructor
arguments differ. The Talismans core contracts do not import the module.

`script/thevessel/TalismanInCraft.sol` and `script/thevessel/VesselRaster.sol`
are not deployed. They are plain libraries — public mainnet addresses, the
ERC-721C policy steps and the greyscale rasteriser — published because the
module's tests import them.

## Setup

Requires [Foundry](https://getfoundry.sh).

```sh
git clone --recurse-submodules <this repo>
cd talisman-contracts
forge build
```

If you cloned without `--recurse-submodules`:

```sh
git submodule update --init --recursive
```

The recursive init matters. Foundry derives a remapping from **every**
directory under `lib/`, including the nested submodules that no contract
imports, and that remapping list is hashed into the deployed bytecode. A
partially initialised tree still compiles, but it does not reproduce.

Pinned revisions, licences and provenance for every dependency are in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Running the tests

```sh
forge test                 # whole suite
forge test -vvv            # with traces
forge test --gas-report
forge fmt --check          # formatting
```

At the revision published here the suite is 741 tests across 30 suites, all
passing. Two further suites, `test/thevessel/TalismanInCraftWrapperFork.t.sol`
and `test/thevessel/TalismanInCraftWrapperPolicyFork.t.sol` (23 tests), run the
wrapper against the live Vessel, Talismans and transfer validator on a mainnet
fork. They are skipped unless `MAINNET_RPC_URL` is set:

```sh
MAINNET_RPC_URL=<mainnet-rpc-url> forge test --match-path 'test/thevessel/*Fork*'
```

## Reproducing the deployed bytecode

Deployed contracts are immutable, and their compiler settings are recorded — and
hashed — into the bytecode itself. So reproduction is exact or it is nothing:
the artifact this repository builds either matches what is on-chain byte for
byte, metadata hash included, or the build configuration is not the one that
produced it.

With Foundry, against any address you want to check:

```sh
forge build

forge verify-bytecode <address> src/<Contract>.sol:<Contract> \
  --rpc-url <mainnet-rpc-url> \
  --etherscan-api-key <key>
```

A reproducing contract reports:

```
Creation code matched with status full
Runtime code matched with status full
```

`full` — as opposed to `partial` — means the compiler metadata hash matched too,
so the sources and settings are byte-identical to the ones compiled at deploy
time, not merely semantically equivalent. `forge verify-bytecode` replays the
deployment transaction against a fork, so it handles constructor arguments and
`immutable` slots for you; several contracts here carry immutables, and a naive
`cast code` comparison will differ from the compiled artifact at exactly those
bytes.

Without Foundry, the same check by hand:

```sh
forge build
jq -r '.deployedBytecode.object' out/<Contract>.sol/<Contract>.json
cast code <address> --rpc-url <mainnet-rpc-url>
```

— identical for contracts with no `immutable` fields; differing only in the
immutable slots for those that have them. The trailing CBOR blob of the runtime
code carries the metadata hash, which is the part that pins the source tree.

The mainnet contracts are also verified on Etherscan and on
[Sourcify](https://sourcify.dev), where they resolve as full (`exact_match`)
matches of both creation and runtime bytecode. Those are permissionless indexes,
so the published source can be read back without taking this repository on
trust.

### The build configuration is frozen

Solc records the compiler settings and the full remapping list in each
contract's metadata, and hashes that metadata into the deployed bytecode.
Because the deployed contracts are immutable, any change to the following
permanently breaks byte-exact verification of code that is already on-chain:

- `foundry.toml` — `solc`, `optimizer`, `optimizer_runs`, `via_ir`,
  `evm_version`.
- `remappings.txt` — every line. This includes `ds-test/`, which resolves to a
  directory nothing imports and looks exactly like dead configuration. It is
  load-bearing; leave it. (The file cannot carry a comment saying so — Foundry
  rejects any line that is not `key=value`.)
- The contents and layout of `lib/`, down to the nested submodules. Foundry
  derives a remapping from every directory it finds there, including ones no
  contract imports.

`src/` is likewise fixed for everything already deployed: it is the verified
source of immutable contracts, published exactly as compiled. Bug fixes ship as
new contracts wired in through an upgrade pointer, never as edits here.

## Status and risk

These contracts are deployed and live on Ethereum mainnet, and they hold real
value: they mint against payment, custody ETH pending withdrawal, and enforce
royalties on secondary sales.

- **They have not had an external security audit.** They were developed with the
  test suite in this repository and reviewed internally, and nothing more than
  that. Read the source before trusting it with anything.
- **The deployed contracts are immutable.** Their bytecode cannot be patched.
  A bug in `Talismans` itself — ownership, commit-reveal, the transformations,
  royalty enforcement — is permanent. Only the renderer, the materials table,
  and the minter sit behind owner-controlled pointers that allow replacement.
- **A `TalismanInCraftWrapper` holds its Talisman until the craft is
  unwrapped.** It has no owner and no other way out: whoever holds the craft is
  the only one who can unwrap, and only once.
- **`TalismanSwapV1` is unreviewed, unaudited and undeployed.** It is here to be
  read and challenged, not relied on.
- **The code is published as-is, with no warranty of any kind** (see
  [LICENSE](LICENSE)). If you fork it, adapt it, or deploy it yourself, you do
  so entirely at your own risk. Get it audited first.

Nothing in this repository is an offer, a solicitation, or financial advice.

To report a security issue, see [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).

Third-party components, their licences and pinned revisions are listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
