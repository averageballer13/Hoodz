# Hoodz — Contracts

> **UNAUDITED.** Every file in `src/` carries a `/// @dev UNAUDITED. Do not use in production
> without a full audit.` banner. This is an educational re-implementation of the Olympus DAO
> protocol, rebranded as **Hoodz** and targeted at **Robinhood Chain**. Do not deploy it with
> real value at risk until it has been professionally audited.

The Solidity half of the repo: the HOOD / sHOOD / gHOOD token trio, the staking + rebase engine,
the Hoodz Treasury, bonding, distribution, Hoodz Loans, and the PONS launch integration.

---

## 1. Network facts

| Key        | Mainnet                                     | Testnet                                      |
| ---------- | ------------------------------------------- | -------------------------------------------- |
| Name       | Robinhood Chain                             | Robinhood Chain Testnet                       |
| Chain ID   | `4663`                                      | `46630`                                       |
| RPC        | `https://rpc.mainnet.chain.robinhood.com`   | `https://rpc.testnet.chain.robinhood.com`     |
| Explorer   | `https://robinhoodchain.blockscout.com`     | `https://testnet.robinhoodchain.blockscout.com` |
| Gas token  | ETH                                         | ETH                                           |
| EVM        | fully equivalent, **Cancun** opcodes        | same                                          |

Foundry, Hardhat, ethers.js, viem and wagmi all work unmodified.

## 2. Compiler contract

Non-negotiable, identical across all three toolchains (`compile.js`, `foundry.toml`,
`hardhat.config.js`):

| Setting          | Value                     |
| ---------------- | ------------------------- |
| pragma           | `^0.8.24`                 |
| solc (Foundry/HH)| `0.8.24`                  |
| optimizer        | enabled, `runs = 200`     |
| `evm_version`    | `cancun`                  |
| license          | `AGPL-3.0-or-later`       |

`compile.js` runs whatever the `solc` npm package resolves to (`^0.8.26`, currently **0.8.36**);
the `^0.8.24` pragma accepts it and the settings above are pinned identically. Treat `compile.js`
as the fast type-check loop and `forge build` (pinned 0.8.24) as the source of deployable bytecode.

The install is deliberately tiny — `@openzeppelin/contracts` + `solc`, 11 packages total — so a
cold clone type-checks in seconds without Foundry or Hardhat.

## 3. Layout

```
contracts/
  src/
    interfaces/   IHoodzAuthority, IHOOD, IsHOOD, IgHOOD, IStaking, ITreasury, IDistributor, ...
    types/        HoodzAccessControlled — the shared role-gated base
    tokens/       HOOD, sHOOD, gHOOD
    modules/      treasury, bonding, distribution, staking internals
    policies/     governance-facing policy contracts
    pons/         PONS launchpad interfaces + launch config, guard, buyback router
  script/         Foundry deploy scripts (forge script)
  test/           Foundry tests (forge test)
  compile.js      standalone solc driver — no Foundry/Hardhat needed
  foundry.toml    primary toolchain config
  hardhat.config.js
  remappings.txt
```

### Access control

Every contract inherits `HoodzAccessControlled`, which reads its four roles from a single
`HoodzAuthority` (mirrors `OlympusAuthority`):

| Role       | Modifier         | Typical holder                     |
| ---------- | ---------------- | ---------------------------------- |
| `governor` | `onlyGovernor()` | DAO timelock / multisig            |
| `guardian` | `onlyGuardian()` | fast-response multisig             |
| `policy`   | `onlyPolicy()`   | policy multisig / policy contracts |
| `vault`    | `onlyVault()`    | the Hoodz Treasury (mint authority) |

### OpenZeppelin v5 notes

Declared as `@openzeppelin/contracts` `^5.0.2`; the current install resolves to **5.6.1**
(`npm ls @openzeppelin/contracts` to confirm). v5 breaks a lot of v4 muscle memory:

* `Ownable` **requires** an initial owner: `constructor() Ownable(msg.sender)`.
* `_beforeTokenTransfer` / `_afterTokenTransfer` are **gone** — override `_update(address from, address to, uint256 value)`.
* `SafeERC20` lives at `@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol`.
* `ERC20Votes` requires `Nonces`, an `_update` override, and a `nonces(address)` override
  (`ERC20Permit` and `Nonces` both declare it).
* `Counters`, `SafeMath`, `draft-ERC20Permit.sol` and `security/Pausable.sol` no longer exist
  (`Pausable` moved to `utils/Pausable.sol`).

Never invent an OZ symbol. If you are not certain it exists in v5, implement it locally.

---

## 4. Build

### Install

```bash
# from the repo root (npm workspaces) — or from contracts/, same result
npm install --no-audit --no-fund
```

### Compile — no Foundry required

