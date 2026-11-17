// Scripted checks of the browser tools on real sites, without a model: how
// well script-dispatched input (the only kind a WKWebView allows) operates
// pages. Each case drives the same `page` service the agent's tools use.
// DEBUG builds run it with FREEDOM_DEBUG_AGENT_PAGECHECK=all|<case,…>.

import { waitFor } from "./tools/page.js";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Finder: `{ role, name, tag }`, each a RegExp or string (exact); the first element matching all wins. */
function matches(element, finder) {
	const test = (pattern, value) => (pattern === undefined ? true : pattern instanceof RegExp ? pattern.test(value ?? "") : pattern === value);
	return test(finder.role, element.role) && test(finder.name, element.name) && test(finder.tag, element.tag);
}

export const CASES = [
	{
		name: "wikipedia-search-form",
		what: "type into a plain search form, Enter submits it",
		url: "https://en.wikipedia.org/wiki/Special:Search",
		steps: [
			{ type: { role: /searchbox|textbox|combobox/, name: /search/i }, text: "Swarm intelligence" },
			{ press: { role: /searchbox|textbox|combobox/, name: /search/i }, key: "Enter" },
			{ expect: { url: /Swarm_intelligence|search=Swarm/ } },
		],
	},
	{
		// DuckDuckGo would be the obvious case, but Freedom's ad-block scriptlets crash its page
		// process on the simulator (with or without the agent), so a comparable site instead.
		name: "ecosia-search",
		what: "type into a script-driven search box, click the search button",
		url: "https://www.ecosia.org/",
		steps: [
			{ type: { role: /searchbox|textbox|combobox/ }, text: "freedom browser swarm" },
			{ click: { role: "button", name: /search|such/i } },
			{ expect: { url: /[?&]q=freedom/ } },
		],
	},
	{
		name: "todomvc-react",
		what: "React controlled input + Enter handler",
		url: "https://todomvc.com/examples/react/dist/",
		// Not the item's checkbox: TodoMVC hides it (opacity 0) behind a styled image, and
		// desktop's snapshot leaves invisible controls out; desktop reaches those through
		// screenshots, which the phone doesn't have yet.
		steps: [
			{ type: { role: "textbox", name: /what needs to be done|new todo/i }, text: "Buy oat milk" },
			{ press: { role: "textbox", name: /what needs to be done|new todo/i }, key: "Enter" },
			{ expect: { text: "1 item left" } },
		],
	},
	{
		name: "todomvc-vue",
		what: "Vue v-model input + Enter handler",
		url: "https://todomvc.com/examples/vue/dist/",
		steps: [
			{ type: { role: "textbox", name: /what needs to be done/i }, text: "Water the plants" },
			{ press: { role: "textbox", name: /what needs to be done/i }, key: "Enter" },
			{ expect: { text: "1 item left" } },
		],
	},
	{
		name: "httpbin-order-form",
		what: "text, radio, checkbox, textarea, then the submit button",
		url: "https://httpbin.org/forms/post",
		steps: [
			{ type: { role: "textbox", name: /customer name/i }, text: "Freedom Agent" },
			{ click: { role: "radio", name: /medium/i } },
			{ click: { role: "checkbox", name: /bacon/i } },
			{ type: { role: "textbox", name: /delivery instructions/i }, text: "Ring twice" },
			{ click: { role: "button", name: /submit order/i } },
			{ expect: { text: '"custname": "Freedom Agent"' } },
			{ expect: { text: '"size": "medium"' } },
			{ expect: { text: '"topping": "bacon"' } },
		],
	},
	{
		name: "native-select",
		what: "a native <select> through browser_select",
		url: "https://the-internet.herokuapp.com/dropdown",
		steps: [
			{ select: { role: /combobox|listbox/ }, value: "2" },
			{ expect: { selected: { role: /combobox|listbox/ }, value: "2" } },
		],
	},
	{
		name: "key-events",
		what: "key events reach the page's own key handlers",
		url: "https://the-internet.herokuapp.com/key_presses",
		steps: [
			{ press: { role: "textbox" }, key: "Escape" },
			{ expect: { text: "You entered: ESCAPE" } },
			{ press: { role: "textbox" }, key: "ArrowDown" },
			{ expect: { text: "You entered: DOWN" } },
		],
	},
	{
		name: "hacker-news-link",
		what: "a plain link click navigates",
		url: "https://news.ycombinator.com/",
		steps: [{ click: { role: "link", name: /^new$/i } }, { expect: { url: /\/newest/ } }],
	},
	{
		name: "react-dev-spa-link",
		what: "a client-side router link (Next.js) navigates without a page load",
		url: "https://react.dev/",
		steps: [{ click: { role: "link", name: /^learn( react)?$/i } }, { expect: { url: /react\.dev\/learn/ } }],
	},
	{
		name: "wikipedia-scroll",
		what: "scroll the page by viewport pages",
		url: "https://en.wikipedia.org/wiki/Ethereum",
		steps: [{ scroll: "viewport", direction: "down", pages: 2 }, { scroll: "viewport", direction: "up", pages: 1 }],
	},
	{
		name: "github-search-dialog",
		what: "open a script-built search dialog and type into it",
		url: "https://github.com/solardev-xyz",
		steps: [
			{ click: { role: "button", name: /search|type \/ to search/i } },
			{ type: { role: /combobox|searchbox|textbox/, name: /search/i }, text: "freedom-browser" },
			{ press: { role: /combobox|searchbox|textbox/, name: /search/i }, key: "Enter" },
			{ expect: { url: /search\?q=freedom-browser|q=freedom-browser/ } },
		],
	},
	{
		name: "ens-swarm-site",
		what: "a dweb site through ENS, then a link on it",
		url: "ens://swarm.eth",
		timeoutMs: 60_000,
		steps: [{ expect: { loaded: true } }, { click: { role: "link" } }, { expect: { navigated: true } }],
	},
];

