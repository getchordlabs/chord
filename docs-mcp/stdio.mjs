#!/usr/bin/env node
// Chord Docs MCP over stdio — for Claude Code / Claude Desktop / Cursor:
//   claude mcp add chord-docs -- node /abs/path/packages/docs-mcp/stdio.mjs
// Loads the docs index from getchord.xyz on start (DOCS_INDEX_URL to override, DOCS_INDEX_FILE for a
// local build) and refreshes it every DOCS_INDEX_TTL_MIN minutes (default 30) on the next call.
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createServer, loadIndex } from "./server.mjs";

const TTL = (Number(process.env.DOCS_INDEX_TTL_MIN) || 30) * 60_000;
let index = null, loading = null;
async function getIndex() {
  if (index && Date.now() - index.loadedAt < TTL) return index;
  if (!loading) loading = loadIndex().then((i) => { index = i; return i; }).catch((e) => { if (index) return index; throw e; }).finally(() => { loading = null; });
  return loading;
}

const server = createServer(getIndex);
await server.connect(new StdioServerTransport());
// Warm the index so the first tool call is fast; a failure here surfaces on the first call instead.
getIndex().catch(() => {});
