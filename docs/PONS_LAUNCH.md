# HOODZ Launch Runbook — PONS on Robinhood Chain

> **UNAUDITED.** Every contract referenced here carries the `/// @dev UNAUDITED` banner. Do not run
> this sequence on mainnet without a full audit.

This is the operational order of the HOODZ launch, the parameter set it runs on, and the specific way
each step can go wrong. Values live in [`pons-launch.json`](./pons-launch.json); this file explains
what they mean and in what order they become real.

The single design constraint everything below serves:

> **The protocol cannot mint HOODZ while HOODZ is still price-discovering.**

Between the first curve trade and the moment the Treasury receives mint authority, HOODZ's total supply
is frozen at exactly the amount minted before trading opened. That is enforced by `HoodzLaunchGuard`
sitting in the `vault` role with no mint function, not by a promise.

---

## 1. Parameters

### 1.1 Network

| Key | Mainnet | Testnet |
| --- | --- | --- |
| Name | Robinhood Chain | Robinhood Chain Testnet |
| Chain ID | `4663` | `46630` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` | `https://rpc.testnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` | `https://testnet.robinhoodchain.blockscout.com` |
| Gas token | ETH | ETH |
| EVM | Cancun, fully equivalent | Cancun, fully equivalent |

The deploy script takes `--chain 4663` or `--chain 46630` and rewrites `docs/pons-launch.json` in place.

### 1.2 Launch parameters

| Parameter | Where it is burned in | Meaning |
| --- | --- | --- |
| `hoodzToken` | `PonsLaunchConfig` immutable | The HOODZ ERC20. Clean, permissionless, no tax, no blacklist, no pausable transfers. |
| `reserveToken` | `PonsLaunchConfig` immutable | Quote asset the bonding curve collects. |
| `curve` | `PonsLaunchConfig` immutable | The PONS bonding curve escrow returned by `createToken`. |
| `targetRaise` | `PonsLaunchConfig` immutable | Total reserve the curve is sized to collect across its whole range. |
| `graduationThreshold` | `PonsLaunchConfig` immutable | Reserve balance at which the curve becomes graduatable. Must be `0 < x <= targetRaise`. |
| `lpFeeTier` | `PonsLaunchConfig` immutable | Fee tier of the graduated Uniswap v4 pool, in hundredths of a bip. `0x800000` = dynamic fee. |
| `lockBeneficiary` | `PonsLaunchConfig` immutable | Entitled to the locked position's **trading fees only**. Principal is withdrawable by nobody. |
| `launchTimestamp` | `PonsLaunchConfig` immutable | When the curve went live. Pass `0` to stamp deployment time. |
| `TREASURY` | `HoodzLaunchGuard` immutable | Sole possible destination of mint authority. |
| `TRANSFER_DELAY` | `HoodzLaunchGuard` constant | `48 hours`. Compiled in; governance cannot shorten it. |

Everything in the first eight rows is set once in a constructor and lives in deployed bytecode. There
is no setter, no owner and no upgrade path on `PonsLaunchConfig`. **A typo here is permanent.**

### 1.3 Roles (`HoodzAuthority`)

| Role | Held by | Can do |
| --- | --- | --- |
| `governor` | DAO multisig / timelock | `arm()`, `releaseToTreasury()`, `pointFeesHere()`, `setAuthority` |
| `guardian` | Guardian multisig | `abort()` — cancels a pending release and resets the 48h clock |
| `policy` | Policy multisig / keeper | `buybackAndBurn(minOut, deadline)` |
| `vault` | Launch operator → `HoodzLaunchGuard` → `HoodzTreasury` | Mint HOODZ |

The `vault` role is the whole story. It starts with the launch operator for exactly one mint, then
moves to the guard where it is inert, then to the Treasury. Nothing else ever holds it.

### 1.4 Contracts in this layer

| File | Role |
| --- | --- |
| `contracts/src/pons/IPonsLaunchpad.sol` | Launchpad read/integration surface |
| `contracts/src/pons/IPonsBondingCurve.sol` | Curve read surface (`reserves`, `supplySold`, `graduated`, `spotPrice`) |
| `contracts/src/pons/IPonsFeeRouter.sol` | Fee claim surface |
| `contracts/src/pons/IUniswapV4PoolManager.sol` | v4 `PoolKey`, pool-id derivation, liquidity cross-check |
| `contracts/src/pons/IPositionLocker.sol` | The permanently locked graduated LP position |
| `contracts/src/pons/PonsLaunchConfig.sol` | Immutable on-chain record of the launch |
| `contracts/src/pons/HoodzLaunchGuard.sol` | The safety rail on mint authority |
| `contracts/src/pons/FeeRouterBuyback.sol` | Protocol fee share → buy HOODZ → burn |

