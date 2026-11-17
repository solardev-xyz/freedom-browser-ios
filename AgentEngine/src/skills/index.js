// Desktop Freedom's built-in skills (src/main/agent/skills), adapted to the
// phone: procedures the model reads with skill_read before a task they
// cover. The system prompt lists them by name and description.

import { defineTool } from "@earendil-works/pi-durable";
import { obj, oneOf } from "@earendil-works/pi-schema";
import swarmPostage from "./swarm-postage.js";
import swarmPublishing from "./swarm-publishing.js";
import dwebDomains from "./dweb-domains.js";

export const SKILLS = [swarmPublishing, swarmPostage, dwebDomains];

export function skillsSection() {
	return [
		"Skills: procedures for some tasks. Before such a task, read the skill with skill_read and follow it.",
		...SKILLS.map((skill) => `- ${skill.name}: ${skill.description}`),
	].join("\n");
}

export const skillTool = defineTool({
	name: "skill_read",
	description: "Read one of Freedom's skills (the procedures listed in your instructions) before the task it covers.",
	parameters: obj({ name: oneOf(SKILLS.map((skill) => skill.name)) }),
	replay: "safe",
	execute: async ({ name }) => ({ output: [{ type: "text", text: SKILLS.find((skill) => skill.name === name).content }] }),
});
