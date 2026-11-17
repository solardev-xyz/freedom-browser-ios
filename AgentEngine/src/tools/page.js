// The browser tools: desktop Freedom's names, parameters and descriptions
// (src/main/agent/pi-browser-tools.js), cut to what the phone does: one
// tab (the user's active one), its main frame, no screenshots, uploads,
// downloads, dialogs or page tools yet. Every call goes to the app's `page`
// service (AgentPageDriver.swift), which runs page/index.js in the tab.

import { defineTool } from "@earendil-works/pi-durable";
import { arr, bool, int, num, obj, oneOf, opt, str } from "@earendil-works/pi-schema";

const INTENT_DESCRIPTION =
	"Briefly state what you expect this exact interaction to accomplish. Freedom uses this as untrusted input when deciding whether the user should approve it.";
const intent = () => opt(str({ minLength: 1, maxLength: 240, description: INTENT_DESCRIPTION }));
const ref = () => str({ minLength: 1, maxLength: 200 });

export const PRESS_KEYS = ["Enter", "Tab", "Escape", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown", "Backspace", "Delete", "Space"];
const MAX_WAIT_TIMEOUT_MS = 30_000;
const DEFAULT_WAIT_TIMEOUT_MS = 10_000;

/** Tools that act on the page, for the approval gate. */
export const INTERACTION_TOOLS = new Set(["browser_click", "browser_type", "browser_select", "browser_scroll", "browser_press"]);

const REASONS = {
	changed: "STALE_ELEMENT_REFERENCE: that element is gone or the page changed. Take a new snapshot and use its references.",
	not_interactable: "ELEMENT_NOT_INTERACTABLE: the element is hidden, covered, disabled or doesn't accept this action. Take a new snapshot.",
	unsupported_key: "UNSUPPORTED_KEY: that key isn't supported.",
	unknown_method: "The page script doesn't know that action.",
};

function check(result) {
	if (result && result.ok === false) throw new Error(REASONS[result.reason] ?? `The action failed (${result.reason ?? "unknown"}).`);
	return result;
}

const json = (value) => ({ output: [{ type: "text", text: JSON.stringify(value) }] });

/**
 * `page(method, params)`: the host's page service. Returns the tools plus
 * `describeAction(name, args)` for the approval gate: what the element is,
 * whether it submits a form or opens a link, whether it's a password field.
 */
export function createPageTools(page) {
	const call = async (method, params = {}) => check(await page(method, params));

	const tools = [
		defineTool({
			name: "browser_get_tab",
			description: "Get the current URL, title, loading state, and navigation ID of the active task tab.",
			parameters: obj({}),
			replay: "safe",
			execute: async () => json(await call("tab")),
		}),
		defineTool({
			name: "browser_snapshot",
			description:
				"Read the active task tab with control names and available checked/selected/pressed/expanded states. Use references for interaction. Optional query filters control names. Optional textQuery finds the next literal, case-insensitive match in collected rendered text and returns a short excerpt plus textMatch offsets (or null). This only reads; it does not scroll. For the next match, pass nextMatchOffset as textOffset with the same textQuery. Text not yet loaded requires scrolling first. For omitted controls/text, pass the returned nextElementOffset/nextTextOffset as elementOffset/textOffset with the same query. Each call reads the live page: content can move between calls; restart or search if it changes. Display fields can be shortened (nameTruncated, labelTruncated); oversized URLs and exact values are omitted (urlOmitted, valueOmitted). optionsTruncated means some dropdown choices are missing. Respect fieldsTruncated, scanTruncated and textCollectionTruncated; no match is not proof of absence when collection was limited.",
			parameters: obj({
				query: opt(str({ maxLength: 200 })),
				textQuery: opt(str({ maxLength: 200 })),
				elementOffset: opt(int({ minimum: 0, maximum: 1_000_000 })),
				textOffset: opt(int({ minimum: 0, maximum: 1_000_000 })),
			}),
			replay: "safe",
			execute: async (args) => {
				const tab = await call("tab");
				const result = await call("snapshot", { options: args });
				return json({ ok: true, navigationId: tab.navigationId, result });
			},
		}),
		defineTool({
			name: "browser_navigate",
			description:
				"Navigate the active task tab to an absolute http, https, bzz, ipfs, ipns or ens URL without embedded credentials. ENS names (name.eth) open the site their content hash points to, on Swarm or IPFS.",
			parameters: obj({ url: str({ minLength: 1, maxLength: 4000 }) }),
			replay: "unsafe",
			execute: async ({ url }) => json(await call("navigate", { url })),
		}),
		defineTool({
			name: "browser_click",
			description: "Click an element in the active task tab using a reference from the latest page snapshot.",
			parameters: obj({ ref: ref(), intent: intent() }),
			replay: "unsafe",
			execute: async ({ ref }) => json(await call("click", { ref })),
		}),
		defineTool({
			name: "browser_type",
			description: "Type text into an editable element using a reference from the latest page snapshot. Replaces existing text by default.",
			parameters: obj({ ref: ref(), text: str({ maxLength: 20_000 }), replace: opt(bool()), intent: intent() }),
			replay: "unsafe",
			execute: async ({ ref, text, replace }) => json(await call("type", { ref, text, replace: replace !== false })),
		}),
		defineTool({
			name: "browser_select",
			description:
				"Select native dropdown/listbox options using exact observed values. Pass value for a single option, or values for the complete desired set in a multiple select (an empty array clears it). Do not send both. Selection emits synthetic input/change events, not trusted pointer events. Disabled/ambiguous options are rejected. For custom ARIA menus, use observed clicks and fresh snapshots.",
			parameters: obj({ ref: ref(), value: opt(str({ maxLength: 2000 })), values: opt(arr(str({ maxLength: 2000 }), { maxItems: 100, uniqueItems: true })), intent: intent() }),
			replay: "unsafe",
			execute: async ({ ref, value, values }) => {
				if ((value === undefined) === (values === undefined)) throw new Error("Pass either value or values.");
				return json(await call("select", { ref, value: values ?? value }));
			},
		}),
		defineTool({
			name: "browser_scroll",
			description:
				"Scroll using a reference from the latest snapshot: frames[].viewport.ref for the page, or an element with scrollable state for a nested container. Choose up/down/left/right and optionally 0.1–3 viewport pages (default 1). Result reports actual movement, boundary, or no_movement. Do not repeat a blocked/no-movement scroll blindly; read a fresh snapshot to check lazy-loaded content or choose another container. This does not click or focus a control.",
			parameters: obj({ ref: ref(), direction: oneOf(["up", "down", "left", "right"]), pages: opt(num({ minimum: 0.1, maximum: 3 })), intent: intent() }),
			replay: "unsafe",
			execute: async ({ ref, direction, pages }) => json(await call("scroll", { ref, direction, pages })),
		}),
		defineTool({
			name: "browser_press",
			description: "Focus an element from the latest page snapshot and press one supported named key.",
			parameters: obj({ ref: ref(), key: oneOf(PRESS_KEYS), intent: intent() }),
			replay: "unsafe",
			execute: async ({ ref, key }) => json(await call("press", { ref, key })),
		}),
		defineTool({
			name: "browser_wait",
			description:
				"Wait up to 30 seconds for load completion, a navigation, visible text, an exact URL, or a state of an observed control. For condition element, supply its ref and state. Hidden includes a removed original element; a replacement never inherits its reference. Wait for an actual expected outcome instead of repeating an action or guessing a sleep.",
			parameters: obj({
				condition: oneOf(["load", "navigation", "text", "url", "element"]),
				ref: opt(ref()),
				state: opt(oneOf(["visible", "hidden", "enabled", "disabled", "checked", "unchecked", "expanded", "collapsed"])),
				timeoutMs: opt(int({ minimum: 0, maximum: MAX_WAIT_TIMEOUT_MS })),
				text: opt(str({ minLength: 1, maxLength: 2000 })),
				url: opt(str({ minLength: 1, maxLength: 4000 })),
				sinceNavigationId: opt(int({ minimum: 0 })),
			}),
			replay: "safe",
			execute: async (args, ctx) => json(await waitFor(call, args, ctx?.abortSignal)),
		}),
	];

	return {
		tools,
		/**
		 * What an interaction would touch, for approvals: `{ described }` (label,
		 * effect, navigation target, form fingerprint), `{ stale }` when the
		 * reference no longer resolves (the tool then fails with the reason), or
		 * `{ unavailable }` when the element couldn't be inspected, which must
		 * not let the action skip the approval.
		 */
		async describeAction(name, args) {
			const action = name.replace("browser_", "");
			try {
				const described = await page("describe", { ref: args.ref, action, key: args.key ?? "" });
				if (described?.ok) return { described };
				if (described?.reason === "changed" || described?.reason === "not_interactable") return { stale: described.reason };
				return { unavailable: described?.reason ?? "unknown" };
			} catch (error) {
				return { unavailable: error?.message ?? String(error) };
			}
		},
		call,
	};
}

/** browser_wait: polls the tab or the page every 100 ms. */
export async function waitFor(call, { condition, ref, state, timeoutMs, text, url, sinceNavigationId }, signal) {
	const limit = Math.min(MAX_WAIT_TIMEOUT_MS, timeoutMs ?? DEFAULT_WAIT_TIMEOUT_MS);
	const started = Date.now();
	const initial = await call("tab");
	const since = sinceNavigationId ?? initial.navigationId;
	if (condition === "element" && (!ref || !state)) throw new Error("condition element needs ref and state.");
	if (condition === "text" && !text) throw new Error("condition text needs text.");
	if (condition === "url" && !url) throw new Error("condition url needs url.");
	for (;;) {
		signal?.throwIfAborted();
		const tab = await call("tab");
		let matched = false;
		switch (condition) {
			case "load":
				matched = !tab.loading;
				break;
			case "navigation":
				matched = tab.navigationId > since;
				break;
			case "url":
				matched = tab.url === url;
				break;
			case "text":
				matched = !tab.loading && (await call("containsText", { text })).matched === true;
				break;
			case "element":
				matched = (await call("matches", { ref, state })).matched === true;
				break;
		}
		if (matched) return { ok: true, condition, waitedMs: Date.now() - started, tab };
		if (Date.now() - started >= limit) return { ok: false, condition, timedOut: true, waitedMs: Date.now() - started, tab };
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
}
