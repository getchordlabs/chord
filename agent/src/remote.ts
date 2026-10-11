// The hosted Chord MCP (POST <api>/v1/mcp) as a tiny client. The API owns the tool list and every tool's behaviour;
// this package only carries the protocol, so a new or changed tool reaches every install without a new release.
// Env: CHORD_API_URL (default https://api.getchord.xyz) · CHORD_API_KEY (optional, raises limits; chord_ask needs it) ·
// CHORD_CHAIN (optional: pins a default chain, e.g. arc, monad, robinhood, base, bnb, avalanche, solana).
const BASE = (process.env.CHORD_API_URL || "https://api.getchord.xyz").replace(/\/+$/, "");
const KEY = process.env.CHORD_API_KEY || "";
const CHAIN = (process.env.CHORD_CHAIN || "").trim().toLowerCase();

export const endpoint = () => `${BASE}/v1/mcp${CHAIN ? `?chain=${encodeURIComponent(CHAIN)}` : ""}`;

export interface RemoteTool { name: string; description: string; inputSchema: Record<string, unknown>; annotations?: Record<string, unknown> }
export interface ToolResult { content: { type: string; text?: string }[]; isError?: boolean }

let seq = 0;
/** One JSON-RPC call to the hosted server. Throws on transport and protocol errors (tool errors come back as results). */
export async function rpc<T>(method: string, params?: unknown, timeoutMs = 90_000): Promise<T> {
  const res = await fetch(endpoint(), {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json", ...(KEY ? { "X-API-Key": KEY } : {}) },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++seq, method, ...(params === undefined ? {} : { params }) }),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await res.text();
  let body: any;
  try { body = JSON.parse(text); } catch { throw new Error(`Chord MCP ${res.status}: ${text.slice(0, 200)}`); }
  if (body?.error) throw new Error(`Chord MCP ${body.error.code}: ${body.error.message}`);
  if (!res.ok) throw new Error(`Chord MCP ${res.status}`);
  return body.result as T;
}

export const initialize = () => rpc<{ serverInfo: { name: string; version: string }; instructions?: string; protocolVersion: string }>("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "chord-agent", version: "0.2.0" } });
export const listTools = async (): Promise<RemoteTool[]> => (await rpc<{ tools: RemoteTool[] }>("tools/list")).tools;
export const callTool = (name: string, args: Record<string, unknown> = {}) => rpc<ToolResult>("tools/call", { name, arguments: args });
