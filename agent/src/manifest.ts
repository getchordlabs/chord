// Prints the tools as OpenAI-style function-calling definitions (JSON) — the same list the MCP
// server exposes, for frameworks that take a manifest instead of speaking MCP. `pnpm manifest`
// writes tools.json; the web build serves a copy at https://getchord.xyz/agent/tools.json.
import { zodToJsonSchema } from "./zodschema.js";
import { tools } from "./tools.js";

const manifest = {
  name: "chord",
  version: "0.1.0",
  base_url: "https://api.getchord.xyz",
  auth: { header: "X-API-Key", required: false, note: "Reads work without a key at a lower limit; a key raises it to your plan." },
  tools: tools.map((t) => ({ type: "function", function: { name: t.name, description: t.description, parameters: zodToJsonSchema(t.input) } })),
};
process.stdout.write(JSON.stringify(manifest, null, 2) + "\n");
