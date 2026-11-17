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
// 7. With no page open, an interaction is blocked without asking.
// 8. Every page call carries the chat's ID (each chat has its own tabs).
// 9. "sensitive_actions": a click the classifier can't judge runs (here at a
//    screenshot point); a form it can't judge asks; typing, links and keys
//    that don't submit never reach the classifier.
// 10. browser_stop_loading ends a running browser_wait.
// 11. Answering a page dialog asks even in "allow_website_interactions".
// 12. wallet_transfer reaches the app's wallet service with the chat's ID.
// 13. Killed while the wallet waited for the user: reopening never sends again.
// 14. A download asks even in "allow_website_interactions".
// 15. Attached files: the message names them; images go along only for models that accept them.
// 16. A node request that changes state asks even in "allow_website_interactions"; reads don't.

import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { openAgent, SCRIPTED_MODEL } from "../src/agent.js";
import { createPageTools } from "../src/tools/page.js";
import { messageWithAttachments } from "../src/tools/attachments.js";
import { nodeCallAsks } from "../src/tools/node.js";
import { sensitiveAsks, sensitivePrecheck } from "../src/classifier.js";

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

		const noTab = JSON.parse((await runChild("no-tab", join(dir, "no-tab.sqlite"))).stdout);
		check(noTab.approvalsAsked === 0 && noTab.clicks === 0 && /didn't click/.test(noTab.answer), "with no page open, an interaction is blocked without asking");
		check(approved.chatIds.length === 1 && approved.chatIds[0] === approved.chatId && approved.unboundCalls === 0, "every page call carries the chat's ID");

		const visual = JSON.parse((await runChild("visual", join(dir, "visual.sqlite"))).stdout);
		check(visual.approvalsAsked === 0 && visual.clicks === 1, "sensitive_actions: a click the classifier can't judge runs");
		const submit = JSON.parse((await runChild("sensitive-submit", join(dir, "submit.sqlite"))).stdout);
		check(submit.approvalsAsked === 1 && submit.approval?.label === "Send" && submit.clicks === 1, "sensitive_actions: a form the classifier can't judge asks first");
		const page = "https://mail.example/inbox";
		check(
			sensitivePrecheck("type", {}, page) === "proceed" && sensitivePrecheck("press", {}, page) === "proceed" &&
				sensitivePrecheck("press", { effect: "form_submission" }, page) === "classify" &&
				sensitivePrecheck("click", { navigationTarget: "https://mail.example/sent" }, page) === "proceed" &&
				sensitivePrecheck("click", { navigationTarget: "https://mail.example/inbox#" }, page) === "classify" &&
				sensitivePrecheck("click", { navigationTarget: "javascript:send()" }, page) === "classify" &&
				sensitivePrecheck("click", { formControl: "checkbox", inForm: true }, page) === "proceed" &&
				sensitivePrecheck("click", { formControl: "checkbox", inForm: false }, page) === "classify" &&
				sensitiveAsks({ kind: "consequential" }, false) && !sensitiveAsks({ kind: "ordinary" }, true),
			"sensitive_actions: typing, links and keys run unasked; consequential actions ask",
		);

		check(await stopEndsWait(), "browser_stop_loading ends a running browser_wait");

		const dialog = JSON.parse((await runChild("dialog", join(dir, "dialog.sqlite"))).stdout);
		check(dialog.approvalsAsked === 1 && dialog.approval?.effect === "dialog_accept" && dialog.dialogAnswers === 1, "answering a page dialog asks even in allow_website_interactions");

		const transfer = JSON.parse((await runChild("transfer", join(dir, "transfer.sqlite"))).stdout);
		check(transfer.transfers === 1 && transfer.transferChat === transfer.chatId && /0xfeed/.test(transfer.answer), "wallet_transfer reaches the wallet service with the chat's ID");

		const transferDb = join(dir, "transfer-kill.sqlite");
		check((await runChild("kill-at-transfer", transferDb)).signal === "SIGKILL", "killed while the wallet waited for the user");
		const resumedTransfer = JSON.parse((await runChild("transfer-resume", transferDb)).stdout);
		check(resumedTransfer.transfers === 0 && /^Not sent/.test(resumedTransfer.answer), "reopening doesn't send the interrupted transfer again; the model is told");

		const download = JSON.parse((await runChild("download", join(dir, "download.sqlite"))).stdout);
		check(download.approvalsAsked === 1 && download.approval?.tool === "browser_download" && download.downloads === 1, "a download asks even in allow_website_interactions");

		const files = [{ resourceId: "attachment_0123456789abcdef0123", name: "cv.pdf", mimeType: "application/pdf", bytes: 120_000 }];
		const images = [{ base64: "AAAA", mimeType: "image/jpeg" }];
		const withVision = messageWithAttachments("Check my CV", files, images, true);
		const withoutVision = messageWithAttachments("Check my CV", files, images, false);
		check(
			Array.isArray(withVision) && withVision[1]?.type === "image" && /cv\.pdf \(attachment_0123456789abcdef0123, application\/pdf, 117 KB\)/.test(withVision[0].text) &&
				typeof withoutVision === "string" && messageWithAttachments("Hi") === "Hi",
			"attached files are named in the message; images only for models that accept them",
		);

		const stamps = JSON.parse((await runChild("stamps", join(dir, "stamps.sqlite"))).stdout);
		check(
			stamps.approvalsAsked === 1 && stamps.approval?.tool === "node_request" && stamps.nodeRequests === 1 &&
				!nodeCallAsks("node_request", { request: { method: "GET", path: "/stamps" } }) && nodeCallAsks("swarm_publish", {}),
			"a state-changing node request asks even in allow mode; reads don't",
		);
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

/** The tools alone: a wait on a page that never finishes loading, stopped after 200 ms. */
async function stopEndsWait() {
	const { tools } = createPageTools(async (method) => (method === "tab" ? { url: "https://slow.example/", loading: true, navigationId: 1 } : { stopped: true }));
	const tool = (name) => tools.find((t) => t.name === name);
	const api = { conversationId: 7 };
	const started = Date.now();
	const wait = tool("browser_wait").execute({ condition: "load", timeoutMs: 10_000 }, api, {});
	setTimeout(() => tool("browser_stop_loading").execute({}, api, {}), 200);
	const result = JSON.parse((await wait).output[0].text);
	return result.stopped === true && Date.now() - started < 2_000;
}

/** A page with one button; `describe` changes its label once `relabel` is set. */
function fakePage({ describeThrows = false, noTab = false, visual = false, submit = false } = {}) {
	const state = { clicks: 0, relabel: false, chatIds: new Set(), unboundCalls: 0, dialogAnswers: 0, dialogOpen: true, downloads: 0 };
	const page = async (method, params = {}) => {
		if (params.chatId === undefined) state.unboundCalls += 1;
		else state.chatIds.add(params.chatId);
		switch (method) {
			case "tab":
				if (noTab && state.snapshotted) throw new Error("No tab is open.");
				return { url: "https://shop.example/", title: "Example Shop", loading: false, navigationId: 1 };
			case "snapshot":
				state.snapshotted = true;
				return { url: "https://shop.example/", title: "Example Shop", text: "A shop.", frames: [], elements: [{ ref: visual ? "visual_1" : "ref_a_0", role: "button", name: "Buy now", tag: "button" }], documentId: "document_1" };
			case "describe":
				if (describeThrows) throw new Error("crypto.subtle is unavailable");
				if (noTab) throw new Error("No tab is open.");
				if (visual) return { ok: true, label: "Visual point (40%, 60%); effect unknown", effect: "", visual: true };
				if (submit) return { ok: true, label: "Send", effect: "form_submission", formMethod: "get", navigationTarget: "https://shop.example/" };
				return { ok: true, label: state.relabel ? "Delete account" : "Buy now" };
			case "download":
				state.downloads += 1;
				return { downloadId: "d1", filename: "report.pdf", state: "completed", available: true };
			case "getDialog":
				return { dialog: state.dialogOpen ? { dialogRef: "dialog_1", type: "confirm", message: "Delete this item?", origin: "shop.example" } : null };
			case "handleDialog":
				state.dialogAnswers += 1;
				state.dialogOpen = false;
				return { handled: true, accepted: params.accept };
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
	const walletState = { transfers: 0, nodeRequests: 0 };
	const nodes = async (method) => {
		if (method === "request") walletState.nodeRequests += 1;
		return { status: 201, body: "{\"batchID\":\"abc\"}" };
	};
	const wallet = async (method, params) => {
		if (mode === "kill-at-transfer") process.kill(process.pid, "SIGKILL");
		walletState.transfers += 1;
		walletState.chatId = params.chatId;
		return { status: "submitted", txHash: "0xfeed", chainId: params.chainId };
	};
	const { page, state } = fakePage({ describeThrows: mode === "uninspectable", noTab: mode === "no-tab", visual: mode === "visual", submit: mode === "sensitive-submit" });
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
			// A resumed run can finish before the chat is watched: idle with a finished answer ends it too.
			const last = items.at(-1);
			const finished = last?.role === "assistant" && !last.interrupted && !last.tools?.length;
			if (!event.busy && (wasBusy || finished)) ended.resolve();
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
			if (["approve", "changed", "uninspectable", "visual", "sensitive-submit", "dialog", "download", "stamps"].includes(mode)) agent.approve(event.taskId, true);
			if (mode === "decline") agent.approve(event.taskId, false);
		}
	};
	let wasBusy = false;
	const approvalMode = ["allow", "dialog", "download", "stamps"].includes(mode) ? "allow_website_interactions" : ["uninspectable", "visual", "sensitive-submit"].includes(mode) ? "sensitive_actions" : "every_interaction";
	agent = await openAgent({ database, page, wallet, nodes, emit, approvalMode, scriptedPace: mode === "kill-mid-answer" ? 25 : 2000 });
	// One chat per database: the first run creates it and the restart finds it under the same ID.
	const chatId = await findOrCreateChat(agent, file);
	await agent.view(chatId);
	const question = ["kill-mid-answer", "resume"].includes(mode) ? QUESTION : mode === "dialog" ? "Answer the dialog" : /transfer/.test(mode) ? "Send 0.01 ETH to vitalik.eth" : mode === "download" ? "Download the file" : mode === "stamps" ? "Buy stamps" : CLICK;
	if (!["approve", "transfer-resume"].includes(mode)) await agent.submit({ chatId, prompt: question, requestId: `${question}-1`, model: SCRIPTED_MODEL });
	const timeout = setTimeout(() => ended.reject(new Error(`${mode}: the run didn't end within 30 s`)), 30_000);
	await ended.promise;
	clearTimeout(timeout);
	await new Promise((resolve) => setTimeout(resolve, 50)); // the last chat_items
	process.stdout.write(JSON.stringify({ firstLive, items, answer, approvalsAsked, approval, clicks: state.clicks, dialogAnswers: state.dialogAnswers, transfers: walletState.transfers, nodeRequests: walletState.nodeRequests, downloads: state.downloads, transferChat: walletState.chatId, chatId, chatIds: [...state.chatIds], unboundCalls: state.unboundCalls }));
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
