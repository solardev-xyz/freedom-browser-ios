// The agent's hands on a web page, run in the tab's isolated content world
// ("FreedomAgent"), so page scripts can neither see nor call it.
//
// Reading (snapshot, element references, state checks) is desktop's code,
// unchanged (desktop-page.js). Input is not: desktop sends OS-level mouse
// and key events, which a WKWebView can't. Here every action is page
// events dispatched from script (`isTrusted` false), shaped like a tap or a
// keystroke, plus the default action the browser would have taken for a
// real one (implicit form submission on Enter, focus moves on Tab, …),
// since browsers don't run those for script events. Results say
// `trusted: false` so the model and the logs know.

import {
	collectPageSnapshot,
	describeReferencedElement,
	inspectReferencedElement,
	inspectScrollReference,
	pageContainsText,
	prepareTextInsertion,
	readScrollState,
	referencedElementMatchesState,
	selectOptionByValue,
} from "./desktop-page.js";
import { ensureDigest } from "./sha256.js";

const VERSION = 1;
const MAX_PAGE_TEXT_LENGTH = 12_000;
const MAX_SNAPSHOT_ELEMENTS = 250;
const MAX_RETAINED_REFERENCES = 1_000;
const MAX_SELECT_OPTIONS = 100;

const hex = (bytes) => Array.from(crypto.getRandomValues(new Uint8Array(bytes)), (b) => b.toString(16).padStart(2, "0")).join("");
// This world's globals live as long as the document: a new document gets a new ID.
const documentId = `document_${hex(16)}`;

const reference = (ref) => globalThis.__FREEDOM_AUTOMATION_ELEMENT_REFERENCES__?.refs?.get(ref);
const nextFrame = (view) => new Promise((resolve) => view.requestAnimationFrame(() => resolve()));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function deepHit(root, x, y) {
	let hit = root.elementFromPoint(x, y);
	while (hit?.shadowRoot) {
		const nested = hit.shadowRoot.elementFromPoint(x, y);
		if (!nested || nested === hit) break;
		hit = nested;
	}
	return hit;
}

function deepActiveElement(doc) {
	let active = doc.activeElement;
	while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
	return active;
}

const FOCUSABLE = 'a[href],area[href],button,input,select,textarea,iframe,summary,[tabindex],[contenteditable=""],[contenteditable="true"]';

function focusTarget(element) {
	for (let node = element; node; node = node.parentElement || node.getRootNode()?.host) {
		if (node.matches?.(FOCUSABLE) && !node.matches(":disabled")) return node;
	}
	return null;
}

// MARK: - snapshot

function snapshot(options = {}) {
	const result = collectPageSnapshot(MAX_PAGE_TEXT_LENGTH, MAX_SNAPSHOT_ELEMENTS, MAX_RETAINED_REFERENCES, MAX_SELECT_OPTIONS, `ref_${hex(8)}`, options);
	return { ...result, documentId };
}

// MARK: - click

/** A tap: pointer and touch events, the compatibility mouse events, focus and click. */
async function click(ref) {
	const inspected = inspectReferencedElement(ref, "click");
	if (!inspected.ok) return inspected;
	const { element } = reference(ref);
	const doc = element.ownerDocument;
	const view = doc.defaultView;
	// inspectReferencedElement scrolled it to the centre; tap that point in its own frame.
	const rect = element.getBoundingClientRect();
	const x = rect.left + rect.width / 2;
	const y = rect.top + rect.height / 2;
	const hit = deepHit(doc, x, y);
	const target = hit && (hit === element || element.contains(hit)) ? hit : element;
	const base = { bubbles: true, cancelable: true, composed: true, view, clientX: x, clientY: y, screenX: x, screenY: y };
	const pointer = { ...base, pointerId: 1, pointerType: "touch", isPrimary: true, width: 1, height: 1, pressure: 0.5 };
	const fire = (event) => target.dispatchEvent(event);

	fire(new view.PointerEvent("pointerover", pointer));
	fire(new view.PointerEvent("pointerenter", { ...pointer, bubbles: false, cancelable: false }));
	fire(new view.PointerEvent("pointerdown", { ...pointer, button: 0, buttons: 1 }));
	let touchCancelled = false;
	const touch = touchEvents(view, target, x, y);
	if (touch) {
		fire(touch.start);
		await nextFrame(view);
		fire(new view.PointerEvent("pointerup", { ...pointer, button: 0, buttons: 0, pressure: 0 }));
		touchCancelled = !fire(touch.end);
	} else {
		await nextFrame(view);
		fire(new view.PointerEvent("pointerup", { ...pointer, button: 0, buttons: 0, pressure: 0 }));
	}
	fire(new view.PointerEvent("pointerout", pointer));
	fire(new view.PointerEvent("pointerleave", { ...pointer, bubbles: false, cancelable: false }));
	// A page that cancels touchend handled the tap itself: browsers then send no mouse events or click.
	if (touchCancelled) return { clicked: true, ref, trusted: false, handledByTouch: true };

	const mouse = { ...base, button: 0, detail: 1 };
	fire(new view.MouseEvent("mouseover", mouse));
	fire(new view.MouseEvent("mousemove", mouse));
	const focusAllowed = fire(new view.MouseEvent("mousedown", { ...mouse, buttons: 1 }));
	if (focusAllowed) {
		const focusable = focusTarget(target);
		if (focusable && deepActiveElement(doc) !== focusable) focusable.focus({ preventScroll: true });
		else if (!focusable) deepActiveElement(doc)?.blur?.();
	}
	fire(new view.MouseEvent("mouseup", { ...mouse, buttons: 0 }));
	// Runs the activation behaviour too: links follow, checkboxes toggle, submit buttons submit.
	fire(new view.MouseEvent("click", { ...mouse, buttons: 0 }));
	return { clicked: true, ref, trusted: false };
}

