/**
 * Radicle provider preload (iOS). Mirror of the desktop browser's
 * window.radicle provider (docs/radicle-provider-api.md) adapted to
 * WKWebView's transport: `window.webkit.messageHandlers.freedomRadicle
 * .postMessage` going out, `window.__freedomRadicle.__handleResponse` /
 * `__handleEvent` being called from native via `evaluateJavaScript`
 * coming back. Same request/response pattern as SwarmBridge.js.
 *
 * Origin identity comes from `tab.displayURL` on the native side — the
 * page never supplies it.
 *
 * Actions only: repo reads are NOT provider methods (desktop serves
 * them over the `rad:` URL scheme; that read path is not on iOS yet).
 */
(function () {
  const pendingRequests = new Map();
  let requestId = 0;
  const eventListeners = {
    connect: [],
    disconnect: [],
    seedStatus: [],
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
      window.webkit.messageHandlers.freedomRadicle.postMessage(message);
    } catch (e) {
      console.error('[radicle] native bridge unavailable:', e);
    }
  }

  function makeRequest(method, params) {
    const id = ++requestId;
    return new Promise(function (resolve, reject) {
      pendingRequests.set(id, { resolve: resolve, reject: reject });
      postToNative({ type: 'request', id: id, method: method, params: params || {} });
      // 5 min ceiling, matching window.swarm — consent prompts can sit
      // open for a while; node actions themselves resolve fast (fetches
      // are backgrounded, never awaited in a request).
      setTimeout(function () {
        if (pendingRequests.has(id)) {
          pendingRequests.delete(id);
          reject(new Error('Request timed out'));
        }
      }, 300000);
    });
  }

  // request() is the catch-all; wrappers per the provider spec.
  window.radicle = {
    isFreedomBrowser: true,
    request: function (payload) {
      return makeRequest(payload && payload.method, (payload && payload.params) || {});
    },
    requestAccess: function () { return makeRequest('radicle_requestAccess'); },
    disconnect: function () { return makeRequest('radicle_disconnect'); },
    getCapabilities: function () { return makeRequest('radicle_getCapabilities'); },
    getNodeStatus: function () { return makeRequest('radicle_getNodeStatus'); },
    listSeededRepos: function () { return makeRequest('radicle_listSeededRepos'); },
    seed: function (params) { return makeRequest('radicle_seed', params); },
    unseed: function (params) { return makeRequest('radicle_unseed', params); },
    sync: function (params) { return makeRequest('radicle_sync', params); },
    getSeedStatus: function (params) { return makeRequest('radicle_getSeedStatus', params); },
    getIdentity: function () { return makeRequest('radicle_getIdentity'); },
    createIssue: function (params) { return makeRequest('radicle_createIssue', params); },
    commentIssue: function (params) { return makeRequest('radicle_commentIssue', params); },
    editIssueState: function (params) { return makeRequest('radicle_editIssueState', params); },
    commentPatch: function (params) { return makeRequest('radicle_commentPatch', params); },

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

  // Native calls these via `evaluateJavaScript`. Kept under
  // `__freedomRadicle` so the only public shape is `window.radicle`.
  window.__freedomRadicle = {
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
