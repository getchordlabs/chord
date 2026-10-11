#!/usr/bin/env node
// Chord MCP server (stdio) — a bridge to the hosted server at <CHORD_API_URL>/v1/mcp, for clients that only speak
// stdio. Clients that speak HTTP should add the hosted URL directly:
//   claude mcp add --transport http chord https://api.getchord.xyz/v1/mcp
// Env: CHORD_API_KEY (optional), CHORD_API_URL (default https://api.getchord.xyz), CHORD_CHAIN (optional default chain).
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { callTool, initialize, listTools } from "./remote.js";

// The hosted server's own name and instructions, when it answers; a bridge that starts offline still starts.
const remote = await initialize().catch(() => null);
const server = new Server(
  { name: remote?.serverInfo?.name ?? "chord", version: "0.2.0" },
  { capabilities: { tools: {} }, ...(remote?.instructions ? { instructions: remote.instructions } : {}) },
);
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: (await listTools()) as any }));
server.setRequestHandler(CallToolRequestSchema, async (req) => {
  try {
    return (await callTool(req.params.name, (req.params.arguments ?? {}) as Record<string, unknown>)) as any;
  } catch (e) {
    return { content: [{ type: "text", text: `error: ${(e as Error).message}` }], isError: true };
  }
});
await server.connect(new StdioServerTransport());
