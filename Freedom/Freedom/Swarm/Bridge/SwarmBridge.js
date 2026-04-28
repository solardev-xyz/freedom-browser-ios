/**
 * Swarm provider preload (iOS). Mirror of the desktop browser's
 * `webview-preload-swarm-inject.js` adapted to WKWebView's transport:
 * `window.webkit.messageHandlers.freedomSwarm.postMessage` going out,
 * `window.__freedomSwarm.__handleResponse` / `__handleEvent` being
 * called from native via `evaluateJavaScript` coming back.
 *
 * Origin identity comes from `tab.displayURL` on the native side — the
 * page never supplies it. A page that postMessages through this handler
 * with a forged origin still only acts on permissions granted to its
 * real address-bar identity.
 */
(function () {
  const pendingRequests = new Map();
  let requestId = 0;
  const eventListeners = {
    connect: [],
    disconnect: [],
  };

  function emitEvent(event, data) {
    if (eventListeners[event]) {
      eventListeners[event].forEach(function (h) {
        try { h(data); } catch (_) { /* swallow */ }
      });
    }
  }

  function postToNative(message) {
    try {
      window.webkit.messageHandlers.freedomSwarm.postMessage(message);
    } catch (e) {
      console.error('[swarm] native bridge unavailable:', e);
    }
  }

  function makeRequest(method, params) {
    const id = ++requestId;
    return new Promise(function (resolve, reject) {
      pendingRequests.set(id, { resolve: resolve, reject: reject });
      postToNative({ type: 'request', id: id, method: method, params: params || {} });
      // 5 min ceiling — covers chain-tx-blocked publish/feed-write paths.
      // Reads + capability checks resolve in tens of ms, so the cap only
      // bites on misbehaving native handlers.
      setTimeout(function () {
        if (pendingRequests.has(id)) {
          pendingRequests.delete(id);
          reject(new Error('Request timed out'));
        }
      }, 300000);
    });
  }

  // request() is the catch-all for forward-compat — convenience wrappers
  // below are SWIP §"Convenience Methods".
  window.swarm = {
    // Implementation marker. Per SWIP §"Properties" this is not part of
    // the standard interface and dapps SHOULD use `swarm_getCapabilities`
    // for feature detection — but desktop sets it and existing test
    // pages branch on it, so we match for cross-platform compatibility.
    isFreedomBrowser: true,
    request: function (payload) {
      return makeRequest(payload && payload.method, (payload && payload.params) || {});
    },
    requestAccess: function () { return makeRequest('swarm_requestAccess'); },
    getCapabilities: function () { return makeRequest('swarm_getCapabilities'); },
    publishData: function (params) { return makeRequest('swarm_publishData', params); },
    publishFiles: function (params) { return makeRequest('swarm_publishFiles', params); },
    getUploadStatus: function (params) { return makeRequest('swarm_getUploadStatus', params); },
    createFeed: function (params) { return makeRequest('swarm_createFeed', params); },
    updateFeed: function (params) { return makeRequest('swarm_updateFeed', params); },
    writeFeedEntry: function (params) { return makeRequest('swarm_writeFeedEntry', params); },
    readFeedEntry: function (params) { return makeRequest('swarm_readFeedEntry', params); },
    listFeeds: function () { return makeRequest('swarm_listFeeds'); },

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
    removeAllListeners: function (event) {
      if (event && eventListeners[event]) eventListeners[event] = [];
      return this;
    },
  };

  // Native calls these via `evaluateJavaScript` once a result/event
  // is ready. Kept under `__freedomSwarm` so the global surface stays
  // clean — the only public shape is `window.swarm`.
  window.__freedomSwarm = {
    __handleResponse: function (id, result, error) {
      const pending = pendingRequests.get(id);
      if (!pending) return;
      pendingRequests.delete(id);
      if (error) {
        const err = new Error(error.message || 'Unknown error');
        err.code = error.code;
        if (error.data) err.data = error.data;
        pending.reject(err);
      } else {
        pending.resolve(result);
      }
    },
    __handleEvent: function (event, data) {
      emitEvent(event, data);
    },
  };
})();
