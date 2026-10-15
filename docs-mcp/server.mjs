// Chord Docs MCP — the developer docs and the API reference as tools for any MCP client (the same
// idea as Codex's "Docs MCP" / Mintlify's hosted /mcp). Read-only: it serves documentation, it never
// calls the Chord API. Data = one JSON built with the site (packages/docs-chord/scripts/build-index.mjs,
// published at <site>/docs/docs-index.json): every page's Markdown split into sections, and every
// OpenAPI operation with its parameters, response outline and real example.
//
// Two transports share this module: stdio.mjs (local, `claude mcp add`) and http.mjs (hosted,
// Streamable HTTP at getchord.xyz/docs/mcp). Search is a small in-memory scorer — 34 pages and 72
// operations do not need more, and it keeps the server dependency-free beyond the SDK.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

export const DEFAULT_INDEX_URL = "https://getchord.xyz/docs/docs-index.json";

// ── index loading ─────────────────────────────────────────────────────────────────────────────
export async function loadIndex({ url = process.env.DOCS_INDEX_URL || DEFAULT_INDEX_URL, file = process.env.DOCS_INDEX_FILE } = {}) {
  if (file) {
    const { readFileSync } = await import("node:fs");
    return prepare(JSON.parse(readFileSync(file, "utf8")), `file:${file}`);
  }
  const res = await fetch(url, { headers: { "User-Agent": "chord-docs-mcp" }, signal: AbortSignal.timeout(20_000) });
  if (!res.ok) throw new Error(`docs index: HTTP ${res.status} from ${url}`);
  return prepare(await res.json(), url);
}

const tokenize = (s) => (s || "").toLowerCase().replace(/[`*_>#|]/g, " ").split(/[^a-z0-9_/.{}-]+/).filter((t) => t.length > 1);

/** Pre-tokenise once per load so a search is a few map lookups per document. */
function prepare(raw, source) {
  const docs = [];
  for (const p of raw.pages) {
    docs.push({ kind: "page", id: p.path, title: p.title, url: p.url, description: p.description, heading: "", text: p.description, weight: 1.2, page: p });
    for (const s of p.sections) docs.push({ kind: "section", id: `${p.path}#${s.anchor}`, title: p.title, url: s.anchor ? `${p.url}#${s.anchor}` : p.url, description: p.description, heading: s.heading, text: s.text, weight: 1, page: p, section: s });
  }
  for (const o of raw.operations) {
    docs.push({ kind: "operation", id: o.operationId, title: `${o.method} ${o.path} — ${o.summary}`, url: o.url, description: o.tag, heading: o.summary, text: `${o.description}\n${o.parameters.map((x) => `${x.name} ${x.description}`).join("\n")}`, weight: 1.1, op: o });
  }
  for (const d of docs) {
    d.tf = new Map();
    const add = (s, w) => { for (const t of tokenize(s)) d.tf.set(t, (d.tf.get(t) || 0) + w); };
    add(d.title, 6); add(d.heading, 4); add(d.description, 2); add(d.text, 1);
    if (d.op) { add(d.op.operationId, 8); add(d.op.path, 8); add(d.op.tag, 2); }
    d.lower = `${d.title}\n${d.heading}\n${d.text}`.toLowerCase();
  }
  const df = new Map();
  for (const d of docs) for (const t of d.tf.keys()) df.set(t, (df.get(t) || 0) + 1);
  return { raw, docs, df, source, loadedAt: Date.now(), pages: raw.pages, operations: raw.operations };
}

// ── search ────────────────────────────────────────────────────────────────────────────────────
export function search(index, query, limit = 6, kinds = null) {
  const terms = [...new Set(tokenize(query))];
  const phrase = query.trim().toLowerCase();
  const N = index.docs.length;
  const scored = [];
  for (const d of index.docs) {
    if (kinds && !kinds.includes(d.kind)) continue;
    let s = 0;
    for (const t of terms) {
      const tf = d.tf.get(t);
      if (!tf) { // prefix match (e.g. "websock" → websocket)
        for (const [k, v] of d.tf) if (k.startsWith(t) && k.length - t.length <= 4) { s += Math.log(1 + v) * 0.6 * Math.log(1 + N / ((index.df.get(k) || 1))); break; }
        continue;
      }
      s += Math.log(1 + tf) * Math.log(1 + N / (index.df.get(t) || 1));
    }
    if (!s) continue;
    if (phrase.length > 3 && d.lower.includes(phrase)) s *= 1.8;
    if (terms.length > 1 && terms.every((t) => d.tf.has(t))) s *= 1.3;
    scored.push({ d, s: s * d.weight });
  }
  scored.sort((a, b) => b.s - a.s);
  // one hit per page unless it is the only thing on the page; operations are their own hits
  const seen = new Map(); const out = [];
  for (const { d, s } of scored) {
    const key = d.kind === "operation" ? d.id : d.page.path;
    if ((seen.get(key) || 0) >= 2) continue;
    seen.set(key, (seen.get(key) || 0) + 1);
    out.push({ kind: d.kind, title: d.title, heading: d.heading || undefined, url: d.url, snippet: snippet(d.text, terms), score: Number(s.toFixed(2)), ...(d.op ? { operationId: d.op.operationId, method: d.op.method, path: d.op.path } : { path: d.page.path }) });
    if (out.length >= limit) break;
  }
  return out;
}
function snippet(text, terms, width = 320) {
  const plain = (text || "").replace(/\s+/g, " ").trim();
  if (plain.length <= width) return plain;
  const low = plain.toLowerCase();
  let at = -1;
  for (const t of terms) { const i = low.indexOf(t); if (i >= 0 && (at < 0 || i < at)) at = i; }
  const start = Math.max(0, (at < 0 ? 0 : at) - 80);
  return (start ? "…" : "") + plain.slice(start, start + width) + "…";
}

