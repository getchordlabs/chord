// Smoke test: talks to the server the way a client does. `node test/smoke.mjs` = stdio against the
// local index file; `node test/smoke.mjs http://localhost:8424/docs/mcp` = Streamable HTTP.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const target = process.argv[2];
const transport = target
  ? new StreamableHTTPClientTransport(new URL(target))
  : new StdioClientTransport({ command: "node", args: [join(here, "..", "stdio.mjs")], env: { ...process.env, DOCS_INDEX_FILE: process.env.DOCS_INDEX_FILE || join(here, "..", "..", "docs-chord", "public", "docs-index.json") } });

const client = new Client({ name: "smoke", version: "0" });
await client.connect(transport);
const tools = (await client.listTools()).tools.map((t) => t.name);
console.log("tools:", tools.join(", "));
const text = (r) => r.content.map((c) => c.text).join("\n");
const checks = [
  ["search_chord_docs", { query: "subscribe to Arc prices over websocket", limit: 3 }, /prices/i],
  ["search_chord_docs", { query: "SLIPPAGE_MISMATCH", limit: 3 }, /SLIPPAGE_MISMATCH/],
  ["read_chord_docs_page", { path: "/docs/concepts/streaming/" }, /op": "sub"/],
  ["chord_api_reference", { query: "/v1/arc/tokens", full: false }, /GET \/v1\/arc\/tokens/],
  ["chord_api_reference", { query: "getQuote", limit: 1 }, /otherAmountThreshold/],
  ["chord_api_reference", { query: "holders" }, /arcTokenHolders/],
  ["list_chord_docs_pages", {}, /recipes/],
];
let fail = 0;
for (const [name, args, re] of checks) {
  const t0 = Date.now();
  const r = await client.callTool({ name, arguments: args });
  const out = text(r);
  const ok = !r.isError && re.test(out);
  if (!ok) fail++;
  console.log(`${ok ? "ok " : "FAIL"} ${name} ${JSON.stringify(args)} → ${out.length} chars, ${Date.now() - t0} ms${ok ? "" : "\n" + out.slice(0, 400)}`);
}
await client.close();
if (fail) { console.error(`${fail} check(s) failed`); process.exit(1); }
console.log("all checks passed");
