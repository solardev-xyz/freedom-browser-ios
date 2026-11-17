// The part of Node's Buffer pi-mcp's HTTP and OAuth code uses (SSE byte
// counts, PKCE and state encoding, Basic auth, output limits), for WebKit.
// Only pi-mcp's modules see it (build.mjs): other packages test
// `typeof Buffer` and must keep taking their browser paths.

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const HEX = Array.from({ length: 256 }, (_, i) => i.toString(16).padStart(2, "0"));

function base64(bytes) {
	let binary = "";
	for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
	return btoa(binary);
}

function fromBase64(text) {
	const normal = text.replace(/-/g, "+").replace(/_/g, "/");
	const binary = atob(normal + "=".repeat((4 - (normal.length % 4)) % 4));
	return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

export class Buffer extends Uint8Array {
	static from(value, encodingOrOffset, length) {
		if (typeof value === "string") {
			const encoding = encodingOrOffset ?? "utf8";
			if (encoding === "hex") return new Buffer(Uint8Array.from(value.match(/../g) ?? [], (pair) => parseInt(pair, 16)));
			if (encoding === "base64" || encoding === "base64url") return new Buffer(fromBase64(value));
			return new Buffer(encoder.encode(value));
		}
		if (value instanceof ArrayBuffer) return new Buffer(new Uint8Array(value, encodingOrOffset ?? 0, length ?? value.byteLength - (encodingOrOffset ?? 0)));
		if (ArrayBuffer.isView(value)) return new Buffer(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
		return new Buffer(Uint8Array.from(value));
	}

	static alloc(size) {
		return new Buffer(size);
	}

	static byteLength(value) {
		return typeof value === "string" ? encoder.encode(value).length : value.byteLength;
	}

	static concat(list, total) {
		const size = total ?? list.reduce((n, item) => n + item.length, 0);
		const out = new Buffer(size);
		let offset = 0;
		for (const item of list) {
			out.set(item.subarray(0, Math.min(item.length, size - offset)), offset);
			offset += item.length;
			if (offset >= size) break;
		}
		return out;
	}

	static isBuffer(value) {
		return value instanceof Buffer;
	}

	toString(encoding = "utf8", start = 0, end = this.length) {
		const bytes = this.subarray(start, end);
		switch (encoding) {
			case "hex":
				return Array.from(bytes, (b) => HEX[b]).join("");
			case "base64":
				return base64(bytes);
			case "base64url":
				return base64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
			default:
				return decoder.decode(bytes);
		}
	}
}
