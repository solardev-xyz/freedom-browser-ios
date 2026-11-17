// The wallet tool: desktop Freedom's `wallet_transfer` (pi-browser-tools.js),
// name, parameters and description. The app's `wallet` service
// (AgentWallet.swift) resolves the network, asset and recipient, checks
// balances and the fee, and shows the exact transfer to the user, who
// approves it on the phone; only then does the wallet sign and send.

import { defineTool } from "@earendil-works/pi-durable";
import { int, obj, opt, str } from "@earendil-works/pi-schema";

const json = (value) => ({ output: [{ type: "text", text: JSON.stringify(value) }] });

/** `wallet(method, params)`: the host's wallet service. */
export function createWalletTools(wallet) {
	return [
		defineTool({
			name: "wallet_transfer",
			description:
				"Prepare and send one exact asset transfer from a Freedom wallet. This is a direct Freedom capability, not a webpage interaction. Freedom resolves the recipient, verifies balances, estimates the maximum fee, and always asks the user to approve the exact transfer before signing. If an asset exists on multiple networks, ask the user which network to use and retry with its chainId. If the user declines, do not retry or work around the decision unless they explicitly ask again. If a call was interrupted, ask the user to check the wallet's activity before sending again; never send twice.",
			parameters: obj({
				recipient: str({ minLength: 1, maxLength: 255 }),
				amount: str({ minLength: 1, maxLength: 80 }),
				asset: str({ minLength: 1, maxLength: 80, description: "Configured wallet asset symbol or token contract address." }),
				chainId: opt(int({ minimum: 1, description: "Exact EVM chain ID. Required when the asset is ambiguous." })),
				walletIndex: opt(int({ minimum: 0, description: "Freedom wallet account index. Omit to use the active account." })),
			}),
			// Never repeated after a restart: a transfer may already have been sent.
			replay: "unsafe",
			execute: async (args, api) => json(await wallet("transfer", { ...args, chatId: api.conversationId })),
		}),
	];
}