function touchEvents(view, target, x, y) {
	try {
		const point = new view.Touch({ identifier: 1, target, clientX: x, clientY: y, screenX: x, screenY: y, pageX: x + view.scrollX, pageY: y + view.scrollY, radiusX: 1, radiusY: 1, force: 0.5 });
		const options = { bubbles: true, cancelable: true, composed: true, view };
		return {
			start: new view.TouchEvent("touchstart", { ...options, touches: [point], targetTouches: [point], changedTouches: [point] }),
			end: new view.TouchEvent("touchend", { ...options, touches: [], targetTouches: [], changedTouches: [point] }),
		};
	} catch {
		return null; // No Touch constructor here.
	}
}

// MARK: - type

const valueOf = (element) => (element.isContentEditable ? element.textContent : String(element.value ?? ""));

/** Inserts text as typing would: through the editing command, so the page sees beforeinput/input. */
function type(ref, text, replace = true) {
	const prepared = prepareTextInsertion(ref, replace);
	if (!prepared.ok) return prepared;
	const { element } = reference(ref);
	const doc = element.ownerDocument;
	const before = valueOf(element);
	let method = "insertText";
	let ok = false;
	try {
		ok = text === "" ? (replace ? doc.execCommand("delete") : true) : doc.execCommand("insertText", false, text);
	} catch {
		ok = false;
	}
	const expected = replace ? text : before + text;
	if (!ok || (!element.isContentEditable && valueOf(element) !== expected && valueOf(element) === before)) {
		// The editing command did nothing (some input types, some frameworks): set the value the
		// way a framework's own setter would, then announce it.
		if (element.isContentEditable) return { ok: false, reason: "not_interactable" };
		const view = doc.defaultView;
		const proto = element instanceof view.HTMLTextAreaElement ? view.HTMLTextAreaElement.prototype : view.HTMLInputElement.prototype;
		Object.getOwnPropertyDescriptor(proto, "value").set.call(element, expected);
		element.dispatchEvent(new view.InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: text }));
		method = "value";
	}
	return { typed: true, ref, characters: text.length, method, trusted: false };
}

// MARK: - press

const KEYS = {
	Enter: { code: "Enter", keyCode: 13, char: "\r" },
	Tab: { code: "Tab", keyCode: 9 },
	Escape: { code: "Escape", keyCode: 27 },
	ArrowUp: { code: "ArrowUp", keyCode: 38 },
	ArrowDown: { code: "ArrowDown", keyCode: 40 },
	ArrowLeft: { code: "ArrowLeft", keyCode: 37 },
	ArrowRight: { code: "ArrowRight", keyCode: 39 },
	Home: { code: "Home", keyCode: 36 },
	End: { code: "End", keyCode: 35 },
	PageUp: { code: "PageUp", keyCode: 33 },
	PageDown: { code: "PageDown", keyCode: 34 },
	Backspace: { code: "Backspace", keyCode: 8 },
	Delete: { code: "Delete", keyCode: 46 },
	Space: { code: "Space", keyCode: 32, char: " ", key: " " },
};

/** keydown, keypress for character keys, the browser's default action, keyup. */
async function press(ref, key) {
	const spec = KEYS[key];
	if (!spec) return { ok: false, reason: "unsupported_key" };
	const prepared = inspectReferencedElement(ref, "press");
	if (!prepared.ok) return prepared;
	const { element } = reference(ref);
	const doc = element.ownerDocument;
	const view = doc.defaultView;
	const target = deepActiveElement(doc) ?? element;
	const init = { key: spec.key ?? key, code: spec.code, keyCode: spec.keyCode, which: spec.keyCode, bubbles: true, cancelable: true, composed: true, view };
	let proceed = target.dispatchEvent(new view.KeyboardEvent("keydown", init));
	if (proceed && spec.char) proceed = target.dispatchEvent(new view.KeyboardEvent("keypress", { ...init, charCode: spec.char.charCodeAt(0) }));
	const effect = proceed ? await defaultKeyAction(target, key, view) : "prevented_by_page";
	target.dispatchEvent(new view.KeyboardEvent("keyup", init));
	return { pressed: true, ref, key, effect, trusted: false };
}

