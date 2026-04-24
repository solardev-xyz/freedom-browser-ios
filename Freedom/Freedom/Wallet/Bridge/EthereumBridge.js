/**
 * Ethereum provider preload (iOS). Mirror of desktop's
 * `src/main/webview-preload-ethereum-inject.js` adapted to WKWebView's
 * transport: `window.webkit.messageHandlers.freedomEthereum.postMessage`
 * going out, `window.__freedomEthereum.__handleResponse/__handleEvent`
 * being called from native via `evaluateJavaScript` coming back.
 *
 * Source-as-data: native prepends a preamble assigning
 * `window.__FREEDOM_PROVIDER_CONFIG__` (uuid, name, icon, rdns) before
 * serving this to WKUserScript. The EIP-6963 announce reads that preamble
 * once and deletes it. A fresh UUID is generated per navigation commit —
 * see EthereumBridge.swift's `reinstallScript` path.
 *
 * Shape matches desktop's webview preload so dapps that work on desktop
 * behave the same here. Revisit dropping `isMetaMask: true` once EIP-6963
 * adoption lets modern dapps find us without the legacy sniff.
 */
(function () {
  const pendingRequests = new Map();
  let requestId = 0;
  const eventListeners = {
    connect: [],
    disconnect: [],
    chainChanged: [],
    accountsChanged: [],
    message: [],
  };
  const providerState = { chainId: null, accounts: [], isConnected: false };

  function emitEvent(event, data) {
    if (eventListeners[event]) {
      eventListeners[event].forEach(function (h) {
        try { h(data); } catch (_) { /* swallow listener errors */ }
      });
    }
  }

  function postToNative(message) {
    try {
      window.webkit.messageHandlers.freedomEthereum.postMessage(message);
    } catch (e) {
      console.error('[ethereum] native bridge unavailable:', e);
    }
  }

  window.ethereum = {
    // isMetaMask is a legacy compat hack — pre-EIP-6963 dapps sniff
    // window.ethereum.isMetaMask as a feature gate. Modern dapps discover
    // us via the EIP-6963 announce below and ignore this flag.
    isMetaMask: true,
    isFreedomBrowser: true,
    get chainId() { return providerState.chainId; },
    get selectedAddress() { return providerState.accounts[0] || null; },
    get networkVersion() {
      return providerState.chainId ? String(parseInt(providerState.chainId, 16)) : null;
    },
    isConnected: function () { return providerState.isConnected; },
    request: function (payload) {
      const method = payload && payload.method;
      const params = (payload && payload.params) || [];
      const id = ++requestId;
      return new Promise(function (resolve, reject) {
        pendingRequests.set(id, { resolve: resolve, reject: reject });
        postToNative({ type: 'request', id: id, method: method, params: params });
        setTimeout(
          function () {
            if (pendingRequests.has(id)) {
              pendingRequests.delete(id);
              reject(new Error('Request timed out'));
            }
          },
          method === 'eth_sendTransaction' ? 300000 : 60000
        );
      });
    },
    on: function (event, handler) {
      if (eventListeners[event]) eventListeners[event].push(handler);
      return this;
    },
    removeListener: function (event, handler) {
      if (eventListeners[event]) {
        const i = eventListeners[event].indexOf(handler);
        if (i > -1) eventListeners[event].splice(i, 1);
      }
      return this;
    },
    addListener: function (event, handler) { return this.on(event, handler); },
    removeAllListeners: function (event) {
      if (event && eventListeners[event]) eventListeners[event] = [];
      return this;
    },
    enable: function () {
      return this.request({ method: 'eth_requestAccounts' });
    },
    send: function (methodOrPayload, paramsOrCallback) {
      if (typeof methodOrPayload === 'string')
        return this.request({ method: methodOrPayload, params: paramsOrCallback });
      if (typeof paramsOrCallback === 'function') {
        this.sendAsync(methodOrPayload, paramsOrCallback);
        return;
      }
      return this.request({ method: methodOrPayload.method, params: methodOrPayload.params });
    },
    sendAsync: function (payload, callback) {
      this.request({ method: payload.method, params: payload.params })
        .then(function (result) { callback(null, { id: payload.id, jsonrpc: '2.0', result: result }); })
        .catch(function (error) { callback(error, null); });
    },
  };

  // Native calls these via webView.evaluateJavaScript once it has a
  // result to deliver. Kept under __freedomEthereum so the global
  // surface stays clean.
  window.__freedomEthereum = {
    __handleResponse: function (id, result, error) {
      const pending = pendingRequests.get(id);
      if (!pending) return;
      pendingRequests.delete(id);
      if (error) {
        const err = new Error(error.message || 'Unknown error');
        err.code = error.code;
        pending.reject(err);
      } else {
        pending.resolve(result);
      }
    },
    __handleEvent: function (event, data) {
      if (event === 'chainChanged') providerState.chainId = data;
      else if (event === 'accountsChanged') providerState.accounts = data || [];
      else if (event === 'connect') {
        providerState.isConnected = true;
        providerState.chainId = data && data.chainId;
      } else if (event === 'disconnect') {
        providerState.isConnected = false;
        providerState.accounts = [];
      }
      emitEvent(event, data);
    },
  };

  // EIP-6963 discovery — the primary path for modern wallet-connection
  // stacks (Wagmi, Web3Modal, RainbowKit). Config arrives via the native
  // preamble. If it's missing we still leave window.ethereum installed
  // and fire ethereum#initialized below, so legacy-only dapps degrade
  // instead of losing provider support entirely.
  const providerConfig = window.__FREEDOM_PROVIDER_CONFIG__;
  delete window.__FREEDOM_PROVIDER_CONFIG__;
  if (providerConfig) {
    const providerDetail = Object.freeze({
      info: Object.freeze({
        uuid: providerConfig.uuid,
        name: providerConfig.name,
        icon: providerConfig.icon,
        rdns: providerConfig.rdns,
      }),
      provider: window.ethereum,
    });
    const announceProvider = function () {
      window.dispatchEvent(
        new CustomEvent('eip6963:announceProvider', { detail: providerDetail })
      );
    };
    window.addEventListener('eip6963:requestProvider', announceProvider);
    announceProvider();
  } else {
    console.error('[ethereum] EIP-6963 provider config missing — preamble not prepended');
  }

  // Legacy signal — some older dapps still wait for this.
  window.dispatchEvent(new Event('ethereum#initialized'));
})();
