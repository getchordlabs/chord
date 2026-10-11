// Prints the tools as OpenAI-style function-calling definitions (JSON), read from the hosted server — the same list
// every MCP client sees. `pnpm manifest` writes tools.json; the web build serves a copy at
// https://getchord.xyz/agent/tools.json. The live copy is always GET https://api.getchord.xyz/v1/mcp/tools.json.
import { toolManifest } from "./tools.js";

const manifest = {
  name: "chord",
  version: "0.2.0",
  base_url: "https://api.getchord.xyz",
  mcp: "https://api.getchord.xyz/v1/mcp",
  auth: { header: "X-API-Key", required: false, note: "Reads work without a key at a lower limit; a key raises it to your plan." },
  tools: await toolManifest(),
};
process.stdout.write(JSON.stringify(manifest, null, 2) + "\n");