/**
 * Runs `names` (or all cases) and returns one result per case:
 * `{ name, ok, steps: [{ step, ok, detail, ms }], ms }`.
 */
export async function runPageChecks(call, names, log = console.log, { loadOnly = false } = {}) {
	const selected = !names || names === "all" ? CASES : CASES.filter((c) => names.split(",").includes(c.name));
	const results = [];
	for (const testCase of selected) {
		log(`[pagecheck] ${testCase.name} …`);
		const started = Date.now();
		const steps = [];
		const context = {};
		let ok = true;
		try {
			await call("navigate", { url: testCase.url });
			const loaded = await waitFor(call, { condition: "load", timeoutMs: testCase.timeoutMs ?? 30_000 });
			if (!loaded.ok) throw new Error(`page didn't load: ${JSON.stringify(loaded.tab)}`);
			await sleep(800); // scripts that build the page after load
			// Load-only: the same pages without any agent action, a baseline for page crashes.
			for (const step of loadOnly ? [] : testCase.steps) {
				const t0 = Date.now();
				let detail;
				try {
					detail = await runStep(call, step, testCase, context);
					steps.push({ step: label(step), ok: true, detail, ms: Date.now() - t0 });
				} catch (error) {
					ok = false;
					steps.push({ step: label(step), ok: false, detail: error.message, ms: Date.now() - t0 });
					break;
				}
			}
		} catch (error) {
			ok = false;
			steps.push({ step: "open", ok: false, detail: error.message });
		}
		const result = { name: testCase.name, what: testCase.what, ok, steps, ms: Date.now() - started };
		results.push(result);
		log(`[pagecheck] ${ok ? "PASS" : "FAIL"} ${testCase.name} (${result.ms} ms): ${testCase.what}`);
		for (const s of steps) log(`[pagecheck]   ${s.ok ? "ok  " : "FAIL"} ${s.step} ${s.ms ?? ""}ms ${typeof s.detail === "string" ? s.detail : JSON.stringify(s.detail ?? "")}`.slice(0, 900));
	}
	const passed = results.filter((r) => r.ok).length;
	log(`[pagecheck] ${passed}/${results.length} cases passed`);
	return results;
}

