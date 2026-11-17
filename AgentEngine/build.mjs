// Bundles the engine for WebKit into the app's resources:
// Freedom/Freedom/Resources/agent-engine/agent-engine.{js,html}, and the page
// side, agent-page.js.
// The output is generated, so git ignores it; run `npm run build` after
// changing src/ or the Pi versions in package.json.

import { mkdir, writeFile } from "node:fs/promises";
import { build } from "esbuild";

const outdir = new URL("../Freedom/Freedom/Resources/agent-engine/", import.meta.url);
await mkdir(outdir, { recursive: true });

// pi-mcp (MCP servers) is written for Node: its HTTP and OAuth code needs a
// little of Buffer and node:crypto, and its stdio transport and loopback
// sign-in server need processes and sockets, which a phone doesn't offer.
const shim = (name) => new URL(`src/shims/${name}`, import.meta.url).pathname;
const piMcpForWebKit = {
	name: "pi-mcp-for-webkit",
	setup(build) {
		build.onResolve({ filter: /^node:crypto$/ }, () => ({ path: shim("node-crypto.js") }));
		build.onResolve({ filter: /^(node:child_process|node:process|node:http|cross-spawn)$/ }, () => ({ path: shim("unavailable.js") }));
		// Buffer, for pi-mcp's own modules only.
		build.onLoad({ filter: /node_modules\/@earendil-works\/pi-mcp\/dist\/.*\.js$/ }, async (args) => {
			const { readFile } = await import("node:fs/promises");
			const source = await readFile(args.path, "utf8");
			return { contents: `import { Buffer } from ${JSON.stringify(shim("buffer.js"))};\n${source}`, loader: "js" };
		});
	},
};

const result = await build({
	plugins: [piMcpForWebKit],
	entryPoints: ["src/main.js"],
	outfile: new URL("agent-engine.js", outdir).pathname,
	bundle: true,
	format: "esm",
	platform: "browser",
	target: "safari18",
	minify: true,
	metafile: true,
	logLevel: "info",
});

// The page side: injected into a tab's isolated content world when the agent
// reads or operates the page (AgentPageDriver.swift).
await build({
	entryPoints: ["page/index.js"],
	outfile: new URL("agent-page.js", outdir).pathname,
	bundle: true,
	format: "iife",
	platform: "browser",
	target: "safari18",
	minify: true,
	logLevel: "info",
});

await writeFile(
	new URL("agent-engine.html", outdir),
	`<!doctype html>
<html>
<head><meta charset="utf-8"><title>Freedom agent engine</title></head>
<body><script type="module" src="agent-engine.js"></script></body>
</html>
`,
);

// The largest inputs, to keep an eye on what the bundle pulls in.
const sizes = new Map();
for (const [file, { bytesInOutput }] of Object.entries(Object.values(result.metafile.outputs)[0].inputs)) {
	const pkg = /node_modules\/((?:@[^/]+\/)?[^/]+)/.exec(file)?.[1] ?? "(engine)";
	sizes.set(pkg, (sizes.get(pkg) ?? 0) + bytesInOutput);
}
for (const [pkg, bytes] of [...sizes].sort((a, b) => b[1] - a[1]).slice(0, 12)) {
	console.log(`${(bytes / 1024).toFixed(0).padStart(6)} KiB  ${pkg}`);
}
