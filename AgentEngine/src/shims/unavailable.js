// Node modules pi-mcp imports for local (stdio) servers and its loopback
// sign-in server. A phone has neither: they fail if ever reached.
const unavailable = () => {
	throw new Error("Not available on iPhone: only remote MCP servers over HTTPS are supported.");
};
export const spawn = unavailable;
export const createServer = unavailable;
export default new Proxy(unavailable, { get: () => unavailable });