// ── formatting ────────────────────────────────────────────────────────────────────────────────
function pageMarkdown(p, sectionAnchor) {
  if (sectionAnchor) {
    const s = p.sections.find((x) => x.anchor === sectionAnchor);
    if (s) return `# ${p.title}\n\n## ${s.heading}\n\n${s.text}\n\n— ${p.url}#${s.anchor}`;
  }
  return `# ${p.title}\n\n> ${p.description}\n\n${p.markdown}\n\n— ${p.url}`;
}
function operationMarkdown(o, { full = true } = {}) {
  const lines = [`## ${o.method} ${o.path}`, `**${o.summary}** · tag: ${o.tag} · operationId: \`${o.operationId}\`${o.security ? " · auth: " + o.security.map((s) => Object.keys(s)[0]).join(" or ") : ""}`, `Reference: ${o.url}`, ""];
  if (full && o.description) lines.push(o.description, "");
  if (o.parameters.length) {
    lines.push("### Parameters", "", "| name | in | required | type | description |", "| --- | --- | --- | --- | --- |");
    for (const p of o.parameters) lines.push(`| \`${p.name}\` | ${p.in} | ${p.required ? "yes" : "no"} | ${p.type ?? ""}${p.enum ? ` (${p.enum.join(" \\| ")})` : ""}${p.default !== undefined ? `, default ${JSON.stringify(p.default)}` : ""} | ${(p.description || "").replace(/\|/g, "\\|")} |`);
    lines.push("");
  }
  if (o.requestBody) { lines.push("### Request body", "", "```json", JSON.stringify(o.requestBody.schema, null, 1), "```", ""); if (o.requestBody.example) lines.push("Example:", "", "```json", JSON.stringify(o.requestBody.example, null, 1), "```", ""); }
  lines.push("### Responses", "");
  for (const [c, d] of Object.entries(o.responses)) lines.push(`- **${c}** ${d}`);
  if (o.response) {
    lines.push("", "Success shape:", "", "```json", JSON.stringify(o.response.schema, null, 1), "```");
    if (full && o.response.example != null) { let ex = JSON.stringify(o.response.example, null, 1); if (ex.length > 6000) ex = ex.slice(0, 6000) + "\n…(truncated)"; lines.push("", "Real example (captured from api.getchord.xyz):", "", "```json", ex, "```"); }
  }
  return lines.join("\n");
}

