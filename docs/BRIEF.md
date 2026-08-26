# HOODZ — Master Brief

> Shared source of truth for every agent/contributor working on this repo.
> Read this before writing a single line.

## 1. What we are building

**Hoodz** is a 1:1 structural clone of the **Olympus DAO** protocol + website, rebranded.
Nothing about the mechanism design changes; only the naming, the chain, and the launch venue.

| Olympus            | Hoodz           |
| ------------------ | ------------------ |
| Olympus DAO        | Hoodz           |
| OHM                | HOODZ               |
| sOHM               | sHOODZ              |
| gOHM               | gHOODZ              |
| Ethereum L1        | **Robinhood Chain** (EVM L2) |
| Cooler Loans       | **Hoodz Loans**     |
| Emissions Manager  | Emissions Manager  |
| Yield Repurchase Facility (YRF) | Yield Repurchase Facility (YRF) |
| Convertible Deposits (CD) | Convertible Deposits (CD) |
| Olympus Treasury   | Hoodz Treasury      |

**The HOODZ token is launched on PONS** — the non-custodial launchpad of Robinhood Chain.
Everything token-launch related must be PONS-native (see §4).

## 2. Network facts (verified)

| Key | Mainnet | Testnet |
| --- | --- | --- |
| Name | Robinhood Chain | Robinhood Chain Testnet |
| Chain ID | `4663` | `46630` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` | `https://rpc.testnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` | `https://testnet.robinhoodchain.blockscout.com` |
| Gas token | ETH | ETH |
| EVM | fully equivalent, Cancun opcodes, Solidity/Vyper unmodified | same |

Tooling that works out of the box: Foundry, Hardhat, ethers.js, viem, wagmi.

## 3. Design system (extracted 1:1 from olympusdao.finance)

### 3.1 Color tokens
```css
--primary:        #efe9e0;  /* cream — page bg (light sections), text on dark */
--primary-light:  #eeebe2;
--primary-alt:    #a0853e;  /* muted gold */
--primary-300:    #f8cc82;  /* light gold */
--brand-black:    #141722;  /* navy-black — body text, buttons */
--true-black:     #000000;  /* dark sections bg */
--grey:           #7e7e7e;  /* hairline borders */
--gray-600:       #2c2e37;  /* feature card bg */
--slate:          #798399;  /* hero hairline + "stacking" card */
--gold-card:      #f3ce8c;  /* "bonding" card */
--white:          #ffffff;
```

### 3.2 Typography — **everything is `vw`-based**
```css
body  { font-size: 1vw;   line-height: 1.43; letter-spacing: .02em; font-weight: 400 }
h1,h2 { font-size: 3.7vw; line-height: 1.2;  font-weight: 500; letter-spacing: 0 }
h3    { font-size: 2.8vw; line-height: 1.2;  font-weight: 400 }
.t-80 { font-size: 2.7vw; font-weight: 500 }   /* big metric numbers */
.t-30 { font-size: 1.7vw }
.t-24 { font-size: 1.2vw; line-height: 1.1 }
.t-16 { font-size: .9vw;  line-height: 1.2 }
.nav__link, .btn { font-size: .9vw; font-weight: 500; text-transform: uppercase; line-height: 1.2 }
```
At `min-width:1920px` the `vw` units freeze:
`body 19.2px · h1 71.04px · h2 71px · h3 54px · .t-80 88.36px · .t-24 26.88px · .t-16/.nav/.btn 18px`

Font stack: Neue Haas Grotesk Display → we ship a free lookalike:
`"Inter Tight", "Neue Haas Grotesk Display", "Helvetica Neue", Helvetica, Arial, sans-serif`
(self-hosted or Google Fonts `Inter Tight` — grotesk, tight, same 500-weight feel).

### 3.3 Layout primitives
```css
.vertical-container   { padding-top: 66px; justify-content:center; align-items:stretch }
.horizontal-container { flex:1; max-width:1920px; margin: 60px auto 0;
                        padding-left:4.6vw; padding-right:4.6vw; position:relative }
@media (min-width:1920px){ .horizontal-container{ padding: 0 88.32px } }
```
Spacing scale (all `vw`, this is the signature of the site):
`mar-bot-4 .25vw · 8 .5vw · 12 .7vw · 16 .9vw · 24 1.4vw · 32 1.8vw · 40 2.3vw · 58 3.4vw · 80 4.6vw · 100 5.8vw · 130 7.5vw · 150 10.5vw · 240 14vw · 320 18.5vw`

Width caps: `max-width-400 → 23.15vw/444px` · `450 → 26.04vw/500px` · `500` · `550 → 31.83vw/611px` · `1300 → 75vw/1440px`

