// The attachment tools: desktop Freedom's attachment_list, attachment_read
// and attachment_render_page (pi-attachment-tools.js), names, parameters and
// descriptions. The app's `attachments` service (AgentAttachments.swift)
// keeps each chat's files: bounded text, images, PDF text and PDF pages.
// The phone has files only, no shared folders, so `path` is accepted and
// unused.

import { defineTool } from "@earendil-works/pi-durable";
import { int, obj, opt, str } from "@earendil-works/pi-schema";

const json = (value) => ({ output: [{ type: "text", text: JSON.stringify(value) }] });

async function acceptsImages(api, ctx) {
	const agent = await api.agent(ctx);
	const model = agent?.model && api.models.getModel(agent.model.provider, agent.model.modelId);
	return !model || model.input?.includes("image") === true;
}

/** `files(method, params)`: the host's attachments service. */
export function createAttachmentTools(files) {
	const call = (api, method, params = {}) => files(method, { ...params, chatId: api.conversationId });
	return [
		defineTool({
			name: "attachment_list",
			description: "List files explicitly shared with this conversation. Local filesystem paths are never exposed.",
			parameters: obj({ resourceId: opt(str({ maxLength: 80 })), path: opt(str({ maxLength: 1024 })), offset: opt(int({ minimum: 0, maximum: 10_000 })) }),
			replay: "safe",
			execute: async (_, api) => json(await call(api, "list")),
		}),
		defineTool({
			name: "attachment_read",
			description:
				"Read a bounded section of an attached text file, inspect an image when the selected model supports vision, or extract text from 1–4 PDF pages. Use 1-based page and pageCount for PDFs.",
			parameters: obj({
				resourceId: str({ minLength: 1, maxLength: 80 }),
				path: opt(str({ maxLength: 1024 })),
				offset: opt(int({ minimum: 0 })),
				limit: opt(int({ minimum: 1 })),
				page: opt(int({ minimum: 1, maximum: 500 })),
				pageCount: opt(int({ minimum: 1, maximum: 4 })),
			}),
			replay: "safe",
			execute: async ({ resourceId, offset, limit, page, pageCount }, api, ctx) => {
				const result = await call(api, "read", { resourceId, offset, limit, page, pageCount });
				if (result.kind !== "image") return json(result);
				if (!(await acceptsImages(api, ctx))) throw new Error("The selected model cannot inspect image attachments.");
				const { base64, mimeType, ...meta } = result;
				return { output: [{ type: "text", text: JSON.stringify(meta) }, { type: "image", data: base64, mimeType }] };
			},
		}),
		defineTool({
			name: "attachment_render_page",
			description:
				"Render one page of an attached PDF as a bounded image for visual inspection. Use this only for a specific page whose layout or imagery matters, or when text extraction reports no extractable text. Page numbers are 1-based. Needs a model that accepts images.",
			parameters: obj({ resourceId: str({ minLength: 1, maxLength: 80 }), path: opt(str({ maxLength: 1024 })), page: int({ minimum: 1, maximum: 500 }) }),
			replay: "safe",
			execute: async ({ resourceId, page }, api, ctx) => {
				if (!(await acceptsImages(api, ctx))) throw new Error("The selected model cannot look at images; use attachment_read for the page's text.");
				const { base64, mimeType, ...meta } = await call(api, "renderPage", { resourceId, page });
				return { output: [{ type: "text", text: `Rendered PDF: ${meta.name} — page ${meta.page} of ${meta.pageCount}` }, { type: "image", data: base64, mimeType }] };
			},
		}),
	];
}

const SIZE_UNITS = ["B", "KB", "MB"];
function size(bytes) {
	let value = bytes;
	let unit = 0;
	while (value >= 1024 && unit < SIZE_UNITS.length - 1) {
		value /= 1024;
		unit += 1;
	}
	return `${value < 10 && unit > 0 ? value.toFixed(1) : Math.round(value)} ${SIZE_UNITS[unit]}`;
}

/**
 * The user message for `prompt` with attached files: a note naming them (the
 * app's sheet shows it as chips) and, for a model that accepts images, the
 * images themselves.
 */
export function messageWithAttachments(prompt, attachments = [], images = [], acceptsImages = false) {
	if (!attachments.length) return prompt;
	const note = attachments.map((a) => `${a.name} (${a.resourceId}, ${a.mimeType}, ${size(a.bytes)})`).join("; ");
	const text = `${prompt}\n\nAttached files (read them with attachment_read): ${note}`;
	const shown = acceptsImages ? images.map((image) => ({ type: "image", data: image.base64, mimeType: image.mimeType })) : [];
	return shown.length ? [{ type: "text", text }, ...shown] : text;
}
