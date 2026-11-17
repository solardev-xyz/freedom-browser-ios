// Bridge between the engine (inside a hidden WKWebView) and the app.
//
// - Engine → app: `request(service, method, params)` posts to the
//   `freedomAgent` script message handler and awaits the app's reply
//   (WKScriptMessageHandlerWithReply). `emit(event)` is fire-and-forget.
// - App → engine: the app calls `window.__freedomAgent.command(name, params)`
//   with callAsyncJavaScript and awaits the returned promise.

function handler() {
	const h = window.webkit?.messageHandlers?.freedomAgent;
	if (!h) throw new Error("No freedomAgent message handler: the engine only runs inside Freedom");
	return h;
}

// Message handlers take JSON-like values only.
const plain = (value) => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)));

// Requests waiting for the app's reply, for diagnostics (`pendingRequests`).
const pending = new Map();
let nextRequest = 0;

export async function request(service, method, params) {
	const id = nextRequest++;
	pending.set(id, { service, method, since: Date.now(), detail: service === "sql" ? String(params?.sql ?? "").slice(0, 80) : "" });
	try {
		return await handler().postMessage({ service, method, params: plain(params) });
	} finally {
		pending.delete(id);
	}
}

/** Requests older than `ms` still waiting for the app. */
export const pendingRequests = (ms = 0) => [...pending.values()].filter((r) => Date.now() - r.since >= ms).map((r) => ({ ...r, ageMs: Date.now() - r.since }));

export function emit(event) {
	handler()
		.postMessage({ service: "event", method: "emit", params: plain(event) })
		.catch(() => {});
}

const commands = new Map();

export function onCommand(name, run) {
	commands.set(name, run);
}

window.__freedomAgent = {
	async command(name, params) {
		const run = commands.get(name);
		if (!run) throw new Error(`Unknown engine command: ${name}`);
		return plain(await run(params ?? {}));
	},
};

// The engine has no visible console: forward it, and uncaught errors, to the app's log.
export function forwardConsole() {
	for (const level of ["log", "info", "warn", "error", "debug"]) {
		const original = console[level].bind(console);
		console[level] = (...args) => {
			original(...args);
			const text = args.map((a) => (typeof a === "string" ? a : a instanceof Error ? `${a.message}\n${a.stack ?? ""}` : safeJSON(a))).join(" ");
			handler().postMessage({ service: "log", method: level, params: text }).catch(() => {});
		};
	}
	window.addEventListener("error", (e) => console.error("Uncaught", e.error ?? e.message));
	window.addEventListener("unhandledrejection", (e) => console.error("Unhandled rejection", e.reason));
}

function safeJSON(value) {
	try {
		return JSON.stringify(value);
	} catch {
		return String(value);
	}
}