### 3.4 Buttons — the signature "text flip" hover
```html
<a class="btn-pr"><span class="btn-text-cont">
  <span class="btn-text-ghost">Enter App</span>   <!-- opacity:0; top:-100% -->
  <span class="btn-text">Enter App</span>
</span></a>
```
```css
.btn-pr { background: var(--brand-black); box-shadow: inset 0 0 0 2px var(--brand-black);
          color: var(--primary); border-radius: 100vw; padding: 1vw 1.85vw;
          font-size:.9vw; font-weight:500; line-height:1; text-transform:uppercase;
          white-space:nowrap; align-self:flex-start;
          transition: all .5s cubic-bezier(.19,1,.22,1) }
.btn-pr:hover { background: transparent }        /* fills → outline, text inverts */
.btn-pr.alt   { background: transparent; box-shadow: inset 0 0 0 2px var(--brand-black);
                color: var(--brand-black); transition-duration:.8s }
.btn-pr.alt:hover { background: var(--brand-black) }
.btn-pr.dark  { background: var(--primary); box-shadow: inset 0 0 0 2px var(--primary);
                color: var(--brand-black) }
.btn-text-cont  { display:flex; flex-direction:column; align-items:center; position:relative }
.btn-text-ghost { position:absolute; top:-100%; opacity:0; transition: all .4s }
.btn-text       { transition: all .4s }
/* on hover: ghost slides to top:0/opacity:1, real text slides to top:100%/opacity:0 */
```
At ≥1920px: `padding: 19.2px 35.52px; font-size: 18px`.
**Easing used everywhere: `cubic-bezier(.19, 1, .22, 1)` (expo-out), .5s–.8s.**

### 3.5 Cards
```css
.c-card            { background: var(--primary); border-radius: 2.3vw; position:relative; z-index:2 }
.c-card._w-border  { box-shadow: inset 0 0 0 1px var(--grey); padding: 3.8vw }
.c-card__anm       { transition: all .5s cubic-bezier(.19,1,.22,1);
                     box-shadow: 0 0 100px 18px transparent }
.c-card__anm:hover { box-shadow: 0 0 100px 18px rgba(0,0,0,.10) }   /* the big soft glow */
@media (min-width:1920px){ .c-card{ border-radius: 44.16px } }
```

### 3.6 Section anatomy of the homepage (top → bottom)
1. **Navbar** — `position:absolute; top:0; padding-top:3.2vw; background:transparent`.
   Left: wordmark (`width:7.5vw; max-width:144px`). Right: uppercase links (`gap 2.9vw`) +
   `GOVERNANCE` hover-dropdown + pill CTA `ENTER APP`. Burger ≤991px: pill with
   `inset 0 0 0 3px` ring, three 16×2px bars.
2. **Hero** `.s-hero.home-hero` — `padding: 6.2vw 0 18vw`, `border-bottom: 1px solid #798399`,
   cream bg, full-bleed looping animation behind (`z-index:1`, `overflow:hidden`), content `z-index:2`.
   h1 + paragraph (`max-width: 80ch`) + `ENTER APP` button.
3. **Protocol Stats** `.s-home__protocol` — bg `--true-black`, card pulled up `margin-top:-16vh`,
   `.c-card._w-border` cream card, 3 metric blocks in a row (`flex:1; max-width:30%`),
   `h4` "Protocol Stats" + `.t-24` label + `.t-80` value. Floating 3D object absolutely
   positioned `top:36%; left:-5%` (`width:17.9vw`) and a second at `top:50%; right:-8%` (`21vw`).
4. **4 × feature section** `.discover-section` — `background: var(--gray-600)`,
   `border-radius: 33px`, `padding: 33px`, flex `1fr / 1.8fr`, `gap: 32px`, `align-items:flex-end`.
   Alternating `illustration-right` / `illustration-left`. Title `h1.section-title` (line-height 1),
   paragraph `max-width:80ch`, two buttons (`gap:16px`) — one `.dark`, one `.alt.dark`.
   Illustration `object-fit:contain; height:21vw`, container `max-width:33vw`.
   Content column: `height:21vw; max-height:360px; justify-content:flex-end`.
5. **How to Participate** `.s-home__participate` — `padding-top:120px`, centered h2,
   2-col grid, **zero gap**, the two cards fuse into one pill:
   left `.stacking` bg `#798399` + `border-radius: 2.3vw 0 0 2.3vw`,
   right `.bonding` bg `#f3ce8c` + `border-radius: 0 2.3vw 2.3vw 0`.
   Card padding `3vw 3.7vw`, flex column, icon `7.75vw/149px` top-right,
   `h3.heading-5` weight 700, paragraph, button pinned bottom (`margin-top:auto`).