---

## 2. The ordering

Steps run strictly in order. Each one lists who signs it, what to verify before moving on, and what
the step actually risks.

### Step 0 — Full dry run on testnet (`--chain 46630`)

Run steps 1–12 end to end on chain `46630` against the real PONS testnet deployment, with the same
parameters, before touching mainnet.

**Risk if skipped:** the guard verifies the LP lock by reading `IPositionLocker.lockOf()` and hashing
the returned `PoolKey`. If the live locker's return shape or semantics differ from the interface in
this repo, `verifyGraduation()` reverts — and you will discover that only after mainnet supply is
already frozen behind the guard. The dry run is the only cheap place to find that out.

### Step 1 — Deploy `HoodzAuthority`

Signer: deployer. Set `governor`, `guardian`, `policy` to their multisigs and `vault` to the launch
operator.

Verify: all four getters return the intended addresses, and the governor multisig can actually sign
(do a no-op transaction from it).

**Risk:** a governor set to an address nobody controls bricks the launch at step 10 with supply
already frozen. A governor set to a single EOA makes every guarantee below worth exactly that EOA's
key hygiene.

### Step 2 — Deploy `HOODZ`

Signer: deployer. Mint gated on `HoodzAuthority.vault()`.

Verify on the deployed bytecode, not the source you think you deployed: no transfer tax, no
blacklist, no pausable transfers, no rebasing balances, and `mint` reachable only by the vault.

**Risk:** any transfer hook at all makes HOODZ incompatible with the PONS curve and with the Uniswap v4
pool it graduates into. This is discovered at step 4 or, worse, at step 8 as failing user trades.

### Step 3 — Mint the launch supply

Signer: launch operator (currently `vault`). One transaction. This is the **only** mint before
graduation.

Verify: `hoodz.totalSupply()` equals the published launch supply exactly. Publish the number and the
transaction hash before opening trading.

**Risk:** this is the single unguarded mint of the entire launch. Everything the guard does afterwards
is meaningless if the vault role is left on the operator key — see step 7, which must follow in the
same operational session.

### Step 4 — `createToken` on PONS

Signer: launch operator. Approve the launchpad for exactly the sellable supply, then call
`IPonsLaunchpad.createToken(params)` with `params.token = HOODZ`. Returns `(token, curve)`.

Verify: `launchpad.curveOf(HOODZ) == curve`, `curve.reserveToken()` and `curve.graduationThreshold()`
match the intended parameters, `curve.reserves() == 0`, `curve.graduated() == false`.

**Risk:** the approval is the exposure. Approve the sellable supply and nothing more, and confirm the
allowance is consumed to zero. Curve parameters are fixed on the PONS side once the curve exists — a
wrong `graduationThreshold` here cannot be corrected later, only abandoned.

### Step 5 — Deploy `PonsLaunchConfig`

Signer: deployer. Constructor takes the real `curve` from step 4.

Verify: read `manifest()` back and diff it field by field against `pons-launch.json`. Confirm the
`LaunchConfigured` event matches.

**Risk:** every field is immutable and `HoodzLaunchGuard` and `FeeRouterBuyback` both anchor to this
contract. A wrong `lpFeeTier` here silently routes every future buyback swap at the wrong fee tier —
i.e. to a pool that may not exist. Wrong values are only fixable by redeploying this contract *and*
everything that points at it, which is only possible before step 7.

### Step 6 — Deploy `HoodzTreasury`, then `HoodzLaunchGuard`

Signer: deployer. The Treasury must exist first, because the guard's destination is immutable.

```
HoodzLaunchGuard(authority, config, launchpad, locker, poolManager, treasury)
```

`poolManager` may be `address(0)` to skip the independent v4 liquidity cross-check; the locker checks
still apply.

Verify: `guard.TREASURY()`, `guard.HOODZ()`, `guard.CONFIG()` and `guard.HOODZ_AUTHORITY()` all read
back correct. `guard.released() == false`.

**Risk:** a wrong `TREASURY` sends mint authority to the wrong contract in step 12, irreversibly, with
no way to claw it back. Read it back from the chain before step 7 — not from the deploy log.

The Treasury is inert until step 12: it holds no vault role and can mint nothing.

### Step 7 — Freeze supply: push the vault role to the guard

Signer: governor. `authority.pushVault(address(guard), true)`.

Verify: `guard.holdsVaultRole() == true` and `authority.vault() == address(guard)`. Record
`hoodz.totalSupply()` — this number cannot change again until step 12.

**Risk:** this is the point of no return for the operator key, and it must happen *before* any public
trading. Trading that opens while the operator still holds the vault role is a launch where the team
can mint into its own market.

