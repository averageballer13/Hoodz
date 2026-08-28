/* ============================================================================
   Hoodz — live on-chain data for the landing page.

   Two things happen here, both driven by assets/deployments.json:

     1. Token stats. Market cap, holders and circulating supply come from the
        Robinhood Chain Blockscout API, which is public, CORS-open and needs no
        key. Holder count in particular CANNOT be read from the chain - ERC20 has
        no such function - so an indexer is the only honest source for it.

     2. Contract buttons. Once addresses are filled in, they render as explorer
        links. Until then the section stays hidden.

   Nothing here invents a number. If the token is not set, or the API is down,
   the page keeps its em-dashes and says the data is not live yet.
   ========================================================================== */
(function () {
  'use strict';

  var MANIFEST = 'assets/deployments.json?v=2';

  function $(sel, ctx) { return (ctx || document).querySelector(sel); }
  function $$(sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); }

  /* ------------------------------------------------------------ formatting */

  function compactUsd(n) {
    if (n === null || n === undefined || isNaN(n)) return null;
    n = Number(n);
    var units = [[1e12, 'T'], [1e9, 'B'], [1e6, 'M'], [1e3, 'K']];
    for (var i = 0; i < units.length; i++) {
      if (n >= units[i][0]) return '$' + (n / units[i][0]).toFixed(n / units[i][0] >= 100 ? 0 : 2) + units[i][1];
    }
    return '$' + n.toFixed(2);
  }

  function compactNum(n) {
    if (n === null || n === undefined || isNaN(n)) return null;
    n = Number(n);
    if (n >= 1e6) return (n / 1e6).toFixed(2) + 'M';
    if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K';
    return String(Math.round(n));
  }

  /** total_supply arrives as an integer string in the token's smallest unit. */
  function fromUnits(raw, decimals) {
    try {
      var d = BigInt(decimals || 18);
      var v = BigInt(raw);
      var whole = v / 10n ** d;
      return Number(whole);
    } catch (e) { return null; }
  }

  function setStat(key, value, note) {
    var el = document.querySelector('[data-stat="' + key + '"]');
    if (!el) return;
    if (value === null || value === undefined) return;      // leave the em-dash
    el.textContent = value;
    var noteEl = document.querySelector('[data-stat-note="' + key + '"]');
    if (noteEl && note) noteEl.textContent = note;
  }

  /* ---------------------------------------------------------------- token */

  function loadToken(manifest) {
    var addr = manifest.token;
    if (!addr) return;                                       // nothing launched yet

    var base = (manifest.explorer || '').replace(/\/$/, '');
    var url = base + '/api/v2/tokens/' + addr;

    fetch(url, { headers: { accept: 'application/json' } })
      .then(function (r) {
        if (!r.ok) throw new Error('explorer returned ' + r.status);
        return r.json();
      })
      .then(function (t) {
        var supply = fromUnits(t.total_supply, t.decimals);

        setStat('marketcap', compactUsd(t.circulating_market_cap), 'Live · Blockscout');
        setStat('holders', compactNum(t.holders_count), 'Live · Blockscout');
        setStat('supply', supply !== null ? compactNum(supply) + ' ' + (t.symbol || 'HOOD') : null,
                'Fixed at launch');

        // ticker facts that are only true once the token exists
        var price = t.exchange_rate ? '$' + Number(t.exchange_rate).toFixed(4) : null;
        if (price) addTickerFact('Price', price);
        if (t.volume_24h) addTickerFact('24h volume', compactUsd(t.volume_24h));

        applyTickerFacts();

        var link = $('[data-token-link]');
        if (link) {
          link.href = base + '/token/' + addr;
          link.hidden = false;
        }
      })
      .catch(function (e) {
        // Never fake it. Say the feed is unavailable and leave the dashes.
        $$('[data-stat-note]').forEach(function (n) {
          if (n.textContent.indexOf('Live') === -1) n.textContent = 'Feed unavailable';
        });
        if (window.console) console.warn('[hoodz] token stats unavailable:', e.message);
      });
  }

  /* hoodz.js duplicates the ticker track so the -50% keyframe loops seamlessly.
     Appending to it afterwards breaks that symmetry and the marquee visibly jumps,
     so facts are collected and the track is rebuilt from its original half once. */
  var extraFacts = [];

  function addTickerFact(label, value) {
    extraFacts.push('<span class="ticker__item"><b>' + label + '</b> ' + value +
                    ' <span class="ticker__sep">·</span></span>');
  }

  function applyTickerFacts() {
    if (!extraFacts.length) return;
    var track = $('#ticker-track');
    if (!track) return;

    var items = $$('.ticker__item', track);
    // the track is either pristine or exactly doubled; take the original half
    var base = items.slice(0, Math.ceil(items.length / 2)).map(function (n) { return n.outerHTML; });
    var full = base.concat(extraFacts).join('');
    track.innerHTML = full + full;
    extraFacts = [];
  }

  /* ------------------------------------------------------------ contracts */

  var LABELS = {
    HoodzAuthority: 'Authority', sHOOD: 'sHOOD', gHOOD: 'gHOOD',
    HoodzTreasury: 'Treasury', HoodzBondingCalculator: 'Bonding calculator',
    HoodzStaking: 'Staking', Distributor: 'Distributor', BondDepository: 'Bond depository',
    CoolerFactory: 'Loan factory', Clearinghouse: 'Clearinghouse',
    HoodzTimelock: 'Timelock', HoodzGovernor: 'Governor',
    PonsLaunchConfig: 'Launch config', HoodzLaunchGuard: 'Launch guard',
    CreatorFeeSplitter: 'Fee splitter', FeeRouterBuyback: 'Buyback router',
    EmissionsManager: 'Emissions manager', YieldRepurchaseFacility: 'Yield repurchase',
    ConvertibleDepository: 'Convertible deposits'
  };

  function loadContracts(manifest) {
    var section = $('#contracts');
    if (!section) return;

    var base = (manifest.explorer || '').replace(/\/$/, '');
    var live = Object.keys(manifest.contracts || {}).filter(function (k) {
      return !!manifest.contracts[k];
    });

    if (!live.length) return;                                // nothing deployed: stay hidden

    var grid = $('#contracts-grid');
    grid.innerHTML = '';

    if (manifest.token) {
      grid.appendChild(contractLink('HOOD token', manifest.token, base, true));
    }
    live.forEach(function (k) {
      grid.appendChild(contractLink(LABELS[k] || k, manifest.contracts[k], base, false));
    });

    var count = $('#contracts-count');
    if (count) {
      count.textContent = live.length + (manifest.token ? 1 : 0) + ' contracts live on Robinhood Chain';
    }
    section.hidden = false;
  }

  function contractLink(label, address, base, isToken) {
    var a = document.createElement('a');
    a.className = 'contract-card' + (isToken ? ' contract-card--token' : '');
    a.href = base + (isToken ? '/token/' : '/address/') + address;
    a.target = '_blank';
    a.rel = 'noopener';
    a.innerHTML = '<span class="contract-card__name">' + label + '</span>' +
                  '<span class="contract-card__addr">' + address.slice(0, 10) + '…' + address.slice(-8) + '</span>';
    return a;
  }

  /* --------------------------------------------------- auto-discovery ---- */
  /**
   * Ask the explorer which contracts a wallet has created, so the site can pick
   * up a deployment without waiting for anyone to commit a file.
   *
   * Only contracts whose verified name matches one we know about are shown. That
   * filter matters: the dev wallet may deploy other things, and an unlabelled
   * address on the landing page is worse than nothing. It also means the names
   * only appear once the contracts are verified on Blockscout - before that the
   * explorer has nothing to match on.
   *
   * The committed manifest always wins, so publishing a file overrides whatever
   * the explorer thinks.
   */
  function autodiscover(manifest, known) {
    var wallet = manifest.autodiscover;
    if (!wallet) return Promise.resolve(known);

    var base = (manifest.explorer || '').replace(/\/$/, '');
    var url = base + '/api/v2/addresses/' + wallet + '/transactions?filter=from';

    return fetch(url, { headers: { accept: 'application/json' } })
      .then(function (r) {
        if (!r.ok) throw new Error('explorer returned ' + r.status);
        return r.json();
      })
      .then(function (d) {
        var found = 0;
        (d.items || []).forEach(function (tx) {
          var c = tx.created_contract;
          if (!c || !c.hash) return;
          var name = c.name;
          if (!name || !Object.prototype.hasOwnProperty.call(LABELS, name)) return;
          if (known[name]) return;                       // the committed file wins
          known[name] = c.hash;
          found++;
        });
        if (found && window.console) {
          console.info('[hoodz] discovered ' + found + ' contract(s) from ' + wallet);
        }
        return known;
      })
      .catch(function (e) {
        if (window.console) console.warn('[hoodz] autodiscovery unavailable:', e.message);
        return known;                                     // fall back to the file
      });
  }

  /* ---------------------------------------------------------------- boot */

  function boot() {
    fetch(MANIFEST, { headers: { accept: 'application/json' } })
      .then(function (r) { return r.json(); })
      .then(function (m) {
        loadToken(m);

        var known = {};
        Object.keys(m.contracts || {}).forEach(function (k) {
          if (m.contracts[k]) known[k] = m.contracts[k];
        });

        // Render what the committed manifest already knows, immediately. The
        // explorer call that follows is a slow third party that can and does
        // fail - it must never sit between a visitor and a list we already have.
        m.contracts = known;
        loadContracts(m);

        // Then top up with anything the explorer knows that the file does not,
        // and re-render only if that actually added something.
        var before = Object.keys(known).length;
        autodiscover(m, known).then(function (merged) {
          if (Object.keys(merged).length === before) return;
          m.contracts = merged;
          loadContracts(m);
        });
      })
      .catch(function (e) {
        if (window.console) console.warn('[hoodz] deployments.json unreadable:', e.message);
      });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
