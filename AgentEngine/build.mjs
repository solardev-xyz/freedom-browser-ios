// Bundles the engine for WebKit into the app's resources:
// Freedom/Freedom/Resources/agent-engine/agent-engine.{js,html}.
// The output is generated, so git ignores it; run `npm run build` after
// changing src/ or the Pi versions in package.json.

import { mkdir, writeFile } from "node:fs/promises";
import { build } from "esbuild";

const outdir = new URL("../Freedom/Freedom/Resources/agent-engine/", import.meta.url);
await mkdir(outdir, { recursive: true });

const result = await build({
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