The escape hatch, deliberately preserved: the governor keeps `pushVault` on `HoodzAuthority`. If the
guard turns out to be mis-specified against the live PONS locker (step 9), governance can deploy a
corrected guard and push the vault role to it. Supply stays frozen throughout — the guard is a
credible commitment about *timing*, not a lock that can strand the protocol permanently.

### Step 8 — Public trading to graduation

Signer: the market. Nobody at Hoodz trades the curve from a contract; every buy is a user wallet
signing its own transaction, as PONS requires.

Anyone may call `launchpad.graduate(HOODZ)` once `curve.reserves() >= curve.graduationThreshold()`.
Graduation migrates reserves and remaining supply into the Uniswap v4 pool and locks the position.

Verify: `launchpad.isGraduated(HOODZ) == true`, `launchpad.poolOf(HOODZ) != address(0)`,
`curve.graduated() == true`.

**Risk:** this is an open market and the protocol does not control it.
- The threshold may never be reached. Reserve is not stranded — holders can still `sell()` back into
  the curve — but the launch simply does not complete and steps 9–15 never run.
- Sniping and MEV around the first blocks and around the graduation transaction itself. The curve's
  deterministic pricing bounds this but does not remove it.
- Do not "help" the curve over the line with protocol funds. It is the one action that would make the
  graduation threshold meaningless as a signal.

### Step 9 — Verify the pool is locked forever

Signer: anyone (permissionless). **Simulate first** with `eth_call`, then send:

```
guard.verifyGraduation()
```

This checks, and fails closed on every branch: the launchpad reports graduated; a locked position
exists for HOODZ in the pool the launchpad names; it holds non-zero liquidity; its `PoolKey` actually
hashes to its recorded `poolId`; `unlockable == false`; `unlockTime == type(uint256).max`;
`isPermanentlyLocked(HOODZ) == true`; and — if a `poolManager` was configured — the v4 singleton itself
reports non-zero liquidity for that pool id.

Verify independently, without trusting the guard: read `locker.lockOf(HOODZ)` yourself and confirm
`unlockable` is false and `unlockTime` is `type(uint256).max`.

