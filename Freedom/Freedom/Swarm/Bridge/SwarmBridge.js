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
    message: [],  // SWIP messaging extension — SubscriptionMessage push
  };

  function emitEvent(event, data) {
    if (eventListeners[event]) {
      eventListeners[event].forEach(function (h) {
        try { h(data); } catch (_) { /* swallow */ }
      });
    }
  }

  // Convert any of the SWIP-allowed `bytes` shapes
  // (`Uint8Array | ArrayBuffer | string`) to a base64 string for the
  // native bridge. A `string` is treated as already-base64 — callers
  // who want UTF-8 bytes should `TextEncoder().encode(...)` first.
  //
  // Processing in 32 KB chunks via `String.fromCharCode.apply` is
  // ~10× faster than a per-byte loop for large blobs and avoids the
  // call-stack-overflow trap of a single `apply` over the SWIP's
  // 50 MB cap. Each chunk's binary string is pushed into an array and
  // joined once at the end — also faster than `+=` concat on the
  // 50 MB upper bound where rope-rebalancing dominates.
  function __toBase64(input) {
    // String passthrough is the SWIP `bytes: string` allowance for
    // publishFiles — dapps can pre-encode binary themselves. Callers
    // that want a string treated as utf-8 (writeFeedEntry's `data`)
    // must `TextEncoder().encode(...)` first.
    if (typeof input === 'string') return input;
    var bytes;
    if (input instanceof Uint8Array) {
      bytes = input;
    } else if (input instanceof ArrayBuffer) {
      bytes = new Uint8Array(input);
    } else if (input && typeof input.length === 'number') {
      bytes = new Uint8Array(input);
    } else {
      throw new Error('files[].bytes must be a Uint8Array, ArrayBuffer, or base64 string');
    }
    var CHUNK = 0x8000;  // 32 KB — well under the per-call apply ceiling
    var parts = [];
    for (var i = 0; i < bytes.length; i += CHUNK) {
      parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK)));
    }
    return btoa(parts.join(''));
  }

  function postToNative(message) {
    try {
      window.webkit.messageHandlers.freedomSwarm.postMessage(message);
    } catch (e) {
      console.error('[swarm] native bridge unavailable:', e);
    }
  }

  // UTF-8-encode strings, base64 everything — the SWIP's
  // `string | Uint8Array | ArrayBuffer` payload contract for
  // writeFeedEntry and the chunk methods ("Strings are encoded as
  // UTF-8"). Distinct from publishFiles' `bytes: string` allowance,
  // where a string is already base64.
  function __payloadToBase64(data) {
    if (typeof data === 'string') {
      return __toBase64(new TextEncoder().encode(data));
    }
    return __toBase64(data);
  }

  // Per-method param normalization shared by request() and the
  // convenience wrappers, so `request({method, params})` stays
  // byte-equivalent to the wrapper call (SWIP §"Convenience Methods").
  // Typed arrays / ArrayBuffers become base64 (WKWebView's typed-array
  // bridging is version-dependent); `bigint` spans become decimal
  // strings (postMessage can't serialize BigInt).
  function normalizeParams(method, params) {
    params = params || {};
    if (method === 'swarm_publishFiles' && Array.isArray(params.files)) {
      return Object.assign({}, params, {
        files: params.files.map(function (f) {
          return {
            path: f.path,
            contentType: f.contentType,
            bytes: __toBase64(f.bytes),
          };
        }),
      });
    }
    if (method === 'swarm_writeFeedEntry'
        && params.data !== undefined && params.data !== null) {
      return Object.assign({}, params, { data: __payloadToBase64(params.data) });
    }
    if (method === 'swarm_publishChunk' || method === 'swarm_writeSingleOwnerChunk') {
      var next = Object.assign({}, params);
      if (params.data !== undefined && params.data !== null) {
        next.data = __payloadToBase64(params.data);
      }
      if (typeof params.span === 'bigint') {
        next.span = params.span.toString();
      }
      return next;
    }
    // Messaging sends take the same `string | Uint8Array | ArrayBuffer`
    // payload contract as writeFeedEntry ("Strings encoded UTF-8").
    // `''` must survive as an empty payload — PSS zero-byte pings are
    // valid — so only skip undefined/null, not falsy.
    if (method === 'swarm_sendPss' || method === 'swarm_sendGsoc') {
      if (params.data !== undefined && params.data !== null) {
        return Object.assign({}, params, { data: __payloadToBase64(params.data) });
      }
      return params;
    }
    return params;
  }

  // Chunk-read spans above Number.MAX_SAFE_INTEGER cross the bridge as
  // decimal strings; surface them as `bigint` per the SWIP's
  // `span: number | bigint` result contract.
  function postProcessResult(method, result) {
    if ((method === 'swarm_readChunk' || method === 'swarm_readSingleOwnerChunk')
        && result && typeof result.span === 'string') {
      result.span = BigInt(result.span);
    }
    return result;
  }

  function makeRequest(method, params) {
    const id = ++requestId;
    var normalized = normalizeParams(method, params);
    return new Promise(function (resolve, reject) {
      pendingRequests.set(id, { resolve: resolve, reject: reject, method: method });
      postToNative({ type: 'request', id: id, method: method, params: normalized });
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
    publishFiles: function (params) {
      // WKWebView's bridging of `Uint8Array` / `ArrayBuffer` to native
      // is version-dependent — sometimes NSData, sometimes NSArray of
      // NSNumber. Pre-encode each file's bytes as a base64 string here
      // and decode on the native side: stable across iOS versions and
      // independent of the JS runtime's typed-array representation.
      var normalized = params;
      if (params && Array.isArray(params.files)) {
        normalized = Object.assign({}, params, {
          files: params.files.map(function (f) {
            return {
              path: f.path,
              contentType: f.contentType,
              bytes: __toBase64(f.bytes),
            };
          }),
        });
      }
      return makeRequest('swarm_publishFiles', normalized);
    },
    getUploadStatus: function (params) { return makeRequest('swarm_getUploadStatus', params); },
    createFeed: function (params) { return makeRequest('swarm_createFeed', params); },
    updateFeed: function (params) { return makeRequest('swarm_updateFeed', params); },
    // Payload/span normalization happens in normalizeParams so the
    // request() path behaves identically.
    writeFeedEntry: function (params) { return makeRequest('swarm_writeFeedEntry', params); },
    readFeedEntry: function (params) { return makeRequest('swarm_readFeedEntry', params); },
    listFeeds: function () { return makeRequest('swarm_listFeeds'); },
    publishChunk: function (params) { return makeRequest('swarm_publishChunk', params); },
    readChunk: function (params) { return makeRequest('swarm_readChunk', params); },
    writeSingleOwnerChunk: function (params) { return makeRequest('swarm_writeSingleOwnerChunk', params); },
    readSingleOwnerChunk: function (params) { return makeRequest('swarm_readSingleOwnerChunk', params); },
    getSigningIdentity: function () { return makeRequest('swarm_getSigningIdentity'); },
    // Messaging extension (SWIP messaging §"Convenience Methods").
    getMessagingIdentity: function () { return makeRequest('swarm_getMessagingIdentity'); },
    subscribe: function (params) { return makeRequest('swarm_subscribe', params); },
    unsubscribe: function (params) { return makeRequest('swarm_unsubscribe', params); },
    sendPss: function (params) { return makeRequest('swarm_sendPss', params); },
    sendGsoc: function (params) { return makeRequest('swarm_sendGsoc', params); },

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
        pending.resolve(postProcessResult(pending.method, result));
      }
    },
    __handleEvent: function (event, data) {
      emitEvent(event, data);
    },
  };
})();