const TEXT_INPUT_TYPES = new Set(["", "text", "search", "email", "url", "tel", "password", "number", "date", "datetime-local", "month", "time", "week"]);

function isTextField(element) {
	if (element.isContentEditable || element.tagName === "TEXTAREA") return true;
	return element.tagName === "INPUT" && TEXT_INPUT_TYPES.has((element.getAttribute("type") || "").toLowerCase());
}

/** What the browser would do after an uncancelled real keystroke. Returns a short label. */
async function defaultKeyAction(target, key, view) {
	const doc = target.ownerDocument;
	const tag = target.tagName;
	const type = (target.getAttribute?.("type") || "").toLowerCase();
	const activate = () => {
		target.dispatchEvent(new view.MouseEvent("click", { bubbles: true, cancelable: true, composed: true, view, detail: 0 }));
	};
	switch (key) {
		case "Enter":
			if (tag === "TEXTAREA" || target.isContentEditable) return doc.execCommand("insertLineBreak") ? "inserted_line_break" : "none";
			if (tag === "INPUT" && target.form && isTextField(target)) {
				// Implicit submission: the form's default button, else the form itself when it allows it.
				const form = target.form;
				const submitter = [...form.elements].find((el) => el.matches('button:not([type]),button[type="submit"],input[type="submit"],input[type="image"]'));
				if (submitter) {
					if (submitter.matches(":disabled")) return "none";
					submitter.dispatchEvent(new view.MouseEvent("click", { bubbles: true, cancelable: true, composed: true, view, detail: 0 }));
					return "submitted_form";
				}
				const blocking = [...form.elements].filter((el) => el.tagName === "INPUT" && isTextField(el));
				if (blocking.length <= 1) {
					form.requestSubmit();
					return "submitted_form";
				}
				return "none";
			}
			if (tag === "A" && target.hasAttribute("href")) return activate(), "followed_link";
			if (tag === "BUTTON" || (tag === "INPUT" && ["button", "submit", "reset", "image"].includes(type)) || target.getAttribute("role") === "button" || tag === "SUMMARY") return activate(), "activated";
			return "none";
		case "Space":
			if (isTextField(target)) return doc.execCommand("insertText", false, " ") ? "inserted_space" : "none";
			if (tag === "BUTTON" || tag === "SUMMARY" || (tag === "INPUT" && ["button", "submit", "reset", "checkbox", "radio", "image"].includes(type)) || ["button", "checkbox", "switch", "radio", "menuitem", "tab", "option"].includes(target.getAttribute("role")))
				return activate(), "activated";
			return scrollViewport(view, 0, view.innerHeight * 0.875), "scrolled";
		case "Tab":
			return moveFocus(doc, target) ? "moved_focus" : "none";
		case "Backspace":
		case "Delete":
			if (isTextField(target)) return doc.execCommand(key === "Backspace" ? "delete" : "forwardDelete") ? "deleted" : "none";
			return "none";
		case "Escape":
			return "none";
		default:
			return navigationKey(target, key, view);
	}
}

function navigationKey(target, key, view) {
	if (target.tagName === "SELECT" && !target.multiple && ["ArrowUp", "ArrowDown", "Home", "End"].includes(key)) {
		const options = [...target.options].filter((option) => !option.disabled);
		const current = options.indexOf(target.selectedOptions[0]);
		const next = { ArrowUp: Math.max(0, current - 1), ArrowDown: Math.min(options.length - 1, current + 1), Home: 0, End: options.length - 1 }[key];
		if (next === current || !options[next]) return "none";
		target.value = options[next].value;
		target.dispatchEvent(new view.Event("input", { bubbles: true, composed: true }));
		target.dispatchEvent(new view.Event("change", { bubbles: true }));
		return "changed_selection";
	}
	if (isTextField(target) && typeof target.setSelectionRange === "function") {
		try {
			const length = String(target.value ?? "").length;
			const at = target.selectionStart ?? 0;
			const position = { ArrowLeft: Math.max(0, at - 1), ArrowRight: Math.min(length, at + 1), Home: 0, End: length, ArrowUp: 0, ArrowDown: length, PageUp: 0, PageDown: length }[key];
			target.setSelectionRange(position, position);
			return "moved_caret";
		} catch {
			return "none";
		}
	}
	const line = 40;
	const page = view.innerHeight * 0.875;
	const [dx, dy] = {
		ArrowUp: [0, -line],
		ArrowDown: [0, line],
		ArrowLeft: [-line, 0],
		ArrowRight: [line, 0],
		PageUp: [0, -page],
		PageDown: [0, page],
		Home: [0, -Infinity],
		End: [0, Infinity],
	}[key] ?? [0, 0];
	return scrollViewport(view, dx, dy), "scrolled";
}