**Risk:** if this call reverts, **stop**. Do not proceed to step 10. Either the launch did not
graduate the way the interfaces in this repo assume, or the position is not actually locked forever.
Both are reasons to redeploy a corrected guard (step 7's escape hatch), not to route around the check.

### Step 10 — Arm the release

Signer: governor. `guard.arm()`.

This starts the 48-hour countdown and emits `Armed(governor, armedAt, eligibleAt)`. Announce it
publicly with the `eligibleAt` timestamp.

**Risk:** the countdown is the whole point — it is the window in which HOODZ holders who do not want to
hold through a mint-capable protocol can leave. Arming quietly, or arming and releasing without
announcing, converts a governance guarantee into a surprise. `arm()` is callable before graduation by
design; doing so signals intent early, but the release still proves graduation and the lock
independently at step 12.

### Step 11 — Wait 48 hours

Nothing to sign. `guard.secondsUntilRelease()` and `guard.releaseStatus()` report progress without
reverting.

The guardian may call `guard.abort()` at any point, which zeroes `armedAt` and clears
`graduationVerified`. The governor can then re-run steps 9 and 10 and wait out another full 48 hours.

**Risk:** an `abort()` is loud and the market will read it as an emergency. Use it for one, not for
scheduling convenience. Note the asymmetry: the guardian can only delay, never veto — a guardian who
aborts repeatedly costs the protocol 48 hours per abort and nothing more.

### Step 12 — Release mint authority to the Treasury

Signer: governor. `guard.releaseToTreasury()`.

Re-checks live, in this block: graduation, the permanent LP lock, `armedAt != 0`, and 48 hours
elapsed. Then pushes the vault role to the immutable `TREASURY` and asserts that
`authority.vault() == TREASURY` actually landed, reverting with `HandoffFailed()` if it did not.

Verify: `authority.vault() == treasury`, `guard.released() == true`, `guard.holdsVaultRole() == false`.

**Risk:** irreversible. From this block on, the protocol can mint HOODZ. The guard is spent — `arm()`,
`verifyGraduation()` and `abort()` all revert with `AlreadyReleased()` forever.

Prerequisite for this call to succeed at all: `HoodzAuthority` must accept `pushVault` from the guard.
Confirm this on testnet in step 0 — it is the one integration assumption in the guard that only the
live authority can settle.

### Step 13 — Deploy the staking stack

Signer: deployer, then governor for wiring. `sHOODZ`, `gHOODZ`, `HoodzStaking`, `Distributor`, bond
depository. Set Treasury permissions (reserve tokens, reserve depositors, reward manager for the
Distributor).

Verify: `staking.index()` equals the initial index, epoch length and first epoch time are correct, and
`sHOODZ` is initialised against staking before the first rebase.

**Risk:** the Distributor is a reward manager on the Treasury — it mints. A reward rate set from a
copied constant rather than from this launch's actual supply and backing is how a clone protocol
inflates itself to zero in a week. Set it deliberately and low; it is far easier to raise later than
to explain a supply spike.

### Step 14 — Seed the Treasury

Signer: governor / policy. Deposit reserve assets via `treasury.deposit(amount, token, profit)`.

Verify: `treasury.excessReserves()`, `treasury.baseSupply()` and `treasury.tokenValue()` all read as
expected, and backing per HOODZ matches what you intend to publish.

**Risk:** `profit` is the portion of a deposit *not* minted back to the depositor. Getting it wrong
mints HOODZ against reserves that were never there. Do this before enabling emissions, not after, so
that the first rebase happens against a treasury whose backing is already correct and public.

### Step 15 — Point PONS fees at the buyback

Signer: deployer, then governor, then policy.

1. Deploy `FeeRouterBuyback(authority, config, feeRouter, swapRouter)`.
2. Governor: `buyback.pointFeesHere()` — only effective if this contract is the launch's registered
   fee owner on the PONS side; otherwise set the recipient through whichever account is.
3. Policy or keeper: `buyback.buybackAndBurn(minOut, deadline)` on a schedule.

`pendingFees()` returns `(held, claimable)` without reverting, so a keeper can decide whether a
buyback is worth the gas before sending one.

**Risk:** every buyback is a swap, and a swap sitting in the mempool with a loose `minOut` is a free
option for whoever is watching it. `minOut == 0` is rejected outright (`ZeroMinOut()`); quote against
the pool at send time and set `deadline` in minutes, not hours. The HOODZ bought is burned
unconditionally in the same transaction — nothing accumulates in the contract between calls, so a
failed or skipped buyback costs nothing but delay.

---

## 3. What the guard does and does not guarantee

**Does:**
- HOODZ supply cannot change between step 7 and step 12.
- Mint authority can only ever go to the `TREASURY` address fixed at step 6.
- It cannot go there until graduation and the permanent LP lock are both proven on-chain, in the same
  block as the transfer.
- There is a public, fixed 48-hour window between the governor's declared intent and the transfer.

**Does not:**
- Prevent the pre-graduation mint at step 3. That supply is whatever the launch operator minted, and
  the mitigation is publishing the number, not the contract.
- Prevent governance from minting after step 12. That is what step 12 *is*.
- Constrain how the Treasury spends what it mints. That is the staking stack's problem, and the
  Distributor's reward rate is where it actually gets decided.
- Survive a compromised governor multisig. The governor can push the vault role directly on
  `HoodzAuthority` at any time; the guard is a credible commitment by a governor acting in good faith,
  not a lock against one that is not.

## 4. Failure modes

| Symptom | Cause | Action |
| --- | --- | --- |
| `verifyGraduation()` reverts `NotGraduated` | Curve has not crossed the threshold, or `graduate()` was never called | Anyone may call `launchpad.graduate(HOODZ)` once reserves suffice |
| `verifyGraduation()` reverts `LpNotLocked` | Position missing, empty, unlockable, or the interface does not match the live locker | Stop. Read `locker.lockOf(HOODZ)` directly. If the lock is genuine, deploy a corrected guard and re-push the vault role |
| `releaseToTreasury()` reverts `NotArmed` | Never armed, or the guardian aborted | Governor re-runs `arm()` and waits the full 48h again |
| `releaseToTreasury()` reverts `DelayNotElapsed` | Less than 48h since `arm()` | Wait. `secondsUntilRelease()` reports how long |
| `releaseToTreasury()` reverts `HandoffFailed` | `HoodzAuthority` did not accept `pushVault` from the guard | Authority misconfiguration. Nothing is released; fix the authority's permissions and retry |
| `buybackAndBurn` reverts `NothingToBuy` | No reserve on hand and nothing claimable | Check `pendingFees()` before firing |
| `buybackAndBurn` reverts `InsufficientOutput` | Price moved past `minOut` | Re-quote and resend with a fresh `minOut` and `deadline` |

## 5. Checklist

Mirrors the `verification` block in `pons-launch.json`. None of these are true at the start.

- [ ] Sources verified on Blockscout
- [ ] HOODZ confirmed as a clean ERC20 on deployed bytecode
- [ ] Supply frozen: `authority.vault() == guard`, total supply published
- [ ] Curve graduated
- [ ] LP position independently confirmed permanently locked
- [ ] `verifyGraduation()` simulated, then executed
- [ ] 48h observed between `arm()` and `releaseToTreasury()`
- [ ] `authority.vault() == treasury`
