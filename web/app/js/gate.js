/* ============================================================================
   Hoodz dApp — wallet gate.

   The app is browsable, but nothing in it responds until a wallet is connected.
   Two layers, deliberately:

     1. An overlay that covers the app and explains what is needed.
     2. Every control inside the app is actually disabled, not just visually
        covered. Removing the overlay in devtools gets you a page of dead
        buttons rather than a way to fire a transaction.

   There is a third thing this file is honest about: the contracts are deployed
   but not yet wired to each other, and the token does not exist. So even after
   connecting, the app is read-only and says so.
   ========================================================================== */
(function () {
  'use strict';

  var CHAIN_ID = 4663;
  var CHAIN = {
    chainId: '0x1237',
    chainName: 'Robinhood Chain',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: ['https://rpc.mainnet.chain.robinhood.com'],
    blockExplorerUrls: ['https://robinhoodchain.blockscout.com']
  };

  var account = null;

  function $(s, c) { return (c || document).querySelector(s); }
  function $$(s, c) { return Array.prototype.slice.call((c || document).querySelectorAll(s)); }

  /* ------------------------------------------------------------- controls */

  /** Disable every interactive control in the app shell. */
  function setControls(enabled) {
    $$('main button, main input, main select, main textarea, .app-shell button, .app-shell input')
      .forEach(function (el) {
        if (el.closest('#wallet-gate')) return;          // never the gate's own button
        if (el.hasAttribute('data-always-on')) return;   // nav, theme toggles, etc.
        el.disabled = !enabled;
      });
    document.body.setAttribute('data-locked', enabled ? 'false' : 'true');
  }

  /* ----------------------------------------------------------------- gate */

  function buildGate() {
    var g = document.createElement('div');
    g.id = 'wallet-gate';
    g.innerHTML =
      '<div class="gate__panel">' +
        '<img class="gate__mark" src="../assets/img/coin-3d.webp?v=2" alt="" width="700" height="700">' +
        '<h2 class="gate__title">Connect your wallet</h2>' +
        '<p class="gate__body">The app is read-only until a wallet is connected. ' +
        'Nothing here can be clicked, signed or sent before that.</p>' +
        '<button class="gate__btn" id="gate-connect">Connect wallet</button>' +
        '<p class="gate__note" id="gate-note">Robinhood Chain · 4663</p>' +
        '<a class="gate__back" href="/">← Back to hoodz.finance</a>' +
      '</div>';
    document.body.appendChild(g);

    $('#gate-connect').addEventListener('click', connect);
  }

  function note(msg, bad) {
    var n = $('#gate-note');
    if (!n) return;
    n.textContent = msg;
    n.className = 'gate__note' + (bad ? ' gate__note--bad' : '');
  }

  function connect() {
    if (!window.ethereum) {
      note('No wallet extension found in this browser.', true);
      return;
    }
    note('Waiting for the wallet…');

    window.ethereum.request({ method: 'eth_requestAccounts' })
      .then(function (a) {
        account = a[0];
        return window.ethereum.request({ method: 'eth_chainId' });
      })
      .then(function (c) {
        if (parseInt(c, 16) === CHAIN_ID) return null;
        note('Switching to Robinhood Chain…');
        return window.ethereum.request({
          method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN.chainId }]
        }).catch(function (e) {
          if (e && (e.code === 4902 || String(e.message).indexOf('Unrecognized') >= 0)) {
            return window.ethereum.request({ method: 'wallet_addEthereumChain', params: [CHAIN] });
          }
          throw e;
        });
      })
      .then(unlock)
      .catch(function (e) {
        note(e && e.code === 4001 ? 'Connection rejected.' : (e.message || 'Could not connect.'), true);
      });
  }

  function unlock() {
    var g = $('#wallet-gate');
    if (g) {
      g.classList.add('is-open');
      setTimeout(function () { g.remove(); }, 420);
    }
    setControls(true);
    showAccount();
    showReadOnlyBanner();
  }

  function showAccount() {
    var slot = $('[data-wallet-address]');
    if (slot && account) slot.textContent = account.slice(0, 6) + '…' + account.slice(-4);
    $$('[data-wallet-connected]').forEach(function (el) { el.hidden = false; });
    $$('[data-wallet-disconnected]').forEach(function (el) { el.hidden = true; });
  }

  /**
   * Connecting a wallet does not make the protocol work. The contracts are
   * deployed but not wired, and HOODZ does not exist yet, so every figure is
   * blank and every action is inert. Say that once, at the top, rather than
   * letting someone discover it by clicking.
   */
  function showReadOnlyBanner() {
    if ($('#readonly-banner')) return;
    var b = document.createElement('div');
    b.id = 'readonly-banner';
    b.innerHTML = 'Read-only. The contracts are live on Robinhood Chain but not yet wired together, ' +
                  'and HOODZ has not launched — so there are no balances to show and nothing to sign yet. ' +
                  '<a href="/contracts">See the deployed contracts</a>';
    document.body.insertBefore(b, document.body.firstChild);
  }

  /* ---------------------------------------------------------------- boot */

  function boot() {
    setControls(false);
    buildGate();

    if (window.ethereum && window.ethereum.on) {
      window.ethereum.on('accountsChanged', function (a) {
        if (!a.length) { location.reload(); return; }
        account = a[0];
        showAccount();
      });
      window.ethereum.on('chainChanged', function () { location.reload(); });
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
