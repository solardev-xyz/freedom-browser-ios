// Every http(s) fetch the engine makes goes through the app's URLSession,
// via the same-origin endpoint `freedom-agent://engine/net`.
//
// WebKit applies CORS and drops forbidden request headers, and several model
// providers don't allow browser origins. The app replays the request exactly:
// the target URL travels in `x-freedom-target`, the original headers as base64
// JSON in `x-freedom-headers`. The response body streams back through the
// scheme task, so server-sent events arrive as they come, and aborting the
// fetch stops the app's request.

export const NET_ENDPOINT = "freedom-agent://engine/net";

export function installNativeFetch() {
	const webkitFetch = globalThis.fetch.bind(globalThis);
	let counter = 0;

	globalThis.fetch = async (input, init) => {
		const request = new Request(input, init);
		const { protocol } = new URL(request.url);
		if (protocol !== "http:" && protocol !== "https:") return webkitFetch(request);

		const headers = [];
		request.headers.forEach((value, name) => headers.push([name, value]));
		const hasBody = request.method !== "GET" && request.method !== "HEAD";
		const response = await webkitFetch(NET_ENDPOINT, {
			method: request.method,
			headers: {
				"x-freedom-target": request.url,
				"x-freedom-headers": base64(JSON.stringify(headers)),
				"x-freedom-request": `${Date.now().toString(36)}-${(++counter).toString(36)}`,
			},
			body: hasBody ? await request.arrayBuffer() : undefined,
			signal: request.signal,
			cache: "no-store",
		});
		// The SDKs read `response.url`; report the target, not the bridge endpoint.
		const wrapped = new Response(response.body, { status: response.status, statusText: response.statusText, headers: response.headers });
		Object.defineProperty(wrapped, "url", { value: request.url });
		return wrapped;
	};
}

function base64(text) {
	let binary = "";
	for (const byte of new TextEncoder().encode(text)) binary += String.fromCharCode(byte);
	return btoa(binary);
}