```bash
npm run compile                          # from the repo root
node contracts/compile.js                # equivalent
node contracts/compile.js -q             # errors only
node contracts/compile.js --all-warnings # include warnings raised inside OpenZeppelin
```

Compiles every `.sol` under `src/` in a single standard-JSON invocation, groups diagnostics by
file, exits `1` on any error, and writes `contracts/out/artifacts.json`
(ABI + creation bytecode + runtime bytecode + method identifiers per contract, plus an
EIP-170 24 576-byte size warning).

Warnings raised inside `node_modules` are hidden by default — recent solc versions flag
OpenZeppelin's use of `error` and `at` as identifiers, which is noise you cannot fix and which
buries your own diagnostics. Errors are never hidden, wherever they come from.

### Compile — Foundry (primary)

```bash
cd contracts
forge build
forge test -vvv
forge fmt
forge coverage
forge build --sizes        # EIP-170 check
```

`forge-std` **is already vendored** at `lib/forge-std/` (plain files, no submodule), so
`forge test` runs as soon as Foundry is installed. Note that `.gitignore` excludes `lib/` — the
Foundry convention — so if you commit this repo, re-add it as a proper submodule instead:

```bash
forge install foundry-rs/forge-std --no-commit
```

OpenZeppelin is consumed from `node_modules` via `remappings.txt`, **not** from `lib/` — do not
`forge install` a second copy or you will get duplicate-symbol confusion.

### Compile — Hardhat (optional)

```bash
cd contracts
npm i -D hardhat @nomicfoundation/hardhat-toolbox dotenv
npx hardhat compile
```

`hardhat.config.js` guards its plugin requires, so it parses even when those dev deps are absent.

---

## 5. Deploy

```bash
cp ../.env.example ../.env    # then fill it in — never commit .env
```

Required: `PRIVATE_KEY`, the four `HOOD_*` role addresses, and the `PONS_*` launch parameters.

### Testnet (46630)

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url robinhood_testnet \
  --broadcast \
  --slow \
  --verify --verifier blockscout \
  --verifier-url https://testnet.robinhoodchain.blockscout.com/api \
  -vvvv
```

### Mainnet (4663)

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url robinhood \
  --broadcast \
  --slow \
  --verify --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api \
  -vvvv
```

`robinhood` and `robinhood_testnet` are named `[rpc_endpoints]` in `foundry.toml`, so
`--rpc-url robinhood` resolves without pasting a URL. The deploy script accepts
`--chain 4663` / `--chain 46630` and writes a PONS-ready launch manifest to `docs/pons-launch.json`.

Dry run first — omit `--broadcast` to simulate.

### Verify an already-deployed contract

```bash
forge verify-contract <ADDRESS> src/tokens/HOOD.sol:HOOD \
  --chain 4663 \
  --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api \
  --compiler-version 0.8.24 \
  --num-of-optimizations 200
```

---

## 6. PONS launch order

HOOD is launched through **PONS**, the non-custodial launchpad on Robinhood Chain. The token
starts on a bonding curve; on graduation the curve reserves migrate into a permanently locked
Uniswap v4 pool, and a share of trading fees funds buyback-and-burn.

That dictates the deployment order:

1. Deploy `HoodzAuthority` with the governor / guardian / policy / vault addresses.
2. Deploy `HOOD` as a **clean, permissionless ERC20** — no transfer tax, no blacklist, no
   pausable transfers. PONS will reject anything else.
3. Deploy `PonsLaunchConfig` recording the immutable launch parameters (reserve token, target
   raise, graduation threshold, LP fee tier, lock beneficiary).
4. Launch on PONS. Trade on the curve until the graduation threshold is met.
5. **Only after `graduated == true`**, `HoodzLaunchGuard` permits mint authority to move to the
   Treasury/vault. Before graduation the move reverts.
6. Deploy the protocol stack (Treasury, staking, sHOOD/gHOOD, distributor, bonding) and point
   `FeeRouterBuyback` at the graduated v4 pool.

Do not hand mint authority to the protocol before step 5 — the guard exists precisely to make
that mistake impossible on-chain.

---

## 7. Handy `cast` calls

```bash
cast chain-id            --rpc-url https://rpc.mainnet.chain.robinhood.com   # -> 4663
cast balance   <ADDR>    --rpc-url robinhood
cast call <HOOD> "totalSupply()(uint256)" --rpc-url robinhood
cast call <STAKING> "index()(uint256)"    --rpc-url robinhood
cast call <STAKING> "secondsToNextEpoch()(uint256)" --rpc-url robinhood
```

## 8. Conventions

* `pragma solidity ^0.8.24;` and `// SPDX-License-Identifier: AGPL-3.0-or-later` on every file.
* **Custom errors only** — no revert strings anywhere.
* NatSpec on every external function.
* `immutable` / `constant` wherever the value never changes after construction.
* The `UNAUDITED` banner comment at the top of every contract file.