// ── server ────────────────────────────────────────────────────────────────────────────────────
export function createServer(getIndex, { name = "chord-docs", version = "0.1.0" } = {}) {
  const server = new McpServer({ name, version }, {
    instructions: "Chord developer documentation (getchord.xyz/docs): a non-custodial trading API and on-chain data index. Swap quotes and unsigned transactions on seven EVM chains (Monad 143, Robinhood Chain 4663, Arc 5042, Avalanche C-Chain 43114, Base 8453, BNB Chain 56, Arbitrum One 42161) and read-only trade data on Solana; GET /v1/chains lists what each chain serves. Use search_chord_docs first, then read_chord_docs_page for the full page or chord_api_reference for an endpoint's exact parameters, response shape and a real example. Base URL for the API itself is https://api.getchord.xyz/v1; amounts are decimal strings in the token's smallest unit; on Arc the USDC predeploy 0x3600000000000000000000000000000000000000 has 6 decimals and the zero address aliases to it. For trading and market-data tools (not the docs), connect to the hosted MCP server at https://api.getchord.xyz/v1/mcp.",
  });

  server.registerTool("search_chord_docs", {
    title: "Search the Chord docs",
    description: "Full-text search over every page of the Chord developer docs and every API endpoint. Returns the best-matching sections and operations with a snippet and the URL. Start here for any question about the Chord API, its data, streams, fees, chains or agents.",
    inputSchema: { query: z.string().min(1).max(200).describe("What you are looking for — words, an endpoint path, an error code, a field name."), limit: z.number().int().min(1).max(20).default(6).describe("Max results."), kind: z.enum(["all", "pages", "operations"]).default("all").describe("Restrict to documentation pages or API operations.") },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async ({ query, limit, kind }) => {
    const index = await getIndex();
    const kinds = kind === "pages" ? ["page", "section"] : kind === "operations" ? ["operation"] : null;
    const hits = search(index, query, limit, kinds);
    if (!hits.length) return { content: [{ type: "text", text: `No match for "${query}". Try fewer or different words, an endpoint path like /v1/arc/tokens, or list_chord_docs_pages.` }] };
    const text = hits.map((h, i) => `${i + 1}. ${h.kind === "operation" ? `${h.method} ${h.path} — ${h.title.split(" — ")[1] ?? ""} (operationId ${h.operationId})` : `${h.title}${h.heading ? ` › ${h.heading}` : ""} (${h.path})`}\n   ${h.url}\n   ${h.snippet}`).join("\n\n");
    return { content: [{ type: "text", text }], structuredContent: { results: hits } };
  });

  server.registerTool("read_chord_docs_page", {
    title: "Read a docs page",
    description: "The full Markdown of one documentation page (or one section of it) by its path, e.g. /docs/concepts/streaming/ or /docs/recipes/swap/#4-build. Paths come from search_chord_docs or list_chord_docs_pages.",
    inputSchema: { path: z.string().min(1).max(200).describe("Page path (with or without the /docs prefix, with or without a trailing slash), optionally with #anchor.") },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async ({ path }) => {
    const index = await getIndex();
    let [p, anchor] = path.replace(/^https?:\/\/[^/]+/, "").split("#");
    p = p.replace(/^\/?docs\/?/, "/").replace(/\/+$/, "") + "/";
    if (p === "//") p = "/";
    const page = index.pages.find((x) => x.path.replace(/^\/docs/, "") === p || x.path === p);
    if (!page) return { isError: true, content: [{ type: "text", text: `No page at ${path}. Known paths:\n${index.pages.map((x) => x.path).join("\n")}` }] };
    return { content: [{ type: "text", text: pageMarkdown(page, anchor) }] };
  });

  server.registerTool("list_chord_docs_pages", {
    title: "List all docs pages",
    description: "Every page of the Chord docs with its path and one-line description, grouped by section, plus the API reference tags. Use it to orient before reading.",
    inputSchema: {},
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async () => {
    const index = await getIndex();
    const groups = new Map();
    for (const p of index.pages) { const g = p.path.replace(/^\/docs\//, "").split("/")[0] || "getting-started"; const key = p.path.includes("/", 6) && p.path !== "/docs/" ? g : "getting-started"; if (!groups.has(key)) groups.set(key, []); groups.get(key).push(p); }
    const lines = [];
    for (const [g, ps] of groups) { lines.push(`## ${g}`); for (const p of ps) lines.push(`- ${p.path} — ${p.title}: ${p.description}`); lines.push(""); }
    const tags = new Map();
    for (const o of index.operations) { if (!tags.has(o.tag)) tags.set(o.tag, []); tags.get(o.tag).push(`${o.method} ${o.path}`); }
    lines.push("## api-reference (use chord_api_reference for details)");
    for (const [t, ops] of tags) lines.push(`- ${t}: ${ops.join(" · ")}`);
    return { content: [{ type: "text", text: lines.join("\n") }] };
  });

  server.registerTool("chord_api_reference", {
    title: "API endpoint reference",
    description: "Exact reference for Chord API endpoints: method, path, every parameter with type/enum/default, the request body, the response shape and a real example response captured from the live API. Look up by operationId (getQuote), by path (/v1/arc/tokens), by method+path, or by words (\"holders\", \"swap simulate\"). Returns up to `limit` operations, most relevant first.",
    inputSchema: { query: z.string().min(1).max(200).describe("operationId, path, or words."), limit: z.number().int().min(1).max(10).default(3), full: z.boolean().default(true).describe("Include the description prose and the real example (false = compact: parameters and shapes only).") },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async ({ query, limit, full }) => {
    const index = await getIndex();
    const q = query.trim();
    const norm = q.toLowerCase().replace(/^(get|post|delete|put)\s+/, "").replace(/^https?:\/\/[^/]+/, "").replace(/\?.*$/, "");
    let ops = index.operations.filter((o) => o.operationId.toLowerCase() === norm || o.path.toLowerCase() === norm || o.path.toLowerCase() === "/v1" + norm || o.path.toLowerCase().replace(/^\/v1/, "") === norm);
    if (q.match(/^(get|post|delete|put)\s+/i)) ops = ops.filter((o) => o.method === q.split(/\s+/)[0].toUpperCase());
    if (!ops.length) ops = search(index, q, limit, ["operation"]).map((h) => index.operations.find((o) => o.operationId === h.operationId));
    if (!ops.length) return { isError: true, content: [{ type: "text", text: `No endpoint matches "${query}". Tags: ${[...new Set(index.operations.map((o) => o.tag))].join(", ")}. Try list_chord_docs_pages.` }] };
    return { content: [{ type: "text", text: ops.slice(0, limit).map((o) => operationMarkdown(o, { full })).join("\n\n---\n\n") }] };
  });

  return server;
}
