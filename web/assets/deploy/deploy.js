/* ============================================================================
   Hoodz — browser contract deployer
   Zero dependencies: talks to window.ethereum directly and ABI-encodes the
   constructor arguments by hand. Every constructor in the bundle takes only
   address / uintN / address[], which is a small enough surface to encode
   correctly without pulling in a library.
   ========================================================================== */
(function () {
  'use strict';

  var DEV_WALLET = '0xf66f85ddE0f123e0EE8100eaDFa637b4eA1FD0e9'.toLowerCase();

  var NETWORKS = {
    4663: {
      chainId: '0x1237',
      chainName: 'Robinhood Chain',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      rpcUrls: ['https://rpc.mainnet.chain.robinhood.com'],
      blockExplorerUrls: ['https://robinhoodchain.blockscout.com']
    },
    46630: {
      chainId: '0xb626',
      chainName: 'Robinhood Chain Testnet',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      rpcUrls: ['https://rpc.testnet.chain.robinhood.com'],
      blockExplorerUrls: ['https://testnet.robinhoodchain.blockscout.com']
    }
  };

  /* ------------------------------------------------------ ABI encoding ---- */

  function pad32(hexNo0x) {
    if (hexNo0x.length > 64) throw new Error('value too wide for one word');
    return '0'.repeat(64 - hexNo0x.length) + hexNo0x;
  }

  function encAddress(v) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(v || '')) throw new Error('not an address: ' + v);
    return pad32(v.slice(2).toLowerCase());
  }

  function encUint(v) {
    var b = BigInt(v);
    if (b < 0n) throw new Error('negative uint: ' + v);
    return pad32(b.toString(16));
  }

  function encBool(v) { return pad32(v ? '1' : '0'); }

  /**
   * Encode constructor arguments per the Solidity ABI.
   * Static types go inline; dynamic ones (address[] here) leave a 32-byte
   * offset in the head and append length + elements to the tail.
   */
  function encodeArgs(inputs, values) {
    var head = '', tail = '';
    // Every top-level argument occupies exactly one head word: the value itself if
    // static, or an offset into the tail if dynamic. So the tail starts right after
    // inputs.length words.
    var tailOffsetBytes = inputs.length * 32;

    inputs.forEach(function (inp, i) {
      var t = inp.type, v = values[i];
      if (t === 'address') { head += encAddress(v); }
      else if (t === 'bool') { head += encBool(v); }
      else if (/^uint\d*$/.test(t)) { head += encUint(v); }
      else if (t === 'address[]') {
        head += encUint(tailOffsetBytes + tail.length / 2);
        var arr = Array.isArray(v) ? v : String(v).split(',').map(function (s) { return s.trim(); }).filter(Boolean);
        var chunk = encUint(arr.length);
        arr.forEach(function (a) { chunk += encAddress(a); });
        tail += chunk;
      } else {
        throw new Error('unsupported constructor type: ' + t);
      }
    });

    return head + tail;
  }

  /* --------------------------------------------------------- RPC helpers -- */

  function rpc(method, params) {
    if (!window.ethereum) return Promise.reject(new Error('No wallet found. Install a browser wallet.'));
    return window.ethereum.request({ method: method, params: params || [] });
  }

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  /** Poll until the transaction is mined. Returns the receipt. */
  function waitForReceipt(hash, onTick) {
    var tries = 0;
    return (function poll() {
      return rpc('eth_getTransactionReceipt', [hash]).then(function (r) {
        if (r) return r;
        tries++;
        if (onTick) onTick(tries);
        if (tries > 300) throw new Error('Timed out waiting for ' + hash);
        return sleep(2000).then(poll);
      });
    })();
  }

  /* --------------------------------------------------------------- state -- */

  // Bumped with the wallet rotation: the previous run recorded six contracts
  // deployed by the old wallet, and carrying that progress forward would make
  // the page skip them instead of deploying a fresh set.
  var STORE = 'hoodz.deploy.v2';

  function loadState() {
    try { return JSON.parse(localStorage.getItem(STORE)) || {}; }
    catch (e) { return {}; }
  }

  function saveState(s) {
    try { localStorage.setItem(STORE, JSON.stringify(s)); } catch (e) {}
  }

  window.HoodzDeploy = {
    DEV_WALLET: DEV_WALLET,
    NETWORKS: NETWORKS,
    encodeArgs: encodeArgs,
    rpc: rpc,
    waitForReceipt: waitForReceipt,
    loadState: loadState,
    saveState: saveState,

    /** Estimate the gas one deployment will take, without sending anything. */
    estimateOne: function (from, artifact, args) {
      var data = artifact.bytecode + encodeArgs(artifact.constructor, args);
      return rpc('eth_estimateGas', [{ from: from, data: data }]).then(function (g) {
        return BigInt(g);
      });
    },

    /** Current gas price, as a BigInt of wei. */
    gasPrice: function () {
      return rpc('eth_gasPrice').then(function (p) { return BigInt(p); });
    },

    /** Deploy one contract and return its address. */
    deployOne: function (from, artifact, args) {
      var data = artifact.bytecode + encodeArgs(artifact.constructor, args);
      return rpc('eth_sendTransaction', [{ from: from, data: data }])
        .then(function (hash) {
          return waitForReceipt(hash).then(function (receipt) {
            if (receipt.status && BigInt(receipt.status) === 0n) {
              throw new Error('Deployment reverted (tx ' + hash + ')');
            }
            if (!receipt.contractAddress) {
              throw new Error('No contractAddress in receipt for ' + hash);
            }
            return { address: receipt.contractAddress, hash: hash, gasUsed: receipt.gasUsed };
          });
        });
    }
  };
})();
