// Desktop's swarm-publishing skill, for the phone: attachments and inline
// text (no project workspaces or folders), with desktop's private draft links
// and stable addresses. No domain tools on the phone yet.
export default {
	name: "swarm-publishing",
	description: "Publish a file attached to the chat, or bounded text, to Swarm through Freedom.",
	content: `# Swarm publishing

Use this skill when the user wants to publish a file or a text to Swarm. Use Freedom's \`swarm_publish\` tool. Do not use \`window.swarm\`, raw \`node_request\`, or a webpage upload flow for this direct Freedom capability.

## Publication semantics

- A Swarm publication is public and unencrypted by default (\`target\` omitted or \`public\`). Explain that clearly before publication when the user may not expect public distribution.
- \`target: "draft"\` makes a **private draft link** instead: Freedom uploads it with Swarm encryption and returns a longer \`bzz://\` link that carries the decryption key. Use it only when the user asks for a draft, preview or private link. Tell the user plainly that anyone who gets the link can read the content, and that the encrypted data is still stored on the public network permanently; it can't be deleted. A draft never gets a stable address or a domain name. Publishing the same content publicly later is a separate \`swarm_publish\` call with its own approval; never present a draft as published.
- \`stableAddress: "<name>"\` (public only) publishes under a Swarm feed owned by the user's Swarm identity, so a later publication with the same name updates the same \`bzz://\` address. Use it when the user wants one address for a site they will keep fixing, and reuse the same name for every update. It needs Freedom's vault unlocked. A feed unpublishes nothing: older versions stay retrievable by anyone who has their own reference while their postage is valid. Say so when you offer it.
- Sources: a file the user attached to this chat (find its \`resourceId\` with \`attachment_list\`), or bounded text you already have authority to publish. Never ask for or invent a filesystem path. Inline text is a text/data publication; do not invent or report a filename. Supply a content type only when it is useful (for example \`text/html\` for a one-page site you wrote for the user).
- For a single-page site you write: put everything in one HTML document, with no scripts, fonts, styles or images loaded from other hosts, no analytics, and no form posting to another site unless the user asks.

## Preflight

1. If the content appears to contain secrets, private keys, credentials, or personal data, warn the user rather than silently publishing it.
2. Call \`node_status\` if Swarm readiness or storage is unknown.
3. Publishing uses existing usable Swarm storage (a postage batch). The approval shows the user that batch and its remaining time. If Freedom reports that no usable storage exists, read the swarm-postage skill and follow it. Never buy storage implicitly.

## Publish and recover

1. Call \`swarm_publish\` once with exactly one of \`resourceId\` or \`text\`. Freedom asks the user, then uploads.
2. Keep the returned \`publicationId\`. A \`sending\` status means the reference is final but chunks are still being pushed to the network; check again with \`swarm_publication_status\`. Do not repeat \`swarm_publish\` while the earlier publication may have applied.
3. After an interrupted run, call \`swarm_publication_status\` without an ID to find this chat's recent publications.

## Completion report

Report the published file's name (for an attachment) or that text was published, the \`bzz://\` URL and the reference, and whether all chunks were sent. Distinguish "sent to the network" from "still sending". The receipt's \`target\` says whether it was a public publication or a private draft link; report a draft as a private draft link, never as published. With a stable address, report \`stableAddress.bzzUrl\` as the address to share, and say plainly if \`stableAddress.updated\` is false (the content is published, but the address still points to the previous version). Never expose a filesystem path.`,
};
