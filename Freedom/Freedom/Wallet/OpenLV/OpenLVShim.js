/**
 * JS half of WebViewOpenLVEngine. Mirrors the desktop bridge page
 * (freedom-browser bridge/bridge.js) but forwards the browser's
 * JSON-RPC requests to native Swift over webkit.messageHandlers
 * instead of window.ethereum — the native side gates everything
 * through the wallet's approval sheets.
 *
 * Classic script, not a module: WKWebView refuses ES-module imports
 * from file:// pages (opaque origin + CORS), so the SDK is loaded as
 * the IIFE flavor (openlv.iife.js → window.OpenLV) by OpenLVShell.html
 * before this file.
 *
 * Wire surfaces:
 *  - shim → native: postMessage({type: 'ready' | 'status' | 'request', …})
 *    (parsed by OpenLVShimMessage.swift)
 *  - native → shim: window.__freedomOpenLV.__handleResponse(id, result, error)
 *    and .__handleEvent('start' | 'stop', data)
 *    (produced by BridgeReplyChannel.swift)
 */

(() => {
  const { createSession, decodeConnectionURL, mqtt, webrtc } = window.OpenLV;

  // Same allowlist as the desktop bridge page — refused here at the
  // transport edge, independent of the native approval layer, so a
  // malicious QR can't turn the endpoint into a generic RPC proxy.
  const ALLOWED_METHODS = new Set([
    'eth_requestAccounts',
    'eth_accounts',
    'eth_chainId',
    'personal_sign',
    'eth_signTypedData_v4',
    'eth_sendTransaction',
    'wallet_switchEthereumChain',
    'wallet_addEthereumChain',
  ]);

  const post = (message) => window.webkit.messageHandlers.openlv.postMessage(message);

  const pending = new Map();
  let nextRequestId = 1;
  let session = null;

  /**
   * The openlv session's incoming-request handler. Resolves to the
   * response envelope ({result} or {error: {code, message}}) that
   * session.send on the browser side unwraps.
   */
  function handleRequest(payload) {
    const { method, params } = payload || {};
    if (!ALLOWED_METHODS.has(method)) {
      return Promise.resolve({
        error: { code: -32601, message: 'Method not supported by this wallet endpoint' },
      });
    }
    const id = nextRequestId++;
    return new Promise((resolve) => {
      pending.set(id, resolve);
      post({ type: 'request', id, method, params: params ?? [] });
    });
  }

  async function start(uri) {
    try {
      const params = decodeConnectionURL(uri);
      if (params.p !== 'mqtt') {
        throw new Error(`Unsupported signaling protocol "${params.p}"`);
      }
      post({ type: 'status', status: 'connecting' });
      session = await createSession(params, mqtt, [webrtc()], handleRequest);
      session.emitter.on('state_change', (state) => {
        if (state?.status === 'connected') {
          post({ type: 'status', status: 'connected' });
        } else if (state?.status === 'disconnected') {
          post({ type: 'status', status: 'disconnected' });
        }
      });
      await session.connect();
    } catch (err) {
      post({ type: 'status', status: 'failed', message: String(err?.message || err) });
    }
  }

  function stop() {
    if (!session) return;
    Promise.resolve(session.close()).catch(() => {});
    session = null;
  }

  window.__freedomOpenLV = {
    // Exposed for engine tests: same function the openlv session calls,
    // so tests can drive the full JS↔native round trip without a peer.
    request: handleRequest,

    __handleResponse(id, result, error) {
      const resolve = pending.get(id);
      if (!resolve) return;
      pending.delete(id);
      resolve(error ? { error } : { result });
    },

    __handleEvent(name, data) {
      if (name === 'start') start(data);
      if (name === 'stop') stop();
    },
  };

  post({ type: 'ready' });
})();
