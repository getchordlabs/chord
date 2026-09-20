# chord-docs-mcp

The Chord developer docs (getchord.xyz/docs) as an MCP server. Read-only; it never calls the Chord API.

- Hosted (Streamable HTTP): `https://getchord.xyz/docs/mcp` — `claude mcp add --transport http chord-docs https://getchord.xyz/docs/mcp`
- Local (stdio): `claude mcp add chord-docs -- node /abs/path/packages/docs-mcp/stdio.mjs`

Tools: `search_chord_docs` · `read_chord_docs_page` · `chord_api_reference` · `list_chord_docs_pages`.

Data = `https://getchord.xyz/docs/docs-index.json`, built by `packages/docs-chord/scripts/build-index.mjs` with the site.
Env: `DOCS_INDEX_URL` (default the URL above) · `DOCS_INDEX_FILE` (local build) · `DOCS_INDEX_TTL_MIN` · `PORT` / `MCP_PATH` (http only).

```
node test/smoke.mjs                              # stdio, local index
node test/smoke.mjs http://localhost:8424/docs/mcp   # http
```
