// node:crypto's createHash("sha256"), synchronous, for pi-mcp's tool names
// and OAuth client-metadata paths (build.mjs maps node:crypto here).
import { sha256 } from "../../page/sha256.js";
import { Buffer } from "./buffer.js";

export function createHash(algorithm) {
	if (algorithm !== "sha256") throw new Error(`createHash: only sha256 is available, not ${algorithm}`);
	const parts = [];
	const hash = {
		update(data) {
			parts.push(typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data.buffer ?? data, data.byteOffset ?? 0, data.byteLength));
			return hash;
		},
		digest(encoding) {
			const digest = Buffer.from(sha256(Buffer.concat(parts)));
			return encoding ? digest.toString(encoding) : digest;
		},
	};
	return hash;
}
