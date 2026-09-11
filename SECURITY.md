# Security policy

## Reporting a vulnerability

Report privately to **tokenfox@protonmail.com**. Please do not open a public
issue for a security finding.

Include whatever you have: the contract and address, what an attacker can do,
and a proof of concept if you have one — a failing Foundry test against this
repository is the ideal form.

Findings are triaged by what an attacker can actually take or break, not by
category. No response time is promised.

## Scope

The sources in `src/`, and the live Ethereum mainnet contracts they produce.

`src/TalismanSwapV1.sol` is in scope too, and is the one part of this repository
where a finding can still be fixed by changing the source: it is not deployed.
Reports against it are especially welcome.

Out of scope: testnet deployments, third-party dependencies (report those
upstream), and anything that requires the contract owner's private key.

## What can and cannot be fixed

**The deployed contracts are immutable.** Their bytecode cannot be patched.
That shapes what a fix can look like:

- Contracts reachable through an upgrade pointer — the renderer and the
  materials table — can be replaced by deploying a new contract and repointing
  (`setRenderer`, `setMaterials`). At the time of writing `rendererFrozen()` and
  `materialsFrozen()` are both `false`, so this path is available.
- The minter can be swapped via `setMinter`, and a live minter can be
  neutralised by its owner.
- Everything else in `Talismans` — ownership, commit-reveal, the
  transformations, royalty enforcement — is fixed forever. For a finding there,
  the honest answer may be mitigation and disclosure rather than a fix.

Please take that into account when judging how urgently something needs to stay
private.

## Recognition

There is no bug bounty programme and no budget for one. Credit is offered for
any report that leads to a change, if the reporter wants it.
