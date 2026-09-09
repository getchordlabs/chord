#!/usr/bin/env node
// Chord MCP server (stdio). Point Claude Desktop, Cursor, Claude Code or any MCP client at
// `chord-agent` and the nine Chord tools appear. Env: CHORD_API_KEY (optional, raises limits),
// CHORD_API_URL (default https://api.getchord.xyz).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { tools } from "./tools.js";

const server = new McpServer({ name: "chord", version: "0.1.0" });
for (const t of tools) {
  const shape = (t.input as any).shape ?? {};
  server.tool(t.name, t.description, shape, async (args: unknown) => {
    try {
      const out = await t.run(t.input.parse(args ?? {}) as never);
      return { content: [{ type: "text" as const, text: JSON.stringify(out, null, 1) }] };
    } catch (e) {
      return { content: [{ type: "text" as const, text: `error: ${(e as Error).message}` }], isError: true };
    }
  });
}
await server.connect(new StdioServerTransport());
