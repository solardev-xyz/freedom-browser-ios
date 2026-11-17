// The browser tools: desktop Freedom's names, parameters and descriptions
// (src/main/agent/pi-browser-tools.js). Every call goes to the app's `page`
// service (AgentPageDriver.swift) with the calling chat's ID: each chat has
// its own tabs (the user's tab it started in, the tabs it opened) and an
// active one its tools act on. The driver runs page/index.js in the tab.
// Not here yet: frames, dialogs, uploads, downloads; page tools (WebMCP)
// don't exist in WebKit.

import { defineTool } from "@earendil-works/pi-durable";
import { arr, bool, int, num, obj, oneOf, opt, str } from "@earendil-works/pi-schema";

const INTENT_DESCRIPTION =
	"Briefly state what you expect this exact interaction to accomplish. Freedom uses this as untrusted input when deciding whether the user should approve it.";
const intent = () => opt(str({ minLength: 1, maxLength: 240, description: INTENT_DESCRIPTION }));
const ref = () => str({ minLength: 1, maxLength: 200 });

export const PRESS_KEYS = ["Enter", "Tab", "Escape", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown", "Backspace", "Delete", "Space"];
const MAX_WAIT_TIMEOUT_MS = 30_000;
const DEFAULT_WAIT_TIMEOUT_MS = 10_000;
const DWEB_NAVIGATION_GUIDANCE =
	" ENS names (name.eth) open the site their content hash points to, on Swarm or IPFS; navigate to the name itself (vitalik.eth or ens://vitalik.eth), never an invented https:// URL for it, which would use DNS instead of Freedom's name resolution.";

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
 * `page(method, params)`: the host's page service. Returns the tools plus,
 * for the approval gate, `describeAction(name, args, chatId)`: what the
 * element is, whether it submits a form or opens a link, whether it's a
 * password field.
 */
export function createPageTools(page) {
	/** One page-service call for chat `chatId` (none: the user's visible tab). */
	const call = async (method, params = {}, chatId) => check(await page(method, chatId === undefined ? params : { ...params, chatId }));
	/** The calls of one tool invocation, for its chat. */
	const forChat = (api) => (method, params) => call(method, params, api.conversationId);
	// Running browser_wait calls per chat, which browser_stop_loading cancels.
	const waits = new Map();
	const runWait = async (api, args, ctx) => {
		const controller = new AbortController();
		const chatWaits = waits.get(api.conversationId) ?? new Set();
		waits.set(api.conversationId, chatWaits.add(controller));
		const signal = ctx?.abortSignal ? AbortSignal.any([ctx.abortSignal, controller.signal]) : controller.signal;
		try {
			return await waitFor(forChat(api), args, signal);
		} catch (error) {
			if (controller.signal.aborted) return { ok: false, condition: args.condition, stopped: true };
			throw error;
		} finally {
			chatWaits.delete(controller);
		}
	};

	const tools = [
		defineTool({
			name: "browser_get_tab",
			description: "Get the current URL, title, loading state, and navigation ID of the active task tab.",
			parameters: obj({}),
			replay: "safe",
			execute: async (_, api) => json(await forChat(api)("tab")),
		}),
		defineTool({
			name: "browser_list_tabs",
			description: "List only the browser tabs owned by this Agent task and identify the active tab.",
			parameters: obj({}),
			replay: "safe",
			execute: async (_, api) => json(await forChat(api)("tabs")),
		}),
		defineTool({
			name: "browser_create_tab",
			description:
				"Create a visible task-owned tab at a supported web or distributed-web URL and make it the active Agent tab. Call once per new tab. No page snapshot is required to create a tab." +
				DWEB_NAVIGATION_GUIDANCE,
			parameters: obj({ url: str({ minLength: 1, maxLength: 4000 }) }),
			replay: "unsafe",
			execute: async ({ url }, api) => json(await forChat(api)("createTab", { url })),
		}),
		defineTool({
			name: "browser_focus_tab",
			description: "Focus a task-owned browser tab by ID and make it the active tab for subsequent Agent tools. The user sees the focused tab.",
			parameters: obj({ tabId: str({ minLength: 1, maxLength: 80 }) }),
			replay: "safe",
			execute: async ({ tabId }, api) => json(await forChat(api)("focusTab", { tabId })),
		}),
		defineTool({
			name: "browser_close_tab",
			description: "Close a tab created by this task. Tabs the user opened, including the one this task started in, cannot be closed by the Agent.",
			parameters: obj({ tabId: str({ minLength: 1, maxLength: 80 }) }),
			replay: "unsafe",
			execute: async ({ tabId }, api) => json(await forChat(api)("closeTab", { tabId })),
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
			execute: async (args, api) => {
				const tab = await forChat(api)("tab");
				const result = await forChat(api)("snapshot", { options: args });
				return json({ ok: true, tabId: tab.tabId, navigationId: tab.navigationId, result });
			},
		}),
		defineTool({
			name: "browser_navigate",
			description:
				"Navigate the active task tab to an absolute http, https, bzz, ipfs, ipns or ens URL without embedded credentials." + DWEB_NAVIGATION_GUIDANCE,
			parameters: obj({ url: str({ minLength: 1, maxLength: 4000 }) }),
			replay: "unsafe",
			execute: async ({ url }, api) => json(await forChat(api)("navigate", { url })),
		}),
		defineTool({
			name: "browser_click",
			description: "Click an element in the active task tab using a reference from the latest page snapshot.",
			parameters: obj({ ref: ref(), intent: intent() }),
			replay: "unsafe",
			execute: async ({ ref }, api) => json(await forChat(api)("click", { ref })),
		}),
		defineTool({
			name: "browser_type",
			description: "Type text into an editable element using a reference from the latest page snapshot. Replaces existing text by default.",
			parameters: obj({ ref: ref(), text: str({ maxLength: 20_000 }), replace: opt(bool()), intent: intent() }),
			replay: "unsafe",
			execute: async ({ ref, text, replace }, api) => json(await forChat(api)("type", { ref, text, replace: replace !== false })),
		}),
		defineTool({
			name: "browser_select",
			description:
				"Select native dropdown/listbox options using exact observed values. Pass value for a single option, or values for the complete desired set in a multiple select (an empty array clears it). Do not send both. Selection emits synthetic input/change events, not trusted pointer events. Disabled/ambiguous options are rejected. For custom ARIA menus, use observed clicks and fresh snapshots.",
			parameters: obj({ ref: ref(), value: opt(str({ maxLength: 2000 })), values: opt(arr(str({ maxLength: 2000 }), { maxItems: 100, uniqueItems: true })), intent: intent() }),
			replay: "unsafe",
			execute: async ({ ref, value, values }, api) => {
				if ((value === undefined) === (values === undefined)) throw new Error("Pass either value or values.");
				return json(await forChat(api)("select", { ref, value: values ?? value }));
			},
		}),
		defineTool({
			name: "browser_scroll",
			description:
				"Scroll using a reference from the latest snapshot: frames[].viewport.ref for the page, or an element with scrollable state for a nested container. Choose up/down/left/right and optionally 0.1–3 viewport pages (default 1). Result reports actual movement, boundary, or no_movement. Do not repeat a blocked/no-movement scroll blindly; read a fresh snapshot to check lazy-loaded content or choose another container. This does not click or focus a control.",
			parameters: obj({ ref: ref(), direction: oneOf(["up", "down", "left", "right"]), pages: opt(num({ minimum: 0.1, maximum: 3 })), intent: intent() }),
			replay: "unsafe",
			execute: async ({ ref, direction, pages }, api) => json(await forChat(api)("scroll", { ref, direction, pages })),
		}),
		defineTool({
			name: "browser_press",
			description: "Focus an element from the latest page snapshot and press one supported named key.",
			parameters: obj({ ref: ref(), key: oneOf(PRESS_KEYS), intent: intent() }),
			replay: "unsafe",
			execute: async ({ ref, key }, api) => json(await forChat(api)("press", { ref, key })),
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
			execute: async (args, api, ctx) => json(await runWait(api, args, ctx)),
		}),
		defineTool({
			name: "browser_stop_loading",
			description: "Stop loading and cancel active waits in the active task tab.",
			parameters: obj({}),
			replay: "safe",
			execute: async (_, api) => {
				for (const controller of waits.get(api.conversationId) ?? []) controller.abort();
				return json(await forChat(api)("stop"));
			},
		}),
		defineTool({
			name: "browser_screenshot",
			description:
				"Look at the visible viewport of the active task tab when visual layout or non-semantic content matters. This is observation only. Use a fresh page snapshot for semantic interaction. If it cannot describe a canvas or custom control, use browser_target_point with the returned captureRef and normalized coordinates from this complete image. Needs a model that accepts images.",
			parameters: obj({}),
			replay: "safe",
			execute: async (_, api, ctx) => {
				await requireVision(api, ctx);
				const { base64, mediaType, ...rest } = await forChat(api)("screenshot");
				const text = JSON.stringify({
					ok: true,
					result: { mediaType, ...rest },
					instruction:
						"This is the full visible viewport. Prefer a fresh semantic snapshot and its references. For canvas or controls missing from semantic observations, use browser_target_point with captureRef and normalized full-image coordinates; do not use coordinates from a crop.",
				});
				return { output: [{ type: "text", text }, { type: "image", data: base64, mimeType: mediaType }] };
			},
		}),
		defineTool({
			name: "browser_target_point",
			description:
				"Fallback for canvas or controls absent from semantic observations. Use a fresh browser_screenshot captureRef and normalized x/y coordinates (0 to less than 1) relative to the entire displayed image, never a crop. This only prepares a single-use reference; use browser_click on it afterward. Changed screenshot, viewport, zoom or hit target invalidates it. Semantic controls and embedded frames require their normal references. The effect of a visual click is unknown and may require approval.",
			parameters: obj({ captureRef: str({ minLength: 1, maxLength: 120 }), x: num({ minimum: 0, exclusiveMaximum: 1 }), y: num({ minimum: 0, exclusiveMaximum: 1 }) }),
			replay: "safe",
			execute: async ({ captureRef, x, y }, api, ctx) => {
				await requireVision(api, ctx);
				return json(await forChat(api)("targetPoint", { captureRef, x, y }));
			},
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
		async describeAction(name, args, chatId) {
			const action = name.replace("browser_", "");
			try {
				const described = await page("describe", { ref: args.ref, action, key: args.key ?? "", ...(chatId !== undefined && { chatId }) });
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

/** Screenshots go to the model as images: only to one that accepts them. */
async function requireVision(api, ctx) {
	const agent = await api.agent(ctx);
	const model = agent?.model && api.models.getModel(agent.model.provider, agent.model.modelId);
	if (model && !model.input?.includes("image")) {
		throw new Error("CAPABILITY_UNAVAILABLE: the selected model doesn't accept images, so it can't look at the page. Use browser_snapshot instead.");
	}
}

/** browser_wait: polls the tab or the page every 100 ms. `call` is bound to the chat. */
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
