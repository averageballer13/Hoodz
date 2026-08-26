# Hoodz

**[hoodz.finance](https://hoodz.finance)** · **[@hoodzdao](https://x.com/hoodzdao)**

**A faithful, rebranded re-implementation of the Olympus DAO protocol, deployed on Robinhood Chain
(EVM, chainId `4663`), with the `HOODZ` token launched through the PONS launchpad.**

> ## UNAUDITED — EDUCATIONAL CLONE
>
> This repository is a **structural clone of Olympus DAO** written from scratch for study and
> experimentation. **No contract here has been audited.** Every Solidity file carries a
> `/// @dev UNAUDITED. Do not use in production without a full audit.` banner, and that banner is
> the literal truth.
>
> * Nothing in this repo is deployed. There is no official HOODZ token, no official website, no
>   team, no treasury, and no promise that any of the above will ever exist.
> * Do not send money to any address claiming to be this project.
> * This is **not** investment advice, not a securities offering, and not affiliated with,
>   endorsed by, or connected to Olympus DAO, Robinhood Markets, Inc., or PONS.
> * Rebasing tokens, bond markets, protocol-owned liquidity and collateralised lending can all
>   lose 100% of the value put into them. Read [`docs/SECURITY.md`](docs/SECURITY.md) before you
>   consider doing anything with this code.

---

## 0. Where things are right now

The site is **gated behind a coming-soon page**. `web/index.html` is that page; the full landing
lives at `web/home.html` and is reachable but not linked.

The mock dApp moved to `app-preview/` — **outside** the deployed directory. It renders invented
balances and yields, which is fine as a design preview and actively misleading on a live finance
site, so it is not served. Nothing about it is lost; point Vercel's output at it if you want it back.

`web/deploy.html` is a browser deployer for the contract stack. It reads creation bytecode from
`web/assets/deploy/bytecode.json` (regenerate it from `contracts/out/artifacts.json` after any
contract change) and sends one transaction per contract from the connected wallet, saving progress
so a failure resumes. **Use it for testnet.** For mainnet run `forge script script/Deploy.s.sol` —
it simulates the whole sequence first, wires roles atomically, and verifies in the same command.
Neither path wires roles for you; see `docs/DEPLOYMENT.md`.

## 1. What Hoodz is

Hoodz is a reserve-backed currency protocol. It has three jobs:

1. **Hold assets.** A treasury owns reserve tokens and protocol-owned liquidity. The value it
   holds per circulating HOODZ is the *backing*.
2. **Issue HOODZ against those assets.** New HOODZ is only ever minted against reserves the treasury
   actually holds — through bonds, through the Emissions Manager, or through Convertible Deposits.
   Each of those paths is designed to mint at a price *above* backing, so the backing per token
   rises rather than falls.
3. **Give holders something to do with it.** Stake it and receive the protocol's issuance as a
   rebase; borrow against it at a fixed 0.5% with no liquidations; vote with it.

Everything else in the repo — the staking index, the bond control variable, the yield repurchase
loop, the buyback funded by PONS trading fees — exists to serve one of those three jobs.

### The Olympus lineage, stated plainly

Hoodz is **not an original protocol**. Its mechanism design is Olympus DAO's, cloned
one-for-one. The token trio, the gons-based rebase, the treasury permission model, the bond
control variable, the emissions premium formula, the yield repurchase facility, the convertible
deposit auction and the no-liquidation loan book are all Olympus inventions. We changed the names,
the chain and the launch venue — nothing else.

| Olympus DAO                     | Hoodz                        |
| ------------------------------- | ------------------------------- |
| Olympus DAO                     | Hoodz                        |
| OHM                             | **HOODZ**                        |
| sOHM                            | **sHOODZ**                       |
| gOHM                            | **gHOODZ**                       |
| Ethereum L1                     | **Robinhood Chain** (EVM L2)    |
| Cooler Loans                    | **Hoodz Loans**                  |
| Olympus Treasury                | **Hoodz Treasury**               |
| `OlympusAuthority`              | `HoodzAuthority`                 |
| Emissions Manager               | Emissions Manager               |
| Yield Repurchase Facility (YRF) | Yield Repurchase Facility (YRF) |
| Convertible Deposits (CD)       | Convertible Deposits (CD)       |

The code is a re-implementation, not a fork: it is written against Solidity `^0.8.24` and
OpenZeppelin **v5**, whereas the audited Olympus contracts target older compilers and older
OpenZeppelin. **Semantic equivalence is the goal, not a guarantee.** Every one of those rewrites is
a place a bug can live that Olympus's auditors never looked at. The full list of deltas is in
[`docs/SECURITY.md`](docs/SECURITY.md).

Olympus DAO's contracts are AGPL-3.0; this repo is AGPL-3.0-or-later for the same reason.

---

## 2. Repository map

```
PONSDAO/
  web/                 Static marketing site. No build step - open web/index.html.
    css/hoodz.css       The whole design system (vw-based type scale, tokens, motion).
    assets/img/        Hand-authored SVG artwork. No CDN assets, ever.
  app/                 The dApp shell: dashboard, stake, bond, borrow, governance.
                       Same design system as /web.
  contracts/           Foundry-first Solidity. Hardhat config provided too.
    src/
      HoodzAuthority.sol         governor / guardian / policy / vault, in one place
      HoodzTreasury.sol          the vault: reserves, permissions, mint authority
      HoodzStaking.sol           epochs, warmup, the rebase trigger
      HoodzBondingCalculator.sol LP valuation for treasury accounting
      interfaces/      IHoodzAuthority, IHOODZ, IsHOODZ, IgHOODZ, IStaking, ITreasury, IDistributor, ...
      types/           HoodzAccessControlled - the shared role-gated base
      tokens/          HOODZ, sHOODZ, gHOODZ
      policies/        BondDepository, Distributor, EmissionsManager,
                       YieldRepurchaseFacility, ConvertibleDepository
      loans/           Hoodz Loans: Clearinghouse, Cooler, CoolerFactory
      governance/      HoodzGovernor, HoodzTimelock
      pons/            PONS launchpad interfaces, launch config, launch guard, buyback router
    script/            Foundry deploy scripts
    test/              Foundry tests
    compile.js         Standalone solc driver - type-checks without Foundry or Hardhat
    foundry.toml       Primary toolchain config
    hardhat.config.js
  docs/
    BRIEF.md           Master brief: naming, chain facts, design tokens, non-negotiables.
    PROTOCOL.md        How the protocol works, end to end, with diagrams.
    TOKENOMICS.md      Supply, backing, RFV, dilution, worked numbers.
    DEPLOYMENT.md      Deploy + role-wiring runbook for testnet then mainnet.
    PONS_LAUNCH.md     The PONS launch itself, step by step, with signers and checks.
    pons-launch.json   The launch manifest. Committed; rewritten by the deploy script.
    SECURITY.md        Threat model, deltas vs Olympus, audit scope, emergency procedures.
  .env.example         Copy to .env. Never commit .env.
  package.json         npm workspaces root.
```

`docs/BRIEF.md` is the source of truth for naming, chain facts and design tokens. If this README
and the brief ever disagree, the brief wins.

---

## 3. Quickstart

### 3.1 `/web` — the marketing site

There is no build step and no dependency to install.

```bash
open web/index.html          # macOS
start web\index.html         # Windows
xdg-open web/index.html      # Linux
```

If you would rather serve it over HTTP (needed the moment you add anything that uses `fetch`):

```bash
npx serve web
# or
python -m http.server 8080 --directory web
```

The type scale is `vw`-based and freezes at `min-width: 1920px`; below `991px` it switches to fixed
pixels. Check all four breakpoints (`1920+ / 991 / 767 / 479`) before you call a change done, and
check it once more with `prefers-reduced-motion: reduce` enabled.

### 3.2 `/app` — the dApp shell

Same story: static, no bundler, same stylesheet and tokens as `/web`.

```bash
npx serve app
```

Serve it rather than opening the file directly — wallet providers and `window.ethereum` behave
badly on `file://`. Point the app at Robinhood Chain Testnet (`46630`) while you work; contract
addresses come from the deployment manifest written by the deploy script.

### 3.3 `/contracts` — Solidity

```bash
npm install --no-audit --no-fund     # from the repo root; npm workspaces installs contracts/ too
npm run compile                      # standalone solc - no Foundry needed, seconds on a cold clone
```

`npm run compile` runs `contracts/compile.js`, which compiles everything under `src/` in one
standard-JSON invocation, groups diagnostics by file, exits non-zero on any error, and writes
`contracts/out/artifacts.json` (ABI, creation and runtime bytecode, method identifiers, plus an
EIP-170 24,576-byte size warning). Use it as the fast type-check loop.

Foundry is the primary toolchain and the source of deployable bytecode:

```bash
cd contracts
forge install foundry-rs/forge-std --no-commit   # once - forge-std is not vendored
forge build
forge test -vvv
forge fmt
forge coverage
forge build --sizes
```

OpenZeppelin is consumed from `node_modules` through `remappings.txt`. Do **not** `forge install`
a second copy of it.

Hardhat is optional and only needed for ethers.js-based tooling:

```bash
cd contracts
npm i -D hardhat @nomicfoundation/hardhat-toolbox dotenv
npx hardhat compile
```

All three toolchains are pinned to the same compiler contract: solc `0.8.24`, optimizer on with
`runs = 200`, `evm_version = cancun`, `bytecode_hash = none`.

### 3.4 Solidity house rules

Non-negotiable, enforced by review:

* `pragma solidity ^0.8.24;` and `// SPDX-License-Identifier: AGPL-3.0-or-later` on every file.
* The `/// @dev UNAUDITED. Do not use in production without a full audit.` banner on every file.
* **Custom errors only.** No revert strings anywhere.
* NatSpec on every external function.
* `immutable` / `constant` wherever the value cannot change after construction.
* Access control comes from `HoodzAuthority` via the `HoodzAccessControlled` base
  (`governor` / `guardian` / `policy` / `vault`). Do not roll your own `Ownable` on a protocol
  contract.
* OpenZeppelin **v5** API. `Ownable(initialOwner)`; `_update` instead of `_beforeTokenTransfer`;
  `SafeERC20` at `token/ERC20/utils/SafeERC20.sol`; `ERC20Votes` needs `Nonces` plus `_update` and
  `nonces()` overrides. `Counters`, `SafeMath` and `draft-ERC20Permit.sol` do not exist in v5.
  **Never invent an OZ symbol** — if you are not certain it exists, implement it locally.

---

## 4. Robinhood Chain

| Key       | Mainnet                                     | Testnet                                         |
| --------- | ------------------------------------------- | ----------------------------------------------- |
| Name      | Robinhood Chain                             | Robinhood Chain Testnet                          |
| Chain ID  | `4663`                                      | `46630`                                          |
| RPC       | `https://rpc.mainnet.chain.robinhood.com`   | `https://rpc.testnet.chain.robinhood.com`        |
| Explorer  | `https://robinhoodchain.blockscout.com`     | `https://testnet.robinhoodchain.blockscout.com`  |
| Gas token | ETH                                         | ETH                                              |
| EVM       | fully equivalent, **Cancun** opcodes        | same                                             |

Solidity and Vyper are unmodified. Foundry, Hardhat, ethers.js, viem and wagmi all work out of the
box. Both networks are pre-declared in `foundry.toml` (`--rpc-url robinhood`,
`--rpc-url robinhood_testnet`) and in `hardhat.config.js` (`robinhood`, `robinhoodTestnet`).

Blockscout is Etherscan-API compatible, so `forge verify-contract --verifier blockscout` and the
Hardhat verify plugin both work. Exact commands: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

Sanity-check your RPC before anything else:

```bash
cast chain-id --rpc-url https://rpc.mainnet.chain.robinhood.com   # -> 4663
```

---

## 5. The PONS launch

**PONS** is the non-custodial launchpad on Robinhood Chain. HOODZ launches there, and that
constrains both the token and the deployment order.

How PONS V2 works:

1. Every token **starts on a bonding curve**. There is no instant LP and no pre-seeded pool.
2. On **graduation** — when the curve's reserves cross the graduation threshold — those reserves
   migrate into a **permanently locked Uniswap v4 pool**.
3. Trading fees from that pool flow back to the protocol, and a share of them funds
   **buyback-and-burn**.
4. It is non-custodial end to end: the launchpad never holds user funds, and every transaction is
   signed by the user's own wallet.

What that forces on us:

* **HOODZ must be a clean, permissionless ERC20 at launch.** No transfer tax, no blacklist, no
  pausable transfers, no hooks on transfer. PONS will reject anything else, and so should you.
* **Supply is frozen while HOODZ is price-discovering.** The `vault` role — the only role that can
  mint HOODZ — moves: launch operator (for exactly **one** mint, the launch supply) →
  **`HoodzLaunchGuard`** → `HoodzTreasury`. The guard has no mint function at all, so while it holds
  the role, total supply cannot change. Nothing else ever holds `vault`.
* **Mint authority reaches the treasury only after graduation is proven on-chain.** The guard's
  `releaseToTreasury()` re-checks, in the same block, that the curve graduated, that the LP
  position is permanently locked, and that a governor-signed `arm()` was followed by a compiled-in
  **48-hour delay** that governance cannot shorten. The guardian can `abort()` a pending release
  and reset the clock. The destination is an immutable address baked into the guard.
* **The LP lock is permanent.** The lock beneficiary is entitled to the position's *trading fees
  only*; the principal is withdrawable by nobody. No unlock path, no timelock, no override.
* `contracts/src/pons/` holds the integration surface: `IPonsLaunchpad`, `IPonsBondingCurve`,
  `IPonsFeeRouter` and `IPositionLocker` (the interfaces we integrate against), `PonsLaunchConfig`
  (an immutable on-chain record of the launch parameters — HOODZ, reserve token, curve, target
  raise, graduation threshold, LP fee tier, lock beneficiary, launch timestamp),
  `HoodzLaunchGuard`, and `FeeRouterBuyback` (receives the protocol fee share, buys HOODZ on the
  graduated v4 pool, burns it in the same transaction).
* The deploy script supports `--chain 4663` and `--chain 46630` and writes a PONS-ready launch
  manifest to `docs/pons-launch.json`.

Launch order in one line: **authority → clean HOODZ → one launch mint → PONS curve → vault role to
the guard (supply frozen) → graduation + LP lock verified → `arm()` → 48 hours →
`releaseToTreasury()`.**
The step-by-step, with signers, verifications and failure modes, is in
[`docs/PONS_LAUNCH.md`](docs/PONS_LAUNCH.md); the surrounding protocol deployment is in
[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

---

## 6. Documentation

| Document                                     | Read it when you want to know…                                        |
| -------------------------------------------- | --------------------------------------------------------------------- |
| [`docs/BRIEF.md`](docs/BRIEF.md)             | Naming, chain facts, design tokens, non-negotiables. Source of truth.  |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md)       | How every moving part works, and how value flows between them.         |
| [`docs/TOKENOMICS.md`](docs/TOKENOMICS.md)   | Supply, backing, RFV, dilution, and worked arithmetic.                 |
| [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)   | The deploy runbook and the post-deploy checklist.                      |
| [`docs/PONS_LAUNCH.md`](docs/PONS_LAUNCH.md) | The launch itself, step by step: signers, checks, failure modes.       |
| [`docs/pons-launch.json`](docs/pons-launch.json) | The launch manifest. Machine-readable, rewritten by the deploy script. |
| [`docs/SECURITY.md`](docs/SECURITY.md)       | What can go wrong, what an audit must cover, how to shut things off.   |
| [`contracts/README.md`](contracts/README.md) | Toolchain detail, build flags, `cast` recipes.                         |

New to Olympus-style protocols? Read `docs/PROTOCOL.md` §2 (the token trio) and §3 (the rebase
loop) first. Nothing else in the repo makes sense until those two click.

---

## 7. Contributing

* Read `docs/BRIEF.md` first. It is the contract between contributors.
* Match the existing design system exactly — no new colours, no new type sizes, no CDN assets in
  `/web` or `/app`. Artwork is hand-authored SVG in `web/assets/img/`.
* Do not copy Olympus's marketing copy. Naming the lineage is required; reproducing their prose is
  not. Rewrite everything in Hoodz's own words.
* Solidity: see §3.4. Every file must compile standalone.
* Never commit `.env`, a private key, or a deployment broadcast containing one.

---

## 8. Licence and disclaimer

Licensed under **AGPL-3.0-or-later**. See the SPDX header on every source file.

This software is provided "as is", without warranty of any kind, express or implied. The authors
are not liable for any claim, damages, or other liability arising from the software or its use.

**Hoodz is an unaudited educational clone.** It is not affiliated with, endorsed by, or
connected to Olympus DAO, Robinhood Markets, Inc., or the PONS launchpad. "Robinhood" and
"Olympus DAO" are the marks of their respective owners and are used here only to identify the
chain this code targets and the protocol this code re-implements. Nothing in this repository is
financial, investment, legal or tax advice.
