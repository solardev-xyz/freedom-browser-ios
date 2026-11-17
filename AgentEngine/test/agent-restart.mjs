// Kill-and-reopen check of src/agent.js under Node, on Node's SQLite and a
// fake page, with the offline scripted model: run it after every Pi upgrade
// (`npm run check`), since pi-durable's API changes between releases.
//
// 1. A run is killed (SIGKILL) while the answer streams; reopening continues
//    it, and asking again with the same request ID doesn't ask twice.
// 2. A click waits for approval ("every_interaction") and the process is
//    killed; reopening asks again, and once approved it clicks exactly once.
// 3. A declined click doesn't run; the model is told.
// 4. "allow_website_interactions" clicks without asking.
// 5. A page that changed while the approval was pending blocks the click.
// 6. An element that can't be inspected asks instead of running unasked.

import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { openAgent, SCRIPTED_MODEL } from "../src/agent.js";

const QUESTION = "What is the page I have open about?";
const CLICK = "Please click the button";

if (process.argv[2] === "child") await child(process.argv[3], process.argv[4]);
else await main();

async function main() {
	const dir = await mkdtemp(join(tmpdir(), "freedom-agent-"));
	let failed = false;
	const check = (ok, what) => {
		console.log(`${ok ? "PASS" : "FAIL"}  ${what}`);
		failed ||= !ok;
	};
	try {
		const answerDb = join(dir, "answer.sqlite");
		check((await runChild("kill-mid-answer", answerDb)).signal === "SIGKILL", "killed while the answer streamed");
		const resumed = JSON.parse((await runChild("resume", answerDb)).stdout);
		check(resumed.firstLive?.busy === true, "reopening finds the run in progress");
		check(resumed.items.filter((i) => i.role === "user").length === 1, "asking again with the same request ID adds no second question");
		check(resumed.items.some((i) => i.role === "assistant" && i.interrupted), "the cut-off answer is kept, marked interrupted");
		check(/That is the end of the answer\.$/.test(resumed.answer), "the run finishes with the whole answer");

		const clickDb = join(dir, "click.sqlite");
		check((await runChild("kill-at-approval", clickDb)).signal === "SIGKILL", "killed while an approval waited");
		const approved = JSON.parse((await runChild("approve", clickDb)).stdout);
		check(approved.approvalsAsked === 1, "reopening asks for the approval again");
		check(approved.clicks === 1, "the approved click runs once");
		check(approved.approval?.label === "Buy now" && approved.approval?.tool === "browser_click", "the approval names the tool and the element");

		const declined = JSON.parse((await runChild("decline", join(dir, "decline.sqlite"))).stdout);
		check(declined.clicks === 0 && /didn't click/.test(declined.answer), "a declined click doesn't run and the model is told");

		const allowed = JSON.parse((await runChild("allow", join(dir, "allow.sqlite"))).stdout);
		check(allowed.approvalsAsked === 0 && allowed.clicks === 1, "allow_website_interactions clicks without asking");

		const changed = JSON.parse((await runChild("changed", join(dir, "changed.sqlite"))).stdout);
		check(changed.clicks === 0 && /page changed/i.test(changed.answer), "a page that changed during the approval blocks the click");

		const uninspectable = JSON.parse((await runChild("uninspectable", join(dir, "uninspectable.sqlite"))).stdout);
		check(uninspectable.approvalsAsked === 1 && /couldn't inspect/.test(uninspectable.approval?.summary ?? ""), "an element that can't be inspected asks first");
	} finally {
		await rm(dir, { recursive: true, force: true });
	}
	process.exit(failed ? 1 : 0);
}

function runChild(mode, db) {
	return new Promise((resolve, reject) => {
		const proc = spawn(process.execPath, [fileURLToPath(import.meta.url), "child", mode, db], { stdio: ["ignore", "pipe", "inherit"] });
		let stdout = "";
		proc.stdout.on("data", (chunk) => (stdout += chunk));
		proc.on("error", reject);
		proc.on("exit", (code, signal) => resolve({ code, signal, stdout }));
	});
}

/** A page with one button; `describe` changes its label once `relabel` is set. */
function fakePage({ describeThrows = false } = {}) {
	const state = { clicks: 0, relabel: false };
	const page = async (method) => {
		switch (method) {
			case "tab":
				return { url: "https://shop.example/", title: "Example Shop", loading: false, navigationId: 1 };
			case "snapshot":
				return { url: "https://shop.example/", title: "Example Shop", text: "A shop.", frames: [], elements: [{ ref: "ref_a_0", role: "button", name: "Buy now", tag: "button" }], documentId: "document_1" };
			case "describe":
				if (describeThrows) throw new Error("crypto.subtle is unavailable");
				return { ok: true, label: state.relabel ? "Delete account" : "Buy now" };
			case "click":
				state.clicks += 1;
				return { clicked: true, ref: "ref_a_0", trusted: false, navigated: false };
			default:
				return { ok: false, reason: "unknown_method" };
		}
	};
	return { page, state };
}

async function child(mode, file) {
	const database = await openNodeSqliteDatabase(file);
	const { page, state } = fakePage({ describeThrows: mode === "uninspectable" });
	const ended = Promise.withResolvers();
	let approvalsAsked = 0;
	let approval;
	let firstLive;
	let answer = "";
	let items = [];
	let agent;
	const emit = (event) => {
		if (event.type === "chat_live") {
			firstLive ??= event;
			// Past Pi's one-second window for storing a streaming answer, so some of it is saved.
			if (mode === "kill-mid-answer" && event.partial.length >= 120) process.kill(process.pid, "SIGKILL");
			if (wasBusy && !event.busy) ended.resolve();
			wasBusy = event.busy;
		}
		if (event.type === "chat_items") {
			items = event.items;
			answer = items.findLast((i) => i.role === "assistant" && !i.interrupted && i.text)?.text ?? answer;
		}
		if (event.type === "approval") {
			approvalsAsked += 1;
			approval = event;
			if (mode === "kill-at-approval") process.kill(process.pid, "SIGKILL");
			if (mode === "changed") state.relabel = true;
			if (["approve", "changed", "uninspectable"].includes(mode)) agent.approve(event.taskId, true);
			if (mode === "decline") agent.approve(event.taskId, false);
		}
	};
	let wasBusy = false;
	const approvalMode = mode === "allow" ? "allow_website_interactions" : mode === "uninspectable" ? "sensitive_actions" : "every_interaction";
	agent = await openAgent({ database, page, emit, approvalMode, scriptedPace: mode === "kill-mid-answer" ? 25 : 2000 });
	// One chat per database: the first run creates it and the restart finds it under the same ID.
	const chatId = await findOrCreateChat(agent, file);
	await agent.view(chatId);
	const question = ["kill-mid-answer", "resume"].includes(mode) ? QUESTION : CLICK;
	if (mode !== "approve") await agent.submit({ chatId, prompt: question, requestId: `${question}-1`, model: SCRIPTED_MODEL });
	const timeout = setTimeout(() => ended.reject(new Error(`${mode}: the run didn't end within 30 s`)), 30_000);
	await ended.promise;
	clearTimeout(timeout);
	await new Promise((resolve) => setTimeout(resolve, 50)); // the last chat_items
	process.stdout.write(JSON.stringify({ firstLive, items, answer, approvalsAsked, approval, clicks: state.clicks }));
	await agent.close();
	await database.close();
}

// The chat ID lives next to the database, as the app keeps it in its chat list.
async function findOrCreateChat(agent, file) {
	try {
		return Number((await readFile(`${file}.chat`, "utf8")).trim());
	} catch {
		const chatId = await agent.createChat({ model: SCRIPTED_MODEL });
		await writeFile(`${file}.chat`, String(chatId));
		return chatId;
	}
}
