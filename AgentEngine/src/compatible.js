// Providers spoken to with the OpenAI chat-completions API at a base URL:
// desktop's Venice and NEAR AI (here without their attestation and
// end-to-end encryption) and any compatible server the user names. The
// user picks the model; its one entry here is what pi-ai needs to talk to
// it (prices unknown, so 0).

import { createProvider, envApiKeyAuth } from "@earendil-works/pi-ai";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";

const NO_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

/** `{ id, name, baseUrl, modelId, vision }` from the app's settings. */
export function compatibleProvider({ id, name, baseUrl, modelId, vision }) {
	return createProvider({
		id,
		name,
		baseUrl,
		auth: { apiKey: envApiKeyAuth(`${name} API key`, []) },
		models: [
			{
				id: modelId,
				name: modelId,
				api: "openai-completions",
				provider: id,
				baseUrl,
				input: vision ? ["text", "image"] : ["text"],
				cost: NO_COST,
				reasoning: false,
				contextWindow: 128_000,
				maxTokens: 8192,
			},
		],
		api: openAICompletionsApi(),
	});
}
