// Kill-and-reopen check of src/durable.js under Node, on Node's SQLite:
// run it after every Pi upgrade (`npm run check`), since pi-durable's API
// changes without notice between releases.
//
// 1. A run is killed (SIGKILL) while the answer streams; reopening continues
//    it, and asking again with the same request ID doesn't ask twice.
// 2. A tip waits for approval and the process is killed; reopening asks
//    again, and once approved the tip is sent exactly once.

import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { openDurableAgent } from "../src/durable.js";

const QUESTION = "What is the page I have open about?";
const TIP = "Please send a tip to the author";

if (process.argv[2] === "child") await child(process.argv[3], process.argv[4]);
else await main();

async function main() {
	const dir = await mkdtemp(join(tmpdir(), "freedom-durable-"));
	let failed = false;
	const check = (ok, what) => {
		console.log(`${ok ? "PASS" : "FAIL"}  ${what}`);
		failed ||= !ok;
	};
	try {
		const answerDb = join(dir, "answer.sqlite");
		check((await runChild("kill-mid-answer", answerDb)).signal === "SIGKILL", "killed while the answer streamed");
		const resumed = JSON.parse((await runChild("resume", answerDb)).stdout);
		check(resumed.resumedBusy, "reopening finds the run in progress");
		check(resumed.transcript.filter((e) => e.kind === "pi.user").length === 1, "asking again with the same request ID adds no second question");
		check(resumed.transcript.some((e) => e.text.endsWith("[aborted]")), "the cut-off answer is kept, marked aborted");
		check(/That is the end of the answer\.$/.test(resumed.answer), "the run finishes with the whole answer");

		const tipDb = join(dir, "tip.sqlite");
		check((await runChild("kill-at-approval", tipDb)).signal === "SIGKILL", "killed while an approval waited");
		const approved = JSON.parse((await runChild("approve", tipDb)).stdout);
		check(approved.approvalAskedAgain, "reopening asks for the approval again");
		check(approved.transcript.filter((e) => e.kind === "pi.tool-result" && e.text.startsWith("send_tip: Sent")).length === 1, "the approved tip is sent once");
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

async function child(mode, file) {
	const database = await openNodeSqliteDatabase(file);
	const ended = Promise.withResolvers();
	let approvalAskedAgain = false;
	let agent;
	const emit = (event) => {
		// Past Pi's one-second window for storing a streaming answer, so some of it is saved.
		if (event.type === "state" && mode === "kill-mid-answer" && event.partial.length >= 200) process.kill(process.pid, "SIGKILL");
		if (event.type === "approval") {
			if (mode === "kill-at-approval") process.kill(process.pid, "SIGKILL");
			if (mode === "approve") {
				approvalAskedAgain = true;
				agent.approve(event.taskId, true);
			}
		}
		if (event.type === "run_end") ended.resolve(event);
	};
	agent = await openDurableAgent({
		database,
		emit,
		pace: mode === "kill-mid-answer" ? 25 : 2000,
		readPage: async () => ({ url: "https://example.com/", title: "Example Domain", text: "This domain is for use in illustrative examples." }),
	});
	if (mode === "kill-mid-answer" || mode === "resume") await agent.submit({ prompt: QUESTION, requestId: "question-1" });
	if (mode === "kill-at-approval") await agent.submit({ prompt: TIP, requestId: "tip-1" });
	const timeout = setTimeout(() => ended.reject(new Error(`${mode}: no run_end within 30 s`)), 30_000);
	const end = await ended.promise;
	clearTimeout(timeout);
	const transcript = await agent.transcript();
	process.stdout.write(JSON.stringify({ resumedBusy: agent.resumed.busy, approvalAskedAgain, answer: end.answer, transcript }));
	await agent.close();
	await database.close();
}