function scrollViewport(view, dx, dy) {
	const scroller = view.document.scrollingElement ?? view.document.documentElement;
	const top = dy === Infinity ? scroller.scrollHeight : dy === -Infinity ? 0 : scroller.scrollTop + dy;
	scroller.scrollTo({ left: scroller.scrollLeft + dx, top, behavior: "instant" });
}

/** Focus to the next element in tab order (document order of tabbable elements; positive tabindex first). */
function moveFocus(doc, from) {
	const candidates = [...doc.querySelectorAll(FOCUSABLE)].filter((el) => {
		if (el.matches(":disabled") || el.tabIndex < 0 || el.closest("[inert]")) return false;
		const style = doc.defaultView.getComputedStyle(el);
		return style.visibility !== "hidden" && style.display !== "none" && el.getClientRects().length > 0;
	});
	const ordered = [...candidates.filter((el) => el.tabIndex > 0).sort((a, b) => a.tabIndex - b.tabIndex), ...candidates.filter((el) => el.tabIndex === 0)];
	const next = ordered[ordered.indexOf(from) + 1];
	if (!next) return false;
	from.blur?.();
	next.focus();
	return true;
}

// MARK: - scroll

/** Scrolls the referenced viewport or container by `pages` of its size (programmatically: scroll events fire, wheel events don't). */
async function scroll(ref, direction, pages = 1) {
	const inspected = inspectScrollReference(ref, direction, false);
	if (!inspected.ok) return inspected;
	const { element } = reference(ref);
	const view = element.ownerDocument.defaultView;
	const before = readScrollState(element);
	const horizontal = direction === "left" || direction === "right";
	if (!before[horizontal ? "horizontal" : "vertical"]) return { ref, direction, moved: false, outcome: "boundary", before, after: before, trusted: false };
	const sign = direction === "down" || direction === "right" ? 1 : -1;
	const distance = sign * Math.max(1, Math.round((horizontal ? before.width : before.height) * Math.min(3, Math.max(0.1, pages))));
	element.scrollBy({ left: horizontal ? distance : 0, top: horizontal ? 0 : distance, behavior: "instant" });
	// Let scroll handlers (lazy loading, sticky headers) run, then read where it ended.
	await nextFrame(view);
	await sleep(50);
	const after = readScrollState(element);
	const moved = after.x !== before.x || after.y !== before.y;
	const atEdge = horizontal ? (sign > 0 ? after.x >= after.maxX - 1 : after.x <= after.minX + 1) : sign > 0 ? after.y >= after.maxY - 1 : after.y <= 1;
	return {
		ref,
		direction,
		moved,
		outcome: moved ? "moved" : atEdge ? "boundary" : "no_movement",
		before,
		after,
		deltaX: after.x - before.x,
		deltaY: after.y - before.y,
		trusted: false,
	};
}

// MARK: - dispatch

const methods = {
	snapshot: ({ options }) => snapshot(options),
	describe: ({ ref, action, key }) => {
		ensureDigest(reference(ref)?.frameWindow ?? window);
		return describeReferencedElement(ref, action, key ?? "");
	},
	click: ({ ref }) => click(ref),
	type: ({ ref, text, replace }) => type(ref, text, replace !== false),
	select: ({ ref, value }) => {
		const result = selectOptionByValue(ref, value);
		return result.ok ? { selected: true, ref, ...(Array.isArray(value) ? { values: value } : { value }), trusted: false } : result;
	},
	press: ({ ref, key }) => press(ref, key),
	scroll: ({ ref, direction, pages }) => scroll(ref, direction, pages ?? 1),
	matches: ({ ref, state }) => referencedElementMatchesState(ref, state),
	containsText: ({ text }) => ({ ok: true, matched: pageContainsText(text) }),
};

globalThis.__freedomAgentPage = {
	version: VERSION,
	documentId,
	async call(method, args = {}) {
		const fn = methods[method];
		if (!fn) return { ok: false, reason: "unknown_method" };
		// As a JSON string: WebKit refuses to hand some values back to the app ("unsupported type"),
		// such as text cut in the middle of an emoji (a lone surrogate), which toWellFormed repairs.
		const result = await fn(args);
		return JSON.stringify(result ?? null, (_, value) => (typeof value === "string" ? value.toWellFormed() : value));
	},
};
