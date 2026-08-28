/* ============================================================================
   HOOD — dApp shell runtime
   Plain ES5-ish browser JS. No build step, no dependencies, no CDN.

   Everything except the wallet connection is MOCK DATA (see MOCK banner).
   Contract ABIs + the address book live in abi.js (window.HOOD_ABI / HOOD_NET).
   ========================================================================== */
(function (global, doc) {
  "use strict";

  /* ======================================================================
     0. tiny DOM helpers
     ==================================================================== */
  function $(sel, root) { return (root || doc).querySelector(sel); }
  function $$(sel, root) {
    return Array.prototype.slice.call((root || doc).querySelectorAll(sel));
  }
  function on(el, type, fn, opts) { if (el) el.addEventListener(type, fn, opts || false); }
  function reducedMotion() {
    return global.matchMedia && global.matchMedia("(prefers-reduced-motion: reduce)").matches;
  }

  /* ======================================================================
     1. MOCK DATA MODULE
     Nothing here is read from a chain. Replace with live reads once the
     addresses in abi.js are filled by the deploy script.
     ==================================================================== */
  var MOCK = {
    asOf: "2026-08-26T00:00:00Z",

    token: {
      symbol: "HOOD",
      decimals: 9,
      price: 12.47,
      priceChange24h: 0.0184
    },

    supply: {
      total: 3811420.394817263,
      circulating: 3233190.472913481,
      staked: 2190470.118934720
    },

    treasury: {
      marketValue: 44912600,
      backingPerHoodz: 11.68,
      runwayDays: 2485,
      /* liquid reserves by asset, USD */
      holdings: [
        { asset: "USDC",       value: 21840300, kind: "stable" },
        { asset: "wstETH",     value: 9612400,  kind: "volatile" },
        { asset: "WETH",       value: 4108900,  kind: "volatile" },
        { asset: "HOOD-USDC",  value: 2202064,  kind: "lp" },
        { asset: "Illiquid",   value: 7148936,  kind: "illiquid" }
      ]
    },

    staking: {
      index: 269.4523,
      epochNumber: 4821,
      epochLengthSec: 28800,           /* 8h → 3 rebases/day */
      rebaseRate: 0.00006357,          /* per epoch */
      warmupEpochs: 0
    },

    /* 12 months of liquid backing per HOOD — mirrors the dashboard chart */
    backingSeries: [
      { label: "Sep '25", value: 8.94 },
      { label: "Oct '25", value: 9.21 },
      { label: "Nov '25", value: 9.48 },
      { label: "Dec '25", value: 9.62 },
      { label: "Jan '26", value: 9.95 },
      { label: "Feb '26", value: 10.31 },
      { label: "Mar '26", value: 10.44 },
      { label: "Apr '26", value: 10.79 },
      { label: "May '26", value: 11.02 },
      { label: "Jun '26", value: 11.24 },
      { label: "Jul '26", value: 11.41 },
      { label: "Aug '26", value: 11.68 }
    ],

    /* the "connected" demo wallet */
    wallet: {
      address: null,
      hoodz: 1284.372910044,
      sHoodz: 3120.884210331,
      gHoodz: 6.421800000000000000,
      reserve: 24810.42,               /* USDC */
      reserveSymbol: "USDC",
      delegate: null
    },

    /* Hoodz Loans (Cooler-style) parameters */
    loans: {
      oltc: 2894.12,                   /* reserve borrowable per gHOOD */
      interestRate: 0.005,             /* 0.5% fixed, annualised */
      durationDays: 121,
      open: [
        { id: 12, collateral: 4.5,  principal: 13023.54, interest: 21.58, daysToExpiry: 84 },
        { id: 9,  collateral: 2.0,  principal: 5788.24,  interest: 9.59,  daysToExpiry: 12 },
        { id: 4,  collateral: 1.25, principal: 3617.65,  interest: 6.00,  daysToExpiry: -3 }
      ]
    },

    /* quote-token spot prices used by the bond drawer */
    quotePrices: {
      "USDC": 1.00,
      "USDT": 1.00,
      "WETH": 3120.55,
      "wstETH": 3684.10,
      "HOOD-USDC": 46.28
    }
  };

  /* ---------- derived values: one source of truth for every page ---------- */
  function derive() {
    var t = MOCK.token, s = MOCK.supply, tr = MOCK.treasury, st = MOCK.staking, w = MOCK.wallet;
    var epochsPerYear = (365 * 24 * 3600) / st.epochLengthSec;
    var apy = Math.pow(1 + st.rebaseRate, epochsPerYear) - 1;
    var liquidBacking = tr.backingPerHoodz * s.circulating;

    return {
      marketCap: t.price * s.circulating,
      fdv: t.price * s.total,
      liquidBacking: liquidBacking,
      premium: (t.price / tr.backingPerHoodz) - 1,
      stakingRatio: s.staked / s.circulating,
      apy: apy,
      fiveDayRoi: Math.pow(1 + st.rebaseRate, 15) - 1,
      nextRewardYield: st.rebaseRate,
      nextRewardAmount: w.sHoodz * st.rebaseRate,
      stakedUsd: w.sHoodz * t.price,
      gHoodzInHoodz: w.gHoodz * st.index,
      gHoodzUsd: w.gHoodz * st.index * t.price,
      maxBorrow: w.gHoodz * MOCK.loans.oltc,
      loanDebt: MOCK.loans.open.reduce(function (a, l) { return a + l.principal + l.interest; }, 0),
      loanCollateral: MOCK.loans.open.reduce(function (a, l) { return a + l.collateral; }, 0),
      epochsPerYear: epochsPerYear
    };
  }

  /* ======================================================================
     2. NUMBER FORMATTING
     ==================================================================== */
  var LOCALE = "en-US";

  function nf(min, max) {
    try {
      return new Intl.NumberFormat(LOCALE, {
        minimumFractionDigits: min,
        maximumFractionDigits: max
      });
    } catch (e) { return null; }
  }
  var f2 = nf(2, 2), f0 = nf(0, 0), f4 = nf(4, 4), f9 = nf(9, 9);

  function fixed(n, dp) {
    var v = Number(n);
    if (!isFinite(v)) return "—";
    var fmt = dp === 0 ? f0 : dp === 2 ? f2 : dp === 4 ? f4 : dp === 9 ? f9 : nf(dp, dp);
    return fmt ? fmt.format(v) : v.toFixed(dp);
  }

  /** $1,234.56 */
  function usd(n, dp) {
    var v = Number(n);
    if (!isFinite(v)) return "—";
    var sign = v < 0 ? "-" : "";
    return sign + "$" + fixed(Math.abs(v), dp === undefined ? 2 : dp);
  }

  /** $40.32M — compact USD for headline metrics */
  function compactUsd(n) {
    var v = Number(n);
    if (!isFinite(v)) return "—";
    var sign = v < 0 ? "-" : "";
    var a = Math.abs(v);
    var units = [
      [1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "K"]
    ];
    for (var i = 0; i < units.length; i++) {
      if (a >= units[i][0]) {
        var scaled = a / units[i][0];
        return sign + "$" + fixed(scaled, scaled >= 100 ? 1 : 2) + units[i][1];
      }
    }
    return sign + "$" + fixed(a, 2);
  }

  /** HOOD is a 9-decimal token: 1,284.372910044 */
  function hoodz(n, dp) {
    var v = Number(n);
    if (!isFinite(v)) return "—";
    return fixed(v, dp === undefined ? 4 : dp);
  }
  /** full 9-decimal precision, the way the contract stores it */
  function hoodz9(n) { return fixed(n, 9); }

  /** 7.21% */
  function pct(n, dp) {
    var v = Number(n);
    if (!isFinite(v)) return "—";
    return fixed(v * 100, dp === undefined ? 2 : dp) + "%";
  }
  /** +1.84% / -0.62% */
  function signedPct(n, dp) {
    var v = Number(n);
    if (!isFinite(v)) return "—";
    return (v > 0 ? "+" : "") + pct(v, dp);
  }

  /** 0x1234…abcd */
  function shortAddr(a) {
    if (!a || a.length < 12) return a || "—";
    return a.slice(0, 6) + "…" + a.slice(-4);
  }

  /** 3d 4h 12m / 5h 42m 09s */
  function duration(seconds, style) {
    var s = Math.max(0, Math.floor(seconds));
    var d = Math.floor(s / 86400); s -= d * 86400;
    var h = Math.floor(s / 3600);  s -= h * 3600;
    var m = Math.floor(s / 60);    s -= m * 60;
    function pad(n) { return (n < 10 ? "0" : "") + n; }
    if (style === "long" && d > 0) return d + "d " + h + "h " + pad(m) + "m";
    if (d > 0) return d + "d " + pad(h) + "h " + pad(m) + "m";
    return h + "h " + pad(m) + "m " + pad(s) + "s";
  }

  function days(n) {
    var v = Math.round(Number(n));
    return fixed(v, 0) + (Math.abs(v) === 1 ? " day" : " days");
  }

  function dateShort(ts) {
    try {
      return new Date(ts).toLocaleDateString(LOCALE, {
        year: "numeric", month: "short", day: "numeric"
      });
    } catch (e) { return "—"; }
  }

  var fmt = {
    fixed: fixed, usd: usd, compactUsd: compactUsd, hoodz: hoodz, hoodz9: hoodz9,
    pct: pct, signedPct: signedPct, shortAddr: shortAddr, duration: duration,
    days: days, dateShort: dateShort
  };

  /* ======================================================================
     3. BINDINGS — [data-bind="key"] gets its text from the value map
     Static HTML already carries the same numbers so the pages read fine
     with JavaScript disabled; this just keeps one source of truth.
     ==================================================================== */
  function valueMap() {
    var d = derive(), t = MOCK.token, s = MOCK.supply, tr = MOCK.treasury,
        st = MOCK.staking, w = MOCK.wallet, ln = MOCK.loans;

    return {
      price:            usd(t.price),
      priceChange:      signedPct(t.priceChange24h),
      marketCap:        compactUsd(d.marketCap),
      fdv:              compactUsd(d.fdv),
      treasuryValue:    compactUsd(tr.marketValue),
      liquidBacking:    compactUsd(d.liquidBacking),
      backingPerHoodz:   usd(tr.backingPerHoodz),
      premium:          pct(d.premium),
      index:            fixed(st.index, 4),
      apy:              pct(d.apy),
      runway:           days(tr.runwayDays),
      runwayYears:      fixed(tr.runwayDays / 365, 1) + " yrs",
      totalSupply:      hoodz(s.total, 2),
      circulatingSupply: hoodz(s.circulating, 2),
      stakedSupply:     hoodz(s.staked, 2),
      stakingRatio:     pct(d.stakingRatio),
      epochNumber:      fixed(st.epochNumber, 0),
      epochLength:      Math.round(st.epochLengthSec / 3600) + "h",
      rebasesPerDay:    String(Math.round(86400 / st.epochLengthSec)),
      rebaseRate:       pct(st.rebaseRate, 6),
      nextRewardYield:  pct(d.nextRewardYield, 4),
      nextRewardAmount: hoodz(d.nextRewardAmount, 4),
      fiveDayRoi:       pct(d.fiveDayRoi, 4),

      walletHoodz:       hoodz(w.hoodz, 4),
      walletHoodz9:      hoodz9(w.hoodz),
      walletSHoodz:      hoodz(w.sHoodz, 4),
      walletGHoodz:      fixed(w.gHoodz, 4),
      walletReserve:    fixed(w.reserve, 2),
      reserveSymbol:    w.reserveSymbol,
      stakedUsd:        usd(d.stakedUsd),
      gHoodzInHoodz:      hoodz(d.gHoodzInHoodz, 4),
      gHoodzUsd:         usd(d.gHoodzUsd),

      oltc:             fixed(ln.oltc, 2),
      oltcUsd:          usd(ln.oltc),
      loanRate:         pct(ln.interestRate, 2),
      loanDuration:     days(ln.durationDays),
      maxBorrow:        fixed(d.maxBorrow, 2),
      loanDebt:         fixed(d.loanDebt, 2),
      loanCollateral:   fixed(d.loanCollateral, 4),
      openLoans:        String(ln.open.length),

      votingPower:      fixed(w.gHoodz, 4),
      delegateLabel:    w.delegate ? shortAddr(w.delegate) : "Not delegated",
      walletLabel:      w.address ? shortAddr(w.address) : "Not connected",
      asOf:             dateShort(MOCK.asOf)
    };
  }

  /**
   * Bindings are switched off.
   *
   * valueMap() is built entirely from MOCK, and writing those figures into the
   * page would put invented balances, yields and treasury totals in front of
   * people on a live finance site. The contracts are deployed but not wired to
   * each other, and HOOD has not launched, so there is genuinely nothing to
   * read yet - every bound element stays as an em-dash.
   *
   * To switch this back on, replace valueMap() with real contract reads. Do not
   * simply delete this guard: the mock numbers are still below it.
   */
  var BINDINGS_ENABLED = false;

  function applyBindings(root) {
    if (!BINDINGS_ENABLED) return;
    var map = valueMap();
    $$("[data-bind]", root || doc).forEach(function (el) {
      var key = el.getAttribute("data-bind");
      if (Object.prototype.hasOwnProperty.call(map, key)) el.textContent = map[key];
    });
    /* delta colouring */
    $$("[data-delta]").forEach(function (el) {
      var v = parseFloat(el.getAttribute("data-delta"));
      el.classList.toggle("up", v > 0);
      el.classList.toggle("down", v < 0);
    });
  }

  /* ======================================================================
     4. COUNTDOWNS
     [data-countdown="rebase"]        → next epoch boundary
     [data-countdown-until="<unix s>"] → arbitrary target
     ==================================================================== */
  function nextRebaseSeconds() {
    var len = MOCK.staking.epochLengthSec;
    var now = Math.floor(Date.now() / 1000);
    return len - (now % len);
  }

  var COUNTDOWN_SEL = "[data-countdown], [data-countdown-until], [data-countdown-in]";

  function tickCountdowns() {
    var nodes = $$(COUNTDOWN_SEL);
    if (!nodes.length) return;
    var now = Math.floor(Date.now() / 1000);
    nodes.forEach(function (el) {
      var secs;
      /* data-countdown-in="<seconds>" is resolved against page load, so the
         mock vesting/expiry dates never go stale. */
      if (el.hasAttribute("data-countdown-in") && !el.hasAttribute("data-countdown-until")) {
        el.setAttribute("data-countdown-until",
          String(now + Number(el.getAttribute("data-countdown-in"))));
      }
      if (el.hasAttribute("data-countdown-until")) {
        secs = Number(el.getAttribute("data-countdown-until")) - now;
      } else {
        secs = nextRebaseSeconds();
      }
      if (secs <= 0) {
        el.textContent = el.getAttribute("data-countdown-done") || "Ready";
        return;
      }
      el.textContent = duration(secs, el.getAttribute("data-countdown-style") || "");
    });
  }

  function startCountdowns() {
    if (!$$(COUNTDOWN_SEL).length) return;
    tickCountdowns();
    global.setInterval(tickCountdowns, 1000);
  }

  /* ======================================================================
     5. TABS — roving tabindex, arrow-key navigable
     ==================================================================== */
  function initTabs() {
    $$("[data-tabs]").forEach(function (group) {
      var tabs = $$('[role="tab"]', group);
      if (!tabs.length) return;

      /* Hide every panel first, then reveal the selected one. Several tabs may
         legitimately point at the SAME panel (one panel whose content swaps),
         so order matters here. */
      function select(tab, focus) {
        tabs.forEach(function (t) {
          t.setAttribute("aria-selected", t === tab ? "true" : "false");
          t.tabIndex = t === tab ? 0 : -1;
          var panel = doc.getElementById(t.getAttribute("aria-controls"));
          if (panel) panel.hidden = true;
        });
        var shown = doc.getElementById(tab.getAttribute("aria-controls"));
        if (shown) {
          shown.hidden = false;
          shown.setAttribute("aria-labelledby", tab.id);
        }
        if (focus) tab.focus();
        group.dispatchEvent(new CustomEvent("tabchange", {
          bubbles: true,
          detail: { value: tab.getAttribute("data-tab-value") || tab.id, tab: tab }
        }));
      }

      tabs.forEach(function (tab, i) {
        on(tab, "click", function () { select(tab, false); });
        on(tab, "keydown", function (e) {
          var next = null;
          if (e.key === "ArrowRight" || e.key === "ArrowDown") next = tabs[(i + 1) % tabs.length];
          else if (e.key === "ArrowLeft" || e.key === "ArrowUp") next = tabs[(i - 1 + tabs.length) % tabs.length];
          else if (e.key === "Home") next = tabs[0];
          else if (e.key === "End") next = tabs[tabs.length - 1];
          if (next) { e.preventDefault(); select(next, true); }
        });
      });

      var initial = tabs.filter(function (t) { return t.getAttribute("aria-selected") === "true"; })[0] || tabs[0];
      select(initial, false);
    });
  }

  /* ======================================================================
     6. DRAWER — modal side panel with focus trap
     ==================================================================== */
  var FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), ' +
                  'select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
  var openDrawer = null, drawerReturnFocus = null;

  function drawerScrim() {
    var el = $(".drawer-scrim");
    if (!el) {
      el = doc.createElement("div");
      el.className = "drawer-scrim";
      el.setAttribute("data-drawer-scrim", "");
      doc.body.appendChild(el);
      on(el, "click", closeDrawer);
    }
    return el;
  }

  function showDrawer(id, trigger) {
    var el = typeof id === "string" ? doc.getElementById(id) : id;
    if (!el) return;
    drawerReturnFocus = trigger || doc.activeElement;
    openDrawer = el;
    el.setAttribute("data-open", "true");
    el.removeAttribute("aria-hidden");
    drawerScrim().setAttribute("data-open", "true");
    doc.documentElement.style.overflow = "hidden";
    /* the panel is visibility:hidden until styles recalc, so focus on the
       next frame or the call is a no-op */
    global.requestAnimationFrame(function () {
      global.requestAnimationFrame(function () {
        var first = $$(FOCUSABLE, el)[0];
        if (first && openDrawer === el) first.focus();
      });
    });
    el.dispatchEvent(new CustomEvent("draweropen", { bubbles: true, detail: { trigger: trigger } }));
  }

  function closeDrawer() {
    if (!openDrawer) return;
    var el = openDrawer;
    openDrawer = null;
    el.setAttribute("data-open", "false");
    el.setAttribute("aria-hidden", "true");
    var scrim = $(".drawer-scrim");
    if (scrim) scrim.setAttribute("data-open", "false");
    doc.documentElement.style.overflow = "";
    if (drawerReturnFocus && drawerReturnFocus.focus) drawerReturnFocus.focus();
    drawerReturnFocus = null;
  }

  function initDrawers() {
    $$(".drawer").forEach(function (el) { el.setAttribute("aria-hidden", "true"); });
    $$("[data-drawer-open]").forEach(function (btn) {
      on(btn, "click", function () { showDrawer(btn.getAttribute("data-drawer-open"), btn); });
    });
    $$("[data-drawer-close]").forEach(function (btn) { on(btn, "click", closeDrawer); });
    if ($(".drawer")) drawerScrim();

    on(doc, "keydown", function (e) {
      if (!openDrawer) return;
      if (e.key === "Escape") { e.preventDefault(); closeDrawer(); return; }
      if (e.key !== "Tab") return;
      var items = $$(FOCUSABLE, openDrawer).filter(function (n) { return n.offsetParent !== null; });
      if (!items.length) return;
      var first = items[0], last = items[items.length - 1];
      if (e.shiftKey && doc.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && doc.activeElement === last) { e.preventDefault(); first.focus(); }
    });
  }

  /* ======================================================================
     7. TOASTS
     ==================================================================== */
  function toastStack() {
    var el = $(".toast-stack");
    if (!el) {
      el = doc.createElement("div");
      el.className = "toast-stack";
      el.setAttribute("role", "status");
      el.setAttribute("aria-live", "polite");
      doc.body.appendChild(el);
    }
    return el;
  }

  /**
   * toast("Bond submitted", "Mock transaction — nothing was signed.", "ok")
   * kind: "info" (default) | "ok" | "err"
   */
  function toast(title, message, kind, ttl) {
    var stack = toastStack();
    var el = doc.createElement("div");
    el.className = "toast toast--" + (kind || "info");

    var bar = doc.createElement("i");
    bar.className = "toast__bar";
    bar.setAttribute("aria-hidden", "true");

    var body = doc.createElement("div");
    var b = doc.createElement("b");
    b.textContent = title;
    body.appendChild(b);
    if (message) {
      var span = doc.createElement("span");
      span.textContent = message;
      body.appendChild(span);
    }

    el.appendChild(bar);
    el.appendChild(body);
    stack.appendChild(el);

    /* force a frame so the transition runs */
    global.requestAnimationFrame(function () { el.setAttribute("data-show", "true"); });

    var life = ttl || 5200;
    global.setTimeout(function () {
      el.setAttribute("data-show", "false");
      global.setTimeout(function () {
        if (el.parentNode) el.parentNode.removeChild(el);
      }, reducedMotion() ? 0 : 500);
    }, life);

    return el;
  }

  /* ======================================================================
     8. LEFT RAIL (off-canvas ≤991px)
     ==================================================================== */
  function initRail() {
    var rail = $("#rail");
    var toggle = $("[data-rail-toggle]");
    if (!rail || !toggle) return;

    var scrim = $(".rail-scrim");
    if (!scrim) {
      scrim = doc.createElement("div");
      scrim.className = "rail-scrim";
      doc.body.appendChild(scrim);
    }

    function setOpen(open) {
      rail.setAttribute("data-open", open ? "true" : "false");
      scrim.setAttribute("data-open", open ? "true" : "false");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
      if (open) {
        global.requestAnimationFrame(function () {
          global.requestAnimationFrame(function () {
            var first = $$(FOCUSABLE, rail)[0];
            if (first && rail.getAttribute("data-open") === "true") first.focus();
          });
        });
      }
    }

    on(toggle, "click", function () {
      setOpen(rail.getAttribute("data-open") !== "true");
    });
    on(scrim, "click", function () { setOpen(false); });
    on(doc, "keydown", function (e) {
      if (e.key === "Escape" && rail.getAttribute("data-open") === "true") {
        setOpen(false);
        toggle.focus();
      }
    });
    $$("a", rail).forEach(function (a) { on(a, "click", function () { setOpen(false); }); });
  }

  /* ======================================================================
     9. WALLET — the only non-mock part of this app
     ==================================================================== */
  var NET = global.HOOD_NET;
  var TARGET_CHAIN_ID = NET ? NET.DEFAULT_CHAIN_ID : 4663;

  var wallet = {
    address: null,
    chainId: null,
    connected: false
  };

  function ethereum() { return global.ethereum || null; }

  function targetNet() {
    return (NET && NET.NETWORKS[TARGET_CHAIN_ID]) || {
      chainIdHex: "0x1237",
      chainName: "Robinhood Chain",
      rpcUrls: ["https://rpc.mainnet.chain.robinhood.com"],
      blockExplorerUrls: ["https://robinhoodchain.blockscout.com"],
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }
    };
  }

  function renderWallet() {
    var net = targetNet();
    var wrongChain = wallet.connected && wallet.chainId !== TARGET_CHAIN_ID;

    $$("[data-wallet-label]").forEach(function (el) {
      el.textContent = wallet.connected ? shortAddr(wallet.address) : "Connect Wallet";
    });
    $$("[data-wallet-status]").forEach(function (el) {
      el.classList.toggle("is-wrong", wrongChain);
      var dot = $(".chip__dot", el);
      var text = $("[data-wallet-status-text]", el);
      if (dot) {
        dot.classList.toggle("is-off", !wallet.connected);
        dot.classList.toggle("is-warn", wrongChain);
      }
      if (text) {
        text.textContent = !wallet.connected ? "Wallet disconnected"
          : wrongChain ? "Wrong network" : net.chainName;
      }
    });
    $$("[data-wallet-address]").forEach(function (el) {
      el.textContent = wallet.connected ? wallet.address : "—";
    });
    MOCK.wallet.address = wallet.address;
    applyBindings();
  }

  /**
   * Connect an injected EIP-1193 wallet and put it on Robinhood Chain (4663).
   * Falls back to wallet_addEthereumChain when the chain is unknown (4902).
   */
  function connectWallet() {
    var eth = ethereum();
    var net = targetNet();

    if (!eth) {
      toast(
        "No wallet detected",
        "Install an EVM wallet (MetaMask, Rabby, …) and add Robinhood Chain " +
        "(chain id " + TARGET_CHAIN_ID + ").",
        "err", 7000
      );
      return Promise.resolve(null);
    }

    return eth.request({ method: "eth_requestAccounts" })
      .then(function (accounts) {
        wallet.address = accounts && accounts[0] ? accounts[0] : null;
        wallet.connected = !!wallet.address;
        return eth.request({ method: "eth_chainId" });
      })
      .then(function (hex) {
        wallet.chainId = parseInt(hex, 16);
        if (wallet.chainId === TARGET_CHAIN_ID) return null;
        return switchChain();
      })
      .then(function () {
        renderWallet();
        toast("Wallet connected", shortAddr(wallet.address) + " on " + net.chainName, "ok");
        return wallet.address;
      })
      .catch(function (err) {
        renderWallet();
        if (err && err.code === 4001) {
          toast("Request rejected", "You dismissed the wallet prompt.", "err");
        } else {
          toast("Connection failed", (err && err.message) || "Unknown wallet error.", "err", 7000);
        }
        return null;
      });
  }

  /** wallet_switchEthereumChain → 0x1237, with an add-chain fallback. */
  function switchChain() {
    var eth = ethereum();
    var net = targetNet();
    if (!eth) return Promise.reject(new Error("No injected provider"));

    return eth.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: net.chainIdHex }]
    }).then(function () {
      wallet.chainId = TARGET_CHAIN_ID;
    }).catch(function (err) {
      /* 4902 = unrecognised chain. Some wallets nest it under err.data. */
      var code = err && (err.code || (err.data && err.data.originalError && err.data.originalError.code));
      if (code !== 4902 && code !== -32603) throw err;
      return eth.request({
        method: "wallet_addEthereumChain",
        params: [{
          chainId: net.chainIdHex,
          chainName: net.chainName,
          nativeCurrency: net.nativeCurrency,
          rpcUrls: net.rpcUrls,
          blockExplorerUrls: net.blockExplorerUrls
        }]
      }).then(function () {
        wallet.chainId = TARGET_CHAIN_ID;
      });
    });
  }

  function initWallet() {
    $$("[data-connect]").forEach(function (btn) {
      on(btn, "click", function (e) {
        e.preventDefault();
        connectWallet();
      });
    });

    var eth = ethereum();
    if (eth && eth.on) {
      eth.on("accountsChanged", function (accounts) {
        wallet.address = accounts && accounts[0] ? accounts[0] : null;
        wallet.connected = !!wallet.address;
        renderWallet();
        if (!wallet.connected) toast("Wallet disconnected", "No accounts are exposed to this site.", "info");
      });
      eth.on("chainChanged", function (hex) {
        wallet.chainId = parseInt(hex, 16);
        renderWallet();
        if (wallet.chainId !== TARGET_CHAIN_ID) {
          toast("Wrong network", "Switch to " + targetNet().chainName + " (" + TARGET_CHAIN_ID + ").", "err");
        }
      });
      /* silent reconnect if the site is already authorised */
      eth.request({ method: "eth_accounts" }).then(function (accounts) {
        if (accounts && accounts.length) {
          wallet.address = accounts[0];
          wallet.connected = true;
          return eth.request({ method: "eth_chainId" }).then(function (hex) {
            wallet.chainId = parseInt(hex, 16);
            renderWallet();
          });
        }
      }).catch(function () { /* wallet locked — ignore */ });
    }

    renderWallet();
  }

  /* ======================================================================
     10. small shared behaviours
     ==================================================================== */

  /** Buttons that only exist to demo a flow. */
  function initMockActions() {
    $$("[data-mock-action]").forEach(function (btn) {
      on(btn, "click", function (e) {
        if (btn.tagName === "A") e.preventDefault();
        toast(
          btn.getAttribute("data-mock-action"),
          btn.getAttribute("data-mock-note") || "Mock data — no transaction was signed.",
          btn.getAttribute("data-mock-kind") || "info"
        );
      });
    });
  }

  /** Vote bars / any meter driven by data-fill="0.8123".
      Set synchronously — the grow-in is a CSS animation, not a JS-timed one,
      so the bars are correct even when rAF never runs (background tab). */
  function initMeters() {
    $$("[data-fill]").forEach(function (el) {
      var v = Math.max(0, Math.min(1, parseFloat(el.getAttribute("data-fill")) || 0));
      el.style.setProperty("--w", (v * 100).toFixed(2) + "%");
    });
  }

  /** Segmented controls with aria-pressed. */
  function initSegments() {
    $$("[data-seg]").forEach(function (group) {
      var btns = $$("button", group);
      btns.forEach(function (btn) {
        on(btn, "click", function () {
          btns.forEach(function (b) { b.setAttribute("aria-pressed", b === btn ? "true" : "false"); });
          group.dispatchEvent(new CustomEvent("segchange", {
            bubbles: true,
            detail: { value: btn.getAttribute("data-value") }
          }));
        });
      });
    });
  }

  function num(el) {
    if (!el) return 0;
    var v = parseFloat(String(el.value).replace(/,/g, ""));
    return isFinite(v) && v >= 0 ? v : 0;
  }
  function setText(sel, text, root) {
    var el = $(sel, root);
    if (el) el.textContent = text;
  }

  /* ======================================================================
     11. PAGE CONTROLLERS
     ==================================================================== */
  var pages = {};

  /* ------------------------------------------------------------ stake */
  pages.stake = function () {
    var form = $("#stake-form");
    if (!form) return;

    var input = $("#stake-amount");
    var maxBtn = $("#stake-max");
    var wrapToggle = $("#wrap-toggle");
    var tabsRoot = $("#stake-tabs");
    var submit = $("#stake-submit");
    var mode = "stake";

    function available() {
      return mode === "stake" ? MOCK.wallet.hoodz : MOCK.wallet.sHoodz;
    }
    function unitIn() { return mode === "stake" ? "HOOD" : "sHOOD"; }

    function refresh() {
      var amt = num(input);
      var d = derive();
      var wrap = wrapToggle && wrapToggle.checked;
      var outUnit = mode === "stake" ? (wrap ? "gHOOD" : "sHOOD") : "HOOD";
      var out = mode === "stake"
        ? (wrap ? amt / MOCK.staking.index : amt)
        : amt;

      setText("[data-stake-available]", hoodz(available(), 4) + " " + unitIn());
      setText("[data-stake-unit]", unitIn());
      setText("[data-stake-out]", (wrap && mode === "stake" ? fixed(out, 6) : hoodz(out, 4)) + " " + outUnit);
      setText("[data-stake-out-unit]", outUnit);
      setText("[data-stake-usd]", usd(amt * MOCK.token.price));

      /* rewards table reacts to what you are about to stake */
      var futureS = mode === "stake" ? MOCK.wallet.sHoodz + amt : Math.max(0, MOCK.wallet.sHoodz - amt);
      setText("[data-next-reward]", hoodz(futureS * MOCK.staking.rebaseRate, 4) + " sHOOD");
      setText("[data-next-reward-usd]", usd(futureS * MOCK.staking.rebaseRate * MOCK.token.price));
      setText("[data-projected-balance]", hoodz(futureS, 4) + " sHOOD");
      setText("[data-five-day]", hoodz(futureS * d.fiveDayRoi, 4) + " sHOOD");

      if (submit) {
        var label = mode === "stake" ? (wrap ? "Stake & wrap" : "Stake HOOD") : "Unstake";
        $$(".btn-text, .btn-text-ghost", submit).forEach(function (n) { n.textContent = label; });
        submit.setAttribute("aria-disabled", amt <= 0 ? "true" : "false");
      }

      var over = amt > available();
      var warn = $("[data-stake-overdraft]");
      if (warn) warn.hidden = !over;
    }

    on(input, "input", refresh);
    on(maxBtn, "click", function () {
      input.value = hoodz9(available()).replace(/,/g, "");
      refresh();
    });
    on(wrapToggle, "change", function () {
      refresh();
      var w = $("[data-wrap-note]");
      if (w) w.hidden = !wrapToggle.checked;
    });
    on(tabsRoot, "tabchange", function (e) {
      mode = e.detail.value === "unstake" ? "unstake" : "stake";
      input.value = "";
      refresh();
    });
    on(form, "submit", function (e) {
      e.preventDefault();
      var amt = num(input);
      if (amt <= 0) { toast("Enter an amount", "Nothing to " + mode + " yet.", "err"); return; }
      if (amt > available()) { toast("Insufficient balance", "You hold " + hoodz(available(), 4) + " " + unitIn() + ".", "err"); return; }
      toast(
        (mode === "stake" ? "Stake" : "Unstake") + " submitted",
        hoodz(amt, 4) + " " + unitIn() + " — mock data, no transaction was signed.",
        "ok"
      );
      input.value = "";
      refresh();
    });

    refresh();
  };

  /* ------------------------------------------------------------- bond */
  pages.bond = function () {
    var drawer = $("#bond-drawer");
    if (!drawer) return;

    var state = { market: null, quote: "USDC", quotePrice: 1, bondPrice: 0, vesting: 5, slippage: 0.005 };

    var amountInput = $("#bond-amount", drawer);
    var recipientInput = $("#bond-recipient", drawer);
    var slipSeg = $("#bond-slippage", drawer);
    var slipCustom = $("#bond-slippage-custom", drawer);

    /* Every lookup is scoped to the drawer: the market rows carry
       data-bond-price / data-quote attributes of their own. */
    function put(sel, text) { setText(sel, text, drawer); }

    function refresh() {
      var amt = num(amountInput);
      var quoteUsd = amt * state.quotePrice;
      var payout = state.bondPrice > 0 ? quoteUsd / state.bondPrice : 0;
      var atMarket = MOCK.token.price > 0 ? quoteUsd / MOCK.token.price : 0;
      var maxPrice = state.bondPrice * (1 + state.slippage);
      var vestEnd = Date.now() + state.vesting * 86400000;

      put("[data-bond-quote-unit]", state.quote);
      put("[data-bond-value]", usd(quoteUsd));
      put("[data-bond-payout]", hoodz(payout, 4) + " HOOD");
      put("[data-bond-payout-usd]", usd(payout * MOCK.token.price));
      put("[data-bond-vs-market]", hoodz(payout - atMarket, 4) + " HOOD");
      put("[data-bond-max-price]", usd(maxPrice, 4));
      put("[data-bond-vest-end]", amt > 0 ? dateShort(vestEnd) : "—");
      put("[data-bond-available]", fixed(
        state.quote === MOCK.wallet.reserveSymbol ? MOCK.wallet.reserve : 0, 2
      ) + " " + state.quote);

      var submit = $("#bond-submit", drawer);
      if (submit) submit.setAttribute("aria-disabled", amt <= 0 ? "true" : "false");
    }

    /* open the drawer from a market row */
    $$("[data-drawer-open='bond-drawer']").forEach(function (btn) {
      on(btn, "click", function () {
        state.market = btn.getAttribute("data-market");
        state.quote = btn.getAttribute("data-quote") || "USDC";
        state.quotePrice = parseFloat(btn.getAttribute("data-quote-price")) || MOCK.quotePrices[state.quote] || 1;
        state.bondPrice = parseFloat(btn.getAttribute("data-bond-price")) || 0;
        state.vesting = parseFloat(btn.getAttribute("data-vesting")) || 5;

        put("[data-bond-market]", state.quote + " bond");
        put("[data-bond-market-sub]", "Market #" + state.market + " · " + state.vesting + "-day term");
        put("[data-bond-price]", usd(state.bondPrice, 4));
        put("[data-bond-market-price]", usd(MOCK.token.price, 4));
        var disc = (MOCK.token.price - state.bondPrice) / MOCK.token.price;
        var discEl = $("[data-bond-discount]", drawer);
        if (discEl) {
          discEl.textContent = signedPct(disc);
          discEl.classList.toggle("t-pos", disc > 0);
          discEl.classList.toggle("t-neg", disc < 0);
        }
        put("[data-bond-vesting]", days(state.vesting));
        if (amountInput) amountInput.value = "";
        if (recipientInput) recipientInput.value = wallet.address || "";
        refresh();
      });
    });

    on(amountInput, "input", refresh);
    on($("#bond-max", drawer), "click", function () {
      var bal = state.quote === MOCK.wallet.reserveSymbol ? MOCK.wallet.reserve : 0;
      amountInput.value = bal ? String(bal) : "";
      if (!bal) toast("No balance", "This demo wallet only holds " + MOCK.wallet.reserveSymbol + ".", "info");
      refresh();
    });
    on(slipSeg, "segchange", function (e) {
      state.slippage = parseFloat(e.detail.value);
      if (slipCustom) slipCustom.value = "";
      refresh();
    });
    on(slipCustom, "input", function () {
      var v = parseFloat(slipCustom.value);
      if (isFinite(v) && v >= 0) {
        state.slippage = v / 100;
        $$("button", slipSeg).forEach(function (b) { b.setAttribute("aria-pressed", "false"); });
      }
      refresh();
    });
    on($("#bond-form", drawer), "submit", function (e) {
      e.preventDefault();
      var amt = num(amountInput);
      if (amt <= 0) { toast("Enter an amount", "Nothing to bond yet.", "err"); return; }
      toast(
        "Bond submitted",
        hoodz(amt, 4) + " " + state.quote + " into market #" + state.market +
        " — mock data, no transaction was signed.",
        "ok"
      );
      closeDrawer();
    });

    refresh();
  };

  /* ----------------------------------------------------------- borrow */
  pages.borrow = function () {
    var form = $("#borrow-form");
    if (!form) return;

    var input = $("#borrow-collateral");
    var ln = MOCK.loans;

    function refresh() {
      var col = num(input);
      var principal = col * ln.oltc;
      var interest = principal * ln.interestRate * (ln.durationDays / 365);
      var expiry = Date.now() + ln.durationDays * 86400000;

      setText("[data-borrow-principal]", fixed(principal, 2) + " " + MOCK.wallet.reserveSymbol);
      setText("[data-borrow-interest]", fixed(interest, 2) + " " + MOCK.wallet.reserveSymbol);
      setText("[data-borrow-total]", fixed(principal + interest, 2) + " " + MOCK.wallet.reserveSymbol);
      setText("[data-borrow-expiry]", dateShort(expiry));
      setText("[data-borrow-collateral-usd]", usd(col * MOCK.staking.index * MOCK.token.price));

      var over = col > MOCK.wallet.gHoodz;
      var warn = $("[data-borrow-overdraft]");
      if (warn) warn.hidden = !over;

      var submit = $("#borrow-submit");
      if (submit) submit.setAttribute("aria-disabled", col <= 0 ? "true" : "false");
    }

    on(input, "input", refresh);
    on($("#borrow-max"), "click", function () {
      input.value = fixed(MOCK.wallet.gHoodz, 4).replace(/,/g, "");
      refresh();
    });
    on(form, "submit", function (e) {
      e.preventDefault();
      var col = num(input);
      if (col <= 0) { toast("Enter collateral", "Deposit gHOOD to open a loan.", "err"); return; }
      if (col > MOCK.wallet.gHoodz) { toast("Insufficient gHOOD", "You hold " + fixed(MOCK.wallet.gHoodz, 4) + " gHOOD.", "err"); return; }
      toast(
        "Loan requested",
        fixed(col * ln.oltc, 2) + " " + MOCK.wallet.reserveSymbol +
        " against " + fixed(col, 4) + " gHOOD — mock data, nothing was signed.",
        "ok"
      );
      refresh();
    });

    refresh();
  };

  /* ------------------------------------------------------- governance */
  pages.governance = function () {
    var list = $("#proposal-list");
    if (!list) return;

    /* filter pills */
    var filters = $("#proposal-filters");
    if (filters) {
      on(filters, "segchange", function (e) {
        var want = e.detail.value;
        var shown = 0;
        $$("[data-proposal-state]", list).forEach(function (card) {
          var match = want === "all" || card.getAttribute("data-proposal-state") === want;
          card.hidden = !match;
          if (match) shown++;
        });
        var empty = $("#proposal-empty");
        if (empty) empty.hidden = shown !== 0;
        var count = $("[data-proposal-count]");
        if (count) count.textContent = String(shown);
      });
    }

    /* delegation panel */
    var delForm = $("#delegate-form");
    var delInput = $("#delegate-address");
    if (delForm) {
      on(delForm, "submit", function (e) {
        e.preventDefault();
        var v = (delInput.value || "").trim();
        if (!/^0x[a-fA-F0-9]{40}$/.test(v)) {
          toast("Invalid address", "Enter a 20-byte hex address (0x…).", "err");
          return;
        }
        MOCK.wallet.delegate = v;
        applyBindings();
        toast("Delegation set", "Voting power delegated to " + shortAddr(v) + " — mock data.", "ok");
        delInput.value = "";
      });
    }
    on($("#delegate-self"), "click", function () {
      var v = wallet.address;
      if (!v) { toast("Connect first", "Connect a wallet to self-delegate.", "err"); return; }
      MOCK.wallet.delegate = v;
      applyBindings();
      toast("Self-delegated", shortAddr(v) + " now holds its own voting power — mock data.", "ok");
    });

    /* vote buttons */
    $$("[data-vote]").forEach(function (btn) {
      on(btn, "click", function () {
        var support = btn.getAttribute("data-vote");
        var id = btn.getAttribute("data-proposal");
        toast(
          "Vote cast: " + support,
          "Proposal " + id + " · " + fixed(MOCK.wallet.gHoodz, 4) +
          " gHOOD — mock data, nothing was signed.",
          "ok"
        );
      });
    });
  };

  /* ======================================================================
     12. boot
     ==================================================================== */
  function init() {
    doc.documentElement.classList.add("js");
    initRail();
    initTabs();
    initDrawers();
    initSegments();
    initMeters();
    initMockActions();
    applyBindings();
    startCountdowns();
    initWallet();

    var page = doc.body.getAttribute("data-page");
    if (page && pages[page]) pages[page]();
  }

  if (doc.readyState === "loading") on(doc, "DOMContentLoaded", init);
  else init();

  /* public surface — handy from the console, and for future live reads */
  global.HoodzApp = {
    mock: MOCK,
    derive: derive,
    fmt: fmt,
    wallet: wallet,
    connectWallet: connectWallet,
    switchChain: switchChain,
    toast: toast,
    openDrawer: showDrawer,
    closeDrawer: closeDrawer,
    refresh: applyBindings,
    nextRebaseSeconds: nextRebaseSeconds
  };
})(window, document);