6. **FAQ** `.s-home__faq` — grid `.4fr 1fr`, `gap 3.3vw`. Left: h2 "FAQ" + button.
   Right: accordions `.faq-dd` — `border-bottom:1px solid var(--grey)`, `padding:1.85vw 3.8vw`,
   toggle row = circular `3.2vw/61px` icon ring (`inset 0 0 0 2px var(--grey)`) with a
   `+`→`−` cross (2px bars, 45% length) + `h3` question. Panel animates height.
7. **Prefooter CTA** `.s-cta-prefooter` — black, `padding-top:120px`, centered h2
   "Be smart, use HOODZ" + `ENTER HOODZ` `.btn-pr.dark`, giant artwork `75vw/1440px` below.
8. **Footer** `.footer` — bg `--brand-black`, grid `2fr 1fr 1fr 1fr`, `column-gap 5vw`,
   brand mark `11.1vw/213px`, newsletter pill input (`height 2.9vw; border-radius 100vw;
   padding .7vw 5.55vw .7vw 1.4vw`) with submit arrow inset right, social icons `2.9vw/55px`.

### 3.7 Motion
* `.slide-in` — elements start `translate3d(0,-30px,0); opacity:0` → animate to `0/1` on
  scroll-into-view, staggered ~90ms, `cubic-bezier(.19,1,.22,1)` .8s.
* Participate cards enter from `translate3d(0,20%,0); opacity:0`.
* Floating decorative objects parallax on scroll (`translate3d(0, 20% → -20%, 0)`, `will-change:transform`).
* Number counters roll up when the stats card enters the viewport.
* Marquee/looping hero animation behind the h1.
* Respect `prefers-reduced-motion: reduce` — kill transforms, keep opacity 1.

### 3.8 Breakpoints
`1920+` (freeze vw) · `≤991` (tablet: burger, stack feature grids, cards go full width & round on all corners) · `≤767` (mobile) · `≤479` (small mobile).
Below 991px switch the `vw` type scale to fixed px so text stays legible:
`h1/h2 40px · h3 28px · body 16px · .t-80 40px · buttons 14px`, container padding `24px`.

## 4. PONS launch requirements

PONS = the non-custodial launchpad on Robinhood Chain. V2 model:
1. Every token **starts on a bonding curve** (no instant LP).
2. On **graduation** the curve's reserves migrate into a **permanently locked Uniswap v4 pool**.
3. Trading fees flow back to the protocol; a share funds **buyback + burn**.
4. Non-custodial: the launchpad never holds user funds; every tx is signed by the user's wallet.

Implications for our contracts:
* `HOODZ` must be a clean, permissionless ERC20 at launch (no transfer tax, no blacklist,
  no pausable transfer) so it is PONS-compatible. Mint authority is granted **after**
  graduation to the Treasury/vault, guarded by `HoodzAuthority`.
* Ship `contracts/src/pons/` with:
  * `IPonsLaunchpad.sol` / `IPonsBondingCurve.sol` / `IPonsFeeRouter.sol` — interfaces we integrate against.
  * `PonsLaunchConfig.sol` — immutable, on-chain record of the launch parameters
    (curve reserve token, target raise, graduation threshold, LP fee tier, lock beneficiary).
  * `HoodzLaunchGuard.sol` — enforces that mint authority cannot move to the protocol
    before `graduated == true`, and that the LP position is locked forever.
  * `FeeRouterBuyback.sol` — receives protocol fee share, buys HOODZ on the graduated v4
    pool and burns it (mirrors PONS's own buyback-and-burn).
* Deploy script must support both `--chain 4663` and `--chain 46630`, and print a
  PONS-ready launch manifest (`docs/pons-launch.json`).

## 5. Repository layout
```
/web        static landing page (the 1:1 clone) — no build step, plain HTML/CSS/JS
/app        the dApp shell (dashboard, stake, bond, borrow, governance) — same design system
/contracts  Foundry-first Solidity (hardhat config provided too)
/docs       this brief, protocol docs, deployment manifest
```

## 6. Non-negotiables
* No external CDN assets in `/web` — artwork is **hand-authored SVG** in `web/assets/img/`
  (torus, coin, sphere, flow ribbons) with the gold/cream/slate gradient palette.
* No copied Olympus text verbatim where it names Olympus — rewrite for Hoodz.
* All Solidity `^0.8.24`, `SPDX-License-Identifier: AGPL-3.0-or-later`, NatSpec on every
  external function, custom errors (no revert strings), `immutable` where possible.
* Every contract file must compile standalone against OpenZeppelin v5 (`@openzeppelin/contracts`).
* This is unaudited educational/DeFi-clone code — every contract header carries a
  `/// @dev UNAUDITED. Do not use in production without a full audit.` banner.
