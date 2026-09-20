// Chord Docs MCP over Streamable HTTP — the hosted endpoint (getchord.xyz/docs/mcp):
//   claude mcp add --transport http chord-docs https://getchord.xyz/docs/mcp
// Stateless (one transport per request, no session ids), so any number of replicas and no sticky
// routing. Runs as the `docs-mcp` compose service; Caddy routes /docs/mcp* here. Index comes from
// DOCS_INDEX_URL (in compose: the docs-chord container's own copy) and refreshes every
// DOCS_INDEX_TTL_MIN minutes.
import { createServer as createHttpServer } from "node:http";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { createServer, loadIndex } from "./server.mjs";

const PORT = Number(process.env.PORT) || 8424;
const PATH = process.env.MCP_PATH || "/docs/mcp";
const TTL = (Number(process.env.DOCS_INDEX_TTL_MIN) || 10) * 60_000;

let index = null, loading = null;
async function getIndex() {
  if (index && Date.now() - index.loadedAt < TTL) return index;
  if (!loading) loading = loadIndex().then((i) => { index = i; console.log(JSON.stringify({ msg: "docs index loaded", source: i.source, pages: i.pages.length, operations: i.operations.length })); return i; }).catch((e) => { console.error(JSON.stringify({ msg: "docs index load failed", err: String(e.message || e) })); if (index) return index; throw e; }).finally(() => { loading = null; });
  return loading;
}
// Retry the first load until it succeeds (docs-chord may still be starting when this container does).
(async function warm() { for (let i = 0; i < 30; i++) { try { await getIndex(); return; } catch { await new Promise((r) => setTimeout(r, 5000)); } } })();

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS", "Access-Control-Allow-Headers": "Content-Type, Accept, Authorization, Mcp-Session-Id, Mcp-Protocol-Version", "Access-Control-Expose-Headers": "Mcp-Session-Id" };

const httpServer = createHttpServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  if (req.method === "OPTIONS") { res.writeHead(204, CORS); return res.end(); }
  if (url.pathname === "/healthz" || url.pathname === PATH + "/healthz") {
    const ok = !!index; res.writeHead(ok ? 200 : 503, { "Content-Type": "application/json", ...CORS });
    return res.end(JSON.stringify({ ok, pages: index?.pages.length ?? 0, operations: index?.operations.length ?? 0, loadedAt: index?.loadedAt ?? null, source: index?.source ?? null }));
  }
  if (url.pathname !== PATH && url.pathname !== PATH + "/") { res.writeHead(404, { "Content-Type": "application/json", ...CORS }); return res.end(JSON.stringify({ error: "NOT_FOUND", message: `MCP endpoint is ${PATH}` })); }
  if (req.method === "GET" || req.method === "DELETE") {
    // Stateless server: no SSE resumption stream, no sessions to delete.
    res.writeHead(405, { "Content-Type": "application/json", Allow: "POST, OPTIONS", ...CORS });
    return res.end(JSON.stringify({ jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed. POST JSON-RPC to this endpoint (Streamable HTTP, stateless)." }, id: null }));
  }
  if (req.method !== "POST") { res.writeHead(405, CORS); return res.end(); }
  try {
    for (const [k, v] of Object.entries(CORS)) res.setHeader(k, v);
    const body = await readJson(req);
    const server = createServer(getIndex);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    res.on("close", () => { transport.close().catch(() => {}); server.close().catch(() => {}); });
    await server.connect(transport);
    await transport.handleRequest(req, res, body);
  } catch (e) {
    console.error(JSON.stringify({ msg: "mcp request failed", err: String(e?.message || e) }));
    if (!res.headersSent) { res.writeHead(500, { "Content-Type": "application/json", ...CORS }); res.end(JSON.stringify({ jsonrpc: "2.0", error: { code: -32603, message: "Internal error" }, id: null })); }
  }
});
function readJson(req) {
  return new Promise((resolve, reject) => {
    let data = ""; req.setEncoding("utf8");
    req.on("data", (c) => { data += c; if (data.length > 1_000_000) { reject(new Error("body too large")); req.destroy(); } });
    req.on("end", () => { try { resolve(data ? JSON.parse(data) : undefined); } catch (e) { reject(e); } });
    req.on("error", reject);
  });
}
httpServer.listen(PORT, () => console.log(JSON.stringify({ msg: "chord docs mcp listening", port: PORT, path: PATH })));