function label(step) {
	const [kind] = Object.keys(step).filter((k) => ["type", "press", "click", "select", "scroll", "expect"].includes(k));
	return `${kind} ${JSON.stringify(step[kind], (_, v) => (v instanceof RegExp ? String(v) : v))}${step.key ? ` ${step.key}` : ""}${step.text ? ` "${step.text}"` : ""}`;
}

async function find(call, finder) {
	// Without a query, page through the whole snapshot.
	const seen = [];
	for (let offset = 0; offset < 2000; ) {
		const snap = await call("snapshot", { options: { elementOffset: offset } });
		const element = snap.elements.find((e) => matches(e, finder));
		if (element) return { element, snap };
		seen.push(...snap.elements.map((e) => `${e.role}:${e.name}`));
		if (!snap.elementsTruncated || !snap.nextElementOffset) break;
		offset = snap.nextElementOffset;
	}
	const finderText = JSON.stringify(finder, (_, v) => (v instanceof RegExp ? String(v) : v));
	throw new Error(`no element matches ${finderText}; ${seen.length} seen: ${seen.slice(0, 25).join(" | ")}`);
}

async function runStep(call, step, testCase, context) {
	if (step.type) {
		const { element } = await find(call, step.type);
		const r = await call("type", { ref: element.ref, text: step.text, replace: true });
		return { name: element.name, method: r.method };
	}
	if (step.press) {
		const { element } = await find(call, step.press);
		const r = await call("press", { ref: element.ref, key: step.key });
		return { name: element.name, effect: r.effect, navigated: r.navigated };
	}
	if (step.click) {
		const { element } = await find(call, step.click);
		context.urlBefore = (await call("tab")).url;
		const r = await call("click", { ref: element.ref });
		return { name: element.name, navigated: r.navigated, handledByTouch: r.handledByTouch };
	}
	if (step.select) {
		const { element } = await find(call, step.select);
		await call("select", { ref: element.ref, value: step.value });
		return { name: element.name };
	}
	if (step.scroll) {
		const snap = await call("snapshot", { options: {} });
		const viewport = snap.frames?.[0]?.viewport?.ref;
		if (!viewport) throw new Error("no viewport reference in the snapshot");
		const r = await call("scroll", { ref: viewport, direction: step.direction, pages: step.pages });
		if (!r.moved) throw new Error(`didn't scroll: ${r.outcome}`);
		return { outcome: r.outcome, deltaY: r.deltaY };
	}
	if (step.expect) return expectation(call, step.expect, testCase.timeoutMs ?? 10_000, context);
	throw new Error("unknown step");
}

async function expectation(call, expect, timeoutMs, context) {
	const started = Date.now();
	let last;
	while (Date.now() - started < timeoutMs) {
		const tab = await call("tab");
		last = tab;
		if (expect.url && expect.url.test(tab.url)) return { url: tab.url };
		if (expect.loaded && !tab.loading && tab.url) return { url: tab.url, title: tab.title };
		if (expect.navigated && tab.url && tab.url !== context.urlBefore) return { url: tab.url };
		if (expect.text && !tab.loading) {
			const r = await call("containsText", { text: expect.text });
			if (r.matched) return { text: expect.text };
		}
		if (expect.selected) {
			const { element } = await find(call, expect.selected);
			const chosen = element.options?.find((o) => o.selected);
			if (chosen?.value === expect.value) return { value: chosen.value };
			last = { element };
		}
		await sleep(200);
	}
	throw new Error(`not met within ${timeoutMs} ms; last: ${JSON.stringify(last).slice(0, 300)}`);
}
